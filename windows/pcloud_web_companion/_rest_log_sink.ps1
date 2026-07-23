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
    $stream.ReadTimeout = 5000
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
        404 { "Not Found" }
        default { "Error" }
    }
    $payload = [Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
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
        } elseif ($line -match '^GET\s+/health\b') {
            Write-HttpResponse -Stream $req.Stream -StatusCode 200 -Body '{"ok":true}'
        } else {
            Write-HttpResponse -Stream $req.Stream -StatusCode 404 -Body '{"ok":false}'
        }
    } catch {
        try { Write-LogLine "$(Get-Date -Format o) SINK_ERROR $_" } catch {}
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}
