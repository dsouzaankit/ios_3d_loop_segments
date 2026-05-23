#Requires -Version 5.1
<#
.SYNOPSIS
  PUT export_trigger.json on the phone LAN server (Export screen must be open with triggers enabled).

.PARAMETER PhoneHost
  iPhone LAN IP (or use loop-segments-windows.json).

.PARAMETER Command
  start_export | start_export_random | pause_export | stop_export

.PARAMETER Href
  pCloud WebDAV href for start_export (from Browse / PROPFIND).

.PARAMETER DisplayName
  File name for start_export.

.PARAMETER SeekMs
  Start position in ms (default 0).

.PARAMETER Pool
  same_folder | bookmarks — for start_export_random.

.EXAMPLE
  .\Send-LoopSegmentsExportTrigger.ps1 -PhoneHost 10.0.0.42 -Command start_export `
    -Href '/remote.php/dav/files/123/0/movie.mp4' -DisplayName 'movie.mp4'

.EXAMPLE
  .\Send-LoopSegmentsExportTrigger.ps1 -Command start_export_random -Pool bookmarks
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidateSet('start_export', 'start_export_random', 'pause_export', 'stop_export')]
    [string] $Command = 'start_export',
    [string] $Href = '',
    [string] $DisplayName = '',
    [long] $SeekMs = 0,
    [ValidateSet('same_folder', 'bookmarks', '')]
    [string] $Pool = '',
    [int] $Port = 0
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Windows.ps1"

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$portNum = Get-LoopSegmentsLanPort -Override $Port
$creds = Get-LoopSegmentsWebDAVCredentials
$pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($creds.User):$($creds.Password)"))
$headers = @{ Authorization = "Basic $pair" }

$body = [ordered]@{
    version = 1
    command = $Command
    id      = [guid]::NewGuid().ToString()
}
if ($Command -eq 'start_export') {
    if ([string]::IsNullOrWhiteSpace($Href) -or [string]::IsNullOrWhiteSpace($DisplayName)) {
        throw 'start_export requires -Href and -DisplayName (pCloud WebDAV paths, not phone LAN paths).'
    }
    $body.href = $Href.Trim()
    $body.displayName = $DisplayName.Trim()
    $body.seekMs = $SeekMs
}
if ($Command -eq 'start_export_random' -and -not [string]::IsNullOrWhiteSpace($Pool)) {
    $body.pool = $Pool
    $body.seekMs = $SeekMs
}

$triggerUrl = "http://${hostIp}:${portNum}/pcld_ios_media/scripts/export_trigger.json"
$ackUrl = "http://${hostIp}:${portNum}/pcld_ios_media/scripts/export_trigger.ack.json"
$json = $body | ConvertTo-Json -Compress

Write-Host "PUT $triggerUrl"
Invoke-WebRequest -Method PUT -Uri $triggerUrl -Headers $headers -Body $json -ContentType 'application/json; charset=utf-8' | Out-Null

Start-Sleep -Seconds 3
Write-Host "GET $ackUrl"
try {
    $ack = Invoke-WebRequest -Uri $ackUrl -Headers $headers -UseBasicParsing
    Write-Host $ack.Content
} catch {
    Write-Warning "No ack yet — is Export open on the phone with triggers enabled?"
}

Write-Host ''
Write-Host "LAN tree: http://${hostIp}:${portNum}/lan_tree.json"
