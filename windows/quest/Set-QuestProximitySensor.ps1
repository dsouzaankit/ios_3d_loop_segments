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
  headset reboot also turns the sensor back on. While the sensor is off, the headset shows a
  "Proximity sensor OFF" notification and opens the notifications list (bell) to show it for 20 s
  (the script waits); turning the sensor on removes the notification.

  Runs quest\Watch-LoopSegmentsQuestLanTab.ps1 (-DisableProximity / -EnableProximity /
  -ToggleProximity), so it finds the headset the same way (adb devices, questAdbHost, mDNS).

  While the PC companion runs with questKeepAwakeDuringSession=true, its keep-awake job switches the
  sensor off again within ~20 s after you turn it on; the companion turns it on itself at close.

  First it makes sure this PC is on the phone's network, like the companion's startup:
  lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -PhoneLanHost <phoneLanHost> checks the PC's
  default gateway against the phone's subnet and, only when it is on another network (for example
  after a quit's Wi-Fi bounce), restarts that router's Wi-Fi so the PC moves back. -SkipNetworkCheck
  skips it. The headset is only reachable over adb from the same network.

  Headset not on adb (asleep, or Wi-Fi just switched on): keeps trying every 5 s for up to
  -WaitSec (default 120 s), so you can put the headset on or switch its Wi-Fi on meanwhile.

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
    [switch] $NoWait,
    # Headset not on adb: keep trying for this many seconds (every 5 s). 0 = try once.
    [int] $WaitSec = 120,
    # Do not check / fix this PC's network first.
    [switch] $SkipNetworkCheck
)

. (Join-Path $PSScriptRoot 'QuestWrapperCommon.ps1')

if (-not $SkipNetworkCheck) { Invoke-QuestWrapperNetworkCheck }
$switch = @{ On = '-EnableProximity'; Off = '-DisableProximity'; Toggle = '-ToggleProximity' }[$State]
Write-Host "Quest proximity sensor: $($State.ToLowerInvariant())..." -ForegroundColor Cyan

# The Quest script prints "[quest] Proximity: ... now 'CLOSE'" (or an error line).
$r = Invoke-QuestWrapperWatch -Arguments @($switch) -WaitSec $WaitSec
if ($r.Code -eq 0) {
    $now = $null
    foreach ($l in $r.Out) { if ($l -match "now '(\w+)'") { $now = $Matches[1] } }
    switch ($now) {
        'CLOSE' { Write-Host 'Sensor is OFF: the headset stays awake (and on adb) when you take it off.' -ForegroundColor Green }
        'DISABLED' { Write-Host 'Sensor is ON: the headset sleeps again when you take it off.' -ForegroundColor Green }
        default { Write-Host "Done (virtual proximity state: $(if ($now) { $now } else { 'unknown' }))." -ForegroundColor Green }
    }
}
Exit-QuestWrapper -Code $r.Code -WaitSec $WaitSec -NoWait:$NoWait -FailedText 'The headset did not take the change (see the lines above).'
