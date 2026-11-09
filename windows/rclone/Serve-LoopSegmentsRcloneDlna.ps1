# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
<#
.SYNOPSIS
  Expose the phone LAN WebDAV tree as an rclone DLNA media server (Quest / Skybox Network).

.DESCRIPTION
  Loop Segments on the phone serves HTTP + WebDAV on port 8765 (Basic auth admin / the per-install password from the app's Export screen).
  This script writes/updates a [loopsegments] block in rclone.conf and runs:
    rclone serve dlna loopsegments:pcld_ios_media  (or remote root if that folder is missing)

  Prefer this over mapping the WinFsp L: mount into Skybox AirScreen Add-folders — AirScreen
  over a remote WinFsp letter is unreliable; DLNA discovery is the Quest-facing path.

  Per-PC settings: loop-segments-windows.json (rcloneDlnaAddr, rcloneDlnaName, phone LAN, etc.).

.PARAMETER Remove
  Stop rclone serve dlna processes for the loopsegments remote (and this script's consoles).

.PARAMETER Quick
  Skip rclone ls; HTTP status.json + remote config only (companion default).

.PARAMETER NoLanWatch
  Keep serve in the foreground until Ctrl+C without polling phone LAN.

.EXAMPLE
  .\Serve-LoopSegmentsRcloneDlna.ps1 -TestOnly
  .\Serve-LoopSegmentsRcloneDlna.ps1
  .\Serve-LoopSegmentsRcloneDlna.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string] $PhoneHost = '',
    [int] $Port = 0,
    [string] $RemoteName = '',
    [string] $WebDAVUser = '',
    [string] $WebDAVPassword = '',
    [string] $Addr = '',
    [string] $FriendlyName = '',
    [switch] $Remove,
    [switch] $TestOnly,
    [switch] $Quick,
    [ValidateRange(5, 600)]
    [int] $LanPollSeconds = 15,
    [ValidateRange(15, 3600)]
    [int] $LanDownSeconds = 60,
    [switch] $NoLanWatch,
    [switch] $SkipOffSubnetRouterReboot,
    # Companion: no interactive console needed (rclone CreateNoWindow; script may still host).
    [switch] $Hidden,
    [switch] $NoWaitEnter
)

$ErrorActionPreference = 'Stop'
try {
    $Host.UI.RawUI.WindowTitle = 'Loop Segments — rclone DLNA'
} catch {}
Write-Host '[rclone-dlna] Starting…' -ForegroundColor Cyan

$PwshHelper = Join-Path $PSScriptRoot '..\lib\Get-LoopSegmentsPwsh.ps1'
if (-not (Test-Path -LiteralPath $PwshHelper)) {
    throw "Missing $PwshHelper"
}
. $PwshHelper
Ensure-LoopSegmentsPwshHost -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

. "$PSScriptRoot\..\lib\LoopSegments-Windows.ps1"

function Ensure-RcloneRemote {
    param(
        [string] $Name,
        [string] $Url,
        [string] $User,
        [string] $Pass
    )

    $inv = Get-RcloneInvocation
    $args = @()
    if ($inv.PrefixArgs) { $args += $inv.PrefixArgs }
    $args += 'obscure', $Pass
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $obscured = (& $inv.Exe @args 2>&1 | Out-String).Trim()
    $ErrorActionPreference = $prev
    if ($LASTEXITCODE -ne 0) {
        throw "rclone obscure failed: $obscured"
    }

    $configPath = (Get-RcloneInvocation).ConfigPath
    $block = @"
[$Name]
type = webdav
url = $Url
vendor = other
user = $User
pass = $obscured

"@

    if (Test-Path -LiteralPath $configPath) {
        $text = Get-Content -LiteralPath $configPath -Raw
        $pattern = "(?ms)^\[$([regex]::Escape($Name))\].*?(?=^\[|\z)"
        if ($text -match $pattern) {
            $text = [regex]::Replace($text, $pattern, $block.TrimEnd() + "`r`n`r`n")
        } else {
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
            $text += "`r`n" + $block
        }
        Set-Content -LiteralPath $configPath -Value $text -Encoding UTF8 -NoNewline
    } else {
        Set-Content -LiteralPath $configPath -Value $block -Encoding UTF8
    }
    Write-Host "rclone remote '$Name' -> $Url"
    Write-Host "Config: $configPath"
}

function Invoke-WebDavRequest {
    param(
        [string] $Uri,
        [string] $Method,
        [hashtable] $Headers = @{},
        [string] $Body = '',
        [int] $TimeoutSec = 20
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    foreach ($key in $Headers.Keys) {
        if ($key -ieq 'Authorization') {
            $request.Headers['Authorization'] = [string]$Headers[$key]
        } else {
            $request.Headers[$key] = [string]$Headers[$key]
        }
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = 'text/xml; charset=utf-8'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Close()
        }
    }
    try {
        return $request.GetResponse()
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            return $_.Exception.Response
        }
        throw
    }
}

function Test-PhoneLANExport {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )

    $base = "http://${HostName}:${PortNum}/"
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    $headers = @{ Authorization = "Basic $pair" }

    Write-Host "Checking $base ..."
    try {
        $r = Invoke-WebRequest -Uri ($base + 'status.json') -Headers $headers -TimeoutSec 15 -UseBasicParsing
        Write-Host "  GET status.json -> $($r.StatusCode)"
    } catch {
        throw "Phone not reachable at $base (same Wi-Fi? LAN server on? app in foreground?). $($_.Exception.Message)"
    }

    try {
        $r = Invoke-WebRequest -Uri $base -Method 'OPTIONS' -Headers $headers -TimeoutSec 15 -UseBasicParsing
        Write-Host "  OPTIONS (WebDAV) -> $($r.StatusCode)"
    } catch {
        Write-Warning "  OPTIONS failed: $($_.Exception.Message)"
    }
}

function Invoke-OffSubnetRouterRebootsForLanRecovery {
    param([string] $PhoneLanHost = '')
    if ($SkipOffSubnetRouterReboot) {
        Write-Host '[lan-recover] Skipping phone LAN recovery (-SkipOffSubnetRouterReboot)'
        return $false
    }
    $recoverPs1 = Join-Path $script:LoopSegmentsWindowsRoot 'lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $recoverPs1)) {
        Write-Warning "[lan-recover] Missing $recoverPs1 — cannot recover unreachable phone LAN"
        return $false
    }

    Write-Host '[lan-recover] Phone LAN page not reachable - recovering onto the expected subnet...'
    $prevEap = $ErrorActionPreference
    $code = 0
    try {
        if (-not [string]::IsNullOrWhiteSpace($PhoneLanHost)) {
            & $recoverPs1 -WaitBeforeRebootSec 0 -NoWaitEnter -PhoneLanHost $PhoneLanHost
        } else {
            & $recoverPs1 -WaitBeforeRebootSec 0 -NoWaitEnter
        }
        $code = 0
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match 'LAN_RECOVER_EXIT:(\d+)') {
            $code = [int]$Matches[1]
        } else {
            throw
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        Write-Warning "[lan-recover] Phone LAN recover failed (exit $code)"
        return $false
    }
    return $true
}

function Test-PhoneLANExportWithOffSubnetRecovery {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )
    try {
        Test-PhoneLANExport -HostName $HostName -PortNum $PortNum -User $User -Pass $Pass
        return
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -notmatch '(?i)not reachable|timed out|unable to connect|actively refused|No such host|could not be resolved') {
            throw
        }
        Write-Warning "[rclone-dlna] $msg"
        if (-not (Invoke-OffSubnetRouterRebootsForLanRecovery -PhoneLanHost $HostName)) {
            throw
        }
        Write-Host '[rclone-dlna] Retrying phone LAN page after phone-LAN recover...'
        Start-Sleep -Seconds 5
        Test-PhoneLANExport -HostName $HostName -PortNum $PortNum -User $User -Pass $Pass
    }
}

function Test-RcloneWebDAVRemote {
    param([string] $Name)
    Write-Host "rclone ls ${Name}: (WebDAV list) ..."
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Invoke-LoopSegmentsRclone ls "${Name}:" --max-depth 1 | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($code -ne 0) {
        throw "rclone could not list ${Name}:"
    }
    Write-Host '  Phone Exports visible via WebDAV - good'
}

function Test-PhoneLanHasPcldIosMediaFolder {
    param(
        [string] $HostName,
        [int] $PortNum,
        [string] $User,
        [string] $Pass
    )
    $uri = "http://${HostName}:${PortNum}/pcld_ios_media/"
    $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    $headers = @{
        Authorization = "Basic $pair"
        Depth         = '0'
    }
    $body = '<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>'
    $response = $null
    try {
        $response = Invoke-WebDavRequest -Uri $uri -Method 'PROPFIND' -Headers $headers -Body $body -TimeoutSec 12
        $status = [int]$response.StatusCode
        return ($status -ge 200 -and $status -lt 400)
    } catch {
        return $false
    } finally {
        if ($null -ne $response) {
            try { $response.Close() } catch {}
        }
    }
}

function Wait-EnterOnError {
    param([int] $ExitCode = 1)
    if ($NoWaitEnter) {
        exit $ExitCode
    }
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
    exit $ExitCode
}

function Test-PhoneLanAlive {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $PortNum,
        [int] $TimeoutMs = 2500
    )

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $PortNum, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $tcp.EndConnect($iar)
    } catch {
        return $false
    } finally {
        if ($null -ne $tcp) {
            try { $tcp.Close() } catch {}
        }
    }

    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://${HostName}:${PortNum}/status.json")
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        return ($code -ge 200 -and $code -lt 500)
    } catch [System.Net.WebException] {
        # 401 = server up but login refused; still reachable.
        $r = $_.Exception.Response
        return ($null -ne $r -and [int]$r.StatusCode -lt 500)
    } catch {
        return $false
    } finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch {}
            try { $resp.Dispose() } catch {}
        }
    }
}

function ConvertTo-RcloneArgumentString {
    param([Parameter(Mandatory = $true)][string[]] $Args)
    return (($Args | ForEach-Object {
        $s = [string]$_
        if ($s -match '[\s"]') {
            '"' + ($s.Replace('"', '\"')) + '"'
        } else {
            $s
        }
    }) -join ' ')
}

function Get-LoopSegmentsRcloneDlnaLogPath {
    Join-Path $env:TEMP 'loopsegments-rclone-dlna.log'
}

function Find-LoopSegmentsRcloneDlnaProcess {
    param([string] $RemoteName = 'loopsegments')
    $match = @(Get-LoopSegmentsWin32Processes -Name 'rclone.exe' |
        Where-Object {
            Test-LoopSegmentsRcloneCommandLineIsOurDlna -CommandLine ([string]$_.CommandLine) -RemoteName $RemoteName
        } |
        Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    try {
        return Get-Process -Id $match[0].ProcessId -ErrorAction Stop
    } catch {
        return $null
    }
}

function Start-LoopSegmentsRcloneDlnaProcess {
    param(
        [Parameter(Mandatory = $true)][string[]] $ServeArgs,
        [string] $LogFile = ''
    )

    $inv = Get-RcloneInvocation
    $all = @()
    if ($inv.PrefixArgs) { $all += $inv.PrefixArgs }
    $all += $ServeArgs
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $all += @('--log-file', $LogFile, '--log-level', 'INFO')
    }
    $argString = ConvertTo-RcloneArgumentString -Args $all
    Write-Host "rclone $argString"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $inv.Exe
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    # Keep the host pwsh console for status; do not attach rclone to it (looks "blank").
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) {
        throw 'Failed to start rclone serve dlna process.'
    }
    return $proc
}

function Show-RcloneDlnaLogTail {
    param([string] $LogFile, [int] $Lines = 40)
    if ([string]::IsNullOrWhiteSpace($LogFile) -or -not (Test-Path -LiteralPath $LogFile)) {
        Write-Host '(no rclone dlna log file)'
        return
    }
    Write-Host "----- rclone dlna log (last $Lines lines): $LogFile -----"
    Get-Content -LiteralPath $LogFile -Tail $Lines | ForEach-Object { Write-Host $_ }
    Write-Host '----- end rclone dlna log -----'
}

function Watch-LoopSegmentsRcloneDlna {
    param(
        [Parameter(Mandatory = $true)]$RcloneProcess,
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $PortNum,
        [string] $ServeLabel = '',
        [int] $PollSeconds = 15,
        [int] $DownSeconds = 60
    )

    $downSince = $null
    $lastBeat = [datetime]::MinValue
    while ($true) {
        try { $RcloneProcess.Refresh() } catch {}
        if ($RcloneProcess.HasExited) {
            $code = 1
            try { $code = [int]$RcloneProcess.ExitCode } catch {}
            return $code
        }
        $alive = Test-PhoneLanAlive -HostName $HostName -PortNum $PortNum
        if ($alive) {
            $downSince = $null
            if (-not $Hidden -and (([datetime]::UtcNow - $lastBeat).TotalSeconds -ge [Math]::Max(30, $PollSeconds * 2))) {
                $lastBeat = [datetime]::UtcNow
                Write-Host ("[rclone-dlna] still serving {0} (Ctrl+C to stop)" -f $(if ($ServeLabel) { $ServeLabel } else { 'DLNA' })) -ForegroundColor DarkGray
            }
        } else {
            if ($null -eq $downSince) {
                $downSince = [datetime]::UtcNow
                Write-Warning ("[rclone-dlna] Phone LAN http://{0}:{1}/ unreachable — will stop serve after {2}s" -f $HostName, $PortNum, $DownSeconds)
            } elseif (([datetime]::UtcNow - $downSince).TotalSeconds -ge $DownSeconds) {
                Write-Warning '[rclone-dlna] Phone LAN stayed down — killing rclone serve dlna'
                try { Stop-Process -Id $RcloneProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
                return 2
            }
        }
        Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds))
    }
}

try {
    Initialize-LoopSegmentsWindowsConfig | Out-Null
    $settings = Get-LoopSegmentsWindowsSettings
    $hostIp = if (-not [string]::IsNullOrWhiteSpace($PhoneHost)) {
        $PhoneHost.Trim()
    } else {
        Get-LoopSegmentsLANHost
    }
    if ([string]::IsNullOrWhiteSpace($hostIp)) {
        throw 'phoneLanHost is empty. Set it in loop-segments-windows.json or pass -PhoneHost.'
    }
    $portNum = Get-LoopSegmentsLanPort -Override $Port
    $remote = Get-LoopSegmentsRcloneRemoteName -Override $RemoteName
    $creds = Get-LoopSegmentsWebDAVCredentials -UserOverride $WebDAVUser -PasswordOverride $WebDAVPassword
    $webdavUrl = "http://${hostIp}:${portNum}/"
    $addr = Get-LoopSegmentsRcloneDlnaAddr -Override $Addr
    $name = Get-LoopSegmentsRcloneDlnaName -Override $FriendlyName

    if ($Remove) {
        $stopped = Stop-LoopSegmentsPhoneRcloneDlna -RemoteName $remote
        Write-Host ("Stopped DLNA serve ({0} rclone, {1} console)." -f $stopped.Rclone, $stopped.PowerShell)
        exit 0
    }

    if ($TestOnly) {
        Test-PhoneLANExportWithOffSubnetRecovery -HostName $hostIp -PortNum $portNum -User $creds.User -Pass $creds.Password
        Ensure-RcloneRemote -Name $remote -Url $webdavUrl -User $creds.User -Pass $creds.Password
        Test-RcloneWebDAVRemote -Name $remote
        Write-Host "OK - run without -TestOnly to serve DLNA ($addr, name=$name)."
        exit 0
    }

    Test-PhoneLANExportWithOffSubnetRecovery -HostName $hostIp -PortNum $portNum -User $creds.User -Pass $creds.Password
    Ensure-RcloneRemote -Name $remote -Url $webdavUrl -User $creds.User -Pass $creds.Password
    if ($Quick) {
        Write-Host 'Quick mode: skipping rclone ls (companion already verified phone LAN).'
    } else {
        Test-RcloneWebDAVRemote -Name $remote
    }

    $servePath = "${remote}:"
    if (Test-PhoneLanHasPcldIosMediaFolder -HostName $hostIp -PortNum $portNum -User $creds.User -Pass $creds.Password) {
        $servePath = "${remote}:pcld_ios_media"
        Write-Host 'Serve path: pcld_ios_media (present on phone LAN)'
    } else {
        Write-Host 'Serve path: WebDAV root (pcld_ios_media not listed)'
    }

    $existing = Find-LoopSegmentsRcloneDlnaProcess -RemoteName $remote
    if ($null -ne $existing -and -not $existing.HasExited) {
        Write-Host ("Reusing existing rclone serve dlna PID {0} ({1})." -f $existing.Id, $servePath)
        if ($NoLanWatch) {
            Write-Host 'Leave that process running (or -Remove). Ctrl+C here only exits this console.'
            while (-not $existing.HasExited) {
                Start-Sleep -Seconds 5
                try { $existing.Refresh() } catch { break }
            }
            exit 0
        }
        $code = Watch-LoopSegmentsRcloneDlna `
            -RcloneProcess $existing `
            -HostName $hostIp `
            -PortNum $portNum `
            -ServeLabel ("{0} / {1}" -f $servePath, $name) `
            -PollSeconds $LanPollSeconds `
            -DownSeconds $LanDownSeconds
        if ($code -eq 2) { exit 2 }
        if ($code -ne 0) { Wait-EnterOnError -ExitCode $code }
        exit 0
    }

    Write-Host ''
    Write-Host ("Serving {0} as DLNA '{1}' on {2} (read-only).{3}" -f $servePath, $name, $addr, $(if ($Hidden) { '' } else { ' Ctrl+C stops.' }))
    if (-not $Hidden) {
        Write-Host 'Quest Skybox: Network channel should discover this server (same Wi-Fi as this PC).'
    }
    if (-not $NoLanWatch) {
        Write-Host ("LAN watch on: stop serve if http://{0}:{1}/ stays down for {2}s (poll {3}s)." -f $hostIp, $portNum, $LanDownSeconds, $LanPollSeconds)
    }
    Write-Host ''

    $serveArgs = @(
        'serve', 'dlna', $servePath,
        '--addr', $addr,
        '--name', $name,
        '--read-only',
        '--vfs-cache-mode', 'full',
        '--dir-cache-time', '30s',
        '--poll-interval', '15s'
    )

    $rcloneLog = Get-LoopSegmentsRcloneDlnaLogPath
    try {
        if (Test-Path -LiteralPath $rcloneLog) {
            Remove-Item -LiteralPath $rcloneLog -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $rcloneLog -Force | Out-Null
    } catch {}

    $rcloneProc = Start-LoopSegmentsRcloneDlnaProcess -ServeArgs $serveArgs -LogFile $rcloneLog
    Write-Host ("rclone serve dlna started (PID {0}); log: {1}" -f $rcloneProc.Id, $rcloneLog)
    Start-Sleep -Seconds 2
    try { $rcloneProc.Refresh() } catch {}
    if ($rcloneProc.HasExited) {
        $early = 1
        try { $early = [int]$rcloneProc.ExitCode } catch {}
        Write-Host ('[Serve-LoopSegmentsRcloneDlna] rclone exited immediately (exit {0}).' -f $early) -ForegroundColor Red
        Show-RcloneDlnaLogTail -LogFile $rcloneLog
        Wait-EnterOnError -ExitCode $early
    }

    if ($NoLanWatch) {
        try {
            $rcloneProc.WaitForExit()
            $code = 0
            try { $code = [int]$rcloneProc.ExitCode } catch {}
            if ($code -ne 0) {
                Show-RcloneDlnaLogTail -LogFile $rcloneLog
                Wait-EnterOnError -ExitCode $code
            }
        } finally {
            try { Stop-Process -Id $rcloneProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        exit 0
    }

    $code = Watch-LoopSegmentsRcloneDlna `
        -RcloneProcess $rcloneProc `
        -HostName $hostIp `
        -PortNum $portNum `
        -ServeLabel ("{0} / {1}" -f $servePath, $name) `
        -PollSeconds $LanPollSeconds `
        -DownSeconds $LanDownSeconds

    if ($code -eq 2) {
        Write-Host '[Serve-LoopSegmentsRcloneDlna] Exited after prolonged LAN outage (rclone killed).'
        Show-RcloneDlnaLogTail -LogFile $rcloneLog
        exit 2
    }
    if ($code -ne 0) {
        Write-Host ('[Serve-LoopSegmentsRcloneDlna] rclone serve dlna failed (exit {0}).' -f $code) -ForegroundColor Red
        Show-RcloneDlnaLogTail -LogFile $rcloneLog
        Wait-EnterOnError -ExitCode $code
    }
} catch {
    Write-Host ""
    Write-Host ('[Serve-LoopSegmentsRcloneDlna] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Wait-EnterOnError -ExitCode 1
}
