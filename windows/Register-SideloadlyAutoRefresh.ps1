#Requires -Version 5.1
<#
.SYNOPSIS
  Enable Sideloadly automatic app refresh (7-day cert) on USB or Wi-Fi.

.DESCRIPTION
  Sideloadly has NO public command-line to refresh IPAs. Automation is done by the
  **Sideloadly Daemon**, which refreshes enrolled apps when your iPhone is seen on
  **USB** or **Wi-Fi** (near expiry).

  This script:
  1. Prints the one-time Sideloadly GUI steps (enable Automatic App Refresh on install).
  2. Registers a logon task to start SideloadlyDaemon.exe if missing.
  3. Optionally registers a lightweight USB-watch task that keeps the daemon running when
     an Apple device is plugged in (daemon performs the actual refresh).

.PARAMETER IpaPath
  Path to LoopSegments.ipa for reference in setup output (optional).

.PARAMETER TaskNamePrefix
  Scheduled task name prefix (default: LoopSegments-Sideloadly).

.PARAMETER WatchUsb
  Register an additional task: every 2 minutes while logged on, if iPhone USB is
  detected, ensure Sideloadly Daemon is running.

.PARAMETER Unregister
  Remove tasks created by this script.

.EXAMPLE
  .\Register-SideloadlyAutoRefresh.ps1

.EXAMPLE
  .\Register-SideloadlyAutoRefresh.ps1 -WatchUsb -IpaPath 'P:\...\LoopSegments.ipa'

.NOTES
  Requires Sideloadly installed from sideloadly.io (not Microsoft Store iTunes).
  See ios/BUILD-WITHOUT-MAC.md
#>
[CmdletBinding()]
param(
    [string] $IpaPath = '',
    [string] $TaskNamePrefix = 'LoopSegments-Sideloadly',
    [switch] $WatchUsb,
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

function Get-SideloadlyDaemonPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Sideloadly\SideloadlyDaemon.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly\SideloadlyDaemon.exe'),
        (Join-Path ${env:ProgramFiles} 'Sideloadly\SideloadlyDaemon.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Sideloadly\SideloadlyDaemon.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $found = @(Get-ChildItem -Path $env:LOCALAPPDATA -Filter 'SideloadlyDaemon.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($found) { return $found.FullName }
    return $null
}

function Test-IphoneUsbConnected {
    try {
        $devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
                $_.Status -eq 'OK' -and $_.FriendlyName -match 'Apple Mobile Device|Apple iPhone|iPad|iPod'
            })
        return ($devices.Count -gt 0)
    } catch {
        try {
            $entities = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match 'Apple Mobile Device|Apple iPhone'
                })
            return ($entities.Count -gt 0)
        } catch {
            return $false
        }
    }
}

function Start-SideloadlyDaemonIfNeeded {
    param([string] $DaemonPath)
    if ([string]::IsNullOrWhiteSpace($DaemonPath) -or -not (Test-Path -LiteralPath $DaemonPath)) {
        return $false
    }
    $proc = Get-Process -Name 'SideloadlyDaemon' -ErrorAction SilentlyContinue
    if ($proc) { return $true }
    Start-Process -FilePath $DaemonPath -WindowStyle Hidden
    return $true
}

function Unregister-LoopSegmentsSideloadlyTasks {
    param([string] $Prefix)
    foreach ($name in @("$Prefix-LogonDaemon", "$Prefix-UsbWatch")) {
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Removed scheduled task: $name"
        }
    }
}

function Show-SideloadlySetupGuide {
    param([string] $DaemonPath, [string] $IpaPath)
    Write-Host ''
    Write-Host '=== Sideloadly automatic refresh (one-time GUI setup) ===' -ForegroundColor Cyan
    Write-Host @'

Sideloadly cannot be fully driven from PowerShell (no official CLI). Use its built-in daemon:

1. Install iTunes (64-bit) from Apple — see ios/BUILD-WITHOUT-MAC.md
2. iTunes → iPhone → Summary → enable "Sync with this iDevice over Wi-Fi" → Apply
3. In Sideloadly, sideload LoopSegments.ipa and CHECK:
     [x] Automatic App Refresh  (or equivalent on your Sideloadly version)
4. In Sideloadly settings: enable "Sideloadly Daemon" / launch at startup
5. Trust developer on iPhone after install (Settings → General → VPN & Device Management)

When enrolled, the daemon refreshes apps near expiry when the phone is on USB OR Wi-Fi
(same network). You do NOT need to open the Sideloadly window each week.

'@
    if ($IpaPath) { Write-Host "IPA: $IpaPath" }
    if ($DaemonPath) {
        Write-Host "Daemon: $DaemonPath" -ForegroundColor Green
    } else {
        Write-Host 'Daemon: NOT FOUND — install Sideloadly from https://sideloadly.io first.' -ForegroundColor Yellow
    }
    Write-Host ''
}

if ($Unregister) {
    Unregister-LoopSegmentsSideloadlyTasks -Prefix $TaskNamePrefix
    exit 0
}

$daemonPath = Get-SideloadlyDaemonPath
Show-SideloadlySetupGuide -DaemonPath $daemonPath -IpaPath $IpaPath

if (-not $daemonPath) {
    Write-Warning 'Install Sideloadly, then re-run this script to register the logon task.'
    exit 1
}

$logonTaskName = "$TaskNamePrefix-LogonDaemon"
$logonAction = New-ScheduledTaskAction -Execute $daemonPath
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logonSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $logonTaskName -Action $logonAction -Trigger $logonTrigger -Settings $logonSettings -Force | Out-Null
Write-Host "Registered logon task: $logonTaskName (starts Sideloadly Daemon)"

if ($WatchUsb) {
    $watchScript = Join-Path $PSScriptRoot 'Invoke-SideloadlyDaemonOnUsb.ps1'
    if (-not (Test-Path -LiteralPath $watchScript)) {
        throw "Missing helper: $watchScript"
    }
    $watchTaskName = "$TaskNamePrefix-UsbWatch"
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchScript`""
    $watchAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $watchTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $watchSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $watchTaskName -Action $watchAction -Trigger $watchTrigger -Settings $watchSettings -Force | Out-Null
    Write-Host "Registered USB-watch task: $watchTaskName (polls for Apple USB, starts daemon)"
    Write-Host 'Note: refresh is still performed BY Sideloadly Daemon, not this script.'
}

Write-Host ''
Write-Host 'Done. Enroll Loop Segments with Automatic App Refresh checked in Sideloadly once.'
Write-Host 'Remove tasks: .\Register-SideloadlyAutoRefresh.ps1 -Unregister'
