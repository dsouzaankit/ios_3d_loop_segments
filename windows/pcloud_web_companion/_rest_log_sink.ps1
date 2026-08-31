param(
    [string]$LogFile = $(Join-Path $PSScriptRoot "rest.log"),
    [int]$Port = 18765,
    [int]$CompanionPid = 0
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null

function Write-LogLine([string]$Line) {
    try {
        Add-Content -LiteralPath $LogFile -Value $Line -Encoding utf8 -ErrorAction Stop
    } catch {
        # pCloud Drive can briefly lock rest.log; never take down the sink for that.
    }
}

if (-not ('CompanionNativeFocus' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CompanionNativeFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
    public const int ASFW_ANY = -1;
    public const byte VK_MENU = 0x12;
    public const uint KEYEVENTF_KEYUP = 2;
}
"@
}

function Get-CompanionConsoleHandle {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return [IntPtr]::Zero }
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            return $proc.MainWindowHandle
        }
        $parentId = $null
        try {
            $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue).ParentProcessId
        } catch {}
        if ($parentId) {
            $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
            if ($parent -and $parent.MainWindowHandle -ne [IntPtr]::Zero) {
                return $parent.MainWindowHandle
            }
        }
    } catch {}
    return [IntPtr]::Zero
}

function Show-HwndForeground {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $false }
    try {
        [void][CompanionNativeFocus]::AllowSetForegroundWindow([CompanionNativeFocus]::ASFW_ANY)
        if ([CompanionNativeFocus]::IsIconic($Hwnd)) {
            [void][CompanionNativeFocus]::ShowWindow($Hwnd, [CompanionNativeFocus]::SW_RESTORE)
        } else {
            [void][CompanionNativeFocus]::ShowWindow($Hwnd, [CompanionNativeFocus]::SW_SHOW)
        }
        # Chromium popup still owns foreground — SetForegroundWindow alone is blocked.
        # TOPMOST flip forces the Explorer window above Chromium without needing input focus rights.
        $flags = [CompanionNativeFocus]::SWP_NOMOVE -bor [CompanionNativeFocus]::SWP_NOSIZE -bor [CompanionNativeFocus]::SWP_SHOWWINDOW
        [void][CompanionNativeFocus]::SetWindowPos(
            $Hwnd,
            [CompanionNativeFocus]::HWND_TOPMOST,
            0, 0, 0, 0,
            $flags
        )
        [void][CompanionNativeFocus]::BringWindowToTop($Hwnd)
        [CompanionNativeFocus]::keybd_event([CompanionNativeFocus]::VK_MENU, 0, 0, [UIntPtr]::Zero)
        [CompanionNativeFocus]::keybd_event([CompanionNativeFocus]::VK_MENU, 0, [CompanionNativeFocus]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        $fg = [CompanionNativeFocus]::GetForegroundWindow()
        $fgPid = [uint32]0
        $fgTid = [CompanionNativeFocus]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        $thisTid = [CompanionNativeFocus]::GetCurrentThreadId()
        if ($fgTid -ne 0 -and $fgTid -ne $thisTid) {
            [void][CompanionNativeFocus]::AttachThreadInput($thisTid, $fgTid, $true)
            [void][CompanionNativeFocus]::SetForegroundWindow($Hwnd)
            [void][CompanionNativeFocus]::AttachThreadInput($thisTid, $fgTid, $false)
        } else {
            [void][CompanionNativeFocus]::SetForegroundWindow($Hwnd)
        }
        [void][CompanionNativeFocus]::SetWindowPos(
            $Hwnd,
            [CompanionNativeFocus]::HWND_NOTOPMOST,
            0, 0, 0, 0,
            $flags
        )
        return $true
    } catch {
        return $false
    }
}

function Show-CompanionConsole {
    $hwnd = Get-CompanionConsoleHandle -ProcessId $CompanionPid
    if ($hwnd -eq [IntPtr]::Zero) {
        return $false
    }
    $ok = Show-HwndForeground -Hwnd $hwnd
    try {
        [void](New-Object -ComObject WScript.Shell).AppActivate($CompanionPid)
    } catch {}
    return $ok
}

# Stop previous sinks (same script) so the port is free.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*_rest_log_sink.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
Start-Sleep -Milliseconds 300

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
} catch {
    Write-LogLine "$(Get-Date -Format o) SINK_START_FAILED $_"
    exit 1
}

Write-LogLine "$(Get-Date -Format o) SINK_LISTENING http://127.0.0.1:$Port/ -> $LogFile"

function Read-HttpRequest {
    param([System.Net.Sockets.TcpClient]$Client)

    $stream = $Client.GetStream()
    $stream.ReadTimeout = 30000
    $buffer = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    while ($true) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $ms.Write($buffer, 0, $read)
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n")
        if ($headerEnd -lt 0) { continue }
        $headerText = $text.Substring(0, $headerEnd)
        $bodyStart = $headerEnd + 4
        $contentLength = 0
        foreach ($line in ($headerText -split "`r`n")) {
            if ($line -match '^(?i)Content-Length:\s*(\d+)\s*$') {
                $contentLength = [int]$Matches[1]
            }
        }
        $bodyBytesSoFar = $ms.Length - $bodyStart
        while ($bodyBytesSoFar -lt $contentLength) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $ms.Write($buffer, 0, $read)
            $bodyBytesSoFar = $ms.Length - $bodyStart
        }
        $all = $ms.ToArray()
        $body = ""
        if ($contentLength -gt 0 -and $all.Length -ge ($bodyStart + $contentLength)) {
            $body = [Text.Encoding]::UTF8.GetString($all, $bodyStart, $contentLength)
        } elseif ($all.Length -gt $bodyStart) {
            $body = [Text.Encoding]::UTF8.GetString($all, $bodyStart, $all.Length - $bodyStart)
        }
        $requestLine = ($headerText -split "`r`n")[0]
        return [pscustomobject]@{
            RequestLine = $requestLine
            Body        = $body
            Stream      = $stream
        }
    }
    return $null
}

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$Body
    )
    $reason = switch ($StatusCode) {
        200 { "OK" }
        400 { "Bad Request" }
        404 { "Not Found" }
        502 { "Bad Gateway" }
        503 { "Service Unavailable" }
        default { "Error" }
    }
    $payload = [Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
}

function Test-IsPrivateLanHttpUrl {
    param([string]$Url)
    try {
        $u = [Uri]$Url
    } catch {
        return $false
    }
    if ($u.Scheme -ne 'http') { return $false }
    $h = $u.Host
    if ([string]::IsNullOrWhiteSpace($h)) { return $false }
    if ($h -eq '127.0.0.1' -or $h -eq 'localhost' -or $h -eq '::1') { return $false }
    if ($h -match '^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $true }
    if ($h -match '^192\.168\.\d{1,3}\.\d{1,3}$') { return $true }
    if ($h -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.\d{1,3}\.\d{1,3}$') { return $true }
    return $false
}

function Get-PCloudDriveRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()

    try {
        $sync = [string](Get-ItemProperty -Path 'HKCU:\SOFTWARE\pCloud' -Name 'SyncDrive' -ErrorAction Stop).SyncDrive
        if (-not [string]::IsNullOrWhiteSpace($sync)) {
            $candidates.Add($sync.Trim())
        }
    } catch {}

    try {
        Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.VolumeName -match '(?i)pcloud' -and $_.DeviceID -match '^[A-Za-z]:$' } |
            ForEach-Object { [void]$candidates.Add("$($_.DeviceID)\") }
    } catch {}

    foreach ($raw in $candidates) {
        $root = $raw
        if ($root -match '^([A-Za-z]):\\?$') {
            $root = "$($Matches[1].ToUpperInvariant()):\"
        } elseif ($root -match '^([A-Za-z]):\\') {
            $root = "$($Matches[1].ToUpperInvariant()):\"
        } else {
            continue
        }
        if (Test-Path -LiteralPath $root) {
            return ([System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\')
        }
    }

    throw "pCloud Drive is not mounted (HKCU:\SOFTWARE\pCloud SyncDrive / volume label 'pCloud Drive')"
}

function ConvertTo-PCloudExplorerTarget {
    param(
        [string]$FolderPath,
        [string]$Relative,
        [string]$FileName,
        [string]$DriveRoot
    )
    $parts = @()
    $rel = $Relative
    if ([string]::IsNullOrWhiteSpace($rel)) {
        $rel = [string]$FolderPath
    }
    $rel = $rel -replace '/', '\'
    foreach ($seg in ($rel -split '\\')) {
        $s = $seg.Trim()
        if ([string]::IsNullOrWhiteSpace($s) -or $s -eq '.') { continue }
        if ($s -eq '..') { throw "path must not contain .." }
        if ($s -match '[:*?"<>|]') { throw "invalid path segment" }
        if ($parts.Count -eq 0 -and $s -match '^(?i)all files$') { continue }
        $parts += $s
    }
    $rootFull = [System.IO.Path]::GetFullPath($DriveRoot)
    if (-not $rootFull.EndsWith('\')) { $rootFull += '\' }
    $folderFull = $rootFull
    if ($parts.Count -gt 0) {
        $folderFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($parts -join '\')))
    }
    if (-not $folderFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path is outside the pCloud drive"
    }
    $fileFull = $null
    $leaf = [string]$FileName
    if (-not [string]::IsNullOrWhiteSpace($leaf) -and $leaf -notmatch '[\\/:*?"<>|]') {
        $fileFull = [System.IO.Path]::GetFullPath((Join-Path $folderFull $leaf))
        if (-not $fileFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $fileFull = $null
        }
    }
    $open = $folderFull
    $select = $false
    if ($fileFull -and (Test-Path -LiteralPath $fileFull)) {
        $open = $fileFull
        $select = $true
    } else {
        $probe = $folderFull
        while ($probe.Length -ge $rootFull.Length) {
            if (Test-Path -LiteralPath $probe) { break }
            $parent = Split-Path -Parent $probe
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
            $probe = $parent
        }
        if (-not (Test-Path -LiteralPath $probe)) {
            throw "folder is not on pCloud Drive ($DriveRoot) (not synced?): $folderFull"
        }
        $open = $probe
    }
    return @{
        path   = $open
        select = $select
        mapped = $folderFull
    }
}

function Get-ExplorerHwndForPath {
    param([string]$FolderPath)
    $want = [System.IO.Path]::GetFullPath($FolderPath).TrimEnd('\').ToLowerInvariant()
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($win in @($shell.Windows())) {
            try {
                $loc = $null
                try { $loc = [string]$win.Document.Folder.Self.Path } catch {}
                if ([string]::IsNullOrWhiteSpace($loc)) {
                    try {
                        $url = [string]$win.LocationURL
                        if ($url -match '^file:///') {
                            $loc = [Uri]::UnescapeDataString($url.Substring(8) -replace '/', '\')
                        }
                    } catch {}
                }
                if ([string]::IsNullOrWhiteSpace($loc)) { continue }
                $have = [System.IO.Path]::GetFullPath($loc).TrimEnd('\').ToLowerInvariant()
                if ($have -eq $want) {
                    return [IntPtr]$win.HWND
                }
            } catch {}
        }
    } catch {}
    return [IntPtr]::Zero
}

function Start-ExplorerAt {
    param([string]$Path, [bool]$Select)
    $explorer = Join-Path $env:WINDIR 'explorer.exe'
    $folderForWindow = $Path
    $selectPath = $null
    if ($Select -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $folderForWindow = Split-Path -Parent $Path
        $selectPath = $Path
    }

    # Folder already open → foreground only (/select always spawns another Explorer window).
    $existing = Get-ExplorerHwndForPath -FolderPath $folderForWindow
    if ($existing -ne [IntPtr]::Zero) {
        [void](Show-HwndForeground -Hwnd $existing)
        return
    }

    try {
        if ($selectPath) {
            Start-Process -FilePath $explorer -ArgumentList @("/select,`"$selectPath`"")
        } else {
            # ShellExecute on the folder path (not explorer.exe args) — more reliable
            # than explorer.exe <path> / Shell.Open when Chromium still owns focus.
            Start-Process -FilePath $folderForWindow
        }
    } catch {
        if ($selectPath) {
            Start-Process -FilePath $explorer -ArgumentList @("/select,`"$selectPath`"")
        } else {
            try {
                (New-Object -ComObject Shell.Application).Open($folderForWindow)
            } catch {
                Start-Process -FilePath $explorer -ArgumentList @("/root,`"$folderForWindow`"")
            }
        }
    }

    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 125
        $hwnd = Get-ExplorerHwndForPath -FolderPath $folderForWindow
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        [void](Show-HwndForeground -Hwnd $hwnd)
        # Chromium may reclaim focus when the popup paints the result — nudge again.
        Start-Sleep -Milliseconds 200
        [void](Show-HwndForeground -Hwnd $hwnd)
    } else {
        try {
            $leaf = Split-Path -Leaf $folderForWindow
            if ($leaf) {
                [void](New-Object -ComObject WScript.Shell).AppActivate($leaf)
            }
        } catch {}
    }
}

# Clash TUN often black-holes Chromium SW fetch to RFC1918. This relay uses WinHTTP
# with an empty proxy so phone LAN stays DIRECT even when TUN is on.
function Invoke-PhoneLanRelay {
    param([string]$JsonBody)

    $obj = $JsonBody | ConvertFrom-Json
    $targetUrl = [string]$obj.url
    if (-not (Test-IsPrivateLanHttpUrl $targetUrl)) {
        return @{ ok = $false; status = 400; body = 'url must be http:// to a private LAN IP' }
    }
    $method = [string]$obj.method
    if ([string]::IsNullOrWhiteSpace($method)) { $method = 'GET' }
    $timeoutMs = 10000
    if ($null -ne $obj.timeoutMs -and [int]$obj.timeoutMs -gt 0) {
        $timeoutMs = [Math]::Min(60000, [int]$obj.timeoutMs)
    }

    $req = [System.Net.HttpWebRequest]::Create($targetUrl)
    $req.Method = $method.ToUpperInvariant()
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = $timeoutMs
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $req.KeepAlive = $false

    if ($null -ne $obj.headers) {
        foreach ($p in $obj.headers.PSObject.Properties) {
            $name = [string]$p.Name
            $val = [string]$p.Value
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -match '(?i)^Content-Type$') {
                $req.ContentType = $val
            } elseif ($name -match '(?i)^Accept$') {
                $req.Accept = $val
            } elseif ($name -match '(?i)^User-Agent$') {
                $req.UserAgent = $val
            } else {
                try { [void]$req.Headers.Add($name, $val) } catch {}
            }
        }
    }

    $bodyText = $null
    if ($null -ne $obj.body) {
        if ($obj.body -is [string]) {
            $bodyText = [string]$obj.body
        } else {
            $bodyText = ($obj.body | ConvertTo-Json -Compress -Depth 20)
        }
    }
    if ($req.Method -ne 'GET' -and $req.Method -ne 'HEAD' -and $null -ne $bodyText) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($bodyText)
        $req.ContentLength = $bytes.Length
        if ([string]::IsNullOrWhiteSpace($req.ContentType)) {
            $req.ContentType = 'application/json; charset=utf-8'
        }
        $reqStream = $req.GetRequestStream()
        try {
            $reqStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $reqStream.Close()
        }
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
        $status = [int]$resp.StatusCode
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try {
            $respBody = $reader.ReadToEnd()
        } finally {
            $reader.Close()
        }
        return @{ ok = $true; status = $status; body = $respBody; via = 'direct-relay' }
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($null -ne $ex.Response) {
            $errResp = $ex.Response
            $status = [int]$errResp.StatusCode
            $reader = New-Object System.IO.StreamReader($errResp.GetResponseStream(), [Text.Encoding]::UTF8)
            try {
                $respBody = $reader.ReadToEnd()
            } finally {
                $reader.Close()
            }
            return @{ ok = $true; status = $status; body = $respBody; via = 'direct-relay' }
        }
        return @{ ok = $false; status = 502; body = "relay fetch failed: $($ex.Message)"; via = 'direct-relay' }
    } finally {
        if ($null -ne $resp) {
            try { $resp.Close() } catch {}
            try { $resp.Dispose() } catch {}
        }
    }
}

function Get-WebCompanionMediaListFilePath {
    $envPath = [string]$env:WEB_COMPANION_MEDIA_LIST
    if (-not [string]::IsNullOrWhiteSpace($envPath)) {
        return [System.IO.Path]::GetFullPath($envPath.Trim())
    }
    $configPath = Join-Path $PSScriptRoot 'lan_config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fromCfg = [string]$cfg.webCompanionMediaListFile
            if (-not [string]::IsNullOrWhiteSpace($fromCfg)) {
                return [System.IO.Path]::GetFullPath($fromCfg.Trim())
            }
        } catch {}
    }
    try {
        $driveRoot = Get-PCloudDriveRoot
        return [System.IO.Path]::GetFullPath((Join-Path $driveRoot 'p_cld_media\web_compann_plst\media_files.txt'))
    } catch {
        return 'P:\p_cld_media\web_compann_plst\media_files.txt'
    }
}

function Test-BatchVideoLeafName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '\.(?i)(mp4|wmv|ts|mkv)$'
}

function Resolve-PCloudDriveMappedFolderFull {
    param(
        [string]$DriveRoot,
        [string[]]$RelativeParts
    )
    $rootFull = [System.IO.Path]::GetFullPath($DriveRoot)
    if (-not $rootFull.EndsWith('\')) { $rootFull += '\' }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in @($RelativeParts)) {
        $s = ([string]$seg).Trim()
        if ([string]::IsNullOrWhiteSpace($s) -or $s -eq '.') { continue }
        if ($s -eq '..') { throw "path must not contain .." }
        if ($s -match '[:*?"<>|]') { throw "invalid path segment: $s" }
        if ($parts.Count -eq 0 -and $s -match '^(?i)all files$') { continue }
        [void]$parts.Add($s)
    }
    $folderFull = $rootFull
    if ($parts.Count -gt 0) {
        $folderFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($parts -join '\')))
    }
    if (-not $folderFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path is outside the pCloud drive"
    }
    return $folderFull
}

function Convert-PCloudLogicalPathToDriveFilePath {
    param(
        [string]$LogicalPath,
        [string]$DriveRoot
    )
    if ([string]::IsNullOrWhiteSpace($LogicalPath)) { return $null }
    $parts = @(
        (($LogicalPath -replace '\\', '/') -split '/') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($parts.Count -lt 1) { return $null }
    $fileName = $parts[$parts.Count - 1]
    $folderParts = @()
    if ($parts.Count -gt 1) {
        $folderParts = $parts[0..($parts.Count - 2)]
    }
    $folderFull = Resolve-PCloudDriveMappedFolderFull -DriveRoot $DriveRoot -RelativeParts $folderParts
    return [System.IO.Path]::GetFullPath((Join-Path $folderFull $fileName))
}

function Resolve-PCloudDriveFullFilePath {
    param(
        [string]$FolderPath,
        [string]$FileName,
        [string]$DriveRoot,
        [string]$PcloudPath = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($PcloudPath)) {
        return Convert-PCloudLogicalPathToDriveFilePath -LogicalPath $PcloudPath -DriveRoot $DriveRoot
    }
    if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }
    $folderParts = @(
        (($FolderPath -replace '\\', '/') -split '/') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    $folderFull = Resolve-PCloudDriveMappedFolderFull -DriveRoot $DriveRoot -RelativeParts $folderParts
    return [System.IO.Path]::GetFullPath((Join-Path $folderFull $FileName))
}

function Write-WebCompanionHybridMediaList {
    param($JsonBody)
    $obj = if ([string]::IsNullOrWhiteSpace($JsonBody)) { [pscustomobject]@{} } else { $JsonBody | ConvertFrom-Json }
    $driveRoot = Get-PCloudDriveRoot
    $outFile = Get-WebCompanionMediaListFilePath
    $paths = [System.Collections.Generic.List[string]]::new()
    $skippedNonVideo = 0
    $missingOnDisk = 0
    $errors = [System.Collections.Generic.List[string]]::new()

    # @($null).Count is 1 in PowerShell — only use paths when the JSON key exists and has values.
    $rawPaths = @()
    if ($null -ne $obj.paths) {
        $rawPaths = @($obj.paths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    }
    if ($rawPaths.Count -gt 0) {
        foreach ($p in $rawPaths) {
            $full = [string]$p
            if ([string]::IsNullOrWhiteSpace($full)) { continue }
            try { $full = [System.IO.Path]::GetFullPath($full.Trim()) } catch { continue }
            $leaf = [System.IO.Path]::GetFileName($full)
            if (-not (Test-BatchVideoLeafName $leaf)) {
                $skippedNonVideo++
                continue
            }
            if ($paths -notcontains $full) { [void]$paths.Add($full) }
        }
    } else {
        foreach ($item in @($obj.items)) {
            $displayName = [string]$item.displayName
            $folderPath = [string]$item.folderPath
            $pcloudPath = [string]$item.pcloudPath
            if ([string]::IsNullOrWhiteSpace($pcloudPath) -and [string]::IsNullOrWhiteSpace($displayName)) { continue }
            if (-not [string]::IsNullOrWhiteSpace($pcloudPath)) {
                $leaf = [System.IO.Path]::GetFileName(($pcloudPath -replace '/', '\'))
                if (-not (Test-BatchVideoLeafName $leaf)) {
                    $skippedNonVideo++
                    continue
                }
            } elseif (-not (Test-BatchVideoLeafName $displayName)) {
                $skippedNonVideo++
                continue
            }
            try {
                $full = Resolve-PCloudDriveFullFilePath -FolderPath $folderPath -FileName $displayName -DriveRoot $driveRoot -PcloudPath $pcloudPath
            } catch {
                [void]$errors.Add("${displayName}${pcloudPath} : $_")
                continue
            }
            if ([string]::IsNullOrWhiteSpace($full)) {
                [void]$errors.Add("${displayName}${pcloudPath} : could not map to Drive path")
                continue
            }
            if ($paths -notcontains $full) { [void]$paths.Add($full) }
        }
    }

    if ($paths.Count -lt 1) {
        $detail = if ($errors.Count -gt 0) { " — " + ($errors -join "; ") } else { "" }
        throw "no batch video paths to write (.mp4/.mkv/.wmv/.ts)$detail"
    }

    foreach ($full in $paths) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missingOnDisk++
        }
    }

    $dir = Split-Path -Parent $outFile
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = (($paths | ForEach-Object { $_.Trim() }) -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($outFile, $text, $utf8)
    Write-LogLine "$(Get-Date -Format o) WRITE_HYBRID_MEDIA_LIST $outFile count=$($paths.Count) missing=$missingOnDisk skipped=$skippedNonVideo"

    $explorerOpened = $false
    $explorerPath = $dir
    try {
        Start-ExplorerAt -Path $outFile -Select $true
        $explorerOpened = $true
        Write-LogLine "$(Get-Date -Format o) OPEN_EXPLORER_HYBRID_HUB $outFile"
    } catch {
        try {
            Start-ExplorerAt -Path $dir -Select $false
            $explorerOpened = $true
            Write-LogLine "$(Get-Date -Format o) OPEN_EXPLORER_HYBRID_HUB $dir (folder fallback)"
        } catch {
            Write-LogLine "$(Get-Date -Format o) OPEN_EXPLORER_HYBRID_HUB_ERROR $_"
        }
    }

    return @{
        ok              = $true
        written         = $paths.Count
        missingOnDisk   = $missingOnDisk
        skippedNonVideo = $skippedNonVideo
        mediaListFile   = $outFile
        explorerOpened  = $explorerOpened
        explorerPath    = $explorerPath
        paths           = @($paths)
        errors          = @($errors)
    }
}

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $req = Read-HttpRequest -Client $client
        if ($null -eq $req) {
            continue
        }
        $line = $req.RequestLine
        if ($line -match '^POST\s+/log\b') {
            $body = $req.Body
            if ([string]::IsNullOrWhiteSpace($body)) { $body = "{}" }
            Write-LogLine $body
            Write-HttpResponse -Stream $req.Stream -StatusCode 200 -Body '{"ok":true}'
        } elseif ($line -match '^POST\s+/phone-lan\b') {
            try {
                $result = Invoke-PhoneLanRelay -JsonBody $req.Body
                $statusOut = 200
                if (-not $result.ok -and [int]$result.status -eq 400) { $statusOut = 400 }
                elseif (-not $result.ok -and [int]$result.status -eq 502) { $statusOut = 502 }
                $payload = ($result | ConvertTo-Json -Compress -Depth 5)
                Write-HttpResponse -Stream $req.Stream -StatusCode $statusOut -Body $payload
            } catch {
                Write-LogLine "$(Get-Date -Format o) PHONE_LAN_RELAY_ERROR $_"
                Write-HttpResponse -Stream $req.Stream -StatusCode 502 -Body '{"ok":false,"status":502,"body":"relay exception"}'
            }
        } elseif ($line -match '^GET\s+/health\b') {
            Write-HttpResponse -Stream $req.Stream -StatusCode 200 -Body '{"ok":true,"phoneLanRelay":true}'
        } elseif ($line -match '^(GET|POST)\s+/focus-console\b') {
            $okFocus = Show-CompanionConsole
            $payload = (@{ ok = [bool]$okFocus; pid = $CompanionPid } | ConvertTo-Json -Compress)
            Write-HttpResponse -Stream $req.Stream -StatusCode 200 -Body $payload
        } elseif ($line -match '^POST\s+/open-explorer\b') {
            try {
                $obj = if ([string]::IsNullOrWhiteSpace($req.Body)) { [pscustomobject]@{} } else { $req.Body | ConvertFrom-Json }
                $driveRoot = Get-PCloudDriveRoot
                $target = ConvertTo-PCloudExplorerTarget -FolderPath ([string]$obj.folderPath) -Relative ([string]$obj.relative) -FileName ([string]$obj.fileName) -DriveRoot $driveRoot
                Start-ExplorerAt -Path $target.path -Select ([bool]$target.select)
                Write-LogLine "$(Get-Date -Format o) OPEN_EXPLORER $($target.path)"
                $payload = (@{
                    ok     = $true
                    path   = $target.path
                    mapped = $target.mapped
                    select = [bool]$target.select
                } | ConvertTo-Json -Compress)
                Write-HttpResponse -Stream $req.Stream -StatusCode 200 -Body $payload
            } catch {
                $msg = "$_"
                Write-LogLine "$(Get-Date -Format o) OPEN_EXPLORER_ERROR $msg"
                $status = 400
                if ($msg -match 'not mounted|is not available') { $status = 503 }
                $payload = (@{ ok = $false; error = $msg } | ConvertTo-Json -Compress)
                Write-HttpResponse -Stream $req.Stream -StatusCode $status -Body $payload
            }
        } elseif ($line -match '^POST\s+/write-hybrid-media-list\b') {
            try {
                $result = Write-WebCompanionHybridMediaList -JsonBody $req.Body
                $payload = ($result | ConvertTo-Json -Compress -Depth 6)
                Write-HttpResponse -Stream $req.Stream -StatusCode 200 -Body $payload
            } catch {
                $msg = "$_"
                Write-LogLine "$(Get-Date -Format o) WRITE_HYBRID_MEDIA_LIST_ERROR $msg"
                $status = 400
                if ($msg -match 'not mounted|is not available') { $status = 503 }
                $payload = (@{ ok = $false; error = $msg } | ConvertTo-Json -Compress)
                Write-HttpResponse -Stream $req.Stream -StatusCode $status -Body $payload
            }
        } else {
            Write-HttpResponse -Stream $req.Stream -StatusCode 404 -Body '{"ok":false}'
        }
    } catch {
        $msg = "$_"
        # Client abort / Clash reset on health poll — not fatal for the sink loop.
        if ($msg -match 'forcibly closed|aborted by the software|Cannot access a disposed object') {
            # quiet
        } else {
            try { Write-LogLine "$(Get-Date -Format o) SINK_ERROR $_" } catch {}
        }
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}
