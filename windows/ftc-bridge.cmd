@echo off
rem Lets you type `ftc-bridge` in any Windows terminal (install.ps1 puts this folder on PATH).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ftc-bridge.ps1" %*
exit /b %ERRORLEVEL%
