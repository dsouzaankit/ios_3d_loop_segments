#Requires -Version 5.1
<#
.SYNOPSIS
  Shared Python runtime selection for Loop Segments Windows scripts.

.DESCRIPTION
  Prefer Python 3.12 (prebuilt wheels for pymobiledevice3). Avoid 3.14+ for
  USB tooling. Dot-source from Launch-LoopSegmentsViaUsb.ps1 / run_chromium.ps1.
#>

function Test-LoopSegmentsPyLauncherVersion {
    param(
        [Parameter(Mandatory = $true)] [string] $PyExe,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [string] $Code
    )
    # Missing versions write to stderr; with $ErrorActionPreference=Stop that
    # becomes a terminating ErrorRecord unless we swallow NativeCommandError.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $PyExe "-$Version" "-c" $Code 2>&1
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = (@($out) | ForEach-Object { [string]$_ }) -join "`n"
    return (($code -eq 0) -and ($text -match "(?m)^ok\s*$"))
}

function Get-LoopSegmentsPythonVersionTuple {
    param(
        [Parameter(Mandatory = $true)] $Runtime
    )
    $result = Invoke-LoopSegmentsPythonRuntime -Runtime $Runtime -ArgumentList @(
        "-c",
        "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"
    )
    if ($result.ExitCode -ne 0) { return $null }
    $line = ($result.Lines | Where-Object { $_ -match '^\d+\.\d+' } | Select-Object -First 1)
    if (-not $line) { return $null }
    return $line.Trim()
}

function Test-LoopSegmentsPythonVersionSupported {
    param([string] $Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    if ($Version -match '^(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        # 3.14+ often lacks prebuilt wheels for pymobiledevice3 native deps.
        if ($major -gt 3) { return $false }
        if ($major -eq 3 -and $minor -ge 14) { return $false }
        if ($major -eq 3 -and $minor -ge 9) { return $true }
    }
    return $false
}

function Get-LoopSegmentsPythonRuntime {
    <#
    .SYNOPSIS
      Pick a usable Python for USB tooling and companion venv creation.
    .PARAMETER RequirePymobiledevice3
      Prefer (and eventually require) a runtime that can import pymobiledevice3.
    .PARAMETER ForVenv
      Prefer 3.12 specifically for creating the companion virtualenv.
    #>
    param(
        [switch] $RequirePymobiledevice3,
        [switch] $ForVenv
    )

    $preferWithPkg = @("3.12", "3.11", "3.10", "3.9", "3.13")
    $preferBare = if ($ForVenv) {
        @("3.12", "3.11", "3.10", "3.9", "3.13")
    } else {
        @("3.12", "3.9", "3.11", "3.10", "3.13")
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        foreach ($ver in $preferWithPkg) {
            if (Test-LoopSegmentsPyLauncherVersion -PyExe $pyLauncher.Source -Version $ver -Code "import pymobiledevice3; print('ok')") {
                return [pscustomobject]@{
                    Exe     = $pyLauncher.Source
                    Prefix  = @("-$ver")
                    Display = "py -$ver"
                    Version = $ver
                }
            }
        }
        if (-not $RequirePymobiledevice3) {
            foreach ($ver in $preferBare) {
                if (Test-LoopSegmentsPyLauncherVersion -PyExe $pyLauncher.Source -Version $ver -Code "print('ok')") {
                    return [pscustomobject]@{
                        Exe     = $pyLauncher.Source
                        Prefix  = @("-$ver")
                        Display = "py -$ver"
                        Version = $ver
                    }
                }
            }
        }
    }

    if ($RequirePymobiledevice3) {
        return $null
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $candidate = [pscustomobject]@{
            Exe     = $python.Source
            Prefix  = @()
            Display = "python"
            Version = $null
        }
        $ver = Get-LoopSegmentsPythonVersionTuple -Runtime $candidate
        if (Test-LoopSegmentsPythonVersionSupported -Version $ver) {
            $candidate.Version = $ver
            return $candidate
        }
    }
    return $null
}

function Invoke-LoopSegmentsPythonRuntime {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList
    )
    $all = @($Runtime.Prefix) + $ArgumentList
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Runtime.Exe @all 2>&1
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @()
    foreach ($item in @($output)) { $lines += [string]$item }
    return [pscustomobject]@{
        ExitCode = $code
        Lines    = $lines
    }
}

function Get-LoopSegmentsPythonInstallHint {
    @"
Install Python 3.12 (recommended), then re-run:

  py install 3.12
  py -3.12 -m pip install -U pymobiledevice3
"@
}
