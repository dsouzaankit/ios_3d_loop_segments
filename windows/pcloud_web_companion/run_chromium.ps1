param(
    [switch]$RecreateVenv,
    [switch]$ForceDeps,
    [switch]$NoLaunch,
    [switch]$SkipUsbLaunch,
    # By default USB launch uses -SkipMount (DDI already mounted). Set this to remount.
    [switch]$UsbLaunchMount,
    [switch]$SkipProfileSync,
    # Do not wait for Chromium exit (upload runs at the start of the next launch instead).
    [switch]$DetachChromium,
    # Keep the full local AppData profile after upload (default: wipe local after sync to P:).
    [switch]$KeepLocalProfile,
    # Do not press iPhone Home on companion finish (default: background Loop Segments via USB HID).
    [switch]$SkipGoHome,
    [string]$StartUrl = "https://my.pcloud.com"
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { throw "Cannot resolve script directory; run with: powershell -File `"$($MyInvocation.MyCommand.Path)`"" }

$ExtensionDir = $ScriptDir
$ManifestPath = Join-Path $ExtensionDir "manifest.json"
$WindowsDir = Split-Path -Parent $ScriptDir
$PythonHelper = Join-Path $WindowsDir "Get-LoopSegmentsPython.ps1"
if (-not (Test-Path -LiteralPath $PythonHelper)) {
    throw "Missing shared Python helper: $PythonHelper"
}
. $PythonHelper

$AltServerHelper = Join-Path $WindowsDir "Get-LoopSegmentsAltServer.ps1"
if (-not (Test-Path -LiteralPath $AltServerHelper)) {
    throw "Missing shared AltServer helper: $AltServerHelper"
}
. $AltServerHelper

# Machine-local only (never on pCloud P:). Repo .venv is legacy and ignored.
$CompanionLocalRoot = Join-Path $env:LOCALAPPDATA "pcloud_web_companion"
$VenvDir = Join-Path $CompanionLocalRoot "venv"
$PythonExe = Join-Path $VenvDir "Scripts\python.exe"
$Requirements = Join-Path $ScriptDir "requirements.txt"
$DepsStamp = Join-Path $VenvDir ".deps_requirements_sha256.txt"
$LegacyRepoVenv = Join-Path $ScriptDir ".venv"

# Chromium must use a local disk profile (not P:). We sync that folder to/from the repo each run.
$UserDataDir = Join-Path $CompanionLocalRoot "chromium-profile"
$RepoProfileDir = Join-Path $ScriptDir "chromium-profile"

if (-not (Test-Path $ManifestPath)) {
    throw "Extension manifest not found: $ManifestPath"
}

# Browsers stay machine-local under LOCALAPPDATA. Ignore ambient PLAYWRIGHT_BROWSERS_PATH
# (IDEs/sandboxes often set it); use LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS for a custom cache.
# Do not prefer a repo/.playwright-browsers folder on P: (pCloud sync + wrong machine).
$LegacyRepoBrowsers = Join-Path $ScriptDir ".playwright-browsers"
if (-not [string]::IsNullOrWhiteSpace($env:LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS)) {
    $PlaywrightCache = $env:LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS
    Write-Host "[playwright] Using LOOP_SEGMENTS_PLAYWRIGHT_BROWSERS: $PlaywrightCache"
} else {
    $PlaywrightCache = Join-Path $env:LOCALAPPDATA "ms-playwright"
    Write-Host "[playwright] Using machine-local browser cache: $PlaywrightCache"
}
$env:PLAYWRIGHT_BROWSERS_PATH = $PlaywrightCache
if (Test-Path -LiteralPath $LegacyRepoBrowsers) {
    Write-Warning "[playwright] Ignoring legacy $LegacyRepoBrowsers (use LOCALAPPDATA; delete that folder to stop syncing browsers via pCloud)."
}

function Test-CompanionVenvHealthy {
    param([string] $Dir, [string] $Exe)
    if (-not (Test-Path -LiteralPath $Exe)) { return $false }
    $pyvenvCfg = Join-Path $Dir "pyvenv.cfg"
    if (-not (Test-Path -LiteralPath $pyvenvCfg)) { return $false }
    $homeLine = Get-Content -LiteralPath $pyvenvCfg | Where-Object { $_ -match '^\s*home\s*=' } | Select-Object -First 1
    if ($homeLine -notmatch '^\s*home\s*=\s*(.+)$') { return $false }
    $venvHome = $Matches[1].Trim()
    $homePython = Join-Path $venvHome "python.exe"
    if (-not (Test-Path -LiteralPath $homePython)) { return $false }
    # Another Windows user/machine left a synced or copied venv.
    $userProfile = $env:USERPROFILE
    if ($userProfile -and ($venvHome -match '(?i)^[A-Za-z]:\\Users\\') -and ($venvHome -notlike "$userProfile*")) {
        return $false
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $probe = & $Exe -c "print('ok')" 2>&1
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = (@($probe) | ForEach-Object { [string]$_ }) -join "`n"
    return (($code -eq 0) -and ($text -match "(?m)^ok\s*$"))
}

if (Test-Path -LiteralPath $LegacyRepoVenv) {
    Write-Host "[venv] Removing legacy repo .venv (not portable across PCs / pCloud sync): $LegacyRepoVenv"
    try {
        # Clear hidden/system attrs that can block deletes on cloud drives.
        Get-ChildItem -LiteralPath $LegacyRepoVenv -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = 'Normal' }
        (Get-Item -LiteralPath $LegacyRepoVenv -Force).Attributes = 'Normal'
        Remove-Item -Recurse -Force -LiteralPath $LegacyRepoVenv -ErrorAction Stop
    } catch {
        Write-Warning "[venv] Could not fully remove $LegacyRepoVenv ($($_.Exception.Message)). Delete it manually; companion uses $VenvDir instead."
    }
}
$legacyVenvMarker = Join-Path $ScriptDir ".venv-DO-NOT-USE.txt"
if (-not (Test-Path -LiteralPath $legacyVenvMarker)) {
    @(
        "Do not create .venv in this folder."
        "The companion virtualenv is machine-local:"
        "  %LOCALAPPDATA%\pcloud_web_companion\venv"
        "Run ..\Setup-LoopSegmentsWindows.ps1 on each PC."
    ) -join [Environment]::NewLine | Set-Content -LiteralPath $legacyVenvMarker -Encoding utf8
}

if (-not $RecreateVenv -and -not (Test-CompanionVenvHealthy -Dir $VenvDir -Exe $PythonExe)) {
    if (Test-Path -LiteralPath $VenvDir) {
        Write-Host "[venv] Existing venv is stale or from another PC/user; recreating $VenvDir"
        $RecreateVenv = $true
    }
}

if ($RecreateVenv -and (Test-Path $VenvDir)) {
    Write-Host "[venv] Removing existing $VenvDir"
    Remove-Item -Recurse -Force $VenvDir
}

if (-not (Test-Path $PythonExe)) {
    $pyRt = Get-LoopSegmentsPythonRuntime -ForVenv
    if (-not $pyRt) {
        throw @"
No suitable Python for companion venv (need 3.9-3.13; prefer 3.12).

$(Get-LoopSegmentsPythonInstallHint)
"@
    }
    New-Item -ItemType Directory -Force -Path $CompanionLocalRoot | Out-Null
    Write-Host "[venv] Creating virtualenv at $VenvDir with $($pyRt.Display)"
    $create = Invoke-LoopSegmentsPythonRuntime -Runtime $pyRt -ArgumentList @("-m", "venv", $VenvDir)
    if ($create.ExitCode -ne 0) {
        $create.Lines | ForEach-Object { Write-Host $_ }
        throw "venv create failed (exit $($create.ExitCode)) via $($pyRt.Display)"
    }
}

if (-not (Test-Path $Requirements)) {
    throw "Missing requirements file: $Requirements"
}

$CurrentReqHash = (Get-FileHash -Path $Requirements -Algorithm SHA256).Hash
$PreviousReqHash = ""
if (Test-Path $DepsStamp) {
    $PreviousReqHash = (Get-Content -Path $DepsStamp -Raw).Trim()
}

$NeedsDeps = $ForceDeps -or $RecreateVenv -or (-not (Test-Path $DepsStamp)) -or ($CurrentReqHash -ne $PreviousReqHash)

if ($NeedsDeps) {
    Write-Host "[venv] Installing dependencies from requirements.txt"
    & $PythonExe -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw "pip upgrade failed (exit $LASTEXITCODE)" }
    & $PythonExe -m pip install -r $Requirements
    if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }
    Set-Content -Path $DepsStamp -Value $CurrentReqHash -Encoding ascii
} else {
    Write-Host "[venv] Dependencies unchanged; skipping pip install"
}

function Get-PlaywrightChromiumExe {
    $path = & $PythonExe -c @"
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    print(p.chromium.executable_path)
"@
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($path)) {
        return $null
    }
    return $path.Trim()
}

Write-Host "[chromium] Resolving executable path expected by Playwright"
$ChromiumExe = Get-PlaywrightChromiumExe
# Any leftover chromium-* folder is not enough - version must match this Playwright package.
$NeedsChromium = $ForceDeps -or [string]::IsNullOrWhiteSpace($ChromiumExe) -or -not (Test-Path $ChromiumExe)
if ($NeedsChromium) {
    Write-Host "[playwright] Installing Chromium for this Playwright version (cache: $PlaywrightCache)"
    if (-not [string]::IsNullOrWhiteSpace($ChromiumExe)) {
        Write-Host "[playwright] Missing executable: $ChromiumExe"
    }
    & $PythonExe -m playwright install chromium
    if ($LASTEXITCODE -ne 0) {
        throw "playwright install chromium failed (exit $LASTEXITCODE). Re-run with -ForceDeps if needed."
    }
    $ChromiumExe = Get-PlaywrightChromiumExe
}

if ([string]::IsNullOrWhiteSpace($ChromiumExe) -or -not (Test-Path $ChromiumExe)) {
    throw "Chromium executable not found after install: $ChromiumExe"
}
Write-Host "[chromium] $ChromiumExe"

function Sync-LanConfigFromLoopSegments {
    $lanConfigPath = Join-Path $ExtensionDir "lan_config.json"
    # Integrated layout: windows/pcloud_web_companion -> parent is windows/
    # Legacy sibling layout: .../pcloud_web_companion next to ios_3d_loop_segments/
    $windowsDirCandidates = @(
        (Split-Path -Parent $ScriptDir)
        (Join-Path (Split-Path -Parent $ScriptDir) "ios_3d_loop_segments\windows")
        (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) "ios_3d_loop_segments\windows")
    )

    $sourcePath = $null
    $examplePath = $null
    foreach ($windowsDir in $windowsDirCandidates) {
        $settingsPath = Join-Path $windowsDir "loop-segments-windows.json"
        $examplePath = Join-Path $windowsDir "loop-segments-windows.example.json"
        if (Test-Path -LiteralPath $settingsPath) {
            $sourcePath = $settingsPath
            break
        }
        if (-not $sourcePath -and (Test-Path -LiteralPath $examplePath)) {
            $sourcePath = $examplePath
            Write-Host "[lan] loop-segments-windows.json missing; using example at $examplePath"
            break
        }
    }

    if (-not $sourcePath) {
        Write-Warning "[lan] No Loop Segments windows settings found; leaving $lanConfigPath unchanged"
        return
    }

    $settings = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
    $hostName = [string]$settings.phoneLanHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw "phoneLanHost is empty in $sourcePath"
    }

    $port = 8765
    if ($null -ne $settings.lanPort -and [int]$settings.lanPort -gt 0) {
        $port = [int]$settings.lanPort
    }

    $user = "admin"
    if (-not [string]::IsNullOrWhiteSpace([string]$settings.webdavUser)) {
        $user = [string]$settings.webdavUser
    }

    $password = "iosadmin"
    if (-not [string]::IsNullOrWhiteSpace([string]$settings.webdavPassword)) {
        $password = [string]$settings.webdavPassword
    }

    $lanConfig = [ordered]@{
        phoneLanHost   = $hostName.Trim()
        lanPort        = $port
        webdavUser     = $user
        webdavPassword = $password
    }

    $json = $lanConfig | ConvertTo-Json -Depth 3
    # UTF-8 without BOM - BOM breaks extension JSON.parse on some Chromium builds
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($lanConfigPath, $json + "`n", $utf8NoBom)
    Write-Host "[lan] Synced $lanConfigPath -> http://$($lanConfig.phoneLanHost):$($lanConfig.lanPort)/export_from_url.json"
}

function Sync-ExtensionToLocalDisk {
    # Chromium refuses unpacked extensions from network/cloud drives (P:).
    $localExt = Join-Path $env:LOCALAPPDATA "pcloud_web_companion\extension"
    New-Item -ItemType Directory -Force -Path $localExt | Out-Null

    $files = @(
        "manifest.json"
        "background.js"
        "pcloud_folder_tracker.js"
        "offscreen.html"
        "offscreen.js"
        "logs.html"
        "logs.js"
        "icon.png"
        "lan_config.json"
    )

    foreach ($name in $files) {
        $src = Join-Path $ExtensionDir $name
        if (-not (Test-Path -LiteralPath $src)) {
            if ($name -eq "pcloud_folder_tracker.js") {
                Write-Warning "[ext] Optional missing: $src"
                continue
            }
            throw "Missing extension file: $src"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $localExt $name) -Force
    }

    Write-Host "[ext] Local unpack: $localExt"
    return $localExt
}

function Start-HiddenPowerShell {
    param(
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList,
        # Survive parent console X (exit watchdog). Rest-log sink does not need this.
        [switch] $BreakAwayFromConsoleJob
    )

    $argString = ($ArgumentList | ForEach-Object {
            $a = [string]$_
            if ($a -match '[\s"]') {
                '"' + ($a -replace '\\', '\\' -replace '"', '\"') + '"'
            } else {
                $a
            }
        }) -join ' '

    $psExe = (Get-Command powershell.exe).Source
    # -WindowStyle Hidden alone still flashes a blue console; CreateNoWindow avoids that.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -NoLogo -NonInteractive $argString"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    if (-not $BreakAwayFromConsoleJob) {
        return [System.Diagnostics.Process]::Start($psi)
    }

    # Detach from the console job so closing the companion window does not kill this child.
    # PowerShell $null marshals as "" for string P/Invoke — that makes CreateProcess return
    # ERROR_INVALID_NAME. Use IntPtr.Zero for lpApplicationName and a writable StringBuilder.
    if (-not ("CompanionDetachedProc" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CompanionDetachedProc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateProcess(
        IntPtr lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    public const uint CREATE_NO_WINDOW = 0x08000000;
    public const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    public const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;

    public static int Start(string exePath, string arguments, bool breakAway) {
        string cmd = "\"" + exePath + "\" " + arguments;
        var sb = new StringBuilder(cmd);
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        uint flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;
        if (breakAway) flags |= CREATE_BREAKAWAY_FROM_JOB;
        if (!CreateProcess(IntPtr.Zero, sb, IntPtr.Zero, IntPtr.Zero, false, flags,
                IntPtr.Zero, null, ref si, out pi)) {
            return 0;
        }
        int pid = pi.dwProcessId;
        if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
        if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
        return pid;
    }
}
"@
    }

    $pidStarted = [CompanionDetachedProc]::Start($psExe, $psi.Arguments, $true)
    if ($pidStarted -le 0) {
        $pidStarted = [CompanionDetachedProc]::Start($psExe, $psi.Arguments, $false)
    }
    if ($pidStarted -le 0) {
        $err = [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        throw "CreateProcess failed (Win32 $($err.Message))"
    }
    return [pscustomobject]@{ Id = $pidStarted }
}

function Start-RestLogSink {
    $sinkScript = Join-Path $ScriptDir "_rest_log_sink.ps1"
    $logFile = Join-Path $env:LOCALAPPDATA "pcloud_web_companion\rest.log"
    if (-not (Test-Path -LiteralPath $sinkScript)) {
        Write-Warning "[rest-log] Missing $sinkScript"
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logFile) | Out-Null
    # Fresh log each launcher run
    Set-Content -LiteralPath $logFile -Value "" -Encoding utf8
    Write-Host "[rest-log] Cleared $logFile"
    Write-Host "[rest-log] Starting sink -> $logFile"
    [void](Start-HiddenPowerShell -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-File", $sinkScript,
            "-LogFile", $logFile,
            "-Port", "18765"
        ))

    # Child powershell cold-start often exceeds 400ms; poll briefly before warning.
    $deadline = [datetime]::UtcNow.AddSeconds(12)
    $ok = $false
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $health = Invoke-WebRequest -Uri "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 1
            Write-Host "[rest-log] Sink OK ($($health.StatusCode))"
            $ok = $true
            break
        } catch {
            Start-Sleep -Milliseconds 400
        }
    }
    if (-not $ok) {
        Write-Warning "[rest-log] Sink not reachable after 12s (extension logs may miss this run)"
    }
}

function Test-TcpPortOpen {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close() } catch {}
        }
    }
}

function Test-PhoneLanPageReachable {
    $lanConfigPath = Join-Path $ExtensionDir "lan_config.json"
    if (-not (Test-Path -LiteralPath $lanConfigPath)) {
        return $false
    }

    try {
        $lan = Get-Content -LiteralPath $lanConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "[lan] Could not read $lanConfigPath : $_"
        return $false
    }

    $hostName = [string]$lan.phoneLanHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        return $false
    }

    $port = 8765
    if ($null -ne $lan.lanPort -and [int]$lan.lanPort -gt 0) {
        $port = [int]$lan.lanPort
    }

    Write-Host "[lan] TCP probe ${hostName}:${port} ..."
    if (-not (Test-TcpPortOpen -HostName $hostName -Port $port -TimeoutMs 2000)) {
        Write-Host "[lan] Port closed/unreachable - will USB-launch if needed"
        return $false
    }

    # Prefer /browse (companion target); fall back to /status.json.
    $paths = @("/browse", "/status.json")
    foreach ($path in $paths) {
        $uri = "http://${hostName}:${port}${path}"
        try {
            Write-Host "[lan] HTTP probe $uri ..."
            $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 3
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                Write-Host "[lan] Reachable ($($resp.StatusCode)): $uri"
                return $true
            }
        } catch {
            Write-Host "[lan] Not reachable: $uri ($($_.Exception.Message))"
        }
    }
    return $false
}

function Invoke-LoopSegmentsUsbLaunch {
    # Always warn if AltServer missing (7-day AltStore cert), even when LAN skip / -SkipUsbLaunch.
    [void](Write-LoopSegmentsAltServerNotice -AlwaysStatus)

    if ($SkipUsbLaunch) {
        Write-Host "[usb] Skipping Loop Segments USB launch (-SkipUsbLaunch)"
        return
    }

    if (Test-PhoneLanPageReachable) {
        Write-Host "[usb] Phone LAN already up - skipping unlock probe and USB launch"
        return
    }

    $windowsDir = Split-Path -Parent $ScriptDir
    $launchPs1 = Join-Path $windowsDir "Launch-LoopSegmentsViaUsb.ps1"
    if (-not (Test-Path -LiteralPath $launchPs1)) {
        throw "[usb] Missing $launchPs1 - expected integrated windows/Launch-LoopSegmentsViaUsb.ps1"
    }

    $psArgs = [System.Collections.Generic.List[string]]::new()
    [void]$psArgs.Add("-NoProfile")
    [void]$psArgs.Add("-ExecutionPolicy")
    [void]$psArgs.Add("Bypass")
    [void]$psArgs.Add("-File")
    [void]$psArgs.Add($launchPs1)
    # Default SkipMount: DDI is usually already mounted after the first run.
    if (-not $UsbLaunchMount) {
        [void]$psArgs.Add("-SkipMount")
    }

    Write-Host "[usb] LAN not reachable - launching Loop Segments on phone before Chromium..."
    Write-Host "[usb] > powershell $($psArgs -join ' ')"
    & powershell.exe @psArgs
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    if ($code -eq 3) {
        throw @"
[usb] Phone is LOCKED (exit 3). Unlock the iPhone, leave it on the Home Screen, then re-run.
Chromium was not started.
"@
    }
    if ($code -eq 2) {
        throw @"
[usb] No iPhone on USB (exit 2). Plug in, Trust This Computer, unlock.
If AltServer is not installed, install from https://altstore.io - without weekly AltStore refresh,
Loop Segments (free/Personal Team) stops working after ~7 days.

$(Get-LoopSegmentsAppUnavailableResolution)
Chromium was not started. Use -SkipUsbLaunch to start Chromium without USB launch.
"@
    }
    if ($code -ne 0) {
        throw @"
[usb] Launch-LoopSegmentsViaUsb.ps1 failed (exit $code). Fix USB / Developer Mode / cert trust, then re-run.

$(Get-LoopSegmentsAppUnavailableResolution)
Chromium was not started. Use -SkipUsbLaunch to start Chromium without USB launch.
"@
    }
    Write-Host "[usb] Loop Segments launch OK"
}

Sync-LanConfigFromLoopSegments
$ExtensionLoadDir = Sync-ExtensionToLocalDisk
Start-RestLogSink
Invoke-LoopSegmentsUsbLaunch

if ($NoLaunch) {
    Write-Host "[run] Setup complete (-NoLaunch). Extension: $ExtensionDir"
    exit 0
}

function Stop-ProfileChromium {
    param([string]$ProfileDir)

    Write-Host "[cleanup] Closing Chromium instances for this profile"
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-IsCompanionProfileChromium -CommandLine $_.CommandLine -ProfileDir $ProfileDir })

    foreach ($proc in $procs) {
        Write-Host "[cleanup] Stopping PID $($proc.ProcessId)"
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }

    if ($procs.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
}

function Test-IsCompanionProfileChromium {
    param(
        [string] $CommandLine,
        [string] $ProfileDir
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    # Chromium is started with forward-slash --user-data-dir=...; normalize before match.
    $cmd = $CommandLine.Replace('/', '\')
    if (-not [string]::IsNullOrWhiteSpace($ProfileDir)) {
        $prof = $ProfileDir.Replace('/', '\')
        if ($cmd.IndexOf($prof, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return ($cmd -match '(?i)pcloud_web_companion[\\/]+chromium-profile')
}

function Get-CompanionProfileChromiumProcessIds {
    param([string] $ProfileDir)
    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { Test-IsCompanionProfileChromium -CommandLine $_.CommandLine -ProfileDir $ProfileDir } |
            ForEach-Object { [int]$_.ProcessId }
    )
}

function Remove-ProfilePath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Sync-ChromiumProfile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Download", "Upload")]
        [string] $Direction
    )

    if ($SkipProfileSync) {
        Write-Host "[profile] Sync skipped (-SkipProfileSync)"
        return
    }

    $src = if ($Direction -eq "Download") { $RepoProfileDir } else { $UserDataDir }
    $dst = if ($Direction -eq "Download") { $UserDataDir } else { $RepoProfileDir }

    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host "[profile] $Direction skip (missing $src)"
        return
    }

    # Empty source (no Default/) - nothing useful to copy yet
    $hasContent = Test-Path -LiteralPath (Join-Path $src "Default")
    if (-not $hasContent) {
        $any = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
        if ($any.Count -eq 0) {
            Write-Host "[profile] $Direction skip (empty $src)"
            return
        }
    }

    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Write-Host "[profile] $Direction (full folder): $src -> $dst"

    # Full mirror of the profile tree. Skip only live lock files so the next
    # Chromium start is not blocked (Chromium must already be closed).
    $excludeFiles = @(
        "SingletonLock"
        "SingletonCookie"
        "SingletonSocket"
        "lockfile"
        "DevToolsActivePort"
    )

    $robocopyArgs = @(
        $src
        $dst
        "/E"
        "/MIR"
        "/R:2"
        "/W:1"
        "/NFL"
        "/NDL"
        "/NJH"
        "/NJS"
        "/NC"
        "/NS"
        "/XF"
    ) + $excludeFiles

    & robocopy.exe @robocopyArgs | Out-Null
    $rc = $LASTEXITCODE
    # robocopy: 0-7 = success / no fatal error (do not leave this in $LASTEXITCODE for the wrapper).
    if ($rc -ge 8) {
        Write-Warning "[profile] $Direction robocopy exit $rc (see robocopy docs)"
    } else {
        Write-Host "[profile] $Direction OK (robocopy=$rc)"
    }
    $global:LASTEXITCODE = 0

    foreach ($name in $excludeFiles) {
        Remove-ProfilePath (Join-Path $dst $name)
    }
}

function Test-LocalProfileHasContent {
    param([string] $ProfileDir)
    if (-not (Test-Path -LiteralPath $ProfileDir)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $ProfileDir "Default")) { return $true }
    $any = @(Get-ChildItem -LiteralPath $ProfileDir -Force -ErrorAction SilentlyContinue)
    return ($any.Count -gt 0)
}

function Clear-LocalProfileMinimal {
    param([string] $ProfileDir)

    if ($KeepLocalProfile) {
        Write-Host "[profile] Keeping local profile (-KeepLocalProfile)"
        return
    }
    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
        return
    }

    Write-Host "[profile] Clearing local profile (canonical copy is on P: / repo)"
    Get-ChildItem -LiteralPath $ProfileDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
    Write-Host "[profile] Local profile is empty: $ProfileDir"
}

$script:CompanionShutdownRequested = $false
$script:CompanionFinished = $false
$script:CancelKeyPressHandler = $null
$script:ConsoleCtrlHandler = $null
$GracefulExitMarker = Join-Path $CompanionLocalRoot "companion-graceful-exit.marker"

# Native console close (X) does not raise CancelKeyPress. Track Chromium PIDs and kill
# them from SetConsoleCtrlHandler; watchdog (detached) syncs the profile afterward.
try {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class CompanionConsoleGuard {
    public static int[] ChromePids = new int[0];
    public static volatile bool CloseRequested = false;
    static HandlerRoutine _handler;

    public delegate bool HandlerRoutine(uint dwCtrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(HandlerRoutine Handler, bool Add);

    public static void Register() {
        if (_handler != null) return;
        _handler = Handler;
        SetConsoleCtrlHandler(_handler, true);
    }

    public static void Unregister() {
        if (_handler == null) return;
        SetConsoleCtrlHandler(_handler, false);
        _handler = null;
    }

    public static void SetChromePids(int[] pids) {
        ChromePids = pids ?? new int[0];
    }

    public static void KillTrackedChrome() {
        var pids = ChromePids;
        if (pids == null) return;
        foreach (var id in pids) {
            try {
                using (var p = Process.GetProcessById(id)) {
                    p.Kill();
                }
            } catch { }
        }
    }

    static bool Handler(uint ctrlType) {
        // 0 CTRL_C, 1 CTRL_BREAK, 2 CTRL_CLOSE, 5 LOGOFF, 6 SHUTDOWN
        if (ctrlType == 0 || ctrlType == 1 || ctrlType == 2 || ctrlType == 5 || ctrlType == 6) {
            CloseRequested = true;
            KillTrackedChrome();
            // Return true for Close so we get a short window; process still ends after.
            return true;
        }
        return false;
    }
}
"@ -ErrorAction Stop
} catch {
    Write-Warning "[run] Console close guard unavailable: $($_.Exception.Message)"
}

function Stop-CompanionRestLogSink {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*_rest_log_sink.ps1*' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
}

function Invoke-GoIphoneHome {
    if ($SkipGoHome) {
        Write-Host "[home] Skipping iPhone Home press (-SkipGoHome)"
        return
    }
    $homePs1 = Join-Path $WindowsDir "Go-IphoneHomeViaUsb.ps1"
    if (-not (Test-Path -LiteralPath $homePs1)) {
        Write-Warning "[home] Missing $homePs1"
        return
    }
    Write-Host "[home] Backgrounding Loop Segments (USB Home button)..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $code = 1
    try {
        $p = Start-HiddenPowerShell -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-File", $homePs1
        )
        if ($p -is [System.Diagnostics.Process]) {
            if (-not $p.WaitForExit(90000)) {
                try { $p.Kill() } catch {}
                $code = 1
            } else {
                $code = [int]$p.ExitCode
            }
        } else {
            # Unexpected shape from Start-HiddenPowerShell
            $code = 1
        }
    } finally {
        $ErrorActionPreference = $prev
        $global:LASTEXITCODE = 0
    }
    if ($code -eq 0) {
        Write-Host "[home] Done"
    } elseif ($code -eq 2) {
        Write-Host "[home] Skipped (no USB device)"
    } else {
        Write-Warning "[home] Home press did not succeed (exit $code) - phone may still show Loop Segments"
    }
}

function Invoke-CompanionGracefulFinish {
    param([string] $Reason = "session end")

    if ($script:CompanionFinished) { return }
    $script:CompanionFinished = $true

    Write-Host ""
    Write-Host "[run] Finishing companion ($Reason): close Chromium, sync profile, clear local, Home on phone..." -ForegroundColor Cyan

    try {
        Stop-ProfileChromium -ProfileDir $UserDataDir
        Start-Sleep -Milliseconds 500
        if (Test-LocalProfileHasContent -ProfileDir $UserDataDir) {
            Sync-ChromiumProfile -Direction Upload
            Write-Host "[run] Profile synced to $RepoProfileDir"
        } else {
            Write-Host "[run] Local profile empty - skip upload"
        }
        Clear-LocalProfileMinimal -ProfileDir $UserDataDir
        Stop-CompanionRestLogSink
        Invoke-GoIphoneHome
        Write-Host "[run] Companion finish complete." -ForegroundColor Green
    } catch {
        Write-Warning "[run] Finish had errors: $($_.Exception.Message)"
    } finally {
        # Marker only after finish attempt so a killed-mid-sync console X still lets the watchdog upload.
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $GracefulExitMarker) | Out-Null
            Set-Content -LiteralPath $GracefulExitMarker -Value (Get-Date -Format o) -Encoding ascii
        } catch {}
    }
}

function Register-CompanionCancelHandler {
    # Windows PowerShell 5.1 [Console] often has no CancelKeyPress; native SetConsoleCtrlHandler covers Ctrl+C / X.
    try {
        $consoleType = [Console]
        $hasCancel = $consoleType.GetEvent('CancelKeyPress')
        if ($null -ne $hasCancel) {
            $script:CancelKeyPressHandler = [ConsoleCancelEventHandler] {
                param($sender, $eventArgs)
                $eventArgs.Cancel = $true
                $script:CompanionShutdownRequested = $true
                Write-Host ""
                Write-Host "[run] Ctrl+C received - will close Chromium and sync profile..." -ForegroundColor Yellow
                try { [CompanionConsoleGuard]::KillTrackedChrome() } catch {}
            }
            [Console]::CancelKeyPress += $script:CancelKeyPressHandler
        }
    } catch {
        # Ignore - CompanionConsoleGuard handles console signals.
    }
    try {
        [CompanionConsoleGuard]::Register()
    } catch {
        Write-Warning "[run] Could not register console close handler: $($_.Exception.Message)"
    }
}

function Unregister-CompanionCancelHandler {
    if ($null -ne $script:CancelKeyPressHandler) {
        try { [Console]::CancelKeyPress -= $script:CancelKeyPressHandler } catch {}
        $script:CancelKeyPressHandler = $null
    }
    try { [CompanionConsoleGuard]::Unregister() } catch {}
}

function Start-CompanionExitWatchdog {
    $watchdog = Join-Path $ScriptDir "_profile_exit_watchdog.ps1"
    if (-not (Test-Path -LiteralPath $watchdog)) {
        Write-Warning "[run] Missing $watchdog - console X may skip profile sync"
        return
    }
    Remove-Item -LiteralPath $GracefulExitMarker -Force -ErrorAction SilentlyContinue

    $watchArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @(
            "-ExecutionPolicy", "Bypass",
            "-File", $watchdog,
            "-ParentPid", "$PID",
            "-ProfileDir", $UserDataDir,
            "-RepoProfileDir", $RepoProfileDir,
            "-GracefulMarkerPath", $GracefulExitMarker
        )) { [void]$watchArgs.Add($a) }
    if ($SkipProfileSync) { [void]$watchArgs.Add("-SkipProfileSync") }
    if ($KeepLocalProfile) { [void]$watchArgs.Add("-KeepLocalProfile") }
    if ($SkipGoHome) { [void]$watchArgs.Add("-SkipGoHome") }

    try {
        $started = Start-HiddenPowerShell -BreakAwayFromConsoleJob -ArgumentList $watchArgs.ToArray()
        Write-Host "[run] Exit watchdog armed (PID $($started.Id); survives console X, no blue flash)"
    } catch {
        Write-Warning "[run] Detached watchdog failed ($($_.Exception.Message)); falling back to hidden Start-Process"
        [void](Start-HiddenPowerShell -ArgumentList $watchArgs.ToArray())
        Write-Host "[run] Exit watchdog armed (hidden Start-Process fallback)"
    }
}

function Wait-ProfileChromiumExit {
    param([string]$ProfileDir)

    Write-Host "[run] Waiting for Chromium to exit (will upload profile to repo, then clear local)..."
    Write-Host "      Close the browser, or quit this window with Ctrl+C / X (graceful finish)."
    while ($true) {
        $pids = @(Get-CompanionProfileChromiumProcessIds -ProfileDir $ProfileDir)
        try { [CompanionConsoleGuard]::SetChromePids([int[]]$pids) } catch {}

        if ($script:CompanionShutdownRequested) {
            Write-Host "[run] Shutdown requested - stopping Chromium..."
            Stop-ProfileChromium -ProfileDir $ProfileDir
            return
        }
        try {
            if ([CompanionConsoleGuard]::CloseRequested) {
                Write-Host "[run] Console close - stopping Chromium..."
                $script:CompanionShutdownRequested = $true
                Stop-ProfileChromium -ProfileDir $ProfileDir
                return
            }
        } catch {}

        if ($pids.Count -eq 0) {
            Write-Host "[run] Chromium exited"
            return
        }
        Start-Sleep -Seconds 1
    }
}

function Clear-ProfileTabsAndDownloadHistory {
    param([string]$ProfileRoot)

    Write-Host "[cleanup] Clearing tabs/session and download history (cookies retained)"

    $profileDirs = [System.Collections.Generic.List[string]]::new()
    $defaultProfile = Join-Path $ProfileRoot "Default"
    if (Test-Path -LiteralPath $defaultProfile) {
        $profileDirs.Add($defaultProfile)
    }
    Get-ChildItem -LiteralPath $ProfileRoot -Directory -Filter "Profile *" -ErrorAction SilentlyContinue |
        ForEach-Object { $profileDirs.Add($_.FullName) }

    $relativePaths = @(
        # Open tabs / session restore
        "Current Session"
        "Current Tabs"
        "Last Session"
        "Last Tabs"
        "Sessions"
        # Download history (leave Cookies / Network\Cookies alone)
        "History"
        "History-journal"
        "Archived History"
        "Archived History-journal"
        "DownloadMetadata"
        "Download Service"
    )

    foreach ($profileDir in $profileDirs) {
        foreach ($rel in $relativePaths) {
            Remove-ProfilePath (Join-Path $profileDir $rel)
        }
    }

    foreach ($name in @(
            "SingletonLock"
            "SingletonCookie"
            "SingletonSocket"
            "lockfile"
            "DevToolsActivePort"
        )) {
        Remove-ProfilePath (Join-Path $ProfileRoot $name)
    }
}

New-Item -ItemType Directory -Force -Path $UserDataDir | Out-Null
New-Item -ItemType Directory -Force -Path $RepoProfileDir | Out-Null
Stop-ProfileChromium -ProfileDir $UserDataDir
# If a prior -DetachChromium left a full local profile, upload it first.
# Never upload an empty local over P: (would wipe the canonical copy).
if (Test-LocalProfileHasContent -ProfileDir $UserDataDir) {
    Sync-ChromiumProfile -Direction Upload
} else {
    Write-Host "[profile] Local empty - skip upload before download"
}
Sync-ChromiumProfile -Direction Download
Clear-ProfileTabsAndDownloadHistory -ProfileRoot $UserDataDir

# Drop cached extension service workers so background.js updates always apply.
foreach ($rel in @(
        "Default\Service Worker"
        "Default\Extension State"
        "Default\Extension Scripts"
        "Default\Extension Rules"
    )) {
    Remove-ProfilePath (Join-Path $UserDataDir $rel)
}

# Start-Process ArgumentList treats backslash escapes (\a, \n, ...). Path
# P:\all_scripts\... became "--load-extension=P" and the extension never loaded.
function ConvertTo-ChromeSwitchPath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

$ChromeUserData = ConvertTo-ChromeSwitchPath $UserDataDir
$ChromeExtension = ConvertTo-ChromeSwitchPath $ExtensionLoadDir

# Load the unpacked MV3 extension. DisableLoadExtensionCommandLineSwitch keeps
# --load-extension working on newer Chromium builds.
$ChromeArgString = @(
    "--user-data-dir=`"$ChromeUserData`""
    "--disable-extensions-except=`"$ChromeExtension`""
    "--load-extension=`"$ChromeExtension`""
    "--disable-features=DisableLoadExtensionCommandLineSwitch,BlockInsecurePrivateNetworkRequests"
    "--disable-restore-session-state"
    "--no-first-run"
    "--no-default-browser-check"
    "`"$StartUrl`""
) -join " "

Write-Host "[run] Launching Chromium with extension loaded from:"
Write-Host "      $ChromeExtension"
Write-Host "[run] Profile (local): $ChromeUserData"
Write-Host "[run] Profile (repo):  $RepoProfileDir"
Write-Host "[run] URL: $StartUrl"
Write-Host "[run] REST disk log: $(Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\rest.log')"
Write-Host "[run] In-browser logs: click the extension icon"
Write-Host "[run] Args: $ChromeArgString"

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $ChromiumExe
$startInfo.Arguments = $ChromeArgString
$startInfo.UseShellExecute = $true
[void][System.Diagnostics.Process]::Start($startInfo)

Start-Sleep -Milliseconds 800
$verify = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf("chromium-profile", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -like '*--load-extension=*' -and
        $_.CommandLine -notlike '*--type=*'
    } |
    Select-Object -First 1

if ($null -eq $verify) {
    Write-Warning "[run] Could not verify Chromium browser process"
} elseif ($verify.CommandLine -match '--load-extension=(?:"([^"]+)"|(\S+))') {
    $loaded = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    Write-Host "[run] Verified --load-extension=$loaded"
    if ($loaded -notlike '*pcloud_web_companion*') {
        Write-Warning "[run] Extension path looks wrong; plugin will not run"
    }
} else {
    Write-Warning "[run] Browser started but --load-extension missing from command line"
}

Write-Host "[run] Chromium started (fresh tabs + download history; cookies kept)."
Write-Host "[run] pCloud downloads -> clipboard + POST Loop Segments /export_from_folder.json"

if ($DetachChromium) {
    Write-Host "[run] Detached (-DetachChromium). Full local profile kept until next run uploads, then clears."
    exit 0
} else {
    Register-CompanionCancelHandler
    Start-CompanionExitWatchdog
    try {
        Wait-ProfileChromiumExit -ProfileDir $UserDataDir
    } catch {
        Write-Warning "[run] Wait interrupted: $_"
        $script:CompanionShutdownRequested = $true
    } finally {
        Unregister-CompanionCancelHandler
        $reason = if ($script:CompanionShutdownRequested) { "Ctrl+C / shutdown" } else { "Chromium closed" }
        Invoke-CompanionGracefulFinish -Reason $reason
    }
    exit 0
}
