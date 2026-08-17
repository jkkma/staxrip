# compile-gate.ps1 -- Stop hook.
#
# StaxRip has no test suite, so with Option Strict On the VB compiler is the only automated
# gate there is. This runs an incremental Debug build when sources are dirty, and blocks the
# turn from ending if the code no longer compiles.
#
# Every skip is ANNOUNCED through systemMessage, once per session per reason. A gate that
# exits 0 silently is invisible outside transcript mode, so a permanently-skipping gate reads
# exactly like a passing one -- which is worse than having no gate at all. Announcing once
# rather than on every Stop keeps it visible without training the user to ignore it.
#
# Escape hatch: STAXRIP_SKIP_COMPILE_GATE=1 disables it entirely.
#
# MSBuild resolution order:
#   1. $env:STAXRIP_MSBUILD
#   2. vswhere (Visual Studio / Build Tools), preferring the 64-bit host
#
# The .NET Framework MSBuild in %WINDIR%\Microsoft.NET\Framework64 is deliberately NOT used:
# its pre-Roslyn vbc rejects VB14 syntax this codebase relies on (null-conditional `?.`,
# string interpolation), so it would report failures that are not real.
#
# Build scope tracks what is dirty AND what the toolchain can actually build. StaxRip.vbproj
# has no ProjectReference to FrameServer.vcxproj, so the two are independently buildable:
#   - only .vb/.vbproj/.resx dirty  -> build StaxRip.vbproj (never needs the C++ toolchain)
#   - native or .sln dirty          -> build StaxRip.sln, which includes FrameServer
# Two separate things can make FrameServer unbuildable, and neither is fixable from the working
# tree, so both are detected up front and reported as skips rather than used to block the turn:
#   1. A Build Tools install with only the .NET workload satisfies Microsoft.Component.MSBuild
#      but fails the solution with MSB4019/MSB8020 (the v143 C++ targets are missing).
#   2. Even WITH the C++ tools, FrameServer.vcxproj includes the VapourSynth SDK from
#      Source\bin\Apps\FrameServer\VapourSynth\sdk\include\vapoursynth. Source\bin is gitignored
#      and those headers ship with the bundled VapourSynth app, so a clean clone dies on
#      C1083: 'VSScript4.h'. The repo vendors avisynth.h and avs\*.h, but not the VapourSynth SDK.

$ErrorActionPreference = 'Stop'

if ($env:STAXRIP_SKIP_COMPILE_GATE -eq '1') { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = if ([string]::IsNullOrWhiteSpace($raw)) { $null } else { $raw | ConvertFrom-Json }
} catch {
    exit 0
}

# Never re-enter: a Stop hook that blocks fires again after Claude responds.
if ($payload -and $payload.stop_hook_active) { exit 0 }

$sessionId = 'nosession'
if ($payload -and $payload.session_id) {
    $sessionId = ($payload.session_id -replace '[^A-Za-z0-9_-]', '_')
}

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }

$solution = Join-Path $projectDir 'Source\StaxRip.sln'
$vbProject = Join-Path $projectDir 'Source\StaxRip.vbproj'
$vcxProject = Join-Path $projectDir 'Source\FrameServer\FrameServer.vcxproj'
if (-not (Test-Path -LiteralPath $solution -PathType Leaf)) { exit 0 }

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

function Exit-Skip {
    param([string] $Key, [string] $Message)

    $alreadyAnnounced = $false
    try {
        $markerDir = Join-Path ([IO.Path]::GetTempPath()) 'staxrip-compile-gate'
        [void][IO.Directory]::CreateDirectory($markerDir)
        $marker = Join-Path $markerDir "$script:sessionId.$Key.flag"
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $alreadyAnnounced = $true
        } else {
            [IO.File]::WriteAllText($marker, '')
        }
    } catch {
        # If the marker cannot be written, repeat the message rather than lose it.
    }

    if (-not $alreadyAnnounced) {
        Write-Output (@{
            systemMessage = "compile-gate skipped: $Message"
        } | ConvertTo-Json -Depth 3 -Compress)
    }

    exit 0
}

function Resolve-MSBuild {
    if ($env:STAXRIP_MSBUILD -and (Test-Path -LiteralPath $env:STAXRIP_MSBUILD -PathType Leaf)) {
        return $env:STAXRIP_MSBUILD
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }

    # The glob must be MSBuild\**\MSBuild.exe, NOT MSBuild\**\Bin\MSBuild.exe. The 64-bit host
    # lives at MSBuild\Current\Bin\amd64\MSBuild.exe, whose parent directory is amd64, not Bin --
    # so the narrower glob silently returns the 32-bit host and nothing else. Verified against a
    # real 17.14 Build Tools install: narrow glob -> 1 result (x86), broad glob -> both.
    $found = @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
                          -find 'MSBuild\**\MSBuild.exe' 2>$null |
               Where-Object { $_ -match '(?i)\\Bin\\(amd64\\)?MSBuild\.exe$' })
    if ($found.Count -eq 0) { return $null }

    # The 32-bit host is capped near 3-4 GB and is a known OOM source on the larger encoder
    # sources here (NVEnc 179 KB, VCEEnc 162 KB, QSVEnc 152 KB). Order is not contractual, so
    # pick the 64-bit host explicitly rather than relying on it coming out first.
    $amd64 = $found | Where-Object { $_ -match '(?i)\\amd64\\MSBuild\.exe$' } | Select-Object -First 1
    if ($amd64) { return $amd64 }

    return ($found | Select-Object -First 1)
}

function Test-NativeToolchain {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    # Undeterminable (no vswhere, e.g. STAXRIP_MSBUILD set by hand) counts as available:
    # attempt the build, and let the MSB8020 classifier below sort out a real absence.
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $true }

    $found = @(& $vswhere -latest -products * `
                          -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                          -property installationPath 2>$null)
    return ($found.Count -gt 0)
}

function Test-NativeHeaders {
    # FrameServer.vcxproj pulls the VapourSynth SDK out of Source\bin\Apps\..., which .gitignore
    # excludes -- those headers ship with the bundled VapourSynth app, not with the repo. So a
    # clean clone CANNOT compile FrameServer no matter what toolchain is installed: it dies with
    # C1083 on VSScript4.h. That is an environment problem wearing a compiler error's clothes, and
    # C1083 is indistinguishable from a genuine bad #include, so detect the cause up front rather
    # than trying to classify the symptom afterwards.
    param([string] $VcxProj)

    if (-not (Test-Path -LiteralPath $VcxProj -PathType Leaf)) { return $true }

    try { $text = Get-Content -LiteralPath $VcxProj -Raw } catch { return $true }

    $projDir = Split-Path -Parent $VcxProj

    foreach ($match in [regex]::Matches($text, '(?i)<IncludePath>(?<v>[^<]*)</IncludePath>')) {
        foreach ($entry in ($match.Groups['v'].Value -split ';')) {
            $e = $entry.Trim()
            if (-not $e) { continue }
            if ($e -match '^\$\(') { continue }   # $(IncludePath) and friends
            try {
                $full = [IO.Path]::GetFullPath((Join-Path $projDir $e))
            } catch { continue }
            if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
            # Existence is not enough: a half-staged SDK leaves the directory there and still
            # dies on C1083. Require it to actually hold headers.
            $headers = @(Get-ChildItem -LiteralPath $full -Filter '*.h' -File -ErrorAction SilentlyContinue)
            if ($headers.Count -eq 0) { return $false }
        }
    }

    return $true
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Is there anything worth compiling?

$managedPattern  = '(?i)^Source/(?!Apps/).*\.(vb|vbproj|resx|config)$'
$nativePattern   = '(?i)^Source/(?!Apps/).*\.(c|cc|cpp|cxx|h|hh|hpp|rc|vcxproj|filters|props|targets)$'
$solutionPattern = '(?i)^Source/StaxRip\.sln$'

$dirtyManaged = 0
$dirtyNative = 0
$dirtySolution = 0

try {
    $status = & git -C $projectDir status --porcelain --untracked-files=all 2>$null
} catch {
    Exit-Skip -Key 'git' -Message 'git status failed, so dirty sources could not be determined.'
}

foreach ($line in $status) {
    if ($line.Length -lt 4) { continue }
    $path = $line.Substring(3)
    if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
    $path = $path.Trim('"')

    if ($path -match $solutionPattern) { $dirtySolution++ }
    elseif ($path -match $managedPattern) { $dirtyManaged++ }
    elseif ($path -match $nativePattern) { $dirtyNative++ }
}

# Nothing to build is the one skip that stays silent -- it is the normal, correct outcome.
if (($dirtyManaged + $dirtyNative + $dirtySolution) -eq 0) { exit 0 }

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Toolchain

$msBuild = Resolve-MSBuild

if (-not $msBuild) {
    Exit-Skip -Key 'nomsbuild' -Message (
        'no MSBuild.exe found, so nothing verified that this compiles. ' +
        'Install VS Build Tools (.NET desktop workload), or set STAXRIP_MSBUILD to an MSBuild.exe path.')
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Build scope

$needsNative = ($dirtyNative -gt 0) -or ($dirtySolution -gt 0)
$needsManaged = ($dirtyManaged -gt 0) -or ($dirtySolution -gt 0)
$nativeNote = ''
$nativeBlocker = $null

if ($needsNative) {
    if (-not (Test-NativeToolchain)) {
        $nativeBlocker = 'the C++ build tools (MSVC v143 x64/x86) are not installed'
    } elseif (-not (Test-NativeHeaders -VcxProj $vcxProject)) {
        $nativeBlocker = 'the VapourSynth SDK headers FrameServer.vcxproj includes from ' +
                         'Source\bin\Apps\ are not staged -- they ship with the bundled ' +
                         'VapourSynth app, and Source\bin is gitignored'
    }
}

if ($nativeBlocker) {
    if (-not $needsManaged) {
        Exit-Skip -Key 'nonative' -Message (
            "$nativeBlocker, and only native FrameServer sources changed, so nothing was compiled.")
    }
    $needsNative = $false
    $nativeNote = ' (FrameServer skipped)'
}

# Only the managed half consumes packages.config, so check this AFTER the scope is settled --
# otherwise a native-only turn is told "NuGet is not restored", which is true but irrelevant to
# FrameServer and points at the wrong fix.
if ($needsManaged -and
    -not (Test-Path -LiteralPath (Join-Path $projectDir 'Source\packages') -PathType Container)) {
    Exit-Skip -Key 'norestore' -Message (
        'NuGet packages are not restored, so nothing verified that this compiles ' +
        '(a build would be pure BC30002 noise). Restore with: ' +
        'MSBuild.exe Source\StaxRip.sln -t:Restore -p:RestorePackagesConfig=true')
}

if ($needsNative) {
    $target = $solution
    $scope = 'StaxRip.sln'
} else {
    $target = $vbProject
    $scope = 'StaxRip.vbproj'
    if (-not (Test-Path -LiteralPath $vbProject -PathType Leaf)) {
        $target = $solution
        $scope = 'StaxRip.sln'
    }
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#   Build

$output = & $msBuild $target -t:Build -p:Configuration=Debug -p:Platform=x64 -nologo -v:minimal -m 2>&1
$buildExitCode = $LASTEXITCODE

if ($buildExitCode -eq 0) {
    # A pass on a REDUCED scope is still a partial skip. Say so, or "no output from the gate"
    # reads as "FrameServer compiles" when nothing ever tried to compile it.
    if ($nativeNote) {
        Exit-Skip -Key 'nonative-partial' -Message (
            "$nativeBlocker. StaxRip.vbproj compiles, but the native FrameServer changes in " +
            'this turn were NOT verified.')
    }
    exit 0
}

# Environment failures, not code failures. Blocking the turn on these strands Claude on
# something it cannot fix from the working tree.
$toolchainFailure = $output | Where-Object {
    $_ -match '(?i)\b(MSB8020|MSB8036|MSB8040|MSB3644|MSB4019|MSB4236)\b'
} | Select-Object -First 1

if ($toolchainFailure) {
    Exit-Skip -Key 'toolchain' -Message (
        "the build failed for a toolchain reason rather than a code one, so nothing was verified: " +
        "$($toolchainFailure.ToString().Trim())")
}

$errors = @($output | Where-Object { $_ -match '(?i): (error|fatal error) ' } | Select-Object -First 25)
if ($errors.Count -eq 0) {
    $errors = @($output | Select-Object -Last 25)
}

$report = New-Object Text.StringBuilder
[void]$report.AppendLine("$scope no longer compiles (MSBuild exit $buildExitCode)$nativeNote.")
[void]$report.AppendLine('There is no test suite here, so a clean build is the bar. Fix these before finishing:')
[void]$report.AppendLine('')
foreach ($line in $errors) { [void]$report.AppendLine("  $line") }

[Console]::Error.Write($report.ToString())
exit 2
