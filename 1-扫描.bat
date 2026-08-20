@echo off
cd /d "%~dp0"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0gui-cleaner.ps1"
exit /b %errorlevel%
