#Requires -Version 5.1
<#
.SYNOPSIS
  Create or update per-PC settings (loop-segments-windows.json).

.DESCRIPTION
  Portable across Windows PCs: rclone.conf path (Koofr etc.), mount drive letter,
  WinFsp DLL path, phone IP. Copy the repo folder or clone git; run this once per machine.

.PARAMETER Show
  Print resolved paths (rclone, WinFsp) without changing config.

.EXAMPLE
  Copy-Item loop-segments-windows.example.json loop-segments-windows.json
  .\Set-LoopSegmentsWindows.ps1 -PhoneHost 10.0.100.10

.EXAMPLE
  .\Set-LoopSegmentsWindows.ps1 -Show
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [string] $RcloneConfigPath = '',
    [string] $RcloneExe = '',
    [string] $DriveLetter = '',
    [string] $RemoteName = '',
    [string] $WinFspDllPath = '',
    [string] $DlnaFolder = '',
    [int] $LanPort = 0,
    [switch] $SkipWinFspCheck,
    [switch] $Show,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Windows.ps1"

if ($Show) {
    Show-LoopSegmentsWindowsDiagnostics
    exit 0
}

Initialize-LoopSegmentsWindowsConfig -Force:$Force
$settings = Get-LoopSegmentsWindowsSettings

if (-not [string]::IsNullOrWhiteSpace($PhoneHost)) {
    $settings.phoneLanHost = $PhoneHost.Trim()
}
if (-not [string]::IsNullOrWhiteSpace($RcloneConfigPath)) {
    $settings.rcloneConfigPath = $RcloneConfigPath.Trim()
}
if (-not [string]::IsNullOrWhiteSpace($RcloneExe)) {
    $settings.rcloneExe = $RcloneExe.Trim()
}
if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
    $settings.mountDriveLetter = $DriveLetter.Trim().ToUpperInvariant()[0]
}
if (-not [string]::IsNullOrWhiteSpace($RemoteName)) {
    $settings.rcloneRemoteName = $RemoteName.Trim()
}
if (-not [string]::IsNullOrWhiteSpace($WinFspDllPath)) {
    $settings.winfspDllPath = $WinFspDllPath.Trim()
}
if (-not [string]::IsNullOrWhiteSpace($DlnaFolder)) {
    $settings.dlnaFolder = $DlnaFolder.Trim()
}
if ($LanPort -gt 0) {
    $settings.lanPort = $LanPort
}
if ($SkipWinFspCheck) {
    $settings.skipWinFspCheck = $true
}

if ([string]::IsNullOrWhiteSpace($settings.phoneLanHost)) {
    Write-Host 'Enter iPhone LAN IP (from app export log, e.g. 192.168.1.42):'
    $entered = (Read-Host).Trim()
    if (-not [string]::IsNullOrWhiteSpace($entered)) {
        $settings.phoneLanHost = $entered
    }
}

if ([string]::IsNullOrWhiteSpace($settings.rcloneConfigPath)) {
    try {
        $detected = Find-RcloneConfigPath
        Write-Host "Detected rclone.conf: $detected"
        Write-Host 'Press Enter to use it, or type another full path:'
        $entered = (Read-Host).Trim()
        if (-not [string]::IsNullOrWhiteSpace($entered)) {
            $settings.rcloneConfigPath = $entered
        } else {
            $settings.rcloneConfigPath = $detected
        }
    } catch {
        Write-Warning $_.Exception.Message
    }
}

Save-LoopSegmentsWindowsSettings -Settings $settings
Write-Host ''
Show-LoopSegmentsWindowsDiagnostics
Write-Host ''
Write-Host 'Next: .\Mount-LoopSegmentsRclone.ps1 -TestOnly   # then .\Mount-LoopSegmentsRclone.ps1 to mount'
