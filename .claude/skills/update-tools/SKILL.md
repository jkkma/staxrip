---
name: update-tools
description: Record a bundled tool or plugin update - write the correctly-categorized CHANGELOG sub-list entry, and apply any Package.vb metadata changes when an upstream project moves, renames, or changes its AviSynth/VapourSynth interface. Use for "Tool Updates" commits and for the Update tools block of a release.
---

# Update tools and plugins

## What a tool update actually is here

Worth being precise, because the obvious assumption is wrong:

**`Package.vb` does not store tool versions.** It has `.Version`, `.VersionDate`,
`.VersionAllowOld`, `.VersionAllowNew` and `.VersionAllowAny` properties, and across all **299**
package entries **not one sets any of them**. They are an unused constraint mechanism, not a record
of what ships.

So a tool update splits into two independent activities:

1. **Changelog** -- record which bundled binary versions changed. This is the part that happens on
   every release, and it is bookkeeping about the release `.7z`, not about the source tree.
2. **`Package.vb` metadata** -- only when something structural changed upstream: the project moved
   to a new maintainer, the download URL changed, a plugin gained or lost an AviSynth or VapourSynth
   interface, or a package was added or dropped.

Most "Tool Updates" commits touch only #1, or only a handful of lines in #2. Commit `4cccd303` is a
representative #2: `VSFilterMod` was re-pointed from `kedaitinh12` to `Masaiki`, its description
rewritten, and `.AvsFilterNames` dropped because that fork is VapourSynth-only -- which also moved
it between changelog sub-lists.

## The four sub-lists

Both changelogs keep this structure inside a release section:

```
- Update tools
    - eac3to v3.64
- Update AviSynth+ plugins
    - ...
- Update Dual plugins
    - ...
- Update VapourSynth plugins
    - ...
```

A package's sub-list is determined entirely by which filter-name arrays its entry sets:

| `Package.vb` entry | Sub-list |
|---|---|
| `Package`, or `PluginPackage` with neither array | `Update tools` |
| `PluginPackage` with `.AvsFilterNames` only | `Update AviSynth+ plugins` |
| `PluginPackage` with `.VsFilterNames` only | `Update VapourSynth plugins` |
| `PluginPackage` with **both** | `Update Dual plugins` |

Current split: 63 tools, 132 AviSynth-only, 91 VapourSynth-only, 13 dual.

**The trap:** the AviSynth and VapourSynth builds of a plugin are *separate entries that share one
`.Name`*, told apart only by `.Filename` and their filter arrays. `DotKill` exists twice --
Asd-g's AviSynth port and myrsloik's VapourSynth original. Updating one and filing it under the
other's heading is an easy and invisible mistake.

Resolve it with the bundled script rather than by eye:

```powershell
.claude\skills\update-tools\scripts\package-category.ps1 DotKill
```

```
Name    SubList                    Filename    Line DownloadURL
----    -------                    --------    ---- -----------
DotKill Update AviSynth+ plugins   DotKill.dll 2552 https://github.com/Asd-g/AviSynth-DotKill/releases
DotKill Update VapourSynth plugins DotKill.dll 2562 https://github.com/myrsloik/DotKill
```

Two rows means you must decide which one you actually updated. The `Line` column jumps you to the
entry. `-Category Dual` lists a whole category; no arguments lists everything grouped.

## Writing the entry

### Ordering

Case-insensitive alphabetical within each sub-list. From the v2.52.5 release:
`eac3to, ffmpeg, MediaInfo, MKVToolNix, NVEncC, QSVEncC, SvtAv1EncApp x3, TrueHDD, VCEEncC,
vvencFFapp, x264, x265`.

### Version strings

Use the upstream project's own version string **verbatim**. Do not normalise it. Real entries:

```
    - eac3to v3.64
    - MKVToolNix v100.0
    - ffmpeg v8.2-dev-N-125670-x64-clang22.1.8
    - x265 v4.3+6+70-44ebc4e46-[Mod-by-Patman]-x64-avx2-clang22.1.8
    - DotKill R4
    - VSFilterMod r5.3.1
    - FillBorders v4
```

Note `v3.64`, `R4`, and `r5.3.1` coexist -- the prefix follows upstream, it is not a house style.

### Names

The changelog name usually matches the package `.Name`, but not always:

| `Package.vb` `.Name` | Changelog |
|---|---|
| `NVEncC` | `NVEncC` |
| `MKVToolnix GUI` | `MKVToolNix` |
| `SvtAv1EncApp (SVT-AV1-HDR)` | `SvtAv1EncApp ... [SVT-AV1-HDR]` |

**The authority is the previous release's entry for that tool, not a rule.** Grep for it:

```powershell
Select-String -Path CHANGELOG.md -Pattern '^\s+- <toolname>' | Select-Object -First 3
```

and match that spelling exactly.

### Same-name tools

The five SVT-AV1 forks all ship a binary called `SvtAv1EncApp.exe` from one download URL. The
package `.Name` disambiguates in **parentheses**; the changelog disambiguates with a **trailing
square-bracket tag**:

```
    - SvtAv1EncApp v4.2.0+71+88-17cd99550-[Mod-by-Patman]-x64-clang22.1.8 [SVT-AV1]
    - SvtAv1EncApp v4.1.0+77+85-e4b6c4ff5-[Mod by Patman]-x64-clang22.1.8 [SVT-AV1-HDR]
    - SvtAv1EncApp v4.1.0+54+28-12aa310be-[Mod-by-Patman]-x64-clang22.1.8 [SVT-AV1-Tritium]
```

The inner `[Mod-by-Patman]` is part of upstream's own build string; the trailing tag is ours.

## Changing `Package.vb` metadata

When the update is structural, edit the entry in place. Fields that actually change in practice:

- `.WebURL` / `.DownloadURL` -- upstream moved or forked. Verify both resolve before committing;
  they are the only way users can get the tool.
- `.Description` -- rewrite when the fork's purpose genuinely differs. Keep it one sentence.
- `.AvsFilterNames` / `.VsFilterNames` -- add or remove when the plugin gains or loses an interface.
  **This moves the package between changelog sub-lists**, and it also changes
  `PluginPackage.IsPluginPackageRequired`, which decides whether StaxRip nags the user to install
  the plugin. The arrays hold the script-callable filter names (`{"VobSub", "TextSubMod"}` for
  AviSynth, `{"vsfm.VobSub", "vsfm.TextSubMod"}` for VapourSynth, namespace-qualified). Get them
  from the plugin's own documentation, not from the old entry.
- `.Filename` -- upstream renamed the binary. Also check `.Filename32` and `.Locations`.
- `.HelpSwitch` -- the tool changed how it prints help. See `Package.CreateHelpfile()`; a `"stderr"`
  marker inside the switch string means help goes to stderr.

Adding a whole package follows the existing `Shared Property <X> As Package = Add(New Package With
{...})` or the bare `Add(New PluginPackage With {...})` form used inside the plugin lists. Copy the
nearest sibling and adjust; field order in the file is loose.

**ASCII only.** `Package.vb` is a `.vb` file so `Build.ps1` exempts it, but descriptions get copied
from upstream READMEs and routinely carry smart quotes and en dashes. Keep them ASCII anyway for
consistency with the rest of the file.

## Both changelogs

Entries go in the `v2.5x.0 (not published yet)` block at the top of **both** `CHANGELOG.md` and
`CHANGELOG-SUPPORTER.md`, unless the tool ships only in the supporter build. The two files track
independent version streams -- see `CLAUDE.md` and the `release` skill.

## Commit

Terse, matching history: `Tool Updates`, or `Update x265` when it is one tool.
