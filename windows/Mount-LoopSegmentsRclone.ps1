#Requires -Version 5.1
<#
.SYNOPSIS
  Test HTTP connectivity to the phone LAN export server (port 8765).

.DESCRIPTION
  Loop Segments on the phone serves **HTTP GET/HEAD/OPTIONS** only — **WebDAV (PROPFIND) was removed**.
  **rclone WebDAV mount no longer works** against current app builds. Use the LAN index in a browser,
  Invoke-WebRequest to download files, Apple Devices USB, or `Run-SegmentCopy.ps1` from the sibling PC repo.

  Per-PC settings: loop-segments-windows.json (see Set-LoopSegmentsWindows.ps1).

  Legacy rclone WinFsp mount script (pre–HTTP-only app): archive\Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1

.PARAMETER RemovePort80Proxy
  Admin: remove netsh portproxy rules (PC :80 or :8080 -> phone :8765) from legacy WebDAV mapping.

.PARAMETER Remove
  Stop rclone processes that mount the configured drive letter (legacy — use if an old mount is still running).

.EXAMPLE
  .\Set-LoopSegmentsWindows.ps1 -PhoneHost 192.168.1.42
  .\Mount-LoopSegmentsRclone.ps1 -TestOnly

.EXAMPLE
  .\Mount-LoopSegmentsRclone.ps1 -RemovePort80Proxy
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = '',
    [int] $Port = 0,
    [switch] $Remove,
    [switch] $RemovePort80Proxy,
    [switch] $TestOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Windows.ps1"

function Test-PhoneLANHTTPExport {
    param(
        [string] $HostName,
        [int] $PortNum
    )

    $base = "http://${HostName}:${PortNum}/"
    Write-Host "Checking $base (HTTP only — no WebDAV) ..."
    try {
        $r = Invoke-WebRequest -Uri ($base + 'status.json') -TimeoutSec 15 -UseBasicParsing
        Write-Host "  GET status.json -> $($r.StatusCode)"
    } catch {
        throw "Phone not reachable at $base (same Wi-Fi? LAN server on? app in foreground?). $($_.Exception.Message)"
    }

    try {
        $r = Invoke-WebRequest -Uri $base -TimeoutSec 15 -UseBasicParsing
        Write-Host "  GET / (HTML index) -> $($r.StatusCode)"
    } catch {
        Write-Warning "  GET / failed: $($_.Exception.Message)"
    }

    try {
        $r = Invoke-WebRequest -Uri $base -Method OPTIONS -TimeoutSec 15 -UseBasicParsing
        $allow = $r.Headers['Allow']
        if ($allow) {
            Write-Host "  OPTIONS -> $($r.StatusCode); Allow: $allow"
        } else {
            Write-Host "  OPTIONS -> $($r.StatusCode)"
        }
    } catch {
        Write-Warning "  OPTIONS failed: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'OK — phone LAN HTTP export is reachable.'
    Write-Host 'Copy files: open this URL in a browser, use Invoke-WebRequest, or USB / Apple Devices.'
    Write-Host 'See ../ios/README.md, ../WORKFLOW.md, and archive/RCLONE-PHONE-MOUNT-LEGACY.md'
}

$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$portNum = Get-LoopSegmentsLanPort -Override $Port
$driveLetter = Get-LoopSegmentsMountDriveLetter -Override $DriveLetter

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

if ($TestOnly) {
    Test-PhoneLANHTTPExport -HostName $hostIp -PortNum $portNum
    exit 0
}

Write-Error @'
Loop Segments no longer exposes WebDAV (PROPFIND) on port 8765 — the app LAN server is HTTP only.
rclone cannot mount the phone as a WebDAV remote anymore.

What to use instead:
  • Browser: open http://<phone-ip>:8765/ and download or stream linked paths.
  • PowerShell: Invoke-WebRequest -Uri "http://<ip>:8765/pcld_ios_media/loop/op_00.mp4" -OutFile .\op_00.mp4
  • USB: Apple Devices → copy from the phone’s Exports folder.
  • Unattended PC pull: Run-SegmentCopy.ps1 in the sibling 3d_loop_segments repo (pCloud → PC).
  • Historical rclone+WinFsp script (reference only): .\archive\Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1

Run with -TestOnly to verify the phone answers HTTP, or see ../WORKFLOW.md.
'@
exit 1
