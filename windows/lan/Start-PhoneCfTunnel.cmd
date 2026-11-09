@echo off
REM Deprecated (asks for confirmation): Cloudflare quick tunnel → phone LAN page (loop-segments-windows.json).
setlocal
set "SCRIPT=%~dp0Start-LoopSegmentsCloudflareTunnel.ps1"
where pwsh >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh^) is required.
  echo Install: https://aka.ms/powershell
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EC=%ERRORLEVEL%"
if not "%EC%"=="0" pause
exit /b %EC%
