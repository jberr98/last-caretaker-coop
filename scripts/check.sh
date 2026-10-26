#!/usr/bin/env bash
# Diagnóstico rápido de la instalación de LC_Coop + UE4SS.
set -uo pipefail

GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"
GAME_ROOT="$(dirname "$(dirname "$GAME_BIN")")"        # .../common/Voyage
PREFIX="$HOME/.local/share/Steam/steamapps/compatdata/1783560/pfx"

echo "== 1. Instalación =="
[ -f "$GAME_BIN/dwmapi.dll" ] && echo "  OK  dwmapi.dll" || echo "  FALTA dwmapi.dll  -> corré scripts/install_ue4ss.sh"
[ -d "$GAME_BIN/ue4ss" ] && echo "  OK  ue4ss/" || echo "  FALTA ue4ss/        -> corré scripts/install_ue4ss.sh"
if [ -f "$GAME_BIN/ue4ss/Mods/LC_Coop/Scripts/main.lua" ]; then
    echo "  OK  mod LC_Coop instalado"
else
    echo "  FALTA mod LC_Coop    -> corré scripts/install.sh"
fi
if [ -f "$GAME_BIN/ue4ss/Mods/mods.json" ]; then
    if command -v jq >/dev/null 2>&1; then
        jq -e '.[] | select(.mod_name=="LC_Coop" and .mod_enabled==true)' \
            "$GAME_BIN/ue4ss/Mods/mods.json" >/dev/null 2>&1 \
            && echo "  OK  LC_Coop habilitado en mods.json" \
            || echo "  AVISO: LC_Coop no aparece habilitado en mods.json (corré scripts/install.sh)"
    fi
fi

echo "== 2. ¿Juego corriendo? =="
if pgrep -af "VoyageSteam|Voyage\.exe" | grep -v pgrep >/dev/null 2>&1; then
    pgrep -af "VoyageSteam|Voyage\.exe" | grep -v pgrep | sed 's/^/  /'
else
    echo "  El juego NO está corriendo. Lanzalo desde Steam."
fi

echo "== 3. Log de UE4SS =="
LOG="$(find "$GAME_BIN" "$GAME_ROOT" "$PREFIX" -iname "UE4SS.log" 2>/dev/null | head -1)"
if [ -n "$LOG" ]; then
    echo "  encontrado: $LOG"
    echo "  -- líneas relevantes --"
    grep -iE "LC_Coop|mod_init|error|exception|failed" "$LOG" | tail -25 | sed 's/^/  /'
else
    echo "  No hay UE4SS.log todavía."
    echo "  -> Si el juego está corriendo y aun así no hay log: UE4SS no se inyectó."
    echo "     Probá la build de Nexus: scripts/install_ue4ss.sh /ruta/al/zip-de-Nexus.zip"
fi

echo "== 4. Archivos IPC (coords/event) =="
found="$(find "$GAME_ROOT" "$PREFIX" \( -name "coords_out.txt" -o -name "coords_in.txt" \) 2>/dev/null | head)"
if [ -n "$found" ]; then
    echo "$found" | sed 's/^/  /'
    echo "  -> usá ESA carpeta como --dir del fake peer / sidecar"
else
    echo "  Todavía no hay archivos IPC (aparecen cuando el mod corre y te movés)."
fi
