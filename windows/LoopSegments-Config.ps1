#Requires -Version 5.1
# Shared paths for Loop Segments Windows scripts (dot-source from $PSScriptRoot).

$script:LoopSegmentsDefaultDestination = 'F:\f1_media\3d_fullsbs_trans'

function Get-LoopSegmentsDestinationConfigPath {
    Join-Path $PSScriptRoot 'loop-segments-destination.txt'
}

function Get-LoopSegmentsDestinationDirectory {
    param(
        [string] $Override = '',
        [string] $DefaultPath = $script:LoopSegmentsDefaultDestination
    )

    $path = $Override.Trim()
    if ([string]::IsNullOrWhiteSpace($path)) {
        $configFile = Get-LoopSegmentsDestinationConfigPath
        if (Test-Path -LiteralPath $configFile -PathType Leaf) {
            $fromFile = (Get-Content -LiteralPath $configFile -Raw).Trim().Trim('"')
            if (-not [string]::IsNullOrWhiteSpace($fromFile)) {
                $path = $fromFile
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $DefaultPath
    }
    return [System.IO.Path]::GetFullPath($path)
}

function Test-LoopSegmentsDestinationReady {
    param([string] $Directory)

    $root = [System.IO.Path]::GetPathRoot($Directory)
    if ($root -match '^[a-zA-Z]:\\$') {
        $drive = $root.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $drive)) {
            $letter = $drive[0]
            $configFile = Get-LoopSegmentsDestinationConfigPath
            throw @"
DLNA destination drive '$letter' is not available on this PC.
  Configured path: $Directory

Save your real DLNA folder (where op_00.mp4 / op_01.mp4 live), for example:
  D:\media\3d_fullsbs_trans

Run once:
  .\Set-LoopSegmentsDestination.ps1 'D:\media\3d_fullsbs_trans'

Or pass -DestinationDirectory on each sync script run.
Config file (optional): $configFile
"@
        }
    }
}
