# PC-signed USB install (zsign + SideStore's exported certificate): shared lookups for
# usb\Prepare-PhoneForSideStoreViaUsb.ps1, usb\Install-LoopSegmentsIpaViaUsb.ps1 and
# setup\Set-LoopSegmentsSigning.ps1. Dot-source after LoopSegments-Windows.ps1 and Get-LoopSegmentsPython.ps1.
# Nothing here is tied to one PC: paths are relative to the repo, the password is per-PC
# (Windows Credential Manager), and zsignExe in loop-segments-windows.json can override the zsign path.

$script:LoopSegmentsWindowsDir = Split-Path -Parent $PSScriptRoot
$script:LoopSegmentsRepoRoot = Split-Path -Parent $script:LoopSegmentsWindowsDir

# windows\signing\ is gitignored (it syncs with the repo folder, e.g. on pCloud). Not under AppData:
# the Microsoft Store Python sees its own private copy of AppData\Local.
$LoopSegmentsSigningDir = Join-Path $script:LoopSegmentsWindowsDir 'signing'
$LoopSegmentsSigningP12 = Join-Path $LoopSegmentsSigningDir 'signing.p12'
# Windows Credential Manager generic credential holding the .p12 password (per PC).
$LoopSegmentsSigningCredTarget = 'LoopSegments-signing'

# zsign release Set-LoopSegmentsSigning.ps1 installs (hash from the release's SHA256SUMS.txt).
$LoopSegmentsZsignVersion = 'v1.1.3'
$LoopSegmentsZsignZipSha256 = '6fb5e12a5b7179cfe7e729aa471b35ccf86474eba33d8203df119bf62bad77f7'

function Get-LoopSegmentsZsignCandidates {
    # In order: zsignExe (config), env_setup\zsign next to the repo (shared with the sibling iOS
    # app repos), windows\signing\zsign in this repo.
    $list = @()
    try {
        $cfg = [string](Get-LoopSegmentsWindowsSettings).zsignExe
        if ($cfg.Trim()) { $list += (Resolve-LoopSegmentsPath $cfg) }
    } catch {}
    $list += (Join-Path (Split-Path -Parent $script:LoopSegmentsRepoRoot) 'env_setup\zsign\zsign.exe')
    $list += (Join-Path $LoopSegmentsSigningDir 'zsign\zsign.exe')
    return $list
}

function Get-LoopSegmentsZsignInstallDir {
    # Where setup puts zsign: env_setup\zsign next to the repo when that env_setup folder exists,
    # else windows\signing\zsign.
    $envSetup = Join-Path (Split-Path -Parent $script:LoopSegmentsRepoRoot) 'env_setup'
    if (Test-Path -LiteralPath $envSetup -PathType Container) { return (Join-Path $envSetup 'zsign') }
    return (Join-Path $LoopSegmentsSigningDir 'zsign')
}

function Find-LoopSegmentsZsign {
    foreach ($p in Get-LoopSegmentsZsignCandidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    $c = Get-Command zsign -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Test-LoopSegmentsSigningPassword {
    param([string] $CredTarget = $LoopSegmentsSigningCredTarget)
    return [bool]((& cmdkey /list 2>$null) | Select-String -SimpleMatch "target=$CredTarget")
}

function Invoke-LoopSegmentsSigningCheck {
    # LoopSegments-UsbSign.py check -> its result line (READY ... / NO_P12 / NO_PASSWORD / ...).
    param(
        [Parameter(Mandatory)] $Runtime,
        [string] $P12 = $LoopSegmentsSigningP12,
        [string] $CredTarget = $LoopSegmentsSigningCredTarget
    )
    $py = Join-Path $script:LoopSegmentsWindowsDir 'usb\LoopSegments-UsbSign.py'
    $r = Invoke-LoopSegmentsPythonRuntime -Runtime $Runtime -ArgumentList @($py, 'check', $P12, $CredTarget)
    $line = @($r.Lines | Where-Object { $_ -match '^[A-Z_]+(\t|$)' } | Select-Object -Last 1)
    if ($line) { return [string]$line[0] }
    return ('ERROR' + "`t" + (($r.Lines | Select-Object -Last 1) -join ''))
}

function Test-LoopSegmentsSignedInstallReady {
    # $true when the PC-signed install can run now: zsign found and LoopSegments-UsbSign.py check
    # prints READY (.p12 + password + an unexpired profile on the USB phone for the installed app).
    param(
        [Parameter(Mandatory)] $Runtime,
        [string] $P12 = $LoopSegmentsSigningP12,
        [string] $CredTarget = $LoopSegmentsSigningCredTarget
    )
    if (-not (Test-Path -LiteralPath $P12) -or -not (Find-LoopSegmentsZsign)) { return $false }
    return ((Invoke-LoopSegmentsSigningCheck -Runtime $Runtime -P12 $P12 -CredTarget $CredTarget) -match '^READY\t')
}
