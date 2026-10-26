#!/usr/bin/env bash
# Instala el mod LC_Coop dentro de la carpeta de UE4SS del juego.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"
UE4SS_DIR="$GAME_BIN/ue4ss"
MOD_SRC="$PROJECT_DIR/mods/LC_Coop"
MOD_DST="$UE4SS_DIR/Mods/LC_Coop"

echo "Juego : $GAME_BIN"

if [ ! -d "$UE4SS_DIR" ]; then
    echo "ERROR: no existe $UE4SS_DIR"
    echo "Primero corré: scripts/install_ue4ss.sh"
    exit 1
fi

mkdir -p "$MOD_DST"
cp -r "$MOD_SRC/." "$MOD_DST/"
echo "Mod copiado en: $MOD_DST"

# Personalizar la ruta del proyecto/juego en la copia instalada. El config.lua
# del repo queda con placeholders para que sea portable.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$MOD_DST/Scripts/config.lua" "$PROJECT_DIR" "$GAME_BIN" <<'PY'
import sys

path, project, game = sys.argv[1:4]


def lua_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


text = open(path, encoding="utf-8").read()
text = text.replace("__LC_COOP_PROJECT__", lua_escape(project))
text = text.replace("__LC_COOP_GAME_BIN__", lua_escape(game))
open(path, "w", encoding="utf-8").write(text)
PY
else
    echo "AVISO: python3 no encontrado; editá sidecarCmdLinux en:"
    echo "       $MOD_DST/Scripts/config.lua"
fi

# --- habilitar en mods.txt (formato viejo) ---
MODS_TXT="$UE4SS_DIR/Mods/mods.txt"
touch "$MODS_TXT"
if grep -qE '^[[:space:]]*LC_Coop[[:space:]]*:' "$MODS_TXT"; then
    sed -i -E 's/^[[:space:]]*LC_Coop[[:space:]]*:.*/LC_Coop : 1/' "$MODS_TXT"
else
    printf '\nLC_Coop : 1\n' >> "$MODS_TXT"
fi

# --- habilitar en mods.json (formato nuevo de UE4SS 3.x) ---
MODS_JSON="$UE4SS_DIR/Mods/mods.json"
if [ -f "$MODS_JSON" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.[] | select(.mod_name == "LC_Coop")' "$MODS_JSON" >/dev/null 2>&1; then
        jq '(.[] | select(.mod_name == "LC_Coop") | .mod_enabled) = true' "$MODS_JSON" > "$MODS_JSON.tmp"
    else
        jq '. + [{"mod_name": "LC_Coop", "mod_enabled": true}]' "$MODS_JSON" > "$MODS_JSON.tmp"
    fi
    mv "$MODS_JSON.tmp" "$MODS_JSON"
    echo "Habilitado en Mods/mods.json"
fi
echo "Habilitado en Mods/mods.txt"
echo
echo "Listo. Pasos: 1) lanzá el juego  2) corré scripts/solo_test.sh"
