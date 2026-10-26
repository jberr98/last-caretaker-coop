#!/usr/bin/env bash
# Activa el mod LC_Coop (toma efecto al reiniciar el juego).
set -euo pipefail
GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"
MODS="$GAME_BIN/ue4ss/Mods"
sed -i -E 's/^[[:space:]]*LC_Coop[[:space:]]*:.*/LC_Coop : 1/' "$MODS/mods.txt"
if command -v jq >/dev/null 2>&1 && [ -f "$MODS/mods.json" ]; then
    jq '(.[] | select(.mod_name=="LC_Coop") | .mod_enabled) = true' "$MODS/mods.json" > "$MODS/mods.json.tmp" \
        && mv "$MODS/mods.json.tmp" "$MODS/mods.json"
fi
echo "LC_Coop ACTIVADO (reiniciá el juego para que aplique)."
