#Requires -Version 7.0
<#
.SYNOPSIS
  Get the USB iPhone ready for a SideStore install: Loop Segments not in front, LocalDevVPN on.

.DESCRIPTION
  deploy.ps1 runs this right after it triggers the IPA build (and before the USB install when it
  skips the trigger). No router is touched: the phone LAN Wi-Fi has no gateway on purpose (LAN only,
  5G for internet), and the install itself moves the PC off that LAN (Install-LoopSegmentsIpaViaUsb.ps1).

  1. usbmux list (pymobiledevice3). No iPhone on USB: skipped (exit 0).
  2. Loop Segments in the foreground (DVT proclist): quit it (DVT kill), since SideStore installs
     over a running app often hang. A backgrounded app is left alone. Not while an export or the
     pending queue runs (checked on the LAN page when this PC can reach it). -NoQuit skips it.
  3. LocalDevVPN (SideStore needs it): its tunnel process not running -> launch LocalDevVPN over USB
     (Connect-LocalDevVPNViaUsb.py); its "Auto-connect on launch" setting (switch it on once in
     LocalDevVPN) then connects, this waits up to 15 s, and the phone goes back to the Home Screen.
     When it switched the VPN on, it leaves %TEMP%\loopsegments-vpn-turned-on.json so the install
     switches it off again afterwards. -NoVpn skips it.

.EXITCODES
  0  done or skipped (warnings are printed; they never fail the deploy)

.EXAMPLE
  .\Prepare-PhoneForSideStoreViaUsb.ps1
#>
[CmdletBinding()]
param(
    # Leave Loop Segments running even when it is in the foreground.
    [switch] $NoQuit,
    # Do not connect LocalDevVPN.
    [switch] $NoVpn
)

$ErrorActionPreference = 'Stop'
$WindowsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $WindowsDir 'lib\LoopSegments-Windows.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsPython.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsAltServer.ps1')

function Write-Prep([string] $Text, [string] $Color = 'Gray') {
    Write-Host "[phone-prep] $Text" -ForegroundColor $Color
}

function Get-ExportBusyReason {
    # Best effort: only when this PC can reach the phone LAN page (status.json, WebDAV login).
    $settings = Get-LoopSegmentsWindowsSettings
    $hostName = ([string]$settings.phoneLanHost).Trim()
    if (-not $hostName) { return $null }
    $port = Get-LoopSegmentsLanPort
    $j = $null
    try {
        $h = Get-LoopSegmentsPhoneWebDavAuthHeader
        $j = Invoke-RestMethod -Uri "http://${hostName}:$port/status.json" -Headers $h -NoProxy -TimeoutSec 5
    } catch { return $null }
    if ($null -eq $j) { return $null }
    $es = $j.PSObject.Properties['exportSource']
    if ($null -ne $es -and $null -ne $es.Value) {
        $ph = $es.Value.PSObject.Properties['phase']
        if ($null -ne $ph -and [string]$ph.Value -eq 'running') { return 'export running' }
    }
    $q = $j.PSObject.Properties['pendingExportQueue']
    if ($null -ne $q -and $null -ne $q.Value) {
        $c = $q.Value.PSObject.Properties['count']
        if ($null -ne $c -and [int]$c.Value -gt 0) { return "pending queue ($($c.Value))" }
    }
    return $null
}

# --- 1. iPhone on USB? ---
$rt = Get-LoopSegmentsPythonRuntime -RequirePymobiledevice3
if ($null -eq $rt) {
    Write-Prep 'No Python with pymobiledevice3 - cannot reach the phone over USB; skipped.' Yellow
    exit 0
}
$list = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @('-m', 'pymobiledevice3', 'usbmux', 'list')
if (-not (Test-LoopSegmentsUsbmuxListHasDevice -ExitCode $list.ExitCode -Lines $list.Lines)) {
    Write-Prep 'No iPhone on USB - skipped.'
    exit 0
}
Write-Prep 'iPhone found on USB.'

# --- 2. Quit Loop Segments if it is in the foreground ---
# A running export also blocks the install's phone restart (Install-LoopSegmentsIpaViaUsb.ps1
# -RestartPhoneOnError), which cannot check it later from off the phone LAN: leave a marker.
$busy = Get-ExportBusyReason
$busyMarker = Join-Path $env:TEMP 'loopsegments-export-busy.json'
try {
    if ($busy) { @{ reason = $busy; at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $busyMarker -Encoding utf8 }
    else { Remove-Item -LiteralPath $busyMarker -Force -ErrorAction SilentlyContinue }
} catch {}
if ($NoQuit) {
    Write-Prep 'Foreground quit skipped (-NoQuit).'
} else {
    if ($busy) {
        Write-Prep "Loop Segments left running ($busy)." Yellow
    } else {
        $probePy = Join-Path $PSScriptRoot 'Probe-LoopSegmentsForeground.py'
        $fg = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @($probePy, 'com.loopsegments.app', '--kill')
        $blob = ($fg.Lines -join "`n")
        if ($blob -match '(?m)^KILLED\b') {
            Write-Prep 'Loop Segments was in the foreground - quit it (SideStore can install over it now).' Green
        } elseif ($blob -match '(?m)^KILL_FAILED\b') {
            Write-Prep 'Loop Segments is in the foreground, but quitting it failed (Developer Mode / tunnel?). Swipe it away by hand before installing.' Yellow
        } elseif ($blob -match '(?m)^NOT_FOREGROUND\b') {
            Write-Prep 'Loop Segments is not in the foreground - left alone.'
        } else {
            Write-Prep 'Could not tell whether Loop Segments is in the foreground - left alone.' Yellow
        }
    }
}

# --- 3. LocalDevVPN connected (SideStore installs / refreshes need it) ---
if ($NoVpn) {
    Write-Prep 'LocalDevVPN step skipped (-NoVpn).'
} else {
    $vpnPy = Join-Path $PSScriptRoot 'Connect-LocalDevVPNViaUsb.py'
    $vpn = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @($vpnPy, '--wait', '15')
    $blob = ($vpn.Lines -join "`n")
    if ($blob -match '(?m)^VPN_ALREADY_CONNECTED\b') {
        Write-Prep 'LocalDevVPN already connected.' Green
    } elseif ($blob -match '(?m)^VPN_CONNECTED\b') {
        Write-Prep 'LocalDevVPN: launched it and it connected (switched back off after the USB install).' Green
        # Install-LoopSegmentsIpaViaUsb.ps1 switches it off again once the new build is installed.
        try {
            @{ turnedOnAt = (Get-Date).ToString('o') } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $env:TEMP 'loopsegments-vpn-turned-on.json') -Encoding utf8
        } catch {}
    } elseif ($blob -match '(?m)^VPN_NOT_CONNECTED\b') {
        Write-Prep 'LocalDevVPN: launched it, but it did not connect within 15 s. Switch on "Auto-connect on launch" in LocalDevVPN (once), or tap Connect.' Yellow
    } else {
        $why = (@($vpn.Lines | Where-Object { $_ -match '^(LAUNCH_FAILED|PROBE_FAILED|NO_DEVICE)' }) | Select-Object -First 1)
        Write-Prep "LocalDevVPN: could not check or launch it over USB ($why). Connect it by hand before installing." Yellow
    }
}
exit 0
