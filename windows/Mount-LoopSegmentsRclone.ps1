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
  rclone config section name (default loopsegments; separate from Koofr/other remotes).

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
    if (-not [string]::IsNullOrWhiteSpace($env:RCLONE_CONFIG)) {
        return $env:RCLONE_CONFIG.Trim()
    }
    try {
        $fromRclone = (& rclone config file 2>$null | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($fromRclone) -and (Test-Path -LiteralPath $fromRclone)) {
            return $fromRclone
        }
    } catch {
        # ignore
    }
    $candidates = @(
        (Join-Path $env:APPDATA 'rclone\rclone.conf'),
        (Join-Path $env:LOCALAPPDATA 'rclone\rclone.conf'),
        (Join-Path $env:USERPROFILE '.config\rclone\rclone.conf')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return (Join-Path $env:APPDATA 'rclone\rclone.conf')
}

function Get-RcloneConfigArgs {
    $path = Get-RcloneConfigPath
    if (Test-Path -LiteralPath $path) {
        return @('--config', $path)
    }
    return @()
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

function Test-WinFspInstalled {
    $candidates = @(
        "${env:ProgramFiles}\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles}\WinFsp\bin\winfsp.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp.dll"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    foreach ($root in @("${env:ProgramFiles}\WinFsp", "${env:ProgramFiles(x86)}\WinFsp")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Get-ChildItem -LiteralPath $root -Recurse -Filter 'winfsp*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }
    return $false
}

function Invoke-WebDavRequest {
    param(
        [string] $Uri,
        [string] $Method,
        [hashtable] $Headers = @{},
        [string] $Body = '',
        [int] $TimeoutSec = 20
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    foreach ($key in $Headers.Keys) {
        if ($key -ieq 'Authorization') {
            $request.Headers['Authorization'] = [string]$Headers[$key]
        } else {
            $request.Headers[$key] = [string]$Headers[$key]
        }
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = 'text/xml; charset=utf-8'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Close()
        }
    }
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            return $_.Exception.Response
        }
        throw
    }
    return $response
}

function Test-PhoneLANExport {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )

    $base = "http://${HostName}:${PortNum}/"
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    $headers = @{ Authorization = "Basic $pair" }

    Write-Host "Checking $base ..."
    try {
        $r = Invoke-WebRequest -Uri ($base + 'status.json') -TimeoutSec 15 -UseBasicParsing
        Write-Host "  GET status.json -> $($r.StatusCode)"
    } catch {
        throw "Phone not reachable at $base (same Wi-Fi? Serve Exports on?). $($_.Exception.Message)"
    }

    try {
        $r = Invoke-WebRequest -Uri $base -Method 'OPTIONS' -Headers $headers -TimeoutSec 15 -UseBasicParsing
        Write-Host "  OPTIONS (WebDAV) -> $($r.StatusCode)"
    } catch {
        Write-Warning "  OPTIONS failed: $($_.Exception.Message)"
    }

    $body = '<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>'
    $propHeaders = $headers.Clone()
    $propHeaders['Depth'] = '1'
    try {
        $response = Invoke-WebDavRequest -Uri $base -Method 'PROPFIND' -Headers $propHeaders -Body $body -TimeoutSec 20
        $status = [int]$response.StatusCode
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try {
            $content = $reader.ReadToEnd()
        } finally {
            $reader.Close()
            $response.Close()
        }
        Write-Host "  PROPFIND -> $status"
        if ($content -match 'loop/op_00') {
            Write-Host '  loop/op_00.mp4 listed - good'
        } elseif ($content -match 'op_00') {
            Write-Warning '  Found op_00 at root - install latest Loop Segments (loop/ subfolder).'
        }
    } catch {
        Write-Warning "  PROPFIND probe skipped ($($_.Exception.Message)); rclone will verify WebDAV next."
    }
}

function Test-RcloneWebDAVRemote {
    param([string] $Name)
    $cfg = Get-RcloneConfigArgs
    Write-Host "rclone ls ${Name}: (WebDAV list) ..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & rclone @cfg ls "${Name}:" --max-depth 1 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0) {
        throw "rclone could not list ${Name}: - $(($out | Out-String).Trim())"
    }
    $text = $out | Out-String
    if ($text -match '_working\.mp4|loop/op_00') {
        Write-Host '  Phone Exports visible via WebDAV - good'
    } else {
        Write-Warning "  Listed remote but expected _working.mp4 or loop/op_00.mp4"
    }
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$webdavUrl = "http://${hostIp}:${Port}/"
$driveRoot = "${DriveLetter}:\"
$mountLabel = "${RemoteName}:"

Assert-CommandExists -Name 'rclone' -InstallHint 'Install from https://rclone.org/install/'
if (-not $Remove -and -not $TestOnly) {
    if (-not (Test-WinFspInstalled)) {
        Write-Warning @'
WinFsp not detected under Program Files (Koofr mount may still mean it is installed).
If rclone mount fails, install WinFsp from https://winfsp.dev/
'@
    }
}

if ($TestOnly) {
    Test-PhoneLANExport -HostName $hostIp -PortNum $Port -User $WebDAVUser -Pass $WebDAVPassword
    Ensure-RcloneRemote -Name $RemoteName -Url $webdavUrl -User $WebDAVUser -Pass $WebDAVPassword
    Test-RcloneWebDAVRemote -Name $RemoteName
    Write-Host 'OK - run without -TestOnly to mount.'
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
        Write-Warning 'No matching rclone mount process - close the mount window or Ctrl+C the running mount.'
    }
    exit 0
}

Test-PhoneLANExport -HostName $hostIp -PortNum $Port -User $WebDAVUser -Pass $WebDAVPassword
Ensure-RcloneRemote -Name $RemoteName -Url $webdavUrl -User $WebDAVUser -Pass $WebDAVPassword
Test-RcloneWebDAVRemote -Name $RemoteName

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

$cfg = Get-RcloneConfigArgs
& rclone @cfg mount "${RemoteName}:" $driveRoot `
    --read-only `
    --vfs-cache-mode full `
    --dir-cache-time 5s `
    --poll-interval 10s `
    --attr-timeout 5s `
    --volname 'LoopSegments'
