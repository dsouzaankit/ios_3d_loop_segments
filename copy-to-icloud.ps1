#Requires -Version 5.1
<#
.SYNOPSIS
  Copy LoopSegments.ipa to iCloud Drive Downloads with a unique name (Files refresh).

.DESCRIPTION
  Same pattern as web_auto_parking\deploy.ps1: stamp the destination IPA
  (LoopSegments-b{build}-{yyyyMMdd-HHmmss}.ipa), remove older LoopSegments*.ipa
  from iCloud Downloads, then copy. Does not trigger GitHub Actions.

  Usage:
    .\copy-to-icloud.ps1
    .\copy-to-icloud.ps1 -FetchIfMissing   # if local IPA missing, gh download latest first

.PARAMETER FetchIfMissing
  When the local IPA is absent, run deploy.ps1 -UseLatest -SkipICloud, then copy.

.PARAMETER SourceIpa
  Optional override path to an .ipa (default: ios\build artifacts\ipa\LoopSegments.ipa).
#>
param(
    [switch] $FetchIfMissing,
    [string] $SourceIpa = ''
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseIpaName = 'LoopSegments.ipa'
$LocalIpa = if (-not [string]::IsNullOrWhiteSpace($SourceIpa)) {
    $SourceIpa
} else {
    Join-Path $ProjectRoot "ios\build artifacts\ipa\$BaseIpaName"
}
$ICloudDownloads = Join-Path $env:USERPROFILE 'iCloudDrive\Downloads'

$configModule = Join-Path $ProjectRoot 'windows\lib\LoopSegments-Windows.ps1'
if (Test-Path -LiteralPath $configModule) {
    . $configModule
    $winCfg = Get-LoopSegmentsWindowsSettings
    if (-not [string]::IsNullOrWhiteSpace([string]$winCfg.iCloudDownloads)) {
        $ICloudDownloads = [string]$winCfg.iCloudDownloads
        if ($ICloudDownloads -notmatch '^[A-Za-z]:\\' -and -not $ICloudDownloads.StartsWith('\\')) {
            $ICloudDownloads = Join-Path $env:USERPROFILE $ICloudDownloads
        }
    }
}

$ProjectSpecPath = Join-Path $ProjectRoot 'ios\project.yml'
$BuildNumber = 'unknown'
if (Test-Path -LiteralPath $ProjectSpecPath) {
    $match = Select-String -Path $ProjectSpecPath -Pattern 'CURRENT_PROJECT_VERSION:\s*"?(?<build>\d+)"?' -AllMatches
    if ($match -and $match.Matches.Count -gt 0) {
        $BuildNumber = $match.Matches[0].Groups['build'].Value
    }
}
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$DestIpaName = "LoopSegments-b$BuildNumber-$Timestamp.ipa"
$DestIpa = Join-Path $ICloudDownloads $DestIpaName

function Write-Step([string] $Message) {
    Write-Host "==> $Message"
}

if (-not (Test-Path -LiteralPath $LocalIpa)) {
    if ($FetchIfMissing) {
        Write-Step 'Local IPA missing — fetching latest Actions artifact'
        & (Join-Path $ProjectRoot 'deploy.ps1') -UseLatest -SkipICloud
        if ($LASTEXITCODE -ne 0) {
            throw 'deploy.ps1 -UseLatest -SkipICloud failed'
        }
    } else {
        throw @"
Local IPA not found: $LocalIpa
Run .\deploy.ps1 first, or: .\copy-to-icloud.ps1 -FetchIfMissing
"@
    }
}

if (-not (Test-Path -LiteralPath $ICloudDownloads)) {
    throw "iCloud Downloads folder not found: $ICloudDownloads (sign in to iCloud for Windows, or set iCloudDownloads in windows\loop-segments-windows.json)"
}

Write-Host ''
Write-Host 'copy-to-icloud (unique IPA name — same idea as web_auto_parking\deploy.ps1)'
Write-Host "  Source: $LocalIpa"
Write-Host "  Dest:   $DestIpa"
Write-Host ''

Write-Step 'Deleting older LoopSegments IPA files from iCloud Downloads'
$OldIpas = Get-ChildItem -LiteralPath $ICloudDownloads -Filter 'LoopSegments*.ipa' -File -ErrorAction SilentlyContinue
foreach ($old in $OldIpas) {
    if ($old.Name -ne $DestIpaName) {
        Write-Host "    removing $($old.FullName)"
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Copying IPA to iCloud Downloads as $DestIpaName"
Copy-Item -LiteralPath $LocalIpa -Destination $DestIpa -Force

$src = Get-Item -LiteralPath $LocalIpa
$dst = Get-Item -LiteralPath $DestIpa
$mb = [math]::Round($dst.Length / 1MB, 2)
Write-Host ''
Write-Host "Done. $($dst.FullName) ($mb MB)"
Write-Host "Source mtime: $($src.LastWriteTime)"
Write-Host "Build: $BuildNumber"
Write-Host ''
Write-Host 'Next on iPhone:'
Write-Host '  Wait for iCloud to sync Downloads (new filename triggers Files refresh)'
Write-Host "  AltStore → My Apps → + → $DestIpaName"
Write-Host '  Or Files → iCloud Drive → Downloads → Share → AltStore'
Write-Host ''
