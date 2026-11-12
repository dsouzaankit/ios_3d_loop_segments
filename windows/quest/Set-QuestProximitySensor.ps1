<#
.SYNOPSIS
  Turn the Quest headset's proximity sensor off (stays awake) or on (sleeps when taken off), over adb.

.DESCRIPTION
  Run it with no arguments to flip the sensor: it shows what it did and the sensor's final state
  (or the error) and waits for Enter (-NoWait skips that).

  Off = `am broadcast -a com.oculus.vrpowermanager.prox_close`: the headset acts as if worn, so it
  does not sleep (and stays on adb) when you take it off. On = `...automation_disable`: the real
  sensor is used again. Toggle (the default) flips whichever it is now. Checked against
  `dumpsys vrpowermanager` (Virtual proximity state CLOSE = held off, DISABLED = sensor on). A
  headset reboot also turns the sensor back on.

  Runs quest\Watch-LoopSegmentsQuestLanTab.ps1 (-DisableProximity / -EnableProximity /
  -ToggleProximity), so it finds the headset the same way (adb devices, questAdbHost, mDNS).

  While the PC companion runs with questKeepAwakeDuringSession=true, its keep-awake job switches the
  sensor off again within ~20 s after you turn it on; the companion turns it on itself at close.

  Exit codes: 0 done, 1 headset not on adb, 2 no adb, 3 the headset did not take the change.
  Log: %TEMP%\loopsegments-quest-lantab.log

.EXAMPLE
  .\Set-QuestProximitySensor.ps1                 # Toggle, then wait for Enter

.EXAMPLE
  .\Set-QuestProximitySensor.ps1 -State Off -NoWait
#>
[CmdletBinding()]
param(
    [ValidateSet('On', 'Off', 'Toggle')] [string] $State = 'Toggle',
    # Exit straight away instead of waiting for Enter (for scripts).
    [switch] $NoWait
)

$watch = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'
$switch = @{ On = '-EnableProximity'; Off = '-DisableProximity'; Toggle = '-ToggleProximity' }[$State]
Write-Host "Quest proximity sensor: $($State.ToLowerInvariant())..." -ForegroundColor Cyan

# The Quest script prints "[quest] Proximity: ... now 'CLOSE'" (or an error line); keep its lines.
$out = @(& (Get-Process -Id $PID).Path -NoProfile -NoLogo -ExecutionPolicy Bypass -File $watch $switch 2>&1 | ForEach-Object { "$_" })
$code = $LASTEXITCODE
foreach ($l in $out) { Write-Host "  $l" -ForegroundColor DarkGray }

$now = $null
foreach ($l in $out) { if ($l -match "now '(\w+)'") { $now = $Matches[1] } }
Write-Host ''
if ($code -eq 0) {
    switch ($now) {
        'CLOSE' { Write-Host 'Sensor is OFF: the headset stays awake (and on adb) when you take it off.' -ForegroundColor Green }
        'DISABLED' { Write-Host 'Sensor is ON: the headset sleeps again when you take it off.' -ForegroundColor Green }
        default { Write-Host "Done (virtual proximity state: $(if ($now) { $now } else { 'unknown' }))." -ForegroundColor Green }
    }
} else {
    $why = switch ($code) {
        1 { 'Headset not reachable over adb: wake it (put it on) and check wireless debugging, then try again.' }
        2 { 'adb not found: winget install Google.PlatformTools (see quest\README.md).' }
        3 { 'The headset did not take the change (see the lines above).' }
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
