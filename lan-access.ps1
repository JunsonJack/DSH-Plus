# =====================================================================
#  lan-access.ps1  —  DSH 桌面版 手机/局域网访问开关
#
#  原理: dsh web 出于安全设计拒绝绑定 0.0.0.0（避免把 Agent 暴露到局域网），
#        所以保持服务只监听 127.0.0.1，用 Windows 端口转发(portproxy)把流量
#        从本机各局域网 IP:<port> 转回 127.0.0.1:<port>，并写入可信主机记录，
#        让启动器在拉起服务时附带 --trusted-host 参数（否则接口会被 403）。
#        注意: 转发必须按具体 IP 逐条监听，不能用 0.0.0.0 通配——通配监听会
#        占住端口导致 dsh 自己绑不上，每次启动都要白等一轮失败再换端口。
#
#  用法:
#    .\lan-access.ps1                启用（需要 UAC 确认）
#    .\lan-access.ps1 -Disable       停用（移除转发与防火墙规则）
#    .\lan-access.ps1 -Status        查看当前状态
# =====================================================================

param(
    [switch]$EnableCore,
    [switch]$DisableCore,
    [switch]$Disable,
    [switch]$Status
)

$ErrorActionPreference = "Stop"
$markerDir  = Join-Path $env:LOCALAPPDATA "DSHDesktop"
$markerFile = Join-Path $markerDir "lan-trust.txt"
$ruleName   = "DSH Desktop LAN Access"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LanIPs {
    # 纯 .NET 实现，不依赖外部命令；排除环回与链路本地地址
    $ips = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
        Where-Object { $_.AddressFamily -eq "InterNetwork" } |
        Where-Object { -not $_.IPAddressToString.StartsWith("127.") -and -not $_.IPAddressToString.StartsWith("169.254.") } |
        Select-Object -ExpandProperty IPAddressToString -Unique
    return @($ips)
}

function Get-ServingPort {
    # 找出 DSH 正在服务的端口（与启动器同款探测逻辑）
    foreach ($port in @(3080, 3081, 3082)) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri ("http://127.0.0.1:{0}" -f $port) -TimeoutSec 2
            if ($resp.Content -match "__DSH_BOOT__") { return $port }
        } catch {}
    }
    return 3080   # 未运行时按默认端口准备
}

# 解析现有 v4tov4 转发规则（兼容中英文系统，只匹配纯 IP/端口行）
function Get-PortProxyRules {
    $rules = @()
    $out = @(netsh interface portproxy show v4tov4 2>$null)
    foreach ($l in $out) {
        if ($l -match "^\s*(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s*$") {
            $rules += @{ listen = $Matches[1]; lport = [int]$Matches[2]; connect = $Matches[3]; cport = [int]$Matches[4] }
        }
    }
    return ,$rules
}

# 删除指定端口的全部转发规则（含 0.0.0.0 通配与各具体 IP 的历史残留）
function Remove-PortProxyRules([int[]]$ports) {
    foreach ($r in (Get-PortProxyRules)) {
        if ($ports -contains $r.lport) {
            netsh interface portproxy delete v4tov4 listenport=$($r.lport) listenaddress=$($r.listen) | Out-Null
        }
    }
}

function Show-Status {
    Write-Host "== DSH 手机访问状态 =="
    $ips = Get-LanIPs
    $port = Get-ServingPort
    Write-Host (" 本机局域网 IP: " + $(if ($ips) { $ips -join ", " } else { "(未检测到)" }))
    Write-Host (" 服务端口: " + $port)
    $enabled = Test-Path $markerFile
    Write-Host (" 功能状态: " + $(if ($enabled) { "已启用" } else { "未启用" }))
    if ($enabled) {
        foreach ($ip in $ips) { Write-Host (" 手机访问地址: http://" + $ip + ":" + $port) }
    }
    Write-Host ""
    Write-Host " 端口转发规则:"
    try { netsh interface portproxy show v4tov4 2>&1 | ForEach-Object { Write-Host ("   " + $_) } } catch { Write-Host "   （当前环境无法读取，需管理员权限）" }
    Write-Host ""
    Write-Host " 提示: 启用后需重启一次 DSH 服务，接口才能在手机上完全可用。"
}

if ($Status) { Show-Status; exit 0 }

# 交互式入口（双击 bat 且未带参数时）
if (-not ($EnableCore -or $DisableCore -or $Disable)) {
    Write-Host "=========================================="
    Write-Host " DSH 手机 / 局域网访问"
    $ips = Get-LanIPs
    if ($ips) { Write-Host (" 本机局域网 IP: " + ($ips -join ", ")) }
    Write-Host (" 功能状态: " + $(if (Test-Path $markerFile) { "已启用" } else { "未启用" }))
    Write-Host "------------------------------------------"
    Write-Host "  [1] 启用（弹出 UAC 确认）"
    Write-Host "  [2] 停用（弹出 UAC 确认）"
    Write-Host "  [3] 查看状态"
    Write-Host "  [0] 退出"
    Write-Host "=========================================="
    $c = Read-Host "请选择"
    switch ($c) {
        "1" { $EnableCore = $true }
        "2" { $Disable = $true }
        "3" { Show-Status; Read-Host "按回车关闭"; exit 0 }
        default { exit 0 }
    }
}

if (-not (Test-Admin)) {
    # 以管理员身份重新运行自身（触发 UAC），完成后保留窗口展示结果
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    if ($Disable) { $argList += "-DisableCore" } else { $argList += "-EnableCore" }
    Write-Host "需要管理员权限配置端口转发与防火墙，正在弹出 UAC 确认..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}

# ---------------- 以下为管理员上下文 ----------------

if ($DisableCore) {
    Write-Host "== 停用手机访问 =="
    Remove-PortProxyRules @(3080, 3081, 3082)
    netsh advfirewall firewall delete rule name="$ruleName" | Out-Null
    Remove-Item $markerFile -Force -ErrorAction SilentlyContinue
    Write-Host "已移除端口转发与防火墙规则。手机将无法再访问。"
    Read-Host "按回车关闭"
    exit 0
}

if ($EnableCore) {
    Write-Host "== 启用手机访问 =="
    $port = Get-ServingPort
    $ips = Get-LanIPs
    if (-not $ips) { Write-Host "未检测到局域网 IP，无法启用。"; Read-Host "按回车关闭"; exit 1 }

    Write-Host ("1) 配置端口转发（按每个局域网 IP 精确转发 -> 127.0.0.1:$port，不占用 0.0.0.0）...")
    Remove-PortProxyRules @($port)
    foreach ($ip in $ips) {
        netsh interface portproxy add v4tov4 listenport=$port listenaddress=$ip connectaddress=127.0.0.1 connectport=$port | Out-Null
    }

    Write-Host "2) 添加防火墙规则（3080-3082 整段，仅限同一子网访问）..."
    netsh advfirewall firewall delete rule name="$ruleName" | Out-Null
    netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=3080-3082 remoteip=localsubnet | Out-Null

    Write-Host "3) 写入可信主机记录（供启动器附加 --trusted-host）..."
    New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    [System.IO.File]::WriteAllLines($markerFile, $ips)

    Write-Host ""
    Write-Host "已启用！请确保手机与电脑在同一 Wi-Fi/网络下，然后用手机浏览器打开："
    foreach ($ip in $ips) { Write-Host ("   http://" + $ip + ":" + $port) }
    Write-Host ""
    Write-Host "重要提示:"
    Write-Host " - 若当前 DSH 服务正在运行且不是由本启动器拉起的，接口会返回 403，"
    Write-Host "   请重启一次 DSH 服务（下次由启动器拉起时会自动携带可信主机参数）。"
    Write-Host " - 不用时建议双击本脚本选择停用，避免 Agent 暴露在局域网中。"
    Read-Host "按回车关闭"
    exit 0
}
