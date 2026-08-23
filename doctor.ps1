# =====================================================================
#  doctor.ps1  —  DSH 桌面版 环境自检工具
#
#  核心场景：电脑启动后「桌面快捷方式丢失 / 双击不可用」时，一键诊断根因。
#  覆盖失败模式 M01–M15（物理丢失 / 路径漂移 / 图标失效 / OneDrive 桌面 /
#  权限只读 / MOTW 拦截 / Explorer 缓存 / 依赖缺失 / lnk 损坏 / 启动器自身
#  故障 / 杀软隔离 / 多用户混淆 / 编码错误 / portproxy 抢占 / WorkingDir 绑定）。
#
#  用法:
#    powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Fix      # 交互式自动修复
#    powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Json     # 机器可读 JSON
#
#  设计约定:
#    - 默认纯只读探测，绝不改动任何文件；
#    - -Fix 仅对 error / critical 项尝试修复，且每项修复前 Read-Host 确认(y/N)；
#    - 单项检查失败不中断整体（每项 try/catch）；
#    - PowerShell 5.1 兼容（不用 ?? 等 PS7 语法）。
# =====================================================================

param(
    [switch]$Fix,   # 交互式自动修复 error/critical（重建快捷方式 / Unblock-File / 清理陈旧 server.pid）
    [switch]$Json   # 输出机器可读 JSON
)

# 单项检查失败不得中断整体：用 Continue 而非 Stop
$ErrorActionPreference = "Continue"
$ProgressPreference     = "SilentlyContinue"

# 项目根目录：doctor.ps1 与启动器同目录
$scriptDir     = $PSScriptRoot
$lnkName       = "DSH 桌面版"
$launcherRel   = Join-Path $scriptDir "start-dsh-desktop.ps1"
$logDir        = Join-Path $env:LOCALAPPDATA "DSHDesktop"

# ----------------- 严重度定义与排序 -----------------
# critical > error > warn > info
$sevRank = @{ critical = 0; error = 1; warn = 2; info = 3 }

# ----------------- 结论收集容器 -----------------
$results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [string]$Id, [string]$Name, [string]$Severity,
        [string]$Status, [string]$Evidence, [string]$FixCmd, [string]$FixKind
    )
    $r = [PSCustomObject]@{
        id       = $Id
        name     = $Name
        severity = $Severity
        status   = $Status
        evidence = $(if ($Evidence) { $Evidence } else { "" })
        fix      = $(if ($FixCmd) { $FixCmd } else { "" })
        fixKind  = $(if ($FixKind) { $FixKind } else { "" })
    }
    [void]$results.Add($r)
}

# ----------------- 通用探测辅助（沿用 start-dsh-desktop.ps1 逻辑） -----------------

# 多候选定位浏览器：Chrome 优先，Edge 兜底
function Resolve-Browser {
    $cands = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    foreach ($n in @("chrome", "msedge")) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# 解析 dsh 启动方式（避免 PATH 失效导致误判为缺失）
function Resolve-Dsh {
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 兜底：nvmd 全局垫片
    $nvmd = Join-Path $env:USERPROFILE ".nvmd\bin\dsh.cmd"
    if (Test-Path $nvmd) { return $nvmd }
    return $null
}

# 列出 portproxy 中 0.0.0.0 通配监听的端口
function Get-PortProxyWildcardPorts {
    try {
        $out = @(netsh interface portproxy show v4tov4 2>$null)
        $ports = @()
        foreach ($l in $out) {
            if ($l -match "^\s*(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s*$") {
                if ($Matches[1] -eq "0.0.0.0") { $ports += [int]$Matches[2] }
            }
        }
        return $ports
    } catch { return @() }
}

# 探测某文件是否带 MOTW（Zone.Identifier 备用数据流）
function Test-Motw {
    param([string]$Path)
    try {
        $st = Get-Item -Path $Path -Stream Zone.Identifier -ErrorAction Stop
        if ($st) { return $true }
        return $false
    } catch {
        return $false
    }
}

# 读取 .lnk 快捷方式（WScript.Shell COM）
function Read-Lnk {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($Path)
    return @{
        TargetPath       = $sc.TargetPath
        Arguments        = $sc.Arguments
        WorkingDirectory = $sc.WorkingDirectory
        IconLocation     = $sc.IconLocation
    }
}

# 从 Arguments 中解析 -File 指向的脚本路径
function Get-FileArg {
    param([string]$Arguments)
    if ($Arguments -match '-File\s+"?([^"]+)"') { return $Matches[1].Trim() }
    return $null
}

# ----------------- 预取若干通用路径 -----------------
$userDesktop   = [Environment]::GetFolderPath("Desktop")
$publicDesktop = $null
try { $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory") } catch { $publicDesktop = $null }
$userLnkPath   = Join-Path $userDesktop ($lnkName + ".lnk")
$lnkExists     = Test-Path $userLnkPath

Write-Host ""
Write-Host "========== DSH 桌面版 环境自检 ==========" -ForegroundColor Cyan
Write-Host ("项目根 : " + $scriptDir)
Write-Host ("桌面   : " + $userDesktop)
Write-Host ("模式   : " + $(if ($Fix) { "只读 + 交互修复" } else { "纯只读探测" }))
Write-Host ""

# =====================================================================
# M01 物理丢失(.lnk 不存在) —— error
# 检测桌面与 shell:Desktop 路径下是否存在 "DSH 桌面版.lnk"
# =====================================================================
try {
    $shell = New-Object -ComObject WScript.Shell
    $shellDesktop = $shell.SpecialFolders.Item("Desktop")
    $shellLnkPath = Join-Path $shellDesktop ($lnkName + ".lnk")

    $found = $false
    $where = ""
    if ($lnkExists) { $found = $true; $where = $userLnkPath }
    elseif (Test-Path $shellLnkPath) { $found = $true; $where = $shellLnkPath }

    if ($found) {
        Add-Result "M01" "物理丢失" "error" "OK" "" "" ""
    } else {
        Add-Result "M01" "物理丢失" "error" "FAIL" `
            ("桌面不存在 " + $lnkName + ".lnk （" + $userDesktop + "）") `
            ".\创建桌面快捷方式.bat" "rebuild"
    }
} catch {
    Add-Result "M01" "物理丢失" "error" "FAIL" ("检测异常: " + $_.Exception.Message) "" "rebuild"
}

# =====================================================================
# M02 路径漂移(.lnk 目标失效) —— error
# 兼容两种形态: 直指入口 bat / powershell -File，分别校验目标存在性
# =====================================================================
try {
    if ($lnkExists) {
        $info = Read-Lnk $userLnkPath
        $tp = [string]$info.TargetPath
        if ($tp -match "\.(bat|cmd)$") {
            # 形态A: 快捷方式直指入口 bat（防杀软隔离形态）
            if (Test-Path $tp) {
                Add-Result "M02" "路径漂移" "error" "OK" "" "" ""
            } else {
                Add-Result "M02" "路径漂移" "error" "FAIL" ("目标 bat 不存在(项目被移动/重命名): " + $tp) `
                    ".\创建桌面快捷方式.bat" "rebuild"
            }
        } else {
            # 形态B: 旧版直接调用 powershell，校验 Arguments 中 -File 路径
            $fileArg = Get-FileArg $info.Arguments
            if (-not $fileArg) {
                Add-Result "M02" "路径漂移" "error" "FAIL" ("无法从 Arguments 解析 -File 路径: " + $info.Arguments) `
                    ".\创建桌面快捷方式.bat" "rebuild"
            } elseif (Test-Path $fileArg) {
                Add-Result "M02" "路径漂移" "error" "OK" "" "" ""
            } else {
                Add-Result "M02" "路径漂移" "error" "FAIL" ("-File 目标不存在(项目被移动/重命名): " + $fileArg) `
                    ".\创建桌面快捷方式.bat" "rebuild"
            }
        }
    } else {
        # 快捷方式本身不存在，归并到 M01；此处标记跳过
        Add-Result "M02" "路径漂移" "error" "OK" "（快捷方式缺失，由 M01 处理）" "" ""
    }
} catch {
    Add-Result "M02" "路径漂移" "error" "FAIL" ("检测异常: " + $_.Exception.Message) "" "rebuild"
}

# =====================================================================
# M03 图标失效(warn) —— IconLocation 指向的 dsh-icon-*.ico 不存在
# 双击仍可用但显示白板图标
# =====================================================================
try {
    if ($lnkExists) {
        $info = Read-Lnk $userLnkPath
        $ico  = $info.IconLocation
        if ($ico -match "^(.*?),") { $icoPath = $Matches[1] } else { $icoPath = $ico }
        if ($icoPath -and (Test-Path $icoPath)) {
            Add-Result "M03" "图标失效" "warn" "OK" "" "" ""
        } elseif ($icoPath) {
            Add-Result "M03" "图标失效" "warn" "WARN" ("图标文件不存在(白板图标): " + $icoPath) `
                ".\切换DSH图标.bat" ""
        } else {
            Add-Result "M03" "图标失效" "warn" "OK" "（未显式设置图标，使用系统兜底）" "" ""
        }
    } else {
        Add-Result "M03" "图标失效" "warn" "OK" "（快捷方式缺失，跳过）" "" ""
    }
} catch {
    Add-Result "M03" "图标失效" "warn" "WARN" ("检测异常: " + $_.Exception.Message) "" ""
}

# =====================================================================
# M04 OneDrive 桌面异常(warn) —— GetFolderPath("Desktop") 返回云端路径且不可用
# =====================================================================
try {
    $isCloud = $userDesktop -match "OneDrive"
    $accessible = Test-Path $userDesktop
    if ($isCloud -and -not $accessible) {
        Add-Result "M04" "OneDrive桌面" "warn" "WARN" ("桌面指向 OneDrive 云端且当前不可用: " + $userDesktop) `
            "将桌面文件夹移回本地，或确保 OneDrive 已同步登录" ""
    } elseif ($isCloud) {
        Add-Result "M04" "OneDrive桌面" "warn" "WARN" ("桌面位于 OneDrive 云端路径(同步延迟可能导致快捷方式不显示): " + $userDesktop) `
            "等待 OneDrive 同步完成，或在本地「文档」之外建立固定桌面" ""
    } else {
        Add-Result "M04" "OneDrive桌面" "warn" "OK" "" "" ""
    }
} catch {
    Add-Result "M04" "OneDrive桌面" "warn" "WARN" ("检测异常: " + $_.Exception.Message) "" ""
}

# =====================================================================
# M05 权限/只读(error) —— 桌面目录无写权限 / 盘只读
# =====================================================================
try {
    $probe = Join-Path $userDesktop ("__dsh_doctor_write_test_" + [Guid]::NewGuid().ToString("N").Substring(0,6) + ".tmp")
    try {
        [System.IO.File]::WriteAllText($probe, "t")
        [System.IO.File]::Delete($probe)
        Add-Result "M05" "权限/只读" "error" "OK" "" "" ""
    } catch {
        Add-Result "M05" "权限/只读" "error" "FAIL" ("桌面目录不可写(权限不足或磁盘只读): " + $userDesktop) `
            "以管理员身份运行，或检查磁盘属性/防篡改软件" ""
    }
} catch {
    Add-Result "M05" "权限/只读" "error" "FAIL" ("写权限探测异常: " + $_.Exception.Message) "" ""
}

# =====================================================================
# M06 MOTW 拦截(error) —— Zone.Identifier 存在致 ps1 静默不执行
# =====================================================================
try {
    $motwFiles = @()
    # 检查本目录所有 ps1（重点入口启动器）
    $ps1Files = @(Get-ChildItem $scriptDir -Filter "*.ps1" -ErrorAction SilentlyContinue)
    foreach ($f in $ps1Files) {
        if (Test-Motw $f.FullName) { $motwFiles += $f.Name }
    }
    if ($motwFiles.Count -gt 0) {
        Add-Result "M06" "MOTW拦截" "error" "FAIL" ("存在 Web 标记(MOTW)，双击会被拦截静默不执行: " + ($motwFiles -join ", ")) `
            "Get-ChildItem -Recurse | Unblock-File" "unblock"
    } else {
        Add-Result "M06" "MOTW拦截" "error" "OK" "" "" ""
    }
} catch {
    Add-Result "M06" "MOTW拦截" "error" "FAIL" ("检测异常: " + $_.Exception.Message) "" "unblock"
}

# =====================================================================
# M07 Explorer 缓存假象(info) —— .lnk 磁盘存在但桌面不显示
# 重启 explorer 可恢复。启发式：文件在磁盘存在但 explorer.exe 未运行
# =====================================================================
try {
    $explorerRunning = $false
    try { $explorerRunning = @(Get-Process explorer -ErrorAction SilentlyContinue).Count -gt 0 } catch { $explorerRunning = $true }
    if ($lnkExists -and -not $explorerRunning) {
        Add-Result "M07" "Explorer缓存" "info" "INFO" "快捷方式在磁盘存在，但 explorer.exe 未运行，桌面无法显示" `
            "taskkill /f /im explorer.exe 后重启资源管理器(或注销重登)" ""
    } else {
        Add-Result "M07" "Explorer缓存" "info" "OK" "" "" ""
    }
} catch {
    Add-Result "M07" "Explorer缓存" "info" "OK" "" "" ""
}

# =====================================================================
# M08 依赖缺失(error) —— PowerShell / dsh / node / Chrome 任一不可用
# =====================================================================
try {
    $missing = @()
    # PowerShell 版本
    $psMajor = $PSVersionTable.PSVersion.Major
    if ($psMajor -lt 5) { $missing += ("PowerShell 版本过低(当前 " + $psMajor + ", 需 >=5)") }
    # dsh
    $dsh = Resolve-Dsh
    if (-not $dsh) { $missing += "dsh 命令不可用(未在 PATH，且 %USERPROFILE%\.nvmd\bin\dsh.cmd 不存在)" }
    # node（dsh 运行时的间接依赖）
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        # nvmd 风格：dsh 垫片同目录的 node.exe
        if ($dsh -and (Test-Path (Join-Path (Split-Path $dsh -Parent) "node.exe"))) {
            # 通过 dsh 垫片可解析 node，视为可用
        } else { $missing += "node 不可用(DeepSeek Harness 运行时依赖)" }
    }
    # Chrome / Edge
    $browser = Resolve-Browser
    if (-not $browser) { $missing += "Chrome / Edge 均不可用(App 窗口容器缺失)" }

    if ($missing.Count -eq 0) {
        Add-Result "M08" "依赖缺失" "error" "OK" "" "" ""
    } else {
        Add-Result "M08" "依赖缺失" "error" "FAIL" ("缺失依赖: " + ($missing -join "；")) `
            "安装/修复 DeepSeek Harness 与 Node.js，并确保 Chrome 或 Edge 已安装" ""
    }
} catch {
    Add-Result "M08" "依赖缺失" "error" "FAIL" ("检测异常: " + $_.Exception.Message) "" ""
}

# =====================================================================
# M09 .lnk 内容损坏(error) —— TargetPath 空 / 参数截断
# 兼容两种形态: 直指入口 bat（Arguments 可为空）/ powershell -File
# =====================================================================
try {
    if ($lnkExists) {
        $info = Read-Lnk $userLnkPath
        $bad = @()
        if (-not $info.TargetPath) { $bad += "TargetPath 为空" }
        if ($info.TargetPath -match "\.(bat|cmd)$") {
            # 形态A: 指向 bat，无参数属正常
        } elseif (-not $info.Arguments) {
            $bad += "Arguments 为空"
        } elseif ($info.Arguments -notmatch "-File") {
            $bad += "Arguments 缺少 -File（参数被截断）"
        }
        if ($bad.Count -eq 0) {
            Add-Result "M09" ".lnk损坏" "error" "OK" "" "" ""
        } else {
            Add-Result "M09" ".lnk损坏" "error" "FAIL" ("快捷方式内容损坏: " + ($bad -join "；")) `
                ".\创建桌面快捷方式.bat" "rebuild"
        }
    } else {
        Add-Result "M09" ".lnk损坏" "error" "OK" "（快捷方式缺失，跳过）" "" ""
    }
} catch {
    Add-Result "M09" ".lnk损坏" "error" "FAIL" ("检测异常: " + $_.Exception.Message) "" "rebuild"
}

# =====================================================================
# M10 启动器自身故障被误认(warn) —— 端口全占 / dsh 起不来
# 查 start.log 与 server-*.err.log 关键字
# =====================================================================
try {
    $hits = @()
    $logFile = Join-Path $logDir "start.log"
    if (Test-Path $logFile) {
        $tail = @(Get-Content $logFile -ErrorAction SilentlyContinue | Select-Object -Last 40)
        foreach ($line in $tail) {
            if ($line -match "ERROR|失败|exit code|EADDRINUSE|EACCES|listen E|无法启动|crash") { $hits += $line.Trim() }
        }
    }
    $errLogs = @(Get-ChildItem $logDir -Filter "server-*.err.log" -ErrorAction SilentlyContinue | Select-Object -First 3)
    foreach ($el in $errLogs) {
        $tail = @(Get-Content $el.FullName -ErrorAction SilentlyContinue | Select-Object -Last 10)
        foreach ($line in $tail) { if ($line.Trim()) { $hits += ($el.Name + ": " + $line.Trim()) } }
    }
    if ($hits.Count -gt 0) {
        Add-Result "M10" "启动器故障" "warn" "WARN" ("日志发现启动失败痕迹(双击无反应可能源于 dsh 起不来): " + ($hits -join " | ")) `
            ("查看日志 " + $logDir + "\start.log 与 server-*.err.log") ""
    } else {
        Add-Result "M10" "启动器故障" "warn" "OK" "" "" ""
    }
} catch {
    Add-Result "M10" "启动器故障" "warn" "OK" "" "" ""
}

# =====================================================================
# M11 杀软隔离(critical) —— 启发式：核心文件被清空或落入已知隔离区
# 覆盖: Windows Defender 隔离区 + 火绒(Huorong)隔离区。
# 火绒载荷按内容哈希命名且加密存储，无法读出原文件名，
# 采用「时间(近30天) + 大小(与 .lnk 相差≤64B)」关联启发判定。
# =====================================================================
try {
    $crit  = @()
    $warns = @()
    # 核心入口脚本被清空（疑似隔离/截断）
    if (Test-Path $launcherRel) {
        $sz = (Get-Item $launcherRel).Length
        if ($sz -eq 0) { $crit += ("入口脚本被清空(可能为杀软隔离): " + $launcherRel) }
    } else {
        $crit += ("入口脚本不存在: " + $launcherRel)
    }
    # 扫描 Windows Defender 隔离目录是否含与本项目相关的文件
    $quarRoots = @(
        (Join-Path $env:ProgramData "Microsoft\Windows Defender\Quarantine"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Defender\Quarantine")
    )
    foreach ($qr in $quarRoots) {
        if (Test-Path $qr) {
            $match = @(Get-ChildItem $qr -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "DSH|start-dsh-desktop|dsh-icon" } | Select-Object -First 3)
            foreach ($m in $match) { $crit += ("疑似被隔离: " + $m.FullName) }
        }
    }
    # 扫描火绒(Huorong)隔离区 —— 本项目快捷方式曾被其两次静默隔离
    $huorongQ = Join-Path $env:ProgramData "Huorong\Sysdiag\Quarantine"
    if (Test-Path $huorongQ) {
        $recentQ = @(Get-ChildItem $huorongQ -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) -and $_.Length -gt 200 })
        if ($recentQ.Count -gt 0) {
            if ($lnkExists) {
                $lnkSz = (Get-Item $userLnkPath).Length
                foreach ($f in $recentQ) {
                    if ([Math]::Abs($f.Length - $lnkSz) -le 64) {
                        $warns += ("火绒隔离区存在与当前快捷方式大小相近的载荷(疑似历史被隔离): " + $f.Name + " (" + $f.Length + "B @ " + $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm") + ")")
                    }
                }
            } else {
                foreach ($f in ($recentQ | Select-Object -First 3)) {
                    $crit += ("桌面无快捷方式 且 火绒隔离区近30天有记录(高度疑似被静默隔离): " + $f.Name + " (" + $f.Length + "B @ " + $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm") + ")")
                }
            }
        }
    }
    if ($crit.Count -gt 0) {
        Add-Result "M11" "杀软隔离" "critical" "FAIL" ($crit -join "；") `
            "打开杀软(火绒: 防护中心→信任区)将 dsh-desktop 目录加入信任区并从隔离区恢复，然后运行 .\创建桌面快捷方式.bat" ""
    } elseif ($warns.Count -gt 0) {
        Add-Result "M11" "杀软隔离" "warn" "WARN" ($warns -join "；") `
            "建议将 dsh-desktop 目录加入杀软信任区(火绒: 防护中心→信任区)，防止快捷方式再次被静默隔离" ""
    } else {
        Add-Result "M11" "杀软隔离" "critical" "OK" "" "" ""
    }
} catch {
    Add-Result "M11" "杀软隔离" "critical" "OK" "" "" ""
}

# =====================================================================
# M12 多用户混淆(warn) —— .lnk 建在另一用户 / Public 桌面
# =====================================================================
try {
    $others = @()
    if ($publicDesktop -and (Test-Path (Join-Path $publicDesktop ($lnkName + ".lnk")))) {
        $others += ("Public 桌面: " + (Join-Path $publicDesktop ($lnkName + ".lnk")))
    }
    # 遍历 C:\Users\* 的桌面
    $usersRoot = Join-Path $env:SystemDrive "Users"
    if (Test-Path $usersRoot) {
        foreach ($u in @(Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue)) {
            $ud = Join-Path $u.FullName "Desktop"
            $ul = Join-Path $ud ($lnkName + ".lnk")
            if ((Test-Path $ul) -and ($ul -ne $userLnkPath)) { $others += ("其他用户桌面: " + $ul) }
        }
    }
    if ($others.Count -gt 0 -and -not $lnkExists) {
        Add-Result "M12" "多用户混淆" "warn" "WARN" ("当前用户桌面无快捷方式，但以下位置存在: " + ($others -join "；")) `
            "在当前用户下重新运行 .\创建桌面快捷方式.bat" "rebuild"
    } elseif ($others.Count -gt 0) {
        Add-Result "M12" "多用户混淆" "warn" "WARN" ("其他位置也存在快捷方式(可能误双击到旧链接): " + ($others -join "；")) `
            "清理多余快捷方式，仅保留当前用户桌面的一份" ""
    } else {
        Add-Result "M12" "多用户混淆" "warn" "OK" "" "" ""
    }
} catch {
    Add-Result "M12" "多用户混淆" "warn" "OK" "" "" ""
}

# =====================================================================
# M13 编码错误(error) —— ps1 无 UTF-8 BOM 致中文路径解析崩溃
# =====================================================================
try {
    if (Test-Path $launcherRel) {
        $bytes = [System.IO.File]::ReadAllBytes($launcherRel)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if ($hasBom) {
            Add-Result "M13" "编码错误" "error" "OK" "" "" ""
        } else {
            Add-Result "M13" "编码错误" "error" "FAIL" ("启动器缺少 UTF-8 BOM，含中文路径时可能解析崩溃: " + $launcherRel) `
                "以 UTF-8 BOM 重新保存 ps1（或重新解压项目）" ""
        }
    } else {
        Add-Result "M13" "编码错误" "error" "OK" "（入口脚本缺失，跳过）" "" ""
    }
} catch {
    Add-Result "M13" "编码错误" "error" "FAIL" ("检测异常: " + $_.Exception.Message) "" ""
}

# =====================================================================
# M14 portproxy 通配监听抢占端口(warn)
# 0.0.0.0 通配监听 3080/3081/3082 会导致 dsh 绑定失败
# =====================================================================
try {
    $wild = Get-PortProxyWildcardPorts
    $hitPorts = @(3080, 3081, 3082) | Where-Object { $wild -contains $_ }
    if ($hitPorts.Count -gt 0) {
        Add-Result "M14" "portproxy抢占" "warn" "WARN" ("portproxy 0.0.0.0 通配监听占用端口: " + ($hitPorts -join ",")) `
            "netsh interface portproxy delete v4tov4 listenport=<端口> listenaddress=0.0.0.0" ""
    } else {
        Add-Result "M14" "portproxy抢占" "warn" "OK" "" "" ""
    }
} catch {
    Add-Result "M14" "portproxy抢占" "warn" "OK" "" "" ""
}

# =====================================================================
# M15 WorkingDirectory 绑定错误(warn)
# .lnk WorkingDirectory 应等于项目根
# =====================================================================
try {
    if ($lnkExists) {
        $info = Read-Lnk $userLnkPath
        if ($info.WorkingDirectory -eq $scriptDir) {
            Add-Result "M15" "WorkingDir" "warn" "OK" "" "" ""
        } else {
            Add-Result "M15" "WorkingDir" "warn" "WARN" ("WorkingDirectory 绑定错误(应为 " + $scriptDir + ", 实为 " + $info.WorkingDirectory + ")") `
                ".\创建桌面快捷方式.bat" "rebuild"
        }
    } else {
        Add-Result "M15" "WorkingDir" "warn" "OK" "（快捷方式缺失，跳过）" "" ""
    }
} catch {
    Add-Result "M15" "WorkingDir" "warn" "OK" "" "" ""
}

# =====================================================================
# -Fix 交互式自动修复（仅 error / critical，每项确认 y/N，同类只做一次）
# =====================================================================
function Apply-Fix {
    param([string]$Kind)
    try {
        if ($Kind -eq "rebuild") {
            & (Join-Path $scriptDir "create-desktop-shortcut.ps1") | Out-Null
            Write-Host "    [修复] 已重建桌面快捷方式" -ForegroundColor Green
        } elseif ($Kind -eq "unblock") {
            Get-ChildItem -Path $scriptDir -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
            Write-Host "    [修复] 已对目录内全部文件执行 Unblock-File" -ForegroundColor Green
        } elseif ($Kind -eq "pid") {
            $pidFile = Join-Path $logDir "server.pid"
            if (Test-Path $pidFile) { Remove-Item $pidFile -Force; Write-Host "    [修复] 已清理陈旧 server.pid" -ForegroundColor Green }
        }
    } catch {
        Write-Host ("    [修复失败] " + $_.Exception.Message) -ForegroundColor Red
    }
}

if ($Fix) {
    Write-Host ""
    Write-Host "---------- 交互式修复（仅 error/critical，逐项确认） ----------" -ForegroundColor Yellow
    $done = @{}
    foreach ($r in $results) {
        if ($r.status -eq "OK") { continue }
        if ($r.severity -ne "error" -and $r.severity -ne "critical") { continue }
        if (-not $r.fixKind) { continue }
        if ($done.ContainsKey($r.fixKind)) { continue }   # 同类修复只执行一次
        $ans = Read-Host ("是否修复 [$r.id] $r.name ? (y/N)")
        if ($ans -eq "y" -or $ans -eq "Y") {
            Apply-Fix $r.fixKind
            $done[$r.fixKind] = $true
        } else {
            Write-Host ("    跳过 [$r.id] $r.name") -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# =====================================================================
# 输出
# =====================================================================
if ($Json) {
    # 机器可读 JSON
    $out = $results | ForEach-Object {
        [PSCustomObject]@{
            id       = $_.id
            name     = $_.name
            severity = $_.severity
            status   = $_.status
            evidence = $_.evidence
            fix      = $_.fix
        }
    }
    $out | ConvertTo-Json -Depth 3 -Compress
    exit 0
}

# 表格化输出
Write-Host ""
Write-Host ("{0,-5} {1,-14} {2,-8} {3,-5} {4}" -f "编号", "检查项", "严重度", "状态", "证据 / 说明")
Write-Host ("----- -------------- -------- ----- ----------------------------------------")
foreach ($r in $results) {
    $ev = if ($r.evidence) { $r.evidence } else { "-" }
    $color = switch ($r.status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "INFO"  { "Cyan" }
        "FAIL"  { "Red" }
        default { "White" }
    }
    Write-Host ("{0,-5} {1,-14} {2,-8} {3,-5} " -f $r.id, $r.name, $r.severity, $r.status) -NoNewline
    Write-Host $ev
    # 建议修复命令单独缩进一行
    if ($r.fix) {
        Write-Host ("      建议: {0}" -f $r.fix) -ForegroundColor DarkGray
    }
}

# 汇总
$critical = 0; $errorN = 0; $warnN = 0; $infoN = 0
foreach ($r in $results) {
    if ($r.status -eq "OK") { continue }
    switch ($r.severity) {
        "critical" { $critical++ }
        "error"    { $errorN++ }
        "warn"     { $warnN++ }
        "info"     { $infoN++ }
    }
}
Write-Host ""
Write-Host ("汇总: {0} critical / {1} error / {2} warn / {3} info" -f $critical, $errorN, $warnN, $infoN) -ForegroundColor White

# 待修复清单（按严重度降序）
$bad = @($results | Where-Object { $_.status -ne "OK" } | Sort-Object { $sevRank[$_.severity] })
if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "待修复清单（按严重度降序）:" -ForegroundColor Yellow
    foreach ($r in $bad) {
        Write-Host ("  [{0}] {1} ({2}/{3})" -f $r.id, $r.name, $r.severity, $r.status) -ForegroundColor Yellow
        if ($r.evidence) { Write-Host ("      证据: {0}" -f $r.evidence) }
        if ($r.fix)      { Write-Host ("      建议: {0}" -f $r.fix) }
    }
} else {
    Write-Host ""
    Write-Host "未发现异常，环境健康。" -ForegroundColor Green
}

Write-Host ""
