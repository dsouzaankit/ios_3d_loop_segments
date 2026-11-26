# PC-signed USB install (zsign + SideStore's exported certificate): Loop Segments wrapper around the shared
# ..\env_setup\zsign kit (SideStoreSigning.ps1 + sidestore_sign.py, next to the repo). Used by
# usb\Prepare-PhoneForSideStoreViaUsb.ps1, usb\Install-LoopSegmentsIpaViaUsb.ps1 and
# setup\Set-LoopSegmentsSigning.ps1. Dot-source after LoopSegments-Windows.ps1 and Get-LoopSegmentsPython.ps1.
# Nothing here is tied to one PC: the .p12 and zsign live in env_setup\zsign (synced with that folder), the
# password is per PC (Windows Credential Manager), and zsignExe in loop-segments-windows.json can override zsign.

$script:LoopSegmentsWindowsDir = Split-Path -Parent $PSScriptRoot
$script:LoopSegmentsRepoRoot = Split-Path -Parent $script:LoopSegmentsWindowsDir

# Loop Segments' own bundle id (SideStore installs it as <id>.TEAMID) and display name.
$LoopSegmentsBundleId = 'com.loopsegments.app'
$LoopSegmentsDisplayName = 'Loop Segments'

$LoopSegmentsZsignKitDir = $null
foreach ($c in @(
        (Join-Path (Split-Path -Parent $script:LoopSegmentsRepoRoot) 'env_setup\zsign')
        'P:\all_scripts\iOS apps\env_setup\zsign'
    )) {
    if (Test-Path -LiteralPath (Join-Path $c 'SideStoreSigning.ps1') -PathType Leaf) { $LoopSegmentsZsignKitDir = $c; break }
}
if ($LoopSegmentsZsignKitDir) {
    . (Join-Path $LoopSegmentsZsignKitDir 'SideStoreSigning.ps1')
    $LoopSegmentsSigningDir = $SideStoreZsignDir
    $LoopSegmentsSigningP12 = $SideStoreSigningP12
    $LoopSegmentsSigningCredTarget = Resolve-SideStoreSigningCredTarget
} else {
    # No env_setup next to the repo: the PC-signed install reports "not set up" and deploys use SideStore.
    $LoopSegmentsSigningDir = Join-Path (Split-Path -Parent $script:LoopSegmentsRepoRoot) 'env_setup\zsign'
    $LoopSegmentsSigningP12 = Join-Path $LoopSegmentsSigningDir 'signing.p12'
    $LoopSegmentsSigningCredTarget = 'SideStore-signing'
}

function Test-LoopSegmentsZsignKit { return [bool]$LoopSegmentsZsignKitDir }

function Find-LoopSegmentsZsign {
    # zsignExe (config), else env_setup\zsign\zsign.exe, else PATH.
    if (-not $LoopSegmentsZsignKitDir) { return $null }
    $cfg = ''
    try {
        $v = [string](Get-LoopSegmentsWindowsSettings).zsignExe
        if ($v.Trim()) { $cfg = Resolve-LoopSegmentsPath $v }
    } catch {}
    return (Find-SideStoreZsign -Override $cfg)
}

function Test-LoopSegmentsSigningPassword {
    param([string] $CredTarget = $LoopSegmentsSigningCredTarget)
    if (-not $LoopSegmentsZsignKitDir) { return $false }
    return (Test-SideStoreSigningPassword -CredTarget $CredTarget)
}

function Invoke-LoopSegmentsSignPy {
    # env_setup\zsign\sidestore_sign.py <check|sign-install> ... <bundle id> <display name> -> runtime result.
    param([Parameter(Mandatory)] $Runtime, [Parameter(Mandatory)] [string[]] $ArgumentList)
    $all = @($SideStoreSignPy) + $ArgumentList + @($LoopSegmentsBundleId, $LoopSegmentsDisplayName)
    return (Invoke-LoopSegmentsPythonRuntime -Runtime $Runtime -ArgumentList $all)
}

function Invoke-LoopSegmentsSigningCheck {
    # sidestore_sign.py check -> its result line (READY ... / NO_P12 / NO_PASSWORD / ...).
    param(
        [Parameter(Mandatory)] $Runtime,
        [string] $P12 = $LoopSegmentsSigningP12,
        [string] $CredTarget = $LoopSegmentsSigningCredTarget
    )
    if (-not $LoopSegmentsZsignKitDir) { return "ERROR`tno env_setup\zsign next to the repo" }
    $r = Invoke-LoopSegmentsSignPy -Runtime $Runtime -ArgumentList @('check', $P12, $CredTarget)
    $line = @($r.Lines | Where-Object { $_ -match '^[A-Z_]+(\t|$)' } | Select-Object -Last 1)
    if ($line) { return [string]$line[0] }
    return ('ERROR' + "`t" + (($r.Lines | Select-Object -Last 1) -join ''))
}

function Test-LoopSegmentsSignedInstallReady {
    # $true when the PC-signed install can run now: zsign found and the check prints READY
    # (.p12 + password + an unexpired profile on the USB phone for the installed app).
    param(
        [Parameter(Mandatory)] $Runtime,
        [string] $P12 = $LoopSegmentsSigningP12,
        [string] $CredTarget = $LoopSegmentsSigningCredTarget
    )
    if (-not (Test-Path -LiteralPath $P12) -or -not (Find-LoopSegmentsZsign)) { return $false }
    return ((Invoke-LoopSegmentsSigningCheck -Runtime $Runtime -P12 $P12 -CredTarget $CredTarget) -match '^READY\t')
}
