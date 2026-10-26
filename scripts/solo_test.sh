#!/usr/bin/env bash
# Lanza el fake peer (prueba SOLO, sin segunda máquina).
#   ./solo_test.sh                 -> ghost orbitando (default)
#   ./solo_test.sh --mode mirror --offset 200,0,0
#   ./solo_test.sh --event DOOR,NombrePuerta,1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"

if [ "$#" -eq 0 ]; then
    exec python3 "$PROJECT_DIR/sidecar/fake_peer.py" --dir "$GAME_BIN" --mode orbit --radius 400
fi
exec python3 "$PROJECT_DIR/sidecar/fake_peer.py" --dir "$GAME_BIN" "$@"
