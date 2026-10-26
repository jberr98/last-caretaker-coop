#!/bin/sh
# Lanza el sidecar en segundo plano, TOTALMENTE desacoplado del juego/Proton.
#
# Se invoca desde el mod Lua (bajo Proton) con:
#   start /unix /bin/sh /ruta/scripts/launch_sidecar.sh "<carpeta Win64>"
#
# Por qué no se ejecuta python directo desde Wine:
#   `os.execute("start /unix python3 ...")` deja el proceso colgado de la
#   consola que Wine crea para cmd.exe. Esa consola queda visible en segundo
#   plano y Proton/Steam espera a que termine al cerrar el juego.
#   Con setsid + redirección de stdio, el sidecar pasa a ser un proceso
#   independiente (sin terminal) y el juego se puede cerrar normalmente.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SIDECAR="$PROJECT_DIR/sidecar/coop_net.py"

# El mod pasa la carpeta Win64 como $1. Si no, se usa GAME_BIN o el default.
GAME_BIN="${1:-${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}}"
PYTHON="${PYTHON:-/usr/bin/python3}"
LOG="$GAME_BIN/lc_sidecar_launch.log"

# No heredar los preloads de Proton/Steam (gamemode, overlay, etc.).
unset LD_PRELOAD LD_LIBRARY_PATH

if [ ! -f "$SIDECAR" ]; then
    echo "ERROR: no existe $SIDECAR" >>"$LOG" 2>&1
    exit 1
fi
if [ ! -d "$GAME_BIN" ]; then
    echo "ERROR: no existe la carpeta del juego: $GAME_BIN" >>"$LOG" 2>&1
    exit 1
fi

# Si ya hay un sidecar vivo para esta misma carpeta, no lanzar otro.
if pgrep -f "coop_net\.py.*--dir[ =]$GAME_BIN" >/dev/null 2>&1; then
    exit 0
fi

cd "$GAME_BIN" || exit 1

# setsid -f: nueva sesión + fork (no depende de que el padre sea líder).
# stdin/stderr/stdout redirigidos: la consola de Wine puede cerrarse ya.
exec setsid -f "$PYTHON" "$SIDECAR" \
    --peer-file lc_peer.txt \
    --watch-game \
    --dir "$GAME_BIN" \
    >/dev/null 2>>"$LOG" </dev/null
