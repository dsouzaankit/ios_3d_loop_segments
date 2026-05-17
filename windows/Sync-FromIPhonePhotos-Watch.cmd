@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-FromIPhonePhotos.ps1" -Watch %*
pause
