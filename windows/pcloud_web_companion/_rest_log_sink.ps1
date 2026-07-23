param(
    [string]$LogFile = $(Join-Path $PSScriptRoot "rest.log"),
    [int]$Port = 18765
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null

function Write-LogLine([string]$Line) {
    Add-Content -LiteralPath $LogFile -Value $Line -Encoding utf8
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
