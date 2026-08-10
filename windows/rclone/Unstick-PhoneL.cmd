@echo off
rem Kill stuck phone rclone mount / remount helper.
cd /d "%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mount-LoopSegmentsRclone.ps1" -Unstick %*
