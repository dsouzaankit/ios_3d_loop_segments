#Requires -Version 7.0
<#
.SYNOPSIS
  Set up (or check) the PC-signed USB install on this PC: zsign, SideStore's .p12, its password.

.DESCRIPTION
  Works on any Windows PC; Setup-LoopSegmentsWindows.ps1 runs it. Each step is skipped when done:
  Uses the shared kit in ..\env_setup\zsign next to the repo (SideStoreSigning.ps1, sidestore_sign.py;
  see its README.md). No env_setup there: nothing to set up (clone ios_env_setup next to the repo).
  1. zsign: found via zsignExe (loop-segments-windows.json), env_setup\zsign\zsign.exe, or PATH.
     Missing: downloads zsign-windows-x64.zip (pinned version + SHA-256 in SideStoreSigning.ps1) from
     github.com/zhlynn/zsign releases into env_setup\zsign. -SkipZsign skips this.
  2. Certificate: env_setup\zsign\signing.p12 (gitignored; it syncs with that folder, so other PCs on
     the same synced folder have it too). -P12 <file> copies an export there (SideStore > Settings >
     Certificate Management > long-press the certificate > Export Certificate > Export Full (.p12)).
  3. Password: a generic credential SideStore-signing (older setups: LoopSegments-signing, still used)
     in this PC's Credential Manager (per PC, never synced). Missing (or -ResetPassword): cmdkey prompts.
  4. Check: env_setup\zsign\sidestore_sign.py check for Loop Segments (needs the iPhone on USB for the
     profile part).

.EXITCODES
  0  READY (or everything set up but no iPhone on USB to check against)
  1  something still missing (printed)

.EXAMPLE
  .\setup\Set-LoopSegmentsSigning.ps1

.EXAMPLE
  .\setup\Set-LoopSegmentsSigning.ps1 -P12 "$env:USERPROFILE\iCloudDrive\Downloads\iPhone Developer_ ....p12"
#>
[CmdletBinding()]
param(
    # A SideStore export to copy to env_setup\zsign\signing.p12 (replaces the one there).
    [string] $P12 = '',
    # Ask for the .p12 password again even when this PC already has it.
    [switch] $ResetPassword,
    # Never prompt (setup runs, scheduled use): report what is missing instead.
    [switch] $NoPrompt,
    # Do not download zsign.
    [switch] $SkipZsign
)

$ErrorActionPreference = 'Stop'
$WindowsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $WindowsDir 'lib\LoopSegments-Windows.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsPython.ps1')
. (Join-Path $WindowsDir 'lib\Get-LoopSegmentsSigning.ps1')

function Write-Sign([string] $Text, [string] $Color = 'Gray') {
    Write-Host "[signing] $Text" -ForegroundColor $Color
}

$missing = @()

if (-not (Test-LoopSegmentsZsignKit)) {
    Write-Sign "No env_setup\zsign next to the repo ($LoopSegmentsSigningDir). Clone https://github.com/dsouzaankit/ios_env_setup.git as env_setup next to this repo, then run this again." Yellow
    exit 1
}

# --- 1. zsign ---
$zsign = Find-LoopSegmentsZsign
if ($zsign) {
    Write-Sign "zsign: $zsign"
} elseif ($SkipZsign) {
    Write-Sign 'zsign not found (-SkipZsign).' Yellow
    $missing += 'zsign'
} else {
    try {
        Write-Sign "Downloading zsign $SideStoreZsignVersion ..."
        $zsign = Install-SideStoreZsign
        Write-Sign "zsign installed (checksum OK): $zsign" Green
    } catch {
        Write-Sign "zsign: $($_.Exception.Message)" Red
        $missing += 'zsign'
    }
}

# --- 2. Certificate ---
if ($P12) {
    [void](Copy-SideStoreSigningP12 -Source $P12)
    Write-Sign "Certificate copied to $LoopSegmentsSigningP12 (delete the export from iCloud Drive: it is your signing key)." Green
}
if (Test-Path -LiteralPath $LoopSegmentsSigningP12) {
    Write-Sign "Certificate: $LoopSegmentsSigningP12"
} else {
    Write-Sign "No certificate at $LoopSegmentsSigningP12. Export it from SideStore (Settings > Certificate Management > long-press the certificate > Export Certificate > Export Full (.p12)), then run this with -P12 <file>." Yellow
    $missing += 'certificate'
}

# --- 3. Password (this PC's Credential Manager) ---
$hasPassword = Test-LoopSegmentsSigningPassword
if ($ResetPassword) { $LoopSegmentsSigningCredTarget = $SideStoreSigningCredTarget }
if ($hasPassword -and -not $ResetPassword) {
    Write-Sign "Password: saved on this PC ($LoopSegmentsSigningCredTarget)."
} elseif ($NoPrompt) {
    Write-Sign "No password saved on this PC. Run .\setup\Set-LoopSegmentsSigning.ps1 (it prompts) or: cmdkey /generic:$LoopSegmentsSigningCredTarget /user:p12 /pass" Yellow
    $missing += 'password'
} else {
    Write-Sign 'Enter the password you chose when exporting the certificate from SideStore:' Cyan
    # cmdkey prompts itself, so the password is never on a command line or in history.
    if (-not (Set-SideStoreSigningPassword -CredTarget $LoopSegmentsSigningCredTarget)) { $missing += 'password' }
}

# --- 4. Check ---
if (-not $missing) {
    $rt = Get-LoopSegmentsPythonRuntime -RequirePymobiledevice3
    if ($null -eq $rt) {
        Write-Sign 'No Python with pymobiledevice3 (run Setup-LoopSegmentsWindows.ps1) - check skipped.' Yellow
        exit 1
    }
    $line = Invoke-LoopSegmentsSigningCheck -Runtime $rt
    switch -Regex ($line) {
        '^READY\t' {
            $f = $line -split "`t"
            Write-Sign "READY: $($f[1]); profile valid until $($f[3]) UTC, certificate until $($f[4])." Green
            exit 0
        }
        '^NO_DEVICE\b' {
            Write-Sign 'Set up. No iPhone on USB, so the profile was not checked (run again with it plugged in).' Green
            exit 0
        }
        '^BAD_P12\b' { Write-Sign "Certificate or password wrong: $line  (re-export, or -ResetPassword)" Red }
        default { Write-Sign "Check: $line" Yellow }
    }
    exit 1
}
Write-Sign "Still missing: $($missing -join ', ')." Yellow
exit 1
