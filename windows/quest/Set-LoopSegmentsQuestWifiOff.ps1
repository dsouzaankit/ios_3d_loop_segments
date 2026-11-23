<#
.SYNOPSIS
  Switch the Quest headset's Wi-Fi off, over adb (a sleeping headset then does not drain its battery
  on Wi-Fi).

.DESCRIPTION
  Loop Segments entry for quest_tools\Set-QuestWifiOff.ps1 (see there and quest_tools\README.md):
  first makes sure this PC is on the phone's network (lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1;
  -SkipNetworkCheck skips it), then runs the quest_tools script.

  The companion's quit does the same as its last Quest step (questWifiOffOnExit, default true); this
  is for doing it by hand, and it ignores that setting.

  Exit codes: 0 Wi-Fi off, 1 headset not on adb, 2 no adb / quest_tools not found, 3 the headset did
  not take it. Log: %TEMP%\loopsegments-quest-lantab.log

.EXAMPLE
  .\Set-LoopSegmentsQuestWifiOff.ps1

.EXAMPLE
  .\Set-LoopSegmentsQuestWifiOff.ps1 -NoWait -WaitSec 0
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
& (Join-Path $script:QuestToolsRepo 'Set-QuestWifiOff.ps1') -NoWait:$NoWait -WaitSec $WaitSec
exit $LASTEXITCODE
