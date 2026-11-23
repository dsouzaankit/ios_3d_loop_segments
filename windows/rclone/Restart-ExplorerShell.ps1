# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
<#
.SYNOPSIS
  Restart Explorer only — leave the phone rclone L: mount (and hybrid/ffmpeg) running.

.DESCRIPTION
  Use when Explorer is frozen on L: (thumbnails / This PC) but the mount itself is still
  alive. Does NOT kill rclone. For a dead mount after phone LAN dies, use Unstick-PhoneL.cmd
  or Mount-LoopSegmentsRclone.ps1 -Unstick instead.

.PARAMETER DriveLetter
  Optional quick probe after restart (default L). Skipped with -NoProbe.

.PARAMETER ProbeSeconds
  Max seconds to wait for a non-blocking Get-ChildItem of the drive root (default 5).

.PARAMETER NoProbe
  Skip the post-restart drive list check.

.EXAMPLE
  .\Restart-ExplorerShell.ps1

.EXAMPLE
  .\Restart-ExplorerShell.ps1 -DriveLetter L -ProbeSeconds 8
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string] $DriveLetter = 'L',
    [ValidateRange(1, 60)]
    [int] $ProbeSeconds = 5,
    [switch] $NoProbe
)

$ErrorActionPreference = 'Stop'

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"

Write-Host 'Explorer-only unstick: rclone mount and encode processes are left running.'
Write-Host 'If shell listing of the drive also hangs, use Unstick-PhoneL.cmd / -Unstick instead.'
Restart-WindowsExplorerShell

if ($NoProbe) {
    Write-Host 'Done (no drive probe).'
    exit 0
}

$root = ('{0}:\' -f $DriveLetter.ToUpperInvariant())
Write-Host ("Probing {0} (timeout {1}s)..." -f $root, $ProbeSeconds)
$job = Start-Job -ScriptBlock {
    param([string] $Path)
    try {
        $names = @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop | Select-Object -First 5 -ExpandProperty Name)
        return [pscustomobject]@{ Ok = $true; Names = $names; Error = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; Names = @(); Error = $_.Exception.Message }
    }
} -ArgumentList $root

$finished = Wait-Job -Job $job -Timeout $ProbeSeconds
if (-not $finished) {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-Warning ("{0} list timed out after {1}s — mount may be dead. Run Unstick-PhoneL.cmd or Mount-LoopSegmentsRclone.ps1 -Unstick." -f $root, $ProbeSeconds)
    exit 2
}

$result = Receive-Job -Job $job
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
if (-not $result.Ok) {
    Write-Warning ("{0} list failed: {1}. Try Unstick-PhoneL.cmd if the letter is stuck." -f $root, $result.Error)
    exit 2
}

$preview = if ($result.Names.Count -gt 0) { $result.Names -join ', ' } else { '(empty)' }
Write-Host ("{0} OK — {1}" -f $root, $preview)
Write-Host 'Done.'
exit 0
