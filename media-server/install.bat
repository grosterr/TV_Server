@echo off
REM Torlamp — double-click launcher for the Windows installer.
REM Runs install.ps1 with a relaxed execution policy for this process only.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
