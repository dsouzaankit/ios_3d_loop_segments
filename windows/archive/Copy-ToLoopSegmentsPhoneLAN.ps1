#Requires -Version 5.1
<#
.SYNOPSIS
  Upload files to the phone via LAN WebDAV without mounting L: (optional if mount is not running).

.DESCRIPTION
  The phone accepts authenticated PUT/MKCOL under pcld_ios_media/ except loop/, _working*,
  _vanilla_*, and export segment files. Use pcld_ios_media for a bootstrap .ps1 that copies
  into scripts/ and other subfolders via L: or further PUTs. Max 2 MB per file.

.PARAMETER Path
  Local file(s) or folder(s) to upload.

.PARAMETER RemoteDir
  Remote folder under Exports. Default pcld_ios_media (bootstrap .ps1 at media root).

.PARAMETER ToScripts
  Upload under pcld_ios_media/scripts/ instead of pcld_ios_media/.

.EXAMPLE
  .\Copy-ToLoopSegmentsPhoneLAN.ps1 .\Sync-PhoneFromLAN.ps1

.EXAMPLE
  copy .\Sync-PhoneFromLAN.ps1 L:\pcld_ios_media\

.EXAMPLE
  .\Copy-ToLoopSegmentsPhoneLAN.ps1 -Path .\tools\ -ToScripts
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments = $true)]
    [string[]] $Path,
    [string] $PhoneHost = '',
    [string] $RemoteDir = '',
    [switch] $ToScripts,
    [int] $Port = 0
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\LoopSegments-Windows.ps1"

function Normalize-PhoneLanRemoteDir {
    param([string] $Dir)
    $d = $Dir.Trim().Trim('/').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($d)) {
        throw 'RemoteDir cannot be empty.'
    }
    if ($d -notmatch '^pcld_ios_media') {
        throw "RemoteDir must be pcld_ios_media or a subfolder (got: $d)."
    }
    if ($d -eq 'pcld_ios_media/loop' -or $d -match '^pcld_ios_media/loop/') {
        throw "RemoteDir is read-only on the phone: $d"
    }
    return $d
}

function Test-PhoneLanSkipMkcol {
    param([string] $RelativeDir)
    $d = $RelativeDir.Trim().Trim('/')
    return $d -eq 'pcld_ios_media' -or $d -eq 'pcld_ios_media/loop'
}

function Ensure-PhoneLanRemoteCollection {
    param(
        [string] $BaseUrl,
        [string] $RelativeDir,
        [hashtable] $Headers
    )
    $parts = @($RelativeDir -split '/')
    $built = ''
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $built = if ($built) { "$built/$part" } else { $part }
        if (Test-PhoneLanSkipMkcol $built) { continue }
        $uri = "$BaseUrl/$built/"
        Invoke-LoopSegmentsPhoneWebDavMkcol -Uri $uri -Headers $Headers
    }
}

function Send-PhoneLanFile {
    param(
        [string] $BaseUrl,
        [string] $RemoteDirNormalized,
        [string] $LocalFile,
        [string] $RemoteRelative,
        [hashtable] $Headers
    )
    $remoteRel = if ([string]::IsNullOrWhiteSpace($RemoteRelative)) {
        (Split-Path -Leaf $LocalFile)
    } else {
        $RemoteRelative.Replace('\', '/')
    }
    $remotePath = "$RemoteDirNormalized/$remoteRel".Replace('//', '/')
    $parent = ($remotePath -replace '/[^/]+$','').Trim('/')
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-PhoneLanRemoteCollection -BaseUrl $BaseUrl -RelativeDir $parent -Headers $Headers
    }
    $uri = "$BaseUrl/$remotePath"
    Write-Host "PUT $uri  <=  $LocalFile"
    Invoke-LoopSegmentsPhoneWebDavPutFile -Uri $uri -LocalPath $LocalFile -Headers $Headers
}

$targetDir = if ($ToScripts) {
    'pcld_ios_media/scripts'
} elseif (-not [string]::IsNullOrWhiteSpace($RemoteDir)) {
    $RemoteDir
} else {
    'pcld_ios_media'
}
$remoteRoot = Normalize-PhoneLanRemoteDir $targetDir
$baseUrl = Get-LoopSegmentsPhoneLanBaseUrl -PhoneHostOverride $PhoneHost -PortOverride $Port
$headers = Get-LoopSegmentsPhoneWebDavAuthHeader

if (-not $Path -or $Path.Count -eq 0) {
    throw 'Pass at least one -Path (file or folder).'
}

foreach ($item in $Path) {
    if (-not (Test-Path -LiteralPath $item)) {
        throw "Not found: $item"
    }
    if (Test-Path -LiteralPath $item -PathType Container) {
        $root = (Resolve-Path -LiteralPath $item).Path
        Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            Send-PhoneLanFile -BaseUrl $baseUrl -RemoteDirNormalized $remoteRoot `
                -LocalFile $_.FullName -RemoteRelative $rel -Headers $headers
        }
    } else {
        Send-PhoneLanFile -BaseUrl $baseUrl -RemoteDirNormalized $remoteRoot `
            -LocalFile (Resolve-Path -LiteralPath $item).Path -RemoteRelative '' -Headers $headers
    }
}

Write-Host "Done. On phone (LAN): $baseUrl/$remoteRoot/"
