# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
<#
.SYNOPSIS
  Start a Cloudflare quick tunnel to the configured phone LAN page (:8765).

.DESCRIPTION
  Reads phoneLanHost + lanPort from loop-segments-windows.json (or -PhoneHost / -Port).
  Runs: cloudflared tunnel --url http://<phone>:<port>

  Prints the randomized https://*.trycloudflare.com URL (and host alone) for the
  LAN page Cloudflare tunnel textbox → Update links. Copies the host to the clipboard
  when possible. Writes %TEMP%\loopsegments-cf-tunnel-url.txt.

  Leave this window open while using Quest WebXR. Ctrl+C stops the tunnel (URL dies).

  Prefer: pwsh -File .\lan\Start-LoopSegmentsCloudflareTunnel.ps1
  Opening under Windows PowerShell 5.1 re-launches pwsh.

.EXAMPLE
  .\lan\Start-LoopSegmentsCloudflareTunnel.ps1

.EXAMPLE
  .\lan\Start-LoopSegmentsCloudflareTunnel.ps1 -PhoneHost 10.0.100.10 -SkipLanProbe
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [int] $Port = 0,
    [string] $CloudflaredExe = '',
    [switch] $SkipLanProbe,
    [switch] $NoClipboard,
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ''
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

trap {
    Write-Host ''
    Write-Host ("[cf-tunnel] ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Wait-EnterToClose
    break
}

$Lib = Join-Path $PSScriptRoot '..\lib\LoopSegments-Windows.ps1'
if (-not (Test-Path -LiteralPath $Lib)) {
    throw "Missing $Lib"
}
. $Lib

function Resolve-LoopSegmentsCloudflaredExe {
    param([string] $Override = '')
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $p = $Override.Trim()
        if (-not (Test-Path -LiteralPath $p)) {
            throw "cloudflared not found at -CloudflaredExe path: $p"
        }
        return (Resolve-Path -LiteralPath $p).Path
    }
    $cmd = Get-Command -Name cloudflared.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }
    $cmdBare = Get-Command -Name cloudflared -ErrorAction SilentlyContinue
    if ($null -ne $cmdBare -and -not [string]::IsNullOrWhiteSpace([string]$cmdBare.Source)) {
        return [string]$cmdBare.Source
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'cloudflared\cloudflared.exe')
        (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'cloudflared\cloudflared.exe')
        (Join-Path $env:USERPROFILE 'bin\cloudflared.exe')
        (Join-Path $env:USERPROFILE '.cloudflared\cloudflared.exe')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }
    throw @'
cloudflared not found on PATH.

Install (winget):
  winget install --id Cloudflare.cloudflared -e

Or download: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
Then re-run this script (or pass -CloudflaredExe path\to\cloudflared.exe).
'@
}

function Test-LoopSegmentsPhoneLanReachable {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $PortNum,
        [int] $TimeoutMs = 2500
    )
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($HostName, $PortNum, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) {
            $client.Close()
            return $false
        }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

$cf = Resolve-LoopSegmentsCloudflaredExe -Override $CloudflaredExe
$hostIp = Get-LoopSegmentsLANHost -Override $PhoneHost
$portNum = Get-LoopSegmentsLanPort -Override $Port
$origin = "http://${hostIp}:${portNum}"
$urlFile = Join-Path $env:TEMP 'loopsegments-cf-tunnel-url.txt'

Write-Host ''
Write-Host 'Cloudflare quick tunnel → phone LAN page' -ForegroundColor Cyan
Write-Host ("  phoneLanHost : {0}" -f $hostIp)
Write-Host ("  lanPort      : {0}" -f $portNum)
Write-Host ("  origin       : {0}" -f $origin)
Write-Host ("  cloudflared  : {0}" -f $cf)
Write-Host ("  Quest        : open {0}/ on headset → paste tunnel host → Update links → XR" -f $origin)
Write-Host ''

if (-not $SkipLanProbe) {
    Write-Host ("[cf-tunnel] Probing {0} ..." -f $origin) -ForegroundColor DarkGray
    if (-not (Test-LoopSegmentsPhoneLanReachable -HostName $hostIp -PortNum $portNum)) {
        throw "Phone LAN not reachable at ${origin}. Start Loop Segments LAN server, or fix phoneLanHost (.\setup\Set-LoopSegmentsLANHost.ps1). Pass -SkipLanProbe to tunnel anyway."
    }
    Write-Host '[cf-tunnel] LAN TCP OK' -ForegroundColor Green
}

Write-Host '[cf-tunnel] Starting quick tunnel (leave this window open; Ctrl+C to stop)...' -ForegroundColor Yellow
Write-Host ''

$script:TunnelHttpsUrl = ''
$script:TunnelHost = ''
$urlPattern = [regex]'https://[a-zA-Z0-9.-]+\.trycloudflare\.com'

function Publish-LoopSegmentsTunnelUrl {
    param([Parameter(Mandatory = $true)][string] $HttpsUrl)
    $u = $HttpsUrl.Trim().TrimEnd('/')
    if ($script:TunnelHttpsUrl -eq $u) { return }
    $script:TunnelHttpsUrl = $u
    try {
        $script:TunnelHost = ([uri]$u).Host
    } catch {
        $script:TunnelHost = ($u -replace '^https://', '')
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '  Cloudflare tunnel ready' -ForegroundColor Green
    Write-Host ("  HTTPS : {0}" -f $script:TunnelHttpsUrl) -ForegroundColor Green
    Write-Host ("  Host  : {0}  ← paste into LAN page textbox" -f $script:TunnelHost) -ForegroundColor Green
    Write-Host ("  XR    : {0}/xr" -f $script:TunnelHttpsUrl) -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host ("On Quest Browser: {0}/  → Cloudflare tunnel field → Update links → Open XR chroma" -f $origin) -ForegroundColor Cyan
    Write-Host ''

    try {
        @(
            $script:TunnelHttpsUrl
            $script:TunnelHost
            ("{0}/xr" -f $script:TunnelHttpsUrl)
        ) | Set-Content -LiteralPath $urlFile -Encoding utf8
        Write-Host ("[cf-tunnel] Wrote {0}" -f $urlFile) -ForegroundColor DarkGray
    } catch {
        Write-Host ("[cf-tunnel] Could not write URL file: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    if (-not $NoClipboard) {
        try {
            Set-Clipboard -Value $script:TunnelHost
            Write-Host '[cf-tunnel] Copied host to clipboard' -ForegroundColor DarkGray
        } catch {
            Write-Host '[cf-tunnel] Clipboard unavailable (host still printed above)' -ForegroundColor DarkYellow
        }
    }
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $cf @('tunnel', '--url', $origin, '--no-autoupdate') 2>&1 | ForEach-Object {
        $line = "$_"
        Write-Host $line
        $m = $urlPattern.Match($line)
        if ($m.Success) {
            Publish-LoopSegmentsTunnelUrl -HttpsUrl $m.Value
        }
    }
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
} finally {
    $ErrorActionPreference = $prevEap
}

if ([string]::IsNullOrWhiteSpace($script:TunnelHttpsUrl)) {
    Write-Host '[cf-tunnel] No trycloudflare.com URL was seen in cloudflared output.' -ForegroundColor Yellow
}

if ($exitCode -ne 0) {
    throw "cloudflared exited with code $exitCode"
}

Write-Host '[cf-tunnel] Tunnel process ended.' -ForegroundColor DarkGray
Wait-EnterToClose
