# Companion hooks for Quest Browser (dot-sourced by pcloud_web_companion\run_chromium.ps1 and
# _profile_exit_watchdog.ps1). Each hook runs quest\Watch-LoopSegmentsQuestLanTab.ps1 in a
# hidden pwsh; log lines go to %TEMP%\loopsegments-quest-lantab.log.
#   startup : -EnsureFlags  (background, never blocks)  - questEnsureInsecureOriginFlag (default true)
#   close   : -ClearHistory (waits up to ~90 s)          - questClearHistoryOnExit (default true)
#   close   : -EnableProximity (waits up to ~30 s)       - questEnableProximityOnExit (default true)

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
    param([string] $LanUrl, [int] $TimeoutSec = 90)
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

# Close: turn the Quest proximity sensor back on (undo a prox_close "always worn" override).
function Invoke-QuestProximityOnExit {
    param([int] $TimeoutSec = 30)
    if (-not (Get-QuestCompanionSetting -Name 'questEnableProximityOnExit')) { return }
    if (-not (Test-Path -LiteralPath $script:QuestWatchScript)) { return }
    try {
        $p = Start-QuestWatchProcess -Arguments @('-EnableProximity')
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch {}
            Write-Warning "[quest] Quest proximity re-enable timed out after ${TimeoutSec}s"
            return
        }
        switch ($p.ExitCode) {
            0 { Write-Host '[quest] Quest proximity sensor on.' -ForegroundColor Green }
            1 { Write-Host '[quest] Quest not on adb - proximity sensor not changed.' -ForegroundColor DarkYellow }
            default { Write-Warning "[quest] Quest proximity re-enable failed (exit $($p.ExitCode)); see %TEMP%\loopsegments-quest-lantab.log" }
        }
    } catch {
        Write-Warning "[quest] Quest proximity re-enable: $($_.Exception.Message)"
    }
}
