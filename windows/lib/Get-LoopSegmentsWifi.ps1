# Windows Wi-Fi helpers (netsh): which saved network the PC is on, and switching it onto the network
# that serves a given subnet. Dot-source from the gateway check (companion start-up) and the USB IPA
# install. Self-contained: no other lib file needed.
#
# A Wi-Fi switch is the fast, side-effect-free way to put this PC on (or off) the phone LAN: about
# 5 s, versus a router Wi-Fi restart (1-2 min) that also knocks every other device off that AP.
#
# netsh only connects to a network that is in Windows' scan cache: otherwise it answers "not
# available to connect" at once and nothing is even attempted (no WLAN event). While connected,
# Windows rescans rarely, so a 5 GHz AP can be missing from the cache although it is in range.
# Hence the explicit scan (wlanapi WlanScan) before switching, and the rescan-and-retry on refusal.

function Invoke-LoopSegmentsNetsh {
    # netsh with its output read as UTF-8: profile names such as "dsouzaankit's iPhone" (U+2019)
    # otherwise come back as mojibake under an OEM console code page, and a connect with that name fails.
    $prev = $null
    try { $prev = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $prev = $null }
    try { return @(& netsh @args 2>&1 | ForEach-Object { [string]$_ }) }
    finally { if ($prev) { try { [Console]::OutputEncoding = $prev } catch {} } }
}

function Request-LoopSegmentsWifiScan {
    # Ask every Wi-Fi interface for a fresh scan (wlanapi WlanScan; netsh has no scan command).
    # Returns $true when a scan was requested. Results land in the cache over the next ~2-4 s.
    if (-not ('LoopSegments.WifiScanner' -as [type])) {
        try {
            Add-Type -Namespace LoopSegments -Name WifiScanner -ErrorAction Stop -MemberDefinition @'
[DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint v, IntPtr r, out uint neg, out IntPtr h);
[DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
[DllImport("wlanapi.dll")] static extern int WlanEnumInterfaces(IntPtr h, IntPtr r, out IntPtr list);
[DllImport("wlanapi.dll")] static extern int WlanScan(IntPtr h, ref Guid g, IntPtr ssid, IntPtr ie, IntPtr r);
[DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
public static int ScanAll() {
    uint neg; IntPtr h; if (WlanOpenHandle(2, IntPtr.Zero, out neg, out h) != 0) return 0;
    int n = 0;
    try {
        IntPtr list; if (WlanEnumInterfaces(h, IntPtr.Zero, out list) != 0) return 0;
        try {
            int count = System.Runtime.InteropServices.Marshal.ReadInt32(list);
            // WLAN_INTERFACE_INFO: GUID (16) + WCHAR[256] (512) + state (4) = 532 bytes, after an 8-byte header.
            for (int i = 0; i < count; i++) {
                byte[] gb = new byte[16];
                System.Runtime.InteropServices.Marshal.Copy(new IntPtr(list.ToInt64() + 8 + i * 532), gb, 0, 16);
                Guid g = new Guid(gb);
                if (WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) n++;
            }
        } finally { WlanFreeMemory(list); }
    } finally { WlanCloseHandle(h, IntPtr.Zero); }
    return n;
}
'@
        } catch { return $false }
    }
    try { return ([LoopSegments.WifiScanner]::ScanAll() -gt 0) } catch { return $false }
}

function Get-LoopSegmentsWifiState {
    # Connected profile, saved profiles (netsh lists them in Windows' priority order), SSIDs in range.
    $iface = (Invoke-LoopSegmentsNetsh wlan show interfaces) -join "`n"
    $current = if ($iface -match '(?m)^\s+Profile\s+:\s*(.+?)\s*$') { $Matches[1] } else { $null }
    $profiles = @((Invoke-LoopSegmentsNetsh wlan show profiles) | ForEach-Object { if ($_ -match 'All User Profile\s+:\s*(.+?)\s*$') { $Matches[1] } })
    $visible = @((Invoke-LoopSegmentsNetsh wlan show networks) | ForEach-Object { if ($_ -match '^SSID \d+\s+:\s*(.+?)\s*$') { $Matches[1] } })
    return [pscustomobject]@{ Current = $current; Profiles = $profiles; Visible = $visible }
}

function Get-LoopSegmentsPcIpv4OnSubnet {
    # This PC's IPv4 on HostIp's /PrefixLength (default /24), skipping VPN / virtual adapters; else $null.
    param(
        [Parameter(Mandatory = $true)][string] $HostIp,
        [int] $PrefixLength = 24
    )
    $skipAlias = '(?i)loopback|clash|meta|mihomo|wintun|wireguard|nord|mullvad|vpn|tap-windows|tun\b|vethernet|hyper-v|docker|wsl|virtualbox|vmware|localdevvpn|stosvpn|zerotier|hamachi|radmin'
    try { $target = [System.Net.IPAddress]::Parse($HostIp.Trim()).GetAddressBytes() } catch { return $null }
    if ($target.Length -ne 4) { return $null }
    # 64-bit math: PowerShell reads 0xFFFFFFFF as Int32 -1.
    $all = [uint64][uint32]::MaxValue
    $mask = if ($PrefixLength -le 0) { [uint64]0 } else { ($all -shl (32 - [Math]::Min(32, $PrefixLength))) -band $all }
    $toU32 = { param($b) ([uint64]$b[0] -shl 24) -bor ([uint64]$b[1] -shl 16) -bor ([uint64]$b[2] -shl 8) -bor [uint64]$b[3] }
    $t = & $toU32 $target
    $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -and $_.IPAddress -notmatch '^(127\.|169\.254\.|198\.18\.)' -and
        -not ($_.InterfaceAlias -and $_.InterfaceAlias -match $skipAlias)
    }
    foreach ($a in @($addrs)) {
        $b = [System.Net.IPAddress]::Parse([string]$a.IPAddress).GetAddressBytes()
        if (((& $toU32 $b) -band $mask) -eq ($t -band $mask)) { return [string]$a.IPAddress }
    }
    return $null
}

function Connect-LoopSegmentsPcToSubnet {
    # Put this PC on the Wi-Fi that serves HostIp's subnet via a saved profile (netsh wlan connect).
    # Already there: returns the current profile without switching. Otherwise scans, then tries saved
    # profiles in range first (PerProfileSec each, enough for DHCP), then the rest (a scan can briefly
    # miss a restarting AP; OutOfRangeSec each). A connect that netsh refuses (not in the scan cache)
    # is retried after a rescan instead of waiting out the window. Returns the profile that worked,
    # or $null (no saved profile reaches that subnet).
    param(
        [Parameter(Mandatory = $true)][string] $HostIp,
        [int] $PrefixLength = 24,
        [int] $PerProfileSec = 25,
        [int] $OutOfRangeSec = 8,
        [string] $LogPrefix = '[wifi]'
    )
    if (Get-LoopSegmentsPcIpv4OnSubnet -HostIp $HostIp -PrefixLength $PrefixLength) { return (Get-LoopSegmentsWifiState).Current }
    if (Request-LoopSegmentsWifiScan) { Start-Sleep -Seconds 4 }
    $wifi = Get-LoopSegmentsWifiState
    $others = @($wifi.Profiles | Where-Object { $_ -ne $wifi.Current })
    $inRange = @($others | Where-Object { $wifi.Visible -contains $_ })
    $order = $inRange + @($others | Where-Object { $wifi.Visible -notcontains $_ })
    foreach ($p in $order) {
        $windowSec = if ($inRange -contains $p) { $PerProfileSec } else { $OutOfRangeSec }
        Write-Host "$LogPrefix Switching this PC's Wi-Fi to $p (want an IP on the $HostIp /$PrefixLength subnet)..."
        $until = (Get-Date).AddSeconds($windowSec)
        $accepted = $false
        $lastRefusal = $null
        while ((Get-Date) -lt $until) {
            if (-not $accepted) {
                $out = (Invoke-LoopSegmentsNetsh wlan connect "name=$p") -join ' '
                if ($out -match '(?i)completed successfully') {
                    $accepted = $true
                    # From here on the profile gets the full window: association + DHCP take a while.
                    $until = [datetime]::Now.AddSeconds([Math]::Max($PerProfileSec, ($until - [datetime]::Now).TotalSeconds))
                } else {
                    # Not in the scan cache (or no such profile): rescan, then try again.
                    $lastRefusal = $out.Trim()
                    [void](Request-LoopSegmentsWifiScan)
                    Start-Sleep -Seconds 3
                    continue
                }
            }
            Start-Sleep -Seconds 2
            $ip = Get-LoopSegmentsPcIpv4OnSubnet -HostIp $HostIp -PrefixLength $PrefixLength
            if ($ip) { Write-Host "$LogPrefix PC is on $p ($ip)." -ForegroundColor Green; return $p }
        }
        if (-not $accepted -and $lastRefusal) { Write-Host "$LogPrefix   netsh: $lastRefusal" -ForegroundColor DarkGray }
        elseif ($accepted) { Write-Host "$LogPrefix   $p connected but gave no IP on that subnet in $PerProfileSec s." -ForegroundColor DarkGray }
    }
    # Nothing reached it: go back to where the PC was.
    if ($wifi.Current) { [void](Invoke-LoopSegmentsNetsh wlan connect "name=$($wifi.Current)") }
    return $null
}
