@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
  echo Drag a command JSON file onto this .bat, or run it with a command path.
  echo Example: send_reaper_command.bat commands\examples\get_context.json
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0send_reaper_command.ps1" -CommandPath "%~1" -Wait
pause
