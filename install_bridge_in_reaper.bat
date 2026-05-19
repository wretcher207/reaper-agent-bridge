@echo off
setlocal
cd /d "%~dp0"
echo REAPER Agent Bridge setup
echo.
echo 1. REAPER will need this script loaded once:
echo    %~dp0bridge\reaper_agent_bridge.lua
echo.
echo 2. In REAPER:
echo    Actions ^> Show action list ^> ReaScript: Load...
echo    Pick reaper_agent_bridge.lua, then run it.
echo.
echo 3. To enable drum jobs for shell-less agents, double-click:
echo    %~dp0start_worker.bat
echo.
echo Opening this project folder and README now.
start "" "%~dp0"
start "" notepad.exe "%~dp0README.md"
pause
