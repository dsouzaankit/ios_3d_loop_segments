#Requires -Version 5.1
<#
.SYNOPSIS
  Reboot router Wi‑Fi when the PC/phone are on the wrong gateway, or recover LAN reachability.

.DESCRIPTION
  Reads phoneLanHost from loop-segments-windows.json (LAN page / app export host).

  Default: if the PC IPv4 default gateway is not on the same subnet as phoneLanHost,
  runs the matching Telnet Wi‑Fi restart under P:\all_scripts\5g_router_reboot.

  -ForceReboot: reboot the current default gateway even when subnets already match
  (e.g. after a low LAN-throughput probe).

  -RebootOffSubnetRouters: when the phone LAN page is unreachable, sequentially reboot
  every known router whose ROUTER_IP is outside the phoneLanHost subnet — so the phone
  can re-associate to the desired wireless LAN gateway on that subnet.

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
    [string] $PhoneLanHost = '',
    [string] $RebootScriptsRoot = 'P:\all_scripts\5g_router_reboot',
    [int] $PrefixLength = 0,
    [int] $SettleSecBetweenRouters = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
            $v4 = @($cfg.IPv4Address) | Select-Object -First 1
            if ($null -ne $v4 -and $null -ne $v4.PrefixLength -and [int]$v4.PrefixLength -gt 0) {
                $info.PrefixLength = [int]$v4.PrefixLength
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
                if ($addr -and $addr.PrefixLength -gt 0) {
                    $info.PrefixLength = [int]$addr.PrefixLength
                }
            } catch {}
        }
    } catch {}

    return $info
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
        [Parameter(Mandatory = $true)] $Runtime
    )
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
    if ($code -ne 0) {
        throw ('[gateway] Reboot script failed (exit {0}): {1}' -f $code, $ScriptPath)
    }
}

if ($SkipGatewayReboot) {
    Write-Host '[gateway] Skipping gateway Wi-Fi reboot check (-SkipGatewayReboot)'
    exit 0
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
        exit 0
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
        exit 0
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
            Invoke-RouterWifiRebootScript -ScriptPath $router.Script -Runtime $runtime
            Write-Host ('[gateway] Reboot finished for {0}.' -f $router.Ip) -ForegroundColor Green
        } catch {
            Write-Warning ("[gateway] Reboot failed for {0}: {1}" -f $router.Ip, $_.Exception.Message)
        }
        Write-Host ('[gateway] Waiting {0}s for Wi-Fi / phone to re-associate to the LAN-page gateway...' -f $settle)
        Start-Sleep -Seconds $settle
    }

    Write-Host '[gateway] Off-subnet router reboot pass complete. Retry phone LAN / rclone when the phone is back on the desired gateway.' -ForegroundColor Green
    exit 0
}

# --- Default / ForceReboot: act on the PC's current default gateway ---
if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
    Write-Warning ("[gateway] No IPv4 default gateway found - skip Wi-Fi reboot check (phone LAN page: {0})." -f $phoneHost)
    exit 0
}

# Avoid "$gateway[...]" parse ambiguity: never put $gatewayIp immediately before "[" in double quotes.
Write-Host ('[gateway] PC default gateway: {0} (/{1}) | phone LAN page: {2}' -f $gatewayIp, $prefix, $phoneHost)

$sameSubnet = Test-SameIpv4Subnet -IpA $gatewayIp -IpB $phoneHost -PrefixLen $prefix
if ($sameSubnet -and -not $ForceReboot) {
    Write-Host '[gateway] Gateway is on the same subnet as the app LAN page - no reboot.'
    exit 0
}
if (-not $sameSubnet -and $ForceReboot) {
    Write-Warning ('[gateway] -ForceReboot requested but gateway {0} is NOT on the same subnet as LAN page {1} - still rebooting current gateway.' -f $gatewayIp, $phoneHost)
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
if ($ForceReboot -and $sameSubnet) {
    Write-Host ('[gateway] Forcing Wi-Fi reboot on current gateway {0} (same subnet as LAN page {1}).' -f $gatewayIp, $phoneHost) -ForegroundColor Yellow
} else {
    Write-Host ('[gateway] Current gateway {0} is not on the same subnet as the app LAN page ({1}).' -f $gatewayIp, $phoneHost) -ForegroundColor Yellow
    Write-Host '[gateway] Rebooting Wi-Fi on the CURRENT gateway so all devices are forced to re-connect' -ForegroundColor Yellow
    Write-Host '[gateway] to the gateway that shares the app LAN page subnet.' -ForegroundColor Yellow
}
Write-Host ('[gateway] Python: {0}' -f $runtime.Display)
Invoke-RouterWifiRebootScript -ScriptPath $rebootScript -Runtime $runtime

if ($ForceReboot -and $sameSubnet) {
    Write-Host '[gateway] Reboot script finished (low-throughput / forced). Wait for Wi-Fi to settle, then retry.' -ForegroundColor Green
} else {
    Write-Host '[gateway] Reboot script finished. Devices should re-associate to the LAN-page subnet gateway; companion will wait for phone LAN next.' -ForegroundColor Green
}
exit 0
