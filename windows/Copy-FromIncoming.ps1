#Requires -Version 5.1
<#
.SYNOPSIS
  Copy segment MP4s from the folder you use as Apple Devices "Save to PC" target.

.DESCRIPTION
  Apple Devices does not expose a phone path to PowerShell — you pick a Windows output
  folder manually. Point Apple Devices at -IncomingDirectory each time (it remembers
  the last path), then run this script to copy into the DLNA library folder.

.EXAMPLE
  .\Copy-FromIncoming.ps1

.EXAMPLE
  .\Copy-FromIncoming.ps1 -IncomingDirectory 'C:\Users\you\Documents\LoopSegmentsIncoming'
#>
[CmdletBinding()]
param(
    [string] $IncomingDirectory = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LoopSegmentsIncoming'),
    [string] $DestinationDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

function Copy-IfNewer {
    param([string] $SourcePath, [string] $DestPath, [switch] $DryRun)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $false }
    $copy = $true
    if (Test-Path -LiteralPath $DestPath -PathType Leaf) {
        $src = Get-Item -LiteralPath $SourcePath
        $dst = Get-Item -LiteralPath $DestPath
        if ($src.Length -eq $dst.Length -and $src.LastWriteTimeUtc -le $dst.LastWriteTimeUtc) {
            $copy = $false
        }
    }
    if (-not $copy) {
        Write-Host "Up to date: $DestPath"
        return $true
    }
    if ($DryRun) {
        Write-Host "Would copy: $SourcePath -> $DestPath"
        return $true
    }
    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestPath -Force
    Write-Host "Copied: $DestPath"
    return $true
}

$incoming = [System.IO.Path]::GetFullPath($IncomingDirectory)
$destRoot = [System.IO.Path]::GetFullPath($DestinationDirectory)

if (-not (Test-Path -LiteralPath $incoming -PathType Container)) {
    Write-Error @"
Incoming folder not found: $incoming

In Apple Devices, when saving from Loop Segments -> Exports, choose this folder as the
Windows output path (create it first if needed). Apple Devices usually remembers it.
"@
}

if (-not $DryRun -and -not (Test-Path -LiteralPath $destRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
}

Write-Host "From (Apple Devices save target): $incoming"
Write-Host "To (DLNA library): $destRoot"

$copied = 0
foreach ($name in @('op_00.mp4', 'op_01.mp4', 'export_latest.txt')) {
  $src = Join-Path $incoming $name
  $dst = Join-Path $destRoot $name
  if (Copy-IfNewer -SourcePath $src -DestPath $dst -DryRun:$DryRun) { $copied++ }
}

$logsDir = Join-Path $incoming 'logs'
if (Test-Path -LiteralPath $logsDir -PathType Container) {
    $logDest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'LoopSegmentsLogs'
    if (-not $DryRun) { New-Item -ItemType Directory -Path $logDest -Force | Out-Null }
    Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.log', '.txt' } |
        ForEach-Object {
            if (Copy-IfNewer -SourcePath $_.FullName -DestPath (Join-Path $logDest $_.Name) -DryRun:$DryRun) {
                $copied++
            }
        }
}

if ($copied -eq 0) {
    Write-Host 'Nothing to copy — save op_*.mp4 from Apple Devices into the incoming folder first.'
} else {
    Write-Host 'Done.'
}
