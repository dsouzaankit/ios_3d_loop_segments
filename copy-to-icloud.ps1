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

.PARAMETER EnsureAltStorePrep
  Opt-in: start AltServer / Clash multicast prep after copy. Default skips (SideStore).
  deploy.ps1 can pass this; when deploy runs prep itself it passes -SkipAltStorePrep to this child.

.PARAMETER SkipAltStorePrep
  Deprecated alias for the default (skip AltServer prep). Also used by deploy.ps1 so prep
  runs once in the parent.

.PARAMETER NoWaitEnter
  Do not wait for Enter (when invoked as a child of deploy.ps1).
#>
param(
    [switch] $FetchIfMissing,
    [string] $SourceIpa = '',
    [switch] $EnsureAltStorePrep,
    [switch] $SkipAltStorePrep,
    [switch] $NoWaitEnter
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

$configModule = Join-Path $ProjectRoot 'windows\loop-segments-windows.json'
if (Test-Path -LiteralPath $configModule) {
    try {
        $winCfg = Get-Content -LiteralPath $configModule -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$winCfg.iCloudDownloads)) {
            $ICloudDownloads = [string]$winCfg.iCloudDownloads
            if ($ICloudDownloads -notmatch '^[A-Za-z]:\\' -and -not $ICloudDownloads.StartsWith('\\')) {
                $ICloudDownloads = Join-Path $env:USERPROFILE $ICloudDownloads
            }
        }
    } catch {
        Write-Warning "Could not read iCloudDownloads from loop-segments-windows.json: $($_.Exception.Message)"
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

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    exit $ExitCode
}

trap {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($NoWaitEnter) { throw $_ }
    Wait-EnterToClose
    exit 1
}

function Invoke-ProjectAltStoreDeployPrep {
    if (-not $EnsureAltStorePrep -or $SkipAltStorePrep) {
        Write-Host '[altserver] Deploy prep skipped (default). Pass -EnsureAltStorePrep for AltStore tray.' -ForegroundColor DarkYellow
        return
    }
    $join = @(
        (Join-Path $ProjectRoot 'env_setup\altserver_refresh\lib\Join-AltStoreDeployPrep.ps1')
        (Join-Path $ProjectRoot 'env_setup\altserver_refresh\Join-AltStoreDeployPrep.ps1')
        'P:\all_scripts\iOS apps\env_setup\altserver_refresh\lib\Join-AltStoreDeployPrep.ps1'
        'P:\all_scripts\iOS apps\env_setup\altserver_refresh\Join-AltStoreDeployPrep.ps1'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $join) {
        Write-Host 'WARN: env_setup AltServer helpers not found — skip tray prep.'
        return
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        . $join
        Invoke-AltStoreDeployPrep -SkipPhoneSubnet
    } catch {
        Write-Warning ("AltStore deploy prep failed (IPA copy already done): {0}" -f $_.Exception.Message)
    } finally {
        $ErrorActionPreference = $prev
    }
}

if (-not (Test-Path -LiteralPath $LocalIpa)) {
    if ($FetchIfMissing) {
        Write-Step 'Local IPA missing — fetching latest Actions artifact'
        & (Join-Path $ProjectRoot 'deploy.ps1') -UseLatest -SkipICloud -NoWaitEnter
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
Write-Host "  SideStore or AltStore → My Apps → + → $DestIpaName"
Write-Host '  Or Files → iCloud Drive → Downloads → Share → SideStore / AltStore'
Write-Host ''
Invoke-ProjectAltStoreDeployPrep
Exit-WithEnter 0
