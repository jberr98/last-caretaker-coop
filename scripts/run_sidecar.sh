#!/usr/bin/env bash
# Lanza el sidecar apuntando a la carpeta del juego (uso manual).
#   run_sidecar.sh            -> IP dinámica (lee lc_peer.txt, que el juego escribe)
#   run_sidecar.sh <IP>       -> IP fija
# Sale solo cuando se cierra el juego (--watch-game).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"
SIDECAR="$PROJECT_DIR/sidecar/coop_net.py"

if [ -n "${1:-}" ]; then
    exec python3 "$SIDECAR" --peer "$1" --port "${2:-27015}" --watch-game --dir "$GAME_BIN"
else
    exec python3 "$SIDECAR" --peer-file lc_peer.txt --watch-game --dir "$GAME_BIN"
fi
