#Requires -Version 5.1
<#
.SYNOPSIS
  Loop Segments wrappers around env_setup AltServer helpers.

.DESCRIPTION
  Core locate/start lives in env_setup\altserver_refresh\lib\Get-AltServer.ps1
  (git submodule env_setup, with a sibling-folder fallback).
  This file keeps Loop Segments-specific warnings and USB-list heuristics.
  Dot-source from Launch-LoopSegmentsViaUsb.ps1, run_chromium.ps1, Setup, etc.
#>

$script:LoopSegmentsWindowsRoot = Split-Path -Parent $PSScriptRoot
$script:LoopSegmentsRepoRoot = Split-Path -Parent $script:LoopSegmentsWindowsRoot

function Get-LoopSegmentsEnvSetupRoot {
    $candidates = @(
        (Join-Path $script:LoopSegmentsRepoRoot 'env_setup')
        'P:\all_scripts\iOS apps\env_setup'
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }
    throw @'
Missing env_setup (AltServer helpers). Clone the submodule:
  git submodule update --init env_setup
Or keep a checkout at P:\all_scripts\iOS apps\env_setup
'@
}

function Get-LoopSegmentsAltserverRefreshDir {
    $root = Get-LoopSegmentsEnvSetupRoot
    foreach ($name in @('altserver_refresh', 'altserver_refresh_scripts', 'altserver_refresh_script')) {
        $dir = Join-Path $root $name
        if (Test-Path -LiteralPath $dir) { return $dir }
    }
    throw "Missing $(Join-Path $root 'altserver_refresh')"
}

$script:LoopSegmentsAltServerCore = Join-Path (Get-LoopSegmentsAltserverRefreshDir) 'lib\Get-AltServer.ps1'
if (-not (Test-Path -LiteralPath $script:LoopSegmentsAltServerCore)) {
    throw "Missing AltServer core: $script:LoopSegmentsAltServerCore"
}
. $script:LoopSegmentsAltServerCore

function Get-LoopSegmentsAltServerPath {
    Get-AltServerPath
}

function Test-LoopSegmentsAltServerRunning {
    Test-AltServerRunning
}

function Get-LoopSegmentsAppUnavailableResolution {
    return @"
When Loop Segments becomes unavailable (won't open / "Unable to Verify App" /
"Unable to Trust iPhone Developer: you@email" / USB launch blocked by signature):
  1. Install/start AltServer on this PC (https://altstore.io) - tray icon should be visible.
  2. Plug the iPhone in over USB, unlock it, Trust This Computer.
  3. Open AltStore on the phone -> My Apps -> Refresh All (or refresh Loop Segments).
  4. Trust the developer certificate on the phone (your Apple ID email under DEVELOPER APP):
       Settings -> General -> VPN & Device Management
       -> tap "iPhone Developer: <your Apple ID email>"
       -> Trust "<your Apple ID email>" -> Trust (confirm popup)
     If Loop Segments / that email is not listed yet: wait for AltStore "Complete",
     open (or fail-open) the app once, leave Settings and return - the DEVELOPER APP
     entry often appears only then; trust it and open the app again.
  5. Open Loop Segments once by hand, then re-run the companion / USB launch script.
Wi-Fi background refresh only works if AltServer is running and AltStore Background App Refresh
is on; on Windows 11, USB + Refresh All weekly is the reliable path.
See ios/BUILD-WITHOUT-MAC.md (Trust the developer on iPhone).
"@
}

function Get-LoopSegmentsAltServerSevenDayWarning {
    return @"
Without AltServer + AltStore refresh, a free / Personal Team sideload of Loop Segments
expires in about 7 days: the app icon may still show, but opens fail until you refresh.
Install AltServer: https://altstore.io
Optional: .\sideload\Register-AltServerAtLogon.ps1  (tray at logon)
"@
}

function Write-LoopSegmentsAltServerNotice {
    param(
        [switch] $AlwaysStatus,
        [switch] $IncludeResolution,
        [switch] $EnsureStarted
    )

    $result = Write-AltServerNotice -AlwaysStatus:$AlwaysStatus -EnsureStarted:$EnsureStarted
    if (-not $result.Installed) {
        Write-Host (Get-LoopSegmentsAltServerSevenDayWarning) -ForegroundColor Yellow
        if ($IncludeResolution) {
            Write-Host (Get-LoopSegmentsAppUnavailableResolution) -ForegroundColor Yellow
        }
        return $result
    }

    if ($AlwaysStatus) {
        Write-Host '[altserver] If app unavailable after ~7 days: AltServer -> USB -> AltStore Refresh All -> Trust developer -> open once.' -ForegroundColor DarkYellow
    }
    if ($IncludeResolution) {
        Write-Host (Get-LoopSegmentsAppUnavailableResolution) -ForegroundColor Yellow
    }
    return $result
}

function Start-LoopSegmentsAltServer {
    param(
        [int] $WaitSeconds = 3
    )

    $result = Start-AltServer -WaitSeconds $WaitSeconds
    if (-not $result.Installed) {
        Write-Host (Get-LoopSegmentsAltServerSevenDayWarning) -ForegroundColor Yellow
    }
    return $result
}

function Test-LoopSegmentsUsbmuxListHasDevice {
    param(
        [int] $ExitCode,
        [string[]] $Lines
    )
    if ($ExitCode -ne 0) { return $false }
    $text = (@($Lines) | ForEach-Object { [string]$_ }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -match '(?i)no devices?|device not found|unable to connect') { return $false }
    if ($text -match '(?s)^\s*\[\s*\]\s*$') { return $false }
    if ($text -match '"UniqueDeviceID"|"SerialNumber"|"DeviceName"|[0-9A-Fa-f]{40}') { return $true }
    if ($text -match '\{') { return $true }
    return $false
}
