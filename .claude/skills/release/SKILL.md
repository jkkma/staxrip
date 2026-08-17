---
name: release
description: Cut a StaxRip release - bump both assembly version attributes, promote the pending-changes block into a dated section in CHANGELOG.md (and CHANGELOG-SUPPORTER.md when the supporter stream also moved), and commit as vX.Y.Z. User-invoked only, because it commits.
disable-model-invocation: true
---

# Cut a release

Reproduces the exact ritual behind every `vX.Y.Z` commit in this repo: `AssemblyInfo.vb`,
`CHANGELOG.md`, and `CHANGELOG-SUPPORTER.md` only when the supporter stream also moved. Nothing else
changes in a release commit -- no tags (this repo uses none), no build artifacts, no version strings
anywhere but `AssemblyInfo.vb`.

## Two independent version streams

This trips people up. The public build and the supporter build have **different version numbers that
do not track each other**, and they do **not** both advance on every release commit:

| File | Stream | Most recent at time of writing |
|---|---|---|
| `CHANGELOG.md` | public | `v2.52.5` (2026-08-08) |
| `CHANGELOG-SUPPORTER.md` | supporter | `v2.53.13` (2026-06-06) |

`Source/My Project/AssemblyInfo.vb` and the commit message both carry the **public** version.

`CHANGELOG.md` gets exactly one new section per release commit. `CHANGELOG-SUPPORTER.md` gets
**zero, one, or several**, because supporter builds ship on their own cadence and their sections are
written up retroactively, in batches, whenever a release commit happens to be made:

| Release commit | Sections added to `CHANGELOG.md` | Sections added to `CHANGELOG-SUPPORTER.md` |
|---|---|---|
| `v2.52.5` | `v2.52.5 (2026-08-08)` | `v2.53.13 (2026-06-06)` |
| `v2.52.4` | `v2.52.4 (2026-06-06)` | `v2.53.12`, `v2.53.11`, `v2.53.10`, `v2.53.9` |
| `v2.52.3` | `v2.52.3 (2026-04-07)` | *none* |
| `v2.52.2` | `v2.52.2 (2026-04-06)` | `v2.53.9 (not published yet)`, `v2.53.8`, `v2.53.7`, `v2.53.6` |
| `v2.52.1` | `v2.52.1 (2026-03-10)` | *none* |

So: do not derive one stream's number from the other, and do not assume the supporter stream moves
at all. Read the top-most version out of each file, increment only what actually shipped, and **ask
the user which supporter versions (if any) this commit should write** rather than inventing one.

## Steps

### 1. Confirm the working tree is clean and the branch is right

```powershell
git status --porcelain
git branch --show-current
```

Stop and ask if there is uncommitted work; a release commit should contain only the two or three
files listed above.

### 2. Read the current versions

- Public: first `^v\d+\.\d+\.\d+ \(` heading in `CHANGELOG.md`.
- Supporter: first `^v\d+\.\d+\.\d+ \(` heading in `CHANGELOG-SUPPORTER.md`.
- Assembly: `AssemblyVersion` in `Source/My Project/AssemblyInfo.vb` -- it should already equal the
  current public version. If it does not, say so before proceeding rather than silently papering
  over it.

Ask the user for the new public version if they have not given one; default to a patch bump.

Then ask separately about the supporter stream, because it is not derivable:

- Which supporter version(s), if any, does this commit write? Often none.
- What date did each of them actually ship? Not today's date -- see step 4.

If the user does not know the date, write `vX.Y.Z (not published yet)` as a real, uncommented
heading. That is established practice: `v2.52.2` added `v2.53.9 (not published yet)` and the
`v2.52.4` commit later rewrote it to `v2.53.9 (2026-03-01)`.

### 3. Bump `Source/My Project/AssemblyInfo.vb`

**Both** attributes, to the new public version:

```vb
<Assembly: AssemblyVersion("2.52.6")>
<Assembly: AssemblyFileVersion("2.52.6")>
```

Missing the second one produces a build whose file version disagrees with what `Release.ps1` uses to
name the output directory and `.7z`.

### 4. Promote the pending block

Do this for `CHANGELOG.md` always, and for `CHANGELOG-SUPPORTER.md` only if step 2 established that
this commit writes one or more supporter sections.

Each file keeps this commented template pinned at the very top. It is a permanent scratchpad -- it
stays commented and stays in place. Its accumulated bullets are what you are promoting.

```
<!--
v2.5x.0 (not published yet)
====================

- ...
- Update tools
    - ...
- Update AviSynth+ plugins
    - ...
- Update Dual plugins
    - ...
- Update VapourSynth plugins
    - ...
-->
```

Insert the new section immediately after the closing `-->`, above the previous newest version:

```
-->
<blank>
<blank>
v2.52.6 (2026-08-17)
====================
<blank>
- General: ...
- x265: Add "--foo" parameter
- Update tools
    - eac3to v3.64
<blank>
<blank>
v2.52.5 (2026-08-08)
```

Exact formatting, all of which the existing file follows consistently:

- Heading is `vX.Y.Z (YYYY-MM-DD)`, or literally `vX.Y.Z (not published yet)` when the date is not
  known yet. The date is the date **that build shipped**, which is today's date only for the public
  section:
  - `CHANGELOG.md` -> today's date.
  - `CHANGELOG-SUPPORTER.md` -> the supporter build's own ship date, which is in the **past**.
    Use the date the user gives you. As a sanity check rather than a rule: supporter releases have
    lately shipped alongside public ones and their sections are written one release commit behind,
    so the previous public heading's date is usually the right candidate -- `v2.52.5` wrote
    `v2.53.13 (2026-06-06)`, which is `v2.52.4`'s date. Confirm it; never default to today.
- Underline is **exactly 20 `=` characters**, regardless of heading length.
- **Two** blank lines separate sections.
- Top-level bullets `- `, nested bullets indented **4 spaces**.
- Sub-lists under `Update tools` / `Update AviSynth+ plugins` / `Update Dual plugins` /
  `Update VapourSynth plugins` list `<name> <version>`, e.g. `    - eac3to v3.64`.
- Issue references inline as `([#1761](/../../issues/1761))`.

Then reset the template block's bullets back to `- ...` placeholders for the next cycle -- but only
in the file you actually promoted from. If this commit writes no supporter section,
`CHANGELOG-SUPPORTER.md` is left untouched, scratchpad included.

When a commit writes **several** supporter sections at once, they go in newest-first, all above the
previous newest version, each with its own 20-`=` underline and two blank lines between them. Also
check whether an existing `(not published yet)` supporter heading now has a date -- rewriting that
heading in place is part of the same ritual.

### 5. Source the content

If the pending block is empty or thin, build the entry from the commits since the last release
rather than inventing it:

```powershell
git log --oneline "v-last-release-sha..HEAD"
```

Translate each commit into the house format described in `CLAUDE.md` -- prefix with the tool or area
(`x265:`, `SvtAv1EncApp:`, `General:`, `UI:`, `AviSynth:`, `VapourSynth:`), verb from
`Add` / `Alter` / `Extend` / `Fix` / `Improve` / `Update` / `Remove`.

The two changelogs are not copies of each other: supporter builds carry entries for features not in
the public build. Only put an entry in `CHANGELOG.md` if it shipped publicly. When unsure which
stream a change belongs to, ask.

### 6. Commit

```powershell
git add "CHANGELOG.md" "Source/My Project/AssemblyInfo.vb"
git add "CHANGELOG-SUPPORTER.md"   # only if step 4 changed it
git commit -m "v2.52.6"
```

The message is the bare public version, nothing else. Do not tag; do not push unless asked.

A two-file release commit is normal -- `v2.52.3` and `v2.52.1` both are.

### 7. Building the actual artifact

Out of scope for this skill, and not part of the release commit. `Source/Release.ps1` does it, but
needs `$msBuildDirectory` and `$7zDirectory` filled in and writes to a hard-coded
`A:\StaxRip-Releases`. Mention this to the user rather than editing the script.
