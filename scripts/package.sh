#!/usr/bin/env bash
# Empaqueta el mod + sidecar + instaladores Windows en un .zip.
# (Usa python3 para el zip, así no requiere el binario `zip`.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT="${1:-$PROJECT_DIR/LC_Coop-package.zip}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/LC_Coop"
cp -r "$PROJECT_DIR/mods" "$STAGE/LC_Coop/"
cp -r "$PROJECT_DIR/sidecar" "$STAGE/LC_Coop/"
[ -d "$PROJECT_DIR/windows" ] && cp -r "$PROJECT_DIR/windows" "$STAGE/LC_Coop/"
[ -d "$PROJECT_DIR/server" ] && cp -r "$PROJECT_DIR/server" "$STAGE/LC_Coop/"
# El egg de Pelican también en la raíz del paquete, para subirlo directo.
[ -f "$PROJECT_DIR/server/pelican/egg-lc-coop-coordination-server.json" ] && \
    cp "$PROJECT_DIR/server/pelican/egg-lc-coop-coordination-server.json" "$STAGE/LC_Coop/"
[ -f "$PROJECT_DIR/README.md" ] && cp "$PROJECT_DIR/README.md" "$STAGE/LC_Coop/README.md"
[ -f "$PROJECT_DIR/README.es.md" ] && cp "$PROJECT_DIR/README.es.md" "$STAGE/LC_Coop/README.es.md"
[ -f "$PROJECT_DIR/README.es.md" ] && cp "$PROJECT_DIR/README.es.md" "$STAGE/LC_Coop/LEEME.md"
[ -f "$PROJECT_DIR/LICENSE" ] && cp "$PROJECT_DIR/LICENSE" "$STAGE/LC_Coop/LICENSE"
[ -f "$PROJECT_DIR/NOTICE" ] && cp "$PROJECT_DIR/NOTICE" "$STAGE/LC_Coop/NOTICE"

# Limpiar artefactos de Python
find "$STAGE" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Instalador de doble clic en la raíz del paquete (Windows).
cat > "$STAGE/LC_Coop/INSTALAR.bat" <<'EOF'
@echo off
title Instalador LC_Coop
echo ============================================
echo   LC_Coop - Instalador (Windows)
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\install_lc_coop.ps1"
echo.
echo ============================================
echo   Listo. Revisa los mensajes de arriba.
echo ============================================
pause
EOF

python3 - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(stage):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, stage))
print("Paquete:", out)
with zipfile.ZipFile(out) as z:
    for n in z.namelist():
        print("  " + n)
PY
