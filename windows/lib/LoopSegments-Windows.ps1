#Requires -Version 7.0
# Shared per-PC settings for Loop Segments windows scripts (lib/, setup/, usb/, rclone/, ...).
# This file lives in windows\lib\; config JSON stays in windows\ (parent of lib).
# Capture windows\ at load time so config paths stay correct even when callers live in a subfolder
# (dot-sourced $PSScriptRoot would otherwise follow the caller).
# Requires PowerShell 7+: entry scripts re-launch via Get-LoopSegmentsPwsh.ps1 when opened under 5.1.
$script:LoopSegmentsWindowsRoot = Split-Path -Parent $PSScriptRoot

$script:LoopSegmentsPwshHelper = Join-Path $PSScriptRoot 'Get-LoopSegmentsPwsh.ps1'
if ((Test-Path -LiteralPath $script:LoopSegmentsPwshHelper) -and -not (Get-Command Get-LoopSegmentsPwshExe -ErrorAction SilentlyContinue)) {
    . $script:LoopSegmentsPwshHelper
}

function Get-LoopSegmentsWindowsConfigPath {
    Join-Path $script:LoopSegmentsWindowsRoot 'loop-segments-windows.json'
}

function Get-LoopSegmentsWindowsExamplePath {
    Join-Path $script:LoopSegmentsWindowsRoot 'loop-segments-windows.example.json'
}

function Get-DefaultLoopSegmentsWindowsSettings {
    [ordered]@{
        phoneLanHost            = ''
        phoneLanHosts           = @()
        lanPort                 = 8765
        mountDriveLetter        = 'L'
        rcloneRemoteName        = 'loopsegments'
        rcloneConfigPath        = ''
        rcloneExe               = ''
        winfspDllPath           = ''
        skipWinFspCheck         = $false
        # Below this measured LAN Mbps, companion/measure reboots other routers and re-checks (up to 2 retries).
        minLanThroughputMbps    = 40
        dlnaFolder              = ''
        skyboxExe               = ''
        virtualDesktopStreamerExe = ''
        webdavUser              = 'admin'
        webdavPassword          = 'iosadmin'
        iCloudDownloads         = ''
        notes                   = ''
    }
}

function Get-LoopSegmentsWebDAVCredentials {
    param(
        [string] $UserOverride = '',
        [string] $PasswordOverride = ''
    )
    $settings = Get-LoopSegmentsWindowsSettings
    $user = if (-not [string]::IsNullOrWhiteSpace($UserOverride)) {
        $UserOverride.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$settings.webdavUser)) {
        [string]$settings.webdavUser
    } else {
        'admin'
    }
    $password = if (-not [string]::IsNullOrWhiteSpace($PasswordOverride)) {
        $PasswordOverride
    } elseif ($null -ne $settings.webdavPassword -and [string]$settings.webdavPassword.Length -gt 0) {
        [string]$settings.webdavPassword
    } else {
        'iosadmin'
    }
    return @{ User = $user; Password = $password }
}

function Read-LoopSegmentsWindowsConfigFile {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse $Path : $($_.Exception.Message)"
        return $null
    }
}

function Merge-LoopSegmentsWindowsSettings {
    param($FromFile)
    $merged = Get-DefaultLoopSegmentsWindowsSettings
    if ($null -eq $FromFile) { return $merged }
    foreach ($prop in $FromFile.PSObject.Properties) {
        if ($merged.Contains($prop.Name)) {
            $merged[$prop.Name] = $prop.Value
        }
    }
    return $merged
}

function Import-LoopSegmentsLegacyLanHost {
    param([hashtable] $Settings)
    $legacy = Join-Path $script:LoopSegmentsWindowsRoot 'loop-segments-lan-host.txt'
    if (-not [string]::IsNullOrWhiteSpace($Settings.phoneLanHost)) { return $Settings }
    if (-not (Test-Path -LiteralPath $legacy)) { return $Settings }
    $raw = Get-Content -LiteralPath $legacy -Raw -ErrorAction SilentlyContinue
    $ip = ([string]$raw).Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($ip)) {
        $Settings.phoneLanHost = $ip
    }
    return $Settings
}

function Get-LoopSegmentsWindowsSettings {
    $path = Get-LoopSegmentsWindowsConfigPath
    $fromFile = Read-LoopSegmentsWindowsConfigFile -Path $path
    $settings = Merge-LoopSegmentsWindowsSettings -FromFile $fromFile
    Import-LoopSegmentsLegacyLanHost -Settings $settings
}

function Save-LoopSegmentsWindowsSettings {
    param(
        [hashtable] $Settings,
        [switch] $Quiet
    )
    $path = Get-LoopSegmentsWindowsConfigPath
    $ordered = [ordered]@{}
    foreach ($key in (Get-DefaultLoopSegmentsWindowsSettings).Keys) {
        $ordered[$key] = $Settings[$key]
    }
    $json = $ordered | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    if (-not $Quiet) {
        Write-Host "Saved: $path"
    }
    $legacy = Join-Path $script:LoopSegmentsWindowsRoot 'loop-segments-lan-host.txt'
    if (-not [string]::IsNullOrWhiteSpace([string]$Settings.phoneLanHost)) {
        ([string]$Settings.phoneLanHost).Trim() | Set-Content -LiteralPath $legacy -Encoding UTF8 -NoNewline
    }
}

function Resolve-LoopSegmentsPath {
    param([string] $Path)
    $t = ([string]$Path).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($t)) { return '' }
    return [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables(
            ($t -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        )
    )
}

function Get-DefaultRcloneConfigPath {
    Join-Path $env:APPDATA 'rclone\rclone.conf'
}

function Get-StandardRcloneConfigCandidatePaths {
    @(
        (Get-DefaultRcloneConfigPath)
        (Join-Path $env:LOCALAPPDATA 'rclone\rclone.conf')
        (Join-Path $env:USERPROFILE '.config\rclone\rclone.conf')
    )
}

function Test-IsStandardRcloneConfigPath {
    param([string] $Path)
    $resolved = Resolve-LoopSegmentsPath $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) { return $false }
    foreach ($candidate in Get-StandardRcloneConfigCandidatePaths) {
        if ($resolved -eq (Resolve-LoopSegmentsPath $candidate)) { return $true }
    }
    return $false
}

function Ensure-RcloneConfigFile {
    param([string] $ConfigPath)
    $path = Resolve-LoopSegmentsPath $ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'Ensure-RcloneConfigFile: ConfigPath is required.'
    }
    if (Test-Path -LiteralPath $path) { return $path }
    $configDir = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($configDir) -and -not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $path -Force | Out-Null
    Write-Verbose "Created blank rclone config: $path"
    return $path
}

function Test-RcloneConfigPathForeignUser {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '(?i)^[A-Za-z]:\\Users\\([^\\]+)\\') {
        return ($Matches[1] -ne $env:USERNAME)
    }
    return $false
}

function Find-RcloneConfigPath {
    $settings = Get-LoopSegmentsWindowsSettings
    $override = Resolve-LoopSegmentsPath $settings.rcloneConfigPath
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        # Copied json from another PC/user: ignore foreign absolute paths.
        if (Test-RcloneConfigPathForeignUser $override) {
            Write-Warning "Ignoring rcloneConfigPath from another Windows user; using auto-detect. Clear it with setup\Set-LoopSegmentsWindows.ps1 or setup\Setup-LoopSegmentsWindows.ps1."
            $override = $null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) { return $override }
        if (Test-IsStandardRcloneConfigPath $override) {
            return (Ensure-RcloneConfigFile -ConfigPath $override)
        }
        throw @"
rcloneConfigPath not found: $override

  Set rcloneConfigPath to "" in loop-segments-windows.json for auto (%APPDATA%\rclone\rclone.conf), or create that file, or fix the path if this json was copied from another PC.
  Tip: .\setup\Setup-LoopSegmentsWindows.ps1 clears foreign/stale absolute paths.
"@
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RCLONE_CONFIG)) {
        $envPath = Resolve-LoopSegmentsPath $env:RCLONE_CONFIG
        if (Test-Path -LiteralPath $envPath) { return $envPath }
        if (Test-IsStandardRcloneConfigPath $envPath) {
            return (Ensure-RcloneConfigFile -ConfigPath $envPath)
        }
    }
    $rcloneExe = Find-RcloneExecutable
    if ($rcloneExe) {
        try {
            $fromRclone = (& $rcloneExe config file 2>$null | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($fromRclone)) {
                $resolved = Resolve-LoopSegmentsPath $fromRclone
                if (Test-Path -LiteralPath $resolved) { return $resolved }
                if (Test-IsStandardRcloneConfigPath $resolved) {
                    return (Ensure-RcloneConfigFile -ConfigPath $resolved)
                }
            }
        } catch {
            # ignore
        }
    }
    foreach ($candidate in Get-StandardRcloneConfigCandidatePaths) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return (Get-DefaultRcloneConfigPath)
}

function Find-RcloneExecutable {
    $settings = Get-LoopSegmentsWindowsSettings
    $override = Resolve-LoopSegmentsPath $settings.rcloneExe
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) { return $override }
        throw "rcloneExe not found: $override"
    }
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-RcloneInvocation {
    $exe = Find-RcloneExecutable
    if (-not $exe) {
        throw 'rclone not found on PATH. Set rcloneExe in loop-segments-windows.json or install https://rclone.org/install/'
    }
    $configPath = Ensure-RcloneConfigFile -ConfigPath (Find-RcloneConfigPath)
    return @{
        Exe        = $exe
        ConfigPath = $configPath
        PrefixArgs = @('--config', $configPath)
    }
}

function Get-LoopSegmentsRcloneMountLogPath {
    # Local NTFS — rclone --log-file on P: (pCloud) fails with "cannot find the file specified".
    Join-Path $env:TEMP 'loopsegments-rclone-mount.log'
}

function Get-LoopSegmentsRcloneMountLogArchivePath {
    Join-Path $script:LoopSegmentsWindowsRoot 'rclone\loopsegments-rclone-mount.log'
}

function Clear-LoopSegmentsRcloneMountLog {
    # rclone writes on Temp. On quit/abort/next start, copy the last log to P: then delete Temp.
    $src = Get-LoopSegmentsRcloneMountLogPath
    $dst = Get-LoopSegmentsRcloneMountLogArchivePath
    try {
        if ((Test-Path -LiteralPath $src) -and ((Get-Item -LiteralPath $src).Length -gt 0)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        }
    } catch {
        return
    }
    for ($i = 0; $i -lt 6; $i++) {
        try {
            if (Test-Path -LiteralPath $src) {
                Remove-Item -LiteralPath $src -Force -ErrorAction Stop
            }
            if (-not (Test-Path -LiteralPath $src)) { return }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    try {
        if (Test-Path -LiteralPath $src) {
            Set-Content -LiteralPath $src -Value '' -Encoding utf8
        }
    } catch {}
}

function Register-LoopSegmentsRcloneLogConsoleGuard {
    param([int] $RclonePid = 0)
    $src = Get-LoopSegmentsRcloneMountLogPath
    $dst = Get-LoopSegmentsRcloneMountLogArchivePath
    if (-not ('LoopSegmentsRcloneLogGuard' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
public static class LoopSegmentsRcloneLogGuard {
    public static string Src;
    public static string Dst;
    public static int RclonePid;
    public delegate bool HandlerRoutine(uint dwCtrlType);
    static HandlerRoutine _keep;
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
    public static void Register(string src, string dst, int rclonePid) {
        Src = src;
        Dst = dst;
        RclonePid = rclonePid;
        if (_keep == null) {
            _keep = OnCtrl;
            SetConsoleCtrlHandler(_keep, true);
        }
    }
    public static void SetRclonePid(int pid) { RclonePid = pid; }
    static bool OnCtrl(uint dwCtrlType) {
        try {
            if (RclonePid > 0) {
                try { Process.GetProcessById(RclonePid).Kill(); } catch {}
                Thread.Sleep(250);
            }
            if (!string.IsNullOrEmpty(Src) && File.Exists(Src) && new FileInfo(Src).Length > 0 && !string.IsNullOrEmpty(Dst)) {
                File.Copy(Src, Dst, true);
            }
            if (!string.IsNullOrEmpty(Src) && File.Exists(Src)) {
                try { File.Delete(Src); } catch {}
            }
        } catch {}
        return false;
    }
}
'@
    }
    [LoopSegmentsRcloneLogGuard]::Register($src, $dst, $RclonePid)
}

function Start-LoopSegmentsConsoleNoActivate {
    # New console without stealing focus (SW_SHOWMINNOACTIVE). Minimized on the taskbar.
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string] $ArgumentList = '',
        [string] $WorkingDirectory = ''
    )
    if (-not ('LoopSegmentsShowWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LoopSegmentsShowWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_SHOWMINNOACTIVE = 7;
}
'@ | Out-Null
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentList
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) { return $null }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 50
        try { $proc.Refresh() } catch {}
        if ($proc.HasExited) { break }
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { break }
    }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        [void][LoopSegmentsShowWindow]::ShowWindow($proc.MainWindowHandle, 7)
    }
    return $proc
}

function Invoke-LoopSegmentsRclone {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $RcloneArgs)
    $inv = Get-RcloneInvocation
    $all = @()
    if ($inv.PrefixArgs) { $all += $inv.PrefixArgs }
    if ($RcloneArgs) { $all += $RcloneArgs }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $inv.Exe @all
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { $global:LASTEXITCODE = $code }
    return $code
}

function Get-LoopSegmentsLANHost {
    param([string] $Override = '')
    $resolved = [string]$Override
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = $resolved.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = (Get-LoopSegmentsWindowsSettings).phoneLanHost
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw @"
phoneLanHost is required.

  Copy loop-segments-windows.example.json to loop-segments-windows.json
  Run: .\setup\Set-LoopSegmentsWindows.ps1
  Or:  .\setup\Set-LoopSegmentsLANHost.ps1 <phone-ip>
"@
    }
    return ([string]$resolved).Trim()
}

function Get-LoopSegmentsMountDriveLetter {
    param([string] $Override = '')
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $o = $Override.Trim().ToUpperInvariant()
        if ($o.Length -lt 1) { return 'L' }
        return $o.Substring(0, 1)
    }
    $letter = [string](Get-LoopSegmentsWindowsSettings).mountDriveLetter
    if ([string]::IsNullOrWhiteSpace($letter)) { return 'L' }
    $letter = $letter.Trim().ToUpperInvariant()
    if ($letter.Length -lt 1) { return 'L' }
    return $letter.Substring(0, 1)
}

function Get-LoopSegmentsOccupiedDriveLetters {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $drives = @()
    try {
        $rawDrives = [System.IO.DriveInfo]::GetDrives()
        if ($null -ne $rawDrives) { $drives = @($rawDrives | Where-Object { $null -ne $_ }) }
    } catch { $drives = @() }
    foreach ($d in $drives) {
        if ($null -eq $d) { continue }
        try {
            $name = [string]$d.Name
            if ($name.Length -ge 1) {
                [void]$set.Add($name.Substring(0, 1))
            }
        } catch { }
    }
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        $n = [string]$_.Name
        if ($n.Length -eq 1) { [void]$set.Add($n) }
    }
    # Comma prevents PowerShell from enumerating an empty HashSet into $null.
    return ,$set
}

function Test-LoopSegmentsRcloneCommandLineIsOurMount {
    param([string] $CommandLine)
    $cmd = [string]$CommandLine
    if ([string]::IsNullOrWhiteSpace($cmd) -or $cmd -notmatch '(?i)\bmount\b') {
        return $false
    }
    $remote = 'loopsegments'
    if (Get-Command Get-LoopSegmentsRcloneRemoteName -ErrorAction SilentlyContinue) {
        try {
            $resolved = [string](Get-LoopSegmentsRcloneRemoteName)
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                $remote = $resolved.Trim()
            }
        } catch { }
    }
    $remoteToken = [regex]::Escape("${remote}:")
    return [bool]($cmd -match $remoteToken)
}

function Get-LoopSegmentsWin32Processes {
    param([string] $Name = '')
    # Get-CimInstance returns $null when nothing matches. @($null) is a 1-element
    # array, so foreach would call methods on $null ("You cannot call a method on a null-valued expression").
    $raw = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $raw = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        } else {
            $raw = Get-CimInstance Win32_Process -Filter "Name = '$Name'" -ErrorAction SilentlyContinue
        }
    } catch {
        return @()
    }
    if ($null -eq $raw) { return @() }
    return @($raw | Where-Object { $null -ne $_ })
}

function Get-LoopSegmentsRcloneMountedDriveLetters {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $procs = Get-LoopSegmentsWin32Processes -Name 'rclone.exe'
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if (-not (Test-LoopSegmentsRcloneCommandLineIsOurMount -CommandLine $cmd)) {
            continue
        }
        # rclone mount <remote:path> <X:> [flags]
        if ($cmd -match '(?i)\bmount\s+\S+\s+["'']?([A-Za-z]):(?:\\)?["'']?(?:\s|$)') {
            $ch = [string]$Matches[1]
            if ($ch.Length -ge 1) {
                [void]$set.Add($ch.ToUpperInvariant())
            }
        }
    }
    return ,$set
}

function Test-LoopSegmentsRcloneMountOnDrive {
    param([Parameter(Mandatory = $true)][string] $DriveLetter)
    $letter = ([string]$DriveLetter).Trim().ToUpperInvariant()
    if ($letter.Length -lt 1) { return $false }
    $letter = $letter.Substring(0, 1)
    $ours = Get-LoopSegmentsRcloneMountedDriveLetters
    if ($null -eq $ours) { return $false }
    return $ours.Contains($letter)
}

function Get-LoopSegmentsFreeMountDriveLetters {
    $occupied = Get-LoopSegmentsOccupiedDriveLetters
    $free = [System.Collections.Generic.List[string]]::new()
    foreach ($code in 68..90) {
        $ch = [string][char]$code
        $taken = ($null -ne $occupied -and $occupied.Contains($ch))
        if (-not $taken -and -not (Test-Path -LiteralPath "${ch}:\")) {
            $free.Add($ch)
        }
    }
    return @($free)
}

function Set-LoopSegmentsMountDriveLetter {
    param([Parameter(Mandatory = $true)][string] $DriveLetter)
    $raw = ([string]$DriveLetter).Trim().ToUpperInvariant()
    if ($raw.Length -lt 1) { return }
    $letter = $raw.Substring(0, 1)
    $settings = Get-LoopSegmentsWindowsSettings
    $prev = ([string]$settings.mountDriveLetter).Trim().ToUpperInvariant()
    if ($prev.Length -ge 1 -and $prev.Substring(0, 1) -eq $letter) {
        return
    }
    $settings.mountDriveLetter = $letter
    Save-LoopSegmentsWindowsSettings -Settings $settings -Quiet
}

function Resolve-LoopSegmentsMountDriveLetter {
    <#
      Prefer json / -DriveLetter. Reuse only an existing loopsegments rclone mount (not Koofr/other remotes).
      If the preferred letter is taken by something else, pick a random free D–Z and optionally save it to json.
    #>
    param(
        [string] $Override = '',
        [switch] $PersistIfChanged
    )
    $preferred = [string](Get-LoopSegmentsMountDriveLetter -Override $Override)
    if ([string]::IsNullOrWhiteSpace($preferred)) { $preferred = 'L' }
    $preferred = $preferred.Trim().ToUpperInvariant().Substring(0, 1)

    $ours = Get-LoopSegmentsRcloneMountedDriveLetters
    if ($null -ne $ours -and $ours.Contains($preferred)) {
        return $preferred
    }
    $existingOurs = @($ours)
    if ($existingOurs.Count -gt 0) {
        $picked = [string]$existingOurs[0]
        if ([string]::IsNullOrWhiteSpace($picked)) {
            $picked = $preferred
        } else {
            $picked = $picked.Trim().ToUpperInvariant().Substring(0, 1)
        }
        Write-Host "Phone rclone already mounted on ${picked}: (loopsegments remote). Reusing it instead of ${preferred}:."
        if ($PersistIfChanged) {
            try {
                Set-LoopSegmentsMountDriveLetter -DriveLetter $picked
                Write-Host "Saved mountDriveLetter=${picked} to loop-segments-windows.json (Unstick/companion will use it)."
            } catch {
                Write-Warning "Could not save mountDriveLetter=${picked}: $($_.Exception.Message)"
            }
        }
        return $picked
    }
    $occupied = Get-LoopSegmentsOccupiedDriveLetters
    if ($null -ne $occupied -and -not $occupied.Contains($preferred) -and -not (Test-Path -LiteralPath "${preferred}:\")) {
        return $preferred
    }

    $free = @(Get-LoopSegmentsFreeMountDriveLetters)
    if ($free.Count -eq 0) {
        throw "No free drive letters (D-Z) for the phone rclone mount (preferred ${preferred}: is in use)."
    }
    $picked = [string]($free | Get-Random)
    Write-Warning "Drive ${preferred}: is already in use. Mounting the phone on ${picked}: instead."
    if ($PersistIfChanged) {
        try {
            Set-LoopSegmentsMountDriveLetter -DriveLetter $picked
            Write-Host "Saved mountDriveLetter=${picked} to loop-segments-windows.json (Unstick/companion will use it)."
        } catch {
            Write-Warning "Could not save mountDriveLetter=${picked}: $($_.Exception.Message)"
        }
    }
    return $picked
}

function Get-LoopSegmentsRcloneRemoteName {
    param([string] $Override = '')
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override.Trim() }
    $name = [string](Get-LoopSegmentsWindowsSettings).rcloneRemoteName
    if ([string]::IsNullOrWhiteSpace($name)) { return 'loopsegments' }
    return $name.Trim()
}

function Get-LoopSegmentsLanPort {
    param([int] $Override = 0)
    if ($Override -gt 0) { return $Override }
    $port = (Get-LoopSegmentsWindowsSettings).lanPort
    if ($null -eq $port -or [int]$port -le 0) { return 8765 }
    return [int]$port
}

function Get-LoopSegmentsMinLanThroughputMbps {
    param([double] $Override = 0)
    if ($Override -gt 0) { return [double]$Override }
    $settings = Get-LoopSegmentsWindowsSettings
    $raw = $null
    # StrictMode-safe: missing key must not throw when older json/defaults omit the field.
    if ($null -ne $settings) {
        if ($settings -is [System.Collections.IDictionary]) {
            if ($settings.Contains('minLanThroughputMbps')) {
                $raw = $settings['minLanThroughputMbps']
            }
        } elseif ($null -ne $settings.PSObject.Properties['minLanThroughputMbps']) {
            $raw = $settings.PSObject.Properties['minLanThroughputMbps'].Value
        }
    }
    if ($null -eq $raw) { return 40 }
    try {
        $n = [double]$raw
    } catch {
        return 40
    }
    if ($n -le 0) { return 40 }
    return $n
}

function Get-LoopSegmentsPhoneLanBaseUrl {
    param(
        [string] $PhoneHostOverride = '',
        [int] $PortOverride = 0
    )
    $hostIp = Get-LoopSegmentsLANHost -Override $PhoneHostOverride
    $portNum = Get-LoopSegmentsLanPort -Override $PortOverride
    return "http://${hostIp}:${portNum}"
}

function ConvertTo-LoopSegmentsPhoneHostEntry {
    param(
        [Parameter(Mandatory = $true)]
        $Raw,
        [int] $DefaultPort = 8765
    )

    if ($Raw -is [string]) {
        $hostText = $Raw.Trim()
        if ([string]::IsNullOrWhiteSpace($hostText)) { return $null }
        return @{
            Host  = $hostText
            Label = $hostText
            Port  = $DefaultPort
        }
    }

    $hostText = [string]$Raw.host
    if ([string]::IsNullOrWhiteSpace($hostText)) {
        $hostText = [string]$Raw.phoneLanHost
    }
    if ([string]::IsNullOrWhiteSpace($hostText)) {
        $hostText = [string]$Raw.ip
    }
    $hostText = $hostText.Trim()
    if ([string]::IsNullOrWhiteSpace($hostText)) { return $null }

    $label = [string]$Raw.label
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = [string]$Raw.name
    }
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = $hostText
    }

    $port = $DefaultPort
    if ($null -ne $Raw.port -and [int]$Raw.port -gt 0) {
        $port = [int]$Raw.port
    } elseif ($null -ne $Raw.lanPort -and [int]$Raw.lanPort -gt 0) {
        $port = [int]$Raw.lanPort
    }

    return @{
        Host  = $hostText
        Label = $label.Trim()
        Port  = $port
    }
}

function Get-LoopSegmentsPhoneHostEntries {
    param(
        [string[]] $HostOverride = @(),
        [int] $PortOverride = 0
    )

    $defaultPort = Get-LoopSegmentsLanPort -Override $PortOverride
    $entries = New-Object System.Collections.Generic.List[hashtable]

    foreach ($rawHost in @($HostOverride)) {
        if ([string]::IsNullOrWhiteSpace($rawHost)) { continue }
        foreach ($part in ($rawHost -split '[,\s;]+')) {
            $part = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $entry = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $part -DefaultPort $defaultPort
            if ($null -ne $entry) { [void]$entries.Add($entry) }
        }
    }

    if ($entries.Count -eq 0) {
        $settings = Get-LoopSegmentsWindowsSettings
        foreach ($raw in @($settings.phoneLanHosts)) {
            $entry = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $raw -DefaultPort $defaultPort
            if ($null -ne $entry) { [void]$entries.Add($entry) }
        }
        if ($entries.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$settings.phoneLanHost)) {
            $entry = ConvertTo-LoopSegmentsPhoneHostEntry -Raw $settings.phoneLanHost -DefaultPort $defaultPort
            if ($null -ne $entry) { [void]$entries.Add($entry) }
        }
    }

    if ($entries.Count -eq 0) {
        throw @"
No Loop Segments phone hosts configured.

  Add phoneLanHosts to loop-segments-windows.json, or set phoneLanHost, or pass -PhoneHost.
  Example:
    "phoneLanHosts": [
      { "host": "192.168.1.42", "label": "iPhone A" },
      { "host": "192.168.1.43", "label": "iPhone B" }
    ]
"@
    }

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[hashtable]
    foreach ($entry in $entries) {
        $key = "{0}:{1}" -f $entry.Host, $entry.Port
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$unique.Add($entry)
    }
    return @($unique)
}

function Get-LoopSegmentsPhoneLanBaseUrlForEntry {
    param(
        [hashtable] $Entry
    )
    return "http://$($Entry.Host):$($Entry.Port)"
}

function Invoke-LoopSegmentsPhoneLANJson {
    param(
        [hashtable] $Entry,
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,
        [int] $TimeoutSec = 15
    )

    $base = Get-LoopSegmentsPhoneLanBaseUrlForEntry -Entry $Entry
    $path = $RelativePath.Trim().TrimStart('/')
    $uri = "$base/$path"
    try {
        $response = Invoke-WebRequest -Uri $uri -TimeoutSec $TimeoutSec -UseBasicParsing
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "HTTP $($response.StatusCode)"
        }
        return ($response.Content | ConvertFrom-Json)
    } catch {
        throw $_.Exception.Message
    }
}

function ConvertTo-LoopSegmentsAbsoluteLANHref {
    param(
        [string] $BaseUrl,
        [string] $Html
    )

    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $base = $BaseUrl.TrimEnd('/')
    return [regex]::Replace(
        $Html,
        '(?i)(?<prefix>href\s*=\s*["''])(?!https?://|#|mailto:)(?<path>[^"'']+)',
        {
            param($match)
            $path = $match.Groups['path'].Value
            if ($path.StartsWith('/')) {
                return '{0}{1}{2}' -f $match.Groups['prefix'].Value, $base, $path
            }
            return '{0}{1}/{2}' -f $match.Groups['prefix'].Value, $base, $path
        }
    )
}

function ConvertTo-LoopSegmentsHtmlEncoded {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Get-LoopSegmentsUnifiedLANListing {
    param(
        [string[]] $PhoneHost = @(),
        [int] $Port = 0,
        [int] $TimeoutSec = 15
    )

    $entries = Get-LoopSegmentsPhoneHostEntries -HostOverride $PhoneHost -PortOverride $Port
    $generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $devices = New-Object System.Collections.Generic.List[hashtable]
    $mergedFiles = New-Object System.Collections.Generic.List[hashtable]

    foreach ($entry in $entries) {
        $baseUrl = Get-LoopSegmentsPhoneLanBaseUrlForEntry -Entry $entry
        $device = [ordered]@{
            label    = $entry.Label
            host     = $entry.Host
            port     = $entry.Port
            baseUrl  = $baseUrl
            reachable = $false
            error    = $null
            exportSource = $null
            files    = @()
            playbackListHTML = ''
            exportLogsListHTML = ''
        }

        try {
            $status = Invoke-LoopSegmentsPhoneLANJson -Entry $entry -RelativePath 'status.json' -TimeoutSec $TimeoutSec
            $device.reachable = $true
            if ($null -ne $status.exportSource) {
                $device.exportSource = $status.exportSource
            }
        } catch {
            $device.error = "status.json: $($_.Exception.Message)"
            [void]$devices.Add($device)
            continue
        }

        try {
            $lists = Invoke-LoopSegmentsPhoneLANJson -Entry $entry -RelativePath 'status_lists.json' -TimeoutSec $TimeoutSec
            $device.playbackListHTML = ConvertTo-LoopSegmentsAbsoluteLANHref -BaseUrl $baseUrl -Html ([string]$lists.playbackListHTML)
            $device.exportLogsListHTML = ConvertTo-LoopSegmentsAbsoluteLANHref -BaseUrl $baseUrl -Html ([string]$lists.exportLogsListHTML)

            $fileRows = @()
            if ($null -ne $lists.files) {
                $fileRows = @($lists.files)
            }
            $normalizedFiles = New-Object System.Collections.Generic.List[hashtable]
            foreach ($file in $fileRows) {
                $name = [string]$file.name
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $url = if ($name.StartsWith('/')) { "$baseUrl$name" } else { "$baseUrl/$name" }
                $row = [ordered]@{
                    device   = $entry.Label
                    host     = $entry.Host
                    port     = $entry.Port
                    name     = $name
                    url      = $url
                }
                if ($null -ne $file.bytes) { $row.bytes = [int64]$file.bytes }
                if ($null -ne $file.modified) { $row.modified = [string]$file.modified }
                [void]$normalizedFiles.Add($row)
                [void]$mergedFiles.Add($row)
            }
            $device.files = @($normalizedFiles)
        } catch {
            $device.error = "status_lists.json: $($_.Exception.Message)"
        }

        [void]$devices.Add($device)
    }

    return [ordered]@{
        generatedAt = $generatedAt
        deviceCount = $devices.Count
        reachableCount = @($devices | Where-Object { $_.reachable }).Count
        devices = @($devices)
        files = @($mergedFiles)
    }
}

function ConvertTo-LoopSegmentsUnifiedLANHtml {
    param(
        [hashtable] $Listing
    )

    $deviceSections = New-Object System.Collections.Generic.List[string]
    foreach ($device in @($Listing.devices)) {
        $statusLine = if ($device.reachable) {
            'online'
        } else {
            'offline'
        }
        $exportLine = ''
        if ($null -ne $device.exportSource -and $null -ne $device.exportSource.displayName) {
            $exportLine = "<p><strong>Export:</strong> $($device.exportSource.displayName)</p>"
        }
        $errorLine = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$device.error)) {
            $errorLine = "<p><em>$(ConvertTo-LoopSegmentsHtmlEncoded -Text ([string]$device.error))</em></p>"
        }
        $playback = [string]$device.playbackListHTML
        if ([string]::IsNullOrWhiteSpace($playback)) {
            $playback = '<li><em>No media listed.</em></li>'
        }
        $logs = [string]$device.exportLogsListHTML
        $logsBlock = ''
        if (-not [string]::IsNullOrWhiteSpace($logs)) {
            $logsBlock = @"
<h4>Export logs</h4>
<ul>$logs</ul>
"@
        }
        $section = @"
<section>
  <h2>$(ConvertTo-LoopSegmentsHtmlEncoded -Text ([string]$device.label)) <small>($(ConvertTo-LoopSegmentsHtmlEncoded -Text ([string]$device.host)):$($device.port) - $statusLine)</small></h2>
  <p><a href="$($device.baseUrl)/">Open phone monitor</a> - <a href="$($device.baseUrl)/browse">Browse / export</a></p>
  $exportLine
  $errorLine
  <h3>Media on phone</h3>
  <ul>$playback</ul>
  $logsBlock
</section>
"@
        [void]$deviceSections.Add($section)
    }

    $summary = "Unified listing - $($Listing.reachableCount)/$($Listing.deviceCount) phone(s) reachable - generated $($Listing.generatedAt)"
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Loop Segments - unified LAN media</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 1rem 1.25rem; line-height: 1.4; }
    h1 { font-size: 1.25rem; margin-bottom: 0.25rem; }
    h2 { font-size: 1.05rem; margin-top: 1.5rem; }
    h2 small { font-weight: normal; color: #555; }
    ul { padding-left: 1.25rem; }
    section { border-top: 1px solid #ddd; padding-top: 0.5rem; }
    .meta { color: #555; font-size: 0.9rem; }
  </style>
</head>
<body>
  <h1>Loop Segments - unified LAN media</h1>
  <p class="meta">$summary - <a href="listing.json">listing.json</a></p>
  $($deviceSections -join "`n")
</body>
</html>
"@
}

function Get-LoopSegmentsPhoneWebDavAuthHeader {
    $creds = Get-LoopSegmentsWebDAVCredentials
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($creds.User):$($creds.Password)"))
    return @{ Authorization = "Basic $pair" }
}

function Invoke-LoopSegmentsPhoneWebDavMkcol {
    param(
        [string] $Uri,
        [hashtable] $Headers
    )
    try {
        Invoke-WebRequest -Method MKCOL -Uri $Uri -Headers $Headers -UseBasicParsing | Out-Null
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $code = [int]$resp.StatusCode
        if ($code -eq 405 -or $code -eq 409) { return }
        throw
    }
}

function Invoke-LoopSegmentsPhoneWebDavPutFile {
    param(
        [string] $Uri,
        [string] $LocalPath,
        [hashtable] $Headers,
        [int] $MaxBytes = 2MB
    )
    $info = Get-Item -LiteralPath $LocalPath
    if ($info.Length -gt $MaxBytes) {
        throw "File exceeds phone LAN PUT limit ($MaxBytes bytes): $LocalPath ($($info.Length) bytes)"
    }
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $contentType = switch ($info.Extension.ToLowerInvariant()) {
        '.json' { 'application/json; charset=utf-8' }
        '.ps1' { 'text/plain; charset=utf-8' }
        '.sh' { 'text/x-shellscript; charset=utf-8' }
        '.bat' { 'text/plain; charset=utf-8' }
        '.cmd' { 'text/plain; charset=utf-8' }
        default { 'application/octet-stream' }
    }
    Invoke-WebRequest -Method PUT -Uri $Uri -Headers $Headers -Body $bytes -ContentType $contentType -UseBasicParsing | Out-Null
}

function Test-LoopSegmentsWinFspInstalled {
    $settings = Get-LoopSegmentsWindowsSettings
    if ($settings.skipWinFspCheck) { return $true }
    $custom = Resolve-LoopSegmentsPath $settings.winfspDllPath
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        return (Test-Path -LiteralPath $custom)
    }
    $candidates = @(
        "${env:ProgramFiles}\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles}\WinFsp\bin\winfsp.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp.dll"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    foreach ($root in @("${env:ProgramFiles}\WinFsp", "${env:ProgramFiles(x86)}\WinFsp")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Get-ChildItem -LiteralPath $root -Recurse -Filter 'winfsp*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }
    return $false
}

function Show-LoopSegmentsWindowsDiagnostics {
    $settings = Get-LoopSegmentsWindowsSettings
    $configPath = Get-LoopSegmentsWindowsConfigPath
    Write-Host 'Loop Segments Windows (this PC)'
    Write-Host "  Config file:     $(if (Test-Path $configPath) { $configPath } else { '(missing - copy .example.json)' })"
    Write-Host "  Phone LAN:       $($settings.phoneLanHost) : $(Get-LoopSegmentsLanPort)"
    try {
        $hosts = Get-LoopSegmentsPhoneHostEntries
        if ($hosts.Count -gt 1) {
            Write-Host '  Phone LAN hosts:'
            foreach ($h in $hosts) {
                Write-Host "                   $($h.Label) -> $($h.Host):$($h.Port)"
            }
        }
    } catch {
        # single-host diagnostics still useful when phoneLanHost is empty
    }
    Write-Host "  Mount drive:     $(Get-LoopSegmentsMountDriveLetter):"
    Write-Host "  Min LAN Mbps:    $(Get-LoopSegmentsMinLanThroughputMbps) (other-router Wi-Fi reboot + re-check if probe below this)"
    Write-Host "  rclone remote:   $(Get-LoopSegmentsRcloneRemoteName)"
    $creds = Get-LoopSegmentsWebDAVCredentials
    Write-Host "  WebDAV auth:     $($creds.User) / (password in json or default iosadmin)"
    try {
        $inv = Get-RcloneInvocation
        Write-Host "  rclone.exe:      $($inv.Exe)"
        Write-Host "  rclone.conf:     $($inv.ConfigPath)"
    } catch {
        Write-Host "  rclone:          $($_.Exception.Message)"
    }
    $winfsp = Test-LoopSegmentsWinFspInstalled
    Write-Host "  WinFsp:          $(if ($winfsp) { 'OK' } elseif ($settings.skipWinFspCheck) { 'check skipped' } else { 'not found (set winfspDllPath or skipWinFspCheck)' })"
    if (-not [string]::IsNullOrWhiteSpace($settings.dlnaFolder)) {
        Write-Host "  DLNA folder:     $($settings.dlnaFolder)"
    }
    if (-not [string]::IsNullOrWhiteSpace($settings.skyboxExe)) {
        Write-Host "  Skybox exe:      $($settings.skyboxExe)"
    }
    if (-not [string]::IsNullOrWhiteSpace($settings.virtualDesktopStreamerExe)) {
        Write-Host "  VD Streamer:     $($settings.virtualDesktopStreamerExe)"
    }
    if (-not [string]::IsNullOrWhiteSpace($settings.notes)) {
        Write-Host "  Notes:           $($settings.notes)"
    }
}

function Get-LoopSegmentsPCLanIPv4 {
    param([string] $PreferSameSubnetAs = '')

    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' -and $_.PrefixOrigin -ne 'WellKnown'
        })
    if ($PreferSameSubnetAs -match '^(\d+\.\d+\.\d+)\.\d+$') {
        $prefix = $Matches[1]
        $same = @($addrs | Where-Object { $_.IPAddress -like "$prefix.*" })
        if ($same.Count -gt 0) {
            return $same[0].IPAddress
        }
    }
    if ($addrs.Count -eq 0) {
        throw 'No LAN IPv4 on this PC.'
    }
    return $addrs[0].IPAddress
}

function Get-NetshPortProxyV4Rules {
    <#
      Parses output of netsh interface portproxy show v4tov4
    #>
    $rules = New-Object System.Collections.Generic.List[hashtable]
    $lines = netsh interface portproxy show v4tov4 2>&1 | ForEach-Object { $_.ToString() }
    foreach ($line in $lines) {
        $parts = @($line.Trim() -split '\s+' | Where-Object { $_ })
        if ($parts.Count -ne 4) { continue }
        $lp = 0
        $cp = 0
        if (-not [int]::TryParse($parts[1], [ref]$lp)) { continue }
        if (-not [int]::TryParse($parts[3], [ref]$cp)) { continue }
        $rules.Add(@{
                ListenAddress  = $parts[0]
                ListenPort     = $lp
                ConnectAddress = $parts[2]
                ConnectPort    = $cp
            }) | Out-Null
    }
    return $rules
}

function Remove-LoopSegmentsPortProxyOne {
    param(
        [string] $ListenAddress,
        [int] $ListenPort
    )
    # PowerShell expands * when passing args to native exes - use cmd /c single string.
    $cmdLine = 'netsh interface portproxy delete v4tov4 listenaddress={0} listenport={1}' -f $ListenAddress, $ListenPort
    $null = cmd.exe /c $cmdLine 2>&1
    return $LASTEXITCODE
}

function Clear-LoopSegmentsPort80Proxy {
    param(
        [string] $PhoneHost = '',
        [int] $PhonePort = 0,
        [string] $DriveLetter = ''
    )

    $hostIp = if ([string]::IsNullOrWhiteSpace($PhoneHost)) {
        Get-LoopSegmentsLANHost
    } else {
        $PhoneHost.Trim()
    }
    if ($PhonePort -le 0) {
        $PhonePort = Get-LoopSegmentsLanPort
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isAdmin) {
        Write-Warning 'Deleting portproxy requires Administrator PowerShell (right-click, Run as administrator).'
    }

    $removed = 0
    foreach ($r in @(Get-NetshPortProxyV4Rules)) {
        if ($r.ConnectAddress -ne $hostIp -or [int]$r.ConnectPort -ne $PhonePort) { continue }
        $code = Remove-LoopSegmentsPortProxyOne -ListenAddress $r.ListenAddress -ListenPort $r.ListenPort
        if ($code -eq 0) {
            $removed++
            Write-Host "  Deleted v4 $($r.ListenAddress):$($r.ListenPort) -> $($r.ConnectAddress):$($r.ConnectPort)"
        }
        else {
            Write-Warning "  netsh delete failed (exit $code) for listen $($r.ListenAddress):$($r.ListenPort)"
        }
    }

    $fallbackListen = New-Object System.Collections.Generic.List[string]
    foreach ($a in @('0.0.0.0', '*', '127.0.0.1')) {
        if (-not ($fallbackListen -contains $a)) { [void]$fallbackListen.Add($a) }
    }
    try {
        foreach ($adapterIp in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress -Unique)) {
            if ($adapterIp -notmatch '^169\.254\.' -and $fallbackListen -notcontains $adapterIp) {
                [void]$fallbackListen.Add($adapterIp)
            }
        }
        $sameSubnet = Get-LoopSegmentsPCLanIPv4 -PreferSameSubnetAs $hostIp
        if ($fallbackListen -notcontains $sameSubnet) { [void]$fallbackListen.Add($sameSubnet) }
    } catch {}

    foreach ($addr in $fallbackListen) {
        foreach ($listenPort in @(80, 8080)) {
            $code = Remove-LoopSegmentsPortProxyOne -ListenAddress $addr -ListenPort $listenPort
            if ($code -eq 0) {
                $removed++
                Write-Host "  Deleted fallback listen $addr`:$listenPort"
            }
        }
    }

    Write-Host "Portproxy cleanup finished ($removed successful netsh delete(s)) for target ${hostIp}:$PhonePort."

    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $drive = "${DriveLetter}:"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        cmd.exe /c ("net use {0} /delete /y" -f $drive) 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        Write-Host "net use $drive /delete attempted (WebDAV)."
    }

    Write-Host ''
    Write-Host 'Mapped drives:'
    cmd.exe /c net use 2>&1

    Write-Host ''
    Write-Host 'Remaining portproxy (v4tov4):'
    netsh interface portproxy show v4tov4
}

function Initialize-LoopSegmentsWindowsConfig {
    param([switch] $Force)
    $path = Get-LoopSegmentsWindowsConfigPath
    if ((Test-Path -LiteralPath $path) -and -not $Force) { return }
    $example = Get-LoopSegmentsWindowsExamplePath
    if (Test-Path -LiteralPath $example) {
        Copy-Item -LiteralPath $example -Destination $path -Force
        Write-Host "Created $path from example."
    } else {
        Save-LoopSegmentsWindowsSettings -Settings (Get-LoopSegmentsWindowsSettings)
    }
}
