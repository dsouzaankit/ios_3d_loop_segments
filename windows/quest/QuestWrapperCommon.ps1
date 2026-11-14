# Shared by the double-click Quest helpers (Set-QuestProximitySensor.ps1, Reset-QuestBrowserFlags.ps1):
# config, the PC's network check, running Watch-LoopSegmentsQuestLanTab.ps1 with retries until the
# headset is on adb, and the closing message. Dot-source it.

$script:QuestWatchScript = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'
$script:QuestWrapperCfg = $null
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\LoopSegments-Windows.ps1')
    $script:QuestWrapperCfg = Get-LoopSegmentsWindowsSettings
} catch {}

# http://<phoneLanHost>:<lanPort>/ from windows\loop-segments-windows.json.
function Get-QuestWrapperPhoneUrl {
    $phone = '10.0.100.10'; $port = 8765
    if ($script:QuestWrapperCfg) {
        if ($script:QuestWrapperCfg.phoneLanHost) { $phone = [string]$script:QuestWrapperCfg.phoneLanHost }
        if ([int]$script:QuestWrapperCfg.lanPort -gt 0) { $port = [int]$script:QuestWrapperCfg.lanPort }
    }
    return "http://${phone}:$port/"
}

# This PC on the phone's network first, like the companion's startup (the headset is reachable over
# adb only from the same network): lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 changes
# nothing when the PC's gateway is on the phone's subnet, and otherwise restarts that router's Wi-Fi
# so the PC moves back.
function Invoke-QuestWrapperNetworkCheck {
    $gw = Join-Path (Split-Path -Parent $PSScriptRoot) 'lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $gw)) { return }
    $phone = if ($script:QuestWrapperCfg) { [string]$script:QuestWrapperCfg.phoneLanHost } else { '' }
    Write-Host "Network: making sure this PC is on the phone's network$(if ($phone) { " ($phone)" })..." -ForegroundColor Cyan
    $gwArgs = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', $gw, '-NoWaitEnter')
    if ($phone) { $gwArgs += @('-PhoneLanHost', $phone) }
    & (Get-Process -Id $PID).Path @gwArgs
    if ($LASTEXITCODE -ne 0) { Write-Host "  Network check exited $LASTEXITCODE - trying the headset anyway." -ForegroundColor Yellow }
}

# Run the Quest script with -Arguments. Exit 1 = headset not on adb: try again every ~5 s until
# -WaitSec runs out, restarting the PC's adb server before every retry (when the headset's Wi-Fi
# comes back, wireless debugging gets a new port, and a running adb server can go on missing it over
# mDNS: seen nothing for minutes, listed 4 s after a restart; each try is a new process, so the Quest
# script's own 60 s restart never fires). Prints the Quest script's lines; returns @{ Code; Out }.
function Invoke-QuestWrapperWatch {
    param([string[]] $Arguments, [int] $WaitSec)
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSec))
    $tries = 0
    while ($true) {
        $tries++
        $out = @(& (Get-Process -Id $PID).Path -NoProfile -NoLogo -ExecutionPolicy Bypass -File $script:QuestWatchScript @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        if ($code -ne 1 -or [DateTime]::UtcNow -ge $deadline) { break }
        if ($tries -eq 1) {
            Write-Host ("  Headset not on adb yet - trying every 5 s for up to {0} s (put it on / switch its Wi-Fi on; Ctrl+C to stop)..." -f $WaitSec) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
        $adbExe = (Get-Command adb -ErrorAction SilentlyContinue).Source
        if ($adbExe) {
            if ($tries -eq 1) { Write-Host '  (restarting the adb server before each retry)' -ForegroundColor DarkGray }
            & $adbExe kill-server 2>&1 | Out-Null
            & $adbExe start-server 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }
    }
    if ($tries -gt 1) { Write-Host "  ($tries tries)" -ForegroundColor DarkGray }
    foreach ($l in $out) { Write-Host "  $l" -ForegroundColor DarkGray }
    Write-Host ''
    return @{ Code = $code; Out = $out }
}

# The error for a failed run (exit 3's wording is the caller's), the log path, the Enter prompt;
# then exit with -Code.
function Exit-QuestWrapper {
    param([int] $Code, [int] $WaitSec, [string] $FailedText, [switch] $NoWait)
    if ($Code -ne 0) {
        $why = switch ($Code) {
            1 { "Headset not reachable over adb within $WaitSec s: wake it (put it on), check its Wi-Fi and wireless debugging, then try again." }
            2 { 'adb not found: winget install Google.PlatformTools (see quest\README.md).' }
            3 { $FailedText }
            default { "Failed (exit $Code)." }
        }
        Write-Host "ERROR: $why" -ForegroundColor Red
    }
    Write-Host "Log: $env:TEMP\loopsegments-quest-lantab.log" -ForegroundColor DarkGray
    if (-not $NoWait) {
        Write-Host ''
        [void](Read-Host 'Press Enter to close')
    }
    exit $Code
}
