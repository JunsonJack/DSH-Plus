@echo off
rem Install DSH desktop shortcut self-heal scheduled task (current user, no admin needed)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-selfheal-task.ps1"
pause
