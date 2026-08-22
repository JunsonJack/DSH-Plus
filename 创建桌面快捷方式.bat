@echo off
rem Create a desktop shortcut for DSH Desktop (run once, idempotent)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0create-desktop-shortcut.ps1"
echo.
pause
