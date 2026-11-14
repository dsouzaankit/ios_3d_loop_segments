#Requires -Version 7.0
<#
.SYNOPSIS
  Serve a unified LAN media index page on this PC (pools all configured iPhones).

.DESCRIPTION
  Binds an HttpListener on the PC (default :8766). GET / serves HTML; GET /listing.json serves
  merged JSON from every phone in phoneLanHosts. Refresh the page to re-poll phones.

  Phones still serve their own media on :8765 — this PC page only aggregates listings/links.

  The page shows what the phones keep behind their LAN login (export name, media and log lists),
  so every request must pass all of:
    - client address is loopback or private (10/8, 172.16/12, 192.168/16, 169.254/16)
    - Host header is an IP literal or localhost (no DNS names: blocks DNS rebinding)
    - HTTP Basic auth = the phone LAN login (webdavUser + webdavPassword, or a phoneLanHosts
      entry's webdavPassword); a failed login waits 1 s
  With no webdavPassword configured, every request is refused.

.PARAMETER ListenPort
  PC port for the unified index (default 8766).

.PARAMETER PhoneHost
  Optional override list instead of loop-segments-windows.json.

.EXAMPLE
  .\Serve-LoopSegmentsUnifiedLAN.ps1
  # Open http://<pc-ip>:8766/ on the LAN

.EXAMPLE
  .\Serve-LoopSegmentsUnifiedLAN.ps1 -ListenPort 9080 -RefreshSec 30
#>
[CmdletBinding()]
param(
    [int] $ListenPort = 8766,
    [string[]] $PhoneHost = @(),
    [int] $PhonePort = 0,
    [int] $RefreshSec = 0,
    [int] $TimeoutSec = 15
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"

if ($ListenPort -le 0 -or $ListenPort -gt 65535) {
    throw 'ListenPort must be 1-65535.'
}

function Get-UnifiedLANResponse {
    param([string] $Path)

    $normalized = if ([string]::IsNullOrWhiteSpace($Path)) { '/' } else { $Path.Trim().TrimEnd('/').ToLowerInvariant() }
    if ($normalized -eq '') { $normalized = '/' }
    # Only these two pages; anything else (favicon, typos) must not re-poll every phone.
    if ($normalized -ne '/' -and $normalized -ne '/index.html' -and $normalized -ne '/listing.json') {
        return @{ StatusCode = 404; ContentType = 'text/plain; charset=utf-8'; Body = 'Not found' }
    }
    $listing = Get-LoopSegmentsUnifiedLANListing -PhoneHost $PhoneHost -Port $PhonePort -TimeoutSec $TimeoutSec
    if ($normalized -eq '/listing.json') {
        return @{
            ContentType = 'application/json; charset=utf-8'
            Body        = ($listing | ConvertTo-Json -Depth 8)
        }
    }
    $html = ConvertTo-LoopSegmentsUnifiedLANHtml -Listing $listing
    if ($RefreshSec -gt 0) {
        $meta = "<meta http-equiv=`"refresh`" content=`"$RefreshSec`">"
        $html = $html -replace '(?i)<head>', "<head>`n  $meta"
    }
    return @{
        ContentType = 'text/html; charset=utf-8'
        Body        = $html
    }
}

$prefixes = @("http://+:$ListenPort/", "http://127.0.0.1:$ListenPort/", "http://localhost:$ListenPort/")
try {
    $pcIp = Get-LoopSegmentsPCLanIPv4
    $prefixes += "http://${pcIp}:$ListenPort/"
} catch {
    # PC may have no LAN IP yet
}

$listener = New-Object System.Net.HttpListener
foreach ($prefix in $prefixes) {
    if (-not $listener.Prefixes.Contains($prefix)) {
        $listener.Prefixes.Add($prefix)
    }
}

try {
    $listener.Start()
} catch {
    throw @"
Could not bind HttpListener on port $ListenPort.

  Run elevated once to allow the URL prefix:
    netsh http add urlacl url=http://+:$ListenPort/ user=$env:USERDOMAIN\$env:USERNAME

  Or try another -ListenPort.
  $($_.Exception.Message)
"@
}

Write-Host "Unified Loop Segments LAN index listening on port $ListenPort"
Write-Host "  http://127.0.0.1:$ListenPort/"
try {
    Write-Host "  http://$(Get-LoopSegmentsPCLanIPv4):$ListenPort/"
} catch {}
Write-Host 'Press Ctrl+C to stop.'

function Write-UnifiedLANResponse {
    param(
        [System.Net.HttpListenerResponse] $Response,
        [int] $StatusCode,
        [string] $ContentType,
        [string] $Body,
        [hashtable] $ExtraHeaders = @{}
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    foreach ($k in $ExtraHeaders.Keys) { $Response.Headers[$k] = [string]$ExtraHeaders[$k] }
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

if (-not (Get-LoopSegmentsWindowsSettings).webdavPassword) {
    Write-Warning 'webdavPassword is missing in windows\loop-segments-windows.json: every request will be refused (401).'
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            $remote = $request.RemoteEndPoint.Address
            if (-not (Test-LoopSegmentsPrivateLanAddress -Address $remote)) {
                Write-Host "Refused non-private client $remote"
                Write-UnifiedLANResponse -Response $response -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body 'Forbidden'
                continue
            }
            if (-not (Test-LoopSegmentsIpLiteralHostHeader -HostHeader $request.Headers['Host'])) {
                Write-UnifiedLANResponse -Response $response -StatusCode 400 -ContentType 'text/plain; charset=utf-8' -Body 'Use the IP address.'
                continue
            }
            $authHeader = $request.Headers['Authorization']
            if (-not (Test-LoopSegmentsPhoneLanBasicAuth -AuthorizationHeader $authHeader)) {
                if ($authHeader) {
                    Write-Host "Failed login from $remote"
                    Start-Sleep -Seconds 1
                }
                Write-UnifiedLANResponse -Response $response -StatusCode 401 -ContentType 'text/plain; charset=utf-8' -Body 'Login required: use the Loop Segments LAN login.' `
                    -ExtraHeaders @{ 'WWW-Authenticate' = 'Basic realm="Loop Segments unified LAN", charset="UTF-8"' }
                continue
            }
            if ($request.HttpMethod -ne 'GET' -and $request.HttpMethod -ne 'HEAD') {
                Write-UnifiedLANResponse -Response $response -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body 'GET only' -ExtraHeaders @{ Allow = 'GET, HEAD' }
                continue
            }
            $payload = Get-UnifiedLANResponse -Path $request.Url.AbsolutePath
            $status = if ($payload.ContainsKey('StatusCode')) { [int]$payload.StatusCode } else { 200 }
            Write-UnifiedLANResponse -Response $response -StatusCode $status -ContentType $payload.ContentType -Body $payload.Body
        } catch {
            # Details stay in this console; the client only learns that it failed.
            Write-Warning "Request failed: $($_.Exception.Message)"
            try {
                Write-UnifiedLANResponse -Response $response -StatusCode 500 -ContentType 'text/plain; charset=utf-8' -Body 'Internal error (see the PC console).'
            } catch {}
        } finally {
            try { $response.OutputStream.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
