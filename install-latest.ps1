#Requires -Version 5.1
<#
.SYNOPSIS
  Install the newest already-built IPA: deploy.ps1 -UseLatest (no GitHub build, no build-number bump).

.DESCRIPTION
  Downloads the newest successful ios-build (workflow_dispatch) IPA, copies it to iCloud Downloads,
  and with the iPhone on USB connects LocalDevVPN and runs the SideStore USB install - the same as a
  deploy, minus triggering a build. Use it after a deploy timed out or failed after the build, or to
  reinstall the latest build. (bump-build.ps1 also does this on its own when the newest built IPA is
  newer than the phone's build.)

  The USB install skips a phone that already has this build; -Force reinstalls it anyway.

.EXAMPLE
  .\install-latest.ps1

.EXAMPLE
  .\install-latest.ps1 -SkipICloud -NoPhoneRestart

.EXAMPLE
  .\install-latest.ps1 -Force   # reinstall the build the phone already has
#>
param(
    # Same meaning as in deploy.ps1.
    [switch] $SkipICloud,
    [switch] $SkipUsbInstall,
    [switch] $SkipPhonePrep,
    [switch] $NoPhoneRestart,
    [switch] $EnsureAltStorePrep,
    [switch] $NoWaitEnter,
    # Reinstall even when the phone already has this build (deploy.ps1 -ForceUsbInstall).
    [switch] $Force
)

$deploy = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'deploy.ps1'
# Named arguments (a hashtable): a splatted string array would reach deploy.ps1 as plain values.
$pass = @{ UseLatest = $true }
foreach ($name in 'SkipICloud', 'SkipUsbInstall', 'SkipPhonePrep', 'NoPhoneRestart', 'EnsureAltStorePrep', 'NoWaitEnter') {
    if ((Get-Variable -Name $name -ValueOnly)) { $pass[$name] = $true }
}
if ($Force) { $pass['ForceUsbInstall'] = $true }
& $deploy @pass
exit $LASTEXITCODE
