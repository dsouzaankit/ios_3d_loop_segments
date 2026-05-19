#Requires -Version 5.1
<#
.SYNOPSIS
  Map the phone Exports folder as a Windows drive letter via WebDAV (read-only).

.DESCRIPTION
  Loop Segments cannot run a true SMB server on iOS. The app serves Documents/Exports on
  port 8765 with HTTP + WebDAV (PROPFIND). This script maps that URL to a drive letter
  (e.g. L:) so Explorer can browse op_00.mp4 and logs.

  Requires WebClient service. For HTTP (not HTTPS) on LAN, Windows may need one-time
  registry tweaks (this script can apply them with -ConfigureWebClient).

.PARAMETER PhoneHost
  iPhone LAN IPv4. Default: loop-segments-lan-host.txt (same as Sync-FromPhoneLAN.ps1).

.PARAMETER DriveLetter
  Drive letter without colon (default L).

.PARAMETER Port
  LAN port (default 8765).

.PARAMETER Remove
  Disconnect the mapped drive.

.PARAMETER ConfigureWebClient
  Set BasicAuthLevel and FileSizeLimitInBytes for HTTP WebDAV (admin; run once per PC).

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
  .\Map-LoopSegmentsWebDAV.ps1

.EXAMPLE
  .\Map-LoopSegmentsWebDAV.ps1 -DriveLetter M -Remove
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = 'L',
    [int] $Port = 8765,
    [switch] $Remove,
    [switch] $ConfigureWebClient
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Config.ps1"

function Get-LoopSegmentsLANHostConfigPath {
    Join-Path $PSScriptRoot 'loop-segments-lan-host.txt'
}

function Get-LoopSegmentsLANHost {
    param([string] $Override = '')
    $resolved = $Override.Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $configFile = Get-LoopSegmentsLANHostConfigPath
        if (Test-Path -LiteralPath $configFile -PathType Leaf) {
            $resolved = (Get-Content -LiteralPath $configFile -Raw).Trim().Trim('"')
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "PhoneHost required. Run .\Set-LoopSegmentsLANHost.ps1 <ip> or pass -PhoneHost."
    }
    return $resolved.Trim()
}

function Enable-LoopSegmentsWebClientHTTP {
    $wc = Get-Service -Name WebClient -ErrorAction SilentlyContinue
    if (-not $wc) {
        Write-Warning 'WebClient service not found (Windows Home N without media features?). Use Sync-FromPhoneLAN.ps1 instead.'
        return
    }
    if ($wc.Status -ne 'Running') {
        Set-Service -Name WebClient -StartupType Manual
        Start-Service -Name WebClient
        Write-Host 'Started WebClient service.'
    }
    $paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
    if (-not (Test-Path -LiteralPath $paramsPath)) {
        New-Item -Path $paramsPath -Force | Out-Null
    }
    Set-ItemProperty -Path $paramsPath -Name BasicAuthLevel -Type DWord -Value 2
    Set-ItemProperty -Path $paramsPath -Name FileSizeLimitInBytes -Type DWord -Value 4294967295
    Write-Host 'WebClient: BasicAuthLevel=2, FileSizeLimitInBytes=max (HTTP WebDAV on LAN).'
    Write-Host 'Reboot or restart WebClient if mapping still fails.'
}

if ($ConfigureWebClient) {
    Enable-LoopSegmentsWebClientHTTP
    return
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$rootUrl = "http://${hostIp}:${Port}/"
$drive = "${DriveLetter}:"

if ($Remove) {
    cmd /c "net use $drive /delete /y" 2>$null | Out-Null
    Write-Host "Disconnected $drive (if it was mapped)."
    return
}

Enable-LoopSegmentsWebClientHTTP

$existing = cmd /c "net use $drive" 2>$null
if ($LASTEXITCODE -eq 0) {
    cmd /c "net use $drive /delete /y" | Out-Null
}

Write-Host "Mapping $drive -> $rootUrl (read-only WebDAV; phone app must be open, Serve Exports on)."
cmd /c "net use $drive `"$rootUrl`" /persistent:no"
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'If mapping failed, run once as Administrator:'
    Write-Host "  .\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient"
    Write-Host 'Then retry. For automatic DLNA copy use Sync-FromPhoneLAN.ps1 -Watch instead.'
    exit $LASTEXITCODE
}
Write-Host "Open ${drive}\ in Explorer. Prefer op_00.mp4 over _export_source_working.mp4 for playback."
