# Companion hooks for Quest Browser (dot-sourced by pcloud_web_companion\run_chromium.ps1 and
# _profile_exit_watchdog.ps1). Each hook runs quest\Watch-LoopSegmentsQuestLanTab.ps1 in a
# hidden pwsh; log lines go to %TEMP%\loopsegments-quest-lantab.log.
#   startup : -KeepAwakeSession (background, until the companion exits) - questKeepAwakeDuringSession
#   startup : Serve-QuestControlPage.ps1 (background, until the companion exits): the Quest control
#             page with SKYBOX Push / Update / Clear - questControlPage / questSkyboxWebDav
#   close   : stop keep-awake, the control page and any SKYBOX action, then ONE background process: close LAN tabs,
#             clear history (~30 s), remove the SKYBOX WebDAV server, proximity sensor on -
#             questCloseLanTabsOnExit / questClearHistoryOnExit / questSkyboxWebDav /
#             questKeepAwakeDuringSession. Start-QuestCleanupOnExit starts it, Wait-QuestCleanupOnExit
#             (at most 40 s from its start, 60 s with SKYBOX) waits before anything drops the Wi-Fi.

$script:QuestWatchScript = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'

function Get-QuestCompanionSetting {
    param([string] $Name, [bool] $Default = $true)
    try {
        if (Get-Command Get-LoopSegmentsWindowsSettings -ErrorAction SilentlyContinue) {
            $s = Get-LoopSegmentsWindowsSettings
            if ($s.Contains($Name) -and $null -ne $s[$Name]) { return [bool]$s[$Name] }
        }
    } catch {}
    return $Default
}

# http://<phoneLanHost>:<lanPort>/ from the extension's lan_config.json (what the companion uses).
function Get-QuestCompanionLanUrl {
    param([string] $ExtensionDir)
    $path = Join-Path $ExtensionDir 'lan_config.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $c = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $h = ([string]$c.phoneLanHost).Trim()
        if ([string]::IsNullOrWhiteSpace($h)) { return $null }
        $port = 8765
        if ($null -ne $c.lanPort -and [int]$c.lanPort -gt 0) { $port = [int]$c.lanPort }
        return "http://${h}:${port}/"
    } catch {
        return $null
    }
}

function Start-QuestWatchProcess {
    param([string[]] $Arguments)
    $pwsh = if (Get-Command Get-LoopSegmentsPwshExe -ErrorAction SilentlyContinue) { Get-LoopSegmentsPwshExe } else { (Get-Process -Id $PID).Path }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:QuestWatchScript) + $Arguments) {
        [void]$psi.ArgumentList.Add($a)
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

# ---- Close: one background cleanup process (LAN tabs -> history -> proximity sensor) ----

$script:QuestCleanupProc = $null
$script:QuestCleanupStartedAt = $null

# Start the close-time Quest cleanup without waiting, so the companion can close Chromium and sync
# the profile meanwhile. Wait-QuestCleanupOnExit must run before anything that drops the Wi-Fi.
function Start-QuestCleanupOnExit {
    param([string] $LanUrl)
    Stop-QuestKeepAwake
    Stop-QuestControlPage
    $script:QuestCleanupProc = $null
    $clear = Get-QuestCompanionSetting -Name 'questClearHistoryOnExit'
    $close = Get-QuestCompanionSetting -Name 'questCloseLanTabsOnExit'
    $prox = Get-QuestCompanionSetting -Name 'questKeepAwakeDuringSession'
    $sky = Get-QuestCompanionSetting -Name 'questSkyboxWebDav'
    if (-not ($clear -or $close -or $prox -or $sky)) { return }
    if (-not (Test-Path -LiteralPath $script:QuestWatchScript)) { return }
    $what = @()
    if ($close) { $what += 'close LAN tabs' }
    if ($clear) { $what += 'delete Loop Segments history' }
    if ($sky) { $what += 'remove SKYBOX WebDAV server' }
    if ($prox) { $what += 'proximity sensor on' }
    if ([string]::IsNullOrWhiteSpace($LanUrl)) {
        # No phone LAN page: no tabs or history to clear, but SKYBOX servers and the sensor still.
        if (-not ($prox -or $sky)) { return }
        $qa = @()
        $what = @()
        if ($sky) { $qa += '-ClearSkyboxWebDav'; $what += 'remove SKYBOX WebDAV server' }
        if ($prox) { $qa += $(if ($sky) { '-EnableProximityAfter' } else { '-EnableProximity' }); $what += 'proximity sensor on' }
    } else {
        $qa = @('-Url', $LanUrl, '-ClearHistory')
        if ($close) { $qa += '-CloseLanTabs' }
        if (-not $clear) { $qa += '-SkipHistoryClear' }
        if ($sky) { $qa += '-ClearSkyboxWebDav' }
        if ($prox) { $qa += '-EnableProximityAfter' }
    }
    $script:QuestCleanupTimeoutSec = if ($sky) { 60 } else { 40 }
    try {
        $script:QuestCleanupStartedAt = [DateTime]::UtcNow
        $script:QuestCleanupProc = Start-QuestWatchProcess -Arguments $qa
        $script:QuestCleanupWhat = $what -join ', '
        Write-Host ("[quest] Quest cleanup running in the background: {0} (PID {1})" -f $script:QuestCleanupWhat, $script:QuestCleanupProc.Id)
    } catch {
        Write-Warning "[quest] Could not start Quest cleanup: $($_.Exception.Message)"
        $script:QuestCleanupProc = $null
    }
}

# Wait for the background cleanup, at most -TimeoutSec counted from its start. Safe to call twice.
function Wait-QuestCleanupOnExit {
    param([int] $TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = if ($script:QuestCleanupTimeoutSec) { $script:QuestCleanupTimeoutSec } else { 40 } }
    $p = $script:QuestCleanupProc
    if (-not $p) { return }
    $script:QuestCleanupProc = $null
    $leftMs = [int][Math]::Max(0, ($TimeoutSec - ([DateTime]::UtcNow - $script:QuestCleanupStartedAt).TotalSeconds) * 1000)
    if (-not $p.HasExited) { Write-Host '[quest] Waiting for the Quest cleanup to finish...' }
    if (-not $p.WaitForExit($leftMs)) {
        try { $p.Kill($true) } catch {}
        Write-Warning "[quest] Quest cleanup stopped after ${TimeoutSec}s; see %TEMP%\loopsegments-quest-lantab.log"
        return
    }
    $took = ([DateTime]::UtcNow - $script:QuestCleanupStartedAt).TotalSeconds
    switch ($p.ExitCode) {
        0 { Write-Host ("[quest] Quest cleanup done ({0}) within {1:0.0} s." -f $script:QuestCleanupWhat, $took) -ForegroundColor Green }
        1 {
            if (Test-Path -LiteralPath (Join-Path $env:TEMP 'loopsegments-quest-history-pending.json')) {
                Write-Host '[quest] Quest not on adb - cleanup postponed: a background helper closes the LAN tabs, deletes the history entries and resets the proximity sensor once the headset is back (worn) within 2 h.' -ForegroundColor DarkYellow
            } else {
                Write-Host '[quest] Quest not on adb - cleanup skipped (a headset reboot also resets the proximity sensor).' -ForegroundColor DarkYellow
            }
        }
        4 { Write-Host ("[quest] Quest cleanup done within {0:0.0} s, except the history delete: Quest Browser did not answer (headset not worn?), so a background helper deletes those entries the next time the headset is worn (gives up after 2 h)." -f $took) -ForegroundColor DarkYellow }
        default { Write-Warning "[quest] Quest cleanup incomplete (exit $($p.ExitCode)); see %TEMP%\loopsegments-quest-lantab.log" }
    }
}

# ---- Quest control page (quest\Serve-QuestControlPage.ps1): SKYBOX Push / Update / Clear ----

$script:QuestControlProc = $null
$script:QuestCleanupTimeoutSec = 40
$script:QuestControlScript = Join-Path $PSScriptRoot 'Serve-QuestControlPage.ps1'

# Startup: serve the Quest control page on this PC's LAN address (port questControlPort, signed in
# with the phone LAN login) until the companion exits. Open on Quest opens it on the headset.
function Start-QuestControlPageInBackground {
    param([string] $ExtensionDir, [int] $CompanionPid = $PID)
    if (-not (Get-QuestCompanionSetting -Name 'questControlPage')) {
        Write-Host '[quest] Quest control page off (questControlPage=false)'
        return
    }
    if (-not (Test-Path -LiteralPath $script:QuestControlScript)) { return }
    Stop-QuestControlPage
    $port = 18766
    try { $p = [int](Get-LoopSegmentsWindowsSettings).questControlPort; if ($p -gt 0) { $port = $p } } catch {}
    try {
        $pwsh = if (Get-Command Get-LoopSegmentsPwshExe -ErrorAction SilentlyContinue) { Get-LoopSegmentsPwshExe } else { (Get-Process -Id $PID).Path }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwsh
        foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:QuestControlScript,
                '-Port', "$port", '-LanConfig', (Join-Path $ExtensionDir 'lan_config.json'), '-CompanionPid', "$CompanionPid")) { [void]$psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:QuestControlProc = [System.Diagnostics.Process]::Start($psi)
        Write-Host "[quest] Quest control page on port $port (SKYBOX Push / Update / Clear; opened on the Quest with Open on Quest; PID $($script:QuestControlProc.Id))"
    } catch {
        Write-Warning "[quest] Could not start the Quest control page: $($_.Exception.Message)"
    }
}

# Close: stop the control page and any SKYBOX action it started (this session's, or ones left
# running), whole process trees, so nothing re-adds the server after the cleanup removed it and no
# adb pull/push keeps writing.
function Stop-QuestControlPage {
    $ids = [System.Collections.Generic.List[int]]::new()
    if ($script:QuestControlProc -and -not $script:QuestControlProc.HasExited) { $ids.Add($script:QuestControlProc.Id) }
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $c = $_.CommandLine
                $c -and (($c -like '*Serve-QuestControlPage.ps1*') -or
                    ($c -like '*Watch-LoopSegmentsQuestLanTab.ps1*' -and ($c -like '*-SkyboxPush*' -or $c -like '*-SkyboxUpdate*' -or $c -like '*-SkyboxWebDavSession*' -or ($c -like '*-ClearSkyboxWebDav*' -and $c -like '*-StatusFile*'))))
            } |
            ForEach-Object { $ids.Add([int]$_.ProcessId) }
    } catch {}
    foreach ($id in ($ids | Select-Object -Unique)) {
        try {
            $p = [System.Diagnostics.Process]::GetProcessById($id)
            $p.Kill($true)
            [void]$p.WaitForExit(5000)
        } catch {}
    }
    $script:QuestControlProc = $null
}

# ---- Keep the headset awake during the session, so the close-time history clear can reach it ----

$script:QuestKeepAwakeProc = $null

# Startup: hold the proximity sensor off (prox_close) while this companion runs; applied when the
# headset first shows up on adb and again after a headset reboot.
function Start-QuestKeepAwakeInBackground {
    param([int] $CompanionPid = $PID)
    # A new session takes over from the last quit's history helper (this session's quit deletes
    # those entries), before keep-awake can switch the sensor off under it.
    Stop-QuestHistoryRetry
    if (-not (Get-QuestCompanionSetting -Name 'questKeepAwakeDuringSession')) {
        Write-Host '[quest] Not keeping the Quest awake (questKeepAwakeDuringSession=false)'
        return
    }
    if (-not (Test-Path -LiteralPath $script:QuestWatchScript)) { return }
    Stop-QuestKeepAwake
    try {
        $script:QuestKeepAwakeProc = Start-QuestWatchProcess -Arguments @('-KeepAwakeSession', '-ParentPid', "$CompanionPid")
        Write-Host "[quest] Keeping the Quest awake while the companion runs (proximity sensor off once it is on adb; PID $($script:QuestKeepAwakeProc.Id))"
    } catch {
        Write-Warning "[quest] Could not start Quest keep-awake: $($_.Exception.Message)"
    }
}

# Stop the after-quit history helper (Watch-LoopSegmentsQuestLanTab.ps1 -RetryHistory) a previous
# quit left waiting for the headset, and drop what it was waiting to do.
function Stop-QuestHistoryRetry {
    $pending = Join-Path $env:TEMP 'loopsegments-quest-history-pending.json'
    $n = 0
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*Watch-LoopSegmentsQuestLanTab.ps1*' -and $_.CommandLine -like '*-RetryHistory*' } |
            ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue; $n++ }
    } catch {}
    if (Test-Path -LiteralPath $pending) {
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        Write-Host "[quest] Stopped the last quit's history helper$(if ($n) { " (PID stopped: $n)" }); this session's quit deletes those entries."
    }
    # The Wi-Fi->www AP bounce it was holding: this session's quit probes again.
    $bounce = Join-Path $env:TEMP 'loopsegments-wifi-bounce-pending.json'
    if (Test-Path -LiteralPath $bounce) {
        Remove-Item -LiteralPath $bounce -Force -ErrorAction SilentlyContinue
        Write-Host "[quest] Dropped the last quit's held Wi-Fi AP bounce; this session's quit probes Wi-Fi->www again."
    }
}

# Quit: the Wi-Fi->www probe failed. If the after-quit history helper is waiting for the headset, hand
# it the AP bounce (it runs it after the delete, or when it gives up): bouncing now moves the headset
# to the other Wi-Fi, where the helper on this PC cannot reach it. $true = handed over.
function Request-QuestDeferredWifiBounce {
    param([string] $PhoneLanHost)
    $pending = Join-Path $env:TEMP 'loopsegments-quest-history-pending.json'
    if (-not (Test-Path -LiteralPath $pending)) { return $false }
    try {
        $p = Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json
        if (-not ($p.pid -and (Get-Process -Id ([int]$p.pid) -ErrorAction SilentlyContinue))) { return $false }
        $until = [DateTime]::Parse([string]$p.until, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        @{ phoneLanHost = $PhoneLanHost; queuedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $env:TEMP 'loopsegments-wifi-bounce-pending.json') -Encoding utf8
        Write-Host ("[wifi-www] Quest history delete still pending: AP bounce held until it is done (headset worn) or the helper gives up at {0:HH:mm}." -f $until.ToLocalTime()) -ForegroundColor DarkYellow
        return $true
    } catch { return $false }
}

# Stop the keep-awake job (this session's, or any left running) so it cannot switch the sensor off
# again after cleanup turned it back on.
function Stop-QuestKeepAwake {
    $ids = [System.Collections.Generic.List[int]]::new()
    if ($script:QuestKeepAwakeProc -and -not $script:QuestKeepAwakeProc.HasExited) { $ids.Add($script:QuestKeepAwakeProc.Id) }
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*Watch-LoopSegmentsQuestLanTab.ps1*' -and $_.CommandLine -like '*-KeepAwakeSession*' } |
            ForEach-Object { $ids.Add([int]$_.ProcessId) }
    } catch {}
    foreach ($id in ($ids | Select-Object -Unique)) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:QuestKeepAwakeProc = $null
}
