#Requires -Version 5.1
<#
.SYNOPSIS
  Shared AltServer locate / start / warn helpers for Loop Segments Windows scripts.

.DESCRIPTION
  Dot-source from Launch-LoopSegmentsViaUsb.ps1, run_chromium.ps1, Setup, etc.
  AltServer is required for AltStore to refresh Personal Team / free-developer
  installs. Without weekly refresh, Loop Segments stops opening after ~7 days.
#>

function Get-LoopSegmentsAltServerPath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'AltServer\AltServer.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'AltServer\AltServer.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\AltServer\AltServer.exe')
        (Join-Path $env:LOCALAPPDATA 'AltServer\AltServer.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $roots = @($env:LOCALAPPDATA, ${env:ProgramFiles})
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter 'AltServer.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Test-LoopSegmentsAltServerRunning {
    return [bool]@(Get-Process -Name 'AltServer' -ErrorAction SilentlyContinue).Count
}

function Get-LoopSegmentsAppUnavailableResolution {
    return @"
When Loop Segments becomes unavailable (won't open / "Unable to Verify App" /
"Unable to Trust iPhone Developer: you@email" / USB launch blocked by signature):
  1. Install/start AltServer on this PC (https://altstore.io) - tray icon should be visible.
  2. Plug the iPhone in over USB, unlock it, Trust This Computer.
  3. Open AltStore on the phone -> My Apps -> Refresh All (or refresh Loop Segments).
  4. Trust the developer certificate on the phone (your Apple ID email under DEVELOPER APP):
       Settings -> General -> VPN & Device Management
       -> tap "iPhone Developer: <your Apple ID email>"
       -> Trust "<your Apple ID email>" -> Trust (confirm popup)
     If Loop Segments / that email is not listed yet: wait for AltStore "Complete",
     open (or fail-open) the app once, leave Settings and return - the DEVELOPER APP
     entry often appears only then; trust it and open the app again.
  5. Open Loop Segments once by hand, then re-run the companion / USB launch script.
Wi-Fi background refresh only works if AltServer is running and AltStore Background App Refresh
is on; on Windows 11, USB + Refresh All weekly is the reliable path.
See ios/BUILD-WITHOUT-MAC.md (Trust the developer on iPhone).
"@
}

function Get-LoopSegmentsAltServerSevenDayWarning {
    return @"
Without AltServer + AltStore refresh, a free / Personal Team sideload of Loop Segments
expires in about 7 days: the app icon may still show, but opens fail until you refresh.

$(Get-LoopSegmentsAppUnavailableResolution)
Install AltServer: https://altstore.io
Optional: .\Register-AltServerAtLogon.ps1  (tray at logon)
"@
}

function Write-LoopSegmentsAltServerNotice {
    param(
        # When true, print a short OK line if AltServer is installed (running or not).
        [switch] $AlwaysStatus,
        # Always print how to fix the app when it becomes unavailable (~7-day expiry).
        [switch] $IncludeResolution
    )

    $path = Get-LoopSegmentsAltServerPath
    if (-not $path) {
        Write-Host ""
        Write-Host "[altserver] NOT INSTALLED on this PC." -ForegroundColor Yellow
        Write-Host (Get-LoopSegmentsAltServerSevenDayWarning) -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    $running = Test-LoopSegmentsAltServerRunning
    if ($AlwaysStatus) {
        if ($running) {
            Write-Host "[altserver] Running: $path"
        } else {
            Write-Host "[altserver] Installed but not running: $path" -ForegroundColor DarkYellow
            Write-Host "[altserver] Needed for AltStore refresh so Loop Segments does not die after ~7 days." -ForegroundColor DarkYellow
        }
    }
    if ($IncludeResolution -or $AlwaysStatus) {
        Write-Host "[altserver] If Loop Segments becomes unavailable after ~7 days:" -ForegroundColor DarkYellow
        Write-Host "  Start AltServer -> USB + unlock -> AltStore Refresh All -> open app once." -ForegroundColor DarkYellow
        Write-Host "  Trust developer cert: Settings -> General -> VPN & Device Management" -ForegroundColor DarkYellow
        Write-Host "    -> DEVELOPER APP -> iPhone Developer: <your Apple ID email> -> Trust -> Trust" -ForegroundColor DarkYellow
        Write-Host "    (If not listed yet: AltStore Complete -> open/fail-open app once -> return to Settings and trust.)" -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{
        Installed = $true
        Running   = $running
        Path      = $path
        Started   = $false
    }
}

function Start-LoopSegmentsAltServer {
    param(
        [int] $WaitSeconds = 3
    )

    $path = Get-LoopSegmentsAltServerPath
    if (-not $path) {
        Write-Host ""
        Write-Host "[altserver] NOT INSTALLED - cannot start it for USB recovery." -ForegroundColor Yellow
        Write-Host (Get-LoopSegmentsAltServerSevenDayWarning) -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    if (Test-LoopSegmentsAltServerRunning) {
        Write-Host "[altserver] Already running: $path"
        return [pscustomobject]@{
            Installed = $true
            Running   = $true
            Path      = $path
            Started   = $false
        }
    }

    Write-Host "[altserver] Starting AltServer (USB detect failed / recovery): $path"
    try {
        Start-Process -FilePath $path | Out-Null
    } catch {
        Write-Warning "[altserver] Start failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            Installed = $true
            Running   = $false
            Path      = $path
            Started   = $false
        }
    }

    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $WaitSeconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-LoopSegmentsAltServerRunning) { break }
        Start-Sleep -Milliseconds 400
    }
    $running = Test-LoopSegmentsAltServerRunning
    if ($running) {
        Write-Host "[altserver] Started OK"
    } else {
        Write-Warning "[altserver] Process not seen yet; continuing anyway"
    }
    return [pscustomobject]@{
        Installed = $true
        Running   = $running
        Path      = $path
        Started   = $true
    }
}

function Test-LoopSegmentsUsbmuxListHasDevice {
    param(
        [int] $ExitCode,
        [string[]] $Lines
    )
    if ($ExitCode -ne 0) { return $false }
    $text = (@($Lines) | ForEach-Object { [string]$_ }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -match '(?i)no devices?|device not found|unable to connect') { return $false }
    # Empty JSON array from usbmux list.
    if ($text -match '(?s)^\s*\[\s*\]\s*$') { return $false }
    # Heuristic: any JSON object / Identifier / UDID-looking token.
    if ($text -match '"UniqueDeviceID"|"SerialNumber"|"DeviceName"|[0-9A-Fa-f]{40}') { return $true }
    if ($text -match '\{') { return $true }
    return $false
}
