<#
.SYNOPSIS
  After-script of quest_tools' after-quit history helper: run (or drop) the quit's held phone LAN AP
  bounce.

.DESCRIPTION
  When the companion's quit finds the Wi-Fi->www probe failing while a history delete is still
  pending, it does not restart the phone network's router then (that would move the headset to the
  other Wi-Fi, where the helper on this PC cannot reach it). It writes
  %TEMP%\loopsegments-wifi-bounce-pending.json instead (QuestCompanionHooks.ps1
  Request-QuestDeferredWifiBounce). quest_tools' helper (Invoke-QuestHistoryRetry.ps1) runs this
  script when it ends:

    -Outcome done | gaveup | none : bounce the phone LAN AP now (lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1
                                    -BouncePhoneLanAp; output in %TEMP%\loopsegments-wifi-bounce.log);
    -Outcome stopped              : the companion started again - drop it (its quit probes anew).

  Nothing held: nothing to do. Log: %TEMP%\loopsegments-quest-lantab.log ("Wi-Fi bounce:" lines).
#>
[CmdletBinding()]
param(
    [ValidateSet('done', 'gaveup', 'stopped', 'none')] [string] $Outcome = 'none'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bouncePath = Join-Path $env:TEMP 'loopsegments-wifi-bounce-pending.json'
if (-not (Test-Path -LiteralPath $bouncePath)) { exit 0 }

function Write-BounceLog {
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath (Join-Path $env:TEMP 'loopsegments-quest-lantab.log') -Value $line -Encoding utf8 } catch {}
}

$b = $null
try { $b = Get-Content -LiteralPath $bouncePath -Raw | ConvertFrom-Json } catch {}
Remove-Item -LiteralPath $bouncePath -Force -ErrorAction SilentlyContinue
if ($Outcome -eq 'stopped') {
    Write-BounceLog 'Wi-Fi bounce: dropped (the companion started again; its quit probes Wi-Fi->www anew).'
    exit 0
}
$why = @{ done = 'history deleted'; gaveup = 'history helper gave up'; none = 'history delete no longer pending' }[$Outcome]
$ps1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'lan\Invoke-LoopSegmentsGatewayWifiRebootIfNeeded.ps1'
if (-not (Test-Path -LiteralPath $ps1)) { Write-BounceLog "Wi-Fi bounce: $ps1 missing - skipped."; exit 0 }
$log = Join-Path $env:TEMP 'loopsegments-wifi-bounce.log'
Write-BounceLog "Wi-Fi bounce: $why - bouncing the phone LAN AP now (held by the quit; output in $log)."
$a = @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`"", '-BouncePhoneLanAp', '-NoWaitEnter')
if ($b -and $b.PSObject.Properties['phoneLanHost'] -and $b.phoneLanHost) { $a += @('-PhoneLanHost', [string]$b.phoneLanHost) }
try {
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $a -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if (-not $p.WaitForExit(600000)) { try { $p.Kill($true) } catch {}; Write-BounceLog 'Wi-Fi bounce: still running after 10 min - stopped.'; exit 3 }
    Write-BounceLog "Wi-Fi bounce: finished (exit $($p.ExitCode))."
} catch {
    Write-BounceLog "Wi-Fi bounce: could not run: $($_.Exception.Message)"
    exit 3
}
exit 0
