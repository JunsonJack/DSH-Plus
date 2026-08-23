# =====================================================================
#  selfheal-shortcut.ps1 — 桌面快捷方式自愈（供计划任务静默调用）
#
#  职责: 登录后检查桌面 "DSH 桌面版.lnk"；缺失 / 损坏 / 目标漂移时
#        自动按当前标准形态（指向入口 bat，防杀软）重建。
#  日志: %LOCALAPPDATA%\DSHDesktop\selfheal.log
#
#  手动运行同样有效:
#    powershell -NoProfile -ExecutionPolicy Bypass -File selfheal-shortcut.ps1
# =====================================================================

param([string]$ShortcutName = "DSH 桌面版")

$ErrorActionPreference = "Continue"
$scriptDir = $PSScriptRoot
$logDir    = Join-Path $env:LOCALAPPDATA "DSHDesktop"
$logFile   = Join-Path $logDir "selfheal.log"
try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {}

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}

. (Join-Path $scriptDir "shortcut-lib.ps1")

$chk = Test-DshShortcutHealthy -ShortcutName $ShortcutName
if ($chk.Healthy) {
    Write-Log ("OK: 快捷方式健康，无需自愈 (" + $chk.Target + ")")
    exit 0
}

Write-Log ("检测到异常(" + $chk.Reason + ")，开始重建 ...")
try {
    $r = New-DshShortcut -ShortcutName $ShortcutName
    Write-Log ("已重建: " + $r.LnkPath + " (形态: " + $r.Form + ")")
    # 温和刷新资源管理器图标缓存（不重启 explorer）
    try { Start-Process ie4uinit.exe -ArgumentList "-show" -WindowStyle Hidden } catch {}
} catch {
    Write-Log ("重建失败: " + $_.Exception.Message)
    exit 1
}
