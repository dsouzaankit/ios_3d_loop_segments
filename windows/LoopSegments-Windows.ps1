#Requires -Version 5.1
# Shared per-PC settings for Loop Segments windows/*.ps1 (dot-source from $PSScriptRoot).

function Get-LoopSegmentsWindowsConfigPath {
    Join-Path $PSScriptRoot 'loop-segments-windows.json'
}

function Get-LoopSegmentsWindowsExamplePath {
    Join-Path $PSScriptRoot 'loop-segments-windows.example.json'
}

function Get-DefaultLoopSegmentsWindowsSettings {
    [ordered]@{
        phoneLanHost       = ''
        lanPort            = 8765
        mountDriveLetter   = 'L'
        rcloneRemoteName   = 'loopsegments'
        rcloneConfigPath   = ''
        rcloneExe          = ''
        winfspDllPath      = ''
        skipWinFspCheck    = $false
        dlnaFolder         = ''
        notes              = ''
    }
}

function Read-LoopSegmentsWindowsConfigFile {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse $Path : $($_.Exception.Message)"
        return $null
    }
}

function Merge-LoopSegmentsWindowsSettings {
    param($FromFile)
    $merged = Get-DefaultLoopSegmentsWindowsSettings
    if ($null -eq $FromFile) { return $merged }
    foreach ($prop in $FromFile.PSObject.Properties) {
        if ($merged.Contains($prop.Name)) {
            $merged[$prop.Name] = $prop.Value
        }
    }
    return $merged
}

function Import-LoopSegmentsLegacyLanHost {
    param([hashtable] $Settings)
    $legacy = Join-Path $PSScriptRoot 'loop-segments-lan-host.txt'
    if (-not [string]::IsNullOrWhiteSpace($Settings.phoneLanHost)) { return $Settings }
    if (-not (Test-Path -LiteralPath $legacy)) { return $Settings }
    $ip = (Get-Content -LiteralPath $legacy -Raw).Trim().Trim('"')
    if (-not [string]::IsNullOrWhiteSpace($ip)) {
        $Settings.phoneLanHost = $ip
    }
    return $Settings
}

function Get-LoopSegmentsWindowsSettings {
    $path = Get-LoopSegmentsWindowsConfigPath
    $fromFile = Read-LoopSegmentsWindowsConfigFile -Path $path
    $settings = Merge-LoopSegmentsWindowsSettings -FromFile $fromFile
    Import-LoopSegmentsLegacyLanHost -Settings $settings
}

function Save-LoopSegmentsWindowsSettings {
    param([hashtable] $Settings)
    $path = Get-LoopSegmentsWindowsConfigPath
    $ordered = [ordered]@{}
    foreach ($key in (Get-DefaultLoopSegmentsWindowsSettings).Keys) {
        $ordered[$key] = $Settings[$key]
    }
    $json = $ordered | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    Write-Host "Saved: $path"
    $legacy = Join-Path $PSScriptRoot 'loop-segments-lan-host.txt'
    if (-not [string]::IsNullOrWhiteSpace($Settings.phoneLanHost)) {
        $Settings.phoneLanHost.Trim() | Set-Content -LiteralPath $legacy -Encoding UTF8 -NoNewline
    }
}

function Resolve-LoopSegmentsPath {
    param([string] $Path)
    $t = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($t)) { return '' }
    return [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables(
            ($t -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        )
    )
}

function Find-RcloneConfigPath {
    $settings = Get-LoopSegmentsWindowsSettings
    $override = Resolve-LoopSegmentsPath $settings.rcloneConfigPath
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) { return $override }
        throw "rcloneConfigPath not found: $override (edit loop-segments-windows.json)"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RCLONE_CONFIG)) {
        $envPath = Resolve-LoopSegmentsPath $env:RCLONE_CONFIG
        if (Test-Path -LiteralPath $envPath) { return $envPath }
    }
    $rcloneExe = Find-RcloneExecutable
    if ($rcloneExe) {
        try {
            $fromRclone = (& $rcloneExe config file 2>$null | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($fromRclone) -and (Test-Path -LiteralPath $fromRclone)) {
                return $fromRclone
            }
        } catch {
            # ignore
        }
    }
    foreach ($candidate in @(
            (Join-Path $env:APPDATA 'rclone\rclone.conf'),
            (Join-Path $env:LOCALAPPDATA 'rclone\rclone.conf'),
            (Join-Path $env:USERPROFILE '.config\rclone\rclone.conf')
        )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return (Join-Path $env:APPDATA 'rclone\rclone.conf')
}

function Find-RcloneExecutable {
    $settings = Get-LoopSegmentsWindowsSettings
    $override = Resolve-LoopSegmentsPath $settings.rcloneExe
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (Test-Path -LiteralPath $override) { return $override }
        throw "rcloneExe not found: $override"
    }
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-RcloneInvocation {
    $exe = Find-RcloneExecutable
    if (-not $exe) {
        throw 'rclone not found on PATH. Set rcloneExe in loop-segments-windows.json or install https://rclone.org/install/'
    }
    $args = @()
    $configPath = Find-RcloneConfigPath
    if (Test-Path -LiteralPath $configPath) {
        $args += '--config', $configPath
    }
    return @{ Exe = $exe; ConfigPath = $configPath; PrefixArgs = $args }
}

function Invoke-LoopSegmentsRclone {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $RcloneArgs)
    $inv = Get-RcloneInvocation
    $all = @()
    if ($inv.PrefixArgs) { $all += $inv.PrefixArgs }
    if ($RcloneArgs) { $all += $RcloneArgs }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $inv.Exe @all
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { $global:LASTEXITCODE = $code }
    return $code
}

function Get-LoopSegmentsLANHost {
    param([string] $Override = '')
    $resolved = $Override.Trim()
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = (Get-LoopSegmentsWindowsSettings).phoneLanHost
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw @"
phoneLanHost is required.

  Copy loop-segments-windows.example.json to loop-segments-windows.json
  Run: .\Set-LoopSegmentsWindows.ps1
  Or:  .\Set-LoopSegmentsLANHost.ps1 <phone-ip>
"@
    }
    return $resolved.Trim()
}

function Get-LoopSegmentsMountDriveLetter {
    param([string] $Override = '')
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim().ToUpperInvariant()[0]
    }
    $letter = [string](Get-LoopSegmentsWindowsSettings).mountDriveLetter
    if ([string]::IsNullOrWhiteSpace($letter)) { return 'L' }
    return $letter.Trim().ToUpperInvariant()[0]
}

function Get-LoopSegmentsRcloneRemoteName {
    param([string] $Override = '')
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override.Trim() }
    $name = [string](Get-LoopSegmentsWindowsSettings).rcloneRemoteName
    if ([string]::IsNullOrWhiteSpace($name)) { return 'loopsegments' }
    return $name.Trim()
}

function Get-LoopSegmentsLanPort {
    param([int] $Override = 0)
    if ($Override -gt 0) { return $Override }
    $port = (Get-LoopSegmentsWindowsSettings).lanPort
    if ($null -eq $port -or [int]$port -le 0) { return 8765 }
    return [int]$port
}

function Test-LoopSegmentsWinFspInstalled {
    $settings = Get-LoopSegmentsWindowsSettings
    if ($settings.skipWinFspCheck) { return $true }
    $custom = Resolve-LoopSegmentsPath $settings.winfspDllPath
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        return (Test-Path -LiteralPath $custom)
    }
    $candidates = @(
        "${env:ProgramFiles}\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles}\WinFsp\bin\winfsp.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp.dll"
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    foreach ($root in @("${env:ProgramFiles}\WinFsp", "${env:ProgramFiles(x86)}\WinFsp")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Get-ChildItem -LiteralPath $root -Recurse -Filter 'winfsp*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }
    return $false
}

function Show-LoopSegmentsWindowsDiagnostics {
    $settings = Get-LoopSegmentsWindowsSettings
    $configPath = Get-LoopSegmentsWindowsConfigPath
    Write-Host 'Loop Segments Windows (this PC)'
    Write-Host "  Config file:     $(if (Test-Path $configPath) { $configPath } else { '(missing - copy .example.json)' })"
    Write-Host "  Phone LAN:       $($settings.phoneLanHost) : $(Get-LoopSegmentsLanPort)"
    Write-Host "  Mount drive:     $(Get-LoopSegmentsMountDriveLetter):"
    Write-Host "  rclone remote:   $(Get-LoopSegmentsRcloneRemoteName)"
    try {
        $inv = Get-RcloneInvocation
        Write-Host "  rclone.exe:      $($inv.Exe)"
        Write-Host "  rclone.conf:     $($inv.ConfigPath)"
    } catch {
        Write-Host "  rclone:          $($_.Exception.Message)"
    }
    $winfsp = Test-LoopSegmentsWinFspInstalled
    Write-Host "  WinFsp:          $(if ($winfsp) { 'OK' } elseif ($settings.skipWinFspCheck) { 'check skipped' } else { 'not found (set winfspDllPath or skipWinFspCheck)' })"
    if (-not [string]::IsNullOrWhiteSpace($settings.dlnaFolder)) {
        Write-Host "  DLNA folder:     $($settings.dlnaFolder)"
    }
    if (-not [string]::IsNullOrWhiteSpace($settings.notes)) {
        Write-Host "  Notes:           $($settings.notes)"
    }
}

function Get-LoopSegmentsPCLanIPv4 {
    param([string] $PreferSameSubnetAs = '')

    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' -and $_.PrefixOrigin -ne 'WellKnown'
        })
    if ($PreferSameSubnetAs -match '^(\d+\.\d+\.\d+)\.\d+$') {
        $prefix = $Matches[1]
        $same = @($addrs | Where-Object { $_.IPAddress -like "$prefix.*" })
        if ($same.Count -gt 0) {
            return $same[0].IPAddress
        }
    }
    if ($addrs.Count -eq 0) {
        throw 'No LAN IPv4 on this PC.'
    }
    return $addrs[0].IPAddress
}

function Remove-LoopSegmentsPort80ProxyRule {
    param(
        [string] $ListenAddress,
        [string] $PhoneHost,
        [int] $PhonePort,
        [int] $ListenPort
    )
    if ($ListenAddress) {
        netsh interface portproxy delete v4tov4 listenaddress=$ListenAddress listenport=$ListenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
    }
    netsh interface portproxy delete v4tov4 listenport=$ListenPort connectport=$PhonePort connectaddress=$PhoneHost 2>$null | Out-Null
}

function Clear-LoopSegmentsPort80Proxy {
    param(
        [string] $PhoneHost = '',
        [int] $PhonePort = 0,
        [string] $DriveLetter = ''
    )

    $hostIp = if ([string]::IsNullOrWhiteSpace($PhoneHost)) {
        Get-LoopSegmentsLANHost
    } else {
        $PhoneHost.Trim()
    }
    if ($PhonePort -le 0) {
        $PhonePort = Get-LoopSegmentsLanPort
    }

    $listenAddresses = @('0.0.0.0', '127.0.0.1')
    try {
        $pcIp = Get-LoopSegmentsPCLanIPv4 -PreferSameSubnetAs $hostIp
        if ($listenAddresses -notcontains $pcIp) {
            $listenAddresses += $pcIp
        }
    } catch {
        Write-Warning "Could not detect PC LAN IP: $($_.Exception.Message)"
    }

    foreach ($addr in $listenAddresses) {
        foreach ($listenPort in 80, 8080) {
            Remove-LoopSegmentsPort80ProxyRule -ListenAddress $addr -PhoneHost $hostIp -PhonePort $PhonePort -ListenPort $listenPort
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $drive = "${DriveLetter}:"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        cmd /c "net use $drive /delete /y" 2>&1 | Out-Null
        $ErrorActionPreference = $prev
        Write-Host "net use $drive /delete attempted (WebDAV drive letter)."
    }

    Write-Host "Removed portproxy rules for phone ${hostIp}:$PhonePort (listen ports 80 and 8080)."
    Write-Host 'Remaining portproxy rules:'
    netsh interface portproxy show all
}

function Initialize-LoopSegmentsWindowsConfig {
    param([switch] $Force)
    $path = Get-LoopSegmentsWindowsConfigPath
    if ((Test-Path -LiteralPath $path) -and -not $Force) { return }
    $example = Get-LoopSegmentsWindowsExamplePath
    if (Test-Path -LiteralPath $example) {
        Copy-Item -LiteralPath $example -Destination $path -Force
        Write-Host "Created $path from example."
    } else {
        Save-LoopSegmentsWindowsSettings -Settings (Get-LoopSegmentsWindowsSettings)
    }
}
