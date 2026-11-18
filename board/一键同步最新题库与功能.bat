@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_updater.ps1" -Interactive
pause
