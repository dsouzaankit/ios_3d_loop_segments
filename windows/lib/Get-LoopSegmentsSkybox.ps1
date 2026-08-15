#Requires -Version 5.1
<#
.SYNOPSIS
  Locate / start / status helpers for the SKYBOX VR desktop client on this PC.

.DESCRIPTION
  Dot-source from pcloud_web_companion\run_chromium.ps1.
  Finds SKYBOX.exe (Steam / installer / Start Menu / json override), reports
  whether it is running, and can start it. Missing install is a warning only.
  Companion finish/watchdog quits Skybox only when this session started it
  (marker under %LOCALAPPDATA%\pcloud_web_companion).
#>

$script:LoopSegmentsSkyboxProcessNames = @(
    'SKYBOX'
    'Skybox'
    'SkyboxVR'
    'SkyboxDesktop'
    'SKYBOX VR Video Player'
)

# Steam: https://steamdb.info/app/1162750/ (SKYBOX VR Video Player)
$script:LoopSegmentsSkyboxSteamAppId = '1162750'

function Get-LoopSegmentsSkyboxConfiguredExe {
    $envPath = [string]$env:LOOP_SEGMENTS_SKYBOX_EXE
    if (-not [string]::IsNullOrWhiteSpace($envPath) -and (Test-Path -LiteralPath $envPath.Trim() -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($envPath.Trim())
    }
    $jsonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'loop-segments-windows.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $p = [string]$obj.skyboxExe
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p.Trim() -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($p.Trim())
        }
    } catch {}
    return $null
}

function Get-LoopSegmentsSteamLibraryRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $steam = $null
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    } catch {}
    if ([string]::IsNullOrWhiteSpace($steam)) {
        foreach ($c in @(
                (Join-Path ${env:ProgramFiles(x86)} 'Steam')
                (Join-Path $env:ProgramFiles 'Steam')
            )) {
            if ($c -and (Test-Path -LiteralPath $c)) { $steam = $c; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($steam) -or -not (Test-Path -LiteralPath $steam)) {
        return @()
    }
    [void]$roots.Add($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
        if ($text) {
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $p = ($m.Groups[1].Value -replace '\\\\', '\').Trim()
                if ($p -and (Test-Path -LiteralPath $p) -and -not ($roots -contains $p)) {
                    [void]$roots.Add($p)
                }
            }
        }
    }
    return @($roots.ToArray())
}

function Test-LoopSegmentsSkyboxSteamAppInstalled {
    $acf = "appmanifest_$($script:LoopSegmentsSkyboxSteamAppId).acf"
    foreach ($root in (Get-LoopSegmentsSteamLibraryRoots)) {
        $p = Join-Path $root "steamapps\$acf"
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $true }
    }
    return $false
}

function Start-LoopSegmentsDetachedProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string] $Arguments = ''
    )
    # Hidden, not /min: /min puts a taskbar button. Electron tray is the restore path.
    if ($FilePath -notmatch '(?i)^steam:' -and [string]::IsNullOrWhiteSpace($Arguments) -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $cmdArgs = '/c start "" "' + $FilePath + '"'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
        $psi.Arguments = $cmdArgs
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        [void][System.Diagnostics.Process]::Start($psi)
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $psi.Arguments = $Arguments
    }
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
}

function Get-LoopSegmentsSkyboxWinCSharp {
    @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class LoopSegmentsSkyboxWin {
    public const int SW_HIDE = 0;
    public const int SW_SHOWMINNOACTIVE = 7;
    public const int SW_FORCEMINIMIZE = 11;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lp, int n);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder lp, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    public const uint GW_OWNER = 4;

    static string Title(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static string Cls(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static bool IsMainSkyboxWindow(IntPtr h) {
        string t = Title(h);
        if (t.IndexOf("SKYBOX", StringComparison.OrdinalIgnoreCase) >= 0) return true;
        return false;
    }
    static bool IsHelperWindow(IntPtr h) {
        if (IsMainSkyboxWindow(h)) return false;
        string c = Cls(h);
        if (c.Equals("IME", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.Equals("MSCTFIME UI", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.Equals("Electron_NotifyIconHostWindow", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.Equals("Chrome_SystemMessageWindow", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.Equals("Base_PowerMessageWindow", StringComparison.OrdinalIgnoreCase)) return true;
        if (c.StartsWith("Chrome_WidgetWin_", StringComparison.OrdinalIgnoreCase) && string.IsNullOrWhiteSpace(Title(h))) return true;
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0) return true;
        if ((ex & WS_EX_NOACTIVATE) != 0) return true;
        if (GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
        if (string.IsNullOrWhiteSpace(Title(h))) return true;
        return false;
    }

    public static int MinimizePids(uint[] pids) {
        if (pids == null || pids.Length == 0) return 0;
        var set = new HashSet<uint>(pids);
        int n = 0;
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!set.Contains(pid)) return true;
            if (IsHelperWindow(h)) {
                if (IsWindowVisible(h)) ShowWindow(h, SW_HIDE);
                return true;
            }
            if (!IsMainSkyboxWindow(h)) return true;
            // Hide (tray), do not SW_SHOWMIN* — that creates a blank/named taskbar button.
            ShowWindow(h, SW_HIDE);
            n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }
}
'@
}

function Initialize-LoopSegmentsSkyboxNative {
    if ("LoopSegmentsSkyboxWin" -as [type]) { return }
    Add-Type -TypeDefinition (Get-LoopSegmentsSkyboxWinCSharp)
}

function Get-LoopSegmentsSkyboxPids {
    $ids = [System.Collections.Generic.List[uint32]]::new()
    foreach ($n in $script:LoopSegmentsSkyboxProcessNames) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            if ($p.Id -gt 0) { [void]$ids.Add([uint32]$p.Id) }
        }
    }
    # Late Unity/Electron hosts sometimes use a different process name but "SKYBOX" in the title.
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowTitle -and ($_.MainWindowTitle -match '(?i)skybox')
            })) {
        if ($p.Id -gt 0 -and -not ($ids -contains [uint32]$p.Id)) {
            [void]$ids.Add([uint32]$p.Id)
        }
    }
    return @($ids.ToArray())
}

function Minimize-LoopSegmentsSkyboxWindows {
    try { Initialize-LoopSegmentsSkyboxNative } catch { return 0 }
    $pids = @(Get-LoopSegmentsSkyboxPids)
    if ($pids.Count -eq 0) { return 0 }
    try {
        return [int][LoopSegmentsSkyboxWin]::MinimizePids($pids)
    } catch {
        return 0
    }
}

function Start-LoopSegmentsSkyboxMinimizeWatch {
    param([int] $Seconds = 30)
    $names = @($script:LoopSegmentsSkyboxProcessNames)
    $csharp = Get-LoopSegmentsSkyboxWinCSharp
    Get-Job -Name 'LoopSegmentsSkyboxMinimize' -ErrorAction SilentlyContinue |
        Stop-Job -PassThru -ErrorAction SilentlyContinue |
        Remove-Job -Force -ErrorAction SilentlyContinue | Out-Null
    $block = {
        param([string[]] $ProcNames, [int] $Sec, [string] $TypeDef)
        if (-not ("LoopSegmentsSkyboxWin" -as [type])) {
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
                        $_.MainWindowTitle -and ($_.MainWindowTitle -match '(?i)skybox')
                    })) {
                [void]$ids.Add([uint32]$p.Id)
            }
            if ($ids.Count -gt 0) {
                [void][LoopSegmentsSkyboxWin]::MinimizePids(@($ids.ToArray()))
            }
            Start-Sleep -Milliseconds 700
        }
    }
    try {
        if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
            [void](Start-ThreadJob -Name 'LoopSegmentsSkyboxMinimize' -ScriptBlock $block -ArgumentList @(, $names), $Seconds, $csharp)
        } else {
            [void](Start-Job -Name 'LoopSegmentsSkyboxMinimize' -ScriptBlock $block -ArgumentList @(, $names), $Seconds, $csharp)
        }
    } catch {
        Write-Warning "[skybox] Minimize watch not started: $($_.Exception.Message)"
    }
}

function ConvertFrom-LoopSegmentsShortcutTarget {
    param([Parameter(Mandatory = $true)][string] $LnkPath)
    try {
        $sh = New-Object -ComObject WScript.Shell
        $tgt = [string]$sh.CreateShortcut($LnkPath).TargetPath
        if ($tgt -and (Test-Path -LiteralPath $tgt -PathType Leaf)) { return $tgt }
    } catch {}
    return $null
}

function Get-LoopSegmentsSkyboxPath {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return Get-LoopSegmentsSkyboxPathUnsafe
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-LoopSegmentsSkyboxPathUnsafe {
    $configured = Get-LoopSegmentsSkyboxConfiguredExe
    if ($configured) { return $configured }

    $exeNames = @('SKYBOX.exe', 'Skybox.exe', 'SkyboxVR.exe', 'SkyboxDesktop.exe')
    $dirHints = @(
        (Join-Path $env:ProgramFiles 'SKYBOX VR Video Player')
        (Join-Path $env:ProgramFiles 'SKYBOX')
        (Join-Path ${env:ProgramFiles(x86)} 'SKYBOX VR Video Player')
        (Join-Path ${env:ProgramFiles(x86)} 'SKYBOX')
        (Join-Path $env:LOCALAPPDATA 'SKYBOX VR Video Player')
        (Join-Path $env:LOCALAPPDATA 'Programs\SKYBOX VR Video Player')
        (Join-Path $env:LOCALAPPDATA 'Programs\SKYBOX')
        (Join-Path $env:LOCALAPPDATA 'SKYBOX')
    )
    foreach ($root in (Get-LoopSegmentsSteamLibraryRoots)) {
        $dirHints += (Join-Path $root 'steamapps\common\SKYBOX VR Video Player')
        $dirHints += (Join-Path $root 'steamapps\common\SKYBOX')
    }
    foreach ($dir in $dirHints) {
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($name in $exeNames) {
            $p = Join-Path $dir $name
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
    }

    foreach ($menu in @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
        )) {
        if (-not (Test-Path -LiteralPath $menu)) { continue }
        $lnk = Get-ChildItem -LiteralPath $menu -Filter '*SKYBOX*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($lnk) {
            $tgt = ConvertFrom-LoopSegmentsShortcutTarget -LnkPath $lnk.FullName
            if ($tgt) { return $tgt }
        }
    }

    foreach ($rootKey in @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )) {
        $hit = Get-ItemProperty $rootKey -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '(?i)skybox' } |
            Select-Object -First 1
        if (-not $hit) { continue }
        $icon = [string]$hit.DisplayIcon
        if ($icon -match '^"?([^"]+\.exe)') {
            $p = $Matches[1]
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
        $loc = [string]$hit.InstallLocation
        if ($loc -and (Test-Path -LiteralPath $loc)) {
            foreach ($name in $exeNames) {
                $p = Join-Path $loc $name
                if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
            }
        }
    }
    return $null
}

function Test-LoopSegmentsSkyboxRunning {
    foreach ($n in $script:LoopSegmentsSkyboxProcessNames) {
        if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

function Get-LoopSegmentsSkyboxStartedMarkerPath {
    Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\skybox-started-by-companion.marker'
}

function Set-LoopSegmentsSkyboxStartedMarker {
    $p = Get-LoopSegmentsSkyboxStartedMarkerPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    Set-Content -LiteralPath $p -Value (Get-Date -Format o) -Encoding ascii
}

function Clear-LoopSegmentsSkyboxStartedMarker {
    $p = Get-LoopSegmentsSkyboxStartedMarkerPath
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

function Test-LoopSegmentsSkyboxStartedByCompanion {
    Test-Path -LiteralPath (Get-LoopSegmentsSkyboxStartedMarkerPath)
}

function Stop-LoopSegmentsSkyboxMinimizeWatch {
    Get-Job -Name 'LoopSegmentsSkyboxMinimize' -ErrorAction SilentlyContinue |
        Stop-Job -PassThru -ErrorAction SilentlyContinue |
        Remove-Job -Force -ErrorAction SilentlyContinue | Out-Null
}

function Stop-LoopSegmentsSkybox {
    param([switch] $OnlyIfCompanionStarted)

    Stop-LoopSegmentsSkyboxMinimizeWatch
    if ($OnlyIfCompanionStarted -and -not (Test-LoopSegmentsSkyboxStartedByCompanion)) {
        return
    }

    $skip = @{
        'steam'           = $true
        'steamwebhelper'  = $true
        'steamservice'    = $true
        'chrome'          = $true
        'msedge'          = $true
        'pwsh'            = $true
        'powershell'      = $true
        'explorer'        = $true
    }
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in @(Get-LoopSegmentsSkyboxPids)) {
        if ($id -le 0) { continue }
        try {
            $proc = Get-Process -Id $id -ErrorAction Stop
            $base = $proc.ProcessName
            if ($base -and $skip.ContainsKey($base.ToLowerInvariant())) { continue }
        } catch {
            continue
        }
        [void]$ids.Add([int]$id)
    }
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            $exe = [string]$p.ExecutablePath
            if ([string]::IsNullOrWhiteSpace($exe) -or ($exe -notmatch '(?i)skybox')) { continue }
            $base = [System.IO.Path]::GetFileNameWithoutExtension([string]$p.Name)
            if ($base -and $skip.ContainsKey($base.ToLowerInvariant())) { continue }
            if ($p.ProcessId -gt 0) { [void]$ids.Add([int]$p.ProcessId) }
        }
    } catch {}

    if ($ids.Count -eq 0) {
        Clear-LoopSegmentsSkyboxStartedMarker
        return
    }

    Write-Host "[skybox] Quitting SKYBOX VR desktop ($($ids.Count) process(es))"
    foreach ($id in $ids) {
        try { & taskkill.exe /PID $id /T /F 2>&1 | Out-Null } catch {}
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 400
    foreach ($id in $ids) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Clear-LoopSegmentsSkyboxStartedMarker
}

function Start-LoopSegmentsSkybox {
    param([int] $WaitSeconds = 3)

    if (Test-LoopSegmentsSkyboxRunning) {
        $path = Get-LoopSegmentsSkyboxPath
        Write-Host ("[skybox] Already running{0}" -f $(if ($path) { ": $path" } else { '' }))
        return [pscustomobject]@{
            Installed = $true
            Running   = $true
            Path      = $path
            Started   = $false
        }
    }

    $path = Get-LoopSegmentsSkyboxPath
    if ($path) {
        Write-Host "[skybox] Starting SKYBOX VR desktop (hide to tray): $path"
        try {
            Start-LoopSegmentsDetachedProcess -FilePath $path
        } catch {
            Write-Warning "[skybox] Start failed: $($_.Exception.Message)"
            return [pscustomobject]@{
                Installed = $true
                Running   = $false
                Path      = $path
                Started   = $false
            }
        }
    } elseif (Test-LoopSegmentsSkyboxSteamAppInstalled) {
        $uri = "steam://rungameid/$($script:LoopSegmentsSkyboxSteamAppId)"
        Write-Host "[skybox] SKYBOX.exe not on disk; starting installed Steam app (hide to tray) $uri"
        try {
            Start-LoopSegmentsDetachedProcess -FilePath $uri
        } catch {
            Write-Warning "[skybox] Steam start failed: $($_.Exception.Message)"
            return [pscustomobject]@{
                Installed = $false
                Running   = $false
                Path      = $null
                Started   = $false
            }
        }
    } else {
        Write-Host ""
        Write-Host '[skybox] NOT INSTALLED - cannot start SKYBOX VR desktop.' -ForegroundColor Yellow
        Write-Host 'Install SKYBOX VR Video Player, or set skyboxExe in loop-segments-windows.json' -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    try { Set-LoopSegmentsSkyboxStartedMarker } catch {}

    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $WaitSeconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-LoopSegmentsSkyboxRunning) { break }
        Start-Sleep -Milliseconds 400
    }
    $running = Test-LoopSegmentsSkyboxRunning
    if ($running) {
        $winDeadline = [datetime]::UtcNow.AddSeconds(3)
        $minimized = 0
        while ([datetime]::UtcNow -lt $winDeadline) {
            $minimized = Minimize-LoopSegmentsSkyboxWindows
            if ($minimized -gt 0) { break }
            Start-Sleep -Milliseconds 400
        }
        Start-LoopSegmentsSkyboxMinimizeWatch -Seconds 30
        Write-Host '[skybox] Started OK (hide to tray; retries for ~30s as the window appears)'
    } else {
        Write-Warning '[skybox] Process not seen yet; continuing anyway'
        Start-LoopSegmentsSkyboxMinimizeWatch -Seconds 30
    }
    return [pscustomobject]@{
        Installed = [bool]$path
        Running   = $running
        Path      = $path
        Started   = $true
    }
}

function Write-LoopSegmentsSkyboxNotice {
    param(
        [switch] $AlwaysStatus,
        [switch] $EnsureStarted
    )

    $path = Get-LoopSegmentsSkyboxPath
    $running = Test-LoopSegmentsSkyboxRunning
    if (-not $path -and -not $running) {
        Write-Host ""
        Write-Host '[skybox] NOT INSTALLED on this PC (optional for companion).' -ForegroundColor Yellow
        Write-Host 'Install SKYBOX VR Video Player, or set skyboxExe in loop-segments-windows.json / LOOP_SEGMENTS_SKYBOX_EXE.' -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    if ($EnsureStarted -and -not $running) {
        return Start-LoopSegmentsSkybox -WaitSeconds 3
    }
    if ($AlwaysStatus -or $running) {
        Write-Host ("[skybox] {0}{1}" -f $(if ($running) { 'Already running' } else { 'Installed, not running' }), $(if ($path) { ": $path" } else { '' }))
    }
    return [pscustomobject]@{
        Installed = [bool]$path -or $running
        Running   = $running
        Path      = $path
        Started   = $false
    }
}
