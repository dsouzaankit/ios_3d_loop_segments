#Requires -Version 5.1
<#
.SYNOPSIS
  Mount the phone Documents/Exports folder as a Windows drive via rclone WebDAV.

.DESCRIPTION
  Loop Segments serves Exports on http://<phone>:8765/ (WebDAV + HTTP). This script
  configures an rclone remote and mounts the entire Exports folder (loop/op_00|01.mp4,
  _working.mp4, logs). Point Skybox PC / DLNA at <drive>\loop\ (segments only) or
  <drive>\ (includes _working.mp4 for in-progress playback).

  Requires WinFsp (https://winfsp.dev/) and rclone (https://rclone.org/install/).

.PARAMETER PhoneHost
  iPhone LAN IPv4. Default: loop-segments-lan-host.txt in this folder.

.PARAMETER DriveLetter
  Mount point (default L:).

.PARAMETER RemoteName
  rclone config section name (default loopsegments).

.PARAMETER Remove
  Unmount the drive (does not delete rclone.conf).

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
  .\Mount-LoopSegmentsRclone.ps1

.EXAMPLE
  .\Mount-LoopSegmentsRclone.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = 'L',
    [int] $Port = 8765,
    [string] $RemoteName = 'loopsegments',
    [string] $WebDAVUser = 'admin',
    [string] $WebDAVPassword = 'iosadmin',
    [switch] $Remove,
    [switch] $TestOnly
)

$ErrorActionPreference = 'Stop'

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

function Assert-CommandExists {
    param([string] $Name, [string] $InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found on PATH. $InstallHint"
    }
}

function Get-RcloneConfigPath {
    if ($env:RCLONE_CONFIG) { return $env:RCLONE_CONFIG }
    $local = Join-Path $env:LOCALAPPDATA 'rclone\rclone.conf'
    if (Test-Path -LiteralPath $local) { return $local }
    return Join-Path $env:USERPROFILE '.config\rclone\rclone.conf'
}

function Ensure-RcloneRemote {
    param(
        [string] $Name,
        [string] $Url,
        [string] $User,
        [string] $Pass
    )

    $obscured = & rclone obscure $Pass 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rclone obscure failed: $obscured"
    }
    $obscured = ($obscured | Out-String).Trim()

    $configPath = Get-RcloneConfigPath
    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $block = @"
[$Name]
type = webdav
url = $Url
vendor = other
user = $User
pass = $obscured

"@

    if (Test-Path -LiteralPath $configPath) {
        $text = Get-Content -LiteralPath $configPath -Raw
        $pattern = "(?ms)^\[$([regex]::Escape($Name))\].*?(?=^\[|\z)"
        if ($text -match $pattern) {
            $text = [regex]::Replace($text, $pattern, $block.TrimEnd() + "`r`n`r`n")
        } else {
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
            $text += "`r`n" + $block
        }
        Set-Content -LiteralPath $configPath -Value $text -Encoding UTF8 -NoNewline
    } else {
        Set-Content -LiteralPath $configPath -Value $block -Encoding UTF8
    }
    Write-Host "rclone remote '$Name' -> $Url"
    Write-Host "Config: $configPath"
}

function Test-PhoneWebDAV {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )

    $base = "http://${HostName}:${PortNum}/"
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    $headers = @{ Authorization = "Basic $pair" }

    Write-Host "PROPFIND $base ..."
    try {
        $r = Invoke-WebRequest -Uri $base -Method 'OPTIONS' -Headers $headers -TimeoutSec 15 -UseBasicParsing
        Write-Host "  OPTIONS -> $($r.StatusCode)"
    } catch {
        Write-Warning "  OPTIONS failed: $($_.Exception.Message)"
    }

    $body = '<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>'
    try {
        $r = Invoke-WebRequest -Uri $base -Method 'PROPFIND' -Headers $headers -Body $body -ContentType 'text/xml; charset=utf-8' -TimeoutSec 20 -UseBasicParsing
        Write-Host "  PROPFIND -> $($r.StatusCode)"
        if ($r.Content -match 'loop/op_00') {
            Write-Host '  loop/op_00.mp4 listed — good'
        } elseif ($r.Content -match 'op_00') {
            Write-Warning '  Found op_00 at root — install latest Loop Segments (loop/ subfolder).'
        }
    } catch {
        throw "PROPFIND failed. Phone on LAN? Serve Exports on? Build with loop/ + WebDAV. $($_.Exception.Message)"
    }
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$webdavUrl = "http://${hostIp}:${Port}/"
$driveRoot = "${DriveLetter}:\"
$mountLabel = "${RemoteName}:"

Assert-CommandExists -Name 'rclone' -InstallHint 'Install from https://rclone.org/install/'
if (-not $Remove -and -not $TestOnly) {
    $winfsp = "${env:ProgramFiles}\WinFsp\bin\winfsp-x64.dll"
    if (-not (Test-Path -LiteralPath $winfsp)) {
        Write-Warning 'WinFsp not found — install from https://winfsp.dev/ before mounting.'
    }
}

if ($TestOnly) {
    Test-PhoneWebDAV -HostName $hostIp -PortNum $Port -User $WebDAVUser -Pass $WebDAVPassword
    exit 0
}

if ($Remove) {
    Write-Host "Stopping rclone mount processes for ${DriveLetter}: ..."
    $stopped = 0
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape("mount") -and $_.CommandLine -match [regex]::Escape("${DriveLetter}:") } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    if ($stopped -eq 0) {
        Write-Warning 'No matching rclone mount process — close the mount window or Ctrl+C the running mount.'
    }
    exit 0
}

Test-PhoneWebDAV -HostName $hostIp -PortNum $Port -User $WebDAVUser -Pass $WebDAVPassword
Ensure-RcloneRemote -Name $RemoteName -Url $webdavUrl -User $WebDAVUser -Pass $WebDAVPassword

if (Test-Path -LiteralPath $driveRoot) {
    $used = (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue)
    if ($used) {
        Write-Warning "$driveRoot already in use. Unmount first: .\Mount-LoopSegmentsRclone.ps1 -Remove"
    }
}

Write-Host ''
Write-Host "Mounting ${mountLabel} on $driveRoot (read-only, vfs cache full). Ctrl+C stops the mount."
Write-Host "Skybox / DLNA: index ${driveRoot}loop\ (segments) or ${driveRoot} (includes _working.mp4)"
Write-Host 'Optional junction:'
Write-Host "  cmd /c mklink /J `"<DLNA>\phone_exports`" `"$driveRoot`""
Write-Host ''

& rclone mount "${RemoteName}:" $driveRoot `
    --read-only `
    --vfs-cache-mode full `
    --dir-cache-time 5s `
    --poll-interval 10s `
    --attr-timeout 5s `
    --volname 'LoopSegments'
