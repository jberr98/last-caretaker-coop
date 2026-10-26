@echo off
REM LC_Coop - auto-start del sidecar al abrir el juego.
REM Usa Python (sin ventana) si esta instalado; si no, PowerShell (solo P2P).
setlocal
set "DIR=%~1"
if "%DIR%"=="" set "DIR=%~dp0"
if not exist "%~dp0coop_net.py" goto ps

where pythonw >nul 2>nul
if not errorlevel 1 (
    start "" /b pythonw "%~dp0coop_net.py" --peer-file lc_peer.txt --watch-game --dir "%DIR%"
    exit /b 0
)
where pyw >nul 2>nul
if not errorlevel 1 (
    start "" /b pyw -3 "%~dp0coop_net.py" --peer-file lc_peer.txt --watch-game --dir "%DIR%"
    exit /b 0
)
where python >nul 2>nul
if not errorlevel 1 (
    start "" /b python "%~dp0coop_net.py" --peer-file lc_peer.txt --watch-game --dir "%DIR%"
    exit /b 0
)
where py >nul 2>nul
if not errorlevel 1 (
    start "" /b py -3 "%~dp0coop_net.py" --peer-file lc_peer.txt --watch-game --dir "%DIR%"
    exit /b 0
)

:ps
if exist "%~dp0coop_net.ps1" (
    start "" /b powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0coop_net.ps1" -WatchGame -Dir "%DIR%"
)
endlocal
