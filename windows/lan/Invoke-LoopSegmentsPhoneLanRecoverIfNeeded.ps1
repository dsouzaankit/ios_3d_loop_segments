# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Bring the phone onto the PC/AltServer subnet, then wait for the Loop Segments LAN page.

.DESCRIPTION
  Prefers USB/pcapd via env_setup\altserver_refresh\Invoke-AltServerPhoneSubnetIfNeeded.ps1
  (pymobiledevice3 phone Wi-Fi IP vs this PC's LAN). If the phone is already on a PC subnet,
  waits for http://phoneLanHost:8765/ and does not reboot routers just because the app is down.

  If USB is missing or pcapd finds no Wi-Fi IPv4, falls back to: wait for :8765,
  then sequentially reboot routers whose ROUTER_IP is outside that subnet (via
  Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -RebootOffSubnetRouters), then wait again.

  When run directly, waits for Enter before closing. Pass -NoWaitEnter when invoked
  in-process (companion / rclone) so Exit-WithEnter throws LAN_RECOVER_EXIT:<code>
  instead of killing the caller.

.EXAMPLE
  .\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1

.EXAMPLE
  .\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1 -WaitBeforeRebootSec 0 -NoWaitEnter
#>
[CmdletBinding()]
param(
    [string] $PhoneLanHost = '',
    [int] $LanPort = 0,
    [ValidateRange(0, 600)]
    [int] $WaitBeforeRebootSec = 45,
    [ValidateRange(5, 600)]
    [int] $WaitAfterRebootSec = 90,
    [int] $IntervalMs = 1500,
    [string] $RebootScriptsRoot = 'P:\all_scripts\5g_router_reboot',
    [switch] $SkipRecover,
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    if ($NoWaitEnter) {
        throw "LAN_RECOVER_EXIT:$ExitCode"
    }
    exit $ExitCode
}

trap {
    if ("$($_.Exception.Message)" -match '^LAN_RECOVER_EXIT:') { throw $_ }
    Write-Host ""
    Write-Host ('[lan-recover] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($NoWaitEnter) {
        throw $_
    }
    Wait-EnterToClose
    exit 1
}

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
Write-Host '[lan-recover] Started.'
try { [Console]::Out.Flush() } catch {}

$WindowsDir = Split-Path -Parent $PSScriptRoot

function Test-TcpPortOpen {
    param(
        [string] $HostName,
        [int] $Port,
        [int] $TimeoutMs = 2000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close() } catch {}
        }
    }
}

function Invoke-DirectHttpGet {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [int] $TimeoutSec = 3
    )
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
    } finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch {}
            try { $resp.Dispose() } catch {}
        }
    }
}

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

function Test-PhoneLanPageReachable {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $Port,
        [switch] $Quiet
    )
    if (-not $Quiet) {
        Write-Host ("[lan-recover] TCP probe {0}:{1} ..." -f $HostName, $Port)
    }
    if (-not (Test-TcpPortOpen -HostName $HostName -Port $Port -TimeoutMs 2000)) {
        if (-not $Quiet) {
            Write-Host '[lan-recover] Port closed/unreachable'
        }
        return $false
    }
    foreach ($path in @('/browse', '/status.json')) {
        $uri = "http://${HostName}:${Port}${path}"
        try {
            if (-not $Quiet) {
                Write-Host ("[lan-recover] HTTP probe {0} (direct, no proxy) ..." -f $uri)
            }
            $resp = Invoke-DirectHttpGet -Uri $uri -TimeoutSec 3
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                if (-not $Quiet) {
                    Write-Host ("[lan-recover] Reachable ({0}): {1}" -f $resp.StatusCode, $uri)
                }
                return $true
            }
        } catch {
            if (-not $Quiet) {
                Write-Host ("[lan-recover] Not reachable: {0} ({1})" -f $uri, $_.Exception.Message)
            }
        }
    }
    return $false
}

function Wait-PhoneLanPageReachable {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $Port,
        [int] $TimeoutSec = 45,
        [int] $PollMs = 1500,
        [string] $Label = 'lan-recover'
    )
    if ($TimeoutSec -le 0) {
        return (Test-PhoneLanPageReachable -HostName $HostName -Port $Port)
    }
    if (Test-PhoneLanPageReachable -HostName $HostName -Port $Port) {
        return $true
    }
    Write-Host ("[{0}] Waiting up to {1}s for phone LAN (app may still be starting)..." -f $Label, $TimeoutSec)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $nextStatus = [datetime]::UtcNow.AddSeconds(5)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds ([Math]::Max(200, $PollMs))
        if (Test-PhoneLanPageReachable -HostName $HostName -Port $Port -Quiet) {
            Write-Host ("[{0}] Phone LAN is up" -f $Label)
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

try {
    $target = Resolve-PhoneLanTarget
    $hostName = [string]$target.Host
    $port = [int]$target.Port

    if ($SkipRecover) {
        Write-Host '[lan-recover] Skipping phone LAN recovery (-SkipRecover)'
        Exit-WithEnter 0
    }

    $usbSubnetOk = $false
    $repoRoot = Split-Path -Parent $WindowsDir
    $altRefreshDir = $null
    foreach ($candidate in @(
            (Join-Path $repoRoot 'env_setup\altserver_refresh')
            (Join-Path $repoRoot 'env_setup\altserver_refresh_scripts')
            (Join-Path $repoRoot 'env_setup\altserver_refresh_script')
            'P:\all_scripts\iOS apps\env_setup\altserver_refresh'
            'P:\all_scripts\iOS apps\env_setup\altserver_refresh_scripts'
            'P:\all_scripts\iOS apps\env_setup\altserver_refresh_script'
        )) {
        if (Test-Path -LiteralPath $candidate) {
            $altRefreshDir = $candidate
            break
        }
    }
    $altSubnetPs1 = if ($altRefreshDir) {
        Join-Path $altRefreshDir 'Invoke-AltServerPhoneSubnetIfNeeded.ps1'
    } else {
        ''
    }
    if (Test-Path -LiteralPath $altSubnetPs1) {
        Write-Host '[lan-recover] Using USB/pcapd AltServer subnet check (pymobiledevice3)...'
        Write-Host ("[lan-recover] > {0} -NoWaitEnter" -f $altSubnetPs1)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        $altCode = 0
        try {
            # Same pwsh process so [altserver-subnet] lines show immediately (child pwsh from P: was silent).
            & $altSubnetPs1 -NoWaitEnter -RebootScriptsRoot $RebootScriptsRoot
            if ($null -ne $LASTEXITCODE) { $altCode = [int]$LASTEXITCODE }
        } catch {
            $msg = [string]$_.Exception.Message
            if ($msg -match 'ALTSERVER_SUBNET_EXIT:(\d+)') {
                $altCode = [int]$Matches[1]
            } else {
                Write-Warning ("[lan-recover] AltServer subnet check threw: {0} — falling back to LAN-page wait + off-subnet router reboots." -f $msg)
                $altCode = 4
            }
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($altCode -eq 0) {
            Write-Host '[lan-recover] Phone and PC/AltServer are on the same subnet.'
            $usbSubnetOk = $true
        } elseif ($altCode -eq 2 -or $altCode -eq 4) {
            Write-Host ('[lan-recover] USB/pcapd could not give a phone LAN IP (exit {0}) — falling back to LAN-page wait + off-subnet router reboots.' -f $altCode)
        } else {
            Write-Warning ("[lan-recover] AltServer subnet refresh failed (exit {0})" -f $altCode)
            Exit-WithEnter $altCode
        }
    }

    Write-Host ("[lan-recover] Expected phone LAN page: http://{0}:{1}/" -f $hostName, $port)

    if (Wait-PhoneLanPageReachable -HostName $hostName -Port $port -TimeoutSec $WaitBeforeRebootSec -PollMs $IntervalMs -Label 'lan-recover') {
        Write-Host '[lan-recover] Phone LAN page is reachable - no off-subnet router reboot.'
        Exit-WithEnter 0
    }

    if ($usbSubnetOk) {
        Write-Warning '[lan-recover] Phone is on the PC/AltServer subnet but :8765 is still down (open Loop Segments / Keep Alive). Skipping off-subnet router reboots.'
        Exit-WithEnter 1
    }

    $rebootPs1 = Join-Path $PSScriptRoot 'Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $rebootPs1)) {
        throw "Missing $rebootPs1"
    }

    Write-Host '[lan-recover] Phone LAN page not reachable - rebooting off-subnet routers so the phone can rejoin the expected wireless LAN gateway...'
    # Gateway reboot still uses exit (no throw-exit pattern), so a nested pwsh is
    # required — in-process & would kill this recover / companion session.
    $psArgs = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $rebootPs1
        '-RebootOffSubnetRouters'
        '-NoWaitEnter'
        '-PhoneLanHost'
        $hostName
    )
    if (-not [string]::IsNullOrWhiteSpace($RebootScriptsRoot)) {
        $psArgs += @('-RebootScriptsRoot', $RebootScriptsRoot)
    }
    Write-Host ("[lan-recover] > pwsh {0}" -f ($psArgs -join ' '))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Get-LoopSegmentsPwshExe) @psArgs
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        Write-Warning ("[lan-recover] Off-subnet router reboot pass failed (exit {0})" -f $code)
        Exit-WithEnter 1
    }

    if (Wait-PhoneLanPageReachable -HostName $hostName -Port $port -TimeoutSec $WaitAfterRebootSec -PollMs $IntervalMs -Label 'lan-recover-after-reboot') {
        Write-Host '[lan-recover] Phone LAN is up after off-subnet router reboot pass.' -ForegroundColor Green
        Exit-WithEnter 0
    }

    Write-Warning '[lan-recover] Phone LAN still not reachable after off-subnet router reboots (open Loop Segments / Keep Alive, check phoneLanHost / Wi-Fi).'
    Exit-WithEnter 1
} catch {
    if ("$($_.Exception.Message)" -match '^LAN_RECOVER_EXIT:') { throw }
    Write-Host ""
    Write-Host ('[lan-recover] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Exit-WithEnter 1
}
