param(
    [string]$Mode = "Daemon", # Daemon | LaunchNow | CheckOnce | Install | Uninstall
    [switch]$HotReload,
    [switch]$NoCloud,
    [string]$PresetSecret = "",
    [switch]$CliMode
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
using System.Text;
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
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
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
    public static string GetForegroundClassName() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return "";
        StringBuilder sb = new StringBuilder(128);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }
    public static bool IsForegroundFullscreen() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        StringBuilder sb = new StringBuilder(128);
        GetClassName(hwnd, sb, sb.Capacity);
        string cls = sb.ToString();
        if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd") return false;
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

function Get-SlotDateTime([datetime]$BaseNow, [string]$HmStr) {
    $ts = [TimeSpan]::ParseExact($HmStr, "hh\:mm", $null)
    return $BaseNow.Date.Add($ts)
}

function Get-TodayActiveSlotTimes($cfg, [string]$ClsCode) {
    $res = @()
    if (-not $cfg) { return $res }
    $offNow = [int]$cfg.clock_offset_minutes
    $nowCal = (Get-Date).AddMinutes($offNow)
    $wpNow  = Get-WeekParity $nowCal $cfg
    $dowNow = [int]$nowCal.DayOfWeek; if ($dowNow -eq 0) { $dowNow = 7 }
    $slotsNow = $cfg.schedules.$ClsCode."$dowNow"
    if ($slotsNow) {
        foreach ($s in $slotsNow) {
            if ($s.week -ne "all" -and $s.week -ne $wpNow) { continue }
            $res += [string]$s.time
        }
    }
    return $res
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
            $tObj = Get-SlotDateTime $nowCal ([string]$s.time)
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

function Get-BoardKioskProcesses {
    try {
        $profMark = ".board_kiosk_profile"
        return @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe' OR Name = 'chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and ($_.CommandLine -like "*$profMark*")
        })
    } catch { return @() }
}

function Close-BoardKioskWindows {
    $procs = Get-BoardKioskProcesses
    $closed = 0
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $closed++
        } catch {}
    }
    return ($closed -gt 0)
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

function Open-TouchKeyboard {
    try {
        $tabTip = "C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe"
        if (Test-Path $tabTip) {
            Start-Process -FilePath $tabTip -ErrorAction SilentlyContinue
            return $true
        }
    } catch {}
    try {
        Start-Process -FilePath "osk.exe" -ErrorAction SilentlyContinue
        return $true
    } catch {}
    return $false
}

function Show-TouchInstallWizard($curCfg, [string]$DefaultCls, [string]$PrefilledSecret) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = "高三地理课前通关 · 无键盘纯触控部署向导"
        $form.Size = New-Object System.Drawing.Size(620, 560)
        $form.StartPosition = "CenterScreen"
        $form.TopMost = $true
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false
        $form.BackColor = [System.Drawing.Color]::FromArgb(11, 19, 36)
        $form.ForeColor = [System.Drawing.Color]::White

        $fTitle = New-Object System.Drawing.Font("Microsoft YaHei", 15, [System.Drawing.FontStyle]::Bold)
        $fLab   = New-Object System.Drawing.Font("Microsoft YaHei", 11, [System.Drawing.FontStyle]::Bold)
        $fBtn   = New-Object System.Drawing.Font("Microsoft YaHei", 12, [System.Drawing.FontStyle]::Bold)

        $stateObj = [PSCustomObject]@{
            Confirmed = $false
            Cls       = if ($DefaultCls -in @("10","11")) { $DefaultCls } else { "10" }
            Parity    = if ($curCfg.anchor_week_parity -eq "even") { "even" } else { "odd" }
            Offset    = [int]$curCfg.clock_offset_minutes
            Secret    = $PrefilledSecret
        }

        $lblHead = New-Object System.Windows.Forms.Label
        $lblHead.Text = "🏫 青云实验中学 · 黑板纯触控一键部署（无需键盘）"
        $lblHead.Font = $fTitle
        $lblHead.ForeColor = [System.Drawing.Color]::FromArgb(250, 204, 21)
        $lblHead.Location = New-Object System.Drawing.Point(20, 16)
        $lblHead.Size = New-Object System.Drawing.Size(570, 34)
        $form.Controls.Add($lblHead)

        # 1. Class buttons
        $l1 = New-Object System.Windows.Forms.Label
        $l1.Text = "1. 请点选本教室绑定班级："
        $l1.Font = $fLab; $l1.Location = New-Object System.Drawing.Point(22, 64); $l1.Size = New-Object System.Drawing.Size(550, 24)
        $form.Controls.Add($l1)

        $btnC10 = New-Object System.Windows.Forms.Button
        $btnC10.Text = "📍 高三 10班"; $btnC10.Font = $fBtn; $btnC10.FlatStyle = "Flat"
        $btnC10.Location = New-Object System.Drawing.Point(22, 92); $btnC10.Size = New-Object System.Drawing.Size(270, 52)
        $btnC11 = New-Object System.Windows.Forms.Button
        $btnC11.Text = "📍 高三 11班"; $btnC11.Font = $fBtn; $btnC11.FlatStyle = "Flat"
        $btnC11.Location = New-Object System.Drawing.Point(310, 92); $btnC11.Size = New-Object System.Drawing.Size(270, 52)
        $form.Controls.AddRange(@($btnC10, $btnC11))

        # 2. Parity buttons
        $l2 = New-Object System.Windows.Forms.Label
        $l2.Text = "2. 请点选本周校历单双周（此后每周一自动翻转）："
        $l2.Font = $fLab; $l2.Location = New-Object System.Drawing.Point(22, 160); $l2.Size = New-Object System.Drawing.Size(550, 24)
        $form.Controls.Add($l2)

        $btnOdd = New-Object System.Windows.Forms.Button
        $btnOdd.Text = "📅 本周是 单周"; $btnOdd.Font = $fBtn; $btnOdd.FlatStyle = "Flat"
        $btnOdd.Location = New-Object System.Drawing.Point(22, 188); $btnOdd.Size = New-Object System.Drawing.Size(270, 52)
        $btnEven = New-Object System.Windows.Forms.Button
        $btnEven.Text = "📅 本周是 双周"; $btnEven.Font = $fBtn; $btnEven.FlatStyle = "Flat"
        $btnEven.Location = New-Object System.Drawing.Point(310, 188); $btnEven.Size = New-Object System.Drawing.Size(270, 52)
        $form.Controls.AddRange(@($btnOdd, $btnEven))

        # 3. Clock offset stepper
        $l3 = New-Object System.Windows.Forms.Label
        $l3.Text = "3. 铃声校准（黑板比铃声快填负、慢填正）："
        $l3.Font = $fLab; $l3.Location = New-Object System.Drawing.Point(22, 256); $l3.Size = New-Object System.Drawing.Size(550, 24)
        $form.Controls.Add($l3)

        $lblOffVal = New-Object System.Windows.Forms.Label
        $lblOffVal.Font = $fTitle; $lblOffVal.TextAlign = "MiddleCenter"
        $lblOffVal.ForeColor = [System.Drawing.Color]::FromArgb(110, 231, 183)
        $lblOffVal.Location = New-Object System.Drawing.Point(215, 286); $lblOffVal.Size = New-Object System.Drawing.Size(170, 48)
        $form.Controls.Add($lblOffVal)

        $mkStepBtn = {
            param($txt, $x, $delta, $isReset)
            $b = New-Object System.Windows.Forms.Button
            $b.Text = $txt; $b.Font = $fBtn; $b.FlatStyle = "Flat"
            $b.BackColor = [System.Drawing.Color]::FromArgb(25, 42, 74); $b.ForeColor = [System.Drawing.Color]::White
            $b.Location = New-Object System.Drawing.Point($x, 286); $b.Size = New-Object System.Drawing.Size(86, 48)
            $b.Add_Click({
                if ($isReset) { $stateObj.Offset = 0 } else { $stateObj.Offset += $delta }
                $lblOffVal.Text = "$($stateObj.Offset) 分钟"
            }.GetNewClosure())
            return $b
        }
        $form.Controls.Add((& $mkStepBtn "-5分" 22 -5 $false))
        $form.Controls.Add((& $mkStepBtn "-1分" 116 -1 $false))
        $form.Controls.Add((& $mkStepBtn "+1分" 396 1 $false))
        $form.Controls.Add((& $mkStepBtn "+5分" 490 5 $false))

        # 4. Remote control secret status (auto-loaded from USB if present)
        $l4 = New-Object System.Windows.Forms.Label
        $l4.Text = "4. 手机远控防伪签名口令（插U盘含口令文件时自动填入，免手打）："
        $l4.Font = $fLab; $l4.Location = New-Object System.Drawing.Point(22, 350); $l4.Size = New-Object System.Drawing.Size(560, 24)
        $form.Controls.Add($l4)

        $tbSec = New-Object System.Windows.Forms.TextBox
        $tbSec.Font = $fLab; $tbSec.UseSystemPasswordChar = $true
        $tbSec.BackColor = [System.Drawing.Color]::FromArgb(8, 16, 32); $tbSec.ForeColor = [System.Drawing.Color]::White
        $tbSec.Location = New-Object System.Drawing.Point(22, 380); $tbSec.Size = New-Object System.Drawing.Size(410, 34)
        if ($PrefilledSecret) { $tbSec.Text = $PrefilledSecret }
        $form.Controls.Add($tbSec)

        $btnOsk = New-Object System.Windows.Forms.Button
        $btnOsk.Text = "⌨️ 屏幕键盘"; $btnOsk.Font = $fLab; $btnOsk.FlatStyle = "Flat"
        $btnOsk.BackColor = [System.Drawing.Color]::FromArgb(30, 58, 138); $btnOsk.ForeColor = [System.Drawing.Color]::White
        $btnOsk.Location = New-Object System.Drawing.Point(442, 378); $btnOsk.Size = New-Object System.Drawing.Size(138, 36)
        $btnOsk.Add_Click({ Open-TouchKeyboard | Out-Null; $tbSec.Focus() })
        $form.Controls.Add($btnOsk)

        $lblSecTip = New-Object System.Windows.Forms.Label
        $lblSecTip.Font = New-Object System.Drawing.Font("Microsoft YaHei", 9.5)
        $lblSecTip.Location = New-Object System.Drawing.Point(22, 418); $lblSecTip.Size = New-Object System.Drawing.Size(560, 22)
        if ($PrefilledSecret) {
            $lblSecTip.ForeColor = [System.Drawing.Color]::FromArgb(110, 231, 183)
            $lblSecTip.Text = "🟢 已自动读取 U 盘预置远控口令，直接点下方绿色按钮完成部署！"
        } elseif ($curCfg.PSObject.Properties['remote_control_secret'] -and ([string]$curCfg.remote_control_secret).Trim()) {
            $lblSecTip.ForeColor = [System.Drawing.Color]::FromArgb(147, 197, 253)
            $lblSecTip.Text = "ℹ️ 本机已保存过远控口令（留空将保持原口令不变）。"
        } else {
            $lblSecTip.ForeColor = [System.Drawing.Color]::FromArgb(253, 230, 138)
            $lblSecTip.Text = "💡 无键盘可先留空直接部署，稍后插U盘或在大屏【设置】内置软键盘中录入。"
        }
        $form.Controls.Add($lblSecTip)

        $syncStyles = {
            $cActive = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $cIdle   = [System.Drawing.Color]::FromArgb(19, 32, 59)
            $btnC10.BackColor  = if ($stateObj.Cls -eq "10") { $cActive } else { $cIdle }
            $btnC11.BackColor  = if ($stateObj.Cls -eq "11") { $cActive } else { $cIdle }
            $btnOdd.BackColor  = if ($stateObj.Parity -eq "odd") { $cActive } else { $cIdle }
            $btnEven.BackColor = if ($stateObj.Parity -eq "even") { $cActive } else { $cIdle }
            $lblOffVal.Text    = "$($stateObj.Offset) 分钟"
        }
        $btnC10.Add_Click({ $stateObj.Cls = "10"; & $syncStyles })
        $btnC11.Add_Click({ $stateObj.Cls = "11"; & $syncStyles })
        $btnOdd.Add_Click({ $stateObj.Parity = "odd"; & $syncStyles })
        $btnEven.Add_Click({ $stateObj.Parity = "even"; & $syncStyles })
        & $syncStyles

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "✅ 确认部署并启动零黑框静默值守"; $btnOk.Font = $fTitle; $btnOk.FlatStyle = "Flat"
        $btnOk.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129); $btnOk.ForeColor = [System.Drawing.Color]::FromArgb(5, 46, 22)
        $btnOk.Location = New-Object System.Drawing.Point(22, 452); $btnOk.Size = New-Object System.Drawing.Size(558, 56)
        $btnOk.Add_Click({
            $stateObj.Secret = $tbSec.Text.Trim()
            $stateObj.Confirmed = $true
            $form.Close()
        })
        $form.Controls.Add($btnOk)

        $null = $form.ShowDialog()
        $form.Dispose()
        return $stateObj
    } catch {
        return $null
    }
}

if ($Mode -eq "Install") {
    $autoSecret = $PresetSecret.Trim()
    if (-not $autoSecret) {
        foreach ($cand in @((Join-Path $ScriptDir "local_ctl_secret.txt"), (Join-Path (Split-Path -Parent $ScriptDir) "local_ctl_secret.txt"))) {
            if (Test-Path $cand) {
                $autoSecret = ([System.IO.File]::ReadAllText($cand, [System.Text.Encoding]::UTF8)).Trim()
                if ($autoSecret) { break }
            }
        }
    }

    $wizRes = if (-not $CliMode) { Show-TouchInstallWizard $cfg $cls $autoSecret } else { $null }
    if ($wizRes) {
        if (-not $wizRes.Confirmed) {
            Write-Host "已取消部署。" -ForegroundColor Yellow
            exit 0
        }
        $cls = [string]$wizRes.Cls
        $cfg.current_blackboard_class = $cls
        $today = Get-Date
        $cfg.anchor_monday = $today.Date.AddDays(-(([int]$today.DayOfWeek + 6) % 7)).ToString("yyyy-MM-dd")
        $cfg.anchor_week_parity = [string]$wizRes.Parity
        $cfg.clock_offset_minutes = [int]$wizRes.Offset
        if ($wizRes.Secret -ne "") {
            $cfg | Add-Member -NotePropertyName "remote_control_secret" -NotePropertyValue ([string]$wizRes.Secret) -Force
        }
    } else {
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

        if ($autoSecret) {
            $cfg | Add-Member -NotePropertyName "remote_control_secret" -NotePropertyValue $autoSecret -Force
            Write-Host "4. 已自动注入 U 盘预置远控防伪签名口令！" -ForegroundColor Green
        } else {
            $curSecHint = if ($cfg.PSObject.Properties['remote_control_secret'] -and [string]$cfg.remote_control_secret) { "已配置" } else { "未配置" }
            $inCtlSec = (Read-Host "4. 手机远控防伪签名口令（与教师端一致，直接回车保持[$curSecHint]）").Trim()
            if ($inCtlSec -ne "") {
                $cfg | Add-Member -NotePropertyName "remote_control_secret" -NotePropertyValue $inCtlSec -Force
            }
        }
    }

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
    $secTag = if ($cfg.PSObject.Properties['remote_control_secret'] -and ([string]$cfg.remote_control_secret).Trim()) { "SIGNED_HMAC" } else { "REPO_ONLY_NO_NTFY" }
    Write-Output ("SCHEDULE_OK | Class=${cls}班 | Status=$pauseTxt | RemoteCtl=$secTag | Parity=$wp | Idle=$([math]::Round($idleSec,1))s | ActiveSlots=" + ($activeList -join ", "))
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

$MaxPauseSpanMs = [int64]31 * 86400 * 1000
$script:NeedImmediateHb = $false
$script:BgHbJob   = $null
$script:BgCtlJob  = $null
$script:BgSyncJob = $null
$script:BgLanJob  = $null

function Get-LocalBuildVer {
    $mf = Read-JsonSafe (Join-Path $ScriptDir "board_manifest.json")
    if ($mf -and $mf.build_version) { return [string]$mf.build_version }
    return "20261118"
}

function Get-CanonicalControlString($ctlObj) {
    $upd = if ($ctlObj -and $ctlObj.PSObject.Properties['updated_at'] -and $ctlObj.updated_at) { [int64]$ctlObj.updated_at } else { [int64]0 }
    $parts = @()
    foreach ($k in @("10", "11")) {
        $e = if ($ctlObj -and $ctlObj.PSObject.Properties['classes'] -and $ctlObj.classes -and $ctlObj.classes.PSObject.Properties[$k]) { $ctlObj.classes.$k } else { $null }
        $cts = if ($e -and $e.PSObject.Properties['cmd_ts'] -and $e.cmd_ts) { [int64]$e.cmd_ts } else { [int64]0 }
        $pms = if ($e -and $e.PSObject.Properties['pause_until_ms'] -and $e.pause_until_ms) { [int64]$e.pause_until_ms } else { [int64]0 }
        $plb = if ($e -and $e.PSObject.Properties['pause_label'] -and $e.pause_label) { [string]$e.pause_label } else { "" }
        $parts += "${k}:${cts}:${pms}:${plb}"
    }
    return "v1|${upd}|$($parts[0])|$($parts[1])"
}

function Get-HmacSha256Hex([string]$Secret, [string]$Message) {
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $msgBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (,$keyBytes)
    try {
        $hash = $hmac.ComputeHash($msgBytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hmac.Dispose()
    }
}

function Test-ControlObjectAllowed($ctlObj, [string]$Source, $curCfg) {
    if (-not $ctlObj -or -not $ctlObj.PSObject.Properties['classes'] -or -not $ctlObj.classes) { return $false }
    $secret = ""
    if ($curCfg -and $curCfg.PSObject.Properties['remote_control_secret'] -and $curCfg.remote_control_secret) {
        $secret = ([string]$curCfg.remote_control_secret).Trim()
    }
    $allowUnsignedNtfy = $false
    if ($curCfg -and $curCfg.PSObject.Properties['allow_unsigned_ntfy']) {
        $allowUnsignedNtfy = [bool]$curCfg.allow_unsigned_ntfy
    }
    if ($secret -ne "") {
        $sig = if ($ctlObj.PSObject.Properties['sig'] -and $ctlObj.sig) { ([string]$ctlObj.sig).Trim().ToLowerInvariant() } else { "" }
        if ($sig.Length -ne 64) { return $false }
        $expected = Get-HmacSha256Hex $secret (Get-CanonicalControlString $ctlObj)
        $diff = 0
        for ($idx = 0; $idx -lt 64; $idx++) { $diff = $diff -bor ([int]$sig[$idx] -bxor [int]$expected[$idx]) }
        return ($diff -eq 0)
    }
    if ($Source -eq "ntfy") { return $allowUnsignedNtfy }
    return ($Source -in @("repo", "disk"))
}

function Apply-RemoteControlCandidates($curCfg, $curState, [array]$TaggedCandidates) {
    $cCode = [string]$curCfg.current_blackboard_class
    $bestCmdTs = [int64]$curState.applied_remote_ts
    $winEntry = $null
    $nowMs = Get-NowMs
    $maxAllowedUntil = $nowMs + $MaxPauseSpanMs

    foreach ($item in $TaggedCandidates) {
        if (-not $item -or -not $item.obj) { continue }
        $c = $item.obj
        $src = [string]$item.source
        if (-not (Test-ControlObjectAllowed $c $src $curCfg)) { continue }
        if ($c.classes -and $c.classes.PSObject.Properties[$cCode] -and $c.classes.$cCode) {
            $entry = $c.classes.$cCode
            $cts = [int64]$entry.cmd_ts
            $pUntil = [int64]$entry.pause_until_ms
            if ($pUntil -gt $maxAllowedUntil) { continue }
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
        return $true
    }
    return $false
}

function Start-AsyncPowerShellJob([scriptblock]$ScriptBlock, [array]$ArgList) {
    $ps = [powershell]::Create()
    $null = $ps.AddScript($ScriptBlock)
    foreach ($a in $ArgList) { $null = $ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    return [PSCustomObject]@{ Ps = $ps; Handle = $handle; StartedAt = (Get-Date) }
}

function Complete-AsyncJobIfDone($Job) {
    if (-not $Job) { return [PSCustomObject]@{ Done = $false; Result = $null } }
    if (-not $Job.Handle.IsCompleted) { return [PSCustomObject]@{ Done = $false; Result = $null } }
    $res = $null
    try { $res = $Job.Ps.EndInvoke($Job.Handle) } catch {}
    try { $Job.Ps.Dispose() } catch {}
    return [PSCustomObject]@{ Done = $true; Result = $res }
}

function Start-AsyncHeartbeat($curCfg, $curState) {
    if ($NoCloud -or $script:BgHbJob) { return }
    try {
        $cCode = [string]$curCfg.current_blackboard_class
        $epVal = Get-SavedClassEp $curState $cCode
        $payload = [PSCustomObject]@{
            cls          = "${cCode}班"
            clsCode      = $cCode
            host         = $env:COMPUTERNAME
            ver          = (Get-LocalBuildVer)
            ep           = [int]$epVal
            pauseUntilMs = [int64]$curState.pause_until_ms
            pauseLabel   = [string]$curState.pause_label
            ts           = (Get-NowMs)
        } | ConvertTo-Json -Compress
        $sb = {
            param($topic, $jsonBody)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Add-Type -AssemblyName System.Net.Http
                $hc = New-Object System.Net.Http.HttpClient
                $hc.DefaultRequestHeaders.UserAgent.ParseAdd("GeoBoardDaemon/3.2")
                $hc.Timeout = [TimeSpan]::FromSeconds(4)
                $content = New-Object System.Net.Http.StringContent($jsonBody, [System.Text.Encoding]::UTF8, "application/json")
                $hc.PostAsync("https://ntfy.sh/$topic", $content).GetAwaiter().GetResult() | Out-Null
                $hc.Dispose()
            } catch {}
        }
        $script:BgHbJob = Start-AsyncPowerShellJob $sb @($HbTopic, $payload)
    } catch {}
}

function Start-AsyncRemoteControlFetch {
    if ($NoCloud -or $script:BgCtlJob) { return }
    try {
        $sb = {
            param($ctlTopic)
            $out = @()
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Add-Type -AssemblyName System.Net.Http
                $hc = New-Object System.Net.Http.HttpClient
                $hc.DefaultRequestHeaders.UserAgent.ParseAdd("GeoBoardDaemon/3.2")
                $hc.Timeout = [TimeSpan]::FromSeconds(4)
                try {
                    $rawLines = $hc.GetStringAsync("https://ntfy.sh/$ctlTopic/json?poll=1&since=12h").GetAwaiter().GetResult()
                    if ($rawLines) {
                        foreach ($line in ($rawLines -split "`r?`n")) {
                            if (-not $line.Trim()) { continue }
                            try {
                                $ev = $line | ConvertFrom-Json
                                if ($ev.event -eq "message" -and $ev.message) {
                                    $out += [PSCustomObject]@{ source = "ntfy"; raw = [string]$ev.message }
                                }
                            } catch {}
                        }
                    }
                } catch {}
                try {
                    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $ghCtlTxt = $hc.GetStringAsync("https://autumnsorrow.github.io/geo-pass-tracker/board/board_control.json?t=$ts").GetAwaiter().GetResult()
                    if ($ghCtlTxt) {
                        $out += [PSCustomObject]@{ source = "repo"; raw = [string]$ghCtlTxt }
                    }
                } catch {}
                $hc.Dispose()
            } catch {}
            return ,$out
        }
        $script:BgCtlJob = Start-AsyncPowerShellJob $sb @($CtlTopic)
    } catch {}
}

function Start-AsyncCloudSync([string]$LanUrl = "", [string]$ReplyHost = "", [int]$AckPort = 0, [string]$ClsLabel = "", [string]$TargetVer = "") {
    if ($NoCloud -and (-not $LanUrl)) { return }
    if (-not (Test-Path $SyncPath)) { return }
    if ($LanUrl) {
        if ($script:BgLanJob) { return }
    } else {
        if ($script:BgSyncJob) { return }
    }
    $sb = {
        param($syncScript, $targetDir, $lanBase, $replyIp, $ackPort, $clsLabel)
        $resStr = ""
        try {
            . $syncScript -LibraryOnly
            $resStr = Invoke-GeoBoardSync -SyncTargetDir $targetDir -SyncLanBaseUrl $lanBase -IsInteractive $false -IsSilent $true
        } catch { $resStr = "" }
        if ($replyIp -and $ackPort -gt 0) {
            try {
                $u = New-Object System.Net.Sockets.UdpClient
                $ackMsg = "GEO_ACK|${clsLabel}|$env:COMPUTERNAME|$resStr"
                $ackBytes = [System.Text.Encoding]::UTF8.GetBytes($ackMsg)
                $u.Send($ackBytes, $ackBytes.Length, $replyIp, $ackPort) | Out-Null
                $u.Close()
            } catch {}
        }
        return [string]$resStr
    }
    $job = Start-AsyncPowerShellJob $sb @($SyncPath, $ScriptDir, $LanUrl, $ReplyHost, $AckPort, $ClsLabel)
    if ($LanUrl) {
        $job | Add-Member -NotePropertyName "TargetVer" -NotePropertyValue $TargetVer -Force
        $script:BgLanJob = $job
    } else {
        $script:BgSyncJob = $job
    }
}

function Invoke-HotReloadExit {
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
            $shouldCloseKiosk = $false
            if ($method -eq "OPTIONS") {
                $respJson = ""
            } elseif ($reqPath -eq "/status") {
                $cCfg = Read-JsonSafe $CfgPath
                $cSt  = Get-RuntimeState
                $cSt.board_open_ping_ms = Get-NowMs
                Write-JsonSafe $StatePath $cSt
                $cCls = [string]$cCfg.current_blackboard_class
                $savedEp = Get-SavedClassEp $cSt $cCls
                $todaySlots = @(Get-TodayActiveSlotTimes $cCfg $cCls)
                $nearSt = Find-UpcomingSlot $cCfg $cCls 0.0 25.0
                $hasCtlSec = ($cCfg.PSObject.Properties['remote_control_secret'] -and ([string]$cCfg.remote_control_secret).Trim() -ne "")
                $respJson = ([PSCustomObject]@{
                    ok               = $true
                    clsCode          = $cCls
                    cls              = "${cCls}班"
                    ep               = $savedEp
                    classEp          = $cSt.class_ep
                    recentOld        = $cSt.recent_old
                    vcntMap          = $cSt.vcnt_map
                    uiPrefs          = $cSt.ui_prefs
                    offsetMin        = [int]$cCfg.clock_offset_minutes
                    pauseUntilMs     = [int64]$cSt.pause_until_ms
                    pauseLabel       = [string]$cSt.pause_label
                    todaySlots       = $todaySlots
                    nextSlotTime     = if ($nearSt) { [string]$nearSt.timeStr } else { "" }
                    anchorMonday     = [string]$cCfg.anchor_monday
                    anchorWeekParity = [string]$cCfg.anchor_week_parity
                    hasControlSecret = [bool]$hasCtlSec
                    ver              = (Get-LocalBuildVer)
                } | ConvertTo-Json -Depth 6 -Compress)
            } elseif ($method -eq "POST" -and $reqPath -eq "/action") {
                $idxBody = $reqRaw.IndexOf("`r`n`r`n")
                $bodyStr = if ($idxBody -ge 0) { $reqRaw.Substring($idxBody + 4) } else { "{}" }
                $act = $bodyStr | ConvertFrom-Json
                $cCfg = Read-JsonSafe $CfgPath
                $cSt  = Get-RuntimeState
                $cCls = [string]$cCfg.current_blackboard_class
                $needHb = $false
                $willClose = $false

                if ($act.type -eq "open_osk") {
                    Open-TouchKeyboard | Out-Null
                } elseif ($act.type -eq "set_pause") {
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
                    if ((Get-BoardKioskProcesses).Count -gt 0) { $shouldCloseKiosk = $true; $willClose = $true }
                } elseif ($act.type -eq "close_lock") {
                    $near = Find-UpcomingSlot $cCfg $cCls -5.0 25.0
                    if ($near) {
                        $cSt.last_triggered_slot = $near.slotKey
                        $cSt.last_triggered_ms = Get-NowMs
                    }
                    $cSt.snooze_slot = ""
                    $cSt.board_open_ping_ms = 0
                    Write-JsonSafe $StatePath $cSt
                    if ((Get-BoardKioskProcesses).Count -gt 0) { $shouldCloseKiosk = $true; $willClose = $true }
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
                    if ($act.PSObject.Properties['remoteControlSecret'] -and $null -ne $act.remoteControlSecret) {
                        $cCfg | Add-Member -NotePropertyName "remote_control_secret" -NotePropertyValue ([string]$act.remoteControlSecret).Trim() -Force
                    }
                    if ($act.clsCode -in @("10","11") -and $act.clsCode -ne $cCfg.current_blackboard_class) {
                        $newCls = [string]$act.clsCode
                        $cCfg.current_blackboard_class = $newCls
                        $cSt.current_ep = Get-SavedClassEp $cSt $newCls
                        Write-JsonSafe $StatePath $cSt
                        $hasSt = @(Get-ChildItem -Path ([Environment]::GetFolderPath("Startup")) -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue).Count -gt 0
                        if ($hasSt) { Repair-Shortcuts $newCls $true }
                        $needHb = $true
                    }
                    Write-JsonSafe $CfgPath $cCfg
                }
                if ($needHb) { $script:NeedImmediateHb = $true }
                $hasCtlSecNow = ($cCfg.PSObject.Properties['remote_control_secret'] -and ([string]$cCfg.remote_control_secret).Trim() -ne "")
                $respJson = ([PSCustomObject]@{
                    ok               = $true
                    willClose        = [bool]$willClose
                    clsCode          = [string]$cCfg.current_blackboard_class
                    pauseUntilMs     = [int64]$cSt.pause_until_ms
                    pauseLabel       = [string]$cSt.pause_label
                    hasControlSecret = [bool]$hasCtlSecNow
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
        if ($shouldCloseKiosk) {
            Start-Sleep -Milliseconds 120
            Close-BoardKioskWindows | Out-Null
        }
    }
}

$UdpPort = 18766
$UdpListener = $null
try { $UdpListener = New-Object System.Net.Sockets.UdpClient($UdpPort) } catch { $UdpListener = $null }

$lastCloudSync = (Get-Date).AddSeconds(-172)
$lastHbSent    = (Get-Date).AddSeconds(-892)
$lastRemoteCtl = (Get-Date).AddSeconds(-170)
$script:LastLanVer = ""

function Poll-AsyncJobs {
    if ($script:BgHbJob) {
        $hbDone = Complete-AsyncJobIfDone $script:BgHbJob
        if ($hbDone.Done) { $script:BgHbJob = $null }
    }
    if ($script:BgCtlJob) {
        $ctlDone = Complete-AsyncJobIfDone $script:BgCtlJob
        if ($ctlDone.Done) {
            $script:BgCtlJob = $null
            try {
                $curCfg = Read-JsonSafe $CfgPath
                $curSt  = Get-RuntimeState
                $tagged = @()
                if ($ctlDone.Result) {
                    foreach ($row in @($ctlDone.Result)) {
                        if ($row -and $row.raw) {
                            try {
                                $parsed = ([string]$row.raw) | ConvertFrom-Json
                                if ($parsed) { $tagged += [PSCustomObject]@{ source = [string]$row.source; obj = $parsed } }
                            } catch {}
                        }
                    }
                }
                $diskCtl = Read-JsonSafe (Join-Path $ScriptDir "board_control.json")
                if ($diskCtl) { $tagged += [PSCustomObject]@{ source = "disk"; obj = $diskCtl } }
                if ($curCfg -and (Apply-RemoteControlCandidates $curCfg $curSt $tagged)) {
                    $script:NeedImmediateHb = $true
                }
            } catch {}
        }
    }
    if ($script:BgSyncJob) {
        $syDone = Complete-AsyncJobIfDone $script:BgSyncJob
        if ($syDone.Done) {
            $script:BgSyncJob = $null
            $resStr = ($syDone.Result | Select-Object -Last 1) -as [string]
            if ($resStr -like "UPDATED_DAEMON*") { Invoke-HotReloadExit }
        }
    }
    if ($script:BgLanJob) {
        $tVer = $script:BgLanJob.TargetVer
        $lanDone = Complete-AsyncJobIfDone $script:BgLanJob
        if ($lanDone.Done) {
            $script:BgLanJob = $null
            $resStr = ($lanDone.Result | Select-Object -Last 1) -as [string]
            if ($resStr -and $tVer) { $script:LastLanVer = $tVer }
            if ($resStr -like "UPDATED_DAEMON*") { Invoke-HotReloadExit }
        }
    }
    if ($script:NeedImmediateHb -and (-not $script:BgHbJob)) {
        $script:NeedImmediateHb = $false
        $curCfg = Read-JsonSafe $CfgPath
        $curSt  = Get-RuntimeState
        if ($curCfg) { Start-AsyncHeartbeat $curCfg $curSt }
    }
}

while ($true) {
    try {
        [IdleWin32]::KeepSystemAwake()
        Poll-AsyncJobs
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
                    $targetTime  = Get-SlotDateTime $now $slotTimeStr
                    $minsToClass = ($targetTime - $now).TotalMinutes
                    $slotKey     = "$($now.ToString('yyyyMMdd'))_${cls}_$slotTimeStr"

                    if ($st.snooze_slot -eq $slotKey) {
                        if ($nowMs -lt [int64]$st.snooze_until_ms) { continue }
                        $st.snooze_slot = ""
                        # 延后到期后若距上课不足 90 秒（1.5 分钟），不再强行弹窗打扰上课
                        if ($minsToClass -ge 1.5 -and $minsToClass -le 15.0) {
                            $st.last_triggered_slot = $slotKey
                            $st.last_triggered_ms = $nowMs
                            Write-JsonSafe $StatePath $st
                            Open-BoardApp $cls $slotTimeStr $offset
                            break
                        } else {
                            $st.last_triggered_slot = $slotKey
                            $st.last_triggered_ms = $nowMs
                            Write-JsonSafe $StatePath $st
                            continue
                        }
                    }

                    if ($st.last_triggered_slot -eq $slotKey) { continue }

                    # 严禁临近打铃或上课后自动弹窗！距上课不足 90 秒（1.5 分钟）不再自动弹，避免跳出来只剩 10 秒
                    $isMorningSlot = ($slotTimeStr -lt "07:30")
                    $minBound = 1.5
                    $maxBound = if ($isMorningSlot) { [math]::Max($leadMin, 8.0) } else { $leadMin }

                    if ($minsToClass -le $maxBound -and $minsToClass -ge $minBound) {
                        $idleSec = [IdleWin32]::GetIdleSeconds()
                        $fg = Get-ForegroundAppName
                        $shellApps = @("explorer", "SearchHost", "ShellExperienceHost", "StartMenuExperienceHost", "LockApp")
                        $busyApps = @("POWERPNT", "wpp", "wps", "et", "EasiNote", "HiteBoard", "AcroRd32", "FoxitReader", "PotPlayerMini64", "vlc")
                        $isRealFullscreen = ([IdleWin32]::IsForegroundFullscreen()) -and (-not ($fg -in $shellApps))
                        $isTeachingActive = ($fg -in $busyApps) -or $isRealFullscreen
                        if ($isMorningSlot) {
                            $needIdle = 25.0
                        } elseif ($isTeachingActive) {
                            $needIdle = [math]::Min([math]::Max($reqIdle, 75.0), 90.0)
                        } else {
                            $needIdle = [math]::Min($reqIdle, 35.0)
                        }

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

        if (((Get-Date) - $lastRemoteCtl).TotalSeconds -ge 180) {
            $lastRemoteCtl = Get-Date
            if ($NoCloud) {
                $diskCtl = Read-JsonSafe (Join-Path $ScriptDir "board_control.json")
                if ($diskCtl) {
                    Apply-RemoteControlCandidates $cfg $st @([PSCustomObject]@{ source = "disk"; obj = $diskCtl }) | Out-Null
                }
            } else {
                Start-AsyncRemoteControlFetch
            }
        }

        if (((Get-Date) - $lastCloudSync).TotalSeconds -ge 180) {
            $lastCloudSync = Get-Date
            Start-AsyncCloudSync ""
        }

        if (((Get-Date) - $lastHbSent).TotalSeconds -ge 900) {
            $lastHbSent = Get-Date
            $curHm = (Get-Date).AddMinutes($offset).ToString("HH:mm")
            if ($curHm -ge "06:15" -and $curHm -le "22:10") {
                $stAfter = Get-RuntimeState
                Start-AsyncHeartbeat $cfg $stAfter
            }
        }
    } catch {}

    for ($i = 0; $i -lt 8; $i++) {
        Handle-LocalApiPending
        Poll-AsyncJobs
        if ($UdpListener -and $UdpListener.Available -gt 0) {
            try {
                $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $pkt = $UdpListener.Receive([ref]$remoteEp)
                $msg = [System.Text.Encoding]::UTF8.GetString($pkt)
                if ($msg -match '^GEO_SYNC\|([^|]*)\|([^|]*)\|(\d+)$') {
                    $lanUrl = $Matches[1]
                    $targetVer = $Matches[2]
                    $ackPort = [int]$Matches[3]
                    if ($targetVer -and $targetVer -eq $script:LastLanVer) {
                        $ackMsg = "GEO_ACK|${cls}班|$env:COMPUTERNAME|UP_TO_DATE|$targetVer"
                        $ackBytes = [System.Text.Encoding]::UTF8.GetBytes($ackMsg)
                        $UdpListener.Send($ackBytes, $ackBytes.Length, $remoteEp.Address.ToString(), $ackPort) | Out-Null
                    } else {
                        Start-AsyncCloudSync $lanUrl $remoteEp.Address.ToString() $ackPort "${cls}班" $targetVer
                    }
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 250
    }
}
