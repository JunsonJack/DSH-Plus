@echo off
rem Remove DSH desktop shortcut self-heal scheduled task
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-selfheal-task.ps1" -Remove
pause
