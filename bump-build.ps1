#Requires -Version 5.1
<#
.SYNOPSIS
  Raise the iOS build number by one, commit and push it, then run deploy.ps1.

.DESCRIPTION
  For a new IPA with no app changes (for example to test the deploy / USB install path end to end):
  the USB install skips a phone that already has the IPA's build, so a test needs a new number.

    0. First: if the newest built IPA (successful ios-build workflow_dispatch run) has a higher build
       than the Loop Segments on the USB iPhone - e.g. a deploy that timed out - it runs
       .\deploy.ps1 -UseLatest to install that one and stops; no bump, no new build. -ForceBump skips
       this check. No USB phone: the check is skipped and it bumps.
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

.PARAMETER ForceBump
  Always make a new build, even when a built IPA newer than the phone's build is ready.

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
    [switch] $ForceBump,
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

function ConvertTo-DeploySplat([string[]] $Tokens) {
    # '-SkipICloud', '-RunId 123' -> @{ SkipICloud = $true; RunId = '123' }. A splatted *array* would
    # hand '-Name' to deploy.ps1 as a plain value (it landed in -RunId), so named args need a hashtable.
    $h = @{}
    $list = @($Tokens | ForEach-Object { "$_" -split '\s+' } | Where-Object { $_ })
    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = $list[$i]
        if ($t -notlike '-*') { throw "DeployArgs: expected -Name, got '$t'" }
        $name = $t.TrimStart('-')
        if ($i + 1 -lt $list.Count -and $list[$i + 1] -notlike '-*') { $h[$name] = $list[$i + 1]; $i++ }
        else { $h[$name] = $true }
    }
    return $h
}

function Get-LatestBuiltIpa {
    # Newest successful ios-build workflow_dispatch run (an IPA) and the build number in its commit.
    $json = & gh run list --workflow=ios-build.yml --event=workflow_dispatch --status=success --limit 1 --json databaseId,headSha 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    $run = @($json | ConvertFrom-Json) | Select-Object -First 1
    if (-not $run) { return $null }
    $ymlAt = (& git -C $ProjectRoot show "$($run.headSha):ios/project.yml" 2>$null) -join "`n"
    if ($ymlAt -notmatch 'CURRENT_PROJECT_VERSION:\s*"(\d+)"') { return $null }
    return [pscustomobject]@{ RunId = [string]$run.databaseId; Build = [int]$Matches[1] }
}

function Get-PhoneBuild {
    # Loop Segments build on the USB iPhone, or $null (no phone / no Python / not installed).
    $py = Get-Command py -ErrorAction SilentlyContinue
    $info = Join-Path $ProjectRoot 'windows\usb\LoopSegments-UsbInfo.py'
    if (-not $py -or -not (Test-Path -LiteralPath $info)) { return $null }
    $out = (& $py.Source -3.12 $info installed-build 2>$null) -join "`n"
    if ($out -match '(?m)^BUILD\t(\d+)') { return [int]$Matches[1] }
    return $null
}

# 0. A built IPA the phone does not have yet (e.g. a deploy that timed out): install that instead of
# making another build. -ForceBump always bumps.
if (-not $ForceBump) {
    $built = Get-LatestBuiltIpa
    $phone = if ($built) { Get-PhoneBuild } else { $null }
    if ($built -and $null -ne $phone -and $built.Build -gt $phone) {
        Write-Host ("Build {0} is already built (run {1}) but the phone has {2}: installing it with deploy.ps1 -UseLatest instead of a new build (-ForceBump to bump anyway)." -f $built.Build, $built.RunId, $phone) -ForegroundColor Cyan
        if ($DryRun) { Write-Host 'Dry run: nothing changed.' -ForegroundColor Yellow; Wait-EnterToClose; exit 0 }
        $deploy = Join-Path $ProjectRoot 'deploy.ps1'
        $passArgs = ConvertTo-DeploySplat $DeployArgs
        $passArgs['UseLatest'] = $true
        if ($NoWaitEnter) { $passArgs['NoWaitEnter'] = $true }
        & $deploy @passArgs
        exit $LASTEXITCODE
    }
    if ($built -and $null -ne $phone) {
        Write-Host ("Newest built IPA is build {0}; the phone has {1}: making a new build." -f $built.Build, $phone)
    }
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
$passArgs = ConvertTo-DeploySplat $DeployArgs
if ($NoWaitEnter) { $passArgs['NoWaitEnter'] = $true }
& $deploy @passArgs
exit $LASTEXITCODE
