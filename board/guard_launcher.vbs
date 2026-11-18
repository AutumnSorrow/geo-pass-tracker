' Zero-Window Launcher for Geo Pre-Class Guard (eliminates all console flash)
Option Explicit
Dim fso, scriptDir, modeArg, psPath, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
modeArg = "-Mode Daemon"
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "launchnow" Then
        modeArg = "-Mode LaunchNow"
    ElseIf LCase(WScript.Arguments(0)) = "hotreload" Then
        modeArg = "-Mode Daemon -HotReload"
    ElseIf LCase(WScript.Arguments(0)) = "daemon" Then
        modeArg = "-Mode Daemon"
    End If
End If
psPath = scriptDir & "\guard_daemon.ps1"
If fso.FileExists(psPath) Then
    cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & psPath & """ " & modeArg
    CreateObject("WScript.Shell").Run cmd, 0, False
End If
