# LC_Coop — Egg para Pelican Panel

`egg-lc-coop-coordination-server.json` es un egg **bootstrap** para Pelican.
No embebe el servidor: al instalar descarga
[`server/pelican/install.sh`](install.sh) desde el repositorio
<https://github.com/jberr98/last-caretaker-coop>. Ese instalador baja la fuente
(o un binario ya compilado) y compila `lc-coop-server`.

No hostea el mundo del juego: cada jugador sigue corriendo su partida. Es el
servidor de coordinación del mod (posiciones por área/dimensión, puertas y
contenedores).

## Qué incluye

- Bootstrap que descarga el instalador versionado en el repositorio.
- Instalador que baja el tarball de la rama `main`, compila
  `server/coop-server-rs` con musl y deja el binario estático.
- Alternativa `LC_COOP_BINARY_URL` para usar un ELF ya compilado.
- Save JSON con posiciones por área/dimensión, puertas y contenedores.
- Variables para el nombre visible, timeout, frecuencia de STATE y frecuencia de
  guardado.
- Detección de arranque (`escuchando en`) y parada ordenada (`^SIGTERM`).

## Importar el egg

1. En el panel: **Admin → Eggs → Import**.
2. Subí `egg-lc-coop-coordination-server.json`, o usá **Import from URL**:

   ```text
   https://raw.githubusercontent.com/jberr98/last-caretaker-coop/main/server/pelican/egg-lc-coop-coordination-server.json
   ```

3. El `meta.update_url` apunta a ese mismo JSON: al actualizar el egg, Pelican
   vuelve a bajarlo del repositorio.
4. El UUID es fijo; reimportar actualiza el mismo egg.

## Crear el servidor

| Campo | Valor |
|---|---|
| Egg | `LC_Coop Coordination Server` |
| Allocation | Un puerto **UDP** (Wings publica TCP y UDP; el servidor usa UDP) |
| RAM | **1 GB para instalar** (compila Rust); después 128–256 MB alcanzan |
| Disco | 1 GB recomendado (el build se borra al terminar) |
| Variables | Los defaults sirven |

El servidor escucha en `0.0.0.0`/`[::]` en el puerto de la allocation
(`SERVER_PORT`). No hace falta configurar nada más.

## Instalación

Por defecto el egg:

1. Descarga `server/pelican/install.sh` desde `main`.
2. El instalador descarga el tarball del repositorio y compila
   `server/coop-server-rs` para la arquitectura del nodo.
3. Deja `lc-coop-server` en `/mnt/server` (que es `/home/container` en runtime).

Tarda aproximadamente 1–3 minutos y necesita salida a internet (GitHub, Debian,
rust-lang.org y crates.io).

Si preferís no compilar:

- Subí un binario Linux ya compilado a cualquier URL y definí
  `LC_COOP_BINARY_URL` (por ejemplo, el binario del repo:
  `https://raw.githubusercontent.com/jberr98/last-caretaker-coop/main/server/bin/lc-coop-server-linux-x86_64`).
- El instalador lo descarga, verifica que sea un ELF y lo deja listo.
- Tiene que ser para la arquitectura del nodo (`x86_64` o `arm64`).

Si la compilación falla pero ya existe un `lc-coop-server` en el servidor, el
instalador conserva el binario anterior. El archivo `save.json` **no se toca**
en una reinstalación.

### Instalación manual

El mismo instalador se puede correr fuera de Pelican:

```bash
DEST=/srv/lc-coop bash server/pelican/install.sh
```

Variables útiles del instalador:

| Variable | Default | Para qué |
|---|---|---|
| `DEST` | `/mnt/server` si existe, si no `$PWD` | Directorio destino |
| `LC_COOP_REPO` | `https://github.com/jberr98/last-caretaker-coop.git` | Repositorio Git |
| `LC_COOP_BRANCH` | `main` | Rama a compilar |
| `LC_COOP_SOURCE_DIR` | vacío | Usar un checkout local en vez del tarball |
| `LC_COOP_BINARY_URL` | vacío | Usar un binario ya compilado |
| `SAVE_FILE` | `save.json` | Ruta del save relativa a `DEST` |
| `KEEP_BUILD` | `0` | `1` conserva `.lc-coop-build` para depurar |

El egg no expone `LC_COOP_REPO`/`LC_COOP_BRANCH` como variables editables por
seguridad (el instalador compila código como root en el contenedor de
instalación). Si usás un fork, cambiá la URL en `generate_egg.py` y regenerá el
egg.

## Variables del egg

| Variable | Default | Para qué |
|---|---|---|
| `SERVER_NAME` | `LC_Coop Server` | Nombre visible que reciben los clientes |
| `LC_COOP_BINARY_URL` | vacío | URL opcional de un binario ya compilado |
| `SAVE_FILE` | `save.json` | Ruta del save, relativa a `/home/container` |
| `TIMEOUT` | `30` | Segundos sin actividad para expirar un cliente |
| `STATE_HZ` | `15` | Frecuencia del STATE a los clientes |
| `SAVE_INTERVAL` | `1` | Cada cuántos segundos guardar si hubo cambios |
| `EXTRA_ARGS` | vacío | Argumentos extra para `lc-coop-server` |

## Conectar los clientes

En el juego, **F9** → escribí:

```text
server:IP_O_HOST:PUERTO
```

Ejemplo: `server:100.x.y.z:27020`.

- Hacelo en **ambas** máquinas.
- El puerto es el de la allocation del servidor (UDP).
- En Linux el sidecar Python se lanza solo.
- En Windows el modo `server:` requiere el sidecar Python:
  `sidecar\run_sidecar_server.bat "C:\...\Voyage\Binaries\Win64"`.
- No copies `lc_client_id.txt` entre máquinas: cada cliente debe tener el suyo.

## Save y persistencia

El save queda en `/home/container/save.json` (o en `SAVE_FILE`). Se escribe cada
`SAVE_INTERVAL` segundos si hubo cambios y al recibir SIGTERM/SIGINT.

- Incluye `players` con `area` y `positions` por área/dimensión, `doors` y
  `containers`.
- Está incluido en los backups normales de Pelican.
- Para inspeccionarlo, descargalo por el file manager/SFTP; también podés correr
  el binario con `--dump-save` desde una consola del nodo.
- **No es un save del mundo**: no guarda máquinas, fluidos, misiones ni el
  inventario del jugador.

## Puertos y firewall

- Abrí el puerto **UDP** en el firewall del nodo (Wings publica TCP+UDP, pero el
  servidor solo usa UDP).
- No hace falta abrir nada en los clientes.
- Funciona por IP LAN, IP pública o Tailscale; el servidor no necesita Tailscale.

## Limitaciones

- No hostea el mundo del juego: no hay `VoyageServer` en el build.
- El mod muestra un solo ghost (dos jugadores).
- Solamente se ven jugadores de la **misma área/dimensión**; al cambiar de área
  se manda `PEER_OFFLINE`.
- `syncContainers` (aplicar snapshots de contenedores en el cliente) sigue siendo
  experimental y está desactivado por defecto.
- El egg necesita acceso a GitHub durante la instalación. Si el nodo no tiene
  salida, usá `LC_COOP_BINARY_URL`.

## Regenerar y actualizar

```bash
python3 server/pelican/generate_egg.py
```

El generador produce un egg bootstrap pequeño (`script_install` de ~1 KB). El
instalador real vive en `server/pelican/install.sh` y se descarga en cada
instalación, así que los cambios del instalador **no** requieren regenerar el
egg.

- Si cambia el servidor Rust: hacé push a `main`; la próxima instalación baja el
  tarball nuevo y recompila.
- Si cambia la definición del egg (variables, startup, etc.): regenerá el JSON,
  hacé push y usá **Import from URL**/actualizar en el panel.
- El UUID se mantiene para que la reimportación actualice el mismo egg.

## Probado

- Bootstrap real desde `raw.githubusercontent.com` + tarball de GitHub +
  compilación musl en `rust:slim`.
- Instalación por `LC_COOP_BINARY_URL` usando el binario del repo.
- Runtime en `ghcr.io/pelican-eggs/yolks:debian` y `:alpine`.
- Arranque, `HELLO/ACK` con `scripts/check_peer.sh` y guardado al recibir
  SIGTERM.

## Licencia

El código de LC_Coop está bajo **GPL-3.0-or-later**. Ver
[`LICENSE`](../../LICENSE) y [`NOTICE`](../../NOTICE).

## Apoyo

Si el proyecto te resulta útil, podés invitarme un café:
<https://ko-fi.com/jberr>.
