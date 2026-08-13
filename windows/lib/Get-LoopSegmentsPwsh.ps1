<#
.SYNOPSIS
  Resolve PowerShell 7 (pwsh.exe) for Loop Segments Windows scripts.

.DESCRIPTION
  Windows PowerShell 5.1 mis-parses UTF-8 .ps1 files without a BOM when they
  contain Unicode dashes. All windows\ entry points and child process launches
  should use pwsh via Get-LoopSegmentsPwshExe.

  No #Requires here so Windows PowerShell 5.1 can dot-source this helper and
  re-launch entry scripts under pwsh.
#>

function Get-LoopSegmentsPwshExe {
    $cmd = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7\pwsh.exe')
    )
    foreach ($path in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    throw @'
PowerShell 7 (pwsh) is required for Loop Segments Windows scripts.
Install from https://aka.ms/powershell then re-run (or ensure pwsh.exe is on PATH).
'@
}

function Test-LoopSegmentsRunningInPwsh {
    return ($PSVersionTable.PSEdition -eq 'Core' -and [int]$PSVersionTable.PSVersion.Major -ge 7)
}

function Ensure-LoopSegmentsPwshHost {
    <#
    .SYNOPSIS
      If running under Windows PowerShell 5.1, re-launch this script with pwsh and exit.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [hashtable] $BoundParameters = @{}
    )

    if (Test-LoopSegmentsRunningInPwsh) { return }

    $pwsh = Get-LoopSegmentsPwshExe
    Write-Host ("[pwsh] Re-launching under PowerShell 7: {0}" -f $pwsh) -ForegroundColor Cyan

    # Use the call operator (not Start-Process -ArgumentList). PS 5.1 Start-Process
    # does not quote -File paths with spaces ("iOS apps"), so pwsh sees only
    # P:\all_scripts\iOS and fails.
    $fileArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($BoundParameters.Keys)) {
        $val = $BoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { [void]$fileArgs.Add("-$key") }
            continue
        }
        if ($val -is [bool]) {
            if ($val) { [void]$fileArgs.Add("-$key") }
            continue
        }
        [void]$fileArgs.Add("-$key")
        [void]$fileArgs.Add([string]$val)
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @fileArgs
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    exit $code
}
