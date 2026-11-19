param(
    [string]$Mode = "Daemon", # Daemon | LaunchNow | CheckOnce | Install | Uninstall
    [switch]$HotReload,
    [switch]$NoCloud
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$HtmlPath  = Join-Path $ScriptDir "地理课前通关大屏.html"
$CfgPath   = Join-Path $ScriptDir "schedule_config.json"
$StatePath = Join-Path $ScriptDir "runtime_state.json"
$SyncPath  = Join-Path $ScriptDir "sync_updater.ps1"
$VbsPath   = Join-Path $ScriptDir "guard_launcher.vbs"

$HbTopic      = "qy_geo_hb_9f4a2c8e71b6d305"
$CtlTopic     = "qy_geo_ctl_7d3e91a5c84b20f6"
$LocalApiPort = 18768
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

if (Test-Path $SyncPath) {
    . $SyncPath -LibraryOnly
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class IdleWin32 {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int nIndex);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint esFlags);
    [DllImport("user32.dll")] static extern IntPtr PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public static double GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        uint diff = unchecked((uint)Environment.TickCount - lii.dwTime);
        return diff / 1000.0;
    }
    public static bool IsForegroundFullscreen() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return false;
        int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
        return (r.Left <= 0 && r.Top <= 0 && (r.Right - r.Left) >= sw && (r.Bottom - r.Top) >= sh);
    }
    public static void KeepSystemAwake() {
        SetThreadExecutionState(0x80000001);
    }
    public static void WakeDisplayNow() {
        SetThreadExecutionState(0x80000003);
        PostMessage((IntPtr)0xFFFF, 0x0112, (IntPtr)0xF170, (IntPtr)(-1));
    }
}
"@

function Get-NowMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonSafe([string]$Path, $Obj) {
    try { [System.IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 8), $Utf8NoBom) } catch {}
}

function Get-RuntimeState {
    $st = Read-JsonSafe $StatePath
    if (-not $st) {
        $st = [PSCustomObject]@{
            last_triggered_slot = ""
            last_triggered_ms   = [int64]0
            snooze_slot         = ""
            snooze_until_ms     = [int64]0
            pause_until_ms      = [int64]0
            pause_label         = ""
            applied_remote_ts   = [int64]0
            current_ep          = 1
            board_open_ping_ms  = [int64]0
            class_ep            = [PSCustomObject]@{ "10" = 1; "11" = 1 }
            recent_old          = [PSCustomObject]@{ "10" = @(); "11" = @() }
            vcnt_map            = [PSCustomObject]@{}
            ui_prefs            = $null
        }
    } else {
        if (-not $st.PSObject.Properties['class_ep'] -or -not $st.class_ep) {
            $seedEp = if ([int]$st.current_ep -ge 1) { [int]$st.current_ep } else { 1 }
            $st | Add-Member -NotePropertyName "class_ep" -NotePropertyValue ([PSCustomObject]@{ "10" = $seedEp; "11" = $seedEp }) -Force
        }
        if (-not $st.PSObject.Properties['recent_old'] -or -not $st.recent_old) {
            $st | Add-Member -NotePropertyName "recent_old" -NotePropertyValue ([PSCustomObject]@{ "10" = @(); "11" = @() }) -Force
        }
        if (-not $st.PSObject.Properties['vcnt_map'] -or -not $st.vcnt_map) {
            $st | Add-Member -NotePropertyName "vcnt_map" -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        if (-not $st.PSObject.Properties['ui_prefs']) {
            $st | Add-Member -NotePropertyName "ui_prefs" -NotePropertyValue $null -Force
        }
    }
    return $st
}

function Get-SavedClassEp($st, [string]$ClsCode) {
    if ($st -and $st.PSObject.Properties['class_ep'] -and $st.class_ep -and $st.class_ep.PSObject.Properties[$ClsCode]) {
        $v = [int]$st.class_ep.$ClsCode
        if ($v -ge 1) { return $v }
    }
    if ($st -and [int]$st.current_ep -ge 1) { return [int]$st.current_ep }
    return 1
}

function Stop-AllOtherDaemons {
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"?[^"]*guard_daemon\.ps1"?\s+-Mode\s+Daemon'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
    return $killed
}

function Repair-Shortcuts([string]$ClsCode, [bool]$UpdateStartup = $true) {
    if (Get-Command Remove-ObsoleteSyncShortcuts -ErrorAction SilentlyContinue) { Remove-ObsoleteSyncShortcuts }
    try {
        $Wsh = New-Object -ComObject WScript.Shell
        $DesktopDir = [Environment]::GetFolderPath("Desktop")
        Get-ChildItem -Path $DesktopDir -Filter "地理课前通关(*班).lnk" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne "地理课前通关(${ClsCode}班).lnk"
        } | Remove-Item -Force -ErrorAction SilentlyContinue

        $ScLaunch = $Wsh.CreateShortcut((Join-Path $DesktopDir "地理课前通关(${ClsCode}班).lnk"))
        if (Test-Path $VbsPath) {
            $ScLaunch.TargetPath = "wscript.exe"
            $ScLaunch.Arguments = "//B //NoLogo `"$VbsPath`" LaunchNow"
            $ScLaunch.IconLocation = "msedge.exe,0"
        } else {
            $ScLaunch.TargetPath = "powershell.exe"
            $ScLaunch.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode LaunchNow"
        }
        $ScLaunch.WorkingDirectory = $ScriptDir
        $ScLaunch.Save()

        if ($UpdateStartup) {
            $StartupDir = [Environment]::GetFolderPath("Startup")
            Get-ChildItem -Path $StartupDir -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            $ScDaemon = $Wsh.CreateShortcut((Join-Path $StartupDir "GeoPreClassGuard_${ClsCode}.lnk"))
            if (Test-Path $VbsPath) {
                $ScDaemon.TargetPath = "wscript.exe"
                $ScDaemon.Arguments = "//B //NoLogo `"$VbsPath`" Daemon"
            } else {
                $ScDaemon.TargetPath = "powershell.exe"
                $ScDaemon.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Daemon"
            }
            $ScDaemon.WorkingDirectory = $ScriptDir
            $ScDaemon.Save()
        }
    } catch {}
}

function Ensure-BoardNeverSleeps {
    try {
        [IdleWin32]::KeepSystemAwake()
        & powercfg.exe /change standby-timeout-ac 0 *> $null
        & powercfg.exe /change hibernate-timeout-ac 0 *> $null
    } catch {}
}

function Get-BrowserExe {
    $candidates = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return "msedge.exe"
}

function Get-ForegroundAppName {
    try {
        $hwnd = [IdleWin32]::GetForegroundWindow()
        $pidOut = [uint32]0
        [IdleWin32]::GetWindowThreadProcessId($hwnd, [ref]$pidOut) | Out-Null
        if ($pidOut -gt 0) { return (Get-Process -Id $pidOut -ErrorAction SilentlyContinue).ProcessName }
    } catch {}
    return ""
}

function Get-WeekParity([datetime]$dt, $cfg) {
    try {
        $curMon = $dt.Date.AddDays(-(([int]$dt.DayOfWeek + 6) % 7))
        $ancMon = [datetime]::ParseExact([string]$cfg.anchor_monday, "yyyy-MM-dd", $null).Date
        $wDiff  = [math]::Round(($curMon - $ancMon).TotalDays / 7.0)
        $isSame = ([math]::Abs($wDiff) % 2 -eq 0)
        if ($cfg.anchor_week_parity -eq "odd") { return $(if ($isSame) { "odd" } else { "even" }) }
        return $(if ($isSame) { "even" } else { "odd" })
    } catch { return "odd" }
}

function Find-UpcomingSlot($cfg, [string]$ClsCode, [double]$MinFrom = -2.0, [double]$MaxTo = 20.0) {
    $offNow = [int]$cfg.clock_offset_minutes
    $nowCal = (Get-Date).AddMinutes($offNow)
    $wpNow  = Get-WeekParity $nowCal $cfg
    $dowNow = [int]$nowCal.DayOfWeek; if ($dowNow -eq 0) { $dowNow = 7 }
    $slotsNow = $cfg.schedules.$ClsCode."$dowNow"
    if ($slotsNow) {
        foreach ($s in $slotsNow) {
            if ($s.week -ne "all" -and $s.week -ne $wpNow) { continue }
            $tObj = [datetime]::ParseExact([string]$s.time, "HH:mm", $null)
            $diffM = ($tObj - $nowCal).TotalMinutes
            if ($diffM -ge $MinFrom -and $diffM -le $MaxTo) {
                return [PSCustomObject]@{
                    timeStr = [string]$s.time
                    slotKey = "$($nowCal.ToString('yyyyMMdd'))_${ClsCode}_$($s.time)"
                    diffMin = $diffM
                }
            }
        }
    }
    return $null
}

function Open-BoardApp([string]$ClsCode, [string]$TargetTime = "", [int]$OffsetMin = 0) {
    try { [IdleWin32]::WakeDisplayNow() } catch {}
    $exe = Get-BrowserExe
    $stOpen = Get-RuntimeState
    $savedEp = Get-SavedClassEp $stOpen $ClsCode
    $qs = "?class=$ClsCode&locked=1&stage=prep&offset=$OffsetMin&ep=$savedEp"
    if ($TargetTime -ne "") { $qs += "&target=$TargetTime" }
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri + $qs
    $profDir = Join-Path $ScriptDir ".board_kiosk_profile"
    if ($exe -like "*msedge.exe*") {
        Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$profDir`" --no-first-run --no-default-browser-check --kiosk `"$uri`" --edge-kiosk-type=fullscreen"
    } else {
        Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$profDir`" --no-first-run --no-default-browser-check --kiosk `"$uri`""
    }
}

$cfg = Read-JsonSafe $CfgPath
if (-not $cfg) {
    $tplFallback = Join-Path $ScriptDir "schedule_template.json"
    $cfg = Read-JsonSafe $tplFallback
}
$cls = if ($cfg -and $cfg.current_blackboard_class) { [string]$cfg.current_blackboard_class } else { "10" }

if ($Mode -eq "LaunchNow") {
    $offNow = if ($cfg) { [int]$cfg.clock_offset_minutes } else { 0 }
    $nearSlot = if ($cfg) { Find-UpcomingSlot $cfg $cls -3.0 25.0 } else { $null }
    $nearTarget = if ($nearSlot) { $nearSlot.timeStr } else { "" }
    if ($nearSlot) {
        $stNow = Get-RuntimeState
        $stNow.last_triggered_slot = $nearSlot.slotKey
        $stNow.last_triggered_ms = Get-NowMs
        $stNow.snooze_slot = ""
        Write-JsonSafe $StatePath $stNow
    }
    Open-BoardApp $cls $nearTarget $offNow
    exit 0
}

if ($Mode -eq "Uninstall") {
    $killed = Stop-AllOtherDaemons
    $StartupDir = [Environment]::GetFolderPath("Startup")
    Get-ChildItem -Path $StartupDir -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if (Get-Command Remove-ObsoleteSyncShortcuts -ErrorAction SilentlyContinue) { Remove-ObsoleteSyncShortcuts }

    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  [已停止] 已关闭后台值守进程 ($killed 个) 并移除开机自启！" -ForegroundColor Green
    Write-Host "  * 💡 提示：若仅考试几天不弹窗，无需卸载！直接用手机端或黑板【设置 -> 考试免打扰】到期自动恢复。" -ForegroundColor Yellow
    Write-Host "  * 如需恢复开机值守：双击【一键部署开机值守到本班黑板.bat】。" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    exit 0
}

if ($Mode -eq "Install") {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  青云实验中学 · 高三地理课前通关系统 一体机部署向导" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    $inCls = Read-Host "1. 请输入本教室绑定班级（填 10 或 11，直接回车默认 [$cls]）"
    if ($inCls -in @("10","11")) { $cfg.current_blackboard_class = $inCls; $cls = $inCls }

    $inParity = Read-Host "2. 本周在学校校历中是单周还是双周？（填 1=单周，2=双周，此后每周一自动翻转）"
    $today = Get-Date
    $cfg.anchor_monday = $today.Date.AddDays(-(([int]$today.DayOfWeek + 6) % 7)).ToString("yyyy-MM-dd")
    $cfg.anchor_week_parity = if ($inParity -eq "2") { "even" } else { "odd" }

    $inOff = Read-Host "3. 一体机时间校准：比学校铃声快2分钟填 -2，慢2分钟填 2（准点直接回车填 0）"
    if ($inOff -match "^-?\d+$") { $cfg.clock_offset_minutes = [int]$inOff }

    Write-JsonSafe $CfgPath $cfg
    Stop-AllOtherDaemons | Out-Null
    Repair-Shortcuts $cls $true

    if (Test-Path $VbsPath) {
        Start-Process -FilePath "wscript.exe" -ArgumentList "//B //NoLogo `"$VbsPath`" Daemon" -WindowStyle Hidden
    } else {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Daemon" -WindowStyle Hidden
    }
    $pLabel = if ($cfg.anchor_week_parity -eq "odd") { "单周" } else { "双周" }
    Ensure-BoardNeverSleeps
    Write-Host ""
    Write-Host "✅ 部署成功！本黑板已专属锁定【高三 ${cls}班】（本周：$pLabel，零黑框静默守护已启动）。" -ForegroundColor Green
    Write-Host "✅ 桌面已清理精简，仅保留唯一图标【地理课前通关(${cls}班)】。" -ForegroundColor Green
    Start-Sleep -Seconds 3
    exit 0
}

if ($Mode -eq "CheckOnce") {
    $now = (Get-Date).AddMinutes([int]$cfg.clock_offset_minutes)
    $wp = Get-WeekParity $now $cfg
    $idleSec = [IdleWin32]::GetIdleSeconds()
    $st = Get-RuntimeState
    $pauseTxt = if ([int64]$st.pause_until_ms -gt (Get-NowMs)) { "PAUSED_UNTIL=$($st.pause_label)" } else { "ACTIVE" }
    $activeList = @()
    foreach ($d in @("1","2","3","4","5","6","7")) {
        $slots = $cfg.schedules.$cls.$d
        if ($slots) {
            foreach ($s in $slots) {
                if ($s.week -eq "all" -or $s.week -eq $wp) { $activeList += "$($s.label)($($s.time))" }
            }
        }
    }
    Write-Output ("SCHEDULE_OK | Class=${cls}班 | Status=$pauseTxt | Parity=$wp | Idle=$([math]::Round($idleSec,1))s | ActiveSlots=" + ($activeList -join ", "))
    exit 0
}

# ==================== Daemon 模式：单实例强互斥 + 零子进程无闪烁守护 ====================
Stop-AllOtherDaemons | Out-Null
$MutexCreated = $false
$GlobalMutex = $null
try {
    $GlobalMutex = New-Object System.Threading.Mutex($true, "Global\GeoPreClassGuardSingleInstance", [ref]$MutexCreated)
    if (-not $MutexCreated) {
        if (-not $GlobalMutex.WaitOne(1500)) { exit 0 }
    }
} catch {}

if (Get-Command Remove-ObsoleteSyncShortcuts -ErrorAction SilentlyContinue) { Remove-ObsoleteSyncShortcuts }
$StartupCheckDir = [Environment]::GetFolderPath("Startup")
if (@(Get-ChildItem -Path $StartupCheckDir -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue).Count -gt 0) {
    Repair-Shortcuts $cls $true
}
Ensure-BoardNeverSleeps

$HttpHandler = New-Object System.Net.Http.HttpClientHandler
$DaemonHttp  = New-Object System.Net.Http.HttpClient($HttpHandler)
$DaemonHttp.DefaultRequestHeaders.UserAgent.ParseAdd("GeoBoardDaemon/3.1")
$DaemonHttp.Timeout = [TimeSpan]::FromSeconds(4)

function Get-LocalBuildVer {
    $mf = Read-JsonSafe (Join-Path $ScriptDir "board_manifest.json")
    if ($mf -and $mf.build_version) { return [string]$mf.build_version }
    return "20261118"
}

function Send-BoardHeartbeat($curCfg, $curState) {
    if ($NoCloud) { return }
    try {
        $cCode = [string]$curCfg.current_blackboard_class
        $payload = [PSCustomObject]@{
            cls          = "${cCode}班"
            clsCode      = $cCode
            host         = $env:COMPUTERNAME
            ver          = (Get-LocalBuildVer)
            ep           = [int]$curState.current_ep
            pauseUntilMs = [int64]$curState.pause_until_ms
            pauseLabel   = [string]$curState.pause_label
            ts           = (Get-NowMs)
        } | ConvertTo-Json -Compress
        $content = New-Object System.Net.Http.StringContent($payload, [System.Text.Encoding]::UTF8, "application/json")
        $DaemonHttp.PostAsync("https://ntfy.sh/$HbTopic", $content).GetAwaiter().GetResult() | Out-Null
    } catch {}
}

function Sync-RemoteControl($curCfg, $curState) {
    if ($NoCloud) { return $false }
    $changed = $false
    $cCode = [string]$curCfg.current_blackboard_class
    $candidates = @()

    try {
        $rawLines = $DaemonHttp.GetStringAsync("https://ntfy.sh/$CtlTopic/json?poll=1&since=12h").GetAwaiter().GetResult()
        if ($rawLines) {
            foreach ($line in ($rawLines -split "`r?`n")) {
                if (-not $line.Trim()) { continue }
                try {
                    $ev = $line | ConvertFrom-Json
                    if ($ev.event -eq "message" -and $ev.message) {
                        $msgObj = $ev.message | ConvertFrom-Json
                        if ($msgObj) { $candidates += $msgObj }
                    }
                } catch {}
            }
        }
    } catch {}

    $diskCtl = Read-JsonSafe (Join-Path $ScriptDir "board_control.json")
    if ($diskCtl) { $candidates += $diskCtl }

    $bestCmdTs = [int64]$curState.applied_remote_ts
    $winEntry = $null
    foreach ($c in $candidates) {
        if ($c.classes -and $c.classes.$cCode) {
            $entry = $c.classes.$cCode
            $cts = [int64]$entry.cmd_ts
            if ($cts -gt $bestCmdTs) {
                $bestCmdTs = $cts
                $winEntry = $entry
            }
        }
    }

    if ($winEntry) {
        $curState.pause_until_ms = [int64]$winEntry.pause_until_ms
        $curState.pause_label = [string]$winEntry.pause_label
        $curState.applied_remote_ts = $bestCmdTs
        Write-JsonSafe $StatePath $curState
        $changed = $true
    }
    return $changed
}

$ApiListener = $null
try {
    $ApiListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $LocalApiPort)
    $ApiListener.Start()
} catch { $ApiListener = $null }

function Handle-LocalApiPending {
    if (-not $ApiListener) { return }
    while ($ApiListener.Pending()) {
        $client = $null
        try {
            $client = $ApiListener.AcceptTcpClient()
            $client.ReceiveTimeout = 800
            $client.SendTimeout = 800
            $stream = $client.GetStream()
            $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 8192
            $readLen = $stream.Read($buf, 0, $buf.Length)
            if ($readLen -le 0) { $ms.Dispose(); $client.Close(); continue }
            $ms.Write($buf, 0, $readLen)
            $hdrProbe = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
            $hdrEnd = $hdrProbe.IndexOf("`r`n`r`n")
            if ($hdrEnd -ge 0 -and $hdrProbe -match '(?im)^Content-Length:\s*(\d+)') {
                $needTotal = $hdrEnd + 4 + [int]$Matches[1]
                while ($ms.Length -lt $needTotal) {
                    $r2 = $stream.Read($buf, 0, $buf.Length)
                    if ($r2 -le 0) { break }
                    $ms.Write($buf, 0, $r2)
                }
            }
            $reqRaw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $ms.Dispose()
            $firstLine = ($reqRaw -split "`r`n")[0]
            $parts = $firstLine -split " "
            $method = $parts[0]
            $reqPath = if ($parts.Length -gt 1) { ($parts[1] -split "\?")[0] } else { "/" }

            $respJson = '{"ok":true}'
            if ($method -eq "OPTIONS") {
                $respJson = ""
            } elseif ($reqPath -eq "/status") {
                $cCfg = Read-JsonSafe $CfgPath
                $cSt  = Get-RuntimeState
                $cSt.board_open_ping_ms = Get-NowMs
                Write-JsonSafe $StatePath $cSt
                $cCls = [string]$cCfg.current_blackboard_class
                $savedEp = Get-SavedClassEp $cSt $cCls
                $respJson = ([PSCustomObject]@{
                    ok           = $true
                    clsCode      = $cCls
                    cls          = "${cCls}班"
                    ep           = $savedEp
                    classEp      = $cSt.class_ep
                    recentOld    = $cSt.recent_old
                    vcntMap      = $cSt.vcnt_map
                    uiPrefs      = $cSt.ui_prefs
                    offsetMin    = [int]$cCfg.clock_offset_minutes
                    pauseUntilMs = [int64]$cSt.pause_until_ms
                    pauseLabel   = [string]$cSt.pause_label
                    ver          = (Get-LocalBuildVer)
                } | ConvertTo-Json -Depth 6 -Compress)
            } elseif ($method -eq "POST" -and $reqPath -eq "/action") {
                $idxBody = $reqRaw.IndexOf("`r`n`r`n")
                $bodyStr = if ($idxBody -ge 0) { $reqRaw.Substring($idxBody + 4) } else { "{}" }
                $act = $bodyStr | ConvertFrom-Json
                $cCfg = Read-JsonSafe $CfgPath
                $cSt  = Get-RuntimeState
                $cCls = [string]$cCfg.current_blackboard_class
                $needHb = $false

                if ($act.type -eq "set_pause") {
                    $cSt.pause_until_ms = [int64]$act.pauseUntilMs
                    $cSt.pause_label = [string]$act.pauseLabel
                    Write-JsonSafe $StatePath $cSt
                    $needHb = $true
                } elseif ($act.type -eq "snooze") {
                    $sec = if ($act.sec) { [int]$act.sec } else { 120 }
                    $near = Find-UpcomingSlot $cCfg $cCls -2.0 20.0
                    $cSt.snooze_slot = if ($near) { $near.slotKey } else { "MANUAL_SNOOZE" }
                    $cSt.snooze_until_ms = (Get-NowMs) + ($sec * 1000)
                    $cSt.board_open_ping_ms = 0
                    Write-JsonSafe $StatePath $cSt
                } elseif ($act.type -eq "close_lock") {
                    $near = Find-UpcomingSlot $cCfg $cCls -5.0 25.0
                    if ($near) {
                        $cSt.last_triggered_slot = $near.slotKey
                        $cSt.last_triggered_ms = Get-NowMs
                    }
                    $cSt.snooze_slot = ""
                    $cSt.board_open_ping_ms = 0
                    Write-JsonSafe $StatePath $cSt
                } elseif ($act.type -eq "sync_ep") {
                    if ($act.ep -and ([int]$act.ep -ge 1)) {
                        $epVal = [int]$act.ep
                        $tCls = if ($act.clsCode -in @("10","11")) { [string]$act.clsCode } else { $cCls }
                        $prevClsEp = Get-SavedClassEp $cSt $tCls
                        $cSt.class_ep | Add-Member -NotePropertyName $tCls -NotePropertyValue $epVal -Force
                        if ($tCls -eq $cCls) { $cSt.current_ep = $epVal }
                        Write-JsonSafe $StatePath $cSt
                        if ($epVal -ne $prevClsEp) { $needHb = $true }
                    }
                } elseif ($act.type -eq "sync_board_prefs") {
                    if ($act.clsCode -in @("10","11") -and $null -ne $act.recent) {
                        $cSt.recent_old | Add-Member -NotePropertyName ([string]$act.clsCode) -NotePropertyValue @($act.recent) -Force
                    }
                    if ($act.vcntKey -and $null -ne $act.vcntVal) {
                        $cSt.vcnt_map | Add-Member -NotePropertyName ([string]$act.vcntKey) -NotePropertyValue ([int]$act.vcntVal) -Force
                    }
                    if ($act.uiPrefs) {
                        $cSt.ui_prefs = $act.uiPrefs
                    }
                    Write-JsonSafe $StatePath $cSt
                } elseif ($act.type -eq "update_cfg") {
                    if ($null -ne $act.offsetMin) { $cCfg.clock_offset_minutes = [int]$act.offsetMin }
                    if ($act.clsCode -in @("10","11") -and $act.clsCode -ne $cCfg.current_blackboard_class) {
                        $cCfg.current_blackboard_class = [string]$act.clsCode
                        $hasSt = @(Get-ChildItem -Path ([Environment]::GetFolderPath("Startup")) -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue).Count -gt 0
                        if ($hasSt) { Repair-Shortcuts $cCfg.current_blackboard_class $true }
                        $needHb = $true
                    }
                    Write-JsonSafe $CfgPath $cCfg
                }
                if ($needHb) { Send-BoardHeartbeat $cCfg $cSt }
                $respJson = ([PSCustomObject]@{
                    ok           = $true
                    clsCode      = [string]$cCfg.current_blackboard_class
                    pauseUntilMs = [int64]$cSt.pause_until_ms
                    pauseLabel   = [string]$cSt.pause_label
                } | ConvertTo-Json -Compress)
            }

            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
            $hdr = "HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`nConnection: close`r`nContent-Length: $($bodyBytes.Length)`r`n`r`n"
            $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($hdr)
            $stream.Write($hdrBytes, 0, $hdrBytes.Length)
            if ($bodyBytes.Length -gt 0) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
            $stream.Flush()
        } catch {} finally {
            if ($client) { try { $client.Close() } catch {} }
        }
    }
}

$UdpPort = 18766
$UdpListener = $null
try { $UdpListener = New-Object System.Net.Sockets.UdpClient($UdpPort) } catch { $UdpListener = $null }

function Run-InProcessCloudSync([string]$LanUrl = "") {
    if ($NoCloud -and (-not $LanUrl)) { return "" }
    if (-not (Get-Command Invoke-GeoBoardSync -ErrorAction SilentlyContinue)) { return "" }
    try {
        $resStr = Invoke-GeoBoardSync -SyncTargetDir $ScriptDir -SyncLanBaseUrl $LanUrl -IsInteractive $false -IsSilent $true
        if ($resStr -like "UPDATED_DAEMON*") {
            if ($UdpListener) { try { $UdpListener.Close() } catch {} }
            if ($ApiListener) { try { $ApiListener.Stop() } catch {} }
            if ($GlobalMutex) { try { $GlobalMutex.ReleaseMutex(); $GlobalMutex.Dispose() } catch {} }
            if (Test-Path $VbsPath) {
                Start-Process -FilePath "wscript.exe" -ArgumentList "//B //NoLogo `"$VbsPath`" HotReload" -WindowStyle Hidden
            } else {
                Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Daemon -HotReload" -WindowStyle Hidden
            }
            exit 0
        }
        return $resStr
    } catch { return "" }
}

$lastCloudSync = (Get-Date).AddSeconds(-172)
$lastRemoteCtl = (Get-Date).AddSeconds(-55)
$lastLanVer    = ""

while ($true) {
    try {
        [IdleWin32]::KeepSystemAwake()
        $cfg = Read-JsonSafe $CfgPath
        $st  = Get-RuntimeState
        $nowMs = Get-NowMs
        $cls = [string]$cfg.current_blackboard_class
        $offset = [int]$cfg.clock_offset_minutes
        $leadMin = if ($cfg.trigger_before_minutes) { [double]$cfg.trigger_before_minutes } else { 5.0 }
        $reqIdle = if ($cfg.idle_required_seconds) { [double]$cfg.idle_required_seconds } else { 90.0 }

        $isPausedMode = ([int64]$st.pause_until_ms -gt $nowMs)
        $isBoardAlreadyOpen = (($nowMs - [int64]$st.board_open_ping_ms) -lt 8000)

        if (-not $isPausedMode -and -not $isBoardAlreadyOpen) {
            $now = (Get-Date).AddMinutes($offset)
            $wp  = Get-WeekParity $now $cfg
            $dow = [int]$now.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
            $daySlots = $cfg.schedules.$cls."$dow"

            if ($daySlots) {
                foreach ($s in $daySlots) {
                    if ($s.week -ne "all" -and $s.week -ne $wp) { continue }
                    $slotTimeStr = [string]$s.time
                    $targetTime  = [datetime]::ParseExact($slotTimeStr, "HH:mm", $null)
                    $minsToClass = ($targetTime - $now).TotalMinutes
                    $slotKey     = "$($now.ToString('yyyyMMdd'))_${cls}_$slotTimeStr"

                    if ($st.snooze_slot -eq $slotKey -and $nowMs -ge [int64]$st.snooze_until_ms) {
                        $st.snooze_slot = ""
                        if ($minsToClass -ge -1.5 -and $minsToClass -le 15.0) {
                            $st.last_triggered_slot = $slotKey
                            $st.last_triggered_ms = $nowMs
                            Write-JsonSafe $StatePath $st
                            Open-BoardApp $cls $slotTimeStr $offset
                            break
                        } else {
                            Write-JsonSafe $StatePath $st
                        }
                    }

                    if ($st.last_triggered_slot -eq $slotKey) { continue }

                    # 严禁正式上课后自动弹窗！正课仅限课前 [0.5 ~ leadMin] 分钟空闲时弹出
                    $minBound = if ($slotTimeStr -eq "07:00") { -2.0 } else { 0.5 }
                    $maxBound = if ($slotTimeStr -eq "07:00") { [math]::Max($leadMin, 8.0) } else { $leadMin }

                    if ($minsToClass -le $maxBound -and $minsToClass -ge $minBound) {
                        $idleSec = [IdleWin32]::GetIdleSeconds()
                        $fg = Get-ForegroundAppName
                        $busyApps = @("POWERPNT", "wpp", "wps", "et", "EasiNote", "HiteBoard", "AcroRd32", "FoxitReader", "PotPlayerMini64", "vlc")
                        $isFullscreen = [IdleWin32]::IsForegroundFullscreen()
                        $needIdle = if (($fg -in $busyApps) -or $isFullscreen) { [math]::Max($reqIdle, 120.0) } else { $reqIdle }
                        if ($slotTimeStr -eq "07:00") { $needIdle = 25.0 }

                        if ($idleSec -ge $needIdle) {
                            $st.last_triggered_slot = $slotKey
                            $st.last_triggered_ms = $nowMs
                            Write-JsonSafe $StatePath $st
                            Open-BoardApp $cls $slotTimeStr $offset
                            break
                        }
                    }
                }
            }
        }

        if (((Get-Date) - $lastRemoteCtl).TotalSeconds -ge 60) {
            $lastRemoteCtl = Get-Date
            if (Sync-RemoteControl $cfg $st) { Send-BoardHeartbeat $cfg $st }
        }

        if (((Get-Date) - $lastCloudSync).TotalSeconds -ge 180) {
            $lastCloudSync = Get-Date
            Run-InProcessCloudSync "" | Out-Null
            $stAfter = Get-RuntimeState
            Sync-RemoteControl $cfg $stAfter | Out-Null
            Send-BoardHeartbeat $cfg $stAfter
        }
    } catch {}

    for ($i = 0; $i -lt 32; $i++) {
        Handle-LocalApiPending
        if ($UdpListener -and $UdpListener.Available -gt 0) {
            try {
                $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $pkt = $UdpListener.Receive([ref]$remoteEp)
                $msg = [System.Text.Encoding]::UTF8.GetString($pkt)
                if ($msg -match '^GEO_SYNC\|([^|]*)\|([^|]*)\|(\d+)$') {
                    $lanUrl = $Matches[1]
                    $targetVer = $Matches[2]
                    $ackPort = [int]$Matches[3]
                    $syncRes = if ($targetVer -and $targetVer -eq $lastLanVer) { "UP_TO_DATE|$targetVer" } else {
                        $r = Run-InProcessCloudSync $lanUrl
                        if ($r) { $lastLanVer = $targetVer }
                        $r
                    }
                    $ackMsg = "GEO_ACK|${cls}班|$env:COMPUTERNAME|$syncRes"
                    $ackBytes = [System.Text.Encoding]::UTF8.GetBytes($ackMsg)
                    $UdpListener.Send($ackBytes, $ackBytes.Length, $remoteEp.Address.ToString(), $ackPort) | Out-Null
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 250
    }
}
