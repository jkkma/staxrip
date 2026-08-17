# Param type reference

Derived from `Source/Video/VideoEncoderCommandLine.vb`. When in doubt, read that file -- it is
under 900 lines and is the whole model.

## Class hierarchy

```
CommandLineParams (MustInherit)      one per encoder, e.g. x265Params
  +-- Items                          List(Of CommandLineParam), built once in the override
  +-- Add(path, ParamArray items)    registers items into a GUI group
  +-- GetCommandLine(...)            MustOverride, assembles the final string
  +-- Separator As String = " "      what sits between a switch and its value

CommandLineParam (MustInherit)
  +-- LineParam        GUI separator only, emits nothing
  +-- BoolParam        flag
  +-- NumParam         number
  +-- OptionParam      fixed choice list
  +-- StringParam      free text / path
```

## Fields on every param (`CommandLineParam`)

| Field | Type | Meaning |
|---|---|---|
| `Switch` | `String` | The primary CLI switch, e.g. `"--crf"`. |
| `NoSwitch` | `String` | Negative form, e.g. `"--no-sbrc"`. `BoolParam` only. |
| `Switches` | `IEnumerable(Of String)` | Extra aliases, folded into `GetSwitches()`. |
| `HelpSwitch` | `String` | Which help entry this param documents. Auto-filled by `Add(...)` from `GetSwitches()(0)` when empty. Set manually when several params share one help entry, or when the param has no `Switch` of its own. |
| `Text` | `String` | GUI label. **Part of the storage key when `Name` and `Switch` are both empty.** |
| `Name` | `String` | Explicit storage key. Highest precedence in `GetKey()`. Use it to pin a key across an upstream switch rename. |
| `Path` | `String` | GUI group heading. Set by `Add(...)`; do not assign directly. |
| `Label` | `String` | Secondary label. |
| `HintText` | `String` | Placeholder / hint in the control. |
| `Help` | `String` | Inline help text. |
| `URLs` | `List(Of String)` | Reference links surfaced in the UI. |
| `AlwaysOn` | `Boolean` | Emit the switch even when the value equals the default. |
| `ArgsFunc` | `Func(Of String)` | Full override of argument generation. When set, all normal emission logic is bypassed. |
| `ImportAction` | `Action(Of String, String)` | Hook for importing a value from a pasted command line. |
| `VisibleFunc` | `Func(Of Boolean)` | Re-evaluated on every value change; hides the param and suppresses its argument when it returns `False`. |
| `Weight` | `Integer` | Final sort order across the whole `Items` list. |
| `LeftMargin` | `Double` | Layout nudge. |

### `GetKey()` -- the persistence key

```
Name  ??  Switch  ??  (Text + HelpSwitch)  ??  Text
```

This string keys the `PrimitiveStore` dictionaries (`Bool`, `Int`, `Double`, `String`) that are
serialized into saved templates and `.srip` project files. Changing whichever of these resolves
first silently orphans every saved user value for that setting. See `CLAUDE.md`.

### Value persistence

Every param's `Value` setter writes through to `Store` **only when the value differs from
`InitialValue`**; when they match, the key is removed. Only deltas are persisted, so the store stays
small and defaults track code changes automatically.

`WasInitialValueSet` guards this: the first assignment to `Value` also becomes `InitialValue`.
`Add(...)` sets `WasInitialValueSet = True` on every item it registers.

---

## `BoolParam`

| Field | Meaning |
|---|---|
| `Init` (write-only) | Sets `Value` and `DefaultValue` together. |
| `DefaultValue` | The encoder's own default. Drives emission. |
| `IntegerValue` | `True` -> emit `--switch 1` / `--switch 0`. `False` -> emit `Switch` or `NoSwitch`. |
| `ValueChangedAction` | `Action(Of Boolean)` fired on user change. |

Emission (`GetArgs`):

- `Value = True`, `DefaultValue = False` -> `Switch` (or `Switch <sep> 1` when `IntegerValue`)
- `Value = False`, `DefaultValue = True` -> `NoSwitch` (or `Switch <sep> 0` when `IntegerValue`)
- otherwise -> nothing

So a `BoolParam` whose default is `False` and which has no `NoSwitch` can never emit a negative form.
That is usually right; confirm against the help text.

```vb
New BoolParam With {.Switch = "--aq-motion", .Text = "AQ Motion"}
New BoolParam With {.Switch = "--sbrc", .NoSwitch = "--no-sbrc", .Text = "Segment based rate control"}
New BoolParam With {.Switch = "--mcstf", .NoSwitch = "--no-mcstf", .Text = "GOP-based Temporal Filter", .Init = False, .IntegerValue = False}
```

---

## `NumParam`

| Field | Meaning |
|---|---|
| `Config` | `{min, max, step, decimalPlaces}` as `Double()`. |
| `Init` (write-only) | Sets `Value` and `DefaultValue`. |
| `ValueChangedAction` | `Action(Of Double)`. |

`Config` behaviour, exactly as implemented:

- Omitted entirely -> `{Double.MinValue, Double.MaxValue, 1, 0}`.
- `{min, max}` -> `step` defaults to `1`, `decimalPlaces` to `0`.
- **`{0, 0}` -> rewritten to `{Double.MinValue, Double.MaxValue, ...}`.** Never write `{0, 0}` meaning
  "clamped to zero"; it produces an unbounded field.
- `decimalPlaces = 0` -> `ValueChanged` rounds via `CInt`. A fractional switch needs a non-zero
  `decimalPlaces` or user input is truncated.

Emission: `Switch <sep> Value.ToInvariantString` when `Value <> DefaultValue` or `AlwaysOn`.
`ToInvariantString` matters -- it prevents a comma decimal separator on non-English locales from
producing an unparseable command line.

```vb
Property McstfRefRange As New NumParam With {
    .Switch = "--mcstf-ref-range",
    .Text = "Maximum number of range for MCSTF",
    .Init = 2,
    .Config = {0, 4}}

Property FoveaSigma As New NumParam With {
    .Switch = "--fovea-sigma",
    .Text = "Fovea Sigma",
    .Config = {0.0, Integer.MaxValue, 0.1, 1},
    .Init = 0}
```

---

## `OptionParam`

| Field | Meaning |
|---|---|
| `Options` | `String()` of GUI labels. Index into this array **is** the stored value. |
| `Values` | `String()` of emitted tokens, parallel to `Options`. Optional. |
| `Init` (write-only) | Sets `Value` (an index) and `DefaultValue`. |
| `IntegerValue` | Emit the numeric index instead of a token. |
| `ValueChangedAction` | `Action(Of Integer)`. |

Emission, when `Value <> DefaultValue` or `AlwaysOn`:

1. `Values` set and `Values(Value)` starts with `--` -> emit `Values(Value)` verbatim as the whole
   argument (the switch itself is ignored).
2. `Values` set otherwise -> `Switch <sep> Values(Value)`, with the separator dropped if the value is
   blank.
3. No `Values`, `IntegerValue = True` -> `Switch <sep> Value` (the index).
4. No `Values`, `IntegerValue = False` -> `Switch <sep> Options(Value).ToLowerInvariant.Replace(" ", "")`.

Case 4 is the default and the usual source of bugs: `"SMPTE 170 M"` emits `smpte170m`,
`"BT 470 BG"` emits `bt470bg`. When the encoder expects anything else, supply `.Values`.

**The stored value is the index.** Inserting an option in the middle of `Options` shifts every index
after it and silently changes what every existing saved template means. Append new options at the
end, or supply `.Values` and accept that the store still holds indices. `Value`'s getter clamps
out-of-range indices down to `Options.Length - 1`, so shrinking the list corrupts rather than crashes.

```vb
Property Range As New OptionParam With {
    .Switch = "--range", .Text = "Range",
    .Options = {"Undefined", "Limited", "Full"}}
```

---

## `StringParam`

| Field | Meaning |
|---|---|
| `Init` (write-only) | Sets `Value` and `DefaultValue`. |
| `BrowseFile` (write-only) | `True` sets `BrowseFileFilter = "*.*|*.*"`, giving a file picker. |
| `BrowseFileFilter` | Explicit picker filter, e.g. `"Zone file|*.txt"`. |
| `BrowseFolderText` | Folder picker prompt. |
| `Quotes` | `QuotesMode.Always` -> always wrap in `"`. `QuotesMode.Auto` -> `val.Escape`. Use one of these for anything that can contain a space, especially paths. |
| `RemoveSpace` | Strip all spaces from the value before emitting. |
| `Menu` | Menu definition string for preset values. |
| `Expand` | Layout: stretch the edit control. Defaults `True`. |
| `InitAction` | `Action(Of SimpleUI.TextBlock)` for control setup. |
| `TextChangedAction` | `Action(Of String)`. |

Emission: nothing when the value is empty or equals `DefaultValue`. With no `Switch` set, the value
is emitted bare -- but only when `AlwaysOn` is also set.

```vb
Property FoveaGazeFile As New StringParam With {
    .Switch = "--fovea-gaze-file",
    .Text = "Fovea Gaze File",
    .BrowseFile = True}

New StringParam With {.Switch = "--zones", .Text = "Zones"}
```

A path param without `Quotes` set will break on any path containing a space.

---

## `LineParam`

A horizontal rule in the GUI. Emits nothing, stores nothing. Used to break up long groups.

---

## Registration

```vb
Overrides ReadOnly Property Items As List(Of CommandLineParam)
    Get
        If ItemsValue Is Nothing Then
            ItemsValue = New List(Of CommandLineParam)

            Add("Rate Control", Mode, Quant, Bitrate, ...)
            Add("Foveated Encoding", FoveaGazeX, FoveaGazeY, FoveaDelta, ...)
            ...

            ItemsValue = ItemsValue.OrderBy(Function(i) i.Weight).ToList
        End If

        Return ItemsValue
    End Get
End Property
```

`Add(path, ParamArray items)` does three things per item: sets `WasInitialValueSet = True`, sets
`Path` to the group heading, and back-fills `HelpSwitch` from `GetSwitches()(0)` when it is empty.

`CommandLineParams.Init(store)` then calls `InitParam(store, params)` on every item, which is what
binds them to the `PrimitiveStore`. Params reachable only through a code path that never calls
`Add(...)` are never bound, and reading their `Value` will throw a `NullReferenceException` on
`Store`.
