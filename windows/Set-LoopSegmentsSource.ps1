#Requires -Version 5.1
<#
.SYNOPSIS
  Save the iPhone Exports folder path for automated Sync-IphoneSegments.ps1 runs.

.DESCRIPTION
  Apple Devices lets you browse Loop Segments manually, but it does not auto-sync to a PC folder.
  Run this once with the Exports path PowerShell can read (often from Explorer while Apple Devices
  has the folder open — copy the address bar).

.EXAMPLE
  .\Set-LoopSegmentsSource.ps1 'D:\Apple iPhone\Internal Storage\Loop Segments\Exports'

.EXAMPLE
  .\Set-LoopSegmentsSource.ps1
  # Prompts for path; tests that op_*.mp4 or export_latest.txt is visible
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $ExportsPath = ''
)

$ErrorActionPreference = 'Stop'
$configFile = Join-Path $PSScriptRoot 'loop-segments-source.txt'

if ([string]::IsNullOrWhiteSpace($ExportsPath)) {
    Write-Host 'Paste the Loop Segments Exports folder path from Explorer'
    Write-Host '(open via Apple Devices -> Files -> Loop Segments -> Exports, then copy address bar):'
    $ExportsPath = Read-Host 'Exports path'
}

$full = [System.IO.Path]::GetFullPath($ExportsPath.Trim().Trim('"'))
if (-not (Test-Path -LiteralPath $full -PathType Container)) {
    throw "Not a folder: $full"
}

$hasSegment = @('op_00.mp4', 'op_01.mp4') | Where-Object {
    Test-Path -LiteralPath (Join-Path $full $_) -PathType Leaf
}
$hasLog = (Test-Path -LiteralPath (Join-Path $full 'export_latest.txt') -PathType Leaf)

if (-not $hasSegment -and -not $hasLog) {
    Write-Warning "No op_*.mp4 or export_latest.txt in this folder yet. Path saved anyway."
}

Set-Content -LiteralPath $configFile -Value $full -Encoding UTF8 -NoNewline
Write-Host "Saved: $configFile"
Write-Host "Test sync:"
Write-Host "  .\Sync-IphoneSegments.ps1"
Write-Host "Register logon automation:"
Write-Host "  .\Register-UsbSyncTask.ps1"
