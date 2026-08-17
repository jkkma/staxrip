---
name: add-encoder-param
description: Add, update, or remove a CLI parameter on a StaxRip video encoder. Creates the Param property with correct type and bounds, registers it in the right Add("<Group>", ...) block, checks the storage-key impact on saved templates, and writes the CHANGELOG entry. Use whenever an encoder gains, renames, or drops a switch upstream.
---

# Add an encoder parameter

The repeating job in this repo. A single upstream encoder release usually means: new switches to
expose, changed bounds on existing ones, and a changelog line per switch.

Read `references/param-types.md` for the complete field semantics before writing any param. The
fields are not self-explanatory and getting `.Config` or `.IntegerValue` wrong produces a command
line the encoder rejects at runtime, which nothing here will catch for you.

## 1. Establish ground truth from the encoder itself

Never work from memory of what a switch does. Get the real help text.

`Source/General/Package.vb` holds the `HelpSwitch` for each tool (`--fullhelp` for x265 and
vvencFFapp, `--help` or a tool-specific variant for others). Two ways to read it:

- In-app: the Apps Manager caches help output to `Package.HelpFile`; `Package.CreateHelpfile()`
  regenerates it by running the executable.
- Directly: run the encoder binary with its help switch. Some tools print help on **stderr** --
  `CreateHelpfile` handles this via a `"stderr"` marker inside `HelpSwitch`, so check that property
  before assuming stdout.

Note that help output formats change between releases; commit `6af89a95 "Fix x265 new help output"`
exists precisely because of that. If parsing looks wrong, re-read the raw text.

From the help entry, extract: exact switch spelling, whether a `--no-` form exists, value type,
min/max, default, and the units.

## 2. Pick the param type

| Help text shape | Type |
|---|---|
| Flag, present/absent, possibly with a `--no-x` counterpart | `BoolParam` |
| Numeric with a range | `NumParam` |
| Fixed set of named choices | `OptionParam` |
| Free text, filename, or comma-separated list | `StringParam` |
| Visual separator in the GUI only | `LineParam` |

## 3. Declare it

Named `Property` when anything else references it (a `VisibleFunc` on another param, a special case
in `GetCommandLine`, an override on the `<Name>Enc` class). Inline `New XParam With {...}` inside the
`Add(...)` call when nothing else touches it -- most params are inline.

```vb
Property FoveaSigma As New NumParam With {
    .Switch = "--fovea-sigma",
    .Text = "Fovea Sigma",
    .Config = {0.0, Integer.MaxValue, 0.1, 1},
    .Init = 0}
```

Rules that matter:

- `.Config` is `{min, max, step, decimalPlaces}`. Trailing elements may be omitted and default to
  `step = 1`, `decimalPlaces = 0`. **`{0, 0}` is a trap** -- it is rewritten to
  `{Double.MinValue, Double.MaxValue}`, an unbounded field.
- `.Init` sets `Value` **and** `DefaultValue` in one assignment. It must equal the encoder's own
  default, because `GetArgs()` only emits the switch when `Value <> DefaultValue`. An `.Init` that
  disagrees with the encoder means the switch is emitted on every encode, or never.
- `decimalPlaces = 0` makes the control round to integers (`NumParam.ValueChanged` does `CInt`).
  A fractional switch with `decimalPlaces = 0` silently truncates user input.
- For `BoolParam`, set `.NoSwitch` when the encoder has an explicit negative form. Set
  `.IntegerValue = True` instead when the encoder wants `--switch 1` / `--switch 0`.
- For `OptionParam`, `.Options` are the GUI labels. Without `.Values`, the emitted token is
  `Options(Value).ToLowerInvariant.Replace(" ", "")` -- so `"BT 2020"` emits `bt2020`. When that
  mapping is wrong, supply `.Values` explicitly. A `.Values` entry starting with `--` is emitted
  verbatim as the whole argument.
- Guard version- or build-specific switches with `.VisibleFunc`, following the existing pattern:
  `.VisibleFunc = Function() Package.x265Type = x265Type.DJATOM`.

## 4. Register it in a group

Add it to the appropriate `Add("<Group>", ...)` call inside the `Items` override of the
`<Name>Params` class. The group string becomes the GUI heading. Reuse an existing group unless the
upstream feature is genuinely a new area -- x265's `Add("Foveated Encoding", ...)` was added as a
group because foveated encoding is a distinct feature set, and related existing params (`CUtree`,
`RcGrain`, `ConstVBV`) were moved into it.

`Add(...)` back-fills `HelpSwitch` from the first switch automatically. Set `.HelpSwitch` manually
only when several params share one help entry -- e.g. x265's `FoveaGazeX` and `FoveaGazeY` both map
to `--fovea-gaze`, and neither sets `.Switch` because the combined value is assembled elsewhere.

Ordering inside a group is by declaration, then the whole list is re-sorted by `.Weight`.

## 5. Check the storage-key impact

Before finishing, re-read the "Param storage keys are load-bearing" section of `CLAUDE.md`.

`GetKey()` = `Name ?? Switch ?? (Text + HelpSwitch) ?? Text`, and that string is the persistence key
in every saved template and `.srip` project file.

- **Adding** a param: no risk.
- **Renaming a `.Switch`** because upstream renamed it: every user's saved value for that setting is
  orphaned. Preserve it by setting `.Name` to the old switch string, or state in the changelog that
  the setting resets.
- **Editing `.Text`** on a param with no `.Name` and no `.Switch`: same orphaning problem, and much
  easier to do by accident. Check before "improving" a label.

## 6. Changelog

Add one line per switch to the `v2.5x.0 (not published yet)` block in **both** `CHANGELOG.md` and
`CHANGELOG-SUPPORTER.md` (they are separate version streams -- see `CLAUDE.md`).

Format, matching existing entries exactly:

```
- x265: Add "--fovea-delta" parameter
- x265: Add "--mcstf" parameter
- SvtAv1EncApp: Extend "--hierarchical-levels" parameter
- SvtAv1EncApp-Essential: Fix not properly working setting of "--crf" and "--qp" parameter values
```

Prefix is the tool name as users know it (`x265`, `x264`, `SvtAv1EncApp`, `SvtAv1EncApp-Essential`,
`SvtAv1EncApp-HDR`, `SvtAv1EncApp-Tritium`, `NVEnc`, `QSVEnc`, `VCEEnc`, `aomenc`, `rav1e`,
`vvencFFapp`), not the VB class name. Verb is one of `Add` / `Alter` / `Extend` / `Fix` / `Remove`.
Switch names go in straight double quotes.

## 7. Verify

There are no tests. Confirm by building. Nothing puts MSBuild on `PATH`, so resolve it first
(`STAXRIP_MSBUILD` wins if set; see the Build section of `CLAUDE.md`):

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = if ($env:STAXRIP_MSBUILD) { $env:STAXRIP_MSBUILD } else {
    @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
                 -find 'MSBuild\**\MSBuild.exe') |
        Where-Object { $_ -match '\\Bin\\(amd64\\)?MSBuild\.exe$' } |
        Sort-Object { $_ -notmatch '\\amd64\\' } | Select-Object -First 1
}
& $msbuild Source\StaxRip.vbproj -t:Build -p:Configuration=Debug -p:Platform=x64
```

`StaxRip.vbproj` rather than `StaxRip.sln`: a param change is pure VB, and the solution also builds
the native `FrameServer`, which needs the MSVC C++ build tools you may not have installed.
`Source\packages` must be restored (`nuget restore Source\StaxRip.sln`) or every line is `BC30002`.

The `compile-gate` Stop hook runs this same build automatically, so a clean turn-end with no skip
notice already means it compiled.

`Option Strict On` catches type errors in `.Config` arrays and `.Init` assignments, which is most of
what goes wrong syntactically. It cannot catch a wrong default, a wrong range, or a broken storage
key -- re-check those against the help text by hand.

## Encoder files

`Source/Encoding/`: `AOMEnc.vb`, `ffmpegEnc.vb`, `NVEnc.vb`, `QSVEnc.vb`, `Rav1e.vb`,
`SvtAv1Enc.vb`, `SvtAv1EssentialEnc.vb`, `SvtAv1HdrEnc.vb`, `SvtAv1PsyexEnc.vb`,
`SvtAv1TritiumEnc.vb`, `VCEEnc.vb`, `VvencffappEnc.vb`, `x264Enc.vb`, `x265Enc.vb`.

The five `SvtAv1*` files are separate forks of SVT-AV1 with diverging switch sets. A switch added to
one is **not** automatically applicable to the others -- check each fork's own help output before
propagating a change.
