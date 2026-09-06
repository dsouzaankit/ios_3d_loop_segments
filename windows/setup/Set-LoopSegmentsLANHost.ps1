#Requires -Version 5.1
<#
.SYNOPSIS
  Save the iPhone LAN IP for Windows scripts (e.g. rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly).

.DESCRIPTION
  With no -PhoneHost, reads the USB-connected phone's Wi-Fi IPv4 via pymobiledevice3
  pcapd (env_setup Get-IphoneLanIpv4.py) and writes phoneLanHost. Pass an IP to set
  explicitly. Subnet align (phone + PC same LAN) is separate:
  lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 -ForceDiscover
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $PhoneHost = '',

    # Re-read USB even when the configured phoneLanHost still answers :8765.
    [switch] $ForceDiscover
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\Get-LoopSegmentsPwsh.ps1"
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"
Initialize-LoopSegmentsWindowsConfig

if (-not [string]::IsNullOrWhiteSpace($PhoneHost)) {
    $settings = Get-LoopSegmentsWindowsSettings
    $settings.phoneLanHost = $PhoneHost.Trim()
    Save-LoopSegmentsWindowsSettings -Settings $settings
} else {
    $found = Update-LoopSegmentsLANHostFromDiscovery -Force:$ForceDiscover
    if ([string]::IsNullOrWhiteSpace($found)) {
        throw 'USB pcapd did not return a phone Wi-Fi IP. Plug in USB, unlock phone, join Wi-Fi — or pass an IP: .\Set-LoopSegmentsLANHost.ps1 <phone-ip>'
    }
}

Write-Host "Run: .\Set-LoopSegmentsWindows.ps1 -Show"
Write-Host "     ..\rclone\Mount-LoopSegmentsRclone.ps1 -TestOnly   # then mount without -TestOnly"
