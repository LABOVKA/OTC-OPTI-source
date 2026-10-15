@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 goto nopython

python build_setup.py
if errorlevel 1 goto fail

echo.
echo Hotovo. Instalator OTC-OPTI-Setup-Admin.exe najdete v dist.
pause
exit /b 0

:nopython
echo Pro sestaveni instalatoru je potreba Python 3 dostupny v PATH.
pause
exit /b 1

:fail
echo Sestaveni instalatoru selhalo.
pause
exit /b 1
