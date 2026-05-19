#Requires -Version 5.1
<#
.SYNOPSIS
  Map the phone Exports folder as a Windows drive letter via WebDAV (read-only).

.PARAMETER ConfigureWebClient
  Admin: registry + WebClient restart + connectivity test (does not map a drive).

.PARAMETER TestOnly
  HTTP + PROPFIND test only.

.PARAMETER ViaPort80Proxy
  Admin: forward localhost:80 -> phone:8765, then net use http://127.0.0.1/
  (Windows WebDAV often rejects non-standard ports like 8765).

.EXAMPLE
  .\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient
  .\Map-LoopSegmentsWebDAV.ps1 -TestOnly
  .\Map-LoopSegmentsWebDAV.ps1
  .\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = 'L',
    [int] $Port = 8765,
    [switch] $Remove,
    [switch] $ConfigureWebClient,
    [switch] $TestOnly,
    [switch] $ViaPort80Proxy
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

function Add-AuthForwardServerListHost {
    param([string[]] $Hosts)

    $paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
    if (-not (Test-Path -LiteralPath $paramsPath)) {
        New-Item -Path $paramsPath -Force | Out-Null
    }
    $existing = @()
    $prop = Get-ItemProperty -Path $paramsPath -Name AuthForwardServerList -ErrorAction SilentlyContinue
    if ($null -ne $prop -and $null -ne $prop.AuthForwardServerList) {
        $existing = @($prop.AuthForwardServerList) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    $merged = $existing
    foreach ($h in $Hosts) {
        if ($merged -notcontains $h) {
            $merged += $h
        }
    }
    Set-ItemProperty -Path $paramsPath -Name AuthForwardServerList -Type MultiString -Value $merged
    Write-Host "AuthForwardServerList: $($merged -join ', ')"
}

function Enable-LoopSegmentsWebClientHTTP {
    param([string[]] $AuthForwardHosts)

    $wc = Get-Service -Name WebClient -ErrorAction SilentlyContinue
    if (-not $wc) {
        throw 'WebClient service not found. Use Sync-FromPhoneLAN.ps1 -Watch instead.'
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
    Add-AuthForwardServerListHost -Hosts $AuthForwardHosts
    Restart-Service -Name WebClient -Force
    Write-Host 'WebClient restarted.'
}

function Test-LoopSegmentsWebDAV {
    param(
        [string] $RootUrl,
        [string] $HostIp
    )

    Write-Host "Testing $RootUrl ..."
    try {
        $get = Invoke-WebRequest -Uri $RootUrl -UseBasicParsing -TimeoutSec 8
        Write-Host "  GET (browser) $($get.StatusCode) OK"
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
            throw "PROPFIND returned $status (expected 207). Use app build 152+ for Windows WebDAV fixes."
        }
        Write-Host '  PROPFIND 207 Multi-Status OK'
    } catch {
        throw "WebDAV PROPFIND failed. $($_.Exception.Message)"
    }

    try {
        $req = [System.Net.HttpWebRequest]::Create($RootUrl)
        $req.Method = 'GET'
        $req.Timeout = 15000
        $req.UserAgent = 'Microsoft-WebDAV-MiniRedir/1.1'
        $req.Headers.Add('Translate', 'f')
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $ctype = $resp.ContentType
        $resp.Close()
        if ($ctype -like '*html*') {
            throw "GET / returned HTML to WebDAV client (build 152+ returns 403 instead — update the app)."
        }
        Write-Host "  GET / as WebDAV client $status ($ctype) OK"
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($null -ne $r) {
            $code = [int]$r.StatusCode
            $r.Close()
            if ($code -eq 403 -or $code -eq 404 -or $code -eq 405) {
                Write-Host "  GET / as WebDAV client $code OK (not HTML)"
                return
            }
        }
        throw "WebDAV GET / check failed. $($_.Exception.Message)"
    }
}

function Enable-LoopSegmentsPort80Proxy {
    param(
        [string] $PhoneHost,
        [int] $PhonePort
    )

    $listenPort = 80
    $inUse = Get-NetTCPConnection -LocalPort $listenPort -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        throw "Port $listenPort is already in use. Stop IIS/other service or skip -ViaPort80Proxy."
    }
    netsh interface portproxy delete v4tov4 listenport=$listenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
    netsh interface portproxy add v4tov4 listenport=$listenPort connectaddress=$PhoneHost connectport=$PhonePort | Out-Null
    Write-Host "Port proxy: 127.0.0.1:$listenPort -> ${PhoneHost}:$PhonePort"
}

function Remove-LoopSegmentsPort80Proxy {
    param(
        [string] $PhoneHost,
        [int] $PhonePort
    )
    netsh interface portproxy delete v4tov4 listenport=80 connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
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
        @{ Label = 'DavWWWRoot UNC'; Cmd = "net use $Drive `"$uncRoot`" /persistent:no" },
        @{ Label = 'http + anonymous'; Cmd = "net use $Drive `"$RootUrl`" /persistent:no /user:anonymous `"`"" },
        @{ Label = 'http URL only'; Cmd = "net use $Drive `"$RootUrl`" /persistent:no" }
    )

    foreach ($attempt in $commands) {
        Write-Host "Trying net use ($($attempt.Label)) ..."
        cmd /c $attempt.Cmd 2>&1 | ForEach-Object { Write-Host $_ }
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
    Remove-LoopSegmentsPort80Proxy -PhoneHost $hostIp -PhonePort $Port
    Write-Host "Disconnected $drive (if mapped). Port 80 proxy removed if present."
    return
}

$authHosts = @($hostIp, '127.0.0.1')

if ($ConfigureWebClient) {
    Enable-LoopSegmentsWebClientHTTP -AuthForwardHosts $authHosts
    Test-LoopSegmentsWebDAV -RootUrl $rootUrl -HostIp $hostIp
    Write-Host ''
    Write-Host 'Configure done. Map drive: .\Map-LoopSegmentsWebDAV.ps1'
    Write-Host 'If net use fails on port 8765, try: .\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy'
    return
}

if ($ViaPort80Proxy) {
    Enable-LoopSegmentsWebClientHTTP -AuthForwardHosts $authHosts
    Enable-LoopSegmentsPort80Proxy -PhoneHost $hostIp -PhonePort $Port
    $rootUrl = 'http://127.0.0.1/'
    Write-Host 'Using http://127.0.0.1/ via port 80 proxy (WebClient-friendly).'
}

Test-LoopSegmentsWebDAV -RootUrl $(if ($ViaPort80Proxy) { "http://${hostIp}:${Port}/" } else { $rootUrl }) -HostIp $hostIp

if ($TestOnly) {
    Write-Host 'WebDAV test passed.'
    return
}

$paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
$prop = Get-ItemProperty -Path $paramsPath -Name AuthForwardServerList -ErrorAction SilentlyContinue
$listed = @()
if ($null -ne $prop -and $null -ne $prop.AuthForwardServerList) {
    $listed = @($prop.AuthForwardServerList)
}
if ($listed -notcontains $hostIp) {
    Write-Warning "Run as admin: .\Map-LoopSegmentsWebDAV.ps1 -ConfigureWebClient"
}

$mapHostIp = if ($ViaPort80Proxy) { '127.0.0.1' } else { $hostIp }
$mapPort = if ($ViaPort80Proxy) { 80 } else { $Port }

$existing = cmd /c "net use $drive" 2>$null
if ($LASTEXITCODE -eq 0) {
    cmd /c "net use $drive /delete /y" | Out-Null
}

Write-Host "Mapping $drive -> $rootUrl (phone app open, Serve Exports on)."
if (-not (Invoke-LoopSegmentsNetUse -Drive $drive -RootUrl $rootUrl -HostIp $mapHostIp -Port $mapPort)) {
    Write-Host ''
    Write-Host 'net use failed. PROPFIND 207 only proves the phone server — Windows WebClient is picky.'
    Write-Host 'Try:'
    Write-Host '  1. App build 152+ (GET / must not return HTML to WebDAV clients)'
    Write-Host '  2. .\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy   (admin; maps via localhost:80)'
    Write-Host '  3. .\Sync-FromPhoneLAN.ps1 -Watch   (recommended; no drive letter)'
    if ($ViaPort80Proxy) {
        Remove-LoopSegmentsPort80Proxy -PhoneHost $hostIp -PhonePort $Port
    }
    exit 1
}

Write-Host "Open ${drive}\ in Explorer. Prefer op_00.mp4 over _export_source_working.mp4."
