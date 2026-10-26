#!/usr/bin/env bash
# Detiene el relay y el bot locales (pruebas en tu PC).
set -uo pipefail
pkill -f "[r]elay_server.py" 2>/dev/null || true
pkill -f "[b]ot_client.py" 2>/dev/null || true
echo "relay/bot detenidos (si estaban corriendo)."
