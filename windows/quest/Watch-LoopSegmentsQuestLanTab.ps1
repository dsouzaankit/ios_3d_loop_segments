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
  -ClearHistory  : clear Quest Browser history - History only, All time - through the browser's
                   own "Clear browsing data" dialog (cookies, cache, passwords, forms, settings are
                   kept; the dialog's previous ticks are restored). Companion runs it on close.
  -EnableProximity : turn the proximity sensor back on (undoes a `prox_close` override, so the
                   headset sleeps again when taken off). Companion runs it on close. Needs no -Url.
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
    # Do not touch chrome://flags before opening the tab.
    [switch] $NoFlags,
    # Only turn the proximity sensor back on (am broadcast ...vrpowermanager.automation_disable).
    [switch] $EnableProximity,
    # Keep the headset awake (prox_close) while -ParentPid runs.
    [switch] $KeepAwakeSession
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

# LAN URL with the per-phone login (phoneLanHosts[].webdavPassword, else webdavPassword) as
# percent-encoded userinfo. Returns -Url unchanged when sending the login is off or none is set.
function Get-QuestTypedUrl {
    if (-not $script:SendLanLogin) { return ($Url -replace "'", '') }
    try {
        $u = [Uri]$Url
        $cred = Get-LoopSegmentsWebDAVCredentials
        $user = [string]$cred.User
        $pass = [string]$cred.Password
        foreach ($raw in @((Get-LoopSegmentsWindowsSettings).phoneLanHosts)) {
            if ($null -eq $raw) { continue }
            $e = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw
            if ($e -and $e.Host -eq $u.Host -and -not [string]::IsNullOrWhiteSpace([string]$e.Password)) { $pass = [string]$e.Password }
        }
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
        if (-not (Open-QuestSignedInTab -DeviceSerial $DeviceSerial -PlainUrl $plain -LoginUrl $login)) { return $false }
        $how = if ($login -ne $plain) { 'signed in' } else { 'not signed in' }
        Write-QuestLog "Opened $Url in Quest browser, normal tab, $how ($DeviceSerial)"
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

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'adb not found (winget install Google.PlatformTools, or set questAdbExe) - Quest LAN tab disabled.'
    exit 2
}
$script:LastConnectMsg = ''
$script:SendLanLogin = (-not $NoLanLogin) -and [bool](Get-Command Get-LoopSegmentsWebDAVCredentials -ErrorAction SilentlyContinue)
if ($ProbeIncognito) { exit (Invoke-QuestIncognitoProbe) }
if ($EnableProximity) { exit (Invoke-QuestEnableProximity) }
if ($KeepAwakeSession) { exit (Invoke-QuestKeepAwakeSession) }
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
        if (-not (Open-QuestDevTools -DeviceSerial $dev)) { exit 3 }
        # Whole run (pwsh start, adb connect, clear) must finish within ~30 s; keep ~2 s for exit.
        $budget = 28 - ([DateTime]::UtcNow - $script:StartedAt).TotalSeconds
        try { $res = Clear-QuestBrowserHistory -DeviceSerial $dev -HelperUrl (Get-QuestHelperUrl) -BudgetSec $budget } finally { Close-QuestDevTools }
        if ($res -eq 'cleared') { exit 0 } else { exit 3 }
    }
    $res = Invoke-QuestFlagSync -DeviceSerial $dev
    if ($res -eq 'failed') { exit 3 } else { exit 0 }
}
Write-QuestLog ("Watcher start: url={0} adb={1} host={2} port={3} serial={4} parent={5}" -f $Url, $script:Adb, $QuestHost, $Port, $Serial, $ParentPid)

function Set-QuestOpenStatus {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }
    try { Set-Content -LiteralPath $StatusFile -Value $Value -Encoding ascii } catch {}
}

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
