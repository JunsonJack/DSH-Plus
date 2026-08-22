# =====================================================================
#  stop-dsh-desktop.ps1
#  只关闭由 start-dsh-desktop.ps1 在后台拉起的 dsh web 服务
#  （通过 server.pid 记录 + 校验命令行，绝不会误杀其他 DSH 实例）
# =====================================================================

param([string]$LogDir = (Join-Path $env:LOCALAPPDATA "DSHDesktop"))

$pidFile = Join-Path $LogDir "server.pid"
if (-not (Test-Path $pidFile)) {
    Write-Host "没有由本启动器启动的 DSH 服务（server.pid 不存在），无需关闭。"
    exit 0
}

$serverPid = [int]((Get-Content $pidFile -Raw).Trim())
$proc = Get-CimInstance Win32_Process -Filter "ProcessId=$serverPid" -ErrorAction SilentlyContinue
if (-not $proc -or $proc.CommandLine -notmatch "deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js") {
    Write-Host ("记录的进程 (PID " + $serverPid + ") 已不存在或不是 dsh 服务，清理记录。")
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

# 收集整个进程树并逆序结束（先子后父）
$toKill = New-Object System.Collections.Generic.List[int]
$toKill.Add($serverPid)
$i = 0
while ($i -lt $toKill.Count) {
    $pidNow = $toKill[$i]
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$pidNow" -ErrorAction SilentlyContinue |
        ForEach-Object { $toKill.Add($_.ProcessId) }
    $i++
}
foreach ($p in ($toKill | Sort-Object -Descending)) {
    try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {}
}
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Write-Host ("已停止 DSH 服务 (PID " + $serverPid + " 及其子进程)。")
