#Requires -Version 5.1
<#
.SYNOPSIS
  Locate / quit / start Virtual Desktop Streamer and restart Virtual Desktop Service.

.DESCRIPTION
  Dot-source from pcloud_web_companion\run_chromium.ps1.
  Companion restarts Streamer (quit if already running) and attempts to restart
  the Windows service. Missing install only warns. Service restart may need
  elevation; Streamer launch often starts the service itself.
#>

$script:LoopSegmentsVdStreamerProcessNames = @(
    'VirtualDesktop.Streamer'
    'VirtualDesktopStreamer'
    'VDStreamer'
)

$script:LoopSegmentsVdStreamerExeNames = @(
    'VirtualDesktop.Streamer.exe'
    'VirtualDesktopStreamer.exe'
)

function Get-LoopSegmentsVdStreamerConfiguredExe {
    $envPath = [string]$env:LOOP_SEGMENTS_VD_STREAMER_EXE
    if (-not [string]::IsNullOrWhiteSpace($envPath) -and (Test-Path -LiteralPath $envPath.Trim() -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($envPath.Trim())
    }
    $jsonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'loop-segments-windows.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $p = [string]$obj.virtualDesktopStreamerExe
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p.Trim() -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($p.Trim())
        }
    } catch {}
    return $null
}

function Get-LoopSegmentsVdStreamerPath {
    $configured = Get-LoopSegmentsVdStreamerConfiguredExe
    if ($configured) { return $configured }

    $dirs = [System.Collections.Generic.List[string]]::new()
    foreach ($c in @(
            (Join-Path $env:ProgramFiles 'Virtual Desktop Streamer')
            (Join-Path ${env:ProgramFiles(x86)} 'Virtual Desktop Streamer')
            (Join-Path $env:ProgramFiles 'Virtual Desktop')
            (Join-Path ${env:ProgramFiles(x86)} 'Virtual Desktop')
            (Join-Path $env:LOCALAPPDATA 'Virtual Desktop Streamer')
        )) {
        if ($c -and (Test-Path -LiteralPath $c)) { [void]$dirs.Add($c) }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        try {
            Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.DisplayName -match 'Virtual Desktop Streamer' } |
                ForEach-Object {
                    $loc = [string]$_.InstallLocation
                    if ($loc -and (Test-Path -LiteralPath $loc) -and -not ($dirs -contains $loc)) {
                        [void]$dirs.Add($loc)
                    }
                }
        } catch {}
    }

    foreach ($dir in $dirs) {
        foreach ($exe in $script:LoopSegmentsVdStreamerExeNames) {
            $p = Join-Path $dir $exe
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
    }

    $menuRoots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($root in $menuRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $lnk = Get-ChildItem -LiteralPath $root -Filter '*Virtual Desktop Streamer*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $lnk) { continue }
        try {
            $w = New-Object -ComObject WScript.Shell
            $tgt = [string]$w.CreateShortcut($lnk.FullName).TargetPath
            if ($tgt -and (Test-Path -LiteralPath $tgt -PathType Leaf)) { return $tgt }
        } catch {}
    }
    return $null
}

function Get-LoopSegmentsVdStreamerPids {
    $ids = [System.Collections.Generic.List[int]]::new()
    foreach ($n in $script:LoopSegmentsVdStreamerProcessNames) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not ($ids -contains $_.Id)) { [void]$ids.Add([int]$_.Id) }
        }
    }
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '(?i)VirtualDesktop.*Streamer'
    } | ForEach-Object {
        if (-not ($ids -contains $_.Id)) { [void]$ids.Add([int]$_.Id) }
    }
    return , @($ids.ToArray())
}

function Test-LoopSegmentsVdStreamerRunning {
    return (@(Get-LoopSegmentsVdStreamerPids).Count -gt 0)
}

function Get-LoopSegmentsVdServices {
    @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -eq 'Virtual Desktop Service' -or
            $_.Name -eq 'Virtual Desktop Service' -or
            $_.Name -match '(?i)^VirtualDesktop(\.Service)?$' -or
            $_.DisplayName -match '(?i)^Virtual Desktop Service$'
        })
}

function Stop-LoopSegmentsVdStreamer {
    $pids = @(Get-LoopSegmentsVdStreamerPids)
    if ($pids.Count -eq 0) { return 0 }
    Write-Host ("[vd] Quitting Virtual Desktop Streamer (PID {0})..." -f ($pids -join ', '))
    foreach ($id in $pids) {
        try {
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p) {
                $p.CloseMainWindow() | Out-Null
            }
        } catch {}
    }
    Start-Sleep -Seconds 2
    foreach ($id in @(Get-LoopSegmentsVdStreamerPids)) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 400
    return $pids.Count
}

function Restart-LoopSegmentsVdService {
    $svcs = @(Get-LoopSegmentsVdServices)
    if ($svcs.Count -eq 0) {
        Write-Host '[vd] Virtual Desktop Service not found (not installed, or name differs).'
        return $false
    }
    $ok = $true
    foreach ($svc in $svcs) {
        Write-Host ("[vd] Restarting service {0} ({1})..." -f $svc.DisplayName, $svc.Name)
        try {
            Restart-Service -InputObject $svc -Force -ErrorAction Stop
            Write-Host ("[vd] Service {0} is {1}." -f $svc.Name, (Get-Service -Name $svc.Name).Status)
        } catch {
            Write-Warning ("[vd] Could not restart {0}: {1} (Streamer start may start the service; elevation may be required.)" -f $svc.Name, $_.Exception.Message)
            $ok = $false
        }
    }
    return $ok
}

function Start-LoopSegmentsVdStreamer {
    param([int] $WaitSeconds = 3)
    $path = Get-LoopSegmentsVdStreamerPath
    if (-not $path) {
        Write-Warning '[vd] Virtual Desktop Streamer not found. Install it, or set virtualDesktopStreamerExe in loop-segments-windows.json / LOOP_SEGMENTS_VD_STREAMER_EXE.'
        return $false
    }
    Write-Host ("[vd] Starting Virtual Desktop Streamer: {0}" -f $path)
    try {
        Start-Process -FilePath $path | Out-Null
    } catch {
        Write-Warning ("[vd] Start failed: {0}" -f $_.Exception.Message)
        return $false
    }
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $WaitSeconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-LoopSegmentsVdStreamerRunning) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return (Test-LoopSegmentsVdStreamerRunning)
}

function Restart-LoopSegmentsVirtualDesktop {
    param([int] $WaitSeconds = 3)
    $path = Get-LoopSegmentsVdStreamerPath
    $svcs = @(Get-LoopSegmentsVdServices)
    if (-not $path -and $svcs.Count -eq 0) {
        Write-Warning '[vd] Virtual Desktop Streamer / Service not found - skip.'
        return $false
    }
    [void](Stop-LoopSegmentsVdStreamer)
    [void](Restart-LoopSegmentsVdService)
    if (-not $path) {
        Write-Warning '[vd] Service restart attempted; Streamer exe not found so it was not relaunched.'
        return ($svcs.Count -gt 0)
    }
    $started = Start-LoopSegmentsVdStreamer -WaitSeconds $WaitSeconds
    if ($started) {
        Write-Host '[vd] Virtual Desktop Streamer is running.'
    } else {
        Write-Warning '[vd] Streamer did not appear after start (check the Virtual Desktop window / tray).'
    }
    return $started
}

function Write-LoopSegmentsVirtualDesktopNotice {
    param([switch] $EnsureRestarted)
    $path = Get-LoopSegmentsVdStreamerPath
    $running = Test-LoopSegmentsVdStreamerRunning
    $svcs = @(Get-LoopSegmentsVdServices)
    Write-Host ('[vd] Streamer: {0}' -f $(if ($path) { $path } else { '(not found)' }))
    Write-Host ('[vd] Streamer running: {0}' -f $running)
    if ($svcs.Count -eq 0) {
        Write-Host '[vd] Service: (not found)'
    } else {
        foreach ($s in $svcs) {
            Write-Host ('[vd] Service: {0} ({1}) {2}' -f $s.DisplayName, $s.Name, $s.Status)
        }
    }
    if ($EnsureRestarted) {
        return (Restart-LoopSegmentsVirtualDesktop)
    }
    return $true
}
