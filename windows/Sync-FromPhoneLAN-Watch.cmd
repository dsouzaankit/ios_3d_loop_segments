@echo off
cd /d "%~dp0"
set "STAGING=%LOCALAPPDATA%\LoopSegmentsLanStaging"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-FromPhoneLAN.ps1" -Watch %*
if exist "%STAGING%\lan-watch-cleanup.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%STAGING%\lan-watch-cleanup.ps1"
)
