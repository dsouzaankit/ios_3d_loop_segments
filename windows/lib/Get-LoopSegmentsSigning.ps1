# PC-signed USB install (zsign + SideStore's exported certificate): shared lookups for
# usb\Prepare-PhoneForSideStoreViaUsb.ps1 and usb\Install-LoopSegmentsIpaViaUsb.ps1.
# Dot-source after LoopSegments-Windows.ps1 and Get-LoopSegmentsPython.ps1.

$script:LoopSegmentsWindowsDir = Split-Path -Parent $PSScriptRoot
$script:LoopSegmentsRepoRoot = Split-Path -Parent $script:LoopSegmentsWindowsDir

# windows\signing\ is gitignored. Not under AppData: the Microsoft Store Python sees its own private
# copy of AppData\Local.
$LoopSegmentsSigningP12 = Join-Path $script:LoopSegmentsWindowsDir 'signing\signing.p12'
# Windows Credential Manager generic credential holding the .p12 password.
$LoopSegmentsSigningCredTarget = 'LoopSegments-signing'

function Find-LoopSegmentsZsign {
    # Next to this repo: <parent of repo>\env_setup\zsign\zsign.exe (shared with the other iOS apps).
    $p = Join-Path (Split-Path -Parent $script:LoopSegmentsRepoRoot) 'env_setup\zsign\zsign.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $c = Get-Command zsign -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
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
    $py = Join-Path $script:LoopSegmentsWindowsDir 'usb\LoopSegments-UsbSign.py'
    $r = Invoke-LoopSegmentsPythonRuntime -Runtime $Runtime -ArgumentList @($py, 'check', $P12, $CredTarget)
    return (($r.Lines -join "`n") -match '(?m)^READY\t')
}
