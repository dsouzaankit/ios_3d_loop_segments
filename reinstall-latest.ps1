#Requires -Version 5.1
<#
.SYNOPSIS
  (Re)install the newest already-built IPA: deploy.ps1 -UseLatest -ForceUsbInstall (no GitHub build,
  no build-number bump).

.DESCRIPTION
  Downloads the newest successful ios-build (workflow_dispatch) IPA, copies it to iCloud Downloads,
  and with the iPhone on USB connects LocalDevVPN and runs the SideStore USB install - the same as a
  deploy, minus triggering a build. It installs when that IPA's build is the same as or newer than
  the phone's: the same build is reinstalled (confirmed by the app's new install path), an older one
  is never installed. Use it after a deploy timed out or failed after the build, or to reinstall
  the current build. (bump-build.ps1 also installs a built IPA newer than the phone's on its own.)

.EXAMPLE
  .\reinstall-latest.ps1

.EXAMPLE
  .\reinstall-latest.ps1 -SkipICloud -NoPhoneRestart
#>
param(
    # Same meaning as in deploy.ps1.
    [switch] $SkipICloud,
    [switch] $SkipUsbInstall,
    [switch] $SkipPhonePrep,
    [switch] $NoPhoneRestart,
    [switch] $EnsureAltStorePrep,
    [switch] $NoWaitEnter
)

$deploy = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'deploy.ps1'
# Named arguments (a hashtable): a splatted string array would reach deploy.ps1 as plain values.
# ForceUsbInstall: the same build as the phone's is reinstalled too (older ones never are).
$pass = @{ UseLatest = $true; ForceUsbInstall = $true }
foreach ($name in 'SkipICloud', 'SkipUsbInstall', 'SkipPhonePrep', 'NoPhoneRestart', 'EnsureAltStorePrep', 'NoWaitEnter') {
    if ((Get-Variable -Name $name -ValueOnly)) { $pass[$name] = $true }
}
& $deploy @pass
exit $LASTEXITCODE
