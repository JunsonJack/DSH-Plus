@echo off
rem DSH Desktop - one-click launcher (hidden PowerShell, no console window)
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start-dsh-desktop.ps1"
