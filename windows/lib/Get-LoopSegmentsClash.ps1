#Requires -Version 5.1
<#
.SYNOPSIS
  Loop Segments wrapper around env_setup\Clash (mihomo multicast / Bonjour).

.DESCRIPTION
  Dot-source from pcloud_web_companion\run_chromium.ps1.
  Core lives in env_setup\Clash (submodule or P:\all_scripts\iOS apps\env_setup).
#>

function Get-LoopSegmentsClashDir {
    $roots = [System.Collections.Generic.List[string]]::new()
    if (Get-Command Get-LoopSegmentsEnvSetupRoot -ErrorAction SilentlyContinue) {
        try {
            $r = Get-LoopSegmentsEnvSetupRoot
            if ($r) { [void]$roots.Add($r) }
        } catch {}
    }
    foreach ($c in @(
            (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'env_setup')
            'P:\all_scripts\iOS apps\env_setup'
        )) {
        if ($c -and (Test-Path -LiteralPath $c) -and -not ($roots -contains $c)) {
            [void]$roots.Add($c)
        }
    }
    foreach ($root in $roots) {
        $core = Join-Path $root 'Clash\Get-Clash.ps1'
        if (Test-Path -LiteralPath $core) {
            return (Join-Path $root 'Clash')
        }
    }
    return $null
}

$script:LoopSegmentsClashCore = $null
$dir = Get-LoopSegmentsClashDir
if ($dir) {
    $core = Join-Path $dir 'Get-Clash.ps1'
    if (Test-Path -LiteralPath $core) {
        $script:LoopSegmentsClashCore = $core
        . $core
    }
}

function Write-LoopSegmentsClashMdnsNotice {
    param([switch] $FixRoute)
    if (-not (Get-Command Test-ClashRunning -ErrorAction SilentlyContinue)) {
        return $false
    }
    if (-not (Test-ClashRunning)) { return $false }
    return (Write-ClashMdnsNotice -FixRoute:$FixRoute)
}
