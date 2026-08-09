@echo off
cd /d "%~dp0"
echo ================================================
echo   CPU Cleaner - GUI (Mouse Style)
echo ================================================
echo   Opening the graphical interface...
echo   (The window may take a few seconds to appear)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui-cleaner.ps1"
