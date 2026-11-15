#Requires -Version 7.0
<#
.SYNOPSIS
  Start a SideStore install of the local LoopSegments.ipa on the USB iPhone: you tap Install once.

.DESCRIPTION
  deploy.ps1 runs this after it downloads the IPA. Steps:
  1. iPhone on USB (usbmux)? No: skipped (exit 0). Already on this IPA's build: skipped.
  2. Moves the phone AND this PC off the phone LAN: SideStore needs www over Wi-Fi to sign, and the
     phone LAN Wi-Fi has no gateway on the phone (LAN only, 5G for internet). The phone LAN is
     phoneLanHost's /24 from loop-segments-windows.json.
     Phone: its Wi-Fi IP is read over USB (DVT network monitor: its own address on its TCP connections
     over en0; none = no www on Wi-Fi = the phone LAN). On the phone LAN: bounces that AP (lan\Invoke-LoopSegments-
     GatewayWifiRebootIfNeeded.ps1 -BouncePhoneLanAp), and the phone hops to another saved Wi-Fi
     (waits up to 150 s). Then waits for the bounced AP to show up again in this PC's Wi-Fi scan,
     plus 15 s (cap -SettleSec 120), so a hop back happens before SideStore downloads; a hop back
     means another bounce (2 rounds). -NoBounce skips the bounce.
     PC: needs an IP on the phone's new /24. Already there (the bounce usually moves it too): stays.
     Otherwise connects to ipaInstallWifiProfile (config, optional) or else each saved Wi-Fi
     profile in range, in Windows' priority order. Both stay on that Wi-Fi afterwards: the web
     companion's start-up network check moves them back to the phone LAN.
     Then serves the IPA once at http://<PC IP>:<Port>/<random>/LoopSegments.ipa (plain TCP
     listener: no admin / URL ACL; PowerShell 7 needs an inbound firewall allow).
  3. Launches Loop Segments over USB with -openURL sidestore://install?url=<that link>
     (Open-LinkViaLoopSegments.py). Build 428+ opens the link and quits itself, and SideStore shows
     its Install dialog: tap Install. LocalDevVPN must be connected (Prepare-PhoneForSideStoreViaUsb.ps1 does it).
  4. A download cut short (-1005: the phone hopped Wi-Fi mid-transfer) is retried: both are put
     back off the phone LAN and the install link is opened again (-Attempts 3; tap Install each
     time). Stops serving once SideStore has downloaded the whole file (or after -WaitSec), then waits up to
     -InstallWaitSec for the phone to report the new build.
  5. LocalDevVPN back to how it was: if Prepare-PhoneForSideStoreViaUsb.ps1 switched it on for this deploy
     (marker %TEMP%\loopsegments-vpn-turned-on.json), switches it off again (localdevvpn://disable,
     opened the same way) once the new build is confirmed. Left on when the install is not confirmed,
     so you can still finish it by hand.

  The installed app must be build 428+ for step 3 to open SideStore; older builds just launch.

.EXITCODES
  0  installed (or skipped: no USB phone, same build already installed)
  1  not confirmed (no download, no tap, or the phone did not report the new build in time)
  2  could not start (no IPA, could not leave the phone LAN, port busy, launch failed)

.EXAMPLE
  .\Install-LoopSegmentsIpaViaUsb.ps1
#>
[CmdletBinding()]
param(
    [string] $IpaPath = '',
    [int] $Port = 8766,
    # How long to wait for SideStore to download the IPA (you tap Install first).
    [int] $WaitSec = 300,
    # After the download, how long to wait for the phone to report the new build.
    [int] $InstallWaitSec = 180,
    # Leave LocalDevVPN on even if this deploy switched it on.
    [switch] $KeepVpn,
    # Install even when the phone already has this IPA's build (testing / reinstall).
    [switch] $Force,
    # Never bounce the phone LAN AP; the phone must already be on another Wi-Fi.
    [switch] $NoBounce,
    # After a bounce: the longest wait for the bounced AP to show up again in this PC's Wi-Fi scan
    # (then 15 s), or a fixed wait when its network name is unknown. Keeps a hop back off the download.
    [int] $SettleSec = 120,
    # Install link launches: a download cut short (-1005, e.g. the phone hopped Wi-Fi) is retried.
    [int] $Attempts = 3
)

$ErrorActionPreference = 'Stop'
$WindowsDir = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsDir
. (Join-Path $WindowsDir 'lib\LoopSegments-Windows.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsPython.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsAltServer.ps1')

$VpnMarker = Join-Path $env:TEMP 'loopsegments-vpn-turned-on.json'
$InfoPy = Join-Path $PSScriptRoot 'LoopSegments-UsbInfo.py'
$OpenPy = Join-Path $PSScriptRoot 'Open-LinkViaLoopSegments.py'

function Write-Inst([string] $Text, [string] $Color = 'Gray') {
    Write-Host "[usb-install] $Text" -ForegroundColor $Color
}

function Invoke-Py([string[]] $ArgList) {
    $r = Invoke-LoopSegmentsPythonRuntime -Runtime $script:rt -ArgumentList $ArgList
    return ($r.Lines -join "`n")
}

function Get-InstalledApp {
    # Build + app path; the path (…/Application/<UUID>/…) changes on every install, same build or not.
    $out = Invoke-Py @($InfoPy, 'installed-build')
    if ($out -match '(?m)^BUILD\t([^\t]*)\t[^\t]*\t?(.*)$') {
        return [pscustomobject]@{ Build = $Matches[1]; Path = $Matches[2].Trim() }
    }
    return $null
}


function Restore-Vpn([bool] $Installed) {
    if (-not (Test-Path -LiteralPath $VpnMarker)) { return }
    # A marker from an older deploy (you may have used the VPN since): forget it.
    if ((Get-Item -LiteralPath $VpnMarker).LastWriteTime -lt (Get-Date).AddHours(-3)) {
        Remove-Item -LiteralPath $VpnMarker -Force -ErrorAction SilentlyContinue
        return
    }
    if ($KeepVpn) { Write-Inst 'LocalDevVPN left on (-KeepVpn).'; return }
    if (-not $Installed) {
        Write-Inst 'LocalDevVPN left on: the install is not confirmed yet (it was off before this deploy; switch it off in LocalDevVPN when done).' Yellow
        return
    }
    $out = Invoke-Py @($OpenPy, 'localdevvpn://disable')
    if ($out -notmatch '(?m)^LAUNCHED\b') {
        Write-Inst "LocalDevVPN: could not switch it back off ($($out.Trim())). It was off before this deploy." Yellow
        return
    }
    foreach ($i in 1..8) {
        Start-Sleep -Seconds 2
        if ((Invoke-Py @($InfoPy, 'vpn-tunnel')) -match '(?m)^TUNNEL_DOWN\b') {
            Write-Inst 'LocalDevVPN switched back off (it was off before this deploy).' Green
            Remove-Item -LiteralPath $VpnMarker -Force -ErrorAction SilentlyContinue
            # The disable link left LocalDevVPN in front: back to the Home Screen.
            [void](Invoke-Py @($InfoPy, 'home'))
            return
        }
    }
    Write-Inst 'LocalDevVPN: asked it to disconnect, but its tunnel is still up. Switch it off in LocalDevVPN.' Yellow
}

function Get-WifiState {
    # Connected profile + saved profiles (netsh lists them in Windows' priority order) + SSIDs in range.
    $iface = (& netsh wlan show interfaces) -join "`n"
    $current = if ($iface -match '(?m)^\s+Profile\s+:\s*(.+?)\s*$') { $Matches[1] } else { $null }
    $profiles = @((& netsh wlan show profiles) | ForEach-Object { if ($_ -match 'All User Profile\s+:\s*(.+?)\s*$') { $Matches[1] } })
    $visible = @((& netsh wlan show networks) | ForEach-Object { if ($_ -match '^SSID \d+\s+:\s*(.+?)\s*$') { $Matches[1] } })
    return [pscustomobject]@{ Current = $current; Profiles = $profiles; Visible = $visible }
}

function Get-PcIpOff([string] $PhoneHost) {
    @(Get-LoopSegmentsPcLanIpv4Addresses | Where-Object { -not (Test-LoopSegmentsSameIpv4Slash24 -IpA $_ -IpB $PhoneHost) }) | Select-Object -First 1
}

function Get-PcIpOn([string] $PhoneHost) {
    @(Get-LoopSegmentsPcLanIpv4Addresses | Where-Object { Test-LoopSegmentsSameIpv4Slash24 -IpA $_ -IpB $PhoneHost }) | Select-Object -First 1
}

function Get-PhoneWifiIp {
    # The phone's Wi-Fi IPv4 over USB from its TCP connections on en0 (DVT network monitor, exact).
    # $null = no TCP over Wi-Fi: on a Wi-Fi with www the phone always has some, so that means the
    # phone LAN (no gateway; internet over 5G) or Wi-Fi off. No pcapd fallback here: sniffing
    # guesses, and a wrong guess bounces the AP for nothing.
    if ((Invoke-Py @($InfoPy, 'wifi-ip')) -match '(?m)^WIFI_IP\t(\S+)') { return $Matches[1] }
    return $null
}

function Move-PcOnPhoneLan([string] $PhoneHost) {
    # Put this PC on the phone LAN (phoneLanHost /24) and return that Wi-Fi's profile name. Already
    # there: the current profile. Else each saved profile in range until one gives a phone-LAN IP.
    $wifi = Get-WifiState
    if (Get-PcIpOn $PhoneHost) { return $wifi.Current }
    # In-range profiles first; then the rest, since a scan can briefly miss a restarting AP.
    $others = @($wifi.Profiles | Where-Object { $_ -ne $wifi.Current })
    $order = @($others | Where-Object { $wifi.Visible -contains $_ }) + @($others | Where-Object { $wifi.Visible -notcontains $_ })
    foreach ($p in $order) {
        Write-Inst "Moving this PC onto the phone LAN to restart its AP: trying $p..."
        & netsh wlan connect "name=$p" | Out-Null
        $until = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $until) {
            Start-Sleep -Seconds 2
            $ip = Get-PcIpOn $PhoneHost
            if ($ip) { Write-Inst "PC is on the phone LAN: $p ($ip)." Green; return $p }
        }
    }
    return $null
}

function Move-PhoneOffPhoneLan([string] $PhoneHost) {
    # SideStore needs www over Wi-Fi, which the phone LAN lacks. There is no way to pick the phone's
    # Wi-Fi over USB, so bounce the phone LAN AP: the phone hops to another saved Wi-Fi (the PC on
    # that AP does too). Returns the phone's Wi-Fi IP off the LAN, or $null.
    $ip = Get-PhoneWifiIp
    if ($ip -and -not (Test-LoopSegmentsSameIpv4Slash24 -IpA $ip -IpB $PhoneHost)) {
        Write-Inst "Phone is already off the phone LAN ($ip)."
        return $ip
    }
    if (-not $ip) { Write-Inst 'No internet traffic on the phone''s Wi-Fi: it is on the phone LAN (or Wi-Fi is off).' }
    if ($NoBounce) {
        Write-Inst "Phone is on the phone LAN$(if ($ip) { " ($ip)" }) and -NoBounce is set: switch the phone to another Wi-Fi by hand." Yellow
        return $null
    }
    $reboot = Join-Path $WindowsDir 'lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    $lanSsid = $null
    foreach ($round in 1..2) {
        # The AP's restart command (telnet) only answers on the phone LAN: the PC has to be there.
        $lanSsid = Move-PcOnPhoneLan $PhoneHost
        if (-not $lanSsid) {
            Write-Inst "This PC could not join the phone LAN ($PhoneHost /24), so it cannot restart that AP. Switch the phone to another Wi-Fi by hand." Yellow
            return $null
        }
        Write-Inst "Phone is on the phone LAN$(if ($ip) { " ($ip)" }): bouncing the phone LAN AP so it hops to another Wi-Fi (round $round)..." Yellow
        & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $reboot -BouncePhoneLanAp -NoWaitEnter -PhoneLanHost $PhoneHost | Out-Host
        $moved = $null
        $until = (Get-Date).AddSeconds(150)
        while ((Get-Date) -lt $until) {
            Start-Sleep -Seconds 10
            $ip = Get-PhoneWifiIp
            if ($ip -and -not (Test-LoopSegmentsSameIpv4Slash24 -IpA $ip -IpB $PhoneHost)) { $moved = $ip; break }
        }
        if (-not $moved) { Write-Inst 'The phone did not leave the phone LAN within 150 s of the AP bounce.' Yellow; return $null }
        # The bounced AP comes back after a minute or so and the phone may hop back to it: wait that
        # out before SideStore starts, so the hop does not cut its download (-1005).
        if ($lanSsid) {
            # Until the bounced AP has dropped out of this PC's Wi-Fi scan and come back, then 15 s for
            # the phone to decide whether to hop back (cap: -SettleSec). Windows' scan list is cached,
            # so right after the bounce it can still list the AP: when the drop-out is never seen,
            # wait at least 45 s instead of trusting that stale entry.
            Write-Inst "Phone moved off the phone LAN ($moved). Waiting for $lanSsid to come back (up to $SettleSec s)..."
            $t0 = Get-Date
            $capAt = $t0.AddSeconds($SettleSec)
            $sawGone = $false
            while ((Get-Date) -lt $capAt) {
                $vis = (Get-WifiState).Visible -contains $lanSsid
                if (-not $vis) { $sawGone = $true }
                elseif ($sawGone -or ((Get-Date) - $t0).TotalSeconds -ge 45) { break }
                Start-Sleep -Seconds 5
            }
            $back = (Get-WifiState).Visible -contains $lanSsid
            Write-Inst ("{0} after {1:N0} s; giving the phone 15 s to settle..." -f $(if ($back) { "$lanSsid is back" } else { "$lanSsid not seen yet" }), ((Get-Date) - $t0).TotalSeconds)
            Start-Sleep -Seconds 15
        } else {
            Write-Inst "Phone moved off the phone LAN ($moved). Waiting $SettleSec s for the bounced AP to come back..."
            Start-Sleep -Seconds $SettleSec
        }
        $ip = Get-PhoneWifiIp
        if ($ip -and -not (Test-LoopSegmentsSameIpv4Slash24 -IpA $ip -IpB $PhoneHost)) {
            Write-Inst "Phone stayed off the phone LAN ($ip)." Green
            return $ip
        }
        Write-Inst "Phone went back to the phone LAN$(if ($ip) { " ($ip)" })." Yellow
    }
    Write-Inst 'The phone keeps going back to the phone LAN: switch it to another Wi-Fi by hand.' Yellow
    return $null
}

function Move-PcOffPhoneLan([string] $PhoneHost, [string] $PhoneIp = '') {
    # The phone LAN = phoneLanHost's /24 (from the config), so this follows whatever network that is.
    # Goal: an IP off that subnet and, when the phone's Wi-Fi IP is known, on the phone's /24.
    # Already there: stay. Else try ipaInstallWifiProfile (config) first, then each saved profile in
    # range, until the PC gets such an IP.
    $wifi = Get-WifiState
    $good = {
        $ip = Get-PcIpOff $PhoneHost
        if ($ip -and -not (Get-PcIpOn $PhoneHost) -and (-not $PhoneIp -or (Test-LoopSegmentsSameIpv4Slash24 -IpA $ip -IpB $PhoneIp))) { $ip } else { $null }
    }
    $now = & $good
    if ($now) {
        Write-Inst "PC is off the phone LAN, on the phone's network: $($wifi.Current) ($now)."
        return [pscustomobject]@{ Ok = $true; Ip = $now; Profile = $wifi.Current }
    }
    $pinned = ''
    try { $pinned = ([string](Get-LoopSegmentsWindowsSettings).ipaInstallWifiProfile).Trim() } catch {}
    $candidates = @()
    if ($pinned) { $candidates += $pinned }
    $candidates += @($wifi.Profiles | Where-Object { $_ -ne $wifi.Current -and $_ -ne $pinned -and ($wifi.Visible -contains $_) })
    if (-not $candidates) {
        return [pscustomobject]@{ Ok = $false; Error = "No other saved Wi-Fi in range to leave the phone LAN ($PhoneHost /24) for the install." }
    }
    $want = if ($PhoneIp) { "the phone's network ($PhoneIp /24)" } else { 'a network off the phone LAN' }
    foreach ($p in $candidates) {
        Write-Inst "Moving this PC to $p for the install (want $want)..."
        & netsh wlan connect "name=$p" | Out-Null
        $until = (Get-Date).AddSeconds(25)
        while ((Get-Date) -lt $until) {
            Start-Sleep -Seconds 2
            $ip = & $good
            if ($ip) {
                Write-Inst "PC is on $p ($ip)." Green
                return [pscustomobject]@{ Ok = $true; Ip = $ip; Profile = $p }
            }
        }
        Write-Inst "$p did not give $want within 25 s." Yellow
    }
    return [pscustomobject]@{ Ok = $false; Error = "Could not move this PC onto $want (tried: $($candidates -join ', '))." }
}


function Write-HttpHead($Stream, [int] $Code, [string] $Reason, [long] $Length, [string] $Type) {
    $head = "HTTP/1.1 $Code $Reason`r`nContent-Type: $Type`r`nContent-Length: $Length`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($b, 0, $b.Length)
}

# --- 1. Phone and IPA ---
if (-not $IpaPath) { $IpaPath = Join-Path $RepoRoot 'ios\build artifacts\ipa\LoopSegments.ipa' }
if (-not (Test-Path -LiteralPath $IpaPath)) { Write-Inst "No IPA at $IpaPath." Red; exit 2 }
$script:rt = Get-LoopSegmentsPythonRuntime -RequirePymobiledevice3
if ($null -eq $script:rt) { Write-Inst 'No Python with pymobiledevice3 - skipped.' Yellow; exit 2 }
$list = Invoke-LoopSegmentsPythonRuntime -Runtime $script:rt -ArgumentList @('-m', 'pymobiledevice3', 'usbmux', 'list')
if (-not (Test-LoopSegmentsUsbmuxListHasDevice -ExitCode $list.ExitCode -Lines $list.Lines)) {
    Write-Inst 'No iPhone on USB - install it from iCloud Downloads in SideStore as usual.'
    exit 0
}
$ipaBuild = $null
if ((Invoke-Py @($InfoPy, 'ipa-build', $IpaPath)) -match '(?m)^BUILD\t(\S+)') { $ipaBuild = $Matches[1] }
$beforeApp = Get-InstalledApp
$before = if ($beforeApp) { $beforeApp.Build } else { $null }
if ($ipaBuild -and $before -eq $ipaBuild -and -not $Force) {
    Write-Inst "Build $ipaBuild is already installed - nothing to do."
    Restore-Vpn $true
    exit 0
}
Write-Inst "IPA build $ipaBuild; phone has $(if ($before) { $before } else { 'no Loop Segments' })."
if ($before -and [int]$before -lt 428) {
    Write-Inst "Note: the phone's build $before cannot open SideStore for you (needs 428+); it will just launch. Install this one from iCloud Downloads." Yellow
}

# --- 2. Serve the IPA on the phone's subnet ---
$phoneHost = ([string](Get-LoopSegmentsWindowsSettings).phoneLanHost).Trim()
if (-not $phoneHost) { Write-Inst 'phoneLanHost is empty in loop-segments-windows.json.' Red; exit 2 }
# SideStore signs over Wi-Fi www, which the phone LAN Wi-Fi does not give (no gateway on purpose),
# so the phone AND this PC go to another Wi-Fi for the install. They stay there: the web companion's
# start-up network check moves both back to the phone LAN.
$phoneIp = Move-PhoneOffPhoneLan $phoneHost
if (-not $phoneIp) { Write-Inst 'The phone is not on a Wi-Fi off the phone LAN, so SideStore could not sign the app there.' Red; exit 2 }
$move = Move-PcOffPhoneLan $phoneHost $phoneIp
if (-not $move.Ok) { Write-Inst $move.Error Red; exit 2 }
$pcIp = $move.Ip
$token = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$path = "/$token/LoopSegments.ipa"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try { $listener.Start() } catch { Write-Inst "Port $Port is busy ($($_.Exception.Message)); pass -Port." Red; exit 2 }
$size = (Get-Item -LiteralPath $IpaPath).Length

# --- 3 + 4. Launch the install link, serve until one full download (retried when cut short) ---
$served = $false
$deadline = (Get-Date).AddSeconds($WaitSec)
try {
    foreach ($attempt in 1..([Math]::Max(1, $Attempts))) {
        if ($attempt -gt 1) {
            # A cut download (-1005) usually means the phone hopped Wi-Fi: put both back off the
            # phone LAN on one network, then ask SideStore again.
            Write-Inst "Retrying the install (attempt $attempt of $Attempts)..." Yellow
            $phoneIp = Move-PhoneOffPhoneLan $phoneHost
            if (-not $phoneIp) { break }
            $move = Move-PcOffPhoneLan $phoneHost $phoneIp
            if (-not $move.Ok) { Write-Inst $move.Error Red; break }
            $pcIp = $move.Ip
            $deadline = (Get-Date).AddSeconds($WaitSec)
        }
        $ipaUrl = "http://${pcIp}:$Port$path"
        $link = 'sidestore://install?url=' + [Uri]::EscapeDataString($ipaUrl)
        Write-Inst "Serving $([math]::Round($size / 1MB, 1)) MB at $ipaUrl"
        # iOS refuses USB launches while the phone is locked: ask to unlock and retry for ~1 min.
        $launched = $false
        foreach ($try in 1..7) {
            $out = Invoke-Py @($OpenPy, $link)
            if ($out -match '(?m)^LAUNCHED\b') { $launched = $true; break }
            if ($try -eq 1) { Write-Inst 'Could not launch Loop Segments over USB - unlock the phone (retrying every 10 s for a minute)...' Yellow }
            Start-Sleep -Seconds 10
        }
        if (-not $launched) {
            Write-Inst "Could not launch Loop Segments over USB: $($out.Trim())" Red
            exit 2
        }
        Write-Inst 'SideStore should show Install now - tap Install on the phone.' Cyan

        $cut = $false
        while (-not $served -and -not $cut -and (Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 10000
                $client.SendTimeout = 60000
                $stream = $client.GetStream()
                $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
                $requestLine = $reader.ReadLine()
                while (($h = $reader.ReadLine())) { }   # skip headers
                $parts = "$requestLine".Split(' ')
                $method = $parts[0]; $reqPath = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                $from = $client.Client.RemoteEndPoint.ToString()
                if ($reqPath -ne $path -or ($method -ne 'GET' -and $method -ne 'HEAD')) {
                    Write-HttpHead $stream 404 'Not Found' 0 'text/plain'
                    Write-Inst "Refused $method $reqPath from $from" DarkGray
                    continue
                }
                Write-HttpHead $stream 200 'OK' $size 'application/octet-stream'
                if ($method -eq 'HEAD') { continue }
                Write-Inst "Download started by $from..."
                $fs = [System.IO.File]::OpenRead($IpaPath)
                try { $fs.CopyTo($stream); $stream.Flush() } finally { $fs.Dispose() }
                $served = $true
                Write-Inst 'Download finished.' Green
            } catch {
                Write-Inst "Download cut short: $($_.Exception.Message)" Yellow
                $cut = $true
            } finally {
                $client.Close()
            }
        }
        if ($served -or -not $cut) { break }
    }
} finally {
    $listener.Stop()
}
if (-not $served) {
    Write-Inst "SideStore did not download the IPA within $WaitSec s (Install not tapped, or VPN / Wi-Fi). Use iCloud Downloads instead." Yellow
    Restore-Vpn $false
    exit 1
}

$installed = $false
$deadline = (Get-Date).AddSeconds($InstallWaitSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $now = Get-InstalledApp
    if (-not $now -or -not $ipaBuild -or $now.Build -ne $ipaBuild) { continue }
    # Same build as before (-Force): only a new app path proves SideStore reinstalled it.
    if ($before -ne $ipaBuild -or ($beforeApp.Path -and $now.Path -and $now.Path -ne $beforeApp.Path)) {
        $installed = $true; break
    }
}
if ($installed) {
    Write-Inst "Installed: the phone now has build $ipaBuild." Green
} else {
    Write-Inst "The phone did not report build $ipaBuild within $InstallWaitSec s - check SideStore." Yellow
}
Restore-Vpn $installed
exit $(if ($installed) { 0 } else { 1 })
