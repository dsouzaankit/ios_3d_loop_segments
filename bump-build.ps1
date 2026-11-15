#Requires -Version 5.1
<#
.SYNOPSIS
  Raise the iOS build number by one, commit and push it, then run deploy.ps1.

.DESCRIPTION
  For a new IPA with no app changes (for example to test the deploy / USB install path end to end):
  the USB install skips a phone that already has the IPA's build, so a test needs a new number.

    1. ios\project.yml: CURRENT_PROJECT_VERSION + 1.
    2. ios\README.md: a "**Build N (version):** <note>" line above the newest build note.
    3. git commit of only those two files, then git push (current branch).
    4. .\deploy.ps1 (trigger ios-build, prepare the USB phone, download, iCloud copy, USB install).

  Refuses to run when either file already has uncommitted changes, so nothing else is swept into
  the commit. Waits for Enter at the end on a direct run (-NoWaitEnter skips).

.PARAMETER Note
  The README build note text. Default: no app changes (deploy test).

.PARAMETER DryRun
  Show the new build number and note; change nothing.

.PARAMETER NoPush
  Commit only (deploy.ps1 then builds the remote branch without this commit, so -NoPush implies
  -NoDeploy).

.PARAMETER NoDeploy
  Stop after the push.

.PARAMETER DeployArgs
  Extra arguments for deploy.ps1, e.g. -DeployArgs '-SkipICloud'.

.EXAMPLE
  .\bump-build.ps1

.EXAMPLE
  .\bump-build.ps1 -DryRun

.EXAMPLE
  .\bump-build.ps1 -Note 'Rebuild after the Xcode update.' -NoDeploy
#>
param(
    [string] $Note = 'No app changes: a new build number to test the deploy and the USB install.',
    [switch] $DryRun,
    [switch] $NoPush,
    [switch] $NoDeploy,
    [string[]] $DeployArgs = @(),
    [switch] $NoWaitEnter
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectYml = Join-Path $ProjectRoot 'ios\project.yml'
$ReadmeMd = Join-Path $ProjectRoot 'ios\README.md'
# pCloud / no-ownership volume: git needs safe.directory (session env only, like deploy.ps1).
if ([string]::IsNullOrWhiteSpace($env:GIT_CONFIG_COUNT)) {
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'safe.directory'
    $env:GIT_CONFIG_VALUE_0 = ($ProjectRoot -replace '\\', '/')
}

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ''
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try { [void][Console]::ReadLine() } catch { Read-Host | Out-Null }
}

trap {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Wait-EnterToClose
    exit 1
}

function Invoke-Git {
    $out = & git -C $ProjectRoot @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git {0} failed:`n{1}" -f ($args -join ' '), ($out | Out-String)) }
    return $out
}

$utf8 = New-Object System.Text.UTF8Encoding $false
$yml = [IO.File]::ReadAllText($ProjectYml)
$readme = [IO.File]::ReadAllText($ReadmeMd)

if ($yml -notmatch 'CURRENT_PROJECT_VERSION:\s*"(\d+)"') { throw "No CURRENT_PROJECT_VERSION in $ProjectYml" }
$old = [int]$Matches[1]
$new = $old + 1
$version = if ($yml -match 'MARKETING_VERSION:\s*"([^"]+)"') { $Matches[1] } else { '?' }
$line = "**Build $new ($version):** $($Note.Trim())"

Write-Host "Build $old -> $new ($version)"
Write-Host "README note: $line"
if ($DryRun) {
    Write-Host 'Dry run: nothing changed.' -ForegroundColor Yellow
    Wait-EnterToClose
    exit 0
}

$dirty = Invoke-Git status --porcelain -- 'ios/project.yml' 'ios/README.md'
if ($dirty) { throw "ios\project.yml or ios\README.md has uncommitted changes; commit or discard them first:`n$($dirty | Out-String)" }

# 1-2. Bump and note (keep each file's line endings).
$yml = [regex]::Replace($yml, 'CURRENT_PROJECT_VERSION:\s*"\d+"', "CURRENT_PROJECT_VERSION: `"$new`"", 1)
$nl = if ($readme.Contains("`r`n")) { "`r`n" } else { "`n" }
$m = [regex]::Match($readme, '(?m)^\*\*Build \d+ \(')
if (-not $m.Success) { throw "No '**Build N (' note in $ReadmeMd to insert above" }
$readme = $readme.Insert($m.Index, $line + $nl + $nl)
[IO.File]::WriteAllText($ProjectYml, $yml, $utf8)
[IO.File]::WriteAllText($ReadmeMd, $readme, $utf8)

# 3. Commit only these two files, then push.
[void](Invoke-Git add -- 'ios/project.yml' 'ios/README.md')
[void](Invoke-Git commit -m "Build ${new}: $($Note.Trim())" -- 'ios/project.yml' 'ios/README.md')
Write-Host "Committed build $new." -ForegroundColor Green
if ($NoPush) {
    Write-Host 'Not pushed (-NoPush), so not deploying either: ios-build builds the pushed branch.' -ForegroundColor Yellow
    Wait-EnterToClose
    exit 0
}
Invoke-Git push | Out-Host
Write-Host "Pushed build $new." -ForegroundColor Green
if ($NoDeploy) { Wait-EnterToClose; exit 0 }

# 4. Deploy (it waits for Enter itself unless -NoWaitEnter).
$deploy = Join-Path $ProjectRoot 'deploy.ps1'
$passArgs = @($DeployArgs)
if ($NoWaitEnter) { $passArgs += '-NoWaitEnter' }
& $deploy @passArgs
exit $LASTEXITCODE
