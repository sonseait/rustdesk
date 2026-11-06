@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Right-click Setup.cmd and select Run as administrator.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"
set "RESULT=%ERRORLEVEL%"
pause
exit /b %RESULT%
