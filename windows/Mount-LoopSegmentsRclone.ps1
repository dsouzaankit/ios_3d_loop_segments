#Requires -Version 5.1
<#
.SYNOPSIS
  Mount the phone Documents/Exports folder as a Windows drive via rclone WebDAV.

.DESCRIPTION
  Per-PC settings: loop-segments-windows.json (see Set-LoopSegmentsWindows.ps1).
  Uses the same rclone.conf as Koofr when rcloneConfigPath is empty (auto-detect).

.PARAMETER RemovePort80Proxy
  Admin: remove netsh portproxy rules (PC :80 or :8080 -> phone :8765) from legacy WebDAV mapping.
  Does not stop an rclone mount; use -Remove for that.

.EXAMPLE
  .\Set-LoopSegmentsWindows.ps1 -PhoneHost 192.168.1.42
  .\Mount-LoopSegmentsRclone.ps1 -TestOnly
  .\Mount-LoopSegmentsRclone.ps1

.EXAMPLE
  .\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = '',
    [int] $Port = 0,
    [string] $RemoteName = '',
    [string] $WebDAVUser = 'admin',
    [string] $WebDAVPassword = 'iosadmin',
    [switch] $Remove,
    [switch] $RemovePort80Proxy,
    [switch] $TestOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Windows.ps1"

function Ensure-RcloneRemote {
    param(
        [string] $Name,
        [string] $Url,
        [string] $User,
        [string] $Pass
    )

    $inv = Get-RcloneInvocation
    $args = @()
    if ($inv.PrefixArgs) { $args += $inv.PrefixArgs }
    $args += 'obscure', $Pass
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $obscured = (& $inv.Exe @args 2>&1 | Out-String).Trim()
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0) {
        throw "rclone obscure failed: $obscured"
    }

    $configPath = (Get-RcloneInvocation).ConfigPath
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
        if ($content -match 'pcld_ios_media/loop/op_00') {
            Write-Host '  pcld_ios_media/loop/op_00.mp4 listed - good'
        } elseif ($content -match 'op_00') {
            Write-Warning '  Found op_00 at root - install latest Loop Segments (pcld_ios_media/loop/ subfolder).'
        }
    } catch {
        Write-Warning "  PROPFIND probe skipped ($($_.Exception.Message)); rclone will verify WebDAV next."
    }
}

function Test-RcloneWebDAVRemote {
    param([string] $Name)
    Write-Host "rclone ls ${Name}: (WebDAV list) ..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Invoke-LoopSegmentsRclone ls "${Name}:" --max-depth 1 | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0) {
        throw "rclone could not list ${Name}:"
    }
    Write-Host '  Phone Exports visible via WebDAV - good'
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$portNum = Get-LoopSegmentsLanPort -Override $Port
$driveLetter = Get-LoopSegmentsMountDriveLetter -Override $DriveLetter
$remote = Get-LoopSegmentsRcloneRemoteName -Override $RemoteName
$webdavUrl = "http://${hostIp}:${portNum}/"
$driveRoot = "${driveLetter}:\"
$mountLabel = "${remote}:"

if ($RemovePort80Proxy) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-Warning 'Run PowerShell as Administrator to delete portproxy rules (netsh).'
    }
    Clear-LoopSegmentsPort80Proxy -PhoneHost $hostIp -PhonePort $portNum -DriveLetter $driveLetter
    exit 0
}

if (-not $Remove -and -not $TestOnly) {
    if (-not (Test-LoopSegmentsWinFspInstalled)) {
        Write-Warning @'
WinFsp not detected. Set winfspDllPath or skipWinFspCheck in loop-segments-windows.json.
If Koofr rclone mount already works, run: .\Set-LoopSegmentsWindows.ps1 -SkipWinFspCheck
'@
    }
}

if ($TestOnly) {
    Test-PhoneLANExport -HostName $hostIp -PortNum $portNum -User $WebDAVUser -Pass $WebDAVPassword
    Ensure-RcloneRemote -Name $remote -Url $webdavUrl -User $WebDAVUser -Pass $WebDAVPassword
    Test-RcloneWebDAVRemote -Name $remote
    Write-Host 'OK - run without -TestOnly to mount.'
    exit 0
}

if ($Remove) {
    Write-Host "Stopping rclone mount processes for ${driveLetter}: ..."
    $stopped = 0
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape('mount') -and $_.CommandLine -match [regex]::Escape("${driveLetter}:") } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    if ($stopped -eq 0) {
        Write-Warning 'No matching rclone mount process - close the mount window or Ctrl+C the running mount.'
    }
    exit 0
}

Test-PhoneLANExport -HostName $hostIp -PortNum $portNum -User $WebDAVUser -Pass $WebDAVPassword
Ensure-RcloneRemote -Name $remote -Url $webdavUrl -User $WebDAVUser -Pass $WebDAVPassword
Test-RcloneWebDAVRemote -Name $remote

if (Test-Path -LiteralPath $driveRoot) {
    $used = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    if ($used) {
        Write-Warning "$driveRoot already in use (Koofr?). Change mountDriveLetter in loop-segments-windows.json or -DriveLetter."
    }
}

$settings = Get-LoopSegmentsWindowsSettings
Write-Host ''
Write-Host "Mounting ${mountLabel} on $driveRoot (read-only). Ctrl+C stops the mount."
Write-Host "Skybox / DLNA: index ${driveRoot}loop\ (segments) or ${driveRoot} (includes _working.mp4)"
if (-not [string]::IsNullOrWhiteSpace($settings.dlnaFolder)) {
    Write-Host "Configured DLNA folder: $($settings.dlnaFolder)"
    Write-Host "  cmd /c mklink /J `"$($settings.dlnaFolder)\phone_exports`" `"$driveRoot`""
}
Write-Host ''

Invoke-LoopSegmentsRclone mount "${remote}:" $driveRoot `
    --read-only `
    --vfs-cache-mode full `
    --dir-cache-time 5s `
    --poll-interval 10s `
    --attr-timeout 5s `
    --volname 'LoopSegments'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
