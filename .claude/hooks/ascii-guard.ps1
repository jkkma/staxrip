# ascii-guard.ps1 -- PostToolUse hook.
#
# Source/Build.ps1 and Source/Release.ps1 throw on any codepoint > 127 in project files
# with certain extensions, which kills a release build long after the offending edit.
# This catches it at edit time instead.
#
# The extension list is READ OUT OF Source/Build.ps1 ($includeProjectFiles) rather than
# copied into this file, so the two cannot drift. Build.ps1 pulls in .vb and .md through
# that same list and then skips them explicitly, so this does too, along with \Apps\.
#
# Two modes, both wired up in .claude/settings.json:
#
#   (default)   Edit|Write        scan tool_input.file_path
#   -Sweep      Bash|PowerShell   scan every dirty guarded file, because `Set-Content`,
#                                 `sed -i` and heredocs write files without ever going
#                                 through Edit|Write and would otherwise bypass the guard
#
# Exit 2 feeds stderr back to Claude so it can fix the character. Fails CLOSED: a file that
# cannot be read (locked by Visual Studio, deleted mid-turn) is reported rather than passed,
# because a silent pass is exactly how a smart quote survives to break Release.ps1.

[CmdletBinding()]
param([switch] $Sweep)

$ErrorActionPreference = 'Stop'

# Only this many offenders are ever printed. A .resx mis-decoded as UTF-8 yields U+FFFD for a
# large fraction of its bytes, and these files carry base64 payloads running to hundreds of KB;
# collecting all of them adds no information and blows the hook timeout.
$MaxReported = 20

$FallbackExtensions = @('.config', '.cpp', '.h', '.ps1', '.rc', '.resx', '.sln', '.vbproj')

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

function Get-ProjectDir {
    if ($env:CLAUDE_PROJECT_DIR) { return $env:CLAUDE_PROJECT_DIR }
    # .claude/hooks -> .claude -> repo root
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-GuardedExtension {
    param([string] $ProjectDir)

    $buildScript = Join-Path $ProjectDir 'Source\Build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) { return $FallbackExtensions }

    try {
        $text = [IO.File]::ReadAllText($buildScript)
    } catch {
        return $FallbackExtensions
    }

    $assignment = [regex]::Match($text, '\$includeProjectFiles\s*=\s*@\(([^)]*)\)')
    if (-not $assignment.Success) { return $FallbackExtensions }

    $extensions = @(
        [regex]::Matches($assignment.Groups[1].Value, "'\*?(?<ext>\.[A-Za-z0-9]+)'") |
            ForEach-Object { $_.Groups['ext'].Value.ToLowerInvariant() } |
            Where-Object { $_ -notin @('.vb', '.md') }
    )

    if ($extensions.Count -eq 0) { return $FallbackExtensions }
    return $extensions
}

function Test-GuardedPath {
    param([string] $FullPath, [string[]] $Extensions)

    $ext = [IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    if ($Extensions -notcontains $ext) { return $false }
    # Build.ps1 walks $PSScriptRoot, i.e. Source\, and skips \Apps\.
    if ($FullPath -notmatch '(?i)\\Source\\') { return $false }
    if ($FullPath -match '(?i)\\Apps\\') { return $false }
    return $true
}

function Get-Offender {
    param([string] $FullPath, [int] $Limit)

    $offenders = [Collections.Generic.List[object]]::new()
    $lineNumber = 0

    foreach ($line in [IO.File]::ReadAllLines($FullPath)) {
        $lineNumber++
        foreach ($char in $line.ToCharArray()) {
            $codePoint = [int]$char
            if ($codePoint -gt 127) {
                $offenders.Add([pscustomobject]@{
                    Line      = $lineNumber
                    Char      = $char
                    CodePoint = $codePoint
                    Text      = $line.Trim()
                })
                if ($offenders.Count -ge $Limit) { return $offenders }
            }
        }
    }

    return $offenders
}

function Get-DisplayPath {
    param([string] $FullPath, [string] $ProjectDir)

    if (-not $ProjectDir) { return $FullPath }

    # Normalize before comparing. CLAUDE_PROJECT_DIR can arrive with forward slashes and/or a
    # trailing separator, in which case a raw StartsWith misses and the report shows a long
    # absolute path instead of the repo-relative one.
    try {
        $normFull = [IO.Path]::GetFullPath($FullPath)
        $normRoot = [IO.Path]::GetFullPath($ProjectDir).TrimEnd('\', '/')
    } catch {
        return $FullPath
    }

    if ($normFull.StartsWith($normRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $normFull.Substring($normRoot.Length + 1)
    }
    return $normFull
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   What to scan

$projectDir = Get-ProjectDir
$extensions = Get-GuardedExtension -ProjectDir $projectDir
$targets = [Collections.Generic.List[string]]::new()

# Drain stdin either way so the caller never blocks on an unread pipe.
try {
    $raw = [Console]::In.ReadToEnd()
} catch {
    $raw = $null
}

if ($Sweep) {
    try {
        $status = & git -C $projectDir status --porcelain --untracked-files=all 2>$null
    } catch {
        $status = $null
    }

    foreach ($line in $status) {
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3)
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = $path.Trim('"')
        $full = Join-Path $projectDir ($path -replace '/', '\')
        if (Test-Path -LiteralPath $full -PathType Leaf) { $targets.Add($full) }
    }
} else {
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    try {
        $payload = $raw | ConvertFrom-Json
    } catch {
        # Malformed payload is not the user's problem -- never block on it.
        exit 0
    }

    $filePath = $payload.tool_input.file_path
    if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { exit 0 }

    $targets.Add((Resolve-Path -LiteralPath $filePath).Path)
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Scan

$report = New-Object Text.StringBuilder
$violations = 0
$sawNonAscii = $false

foreach ($full in ($targets | Sort-Object -Unique)) {
    if (-not (Test-GuardedPath -FullPath $full -Extensions $extensions)) { continue }

    $rel = Get-DisplayPath -FullPath $full -ProjectDir $projectDir

    try {
        $offenders = Get-Offender -FullPath $full -Limit $MaxReported
    } catch {
        $violations++
        [void]$report.AppendLine("Could not read $rel to check the ASCII-only invariant:")
        [void]$report.AppendLine("  $($_.Exception.Message)")
        [void]$report.AppendLine('Close it in Visual Studio (or re-check it by hand) before finishing.')
        [void]$report.AppendLine('')
        continue
    }

    if ($offenders.Count -eq 0) { continue }

    $violations++
    $sawNonAscii = $true
    [void]$report.AppendLine("ASCII-only invariant violated in $rel")
    [void]$report.AppendLine('')

    foreach ($o in $offenders) {
        $hex = '{0:X4}' -f $o.CodePoint
        [void]$report.AppendLine("  line $($o.Line): '$($o.Char)' (U+$hex) in: $($o.Text)")
    }

    if ($offenders.Count -ge $MaxReported) {
        [void]$report.AppendLine("  ... stopped after $MaxReported; there may be more.")
    }

    [void]$report.AppendLine('')
}

if ($violations -eq 0) { exit 0 }

$suffix = New-Object Text.StringBuilder
[void]$suffix.AppendLine('Source/Build.ps1 and Source/Release.ps1 throw on any codepoint > 127 in')
[void]$suffix.AppendLine(($extensions -join '/') + ' files under Source\, so this breaks the release build.')
if ($sawNonAscii) {
    [void]$suffix.AppendLine('Replace with ASCII equivalents (straight quotes, "-" for dashes, plain spaces).')
}

[Console]::Error.Write($report.ToString() + $suffix.ToString())
exit 2
