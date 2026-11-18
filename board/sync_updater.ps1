param(
    [string]$TargetDir = "",
    [string]$SourceDir = "",
    [string]$LanBaseUrl = "",
    [switch]$Interactive,
    [switch]$Silent
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$SelfDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $TargetDir) { $TargetDir = $SelfDir }

function Write-Log([string]$Msg, [string]$Color = "Cyan") {
    if (-not $Silent) { Write-Host $Msg -ForegroundColor $Color }
}

function Read-JsonUtf8([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Get-LocalSha256([string]$Path) {
    if (-not (Test-Path $Path)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-DirectHttpClient([int]$TimeoutSec = 10) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("GeoBoardSync/2.0")
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    return $client
}

function Download-BytesFromMirrors([string[]]$BaseUrls, [string]$RelPath, [string]$ExpectedSha256 = "") {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $client = New-DirectHttpClient 12
    try {
        foreach ($base in $BaseUrls) {
            if (-not $base) { continue }
            $sep = if ($base.EndsWith("/")) { "" } else { "/" }
            $encodedRel = ($RelPath -replace "\\", "/").Split("/") | ForEach-Object { [System.Uri]::EscapeDataString($_) }
            $url = $base + $sep + ($encodedRel -join "/") + "?t=$ts"
            try {
                $bytes = $client.GetByteArrayAsync($url).GetAwaiter().GetResult()
                if ($bytes -and $bytes.Length -gt 0) {
                    if ($ExpectedSha256) {
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        $actual = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
                        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { continue }
                    }
                    return $bytes
                }
            } catch {}
        }
    } finally {
        $client.Dispose()
    }
    return $null
}

# 1. 构建更新源列表（优先局域网 -> 交互模式实时Commit SHA -> 多路云端镜像）
$Manifest = $null
$MirrorBases = @()

if ($SourceDir -and (Test-Path (Join-Path $SourceDir "board_manifest.json"))) {
    Write-Log "📦 正在从本地/U盘更新源读取版本清单..." "Yellow"
    $Manifest = Read-JsonUtf8 (Join-Path $SourceDir "board_manifest.json")
} else {
    if ($LanBaseUrl) { $MirrorBases += $LanBaseUrl }
    $shaRef = "main"
    if ($Interactive) {
        Write-Log "☁️ 正在连接云端检查最新版本（实时通道）..." "Cyan"
        try {
            $cClient = New-DirectHttpClient 5
            $cJson = $cClient.GetStringAsync("https://api.github.com/repos/AutumnSorrow/geo-pass-tracker/commits/main").GetAwaiter().GetResult()
            $cClient.Dispose()
            $cObj = $cJson | ConvertFrom-Json
            if ($cObj -and $cObj.sha) { $shaRef = [string]$cObj.sha }
        } catch {}
    }
    if ($shaRef -ne "main") {
        $MirrorBases += @(
            "https://raw.githubusercontent.com/AutumnSorrow/geo-pass-tracker/$shaRef/board/",
            "https://gcore.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@$shaRef/board/",
            "https://testingcf.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@$shaRef/board/",
            "https://cdn.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@$shaRef/board/",
            "https://autumnsorrow.github.io/geo-pass-tracker/board/"
        )
    } else {
        $MirrorBases += @(
            "https://autumnsorrow.github.io/geo-pass-tracker/board/",
            "https://raw.githubusercontent.com/AutumnSorrow/geo-pass-tracker/main/board/",
            "https://gcore.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@main/board/",
            "https://testingcf.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@main/board/"
        )
    }

    $mBytes = Download-BytesFromMirrors $MirrorBases "board_manifest.json" ""
    if ($mBytes) {
        $mText = [System.Text.Encoding]::UTF8.GetString($mBytes)
        if ($mText.Length -gt 0 -and [int]$mText[0] -eq 0xFEFF) { $mText = $mText.Substring(1) }
        $Manifest = $mText | ConvertFrom-Json
    }
}

if (-not $Manifest -or -not $Manifest.files) {
    Write-Log "❌ 无法连接更新源（请检查教室网络，或使用U盘【一键更新】脚本）！" "Red"
    if ($Silent) { Write-Output "OFFLINE" }
    exit 2
}

$RemoteVer = [string]$Manifest.build_version
$LocalManifest = Read-JsonUtf8 (Join-Path $TargetDir "board_manifest.json")
$LocalVer = if ($LocalManifest) { [string]$LocalManifest.build_version } else { "旧版" }

# 2. 逐文件对比 SHA256，仅增量拉取有变化的文件（绝不触碰 .board_kiosk_profile 与本班配置）
$ChangedFiles = @()
foreach ($f in $Manifest.files) {
    $rel = ([string]$f.path) -replace "/", "\"
    if ($rel -match "^\.board_kiosk_profile" -or $rel -eq "schedule_config.json") { continue }
    $dst = Join-Path $TargetDir $rel
    $curHash = Get-LocalSha256 $dst
    if ($curHash -ne ([string]$f.sha256).ToLowerInvariant()) {
        $ChangedFiles += $f
    }
}

$DaemonUpdated = $false
$UpdatedCount = 0

if ($ChangedFiles.Count -gt 0) {
    Write-Log ("⬇️ 发现新版本 v$RemoteVer（共需增量同步 $($ChangedFiles.Count) 个文件，含 $($Manifest.episode_count) 期题库）...") "Yellow"
    foreach ($f in $ChangedFiles) {
        $rel = ([string]$f.path) -replace "/", "\"
        $dst = Join-Path $TargetDir $rel
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $tmpFile = "$dst.upd_tmp"

        $ok = $false
        if ($SourceDir) {
            $srcFile = Join-Path $SourceDir $rel
            if (Test-Path $srcFile) {
                Copy-Item -LiteralPath $srcFile -Destination $tmpFile -Force
                if ((Get-LocalSha256 $tmpFile) -eq ([string]$f.sha256).ToLowerInvariant()) { $ok = $true }
            }
        } else {
            $bytes = Download-BytesFromMirrors $MirrorBases ([string]$f.path) ([string]$f.sha256)
            if ($bytes) {
                [System.IO.File]::WriteAllBytes($tmpFile, $bytes)
                $ok = $true
            }
        }

        if ($ok) {
            Move-Item -LiteralPath $tmpFile -Destination $dst -Force
            $UpdatedCount++
            if ($rel -ieq "guard_daemon.ps1") { $DaemonUpdated = $true }
            Write-Log "   ✓ 已更新: $rel" "Green"
        } else {
            if (Test-Path $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            Write-Log "   ✗ 跳过/校验未过: $rel" "Red"
        }
    }
}

# 3. 安全合并课表模板（100%保留本教室班级 10/11、铃声误差、单双周锚点！）
$TplPath = Join-Path $TargetDir "schedule_template.json"
$CfgPath = Join-Path $TargetDir "schedule_config.json"
if (Test-Path $TplPath) {
    $tpl = Read-JsonUtf8 $TplPath
    if (-not (Test-Path $CfgPath)) {
        [System.IO.File]::WriteAllText($CfgPath, ($tpl | ConvertTo-Json -Depth 8), $Utf8NoBom)
    } elseif ($tpl -and $tpl.schedules) {
        $curCfg = Read-JsonUtf8 $CfgPath
        if ($curCfg) {
            $curCfg.schedules = $tpl.schedules
            [System.IO.File]::WriteAllText($CfgPath, ($curCfg | ConvertTo-Json -Depth 8), $Utf8NoBom)
        }
    }
}

# 4. 保存最新本地清单 & 自动补建桌面【一键同步更新】快捷方式（若本机已部署过）
if ($UpdatedCount -eq $ChangedFiles.Count) {
    [System.IO.File]::WriteAllText((Join-Path $TargetDir "board_manifest.json"), ($Manifest | ConvertTo-Json -Depth 8), $Utf8NoBom)
}

$StartupDir = [Environment]::GetFolderPath("Startup")
$HasInstalled = @(Get-ChildItem -Path $StartupDir -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue).Count -gt 0
if ($HasInstalled) {
    try {
        $DesktopDir = [Environment]::GetFolderPath("Desktop")
        $SyncBat = Join-Path $TargetDir "一键同步最新题库与功能.bat"
        if (Test-Path $SyncBat) {
            $Wsh = New-Object -ComObject WScript.Shell
            $Sc = $Wsh.CreateShortcut((Join-Path $DesktopDir "地理课前通关·一键同步更新.lnk"))
            $Sc.TargetPath = $SyncBat
            $Sc.WorkingDirectory = $TargetDir
            $Sc.Save()
        }
    } catch {}
}

# 5. 若交互式/U盘更新且守护脚本有变动，自动平滑重启后台守护进程
if ($Interactive -and $DaemonUpdated -and $HasInstalled) {
    $DaemonPs1 = Join-Path $TargetDir "guard_daemon.ps1"
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -match 'guard_daemon\.ps1"\s+-Mode\s+Daemon'
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DaemonPs1`" -Mode Daemon"
    Write-Log "🔄 已自动平滑重启新版后台值守进程！" "Green"
}

if ($ChangedFiles.Count -eq 0) {
    Write-Log "✅ 当前已是最新版本 v$RemoteVer（共 $($Manifest.episode_count) 期题库），无需重复下载！" "Green"
    if ($Silent) { Write-Output "UP_TO_DATE|$RemoteVer" }
} else {
    Write-Log "🎉 同步完成！已从 [$LocalVer] 升级至 [v$RemoteVer]（本次更新 $UpdatedCount 个文件，本班进度与配置完整保留）！" "Green"
    if ($Silent) {
        if ($DaemonUpdated) { Write-Output "UPDATED_DAEMON|$RemoteVer" } else { Write-Output "UPDATED_FILES|$RemoteVer" }
    }
}
