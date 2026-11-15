# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Put PC + phone back on the app LAN after an IPA deploy (companion Wi‑Fi setup).

.DESCRIPTION
  IPA USB install bounces the phone LAN AP and moves this PC onto a www-capable Wi‑Fi
  so SideStore can sign. Companion needs the opposite: both ends on the phoneLanHost
  subnet with :8765 up. This script re-runs the same two steps companion startup uses:

    1. lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1
       (saved Wi‑Fi switch / wrong-subnet gateway reboot until PC gateway matches phoneLanHost)
    2. lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1
       (USB/pcapd phone↔PC subnet, wait for :8765; off-subnet router reboot if still down)

  If the LAN page is still unreachable after that (often the app is backgrounded /
  not running after the install), USB-foregrounds Loop Segments
  (usb\Launch-LoopSegmentsViaUsb.ps1 -SkipMount) and waits again for :8765.

  Direct run waits for Enter. Pass -NoWaitEnter for callers (throws
  COMPANION_WIFI_REORIENT_EXIT:<code>).

.EXAMPLE
  .\lan\Invoke-LoopSegmentsCompanionWifiReorientAfterIpa.ps1

.EXAMPLE
  .\lan\Invoke-LoopSegmentsCompanionWifiReorientAfterIpa.ps1 -NoWaitEnter
#>
[CmdletBinding()]
param(
    [string] $PhoneLanHost = '',
    [int] $LanPort = 0,
    [string] $RebootScriptsRoot = 'P:\all_scripts\5g_router_reboot',
    [ValidateRange(5, 600)]
    [int] $WaitAfterLaunchSec = 90,
    [int] $IntervalMs = 1500,
    [switch] $SkipGatewayReboot,
    [switch] $SkipRecover,
    [switch] $SkipUsbLaunch,
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ''
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try { [void][Console]::ReadLine() } catch { Read-Host | Out-Null }
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    if ($NoWaitEnter) {
        throw "COMPANION_WIFI_REORIENT_EXIT:$ExitCode"
    }
    exit $ExitCode
}

trap {
    if ("$($_.Exception.Message)" -match '^COMPANION_WIFI_REORIENT_EXIT:') { throw $_ }
    Write-Host ''
    Write-Host ('[wifi-reorient] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($NoWaitEnter) { throw $_ }
    Wait-EnterToClose
    exit 1
}

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$WindowsDir = Split-Path -Parent $PSScriptRoot
$UsbDir = Join-Path $WindowsDir 'usb'
$GatewayPs1 = Join-Path $PSScriptRoot 'Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
$RecoverPs1 = Join-Path $PSScriptRoot 'Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1'
$LaunchPs1 = Join-Path $UsbDir 'Launch-LoopSegmentsViaUsb.ps1'

Write-Host '[wifi-reorient] Re-orient PC + phone onto the app LAN (post–IPA deploy / companion Wi‑Fi).'

function Resolve-PhoneLanTarget {
    $hostName = if ($null -eq $PhoneLanHost) { '' } else { $PhoneLanHost.Trim() }
    $port = $LanPort
    $settingsPath = Join-Path $WindowsDir 'loop-segments-windows.json'
    if (([string]::IsNullOrWhiteSpace($hostName) -or $port -le 0) -and (Test-Path -LiteralPath $settingsPath)) {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            $hostName = [string]$settings.phoneLanHost
        }
        if ($port -le 0 -and $null -ne $settings.lanPort -and [int]$settings.lanPort -gt 0) {
            $port = [int]$settings.lanPort
        }
    }
    if ($port -le 0) { $port = 8765 }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw "phoneLanHost is required (pass -PhoneLanHost or set it in $settingsPath)."
    }
    return @{ Host = $hostName.Trim(); Port = $port }
}

function Test-TcpPortOpen {
    param([string] $HostName, [int] $Port, [int] $TimeoutMs = 2000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch {} }
    }
}

function Invoke-DirectHttpGet {
    param([Parameter(Mandatory = $true)][string] $Uri, [int] $TimeoutSec = 3)
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'GET'
    $req.Timeout = [Math]::Max(1, $TimeoutSec) * 1000
    $req.ReadWriteTimeout = $req.Timeout
    $req.AllowAutoRedirect = $true
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $resp = $null
    try {
        $resp = $req.GetResponse()
        return @{ StatusCode = [int]$resp.StatusCode }
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            return @{ StatusCode = [int]$_.Exception.Response.StatusCode }
        }
        throw
    } finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch {}
            try { $resp.Dispose() } catch {}
        }
    }
}

function Test-PhoneLanPageReachable {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $Port,
        [switch] $Quiet
    )
    if (-not (Test-TcpPortOpen -HostName $HostName -Port $Port -TimeoutMs 2000)) {
        if (-not $Quiet) {
            Write-Host ("[wifi-reorient] {0}:{1} closed/unreachable" -f $HostName, $Port)
        }
        return $false
    }
    foreach ($path in @('/browse', '/status.json', '/')) {
        $uri = "http://${HostName}:${Port}${path}"
        try {
            $resp = Invoke-DirectHttpGet -Uri $uri -TimeoutSec 3
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                if (-not $Quiet) {
                    Write-Host ("[wifi-reorient] Reachable ({0}): {1}" -f $resp.StatusCode, $uri) -ForegroundColor Green
                }
                return $true
            }
        } catch {
            if (-not $Quiet) {
                Write-Host ("[wifi-reorient] Not reachable: {0} ({1})" -f $uri, $_.Exception.Message)
            }
        }
    }
    return $false
}

function Wait-PhoneLanPageReachable {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $Port,
        [int] $TimeoutSec = 90,
        [int] $PollMs = 1500,
        [string] $Label = 'wifi-reorient'
    )
    if (Test-PhoneLanPageReachable -HostName $HostName -Port $Port) {
        return $true
    }
    Write-Host ("[{0}] Waiting up to {1}s for http://{2}:{3}/ ..." -f $Label, $TimeoutSec, $HostName, $Port)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $nextStatus = [datetime]::UtcNow.AddSeconds(5)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds ([Math]::Max(200, $PollMs))
        if (Test-PhoneLanPageReachable -HostName $HostName -Port $Port -Quiet) {
            Write-Host ("[{0}] Phone LAN is up" -f $Label) -ForegroundColor Green
            [void](Test-PhoneLanPageReachable -HostName $HostName -Port $Port)
            return $true
        }
        if ([datetime]::UtcNow -ge $nextStatus) {
            $left = [int][Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalSeconds)
            Write-Host ("[{0}] Still waiting for :{1} ({2} s left)..." -f $Label, $Port, $left)
            $nextStatus = [datetime]::UtcNow.AddSeconds(5)
        }
    }
    return $false
}

$target = Resolve-PhoneLanTarget
$hostName = [string]$target.Host
$port = [int]$target.Port
Write-Host ("[wifi-reorient] Target phone LAN: http://{0}:{1}/" -f $hostName, $port)

# --- 1. PC onto phoneLanHost subnet (companion startup gateway check) ---
if ($SkipGatewayReboot) {
    Write-Host '[wifi-reorient] Skipping gateway Wi‑Fi align (-SkipGatewayReboot)'
} else {
    if (-not (Test-Path -LiteralPath $GatewayPs1)) {
        throw "Missing $GatewayPs1"
    }
    $gwArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $GatewayPs1,
        '-NoWaitEnter', '-PhoneLanHost', $hostName
    )
    if (-not [string]::IsNullOrWhiteSpace($RebootScriptsRoot)) {
        $gwArgs += @('-RebootScriptsRoot', $RebootScriptsRoot)
    }
    Write-Host '[wifi-reorient] Aligning this PC gateway / Wi‑Fi to the app LAN subnet...'
    Write-Host ("[wifi-reorient] > pwsh {0}" -f ($gwArgs -join ' '))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Get-LoopSegmentsPwshExe) @gwArgs
        $gwCode = 0
        if ($null -ne $LASTEXITCODE) { $gwCode = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($gwCode -ne 0) {
        Write-Warning ("[wifi-reorient] Gateway Wi‑Fi align failed (exit {0})" -f $gwCode)
        Exit-WithEnter 1
    }
}

# --- 2. Phone↔PC subnet + wait for :8765 (may reboot off-subnet APs) ---
if ($SkipRecover) {
    Write-Host '[wifi-reorient] Skipping phone LAN recover (-SkipRecover)'
} else {
    if (-not (Test-Path -LiteralPath $RecoverPs1)) {
        throw "Missing $RecoverPs1"
    }
    Write-Host '[wifi-reorient] Running phone LAN recover (USB/pcapd + :8765 wait)...'
    $recoverArgs = @{
        NoWaitEnter         = $true
        PhoneLanHost        = $hostName
        LanPort             = $port
        RebootScriptsRoot   = $RebootScriptsRoot
        WaitBeforeRebootSec = 45
        WaitAfterRebootSec  = 90
        IntervalMs          = $IntervalMs
    }
    $recoverCode = 0
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        & $RecoverPs1 @recoverArgs
        $recoverCode = 0
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match 'LAN_RECOVER_EXIT:(\d+)') {
            $recoverCode = [int]$Matches[1]
        } else {
            Write-Warning ("[wifi-reorient] Phone LAN recover threw: {0}" -f $msg)
            $recoverCode = 1
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($recoverCode -eq 0) {
        Write-Host '[wifi-reorient] Phone LAN recover reported OK.' -ForegroundColor Green
    } else {
        Write-Warning ("[wifi-reorient] Phone LAN recover exit {0} — will check :8765 and maybe foreground the app." -f $recoverCode)
    }
}

# --- 3. If :8765 still down after bumping off the wrong AP → foreground app ---
if (Test-PhoneLanPageReachable -HostName $hostName -Port $port) {
    Write-Host '[wifi-reorient] LAN page reachable — ready for companion.' -ForegroundColor Green
    Exit-WithEnter 0
}

Write-Warning '[wifi-reorient] LAN page still down after Wi‑Fi reorient (often the app is not foreground after IPA install).'

if ($SkipUsbLaunch) {
    Write-Warning '[wifi-reorient] Skipping USB foreground (-SkipUsbLaunch). Open Loop Segments / Keep Alive on the phone.'
    Exit-WithEnter 1
}
if (-not (Test-Path -LiteralPath $LaunchPs1)) {
    throw "Missing $LaunchPs1"
}

$launchArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LaunchPs1, '-SkipMount'
)
Write-Host '[wifi-reorient] Foregrounding Loop Segments over USB...'
Write-Host ("[wifi-reorient] > pwsh {0}" -f ($launchArgs -join ' '))
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & (Get-LoopSegmentsPwshExe) @launchArgs
    $launchCode = 0
    if ($null -ne $LASTEXITCODE) { $launchCode = [int]$LASTEXITCODE }
} finally {
    $ErrorActionPreference = $prev
}

if ($launchCode -eq 3) {
    Write-Warning '[wifi-reorient] Phone is LOCKED (USB launch exit 3). Unlock it, then re-run.'
    Exit-WithEnter 3
}
if ($launchCode -ne 0) {
    Write-Warning ("[wifi-reorient] USB launch failed (exit {0}). Check USB / Developer Mode / trust." -f $launchCode)
}

if (Wait-PhoneLanPageReachable -HostName $hostName -Port $port -TimeoutSec $WaitAfterLaunchSec -PollMs $IntervalMs -Label 'wifi-reorient-after-launch') {
    Write-Host '[wifi-reorient] LAN page up after foregrounding the app — ready for companion.' -ForegroundColor Green
    Exit-WithEnter 0
}

Write-Warning '[wifi-reorient] LAN page still not reachable. Check phoneLanHost, Keep Alive, and Wi‑Fi.'
Exit-WithEnter 1
