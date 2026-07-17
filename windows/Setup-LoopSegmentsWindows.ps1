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

.PARAMETER PhoneHost
  Optional iPhone LAN IP to write into loop-segments-windows.json.

.PARAMETER SkipCompanion
  Skip companion venv / Chromium install.

.PARAMETER SkipUsbTools
  Skip pymobiledevice3 install.

.PARAMETER ForceCompanionVenv
  Recreate the companion venv even if it looks healthy.

.EXAMPLE
  .\Setup-LoopSegmentsWindows.ps1

.EXAMPLE
  .\Setup-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [switch] $SkipCompanion,
    [switch] $SkipUsbTools,
    [switch] $ForceCompanionVenv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\LoopSegments-Windows.ps1"
. "$PSScriptRoot\Get-LoopSegmentsPython.ps1"
. "$PSScriptRoot\Get-LoopSegmentsAltServer.ps1"

$exampleJson = Join-Path $PSScriptRoot "loop-segments-windows.example.json"
$liveJson = Join-Path $PSScriptRoot "loop-segments-windows.json"
$companionDir = Join-Path $PSScriptRoot "pcloud_web_companion"
$runChromium = Join-Path $companionDir "run_chromium.ps1"

Write-Host "=== Loop Segments Windows setup (portable) ===" -ForegroundColor Cyan
Write-Host "Repo windows folder: $PSScriptRoot"
Write-Host "Machine-local companion data: $(Join-Path $env:LOCALAPPDATA 'pcloud_web_companion')"
Write-Host ""
[void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)
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
    Write-Warning "[config] phoneLanHost is empty. Set it with: .\Set-LoopSegmentsWindows.ps1 -PhoneHost <ip>"
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
  .\Set-LoopSegmentsWindows.ps1 -Show
  .\Run-PCloudWebCompanion.ps1

Portable notes:
  - loop-segments-windows.json is per-PC (gitignored). Prefer empty rcloneConfigPath.
  - Companion venv/browsers/extension live under %LOCALAPPDATA%\pcloud_web_companion (not P:).
  - chromium-profile on P: is intentional (shared pCloud login cookies across your PCs).
  - On a new PC: run this Setup again; do not copy another user's .venv.
  - Install AltServer (https://altstore.io) and keep it running for AltStore refresh;
    without weekly refresh, free/Personal Team Loop Segments stops opening after ~7 days.
  - If the app becomes unavailable: AltServer running -> USB + unlock -> AltStore Refresh All
    -> Settings -> General -> VPN & Device Management -> Developer App -> Trust
    -> open Loop Segments once -> retry companion/USB launch.
  - Optional: .\Register-AltServerAtLogon.ps1
"@
[void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)