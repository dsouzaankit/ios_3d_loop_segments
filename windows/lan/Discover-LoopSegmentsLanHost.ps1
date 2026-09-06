#Requires -Version 5.1
<#
.SYNOPSIS
  Read the USB-connected iPhone Wi-Fi IPv4 (pcapd) and save phoneLanHost.

.DESCRIPTION
  Uses env_setup\lan\Get-IphoneLanIpv4.py over USB. Does not
  TCP-scan the LAN. Phone + PC same-subnet recovery:
  .\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1

  When run directly, waits for Enter before closing. Pass -NoWaitEnter when invoked
  in-process (companion / other scripts).

.EXAMPLE
  .\Discover-LoopSegmentsLanHost.ps1

.EXAMPLE
  .\Discover-LoopSegmentsLanHost.ps1 -Force

.EXAMPLE
  .\Discover-LoopSegmentsLanHost.ps1 -NoSave

.EXAMPLE
  .\Discover-LoopSegmentsLanHost.ps1 -NoWaitEnter
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $NoSave,
    [switch] $NoWaitEnter
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\Get-LoopSegmentsPwsh.ps1"
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    exit $ExitCode
}

trap {
    Write-Host ""
    Write-Host ('[lan-discover] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($NoWaitEnter) { throw $_ }
    Wait-EnterToClose
    exit 1
}

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"
Initialize-LoopSegmentsWindowsConfig

if ($NoSave) {
    $usb = Get-LoopSegmentsIphoneLanIpv4ViaUsb
    if (-not $usb.Ok -or [string]::IsNullOrWhiteSpace($usb.Ip)) {
        Write-Warning ("USB pcapd failed: {0}" -f $(if ($usb.Error) { $usb.Error.Trim() } else { "exit $($usb.ExitCode)" }))
        Exit-WithEnter -ExitCode 1
    }
    Write-Host $usb.Ip
    Exit-WithEnter -ExitCode 0
}

$found = Update-LoopSegmentsLANHostFromDiscovery -Force:$Force
if ([string]::IsNullOrWhiteSpace($found)) {
    Exit-WithEnter -ExitCode 1
}
Write-Host "OK http://${found}:$(Get-LoopSegmentsLanPort)/"
Exit-WithEnter -ExitCode 0
