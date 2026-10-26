# The Last Caretaker — Mod cooperativo

[English](README.md) · **Español**

> La documentación técnica (`PLAN.md`, `server/README.md`,
> `server/pelican/README.md`) está actualmente en español. El README principal
> y los comandos de inicio rápido están en ambos idiomas.

Repositorio: <https://github.com/jberr98/last-caretaker-coop>  
Apoyo: <https://ko-fi.com/jberr>

Un proof-of-concept cooperativo/multijugador no oficial para **The Last
Caretaker** (UE5, single-player). Permite que dos jugadores se vean en la misma
área, sincronicen puertas y coordinen el estado de contenedores mediante un
pequeño sidecar en Python y, opcionalmente, un servidor dedicado de
coordinación.

Es un proyecto personal, no está afiliado a los desarrolladores del juego. Ver
[`PLAN.md`](PLAN.md) para las notas técnicas y el roadmap por fases.

> **Estado:** funcionan la sincronización de posición/ghost, las puertas, el
> aislamiento por área/dimensión, el menú in-game F9, el overlay de debug
> Ctrl+F6, el servidor dedicado de coordinación con save JSON persistente y el
> relay de respaldo. El egg de Pelican Panel está listo para importar (sus
> componentes de instalación/runtime se probaron por separado). Aplicar
> snapshots de contenedores en el cliente (`syncContainers`) sigue siendo
> experimental. El cooperativo completo del mundo no está soportado — ver
> [Limitaciones](#limitaciones).

## Índice

- [Qué funciona](#qué-funciona)
- [Atajos in-game](#atajos-in-game)
- [Cómo funciona](#cómo-funciona)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Inicio rápido](#inicio-rápido)
- [Estado de conexión (HELLO/ACK)](#estado-de-conexión-helloack)
- [Tailscale y firewall](#tailscale-y-firewall)
- [Overlay de debug (Ctrl+F6)](#overlay-de-debug-ctrlf6)
- [Pruebas en solitario](#pruebas-en-solitario)
- [Configuración](#configuración)
- [Servidor dedicado](#servidor-dedicado)
- [Pelican Panel](#pelican-panel)
- [Estructura del repositorio](#estructura-del-repositorio)
- [Limitaciones](#limitaciones)
- [Próximos pasos](#próximos-pasos)
- [Créditos](#créditos)
- [Apoyo](#apoyo)
- [Licencia](#licencia)

## Qué funciona

| Función | Estado |
|---|---|
| Ver el ghost del otro jugador en la misma área | ✅ |
| Interpolación y suavizado de posición | ✅ |
| Sincronización del estado de puertas | ✅ |
| Aislamiento por área/dimensión (`area_out.txt`) | ✅ |
| Servidor dedicado de coordinación con save JSON | ✅ |
| Snapshots de contenedores (guardar/reproducir) | ✅ se reportan y guardan |
| Aplicar snapshots de contenedores en el cliente | 🧪 experimental (`syncContainers`) |
| Relay de respaldo si el UDP directo está bloqueado | ✅ |
| Menú de conexión in-game (F9) | ✅ |
| Overlay de debug en vivo (Ctrl+F6) | ✅ |
| Animaciones / sincronización de skeleton | ❌ |
| Mundo completo, inventario, máquinas, misiones | ❌ |

## Atajos in-game

| Tecla | Acción |
|---|---|
| **Ctrl+F6** | Abrir/cerrar el overlay de debug en vivo. |
| **F7** | Simulador de peer: el ghost orbita al jugador (sin audio, no empujable). |
| **F8** | Deshabilitado. Simulaba que el peer agrega un ítem a un contenedor; en pausa por el tema del `ItemData`. |
| **F9** | Abrir/cerrar el menú de conexión. |
| **F11** | Conectar a la IP/host escrita en la caja de F9. |
| **ESC** | Cerrar el menú F9. |

La alternativa por consola es `~` o F10: `lc_connect <IP>`, `lc_disconnect`,
`lc_status`.

## Cómo funciona

Modo punto a punto:

```text
Juego (Voyage.exe, UE5)                   Juego (Voyage.exe, UE5)
  └─ UE4SS (Lua) LC_Coop                    └─ UE4SS (Lua) LC_Coop
       │ escribe coords_out.txt                  │ escribe coords_out.txt
       │ lee     coords_in.txt                   │ lee     coords_in.txt
       │ lee     event_in.txt                    │ lee     event_in.txt
       ▼                                          ▼
  sidecar/coop_net.py  ◄──── UDP 27015 ────►  sidecar/coop_net.py
```

Con el servidor dedicado de coordinación:

```text
Cliente A ── UDP ──►  lc-coop-server  ◄── UDP ── Cliente B
                         │
                         └─ save.json
                            (posiciones por área, puertas, contenedores)
```

- El **mod Lua** lee tu posición, escribe archivos IPC, lee los datos del
  jugador remoto y actualiza un actor "ghost" interpolado en tu mundo.
- El **sidecar en Python** convierte esos archivos en paquetes UDP. Reemplaza el
  puente PowerShell del proof-of-concept original.
- Cada 2 segundos el sidecar manda un **HELLO** liviano; el otro lado responde
  con un **ACK**. El estado se escribe en `lc_net_status.txt` y se muestra en el
  menú F9 y en el overlay Ctrl+F6.
- En modo **servidor dedicado** (`server:host:puerto`), el servidor guarda
  posiciones por área/dimensión, puertas y snapshots de contenedores, y manda un
  `STATE` JSON a cada cliente.
- Los jugadores se **clonan** desde la clase del pawn local, así el ghost se ve
  igual.
- Las puertas se sincronizan mediante hooks de
  `VoyageDoorActor:SetDoorState`.
- Solo se ven los jugadores de la **misma área/dimensión**. Al cambiar de área
  se elimina el ghost y se manda `PEER_OFFLINE`.

> Los jugadores **no** comparten el mundo persistente (inventario, máquinas,
> progreso de la historia, save). El mod sincroniza posición, puertas y
> snapshots de contenedores solamente. El cooperativo completo del mundo
> requeriría un servidor del juego, que el build retail no incluye.

## Requisitos

- **The Last Caretaker** con **UE4SS** instalado:
  <https://www.nexusmods.com/thelastcaretaker/mods/4>
  Extraerlo en `.../Voyage/Binaries/Win64/`. En
  `ue4ss/UE4SS-settings.ini`, sección `[Debug]`, poner las tres opciones de
  debug en `0`.
- **Python 3** en ambas máquinas (para el sidecar). Sin dependencias externas.
- **UDP 27015** abierto entre las dos máquinas para P2P/relay, o el puerto UDP
  del servidor dedicado (por ejemplo `27020`) para el modo `server:`.
- Opcional: **Tailscale** en ambas máquinas para no abrir puertos.
- Recomendado: el **Dev Menu** del juego para diagnóstico.

## Instalación

### Linux / Steam / Proton (recomendado)

```bash
scripts/install_ue4ss.sh   # si todavía no tenés UE4SS
scripts/install.sh
```

`scripts/install.sh` copia el mod a
`.../Voyage/Binaries/Win64/ue4ss/Mods/LC_Coop`, lo habilita en `mods.txt` (y en
`mods.json` si existe) y completa las rutas del proyecto/juego que usa el
comando de auto-lanzamiento de Linux.

> El `config.lua` del repositorio contiene a propósito los placeholders
> `__LC_COOP_PROJECT__` y `__LC_COOP_GAME_BIN__`. El instalador los reemplaza en
> la **copia instalada**, así el repositorio queda portable. Si copiás el mod a
> mano, editá `sidecarCmdLinux` en `mods/LC_Coop/Scripts/config.lua` con tus
> rutas absolutas.

> El ZIP para Windows no incluye los helpers de `scripts/`; están en el
> repositorio. Si instalás desde el ZIP, seguí la sección de Windows.

### Windows

Usá el instalador del paquete:

1. Descargá/extraé `LC_Coop-package.zip`.
2. Ejecutá `INSTALAR.bat` (o `windows/install_lc_coop.ps1`).
3. Lanzá el juego.

O copiá `mods/LC_Coop` a
`...\Voyage\Binaries\Win64\ue4ss\Mods\LC_Coop` y agregá `LC_Coop : 1` en
`ue4ss\Mods\mods.txt`. Para UE4SS 3.x, agregalo también a `mods.json`.

El paquete incluye además el sidecar Python, los binarios del servidor Rust y
el egg de Pelican.

## Inicio rápido

### P2P (IP directa o Tailscale)

1. Averiguá la IP LAN o Tailscale de cada máquina (`ip addr` / `ipconfig`).
2. Lanzá el juego en ambas. El sidecar arranca solo, sin ventana de terminal.
3. Presioná **F9**, escribí la IP del otro jugador y hacé clic en **Conectar**
   (o presioná **F11**). Hacelo en **ambas** máquinas.
4. Movete: el ghost del otro jugador debería aparecer y seguir su posición
   cuando están en la misma área.

Alternativa por consola (`~` o F10): `lc_connect <IP>`, `lc_disconnect`,
`lc_status`.

> Se recomienda conectar en ambos lados. Si un lado no tiene peer configurado,
> el sidecar nuevo igual responde al remitente (usa `replyAddr`) y manda sus
> posiciones; la versión vieja funcionaba solo en un sentido.

### Servidor dedicado de coordinación

Corré el servidor en un VPS, servidor casero o nodo de Tailscale:

```bash
server/bin/lc-coop-server-linux-x86_64 \
  --port 27020 \
  --save /var/lib/lc-coop/save.json
```

Después, en ambos clientes, presioná **F9** y usá:

```text
server:100.x.y.z:27020
```

Ver [Servidor dedicado](#servidor-dedicado) y
[`server/README.md`](server/README.md) para el despliegue, systemd, el formato
del save y el egg de Pelican.

### Relay de respaldo

Si el UDP directo está bloqueado, levantá el relay y usá:

```text
relay:host:puerto
```

El relay solo reenvía paquetes; no guarda estado.

### Sidecar manual

Si el auto-lanzamiento está desactivado o no está disponible:

```bash
# P2P: IP del peer (Linux/macOS)
scripts/run_sidecar.sh 192.168.1.55

# Servidor dedicado
python3 sidecar/coop_net.py --server 100.x.y.z:27020 \
  --dir "<...>/Voyage/Binaries/Win64"

# Windows (sidecar PowerShell)
sidecar\run_sidecar.bat "<...>\Voyage\Binaries\Win64"

# Windows, modo servidor dedicado (requiere Python)
sidecar\run_sidecar_server.bat "<...>\Voyage\Binaries\Win64"
```

Usá `python3 sidecar/coop_net.py --help` para ver todas las opciones.

> `run_sidecar.bat` usa el sidecar PowerShell, que solo soporta P2P/relay. Para
> el modo `server:` en Windows, usá `run_sidecar_server.bat` con Python 3.

Los logs se escriben en la carpeta del juego: `lc_sidecar.log`,
`lc_sidecar_launch.log` y `ue4ss/UE4SS.log`.

## Estado de conexión (HELLO/ACK)

El sidecar manda un **HELLO cada 2 segundos**. Si el otro cliente está
escuchando, responde un **ACK**, y el menú F9 muestra uno de estos estados:

| Estado | Etiqueta F9 | Significado |
|---|---|---|
| `confirmed` | `SI (ACK)` | El otro lado recibe nuestros paquetes y responde. |
| `one_way` | `NO (recibo, sin ACK)` | Nos llegan sus paquetes, pero los nuestros no le llegan (firewall / Shields-up). |
| `waiting` | `? (esperando)` | Todavía no hay paquetes: IP mal, sidecar apagado o Tailscale desconectado. |
| `no_peer` | `sin peer` | No hay peer configurado. |
| `stopped` | `sidecar detenido` | El sidecar se detuvo. |

`lc_status` muestra lo mismo en la consola (`~` o F10).

> El ACK requiere el sidecar actual en **ambos** lados. Con una versión vieja en
> un lado, el estado puede quedar en `one_way` aunque las posiciones funcionen
> en un solo sentido.

Para comprobar si un cliente está escuchando **sin abrir el juego** (solo hace
falta el sidecar corriendo):

```bash
scripts/check_peer.sh 100.64.0.2
# OK: 100.64.0.2:27015 está escuchando (cliente: pc-juan)
# TIMEOUT: ... no respondió
```

En Windows (con Python 3):

```powershell
python sidecar\coop_net.py --probe 100.64.0.2 --port 27015
```

El mismo comando sirve contra un servidor dedicado:

```bash
scripts/check_peer.sh 100.x.y.z 27020
```

## Tailscale y firewall

Si `check_peer.sh` funciona de A hacia B pero no de B hacia A, el problema está
en el lado que **no recibe**:

- `ping <IP-Tailscale>` y `tailscale ping <IP-Tailscale>` deben funcionar en
  ambos sentidos.
- Permití **UDP 27015** en el lado que no recibe. En Windows: Firewall de
  Windows Defender → Regla de entrada → UDP 27015. En Linux con ufw:
  `sudo ufw allow 27015/udp`.
- Desactivá **Shields-up** en la máquina que no recibe (Tailscale → Settings, o
  `tailscale set --shields-up=false`).
- Revisá que los ACL de Tailscale permitan el tráfico entre las dos máquinas.
- Si no podés abrir el puerto, usá el relay: `relay:host:puerto` (ver
  [`server/README.md`](server/README.md)).

Para el servidor dedicado, abrí su puerto UDP en el servidor/nodo (por ejemplo
`27020`). Los clientes no necesitan puertos entrantes.

## Overlay de debug (Ctrl+F6)

Presioná **Ctrl+F6** en el juego para abrir/cerrar un overlay en pantalla con:

- `NET`: estado (`confirmed`, `one_way`, `waiting`, `no_peer`), peer, nombre,
  dirección, `rx_pos`/`tx_pos`, edad del ACK/posición y puerto.
- `SRV` (modo servidor): jugadores online/otros, guardados, contenedores y
  antigüedad del save.
- `GAME`: área/dimensión, mundo/menú, estado del ghost y coordenadas
  local/remota.
- `IPC`: contenido de `coords_out.txt` y `coords_in.txt`.
- `SIDECAR (últimas)`: las últimas 8 líneas de `lc_sidecar.log` (HELLO/ACK,
  peer, posiciones, eventos, estado).
- `MOD (últimas)`: las últimas 6 líneas del log del mod (spawn del ghost,
  puertas, `STAT` remoto, acciones del menú F9, etc.).

Se actualiza cada 1 segundo. En `config.lua`:

- `debugKey = "F6"` cambia la tecla (siempre con Ctrl).
- `debugScale = 0.58` ajusta el tamaño visual (0.5 = chico, 1.0 = grande).
- `debugOverlay = false` lo desactiva.

**Evitá F1–F4**: KDE las usa para cambiar de escritorio virtual, por eso el
default es F6.

## Pruebas en solitario

No necesitás un segundo jugador para validar casi todo. `fake_peer.py` simula al
otro jugador escribiendo `coords_in.txt` (sin red):

```bash
# El ghost orbita alrededor tuyo
python3 sidecar/fake_peer.py --dir "<...>/Binaries/Win64" \
  --mode orbit --radius 400

# El ghost aparece desplazado 200 unidades en X
python3 sidecar/fake_peer.py --dir "<...>/Binaries/Win64" \
  --mode mirror --offset 200,0,0

# Inyectar un evento de puerta (para probar el sync de puertas)
python3 sidecar/fake_peer.py --dir "<...>/Binaries/Win64" \
  --mode orbit --event DOOR,NombrePuerta,1
```

No lo corras junto con `coop_net.py`: ambos escriben `coords_in.txt`.

Esto valida que el mod carga, que el ghost spawnea/se mueve y que los eventos de
puerta se aplican. **No** valida latencia, pérdida de paquetes ni el handshake
bidireccional; para eso usá dos sidecars en loopback o dos máquinas reales.

Consejo: si conectás el sidecar a tu propia IP (loopback), vas a ver un ghost
que te copia; sirve como chequeo rápido.

## Configuración

Editá `mods/LC_Coop/Scripts/config.lua` (o la copia instalada en
`.../ue4ss/Mods/LC_Coop/Scripts/config.lua`):

| Clave | Default | Para qué |
|---|---|---|
| `intervalMs` | `50` | Intervalo del loop (20 Hz). |
| `interp` | `0.35` | Suavizado de interpolación del ghost (0..1). |
| `spawnZOffset` | `50` | Eleva el ghost para que no se hunda en el piso. |
| `syncDoors` | `true` | Sincronizar puertas (`false` = solo movimiento). |
| `saveContainers` | `true` | Reportar snapshots de contenedores al servidor. |
| `syncContainers` | `false` | Aplicar snapshots de contenedores del servidor en el cliente (experimental). |
| `verbose` | `true` | Escribir logs en UE4SS. |
| `debugOverlay` | `true` | Activar el overlay Ctrl+`debugKey`. |
| `debugKey` | `"F6"` | Tecla F (con Ctrl) que abre/cierra el overlay. |
| `debugScale` | `0.58` | Tamaño visual del overlay (0.5 chico, 1.0 grande). |
| `simulatePeer` | `true` | Habilitar el simulador de peer F7/F8. |
| `autoStartSidecar` | `true` | Lanzar el sidecar al iniciar el juego. |
| `sidecarCmdLinux` | placeholders | Comando de auto-lanzamiento Linux/Proton; lo completa `scripts/install.sh`. |
| `sidecarCmdWindows` | comando PowerShell | Comando de auto-lanzamiento en Windows. |
| `debugInventory` | `false` | Diagnóstico detallado de inventario. |
| `recon` | `false` | Herramienta de reconocimiento de clases/propiedades. |

## Servidor dedicado

Hay dos modos de servidor, y no son intercambiables:

| Modo | Para qué | Sintaxis del cliente |
|---|---|---|
| **Servidor dedicado de coordinación** | Guarda estado (posiciones por área/dimensión, puertas, contenedores) y coordina a los clientes. Es el recomendado para un servidor externo. | `server:host:puerto` |
| **Relay de paquetes** | Solo reenvía UDP entre clientes. Útil si el P2P directo está bloqueado y no necesitás save. | `relay:host:puerto` |

Ninguno de los dos **hostea el mundo del juego**. El build retail solo trae el
cliente (`VoyageSteam-Win64-Shipping.exe`); no existe `VoyageServer`. Cada
jugador sigue corriendo su propio save. Un servidor real del mundo requeriría el
server target de UE5 o reimplementar el juego.

### Binario standalone (Linux x86_64)

`server/bin/lc-coop-server-linux-x86_64` es un binario Rust/musl estático
(~661 KB), sin dependencias de Python ni glibc:

```bash
scp server/bin/lc-coop-server-linux-x86_64 usuario@servidor:/opt/lc-coop/
ssh usuario@servidor
chmod +x /opt/lc-coop/lc-coop-server-linux-x86_64
/opt/lc-coop/lc-coop-server-linux-x86_64 \
  --port 27020 \
  --save /var/lib/lc-coop/save.json
```

Abrí **UDP 27020** en el firewall del servidor.

Opciones:

```text
--port N            puerto UDP (default: env PORT o 27020)
--save PATH         archivo JSON de estado (default: env SAVE o lc-coop-server-save.json)
--timeout S         segundos sin actividad para expirar un cliente (default: 30)
--state-hz N        frecuencia de STATE a los clientes (default: 15)
--save-interval S   segundos entre guardados si hubo cambios (default: 1)
--name STR          nombre visible del servidor
--dump-save         imprimir el save y salir
-h, --help / -V, --version
```

Variables de entorno equivalentes: `PORT`, `SAVE`, `TIMEOUT`, `STATE_HZ`,
`SAVE_INTERVAL`, `NAME`.

Hay un ejemplo de unidad systemd en
[`server/lc-coop-server.service`](server/lc-coop-server.service).

### Archivo de save

El servidor guarda como mínimo posiciones, además de puertas y contenedores:

```json
{
  "version": 1,
  "updated_at": 1792986000,
  "players": {
    "<client_id>": {
      "id": "<client_id>",
      "name": "pc-juan",
      "area": "Voyage/PersistentLevel",
      "positions": {
        "Voyage/PersistentLevel": {
          "x": 123.4,
          "y": 567.8,
          "z": 90.1,
          "yaw": 45.0,
          "seq": 42,
          "last_seen": 1792985999
        }
      },
      "last_seen": 1792985999
    }
  },
  "doors": {
    "NombrePuerta": 1
  },
  "containers": {
    "<persistent_id>": {
      "id": "<persistent_id>",
      "area": "Voyage/PersistentLevel",
      "items": {
        "/Game/Data/Assets/.../DA_Item": 2
      },
      "last_seen": 1792985999
    }
  }
}
```

- Se guarda cada `--save-interval` segundos si hubo cambios, y al recibir
  SIGINT/SIGTERM.
- `lc-coop-server --save ruta.json --dump-save` imprime el estado actual.
- **Posiciones por área/dimensión**: cada jugador tiene un mapa `positions`
  indexado por área. El servidor solo manda la posición del jugador remoto si
  ambos clientes están en la misma área. Al cambiar de área se elimina el ghost
  (`PEER_OFFLINE`).
- **Contenedores**: el mod reporta snapshots (`saveContainers = true`). El
  servidor los guarda, los reenvía en vivo y los manda al entrar. Aplicarlos en
  el cliente (`syncContainers = true`) limpia y vuelve a agregar los ítems; es
  experimental y está desactivado por defecto.
- **Puertas**: último estado por nombre; se manda a los clientes que entran.

Esto **no es un save completo del juego**: no guarda máquinas, fluidos,
misiones ni el inventario del jugador.

## Pelican Panel

Hay un egg listo para importar en el repositorio:

```text
server/pelican/egg-lc-coop-coordination-server.json
```

También podés importarlo directo desde el panel con **Import from URL**:

```text
https://raw.githubusercontent.com/jberr98/last-caretaker-coop/main/server/pelican/egg-lc-coop-coordination-server.json
```

1. **Admin → Eggs → Import** y subí el JSON, o usá la URL de arriba.
2. Creá un servidor con ese egg y una allocation **UDP**.
3. Usá **1 GB de RAM para la instalación** (compila Rust); 128–256 MB alcanzan
   en runtime.
4. La primera instalación descarga `server/pelican/install.sh` desde este
   repositorio y compila el servidor desde la fuente del repo (`rust:slim`,
   aproximadamente 1–3 minutos). Definí `LC_COOP_BINARY_URL` para bajar un ELF
   de Linux ya compilado.
5. El `meta.update_url` del egg apunta al repositorio, así que actualizar el egg
   vuelve a traer la última versión.
6. El save queda en `/home/container/save.json` y sobrevive reinstalaciones.

Guía completa: [`server/pelican/README.md`](server/pelican/README.md).
Regenerá el egg después de cambiar el servidor con:

```bash
python3 server/pelican/generate_egg.py
```

## Estructura del repositorio

```text
mods/LC_Coop/          mod Lua para UE4SS (cliente)
sidecar/               sidecar UDP en Python (Linux/Windows) + sidecar PowerShell legacy
server/                servidor de coordinación Rust, relay, egg de Pelican, docs
scripts/               helpers de instalación/pruebas/empaquetado
windows/               instalador de Windows
reference/             clones de investigación locales (no se distribuyen; ignorados por Git)
PLAN.md                notas técnicas y roadmap
README.md              este archivo en inglés
README.es.md           traducción al español
LICENSE, NOTICE        GPL-3.0-or-later y aviso de copyright
```

`reference/` contiene clones de proof-of-concept de terceros usados para
investigación. Está ignorado por Git a propósito y **no** forma parte del mod
distribuido.

## Limitaciones

- El ghost no tiene animaciones (se desliza); todavía no hay sincronización de
  skeleton.
- El servidor dedicado **no hostea el mundo**: cada jugador corre su partida. Su
  save cubre posiciones por área, puertas y contenedores, no el estado completo
  del juego.
- Los contenedores se guardan como snapshots por ID persistente
  (ítems/cantidades). Aplicarlos en el cliente (`syncContainers = true`) es
  experimental: limpia y vuelve a agregar los ítems del contenedor; está
  desactivado por defecto.
- **Áreas/dimensiones**: se detectan como mundo + nivel (`area_out.txt`). Si el
  juego usa una sublevel/dimensión separada, el área cambia y no se mezclan
  ghosts. Si una zona nueva no cambia de nivel, se considera la misma área y el
  ghost sigue visible.
- La identificación de puertas por nombre de actor puede fallar si hay
  duplicados.
- Cada update del juego puede requerir revisar nombres de clases/propiedades
  (`/Script/Voyage.…`).
- Solo se soporta un ghost remoto (dos jugadores).
- El modo servidor en Windows requiere el sidecar Python; el sidecar PowerShell
  solo implementa P2P/relay.
- El juego retail no tiene `VoyageServer`; un servidor real del mundo queda
  fuera de alcance sin el server target de UE5 o una reimplementación.

## Próximos pasos

1. Validar el servidor dedicado entre dos máquinas reales por LAN y Tailscale,
   incluyendo el firewall UDP del VPS.
2. Probar en el juego **dentro del mundo** (la última prueba local llegó al
   menú/`Empty`) y verificar el token real de `area_out.txt` para la nueva
   zona/dimensión.
3. Probar `syncContainers=true` en un contenedor real y corregir casos de
   duplicación/limpieza.
4. Probar el modo servidor del sidecar Python en Windows nativo.
5. Probar visualmente el menú F9 en Windows.
6. Importar el egg de Pelican en un panel real y verificar
   instalación/arranque/save tras una reinstalación.
7. Largo plazo: evaluar un transporte en C++ (ver `PLAN.md`) y si un servidor
   real del mundo es factible.

## Créditos

- Hecho con [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) y la API Lua del
  juego.
- Inspirado en los mods proof-of-concept de la comunidad en `reference/` (no se
  distribuyen con este repositorio).
- *The Last Caretaker* y sus assets pertenecen a sus respectivos dueños. Este es
  un proyecto fan no oficial.

## Apoyo

Este es un proyecto libre bajo GPL-3.0. Si te resulta útil, podés apoyar el
desarrollo con una donación:

- **Ko-fi:** <https://ko-fi.com/jberr>

Las donaciones son opcionales y no otorgan una licencia distinta, garantía ni
soporte prioritario.

## Licencia

LC_Coop es software libre bajo la **GNU General Public License, versión 3 o
posterior** (**GPL-3.0-or-later**). Ver [`LICENSE`](LICENSE) y
[`NOTICE`](NOTICE).

Es una licencia **copyleft**: podés usar, estudiar, compartir y modificar el
proyecto, pero si distribuís una versión modificada, tiene que seguir bajo la
misma licencia y tenés que entregar el código fuente. No concede una licencia
propietaria/de código cerrado.

La licencia cubre solo el código original del proyecto. **No** concede derechos
sobre *The Last Caretaker*, sus assets ni UE4SS. Los EULA/ToS del juego pueden
imponer restricciones adicionales, incluido el uso comercial.

GPL-3.0 permite distribuir copias comercialmente, pero cualquier derivado debe
seguir bajo la GPL y entregar su fuente.
