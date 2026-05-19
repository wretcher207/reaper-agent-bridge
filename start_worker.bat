@echo off
setlocal
cd /d "%~dp0"
start "REAPER Agent Bridge Worker" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0worker\job_worker.ps1"
exit /b 0
