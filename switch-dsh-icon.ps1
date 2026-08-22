# =====================================================================
#  switch-dsh-icon.ps1  —  DSH 图标切换器（双图标独立设置版）
#
#  管理两个互相独立的图标:
#    1) 桌面快捷方式图标 (dsh-icon-<hash>.ico)
#    2) 任务栏/独立窗口图标 (DSH 前端 favicon)
#
#  图标库: 把任意 .svg / .png / .ico 文件丢进本目录的 icons\ 即可被识别
#
#  用法:
#    .\switch-dsh-icon.ps1                          交互式菜单（可选目标）
#    .\switch-dsh-icon.ps1 -Name deepseek-blue      两处一起换（兼容旧用法）
#    .\switch-dsh-icon.ps1 -Shortcut deepseek-diy    只换桌面快捷方式图标
#    .\switch-dsh-icon.ps1 -Taskbar deepseek-blue    只换任务栏/窗口图标
#    .\switch-dsh-icon.ps1 -Name C:\xx\logo.png      直接指定文件（两处）
#    .\switch-dsh-icon.ps1 -Reapply                  按记录重新应用(dsh 升级后)
#    .\switch-dsh-icon.ps1 -Restore                  恢复 DSH 出厂原始图标
# =====================================================================

param(
    [string]$Name,
    [string]$Shortcut,
    [string]$Taskbar,
    [switch]$Reapply,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$iconsDir  = Join-Path $scriptDir "icons"
$stateFile = Join-Path $scriptDir "active-icon.txt"
$renderTmp = Join-Path $env:TEMP "dsh-icon-switch"

# 【补丁 A】渲染 SVG 用的浏览器：多候选自动探测（Chrome → Edge → PATH），跨机器不写死路径
function Resolve-HeadlessBrowser {
    foreach ($p in @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
            "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        )) {
        if (Test-Path $p) { return $p }
    }
    foreach ($n in @("chrome", "msedge")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

# Shell API：温和刷新系统图标缓存（不重启资源管理器）
if (-not ("ShellIconNotify" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ShellIconNotify {
    [DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@
}

# ---------------- 工具函数 ----------------

function Get-DistDir {
    # 0) 环境变量逃生口：特殊安装布局时手动指定 dist 路径【补丁 B】
    if ($env:DSH_FRONTEND_DIST -and (Test-Path $env:DSH_FRONTEND_DIST)) { return $env:DSH_FRONTEND_DIST }
    # 1) dsh 在 PATH 中
    $cmd = Get-Command dsh -ErrorAction SilentlyContinue
    if ($cmd) {
        $cand = Join-Path (Split-Path $cmd.Source -Parent) "node_modules\@deepseek-ai\dsh-web-frontend\dist"
        if (Test-Path $cand) { return $cand }
    }
    # 2) nvmd 多版本布局
    $cands = @()
    $nvmdVersions = Join-Path $env:USERPROFILE ".nvmd\versions"
    if (Test-Path $nvmdVersions) {
        Get-ChildItem $nvmdVersions -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $cands += (Join-Path $_.FullName "node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-web-frontend\dist")
        }
    }
    # 3) 常见全局 npm 目录
    $cands += (Join-Path $env:APPDATA "npm\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-web-frontend\dist")
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    throw "未定位到 dsh-web-frontend/dist。请确认 dsh 已安装，或手动修改本函数加入 dist 路径。"
}

function Get-IconSource([string]$name) {
    # 直接文件路径
    if ($name -match "[\\/]" -or $name -match "\.(svg|png|ico)$") {
        $path = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $scriptDir $name }
        if (-not (Test-Path $path)) { return $null }
        $ext = [System.IO.Path]::GetExtension($path).ToLower()
        if (@(".svg", ".png", ".ico") -notcontains $ext) { return $null }
        return @{ name = [System.IO.Path]::GetFileNameWithoutExtension($path); file = $path; ext = $ext }
    }
    # 库内名称 (任意扩展名)
    foreach ($ext in @(".svg", ".png", ".ico")) {
        $f = Join-Path $iconsDir ($name + $ext)
        if (Test-Path $f) { return @{ name = $name; file = $f; ext = $ext } }
    }
    return $null
}

function Get-LibraryIcons {
    if (-not (Test-Path $iconsDir)) { return @() }
    return @(Get-ChildItem $iconsDir -File | Where-Object { $_.Extension.ToLower() -in @(".svg", ".png", ".ico") } | Sort-Object Name)
}

# ---------------- 状态记录 (v2: shortcut=/taskbar= 两行；兼容 v1 单行) ----------------

function Get-State([string]$key) {
    if (-not (Test-Path $stateFile)) { return $null }
    $lines = @(Get-Content $stateFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    foreach ($l in $lines) {
        if ($l -match "^$key=(.+)$") { return $Matches[1].Trim() }
    }
    if ($lines.Count -ge 1 -and $lines[0] -notmatch "=") { return $lines[0].Trim() }  # v1 兼容
    return $null
}

function Set-State([string]$key, [string]$value) {
    $map = @{ shortcut = $null; taskbar = $null }
    if (Test-Path $stateFile) {
        foreach ($l in (Get-Content $stateFile -ErrorAction SilentlyContinue)) {
            if ($l -match "^(shortcut|taskbar)=(.+)$") { $map[$Matches[1]] = $Matches[2].Trim() }
            elseif ($l.Trim() -and $l -notmatch "=") { $map["shortcut"] = $l.Trim(); $map["taskbar"] = $l.Trim() }
        }
    }
    $map[$key] = $value
    # 用 WriteAllLines 确保两行各写一行（Set-Content 数组在此场景会并成一行）
    [System.IO.File]::WriteAllLines($stateFile, @("shortcut=" + $map["shortcut"], "taskbar=" + $map["taskbar"]))
}

# ---------------- 渲染与构建 ----------------

function Render-SvgToPng([string]$svgFile, [string]$outPng) {
    $browser = Resolve-HeadlessBrowser
    if (-not $browser) { throw "找不到可用的 Chrome / Edge，无法渲染 SVG 图标。" }
    # 整文档渲染：保留渐变/滤镜/多元素/圆角底板等全部内容，
    # 只把根节点的 width/height 规范成 256px（兼容 1em / 百分比 / 缺省写法）
    $raw = Get-Content $svgFile -Raw
    $raw = [regex]::Replace($raw, '<\?xml[^>]*\?>\s*', '')
    $raw = [regex]::Replace($raw, '<!DOCTYPE[^>]*>\s*', '', 'IgnoreCase')
    $rootTag = [regex]::Match($raw, '<svg\b[^>]*>').Value
    if (-not $rootTag) { throw "不是有效的 SVG（缺少 <svg> 根标签）。" }
    $viewBox = [regex]::Match($rootTag, 'viewBox\s*=\s*"([^"]*)"').Groups[1].Value
    if (-not $viewBox) { throw "SVG 根标签缺少 viewBox，无法等比渲染。请在根标签加 viewBox（如 viewBox=`"0 0 24 24`"）。" }
    $newRoot = $rootTag
    if ($newRoot -match '\swidth\s*=\s*"[^"]*"') { $newRoot = [regex]::Replace($newRoot, '\swidth\s*=\s*"[^"]*"', ' width="256"') }
    else { $newRoot = $newRoot.Replace('<svg', '<svg width="256"') }
    if ($newRoot -match '\sheight\s*=\s*"[^"]*"') { $newRoot = [regex]::Replace($newRoot, '\sheight\s*=\s*"[^"]*"', ' height="256"') }
    else { $newRoot = $newRoot.Replace('<svg', '<svg height="256"') }
    if ($newRoot -notmatch 'xmlns=') { $newRoot = $newRoot.Replace('<svg', '<svg xmlns="http://www.w3.org/2000/svg"') }
    $newSvg = $raw.Replace($rootTag, $newRoot)
    New-Item -ItemType Directory -Path $renderTmp -Force | Out-Null
    # 关键：先删掉旧产物，避免 Chrome 渲染失败时误用上一次的图
    Remove-Item $outPng -Force -ErrorAction SilentlyContinue
    $guid = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $wrapFile = Join-Path $renderTmp ("render-" + $guid + ".svg")
    [System.IO.File]::WriteAllText($wrapFile, $newSvg, (New-Object System.Text.UTF8Encoding($false)))
    # 每次渲染用全新 profile，避免残留状态干扰
    $ud = Join-Path $renderTmp ("profile-" + $guid)
    New-Item -ItemType Directory -Path $ud -Force | Out-Null
    $url = "file:///" + $wrapFile.Replace("\", "/")
    $args = @("--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
              "--default-background-color=00000000", "--user-data-dir=$ud", "--screenshot=$outPng",
              "--window-size=256,256", $url)
    $proc = Start-Process -FilePath $browser -ArgumentList $args -Wait -PassThru
    Remove-Item $wrapFile -Force -ErrorAction SilentlyContinue
    Remove-Item $ud -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $outPng)) { throw "Chrome 渲染失败(无输出, exit=" + $proc.ExitCode + "): $outPng" }
}

function Convert-IcoToPng([string]$icoFile, [string]$outPng) {
    Add-Type -AssemblyName System.Drawing
    $icon = New-Object System.Drawing.Icon($icoFile)
    $bmp = $icon.ToBitmap()
    $canvas = New-Object System.Drawing.Bitmap(256, 256)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    $w = $bmp.Width; $h = $bmp.Height
    $scale = [Math]::Min(256.0 / $w, 256.0 / $h)
    $dw = [int]($w * $scale); $dh = [int]($h * $scale)
    $g.DrawImage($bmp, [int]((256 - $dw) / 2), [int]((256 - $dh) / 2), $dw, $dh)
    $g.Dispose(); $bmp.Dispose(); $icon.Dispose()
    $canvas.Save($outPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $canvas.Dispose()
}

function New-MultiSizeIco([string]$srcPng, [string]$outIco) {
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Bitmap]::FromFile($srcPng)
    $pngs = New-Object System.Collections.Generic.List[object]
    foreach ($s in @(16, 32, 48, 256)) {
        if ($s -eq 256) { $pngs.Add(@{ size = 256; data = [System.IO.File]::ReadAllBytes($srcPng) }); continue }
        $b = New-Object System.Drawing.Bitmap($s, $s)
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($src, 0, 0, $s, $s)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs.Add(@{ size = $s; data = $ms.ToArray() })
        $ms.Dispose(); $b.Dispose()
    }
    $src.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
    $off = 6 + 16 * $pngs.Count
    foreach ($e in $pngs) {
        $wh = if ($e.size -ge 256) { 0 } else { $e.size }
        $bw.Write([byte]$wh); $bw.Write([byte]$wh); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$e.data.Length); $bw.Write([uint32]$off)
        $off += $e.data.Length
    }
    foreach ($e in $pngs) { $bw.Write($e.data) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($outIco, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

# ---------------- 应用到两个独立目标 ----------------

function Update-Shortcut([string]$iconFile) {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkPath = Join-Path $desktop "DSH 桌面版.lnk"
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = "powershell.exe"
    $sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $scriptDir 'start-dsh-desktop.ps1')`""
    $sc.WorkingDirectory = $scriptDir
    $sc.Description = "一键启动 DeepSeek Harness 桌面版（Chrome 独立窗口）"
    $sc.IconLocation = "$iconFile,0"
    $sc.Save()
}

function Update-Favicon($dist, $source) {
    $fav = Join-Path $dist "favicon.svg"
    if (-not (Test-Path (Join-Path $dist "favicon.svg.orig"))) { Copy-Item $fav (Join-Path $dist "favicon.svg.orig") }
    if (-not (Test-Path (Join-Path $dist "index.html.orig")))   { Copy-Item (Join-Path $dist "index.html") (Join-Path $dist "index.html.orig") }
    if (-not (Test-Path (Join-Path $dist "manifest.webmanifest.orig"))) { Copy-Item (Join-Path $dist "manifest.webmanifest") (Join-Path $dist "manifest.webmanifest.orig") }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if ($source.ext -eq ".svg") {
        Copy-Item $source.file $fav -Force
        Remove-Item (Join-Path $dist "favicon.png") -Force -ErrorAction SilentlyContinue
        $html = [System.IO.File]::ReadAllText((Join-Path $dist "index.html.orig"))
        $manifest = [System.IO.File]::ReadAllText((Join-Path $dist "manifest.webmanifest.orig"))
        [System.IO.File]::WriteAllText((Join-Path $dist "index.html"), $html, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $dist "manifest.webmanifest"), $manifest, $utf8NoBom)
    } else {
        $png = Join-Path $dist "favicon.png"
        if ($source.ext -eq ".png") { Copy-Item $source.file $png -Force }
        else {
            Convert-IcoToPng $source.file (Join-Path $renderTmp "fav.png")
            Copy-Item (Join-Path $renderTmp "fav.png") $png -Force
        }
        $html = [System.IO.File]::ReadAllText((Join-Path $dist "index.html"))
        $html = $html.Replace('<link rel="icon" type="image/svg+xml" href="/favicon.svg" />', '<link rel="icon" type="image/png" href="/favicon.png" />')
        [System.IO.File]::WriteAllText((Join-Path $dist "index.html"), $html, $utf8NoBom)
        $manifest = [System.IO.File]::ReadAllText((Join-Path $dist "manifest.webmanifest"))
        $manifest = $manifest.Replace('"/favicon.svg"', '"/favicon.png"').Replace('"image/svg+xml"', '"image/png"')
        [System.IO.File]::WriteAllText((Join-Path $dist "manifest.webmanifest"), $manifest, $utf8NoBom)
    }
}

function Set-ShortcutIcon($source) {
    # 桌面快捷方式：按内容哈希命名 ico，避开资源管理器「同路径图标缓存」
    if ($source.ext -eq ".svg") {
        New-Item -ItemType Directory -Path $renderTmp -Force | Out-Null
        $png = Join-Path $renderTmp "src.png"
        Render-SvgToPng $source.file $png
        $hashSrc = $png
    } else {
        $hashSrc = $source.file
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash8 = ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($hashSrc)))).Replace("-", "").Substring(0, 8).ToLower()
    $sha.Dispose()
    $icoFile = Join-Path $scriptDir ("dsh-icon-" + $hash8 + ".ico")
    if ($source.ext -eq ".svg") {
        New-MultiSizeIco $png $icoFile
        Remove-Item $png -Force -ErrorAction SilentlyContinue
    } elseif ($source.ext -eq ".png") {
        New-MultiSizeIco $source.file $icoFile
    } else {
        Copy-Item $source.file $icoFile -Force
    }
    Update-Shortcut $icoFile
    Write-Host ("桌面快捷方式图标已更新: " + (Split-Path $icoFile -Leaf))
    Get-ChildItem $scriptDir -Filter "dsh-icon-*.ico" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $icoFile } | Remove-Item -Force -ErrorAction SilentlyContinue
    try { Start-Process ie4uinit.exe -ArgumentList "-show" -WindowStyle Hidden | Out-Null } catch {}
    try { [ShellIconNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) } catch {}
}

function Set-TaskbarIcon($source) {
    $dist = Get-DistDir
    Update-Favicon $dist $source
    Write-Host "任务栏(窗口)图标已更新。"
}

function Restart-AppWindow {
    $pids = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*--user-data-dir=*DSHDesktop*ChromeProfile*" } | Select-Object -ExpandProperty ProcessId)
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    Start-Process powershell.exe -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $scriptDir "start-dsh-desktop.ps1")) | Out-Null
}

function Restore-Original {
    $dist = Get-DistDir
    if (Test-Path (Join-Path $dist "favicon.svg.orig")) {
        Copy-Item (Join-Path $dist "favicon.svg.orig") (Join-Path $dist "favicon.svg") -Force
    }
    if (Test-Path (Join-Path $dist "index.html.orig")) {
        Copy-Item (Join-Path $dist "index.html.orig") (Join-Path $dist "index.html") -Force
    }
    if (Test-Path (Join-Path $dist "manifest.webmanifest.orig")) {
        Copy-Item (Join-Path $dist "manifest.webmanifest.orig") (Join-Path $dist "manifest.webmanifest") -Force
    }
    Remove-Item (Join-Path $dist "favicon.png") -Force -ErrorAction SilentlyContinue
    $fallbackBrowser = Resolve-HeadlessBrowser
    if ($fallbackBrowser) { Update-Shortcut $fallbackBrowser }
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host "已恢复 DSH 出厂原始图标。正在重启窗口..."
    Restart-AppWindow
    Write-Host "完成。"
}

# ---------------- 入口 ----------------

if ($Restore) { Restore-Original; exit 0 }

if ($Reapply) {
    $sName = Get-State "shortcut"; $tName = Get-State "taskbar"
    if (-not $sName -and -not $tName) { Write-Host "没有记录任何图标，请先切换一次。"; exit 1 }
    if ($sName) { $src = Get-IconSource $sName; if ($src) { Set-ShortcutIcon $src } else { Write-Host ("桌面图标源未找到: " + $sName) } }
    if ($tName) { $src = Get-IconSource $tName; if ($src) { Set-TaskbarIcon $src } else { Write-Host ("任务栏图标源未找到: " + $tName) } }
    Restart-AppWindow
    Write-Host "完成（已按记录重新应用）。"
    exit 0
}

if ($Shortcut -or $Taskbar) {
    if ($Shortcut) {
        $src = Get-IconSource $Shortcut
        if (-not $src) { Write-Host ("未找到桌面图标: " + $Shortcut); exit 1 }
        Set-ShortcutIcon $src
        Set-State "shortcut" $src.name
    }
    if ($Taskbar) {
        $src = Get-IconSource $Taskbar
        if (-not $src) { Write-Host ("未找到任务栏图标: " + $Taskbar); exit 1 }
        Set-TaskbarIcon $src
        Set-State "taskbar" $src.name
        Write-Host "正在重启 DSH 桌面版窗口以加载新任务栏图标..."
        Restart-AppWindow
    }
    Write-Host ("完成！当前: 桌面=" + (Get-State "shortcut") + "  任务栏=" + (Get-State "taskbar"))
    exit 0
}

if ($Name) {
    $src = Get-IconSource $Name
    if (-not $src) { Write-Host ("未找到图标: " + $Name + "（可放到 icons\ 目录，或直接给文件路径）"); exit 1 }
    Set-ShortcutIcon $src
    Set-TaskbarIcon $src
    Set-State "shortcut" $src.name
    Set-State "taskbar" $src.name
    Write-Host "正在重启 DSH 桌面版窗口以加载新图标..."
    Restart-AppWindow
    Write-Host ("完成！两处均已应用: " + $src.name)
    exit 0
}

# 交互式菜单
$lib = Get-LibraryIcons
if ($lib.Count -eq 0) {
    Write-Host "图标库为空。请先把 .svg / .png / .ico 文件放进: $iconsDir"
    exit 1
}
Write-Host ""
Write-Host "=========================================="
Write-Host " DSH 图标切换器（桌面 / 任务栏 可分别设置）"
Write-Host (" 桌面快捷方式图标: " + $(Get-State "shortcut"))
Write-Host (" 任务栏(窗口)图标 : " + $(Get-State "taskbar"))
Write-Host " 图标库: $iconsDir"
Write-Host "------------------------------------------"
for ($i = 0; $i -lt $lib.Count; $i++) {
    Write-Host ("  [{0}] {1}" -f ($i + 1), $lib[$i].BaseName)
}
Write-Host "  [0] 退出"
Write-Host "  [r] 恢复 DSH 出厂原始图标"
Write-Host "=========================================="
$choice = Read-Host "请选择图标 (编号或名称)"
if ($choice -eq "0" -or $choice -eq "") { exit 0 }
if ($choice -eq "r" -or $choice -eq "R") { Restore-Original; exit 0 }
$src = $null
if ($choice -match "^\d+$") {
    $idx = [int]$choice - 1
    if ($idx -ge 0 -and $idx -lt $lib.Count) { $src = Get-IconSource $lib[$idx].BaseName }
} else {
    $src = Get-IconSource $choice.Trim()
}
if (-not $src) { Write-Host "无效选择。"; exit 1 }
$target = Read-Host "应用到哪里? [1]桌面+任务栏(默认) [2]仅桌面 [3]仅任务栏"
if ($target -eq "2") {
    Set-ShortcutIcon $src
    Set-State "shortcut" $src.name
    Write-Host ("完成！桌面图标: " + $src.name)
} elseif ($target -eq "3") {
    Set-TaskbarIcon $src
    Set-State "taskbar" $src.name
    Write-Host "正在重启窗口以加载新任务栏图标..."
    Restart-AppWindow
    Write-Host ("完成！任务栏图标: " + $src.name)
} else {
    Set-ShortcutIcon $src
    Set-TaskbarIcon $src
    Set-State "shortcut" $src.name
    Set-State "taskbar" $src.name
    Write-Host "正在重启窗口以加载新任务栏图标..."
    Restart-AppWindow
    Write-Host ("完成！两处均已应用: " + $src.name)
}
