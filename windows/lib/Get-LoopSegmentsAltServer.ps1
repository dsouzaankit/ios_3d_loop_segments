#Requires -Version 5.1
<#
.SYNOPSIS
  Loop Segments wrappers around env_setup AltServer helpers.

.DESCRIPTION
  Core locate/start lives in env_setup\altserver_refresh\lib\Get-AltServer.ps1
  (git submodule env_setup, with a sibling-folder fallback).
  This file keeps Loop Segments-specific warnings and USB-list heuristics.
  Dot-source from Launch-LoopSegmentsViaUsb.ps1, run_chromium.ps1, Setup, etc.

  AltServer is optional (SideStore default). Callers pass -EnsureAltServer /
  -EnsureStarted only for the AltStore path. Core env_setup load is lazy.
#>

$script:LoopSegmentsWindowsRoot = Split-Path -Parent $PSScriptRoot
$script:LoopSegmentsRepoRoot = Split-Path -Parent $script:LoopSegmentsWindowsRoot
$script:LoopSegmentsAltServerCoreLoaded = $false

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

function Ensure-LoopSegmentsAltServerCore {
    if ($script:LoopSegmentsAltServerCoreLoaded) { return }
    $core = Join-Path (Get-LoopSegmentsAltserverRefreshDir) 'lib\Get-AltServer.ps1'
    if (-not (Test-Path -LiteralPath $core)) {
        throw "Missing AltServer core: $core"
    }
    . $core
    $script:LoopSegmentsAltServerCoreLoaded = $true
}

function Get-LoopSegmentsAltServerPath {
    Ensure-LoopSegmentsAltServerCore
    Get-AltServerPath
}

function Test-LoopSegmentsAltServerRunning {
    Ensure-LoopSegmentsAltServerCore
    Test-AltServerRunning
}

function Get-LoopSegmentsAppUnavailableResolution {
    return @"
When Loop Segments becomes unavailable (won't open / "Unable to Verify App" /
"Unable to Trust iPhone Developer: you@email" / USB launch blocked by signature):

  SideStore path (no AltServer) — default:
  1. LocalDevVPN Connect -> SideStore -> Refresh (or My Apps -> + reinstall IPA).
  2. Prefer SideStore nightly if stable shows incorrect data format.
  3. Trust the developer on the phone if iOS asks:
       Settings -> General -> VPN & Device Management -> DEVELOPER APP -> Trust
  4. Open Loop Segments once, then re-run the companion / USB launch.

  AltStore path (opt-in -EnsureAltServer / -EnsureAltStorePrep):
  1. Install/start AltServer on this PC (https://altstore.io) - tray icon should be visible.
  2. Plug the iPhone in over USB, unlock it, Trust This Computer.
  3. Open AltStore on the phone -> My Apps -> Refresh All (or refresh Loop Segments).
  4. Trust the developer certificate (same Settings path as above).
  5. Open Loop Segments once by hand, then re-run the companion / USB launch script.

Wi-Fi AltStore background refresh needs AltServer + Background App Refresh; on Windows 11,
USB + Refresh All weekly is the reliable AltStore path. SideStore needs LocalDevVPN only.
See ios/BUILD-WITHOUT-MAC.md.
"@
}

function Get-LoopSegmentsAltServerSevenDayWarning {
    return @"
Without a weekly refresh, a free / Personal Team sideload of Loop Segments expires in ~7 days
(icon may still show; opens fail until refresh).
  SideStore: LocalDevVPN on -> Refresh (no AltServer). Prefer nightly if stable flakes.
  AltStore: AltServer tray (https://altstore.io) + My Apps -> Refresh All (USB OK).
Optional AltStore logon start: .\sideload\Register-AltServerAtLogon.ps1
Scripts skip AltServer by default; pass -EnsureAltServer / -EnsureAltStorePrep for AltStore.
"@
}

function Write-LoopSegmentsAltServerNotice {
    param(
        [switch] $AlwaysStatus,
        [switch] $IncludeResolution,
        [switch] $EnsureStarted,
        [switch] $SkipAltServer,
        [switch] $EnsureAltServer
    )

    # Default: skip. Opt-in with -EnsureAltServer (or legacy callers that only pass EnsureStarted
    # without Skip must now also pass EnsureAltServer from entry scripts).
    $doAlt = $EnsureAltServer -and -not $SkipAltServer
    if (-not $doAlt) {
        if ($AlwaysStatus) {
            Write-Host '[altserver] Skipped (default). SideStore + LocalDevVPN for ~7-day refresh. Pass -EnsureAltServer for AltStore.' -ForegroundColor DarkYellow
        }
        if ($IncludeResolution) {
            Write-Host (Get-LoopSegmentsAppUnavailableResolution) -ForegroundColor Yellow
        }
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Skipped   = $true
        }
    }

    Ensure-LoopSegmentsAltServerCore
    $result = Write-AltServerNotice -AlwaysStatus:$AlwaysStatus -EnsureStarted:$EnsureStarted
    if (-not $result.Installed) {
        Write-Host (Get-LoopSegmentsAltServerSevenDayWarning) -ForegroundColor Yellow
        if ($IncludeResolution) {
            Write-Host (Get-LoopSegmentsAppUnavailableResolution) -ForegroundColor Yellow
        }
        return $result
    }

    if ($AlwaysStatus) {
        Write-Host '[altserver] If app unavailable after ~7 days: SideStore Refresh (LocalDevVPN) or AltServer -> USB -> AltStore Refresh All -> Trust -> open once.' -ForegroundColor DarkYellow
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

    Ensure-LoopSegmentsAltServerCore
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
