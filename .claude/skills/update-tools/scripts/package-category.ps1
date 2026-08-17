# package-category.ps1
#
# Answers the one question that is easy to get wrong when writing an "Update tools" changelog
# entry: which sub-list does this package belong under?
#
# The four sub-lists in CHANGELOG.md map onto Package.vb entries like this:
#
#   Update tools                  -> Package, or PluginPackage with neither filter-name array
#   Update AviSynth+ plugins      -> PluginPackage with .AvsFilterNames only
#   Update VapourSynth plugins    -> PluginPackage with .VsFilterNames only
#   Update Dual plugins           -> PluginPackage with BOTH
#
# AviSynth and VapourSynth builds of the same plugin are SEPARATE entries sharing one .Name,
# told apart by .Filename. So a bare name can legitimately resolve to two different sub-lists;
# this script prints every match rather than guessing.
#
# Entry bodies are extracted by BALANCING BRACES from the `With {`, not by a non-greedy match
# up to the first `})`. An initializer containing a nested `})` -- an inline call in .Locations,
# a lambda -- would truncate under the regex approach and silently fall through to 'Tools',
# which is precisely the mis-filing this script exists to prevent. Unbalanced entries are
# reported as errors instead of being quietly mis-categorized.
#
# Usage:
#   .\package-category.ps1                 # list everything, grouped
#   .\package-category.ps1 DotKill         # look up one name (substring, case-insensitive)
#   .\package-category.ps1 -Category Dual  # list one category

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Name,

    [ValidateSet('Tools', 'AviSynth', 'VapourSynth', 'Dual')]
    [string] $Category,

    [string] $PackageFile
)

$ErrorActionPreference = 'Stop'

if (-not $PackageFile) {
    $root = $env:CLAUDE_PROJECT_DIR
    if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) }
    $PackageFile = Join-Path $root 'Source\General\Package.vb'
}

if (-not (Test-Path -LiteralPath $PackageFile)) {
    throw "Package.vb not found at '$PackageFile'. Pass -PackageFile explicitly."
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

function Get-BalancedBody {
    # $Start is the index of the opening '{'. Returns the text between the braces, or $null
    # if the initializer never closes. Skips over VB string literals ("" is an escaped quote)
    # and end-of-line comments so a brace inside a .Description cannot end the entry early.
    param([string] $Text, [int] $Start)

    $depth = 0
    $inString = $false
    $i = $Start

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]

        if ($inString) {
            if ($ch -eq '"') {
                if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++ }
                else { $inString = $false }
            }
        }
        elseif ($ch -eq '"') { $inString = $true }
        elseif ($ch -eq "'") {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
        }
        elseif ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($Start + 1, $i - $Start - 1) }
        }

        $i++
    }

    return $null
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

$text = [IO.File]::ReadAllText($PackageFile)
$entryRegex = [regex] 'New\s+(?<kind>Plugin)?Package\s+With\s*\{'

$unbalanced = [Collections.Generic.List[int]]::new()
$entries = [Collections.Generic.List[object]]::new()

# Matches arrive in order, so track the line number with a single forward scan.
$lineNumber = 1
$scanned = 0

foreach ($match in $entryRegex.Matches($text)) {
    while ($scanned -lt $match.Index) {
        if ($text[$scanned] -eq "`n") { $lineNumber++ }
        $scanned++
    }

    $braceIndex = $match.Index + $match.Length - 1
    $body = Get-BalancedBody -Text $text -Start $braceIndex

    if ($null -eq $body) {
        $unbalanced.Add($lineNumber)
        continue
    }

    $packageName = if ($body -match '\.Name\s*=\s*"([^"]*)"') { $Matches[1] } else { '<unnamed>' }
    $filename = if ($body -match '\.Filename\s*=\s*"([^"]*)"') { $Matches[1] } else { '' }
    $downloadUrl = if ($body -match '\.DownloadURL\s*=\s*"([^"]*)"') { $Matches[1] } else { '' }
    $webUrl = if ($body -match '\.WebURL\s*=\s*"([^"]*)"') { $Matches[1] } else { '' }

    $hasAvs = $body -match '\.AvsFilterNames\s*='
    $hasVs = $body -match '\.VsFilterNames\s*='

    $resolved =
        if ($hasAvs -and $hasVs) { 'Dual' }
        elseif ($hasAvs) { 'AviSynth' }
        elseif ($hasVs) { 'VapourSynth' }
        else { 'Tools' }

    $entries.Add([pscustomobject]@{
        Name        = $packageName
        Kind        = if ($match.Groups['kind'].Success) { 'PluginPackage' } else { 'Package' }
        Category    = $resolved
        SubList     = switch ($resolved) {
            'Tools'       { 'Update tools' }
            'AviSynth'    { 'Update AviSynth+ plugins' }
            'VapourSynth' { 'Update VapourSynth plugins' }
            'Dual'        { 'Update Dual plugins' }
        }
        Filename    = $filename
        Line        = $lineNumber
        DownloadURL = if ($downloadUrl) { $downloadUrl } else { $webUrl }
    })
}

if ($unbalanced.Count -gt 0) {
    # Loud, not silent: an entry that could not be parsed is an entry with no category.
    Write-Error ("Unbalanced initializer in $PackageFile at line(s): " + ($unbalanced -join ', ') +
                 '. Those entries were skipped and are NOT categorized below.') -ErrorAction Continue
}

if ($entries.Count -eq 0) {
    throw "No Package/PluginPackage entries found in '$PackageFile'. The file format may have changed."
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

$results = @($entries)

if ($Name) {
    $results = @($results | Where-Object { $_.Name -like "*$Name*" })
    if ($results.Count -eq 0) {
        Write-Warning "No package matching '*$Name*' in $PackageFile"
        exit 1
    }
}

if ($Category) {
    $results = @($results | Where-Object { $_.Category -eq $Category })
}

if ($Name) {
    # Single lookup: show enough to write the changelog line and find the entry.
    $results | Sort-Object Name, Category |
        Format-Table Name, SubList, Filename, Line, DownloadURL -AutoSize -Wrap
} else {
    $results | Group-Object SubList | Sort-Object Name | ForEach-Object {
        ''
        "$($_.Name)  ($($_.Count))"
        '-' * 60
        ($_.Group | Sort-Object Name | Select-Object -ExpandProperty Name -Unique) -join ', '
    }
    ''
    if ($Category) {
        "Entries shown: $($results.Count) of $($entries.Count) total"
    } else {
        "Total entries: $($results.Count)"
    }
}
