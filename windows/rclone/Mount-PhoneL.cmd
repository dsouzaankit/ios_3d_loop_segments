@echo off
rem Day-to-day rclone mount -> L: (uses loop-segments-windows.json). Pass -ReadOnly, -Remove, -TestOnly, etc.
rem On error, Mount-LoopSegmentsRclone.ps1 waits for Enter (no second pause here).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Mount-LoopSegmentsRclone.ps1" %*
