#Requires -Version 7.0
# Dot-sourced by run_chromium.ps1. Console transcript + rest.log archive retention
# under windows\pcloud_web_companion\logs\ (gitignored).

function Get-CompanionLogsDirectory {
    param([Parameter(Mandatory = $true)][string] $CompanionRoot)
    Join-Path $CompanionRoot 'logs'
}

function Get-CompanionLogRetentionPolicy {
    # Keep the last N companion runs (console transcript + rest.log archive each).
    [ordered]@{
        TranscriptMaxFiles   = 5
        RestArchiveMaxFiles  = 5
        LogsFolderMaxBytes   = 100MB  # soft cap; oldest matching files deleted first
    }
}

function Invoke-CompanionLogRetention {
    param(
        [Parameter(Mandatory = $true)][string] $LogsDir,
        [hashtable] $Policy = (Get-CompanionLogRetentionPolicy)
    )
    if (-not (Test-Path -LiteralPath $LogsDir)) { return }

    $groups = @(
        @{ Pattern = 'companion-console-*.log'; MaxFiles = [int]$Policy.TranscriptMaxFiles }
        @{ Pattern = 'rest-*.log';              MaxFiles = [int]$Policy.RestArchiveMaxFiles }
    )

    $removed = 0
    foreach ($g in $groups) {
        $files = @(Get-ChildItem -LiteralPath $LogsDir -Filter $g.Pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
        if ($files.Count -gt $g.MaxFiles) {
            foreach ($f in $files[$g.MaxFiles..($files.Count - 1)]) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $removed++
                } catch {}
            }
        }
    }

    # Soft size cap across both patterns (oldest first).
    $maxBytes = [long]$Policy.LogsFolderMaxBytes
    if ($maxBytes -gt 0) {
        $all = @(Get-ChildItem -LiteralPath $LogsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'companion-console-*.log' -or $_.Name -like 'rest-*.log' } |
            Sort-Object LastWriteTimeUtc)
        # StrictMode-safe: do not use Measure-Object.Sum (missing/null Sum throws).
        $total = 0L
        foreach ($f in $all) {
            $total += [long]$f.Length
        }
        $i = 0
        while ($total -gt $maxBytes -and $i -lt $all.Count) {
            $f = $all[$i]
            $i++
            try {
                $len = [long]$f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $total -= $len
                $removed++
            } catch {}
        }
    }

    if ($removed -gt 0) {
        Write-Host "[logs] Retention removed $removed old file(s) under $LogsDir (keep last $($Policy.TranscriptMaxFiles) runs)"
    }
}

function Initialize-CompanionRestLogArchive {
    <#
      Rotate live rest.log into logs\rest-YYYYMMDD-HHmmss.log, then truncate rest.log.
      Call on fresh companion start (not mid-session sink revive).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $RestLogPath,
        [Parameter(Mandatory = $true)][string] $CompanionRoot,
        [hashtable] $Policy = (Get-CompanionLogRetentionPolicy)
    )
    $LogsDir = Get-CompanionLogsDirectory -CompanionRoot $CompanionRoot
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    Invoke-CompanionLogRetention -LogsDir $LogsDir -Policy $Policy

    if ((Test-Path -LiteralPath $RestLogPath) -and ((Get-Item -LiteralPath $RestLogPath).Length -gt 0)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dest = Join-Path $LogsDir ("rest-{0}.log" -f $stamp)
        try {
            Move-Item -LiteralPath $RestLogPath -Destination $dest -Force
            Write-Host "[rest-log] Archived previous -> $dest"
        } catch {
            try {
                Copy-Item -LiteralPath $RestLogPath -Destination $dest -Force
                Write-Host "[rest-log] Copied previous -> $dest (move failed: $($_.Exception.Message))"
            } catch {
                Write-Warning "[rest-log] Could not archive previous rest.log: $($_.Exception.Message)"
            }
        }
    }

    Set-Content -LiteralPath $RestLogPath -Value "" -Encoding utf8
    Write-Host "[rest-log] Cleared $RestLogPath"
}

function Start-CompanionConsoleTranscript {
    param(
        [Parameter(Mandatory = $true)][string] $CompanionRoot,
        [hashtable] $Policy = (Get-CompanionLogRetentionPolicy),
        [switch] $Skip
    )
    if ($Skip) {
        Write-Host '[logs] Console transcript skipped (-NoTranscript)'
        return $null
    }

    $LogsDir = Get-CompanionLogsDirectory -CompanionRoot $CompanionRoot
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    Invoke-CompanionLogRetention -LogsDir $LogsDir -Policy $Policy

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $LogsDir ("companion-console-{0}.log" -f $stamp)
    $script:CompanionTranscriptPath = $path
    try {
        Start-Transcript -Path $path -Append -IncludeInvocationHeader | Out-Null
        $script:CompanionTranscriptActive = $true
        Write-Host "[logs] Console transcript -> $path"
        Write-Host ("[logs] Retention: last {0} console + last {1} rest archives; folder cap {2:N0} MB" -f `
            $Policy.TranscriptMaxFiles, $Policy.RestArchiveMaxFiles, `
            ([double]$Policy.LogsFolderMaxBytes / 1MB))
        return $path
    } catch {
        $script:CompanionTranscriptActive = $false
        Write-Warning "[logs] Start-Transcript failed: $($_.Exception.Message)"
        return $null
    }
}

function Stop-CompanionConsoleTranscript {
    if (-not $script:CompanionTranscriptActive) { return }
    try {
        Stop-Transcript | Out-Null
        Write-Host ("[logs] Console transcript stopped ({0})" -f $script:CompanionTranscriptPath)
    } catch {
        # Already stopped / host without transcript
    } finally {
        $script:CompanionTranscriptActive = $false
    }
}
