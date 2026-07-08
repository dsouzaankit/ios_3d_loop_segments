#Requires -Version 5.1
<#
.SYNOPSIS
  Pool LAN media listings from multiple Loop Segments iPhones into one JSON or HTML view.

.DESCRIPTION
  Each iPhone serves /status_lists.json on port 8765. This script queries every configured
  phoneLanHosts entry (or legacy phoneLanHost), merges playback/log rows, and rewrites links
  to absolute http://<phone-ip>:8765/... URLs.

.PARAMETER PhoneHost
  One or more phone IPs (comma/space separated). Overrides loop-segments-windows.json.

.PARAMETER Format
  json (default), html, or both (html to stdout after json when piping is awkward — use -OutFile instead).

.PARAMETER OutFile
  Write output to this path (.json or .html inferred from extension).

.EXAMPLE
  .\Get-LoopSegmentsUnifiedLANListing.ps1

.EXAMPLE
  .\Get-LoopSegmentsUnifiedLANListing.ps1 -PhoneHost 192.168.1.42,192.168.1.43 -Format html -OutFile unified-lan.html

.EXAMPLE
  .\Get-LoopSegmentsUnifiedLANListing.ps1 | ConvertFrom-Json | Select-Object -ExpandProperty files
#>
[CmdletBinding()]
param(
    [string[]] $PhoneHost = @(),
    [ValidateSet('json', 'html', 'both')]
    [string] $Format = 'json',
    [string] $OutFile = '',
    [int] $Port = 0,
    [int] $TimeoutSec = 15
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Windows.ps1"

$listing = Get-LoopSegmentsUnifiedLANListing -PhoneHost $PhoneHost -Port $Port -TimeoutSec $TimeoutSec
$html = ConvertTo-LoopSegmentsUnifiedLANHtml -Listing $listing
$json = $listing | ConvertTo-Json -Depth 8

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $ext = [System.IO.Path]::GetExtension($OutFile).ToLowerInvariant()
    if ($ext -eq '.html' -or $ext -eq '.htm') {
        Set-Content -LiteralPath $OutFile -Value $html -Encoding UTF8
        Write-Host "Wrote HTML: $OutFile ($($listing.reachableCount)/$($listing.deviceCount) reachable, $($listing.files.Count) file row(s))"
    } else {
        Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8
        Write-Host "Wrote JSON: $OutFile ($($listing.reachableCount)/$($listing.deviceCount) reachable, $($listing.files.Count) file row(s))"
    }
    exit 0
}

switch ($Format) {
    'html' {
        Write-Output $html
    }
    'both' {
        Write-Output $json
        Write-Output ''
        Write-Output '--- HTML ---'
        Write-Output $html
    }
    default {
        Write-Output $json
    }
}
