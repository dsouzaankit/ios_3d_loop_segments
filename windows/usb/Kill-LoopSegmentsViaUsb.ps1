# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Force-quit Loop Segments on a USB-connected iPhone (DVT kill).

.DESCRIPTION
  Kills the Loop Segments process over USB via pymobiledevice3 DVT
  (ProcessControl.kill). That tears down Keep Alive audio and the phone LAN
  page (:8765). USB Home only backgrounds the app — Keep Alive can keep LAN
  up — so a full kill is the reliable way to stop the LAN server from the PC.

  Works whether the app is foreground or background (unlike
  Probe-LoopSegmentsForeground.py --kill, which only kills when foreground).

  Bundle id: com.loopsegments.app* (AltStore/SideStore team suffix) or process
  name "Loop Segments".

.PARAMETER SkipLanCheck
  Do not wait / probe whether :8765 went down after the kill.

.PARAMETER LanWaitSec
  After a kill, poll the phone LAN page until it is down (default 15 s). 0 = no wait.

.PARAMETER PhoneLanHost
  Host for the post-kill LAN check (default: phoneLanHost from
  loop-segments-windows.json / companion lan_config.json).

.PARAMETER LanPort
  Port for the post-kill LAN check (default 8765 / lanPort from settings).

.PARAMETER NoWaitEnter
  When embedded (companion): throw KILL_USB_EXIT:<code> instead of exit, and
  never wait for Enter.

.EXITCODES
  0  Killed, or app was not running
  1  Kill / tooling failure
  2  No USB device

.EXAMPLE
  .\Kill-LoopSegmentsViaUsb.ps1

.EXAMPLE
  .\Kill-LoopSegmentsViaUsb.ps1 -SkipLanCheck
#>
[CmdletBinding()]
param(
    [switch] $SkipLanCheck,
    [int] $LanWaitSec = 15,
    [string] $PhoneLanHost = '',
    [int] $LanPort = 0,
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PwshHelper = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Get-LoopSegmentsPwsh.ps1"
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$PythonHelper = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Get-LoopSegmentsPython.ps1"
if (-not (Test-Path -LiteralPath $PythonHelper)) {
    throw "Missing shared Python helper: $PythonHelper"
}
. $PythonHelper

$WindowsLib = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\LoopSegments-Windows.ps1"
if (Test-Path -LiteralPath $WindowsLib) {
    . $WindowsLib
}

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-Kill {
    param([int] $ExitCode)
    if ($ExitCode -ne 0 -and $ExitCode -ne 2) {
        Wait-EnterToClose
    }
    if ($NoWaitEnter) {
        throw "KILL_USB_EXIT:$ExitCode"
    }
    exit $ExitCode
}

function Resolve-KillLanEndpoint {
    $hostName = [string]$PhoneLanHost
    $port = if ($LanPort -gt 0) { $LanPort } else { 8765 }
    if ([string]::IsNullOrWhiteSpace($hostName) -and (Get-Command Get-LoopSegmentsWindowsSettings -ErrorAction SilentlyContinue)) {
        try {
            $s = Get-LoopSegmentsWindowsSettings
            if (-not [string]::IsNullOrWhiteSpace([string]$s.phoneLanHost)) {
                $hostName = [string]$s.phoneLanHost
            }
            if ($LanPort -le 0 -and $null -ne $s.lanPort -and [int]$s.lanPort -gt 0) {
                $port = [int]$s.lanPort
            }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $lanConfig = Join-Path (Split-Path -Parent $PSScriptRoot) "pcloud_web_companion\lan_config.json"
        if (Test-Path -LiteralPath $lanConfig) {
            try {
                $lan = Get-Content -LiteralPath $lanConfig -Raw | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$lan.phoneLanHost)) {
                    $hostName = [string]$lan.phoneLanHost
                }
                if ($LanPort -le 0 -and $null -ne $lan.lanPort -and [int]$lan.lanPort -gt 0) {
                    $port = [int]$lan.lanPort
                }
            } catch {}
        }
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) { return $null }
    return [pscustomobject]@{ Host = $hostName.Trim(); Port = $port }
}

function Test-KillLanPageUp {
    param([string]$HostName, [int]$Port)
    $uri = "http://${HostName}:${Port}/"
    try {
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method = 'GET'
        $req.Timeout = 2000
        $req.ReadWriteTimeout = 2000
        $req.AllowAutoRedirect = $false
        $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
        if (Get-Command Get-LoopSegmentsPhoneWebDavAuthHeader -ErrorAction SilentlyContinue) {
            $auth = Get-LoopSegmentsPhoneWebDavAuthHeader
            foreach ($key in $auth.Keys) { $req.Headers[$key] = [string]$auth[$key] }
        }
        $resp = $null
        try {
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            return ($code -ge 200 -and $code -lt 500)
        } catch [System.Net.WebException] {
            if ($null -ne $_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
                return ($code -ge 200 -and $code -lt 500)
            }
            return $false
        } finally {
            if ($null -ne $resp) {
                try { $resp.Close() } catch {}
                try { $resp.Dispose() } catch {}
            }
        }
    } catch {
        return $false
    }
}

$rt = Get-LoopSegmentsPythonRuntime
if (-not $rt) {
    Write-Host @"
Python not found (need 3.9-3.13; prefer 3.12).

$(Get-LoopSegmentsPythonInstallHint)
"@ -ForegroundColor Red
    Exit-Kill 1
}

Write-Host "Using $($rt.Display) ($($rt.Exe))"
$infoPy = Join-Path $PSScriptRoot "LoopSegments-UsbInfo.py"
if (-not (Test-Path -LiteralPath $infoPy)) {
    Write-Host "[kill] Missing $infoPy" -ForegroundColor Red
    Exit-Kill 1
}

Write-Host "[kill] Quitting Loop Segments over USB (DVT kill — stops Keep Alive / :8765)..."
$result = Invoke-LoopSegmentsPythonRuntime -Runtime $rt -ArgumentList @($infoPy, 'quit-loopsegments')
foreach ($line in @($result.Lines)) {
    if ($line) { Write-Host $line }
}
$blob = ($result.Lines -join "`n")

if ($blob -match '(?m)^NO_DEVICE\b' -or $result.ExitCode -eq 2) {
    Write-Host "[kill] No iPhone on USB." -ForegroundColor Yellow
    Exit-Kill 2
}
if ($blob -match '(?m)^STILL_RUNNING\b') {
    Write-Host "[kill] Process still running after kill+SIGKILL — LAN page may stay up. Unlock phone / Developer Mode / retry." -ForegroundColor Red
    Exit-Kill 1
}
if ($blob -match '(?m)^ERROR\b' -or ($result.ExitCode -ne 0 -and $blob -notmatch '(?m)^QUIT\b' -and $blob -notmatch '(?m)^NOT_RUNNING\b')) {
    Write-Host "[kill] Quit failed." -ForegroundColor Red
    Exit-Kill 1
}

if ($blob -match '(?m)^NOT_RUNNING\b') {
    Write-Host "[kill] Loop Segments was not running." -ForegroundColor DarkGray
} elseif ($blob -match '(?m)^QUIT\t([^\t]+)') {
    Write-Host ("[kill] Killed pid(s): {0}" -f $Matches[1]) -ForegroundColor Green
} else {
    Write-Host "[kill] Done." -ForegroundColor Green
}

$lanFailed = $false
if (-not $SkipLanCheck -and $LanWaitSec -gt 0) {
    $ep = Resolve-KillLanEndpoint
    if ($null -eq $ep) {
        Write-Host "[kill] No phoneLanHost configured — skip LAN-down check." -ForegroundColor DarkGray
    } else {
        Write-Host ("[kill] Waiting up to {0}s for http://{1}:{2}/ to go down..." -f $LanWaitSec, $ep.Host, $ep.Port)
        $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $LanWaitSec))
        $down = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not (Test-KillLanPageUp -HostName $ep.Host -Port $ep.Port)) {
                $down = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if ($down) {
            Write-Host "[kill] LAN page is down." -ForegroundColor Green
        } else {
            Write-Warning "[kill] LAN page still responding after kill — process may have respawned, or host/port is wrong."
            $lanFailed = $true
        }
    }
}

if ($lanFailed) {
    Exit-Kill 1
}
Exit-Kill 0
