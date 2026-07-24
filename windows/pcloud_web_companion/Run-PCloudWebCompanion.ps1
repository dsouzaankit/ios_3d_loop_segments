#Requires -Version 5.1
<#
.SYNOPSIS
  Start integrated pcloud_web_companion Chromium helper (USB-launches Loop Segments first).

.DESCRIPTION
  Wrapper around run_chromium.ps1 in this folder.
  Before Chromium starts, prints phone LAN status, then always USB-launches
  Loop Segments to foreground the app (unless -SkipUsbLaunch), then attempts an
  rclone WebDAV mount (unless -SkipRcloneMount) in a separate window when LAN is up.
  Exit code 3 (phone locked) aborts Chromium. No USB / other USB failures abort only when
  phone LAN is also down; if LAN is up, warns and continues.
  On error, waits for Enter so a double-clicked console window does not close immediately.
  While Chromium is running, Ctrl+C or closing the console (X) kills that Chromium profile
  and syncs/clears the profile the same as a normal exit. On finish, presses iPhone Home
  over USB so Loop Segments is backgrounded (Keep Alive can keep running).

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipUsbLaunch

.EXAMPLE
  .\Run-PCloudWebCompanion.ps1 -SkipRcloneMount
#>
[CmdletBinding()]
param(
    [switch] $RecreateVenv,
    [switch] $ForceDeps,
    [switch] $NoLaunch,
    [switch] $SkipUsbLaunch,
    [switch] $UsbLaunchMount,
    [switch] $SkipRcloneMount,
    [switch] $SkipProfileSync,
    [switch] $DetachChromium,
    [switch] $KeepLocalProfile,
    [switch] $SkipGoHome,
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
        RecreateVenv     = $RecreateVenv
        ForceDeps        = $ForceDeps
        NoLaunch         = $NoLaunch
        SkipUsbLaunch    = $SkipUsbLaunch
        UsbLaunchMount   = $UsbLaunchMount
        SkipRcloneMount  = $SkipRcloneMount
        SkipProfileSync  = $SkipProfileSync
        DetachChromium   = $DetachChromium
        KeepLocalProfile = $KeepLocalProfile
        SkipGoHome       = $SkipGoHome
        StartUrl         = $StartUrl
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
