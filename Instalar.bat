@echo off
rem Instalador local de MensorCAD para AutoCAD.
rem Reenvia todas las opciones al mismo Install-MensorCAD.ps1 y conserva el
rem codigo de salida. -ExecutionPolicy Bypass es solo para este proceso.
setlocal EnableExtensions

set "MENSORCAD_SCRIPT=%~dp0Install-MensorCAD.ps1"
if not exist "%MENSORCAD_SCRIPT%" (
    echo ERROR: No se encontro Install-MensorCAD.ps1 junto a Instalar.bat.
    if not defined MENSORCAD_NO_PAUSE pause
    exit /b 1
)

rem Preferir el PowerShell nativo de 64 bits. Desde WOW64, Sysnative evita SysWOW64.
set "MENSORCAD_POWERSHELL=powershell.exe"
if not defined SystemRoot goto :run_installer
set "MENSORCAD_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "MENSORCAD_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%MENSORCAD_POWERSHELL%" goto :run_installer
set "MENSORCAD_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

:run_installer
"%MENSORCAD_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MENSORCAD_SCRIPT%" %*
set "MENSORCAD_EXIT=%ERRORLEVEL%"

if not "%MENSORCAD_EXIT%"=="0" (
    echo.
    echo ERROR: La operacion fallo con codigo %MENSORCAD_EXIT%.
) else (
    echo.
    echo Operacion finalizada correctamente.
)

if not defined MENSORCAD_NO_PAUSE pause
exit /b %MENSORCAD_EXIT%
