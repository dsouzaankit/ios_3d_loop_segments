#Requires -Version 5.1
# Forwarder — full script moved to ..\rclone\Mount-LoopSegmentsRclone.ps1
Write-Warning 'Mount-LoopSegmentsRclone-WebDAVMount-Legacy.ps1 is deprecated. Use ..\rclone\Mount-LoopSegmentsRclone.ps1'
& (Join-Path (Split-Path $PSScriptRoot -Parent) 'rclone\Mount-LoopSegmentsRclone.ps1') @args
