#!/usr/bin/env bash
# Instala UE4SS dentro de la carpeta del juego.
#   ./install_ue4ss.sh                 -> baja el build experimental de GitHub
#   ./install_ue4ss.sh /ruta/al.zip    -> usa un .zip local (ej. el de Nexus)
#
# Es reversible: borrás "dwmapi.dll" y la carpeta "ue4ss/" de Binaries/Win64.
set -euo pipefail

GAME_BIN="${GAME_BIN:-$HOME/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64}"
ZIP_ARG="${1:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$GAME_BIN" ]; then
    echo "ERROR: no existe la carpeta del juego: $GAME_BIN"
    echo "Ajustá GAME_BIN o verificá la instalación de Steam."
    exit 1
fi

if [ -n "$ZIP_ARG" ]; then
    echo "Usando zip local: $ZIP_ARG"
    cp "$ZIP_ARG" "$TMP/ue4ss.zip"
else
    echo "Buscando el último UE4SS experimental en GitHub..."
    URL="$(curl -s --compressed -A "Mozilla/5.0" \
        "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest" \
        | jq -r '.assets[] | select(.name | test("^UE4SS_v.*\\.zip$")) | .browser_download_url' | head -1)"
    if [ -z "$URL" ] || [ "$URL" = "null" ]; then
        echo "ERROR: no pude obtener la URL del release."
        exit 1
    fi
    echo "Descargando: $URL"
    curl -sL -A "Mozilla/5.0" "$URL" -o "$TMP/ue4ss.zip"
fi

echo "Instalando en: $GAME_BIN"
# backup del dwmapi.dll si ya existía y no es nuestro
if [ -f "$GAME_BIN/dwmapi.dll" ] && [ ! -f "$GAME_BIN/dwmapi.dll.orig" ]; then
    cp "$GAME_BIN/dwmapi.dll" "$GAME_BIN/dwmapi.dll.lc_backup"
    echo "Backup creado: dwmapi.dll.lc_backup"
fi

unzip -oq "$TMP/ue4ss.zip" -d "$GAME_BIN"

echo "UE4SS instalado:"
ls -1 "$GAME_BIN" | grep -iE "dwmapi|ue4ss" | sed 's/^/  - /'
echo
echo "Siguiente: scripts/install.sh (instala el mod LC_Coop)"
