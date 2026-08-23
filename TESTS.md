# DSH 桌面版 环境自检（doctor.ps1）手工测试用例

> 运行入口：`检查环境.bat`（只读）或 `powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 -Fix`
> 覆盖失败模式 M01–M15。下表为人工构造异常后的期望报告（status 取值：OK / FAIL / WARN / INFO）。

| 用例名 | 人为构造方法 | 期望报告 |
|---|---|---|
| 快捷方式被误删（M01） | 删除桌面 `DSH 桌面版.lnk` | M01=FAIL(error)，证据「桌面不存在 DSH 桌面版.lnk」，建议 `.\创建桌面快捷方式.bat`；汇总 error≥1 |
| 项目被整体移动（M02） | 把 `dsh-desktop` 文件夹改名/移到其他盘，保留桌面 .lnk | M02=FAIL(error)。bat 形态证据「目标 bat 不存在(<新路径>\DSH桌面版.bat)」；powershell 旧形态证据「-File 目标不存在(<新路径>\start-dsh-desktop.ps1)」；M15 可能 WARN |
| 图标文件丢失（M03） | 删除 `dsh-icon-*.ico`（保留 .lnk） | M03=WARN，证据「图标文件不存在(白板图标): <ico 路径)」；双击仍可用，显示白板图标 |
| 桌面落在 OneDrive（M04） | 将用户桌面重定向到 OneDrive 文件夹并断开同步 | M04=WARN，证据含「OneDrive 云端路径」；若路径当前不可访问仍判 WARN |
| 桌面只读（M05） | 对桌面目录取消写入权限 / 将所在盘设为只读 | M05=FAIL(error)，证据「桌面目录不可写(权限不足或磁盘只读)」 |
| 下载带 MOTW（M06） | 从浏览器下载项目 zip 解压，不解除 Web 标记 | M06=FAIL(error)，证据列出带 Zone.Identifier 的 ps1；建议 `Get-ChildItem -Recurse \| Unblock-File` |
| 杀软隔离入口脚本（M11） | 用杀软将 `start-dsh-desktop.ps1` 隔离（文件被清空） | M11=FAIL(critical)，证据「入口脚本被清空(可能为杀软隔离)」 |
| 火绒静默隔离快捷方式（M11） | 桌面无 `.lnk` 且火绒隔离区近30天有载荷记录 | M11=FAIL(critical)，证据「桌面无快捷方式 且 火绒隔离区近30天有记录(...)」。若 `.lnk` 尚在但存在大小相近(±64B)载荷，则降为 M11=WARN 提示加入信任区 |
| 其他用户建了快捷方式（M12） | 在 Public 桌面或另一用户桌面创建同名 .lnk，当前用户桌面无 | M12=WARN，证据「当前用户桌面无快捷方式，但以下位置存在: ...」；建议重建到当前用户 |
| ps1 被转存为无 BOM（M13） | 用记事本另存 `start-dsh-desktop.ps1` 为 UTF-8（无 BOM） | M13=FAIL(error)，证据「启动器缺少 UTF-8 BOM」 |
| portproxy 抢占端口（M14） | `netsh interface portproxy add v4tov4 listenport=3080 listenaddress=0.0.0.0 connectport=3080 connectaddress=127.0.0.1` | M14=WARN，证据「portproxy 0.0.0.0 通配监听占用端口: 3080」 |
| 启动日志有失败痕迹（M10） | 在 `%LOCALAPPDATA%\DSHDesktop\server-3080.err.log` 写入含 `EADDRINUSE` 的报错 | M10=WARN，证据「日志发现启动失败痕迹(...)」 |
| 健康基线（全 OK） | 全新安装、未做任何破坏 | 所有 M=OK，汇总「0 critical / 0 error / 0 warn / 0 info」，输出「未发现异常，环境健康。」 |

## 验证要点

- **只读性**：默认运行 `检查环境.bat` 后，确认桌面 `.lnk`、项目文件、PID 文件均未被改动（仅读取）。
- **-Fix 确认**：带 `-Fix` 运行时，每项 error/critical 修复前必须出现 `是否修复 [Mxx] ... ? (y/N)` 提示；输入 `N` 则跳过且不改动。
- **不中断**：故意制造一项异常（如删除 .lnk），其余检查项仍应正常输出，整体不被异常中断。
- **JSON**：`doctor.ps1 -Json` 应输出单行合法 JSON 数组，含 id/name/severity/status/evidence/fix 字段。
