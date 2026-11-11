<#
.SYNOPSIS
  Open the phone LAN page in the Quest browser each time the headset wakes (adb over Wi-Fi).

.DESCRIPTION
  Polls the Quest over adb. When the headset is first seen, or goes from asleep / unreachable
  to Awake (dumpsys power mWakefulness), sends a VIEW intent for -Url to com.oculus.browser.
  The intent also asks for an incognito tab; Chromium-based browsers normally ignore that from
  outside callers, so expect a normal tab.

  Needs developer mode on the Quest and adb on this PC (winget install Google.PlatformTools).
  Wireless adb is switched off by every Quest reboot; the adb-auto-enable app
  (https://github.com/project-SIMPLE/adb-auto-enable) keeps it on, so wake-after-boot works
  without USB.

  Finding the headset (each poll, until one is online):
    1. A device already in `adb devices -l` whose model looks like a Quest (or -Serial).
    2. `adb connect <questAdbHost>:<questAdbPort>` (default port 5555) when questAdbHost is set.
    3. `adb mdns services` _adb-tls-connect entries (wireless-debugging TLS port, already paired).

  The companion sink (pcloud_web_companion\_rest_log_sink.ps1) runs this with -Once when you
  click "Open on Quest" on the PC LAN page. Without -Once it keeps polling (manual use);
  -ParentPid makes it exit with that process.
  Log: %TEMP%\loopsegments-quest-lantab.log

  The URL carries no LAN password: type admin / the app password on the Quest.

.EXAMPLE
  .\Watch-LoopSegmentsQuestLanTab.ps1 -Url http://10.0.100.10:8765/ -Once
  Open the page now (if the headset is reachable and awake) and exit.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Url,
    [int] $ParentPid = 0,
    [int] $PollSeconds = 5,
    [string] $AdbExe = '',
    [string] $Serial = '',
    [string] $QuestHost = '',
    [int] $Port = 0,
    # Open once now (no wake transition needed) and exit.
    [switch] $Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogPath = Join-Path $env:TEMP 'loopsegments-quest-lantab.log'
$BrowserPackage = 'com.oculus.browser'

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
        if ([string]::IsNullOrWhiteSpace($AdbExe)) { $AdbExe = [string]$cfg.questAdbExe }
        if ([string]::IsNullOrWhiteSpace($QuestHost)) { $QuestHost = [string]$cfg.questAdbHost }
        if ([string]::IsNullOrWhiteSpace($Serial)) { $Serial = [string]$cfg.questAdbSerial }
        if ($Port -le 0 -and $null -ne $cfg.questAdbPort) { $Port = [int]$cfg.questAdbPort }
    } catch {
        Write-QuestLog "Config read failed: $($_.Exception.Message)"
    }
}
if ($Port -le 0) { $Port = 5555 }

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

function Open-QuestLanTab {
    param([string] $DeviceSerial)
    # adb shell joins args into one device shell line: quote the URL.
    $quoted = "'" + ($Url -replace "'", '') + "'"
    $amArgs = @(
        '-s', $DeviceSerial, 'shell', 'am', 'start',
        '-a', 'android.intent.action.VIEW',
        '-d', $quoted,
        '-p', $BrowserPackage,
        '--ez', 'com.google.android.apps.chrome.EXTRA_OPEN_NEW_INCOGNITO_TAB', 'true',
        '--ez', 'create_new_tab', 'true'
    )
    $r = Invoke-Adb -Arguments $amArgs -TimeoutSec 15
    $msg = (($r.Out + ' ' + $r.Err) -replace '\s+', ' ').Trim()
    if ($r.Code -eq 0 -and $msg -notmatch '(?i)\bError\b') {
        Write-QuestLog "Opened $Url in Quest browser ($DeviceSerial)"
        return $true
    }
    Write-QuestLog "am start failed (code $($r.Code)): $msg"
    return $false
}

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'adb not found (winget install Google.PlatformTools, or set questAdbExe) - Quest LAN tab disabled.'
    exit 2
}
$script:LastConnectMsg = ''
Write-QuestLog ("Watcher start: url={0} adb={1} host={2} port={3} serial={4} parent={5}" -f $Url, $script:Adb, $QuestHost, $Port, $Serial, $ParentPid)

$wasAwake = $false
$lastState = ''
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
                [void](Open-QuestLanTab -DeviceSerial $dev)
                if ($Once) { exit 0 }
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
        Write-QuestLog "Headset not awake/reachable ($lastState) - nothing opened."
        exit 1
    }
    Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
}
