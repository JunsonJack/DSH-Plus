@echo off
rem DSH Desktop - one-click launcher (hidden PowerShell; minimized flash)
start "" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start-dsh-desktop.ps1"
