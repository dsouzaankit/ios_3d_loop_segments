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

.PARAMETER Remove
  Admin: unmap drive letter and delete portproxy rules to the phone (safe if nothing mapped).

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
    [switch] $ViaPort80Proxy,
    [int] $ProxyListenPort = 80,
    [switch] $SkipPort80Check
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

function Add-LoopSegmentsLANWebDAVAuthHeader {
    param(
        $Request,
        [string] $User = 'admin',
        [string] $Password = 'iosadmin'
    )
    $bytes = [Text.Encoding]::ASCII.GetBytes("${User}:${Password}")
    $Request.Headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String($bytes)
}

function Test-LoopSegmentsLANMp4MoovInHead {
    param(
        [string] $FileUrl,
        [int] $ScanBytes = 786432
    )

    $req = [System.Net.HttpWebRequest]::Create($FileUrl)
    $req.Method = 'GET'
    $req.AddRange(0, [Math]::Max(0, $ScanBytes - 1))
    $req.Timeout = 30000
    $req.UserAgent = 'Skybox-Test/1.0'
    $resp = $req.GetResponse()
    $stream = $resp.GetResponseStream()
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    while ($ms.Length -lt $ScanBytes) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
    }
    $stream.Close()
    $resp.Close()
    $bytes = $ms.ToArray()
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    return $text.Contains('moov')
}

function Test-LoopSegmentsWebDAVMediaGet {
    param([string] $RootUrl)

    $segmentName = 'op_00.mp4'
    try {
        $status = Invoke-RestMethod -Uri ($RootUrl.TrimEnd('/') + '/status.json') -TimeoutSec 8
        $mp4 = @($status.files | Where-Object { $_.name -like 'op_*.mp4' } | Select-Object -First 1)
        if ($mp4.name) { $segmentName = $mp4.name }
    } catch {}

    $base = $RootUrl.TrimEnd('/')
    $absoluteUri = "$base/$segmentName"
    try {
        $req = [System.Net.HttpWebRequest]::Create($absoluteUri)
        $req.Method = 'GET'
        $req.Timeout = 20000
        $req.UserAgent = 'Skybox VR Player'
        $req.AddRange(0, 1)
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $acceptRanges = $resp.Headers['Accept-Ranges']
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 4
        $read = $stream.Read($buf, 0, $buf.Length)
        $stream.Close()
        $resp.Close()
        if ($status -notin 200, 206) {
            throw "GET absolute URI (no auth) returned $status (expected 200 or 206)."
        }
        if ($read -lt 1) {
            throw 'GET returned no bytes — export may not have written a segment yet.'
        }
        Write-Host "  GET $segmentName (Skybox URI, no auth, Range) $status OK (Accept-Ranges=$acceptRanges)"
        if (Test-LoopSegmentsLANMp4MoovInHead -FileUrl $absoluteUri) {
            Write-Host "  moov atom in first 768 KB — Skybox-friendly faststart"
        } else {
            Write-Warning "  moov not in file head — normal for stream-copy segments; browser/Pigasus use Range. Install build 173+ if op_00 won't play."
        }
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($null -ne $r) {
            $code = [int]$r.StatusCode
            $r.Close()
            if ($code -eq 404) {
                Write-Warning "  GET $segmentName -> 404 — start export on phone so op_00.mp4 exists, then retry."
                return
            }
            if ($code -eq 401) {
                throw "GET $segmentName returned 401 — media GET must not require auth (build 171+)."
            }
        }
        throw "Skybox-style media GET failed. $($_.Exception.Message)"
    }
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
        Add-LoopSegmentsLANWebDAVAuthHeader -Request $req
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $ctype = $resp.ContentType
        $resp.Close()
        if ($ctype -like '*html*') {
            return $false
        }
        if ($status -eq 200 -and $ctype -like '*xml*') {
            Write-Host '  GET / as WebDAV client OK (200 XML with Basic auth)'
            return $true
        }
        if ($status -eq 403 -or $status -eq 404 -or $status -eq 405) {
            return $true
        }
        Write-Warning "  GET / WebDAV returned $status ($ctype) — expected 200 XML"
        return $false
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($null -ne $r) {
            $code = [int]$r.StatusCode
            $r.Close()
            if ($code -eq 401) {
                Write-Warning '  GET / WebDAV returned 401 — phone may be older than build 169; upgrade IPA or use Sync-FromPhoneLAN.ps1'
                return $false
            }
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
        $opt = [System.Net.HttpWebRequest]::Create($RootUrl)
        $opt.Method = 'OPTIONS'
        $opt.Timeout = 15000
        Add-LoopSegmentsLANWebDAVAuthHeader -Request $opt
        $optResp = $opt.GetResponse()
        $optStatus = [int]$optResp.StatusCode
        $optResp.Close()
        if ($optStatus -ne 200) {
            throw "OPTIONS returned $optStatus (expected 200)."
        }
        Write-Host '  OPTIONS 200 OK (with Basic auth)'
    } catch {
        throw "WebDAV OPTIONS failed. $($_.Exception.Message)"
    }

    try {
        $req = [System.Net.HttpWebRequest]::Create($RootUrl)
        $req.Method = 'PROPFIND'
        $req.Timeout = 15000
        $req.Headers.Add('Depth', '1')
        $req.UserAgent = 'Skybox-Test/1.0'
        Add-LoopSegmentsLANWebDAVAuthHeader -Request $req
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

    Test-LoopSegmentsWebDAVMediaGet -RootUrl $RootUrl

    if (-not (Test-LoopSegmentsWebDAVRootForNetUse -RootUrl $RootUrl)) {
        $msg = @(
            'GET / as WebDAV client failed (need 200 XML with admin/iosadmin — build 169+ on phone).',
            'Skybox/Windows WebDAV still need the IPA from GitHub Actions ios-build.',
            'Until drive mapping works: .\Sync-FromPhoneLAN.ps1 -Watch'
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

function Get-LoopSegmentsPortListeners {
    param([int] $Port)

    $rows = @()
    foreach ($c in Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port }) {
        $procName = 'unknown'
        try {
            $procName = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName
        } catch {}
        $rows += [PSCustomObject]@{
            LocalAddress = $c.LocalAddress
            Process      = $procName
            PID          = $c.OwningProcess
        }
    }
    return $rows | Sort-Object LocalAddress -Unique
}

function Show-Port80BlockedHelp {
    param([int] $Port, [string] $ListenAddress)

    Write-Host "Port $Port is in use (cannot add portproxy on $ListenAddress):"
    foreach ($row in Get-LoopSegmentsPortListeners -Port $Port) {
        Write-Host "  $($row.LocalAddress):$Port  PID $($row.PID)  ($($row.Process))"
    }
    Write-Host ''
    Write-Host 'Common fix (admin PowerShell) — free port 80 for the proxy:'
    Write-Host '  Stop-Service W3SVC -Force -ErrorAction SilentlyContinue   # IIS'
    Write-Host '  Stop-Service http -Force -ErrorAction SilentlyContinue    # HTTP.sys (if present)'
    Write-Host '  Get-Service W3SVC, WAS, WebClient'
    Write-Host ''
    Write-Host 'Or skip drive mapping (works with your passing -TestOnly):'
    Write-Host '  .\Sync-FromPhoneLAN.ps1 -Watch'
    Write-Host ''
    Write-Host 'After stopping IIS, run: .\Map-LoopSegmentsWebDAV.ps1 -ViaPort80Proxy'
}

function Enable-LoopSegmentsPort80Proxy {
    param(
        [string] $ListenAddress,
        [string] $PhoneHost,
        [int] $PhonePort,
        [int] $ListenPort = 80,
        [switch] $SkipPortCheck
    )

    if (-not $SkipPortCheck) {
        $onNic = Get-NetTCPConnection -LocalAddress $ListenAddress -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue
        $onAny = Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue
        if ($onNic -or ($ListenPort -eq 80 -and $onAny)) {
            Show-Port80BlockedHelp -Port $ListenPort -ListenAddress $ListenAddress
            throw "Port $ListenPort is already in use."
        }
    }

    netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$ListenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
    $add = netsh interface portproxy add v4tov4 listenaddress=$ListenAddress listenport=$ListenPort connectaddress=$PhoneHost connectport=$PhonePort 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "netsh portproxy failed: $add"
    }
    Write-Host "Port proxy: ${ListenAddress}:$ListenPort -> ${PhoneHost}:$PhonePort (map WebDAV to http://${ListenAddress}:$ListenPort/)"
}

function Remove-LoopSegmentsPort80Proxy {
    param(
        [string] $ListenAddress,
        [string] $PhoneHost,
        [int] $PhonePort,
        [int] $ListenPort = 80
    )
    if ($ListenAddress) {
        netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$ListenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
    }
    netsh interface portproxy delete v4tov4 listenport=$ListenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
}

function Remove-AllLoopSegmentsPortProxies {
    param(
        [string] $PhoneHost,
        [int] $PhonePort = 8765
    )

    $listenAddresses = @('0.0.0.0', '127.0.0.1')
    try {
        $pcIp = Get-LoopSegmentsPCLanIPv4 -PreferSameSubnetAs $PhoneHost
        if ($listenAddresses -notcontains $pcIp) {
            $listenAddresses += $pcIp
        }
    } catch {}

    foreach ($addr in $listenAddresses) {
        foreach ($listenPort in 80, 8080) {
            netsh interface portproxy delete v4tov4 listenaddress=$addr listenport=$listenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
            netsh interface portproxy delete v4tov4 listenport=$listenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
        }
    }
}

function Disconnect-LoopSegmentsMappedDrive {
    param([string] $Drive)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    cmd /c "net use $Drive /delete /y" 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -eq 0) {
        Write-Host "Disconnected $Drive"
    } else {
        Write-Host "No mapped drive $Drive (OK)"
    }
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
        Add-LoopSegmentsLANWebDAVAuthHeader -Request $req
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
$script:ProxyListenPort = 80

if ($Remove) {
    Disconnect-LoopSegmentsMappedDrive -Drive $drive
    Remove-AllLoopSegmentsPortProxies -PhoneHost $hostIp -PhonePort $Port
    Write-Host ''
    Write-Host "Port proxy cleanup done for phone ${hostIp}:$Port"
    Write-Host 'Remaining portproxy rules (should be empty or unrelated):'
    netsh interface portproxy show all
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
    $script:ProxyListenPort = $ProxyListenPort
    Enable-LoopSegmentsWebClientHTTP -AuthForwardHosts @($hostIp, $script:Port80ListenAddress)
    try {
        Enable-LoopSegmentsPort80Proxy -ListenAddress $script:Port80ListenAddress -PhoneHost $hostIp -PhonePort $Port -ListenPort $script:ProxyListenPort -SkipPortCheck:$SkipPort80Check
    } catch {
        if ($script:ProxyListenPort -eq 80 -and $ProxyListenPort -eq 80) {
            Write-Warning 'Retry with -ProxyListenPort 8080 (WebClient may still reject non-80; freeing port 80 is better).'
            $script:ProxyListenPort = 8080
            Enable-LoopSegmentsPort80Proxy -ListenAddress $script:Port80ListenAddress -PhoneHost $hostIp -PhonePort $Port -ListenPort 8080 -SkipPortCheck:$SkipPort80Check
        } else {
            throw
        }
    }
    $rootUrl = "http://$($script:Port80ListenAddress):$($script:ProxyListenPort)/"
    Write-Host "WebDAV URL for net use: $rootUrl (this PC -> phone :$Port)"
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
$mapPort = if ($ViaPort80Proxy) { $script:ProxyListenPort } else { $Port }

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
        Remove-LoopSegmentsPort80Proxy -ListenAddress $script:Port80ListenAddress -PhoneHost $hostIp -PhonePort $Port -ListenPort $script:ProxyListenPort
    }
    exit 1
}

Write-Host "Open ${drive}\ in Explorer. Prefer op_00.mp4 over _export_source_working.mp4."
