# =====================================================================
#  start-dsh-desktop.ps1
#  DSH 桌面版 一键启动器
#  1. 探测 DSH Web 服务（默认 127.0.0.1:3080）是否已就绪
#  2. 未就绪则后台启动 `dsh web`（隐藏窗口，--no-open 不自动开浏览器）
#  3. 就绪后打开一个 Chrome 独立 App 窗口（无地址栏/标签页，外观如桌面 App）
#
#  用法:
#    powershell -NoProfile -ExecutionPolicy Bypass -File start-dsh-desktop.ps1
#  可选参数:
#    -Ports 3080,3081       依次探测/尝试的端口
#    -ChromePath <exe>      指定浏览器（默认自动查找 Chrome/Edge）
#    -Width / -Height       窗口尺寸（默认 1440x900）
#    -Maximized             以最大化方式打开窗口
# =====================================================================

param(
    [int[]]   $Ports      = @(3080, 3081, 3082),                 # 依次探测/尝试的端口
    [string]  $ChromePath = "",                                  # 留空则自动查找
    [int]     $Width      = 1440,
    [int]     $Height     = 900,
    [switch]  $Maximized,
    [string]  $LogDir     = (Join-Path $env:LOCALAPPDATA "DSHDesktop"),
    [string]  $ProfileDir = (Join-Path $env:LOCALAPPDATA "DSHDesktop\ChromeProfile"),
    [string]  $WorkingDir = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"

$logFile = Join-Path $LogDir "start.log"
try { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } catch {}

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}

function Show-Error([string]$msg) {
    Write-Log ("ERROR: " + $msg)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($msg, "DSH Desktop", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
        Write-Host ("ERROR: " + $msg)
        Read-Host "Press Enter to exit..."
    }
    exit 1
}

# --- 探测端口: 返回 @{status='dsh'|'busy'|'free'; url=...} ---
function Probe-Port([int]$port) {
    $url = "http://127.0.0.1:{0}" -f $port
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2
        if ($resp.Content -match "__DSH_BOOT__") { return @{ status = "dsh";  url = $url } }
        return @{ status = "busy"; url = $url }
    } catch {
        return @{ status = "free"; url = $url }
    }
}

# --- 解析 dsh 启动方式（避免依赖 PATH 失效） ---
function Resolve-DshLaunch {
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) {
        $src = $cmd.Source
        $base = Split-Path $src -Parent
        if ($src -like "*.ps1") {
            # npm/nvmd 风格垫片: 同目录 node.exe + node_modules/@deepseek-ai/dsh/lib/bin.js
            $node = Join-Path $base "node.exe"
            if (-not (Test-Path $node)) {
                $g = Get-Command node -ErrorAction SilentlyContinue
                if ($g) { $node = $g.Source }
            }
            $js = Join-Path $base "node_modules\@deepseek-ai\dsh\lib\bin.js"
            if (Test-Path $js) { return @{ kind = "node"; node = $node; js = $js } }
        } elseif ($src -like "*.cmd" -or $src -like "*.exe" -or $src -like "*.bat") {
            return @{ kind = "exe"; file = $src; args = @() }
        }
    }
    # 回退: nvmd 全局垫片
    $nvmd = Join-Path $env:USERPROFILE ".nvmd\bin\dsh.cmd"
    if (Test-Path $nvmd) { return @{ kind = "exe"; file = $nvmd; args = @() } }
    return $null
}

# --- 查找浏览器: Chrome 优先，Edge 兜底 ---
function Resolve-Browser {
    if ($ChromePath -and (Test-Path $ChromePath)) { return $ChromePath }
    $cands = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

# ================= 主流程 =================
Write-Log "== DSH Desktop launcher started =="

$targetUrl = $null
$serverPidFile = Join-Path $LogDir "server.pid"

foreach ($port in $Ports) {
    $probe = Probe-Port $port
    if ($probe.status -eq "dsh") {
        $targetUrl = $probe.url
        Write-Log ("port " + $port + ": DSH 已在运行 -> " + $targetUrl)
        break
    }
    if ($probe.status -eq "busy") {
        Write-Log ("port " + $port + ": 被其他服务占用，跳过")
        continue
    }

    Write-Log ("port " + $port + ": 空闲，后台启动 dsh web ...")
    $launch = Resolve-DshLaunch
    if (-not $launch) {
        Show-Error "找不到 dsh 命令。请先安装 DeepSeek Harness，并确保 dsh 在 PATH 中。"
    }

    if ($launch.kind -eq "node") {
        $argsList = @($launch.js, "web", "--no-open", "--port", "$port")
        $proc = Start-Process -FilePath $launch.node -ArgumentList $argsList `
            -WindowStyle Hidden -WorkingDirectory $WorkingDir `
            -RedirectStandardOutput (Join-Path $LogDir ("server-" + $port + ".out.log")) `
            -RedirectStandardError  (Join-Path $LogDir ("server-" + $port + ".err.log")) `
            -PassThru
    } else {
        $argsList = @("web", "--no-open", "--port", "$port")
        $proc = Start-Process -FilePath $launch.file -ArgumentList $argsList `
            -WindowStyle Hidden -WorkingDirectory $WorkingDir -PassThru
    }
    Write-Log ("dsh web 已启动 (PID " + $proc.Id + ")，等待服务就绪 ...")

    $deadline = (Get-Date).AddSeconds(90)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        $p = Probe-Port $port
        if ($p.status -eq "dsh") { $ok = $true; $targetUrl = $p.url; break }
        if ($p.status -eq "busy") { Write-Log ("port " + $port + ": 启动期间被其他进程占用"); break }
        if ($proc.HasExited) { Write-Log ("dsh web 进程提前退出，退出码 " + $proc.ExitCode); break }
    }
    if ($ok) {
        # 记录由本启动器拉起的服务 PID，供关闭脚本使用
        try { Set-Content -Path $serverPidFile -Value ($proc.Id.ToString()) -Encoding UTF8 } catch {}
        break
    }
    if (-not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
}

if (-not $targetUrl) {
    Show-Error ("无法启动 DSH Web 服务。请查看日志: " + $logFile)
}
Write-Log ("DSH 服务就绪: " + $targetUrl)

# ---------- 打开 Chrome 独立窗口 ----------
$browser = Resolve-Browser
if (-not $browser) { Show-Error "找不到 Chrome / Edge。可通过 -ChromePath 参数指定浏览器路径。" }
Write-Log ("浏览器: " + $browser)

try { New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null } catch {}

# 已存在本启动器的 App 窗口时，将其带到前台而不是重复开窗
$existing = $null
try {
    $existing = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -like "*--user-data-dir=$ProfileDir*" -and $_.CommandLine -like "*--app=*" } |
        Select-Object -First 1
} catch {}

if ($existing) {
    Write-Log ("App 窗口已在运行 (PID " + $existing.ProcessId + ")，尝试带到前台")
    try { $null = (New-Object -ComObject WScript.Shell).AppActivate($existing.ProcessId) } catch {}
    exit 0
}

# 窗口居中
$windowPos = "120,80"
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $wx = [Math]::Max(0, [Math]::Round(($wa.Width  - $Width)  / 2))
    $wy = [Math]::Max(0, [Math]::Round(($wa.Height - $Height) / 2))
    $windowPos = "$wx,$wy"
} catch {}

$chromeArgs = @(
    "--app=$targetUrl",
    "--user-data-dir=$ProfileDir",
    "--window-size=$Width,$Height",
    "--window-position=$windowPos",
    "--no-first-run",
    "--no-default-browser-check"
)
if ($Maximized) { $chromeArgs += "--start-maximized" }

try {
    Start-Process -FilePath $browser -ArgumentList $chromeArgs | Out-Null
    Write-Log ("已打开 Chrome App 窗口: " + $targetUrl)
} catch {
    Show-Error ("启动浏览器失败: " + $_.Exception.Message)
}
