#!/usr/bin/env bash
# Prueba SOLO (una PC): levanta el relay + un bot que orbita tu posición.
# Después, en el juego: F9 -> escribí  relay:127.0.0.1:27020  -> Conectar.
# Uso: scripts/relay_test.sh [PUERTO]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"
PORT="${1:-27020}"

ORIGIN="$(head -1 "$GAME_BIN/coords_out.txt" 2>/dev/null | cut -d, -f1-3 || true)"
[ -z "$ORIGIN" ] && ORIGIN="0,0,0"

echo "== Relay en 127.0.0.1:$PORT =="
python3 "$PROJECT_DIR/server/relay_server.py" "$PORT" &
RELAY=$!
sleep 0.5
echo "== Bot orbitando alrededor de $ORIGIN =="
python3 "$PROJECT_DIR/server/bot_client.py" --server "127.0.0.1:$PORT" --origin "$ORIGIN" --radius 400 &
BOT=$!
trap 'kill $RELAY $BOT 2>/dev/null || true' EXIT
echo
echo "En el juego: F9 -> escribí  relay:127.0.0.1:$PORT  -> Conectar.  Ctrl+C para salir."
wait
