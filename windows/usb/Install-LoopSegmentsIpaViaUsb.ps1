#Requires -Version 7.0
<#
.SYNOPSIS
  Start a SideStore install of the local LoopSegments.ipa on the USB iPhone: you tap Install once.

.DESCRIPTION
  deploy.ps1 runs this after it downloads the IPA. Steps:
  1. iPhone on USB (usbmux)? No: skipped (exit 0). Already on this IPA's build: skipped.
  2. Serves the IPA once on this PC's LAN at http://<PC IP>:<Port>/<random>/LoopSegments.ipa
     (plain TCP listener: no admin / URL ACL; PowerShell 7 needs an inbound firewall allow, which
     Windows already asks for on first use). The PC IP is the one on the phone's subnet.
  3. Launches Loop Segments over USB with -openURL sidestore://install?url=<that link>
     (Open-LinkViaLoopSegments.py). Build 428+ opens the link and quits itself, and SideStore shows
     its Install dialog: tap Install. LocalDevVPN must be connected (Test-PhoneWwwViaUsb.ps1 does it).
  4. Stops serving once SideStore has downloaded the whole file (or after -WaitSec), then waits up to
     -InstallWaitSec for the phone to report the new build.
  5. LocalDevVPN back to how it was: if Test-PhoneWwwViaUsb.ps1 switched it on for this deploy
     (marker %TEMP%\loopsegments-vpn-turned-on.json), switches it off again (localdevvpn://disable,
     opened the same way) once the new build is confirmed. Left on when the install is not confirmed,
     so you can still finish it by hand.

  The installed app must be build 428+ for step 3 to open SideStore; older builds just launch.

.EXITCODES
  0  installed (or skipped: no USB phone, same build already installed)
  1  not confirmed (no download, no tap, or the phone did not report the new build in time)
  2  could not start (no IPA, no PC IP on the phone's subnet, port busy, launch failed)

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
    [switch] $KeepVpn
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

function Get-InstalledBuild {
    $out = Invoke-Py @($InfoPy, 'installed-build')
    if ($out -match '(?m)^BUILD\t(\S*)') { return $Matches[1] }
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
            return
        }
    }
    Write-Inst 'LocalDevVPN: asked it to disconnect, but its tunnel is still up. Switch it off in LocalDevVPN.' Yellow
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
$before = Get-InstalledBuild
if ($ipaBuild -and $before -eq $ipaBuild) {
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
$pcIp = @(Get-LoopSegmentsPcLanIpv4Addresses | Where-Object { $phoneHost -and (Test-LoopSegmentsSameIpv4Slash24 -IpA $_ -IpB $phoneHost) }) | Select-Object -First 1
if (-not $pcIp) { Write-Inst "This PC has no IP on the phone's subnet ($phoneHost) - SideStore could not reach it." Red; exit 2 }
$token = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$path = "/$token/LoopSegments.ipa"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try { $listener.Start() } catch { Write-Inst "Port $Port is busy ($($_.Exception.Message)); pass -Port." Red; exit 2 }
$ipaUrl = "http://${pcIp}:$Port$path"
$link = 'sidestore://install?url=' + [Uri]::EscapeDataString($ipaUrl)
$size = (Get-Item -LiteralPath $IpaPath).Length
Write-Inst "Serving $([math]::Round($size / 1MB, 1)) MB at $ipaUrl"

# --- 3. Launch Loop Segments with the install link ---
$out = Invoke-Py @($OpenPy, $link)
if ($out -notmatch '(?m)^LAUNCHED\b') {
    $listener.Stop()
    Write-Inst "Could not launch Loop Segments over USB: $($out.Trim())" Red
    exit 2
}
Write-Inst 'SideStore should show Install now - tap Install on the phone.' Cyan

# --- 4. Serve until one full download, then wait for the new build ---
$served = $false
$deadline = (Get-Date).AddSeconds($WaitSec)
try {
    while (-not $served -and (Get-Date) -lt $deadline) {
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
            Write-Inst "Transfer error: $($_.Exception.Message)" Yellow
        } finally {
            $client.Close()
        }
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
    $now = Get-InstalledBuild
    if ($now -and $ipaBuild -and $now -eq $ipaBuild) { $installed = $true; break }
}
if ($installed) {
    Write-Inst "Installed: the phone now has build $ipaBuild." Green
} else {
    Write-Inst "The phone did not report build $ipaBuild within $InstallWaitSec s - check SideStore." Yellow
}
Restore-Vpn $installed
exit $(if ($installed) { 0 } else { 1 })
