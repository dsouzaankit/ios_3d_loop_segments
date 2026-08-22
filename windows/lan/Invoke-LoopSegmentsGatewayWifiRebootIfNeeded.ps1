# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Reboot router Wi-Fi when the PC/phone are on the wrong gateway, or recover LAN reachability.

.DESCRIPTION
  Reads phoneLanHost from loop-segments-windows.json (LAN page / app export host).

  Default: if the PC IPv4 default gateway is not on the same subnet as phoneLanHost,
  informs you, waits for tcp/23, reboots Wi‑Fi on that current gateway, then polls
  (WaitLanIpChangeSec, default 20s) until the PC gets a new LAN IP / gateway or the AP
  is back on tcp/23 after a drop. Windows can keep a stale Wi‑Fi lease while the radio
  is down; Clash TUN often changes the default route sooner. Then re-checks — looping up
  to MaxWrongSubnetRounds times (default 3). A failed telnet round waits and continues
  instead of aborting remaining rounds.

  -ForceReboot: reboot the current default gateway even when subnets already match
  (e.g. after a low LAN-throughput probe). Same-subnet ForceReboot is a single pass.

  -RebootOffSubnetRouters: when the phone LAN page is unreachable, sequentially reboot
  every known router whose ROUTER_IP is outside the phoneLanHost subnet — so the phone
  can re-associate to the desired wireless LAN gateway on that subnet.

  -RebootOtherRouters: reboot Wi-Fi on every known router except the PC's current
  default gateway (low-throughput recovery; leaves this PC's AP up).

  When run directly (double-click / console), waits for Enter before closing so you can
  read the result. Pass -NoWaitEnter when invoked as a child so the parent keeps a
  single prompt.

.EXAMPLE
  .\lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1

.EXAMPLE
  .\lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -ForceReboot

.EXAMPLE
  .\lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -RebootOffSubnetRouters
#>
[CmdletBinding()]
param(
    [switch] $SkipGatewayReboot,
    # Reboot Wi-Fi on the current default gateway even when it already shares the phone LAN subnet
    # (used after a low LAN-throughput probe).
    [switch] $ForceReboot,
    # Sequentially reboot all known routers whose IPs are outside the phone LAN page subnet
    # (used when the LAN page / rclone target cannot be reached).
    [switch] $RebootOffSubnetRouters,
    # Reboot every known router except the current default gateway (low LAN throughput).
    [switch] $RebootOtherRouters,
    [string] $PhoneLanHost = '',
    [string] $RebootScriptsRoot = 'P:\all_scripts\5g_router_reboot',
    [int] $PrefixLength = 0,
    [int] $SettleSecBetweenRouters = 8,
    # After a wrong-subnet reboot, poll this often for a new PC LAN IP / gateway.
    [ValidateRange(2, 60)]
    [int] $PollSecAfterReboot = 4,
    # Per-round wait after WifiRestart for this PC to drop the old AP and DHCP
    # (0 = wait forever). Stale Wi-Fi lease can keep the same IP+gw while tcp/23 is down.
    [ValidateRange(0, 3600)]
    [int] $WaitLanIpChangeSec = 20,
    # Wrong-subnet reboot rounds before giving up (default 3).
    [ValidateRange(1, 100)]
    [int] $MaxWrongSubnetRounds = 3,
    # Skip local Enter on fatal errors (companion parent prompts once instead).
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
    exit $ExitCode
}

function Wait-EnterOnError {
    param([int] $ExitCode = 1)
    Exit-WithEnter -ExitCode $ExitCode
}

# Pause on fatal errors when this script is the console entry (not via companion).
trap {
    Write-Host ""
    Write-Host ('[gateway] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($NoWaitEnter) {
        throw $_
    }
    Wait-EnterToClose
    exit 1
}

$PwshHelper = Join-Path $PSScriptRoot "..\lib\Get-LoopSegmentsPwsh.ps1"
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$WindowsDir = Split-Path -Parent $PSScriptRoot
$LibDir = Join-Path $WindowsDir "lib"
$PythonHelper = Join-Path $LibDir "Get-LoopSegmentsPython.ps1"
if (-not (Test-Path -LiteralPath $PythonHelper)) {
    throw "Missing shared Python helper: $PythonHelper"
}
. $PythonHelper

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

function Get-LoopSegmentsDefaultGatewayInfo {
    $info = [pscustomobject]@{
        Gateway      = $null
        LocalIp      = $null
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
            if ([string]::IsNullOrWhiteSpace($nextHop) -or $nextHop -eq '0.0.0.0') {
                continue
            }
            $info.Gateway = $nextHop.Trim()
            $v4 = @($cfg.IPv4Address) |
                Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if ($null -eq $v4) {
                $v4 = @($cfg.IPv4Address) | Select-Object -First 1
            }
            if ($null -ne $v4) {
                if ($v4.IPAddress) {
                    $info.LocalIp = ([string]$v4.IPAddress).Trim()
                }
                if ($null -ne $v4.PrefixLength -and [int]$v4.PrefixLength -gt 0) {
                    $info.PrefixLength = [int]$v4.PrefixLength
                }
            }
            return $info
        }
    } catch {
        # Fall through to Get-NetRoute
    }

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
                if ($addr) {
                    $info.LocalIp = ([string]$addr.IPAddress).Trim()
                    if ($addr.PrefixLength -gt 0) {
                        $info.PrefixLength = [int]$addr.PrefixLength
                    }
                }
            } catch {}
        }
    } catch {}

    return $info
}

function Test-RouterTcp23 {
    param(
        [Parameter(Mandatory = $true)][string] $Ip,
        [int] $TimeoutMs = 1500
    )
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($Ip.Trim(), 23, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close() } catch {}
        }
    }
}

function Wait-RouterTelnetReady {
    param(
        [Parameter(Mandatory = $true)][string] $Ip,
        [int] $TimeoutSec = 20,
        [int] $PollSec = 4
    )
    if (Test-RouterTcp23 -Ip $Ip) { return $true }
    $poll = [Math]::Max(2, $PollSec)
    $unlimited = ($TimeoutSec -le 0)
    $deadline = if ($unlimited) { [datetime]::MaxValue } else { [datetime]::UtcNow.AddSeconds($TimeoutSec) }
    Write-Host ('[gateway] Waiting for tcp/23 on {0} before telnet (AP still rebooting)...' -f $Ip) -ForegroundColor Yellow
    $lastLog = [datetime]::MinValue
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $poll
        if (Test-RouterTcp23 -Ip $Ip) {
            Write-Host ('[gateway] tcp/23 {0} is open.' -f $Ip) -ForegroundColor Green
            return $true
        }
        if (([datetime]::UtcNow - $lastLog).TotalSeconds -ge 15) {
            $lastLog = [datetime]::UtcNow
            $left = if ($unlimited) { '∞' } else { [int]($deadline - [datetime]::UtcNow).TotalSeconds }
            Write-Host ('[gateway] Still no tcp/23 on {0} ({1}s left)' -f $Ip, $left)
        }
    }
    Write-Warning ('[gateway] tcp/23 {0} still closed after {1}s' -f $Ip, $TimeoutSec)
    return $false
}

function Wait-PcLanIdentityChange {
    param(
        [string] $PreviousLocalIp = '',
        [string] $PreviousGateway = '',
        [int] $TimeoutSec = 20,
        [int] $PollSec = 4
    )
    $poll = [Math]::Max(2, $PollSec)
    $unlimited = ($TimeoutSec -le 0)
    $deadline = if ($unlimited) { [datetime]::MaxValue } else { [datetime]::UtcNow.AddSeconds($TimeoutSec) }
    $prevIp = if ($null -eq $PreviousLocalIp) { '' } else { $PreviousLocalIp.Trim() }
    $prevGw = if ($null -eq $PreviousGateway) { '' } else { $PreviousGateway.Trim() }

    if ($unlimited) {
        Write-Host ('[gateway] Waiting for PC LAN IP/gateway to change (was IP={0} gw={1}; poll {2}s; no timeout)...' -f `
            $(if ($prevIp) { $prevIp } else { '(none)' }),
            $(if ($prevGw) { $prevGw } else { '(none)' }),
            $poll)
    } else {
        Write-Host ('[gateway] Waiting up to {0}s for PC LAN IP/gateway to change (was IP={1} gw={2}; poll {3}s)...' -f `
            $TimeoutSec,
            $(if ($prevIp) { $prevIp } else { '(none)' }),
            $(if ($prevGw) { $prevGw } else { '(none)' }),
            $poll)
    }

    $lastLog = [datetime]::MinValue
    $sameUnchangedStreak = 0
    $sawDrop = $false
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $poll
        $cur = Get-LoopSegmentsDefaultGatewayInfo
        $curIp = if ($null -eq $cur.LocalIp) { '' } else { [string]$cur.LocalIp.Trim() }
        $curGw = if ($null -eq $cur.Gateway) { '' } else { [string]$cur.Gateway.Trim() }
        $telnetGw = if ($curGw) { $curGw } else { $prevGw }
        $tcp23 = if ($telnetGw) { Test-RouterTcp23 -Ip $telnetGw } else { $false }

        $ipChanged = (-not [string]::IsNullOrWhiteSpace($curIp)) -and ($curIp -ne $prevIp)
        $gwChanged = (-not [string]::IsNullOrWhiteSpace($curGw)) -and ($curGw -ne $prevGw)
        if ($ipChanged -or $gwChanged) {
            Write-Host ('[gateway] LAN identity changed: IP {0} -> {1} | gateway {2} -> {3}' -f `
                $(if ($prevIp) { $prevIp } else { '(none)' }),
                $(if ($curIp) { $curIp } else { '(none)' }),
                $(if ($prevGw) { $prevGw } else { '(none)' }),
                $(if ($curGw) { $curGw } else { '(none)' })) -ForegroundColor Green
            return $cur
        }

        # Windows often keeps a stale Wi-Fi lease while the AP is still down (no Clash TUN
        # to change the default route). Treat missing IP/gw OR closed tcp/23 as the drop.
        $lanUp = (-not [string]::IsNullOrWhiteSpace($curIp)) -and (-not [string]::IsNullOrWhiteSpace($curGw))
        if ((-not $lanUp) -or (-not $tcp23)) {
            $sawDrop = $true
            $sameUnchangedStreak = 0
        }

        # Same IP+gateway AND tcp/23 open after a drop = AP is actually back.
        $unchanged = $lanUp -and $tcp23 -and $prevIp -and $prevGw -and ($curIp -eq $prevIp) -and ($curGw -eq $prevGw)
        if ($sawDrop -and $unchanged) {
            $sameUnchangedStreak++
            if ($sameUnchangedStreak -ge 2) {
                Write-Host ('[gateway] Bounce left LAN unchanged (IP={0} gw={1}; tcp/23 open) — stopping wait.' -f $curIp, $curGw) -ForegroundColor Yellow
                return $cur
            }
        } elseif (-not $unchanged) {
            $sameUnchangedStreak = 0
        }

        if (([datetime]::UtcNow - $lastLog).TotalSeconds -ge 15) {
            $lastLog = [datetime]::UtcNow
            $left = if ($unlimited) { '∞' } else { [int]($deadline - [datetime]::UtcNow).TotalSeconds }
            $tcpNote = if ($telnetGw) { $(if ($tcp23) { 'tcp/23 open' } else { 'tcp/23 closed' }) } else { 'no gw' }
            Write-Host ('[gateway] Still waiting for new LAN IP/gateway... (now IP={0} gw={1}; {2}; {3}s left)' -f `
                $(if ($curIp) { $curIp } else { '(none)' }),
                $(if ($curGw) { $curGw } else { '(none)' }),
                $tcpNote,
                $left)
        }
    }

    Write-Warning '[gateway] Timed out waiting for LAN IP/gateway change — re-checking current identity.'
    return (Get-LoopSegmentsDefaultGatewayInfo)
}

function Resolve-PhoneLanHost {
    param([string] $Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }
    $settingsPath = Join-Path $WindowsDir "loop-segments-windows.json"
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "Missing $settingsPath (need phoneLanHost for gateway subnet check)."
    }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $hostName = [string]$settings.phoneLanHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw "phoneLanHost is empty in $settingsPath"
    }
    return $hostName.Trim()
}

function Find-GatewayWifiRebootScript {
    param(
        [Parameter(Mandatory = $true)][string] $GatewayIp,
        [Parameter(Mandatory = $true)][string] $ScriptsRoot
    )
    if (-not (Test-Path -LiteralPath $ScriptsRoot)) {
        throw "Router reboot scripts folder not found: $ScriptsRoot"
    }

    $commons = @(Get-ChildItem -LiteralPath $ScriptsRoot -Filter 'wifi_dx_common_*.py' -File -ErrorAction SilentlyContinue)
    foreach ($common in $commons) {
        $text = Get-Content -LiteralPath $common.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        # Active assignment only (ignore commented ROUTER_IP = ...)
        if ($text -notmatch '(?m)^ROUTER_IP\s*=\s*"([^"]+)"') { continue }
        $routerIp = $Matches[1].Trim()
        if ($routerIp -ne $GatewayIp) { continue }
        if ($common.BaseName -notmatch '^wifi_dx_common_(.+)$') { continue }
        $model = $Matches[1]
        $candidate = Join-Path $ScriptsRoot "telnet_reboot_wlan_$model.py"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    # Fallback: telnet_reboot_wlan_*.py whose text mentions this gateway IP
    $reboots = @(Get-ChildItem -LiteralPath $ScriptsRoot -Filter 'telnet_reboot_wlan_*.py' -File -ErrorAction SilentlyContinue)
    foreach ($script in $reboots) {
        $text = Get-Content -LiteralPath $script.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match [regex]::Escape($GatewayIp)) {
            return $script.FullName
        }
    }

    return $null
}

function Get-KnownRouterRebootTargets {
    param([Parameter(Mandatory = $true)][string] $ScriptsRoot)
    $list = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $ScriptsRoot)) {
        return @()
    }
    $commons = @(Get-ChildItem -LiteralPath $ScriptsRoot -Filter 'wifi_dx_common_*.py' -File -ErrorAction SilentlyContinue)
    foreach ($common in $commons) {
        $text = Get-Content -LiteralPath $common.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -notmatch '(?m)^ROUTER_IP\s*=\s*"([^"]+)"') { continue }
        $routerIp = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($routerIp)) { continue }
        if ($common.BaseName -notmatch '^wifi_dx_common_(.+)$') { continue }
        $model = $Matches[1]
        $scriptPath = Join-Path $ScriptsRoot "telnet_reboot_wlan_$model.py"
        if (-not (Test-Path -LiteralPath $scriptPath)) { continue }
        $dup = $false
        foreach ($existing in $list) {
            if ($existing.Ip -eq $routerIp) { $dup = $true; break }
        }
        if ($dup) { continue }
        [void]$list.Add([pscustomobject]@{
            Ip     = $routerIp
            Model  = $model
            Script = $scriptPath
        })
    }
    return @($list.ToArray())
}

function Invoke-RouterWifiRebootScript {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)] $Runtime,
        [string] $RouterIp = '',
        [int] $TelnetWaitSec = 20,
        [int] $PollSec = 4,
        [switch] $AllowFail
    )
    if (-not [string]::IsNullOrWhiteSpace($RouterIp)) {
        [void](Wait-RouterTelnetReady -Ip $RouterIp -TimeoutSec $TelnetWaitSec -PollSec $PollSec)
    }

    $runOnce = {
        Write-Host ('[gateway] Running: {0}' -f $ScriptPath) -ForegroundColor Cyan
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $allArgs = @($Runtime.Prefix) + @($ScriptPath)
            & $Runtime.Exe @allArgs
            $code = 0
            if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
        } finally {
            $ErrorActionPreference = $prev
        }
        $code
    }.GetNewClosure()

    $code = & $runOnce
    if ($code -ne 0 -and -not [string]::IsNullOrWhiteSpace($RouterIp)) {
        Write-Warning ('[gateway] Telnet reboot failed (exit {0}) — waiting for tcp/23 then retrying once...' -f $code)
        [void](Wait-RouterTelnetReady -Ip $RouterIp -TimeoutSec $TelnetWaitSec -PollSec $PollSec)
        $code = & $runOnce
    }
    if ($code -ne 0) {
        $msg = ('[gateway] Reboot script failed (exit {0}): {1}' -f $code, $ScriptPath)
        if ($AllowFail) {
            Write-Warning $msg
            return $false
        }
        throw $msg
    }
    return $true
}

try {
if ($SkipGatewayReboot) {
    Write-Host '[gateway] Skipping gateway Wi-Fi reboot check (-SkipGatewayReboot)'
    Exit-WithEnter 0
}

$phoneHost = Resolve-PhoneLanHost -Override $PhoneLanHost
$gwInfo = Get-LoopSegmentsDefaultGatewayInfo
$gatewayIp = [string]$gwInfo.Gateway
$prefix = if ($PrefixLength -gt 0) { $PrefixLength } else { [int]$gwInfo.PrefixLength }
if ($prefix -le 0) { $prefix = 24 }

$runtime = Get-LoopSegmentsPythonRuntime
if (-not $runtime) {
    throw @"
[gateway] No usable Python found to run the router reboot script.
$(Get-LoopSegmentsPythonInstallHint)
"@
}

# --- Off-subnet recovery: reboot every known router NOT on the phone LAN page subnet ---
if ($RebootOffSubnetRouters) {
    Write-Host ''
    Write-Host ('[gateway] Phone LAN page {0} is unreachable (or rclone cannot find it).' -f $phoneHost) -ForegroundColor Yellow
    Write-Host '[gateway] Attempting to get the phone re-connected on the desired wireless LAN gateway' -ForegroundColor Yellow
    Write-Host '[gateway] by sequentially rebooting Wi-Fi on routers whose IPs are outside that LAN page subnet.' -ForegroundColor Yellow

    $allRouters = @(Get-KnownRouterRebootTargets -ScriptsRoot $RebootScriptsRoot)
    if ($allRouters.Count -eq 0) {
        Write-Warning ("[gateway] No router reboot scripts found under {0}" -f $RebootScriptsRoot)
        Exit-WithEnter 0
    }

    $offSubnet = @()
    foreach ($router in $allRouters) {
        if (Test-SameIpv4Subnet -IpA $router.Ip -IpB $phoneHost -PrefixLen $prefix) {
            Write-Host ('[gateway] Keep (same subnet as LAN page): {0} ({1})' -f $router.Ip, $router.Model)
        } else {
            $offSubnet += $router
        }
    }

    if ($offSubnet.Count -eq 0) {
        Write-Host '[gateway] No off-subnet routers to reboot (all known ROUTER_IPs share the LAN page subnet).'
        Exit-WithEnter 0
    }

    Write-Host ('[gateway] Python: {0}' -f $runtime.Display)
    $settle = [Math]::Max(1, $SettleSecBetweenRouters)
    $index = 0
    foreach ($router in $offSubnet) {
        $index++
        Write-Host ''
        Write-Host ('[gateway] ({0}/{1}) Rebooting off-subnet router {2} ({3}) so clients can leave that AP...' -f `
            $index, $offSubnet.Count, $router.Ip, $router.Model) -ForegroundColor Cyan
        try {
            Invoke-RouterWifiRebootScript -ScriptPath $router.Script -Runtime $runtime `
                -RouterIp $router.Ip -TelnetWaitSec $WaitLanIpChangeSec -PollSec $PollSecAfterReboot
            Write-Host ('[gateway] Reboot finished for {0}.' -f $router.Ip) -ForegroundColor Green
        } catch {
            Write-Warning ("[gateway] Reboot failed for {0}: {1}" -f $router.Ip, $_.Exception.Message)
        }
        Write-Host ('[gateway] Waiting {0}s for Wi-Fi / phone to re-associate to the LAN-page gateway...' -f $settle)
        Start-Sleep -Seconds $settle
    }

    Write-Host '[gateway] Off-subnet router reboot pass complete. Retry phone LAN / rclone when the phone is back on the desired gateway.' -ForegroundColor Green
    Exit-WithEnter 0
}

# --- Low-throughput: reboot every known router except the PC's current gateway ---
if ($RebootOtherRouters) {
    Write-Host ''
    Write-Host '[gateway] Low LAN throughput: rebooting Wi-Fi on other routers/gateways (not the current default gateway).' -ForegroundColor Yellow

    $allRouters = @(Get-KnownRouterRebootTargets -ScriptsRoot $RebootScriptsRoot)
    if ($allRouters.Count -eq 0) {
        Write-Warning ("[gateway] No router reboot scripts found under {0}" -f $RebootScriptsRoot)
        Exit-WithEnter 0
    }

    $others = @()
    foreach ($router in $allRouters) {
        if ($gatewayIp -and ($router.Ip -eq $gatewayIp)) {
            Write-Host ('[gateway] Keep (current default gateway): {0} ({1})' -f $router.Ip, $router.Model)
        } else {
            $others += $router
        }
    }

    if ($others.Count -eq 0) {
        Write-Host '[gateway] No other routers to reboot (only the current gateway is known).'
        Exit-WithEnter 0
    }

    Write-Host ('[gateway] Python: {0}' -f $runtime.Display)
    $settle = [Math]::Max(1, $SettleSecBetweenRouters)
    $index = 0
    foreach ($router in $others) {
        $index++
        Write-Host ''
        Write-Host ('[gateway] ({0}/{1}) Rebooting other router {2} ({3})...' -f `
            $index, $others.Count, $router.Ip, $router.Model) -ForegroundColor Cyan
        try {
            Invoke-RouterWifiRebootScript -ScriptPath $router.Script -Runtime $runtime `
                -RouterIp $router.Ip -TelnetWaitSec $WaitLanIpChangeSec -PollSec $PollSecAfterReboot
            Write-Host ('[gateway] Reboot finished for {0}.' -f $router.Ip) -ForegroundColor Green
        } catch {
            Write-Warning ("[gateway] Reboot failed for {0}: {1}" -f $router.Ip, $_.Exception.Message)
        }
        Write-Host ('[gateway] Waiting {0}s before the next router / settle...' -f $settle)
        Start-Sleep -Seconds $settle
    }

    Write-Host '[gateway] Other-router Wi-Fi reboot pass complete.' -ForegroundColor Green
    Exit-WithEnter 0
}

# --- Default / ForceReboot: act on the PC's current default gateway ---
$gwInfo = Get-LoopSegmentsDefaultGatewayInfo
$gatewayIp = [string]$gwInfo.Gateway
$localIp = [string]$gwInfo.LocalIp
$prefix = if ($PrefixLength -gt 0) { $PrefixLength } else { [int]$gwInfo.PrefixLength }
if ($prefix -le 0) { $prefix = 24 }

if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
    Write-Warning ("[gateway] No IPv4 default gateway found - skip Wi-Fi reboot check (phone LAN page: {0})." -f $phoneHost)
    Exit-WithEnter 0
}

# Avoid "$gateway[...]" parse ambiguity: never put $gatewayIp immediately before "[" in double quotes.
Write-Host ('[gateway] PC LAN IP: {0} | default gateway: {1} (/{2}) | phone LAN page: {3}' -f `
    $(if ($localIp) { $localIp } else { '(unknown)' }), $gatewayIp, $prefix, $phoneHost)

$sameSubnet = Test-SameIpv4Subnet -IpA $gatewayIp -IpB $phoneHost -PrefixLen $prefix
if ($sameSubnet -and -not $ForceReboot) {
    Write-Host '[gateway] Gateway is on the same subnet as the app LAN page - no reboot.'
    Exit-WithEnter 0
}

# Same-subnet ForceReboot (low-throughput recovery): single pass, then exit.
if ($ForceReboot -and $sameSubnet) {
    $rebootScript = Find-GatewayWifiRebootScript -GatewayIp $gatewayIp -ScriptsRoot $RebootScriptsRoot
    if (-not $rebootScript) {
        throw (@"
[gateway] No matching reboot script for current gateway {0} under {1}
(expected wifi_dx_common_*.py with ROUTER_IP = "{0}" -> telnet_reboot_wlan_*.py).
Phone LAN page: {2}
"@ -f $gatewayIp, $RebootScriptsRoot, $phoneHost)
    }
    Write-Host ""
    Write-Host ('[gateway] Forcing Wi-Fi reboot on current gateway {0} (same subnet as LAN page {1}).' -f $gatewayIp, $phoneHost) -ForegroundColor Yellow
    Write-Host ('[gateway] Python: {0}' -f $runtime.Display)
    Invoke-RouterWifiRebootScript -ScriptPath $rebootScript -Runtime $runtime `
        -RouterIp $gatewayIp -TelnetWaitSec $WaitLanIpChangeSec -PollSec $PollSecAfterReboot
    Write-Host '[gateway] Reboot script finished (low-throughput / forced). Wait for Wi-Fi to settle, then retry.' -ForegroundColor Green
    Exit-WithEnter 0
}

# Wrong subnet (with or without -ForceReboot): reboot → wait for new LAN IP → re-check → loop.
Write-Host ""
Write-Host ('[gateway] Current gateway {0} is NOT on the same subnet as the app LAN page ({1}).' -f $gatewayIp, $phoneHost) -ForegroundColor Yellow
Write-Host '[gateway] Will reboot Wi-Fi on the CURRENT gateway, wait for this PC to get a new LAN IP,' -ForegroundColor Yellow
Write-Host ('[gateway] then re-check — up to {0} rounds until the gateway shares the LAN page subnet.' -f $MaxWrongSubnetRounds) -ForegroundColor Yellow
Write-Host ('[gateway] Python: {0}' -f $runtime.Display)

$round = 0
while ($true) {
    $gwInfo = Get-LoopSegmentsDefaultGatewayInfo
    $gatewayIp = [string]$gwInfo.Gateway
    $localIp = [string]$gwInfo.LocalIp
    $prefix = if ($PrefixLength -gt 0) { $PrefixLength } else { [int]$gwInfo.PrefixLength }
    if ($prefix -le 0) { $prefix = 24 }

    if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
        Write-Warning '[gateway] No default gateway right now — waiting for LAN to return...'
        $gwInfo = Wait-PcLanIdentityChange `
            -PreviousLocalIp $localIp `
            -PreviousGateway '' `
            -TimeoutSec $WaitLanIpChangeSec `
            -PollSec $PollSecAfterReboot
        continue
    }

    $sameSubnet = Test-SameIpv4Subnet -IpA $gatewayIp -IpB $phoneHost -PrefixLen $prefix
    if ($sameSubnet) {
        Write-Host ('[gateway] OK — gateway {0} now shares the app LAN page subnet ({1}). Continuing.' -f $gatewayIp, $phoneHost) -ForegroundColor Green
        Exit-WithEnter 0
    }

    $round++
    if ($round -gt $MaxWrongSubnetRounds) {
        Write-Host ""
        Write-Host ('[gateway] Gave up after {0} wrong-subnet reboot rounds (gateway still {1}, LAN page {2}).' -f `
            $MaxWrongSubnetRounds, $gatewayIp, $phoneHost) -ForegroundColor Red
        Write-Host '[gateway] Fix Wi-Fi / connect to the LAN-page subnet gateway, then re-run the companion.' -ForegroundColor Yellow
        Wait-EnterOnError -ExitCode 1
    }

    $rebootScript = Find-GatewayWifiRebootScript -GatewayIp $gatewayIp -ScriptsRoot $RebootScriptsRoot
    if (-not $rebootScript) {
        throw (@"
[gateway] No matching reboot script for current gateway {0} under {1}
(expected wifi_dx_common_*.py with ROUTER_IP = "{0}" -> telnet_reboot_wlan_*.py).
Phone LAN page: {2}
"@ -f $gatewayIp, $RebootScriptsRoot, $phoneHost)
    }

    Write-Host ""
    Write-Host ('[gateway] Round {0}: PC IP={1} gateway={2} still off LAN-page subnet {3} — rebooting current gateway Wi-Fi...' -f `
        $round,
        $(if ($localIp) { $localIp } else { '(unknown)' }),
        $gatewayIp,
        $phoneHost) -ForegroundColor Cyan
    $rebootOk = Invoke-RouterWifiRebootScript -ScriptPath $rebootScript -Runtime $runtime `
        -RouterIp $gatewayIp -TelnetWaitSec $WaitLanIpChangeSec -PollSec $PollSecAfterReboot -AllowFail
    if ($rebootOk) {
        Write-Host '[gateway] Reboot command finished. Waiting for this PC to reassociate and get another LAN IP...' -ForegroundColor Green
    } else {
        Write-Warning '[gateway] Reboot script failed this round (AP may still be down). Waiting for LAN before the next round...'
    }

    [void](Wait-PcLanIdentityChange `
        -PreviousLocalIp $localIp `
        -PreviousGateway $gatewayIp `
        -TimeoutSec $WaitLanIpChangeSec `
        -PollSec $PollSecAfterReboot)
}
} catch {
    Write-Host ""
    Write-Host ('[gateway] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Wait-EnterOnError -ExitCode 1
}