@echo off
rem Phone / LAN access switcher for DSH Desktop (UAC prompt expected)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lan-access.ps1"
echo.
pause
