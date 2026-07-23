#Requires -Version 5.1
<#
.SYNOPSIS
  Serve a unified LAN media index page on this PC (pools all configured iPhones).

.DESCRIPTION
  Binds an HttpListener on the PC (default :8766). GET / serves HTML; GET /listing.json serves
  merged JSON from every phone in phoneLanHosts. Refresh the page to re-poll phones.

  Phones still serve their own media on :8765 — this PC page only aggregates listings/links.

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

    $listing = Get-LoopSegmentsUnifiedLANListing -PhoneHost $PhoneHost -Port $PhonePort -TimeoutSec $TimeoutSec
    $normalized = if ([string]::IsNullOrWhiteSpace($Path)) { '/' } else { $Path.Trim().TrimEnd('/').ToLowerInvariant() }
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
Write-Host '  http://127.0.0.1:'"$ListenPort/"
try {
    Write-Host "  http://$(Get-LoopSegmentsPCLanIPv4):$ListenPort/"
} catch {}
Write-Host 'Press Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            $payload = Get-UnifiedLANResponse -Path $request.Url.AbsolutePath
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload.Body)
            $response.StatusCode = 200
            $response.ContentType = $payload.ContentType
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            $message = $_.Exception.Message
            $bytes = [Text.Encoding]::UTF8.GetBytes($message)
            $response.StatusCode = 500
            $response.ContentType = 'text/plain; charset=utf-8'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $response.OutputStream.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
