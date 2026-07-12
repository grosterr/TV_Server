@echo off
REM Torlamp — just double-click this file to install.
REM Thin launcher: runs the guided installer in media-server\.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0media-server\install.ps1"
echo.
pause
