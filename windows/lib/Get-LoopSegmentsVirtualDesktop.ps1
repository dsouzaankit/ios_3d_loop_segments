#Requires -Version 5.1
<#
.SYNOPSIS
  Locate / start Virtual Desktop Streamer and hide its window to the tray.

.DESCRIPTION
  Dot-source from pcloud_web_companion\run_chromium.ps1.
  Companion starts Streamer if idle (starts the Windows service if it is stopped)
  and hides the Streamer window to the tray. Does not quit Streamer if it is
  already running, and does not quit it on companion finish. Missing install
  only warns. Starting the service may need elevation; Streamer launch often
  starts the service itself.
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

function Get-LoopSegmentsVdWinCSharp {
    @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class LoopSegmentsVdWin {
    public const int SW_HIDE = 0;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder lp, int n);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    static string Cls(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static bool IsTrayOrImeHelper(IntPtr h) {
        string c = Cls(h);
        if (c.Equals("IME", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.Equals("MSCTFIME UI", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.IndexOf("NotifyIcon", StringComparison.OrdinalIgnoreCase) >= 0) return true;
        if (c.Equals("Electron_NotifyIconHostWindow", StringComparison.OrdinalIgnoreCase)) return true;
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0 && (ex & WS_EX_NOACTIVATE) != 0) return true;
        return false;
    }

    public static int HidePids(uint[] pids) {
        if (pids == null || pids.Length == 0) return 0;
        var set = new HashSet<uint>(pids);
        int n = 0;
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!set.Contains(pid)) return true;
            if (IsTrayOrImeHelper(h)) return true;
            if (!IsWindowVisible(h)) return true;
            ShowWindow(h, SW_HIDE);
            n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }
}
'@
}

function Initialize-LoopSegmentsVdNative {
    if ("LoopSegmentsVdWin" -as [type]) { return }
    Add-Type -TypeDefinition (Get-LoopSegmentsVdWinCSharp)
}

function Minimize-LoopSegmentsVdStreamerWindows {
    try { Initialize-LoopSegmentsVdNative } catch { return 0 }
    $pids = @(Get-LoopSegmentsVdStreamerPids)
    if ($pids.Count -eq 0) { return 0 }
    $uints = [uint32[]]@($pids | ForEach-Object { [uint32]$_ })
    try {
        return [int][LoopSegmentsVdWin]::HidePids($uints)
    } catch {
        return 0
    }
}

function Start-LoopSegmentsVdMinimizeWatch {
    param([int] $Seconds = 30)
    $names = @($script:LoopSegmentsVdStreamerProcessNames)
    $csharp = Get-LoopSegmentsVdWinCSharp
    Get-Job -Name 'LoopSegmentsVdMinimize' -ErrorAction SilentlyContinue |
        Stop-Job -PassThru -ErrorAction SilentlyContinue |
        Remove-Job -Force -ErrorAction SilentlyContinue | Out-Null
    $block = {
        param([string[]] $ProcNames, [int] $Sec, [string] $TypeDef)
        if (-not ("LoopSegmentsVdWin" -as [type])) {
            Add-Type -TypeDefinition $TypeDef
        }
        $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(3, $Sec))
        while ([datetime]::UtcNow -lt $deadline) {
            $ids = New-Object System.Collections.Generic.List[uint32]
            foreach ($n in $ProcNames) {
                foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                    [void]$ids.Add([uint32]$p.Id)
                }
            }
            foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                        $_.ProcessName -match '(?i)VirtualDesktop.*Streamer'
                    })) {
                [void]$ids.Add([uint32]$p.Id)
            }
            if ($ids.Count -gt 0) {
                [void][LoopSegmentsVdWin]::HidePids(@($ids.ToArray()))
            }
            Start-Sleep -Milliseconds 700
        }
    }
    try {
        if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
            [void](Start-ThreadJob -Name 'LoopSegmentsVdMinimize' -ScriptBlock $block -ArgumentList @(, $names), $Seconds, $csharp)
        } else {
            [void](Start-Job -Name 'LoopSegmentsVdMinimize' -ScriptBlock $block -ArgumentList @(, $names), $Seconds, $csharp)
        }
    } catch {
        Write-Warning "[vd] Tray hide watch not started: $($_.Exception.Message)"
    }
}

function Hide-LoopSegmentsVdStreamerToTray {
    param(
        [int] $WaitWindowSeconds = 3,
        [int] $WatchSeconds = 30
    )
    if (-not (Test-LoopSegmentsVdStreamerRunning)) { return 0 }
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $WaitWindowSeconds))
    $hidden = 0
    while ([datetime]::UtcNow -lt $deadline) {
        $hidden = Minimize-LoopSegmentsVdStreamerWindows
        if ($hidden -gt 0) { break }
        Start-Sleep -Milliseconds 400
    }
    Start-LoopSegmentsVdMinimizeWatch -Seconds $WatchSeconds
    return $hidden
}

function Start-LoopSegmentsVdDetachedProcess {
    param([Parameter(Mandatory = $true)][string] $FilePath)
    if (Get-Command Start-LoopSegmentsDetachedProcess -ErrorAction SilentlyContinue) {
        Start-LoopSegmentsDetachedProcess -FilePath $FilePath
        return
    }
    $cmdArgs = '/c start "" "' + $FilePath + '"'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
    $psi.Arguments = $cmdArgs
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
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

function Start-LoopSegmentsVdServiceIfNeeded {
    $svcs = @(Get-LoopSegmentsVdServices)
    if ($svcs.Count -eq 0) { return $false }
    $ok = $true
    foreach ($svc in $svcs) {
        if ($svc.Status -eq 'Running') {
            Write-Host ("[vd] Service {0} already running." -f $svc.Name)
            continue
        }
        Write-Host ("[vd] Starting service {0} ({1})..." -f $svc.DisplayName, $svc.Name)
        try {
            Start-Service -InputObject $svc -ErrorAction Stop
            Write-Host ("[vd] Service {0} is {1}." -f $svc.Name, (Get-Service -Name $svc.Name).Status)
        } catch {
            Write-Warning ("[vd] Could not start {0}: {1} (Streamer start may start the service; elevation may be required.)" -f $svc.Name, $_.Exception.Message)
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
    Write-Host ("[vd] Starting Virtual Desktop Streamer (hide to tray): {0}" -f $path)
    try {
        Start-LoopSegmentsVdDetachedProcess -FilePath $path
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

function Ensure-LoopSegmentsVirtualDesktop {
    param([int] $WaitSeconds = 3)
    $path = Get-LoopSegmentsVdStreamerPath
    $svcs = @(Get-LoopSegmentsVdServices)
    if (-not $path -and $svcs.Count -eq 0) {
        Write-Warning '[vd] Virtual Desktop Streamer / Service not found - skip.'
        return $false
    }

    $wasRunning = Test-LoopSegmentsVdStreamerRunning
    if (-not $wasRunning) {
        [void](Start-LoopSegmentsVdServiceIfNeeded)
        if (-not $path) {
            Write-Warning '[vd] Service start attempted; Streamer exe not found so it was not launched.'
            return ($svcs.Count -gt 0)
        }
        $started = Start-LoopSegmentsVdStreamer -WaitSeconds $WaitSeconds
        if (-not $started) {
            Write-Warning '[vd] Streamer did not appear after start (check the Virtual Desktop window / tray).'
        }
    } else {
        Write-Host ("[vd] Already running{0}" -f $(if ($path) { ": $path" } else { '' }))
    }

    if (Test-LoopSegmentsVdStreamerRunning) {
        [void](Hide-LoopSegmentsVdStreamerToTray)
        Write-Host '[vd] Streamer in tray (retries for ~30s as the window appears)'
        return $true
    }
    return $false
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
        [void](Hide-LoopSegmentsVdStreamerToTray)
        Write-Host '[vd] Virtual Desktop Streamer is running (tray).'
    } else {
        Write-Warning '[vd] Streamer did not appear after start (check the Virtual Desktop window / tray).'
    }
    return $started
}

function Write-LoopSegmentsVirtualDesktopNotice {
    param(
        [switch] $EnsureStarted,
        [switch] $EnsureRestarted
    )
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
    if ($EnsureStarted) {
        return (Ensure-LoopSegmentsVirtualDesktop)
    }
    return $true
}
