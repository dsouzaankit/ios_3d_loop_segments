#Requires -Version 7.0
# Shared Chromium profile sync for run_chromium.ps1 and _profile_exit_watchdog.ps1.
# Canonical copy on P: is one zip (cookies/login). Cache stays off pCloud.

function Get-ChromiumProfileExcludeDirNames {
    @(
        'Cache'
        'Code Cache'
        'GPUCache'
        'GPUPersistentCache'
        'ShaderCache'
        'GrShaderCache'
        'DawnGraphiteCache'
        'Safe Browsing'
        'Safe Browsing Network'
        'component_crx_cache'
        'Crashpad'
        'Crash Reports'
        'BrowserMetrics'
        'Service Worker'
        'File System'
        'optimization_guide_hint_cache_store'
        'ScreenCaptureKit'
        'Sessions'
        'Media Cache'
        'Shared Dictionary'
    )
}

function Get-ChromiumProfileExcludeFileNames {
    @(
        'SingletonLock'
        'SingletonCookie'
        'SingletonSocket'
        'lockfile'
        'DevToolsActivePort'
        'BrowserMetrics-spare.pma'
        'History'
        'History-journal'
        'Archived History'
        'Archived History-journal'
        'DownloadMetadata'
        'Current Session'
        'Current Tabs'
        'Last Session'
        'Last Tabs'
    )
}

function Get-ChromiumProfileTarExe {
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw 'tar.exe not found (needed to zip the Chromium profile)'
    }
    return $tar.Source
}

function Get-ChromiumProfileTarExcludeArgs {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (Get-ChromiumProfileExcludeDirNames)) {
        [void]$list.Add("--exclude=$name")
    }
    foreach ($name in (Get-ChromiumProfileExcludeFileNames)) {
        [void]$list.Add("--exclude=$name")
    }
    return @($list)
}

function Clear-ChromiumProfileDir {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        return
    }
    Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

function Copy-ChromiumProfileZipFile {
    param([string]$Src, [string]$Dst)
    $parent = Split-Path -Parent $Dst
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $partial = "$Dst.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $Src -Destination $partial -Force
    if (-not (Test-Path -LiteralPath $partial)) {
        throw "zip copy failed: $Src -> $partial"
    }
    $srcLen = (Get-Item -LiteralPath $Src).Length
    $dstLen = (Get-Item -LiteralPath $partial).Length
    if ($dstLen -ne $srcLen) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "zip copy size mismatch ($dstLen vs $srcLen)"
    }
    if (Test-Path -LiteralPath $Dst) {
        Remove-Item -LiteralPath $Dst -Force
    }
    Move-Item -LiteralPath $partial -Destination $Dst -Force
}

function New-ChromiumProfileZip {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )
    $tar = Get-ChromiumProfileTarExe
    $stage = Join-Path $env:TEMP ("loop-segments-chromium-profile-{0}.zip" -f [guid]::NewGuid().ToString('n'))
    Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
    $exclude = Get-ChromiumProfileTarExcludeArgs
    & $tar -a -c -f $stage @exclude -C $ProfileDir .
    $code = $LASTEXITCODE
    # bsdtar 1 = some files skipped (locks); 2+ = fatal.
    if ($code -ge 2 -or -not (Test-Path -LiteralPath $stage)) {
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        throw "tar zip failed (exit $code)"
    }
    if ($code -eq 1) {
        Write-Warning "[profile] tar skipped some locked files (exit 1); zip kept"
    }
    $len = (Get-Item -LiteralPath $stage).Length
    if ($len -lt 256) {
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        throw "profile zip too small ($len bytes)"
    }
    Copy-ChromiumProfileZipFile -Src $stage -Dst $ZipPath
    Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
    return $len
}

function Expand-ChromiumProfileZip {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestDir
    )
    $tar = Get-ChromiumProfileTarExe
    Clear-ChromiumProfileDir -Dir $DestDir
    & $tar -x -f $ZipPath -C $DestDir
    $code = $LASTEXITCODE
    if ($code -ge 2) {
        throw "tar extract failed (exit $code)"
    }
}

function Start-LegacyUnpackedProfileCleanup {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) {
        return
    }
    Write-Host "[profile] Removing legacy unpacked folder in the background: $Dir"
    try {
        Start-Process -FilePath "$env:WINDIR\System32\cmd.exe" -ArgumentList @(
            '/c', "rmdir /s /q `"$Dir`""
        ) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "[profile] Could not start legacy folder cleanup: $($_.Exception.Message)"
    }
}

function Sync-LoopSegmentsChromiumProfile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Download', 'Upload')]
        [string]$Direction,
        [Parameter(Mandatory = $true)][string]$LocalProfileDir,
        [Parameter(Mandatory = $true)][string]$RepoProfileDir,
        [string]$RepoProfileZip,
        [switch]$Skip
    )

    if ($Skip) {
        Write-Host "[profile] Sync skipped (-SkipProfileSync)"
        return
    }
    if ([string]::IsNullOrWhiteSpace($RepoProfileZip)) {
        $RepoProfileZip = Join-Path (Split-Path -Parent $RepoProfileDir) 'chromium-profile.zip'
    }

    $localStageZip = Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\chromium-profile.zip'

    if ($Direction -eq 'Upload') {
        if (-not (Test-Path -LiteralPath (Join-Path $LocalProfileDir 'Default'))) {
            Write-Host "[profile] Upload skip (no local Default/)"
            return
        }
        Write-Host "[profile] Upload zip (cache excluded): $LocalProfileDir -> $RepoProfileZip"
        try {
            $len = New-ChromiumProfileZip -ProfileDir $LocalProfileDir -ZipPath $localStageZip
            Copy-ChromiumProfileZipFile -Src $localStageZip -Dst $RepoProfileZip
            Write-Host ("[profile] Upload OK ({0:N1} MB)" -f ($len / 1MB))
            Start-LegacyUnpackedProfileCleanup -Dir $RepoProfileDir
        } catch {
            Write-Warning "[profile] Upload zip failed: $($_.Exception.Message)"
        }
        return
    }

    # Download
    if (Test-Path -LiteralPath $RepoProfileZip) {
        $mb = (Get-Item -LiteralPath $RepoProfileZip).Length / 1MB
        Write-Host ("[profile] Download zip ({0:N1} MB): $RepoProfileZip" -f $mb)
        try {
            Copy-ChromiumProfileZipFile -Src $RepoProfileZip -Dst $localStageZip
            Expand-ChromiumProfileZip -ZipPath $localStageZip -DestDir $LocalProfileDir
            Write-Host "[profile] Download OK (extracted locally)"
        } catch {
            Write-Warning "[profile] Download zip failed: $($_.Exception.Message)"
        }
        return
    }

    if (-not (Test-Path -LiteralPath $RepoProfileDir)) {
        Write-Host "[profile] Download skip (no zip and no legacy folder)"
        return
    }

    Write-Host "[profile] Download legacy folder (cache dirs skipped): $RepoProfileDir -> $LocalProfileDir"
    Clear-ChromiumProfileDir -Dir $LocalProfileDir
    $xd = @(Get-ChromiumProfileExcludeDirNames)
    $xf = @(Get-ChromiumProfileExcludeFileNames)
    $robocopyArgs = @(
        $RepoProfileDir
        $LocalProfileDir
        '/E'
        '/R:2'
        '/W:1'
        '/NFL'
        '/NDL'
        '/NJH'
        '/NJS'
        '/NC'
        '/NS'
        '/XD'
    ) + $xd + @('/XF') + $xf
    & robocopy.exe @robocopyArgs | Out-Null
    $rc = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($rc -ge 8) {
        Write-Warning "[profile] Legacy robocopy exit $rc"
    } else {
        Write-Host "[profile] Legacy download OK (robocopy=$rc)"
    }
}
