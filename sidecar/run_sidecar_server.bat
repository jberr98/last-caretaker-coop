@echo off
REM LC_Coop - sidecar Python en modo servidor dedicado (Windows).
REM Requiere Python 3. El servidor va en server:host:puerto (lc_peer.txt o F9).
REM Uso: run_sidecar_server.bat "C:\...\Voyage\Binaries\Win64"
setlocal
set "DIR=%~1"
if "%DIR%"=="" set "DIR=%~dp0"
where python >nul 2>nul
if errorlevel 1 (
    echo ERROR: Python 3 no encontrado en PATH.
    echo Instalalo desde https://www.python.org/downloads/windows/
    echo y marca "Add Python to PATH".
    pause
    exit /b 1
)
echo [LC_Coop] sidecar Python en %DIR%
echo Si el juego ya lanzo el sidecar PowerShell, cerralo primero.
python "%~dp0coop_net.py" --peer-file lc_peer.txt --dir "%DIR%"
endlocal
