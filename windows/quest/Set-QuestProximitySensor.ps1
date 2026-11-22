<#
.SYNOPSIS
  Turn the Quest headset's proximity sensor off (stays awake) or on (sleeps when taken off), over adb.

.DESCRIPTION
  Loop Segments entry for quest_tools\Set-QuestProximitySensor.ps1 (see there and quest_tools\README.md):
  first makes sure this PC is on the phone's network, like the companion's startup
  (lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1 -PhoneLanHost <phoneLanHost>; only when the
  PC is on another network, e.g. after a quit's Wi-Fi bounce, it restarts that router's Wi-Fi so the PC
  moves back; -SkipNetworkCheck skips it), then runs the quest_tools script.

  While the PC companion runs with questKeepAwakeDuringSession=true, its keep-awake job switches the
  sensor off again within ~20 s after you turn it on; the companion turns it on itself at close.

  Exit codes: 0 done, 1 headset not on adb, 2 no adb / quest_tools not found, 3 the headset did not
  take the change. Log: %TEMP%\loopsegments-quest-lantab.log

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
& (Join-Path $script:QuestToolsRepo 'Set-QuestProximitySensor.ps1') -State $State -NoWait:$NoWait -WaitSec $WaitSec
exit $LASTEXITCODE
