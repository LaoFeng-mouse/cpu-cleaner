@echo off
cd /d "%~dp0"
echo ================================================
echo   Step 1: SCAN (read-only, changes nothing)
echo ================================================
echo.
echo   Scanning... about 10-30 seconds.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpu-cleaner.ps1" -Mode scan
echo.
echo ================================================
echo   Scan finished.
echo   - See "risk score" column and summary section.
echo   - To clean up, run "2-Clean.bat".
echo   Press any key to close...
pause >nul
