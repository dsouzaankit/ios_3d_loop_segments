<#
.SYNOPSIS
  Switch the Quest headset's Wi-Fi off, over adb (a sleeping headset then does not drain its battery
  on Wi-Fi).

.DESCRIPTION
  Run it with no arguments: on an awake headset it first opens Settings > Wi-Fi (so switching Wi-Fi
  back on is one tap when you next put the headset on), then switches Wi-Fi off
  (`cmd wifi set-wifi-enabled disabled`). adb drops right after, because it runs over that Wi-Fi. It
  shows what it did (or the error) and waits for Enter (-NoWait skips that).

  The companion's quit does the same as its last Quest step (questWifiOffOnExit, default true); this
  is for doing it by hand, and it ignores that setting.

  Switch Wi-Fi back on in the headset (Settings > Wi-Fi, or quick settings). Wireless debugging then
  comes back by itself on a new port, which the PC finds over mDNS.

  Like Set-QuestProximitySensor.ps1 (shared code in quest\QuestWrapperCommon.ps1): first makes sure
  this PC is on the phone's network (lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1;
  -SkipNetworkCheck skips it), then, while the headset is not on adb, keeps trying every 5 s for up
  to -WaitSec (default 120 s), restarting the adb server before each retry.

  Exit codes: 0 Wi-Fi off, 1 headset not on adb, 2 no adb, 3 the headset did not take it.
  Log: %TEMP%\loopsegments-quest-lantab.log

.EXAMPLE
  .\Set-QuestWifiOff.ps1

.EXAMPLE
  .\Set-QuestWifiOff.ps1 -NoWait -WaitSec 0
#>
[CmdletBinding()]
param(
    # Exit straight away instead of waiting for Enter (for scripts).
    [switch] $NoWait,
    # Headset not on adb: keep trying for this many seconds (every 5 s). 0 = try once.
    [int] $WaitSec = 120,
    # Do not check / fix this PC's network first.
    [switch] $SkipNetworkCheck
)

. (Join-Path $PSScriptRoot 'QuestWrapperCommon.ps1')

if (-not $SkipNetworkCheck) { Invoke-QuestWrapperNetworkCheck }
Write-Host "Quest Wi-Fi: switching it off..." -ForegroundColor Cyan

$r = Invoke-QuestWrapperWatch -Arguments @('-WifiOff') -WaitSec $WaitSec
if ($r.Code -eq 0) {
    Write-Host 'Wi-Fi is OFF on the headset (adb is disconnected now). Switch it on in the headset (Settings > Wi-Fi) before the next session.' -ForegroundColor Green
}
Exit-QuestWrapper -Code $r.Code -WaitSec $WaitSec -NoWait:$NoWait -FailedText 'The headset did not switch its Wi-Fi off (see the lines above).'
