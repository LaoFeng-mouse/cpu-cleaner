@echo off
cd /d "%~dp0"
echo ================================================
echo   Step 3: RESTORE (undo last changes)
echo ================================================
echo.
echo   Your backups (in "backups" folder):
echo.
dir /b "%~dp0backups" 2>nul
if errorlevel 1 (
    echo   [No backup found - nothing to restore]
    echo.
    pause >nul
    exit /b 1
)
echo.
set /p BD=Type backup name (e.g. 20260809_120000) and press Enter:
if "%BD%"=="" (
    echo   Nothing typed, cancelled.
    echo.
    pause >nul
    exit /b 1
)
echo.
echo   A User Account Control window will pop up. Click YES.
echo.
pause
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0cpu-cleaner.ps1','-Mode','restore','-BackupDir','%~dp0backups\%BD%'"
echo.
echo   Restored. Check the result.
echo   Press any key to close...
pause >nul
