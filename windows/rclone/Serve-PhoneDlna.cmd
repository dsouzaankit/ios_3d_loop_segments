@echo off
rem Day-to-day rclone serve dlna for phone WebDAV (uses loop-segments-windows.json). Pass -Remove, -TestOnly, etc.
rem On error, Serve-LoopSegmentsRcloneDlna.ps1 waits for Enter (no second pause here).
cd /d "%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Serve-LoopSegmentsRcloneDlna.ps1" %*
