#Requires -Version 5.1
<#
.SYNOPSIS
  Pull 3d_op_00.mp4 from Loop Segments LAN export into the older PC DLNA slot.

.DESCRIPTION
  While export runs on the phone, Loop Segments serves Documents/Exports on Wi-Fi
  (default http://<phone-ip>:8765/). This script downloads the segment and copies it
  to the older of 3d_op_00.mp4 / 3d_op_01.mp4 on the PC — same ring logic as Photos MTP.

  Save the phone IP from the export log (LAN export: http://...) or -Discover.

.PARAMETER PhoneHost
  iPhone LAN IPv4 (e.g. 192.168.1.42). Default: loop-segments-lan-host.txt in this folder.

.PARAMETER Port
  LAN server port (default 8765).

.PARAMETER Watch
  Poll every -PollSeconds until Enter.

.PARAMETER Discover
  GET /status.json and list available files.

.EXAMPLE
  .\Sync-FromPhoneLAN.ps1 -PhoneHost 192.168.1.42 -Discover

.EXAMPLE
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42
  .\Sync-FromPhoneLAN.ps1 -Watch
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [int] $Port = 8765,
    [string] $DestinationDirectory = '',
    [string] $StagingDirectory = '',
    [int] $PollSeconds = 60,
    [int] $MinSegmentBytes = 8192,
    [switch] $Discover,
    [switch] $Watch,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Config.ps1"

$SegmentNames = @('3d_op_00.mp4', '3d_op_01.mp4')
$RemoteSegmentName = '3d_op_00.mp4'

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
        throw @"
PhoneHost is required. Copy the IP from the app export log (LAN export: http://...).

Run once:
  .\Set-LoopSegmentsLANHost.ps1 192.168.1.42

Or pass -PhoneHost on each run.
Config file: $(Get-LoopSegmentsLANHostConfigPath)
"@
    }
    return $resolved.Trim()
}

function Get-LANBaseUrl {
    param([string] $PhoneHost, [int] $Port)
    return "http://${PhoneHost}:$Port"
}

function Get-LANStatus {
    param([string] $BaseUrl)
    return Invoke-RestMethod -Uri "$BaseUrl/status.json" -Method Get -TimeoutSec 30
}

function Get-OlderDLNASlot {
    param([string] $DestinationRoot)
    $paths = @(
        (Join-Path $DestinationRoot $SegmentNames[0]),
        (Join-Path $DestinationRoot $SegmentNames[1])
    )
    $exists = @(
        (Test-Path -LiteralPath $paths[0] -PathType Leaf),
        (Test-Path -LiteralPath $paths[1] -PathType Leaf)
    )
    if (-not $exists[0]) { return $paths[0], $SegmentNames[0], '3d_op_00 missing — initial slot' }
    if (-not $exists[1]) { return $paths[1], $SegmentNames[1], '3d_op_01 missing — second slot' }
    $t0 = (Get-Item -LiteralPath $paths[0]).LastWriteTimeUtc
    $t1 = (Get-Item -LiteralPath $paths[1]).LastWriteTimeUtc
    if ($t0 -le $t1) {
        return $paths[0], $SegmentNames[0], 'overwrite older PC slot (3d_op_00)'
    }
    return $paths[1], $SegmentNames[1], 'overwrite older PC slot (3d_op_01)'
}

function Invoke-LANSegmentSync {
    param(
        [string] $BaseUrl,
        [string] $DestinationRoot,
        [string] $StagingDirectory,
        [int] $MinSegmentBytes,
        [switch] $DryRun
    )

    $status = Get-LANStatus -BaseUrl $BaseUrl
    $entry = @($status.files | Where-Object { $_.name -eq $RemoteSegmentName } | Select-Object -First 1)
    if (-not $entry) {
        Write-Host "No $RemoteSegmentName on phone yet (export still warming up)."
        return $false
    }

    $remoteBytes = [int64]$entry.bytes
    if ($remoteBytes -lt $MinSegmentBytes) {
        Write-Host "$RemoteSegmentName on phone too small ($remoteBytes B) — wait for segment to finish."
        return $false
    }

    $stateFile = Join-Path $StagingDirectory 'lan-sync-state.json'
    $lastBytes = -1
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try {
            $prev = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($null -ne $prev.bytes) { $lastBytes = [int64]$prev.bytes }
        } catch { }
    }

    $destPath, $destName, $reason = Get-OlderDLNASlot -DestinationRoot $DestinationRoot
    $stagingFile = Join-Path $StagingDirectory $RemoteSegmentName

    Write-Host "Phone: $RemoteSegmentName $remoteBytes bytes (modified $($entry.modified)) -> $destName ($reason)"

    if ($DryRun) {
        Write-Host "Would download: $BaseUrl/$RemoteSegmentName -> $destPath"
        return $true
    }

    if (-not (Test-Path -LiteralPath $StagingDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    $downloadUrl = "$BaseUrl/$RemoteSegmentName"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $stagingFile -TimeoutSec 600 -UseBasicParsing

    $local = Get-Item -LiteralPath $stagingFile
    if ($local.Length -lt $MinSegmentBytes) {
        Write-Host "Downloaded file too small ($($local.Length) B) — skipped."
        return $false
    }

    Copy-Item -LiteralPath $stagingFile -Destination $destPath -Force
    @{
        bytes = $local.Length
        syncedAt = (Get-Date).ToUniversalTime().ToString('o')
        dest = $destName
    } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

    Write-Host "Copied -> $destPath ($($local.Length) bytes)"
    return $true
}

$phone = Get-LoopSegmentsLANHost -Override $PhoneHost
$baseUrl = Get-LANBaseUrl -PhoneHost $phone -Port $Port

if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    $DestinationDirectory = Get-LoopSegmentsDestinationDirectory
}
Test-LoopSegmentsDestinationReady -Directory $DestinationDirectory
$destRoot = [System.IO.Path]::GetFullPath($DestinationDirectory)

if ([string]::IsNullOrWhiteSpace($StagingDirectory)) {
    $StagingDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LoopSegmentsLanStaging'
}
$stagingRoot = [System.IO.Path]::GetFullPath($StagingDirectory)

if ($Discover) {
    Write-Host "LAN base: $baseUrl"
    try {
        $status = Get-LANStatus -BaseUrl $baseUrl
        $status.files | Format-Table name, bytes, modified -AutoSize
    } catch {
        Write-Error "Cannot reach phone at $baseUrl — export running, same Wi-Fi, Local Network allowed for Loop Segments?`n$_"
    }
    exit 0
}

function Wait-ForEnterOrSeconds {
    param([int] $Seconds)
    $end = [datetime]::UtcNow.AddSeconds($Seconds)
    while ([datetime]::UtcNow -lt $end) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

if ($Watch) {
    if ($PollSeconds -lt 5) { throw 'PollSeconds must be at least 5.' }
    Write-Host "Watch: $baseUrl -> $destRoot every $PollSeconds s"
    Write-Host 'Press Enter to stop (phone: export running, same Wi-Fi, Local Network allowed).'
    Write-Host ''
    $iteration = 0
    while ($true) {
        $iteration++
        Write-Host "--- LAN sync #$iteration  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ---" -ForegroundColor Cyan
        try {
            Invoke-LANSegmentSync -BaseUrl $baseUrl -DestinationRoot $destRoot `
                -StagingDirectory $stagingRoot -MinSegmentBytes $MinSegmentBytes -DryRun:$DryRun
        } catch {
            Write-Warning $_.Exception.Message
        }
        Write-Host "Next sync in $PollSeconds s (Enter to stop)..."
        if (Wait-ForEnterOrSeconds -Seconds $PollSeconds) {
            Write-Host 'Stopped.'
            break
        }
    }
    exit 0
}

Invoke-LANSegmentSync -BaseUrl $baseUrl -DestinationRoot $destRoot `
    -StagingDirectory $stagingRoot -MinSegmentBytes $MinSegmentBytes -DryRun:$DryRun
