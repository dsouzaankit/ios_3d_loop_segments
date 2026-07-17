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
    [string]$StartUrl = "https://my.pcloud.com"
)

$ErrorActionPreference = "Stop"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { throw "Cannot resolve script directory; run with: powershell -File `"$($MyInvocation.MyCommand.Path)`"" }

$ExtensionDir = $ScriptDir
$ManifestPath = Join-Path $ExtensionDir "manifest.json"
$VenvDir = Join-Path $ScriptDir ".venv"
$PythonExe = Join-Path $VenvDir "Scripts\python.exe"
$Requirements = Join-Path $ScriptDir "requirements.txt"
$DepsStamp = Join-Path $VenvDir ".deps_requirements_sha256.txt"

# Prefer project-local browsers when present; otherwise %LOCALAPPDATA%\ms-playwright.
# Chromium must use a local disk profile (not P:). We sync that folder to/from the repo each run.
$LocalBrowsers = Join-Path $ScriptDir ".playwright-browsers"
$UserDataDir = Join-Path $env:LOCALAPPDATA "pcloud_web_companion\chromium-profile"
$RepoProfileDir = Join-Path $ScriptDir "chromium-profile"

if (-not (Test-Path $ManifestPath)) {
    throw "Extension manifest not found: $ManifestPath"
}

if (Test-Path $LocalBrowsers) {
    $env:PLAYWRIGHT_BROWSERS_PATH = $LocalBrowsers
    $PlaywrightCache = $LocalBrowsers
    Write-Host "[playwright] Using local browser path: $PlaywrightCache"
} else {
    Remove-Item Env:PLAYWRIGHT_BROWSERS_PATH -ErrorAction SilentlyContinue
    $PlaywrightCache = Join-Path $env:LOCALAPPDATA "ms-playwright"
    Write-Host "[playwright] Using default browser cache: $PlaywrightCache"
}

if ($RecreateVenv -and (Test-Path $VenvDir)) {
    Write-Host "[venv] Removing existing $VenvDir"
    Remove-Item -Recurse -Force $VenvDir
}

if (-not (Test-Path $PythonExe)) {
    Write-Host "[venv] Creating virtualenv at $VenvDir"
    py -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw "py -m venv failed (exit $LASTEXITCODE)" }
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
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile"
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        $sinkScript
        "-LogFile"
        $logFile
        "-Port"
        "18765"
    ) | Out-Null

    Start-Sleep -Milliseconds 400
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:18765/health" -UseBasicParsing -TimeoutSec 2
        Write-Host "[rest-log] Sink OK ($($health.StatusCode))"
    } catch {
        Write-Warning "[rest-log] Sink not reachable yet: $_"
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

    # Prefer /browse (companion target); fall back to /status.json.
    $paths = @("/browse", "/status.json")
    foreach ($path in $paths) {
        $uri = "http://${hostName}:${port}${path}"
        try {
            Write-Host "[lan] Probing $uri ..."
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
    if ($code -ne 0) {
        throw @"
[usb] Launch-LoopSegmentsViaUsb.ps1 failed (exit $code). Fix USB / Developer Mode / cert trust, then re-run.
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
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.IndexOf($ProfileDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })

    foreach ($proc in $procs) {
        Write-Host "[cleanup] Stopping PID $($proc.ProcessId)"
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }

    if ($procs.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
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
    # robocopy: 0-7 = success / no fatal error
    if ($rc -ge 8) {
        Write-Warning "[profile] $Direction robocopy exit $rc (see robocopy docs)"
    } else {
        Write-Host "[profile] $Direction OK (robocopy=$rc)"
    }

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

function Wait-ProfileChromiumExit {
    param([string]$ProfileDir)

    Write-Host "[run] Waiting for Chromium to exit (will upload profile to repo, then clear local)..."
    Write-Host "      Close the browser window when finished. Ctrl+C skips wait (upload on next run)."
    while ($true) {
        $still = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine.IndexOf($ProfileDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            })
        if ($still.Count -eq 0) {
            Write-Host "[run] Chromium exited"
            return
        }
        Start-Sleep -Seconds 2
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
} else {
    try {
        Wait-ProfileChromiumExit -ProfileDir $UserDataDir
    } catch {
        Write-Warning "[run] Wait interrupted: $_"
    }
    Stop-ProfileChromium -ProfileDir $UserDataDir
    Start-Sleep -Milliseconds 500
    Sync-ChromiumProfile -Direction Upload
    Write-Host "[run] Profile synced to $RepoProfileDir"
    Clear-LocalProfileMinimal -ProfileDir $UserDataDir
}
