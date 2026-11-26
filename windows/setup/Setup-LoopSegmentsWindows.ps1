#Requires -Version 5.1
<#
.SYNOPSIS
  One-time / new-PC bootstrap for Loop Segments Windows tooling.

.DESCRIPTION
  Makes setup portable across Windows machines:
  - Ensures Python 3.12 (hint if missing) and pymobiledevice3
  - Creates loop-segments-windows.json from the example when missing
  - Clears foreign/standard absolute rcloneConfigPath values
  - Builds the pCloud companion venv under %LOCALAPPDATA% (not on P:)
  - Installs Playwright Chromium into the machine-local cache
  - PC-signed USB install: zsign, SideStore's .p12, its password (setup\Set-LoopSegmentsSigning.ps1)

.PARAMETER PhoneHost
  Optional iPhone LAN IP to write into loop-segments-windows.json. Without it (and with no saved
  phoneLanHost), setup reads the Wi-Fi IP of whichever iPhone is on USB once pymobiledevice3 is ready.

.PARAMETER SkipCompanion
  Skip companion venv / Chromium install.

.PARAMETER SkipUsbTools
  Skip pymobiledevice3 install.

.PARAMETER ForceCompanionVenv
  Recreate the companion venv even if it looks healthy.

.PARAMETER SkipSigning
  Skip the PC-signed USB install setup (setup\Set-LoopSegmentsSigning.ps1: zsign download, SideStore
  .p12 check, its password in this PC's Credential Manager).

.PARAMETER EnsureAltServer
  Opt-in: print AltServer install/status (AltStore). Default skips (SideStore).

.EXAMPLE
  .\setup\Setup-LoopSegmentsWindows.ps1

.EXAMPLE
  .\setup\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [switch] $SkipCompanion,
    [switch] $SkipUsbTools,
    [switch] $ForceCompanionVenv,
    [switch] $EnsureAltServer,
    [switch] $SkipSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WindowsRoot = Split-Path -Parent $PSScriptRoot
$LibDir = Join-Path $WindowsRoot 'lib'
. (Join-Path $LibDir 'LoopSegments-Windows.ps1')
. (Join-Path $LibDir 'Get-LoopSegmentsPython.ps1')
. (Join-Path $LibDir 'Get-LoopSegmentsAltServer.ps1')

$exampleJson = Join-Path $WindowsRoot "loop-segments-windows.example.json"
$liveJson = Join-Path $WindowsRoot "loop-segments-windows.json"
$companionDir = Join-Path $WindowsRoot "pcloud_web_companion"
$runChromium = Join-Path $companionDir "_run_chromium.ps1"

Write-Host "=== Loop Segments Windows setup (portable) ===" -ForegroundColor Cyan
Write-Host "Repo windows folder: $WindowsRoot"
Write-Host "Machine-local companion data: $(Join-Path $env:LOCALAPPDATA 'pcloud_web_companion')"
Write-Host ""
[void](Write-LoopSegmentsAltServerNotice -AlwaysStatus -EnsureAltServer:$EnsureAltServer)
Write-Host ""

# --- per-PC json ---
if (-not (Test-Path -LiteralPath $liveJson)) {
    if (-not (Test-Path -LiteralPath $exampleJson)) {
        throw "Missing $exampleJson"
    }
    Copy-Item -LiteralPath $exampleJson -Destination $liveJson
    Write-Host "[config] Created $liveJson from example"
}

Initialize-LoopSegmentsWindowsConfig
$settings = Get-LoopSegmentsWindowsSettings
$configDirty = $false

if (-not [string]::IsNullOrWhiteSpace($PhoneHost)) {
    $settings.phoneLanHost = $PhoneHost.Trim()
    $configDirty = $true
}

if (-not [string]::IsNullOrWhiteSpace($settings.rcloneConfigPath)) {
    $rclonePath = [string]$settings.rcloneConfigPath
    $clear = $false
    if (Test-IsStandardRcloneConfigPath $rclonePath) {
        Write-Host "[config] Clearing standard rcloneConfigPath for portability"
        $clear = $true
    } elseif (Test-RcloneConfigPathForeignUser $rclonePath) {
        Write-Host "[config] Clearing rcloneConfigPath from another Windows user"
        $clear = $true
    } elseif (-not (Test-Path -LiteralPath (Resolve-LoopSegmentsPath $rclonePath))) {
        Write-Host "[config] Clearing missing rcloneConfigPath: $rclonePath"
        $clear = $true
    }
    if ($clear) {
        $settings.rcloneConfigPath = ''
        $configDirty = $true
    }
}

if ($configDirty) {
    Save-LoopSegmentsWindowsSettings -Settings $settings
}

if ([string]::IsNullOrWhiteSpace($settings.phoneLanHost)) {
    Write-Host "[config] phoneLanHost not set yet; read from the iPhone on USB after the USB tools step"
} else {
    Write-Host "[config] phoneLanHost = $($settings.phoneLanHost)"
}
Write-Host "[config] rcloneConfigPath = '$(if ($settings.rcloneConfigPath) { $settings.rcloneConfigPath } else { '<auto>' })'"

# --- Python / USB ---
$pyRt = Get-LoopSegmentsPythonRuntime -ForVenv
if (-not $pyRt) {
    Write-Host ""
    Write-Host "[python] No suitable runtime (3.9-3.13; prefer 3.12)." -ForegroundColor Yellow
    Write-Host (Get-LoopSegmentsPythonInstallHint)
    throw "Python 3.12 (or 3.9-3.13) is required. Install it, then re-run Setup-LoopSegmentsWindows.ps1."
}
Write-Host "[python] Using $($pyRt.Display)"

if (-not $SkipUsbTools) {
    $importCheck = Invoke-LoopSegmentsPythonRuntime -Runtime $pyRt -ArgumentList @(
        "-c", "import pymobiledevice3; print('ok')"
    )
    if ($importCheck.ExitCode -ne 0 -or (($importCheck.Lines -join "`n") -notmatch "(?m)^ok\s*$")) {
        Write-Host "[usb] Installing pymobiledevice3 for $($pyRt.Display) ..."
        $pip = Invoke-LoopSegmentsPythonRuntime -Runtime $pyRt -ArgumentList @(
            "-m", "pip", "install", "-U", "pymobiledevice3"
        )
        $pip.Lines | ForEach-Object { Write-Host $_ }
        if ($pip.ExitCode -ne 0) {
            throw @"
pymobiledevice3 install failed for $($pyRt.Display).

If you are on Python 3.13/3.14 and build tools are missing, install 3.12 instead:
  py install 3.12
  py -3.12 -m pip install -U pymobiledevice3
"@
        }
    } else {
        Write-Host "[usb] pymobiledevice3 already available for $($pyRt.Display)"
    }
}

# --- phone LAN host (any iPhone: read from the one on USB when not configured) ---
if ([string]::IsNullOrWhiteSpace([string](Get-LoopSegmentsWindowsSettings).phoneLanHost)) {
    $found = $null
    if (-not $SkipUsbTools) {
        try { $found = Update-LoopSegmentsLANHostFromDiscovery } catch {
            Write-Host "[config] USB phone IP lookup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$found)) {
        Write-Warning "[config] phoneLanHost is empty. Plug in the iPhone (unlocked, on Wi-Fi) and run .\setup\Set-LoopSegmentsLANHost.ps1, or .\setup\Set-LoopSegmentsWindows.ps1 -PhoneHost <ip>"
    } else {
        Write-Host "[config] phoneLanHost = $found (from the iPhone on USB)"
    }
}

# --- PC-signed USB install (zsign + SideStore's .p12; password per PC) ---
if (-not $SkipSigning) {
    Write-Host "[signing] PC-signed USB install (no Install tap; deploy.ps1 falls back to SideStore without it) ..."
    & (Join-Path $PSScriptRoot 'Set-LoopSegmentsSigning.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[signing] Not fully set up (see above); deploys use the SideStore install until it is. Re-run .\setup\Set-LoopSegmentsSigning.ps1 later." -ForegroundColor Yellow
    }
    $global:LASTEXITCODE = 0
}

# --- companion venv + Chromium ---
if (-not $SkipCompanion) {
    if (-not (Test-Path -LiteralPath $runChromium)) {
        throw "Missing $runChromium"
    }
    Write-Host "[companion] Ensuring machine-local venv + Chromium (no browser launch) ..."
    $args = @{
        NoLaunch       = $true
        SkipUsbLaunch  = $true
        SkipProfileSync = $true
    }
    if ($ForceCompanionVenv) {
        $args.RecreateVenv = $true
    }
    & $runChromium @args
    if ($LASTEXITCODE -ne 0) {
        throw "Companion setup failed (exit $LASTEXITCODE)."
    }
}

Write-Host ""
Write-Host "=== Setup complete ===" -ForegroundColor Green
Write-Host @"
Next:
  .\setup\Set-LoopSegmentsWindows.ps1 -Show
  .\pcloud_web_companion\Run-PCloudWebCompanion.ps1

Portable notes:
  - loop-segments-windows.json is per-PC (gitignored). Prefer empty rcloneConfigPath.
  - Companion venv/browsers/extension live under %LOCALAPPDATA%\pcloud_web_companion (not P:).
  - chromium-profile on P: is intentional (shared pCloud login cookies across your PCs).
  - On a new PC: run this Setup again; do not copy another user's .venv.
  - PC-signed USB install: ..\env_setup\zsign\signing.p12 syncs with that folder; the password is
    per PC (Credential Manager): .\setup\Set-LoopSegmentsSigning.ps1 asks for it.
  - Install AltServer (https://altstore.io) and keep it running for AltStore refresh;
    without weekly refresh, free/Personal Team Loop Segments stops opening after ~7 days.
  - If the app becomes unavailable: AltServer running -> USB + unlock -> AltStore Refresh All
    -> Settings -> General -> VPN & Device Management -> Developer App -> Trust
    -> open Loop Segments once -> retry companion/USB launch.
  - Optional: .\sideload\Register-AltServerAtLogon.ps1
"@
[void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)