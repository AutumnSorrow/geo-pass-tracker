param(
    [string]$TargetDir = "",
    [string]$SourceDir = "",
    [string]$LanBaseUrl = "",
    [switch]$Interactive,
    [switch]$Silent,
    [switch]$Force,
    [switch]$LibraryOnly
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

function Convert-VerToInt64([string]$VerStr) {
    if (-not $VerStr) { return [int64]0 }
    $digits = ($VerStr -replace '\D', '')
    if (-not $digits) { return [int64]0 }
    if ($digits.Length -ge 8) {
        $padded = $digits.PadRight(14, '0').Substring(0, 14)
        return [int64]$padded
    }
    return [int64]$digits
}

function Remove-ObsoleteSyncShortcuts {
    $names = @("地理课前通关·一键同步更新.lnk", "一键同步最新题库与功能.lnk")
    $dirs = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory")
    )
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path $d)) { continue }
        foreach ($n in $names) {
            $p = Join-Path $d $n
            if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-GeoBoardSync {
    param(
        [string]$SyncTargetDir,
        [string]$SyncSourceDir = "",
        [string]$SyncLanBaseUrl = "",
        [bool]$IsInteractive = $false,
        [bool]$IsSilent = $true,
        [bool]$ForceSync = $false
    )

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (-not $SyncTargetDir) { $SyncTargetDir = Split-Path -Parent $PSCommandPath }

    function Write-SyncLog([string]$Msg, [string]$Color = "Cyan") {
        if (-not $IsSilent) { Write-Host $Msg -ForegroundColor $Color }
    }
    function Read-SyncJson([string]$Path) {
        if (-not (Test-Path $Path)) { return $null }
        try { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
    }
    function Get-SyncSha256([string]$Path) {
        if (-not (Test-Path $Path)) { return "" }
        try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return "" }
    }
    function New-FastHttpClient([int]$TimeoutSec = 5) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd("GeoBoardSync/3.1")
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        return $client
    }
    function Get-BytesFromMirrors([string[]]$BaseUrls, [string]$RelPath, [string]$ExpectedSha256 = "", [int]$TimeoutSec = 5) {
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $client = New-FastHttpClient $TimeoutSec
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
                            $sha.Dispose()
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

    Remove-ObsoleteSyncShortcuts

    $Manifest = $null
    $MirrorBases = @()

    if ($SyncSourceDir -and (Test-Path (Join-Path $SyncSourceDir "board_manifest.json"))) {
        Write-SyncLog "📦 正在从本地/U盘更新源读取版本清单..." "Yellow"
        $Manifest = Read-SyncJson (Join-Path $SyncSourceDir "board_manifest.json")
    } else {
        if ($SyncLanBaseUrl) { $MirrorBases += $SyncLanBaseUrl }
        $shaRef = "main"
        if ($IsInteractive) {
            Write-SyncLog "☁️ 正在连接云端检查最新版本（实时直连通道）..." "Cyan"
            try {
                $cClient = New-FastHttpClient 4
                $cJson = $cClient.GetStringAsync("https://api.github.com/repos/AutumnSorrow/geo-pass-tracker/commits/main").GetAwaiter().GetResult()
                $cClient.Dispose()
                $cObj = $cJson | ConvertFrom-Json
                if ($cObj -and $cObj.sha) { $shaRef = [string]$cObj.sha }
            } catch {}
        }
        if ($shaRef -ne "main") {
            $MirrorBases += @(
                "https://testingcf.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@$shaRef/board/",
                "https://gcore.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@$shaRef/board/",
                "https://cdn.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@$shaRef/board/",
                "https://autumnsorrow.github.io/geo-pass-tracker/board/"
            )
        } else {
            $MirrorBases += @(
                "https://autumnsorrow.github.io/geo-pass-tracker/board/",
                "https://testingcf.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@main/board/",
                "https://gcore.jsdelivr.net/gh/AutumnSorrow/geo-pass-tracker@main/board/"
            )
        }

        $mBytes = Get-BytesFromMirrors $MirrorBases "board_manifest.json" "" 4
        if ($mBytes) {
            $mText = [System.Text.Encoding]::UTF8.GetString($mBytes)
            if ($mText.Length -gt 0 -and [int]$mText[0] -eq 0xFEFF) { $mText = $mText.Substring(1) }
            try { $Manifest = $mText | ConvertFrom-Json } catch { $Manifest = $null }
        }
    }

    if (-not $Manifest -or -not $Manifest.files) {
        Write-SyncLog "❌ 无法连接更新源（请检查教室网络，或使用U盘【一键更新】脚本）！" "Red"
        return "OFFLINE"
    }

    $RemoteVer = [string]$Manifest.build_version
    $LocalManifest = Read-SyncJson (Join-Path $SyncTargetDir "board_manifest.json")
    $LocalVer = if ($LocalManifest -and $LocalManifest.build_version) { [string]$LocalManifest.build_version } else { "" }

    # 单调递增防降级保护：绝不允许滞后的 CDN 节点或旧 U 盘包覆盖本机已安装的更新版本！
    $RemoteNum = Convert-VerToInt64 $RemoteVer
    $LocalNum  = Convert-VerToInt64 $LocalVer
    if (-not $ForceSync -and $LocalNum -gt 0 -and $RemoteNum -gt 0) {
        if ($RemoteNum -lt $LocalNum) {
            Write-SyncLog "✅ 本机当前版本 (v$LocalVer) 新于更新源 (v$RemoteVer)，已自动跳过防回退！" "Green"
            return "UP_TO_DATE|$LocalVer"
        }
        if ($IsSilent -and (-not $SyncSourceDir) -and (-not $SyncLanBaseUrl) -and ($RemoteNum -eq $LocalNum)) {
            return "UP_TO_DATE|$LocalVer"
        }
    }

    $ProtectedFiles = @("schedule_config.json", "runtime_state.json")
    $ChangedFiles = @()
    foreach ($f in $Manifest.files) {
        $rel = ([string]$f.path) -replace "/", "\"
        if ($rel -match "^\.board_kiosk_profile" -or ($rel -in $ProtectedFiles)) { continue }
        $dst = Join-Path $SyncTargetDir $rel
        $curHash = Get-SyncSha256 $dst
        if ($curHash -ne ([string]$f.sha256).ToLowerInvariant()) {
            $ChangedFiles += $f
        }
    }

    $DaemonUpdated = $false
    $UpdatedCount = 0

    if ($ChangedFiles.Count -gt 0) {
        Write-SyncLog ("⬇️ 发现新版本 v$RemoteVer（共需增量同步 $($ChangedFiles.Count) 个文件，含 $($Manifest.episode_count) 期题库）...") "Yellow"
        foreach ($f in $ChangedFiles) {
            $rel = ([string]$f.path) -replace "/", "\"
            $dst = Join-Path $SyncTargetDir $rel
            $parent = Split-Path -Parent $dst
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $tmpFile = "$dst.upd_tmp"

            $ok = $false
            if ($SyncSourceDir) {
                $srcFile = Join-Path $SyncSourceDir $rel
                if (Test-Path $srcFile) {
                    Copy-Item -LiteralPath $srcFile -Destination $tmpFile -Force
                    if ((Get-SyncSha256 $tmpFile) -eq ([string]$f.sha256).ToLowerInvariant()) { $ok = $true }
                }
            } else {
                $bytes = Get-BytesFromMirrors $MirrorBases ([string]$f.path) ([string]$f.sha256) 8
                if ($bytes) {
                    [System.IO.File]::WriteAllBytes($tmpFile, $bytes)
                    $ok = $true
                }
            }

            if ($ok) {
                Move-Item -LiteralPath $tmpFile -Destination $dst -Force
                $UpdatedCount++
                if ($rel -ieq "guard_daemon.ps1" -or $rel -ieq "guard_launcher.vbs") { $DaemonUpdated = $true }
                Write-SyncLog "   ✓ 已更新: $rel" "Green"
            } else {
                if (Test-Path $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
                Write-SyncLog "   ✗ 跳过/校验未过: $rel" "Red"
            }
        }
    }

    $TplPath = Join-Path $SyncTargetDir "schedule_template.json"
    $CfgPath = Join-Path $SyncTargetDir "schedule_config.json"
    if (Test-Path $TplPath) {
        $tpl = Read-SyncJson $TplPath
        if (-not (Test-Path $CfgPath)) {
            [System.IO.File]::WriteAllText($CfgPath, ($tpl | ConvertTo-Json -Depth 8), $Utf8NoBom)
        } elseif ($tpl -and $tpl.schedules) {
            $curCfg = Read-SyncJson $CfgPath
            if ($curCfg) {
                $curCfg.schedules = $tpl.schedules
                [System.IO.File]::WriteAllText($CfgPath, ($curCfg | ConvertTo-Json -Depth 8), $Utf8NoBom)
            }
        }
    }

    if ($UpdatedCount -eq $ChangedFiles.Count) {
        [System.IO.File]::WriteAllText((Join-Path $SyncTargetDir "board_manifest.json"), ($Manifest | ConvertTo-Json -Depth 8), $Utf8NoBom)
    }

    $dispOld = if ($LocalVer) { $LocalVer } else { "旧版" }
    if ($ChangedFiles.Count -eq 0) {
        Write-SyncLog "✅ 当前已是最新版本 v$RemoteVer（共 $($Manifest.episode_count) 期题库），无需重复下载！" "Green"
        return "UP_TO_DATE|$RemoteVer"
    } else {
        Write-SyncLog "🎉 同步完成！已从 [$dispOld] 升级至 [v$RemoteVer]（更新 $UpdatedCount 个文件，本班进度与配置完整保留）！" "Green"
        if ($DaemonUpdated) { return "UPDATED_DAEMON|$RemoteVer" }
        return "UPDATED_FILES|$RemoteVer"
    }
}

if (-not $LibraryOnly) {
    $SelfDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not $TargetDir) { $TargetDir = $SelfDir }
    $resCode = Invoke-GeoBoardSync -SyncTargetDir $TargetDir -SyncSourceDir $SourceDir -SyncLanBaseUrl $LanBaseUrl -IsInteractive ([bool]$Interactive) -IsSilent ([bool]$Silent) -ForceSync ([bool]$Force)

    if ($Interactive -and ($resCode -like "UPDATED_DAEMON*")) {
        $StartupDir = [Environment]::GetFolderPath("Startup")
        $HasInstalled = @(Get-ChildItem -Path $StartupDir -Filter "GeoPreClassGuard*.lnk" -ErrorAction SilentlyContinue).Count -gt 0
        if ($HasInstalled) {
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"?[^"]*guard_daemon\.ps1"?\s+-Mode\s+Daemon(\s+-HotReload)?\s*$'
            } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            $VbsPath = Join-Path $TargetDir "guard_launcher.vbs"
            if (Test-Path $VbsPath) {
                Start-Process -FilePath "wscript.exe" -ArgumentList "//B //NoLogo `"$VbsPath`" HotReload" -WindowStyle Hidden
            }
            Write-Host "🔄 已无感平滑重启新版后台值守进程！" -ForegroundColor Green
        }
    }
    if ($Silent) { Write-Output $resCode }
    if ($resCode -eq "OFFLINE") { exit 2 }
}
