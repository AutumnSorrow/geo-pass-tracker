@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0guard_daemon.ps1" -Mode Install
pause
