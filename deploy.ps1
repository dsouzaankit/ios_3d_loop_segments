#Requires -Version 5.1
<#
.SYNOPSIS
  Build (or fetch) LoopSegments.ipa via GitHub Actions and copy it to iCloud Drive Downloads.

.DESCRIPTION
  Neighbors (bike_train_transit, quick_open_apps, …) use deploy.ps1 for Pythonista zips.
  This repo ships a native IPA: trigger ios-build, download the artifact, copy to iCloud.

  Deploy workflow:
    1. Run:  .\deploy.ps1   (build/fetch + iCloud paste via copy-to-icloud.ps1)
    2. Wait for iCloud sync on the iPhone (no cloud badge on the IPA)
    3. AltStore → My Apps → + → LoopSegments.ipa (or Files → Share → AltStore)

  Re-paste only (stamped IPA name, no build): .\copy-to-icloud.ps1

.PARAMETER UseLatest
  Skip triggering a new workflow; download the newest successful workflow_dispatch IPA.

.PARAMETER RunId
  Download a specific Actions run ID (skips trigger).

.PARAMETER SkipICloud
  Only refresh ios\build artifacts\ipa\LoopSegments.ipa (no iCloud copy).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
  .\deploy.ps1 -UseLatest
#>
param(
    [switch] $UseLatest,
    [string] $RunId = '',
    [switch] $SkipICloud
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$IpaDir = Join-Path $ProjectRoot 'ios\build artifacts\ipa'
$IpaName = 'LoopSegments.ipa'
$LocalIpa = Join-Path $IpaDir $IpaName

function Write-Step([string] $Message) {
    Write-Host "==> $Message"
}

function Assert-Gh {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        throw 'GitHub CLI (gh) not found on PATH. Install https://cli.github.com/ then run: gh auth login'
    }
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'gh is not authenticated. Run: gh auth login'
    }
}

function Get-LatestIpaRunId {
    $json = & gh run list --workflow=ios-build.yml --event=workflow_dispatch --status=success --limit 20 --json databaseId,displayTitle,createdAt,headBranch
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw 'Could not list ios-build runs (need a successful workflow_dispatch run, or omit -UseLatest to trigger one).'
    }
    $runs = $json | ConvertFrom-Json
    if (-not $runs -or $runs.Count -eq 0) {
        throw 'No successful ios-build workflow_dispatch runs found. Run without -UseLatest to trigger a build.'
    }
    return [string]$runs[0].databaseId
}

function Wait-ForIpaRun([string] $Id) {
    Write-Step "Waiting for ios-build run $Id"
    & gh run watch $Id --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "ios-build run $Id failed. See: gh run view $Id --web"
    }
}

function Download-IpaArtifact([string] $Id) {
    New-Item -ItemType Directory -Force -Path $IpaDir | Out-Null
    Push-Location $IpaDir
    try {
        Get-ChildItem -Force | Where-Object {
            $_.Name -eq $IpaName -or $_.Name -eq 'LoopSegments-ipa' -or $_.Name -like 'LoopSegments*.ipa'
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        Write-Step "Downloading LoopSegments-ipa from run $Id"
        & gh run download $Id -n LoopSegments-ipa
        if ($LASTEXITCODE -ne 0) {
            throw "gh run download failed for run $Id (artifact LoopSegments-ipa)."
        }

        $found = $null
        if (Test-Path -LiteralPath (Join-Path $IpaDir 'LoopSegments-ipa\LoopSegments.ipa')) {
            $found = Join-Path $IpaDir 'LoopSegments-ipa\LoopSegments.ipa'
        } elseif (Test-Path -LiteralPath (Join-Path $IpaDir $IpaName)) {
            $found = Join-Path $IpaDir $IpaName
        } else {
            $found = Get-ChildItem -Path $IpaDir -Recurse -Filter '*.ipa' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $found) {
            throw "No .ipa found after downloading run $Id"
        }
        $foundFull = [System.IO.Path]::GetFullPath($found)
        $localFull = [System.IO.Path]::GetFullPath($LocalIpa)
        if ($foundFull -ine $localFull) {
            Copy-Item -LiteralPath $found -Destination $LocalIpa -Force
        }
        if (Test-Path -LiteralPath (Join-Path $IpaDir 'LoopSegments-ipa')) {
            Remove-Item -LiteralPath (Join-Path $IpaDir 'LoopSegments-ipa') -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Pop-Location
    }
}

Assert-Gh

Write-Host ''
Write-Host 'Deploy workflow:'
Write-Host '  [PC]  1. This script (GitHub Actions IPA -> local + iCloud Downloads)'
Write-Host '  [YOU] 2. Wait for iCloud sync on iPhone (no cloud badge)'
Write-Host '  [YOU] 3. AltStore -> My Apps -> + -> LoopSegments.ipa'
Write-Host ''

$resolvedRunId = $RunId.Trim()
if (-not $resolvedRunId) {
    if ($UseLatest) {
        $resolvedRunId = Get-LatestIpaRunId
        Write-Step "Using latest successful workflow_dispatch run: $resolvedRunId"
    } else {
        Write-Step 'Triggering ios-build (workflow_dispatch)'
        Push-Location $ProjectRoot
        try {
            & gh workflow run ios-build.yml
            if ($LASTEXITCODE -ne 0) {
                throw 'gh workflow run ios-build.yml failed'
            }
            Start-Sleep -Seconds 4
            $json = & gh run list --workflow=ios-build.yml --event=workflow_dispatch --limit 1 --json databaseId,status
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
                throw 'Could not resolve the new ios-build run id'
            }
            $resolvedRunId = [string](($json | ConvertFrom-Json)[0].databaseId)
        } finally {
            Pop-Location
        }
        Wait-ForIpaRun $resolvedRunId
    }
} else {
    Write-Step "Using run id $resolvedRunId"
    if (-not $UseLatest) {
        # Specific id: still wait if it might be in progress
        $view = & gh run view $resolvedRunId --json status,conclusion 2>$null | ConvertFrom-Json
        if ($view -and $view.status -ne 'completed') {
            Wait-ForIpaRun $resolvedRunId
        } elseif ($view -and $view.conclusion -ne 'success') {
            throw "Run $resolvedRunId conclusion=$($view.conclusion) (need success)"
        }
    }
}

Download-IpaArtifact $resolvedRunId

$local = Get-Item -LiteralPath $LocalIpa
$mb = [math]::Round($local.Length / 1MB, 2)
Write-Host ''
Write-Host "Local IPA: $($local.FullName) ($mb MB)"
Write-Host "Actions:   https://github.com/dsouzaankit/ios_3d_loop_segments/actions/runs/$resolvedRunId"

if ($SkipICloud) {
    Write-Host 'Skipped iCloud copy (-SkipICloud).'
    Write-Host 'Re-paste later: .\copy-to-icloud.ps1'
    exit 0
}

Write-Step 'Pasting IPA to iCloud (copy-to-icloud)'
& (Join-Path $ProjectRoot 'copy-to-icloud.ps1') -SourceIpa $LocalIpa
