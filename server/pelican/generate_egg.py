#!/usr/bin/env python3
"""Genera el egg de Pelican para el servidor de coordinación de LC_Coop.

El egg es un bootstrap: descarga `server/pelican/install.sh` desde el repositorio
y lo ejecuta. El instalador remoto baja la fuente (o un binario ya compilado) y
compila el servidor. Así el egg no queda atado a una copia embebida del código.

Uso:
    python3 server/pelican/generate_egg.py
    # escribe server/pelican/egg-lc-coop-coordination-server.json

El UUID es fijo para que reimportar el egg actualice el mismo registro.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_PATH = HERE / "egg-lc-coop-coordination-server.json"

RAW_URL = "https://raw.githubusercontent.com/jberr98/last-caretaker-coop/main"
INSTALL_URL = f"{RAW_URL}/server/pelican/install.sh"
EGG_URL = f"{RAW_URL}/server/pelican/egg-lc-coop-coordination-server.json"

EGG_UUID = "4f6c1d2a-8b3e-4c7a-9d61-5e2b0a7c9f14"
EGG_NAME = "LC_Coop Coordination Server"
EGG_AUTHOR = "33329664+jberr98@users.noreply.github.com"


def build_install_script() -> str:
    return f"""#!/bin/bash
# LC_Coop — bootstrap del egg de Pelican.
# Descarga el instalador versionado en el repositorio y lo ejecuta.
set -euo pipefail

cd /mnt/server

PREFIX="[lc-coop-install]"
log() {{ echo "$PREFIX $*"; }}

INSTALL_URL="${{LC_COOP_INSTALL_URL:-{INSTALL_URL}}}"
INSTALL_FILE="/tmp/lc-coop-install.sh"

if ! command -v curl >/dev/null 2>&1; then
    log "instalando curl"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl ca-certificates
fi

log "descargando instalador: $INSTALL_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$INSTALL_FILE" "$INSTALL_URL"

if [ ! -s "$INSTALL_FILE" ] || ! head -n 1 "$INSTALL_FILE" | grep -q '^#!'; then
    log "ERROR: el instalador descargado está vacío o no es un script"
    exit 1
fi

export DEST="${{DEST:-/mnt/server}}"
log "ejecutando instalador (DEST=$DEST)"
bash "$INSTALL_FILE"
"""


def build_egg(install_script: str) -> dict:
    # Nota: config.files/startup/logs son strings que contienen JSON, no objetos.
    startup_detect = json.dumps({"done": "escuchando en"}, indent=4)
    return {
        "_comment": (
            "Egg generado por server/pelican/generate_egg.py. "
            "No editar a mano: cambiá el generador y regenerá."
        ),
        "meta": {
            "version": "PLCN_v1",
            "update_url": EGG_URL,
        },
        "exported_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "name": EGG_NAME,
        "author": EGG_AUTHOR,
        "uuid": EGG_UUID,
        "description": (
            "Servidor dedicado de coordinación para el mod LC_Coop de "
            "The Last Caretaker. Guarda posiciones por área/dimensión, puertas "
            "y contenedores en un save.json propio, y coordina a los clientes. "
            "NO hostea el mundo del juego: cada jugador corre su partida. "
            "Los clientes se conectan con server:IP:PUERTO (UDP). "
            "La instalación descarga el instalador y la fuente desde "
            "github.com/jberr98/last-caretaker-coop y compila el binario Rust. "
            "Para usar un binario ya compilado, definí LC_COOP_BINARY_URL. "
            "Licencia: GPL-3.0-or-later (copyleft; ver LICENSE en el repositorio)."
        ),
        "tags": [
            "lc-coop",
            "the-last-caretaker",
            "coordination",
            "rust",
        ],
        "features": [],
        "docker_images": {
            "Debian 13 (recomendado)": "ghcr.io/pelican-eggs/yolks:debian",
            "Alpine (binario estático)": "ghcr.io/pelican-eggs/yolks:alpine",
        },
        "file_denylist": [],
        "startup": (
            "./lc-coop-server --port {{SERVER_PORT}} "
            "--save {{SAVE_FILE}} "
            '--name "{{SERVER_NAME}}" '
            "--timeout {{TIMEOUT}} "
            "--state-hz {{STATE_HZ}} "
            "--save-interval {{SAVE_INTERVAL}} "
            "{{EXTRA_ARGS}}"
        ),
        "config": {
            "files": "{}",
            "startup": startup_detect,
            "logs": "{}",
            "stop": "^SIGTERM",
        },
        "scripts": {
            "installation": {
                "script": install_script,
                "container": "rust:slim",
                "entrypoint": "bash",
            }
        },
        "variables": [
            {
                "sort": 1,
                "name": "Nombre del servidor",
                "description": (
                    "Nombre visible que reciben los clientes del mod (ACK/STATE)."
                ),
                "env_variable": "SERVER_NAME",
                "default_value": "LC_Coop Server",
                "user_viewable": True,
                "user_editable": True,
                "rules": [
                    "required",
                    "string",
                    "max:48",
                    "regex:~^[A-Za-z0-9 _.,:-]+$~",
                ],
            },
            {
                "sort": 2,
                "name": "URL de binario (opcional)",
                "description": (
                    "Si la completás, la instalación descarga ese binario Linux "
                    "ya compilado en vez de compilar desde la fuente. Tiene que "
                    "ser un ELF para la arquitectura del nodo (x86_64 o arm64). "
                    "Dejalo vacío para compilar desde el repositorio."
                ),
                "env_variable": "LC_COOP_BINARY_URL",
                "default_value": "",
                "user_viewable": True,
                "user_editable": True,
                "rules": ["string", "max:512"],
            },
            {
                "sort": 3,
                "name": "Archivo de save",
                "description": (
                    "Ruta del save JSON, relativa a /home/container. "
                    "No se borra al reinstalar."
                ),
                "env_variable": "SAVE_FILE",
                "default_value": "save.json",
                "user_viewable": True,
                "user_editable": True,
                "rules": [
                    "required",
                    "string",
                    "max:96",
                    "regex:~^(?!.*\\.\\.)(?!/)[A-Za-z0-9._/-]+$~",
                ],
            },
            {
                "sort": 4,
                "name": "Timeout de clientes",
                "description": (
                    "Segundos sin actividad para marcar a un cliente como "
                    "desconectado."
                ),
                "env_variable": "TIMEOUT",
                "default_value": "30",
                "user_viewable": True,
                "user_editable": True,
                "rules": ["required", "integer", "between:5,600"],
            },
            {
                "sort": 5,
                "name": "STATE por segundo",
                "description": (
                    "Frecuencia (Hz) con la que el servidor manda el estado a "
                    "los clientes."
                ),
                "env_variable": "STATE_HZ",
                "default_value": "15",
                "user_viewable": True,
                "user_editable": True,
                "rules": ["required", "integer", "between:1,60"],
            },
            {
                "sort": 6,
                "name": "Intervalo de guardado",
                "description": (
                    "Cada cuántos segundos se escribe el save.json si hubo "
                    "cambios."
                ),
                "env_variable": "SAVE_INTERVAL",
                "default_value": "1",
                "user_viewable": True,
                "user_editable": True,
                "rules": ["required", "integer", "between:1,300"],
            },
            {
                "sort": 7,
                "name": "Argumentos extra",
                "description": (
                    "Argumentos adicionales para lc-coop-server (opcional)."
                ),
                "env_variable": "EXTRA_ARGS",
                "default_value": "",
                "user_viewable": True,
                "user_editable": True,
                "rules": ["string", "max:256"],
            },
        ],
    }


def main() -> int:
    egg = build_egg(build_install_script())
    OUT_PATH.write_text(
        json.dumps(egg, indent=4, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # Validación mínima del propio JSON.
    json.loads(OUT_PATH.read_text(encoding="utf-8"))
    size = OUT_PATH.stat().st_size
    print(f"OK: {OUT_PATH} ({size} bytes)")
    print(f"    UUID: {EGG_UUID}")
    print(f"    update_url: {EGG_URL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
