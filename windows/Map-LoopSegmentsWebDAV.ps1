#Requires -Version 5.1
<#
.SYNOPSIS
  Map the phone Exports folder as a Windows drive letter via WebDAV (read-only).

.DESCRIPTION
  Loop Segments serves Documents/Exports on port 8765 (HTTP + WebDAV).
  Windows needs WebClient + AuthForwardServerList for HTTP (not HTTPS) WebDAV.

.PARAMETER PhoneHost
  iPhone LAN IPv4. Default: loop-segments-lan-host.txt

.PARAMETER DriveLetter
  Drive letter without colon (default L).

.PARAMETER Port
  LAN port (default 8765).

.PARAMETER Remove
  Disconnect the mapped drive.

.PARAMETER ConfigureWebClient
  Admin: BasicAuthLevel, FileSizeLimitInBytes, AuthForwardServerList, restart WebClient.

.PARAMETER TestOnly
  Ping HTTP + PROPFIND; do not map a drive.

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
  .\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient
  .\Map-LoopSegmentsWebDAV.ps1
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = 'L',
    [int] $Port = 8765,
    [switch] $Remove,
    [switch] $ConfigureWebClient,
    [switch] $TestOnly
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
    param([string] $AuthForwardHost)

    $wc = Get-Service -Name WebClient -ErrorAction SilentlyContinue
    if (-not $wc) {
        throw 'WebClient service not found. Use Sync-FromPhoneLAN.ps1 -Watch instead of drive mapping.'
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

  # Required for http:// (non-TLS) WebDAV — hostname only, no port.
    $existing = @()
    $prop = Get-ItemProperty -Path $paramsPath -Name AuthForwardServerList -ErrorAction SilentlyContinue
    if ($null -ne $prop -and $null -ne $prop.AuthForwardServerList) {
        $existing = @($prop.AuthForwardServerList) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    if ($existing -notcontains $AuthForwardHost) {
        $merged = @($existing + $AuthForwardHost)
        Set-ItemProperty -Path $paramsPath -Name AuthForwardServerList -Type MultiString -Value $merged
        Write-Host "AuthForwardServerList: $($merged -join ', ')"
    }

    Restart-Service -Name WebClient -Force
    Write-Host 'WebClient restarted (BasicAuthLevel=2, large files, AuthForwardServerList).'
}

function Test-LoopSegmentsWebDAV {
    param(
        [string] $RootUrl,
        [string] $HostIp
    )

    Write-Host "Testing $RootUrl ..."
    try {
        $get = Invoke-WebRequest -Uri $RootUrl -UseBasicParsing -TimeoutSec 8
        Write-Host "  GET $($get.StatusCode) OK"
    } catch {
        throw "HTTP GET failed — phone unreachable or Serve Exports off. $($_.Exception.Message)"
    }

    try {
        $req = [System.Net.HttpWebRequest]::Create($RootUrl)
        $req.Method = 'PROPFIND'
        $req.Timeout = 15000
        $req.Headers.Add('Depth', '1')
        $req.ContentLength = 0
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $resp.Close()
        if ($status -ne 207) {
            throw "PROPFIND returned $status (expected 207). Install app build 146+ with WebDAV."
        }
        Write-Host '  PROPFIND 207 Multi-Status OK'
    } catch {
        throw "WebDAV PROPFIND failed — update Loop Segments on phone (build 146+). $($_.Exception.Message)"
    }

    if (-not (Test-Connection -ComputerName $HostIp -Count 1 -Quiet)) {
        Write-Warning "Ping to $HostIp failed (WebDAV may still work)."
    }
}

function Invoke-LoopSegmentsNetUse {
    param(
        [string] $Drive,
        [string] $RootUrl,
        [string] $HostIp,
        [int] $Port
    )

    $uncRoot = "\\${HostIp}@${Port}\DavWWWRoot\"
    $commands = @(
        "net use $Drive `"$RootUrl`" /persistent:no /user:anonymous `"`"",
        "net use $Drive `"$RootUrl`" /persistent:no",
        "net use $Drive `"$uncRoot`" /persistent:no"
    )
    $labels = @('http + anonymous', 'http URL only', 'DavWWWRoot UNC')

    for ($i = 0; $i -lt $commands.Count; $i++) {
        Write-Host "Trying net use ($($labels[$i])) ..."
        cmd /c $commands[$i] 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$rootUrl = "http://${hostIp}:${Port}/"
$drive = "${DriveLetter}:"

if ($Remove) {
    cmd /c "net use $drive /delete /y" 2>$null | Out-Null
    Write-Host "Disconnected $drive (if it was mapped)."
    return
}

if ($ConfigureWebClient) {
    Enable-LoopSegmentsWebClientHTTP -AuthForwardHost $hostIp
    if (-not $TestOnly) {
        Write-Host 'Registry updated. Run .\Map-LoopSegmentsWebDAV.ps1 (without -ConfigureWebClient) to map the drive.'
    }
}

Test-LoopSegmentsWebDAV -RootUrl $rootUrl -HostIp $hostIp

if ($TestOnly) {
    Write-Host 'WebDAV test passed. Run without -TestOnly to map a drive.'
    return
}

if (-not $ConfigureWebClient) {
    $paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
    $prop = Get-ItemProperty -Path $paramsPath -Name AuthForwardServerList -ErrorAction SilentlyContinue
    $listed = @()
    if ($null -ne $prop -and $null -ne $prop.AuthForwardServerList) {
        $listed = @($prop.AuthForwardServerList)
    }
    if ($listed -notcontains $hostIp) {
        Write-Host ''
        Write-Host "AuthForwardServerList does not include $hostIp (required for http:// WebDAV)."
        Write-Host 'Run once as Administrator:'
        Write-Host "  .\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient -PhoneHost $hostIp"
        Write-Host ''
    }
}

$existing = cmd /c "net use $drive" 2>$null
if ($LASTEXITCODE -eq 0) {
    cmd /c "net use $drive /delete /y" | Out-Null
}

Write-Host "Mapping $drive -> $rootUrl (phone app open, Serve Exports on)."
if (-not (Invoke-LoopSegmentsNetUse -Drive $drive -RootUrl $rootUrl -HostIp $hostIp -Port $Port)) {
    Write-Host ''
    Write-Host 'net use failed (system error 67 / network connection could not be found is common).'
    Write-Host 'Checklist:'
    Write-Host "  1. Phone IP: $hostIp (export screen LAN URL)"
    Write-Host '  2. Loop Segments open, Serve Exports on Wi-Fi enabled'
    Write-Host '  3. Same Wi-Fi; try: .\Map-LoopSegmentsWebDAV.ps1 -TestOnly'
    Write-Host '  4. Admin once: .\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient'
    Write-Host '  5. For DLNA copy without drive mapping: .\Sync-FromPhoneLAN.ps1 -Watch'
    exit 1
}

Write-Host "Open ${drive}\ in Explorer. Prefer op_00.mp4 over _export_source_working.mp4."
