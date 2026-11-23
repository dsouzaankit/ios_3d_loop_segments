# Shared by the double-click Quest helpers in this folder (Reset-QuestBrowserFlags.ps1, and the
# Set-LoopSegmentsQuestProximitySensor.ps1 / Set-LoopSegmentsQuestWifiOff.ps1 forwarders): config, the PC's network check, and
# running Watch-LoopSegmentsQuestLanTab.ps1 with retries until the headset is on adb (the retry loop
# and closing message are quest_tools\QuestWrapperCommon.ps1). Dot-source it.

$script:QuestWatchScript = Join-Path $PSScriptRoot 'Watch-LoopSegmentsQuestLanTab.ps1'
. (Join-Path $PSScriptRoot 'QuestToolsPath.ps1')
if (-not $script:QuestToolsRepo) {
    Write-Host 'ERROR: quest_tools not found (set QUEST_TOOLS_REPO, or put it next to this repo''s parent folder, e.g. P:\all_scripts\quest_tools).' -ForegroundColor Red
    exit 2
}
. (Join-Path $script:QuestToolsRepo 'QuestWrapperCommon.ps1')
$script:QuestWrapperCfg = $null
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\LoopSegments-Windows.ps1')
    $script:QuestWrapperCfg = Get-LoopSegmentsWindowsSettings
} catch {}

# http://<phoneLanHost>:<lanPort>/ from windows\loop-segments-windows.json. Not set: read the IP from
# the iPhone on USB (saved for next time), else stop with the setup hint.
function Get-QuestWrapperPhoneUrl {
    $phone = ''; $port = 8765
    if ($script:QuestWrapperCfg) {
        if ($script:QuestWrapperCfg.phoneLanHost) { $phone = ([string]$script:QuestWrapperCfg.phoneLanHost).Trim() }
        if ([int]$script:QuestWrapperCfg.lanPort -gt 0) { $port = [int]$script:QuestWrapperCfg.lanPort }
    }
    if ([string]::IsNullOrWhiteSpace($phone)) {
        if (-not (Get-Command Get-LoopSegmentsLANHost -ErrorAction SilentlyContinue)) {
            throw 'phoneLanHost is not set and windows\lib\LoopSegments-Windows.ps1 did not load. Set phoneLanHost in windows\loop-segments-windows.json.'
        }
        $phone = Get-LoopSegmentsLANHost -AllowDiscover
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

# Watch-LoopSegmentsQuestLanTab.ps1 with -Arguments, retried while the headset is not on adb.
function Invoke-QuestWrapperWatch {
    param([string[]] $Arguments, [int] $WaitSec)
    return (Invoke-QuestWrapperScript -Script $script:QuestWatchScript -Arguments $Arguments -WaitSec $WaitSec)
}
