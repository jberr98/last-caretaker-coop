#!/usr/bin/env bash
# Pregunta si el otro cliente LC_Coop está escuchando (HELLO/ACK liviano).
#
# Uso:
#   scripts/check_peer.sh <IP-o-nombre> [puerto] [timeout]
#
# Ejemplos:
#   scripts/check_peer.sh 100.64.0.2
#   scripts/check_peer.sh pc-juan 27015 5
#
# Si responde OK, el sidecar del otro lado está escuchando. Si da TIMEOUT,
# revisá firewall/shields-up o que el sidecar esté corriendo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOST="${1:?uso: check_peer.sh <IP-o-nombre> [puerto] [timeout]}"
PORT="${2:-27015}"
TIMEOUT="${3:-3}"

exec python3 "$PROJECT_DIR/sidecar/coop_net.py" \
    --probe "$HOST" --port "$PORT" --probe-timeout "$TIMEOUT"
