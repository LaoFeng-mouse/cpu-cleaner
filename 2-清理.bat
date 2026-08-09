@echo off
cd /d "%~dp0"
echo ================================================
echo   Step 2: CLEAN (needs administrator)
echo ================================================
echo.
echo   A User Account Control window will pop up.
echo   Click YES.
echo.
echo   In the new window:
echo     - type  all  + Enter  = process everything
echo     - or type numbers like 0 or 0,2
echo   Every action is backed up first.
echo   To undo later, run "3-Restore.bat".
echo.
pause
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0cpu-cleaner.ps1','-Mode','clean'"
echo.
echo   Done. Check the result, then restart your PC.
echo   Press any key to close...
pause >nul
