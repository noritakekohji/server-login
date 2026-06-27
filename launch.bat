@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0App.ps1"
exit /b 0
