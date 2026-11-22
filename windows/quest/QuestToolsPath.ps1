# Finds the quest_tools repo (generic Quest headset helpers: adb, headset discovery, proximity sensor,
# Wi-Fi, Quest Browser DevTools, SKYBOX database), which the scripts in this folder load. Dot-source
# it; sets $script:QuestToolsRepo ($null when not found) and $env:QUEST_TOOLS_REPO for child
# processes, so every helper uses the same checkout (they share %TEMP% state and one adb server).
#
# Order: $env:QUEST_TOOLS_REPO, <ALL_SCRIPTS_ROOT>\quest_tools, a quest_tools folder next to any
# parent folder of this repo (P:\all_scripts\iOS apps\ios_3d_loop_segments -> P:\all_scripts\quest_tools),
# then P:\all_scripts\quest_tools.

function Find-QuestToolsRepo {
    param([string] $From)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:QUEST_TOOLS_REPO) { $candidates.Add($env:QUEST_TOOLS_REPO) }
    if ($env:ALL_SCRIPTS_ROOT) { $candidates.Add((Join-Path $env:ALL_SCRIPTS_ROOT 'quest_tools')) }
    $d = $From
    while ($d) {
        $candidates.Add((Join-Path $d 'quest_tools'))
        $d = Split-Path -Parent $d
    }
    $candidates.Add('P:\all_scripts\quest_tools')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'QuestTools.ps1') -PathType Leaf)) { return [System.IO.Path]::GetFullPath($c) }
    }
    return $null
}

$script:QuestToolsRepo = Find-QuestToolsRepo -From $PSScriptRoot
if ($script:QuestToolsRepo) { $env:QUEST_TOOLS_REPO = $script:QuestToolsRepo }
