@echo off
REM LC_Coop — sidecar Python en modo servidor dedicado (Windows).
REM Requiere Python 3. El servidor va en server:host:puerto (lc_peer.txt o F9).
REM Uso: run_sidecar_server.bat "C:\...\Voyage\Binaries\Win64"
setlocal
set "DIR=%~1"
if "%DIR%"=="" set "DIR=%~dp0"
python "%~dp0coop_net.py" --peer-file lc_peer.txt --dir "%DIR%"
endlocal
