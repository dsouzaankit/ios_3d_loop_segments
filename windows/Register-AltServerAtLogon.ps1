#Requires -Version 5.1
<#
.SYNOPSIS
  Start AltServer at Windows logon (for AltStore background refresh).

.DESCRIPTION
  Starts AltServer after you sign in so it is in the tray when AltStore requests a refresh.
  AltServer does NOT refresh apps on USB/Wi-Fi detection — you still tap Refresh All in
  AltStore (USB), or rely on AltStore background refresh (Wi-Fi). See BUILD-WITHOUT-MAC.md §3.

.PARAMETER TaskName
  Scheduled task name (default: LoopSegments-AltServer).

.PARAMETER Unregister
  Remove the scheduled task.

.EXAMPLE
  .\Register-AltServerAtLogon.ps1
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'LoopSegments-AltServer',
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'

$AltServerHelper = Join-Path $PSScriptRoot 'Get-LoopSegmentsAltServer.ps1'
if (-not (Test-Path -LiteralPath $AltServerHelper)) {
    throw "Missing shared AltServer helper: $AltServerHelper"
}
. $AltServerHelper

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed: $TaskName"
    }
    exit 0
}

$altServer = Get-LoopSegmentsAltServerPath
if (-not $altServer) {
    Write-Error @"
AltServer.exe not found. Install from https://altstore.io first.
The AltServer installer usually offers "Run at startup" - use that if present.

$(Get-LoopSegmentsAltServerSevenDayWarning)
"@
}

$action = New-ScheduledTaskAction -Execute $altServer
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host "Registered: $TaskName"
Write-Host "AltServer: $altServer"
Write-Host 'Enable Background App Refresh for AltStore on the iPhone — see ios/BUILD-WITHOUT-MAC.md §3.'
Write-Host "Remove: .\Register-AltServerAtLogon.ps1 -Unregister"
