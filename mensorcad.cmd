@echo off
setlocal EnableExtensions
set "MENSORCAD_MANAGER_SCRIPT=%~dp0mensorcad.ps1"
set "MENSORCAD_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%MENSORCAD_MANAGER_SCRIPT%" (
  echo ERROR: no se encontro mensorcad.ps1 junto a mensorcad.cmd. 1>&2
  exit /b 1
)
if not exist "%MENSORCAD_POWERSHELL%" (
  echo ERROR: no se encontro Windows PowerShell 5.1 en este equipo. 1>&2
  exit /b 1
)
"%MENSORCAD_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%MENSORCAD_MANAGER_SCRIPT%" %*
exit /b %ERRORLEVEL%
