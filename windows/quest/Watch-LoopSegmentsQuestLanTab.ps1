<#
.SYNOPSIS
  Open the phone LAN page in Quest Browser over adb; keep its flags set; clear its history.

.DESCRIPTION
  Default (-Once, used by the "Open on Quest" button through the companion sink): opens -Url in a
  NORMAL Quest Browser tab, signed in:
    1. makes sure chrome://flags "unsafely-treat-insecure-origin-as-secure" is enabled and lists
       every phone LAN origin (restarts Quest Browser only if it had to change the flag),
    2. VIEW intent for the plain URL (retried; the browser sometimes drops the first one),
    3. over the browser's DevTools socket: navigate that tab to http://admin:<password>@host/
       (caches the LAN login), then back to the plain URL, then drop its back/forward entries.
       A page whose URL still has user:pass@ cannot fetch() (status_lists.json would fail).
  The password comes from loop-segments-windows.json (per-phone phoneLanHosts[].webdavPassword,
  else webdavPassword); it is never logged or put on a command line. -NoLanLogin /
  questSendLanLogin=false opens the plain URL (you sign in on the headset).

  Normal tab, not private: Quest Browser disables immersive WebXR in private tabs, so the XR player
  cannot enter VR there. -PrivateTab (or questIncognito=true) still opens a private tab instead
  (Chromium IncognitoTabLauncher + typed URL; falls back to a normal tab).

  -WaitMinutes N : with -Once, a headset that is asleep or off adb is not an error: keep polling
                   for up to N minutes and open the page when it wakes (the button uses 7).
                   -StatusFile gets 'queued' / 'opening' so the companion sink can report it.
  -EnsureFlags   : only step 1 (companion runs it hidden at startup).
  -ClearHistory  : (-CloseLanTabs first closes every tab on a phone LAN origin; -SkipHistoryClear
                   then stops there) delete the Quest Browser history entries on the phone LAN
                   origins and the Quest control page (through the browser's own History list);
                   other history, cookies, cache, passwords, forms, settings are kept. If that
                   fails, clears ALL history from the questClearHistoryFallback range (default
                   last 24 hours, history only) through the Clear browsing data dialog. Companion
                   runs it on close.
  -EnableProximity : turn the proximity sensor back on (undoes a `prox_close` override, so the
                   headset sleeps again when taken off). Companion runs it on close. Needs no -Url.
  -DisableProximity : hold the proximity sensor off (`prox_close`; headset stays awake when taken
                   off). -ToggleProximity flips it. Both need no -Url; quest\Set-QuestProximitySensor.ps1
                   wraps all three.
  -SkyboxPush    : put WebDAV server 'Loop Segments' in SKYBOX's Network list at the phone's current
                   address (-LanConfig lan_config.json, else -Url) with the current LAN login, and drop
                   the ones this PC added at older addresses (QuestSkybox.ps1; stops SKYBOX only when
                   the row changes). The Quest control page's Push button.
  -SkyboxUpdate  : the same, only if such a server is already there (Update button).
  -ClearSkyboxWebDav : remove every SKYBOX server this PC added (with -ClearHistory: after the
                   history step). Needs no -Url.
  -KeepAwakeSession : until -ParentPid exits, every ~20 s: when the headset is on adb and the
                   proximity override is not CLOSE, send `prox_close` (headset acts as worn and does
                   not sleep, so it stays on adb). Re-applies after a headset reboot. Never re-enables
                   the sensor itself (the companion's cleanup does, after clearing history).

  Without -Once / -EnsureFlags / -ClearHistory it keeps polling and opens the page on each
  asleep->Awake (manual use); -ParentPid makes it exit with that process.

  Needs developer mode on the Quest and adb on this PC (winget install Google.PlatformTools).
  Wireless adb is switched off by every Quest reboot; the adb-auto-enable app
  (https://github.com/project-SIMPLE/adb-auto-enable) keeps it on. Setup: quest\README.md.

  Finding the headset:
    1. A device already in `adb devices -l` whose model looks like a Quest (or -Serial).
    2. `adb connect <questAdbHost>:<questAdbPort>` (default port 5555) when questAdbHost is set.
    3. `adb mdns services` _adb-tls-connect entries (wireless-debugging TLS port, already paired).
    4. Not found for questAdbRediscoverSec (60 s) and no adb device connected: restart the adb server
       once and look over mDNS again (at most every 5 min across processes; 0 = off).

  Log: %TEMP%\loopsegments-quest-lantab.log
  Exit codes: 0 ok, 1 headset not reachable / asleep, 2 no adb or bad arguments, 3 step failed.

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -Once

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -EnsureFlags

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -ClearHistory

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -EnableProximity

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -ProbeIncognito
  Read-only: list what Quest Browser exposes for incognito / private launches. Full
  `dumpsys package com.oculus.browser` is saved to %TEMP%\loopsegments-quest-browser-dumpsys.txt.
#>
[CmdletBinding()]
param(
    [string] $Url = '',
    [int] $ParentPid = 0,
    [int] $PollSeconds = 5,
    [string] $AdbExe = '',
    [string] $Serial = '',
    [string] $QuestHost = '',
    [int] $Port = 0,
    # Open once now (no wake transition needed) and exit.
    [switch] $Once,
    # With -Once: wait up to this many minutes for an asleep / unreachable headset to wake.
    [int] $WaitMinutes = 0,
    # With -Once: file that gets 'queued' / 'opening' (read by the companion sink).
    [string] $StatusFile = '',
    # Read-only: report Quest Browser incognito / private launch entry points and exit.
    [switch] $ProbeIncognito,
    # Open a private tab instead of the default normal tab (no WebXR immersive mode there).
    [switch] $PrivateTab,
    # Always a normal tab, even if questIncognito=true.
    [switch] $NoIncognito,
    # Do not sign the tab in with admin:<password>@ (you sign in on the headset).
    [switch] $NoLanLogin,
    # Only make sure the insecure-origin chrome://flags entry covers the phone LAN origins.
    [switch] $EnsureFlags,
    # Only clear Quest Browser history (History only, All time).
    [switch] $ClearHistory,
    # With -ClearHistory: first close every tab on a phone LAN origin.
    [switch] $CloseLanTabs,
    # With -ClearHistory -CloseLanTabs: close the tabs but keep history.
    [switch] $SkipHistoryClear,
    # With -ClearHistory: afterwards turn the proximity sensor back on (companion close, one process).
    [switch] $EnableProximityAfter,
    # Do not touch chrome://flags before opening the tab.
    [switch] $NoFlags,
    # Only turn the proximity sensor back on (am broadcast ...vrpowermanager.automation_disable).
    [switch] $EnableProximity,
    # Only hold the proximity sensor off (am broadcast ...vrpowermanager.prox_close): headset stays awake.
    [switch] $DisableProximity,
    # Only flip the proximity sensor: off if it is on, on if it is held off.
    [switch] $ToggleProximity,
    # Keep the headset awake (prox_close) while -ParentPid runs.
    [switch] $KeepAwakeSession,
    # Quest control page: put the phone in SKYBOX as WebDAV server 'Loop Segments' (current address
    # and login), dropping older addresses this PC added.
    [switch] $SkyboxPush,
    # Same, but only if such a server is already in SKYBOX.
    [switch] $SkyboxUpdate,
    # Remove that SKYBOX WebDAV server (alone, or with -ClearHistory after the history step).
    [switch] $ClearSkyboxWebDav,
    # The companion's lan_config.json: phone address for the SKYBOX steps (re-read every poll).
    [string] $LanConfig = ''
)

Set-StrictMode -Version Latest
$script:StartedAt = [DateTime]::UtcNow
$ErrorActionPreference = 'Stop'

$LogPath = Join-Path $env:TEMP 'loopsegments-quest-lantab.log'
$BrowserPackage = 'com.oculus.browser'
$script:Cfg = $null

function Write-QuestLog {
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 } catch {}
    Write-Host "[quest] $Message"
}

# Per-PC overrides from windows\loop-segments-windows.json (params win).
$script:AdbRediscoverSec = 60
$WindowsLib = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\LoopSegments-Windows.ps1'
if (Test-Path -LiteralPath $WindowsLib) {
    try {
        . $WindowsLib
        $cfg = Get-LoopSegmentsWindowsSettings
        $script:Cfg = $cfg
        if ([string]::IsNullOrWhiteSpace($AdbExe)) { $AdbExe = [string]$cfg.questAdbExe }
        if ([string]::IsNullOrWhiteSpace($QuestHost)) { $QuestHost = [string]$cfg.questAdbHost }
        if ([string]::IsNullOrWhiteSpace($Serial)) { $Serial = [string]$cfg.questAdbSerial }
        if ($Port -le 0 -and $null -ne $cfg.questAdbPort) { $Port = [int]$cfg.questAdbPort }
        if ($null -ne $cfg.questAdbRediscoverSec) { $script:AdbRediscoverSec = [int]$cfg.questAdbRediscoverSec }
        if ($cfg.Contains('questIncognito') -and $cfg.questIncognito -eq $true) { $PrivateTab = $true }
        if ($cfg.Contains('questEnsureInsecureOriginFlag') -and $cfg.questEnsureInsecureOriginFlag -eq $false) { $NoFlags = $true }
        if ($cfg.Contains('questSendLanLogin') -and $cfg.questSendLanLogin -eq $false) { $NoLanLogin = $true }
    } catch {
        Write-QuestLog "Config read failed: $($_.Exception.Message)"
    }
}
if ($Port -le 0) { $Port = 5555 }
if ($NoIncognito) { $PrivateTab = $false }
. (Join-Path $PSScriptRoot 'QuestDevTools.ps1')
. (Join-Path $PSScriptRoot 'QuestSkybox.ps1')

function Find-QuestAdbExe {
    if (-not [string]::IsNullOrWhiteSpace($AdbExe)) {
        if (Test-Path -LiteralPath $AdbExe) { return $AdbExe }
        Write-QuestLog "questAdbExe not found: $AdbExe"
    }
    $cmd = Get-Command -Name adb.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return [string]$cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\adb.exe')
        (Join-Path $env:ProgramFiles 'Meta Quest Developer Hub\resources\bin\adb.exe')
        'C:\platform-tools\adb.exe'
    )
    $wingetPkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetPkgs) {
        $candidates += @(Get-ChildItem -LiteralPath $wingetPkgs -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'platform-tools\adb.exe' })
    }
    foreach ($p in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Invoke-Adb {
    param([string[]] $Arguments, [int] $TimeoutSec = 10)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:Adb
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill($true) } catch {}
        return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

function Get-OnlineQuestSerial {
    $r = Invoke-Adb -Arguments @('devices', '-l')
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' })
    if (-not [string]::IsNullOrWhiteSpace($Serial)) {
        foreach ($l in $lines) { if ($l -match ('^' + [regex]::Escape($Serial) + '\s')) { return $Serial } }
        return $null
    }
    foreach ($l in $lines) {
        if ($l -match '(?i)\bmodel:Quest' -or $l -match '(?i)\bproduct:(hollywood|eureka|seacliff|panther|monterey)') {
            return ($l -split '\s+')[0]
        }
    }
    # Exactly one non-Quest-looking device that we connected to ourselves (host:port) - take it.
    if (-not [string]::IsNullOrWhiteSpace($QuestHost)) {
        foreach ($l in $lines) {
            if ($l -match ('^' + [regex]::Escape($QuestHost) + ':\d+\s')) { return ($l -split '\s+')[0] }
        }
    }
    return $null
}

function Connect-Quest {
    if (-not [string]::IsNullOrWhiteSpace($QuestHost)) {
        $target = '{0}:{1}' -f $QuestHost, $Port
        $r = Invoke-Adb -Arguments @('connect', $target) -TimeoutSec 8
        $msg = ($r.Out + $r.Err).Trim()
        if ($msg -ne $script:LastConnectMsg) {
            Write-QuestLog "adb connect $target -> $msg"
            $script:LastConnectMsg = $msg
        }
        $s = Get-OnlineQuestSerial
        if ($s) { return $s }
    }
    # Wireless debugging (TLS) advertises its random port over mDNS; works once paired.
    $s = Connect-QuestViaMdns
    if ($s) { $script:MdnsUnseenSince = $null; return $s }
    if (Invoke-QuestAdbRediscover) {
        $s = Connect-QuestViaMdns
        if ($s) { $script:MdnsUnseenSince = $null; return $s }
    }
    return $null
}

function Connect-QuestViaMdns {
    $m = Invoke-Adb -Arguments @('mdns', 'services') -TimeoutSec 8
    foreach ($l in @($m.Out -split "`r?`n")) {
        if ($l -match '_adb-tls-connect\._tcp\.?\s+(\d{1,3}(?:\.\d{1,3}){3}:\d+)') {
            $target = $Matches[1]
            [void](Invoke-Adb -Arguments @('connect', $target) -TimeoutSec 8)
            $s = Get-OnlineQuestSerial
            if ($s) { Write-QuestLog "Connected via mDNS $target"; return $s }
        }
    }
    return $null
}

# The PC's adb server can stop hearing the headset's mDNS announcements (seen after the headset
# slept and came back on a new wireless-debugging port: the headset advertised, `adb mdns services`
# stayed empty until the server was restarted). So once this process has not found the headset for
# questAdbRediscoverSec (default 60 s), restart the adb server and look again. Only when no adb
# device at all is connected (nothing to interrupt), and at most once every 5 min across all
# companion processes (shared %TEMP% stamp). Returns $true when it restarted the server.
$script:MdnsUnseenSince = $null
$script:AdbRestartStamp = Join-Path $env:TEMP 'loopsegments-adb-rediscover.txt'
function Invoke-QuestAdbRediscover {
    if ($script:AdbRediscoverSec -le 0) { return $false }
    $now = [DateTime]::UtcNow
    if (-not $script:MdnsUnseenSince) { $script:MdnsUnseenSince = $now; return $false }
    $unseen = ($now - $script:MdnsUnseenSince).TotalSeconds
    if ($unseen -lt $script:AdbRediscoverSec) { return $false }
    try {
        if (Test-Path -LiteralPath $script:AdbRestartStamp) {
            $last = [DateTime]::Parse((Get-Content -LiteralPath $script:AdbRestartStamp -Raw).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind)
            if (($now - $last).TotalMinutes -lt 5) { return $false }
        }
    } catch {}
    $d = Invoke-Adb -Arguments @('devices')
    $attached = @($d.Out -split "`r?`n" | Where-Object { $_ -match '^\S+\s+(device|unauthorized|recovery|sideload)\b' })
    if ($attached.Count -gt 0) { return $false }
    try { Set-Content -LiteralPath $script:AdbRestartStamp -Value $now.ToString('o') -Encoding ascii } catch {}
    Write-QuestLog ("adb: headset not seen over mDNS for {0:0} s - restarting the adb server to rediscover it." -f $unseen)
    [void](Invoke-Adb -Arguments @('kill-server') -TimeoutSec 10)
    [void](Invoke-Adb -Arguments @('start-server') -TimeoutSec 15)
    # mDNS answers arrive over the next few seconds.
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 1
        $m = Invoke-Adb -Arguments @('mdns', 'services') -TimeoutSec 8
        if ($m.Out -match '_adb-tls-connect') { break }
    }
    $script:MdnsUnseenSince = $now
    return $true
}

function Get-QuestWakefulness {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'power') -TimeoutSec 8
    if ($r.Code -ne 0) { return $null }
    if ($r.Out -match 'mWakefulness=(\w+)') { return $Matches[1] }
    return $null
}

$IncognitoLauncher = 'com.oculus.browser/org.chromium.chrome.browser.incognito.IncognitoTabLauncher'

# adb shell joins args into one device shell line: single-quote the URL.
function Get-QuestQuotedUrl { "'" + ($Url -replace "'", '') + "'" }

function Get-AdbMessage { param($R) (($R.Out + ' ' + $R.Err) -replace '\s+', ' ').Trim() }

function Test-AdbStartOk { param($R) ($R.Code -eq 0 -and (Get-AdbMessage $R) -notmatch '(?i)\bError\b|Exception') }

function Test-QuestBrowserResumed {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'activity', 'activities') -TimeoutSec 10
    $resumed = @($r.Out -split "`r?`n" | Where-Object { $_ -match '(?i)ResumedActivity' })
    return (@($resumed | Where-Object { $_ -match [regex]::Escape($BrowserPackage) }).Count -gt 0)
}

# The phone's LAN login for -ForUrl (default -Url): webdavUser + per-phone
# phoneLanHosts[].webdavPassword, else webdavPassword. Re-reads loop-segments-windows.json on every
# call. Never logged.
function Get-QuestLanLogin {
    param([string] $ForUrl = $Url)
    $u = [Uri]$ForUrl
    $cred = Get-LoopSegmentsWebDAVCredentials
    $pass = [string]$cred.Password
    foreach ($raw in @((Get-LoopSegmentsWindowsSettings).phoneLanHosts)) {
        if ($null -eq $raw) { continue }
        $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw
        if ($e -and $e.Host -eq $u.Host -and -not [string]::IsNullOrWhiteSpace([string]$e.Password)) { $pass = [string]$e.Password }
    }
    return [pscustomobject]@{ User = [string]$cred.User; Password = $pass }
}

# LAN URL with the login (Get-QuestLanLogin) as percent-encoded userinfo. Returns -Url unchanged
# when sending the login is off or none is set.
function Get-QuestTypedUrl {
    if (-not $script:SendLanLogin) { return ($Url -replace "'", '') }
    try {
        $u = [Uri]$Url
        $login = Get-QuestLanLogin
        $user = $login.User
        $pass = $login.Password
        if ([string]::IsNullOrEmpty($pass)) {
            Write-QuestLog 'No LAN password in loop-segments-windows.json - opening without the login.'
            return ($Url -replace "'", '')
        }
        $userInfo = [Uri]::EscapeDataString($user) + ':' + [Uri]::EscapeDataString($pass)
        return ('{0}://{1}@{2}' -f $u.Scheme, $userInfo, $u.Authority) + $u.PathAndQuery
    } catch {
        Write-QuestLog 'Could not read the LAN login - opening without it.'
        return ($Url -replace "'", '')
    }
}

function Test-QuestImeShown {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'input_method') -TimeoutSec 10
    return ($r.Out -match 'mInputShown=true')
}

# Best effort: read Quest Browser tabs over its DevTools socket (what chrome://inspect uses).
# $true = a tab shows -Url, $false = none does after ~6 s, $null = could not check.
function Test-QuestBrowserHasUrl {
    # -Mode Any   : a tab shows -Url (login in the URL ignored)
    # -Mode Login : a tab loaded -Url through http://user:pass@host/ (login now cached)
    # -Mode Plain : a tab shows -Url exactly, with no login in its URL
    param([string] $DeviceSerial, [ValidateSet('Any', 'Login', 'Plain')] [string] $Mode = 'Any')
    $f = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'forward', 'tcp:0', 'localabstract:chrome_devtools_remote')
    $port = 0
    if (-not [int]::TryParse(($f.Out).Trim(), [ref]$port) -or $port -le 0) { return $null }
    try {
        $want = $Url.TrimEnd('/')
        for ($i = 0; $i -lt 12; $i++) {
            try {
                # Invoke-RestMethod emits the JSON array as one object: enumerate it explicitly.
                $tabs = @((Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 3 -NoProxy) | ForEach-Object { $_ })
                foreach ($t in $tabs) {
                    $rawUrl = ([string]$t.url).TrimEnd('/')
                    $hasLogin = $rawUrl -match '^https?://[^/@]*@'
                    $bare = $rawUrl -replace '^(https?://)[^/@]*@', '$1'
                    if ($bare -ne $want) { continue }
                    if ($Mode -eq 'Any' -or ($Mode -eq 'Login' -and $hasLogin) -or ($Mode -eq 'Plain' -and -not $hasLogin)) { return $true }
                }
            } catch {}
            Start-Sleep -Milliseconds 500
        }
        return $false
    } finally {
        [void](Invoke-Adb -TimeoutSec 5 -Arguments @('-s', $DeviceSerial, 'forward', '--remove', "tcp:$port"))
    }
}

# Every phone LAN origin the flag should list: -Url plus phoneLanHost / phoneLanHosts from config.
function Get-QuestLanOrigins {
    $list = [System.Collections.Generic.List[string]]::new()
    try { $u = [Uri]$Url; $list.Add(('{0}://{1}' -f $u.Scheme, $u.Authority)) } catch {}
    if ($script:Cfg) {
        $port = 8765
        try { if ([int]$script:Cfg.lanPort -gt 0) { $port = [int]$script:Cfg.lanPort } } catch {}
        $hostsRaw = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Cfg.phoneLanHost)) { $hostsRaw += [string]$script:Cfg.phoneLanHost }
        foreach ($raw in @($script:Cfg.phoneLanHosts)) { if ($null -ne $raw) { $hostsRaw += $raw } }
        foreach ($raw in $hostsRaw) {
            try {
                $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw -DefaultPort $port
                if ($e -and $e.Host) { $list.Add(('http://{0}:{1}' -f $e.Host, $e.Port)) }
            } catch {}
        }
    }
    return @($list | Select-Object -Unique)
}

# A page on the phone that needs no login (XR assets stay open), used for helper tabs.
function Get-QuestHelperUrl {
    try { $u = [Uri]$Url; return ('{0}://{1}/xr-assets/aframe.min.js' -f $u.Scheme, $u.Authority) } catch { return $Url }
}

function Invoke-QuestFlagSync {
    param([string] $DeviceSerial)
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) { return 'failed' }
    try {
        return (Sync-QuestInsecureOriginFlag -DeviceSerial $DeviceSerial -Origins (Get-QuestLanOrigins) -HelperUrl (Get-QuestHelperUrl))
    } catch {
        Write-QuestLog "Flags: $($_.Exception.Message)"
        return 'failed'
    } finally { Close-QuestDevTools }
}

# ---- Quest control page (quest\Serve-QuestControlPage.ps1, on this PC) ----

function Get-QuestControlPort {
    $p = 18766
    try { if ($script:Cfg -and [int]$script:Cfg.questControlPort -gt 0) { $p = [int]$script:Cfg.questControlPort } } catch {}
    return $p
}

# This PC's IPv4 address on the route to the headset (or, for a USB serial, to the phone): the
# address the Quest reaches the control page on. UDP "connect" sends nothing.
function Get-QuestControlPcAddress {
    param([string] $DeviceSerial)
    $target = $null
    if ($DeviceSerial -match '^(\d{1,3}(?:\.\d{1,3}){3}):\d+$') { $target = $Matches[1] }
    elseif ($QuestHost -match '^\d{1,3}(\.\d{1,3}){3}$') { $target = $QuestHost }
    else { try { $target = ([Uri]$Url).Host } catch {} }
    if (-not $target) { return $null }
    $u = [System.Net.Sockets.UdpClient]::new()
    try {
        $u.Connect($target, 9)
        return ([System.Net.IPEndPoint]$u.Client.LocalEndPoint).Address.ToString()
    } catch { return $null } finally { $u.Dispose() }
}

function Get-QuestControlOrigin {
    param([string] $DeviceSerial)
    $ip = Get-QuestControlPcAddress -DeviceSerial $DeviceSerial
    if (-not $ip) { return $null }
    return ('http://{0}:{1}' -f $ip, (Get-QuestControlPort))
}

# Is the companion's control page server running? (it writes %TEMP%\loopsegments-quest-control.json)
function Test-QuestControlPageRunning {
    $state = Join-Path $env:TEMP 'loopsegments-quest-control.json'
    if (-not (Test-Path -LiteralPath $state)) { return $false }
    try { $c = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json; return [bool](Get-Process -Id ([int]$c.pid) -ErrorAction SilentlyContinue) } catch { return $false }
}

# Open on Quest: also open the control page in its own normal tab, signed in with the LAN login
# (reused if already open). Needs an open DevTools session. Never fails the LAN page.
function Open-QuestControlTab {
    param([string] $DeviceSerial)
    if ($script:Cfg -and $script:Cfg.Contains('questControlPageOnQuest') -and $script:Cfg.questControlPageOnQuest -eq $false) { return }
    if (-not (Test-QuestControlPageRunning)) { Write-QuestLog 'Control page: not running on this PC - not opened.'; return }
    $origin = Get-QuestControlOrigin -DeviceSerial $DeviceSerial
    if (-not $origin) { Write-QuestLog 'Control page: no PC address on the route to the headset - not opened.'; return }
    $plain = "$origin/"
    $loginUrl = $plain
    if ($script:SendLanLogin) {
        try {
            $l = Get-QuestLanLogin
            if (-not [string]::IsNullOrEmpty($l.Password)) {
                $loginUrl = ('http://{0}:{1}@{2}/' -f [Uri]::EscapeDataString($l.User), [Uri]::EscapeDataString($l.Password), ([Uri]$plain).Authority)
            }
        } catch {}
    }
    try {
        if (Open-QuestSignedInTab -DeviceSerial $DeviceSerial -PlainUrl $plain -LoginUrl $loginUrl -Origins @($origin)) {
            $which = if ($script:QuestReusedTab) { 'reused open tab' } else { 'new tab' }
            Write-QuestLog "Control page: opened $plain in Quest browser ($which)."
        } else {
            Write-QuestLog "Control page: $plain did not load on the Quest (Windows Firewall blocking port $(Get-QuestControlPort)? see quest\README.md)."
        }
    } catch {
        Write-QuestLog "Control page: $($_.Exception.Message)"
    }
}

function Open-QuestNormalTab {
    param([string] $DeviceSerial)
    $plain = ($Url -replace "'", '')
    $login = Get-QuestTypedUrl
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) {
        # No DevTools: plain VIEW intent, no login.
        $r = Invoke-Adb -TimeoutSec 15 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start',
            '-a', 'android.intent.action.VIEW', '-d', (Get-QuestQuotedUrl), '-p', $BrowserPackage)
        if (Test-AdbStartOk $r) { Write-QuestLog "Opened $Url in Quest browser, normal tab, not signed in ($DeviceSerial)"; return $true }
        Write-QuestLog "am start failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return $false
    }
    try {
        # Quest control page first (its own tab), so the LAN page below ends up in front.
        Open-QuestControlTab -DeviceSerial $DeviceSerial
        if (-not (Open-QuestSignedInTab -DeviceSerial $DeviceSerial -PlainUrl $plain -LoginUrl $login -Origins (Get-QuestLanOrigins))) { return $false }
        $how = if ($login -ne $plain) { 'signed in' } else { 'not signed in' }
        $which = if ($script:QuestReusedTab) { 'reused open tab' } else { 'new tab' }
        Write-QuestLog "Opened $Url in Quest browser, normal tab, $how, $which ($DeviceSerial)"
        return $true
    } catch {
        Write-QuestLog "Normal tab: $($_.Exception.Message)"
        return $false
    } finally { Close-QuestDevTools }
}

# Ctrl+L (retried until the address bar has focus), type TypedUrl, Enter. Never logs TypedUrl.
function Send-QuestOmniboxUrl {
    param([string] $DeviceSerial, [string] $TypedUrl)
    $omnibox = $false
    for ($i = 0; $i -lt 8 -and -not $omnibox; $i++) {
        # A fresh private tab ignores keys for a moment after launch.
        Start-Sleep -Milliseconds 700
        $k = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_L')
        if ($k.Code -ne 0) {
            Write-QuestLog "Ctrl+L failed: $(Get-AdbMessage $k)"
            return $false
        }
        Start-Sleep -Milliseconds 500
        $omnibox = Test-QuestImeShown -DeviceSerial $DeviceSerial
    }
    if (-not $omnibox) {
        Write-QuestLog 'Address bar never took focus - not typing the URL.'
        return $false
    }
    $steps = [System.Collections.Generic.List[object]]::new()
    $steps.Add([string[]]@('input', 'text', ("'" + $TypedUrl + "'")))
    $steps.Add([string[]]@('input', 'keyevent', 'KEYCODE_ENTER'))
    foreach ($step in $steps) {
        $k = Invoke-Adb -TimeoutSec 10 -Arguments (@('-s', $DeviceSerial, 'shell') + $step)
        if ($k.Code -ne 0 -or (Get-AdbMessage $k) -match '(?i)Error|Exception|Unknown') {
            Write-QuestLog "'input $($step[1])' failed (code $($k.Code))."
            return $false
        }
        Start-Sleep -Milliseconds 400
    }
    return $true
}

function Open-QuestIncognitoTab {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 20 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start', '-W', '-n', $IncognitoLauncher)
    if (-not (Test-AdbStartOk $r)) {
        Write-QuestLog "Private-tab launcher failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return $false
    }
    # Let the new private tab settle before keystrokes; only type into Quest Browser.
    $resumed = $false
    for ($i = 0; $i -lt 8 -and -not $resumed; $i++) {
        Start-Sleep -Milliseconds 500
        $resumed = Test-QuestBrowserResumed -DeviceSerial $DeviceSerial
    }
    if (-not $resumed) {
        Write-QuestLog 'Quest Browser not in front after private-tab launch - not typing the URL.'
        return $false
    }
    $plain = ($Url -replace "'", '')
    $typed = Get-QuestTypedUrl
    if (-not (Send-QuestOmniboxUrl -DeviceSerial $DeviceSerial -TypedUrl $typed)) { return $false }
    if ($typed -ne $plain) {
        # A page loaded from http://user:pass@host/ cannot fetch() relative URLs (Chromium refuses
        # URLs with credentials), so status_lists.json etc. fail. Load once with the login so the
        # private session caches it, then reload the same tab from the plain URL.
        if ((Test-QuestBrowserHasUrl -DeviceSerial $DeviceSerial -Mode Login) -eq $false) {
            Write-QuestLog 'Signed-in load not seen in the tab list - reloading without the login anyway.'
        }
        Start-Sleep -Milliseconds 800
        if (-not (Send-QuestOmniboxUrl -DeviceSerial $DeviceSerial -TypedUrl $plain)) {
            Write-QuestLog 'Signed in, but could not reload without the login - page fetches (status_lists.json) will fail.'
            return $true
        }
        $verified = Test-QuestBrowserHasUrl -DeviceSerial $DeviceSerial -Mode Plain
    } else {
        $verified = Test-QuestBrowserHasUrl -DeviceSerial $DeviceSerial -Mode Any
    }
    if ($verified -eq $false) {
        Write-QuestLog "Typed the LAN URL into the private tab, but no browser tab shows $Url - check the headset."
    }
    Write-QuestLog "Opened $Url in Quest browser, private tab ($DeviceSerial)"
    return $true
}

function Open-QuestLanTab {
    param([string] $DeviceSerial)
    if (-not $NoFlags) { [void](Invoke-QuestFlagSync -DeviceSerial $DeviceSerial) }
    if ($PrivateTab) {
        if (Open-QuestIncognitoTab -DeviceSerial $DeviceSerial) { return $true }
        Write-QuestLog 'Falling back to a normal tab.'
    }
    return (Open-QuestNormalTab -DeviceSerial $DeviceSerial)
}

function Invoke-QuestIncognitoProbe {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) {
        Write-QuestLog 'Probe: headset not reachable over adb.'
        return 1
    }
    $dumpPath = Join-Path $env:TEMP 'loopsegments-quest-browser-dumpsys.txt'
    $d = Invoke-Adb -Arguments @('-s', $dev, 'shell', 'dumpsys', 'package', $BrowserPackage) -TimeoutSec 30
    Set-Content -LiteralPath $dumpPath -Value $d.Out -Encoding utf8
    Write-Host "== Quest Browser ($dev) =="
    $ver = [regex]::Match($d.Out, 'versionName=(\S+)')
    Write-Host ("versionName: {0}" -f $(if ($ver.Success) { $ver.Groups[1].Value } else { '?' }))
    Write-Host "== dumpsys lines matching incognito / private =="
    $hits = @($d.Out -split "`r?`n" | Where-Object { $_ -match '(?i)incognito|private.?tab|privatebrows|OPEN_PRIVATE' } |
        ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($hits.Count -eq 0) { Write-Host '(none)' } else { $hits | ForEach-Object { Write-Host "  $_" } }
    Write-Host "== resolve Chromium OPEN_PRIVATE_TAB =="
    $res = Invoke-Adb -Arguments @('-s', $dev, 'shell', 'cmd', 'package', 'resolve-activity', '--brief',
        '-a', 'org.chromium.chrome.browser.incognito.OPEN_PRIVATE_TAB', $BrowserPackage) -TimeoutSec 15
    Write-Host ("  " + (($res.Out + ' ' + $res.Err) -replace '\s+', ' ').Trim())
    Write-Host "== resolve VIEW http (default handler) =="
    $res = Invoke-Adb -Arguments @('-s', $dev, 'shell', 'cmd', 'package', 'resolve-activity', '--brief',
        '-a', 'android.intent.action.VIEW', '-d', 'http://10.0.0.1/', $BrowserPackage) -TimeoutSec 15
    Write-Host ("  " + (($res.Out + ' ' + $res.Err) -replace '\s+', ' ').Trim())
    Write-Host "Full dump: $dumpPath"
    Write-QuestLog "Probe done ($dev, $($hits.Count) incognito/private lines) -> $dumpPath"
    return 0
}

# Proximity sensor: `prox_close` forces "worn" (virtual state CLOSE, headset never sleeps);
# `automation_disable` drops that override so the real sensor is used again (state DISABLED).
function Get-QuestVirtualProximity {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'vrpowermanager')
    if ($r.Out -match 'Virtual proximity state:\s*(\w+)') { return $Matches[1] }
    return $null
}

# Hold the proximity sensor off (`prox_close`, virtual state CLOSE): the headset acts as worn and
# does not sleep when taken off. Undone by -EnableProximity or a headset reboot.
function Invoke-QuestDisableProximity {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Proximity: headset not reachable over adb - skipped.'; return 1 }
    $before = Get-QuestVirtualProximity -DeviceSerial $dev
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.prox_close')
    if ($r.Code -ne 0 -or ($r.Out -notmatch 'Broadcast completed')) {
        Write-QuestLog "Proximity: broadcast failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return 3
    }
    Start-Sleep -Milliseconds 500
    $after = Get-QuestVirtualProximity -DeviceSerial $dev
    if ($after -and $after -ne 'CLOSE') {
        Write-QuestLog "Proximity: override is '$after' after switching the sensor off (was '$before')."
        return 3
    }
    Write-QuestLog ("Proximity: sensor off, headset stays awake (override was '{0}', now '{1}')." -f $(if ($before) { $before } else { '?' }), $(if ($after) { $after } else { '?' }))
    return 0
}

# Flip it: CLOSE (held off) -> on, anything else -> off.
function Invoke-QuestToggleProximity {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Proximity: headset not reachable over adb - skipped.'; return 1 }
    if ((Get-QuestVirtualProximity -DeviceSerial $dev) -eq 'CLOSE') { return (Invoke-QuestEnableProximity) }
    return (Invoke-QuestDisableProximity)
}

function Invoke-QuestEnableProximity {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Proximity: headset not reachable over adb - skipped.'; return 1 }
    $before = Get-QuestVirtualProximity -DeviceSerial $dev
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.automation_disable')
    if ($r.Code -ne 0 -or ($r.Out -notmatch 'Broadcast completed')) {
        Write-QuestLog "Proximity: broadcast failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return 3
    }
    Start-Sleep -Milliseconds 500
    $after = Get-QuestVirtualProximity -DeviceSerial $dev
    if ($after -and $after -ne 'DISABLED') {
        Write-QuestLog "Proximity: override still '$after' after re-enabling (was '$before')."
        return 3
    }
    Write-QuestLog ("Proximity: sensor on (override was '{0}', now '{1}')." -f $(if ($before) { $before } else { '?' }), $(if ($after) { $after } else { '?' }))
    return 0
}

function Invoke-QuestKeepAwakeSession {
    if ($ParentPid -le 0) { Write-QuestLog 'Keep-awake: -ParentPid is required.'; return 2 }
    Write-QuestLog "Keep-awake: holding the Quest proximity sensor off while PID $ParentPid runs."
    $lastNote = ''
    while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
        $note = ''
        try {
            $dev = Get-OnlineQuestSerial
            if (-not $dev) { $dev = Connect-Quest }
            if (-not $dev) {
                $note = 'headset not on adb - waiting'
            } else {
                $state = Get-QuestVirtualProximity -DeviceSerial $dev
                if ($state -eq 'CLOSE') {
                    $note = "sensor held off ($dev)"
                } else {
                    # Check the parent again right before acting: cleanup may have started.
                    if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
                    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.prox_close')
                    $note = if ($r.Out -match 'Broadcast completed') { "sensor switched off (was '$state', $dev)" } else { "prox_close failed: $(Get-AdbMessage $r)" }
                }
            }
        } catch {
            $note = "error: $($_.Exception.Message)"
        }
        if ($note -ne $lastNote) { Write-QuestLog "Keep-awake: $note"; $lastNote = $note }
        for ($i = 0; $i -lt 20 -and (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
    }
    Write-QuestLog 'Keep-awake: companion gone - stopping (sensor is re-enabled by the companion cleanup).'
    return 0
}

# The phone LAN URL to use now: from -LanConfig (the companion's lan_config.json, re-read each call)
# when given, else -Url.
function Get-QuestSkyboxCurrentLanUrl {
    $fromCfg = Get-QuestSkyboxLanUrlFromConfig -Path $LanConfig
    if ($fromCfg) { return $fromCfg }
    if (-not [string]::IsNullOrWhiteSpace($Url)) { return $Url }
    return $null
}

# Quest control page Push / Update (one run each): put server 'Loop Segments' in SKYBOX at the phone's
# current address (-LanConfig lan_config.json, else -Url) with the current LAN login, and delete the
# servers this PC added at older addresses. -OnlyIfPresent (Update): only if one is there already.
# Returns 'added' / 'updated' / 'unchanged' / 'absent' / 'not installed' / 'unreachable' / 'failed'.
function Invoke-QuestSkyboxWebDavPush {
    param([switch] $OnlyIfPresent)
    $lan = Get-QuestSkyboxCurrentLanUrl
    if (-not $lan) { Write-QuestLog 'SKYBOX: no phone LAN address (lan_config.json / -Url) - nothing pushed.'; return 'failed' }
    $login = Get-QuestLanLogin -ForUrl $lan
    if ([string]::IsNullOrEmpty($login.Password)) { Write-QuestLog 'SKYBOX: no LAN password in loop-segments-windows.json - nothing pushed.'; return 'failed' }
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'SKYBOX: headset not reachable over adb - nothing pushed.'; return 'unreachable' }
    $dav = Get-QuestSkyboxWebDavUrl -LanUrl $lan
    $old = @(Get-QuestSkyboxAddedUrls)
    # Record the URL before the edit, so a kill mid-way still leaves it for the clear.
    Set-QuestSkyboxAddedUrls -Urls (@($old) + $dav)
    $res = Invoke-QuestSkyboxWebDav -DeviceSerial $dev -DavUrl $dav -User $login.User -Password $login.Password -RemoveUrls $old -OnlyIfPresent:$OnlyIfPresent
    if ($res -in @('added', 'updated', 'unchanged')) { Set-QuestSkyboxAddedUrls -Urls @($dav) }
    else { Set-QuestSkyboxAddedUrls -Urls $old }
    return $res
}

# Clear button and companion close: remove every SKYBOX Network entry of this app, in one edit:
#   - WebDAV servers this PC added (state file), and any WebDAV server at a phone address the
#     companion knows (current lan_config.json, phoneLanHost, phoneLanHosts[]; also ones added by hand)
#   - any WebDAV server named 'Loop Segments'
#   - the companion's rclone DLNA server (name rcloneDlnaName, announced by rclone)
function Invoke-QuestSkyboxWebDavClear {
    param([string] $DeviceSerial)
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($u in @(Get-QuestSkyboxAddedUrls)) { $urls.Add($u) }
    $lan = Get-QuestSkyboxCurrentLanUrl
    if ($lan) { $urls.Add((Get-QuestSkyboxWebDavUrl -LanUrl $lan)) }
    $port = 8765
    $dlnaName = 'Loop Segments'
    if ($script:Cfg) {
        try { if ([int]$script:Cfg.lanPort -gt 0) { $port = [int]$script:Cfg.lanPort } } catch {}
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Cfg.rcloneDlnaName)) { $dlnaName = ([string]$script:Cfg.rcloneDlnaName).Trim() }
        $hostsRaw = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Cfg.phoneLanHost)) { $hostsRaw += [string]$script:Cfg.phoneLanHost }
        foreach ($raw in @($script:Cfg.phoneLanHosts)) { if ($null -ne $raw) { $hostsRaw += $raw } }
        foreach ($raw in $hostsRaw) {
            try {
                $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw -DefaultPort $port
                if ($e -and $e.Host) { $urls.Add(('webdav://{0}:{1}/' -f $e.Host, $e.Port)) }
            } catch {}
        }
    }
    $list = @($urls | Where-Object { $_ } | Select-Object -Unique)
    $res = Invoke-QuestSkyboxWebDav -DeviceSerial $DeviceSerial -RemoveUrls $list -RemoveNamedWebDav -RemoveDlnaName $dlnaName
    if ($res -in @('removed', 'absent', 'not installed')) { Set-QuestSkyboxAddedUrls -Urls @() }
    return $res
}

# -StatusFile: progress / result word for the caller (companion sink, Quest control page).
function Set-QuestOpenStatus {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }
    try { Set-Content -LiteralPath $StatusFile -Value $Value -Encoding ascii } catch {}
}

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'adb not found (winget install Google.PlatformTools, or set questAdbExe) - Quest LAN tab disabled.'
    exit 2
}
$script:LastConnectMsg = ''
$script:SendLanLogin = (-not $NoLanLogin) -and [bool](Get-Command Get-LoopSegmentsWebDAVCredentials -ErrorAction SilentlyContinue)
if ($ProbeIncognito) { exit (Invoke-QuestIncognitoProbe) }
if ($EnableProximity) { exit (Invoke-QuestEnableProximity) }
if ($DisableProximity) { exit (Invoke-QuestDisableProximity) }
if ($ToggleProximity) { exit (Invoke-QuestToggleProximity) }
if ($KeepAwakeSession) { exit (Invoke-QuestKeepAwakeSession) }
if ($SkyboxPush -or $SkyboxUpdate) {
    $res = Invoke-QuestSkyboxWebDavPush -OnlyIfPresent:$SkyboxUpdate
    Set-QuestOpenStatus $res
    if ($res -eq 'unreachable') { exit 1 }
    if ($res -eq 'failed') { exit 3 }
    exit 0
}
if ($ClearSkyboxWebDav -and -not $ClearHistory) {
    # Companion close without a LAN URL, or a manual run; -EnableProximityAfter still applies.
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'SKYBOX: headset not reachable over adb - skipped.'; Set-QuestOpenStatus 'unreachable'; exit 1 }
    $sky = Invoke-QuestSkyboxWebDavClear -DeviceSerial $dev
    Set-QuestOpenStatus $sky
    $prox = if ($EnableProximityAfter) { if ((Invoke-QuestEnableProximity) -eq 0) { 'on' } else { 'failed' } } else { 'skipped' }
    if ($sky -eq 'failed' -or $prox -eq 'failed') { exit 3 }
    exit 0
}
if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-QuestLog '-Url is required (unless -ProbeIncognito).'
    exit 2
}
if ($EnsureFlags -or $ClearHistory) {
    # Headset only needs to be on adb (awake or not); never waits.
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) {
        Write-QuestLog ("{0}: headset not reachable over adb - skipped." -f $(if ($ClearHistory) { 'History' } else { 'Flags' }))
        exit 1
    }
    if ($ClearHistory) {
        # Companion close, in this order: LAN tabs, history (both within ~30 s of start), then the
        # proximity sensor. Each step logs its duration.
        $since = { ([DateTime]::UtcNow - $script:StartedAt).TotalSeconds }
        Write-QuestLog ("Cleanup: headset on adb after {0:0.0} s." -f (& $since))
        $res = 'skipped'
        if ($CloseLanTabs -or -not $SkipHistoryClear) {
            if (Open-QuestDevTools -DeviceSerial $dev) {
                try {
                    # Phone LAN page origins, plus the Quest control page on this PC: the tabs to close
                    # and the only history entries deleted.
                    $origins = @(@(Get-QuestLanOrigins) + @(Get-QuestControlOrigin -DeviceSerial $dev) | Where-Object { $_ } | Select-Object -Unique)
                    if ($CloseLanTabs) {
                        $t0 = [DateTime]::UtcNow
                        # Phone LAN page tabs, plus the Quest control page on this PC.
                        $lan = @(Get-QuestLanTabs -Origins $origins)
                        foreach ($t in $lan) { Close-QuestTab -Id $t.id }
                        Write-QuestLog ("Tabs: closed {0} Quest Browser tab(s) on the phone LAN page / control page ({1:0.0} s)." -f $lan.Count, ([DateTime]::UtcNow - $t0).TotalSeconds)
                    }
                    if (-not $SkipHistoryClear) {
                        $t0 = [DateTime]::UtcNow
                        $budget = 28 - (& $since)
                        # questClearHistoryFallback: dialog range cleared if the selective delete fails.
                        $fbRange = 'day'
                        if ($script:Cfg -and $script:Cfg.Contains('questClearHistoryFallback')) {
                            $fbRaw = ([string]$script:Cfg.questClearHistoryFallback).Trim().ToLowerInvariant()
                            if (@('', 'none', 'off', 'false') -contains $fbRaw) { $fbRange = '' }
                            elseif (@('hour', 'day', 'week', 'fourweeks', 'all') -contains $fbRaw) { $fbRange = $fbRaw }
                            else { Write-QuestLog "History: questClearHistoryFallback '$fbRaw' unknown - using 'day'." }
                        }
                        $res = Clear-QuestBrowserHistory -DeviceSerial $dev -HelperUrl (Get-QuestHelperUrl) -Origins $origins -BudgetSec $budget -FallbackRange $fbRange
                        Write-QuestLog ("History step: {0} ({1:0.0} s)." -f $res, ([DateTime]::UtcNow - $t0).TotalSeconds)
                    }
                } finally { Close-QuestDevTools }
            } else {
                $res = 'failed'
            }
        }
        $sky = 'skipped'
        if ($ClearSkyboxWebDav) {
            # After the history clear (it has a time budget), before the sensor goes back on.
            $t0 = [DateTime]::UtcNow
            $sky = Invoke-QuestSkyboxWebDavClear -DeviceSerial $dev
            Write-QuestLog ("SKYBOX step: {0} ({1:0.0} s)." -f $sky, ([DateTime]::UtcNow - $t0).TotalSeconds)
        }
        $prox = 'skipped'
        if ($EnableProximityAfter) {
            # Always after the history clear: once the sensor is on, an unworn headset may sleep.
            $t0 = [DateTime]::UtcNow
            $prox = if ((Invoke-QuestEnableProximity) -eq 0) { 'on' } else { 'failed' }
            Write-QuestLog ("Proximity step: {0} ({1:0.0} s)." -f $prox, ([DateTime]::UtcNow - $t0).TotalSeconds)
        }
        Write-QuestLog ("Cleanup: finished {0:0.0} s after start (history {1}, SKYBOX {2}, proximity {3})." -f (& $since), $res, $sky, $prox)
        $historyBad = ($res -eq 'failed') -or (($res -eq 'skipped') -and (-not $SkipHistoryClear))
        if ($historyBad -or ($prox -eq 'failed') -or ($sky -eq 'failed')) { exit 3 }
        exit 0
    }
    $res = Invoke-QuestFlagSync -DeviceSerial $dev
    if ($res -eq 'failed') { exit 3 } else { exit 0 }
}
Write-QuestLog ("Watcher start: url={0} adb={1} host={2} port={3} serial={4} parent={5}" -f $Url, $script:Adb, $QuestHost, $Port, $Serial, $ParentPid)


$wasAwake = $false
$lastState = ''
$queuedLogged = $false
$deadline = if ($Once -and $WaitMinutes -gt 0) { [DateTime]::UtcNow.AddMinutes($WaitMinutes) } else { $null }
Set-QuestOpenStatus 'checking'
while ($true) {
    if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
        Write-QuestLog 'Companion exited - watcher stop.'
        exit 0
    }
    try {
        $dev = Get-OnlineQuestSerial
        if (-not $dev) { $dev = Connect-Quest }
        $state = if ($dev) { Get-QuestWakefulness -DeviceSerial $dev } else { 'Unreachable' }
        if (-not $state) { $state = 'Unknown' }
        if ($state -ne $lastState) {
            Write-QuestLog ("Headset {0}{1}" -f $state, $(if ($dev) { " ($dev)" } else { '' }))
            $lastState = $state
        }
        # Unknown (dumpsys hiccup) keeps the previous state so a blip does not reopen the tab.
        if ($state -eq 'Awake') {
            if (-not $wasAwake) {
                if ($queuedLogged) { Write-QuestLog 'Headset woke - opening the queued page.' }
                Set-QuestOpenStatus 'opening'
                $opened = Open-QuestLanTab -DeviceSerial $dev
                if ($Once) { if ($opened) { exit 0 } else { exit 3 } }
            }
            $wasAwake = $true
        } elseif ($state -ne 'Unknown') {
            $wasAwake = $false
        }
    } catch {
        Write-QuestLog "Poll error: $($_.Exception.Message)"
        $wasAwake = $false
    }
    if ($Once) {
        if ($deadline -and [DateTime]::UtcNow -lt $deadline) {
            if (-not $queuedLogged) {
                Write-QuestLog "Queued: headset $lastState - opening when it wakes (up to $WaitMinutes min)."
                Set-QuestOpenStatus 'queued'
                $queuedLogged = $true
            }
        } else {
            if ($deadline) { Write-QuestLog "Headset did not wake within $WaitMinutes min ($lastState) - nothing opened." }
            else { Write-QuestLog "Headset not awake/reachable ($lastState) - nothing opened." }
            exit 1
        }
    }
    Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
}
