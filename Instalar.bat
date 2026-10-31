@echo off
rem Instalador local de MensorCAD para AutoCAD.
rem Reenvia todas las opciones al mismo Install-MensorCAD.ps1 y conserva el
rem codigo de salida. -ExecutionPolicy Bypass es solo para este proceso.
rem MENSORCAD_BAT_LAUNCHER marca que el lanzamiento viene del doble clic. Si el
rem instalador entrega el resultado a la ventana elevada, este BAT informa el
rem traspaso y termina sin resumen de exito ni pausa (la ventana elevada muestra
rem el final). La marca no evita permisos ni validaciones.
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
set "MENSORCAD_BAT_LAUNCHER=1"
"%MENSORCAD_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MENSORCAD_SCRIPT%" %*
set "MENSORCAD_EXIT=%ERRORLEVEL%"

rem Sentinel privado de entrega: solo lo emite el instalador tras aceptar UAC
rem con una consola dedicada a este BAT. No significa exito de instalacion.
if "%MENSORCAD_EXIT%"=="75" goto :handoff

if not "%MENSORCAD_EXIT%"=="0" (
    echo.
    echo ERROR: La operacion fallo con codigo %MENSORCAD_EXIT%.
) else (
    echo.
    echo Operacion finalizada correctamente.
)

if not defined MENSORCAD_NO_PAUSE pause
exit /b %MENSORCAD_EXIT%

:handoff
echo.
echo La instalacion continua en la ventana elevada.
exit /b 0
