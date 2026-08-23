# =====================================================================
#  create-desktop-shortcut.ps1
#  在桌面创建/更新 "DSH 桌面版" 快捷方式（幂等）
#
#  v2 (2026-08-23): 实现统一移入 shortcut-lib.ps1（创建/换图标/自愈共用）。
#  默认改为【指向入口 DSH桌面版.bat】的防杀软形态——.lnk 内容不再含
#  "powershell -ExecutionPolicy Bypass" 特征命令行，避免被火绒等杀软
#  当作恶意 LNK 静默隔离（本项目曾两次因此「开机后快捷方式丢失」）。
#  代价: 双击瞬间约 0.2~0.4 秒控制台最小化闪现，随后自动隐藏。
#  回退零闪窗旧形态: .\create-desktop-shortcut.ps1 -DirectPowershell
# =====================================================================

param(
    [string]$ShortcutName = "DSH 桌面版",
    [switch]$DirectPowershell
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "shortcut-lib.ps1")

$r = New-DshShortcut -ShortcutName $ShortcutName -DirectPowershell:$DirectPowershell

if ($r.Form -eq "bat") {
    Write-Host ("已创建桌面快捷方式（防杀软形态）: " + $r.LnkPath)
    Write-Host "  指向入口 DSH桌面版.bat；双击时控制台短暂闪现属正常现象。"
} else {
    Write-Host ("已创建桌面快捷方式（直接 powershell 形态）: " + $r.LnkPath)
    Write-Host "  注意: 该形态可能被杀软静默隔离，若再次丢失请改用默认 bat 形态并加入杀软信任区。"
}
if ($r.Icon) { Write-Host ("  图标: " + ($r.Icon -replace ',0$','')) }
