# =====================================================================
#  create-desktop-shortcut.ps1
#  在桌面创建 "DSH 桌面版" 快捷方式（隐藏窗口运行启动器）
#  图标: 优先使用本目录 deepseek-whale.ico（DeepSeek 官方鲸鱼），
#        没有则退回 Chrome / Edge 自带图标
# =====================================================================

param([string]$ShortcutName = "DSH 桌面版")

$ErrorActionPreference = "Stop"
$launcher = Join-Path $PSScriptRoot "start-dsh-desktop.ps1"
if (-not (Test-Path $launcher)) {
    Write-Host ("找不到启动器: " + $launcher)
    exit 1
}

$shell   = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop ($ShortcutName + ".lnk")

$sc = $shell.CreateShortcut($lnkPath)
$sc.TargetPath       = "powershell.exe"
$sc.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
$sc.WorkingDirectory = $PSScriptRoot
$sc.Description      = "一键启动 DeepSeek Harness 桌面版（Chrome 独立窗口）"

# 图标: 最新生成的 dsh-icon-*.ico 优先（由 switch-dsh-icon.ps1 按内容哈希生成），
#       其次遗留的 deepseek-whale.ico，最后 Chrome/Edge 兜底
$whaleIco = Get-ChildItem $PSScriptRoot -Filter "dsh-icon-*.ico" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $whaleIco) {
    $legacy = Join-Path $PSScriptRoot "deepseek-whale.ico"
    if (Test-Path $legacy) { $whaleIco = $legacy }
}
if ($whaleIco -and (Test-Path $whaleIco)) {
    $sc.IconLocation = "$whaleIco,0"
} else {
    foreach ($p in @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        )) {
        if (Test-Path $p) { $sc.IconLocation = "$p,0"; break }
    }
}

$sc.Save()
Write-Host ("已创建桌面快捷方式: " + $lnkPath)
