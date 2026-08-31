#Requires -Version 7.0
<#
.SYNOPSIS
  Dev reload: copy extension to LOCALAPPDATA + restart REST sink (no Chromium restart).

.DESCRIPTION
  1. Copy extension sources -> %LOCALAPPDATA%\pcloud_web_companion\extension
  2. Restart _rest_log_sink.ps1 (kills prior sink on same port)
  Then in Chromium: chrome://extensions -> Reload on "pCloud Download -> Loop Segments"
  and refresh my.pcloud.com tab.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$LocalExt = Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\extension'
$SinkScript = Join-Path $ScriptDir '_rest_log_sink.ps1'
$LogFile = Join-Path $ScriptDir 'rest.log'

function Wait-RestSinkHealth {
    param([int]$TimeoutSec = 25)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri 'http://127.0.0.1:18765/health' -TimeoutSec 2
            if ($health.ok) { return $true }
        } catch {
            # sink still starting (Add-Type + TCP bind can take several seconds)
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-RestSinkDetached {
    param(
        [string]$SinkScriptPath,
        [string]$LogFilePath,
        [int]$CompanionPid
    )
    $psExe = (Get-Command pwsh -ErrorAction Stop).Source
    $args = @(
        '-NoProfile', '-NoLogo', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $SinkScriptPath,
        '-LogFile', $LogFilePath,
        '-Port', '18765',
        '-CompanionPid', "$CompanionPid"
    )
    $quoted = ($args | ForEach-Object {
        $a = [string]$_
        if ($a -match '[\s"]') { '"' + ($a -replace '\\', '\\' -replace '"', '\"') + '"' } else { $a }
    }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = $quoted
    $psi.WorkingDirectory = $ScriptDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
}

function ConvertTo-ChromiumUnpackedExtensionId {
    param([Parameter(Mandatory = $true)][string]$ExtensionDir)
    $path = [System.IO.Path]::GetFullPath($ExtensionDir)
    if ($path.Length -ge 2 -and $path[1] -eq ':') {
        $path = [char]::ToUpperInvariant($path[0]) + $path.Substring(1)
    }
    $path = $path.TrimEnd('\')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::Unicode.GetBytes($path))
    } finally {
        $sha.Dispose()
    }
    $chars = [char[]]::new(32)
    for ($i = 0; $i -lt 16; $i++) {
        $chars[2 * $i] = [char]([int][char]'a' + ($digest[$i] -shr 4))
        $chars[(2 * $i) + 1] = [char]([int][char]'a' + ($digest[$i] -band 0xF))
    }
    return [string]::new($chars)
}

function Set-CompanionExtensionShortcuts {
    param(
        [string]$ExtensionDir,
        [string]$ProfileRoot
    )
    $pythonExe = 'P:\all_scripts\py_venv1\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $pythonExe = (Get-Command py -ErrorAction SilentlyContinue)?.Source
    }
    if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path -LiteralPath $ProfileRoot)) {
        Write-Warning '[dev] Skip shortcut pin (python or chromium profile missing)'
        return
    }
    $extId = ConvertTo-ChromiumUnpackedExtensionId -ExtensionDir $ExtensionDir
    $prefs = Join-Path $ProfileRoot 'Default\Preferences'
    $pyFile = Join-Path $env:TEMP 'loop-segments-chrome-prefs-dev.py'
    $py = @'
import json, os, sys
prefs_path, ext_id = sys.argv[1], sys.argv[2]
commands = [
    ("open-pcloud-on-p", "windows:Ctrl+E"),
    ("write-hybrid-media-list", "windows:Ctrl+Shift+H"),
]
if os.path.isfile(prefs_path):
    with open(prefs_path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    os.makedirs(os.path.dirname(prefs_path), exist_ok=True)
    data = {}
ext = data.setdefault("extensions", {})
pinned = ext.get("pinned_extensions") or []
pinned = [x for x in pinned if isinstance(x, str) and x != ext_id]
pinned.insert(0, ext_id)
ext["pinned_extensions"] = pinned
cmds = ext.setdefault("commands", {})
names = {n for n, _ in commands}
for key in list(cmds):
    item = cmds.get(key)
    if isinstance(item, dict) and item.get("extension") == ext_id and item.get("command_name") in names:
        del cmds[key]
for command_name, accel in commands:
    cmds[accel] = {"command_name": command_name, "extension": ext_id, "global": False}
tmp = prefs_path + ".tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
os.replace(tmp, prefs_path)
'@
    [System.IO.File]::WriteAllText($pyFile, $py, (New-Object System.Text.UTF8Encoding $false))
    & $pythonExe $pyFile $prefs $extId | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[dev] Pinned shortcuts Ctrl+E + Ctrl+Shift+H in Chromium profile"
    } else {
        Write-Warning '[dev] Shortcut pin failed — set manually at chrome://extensions/shortcuts'
    }
}

$files = @(
    'manifest.json', 'background.js', 'pcloud_fileid_hook_main.js', 'pcloud_folder_tracker.js',
    'offscreen.html', 'offscreen.js', 'logs.html', 'logs.js', 'icon.png', 'lan_config.json'
)

New-Item -ItemType Directory -Force -Path $LocalExt | Out-Null
foreach ($name in $files) {
    $src = Join-Path $ScriptDir $name
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Warning "Skip missing: $src"
        continue
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $LocalExt $name) -Force
}
Write-Host "[dev] Extension synced -> $LocalExt"
$profileRoot = Join-Path $env:LOCALAPPDATA 'pcloud_web_companion\chromium-profile'
Set-CompanionExtensionShortcuts -ExtensionDir $LocalExt -ProfileRoot $profileRoot

if (-not (Test-Path -LiteralPath $SinkScript -PathType Leaf)) {
    throw "Missing sink: $SinkScript"
}

Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*_rest_log_sink.ps1*' } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
Start-Sleep -Milliseconds 600

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
Write-Host "[dev] Starting REST sink (may take ~5-15s on cold start)..."
Start-RestSinkDetached -SinkScriptPath $SinkScript -LogFilePath $LogFile -CompanionPid $PID

if (Wait-RestSinkHealth -TimeoutSec 25) {
    Write-Host "[dev] Sink up: http://127.0.0.1:18765/health"
} else {
    Write-Warning "[dev] Sink health check timed out. Check tail of: $LogFile"
    if (Test-Path -LiteralPath $LogFile) {
        Get-Content -LiteralPath $LogFile -Tail 5 | ForEach-Object { Write-Host "  $_" }
    }
}

Write-Host @"

Next (Chromium still open):
  1. chrome://extensions  ->  Reload "pCloud Download -> Loop Segments"
  2. Refresh my.pcloud.com tab
  3. Select videos -> Ctrl+Shift+H  (H=hybrid; not Ctrl+Shift+D=pCloud download, Ctrl+D=bookmark)
     Or: Shift+right-click page -> "Write hybrid media_files.txt"
     Or: extension popup -> Write hybrid media_files.txt

"@
