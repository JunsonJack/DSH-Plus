@echo off
rem Stop the dsh web service started by this launcher (if any)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-dsh-desktop.ps1"
echo.
pause
