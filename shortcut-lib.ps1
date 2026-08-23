# =====================================================================
#  shortcut-lib.ps1  —  桌面快捷方式写入/体检的唯一实现（共享库）
#
#  背景：早期版本把 .lnk 直接指向 powershell.exe 并附带
#       "-WindowStyle Hidden -ExecutionPolicy Bypass" 命令行。
#       该特征与恶意 LNK 高度相似，会被杀软（如火绒）静默隔离
#       （不进回收站），造成「桌面快捷方式开机后丢失」。
#       本库统一改为指向入口 DSH桌面版.bat——.lnk 内容完全无害，
#       杀软不再有触发点；代价是双击瞬间约 0.2~0.4 秒控制台闪现。
#
#  使用方（dot-source 本文件）:
#    create-desktop-shortcut.ps1 / switch-dsh-icon.ps1 / selfheal-shortcut.ps1
# =====================================================================

function New-DshShortcut {
    <#
        幂等写入桌面快捷方式，返回 @{ LnkPath / Form / Icon }。
        Form: "bat"(默认, 防杀软) | "powershell"(旧形态, 零闪窗但易被误杀)
    #>
    param(
        [string]$ShortcutName = "DSH 桌面版",
        [string]$IconFile     = "",
        [switch]$DirectPowershell
    )
    $scriptDir = $PSScriptRoot
    $launcher  = Join-Path $scriptDir "start-dsh-desktop.ps1"
    if (-not (Test-Path $launcher)) { throw ("找不到启动器: " + $launcher) }

    # 形态决策: 默认 bat；显式 -DirectPowershell 或 bat 缺失时回退旧形态
    $batPath = Join-Path $scriptDir "DSH桌面版.bat"
    $useBat  = (-not $DirectPowershell) -and (Test-Path $batPath)

    # 图标解析: 显式指定 > 最新 dsh-icon-*.ico > 遗留 whale.ico > Chrome/Edge 兜底
    $iconLoc = ""
    if ($IconFile -and (Test-Path $IconFile)) {
        $iconLoc = "$IconFile,0"
    } else {
        $gen = Get-ChildItem $scriptDir -Filter "dsh-icon-*.ico" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if (-not $gen) {
            $legacyIco = Join-Path $scriptDir "deepseek-whale.ico"
            if (Test-Path $legacyIco) { $gen = $legacyIco }
        }
        if ($gen) {
            $iconLoc = "$gen,0"
        } else {
            foreach ($p in @(
                    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                    "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
                    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
                )) {
                if (Test-Path $p) { $iconLoc = "$p,0"; break }
            }
        }
    }

    $shell   = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkPath = Join-Path $desktop ($ShortcutName + ".lnk")
    $sc = $shell.CreateShortcut($lnkPath)
    if ($useBat) {
        $sc.TargetPath       = $batPath
        $sc.Arguments        = ""
        $sc.WindowStyle      = 7        # 最小化启动，压低 cmd 控制台闪窗感知
    } else {
        $sc.TargetPath       = "powershell.exe"
        $sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
        $sc.WindowStyle      = 1
    }
    $sc.WorkingDirectory = $scriptDir
    $sc.Description      = "一键启动 DeepSeek Harness 桌面版（Chrome 独立窗口）"
    if ($iconLoc) { $sc.IconLocation = $iconLoc }
    $sc.Save()

    return @{
        LnkPath = $lnkPath
        Form    = $(if ($useBat) { "bat" } else { "powershell" })
        Icon    = $iconLoc
    }
}

function Test-DshShortcutHealthy {
    <#
        体检桌面快捷方式，兼容 bat 直指 / powershell -File 两种形态。
        返回 @{ Healthy=bool; Reason=string; Path=string; Target=string }
    #>
    param([string]$ShortcutName = "DSH 桌面版")
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkPath = Join-Path $desktop ($ShortcutName + ".lnk")
    $r = @{ Healthy = $false; Reason = ""; Path = $lnkPath; Target = "" }
    if (-not (Test-Path $lnkPath)) { $r.Reason = "missing"; return $r }
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
        $tp = [string]$sc.TargetPath
        $r.Target = $tp
        if (-not $tp) { $r.Reason = "TargetPath 为空"; return $r }
        if ($tp -match "\.(bat|cmd)$") {
            if (Test-Path $tp) { $r.Healthy = $true } else { $r.Reason = ("目标 bat 不存在: " + $tp) }
            return $r
        }
        if ($tp -match "powershell") {
            $arg = [string]$sc.Arguments
            $m = [regex]::Match($arg, '-File\s+"?([^"]+)"?')
            if (-not $m.Success) { $r.Reason = "Arguments 缺少 -File"; return $r }
            $f = $m.Groups[1].Value.Trim()
            if (Test-Path $f) { $r.Healthy = $true } else { $r.Reason = ("-File 目标不存在: " + $f) }
            return $r
        }
        if (Test-Path $tp) { $r.Healthy = $true } else { $r.Reason = ("目标不存在: " + $tp) }
        return $r
    } catch {
        $r.Reason = "读取异常: " + $_.Exception.Message
        return $r
    }
}
