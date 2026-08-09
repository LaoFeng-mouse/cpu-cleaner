@echo off
cd /d "%~dp0"
echo ================================================
echo   Shushu Cleaner - GUI
echo ================================================
echo   Opening... (window appears in a few seconds)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui-cleaner.ps1"
