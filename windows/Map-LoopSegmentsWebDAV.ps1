#Requires -Version 5.1
<#
.SYNOPSIS
  Map the phone Exports folder as a Windows drive letter via WebDAV (read-only).

.PARAMETER ConfigureWebClient
  Admin: registry + WebClient restart + connectivity test (does not map a drive).

.PARAMETER TestOnly
  HTTP + PROPFIND test only.

.PARAMETER ViaPort80Proxy
  Admin: forward this PC's LAN IP:80 -> phone:8765, then net use http://<pc-lan-ip>/
  (Windows WebClient usually cannot map http://phone:8765/ — error 67).

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

function Set-AuthForwardServerListHosts {
    param(
        [string[]] $Hosts,
        [switch] $Merge
    )

    $paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
    if (-not (Test-Path -LiteralPath $paramsPath)) {
        New-Item -Path $paramsPath -Force | Out-Null
    }

    $clean = [System.Collections.Generic.List[string]]::new()
    if ($Merge) {
        $prop = Get-ItemProperty -Path $paramsPath -Name AuthForwardServerList -ErrorAction SilentlyContinue
        if ($null -ne $prop -and $null -ne $prop.AuthForwardServerList) {
            foreach ($entry in @($prop.AuthForwardServerList)) {
                $t = [string]$entry
                if (-not [string]::IsNullOrWhiteSpace($t) -and -not $clean.Contains($t)) {
                    $clean.Add($t)
                }
            }
        }
    }

    foreach ($h in $Hosts) {
        $t = $h.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if (-not $clean.Contains($t)) {
            $clean.Add($t)
        }
    }

    $array = $clean.ToArray()
    Set-ItemProperty -Path $paramsPath -Name AuthForwardServerList -Type MultiString -Value $array
    Write-Host ("AuthForwardServerList: " + ($array -join ', '))
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
    Set-AuthForwardServerListHosts -Hosts $AuthForwardHosts
    Restart-Service -Name WebClient -Force
    Write-Host 'WebClient restarted.'
}

function Test-LoopSegmentsWebDAVRootForNetUse {
    param([string] $RootUrl)

    try {
        $req = [System.Net.HttpWebRequest]::Create($RootUrl)
        $req.Method = 'GET'
        $req.Timeout = 15000
        $req.UserAgent = 'Microsoft-WebDAV-MiniRedir/1.1'
        $req.Headers.Add('Translate', 'f')
        $req.Accept = '*/*'
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $ctype = $resp.ContentType
        $resp.Close()
        if ($ctype -like '*html*') {
            return $false
        }
        if ($status -eq 403 -or $status -eq 404 -or $status -eq 405) {
            return $true
        }
        return $true
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($null -ne $r) {
            $code = [int]$r.StatusCode
            $r.Close()
            if ($code -eq 403 -or $code -eq 404 -or $code -eq 405) {
                return $true
            }
        }
        return $false
    }
}

function Test-LoopSegmentsWebDAV {
    param(
        [string] $RootUrl,
        [string] $HostIp,
        [switch] $RequireWebDAVRootNotHtml
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

    $null = Test-LoopSegmentsWebDAVDavWWWRoot -RootUrl $RootUrl

    if (Test-LoopSegmentsWebDAVRootForNetUse -RootUrl $RootUrl) {
        Write-Host '  GET / as WebDAV client OK (not HTML — safe for net use)'
    } else {
        $msg = @(
            'GET / returned HTML to WebDAV client — Windows net use will fail.',
            'Install Loop Segments build 153+ on the phone (GitHub Actions → LoopSegments-ipa), then run:',
            '  .\Map-LoopSegmentsWebDAV.ps1 -TestOnly',
            'Until then use: .\Sync-FromPhoneLAN.ps1 -Watch  (same LAN server, no drive letter).'
        ) -join [Environment]::NewLine
        if ($RequireWebDAVRootNotHtml) {
            throw $msg
        }
        Write-Warning $msg
    }
}

function Get-LoopSegmentsPCLanIPv4 {
    param([string] $PreferSameSubnetAs = '')

    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' -and $_.PrefixOrigin -ne 'WellKnown'
        })
    if ($PreferSameSubnetAs -match '^(\d+\.\d+\.\d+)\.\d+$') {
        $prefix = $Matches[1]
        $same = @($addrs | Where-Object { $_.IPAddress -like "$prefix.*" })
        if ($same.Count -gt 0) {
            return $same[0].IPAddress
        }
    }
    if ($addrs.Count -eq 0) {
        throw 'No LAN IPv4 on this PC — cannot create port-80 WebDAV proxy.'
    }
    return $addrs[0].IPAddress
}

function Enable-LoopSegmentsPort80Proxy {
    param(
        [string] $ListenAddress,
        [string] $PhoneHost,
        [int] $PhonePort
    )

    $listenPort = 80
    $inUse = Get-NetTCPConnection -LocalAddress $ListenAddress -LocalPort $listenPort -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        throw "Port $listenPort is already in use on $ListenAddress. Stop IIS/WAMP or use another PC NIC IP."
    }
    netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$listenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$listenPort connectaddress=$PhoneHost connectport=$PhonePort | Out-Null
    Write-Host "Port proxy: ${ListenAddress}:$listenPort -> ${PhoneHost}:$PhonePort (map WebDAV to http://${ListenAddress}/)"
}

function Remove-LoopSegmentsPort80Proxy {
    param(
        [string] $ListenAddress,
        [string] $PhoneHost,
        [int] $PhonePort
    )
    if ($ListenAddress) {
        netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=80 connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
    }
    netsh interface portproxy delete v4tov4 listenport=80 connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
}

function Test-LoopSegmentsWebDAVDavWWWRoot {
    param([string] $RootUrl)

    $base = $RootUrl.TrimEnd('/')
    $url = "$base/DavWWWRoot/"
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'PROPFIND'
        $req.Timeout = 15000
        $req.Headers.Add('Depth', '0')
        $req.ContentLength = 0
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $resp.Close()
        if ($status -eq 207) {
            Write-Host "  PROPFIND $url -> 207 OK (Windows DavWWWRoot path)"
            return $true
        }
        Write-Warning "  PROPFIND $url -> $status (expected 207 for net use)"
        return $false
    } catch {
        Write-Warning "  PROPFIND DavWWWRoot failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-LoopSegmentsNetUse {
    param(
        [string] $Drive,
        [string] $RootUrl,
        [string] $HostIp,
        [int] $Port
    )

    $root = $RootUrl.TrimEnd('/')
    $commands = [System.Collections.Generic.List[hashtable]]::new()
    $commands.Add(@{ Label = 'UNC \\host@port\DavWWWRoot\'; Cmd = "net use $Drive `"\\${HostIp}@${Port}\DavWWWRoot\`" /persistent:no" })
    if ($Port -eq 80) {
        $commands.Add(@{ Label = 'UNC \\host\DavWWWRoot\ (port 80)'; Cmd = "net use $Drive `"\\${HostIp}\DavWWWRoot\`" /persistent:no" })
    }
    $commands.Add(@{ Label = 'http .../DavWWWRoot/'; Cmd = "net use $Drive `"$root/DavWWWRoot/`" /persistent:no" })
    $commands.Add(@{ Label = 'http root URL'; Cmd = "net use $Drive `"$RootUrl`" /persistent:no" })
    $commands.Add(@{ Label = 'http empty credentials'; Cmd = "net use $Drive `"$RootUrl`" /persistent:no `"`" `"`"" })
    $commands.Add(@{ Label = 'http + anonymous'; Cmd = "net use $Drive `"$RootUrl`" /persistent:no /user:anonymous `"`"" })

    foreach ($attempt in $commands) {
        Write-Host "Trying net use ($($attempt.Label)) ..."
        $out = cmd /c $attempt.Cmd 2>&1 | Out-String
        if ($out.Trim()) { Write-Host $out.TrimEnd() }
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$rootUrl = "http://${hostIp}:${Port}/"
$drive = "${DriveLetter}:"
$script:Port80ListenAddress = $null

if ($Remove) {
    cmd /c "net use $drive /delete /y" 2>$null | Out-Null
    Remove-LoopSegmentsPort80Proxy -ListenAddress $script:Port80ListenAddress -PhoneHost $hostIp -PhonePort $Port
    Write-Host "Disconnected $drive (if mapped). Port 80 proxy removed if present."
    return
}

if ($ConfigureWebClient) {
    # Replace list (fixes corrupted single-string entries like 10.0.0.10127.0.0.1).
    Enable-LoopSegmentsWebClientHTTP -AuthForwardHosts @($hostIp)
    Test-LoopSegmentsWebDAV -RootUrl $rootUrl -HostIp $hostIp
    Write-Host ''
    Write-Host 'Configure done.'
    Write-Host 'Map (often fails on :8765 — WebClient wants port 80):'
    Write-Host '  .\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy   # admin — recommended'
    Write-Host 'Or skip drive letter: .\Sync-FromPhoneLAN.ps1 -Watch'
    return
}

if ($ViaPort80Proxy) {
    $script:Port80ListenAddress = Get-LoopSegmentsPCLanIPv4 -PreferSameSubnetAs $hostIp
    Enable-LoopSegmentsWebClientHTTP -AuthForwardHosts @($hostIp, $script:Port80ListenAddress)
    Enable-LoopSegmentsPort80Proxy -ListenAddress $script:Port80ListenAddress -PhoneHost $hostIp -PhonePort $Port
    $rootUrl = "http://$($script:Port80ListenAddress)/"
    Write-Host "WebDAV URL for net use: $rootUrl (port 80 on this PC -> phone :$Port)"
}

if ($TestOnly) {
    Test-LoopSegmentsWebDAV -RootUrl "http://${hostIp}:${Port}/" -HostIp $hostIp
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

$mapHostIp = if ($ViaPort80Proxy) { $script:Port80ListenAddress } else { $hostIp }
$mapPort = if ($ViaPort80Proxy) { 80 } else { $Port }

$existing = cmd /c "net use $drive" 2>$null
if ($LASTEXITCODE -eq 0) {
    cmd /c "net use $drive /delete /y" | Out-Null
}

if (-not (Test-LoopSegmentsWebDAVRootForNetUse -RootUrl $rootUrl)) {
    Write-Host ''
    Write-Host 'Skipping net use — phone must be build 153+ (GET / returns HTML on your current app).'
    Write-Host 'PROPFIND 207 only means the server is up; it does not mean drive mapping will work.'
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host '  1. Sideload LoopSegments-ipa build 153+ from GitHub Actions'
    Write-Host '  2. .\Map-LoopSegmentsWebDAV.ps1 -TestOnly   (expect: GET / as WebDAV client OK)'
    Write-Host '  3. .\Map-LoopSegmentsWebDAV.ps1'
    Write-Host ''
    Write-Host 'Works today without mapping:'
    Write-Host '  .\Sync-FromPhoneLAN.ps1 -Watch'
    exit 1
}

Write-Host "Mapping $drive -> $rootUrl (phone app open, Serve Exports on)."
if ($ViaPort80Proxy) {
    Test-LoopSegmentsWebDAV -RootUrl $rootUrl -HostIp $mapHostIp | Out-Null
} else {
    Test-LoopSegmentsWebDAV -RootUrl "http://${hostIp}:${Port}/" -HostIp $hostIp | Out-Null
    Write-Host ''
    Write-Host 'Note: -TestOnly can pass while net use still fails — Windows WebClient often refuses port 8765 (error 67).'
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mapped = Invoke-LoopSegmentsNetUse -Drive $drive -RootUrl $rootUrl -HostIp $mapHostIp -Port $mapPort
$ErrorActionPreference = $prevEap

if (-not $mapped) {
    Write-Host ''
    Write-Host 'net use failed. Your -TestOnly passed — the phone server is OK; Windows WebClient is the problem.'
    if (-not $ViaPort80Proxy -and $Port -ne 80) {
        Write-Host ''
        Write-Host 'Error 67 on http://<phone>:8765/ is common: WebClient expects port 80.'
        Write-Host 'Run PowerShell as Administrator:'
        Write-Host '  .\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy'
    }
    Write-Host ''
    Write-Host 'Or skip mapping:'
    Write-Host '  .\Sync-FromPhoneLAN.ps1 -Watch'
    if ($ViaPort80Proxy) {
        Remove-LoopSegmentsPort80Proxy -ListenAddress $script:Port80ListenAddress -PhoneHost $hostIp -PhonePort $Port
    }
    exit 1
}

Write-Host "Open ${drive}\ in Explorer. Prefer op_00.mp4 over _export_source_working.mp4."
