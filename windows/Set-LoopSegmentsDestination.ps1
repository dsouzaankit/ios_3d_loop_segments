#Requires -Version 5.1
<#
.SYNOPSIS
  Save the PC DLNA folder used by Sync-FromIPhonePhotos.ps1 and related scripts.

.EXAMPLE
  .\Set-LoopSegmentsDestination.ps1 'D:\media\3d_fullsbs_trans'

.EXAMPLE
  .\Set-LoopSegmentsDestination.ps1
  # Prompts for path
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $DestinationPath = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\LoopSegments-Config.ps1"

$configFile = Get-LoopSegmentsDestinationConfigPath

if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    Write-Host 'Enter the folder your DLNA server uses for 3d_op_00.mp4 and 3d_op_01.mp4.'
    Write-Host "(Default in docs is F:\f1_media\3d_fullsbs_trans — use your actual drive/path.)"
    $DestinationPath = Read-Host 'DLNA destination folder'
}

$full = Get-LoopSegmentsDestinationDirectory -Override $DestinationPath.Trim().Trim('"')
Test-LoopSegmentsDestinationReady -Directory $full | Out-Null

if (-not (Test-Path -LiteralPath $full -PathType Container)) {
    $create = Read-Host "Folder does not exist yet. Create it? [Y/n]"
    if ($create -eq '' -or $create -match '^[Yy]') {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    } else {
        throw "Not a folder: $full"
    }
}

Set-Content -LiteralPath $configFile -Value $full -Encoding UTF8 -NoNewline
Write-Host "Saved: $configFile"
Write-Host ''
Write-Host 'Test Photos MTP sync:'
Write-Host '  .\Sync-FromIPhonePhotos.ps1 -Discover'
Write-Host '  .\Sync-FromIPhonePhotos.ps1'
