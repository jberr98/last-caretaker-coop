# LC_Coop — Servidores

Hay dos modos, no intercambiables:

| Modo | Para qué | Cliente (F9) |
|---|---|---|
| **Servidor dedicado de coordinación** | Guarda estado (posiciones por área/dimensión, puertas, contenedores) y coordina a los jugadores. Es el recomendado para probar contra un servidor externo. | `server:host:puerto` |
| **Relay de paquetes** | Solo reenvía UDP entre clientes. Útil si no hay P2P directo y no te importa el save. | `relay:host:puerto` |

> Ninguno de los dos **hostea el mundo del juego**. El juego instalado solo trae el
> cliente (`VoyageSteam-Win64-Shipping.exe`), no un `VoyageServer`. Cada jugador
> sigue corriendo su partida; el servidor coordinador guarda/coordina el estado del
> mod. Un servidor dedicado que corra el mundo requeriría el server build de UE5 o
> reimplementar el juego.

---

## Servidor dedicado de coordinación

### Binario standalone (Linux x86_64)

Está en `server/bin/lc-coop-server-linux-x86_64` (Rust + musl, **estático**,
~661 KB). No necesita Python, Docker ni glibc:

```bash
scp server/bin/lc-coop-server-linux-x86_64 usuario@servidor:/opt/lc-coop/
ssh usuario@servidor
chmod +x /opt/lc-coop/lc-coop-server-linux-x86_64
/opt/lc-coop/lc-coop-server-linux-x86_64 --port 27020 --save /var/lib/lc-coop/save.json
```

Abrí **UDP 27020** en el firewall del servidor.

Opciones:

```text
--port N            UDP (default: env PORT o 27020)
--save PATH         JSON de estado (default: env SAVE o lc-coop-server-save.json)
--timeout S         segundos sin actividad para expirar cliente (default 30)
--state-hz N        frecuencia de STATE a los clientes (default 15)
--save-interval S   cada cuántos segundos guardar (default 1)
--name STR          nombre visible del servidor
--dump-save         imprime el save y sale
-h, --help / -V, --version
```

Variables de entorno equivalentes: `PORT`, `SAVE`, `TIMEOUT`, `STATE_HZ`,
`SAVE_INTERVAL`, `NAME`.

### systemd

`server/lc-coop-server.service` es un ejemplo listo:

```bash
sudo mkdir -p /opt/lc-coop
sudo cp server/bin/lc-coop-server-linux-x86_64 /opt/lc-coop/lc-coop-server
sudo cp server/lc-coop-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lc-coop-server
journalctl -u lc-coop-server -f
```

### Pelican Panel (egg)

`server/pelican/egg-lc-coop-coordination-server.json` es un egg bootstrap listo
para importar en Pelican:

1. **Admin → Eggs → Import** → subí el JSON, o usá **Import from URL**:
   `https://raw.githubusercontent.com/jberr98/last-caretaker-coop/main/server/pelican/egg-lc-coop-coordination-server.json`
2. Creá el servidor con ese egg y una allocation **UDP**.
3. La primera instalación descarga `server/pelican/install.sh` desde el
   repositorio y compila la fuente del repo (`rust:slim`, ~1–3 min). También
   podés definir `LC_COOP_BINARY_URL` para bajar un binario ya compilado.
4. El `meta.update_url` del egg apunta al repositorio.
5. El save queda en `/home/container/save.json` y sobrevive reinstalaciones.

Guía completa, variables y limitaciones: `server/pelican/README.md`.
Repositorio: <https://github.com/jberr98/last-caretaker-coop>.

### Save (JSON)

El servidor guarda, como mínimo, **posiciones**, y además **puertas** y
**contenedores**:

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
          "x": 123.4, "y": 567.8, "z": 90.1,
          "yaw": 45.0, "seq": 42, "last_seen": 1792985999
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
- **Posiciones por área/dimensión**: cada jugador tiene `positions` por cada
  `area` donde estuvo. El servidor manda a cada cliente solo la posición del
  jugador remoto si está en la **misma área**; si se cambia de mapa/dimensión,
  el ghost se elimina (`PEER_OFFLINE`) y no se mezclan coordenadas.
- **Contenedores**: el mod manda snapshots (`saveContainers = true`). El servidor
  los guarda y los reenvía en vivo. Aplicar los snapshots en el juego es
  **experimental** (`syncContainers = true`): limpia y vuelve a agregar ítems del
  contenedor; desactivado por defecto para no tocar inventarios ajenos.
- **Puertas**: último estado por nombre; se aplica a los clientes que entran.
- Esto **no es un save del juego**: no guarda el mundo completo, máquinas,
  fluidos, misiones ni el inventario del jugador. Solo lo que el mod sincroniza.

### Clientes

En el juego, **F9** → en vez de una IP:

```text
server:IP_O_HOST_DEL_SERVIDOR:27020
```

- Hacelo en **ambas** máquinas.
- El modo `server:` requiere el **sidecar Python** en los clientes (el sidecar
  PowerShell actual solo implementa P2P/relay). En Windows:
  - Tener Python 3 instalado.
  - Desactivar `autoStartSidecar` en `config.lua` (para que no arranque el PS)
    o asegurarse de que no ocupe el puerto 27015.
  - Ejecutar `sidecar\run_sidecar_server.bat "<carpeta Win64>"` (o
    `python sidecar\coop_net.py --peer-file lc_peer.txt --dir "<carpeta Win64>"`).
- En Linux, el auto-lanzamiento normal usa el `coop_net.py` nuevo y toma
  `server:` desde `lc_peer.txt`.
- El cliente crea `lc_client_id.txt` en la carpeta del juego. **No copiar ese
  archivo entre máquinas**: cada cliente debe tener un ID distinto. Si se copió,
  borralo y el sidecar genera uno nuevo.
- El servidor no necesita Tailscale; alcanza con que los clientes lleguen por
  IP/Tailscale/hostname al puerto UDP.

### Probar el servidor sin abrir el juego

```bash
scripts/check_peer.sh 127.0.0.1 27020
# o: python3 sidecar/coop_net.py --probe 127.0.0.1 --port 27020
```

El servidor responde HELLO/ACK y escribe `lc_net_status.txt` en el cliente.

---

## Relay de paquetes (fallback)

Reenvía paquetes UDP entre jugadores. Sirve para que no hagan falta conexiones
entrantes directas: cada jugador se conecta HACIA el servidor, y el servidor
reenvía. **No guarda estado**.

### Binario standalone (Linux x86_64)

`server/bin/lc-coop-relay-linux-x86_64` es un binario Rust/musl estático
(~409 KB), sin Python:

```bash
scp server/bin/lc-coop-relay-linux-x86_64 usuario@servidor:/opt/lc-coop/
ssh usuario@servidor
chmod +x /opt/lc-coop/lc-coop-relay-linux-x86_64
/opt/lc-coop/lc-coop-relay-linux-x86_64 27020
# o: PORT=27020 TIMEOUT=30 /opt/lc-coop/lc-coop-relay-linux-x86_64
```

Abrí **UDP 27020**. `--help` / `--version` muestran la ayuda.

Para recompilar:
`cd server/relay-rs && cargo build --release --target x86_64-unknown-linux-musl`.

### Docker / Compose (relay)

```bash
cd server
docker compose up -d --build
# o directo:
docker run -d --name lc-coop-relay -p 27020:27020/udp -e PORT=27020 lc-coop-relay:latest
```

Ver clientes conectados:
```bash
docker logs -f lc-coop-relay
```

### Pelican / Pterodactyl (relay)

- Crear el server con un **egg de Python** (o una imagen Docker personalizada).
- Subir `relay_server.py`.
- **Startup**: `python3 relay_server.py {{SERVER_PORT}}`  (o usar `-e PORT=...`).
- ⚠️ **Asignar una allocation UDP**: algunos paneles solo mapean **TCP** por defecto.
  Verificá que el puerto se exponga como **UDP**, si no el relay no recibe.

### Uso desde el juego (relay)

En el menú (**F9**), en vez de una IP escribí:

```text
relay:IP_O_HOST_DEL_SERVIDOR:PUERTO
```

Ejemplos:
- Local (tu PC, si no podés salir): `relay:127.0.0.1:27020`
- Wings (por Tailscale): `relay:wings:27020`  o  `relay:100.x.y.z:27020`

El mod manda y recibe por el servidor; el `relay:` activa ese modo en el sidecar.

### Prueba solo (una PC)

```bash
scripts/relay_test.sh          # levanta relay + un bot que orbita tu posición
```

Luego en el juego: F9 → `relay:127.0.0.1:27020` → Conectar. Deberías ver el ghost del bot.

## Licencia

El código de LC_Coop está bajo **GPL-3.0-or-later**. Ver
[`LICENSE`](../LICENSE) y [`NOTICE`](../NOTICE).
