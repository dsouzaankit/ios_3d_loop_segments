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
     (waits up to 150 s; the PC joins the phone LAN first, since the AP's restart command only
     answers there). -NoBounce skips the bounce.
     PC: needs an IP on the phone's new /24. Already there (the bounce usually moves it too): stays.
     Otherwise connects to ipaInstallWifiProfile (config, optional) or else each saved Wi-Fi
     profile, those in range first (Windows' in-range list is often stale), in Windows' priority order. Both stay on that Wi-Fi afterwards: the web
     companion's start-up network check moves them back to the phone LAN.
     Then serves the IPA once at http://<PC IP>:<Port>/<random>/LoopSegments.ipa (plain TCP
     listener: no admin / URL ACL; PowerShell 7 needs an inbound firewall allow).
  3. Launches Loop Segments over USB with -openURL sidestore://install?url=<that link>
     (Open-LinkViaLoopSegments.py). Build 428+ opens the link and quits itself, and SideStore shows
     its Install dialog: tap Install. LocalDevVPN must be connected (Prepare-PhoneForSideStoreViaUsb.ps1 does it).
  4. Quits SideStore before every try (LoopSegments-UsbInfo.py quit-sidestore), so the link starts
     a fresh SideStore instead of one left with an error dialog or a stale LocalDevVPN connection,
     and restarts LocalDevVPN (its tunnel extension quit, app relaunched, Auto-connect brings a new
     tunnel up; LoopSegments-UsbInfo.py vpn-restart, ~12 s), since SideStore signs through that
     tunnel. Loop Segments is not launched for it, so only the handover asks for Face ID.
     Serves one full download (up to -WaitSec), then waits up to -InstallWaitSec for the phone to
     report the new build (checked every 1 s). A failed try (download cut short, e.g. -1005 - the
     phone's network at the cut is logged - or SideStore never finished) is retried once: both are
     put back off the phone LAN and the link is opened again (tap Install). Right before the link,
     and every 10 s until the download starts, it checks the phone is still on the install Wi-Fi
     (same Wi-Fi address as when it got there - iOS uses a private address per network - and not
     dropped to 5G; right before the link, and to confirm a "left", also the phone's network name
     from its live Wi-Fi log against this PC's, when the log names one within 8 s); if it left (e.g. back to the phone LAN AP: SideStore -1001), the phone is moved
     again before the link, or the try ends and is retried like a cut download. If that fails too and
     -RestartPhoneOnError is set (deploy.ps1 sets it): restarts the phone over USB (the best fix for
     SideStore errors other than an offline LocalDevVPN), waits for it to come back, for you to
     unlock it, and for LocalDevVPN to reconnect, then one last try. Not while an export runs
     (marker %TEMP%\loopsegments-export-busy.json from the prep). No download at all (Install not
     tapped) is not retried.
  5. LocalDevVPN back to how it was: if Prepare-PhoneForSideStoreViaUsb.ps1 switched it on for this deploy
     (marker %TEMP%\loopsegments-vpn-turned-on.json), switches it off again (quits
     LocalDevVPN's tunnel extension over USB: no app launch, so no Face ID prompt) once the new build is confirmed. Left on when the install is not confirmed,
     so you can still finish it by hand.

  1b. Before any of 2-4: when SideStore's exported certificate is at -SigningP12 (password in Credential
     Manager as -SigningCredTarget) and zsign is found (..\env_setup\zsign\zsign.exe next to the repo, or
     PATH), signs the IPA on this PC with it and the phone's newest profile for the installed bundle id,
     and installs it over USB (LoopSegments-UsbSign.py): no tap, no Wi-Fi moves. Confirmed by the new
     build as in step 4. Not set up, or it fails: steps 2-5 as usual. -NoSignedInstall skips it.
     No LocalDevVPN needed: the phone prep skips it when this is ready, and before steps 2-5 the
     VPN is connected if it is not (Prepare-PhoneForSideStoreViaUsb.ps1 -ForceVpn).
     Setup on any PC: ..\setup\Set-LoopSegmentsSigning.ps1 [-P12 <SideStore export>] (zsign download,
     certificate copy, password prompt per PC, check). zsign: zsignExe in loop-segments-windows.json,
     else ..\env_setup\zsign next to the repo, else windows\signing\zsign, else PATH.

  The installed app must be build 428+ for step 3 to open SideStore; older builds just launch.

.EXITCODES
  0  installed (or skipped: no USB phone, same build already installed, IPA older than the phone's build)
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
    # Install even when the phone already has this IPA's build (reinstall). An older IPA is never
    # installed, -Force or not.
    [switch] $Force,
    # Never bounce the phone LAN AP; the phone must already be on another Wi-Fi.
    [switch] $NoBounce,
    # A failed try (download cut short, or SideStore never finished) is retried once; if that fails
    # too, restart the phone over USB (you unlock it), reconnect LocalDevVPN and try a last time.
    [switch] $RestartPhoneOnError,
    # Skip the PC-signed install (step 1b) and always use the SideStore link.
    [switch] $NoSignedInstall,
    # SideStore's exported signing certificate; empty = windows\signing\signing.p12
    # (lib\Get-LoopSegmentsSigning.ps1).
    [string] $SigningP12 = '',
    # Windows Credential Manager generic credential holding the .p12 password; empty = LoopSegments-signing.
    [string] $SigningCredTarget = ''
)

$ErrorActionPreference = 'Stop'
$WindowsDir = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsDir
. (Join-Path $WindowsDir 'lib\LoopSegments-Windows.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsPython.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsAltServer.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsWifi.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsSigning.ps1')
if (-not $SigningP12) { $SigningP12 = $LoopSegmentsSigningP12 }
if (-not $SigningCredTarget) { $SigningCredTarget = $LoopSegmentsSigningCredTarget }

$VpnMarker = Join-Path $env:TEMP 'loopsegments-vpn-turned-on.json'
# Left by Prepare-PhoneForSideStoreViaUsb.ps1 while an export runs: never restart the phone then.
$ExportBusyMarker = Join-Path $env:TEMP 'loopsegments-export-busy.json'
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
    # One USB connection: quit LocalDevVPN's tunnel extension (no Loop Segments launch, so no Face ID
    # prompt), check it is gone, then the Home Screen.
    $out = Invoke-Py @($InfoPy, 'vpn-off')
    # vpn-off ends on the Home Screen whenever it got as far as checking the tunnel.
    if ($out -match '(?m)^VPN_(OFF|STILL_UP)\b') { $script:WentHome = $true }
    if ($out -match '(?m)^VPN_OFF\b') {
        Write-Inst 'LocalDevVPN switched back off (it was off before this deploy).' Green
        Remove-Item -LiteralPath $VpnMarker -Force -ErrorAction SilentlyContinue
    } elseif ($out -match '(?m)^VPN_STILL_UP\b') {
        Write-Inst 'LocalDevVPN: asked it to disconnect, but its tunnel is still up. Switch it off in LocalDevVPN.' Yellow
    } else {
        Write-Inst "LocalDevVPN: could not switch it back off ($($out.Trim())). It was off before this deploy." Yellow
    }
}

function Get-WifiState { Get-LoopSegmentsWifiState }   # lib\Get-LoopSegmentsWifi.ps1

function Get-PcIpOff([string] $PhoneHost) {
    @(Get-LoopSegmentsPcLanIpv4Addresses | Where-Object { -not (Test-LoopSegmentsSameIpv4Slash24 -IpA $_ -IpB $PhoneHost) }) | Select-Object -First 1
}

function Get-PcIpOn([string] $PhoneHost) {
    @(Get-LoopSegmentsPcLanIpv4Addresses | Where-Object { Test-LoopSegmentsSameIpv4Slash24 -IpA $_ -IpB $PhoneHost }) | Select-Object -First 1
}

function Get-PhoneWifiIp([int] $ListenSec = 6) {
    # The phone's Wi-Fi IPv4 over USB from its TCP connections on en0 (DVT network monitor, exact).
    # $null = no TCP over Wi-Fi: on a Wi-Fi with www the phone always has some, so that means the
    # phone LAN (no gateway; internet over 5G) or Wi-Fi off. No pcapd fallback here: sniffing
    # guesses, and a wrong guess bounces the AP for nothing. Listens 6 s by default: the check that
    # decides whether to bounce at all must not miss an idle phone; the wait loops use 3 s and
    # simply check again.
    if ((Invoke-Py @($InfoPy, 'wifi-ip', [string]$ListenSec)) -match '(?m)^WIFI_IP\t(\S+)') { return $Matches[1] }
    return $null
}

function Restart-PhoneAndRecover {
    # Restart the iPhone over USB, wait for it to come back and be unlocked, reconnect LocalDevVPN.
    # Skipped while an export runs (the prep leaves a marker then). $true = ready for another try.
    if ((Test-Path -LiteralPath $ExportBusyMarker) -and
        (Get-Item -LiteralPath $ExportBusyMarker).LastWriteTime -gt (Get-Date).AddHours(-3)) {
        Write-Inst 'Not restarting the phone: an export was running when this deploy started.' Yellow
        return $false
    }
    Write-Inst 'Restarting the phone over USB (SideStore errors usually clear after a restart)...' Yellow
    [void](Invoke-LoopSegmentsPythonRuntime -Runtime $script:rt -ArgumentList @('-m', 'pymobiledevice3', 'diagnostics', 'restart'))
    $usbUp = {
        $l = Invoke-LoopSegmentsPythonRuntime -Runtime $script:rt -ArgumentList @('-m', 'pymobiledevice3', 'usbmux', 'list')
        Test-LoopSegmentsUsbmuxListHasDevice -ExitCode $l.ExitCode -Lines $l.Lines
    }
    # Gone from USB (up to 60 s), then back (up to 4 min).
    $until = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $until -and (& $usbUp)) { Start-Sleep -Seconds 3 }
    $until = (Get-Date).AddSeconds(240)
    $back = $false
    while ((Get-Date) -lt $until) { Start-Sleep -Seconds 5; if (& $usbUp) { $back = $true; break } }
    if (-not $back) { Write-Inst 'The phone did not come back on USB within 4 min.' Yellow; return $false }
    # iOS needs the passcode after a restart; developer services only answer once it is entered.
    Write-Inst 'Phone is back on USB. Unlock it with your passcode (waiting up to 5 min)...' Cyan
    $until = (Get-Date).AddSeconds(300)
    $ready = $false
    while ((Get-Date) -lt $until) {
        if ((Invoke-Py @($InfoPy, 'vpn-tunnel')) -match '(?m)^TUNNEL_(UP|DOWN)\b') { $ready = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { Write-Inst 'The phone was not unlocked within 5 min.' Yellow; return $false }
    # The restart dropped LocalDevVPN; its Auto-connect setting brings it back on launch.
    $vpn = Invoke-Py @((Join-Path $PSScriptRoot 'Connect-LocalDevVPNViaUsb.py'), '--wait', '20')
    if ($vpn -notmatch '(?m)^VPN_(ALREADY_)?CONNECTED\b') {
        Write-Inst 'LocalDevVPN did not reconnect after the restart (Auto-connect on launch on?).' Yellow
        return $false
    }
    Write-Inst 'Phone restarted, unlocked, LocalDevVPN connected.' Green
    return $true
}

function Move-PcOnPhoneLan([string] $PhoneHost) {
    # Put this PC on the phone LAN (phoneLanHost /24) by a saved-Wi-Fi switch; returns the profile or
    # $null. Shared with the companion's gateway check (lib\Get-LoopSegmentsWifi.ps1).
    return Connect-LoopSegmentsPcToSubnet -HostIp $PhoneHost -PrefixLength 24 -LogPrefix '[usb-install]'
}

function Get-PhoneWifiState {
    # State 'ASSOCIATED' (joined to some Wi-Fi), 'NOT_ASSOCIATED' (5G only) or 'UNKNOWN', plus the
    # phone's Wi-Fi address (Mac). iOS uses a separate private address per network, so a different
    # Mac means a different network (iOS redacts the SSID / BSSID, so this is the one handle).
    $a = Invoke-Py @($InfoPy, 'wifi-assoc')
    $state = if ($a -match '(?m)^(ASSOCIATED|NOT_ASSOCIATED)\b') { $Matches[1] } else { 'UNKNOWN' }
    $mac = if ($a -match '(?m)\tmac=([0-9a-fA-F:]{17})') { $Matches[1].ToLowerInvariant() } else { $null }
    return [pscustomobject]@{ State = $state; Mac = $mac }
}

function Get-PhoneWifiAssoc { (Get-PhoneWifiState).State }

function Get-PcWifiSsid {
    # The network name this PC's Wi-Fi is on now (netsh), or $null.
    $iface = (& netsh wlan show interfaces) -join "`n"
    if ($iface -match '(?m)^\s+SSID\s+:\s*(.+?)\s*$') { return $Matches[1] }
    return $null
}

function Get-PhoneWifiName([int] $TimeoutSec = 8) {
    # The phone's network name from its live Wi-Fi log (wifi-ssid), or $null when nothing is logged
    # in time (an idle phone often logs nothing for a while).
    if ((Invoke-Py @($InfoPy, 'wifi-ssid', [string]$TimeoutSec)) -match '(?m)^WIFI_SSID\t([^\t]+)\t') { return $Matches[1] }
    return $null
}

function Get-PhoneLeftInstallWifi([switch] $UseName) {
    # Why the phone is no longer on the Wi-Fi it was on when the install link was opened, or $null.
    # -UseName: first the phone's logged network name against this PC's (exact, but up to ~8 s and
    # not always available); a match means "still here", a different name means "left". Without a
    # name (or without -UseName): the cheap check (~1-2 s) of its per-network Wi-Fi address and a
    # drop to 5G. With "Private Wi-Fi Address" off the address is the same on every network, so then
    # only the name or a drop to 5G shows a switch.
    if ($UseName) {
        $phoneName = Get-PhoneWifiName
        $pcName = Get-PcWifiSsid
        if ($phoneName -and $pcName) {
            if ($phoneName -eq $pcName) { return $null }
            return "it is on $phoneName, not on this PC's $pcName (its Wi-Fi log)"
        }
    }
    $st = Get-PhoneWifiState
    if ($st.State -eq 'NOT_ASSOCIATED') { return 'it dropped to 5G (no Wi-Fi)' }
    if ($script:InstallWifiMac -and $st.Mac -and $st.Mac -ne $script:InstallWifiMac) {
        return "it switched to another Wi-Fi (its Wi-Fi address changed: $($script:InstallWifiMac) -> $($st.Mac))"
    }
    return $null
}

function Wait-PhoneOnOtherWifi([string] $PhoneHost, [int] $Seconds, [string] $Why) {
    # Until the phone has Wi-Fi traffic off the phone LAN; prints what it sees at every check.
    $t0 = Get-Date
    $until = $t0.AddSeconds($Seconds)
    $asked = $false
    while ((Get-Date) -lt $until) {
        # Short pause and short listen (about 8-10 s per check): the phone often hops within
        # seconds, and a miss only means the next check.
        Start-Sleep -Seconds 3
        $ip = Get-PhoneWifiIp 3
        if ($ip -and -not (Test-LoopSegmentsSameIpv4Slash24 -IpA $ip -IpB $PhoneHost)) {
            Write-Inst "Phone is on another Wi-Fi ($ip)." Green
            return $ip
        }
        $assoc = Get-PhoneWifiAssoc
        $state = if ($ip) { "still on the phone LAN ($ip)" }
                 elseif ($assoc -eq 'NOT_ASSOCIATED') { 'on no Wi-Fi (5G only)' }
                 elseif ($assoc -eq 'ASSOCIATED') { 'on a Wi-Fi, no internet traffic yet' }
                 else { 'unknown' }
        Write-Inst ("{0}: phone {1} ({2:N0} of {3} s)" -f $Why, $state, ((Get-Date) - $t0).TotalSeconds, $Seconds)
        if ($assoc -eq 'NOT_ASSOCIATED' -and -not $asked) {
            # iOS can sit on 5G after its Wi-Fi drops instead of joining another saved network.
            Write-Inst 'The phone is not joining another Wi-Fi by itself: on the phone, Settings > Wi-Fi, tap your other network (the one this PC can join).' Cyan
            $asked = $true
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
    if (-not $ip -and (Get-PhoneWifiAssoc) -eq 'NOT_ASSOCIATED') {
        # On no Wi-Fi at all (5G only): bouncing the phone LAN AP would not move it anywhere.
        Write-Inst 'The phone is on no Wi-Fi (5G only), so there is nothing to bounce it off.' Yellow
        $ip = Wait-PhoneOnOtherWifi $PhoneHost 150 'Waiting for the phone to join a Wi-Fi'
        if (-not $ip) { Write-Inst 'The phone did not join a Wi-Fi with internet within 150 s.' Yellow }
        return $ip
    }
    if (-not $ip) { Write-Inst 'No internet traffic on the phone''s Wi-Fi: it is on the phone LAN.' }
    if ($NoBounce) {
        Write-Inst "Phone is on the phone LAN$(if ($ip) { " ($ip)" }) and -NoBounce is set: switch the phone to another Wi-Fi by hand." Yellow
        return $null
    }
    $reboot = Join-Path $WindowsDir 'lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    # The AP's restart command (telnet) only answers on the phone LAN: the PC has to be there.
    if (-not (Move-PcOnPhoneLan $PhoneHost)) {
        Write-Inst "This PC could not join the phone LAN ($PhoneHost /24), so it cannot restart that AP. Switch the phone to another Wi-Fi by hand." Yellow
        return $null
    }
    Write-Inst "Phone is on the phone LAN$(if ($ip) { " ($ip)" }): bouncing the phone LAN AP so it hops to another Wi-Fi..." Yellow
    & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $reboot -BouncePhoneLanAp -NoWaitEnter -PhoneLanHost $PhoneHost | Out-Host
    # No wait for the bounced AP to come back: it can take minutes, and a download cut short by a
    # hop back to it is handled by the retry like any other -1005.
    $ip = Wait-PhoneOnOtherWifi $PhoneHost 150 'After the AP bounce'
    if (-not $ip) { Write-Inst 'The phone did not reach another Wi-Fi within 150 s of the AP bounce.' Yellow }
    return $ip
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
    # In range first, then the other saved profiles: Windows' list of networks in range is often stale
    # (it can show only the current one), like the companion's gateway switch (lib\Get-LoopSegmentsWifi.ps1).
    $others = @($wifi.Profiles | Where-Object { $_ -ne $wifi.Current -and $_ -ne $pinned })
    $candidates += @($others | Where-Object { $wifi.Visible -contains $_ }) + @($others | Where-Object { $wifi.Visible -notcontains $_ })
    if (-not $candidates) {
        return [pscustomobject]@{ Ok = $false; Error = "No other saved Wi-Fi to leave the phone LAN ($PhoneHost /24) for the install." }
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
    Write-Inst "Build $ipaBuild is already installed - nothing to do (-Force reinstalls it)."
    Restore-Vpn $true
    exit 0
}
# Never downgrade, -Force or not: an IPA older than the phone's build is skipped.
if ($ipaBuild -and $before -and ($ipaBuild -as [int]) -and ($before -as [int]) -and [int]$ipaBuild -lt [int]$before) {
    Write-Inst "IPA build $ipaBuild is older than the phone's build $before - not downgrading." Yellow
    Restore-Vpn $true
    exit 0
}
Write-Inst "IPA build $ipaBuild; phone has $(if ($before) { $before } else { 'no Loop Segments' })."

# --- 1b. Signed on this PC with SideStore's certificate, installed over USB (no tap) ---
$zsign = Find-LoopSegmentsZsign
if ($NoSignedInstall) {
    Write-Inst 'PC-signed install skipped (-NoSignedInstall).'
} elseif (-not (Test-Path -LiteralPath $SigningP12)) {
    Write-Inst "PC-signed install not set up (no $SigningP12) - using SideStore." DarkGray
} elseif (-not $zsign) {
    Write-Inst 'PC-signed install: zsign not found - using SideStore.' Yellow
} else {
    Write-Inst 'Signing on this PC with SideStore''s certificate and installing over USB...' Cyan
    $signPy = Join-Path $PSScriptRoot 'LoopSegments-UsbSign.py'
    # Local disk, not P: (pCloud holds new files while it uploads them; the USB install then hung) and
    # not AppData (the Store Python's private copy).
    $work = Join-Path $env:USERPROFILE '.loopsegments-sign-work'
    $oldPath = if ($beforeApp) { $beforeApp.Path } else { '' }
    $out = Invoke-Py @($signPy, 'sign-install', $IpaPath, $zsign, $SigningP12, $SigningCredTarget, $work)
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $ready = [regex]::Match($out, '(?m)^READY\t(\S+)\t\S*\t([^\t]+)\t(\S+)')
    if ($ready.Success) {
        Write-Inst "Profile for $($ready.Groups[1].Value) valid until $($ready.Groups[2].Value) UTC; certificate until $($ready.Groups[3].Value)."
    }
    if ($out -match '(?m)^INSTALLED\b') {
        $ok = $ipaBuild -and ((Invoke-Py @($InfoPy, 'wait-install', $ipaBuild, $oldPath, '60')) -match '(?m)^INSTALLED\b')
        if ($ok) {
            Write-Inst "Installed (PC-signed): the phone now has build $ipaBuild." Green
            Restore-Vpn $true
            exit 0
        }
        Write-Inst "The phone did not report build $ipaBuild after the PC-signed install - trying SideStore." Yellow
    } else {
        $last = (($out -split "`n") | Where-Object { $_ -match '^[A-Z_]+(\t|$)' } | Select-Object -Last 1)
        Write-Inst "PC-signed install failed ($($last -replace "`t", ': ')) - using SideStore." Yellow
    }
}
# The phone prep skips LocalDevVPN when the PC-signed install is ready; SideStore needs it, so make sure
# it is connected now (quick when it already is; the prep leaves the marker when it switches it on,
# so Restore-Vpn switches it off again after the install).
Write-Inst 'Checking LocalDevVPN for the SideStore install...'
& (Join-Path $PSScriptRoot 'Prepare-PhoneForSideStoreViaUsb.ps1') -NoQuit -ForceVpn

if ($before -and [int]$before -lt 428) {
    Write-Inst "Note: the phone's build $before cannot open SideStore for you (needs 428+); it will just launch. Install this one from iCloud Downloads." Yellow
}

# --- 2. Serve the IPA on the phone's subnet ---
$phoneHost = ([string](Get-LoopSegmentsWindowsSettings).phoneLanHost).Trim()
if (-not $phoneHost) { Write-Inst 'phoneLanHost is empty in loop-segments-windows.json.' Red; exit 2 }
# SideStore signs over Wi-Fi www, which the phone LAN Wi-Fi does not give (no gateway on purpose),
# so the phone AND this PC go to another Wi-Fi for the install. They stay there: the PC companion's
# start-up network check moves both back to the phone LAN.
$phoneIp = Move-PhoneOffPhoneLan $phoneHost
if (-not $phoneIp) { Write-Inst 'The phone is not on a Wi-Fi off the phone LAN, so SideStore could not sign the app there.' Red; exit 2 }
$move = Move-PcOffPhoneLan $phoneHost $phoneIp
if (-not $move.Ok) { Write-Inst $move.Error Red; exit 2 }
$pcIp = $move.Ip
# The phone's Wi-Fi address on the install Wi-Fi: a different one later means it switched network.
$script:InstallWifiMac = (Get-PhoneWifiState).Mac
$token = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$path = "/$token/LoopSegments.ipa"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try { $listener.Start() } catch { Write-Inst "Port $Port is busy ($($_.Exception.Message)); pass -Port." Red; exit 2 }
$size = (Get-Item -LiteralPath $IpaPath).Length

# --- 3 + 4. Launch the install link, serve one full download, wait for the new build ---
# A failed try (download cut short, e.g. -1005, or downloaded but SideStore never finished) is retried
# once as is; if that fails too, -RestartPhoneOnError restarts the phone over USB (the user's best fix
# for SideStore errors other than an offline LocalDevVPN), then one last try.
$oldPath = if ($beforeApp -and $beforeApp.Path) { $beforeApp.Path } else { '-' }
$installed = $false
$restarted = $false
$failure = $null
$attempt = 0
try {
    while ($true) {
        $attempt++
        if ($attempt -gt 1) {
            if ($cut) {
                # Where the phone is says which kind of cut it was: back on the phone LAN (a hop to the
                # bounced AP) or still on the install Wi-Fi (another cause).
                $atCut = Get-PhoneWifiIp
                $where = if (-not $atCut) { 'no Wi-Fi TCP = the phone LAN (or Wi-Fi off)' }
                         elseif (Test-LoopSegmentsSameIpv4Slash24 -IpA $atCut -IpB $phoneHost) { "the phone LAN ($atCut)" }
                         elseif (Test-LoopSegmentsSameIpv4Slash24 -IpA $atCut -IpB $pcIp) { "still the install Wi-Fi ($atCut)" }
                         else { "another network ($atCut)" }
                Write-Inst "At the cut the phone was on: $where." Yellow
            }
            Write-Inst "Trying the install again (try $attempt)..." Yellow
            $phoneIp = Move-PhoneOffPhoneLan $phoneHost
            if (-not $phoneIp) { $failure = 'the phone is not on a Wi-Fi off the phone LAN'; break }
            $move = Move-PcOffPhoneLan $phoneHost $phoneIp
            if (-not $move.Ok) { $failure = $move.Error; break }
            $pcIp = $move.Ip
            $script:InstallWifiMac = (Get-PhoneWifiState).Mac
        }
        # A fresh SideStore for every try: a running one keeps whatever state it was left in (an
        # error dialog, a stale connection to LocalDevVPN) and the link would just be handed to it.
        $q = Invoke-Py @($InfoPy, 'quit-sidestore')
        if ($q -match '(?m)^QUIT\b') { Write-Inst 'Quit SideStore so this try starts it fresh.' }
        # And a fresh LocalDevVPN (tunnel off, app relaunched, Auto-connect brings a new tunnel up):
        # SideStore signs through that tunnel, and the phone may just have changed Wi-Fi.
        $v = Invoke-Py @($InfoPy, 'vpn-restart')
        if ($v -match '(?m)^VPN_RESTARTED\b') { Write-Inst 'Restarted LocalDevVPN (fresh tunnel).' }
        else { Write-Inst "LocalDevVPN restart: $(($v -split "`n" | Where-Object { $_ -match '^(VPN_|NOT_|NO_|ERROR)' } | Select-Object -First 1)) - trying anyway." Yellow }
        # Still on the install Wi-Fi right before the link? The phone can hop back to the phone LAN AP
        # (iOS prefers it) between the move and here; SideStore then cannot reach this PC (-1001).
        if (-not $script:InstallWifiMac) { $script:InstallWifiMac = (Get-PhoneWifiState).Mac }
        $gone = Get-PhoneLeftInstallWifi -UseName
        if ($gone) {
            Write-Inst "The phone left the install Wi-Fi before the install link: $gone. Moving it off the phone LAN again..." Yellow
            $phoneIp = Move-PhoneOffPhoneLan $phoneHost
            if (-not $phoneIp) { $failure = 'the phone is not on a Wi-Fi off the phone LAN'; break }
            $move = Move-PcOffPhoneLan $phoneHost $phoneIp
            if (-not $move.Ok) { $failure = $move.Error; break }
            $pcIp = $move.Ip
            $script:InstallWifiMac = (Get-PhoneWifiState).Mac
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
        if (-not $launched) { $failure = "could not launch Loop Segments over USB: $($out.Trim())"; break }
        Write-Inst 'SideStore should show Install now - tap Install on the phone.' Cyan

        $served = $false
        $cut = $false
        $left = $null
        $deadline = (Get-Date).AddSeconds($WaitSec)
        $nextWifiCheck = (Get-Date).AddSeconds(10)
        while (-not $served -and -not $cut -and -not $left -and (Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) {
                # Every 10 s until the download starts (the cheap address check, ~1-2 s): if the phone
                # left the install Wi-Fi, SideStore cannot reach this PC, so end this try now instead of
                # waiting out -WaitSec. A "left" is confirmed by the phone's logged network name when
                # one comes through (a name matching this PC's network clears it).
                if ((Get-Date) -ge $nextWifiCheck) {
                    $left = Get-PhoneLeftInstallWifi
                    if ($left) { $left = Get-PhoneLeftInstallWifi -UseName }
                    if ($left) { Write-Inst "The phone left the install Wi-Fi while waiting for the download: $left." Yellow; break }
                    $nextWifiCheck = (Get-Date).AddSeconds(10)
                }
                Start-Sleep -Milliseconds 200; continue
            }
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

        if ($served) {
            # Checked every second on one connection; a new install path proves the install even for
            # the same build (-Force).
            $installed = $ipaBuild -and ((Invoke-Py @($InfoPy, 'wait-install', $ipaBuild, $oldPath, [string]$InstallWaitSec)) -match '(?m)^INSTALLED\b')
            if ($installed) { break }
            Write-Inst "The phone did not report build $ipaBuild within $InstallWaitSec s (SideStore error?)." Yellow
        } elseif (-not $cut -and -not $left) {
            # No download at all, with the phone still on the install Wi-Fi: Install not tapped (or
            # SideStore could not reach this PC). Not a SideStore error a retry or restart would fix.
            # A phone that left the Wi-Fi ($left) is retried below, like a cut download.
            $failure = "SideStore did not download the IPA within $WaitSec s (Install not tapped, or VPN / Wi-Fi)"
            break
        }

        # A failed try: once as is, then (with -RestartPhoneOnError) a phone restart, then a last try.
        if ($attempt -eq 1) { continue }
        if ($RestartPhoneOnError -and -not $restarted) {
            $restarted = $true
            if (Restart-PhoneAndRecover) { continue }
            $failure = 'the phone did not come back ready after the restart'
            break
        }
        $failure = 'SideStore failed again'
        break
    }
} finally {
    $listener.Stop()
}

if ($installed) {
    Write-Inst "Installed: the phone now has build $ipaBuild." Green
} else {
    Write-Inst "Not installed: $(if ($failure) { $failure } else { 'unknown' })." Yellow
    if (-not $restarted) {
        Write-Inst 'For a SideStore error other than LocalDevVPN being offline, restart the phone, then run .\deploy.ps1 -UseLatest (or use iCloud Downloads).' Yellow
    } else {
        Write-Inst 'Install it from iCloud Downloads in SideStore, or run .\deploy.ps1 -UseLatest later.' Yellow
    }
}
$script:WentHome = $false
Restore-Vpn $installed
# SideStore is still in front after the install: back to the Home Screen (the VPN-off step already
# did that when it ran; it does not when LocalDevVPN was on before the deploy).
if ($installed -and -not $script:WentHome) { [void](Invoke-Py @($InfoPy, 'home')) }
exit $(if ($installed) { 0 } else { 1 })
