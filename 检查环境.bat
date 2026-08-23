@echo off
rem DSH Desktop environment self-check (read-only diagnostics, no changes made)
rem Usage: double-click to run doctor.ps1; add -Fix for interactive repair
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
echo.
pause
