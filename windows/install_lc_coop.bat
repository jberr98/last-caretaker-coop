@echo off
REM Instala el mod LC_Coop en la carpeta de UE4SS del juego.
REM Uso:  install_lc_coop.bat "C:\...\Voyage\Binaries\Win64"
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_lc_coop.ps1" %*
endlocal
