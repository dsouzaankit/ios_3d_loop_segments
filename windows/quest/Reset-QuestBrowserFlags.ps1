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
  phone page (/xr-assets/aframe.min.js) before going to chrome://flags.

  Like Set-QuestProximitySensor.ps1 (shared code in quest\QuestWrapperCommon.ps1): first makes sure
  this PC is on the phone's network (lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1;
  -SkipNetworkCheck skips it), then, while the headset is not on adb (asleep, or Wi-Fi just switched
  on), keeps trying every 5 s for up to -WaitSec (default 120 s), restarting the adb server before
  each retry.

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
    [int] $WaitSec = 120,
    # Do not check / fix this PC's network first.
    [switch] $SkipNetworkCheck
)

. (Join-Path $PSScriptRoot 'QuestWrapperCommon.ps1')

if (-not $SkipNetworkCheck) { Invoke-QuestWrapperNetworkCheck }
$url = Get-QuestWrapperPhoneUrl
Write-Host "Quest Browser: resetting all chrome://flags to default (phone page $url)..." -ForegroundColor Cyan

$r = Invoke-QuestWrapperWatch -Arguments @('-Url', $url, '-ResetFlags') -WaitSec $WaitSec
if ($r.Code -eq 0) {
    Write-Host 'Done: chrome://flags reset and Quest Browser restarted. The next Open on Quest sets the insecure-origin flag again.' -ForegroundColor Green
}
Exit-QuestWrapper -Code $r.Code -WaitSec $WaitSec -NoWait:$NoWait -FailedText 'Reset failed (see the lines above): is the phone LAN page up, and is the headset worn (Quest Browser answers only then)?'
