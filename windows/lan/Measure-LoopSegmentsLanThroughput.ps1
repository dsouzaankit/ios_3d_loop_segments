#Requires -Version 5.1
<#
.SYNOPSIS
  Measure LAN throughput by copying a large phone media file off the rclone mount (L:).

.DESCRIPTION
  Assumes a successful rclone WebDAV mount (Mount-LoopSegmentsRclone.ps1 / Mount-PhoneL.cmd).
  Picks the largest media file under <drive>:\pcld_ios_media\, copies it to a local temp
  file (or -OutFile), and prints MB transferred + Mbps.

  This measures the PC ↔ phone path through the current gateway Wi-Fi (rclone/WinFsp +
  phone HTTP/WebDAV) - not 5G WAN internet speed.

.EXAMPLE
  .\rclone\Mount-LoopSegmentsRclone.ps1   # leave window open
  .\lan\Measure-LoopSegmentsLanThroughput.ps1

.EXAMPLE
  .\lan\Measure-LoopSegmentsLanThroughput.ps1 -MaxBytes 0 -KeepLocal
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = '',
    [string] $MediaRelativePath = 'pcld_ios_media',
    [string] $SourcePath = '',
    [string] $OutFile = '',
    [long] $MinBytes = 8MB,
    [long] $MaxBytes = 64MB,
    [int] $WaitMountSec = 45,
    [int] $BufferBytes = 4MB,
    # Fraction of measured LAN Mbps used as recommended max media/encode bitrate (headroom for HTTP/rclone/player).
    [ValidateRange(0.1, 1.0)]
    [double] $RecommendHeadroom = 0.8,
    [int] $RecommendMinMbps = 5,
    [int] $RecommendMaxMbps = 100,
    # After measure: if gateway shares LAN-page subnet and throughput is below this, force gateway Wi-Fi reboot and stop (exit 10).
    # 0 = use minLanThroughputMbps from loop-segments-windows.json (default 40).
    [double] $LowThroughputMbps = 0,
    [int] $PostRebootSettleSec = 10,
    [switch] $SkipLowThroughputGatewayReboot,
    # When set (companion child): exit 10 without local Enter; parent prompts instead.
    [switch] $NoWaitEnterOnLowThroughputStop,
    [switch] $SkipSidecarWrite,
    [switch] $KeepLocal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"

function Format-Bytes {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Test-MountRootReady {
    param([Parameter(Mandatory = $true)][string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $false }
    try {
        $null = Get-ChildItem -LiteralPath $Root -ErrorAction Stop | Select-Object -First 1
        return $true
    } catch {
        return $false
    }
}

function Wait-MountRootReady {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][int] $TimeoutSec
    )
    if (Test-MountRootReady -Root $Root) { return $true }
    if ($TimeoutSec -le 0) { return $false }
    Write-Host ("[lan-bw] Waiting up to {0}s for mount {1} ..." -f $TimeoutSec, $Root)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-MountRootReady -Root $Root) { return $true }
    }
    return (Test-MountRootReady -Root $Root)
}

function Find-LargestPhoneMediaFile {
    param(
        [Parameter(Mandatory = $true)][string] $MediaRoot,
        [Parameter(Mandatory = $true)][long] $MinBytes
    )
    if (-not (Test-Path -LiteralPath $MediaRoot)) {
        throw "Media root not found: $MediaRoot"
    }

    $exts = @('.mp4', '.mov', '.m4v', '.mkv', '.webm')
    $candidates = @(Get-ChildItem -LiteralPath $MediaRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -ge $MinBytes -and
            ($exts -contains $_.Extension.ToLowerInvariant()) -and
            ($_.FullName -notmatch '(?i)[\\/]scripts[\\/]')
        } |
        Sort-Object Length -Descending)

    if ($candidates.Count -eq 0) {
        throw @"
No media file >= $(Format-Bytes $MinBytes) under $MediaRoot.
Export a video on the phone (or lower -MinBytes), then retry.
"@
    }
    return $candidates[0]
}

function Copy-FileMeasured {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][int] $BufferSize,
        [long] $LimitBytes = 0
    )

    $buffer = New-Object byte[] $BufferSize
    $src = $null
    $dst = $null
    $total = [long]0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $src = [System.IO.File]::Open(
            $Source,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $dst = [System.IO.File]::Create($Destination)
        while ($true) {
            $toRead = $buffer.Length
            if ($LimitBytes -gt 0) {
                $left = $LimitBytes - $total
                if ($left -le 0) { break }
                if ($left -lt $toRead) { $toRead = [int]$left }
            }
            $n = $src.Read($buffer, 0, $toRead)
            if ($n -le 0) { break }
            $dst.Write($buffer, 0, $n)
            $total += $n
        }
    } finally {
        $sw.Stop()
        if ($dst) { $dst.Dispose() }
        if ($src) { $src.Dispose() }
    }

    return [pscustomobject]@{
        Bytes    = $total
        Seconds  = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        Stopwatch = $sw
    }
}

function ConvertTo-Ipv4UInt32 {
    param([Parameter(Mandatory = $true)][string] $IpAddress)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress.Trim(), [ref]$parsed)) {
        throw "Invalid IPv4 address: $IpAddress"
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Not an IPv4 address: $IpAddress"
    }
    $bytes = $parsed.GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-SameIpv4Subnet {
    param(
        [Parameter(Mandatory = $true)][string] $IpA,
        [Parameter(Mandatory = $true)][string] $IpB,
        [Parameter(Mandatory = $true)][int] $PrefixLen
    )
    if ($PrefixLen -lt 0 -or $PrefixLen -gt 32) {
        throw "PrefixLength must be 0..32 (got $PrefixLen)"
    }
    $hostBits = 32 - $PrefixLen
    [uint32]$mask = 0
    if ($PrefixLen -ge 32) {
        $mask = [uint32]::MaxValue
    } elseif ($PrefixLen -gt 0) {
        $mask = [uint32](-bnot (([uint32]1 -shl $hostBits) - 1))
    }
    $netA = (ConvertTo-Ipv4UInt32 -IpAddress $IpA) -band $mask
    $netB = (ConvertTo-Ipv4UInt32 -IpAddress $IpB) -band $mask
    return ($netA -eq $netB)
}

function Get-DefaultGatewayInfo {
    $info = [pscustomobject]@{
        Gateway      = $null
        PrefixLength = 24
    }
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object {
                $_.IPv4DefaultGateway -and
                $_.NetAdapter -and
                $_.NetAdapter.Status -eq 'Up'
            })
        foreach ($cfg in $configs) {
            $nextHop = [string]$cfg.IPv4DefaultGateway.NextHop
            if ([string]::IsNullOrWhiteSpace($nextHop) -or $nextHop -eq '0.0.0.0') { continue }
            $info.Gateway = $nextHop.Trim()
            $v4 = @($cfg.IPv4Address) | Select-Object -First 1
            if ($null -ne $v4 -and $null -ne $v4.PrefixLength -and [int]$v4.PrefixLength -gt 0) {
                $info.PrefixLength = [int]$v4.PrefixLength
            }
            return $info
        }
    } catch {}
    try {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $info.Gateway = ([string]$route.NextHop).Trim()
            try {
                $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -First 1
                if ($addr -and $addr.PrefixLength -gt 0) {
                    $info.PrefixLength = [int]$addr.PrefixLength
                }
            } catch {}
        }
    } catch {}
    return $info
}

function Wait-EnterToClose {
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Invoke-LowThroughputGatewayRebootAndStop {
    param(
        [Parameter(Mandatory = $true)][double] $MeasuredMbps,
        [Parameter(Mandatory = $true)][double] $ThresholdMbps,
        [Parameter(Mandatory = $true)][int] $SettleSec
    )

    $phoneHost = Get-LoopSegmentsLANHost
    $gwInfo = Get-DefaultGatewayInfo
    $gatewayIp = [string]$gwInfo.Gateway
    $prefix = [int]$gwInfo.PrefixLength
    if ($prefix -le 0) { $prefix = 24 }

    if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
        Write-Warning '[lan-bw] Low throughput but no default gateway found - cannot reboot router.'
        return $false
    }

    Write-Host ('[lan-bw] Gateway {0} (/{1}) | phone LAN page {2}' -f $gatewayIp, $prefix, $phoneHost)
    if (-not (Test-SameIpv4Subnet -IpA $gatewayIp -IpB $phoneHost -PrefixLen $prefix)) {
        Write-Warning ('[lan-bw] Low throughput ({0:N1} Mbps < {1}), but gateway is NOT on the same subnet as the LAN page - skip forced reboot (fix subnet first).' -f $MeasuredMbps, $ThresholdMbps)
        return $false
    }

    Write-Host ""
    Write-Host ('[lan-bw] WARNING: LAN throughput {0:N1} Mbps is below {1} Mbps while gateway and LAN page share a subnet.' -f $MeasuredMbps, $ThresholdMbps) -ForegroundColor Yellow
    Write-Host '[lan-bw] Rebooting Wi-Fi on the CURRENT gateway to recover bandwidth.' -ForegroundColor Yellow
    Write-Host '[lan-bw] After Wi-Fi settles, re-run the companion / measure script and try again.' -ForegroundColor Yellow

    $rebootPs1 = Join-Path $PSScriptRoot 'Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $rebootPs1)) {
        Write-Warning ("[lan-bw] Missing {0} - cannot force gateway reboot." -f $rebootPs1)
        return $false
    }

    $psArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $rebootPs1,
        '-ForceReboot'
    )
    if ($NoWaitEnterOnLowThroughputStop) {
        $psArgs += '-NoWaitEnter'
    }
    Write-Host ('[lan-bw] > powershell {0}' -f ($psArgs -join ' '))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe @psArgs
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        Write-Warning ("[lan-bw] Gateway reboot failed (exit {0})." -f $code)
        return $false
    }

    $settle = [Math]::Max(1, $SettleSec)
    Write-Host ('[lan-bw] Waiting {0}s for the router Wi-Fi reboot to finish...' -f $settle) -ForegroundColor Cyan
    Start-Sleep -Seconds $settle
    Write-Host '[lan-bw] Re-run this workflow after devices re-associate to the gateway. Companion will not start Chromium now.' -ForegroundColor Yellow
    return $true
}

$letter = Get-LoopSegmentsMountDriveLetter -Override $DriveLetter
$driveRoot = "${letter}:\"
$mediaRoot = Join-Path $driveRoot $MediaRelativePath.TrimStart('\')

Write-Host ('[lan-bw] Mount drive: {0} (from loop-segments-windows.json / -DriveLetter)' -f $driveRoot)
Write-Host '[lan-bw] Measures PC ↔ phone LAN via rclone mount (not 5G WAN).'
$minLanMbps = Get-LoopSegmentsMinLanThroughputMbps -Override $LowThroughputMbps
Write-Host ('[lan-bw] Min LAN throughput for gateway reboot: {0} Mbps (loop-segments-windows.json minLanThroughputMbps / -LowThroughputMbps)' -f $minLanMbps)

if (-not (Wait-MountRootReady -Root $driveRoot -TimeoutSec $WaitMountSec)) {
    throw @"
[lan-bw] Mount $driveRoot is not ready.

Start it first (leave the window open):
  .\rclone\Mount-PhoneL.cmd
  # or: .\rclone\Mount-LoopSegmentsRclone.ps1

Then re-run this script.
"@
}

if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
    $source = $SourcePath.Trim()
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "SourcePath not found: $source"
    }
    $sourceItem = Get-Item -LiteralPath $source
} else {
    Write-Host ("[lan-bw] Scanning for largest media under {0} ..." -f $mediaRoot)
    $sourceItem = Find-LargestPhoneMediaFile -MediaRoot $mediaRoot -MinBytes $MinBytes
    $source = $sourceItem.FullName
}

Write-Host ('[lan-bw] Source: {0}' -f $source)
Write-Host ('[lan-bw] Size on phone mount: {0}' -f (Format-Bytes ([long]$sourceItem.Length)))
if ($MaxBytes -gt 0) {
    Write-Host ('[lan-bw] Cap transfer at {0} (-MaxBytes)' -f (Format-Bytes $MaxBytes))
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $env:TEMP ('loopsegments-lan-bw-{0:yyyyMMdd-HHmmss}.bin' -f (Get-Date))
} else {
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

Write-Host ('[lan-bw] Local dest: {0}' -f $OutFile)
Write-Host '[lan-bw] Copying...'

$result = Copy-FileMeasured -Source $source -Destination $OutFile -BufferSize $BufferBytes -LimitBytes $MaxBytes
$mb = $result.Bytes / 1MB
$mbps = (8.0 * $mb) / $result.Seconds
$recommendedMbps = [int][Math]::Floor($mbps * $RecommendHeadroom)
if ($recommendedMbps -lt $RecommendMinMbps) { $recommendedMbps = $RecommendMinMbps }
if ($recommendedMbps -gt $RecommendMaxMbps) { $recommendedMbps = $RecommendMaxMbps }

Write-Host ''
Write-Host ('[lan-bw] Transferred: {0} in {1:N2}s' -f (Format-Bytes $result.Bytes), $result.Seconds) -ForegroundColor Green
Write-Host ('[lan-bw] Throughput:  {0:N1} Mbps ({1:N1} MB/s)' -f $mbps, ($mb / $result.Seconds)) -ForegroundColor Green
Write-Host ('[lan-bw] Recommended max media bitrate for minute segments: {0} Mbps ({1:P0} of LAN, clamp {2}-{3})' -f `
    $recommendedMbps, $RecommendHeadroom, $RecommendMinMbps, $RecommendMaxMbps) -ForegroundColor Cyan
Write-Host '[lan-bw] Use this as -SegmentVideoBitrateMbps (hybrid batch / Run-TranscodeFfmpeg) so 60s DLNA slots stay under LAN capacity.'
Write-Host ('[lan-bw] Phone LAN:   {0}' -f (Get-LoopSegmentsPhoneLanBaseUrl))

if (-not $SkipSidecarWrite) {
    $payload = [ordered]@{
        schema                             = 'loopsegments-lan-throughput/v1'
        measuredMbps                       = [Math]::Round($mbps, 2)
        recommendedMaxMediaBitrateMbps     = $recommendedMbps
        minLanThroughputMbps               = $minLanMbps
        headroomFactor                     = $RecommendHeadroom
        measuredAtUtc                      = [datetime]::UtcNow.ToString('o')
        phoneLanHost                       = (Get-LoopSegmentsLANHost)
        phoneLanBaseUrl                    = (Get-LoopSegmentsPhoneLanBaseUrl)
        sourcePath                         = $source
        transferredBytes                   = $result.Bytes
        elapsedSeconds                     = [Math]::Round($result.Seconds, 3)
        note                               = 'Cap minute-segment encode (-SegmentVideoBitrateMbps) at or below recommendedMaxMediaBitrateMbps for sustained LAN / Skybox viewing.'
    }
    $json = ($payload | ConvertTo-Json -Depth 4)
    $sidecarPaths = @(
        (Join-Path $mediaRoot 'scripts\lan_throughput.json')
        (Join-Path $mediaRoot 'archive\lan_recommended_segment_bitrate.json')
        (Join-Path $mediaRoot 'lan_recommended_segment_bitrate.json')
    )
    foreach ($sidecar in $sidecarPaths) {
        try {
            $dir = Split-Path -Parent $sidecar
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Set-Content -LiteralPath $sidecar -Value $json -Encoding UTF8
            Write-Host ('[lan-bw] Wrote recommendation sidecar: {0}' -f $sidecar)
        } catch {
            Write-Warning ("[lan-bw] Could not write sidecar {0}: {1}" -f $sidecar, $_.Exception.Message)
        }
    }
}

if (-not $KeepLocal) {
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    Write-Host '[lan-bw] Removed local copy (use -KeepLocal to retain).'
} else {
    Write-Host ('[lan-bw] Kept local copy: {0}' -f $OutFile)
}

if (-not $SkipLowThroughputGatewayReboot -and $minLanMbps -gt 0 -and $mbps -lt $minLanMbps) {
    $stopped = Invoke-LowThroughputGatewayRebootAndStop -MeasuredMbps $mbps `
        -ThresholdMbps $minLanMbps -SettleSec $PostRebootSettleSec
    if ($stopped) {
        if (-not $NoWaitEnterOnLowThroughputStop) {
            Wait-EnterToClose
        }
        # 10 = intentional stop after low-throughput gateway reboot (do not start Chromium).
        exit 10
    }
}

exit 0
