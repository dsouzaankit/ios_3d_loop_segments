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

function Get-AltServerPath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'AltServer\AltServer.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'AltServer\AltServer.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AltServer\AltServer.exe'),
        (Join-Path $env:LOCALAPPDATA 'AltServer\AltServer.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $found = Get-ChildItem -Path $env:LOCALAPPDATA, ${env:ProgramFiles} -Filter 'AltServer.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed: $TaskName"
    }
    exit 0
}

$altServer = Get-AltServerPath
if (-not $altServer) {
    Write-Error @"
AltServer.exe not found. Install from https://altstore.io first.
The AltServer installer usually offers "Run at startup" — use that if present.
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
