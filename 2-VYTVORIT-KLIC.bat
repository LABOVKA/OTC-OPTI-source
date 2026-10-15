@echo off
chcp 65001 >nul
cd /d "%~dp0"
set /p DAYS=Na kolik dni (napr. 1, 7, 30):
set /p DID=Discord ID zakaznika (Enter = jakykoli ucet):
if "%DID%"=="" (python keygen.py make --days %DAYS%) else (python keygen.py make --days %DAYS% --discord %DID%)
pause
