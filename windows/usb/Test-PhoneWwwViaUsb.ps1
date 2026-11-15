#Requires -Version 7.0
<#
.SYNOPSIS
  If the iPhone is on USB, check its Wi-Fi -> www (like the LAN page's probe button), bounce
  the phone's Wi-Fi AP when www is down, then quit Loop Segments if it is in the foreground.

.DESCRIPTION
  deploy.ps1 runs this right after it triggers the IPA build, so the phone can reach iCloud /
  SideStore by the time the IPA lands.

  1. usbmux list (pymobiledevice3). No iPhone on USB: skipped (exit 0).
  2. Finds the phone's LAN page: the saved phoneLanHost first, then the phone's current Wi-Fi IP
     read over USB (pcapd). LAN page not reachable (app not running, or phone off this LAN):
     skipped, since there is nothing to ask.
  3. POST /wifi_www_probe.json: the app fetches a www URL over Wi-Fi only (cellular blocked).
  4. Probe failed and no export is running: lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1
     -BouncePhoneLanAp (reboots Wi-Fi on the AP serving the phone). An export in progress skips it.
  5. Loop Segments in the foreground (DVT proclist): quit it (DVT kill), since SideStore installs
     over a running app often hang. Runs after the probe, which needs the app. Skipped while an
     export runs, or with -NoQuit. A backgrounded app is left alone.
  6. LocalDevVPN (SideStore needs it): its tunnel process not running -> launch LocalDevVPN over
     USB (Connect-LocalDevVPNViaUsb.py); its "Auto-connect on launch" setting (switch it on once
     in LocalDevVPN) then connects, and this waits up to 15 s for the tunnel. -NoVpn skips it.

.EXITCODES
  0  www OK, or skipped (no USB phone, LAN page not reachable, export running)
  1  www failed and the AP bounce ran (see its exit code in the output)
  2  www failed and the AP bounce failed
  (Quitting the app and the VPN step do not change the exit code.)

.EXAMPLE
  .\Test-PhoneWwwViaUsb.ps1
#>
[CmdletBinding()]
param(
    # Probe only; never bounce the AP.
    [switch] $NoBounce,
    # Leave Loop Segments running even when it is in the foreground.
    [switch] $NoQuit,
    # Do not connect LocalDevVPN.
    [switch] $NoVpn
)

$ErrorActionPreference = 'Stop'
$WindowsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $WindowsDir 'lib\LoopSegments-Windows.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsPython.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsAltServer.ps1')

function Write-Www([string] $Text, [string] $Color = 'Gray') {
    Write-Host "[phone-www] $Text" -ForegroundColor $Color
}

function Invoke-PhoneHttp {
    # No system proxy (Clash), WebDAV login, works on Windows PowerShell 5.1 too.
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [string] $Method = 'GET',
        [string] $Body = '',
        [int] $TimeoutSec = 5
    )
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Timeout = [Math]::Max(1, $TimeoutSec) * 1000
    $req.ReadWriteTimeout = $req.Timeout
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $auth = Get-LoopSegmentsPhoneWebDavAuthHeader
    foreach ($k in $auth.Keys) { $req.Headers[$k] = [string]$auth[$k] }
    # [string] turns $null into '': only POST sends a body.
    if ($Method -ne 'GET') {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    $resp = $null
    try {
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] {
            if ($null -eq $_.Exception.Response) { throw }
            $resp = $_.Exception.Response
        }
        $r = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $text = $r.ReadToEnd(); $r.Close()
        return @{ StatusCode = [int]$resp.StatusCode; Body = $text }
    } finally {
        if ($null -ne $resp) { try { $resp.Close() } catch {} }
    }
}

function Get-JsonOrNull([string] $Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Test-LanPage([string] $HostName, [int] $Port) {
    # Two tries: a phone whose Wi-Fi radio is napping can take several seconds to answer the first.
    foreach ($try in 1..2) {
        try {
            $r = Invoke-PhoneHttp -Uri "http://${HostName}:${Port}/status.json" -TimeoutSec 8
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
            if ($r.StatusCode -eq 401) {
                Write-Www "LAN page at ${HostName}:$Port refused the login (check webdavPassword in loop-segments-windows.json)." Yellow
                return $false
            }
        } catch {}
    }
    return $false
}

function Get-ExportBusyReason([string] $HostName, [int] $Port) {
    try {
        $r = Invoke-PhoneHttp -Uri "http://${HostName}:${Port}/status.json" -TimeoutSec 5
        $j = Get-JsonOrNull $r.Body
    } catch { return $null }
    if ($null -eq $j) { return $null }
    $es = $j.PSObject.Properties['exportSource']
    if ($null -ne $es -and $null -ne $es.Value) {
        $ph = $es.Value.PSObject.Properties['phase']
        if ($null -ne $ph -and [string]$ph.Value -eq 'running') { return 'export running' }
    }
    $q = $j.PSObject.Properties['pendingExportQueue']
    if ($null -ne $q -and $null -ne $q.Value) {
        $c = $q.Value.PSObject.Properties['count']
        if ($null -ne $c -and [int]$c.Value -gt 0) { return "pending queue ($($c.Value))" }
    }
    return $null
}

# --- 1. iPhone on USB? ---
$rt = Get-LoopSegmentsPythonRuntime -RequirePymobiledevice3
if ($null -eq $rt) {
    Write-Www 'No Python with pymobiledevice3 - cannot check USB; skipped.' Yellow
    exit 0
}
$list = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @('-m', 'pymobiledevice3', 'usbmux', 'list')
if (-not (Test-LoopSegmentsUsbmuxListHasDevice -ExitCode $list.ExitCode -Lines $list.Lines)) {
    Write-Www 'No iPhone on USB - skipped the www check and the app quit.'
    exit 0
}
Write-Www 'iPhone found on USB.'

$script:ExportBusy = $null
$script:PhoneHost = $null
$script:PhonePort = 0
function Invoke-WwwCheck {
    # --- 2. Phone LAN page ---
    $port = Get-LoopSegmentsLanPort
    $settings = Get-LoopSegmentsWindowsSettings
    $hostName = ([string]$settings.phoneLanHost).Trim()
    if (-not $hostName -or -not (Test-LanPage $hostName $port)) {
        $tried = $hostName
        Write-Www "LAN page not reachable at $(if ($tried) { "${tried}:$port" } else { '(no phoneLanHost)' }); reading the phone's Wi-Fi IP over USB..."
        $usb = Get-LoopSegmentsIphoneLanIpv4ViaUsb -Quiet
        $hostName = $null
        if ($usb.Ok -and $usb.Ip -and $usb.Ip -ne $tried -and (Test-LanPage $usb.Ip $port)) {
            $hostName = $usb.Ip
        } elseif ($usb.Ok -and $usb.Ip) {
            Write-Www "Phone Wi-Fi IP is $($usb.Ip), but its LAN page does not answer (Loop Segments not running?) - skipped." Yellow
            return 0
        } else {
            Write-Www 'Could not read the phone Wi-Fi IP over USB (phone off Wi-Fi or locked?) - skipped.' Yellow
            return 0
        }
    }

    $script:PhoneHost = $hostName
    $script:PhonePort = $port

    # --- 3. Wi-Fi -> www probe on the phone ---
    $uri = "http://${hostName}:${port}/wifi_www_probe.json"
    Write-Www "POST $uri (Wi-Fi only on the phone; cellular blocked)..."
    $detail = $null
    try {
        $r = Invoke-PhoneHttp -Uri $uri -Method POST -Body '{}' -TimeoutSec 20
        $j = Get-JsonOrNull $r.Body
        if ($null -ne $j -and $null -ne $j.ok -and [bool]$j.ok) {
            $ms = if ($null -ne $j.durationMs) { " ($($j.durationMs) ms)" } else { '' }
            Write-Www "www OK$ms." Green
            return 0
        }
        $detail = if ($null -ne $j -and $j.error) { [string]$j.error }
                  elseif ($null -ne $j -and $null -ne $j.statusCode) { "HTTP $($j.statusCode)" }
                  else { "HTTP $($r.StatusCode)" }
    } catch {
        $detail = $_.Exception.Message
    }

    # --- 4. Bounce the phone's AP ---
    $busy = Get-ExportBusyReason $hostName $port
    $script:ExportBusy = $busy
    if ($busy) {
        Write-Www "www FAILED: $detail - AP bounce skipped ($busy)." Yellow
        return 0
    }
    if ($NoBounce) {
        Write-Www "www FAILED: $detail - AP bounce skipped (-NoBounce)." Yellow
        return 1
    }
    Write-Www "www FAILED: $detail - bouncing the phone's Wi-Fi AP..." Yellow
    $reboot = Join-Path $WindowsDir 'lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    & $shell -NoProfile -ExecutionPolicy Bypass -File $reboot -BouncePhoneLanAp -NoWaitEnter -PhoneLanHost $hostName | Out-Host
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Www 'AP bounce finished.' Green
        return 1
    }
    Write-Www "AP bounce exited $code." Red
    return 2
}

$code = Invoke-WwwCheck
# www OK skips the busy check above; never quit the app under a running export.
if (-not $script:ExportBusy -and $script:PhoneHost) {
    $script:ExportBusy = Get-ExportBusyReason $script:PhoneHost $script:PhonePort
}

# --- 5. Quit Loop Segments if it is in the foreground ---
if ($NoQuit) {
    Write-Www 'Foreground quit skipped (-NoQuit).'
} elseif ($script:ExportBusy) {
    Write-Www "Loop Segments left running ($script:ExportBusy)." Yellow
} else {
    $probePy = Join-Path $PSScriptRoot 'Probe-LoopSegmentsForeground.py'
    $fg = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @($probePy, 'com.loopsegments.app', '--kill')
    $blob = ($fg.Lines -join "`n")
    if ($blob -match '(?m)^KILLED\b') {
        Write-Www 'Loop Segments was in the foreground - quit it (SideStore can install over it now).' Green
    } elseif ($blob -match '(?m)^KILL_FAILED\b') {
        Write-Www 'Loop Segments is in the foreground, but quitting it failed (Developer Mode / tunnel?). Swipe it away by hand before installing.' Yellow
    } elseif ($blob -match '(?m)^NOT_FOREGROUND\b') {
        Write-Www 'Loop Segments is not in the foreground - left alone.'
    } else {
        Write-Www 'Could not tell whether Loop Segments is in the foreground - left alone.' Yellow
    }
}

# --- 6. LocalDevVPN connected (SideStore installs / refreshes need it) ---
if ($NoVpn) {
    Write-Www 'LocalDevVPN step skipped (-NoVpn).'
} else {
    $vpnPy = Join-Path $PSScriptRoot 'Connect-LocalDevVPNViaUsb.py'
    $vpn = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @($vpnPy, '--wait', '15')
    $blob = ($vpn.Lines -join "`n")
    if ($blob -match '(?m)^VPN_ALREADY_CONNECTED\b') {
        Write-Www 'LocalDevVPN already connected.' Green
    } elseif ($blob -match '(?m)^VPN_CONNECTED\b') {
        Write-Www 'LocalDevVPN: launched it and it connected (switched back off after the USB install).' Green
        # Install-LoopSegmentsIpaViaUsb.ps1 switches it off again once the new build is installed.
        try {
            @{ turnedOnAt = (Get-Date).ToString('o') } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $env:TEMP 'loopsegments-vpn-turned-on.json') -Encoding utf8
        } catch {}
    } elseif ($blob -match '(?m)^VPN_NOT_CONNECTED\b') {
        Write-Www 'LocalDevVPN: launched it, but it did not connect within 15 s. Switch on "Auto-connect on launch" in LocalDevVPN (once), or tap Connect.' Yellow
    } else {
        $why = (@($vpn.Lines | Where-Object { $_ -match '^(LAUNCH_FAILED|PROBE_FAILED|NO_DEVICE)' }) | Select-Object -First 1)
        Write-Www "LocalDevVPN: could not check or launch it over USB ($why). Connect it by hand before installing." Yellow
    }
}
exit $code
