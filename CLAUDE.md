# StaxRip

Windows GUI front-end for video/audio encoding tools (x265, x264, SVT-AV1, NVEnc, QSVEnc,
VCEEnc, aomenc, rav1e, vvenc, ffmpeg). It builds command lines for those tools, drives them
as child processes, and manages AviSynth+/VapourSynth frame serving.

## Stack

- **VB.NET**, WinForms, **.NET Framework 4.8**, x64. `Option Strict On`, `Option Explicit On`, `Option Infer On`.
- Native `Source/FrameServer/*.vcxproj` (C++) hosts the AviSynth/VapourSynth servers.
- Legacy MSBuild + **`packages.config`** NuGet (DirectN, ManagedCuda-100, PowerShell 5 reference assemblies).
  Not SDK-style: `dotnet build` will not build this. Needs `MSBuild.exe` from Visual Studio or Build Tools.
- **There is no test suite.** The compiler is the only automated gate. Treat a clean build as the bar.

## Build

```powershell
# Full release build + 7z packaging (fill in $msBuildDirectory / $7zDirectory first)
Source\Release.ps1

# Build only
Source\Build.ps1
```

Both scripts **hard-fail on non-ASCII characters** (see below) before they invoke MSBuild.

Neither script finds MSBuild for you. To compile ad hoc, resolve it once and reuse it -- this is the
same resolution the `compile-gate` hook does, and `STAXRIP_MSBUILD` overrides it everywhere:

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

Prefer the `amd64` host: the 32-bit one is capped near 3-4 GB and OOMs on the larger encoder files.
Note the glob is `MSBuild\**\MSBuild.exe`, **not** `MSBuild\**\Bin\MSBuild.exe` -- the 64-bit host is
at `MSBuild\Current\Bin\amd64\MSBuild.exe`, so the narrower glob only ever returns the 32-bit one.
`Source\packages` is gitignored, so a fresh clone has none and a build without it is pure `BC30002`
noise. `packages.config` predates `PackageReference`, so a bare `-t:Restore` is a no-op and you do
**not** need `nuget.exe` -- MSBuild restores it with the extra flag:

```powershell
& $msbuild Source\StaxRip.sln -t:Restore -p:RestorePackagesConfig=true
```

`StaxRip.vbproj` has no `ProjectReference` to `FrameServer.vcxproj`, so building the **project** needs
only the .NET workload, while building the **solution** also needs the MSVC v143 C++ build tools.

### FrameServer does not build from a clean clone

`FrameServer.vcxproj` sets `<IncludePath>..\bin\Apps\FrameServer\VapourSynth\sdk\include\vapoursynth`.
`/Source/bin` is **gitignored**, and the repo vendors `avisynth.h` + `avs\*.h` but **not** the
VapourSynth SDK -- those headers ship inside the bundled VapourSynth app. So a fresh clone fails at
`error C1083: 'VSScript4.h'` even with the full C++ toolchain installed.

Stage four headers there before touching `Source/FrameServer/`, matching the **bundled** VapourSynth
version rather than upstream `master` (the changelogs are the only record of which that is -- `R73`
at time of writing, and its `VapourSynth4.h` already differs from `master`):

```powershell
$d = 'Source\bin\Apps\FrameServer\VapourSynth\sdk\include\vapoursynth'
New-Item -ItemType Directory -Force $d | Out-Null
'VapourSynth4.h','VSScript4.h','VSHelper4.h','VSConstants4.h' | ForEach-Object {
    Invoke-WebRequest "https://raw.githubusercontent.com/vapoursynth/vapoursynth/R73/include/$_" -OutFile "$d\$_"
}
```

The `compile-gate` hook checks for these up front and skips rather than failing the turn.

## Hard invariants

### ASCII-only in non-`.vb` project files

`Build.ps1` and `Release.ps1` throw on any codepoint > 127 in files under `Source/` with these
extensions: `.config .cpp .h .ps1 .rc .resx .sln .vbproj` (paths containing `\Apps\` are skipped).
`.vb` and `.md` are exempt.

A smart quote, en dash, or non-breaking space pasted into a `.resx` or `.ps1` is invisible in review
and only surfaces when someone tries to cut a release. The `ascii-guard` hook catches it at edit time
(see [Claude Code hooks](#claude-code-hooks)).

### Param storage keys are load-bearing

`CommandLineParam.GetKey()` (`Source/Video/VideoEncoderCommandLine.vb`) resolves to:

```
Name  ??  Switch  ??  (Text + HelpSwitch)  ??  Text
```

That string is the dictionary key in `PrimitiveStore` (`Bool` / `Int` / `Double` / `String`), which is
what gets serialized into users' saved **templates** and **`.srip` project files**.

Consequences, all of which compile cleanly and fail silently at runtime:

- Renaming `.Switch` on a param that has no `.Name` **orphans every saved value** for that setting.
- Changing `.Text` orphans saved values for params that have neither `.Name` nor `.Switch`
  (i.e. the inline `New BoolParam With {...}` ones that only set `.Text` + `.HelpSwitch`).
- Removing a param leaves dead keys in user stores (harmless) but drops the setting.

If a switch is renamed upstream, set an explicit `.Name` to the **old** key to preserve continuity,
or accept the reset deliberately.

Encoder classes are `<Serializable()>` and hold a `ParamsStore As New PrimitiveStore`, so the same
reasoning applies to `AudioProfile.vb` and `ApplicationSettings.vb`.

### Only deltas are persisted

Setting a param `Value` equal to its `InitialValue` **removes** the key from the store; `GetArgs()`
emits a switch only when `Value <> DefaultValue` (or `AlwaysOn` is set). `Init` is a write-only
property that sets `Value` and `DefaultValue` together. So changing an `.Init` value changes both the
UI default and which command lines get the switch emitted at all.

## Layout

| Path | Contents |
|---|---|
| `Source/Encoding/` | One file per encoder. Each defines `<Name>Enc` (the encoder) and `<Name>Params` (the CLI surface). Largest files in the repo. |
| `Source/Video/VideoEncoderCommandLine.vb` | `CommandLineParams` base + the `BoolParam` / `NumParam` / `OptionParam` / `StringParam` / `LineParam` model. Read this before touching any encoder. |
| `Source/General/Package.vb` | Metadata for all 299 external tools and plugins: filename, locations, URLs, `HelpSwitch`. It has `.Version` / `.VersionDate` properties but **no entry sets them** -- bundled tool versions live only in the changelogs. |
| `Source/General/Misc.vb` | Declares the globals `g` (`GlobalClass`), `p` (`Project`, current job state), `s` (`ApplicationSettings`). |
| `Source/Forms/` | WinForms dialogs. `MainForm.vb` is by far the highest-churn file in the repo. |
| `Source/UI/` | `SimpleUI` dynamic layout engine that renders params into controls. |
| `Source/FrameServer/` | Native AviSynth/VapourSynth server. |
| `Docs/` | User documentation (GitHub wiki-style markdown). |

## Encoder param conventions

Params are declared as `Property` members on the `<Name>Params` class, then registered into GUI groups
inside the `Items` override:

```vb
Property FoveaSigma As New NumParam With {
    .Switch = "--fovea-sigma",
    .Text = "Fovea Sigma",
    .Config = {0.0, Integer.MaxValue, 0.1, 1},
    .Init = 0}
...
Add("Foveated Encoding", FoveaGazeX, FoveaGazeY, FoveaDelta, FoveaSigma, FoveaGazeFile)
```

`Add(path, ...)` sets each item's `Path` (the GUI group heading) and back-fills `HelpSwitch` from the
first entry of `GetSwitches()` when it is empty. `ItemsValue` is finally sorted by `.Weight`.

Declare a param as a named `Property` when other code needs to reference it (visibility rules,
`GetCommandLine` special cases); use an inline `New XParam With {...}` inside the `Add(...)` call when
nothing else touches it. See `.claude/skills/add-encoder-param/` for the full field reference.

## Changelogs

Two independent version streams:

- `CHANGELOG.md` -> public stream (currently `2.52.x`). **`AssemblyInfo.vb` tracks this one.**
- `CHANGELOG-SUPPORTER.md` -> supporter stream (currently `2.53.x`).

Do not assume the numbers match; they don't, and they do not advance together. Every release commit
adds exactly one section to `CHANGELOG.md`, but adds **zero, one, or several** to
`CHANGELOG-SUPPORTER.md` -- supporter builds ship on their own cadence and get written up
retroactively in batches (`v2.52.1` and `v2.52.3` added none; `v2.52.4` added four). A supporter
heading carries its own build's ship date, which lags the commit, or literally `(not published yet)`
until it is known. See `.claude/skills/release/` before cutting one.

Both files keep a commented `v2.5x.0 (not published yet)` template block pinned at the top as a
scratchpad.

Entry format is strict and worth matching exactly:

```
- x265: Add "--fovea-delta" parameter
- SvtAv1EncApp: Extend "--hierarchical-levels" parameter
- General: Improve Dolby Vision cropping
- UI: Add a filter bar to the Jobs window ([#1761](/../../issues/1761))
- Update tools
    - eac3to v3.64
```

Prefix is the encoder/tool name, or `General:` / `UI:` / `AviSynth:` / `VapourSynth:`.
Verbs in use: `Add`, `Alter`, `Extend`, `Fix`, `Improve`, `Update`, `Remove`.

## Claude Code hooks

Four hooks in `.claude/settings.json`, all PowerShell under `.claude/hooks/`. Each has an env-var
escape hatch, because a guard you cannot turn off gets deleted instead.

| Hook | Fires on | Does | Off switch |
|---|---|---|---|
| `compile-gate.ps1` | `Stop` | Builds if sources are dirty; blocks the turn on compile errors | `STAXRIP_SKIP_COMPILE_GATE=1` |
| `ascii-guard.ps1` | `PostToolUse` on `Edit`/`Write`/`Bash`/`PowerShell` | Blocks on any codepoint > 127 in a guarded file | -- |
| `designer-guard.ps1` | `PreToolUse` on `Edit`/`Write`/`Bash`/`PowerShell` | Asks before hand-editing `*.Designer.vb` / `*.resx` | `STAXRIP_ALLOW_DESIGNER_EDIT=1` |
| `session-pull.ps1` | `SessionStart` (`startup` only) | Fast-forwards the branch before work starts; silent unless it moved HEAD or failed | `STAXRIP_SKIP_SESSION_PULL=1` |

**`compile-gate` can add minutes to the end of a turn.** There is no test suite, so it is the only
automated gate. Notes:

- It builds `StaxRip.vbproj` when only managed sources are dirty, and `StaxRip.sln` (which pulls in
  the native `FrameServer`) when `.cpp`/`.h`/`.vcxproj`/`.sln` are. See the `MSBuild` note under
  [Build](#build) for why that distinction matters.
- It finds MSBuild via `STAXRIP_MSBUILD`, else vswhere. **Set `STAXRIP_MSBUILD` if it cannot find
  one** -- otherwise the gate skips and nothing checks that your change compiles.
- Every skip is announced once per session via `systemMessage`: no MSBuild, no NuGet restore (only
  when managed sources are in scope -- FrameServer does not use NuGet), no C++ toolchain, no
  VapourSynth SDK, `git status` failed, and the partial case where the VB project compiles but
  FrameServer could not be checked. Only "nothing dirty" is silent. If you never see a skip notice
  and never see a build, it ran.
- A failure that is clearly environmental (`MSB8020`, `MSB3644`, `MSB4019`, ...) is reported as a
  skip, not used to block the turn -- those are not fixable from the working tree. The missing
  VapourSynth SDK is checked *before* building rather than classified afterwards, because its
  `C1083` is indistinguishable from a genuine bad `#include`.
- The `Stop` timeout is 900s, which is pure headroom rather than a measured need: on a 2026 desktop
  a cold `StaxRip.vbproj` build measures ~4s and the restore ~4s, and incremental gate runs land at
  2-3s. Budget for worse on a slow disk or with real-time antivirus scanning `Source\obj`, but the
  gate is not normally something you wait on.

**Both guards also watch `Bash`/`PowerShell`**, not just `Edit`/`Write`. A `Set-Content`, `sed -i` or
heredoc writes files without going through the file tools, and would otherwise slip past. `ascii-guard`
handles this by sweeping every dirty guarded file; `designer-guard` by scanning the command text for
guarded paths. `ascii-guard` reads its extension list out of `Source/Build.ps1`'s
`$includeProjectFiles` rather than duplicating it, so the two cannot drift.

**`session-pull` is deliberately timid**, because a hook that rewrites your tree at startup is worse
than a stale tree. It only ever fast-forwards: it skips, silently and without touching anything, when
the branch has no upstream or when tracked files are modified or staged. Untracked files do not count
as dirty -- they cannot block a fast-forward, and treating them as blocking would mean skipping every
session over a stray scratch file. Silence means "already up to date"; you hear from it only when it
moved `HEAD` or when `--ff-only` refused (usually a diverged branch, needing a real merge or rebase).

## Conventions

- 4-space indent, no tabs. Members of a class are alphabetized loosely, not strictly.
- `Option Strict On` means no implicit narrowing: `CInt(...)`, `CDbl(...)` explicitly.
- Prefer the existing `Extensions.vb` helpers (`.ToInvariantString`, `.NothingOrEmpty`,
  `.EqualsAny`, `.Escape`, `.TrimEx`) over hand-rolled equivalents.
- Do not hand-edit `*.Designer.vb` (17 files) or `*.resx` (51 files, all carrying base64-serialized
  payloads) unless you know the WinForms designer will not round-trip over your change. The
  `designer-guard` hook prompts before these (see [Claude Code hooks](#claude-code-hooks)).
  `Source/Forms/MainForm.vb` is the exception -- it has no designer file at all, and its ~880-line
  hand-written `InitializeComponent()` is edited directly.
- Commit messages are terse and imperative: `Update x265`, `Tool Updates`, `Fix x265 new help output`.
  Release commits are just the version: `v2.52.5`.
