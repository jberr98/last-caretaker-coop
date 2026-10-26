#!/bin/bash
# LC_Coop — instala el servidor de coordinación desde el repositorio.
#
# Lo usa el egg de Pelican (que descarga este script) y también se puede correr
# a mano:
#
#   DEST=/ruta/del/servidor bash server/pelican/install.sh
#   LC_COOP_BINARY_URL=https://.../lc-coop-server DEST=... bash install.sh
#
# Variables:
#   DEST                  destino (default: /mnt/server si existe, si no $PWD)
#   LC_COOP_REPO          repo Git (default: https://github.com/jberr98/last-caretaker-coop.git)
#   LC_COOP_BRANCH        rama (default: main)
#   LC_COOP_SOURCE_DIR    usa un checkout local en vez de descargar el tarball
#   LC_COOP_BINARY_URL    usa un binario ya compilado en vez de compilar
#   SAVE_FILE             ruta del save relativa a DEST (default: save.json)
#   KEEP_BUILD=1          conserva .lc-coop-build para depurar
#
# El save existente NO se borra. El binario anterior se conserva si la
# compilación falla.
set -euo pipefail

REPO_URL="${LC_COOP_REPO:-https://github.com/jberr98/last-caretaker-coop.git}"
REPO_URL="${REPO_URL%/}"
REPO_BASE="${REPO_URL%.git}"
REPO_NAME="$(basename "$REPO_BASE")"
BRANCH="${LC_COOP_BRANCH:-main}"
BIN="lc-coop-server"
BIN_URL="${LC_COOP_BINARY_URL:-}"
SOURCE_DIR="${LC_COOP_SOURCE_DIR:-}"
DEST="${DEST:-}"
if [ -z "$DEST" ]; then
    if [ -d /mnt/server ]; then
        DEST=/mnt/server
    else
        DEST="$PWD"
    fi
fi
mkdir -p "$DEST"
cd "$DEST"

BUILD_DIR=".lc-coop-build"
PREFIX="[lc-coop-install]"

log() { echo "$PREFIX $*"; }

# El directorio del save puede ser una subcarpeta (SAVE_FILE=data/save.json).
SAVE_DIR="$(dirname "${SAVE_FILE:-save.json}")"
if [ "$SAVE_DIR" != "." ]; then
    mkdir -p "$SAVE_DIR"
    chown 1000:1000 "$SAVE_DIR" 2>/dev/null || true
fi

check_binary() {
    local file="$1"
    if [ ! -s "$file" ]; then
        log "ERROR: el binario quedó vacío"
        return 1
    fi
    local magic
    magic="$(od -An -tx1 -N4 "$file" | tr -d ' \n')"
    if [ "$magic" != "7f454c46" ]; then
        log "ERROR: $file no es un binario ELF de Linux"
        return 1
    fi
    chmod +x "$file"
    log "binario listo: $(wc -c < "$file") bytes"
}

cleanup() {
    rm -f "$BIN.part"
    if [ "${KEEP_BUILD:-0}" != "1" ]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT

fix_owner() {
    chmod +x "$BIN"
    chown 1000:1000 "$BIN" 2>/dev/null || true
}

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@"
    else
        log "ERROR: no encontré apt-get ni apk para instalar: $*"
        return 1
    fi
}

fetch() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        install_packages curl ca-certificates
        curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
    fi
}

log "arquitectura: $(uname -m)"
log "destino: $DEST"

# ---------------------------------------------------------------------------
# 1) Binario precompilado por URL
# ---------------------------------------------------------------------------
if [ -n "$BIN_URL" ]; then
    log "descargando binario: $BIN_URL"
    fetch "$BIN_URL" "$BIN.part"
    check_binary "$BIN.part"
    mv "$BIN.part" "$BIN"
    fix_owner
    log "instalación por URL completa"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2) Fuente: checkout local o tarball del repositorio
# ---------------------------------------------------------------------------
if [ -n "$SOURCE_DIR" ]; then
    SRC="$SOURCE_DIR/server/coop-server-rs"
    log "usando fuente local: $SOURCE_DIR"
else
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    ARCHIVE="$BUILD_DIR/repo.tar.gz"
    URL="${REPO_BASE}/archive/refs/heads/${BRANCH}.tar.gz"
    log "descargando fuente: $URL"
    fetch "$URL" "$ARCHIVE"
    if ! command -v tar >/dev/null 2>&1; then
        install_packages tar
    fi
    tar -xzf "$ARCHIVE" -C "$BUILD_DIR"
    BRANCH_DIR="${BRANCH//\//-}"
    SRC="$BUILD_DIR/${REPO_NAME}-${BRANCH_DIR}/server/coop-server-rs"
fi

if [ ! -f "$SRC/Cargo.toml" ]; then
    log "ERROR: no encontré $SRC/Cargo.toml"
    log "revisá LC_COOP_REPO/LC_COOP_BRANCH o LC_COOP_SOURCE_DIR"
    exit 1
fi

case "$(uname -m)" in
    x86_64) TARGET="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) TARGET="aarch64-unknown-linux-musl" ;;
    *)
        log "ERROR: arquitectura no soportada: $(uname -m)"
        exit 1
        ;;
esac

LINKER="musl-gcc"
if [ -f /etc/alpine-release ] && ! command -v musl-gcc >/dev/null 2>&1; then
    LINKER="cc"
fi

if ! command -v "$LINKER" >/dev/null 2>&1; then
    log "instalando musl-tools"
    if command -v apk >/dev/null 2>&1; then
        install_packages gcc musl-dev
    else
        install_packages musl-tools
    fi
fi

if ! command -v cargo >/dev/null 2>&1; then
    log "instalando rustup"
    install_packages curl ca-certificates
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi

if ! command -v rustup >/dev/null 2>&1; then
    log "ERROR: no hay rustup/cargo; usá LC_COOP_BINARY_URL"
    exit 1
fi

rustup target add "$TARGET"

mkdir -p "$DEST/$BUILD_DIR"
export CARGO_TARGET_DIR="$DEST/$BUILD_DIR/target"
TRIPLE_UPPER="$(echo "$TARGET" | tr 'a-z-' 'A-Z_')"
export "CARGO_TARGET_${TRIPLE_UPPER}_LINKER=$LINKER"

log "compilando para $TARGET (puede tardar 1-3 minutos)"
if (cd "$SRC" && cargo build --release --jobs 1 --target "$TARGET"); then
    cp "$CARGO_TARGET_DIR/$TARGET/release/lc-coop-server" "$BIN.part"
    check_binary "$BIN.part"
    mv "$BIN.part" "$BIN"
    fix_owner
    log "compilación completa"
    exit 0
fi

log "ERROR: falló la compilación"
if [ -s "$BIN" ]; then
    log "se conserva el binario existente"
    fix_owner
    exit 0
fi
exit 1
