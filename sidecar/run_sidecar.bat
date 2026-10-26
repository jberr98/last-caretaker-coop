@echo off
REM LC_Coop — sidecar en PowerShell (Windows). Ejecutar en la carpeta del juego.
REM Uso:  run_sidecar.bat "C:\...\Voyage\Binaries\Win64"
setlocal
set "DIR=%~1"
if "%DIR%"=="" set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0coop_net.ps1" -Dir "%DIR%"
endlocal
