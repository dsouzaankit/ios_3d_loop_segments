#Requires -Version 5.1
# Helper: keep Sideloadly Daemon running while iPhone is on USB.
# Started by Register-SideloadlyAutoRefresh.ps1 -WatchUsb (logon task).
# The daemon performs actual app refresh when device is detected — not this script.

$ErrorActionPreference = 'SilentlyContinue'

function Get-SideloadlyDaemonPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Sideloadly\SideloadlyDaemon.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Sideloadly\SideloadlyDaemon.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $found = Get-ChildItem -Path $env:LOCALAPPDATA -Filter 'SideloadlyDaemon.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Test-IphoneUsbConnected {
    $devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'OK' -and $_.FriendlyName -match 'Apple Mobile Device|Apple iPhone|iPad'
        })
    return ($devices.Count -gt 0)
}

$daemon = Get-SideloadlyDaemonPath
if (-not $daemon) { exit 0 }

# Poll for 8 hours after logon (re-launched next logon by scheduled task).
$deadline = [DateTime]::UtcNow.AddHours(8)
while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-IphoneUsbConnected) {
        $proc = Get-Process -Name 'SideloadlyDaemon' -ErrorAction SilentlyContinue
        if (-not $proc) {
            Start-Process -FilePath $daemon -WindowStyle Hidden
        }
    }
    Start-Sleep -Seconds 120
}
