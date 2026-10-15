@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" goto nocsc

set "SRC=%~dp0"
if exist "%~dp0OtcLoader\Program.cs" set "SRC=%~dp0OtcLoader\"
if not exist "%SRC%Program.cs" goto nosrc
if not exist "%SRC%payload.ps1" goto nosrc

where python >nul 2>nul
if errorlevel 1 goto nopython
python -m pip install cryptography -q

python keygen.py init
if errorlevel 1 goto fail

findstr /C:"PASTE_DISCORD_CLIENT_ID_HERE" "%SRC%Program.cs" >nul
if errorlevel 1 goto skipcid
set "CID="
set /p "CID=Discord Client ID (Enter = bez prihlaseni pres Discord): "
if defined CID python keygen.py discord %CID%
:skipcid

findstr /C:"PASTE_UPDATE_URL_HERE" "%SRC%Program.cs" >nul
if errorlevel 1 goto skipupdate
set "UPDATE_URL="
set /p "UPDATE_URL=HTTPS URL version.json (Enter = auto-update vypnuty): "
if defined UPDATE_URL python keygen.py update "%UPDATE_URL%"
if errorlevel 1 goto fail
:skipupdate

if not exist dist mkdir dist
if exist dist\OTC-OPTI.exe del /f /q dist\OTC-OPTI.exe

echo Stavim dist\OTC-OPTI.exe ...
"%CSC%" /nologo /target:winexe /platform:x86 /optimize+ /out:"dist\OTC-OPTI.exe" /win32icon:"%SRC%otc.ico" /win32manifest:"%SRC%app.manifest" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Security.dll /reference:System.Web.Extensions.dll /resource:"%SRC%payload.ps1",payload.ps1 "%SRC%Program.cs"
if errorlevel 1 goto fail

echo.
python keygen.py check
echo.
echo Hotovo: %CD%\dist\OTC-OPTI.exe  (tohle davejte zakaznikum)
echo Kdyz se nespusti: otevri %%APPDATA%%\OtcLoader\launch.log
pause
exit /b 0

:nocsc
echo Nenalezen kompilator C# .NET Framework 4.x
pause
exit /b 1
:nosrc
echo Chybi Program.cs nebo payload.ps1 - rozbal cely ZIP do jedne slozky.
pause
exit /b 1
:nopython
echo Neni nainstalovan Python (python.org) - pridej ho do PATH.
pause
exit /b 1
:fail
echo.
echo Sestaveni selhalo - poslete mi text chyby vyse.
pause
exit /b 1
