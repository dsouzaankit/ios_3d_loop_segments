#Requires -Version 5.1
<#
.SYNOPSIS
  Start integrated pcloud_web_companion Chromium helper (USB-launches Loop Segments first).

.DESCRIPTION
  Wrapper around run_chromium.ps1 in this folder.
  Before Chromium starts, if the PC default gateway is not on the same subnet as
  the phone LAN page IP, reboots Wi-Fi on that current gateway (scripts under
  P:\all_scripts\5g_router_reboot), waits for this PC to get a new LAN IP, and
  retries up to 3 rounds until the gateway shares the app LAN subnet (then waits for
  Enter if still wrong); then
  prints phone LAN status, USB-launches Loop Segments to foreground the app
  (unless -SkipUsbLaunch), then attempts an rclone WebDAV mount (unless
  -SkipRcloneMount) in a separate window when LAN is up, then probes LAN
  throughput off the mount (unless -SkipLanThroughput). If throughput is below
  minLanThroughputMbps in loop-segments-windows.json (default 45) while gateway and
  LAN page share a subnet, forces a gateway Wi-Fi reboot,
  asks you to retry later, waits briefly, then exits on Enter (Chromium not started).
  Exit code 3 (phone locked) aborts Chromium. No USB / other USB failures abort only when
  phone LAN is also down; if LAN is up, warns and continues.
  On any error / non-zero exit, waits for a single Enter so a double-clicked console
  does not close immediately (child scripts use -NoWaitEnter / -NoWaitEnterOnFatal
  so you are not prompted twice).
  While Chromium is running, Ctrl+C or closing the console (X) kills that Chromium profile
  and syncs/clears the profile the same as a normal exit. On finish, presses iPhone Home
  over USB so Loop Segments is backgrounded (Keep Alive can keep running).

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipRcloneMount

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipGatewayReboot

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipLanThroughput

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipLowThroughputGatewayReboot

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -NoDarkMode
#>
[CmdletBinding()]
param(
    [switch] $RecreateVenv,
    [switch] $ForceDeps,
    [switch] $NoLaunch,
    [switch] $SkipUsbLaunch,
    [switch] $UsbLaunchMount,
    [switch] $SkipRcloneMount,
    [switch] $SkipGatewayReboot,
    [switch] $SkipLanThroughput,
    [switch] $SkipLowThroughputGatewayReboot,
    [switch] $SkipProfileSync,
    [switch] $DetachChromium,
    [switch] $KeepLocalProfile,
    [switch] $SkipGoHome,
    [switch] $NoDarkMode,
    [string] $StartUrl = "https://my.pcloud.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-EnterOnError {
    param([int] $ExitCode = 1)
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
    exit $ExitCode
}

try {
    $target = Join-Path $PSScriptRoot "run_chromium.ps1"
    if (-not (Test-Path -LiteralPath $target)) {
        throw "Missing $target"
    }

    $forward = @{
        RecreateVenv                    = $RecreateVenv
        ForceDeps                       = $ForceDeps
        NoLaunch                        = $NoLaunch
        SkipUsbLaunch                   = $SkipUsbLaunch
        UsbLaunchMount                  = $UsbLaunchMount
        SkipRcloneMount                 = $SkipRcloneMount
        SkipGatewayReboot               = $SkipGatewayReboot
        SkipLanThroughput               = $SkipLanThroughput
        SkipLowThroughputGatewayReboot  = $SkipLowThroughputGatewayReboot
        SkipProfileSync                 = $SkipProfileSync
        DetachChromium                  = $DetachChromium
        KeepLocalProfile                = $KeepLocalProfile
        SkipGoHome                      = $SkipGoHome
        NoDarkMode                      = $NoDarkMode
        NoWaitEnterOnFatal              = $true
        StartUrl                        = $StartUrl
    }

    & $target @forward
    $code = 0
    if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    if ($code -ne 0) {
        Write-Host "[Run-PCloudWebCompanion] Failed (exit $code)." -ForegroundColor Red
        Wait-EnterOnError -ExitCode $code
    }
    exit 0
} catch {
    Write-Host ""
    Write-Host "[Run-PCloudWebCompanion] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Wait-EnterOnError -ExitCode 1
}
