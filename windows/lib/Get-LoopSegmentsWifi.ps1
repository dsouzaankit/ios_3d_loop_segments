# Windows Wi-Fi helpers (netsh): which saved network the PC is on, and switching it onto the network
# that serves a given subnet. Dot-source from the gateway check (companion start-up) and the USB IPA
# install. Self-contained: no other lib file needed.
#
# A Wi-Fi switch is the fast, side-effect-free way to put this PC on (or off) the phone LAN: about
# 5 s, versus a router Wi-Fi restart (1-2 min) that also knocks every other device off that AP.

function Get-LoopSegmentsWifiState {
    # Connected profile, saved profiles (netsh lists them in Windows' priority order), SSIDs in range.
    $iface = (& netsh wlan show interfaces) -join "`n"
    $current = if ($iface -match '(?m)^\s+Profile\s+:\s*(.+?)\s*$') { $Matches[1] } else { $null }
    $profiles = @((& netsh wlan show profiles) | ForEach-Object { if ($_ -match 'All User Profile\s+:\s*(.+?)\s*$') { $Matches[1] } })
    $visible = @((& netsh wlan show networks) | ForEach-Object { if ($_ -match '^SSID \d+\s+:\s*(.+?)\s*$') { $Matches[1] } })
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
    # Already there: returns the current profile without switching. Otherwise tries saved profiles in
    # range first, then the rest (a scan can briefly miss a restarting AP), PerProfileSec each, and
    # returns the profile that worked, or $null (no saved profile reaches that subnet).
    param(
        [Parameter(Mandatory = $true)][string] $HostIp,
        [int] $PrefixLength = 24,
        [int] $PerProfileSec = 20,
        [string] $LogPrefix = '[wifi]'
    )
    $wifi = Get-LoopSegmentsWifiState
    if (Get-LoopSegmentsPcIpv4OnSubnet -HostIp $HostIp -PrefixLength $PrefixLength) { return $wifi.Current }
    $others = @($wifi.Profiles | Where-Object { $_ -ne $wifi.Current })
    $order = @($others | Where-Object { $wifi.Visible -contains $_ }) + @($others | Where-Object { $wifi.Visible -notcontains $_ })
    foreach ($p in $order) {
        Write-Host "$LogPrefix Switching this PC's Wi-Fi to $p (want an IP on the $HostIp /$PrefixLength subnet)..."
        & netsh wlan connect "name=$p" | Out-Null
        $until = (Get-Date).AddSeconds($PerProfileSec)
        while ((Get-Date) -lt $until) {
            Start-Sleep -Seconds 2
            $ip = Get-LoopSegmentsPcIpv4OnSubnet -HostIp $HostIp -PrefixLength $PrefixLength
            if ($ip) { Write-Host "$LogPrefix PC is on $p ($ip)." -ForegroundColor Green; return $p }
        }
    }
    # Nothing reached it: go back to where the PC was.
    if ($wifi.Current) { & netsh wlan connect "name=$($wifi.Current)" | Out-Null }
    return $null
}
