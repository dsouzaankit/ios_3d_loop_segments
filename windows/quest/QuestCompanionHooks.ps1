# Companion hooks for Quest Browser (dot-sourced by pcloud_web_companion\run_chromium.ps1 and
# _profile_exit_watchdog.ps1). Each hook runs quest\Watch-LoopSegmentsQuestLanTab.ps1 in a
# hidden pwsh; log lines go to %TEMP%\loopsegments-quest-lantab.log.
#   startup : -EnsureFlags  (background, never blocks)  - questEnsureInsecureOriginFlag (default true)
#   startup : -KeepAwakeSession (background, until the companion exits) - questKeepAwakeDuringSession
#   close   : stop keep-awake, then -ClearHistory (at most 30 s) - questClearHistoryOnExit (default true)
#   close   : then -EnableProximity (waits up to ~30 s)  - questKeepAwakeDuringSession (default true)

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

# Startup: make sure Quest Browser's insecure-origin flag lists the phone LAN origin(s).
function Start-QuestFlagSyncInBackground {
    param([string] $LanUrl)
    if (-not (Get-QuestCompanionSetting -Name 'questEnsureInsecureOriginFlag')) {
        Write-Host '[quest] Skipping Quest flags check (questEnsureInsecureOriginFlag=false)'
        return
    }
    if ([string]::IsNullOrWhiteSpace($LanUrl) -or -not (Test-Path -LiteralPath $script:QuestWatchScript)) { return }
    try {
        $p = Start-QuestWatchProcess -Arguments @('-Url', $LanUrl, '-EnsureFlags')
        Write-Host "[quest] Checking Quest Browser insecure-origin flag in the background (PID $($p.Id); skipped if the headset is not on adb)"
    } catch {
        Write-Warning "[quest] Could not start the Quest flags check: $($_.Exception.Message)"
    }
}

# Close: clear Quest Browser history (History only, All time). Waits so it finishes before exit.
function Invoke-QuestHistoryClearOnExit {
    param([string] $LanUrl, [int] $TimeoutSec = 30)
    if (-not (Get-QuestCompanionSetting -Name 'questClearHistoryOnExit')) { return }
    if ([string]::IsNullOrWhiteSpace($LanUrl) -or -not (Test-Path -LiteralPath $script:QuestWatchScript)) { return }
    try {
        Write-Host '[quest] Clearing Quest Browser history (History only, All time)...'
        $p = Start-QuestWatchProcess -Arguments @('-Url', $LanUrl, '-ClearHistory')
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch {}
            Write-Warning "[quest] Quest history clear timed out after ${TimeoutSec}s"
            return
        }
        switch ($p.ExitCode) {
            0 { Write-Host '[quest] Quest Browser history cleared.' -ForegroundColor Green }
            1 { Write-Host '[quest] Quest not on adb - history not cleared.' -ForegroundColor DarkYellow }
            default { Write-Warning "[quest] Quest history clear failed (exit $($p.ExitCode)); see %TEMP%\loopsegments-quest-lantab.log" }
        }
    } catch {
        Write-Warning "[quest] Quest history clear: $($_.Exception.Message)"
    }
}

# ---- Keep the headset awake during the session, so the close-time history clear can reach it ----

$script:QuestKeepAwakeProc = $null

# Startup: hold the proximity sensor off (prox_close) while this companion runs; applied when the
# headset first shows up on adb and again after a headset reboot.
function Start-QuestKeepAwakeInBackground {
    param([int] $CompanionPid = $PID)
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

# Close (after the history clear): turn the proximity sensor back on.
function Invoke-QuestProximityOnExit {
    param([int] $TimeoutSec = 30)
    Stop-QuestKeepAwake
    if (-not (Get-QuestCompanionSetting -Name 'questKeepAwakeDuringSession')) { return }
    if (-not (Test-Path -LiteralPath $script:QuestWatchScript)) { return }
    try {
        $p = Start-QuestWatchProcess -Arguments @('-EnableProximity')
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch {}
            Write-Warning "[quest] Quest proximity re-enable timed out after ${TimeoutSec}s"
            return
        }
        switch ($p.ExitCode) {
            0 { Write-Host '[quest] Quest proximity sensor back on.' -ForegroundColor Green }
            1 { Write-Host '[quest] Quest not on adb - proximity sensor not changed (a headset reboot also resets it).' -ForegroundColor DarkYellow }
            default { Write-Warning "[quest] Quest proximity re-enable failed (exit $($p.ExitCode)); see %TEMP%\loopsegments-quest-lantab.log" }
        }
    } catch {
        Write-Warning "[quest] Quest proximity re-enable: $($_.Exception.Message)"
    }
}
