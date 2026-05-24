@echo off
rem Day-to-day rclone mount -> L: (uses loop-segments-windows.json). Pass -ReadOnly, -Remove, -TestOnly, etc.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mount-LoopSegmentsRclone.ps1" %*
if errorlevel 1 pause
