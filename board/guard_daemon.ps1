param(
    [string]$Mode = "Daemon" # Daemon | LaunchNow | CheckOnce | Install | Uninstall
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$HtmlPath  = Join-Path $ScriptDir "地理课前通关大屏.html"
$CfgPath   = Join-Path $ScriptDir "schedule_config.json"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class IdleWin32 {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static double GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        uint diff = unchecked((uint)Environment.TickCount - lii.dwTime);
        return diff / 1000.0;
    }
}
"@

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
        if ($pidOut -gt 0) {
            return (Get-Process -Id $pidOut -ErrorAction SilentlyContinue).ProcessName
        }
    } catch {}
    return ""
}

function Get-WeekParity([datetime]$dt, $cfg) {
    try {
        $curMon = $dt.Date.AddDays(-(([int]$dt.DayOfWeek + 6) % 7))
        $ancMon = [datetime]::ParseExact([string]$cfg.anchor_monday, "yyyy-MM-dd", $null).Date
        $wDiff  = [math]::Round(($curMon - $ancMon).TotalDays / 7.0)
        $isSame = ([math]::Abs($wDiff) % 2 -eq 0)
        if ($cfg.anchor_week_parity -eq "odd") {
            return $(if ($isSame) { "odd" } else { "even" })
        } else {
            return $(if ($isSame) { "even" } else { "odd" })
        }
    } catch { return "odd" }
}

function Open-BoardApp([string]$ClsCode, [string]$TargetTime = "", [int]$OffsetMin = 0) {
    $exe = Get-BrowserExe
    $qs = "?class=$ClsCode&stage=prep&offset=$OffsetMin"
    if ($TargetTime -ne "") { $qs += "&target=$TargetTime" }
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri + $qs
    $profDir = Join-Path $ScriptDir ".board_kiosk_profile"
    if ($exe -like "*msedge.exe*") {
        Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$profDir`" --no-first-run --no-default-browser-check --kiosk `"$uri`" --edge-kiosk-type=fullscreen"
    } else {
        Start-Process -FilePath $exe -ArgumentList "--user-data-dir=`"$profDir`" --no-first-run --no-default-browser-check --kiosk `"$uri`""
    }
}

$cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cls = [string]$cfg.current_blackboard_class

if ($Mode -eq "LaunchNow") {
    $offNow = [int]$cfg.clock_offset_minutes
    $nowCal = (Get-Date).AddMinutes($offNow)
    $wpNow  = Get-WeekParity $nowCal $cfg
    $dowNow = [int]$nowCal.DayOfWeek; if ($dowNow -eq 0) { $dowNow = 7 }
    $nearTarget = ""
    $slotsNow = $cfg.schedules.$cls."$dowNow"
    if ($slotsNow) {
        foreach ($s in $slotsNow) {
            if ($s.week -ne "all" -and $s.week -ne $wpNow) { continue }
            $tObj = [datetime]::ParseExact([string]$s.time, "HH:mm", $null)
            $diffM = ($tObj - $nowCal).TotalMinutes
            if ($diffM -ge -1.0 -and $diffM -le 15.0) { $nearTarget = [string]$s.time; break }
        }
    }
    Open-BoardApp $cls $nearTarget $offNow
    exit 0
}

if ($Mode -eq "Uninstall") {
    # 1. 立即终止所有后台运行的 guard_daemon.ps1 守护进程
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -match 'guard_daemon\.ps1"\s+-Mode\s+Daemon\s*$'
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }

    # 2. 移除开机自启文件夹中的快捷方式
    $StartupDir = [Environment]::GetFolderPath("Startup")
    Get-ChildItem -Path $StartupDir -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  [已停止] 已彻底关闭后台自动弹窗（清理守护进程: $killed 个），并移除开机自启！" -ForegroundColor Green
    Write-Host "  * 桌面的手动打开图标仍保留，您平时仍可手动双击使用；" -ForegroundColor Cyan
    Write-Host "  * 如需彻底卸载干净：直接删掉本文件夹及桌面快捷图标即可，无任何系统残留；" -ForegroundColor Cyan
    Write-Host "  * 如需恢复课前自动弹窗：再次双击【一键部署开机值守到本班黑板.bat】即可。" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    exit 0
}

if ($Mode -eq "Install") {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  青云实验中学 · 高三地理课前通关系统 一体机部署向导" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    $inCls = Read-Host "1. 请输入本教室班级（填 10 或 11，直接回车默认 [$cls]）"
    if ($inCls -in @("10","11")) { $cfg.current_blackboard_class = $inCls; $cls = $inCls }

    $inParity = Read-Host "2. 本周在学校校历中是单周还是双周？（填 1=单周，2=双周，此后每周一自动翻转！）"
    $today = Get-Date
    $curMonStr = $today.Date.AddDays(-(([int]$today.DayOfWeek + 6) % 7)).ToString("yyyy-MM-dd")
    $cfg.anchor_monday = $curMonStr
    if ($inParity -eq "2") { $cfg.anchor_week_parity = "even" } else { $cfg.anchor_week_parity = "odd" }

    $inOff = Read-Host "3. 一体机时间校准：若一体机比学校铃声快2分钟填 -2，慢2分钟填 2（准点直接回车填 0）"
    if ($inOff -match "^-?\d+$") { $cfg.clock_offset_minutes = [int]$inOff }

    $cfg | ConvertTo-Json -Depth 8 | Set-Content $CfgPath -Encoding UTF8

    $WshShell = New-Object -ComObject WScript.Shell
    $DesktopDir = [Environment]::GetFolderPath("Desktop")
    $Shortcut1 = $WshShell.CreateShortcut((Join-Path $DesktopDir "地理课前通关(${cls}班).lnk"))
    $Shortcut1.TargetPath = "powershell.exe"
    $Shortcut1.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode LaunchNow"
    $Shortcut1.WorkingDirectory = $ScriptDir
    $Shortcut1.Save()

    $SyncBatPath = Join-Path $ScriptDir "一键同步最新题库与功能.bat"
    if (Test-Path $SyncBatPath) {
        $ShortcutSync = $WshShell.CreateShortcut((Join-Path $DesktopDir "地理课前通关·一键同步更新.lnk"))
        $ShortcutSync.TargetPath = $SyncBatPath
        $ShortcutSync.WorkingDirectory = $ScriptDir
        $ShortcutSync.Save()
    }

    $StartupDir = [Environment]::GetFolderPath("Startup")
    $Shortcut2 = $WshShell.CreateShortcut((Join-Path $StartupDir "GeoPreClassGuard_${cls}.lnk"))
    $Shortcut2.TargetPath = "powershell.exe"
    $Shortcut2.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Daemon"
    $Shortcut2.WorkingDirectory = $ScriptDir
    $Shortcut2.Save()

    # 终止旧守护进程防止重复启动，再启动新守护进程
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -match 'guard_daemon\.ps1"\s+-Mode\s+Daemon\s*$'
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Daemon"
    $pLabel = if ($cfg.anchor_week_parity -eq "odd") { "单周" } else { "双周" }
    Write-Host ""
    Write-Host "✅ 部署成功！已绑定【高三 ${cls}班】（本周设为：$pLabel，下周一自动轮换）。" -ForegroundColor Green
    Write-Host "✅ 桌面已生成【地理课前通关(${cls}班)】与【一键同步更新】图标，开机防拖堂值守与自动热更新已生效！" -ForegroundColor Green
    Start-Sleep -Seconds 3
    exit 0
}

if ($Mode -eq "CheckOnce") {
    $now = (Get-Date).AddMinutes([int]$cfg.clock_offset_minutes)
    $wp = Get-WeekParity $now $cfg
    $idleSec = [IdleWin32]::GetIdleSeconds()
    $fg = Get-ForegroundAppName
    $activeList = @()
    foreach ($d in @("1","2","3","4","5","6","7")) {
        $slots = $cfg.schedules.$cls.$d
        if ($slots) {
            foreach ($s in $slots) {
                if ($s.week -eq "all" -or $s.week -eq $wp) {
                    $activeList += "$($s.label)($($s.time))"
                }
            }
        }
    }
    Write-Output ("SCHEDULE_OK | Class=${cls}班 | Parity=$wp | Idle=$([math]::Round($idleSec,1))s | ActiveSlots=" + ($activeList -join ", "))
    exit 0
}

# 后台常驻防拖堂值守 + 云端/局域网静默热更新循环
$SyncScript = Join-Path $ScriptDir "sync_updater.ps1"
$UdpPort = 18766
$UdpListener = $null
try {
    $UdpListener = New-Object System.Net.Sockets.UdpClient
    $UdpListener.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $UdpListener.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $UdpPort)))
} catch { $UdpListener = $null }

function Invoke-SilentAutoSync([string]$LanUrl = "") {
    if (-not (Test-Path $SyncScript)) { return "" }
    try {
        $res = if ($LanUrl) {
            & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $SyncScript -LanBaseUrl $LanUrl -Silent 2>$null
        } else {
            & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $SyncScript -Silent 2>$null
        }
        $resStr = ($res | Select-Object -Last 1) -as [string]
        if ($resStr -like "UPDATED_DAEMON*") {
            if ($UdpListener) { try { $UdpListener.Close() } catch {} }
            Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Daemon"
            exit 0
        }
        return $resStr
    } catch { return "" }
}

$triggeredKey = ""
$lastCloudSync = (Get-Date).AddSeconds(-170) # 启动约10秒后自动执行首次云端检查，此后每3分钟静默检查一次
$lastLanVer = ""

while ($true) {
    try {
        $cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cls = [string]$cfg.current_blackboard_class
        $offset = [int]$cfg.clock_offset_minutes
        $leadMin = [int]$cfg.trigger_before_minutes
        $reqIdle = [int]$cfg.idle_required_seconds

        $now = (Get-Date).AddMinutes($offset)
        $wp = Get-WeekParity $now $cfg
        $dow = [int]$now.DayOfWeek
        if ($dow -eq 0) { $dow = 7 }
        $daySlots = $cfg.schedules.$cls."$dow"

        if ($daySlots) {
            foreach ($s in $daySlots) {
                if ($s.week -ne "all" -and $s.week -ne $wp) { continue }
                $slotTimeStr = [string]$s.time
                $targetTime = [datetime]::ParseExact($slotTimeStr, "HH:mm", $null)
                $minsToClass = ($targetTime - $now).TotalMinutes
                $slotKey = "$($now.ToString('yyyyMMdd'))_${cls}_$slotTimeStr"

                # 早自习07:00允许开机稍晚(06:55~07:04)补弹；其余时段严格在课前5分钟~铃响前0.5分钟空闲弹出
                $minBound = if ($slotTimeStr -eq "07:00") { -4.0 } else { 0.5 }

                if ($minsToClass -le $leadMin -and $minsToClass -ge $minBound -and $triggeredKey -ne $slotKey) {
                    $idleSec = [IdleWin32]::GetIdleSeconds()
                    $fg = Get-ForegroundAppName
                    $teachingApps = @("POWERPNT", "wpp", "EasiNote", "HiteBoard")
                    $needIdle = if ($fg -in $teachingApps) { [math]::Max($reqIdle, 120) } else { $reqIdle }
                    # 早自习07:00刚开机无需漫长等待空闲，20秒无触控即弹出
                    if ($slotTimeStr -eq "07:00") { $needIdle = 20 }

                    if ($idleSec -ge $needIdle) {
                        Open-BoardApp $cls $slotTimeStr $offset
                        $triggeredKey = $slotKey
                    }
                }
            }
        }

        # 每隔 3 分钟静默检查一次云端增量更新
        if (((Get-Date) - $lastCloudSync).TotalSeconds -ge 180) {
            $lastCloudSync = Get-Date
            Invoke-SilentAutoSync "" | Out-Null
        }
    } catch {}

    # 10秒拆分为 10×1秒，实时监听同一校园网教师本机发来的秒级广播更新指令
    for ($i = 0; $i -lt 10; $i++) {
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
                        $r = Invoke-SilentAutoSync $lanUrl
                        if ($r) { $lastLanVer = $targetVer }
                        $r
                    }
                    $ackMsg = "GEO_ACK|${cls}班|$env:COMPUTERNAME|$syncRes"
                    $ackBytes = [System.Text.Encoding]::UTF8.GetBytes($ackMsg)
                    $UdpListener.Send($ackBytes, $ackBytes.Length, $remoteEp.Address.ToString(), $ackPort) | Out-Null
                }
            } catch {}
        }
        Start-Sleep -Seconds 1
    }
}
