@echo off
if exist "%~dp0guard_launcher.vbs" (
    wscript.exe //B //NoLogo "%~dp0guard_launcher.vbs" LaunchNow
) else (
    start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0guard_daemon.ps1" -Mode LaunchNow
)
