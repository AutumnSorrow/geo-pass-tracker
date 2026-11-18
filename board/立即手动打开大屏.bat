@echo off
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0guard_daemon.ps1" -Mode LaunchNow
