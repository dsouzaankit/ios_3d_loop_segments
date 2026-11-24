#Requires -Version 7.0
# Shared Chromium profile sync for _run_chromium.ps1 and _profile_exit_watchdog.ps1.
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
        'DawnWebGPUCache'
        'AutofillAiModelCache'
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
        'LOCK'
    )
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

function Test-ChromiumProfileRelativeExcluded {
    param([string]$RelativePath)
    $parts = @($RelativePath -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })
    if ($parts.Count -eq 0) { return $true }
    $dirNames = Get-ChromiumProfileExcludeDirNames
    $fileNames = Get-ChromiumProfileExcludeFileNames
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = $parts[$i]
        foreach ($d in $dirNames) {
            if ([string]::Equals($part, $d, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        if ($i -eq ($parts.Count - 1)) {
            foreach ($f in $fileNames) {
                if ([string]::Equals($part, $f, [StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
        }
    }
    return $false
}

function New-ChromiumProfileZip {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [System.IO.Path]::GetFullPath($ProfileDir).TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Default'))) {
        throw "profile zip: no Default/ under $root"
    }
    $stage = Join-Path $env:TEMP ("loop-segments-chromium-profile-{0}.zip" -f [guid]::NewGuid().ToString('n'))
    Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue

    $count = 0
    $hasPrefs = $false
    $hasCookies = $false
    $fs = [System.IO.File]::Open($stage, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($full in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
                $rel = $full.Substring($root.Length).TrimStart('\')
                if (Test-ChromiumProfileRelativeExcluded -RelativePath $rel) { continue }
                $entryName = $rel.Replace('\', '/')
                try {
                    $src = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                } catch {
                    Write-Warning "[profile] skip locked $rel"
                    continue
                }
                try {
                    $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Fastest)
                    $es = $entry.Open()
                    try {
                        $src.CopyTo($es)
                    } finally {
                        $es.Dispose()
                    }
                } catch {
                    Write-Warning "[profile] skip unreadable $rel"
                    continue
                } finally {
                    $src.Dispose()
                }
                $count++
                if ($entryName -eq 'Default/Preferences') { $hasPrefs = $true }
                if ($entryName -eq 'Default/Network/Cookies') { $hasCookies = $true }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $fs.Dispose()
    }

    $len = 0
    if (Test-Path -LiteralPath $stage) {
        $len = (Get-Item -LiteralPath $stage).Length
    }
    if ($count -lt 10 -or -not $hasPrefs -or $len -lt 1024) {
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        throw "profile zip missing login files (entries=$count prefs=$hasPrefs cookies=$hasCookies size=$len)"
    }
    if (-not $hasCookies) {
        Write-Warning "[profile] zip has Preferences but no Default/Network/Cookies"
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
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Clear-ChromiumProfileDir -Dir $DestDir
    # Old companion zips used tar.exe (entries named ./Default/...). New zips use
    # System.IO.Compression (Default/...). tar extract handles both; ZipFile does not.
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -x -f $ZipPath -C $DestDir
        $code = $LASTEXITCODE
        if ($code -ge 2) {
            throw "tar extract failed (exit $code)"
        }
        return
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
}

# pCloud Drive has served this zip with another file's bytes in it (a PowerShell transcript that
# was being appended on P:, then zeros), so a zip is checked before it replaces the local profile
# and after it is written to P:.
function Test-ChromiumProfileZip {
    param([string]$ZipPath)
    $r = [pscustomobject]@{ Ok = $false; Reason = ''; Entries = 0; HasLogin = $false }
    if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { $r.Reason = 'missing'; return $r }
    $len = (Get-Item -LiteralPath $ZipPath).Length
    if ($len -lt 1024) { $r.Reason = "too small ($len bytes)"; return $r }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        # tar.exe-era zips name entries ./Default/...
        $names = @($zip.Entries | ForEach-Object { $_.FullName -replace '^\./', '' })
        $r.Entries = $names.Count
        $r.HasLogin = $names -contains 'Default/Login Data'
        if ($names -notcontains 'Default/Preferences') { $r.Reason = "no Default/Preferences ($($names.Count) entries)"; return $r }
        if ($names.Count -lt 10) { $r.Reason = "only $($names.Count) entries"; return $r }
        $r.Ok = $true
    } catch {
        $r.Reason = "not a readable zip ($($_.Exception.Message))"
    } finally {
        if ($zip) { $zip.Dispose() }
    }
    return $r
}

# Whether this run's Download restored a profile, read by its Upload (same process or the exit
# watchdog): a run that started from an empty profile because every copy was bad must not
# overwrite a copy that reads fine again, nor the backups.
function Get-ChromiumProfileRestoreStatePath { Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\profile-restore.json' }

function Set-ChromiumProfileRestoreState {
    param([bool]$Ok, [string]$Source)
    try {
        $p = Get-ChromiumProfileRestoreStatePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        [ordered]@{ ok = $Ok; source = $Source; atUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $p -Encoding utf8
    } catch {}
}

function Get-ChromiumProfileRestoreState {
    $p = Get-ChromiumProfileRestoreStatePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

# Last good upload, also kept on this PC (outside the local profile the companion clears at exit).
function Get-ChromiumProfileLocalBackupZip { Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\profile-backup\chromium-profile.zip' }

function Get-ChromiumProfilePrevZip {
    param([string]$RepoProfileZip)
    return ($RepoProfileZip -replace '(?i)\.zip$', '.prev.zip')
}

# Copy to P: and read it back: same hash as the local zip and a valid zip, else one more try.
function Copy-ChromiumProfileZipVerified {
    param([string]$Src, [string]$Dst)
    $want = (Get-FileHash -LiteralPath $Src -Algorithm SHA256).Hash
    for ($try = 1; $try -le 2; $try++) {
        try {
            Copy-ChromiumProfileZipFile -Src $Src -Dst $Dst
            $got = (Get-FileHash -LiteralPath $Dst -Algorithm SHA256).Hash
            $t = Test-ChromiumProfileZip -ZipPath $Dst
            if ($got -eq $want -and $t.Ok) { return $true }
            Write-Warning "[profile] $Dst did not read back intact (try $try): $(if ($got -ne $want) { 'hash differs' } else { $t.Reason })"
        } catch {
            Write-Warning "[profile] Copy to $Dst failed (try $try): $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 2
    }
    return $false
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
        $prevZip = Get-ChromiumProfilePrevZip -RepoProfileZip $RepoProfileZip
        $backupZip = Get-ChromiumProfileLocalBackupZip
        $state = Get-ChromiumProfileRestoreState
        $restoreFailed = $state -and ($state.ok -eq $false)
        try {
            $len = New-ChromiumProfileZip -ProfileDir $LocalProfileDir -ZipPath $localStageZip
            $current = Test-ChromiumProfileZip -ZipPath $RepoProfileZip
            if ($restoreFailed) {
                # This run started from an empty profile: never replace a copy that reads fine now
                # (the bad read may have been pCloud's), and never touch the backups.
                if ($current.Ok) {
                    Write-Warning "[profile] Upload skipped: this run started without a restored profile and $RepoProfileZip reads fine now (kept as is)"
                    return
                }
                Write-Warning "[profile] This run started without a restored profile: writing $RepoProfileZip only (previous zip and local backup kept)"
                if (Copy-ChromiumProfileZipVerified -Src $localStageZip -Dst $RepoProfileZip) { Write-Host ("[profile] Upload OK ({0:N1} MB)" -f ($len / 1MB)) }
                return
            }
            # Keep the copy being replaced as the previous zip, if it is a good one.
            if ($current.Ok) {
                try { Copy-ChromiumProfileZipFile -Src $RepoProfileZip -Dst $prevZip } catch { Write-Warning "[profile] Could not keep previous zip: $($_.Exception.Message)" }
            }
            try { Copy-ChromiumProfileZipFile -Src $localStageZip -Dst $backupZip } catch { Write-Warning "[profile] Could not write local backup: $($_.Exception.Message)" }
            if (Copy-ChromiumProfileZipVerified -Src $localStageZip -Dst $RepoProfileZip) {
                Write-Host ("[profile] Upload OK ({0:N1} MB, verified; previous zip {1}, local backup {2})" -f ($len / 1MB), $(if ($current.Ok) { 'kept' } else { 'unchanged' }), $backupZip)
                Start-LegacyUnpackedProfileCleanup -Dir $RepoProfileDir
            } else {
                Write-Warning "[profile] Upload did not verify on P:; the next start falls back to the previous zip or $backupZip"
            }
        } catch {
            Write-Warning "[profile] Upload zip failed: $($_.Exception.Message)"
        }
        return
    }

    # Download: the P: zip, else the previous one on P:, else this PC's backup; each is checked
    # before the local profile is cleared for it.
    $candidates = @(
        [pscustomobject]@{ Name = 'P: zip'; Path = $RepoProfileZip }
        [pscustomobject]@{ Name = 'P: previous zip'; Path = (Get-ChromiumProfilePrevZip -RepoProfileZip $RepoProfileZip) }
        [pscustomobject]@{ Name = 'local backup'; Path = (Get-ChromiumProfileLocalBackupZip) }
    )
    $seen = 0
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Path -PathType Leaf)) { continue }
        $seen++
        $mb = (Get-Item -LiteralPath $c.Path).Length / 1MB
        Write-Host ("[profile] Download {0} ({1:N1} MB): {2}" -f $c.Name, $mb, $c.Path)
        try {
            Copy-ChromiumProfileZipFile -Src $c.Path -Dst $localStageZip
            $t = Test-ChromiumProfileZip -ZipPath $localStageZip
            if (-not $t.Ok) { Write-Warning "[profile] $($c.Name) is not a usable profile zip: $($t.Reason)"; continue }
            Expand-ChromiumProfileZip -ZipPath $localStageZip -DestDir $LocalProfileDir
            if (-not (Test-Path -LiteralPath (Join-Path $LocalProfileDir 'Default\Preferences'))) { Write-Warning "[profile] $($c.Name) extracted without Default\Preferences"; continue }
            Write-Host ("[profile] Download OK from {0} ({1} entries{2})" -f $c.Name, $t.Entries, $(if ($t.HasLogin) { '' } else { ', no saved passwords in it' }))
            Set-ChromiumProfileRestoreState -Ok $true -Source $c.Name
            return
        } catch {
            Write-Warning "[profile] Download $($c.Name) failed: $($_.Exception.Message)"
        }
    }
    if ($seen -gt 0) {
        Write-Warning "[profile] No usable profile zip (P: zip, previous zip, local backup): starting with an EMPTY profile (saved logins missing this run). Restore chromium-profile.zip from pCloud's file history."
        Clear-ChromiumProfileDir -Dir $LocalProfileDir
        Set-ChromiumProfileRestoreState -Ok $false -Source 'none usable'
        return
    }

    if (-not (Test-Path -LiteralPath $RepoProfileDir)) {
        Write-Host "[profile] Download skip (no zip and no legacy folder)"
        Set-ChromiumProfileRestoreState -Ok $true -Source 'first run'
        return
    }
    Set-ChromiumProfileRestoreState -Ok $true -Source 'legacy folder'

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
