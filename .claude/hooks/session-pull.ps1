# session-pull.ps1 -- SessionStart hook, "startup" matcher only.
#
# Brings master up to date before any work starts, so a session never begins by editing
# a stale tree. Deliberately conservative: --ff-only, so this either fast-forwards cleanly
# or does nothing. It will not merge, will not rebase, and will not create a commit.
#
# Skips SILENTLY when there is nothing safe to do:
#
#   - not a git work tree
#   - no upstream for the current branch (a local-only branch has nothing to pull)
#   - tracked files are modified or staged -- a dirty tree is uncommitted work, and
#     surprising it with a fast-forward at startup is not this hook's business
#
# Untracked files do NOT count as dirty. They cannot block a fast-forward except in the
# rare case where the incoming commit adds a file that already exists locally, and that
# case surfaces as a reported --ff-only failure rather than a silent skip every session.
#
# Reports through systemMessage when it actually did something (pulled N commits) or when
# the pull failed (branch diverged, no network, credentials needed). "Already up to date"
# is silent, matching compile-gate: silence means the no-op case.
#
# Escape hatch: STAXRIP_SKIP_SESSION_PULL=1 disables it entirely.

$ErrorActionPreference = 'Stop'

if ($env:STAXRIP_SKIP_SESSION_PULL -eq '1') { exit 0 }

# Never block on a credential prompt -- a hook has no terminal to answer one.
$env:GIT_TERMINAL_PROMPT = '0'

# Drain stdin even though nothing here needs it; leaving it unread can wedge the writer.
try { [void][Console]::In.ReadToEnd() } catch { }

$projectDir = $env:CLAUDE_PROJECT_DIR
if (-not $projectDir) { $projectDir = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

function Invoke-Git {
    param([string[]] $GitArgs)

    $output = & git -C $projectDir @GitArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text     = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    }
}

function Exit-Report {
    param([string] $Message)

    Write-Output (@{ systemMessage = "session-pull: $Message" } | ConvertTo-Json -Depth 3 -Compress)
    exit 0
}

#   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { exit 0 }

if ((Invoke-Git @('rev-parse', '--is-inside-work-tree')).ExitCode -ne 0) { exit 0 }

$upstream = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
if ($upstream.ExitCode -ne 0 -or -not $upstream.Text) { exit 0 }

$dirty = Invoke-Git @('status', '--porcelain', '--untracked-files=no')
if ($dirty.ExitCode -ne 0 -or $dirty.Text) { exit 0 }

$before = Invoke-Git @('rev-parse', 'HEAD')
if ($before.ExitCode -ne 0) { exit 0 }

$pull = Invoke-Git @('pull', '--ff-only')
if ($pull.ExitCode -ne 0) {
    # git prefixes advice with "hint:"; the actual failure is the fatal:/error: line.
    $lines = $pull.Text -split "`n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^hint:' }
    $detail = ($lines | Select-Object -Last 2) -join ' / '
    Exit-Report "git pull --ff-only failed against $($upstream.Text). $detail"
}

$after = Invoke-Git @('rev-parse', 'HEAD')
if ($after.ExitCode -ne 0 -or $after.Text -eq $before.Text) { exit 0 }

$count = Invoke-Git @('rev-list', '--count', "$($before.Text)..$($after.Text)")
$commits = if ($count.ExitCode -eq 0 -and $count.Text) { $count.Text } else { '?' }
$plural = if ($commits -eq '1') { 'commit' } else { 'commits' }
$short = $after.Text.Substring(0, [Math]::Min(8, $after.Text.Length))

Exit-Report "fast-forwarded $commits $plural from $($upstream.Text); HEAD is now $short."
