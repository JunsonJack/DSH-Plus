# =====================================================================
#  install-selfheal-task.ps1 — 注册/卸载「快捷方式登录自愈」计划任务
#
#  任务名: DshDesktopShortcutSelfHeal
#  触发  : 当前用户登录后延迟 1 分钟（避开开机杀软扫描高峰）
#  动作  : 隐藏窗口运行 selfheal-shortcut.ps1
#  权限  : 仅当前用户，无需管理员
#  幂等  : 重复安装覆盖旧任务
#
#  用法:
#    .\install-selfheal-task.ps1            注册
#    .\install-selfheal-task.ps1 -Remove    卸载
# =====================================================================

param([switch]$Remove)

$ErrorActionPreference = "Stop"
$taskName    = "DshDesktopShortcutSelfHeal"
$selfhealPs1 = Join-Path $PSScriptRoot "selfheal-shortcut.ps1"

if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host ("已删除计划任务: " + $taskName)
    } else {
        Write-Host ("计划任务不存在，无需删除: " + $taskName)
    }
    exit 0
}

if (-not (Test-Path $selfhealPs1)) {
    Write-Host ("找不到自愈脚本: " + $selfhealPs1)
    exit 1
}

$userId = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"" + $selfhealPs1 + "`"")

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$trigger.Delay = "PT1M"   # ISO8601 时长: 登录后延迟 1 分钟

$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ("已注册计划任务: " + $taskName)
Write-Host ("  触发 : " + $userId + " 登录后 1 分钟")
Write-Host "  动作 : 隐藏运行 selfheal-shortcut.ps1（快捷方式缺失/损坏时自动重建）"
Write-Host "  日志 : %LOCALAPPDATA%\DSHDesktop\selfheal.log"
Write-Host "  提示 : 若安全软件弹窗询问新增计划任务，请选择允许。"
Write-Host "  卸载 : .\install-selfheal-task.ps1 -Remove 或双击 卸载自愈任务.bat"
