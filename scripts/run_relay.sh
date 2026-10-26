#!/usr/bin/env bash
# Servidor de coordinación (relay) para LC_Coop.
# Uso: scripts/run_relay.sh [PUERTO]   (default 27020)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PORT="${1:-27020}"
echo "Relay escuchando en :$PORT  (abrí el puerto/ACL si hace falta)"
exec python3 "$PROJECT_DIR/server/relay_server.py" "$PORT"
