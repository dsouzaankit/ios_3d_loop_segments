@echo off
rem Emergency: phone LAN dead + Explorer frozen on L: mount.
rem Kills loopsegments rclone (+ mount PowerShell window), then restarts Explorer.
rem Works from Task Manager -> File -> Run new task if Explorer is wedged.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mount-LoopSegmentsRclone.ps1" -Unstick
echo.
pause
