<#
.SYNOPSIS
  Reset every Quest Browser chrome://flags entry to its default, over adb.

.DESCRIPTION
  Run it with no arguments: it does chrome://flags "Reset all" on the headset, restarts Quest Browser
  (flags apply only after a restart; the restart closes its open tabs) and checks afterwards that the
  insecure-origin flag is no longer enabled. Then it removes its own traces (helper page in history,
  Recently closed items) and closes Quest Browser again if it was not running before. It shows what it did (or the error) and waits for Enter (-NoWait skips
  that).

  The insecure-origin flag (unsafely-treat-insecure-origin-as-secure) is reset too, so WebXR on the
  phone LAN page stops working until the next Open on Quest: that finds isSecureContext false and
  sets the flag again (one more browser restart).

  Runs quest\Watch-LoopSegmentsQuestLanTab.ps1 -ResetFlags, so it finds the headset the same way (adb
  devices, last known address, mDNS). Needs the phone LAN page up: the helper tab opens a no-login
  phone page (/xr-assets/aframe.min.js) before going to chrome://flags. Headset not on adb yet
  (asleep, or Wi-Fi just switched on): keeps trying every 5 s for up to -WaitSec (default 120 s).

  Exit codes: 0 reset, 1 headset not on adb, 2 no adb, 3 failed.
  Log: %TEMP%\loopsegments-quest-lantab.log

.EXAMPLE
  .\Reset-QuestBrowserFlags.ps1

.EXAMPLE
  .\Reset-QuestBrowserFlags.ps1 -NoWait -WaitSec 0
#>
[CmdletBinding()]
param(
    # Exit straight away instead of waiting for Enter (for scripts).
    [switch] $NoWait,
    # Headset not on adb: keep trying for this many seconds (every 5 s). 0 = try once.
    [int] $WaitSec = 120
)

$watch = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'
# Phone LAN page from windows\loop-segments-windows.json (phoneLanHost, lanPort).
$phone = '10.0.100.10'; $port = 8765
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\LoopSegments-Windows.ps1')
    $cfg = Get-LoopSegmentsWindowsSettings
    if ($cfg.phoneLanHost) { $phone = [string]$cfg.phoneLanHost }
    if ([int]$cfg.lanPort -gt 0) { $port = [int]$cfg.lanPort }
} catch {}
$url = "http://${phone}:$port/"
Write-Host "Quest Browser: resetting all chrome://flags to default (phone page $url)..." -ForegroundColor Cyan

$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSec))
$tries = 0
while ($true) {
    $tries++
    $out = @(& (Get-Process -Id $PID).Path -NoProfile -NoLogo -ExecutionPolicy Bypass -File $watch -Url $url -ResetFlags 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    if ($code -ne 1 -or [DateTime]::UtcNow -ge $deadline) { break }
    if ($tries -eq 1) {
        Write-Host ("  Headset not on adb yet - trying every 5 s for up to {0} s (put it on / switch its Wi-Fi on; Ctrl+C to stop)..." -f $WaitSec) -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 5
}
if ($tries -gt 1) { Write-Host "  ($tries tries)" -ForegroundColor DarkGray }
foreach ($l in $out) { Write-Host "  $l" -ForegroundColor DarkGray }

Write-Host ''
if ($code -eq 0) {
    Write-Host 'Done: chrome://flags reset and Quest Browser restarted. The next Open on Quest sets the insecure-origin flag again.' -ForegroundColor Green
} else {
    $why = switch ($code) {
        1 { "Headset not reachable over adb within $WaitSec s: wake it (put it on), check its Wi-Fi and wireless debugging, then try again." }
        2 { 'adb not found: winget install Google.PlatformTools (see quest\README.md).' }
        3 { 'Reset failed (see the lines above): is the phone LAN page up, and is the headset worn (Quest Browser answers only then)?' }
        default { "Failed (exit $code)." }
    }
    Write-Host "ERROR: $why" -ForegroundColor Red
}
Write-Host "Log: $env:TEMP\loopsegments-quest-lantab.log" -ForegroundColor DarkGray

if (-not $NoWait) {
    Write-Host ''
    [void](Read-Host 'Press Enter to close')
}
exit $code
