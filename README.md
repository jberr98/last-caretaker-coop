# The Last Caretaker — Co-op Mod

**English** · [Español](README.es.md)

> The deep-dive docs (`PLAN.md`, `server/README.md`,
> `server/pelican/README.md`) are currently in Spanish. The main README and
> the quick-start commands are available in both languages.

Repository: <https://github.com/jberr98/last-caretaker-coop>  
Support: <https://ko-fi.com/jberr>

An unofficial co-op/multiplayer proof-of-concept for **The Last Caretaker**
(UE5, single-player). It lets two players see each other's character in the
same area, synchronize doors, and coordinate container state through a small
Python sidecar and, optionally, a dedicated coordination server.

This is a personal project, not affiliated with the game's developers. See
[`PLAN.md`](PLAN.md) for the technical notes and the phase-by-phase roadmap.

> **Status:** position/ghost sync, door sync, area/dimension isolation,
> proximity/global text chat, the in-game F9 menu, the Ctrl+F6 debug overlay, the
> dedicated coordination server with a persistent JSON save, and the relay
> fallback are working. The Pelican
> Panel egg pulls the installer from this repository; the remote bootstrap and
> runtime were tested. Applying container snapshots on the client
> (`syncContainers`) is still experimental. Full world co-op is not supported —
> see [Limitations](#limitations).

## Table of contents

- [What works](#what-works)
- [In-game shortcuts](#in-game-shortcuts)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Connection status (HELLO/ACK)](#connection-status-helloack)
- [Tailscale and firewall](#tailscale-and-firewall)
- [Debug overlay (Ctrl+F6)](#debug-overlay-ctrlf6)
- [Chat (proximity and global)](#chat-proximity-and-global)
- [Solo testing](#solo-testing)
- [Configuration](#configuration)
- [Dedicated server](#dedicated-server)
- [Pelican Panel](#pelican-panel)
- [Repository layout](#repository-layout)
- [Limitations](#limitations)
- [Roadmap](#roadmap)
- [Credits](#credits)
- [Support](#support)
- [License](#license)

## What works

| Feature | Status |
|---|---|
| See the other player's ghost in the same area | ✅ |
| Position interpolation and smoothing | ✅ |
| Door state sync | ✅ |
| Area/dimension isolation (`area_out.txt`) | ✅ |
| Dedicated coordination server with JSON save | ✅ |
| Container snapshots (save/replay) | ✅ reported and stored |
| Applying container snapshots on the client | 🧪 experimental (`syncContainers`) |
| Relay fallback when direct UDP is blocked | ✅ |
| In-game connection menu (F9) | ✅ |
| Proximity/global text chat | ✅ |
| Live debug overlay (Ctrl+F6) | ✅ |
| Player animations / skeleton sync | ❌ |
| Full world, inventory, machines, missions | ❌ |

## In-game shortcuts

| Key | Action |
|---|---|
| **Ctrl+F6** | Toggle the live debug overlay. |
| **F7** | Peer simulator: the ghost orbits your player (no audio, not pushable). |
| **F8** | Disabled. It used to simulate a peer adding an item to a container; paused due to the `ItemData` issue. |
| **F9** | Open/close the connection menu. |
| **F11** | Connect to the IP/host written in the F9 box. |
| **Enter** | Open the local (proximity) chat; press again to send. |
| **Ctrl+Enter** | Open global chat, or send the current message to global. |
| **Tab** | Switch LOCAL/GLOBAL while the chat is open. |
| **ESC** | Close the chat or the F9 menu. |

The console alternative is `~` or F10: `lc_connect <IP>`, `lc_disconnect`,
`lc_status`, `lc_name <name>`.

## How it works

Point-to-point mode:

```text
Game (Voyage.exe, UE5)                    Game (Voyage.exe, UE5)
  └─ UE4SS (Lua) LC_Coop                    └─ UE4SS (Lua) LC_Coop
       │ writes coords_out.txt                   │ writes coords_out.txt
       │ reads  coords_in.txt                    │ reads  coords_in.txt
       │ reads  event_in.txt                     │ reads  event_in.txt
       ▼                                          ▼
  sidecar/coop_net.py  ◄──── UDP 27015 ────►  sidecar/coop_net.py
```

With the dedicated coordination server:

```text
Client A ── UDP ──►  lc-coop-server  ◄── UDP ── Client B
                         │
                         └─ save.json
                            (positions per area, doors, containers)
```

- The **Lua mod** reads your position, writes IPC files, reads the remote
  player's data, and updates an interpolated "ghost" actor in your world.
- The **Python sidecar** turns those files into UDP packets. It replaces the
  original PowerShell proof-of-concept bridge.
- Every 2 seconds the sidecar sends a lightweight **HELLO**; the other side
  replies with an **ACK**. The state is written to `lc_net_status.txt` and shown
  in the F9 menu and the Ctrl+F6 overlay.
- In **dedicated server** mode (`server:host:port`), the server stores positions
  per area/dimension, doors, and container snapshots, and sends a JSON `STATE`
  to each client.
- Players are **cloned** from the local pawn class, so the ghost looks like the
  same character.
- Doors are synchronized through `VoyageDoorActor:SetDoorState` hooks.
- Only players in the **same area/dimension** see each other. Changing area
  removes the ghost and sends `PEER_OFFLINE`.
- **Chat** uses the same area token. LOCAL messages only reach players in the
  same area and within `chatRadius`; GLOBAL messages reach every client on the
  same server/relay. The text travels as a JSON `PKT_CHAT` packet; it is not
  stored in the save.

> Players do **not** share the persistent world (inventory, machines, story
> progress, save game). The mod synchronizes position, doors, and container
> snapshots only. Full world co-op would require a game server, which the
> retail build does not ship.

## Requirements

- **The Last Caretaker** with **UE4SS** installed:
  <https://www.nexusmods.com/thelastcaretaker/mods/4>
  Extract it into `.../Voyage/Binaries/Win64/`. In
  `ue4ss/UE4SS-settings.ini`, section `[Debug]`, set the three debug options to
  `0`.
- **Python 3** on both machines (for the sidecar). No external packages.
- **UDP 27015** open between the two machines for P2P/relay, or the dedicated
  server's UDP port (for example `27020`) for `server:` mode.
- Optional: **Tailscale** on both machines to avoid opening ports.
- Recommended: the game's **Dev Menu** for diagnostics.

## Installation

### Linux / Steam / Proton (recommended)

```bash
scripts/install_ue4ss.sh   # if UE4SS is not installed yet
scripts/install.sh
```

`scripts/install.sh` copies the mod to
`.../Voyage/Binaries/Win64/ue4ss/Mods/LC_Coop`, enables it in `mods.txt` (and
`mods.json` when present), and fills in the project/game paths used by the
Linux auto-start command.

> The source `config.lua` intentionally contains the placeholders
> `__LC_COOP_PROJECT__` and `__LC_COOP_GAME_BIN__`. The installer replaces them
> in the **installed** copy, so the repository stays portable. If you copy the
> mod by hand, edit `sidecarCmdLinux` in
> `mods/LC_Coop/Scripts/config.lua` with your absolute paths.

> The Windows ZIP does not include the `scripts/` helpers; they live in the
> repository. Use the Windows section below when installing from the ZIP.

### Windows

Use the packaged installer:

1. Download/extract the `LC_Coop-v<version>.zip` package (the build script
   writes it to `dist/`, for example `dist/LC_Coop-v0.2.2.zip`).
2. Run `INSTALAR.bat` (or `windows/install_lc_coop.ps1`).
3. Launch the game.

Or copy `mods/LC_Coop` to
`...\Voyage\Binaries\Win64\ue4ss\Mods\LC_Coop` and add `LC_Coop : 1` to
`ue4ss\Mods\mods.txt`. For UE4SS 3.x, also add the mod to `mods.json`.

The package also includes the Python sidecar, the Rust server binaries, and
the Pelican egg.

> **Windows + dedicated server (`server:host:port`):** the PowerShell sidecar
> only implements P2P/relay. If Python 3 is on `PATH`, the package's
> `run_sidecar_auto.bat` starts the Python sidecar automatically when the game
> opens (server mode + chat, no terminal). Otherwise it falls back to PowerShell
> (P2P/relay only). For manual troubleshooting, set `autoStartSidecar = false`
> in `...\ue4ss\Mods\LC_Coop\Scripts\config.lua` and run
> `sidecar\run_sidecar_server.bat "C:\...\Voyage\Binaries\Win64"`. F9 once
> with `server:host:port`; after that `lc_peer.txt` remembers it.

## Quick start

### P2P (direct IP or Tailscale)

1. Find each machine's LAN or Tailscale IP (`ip addr` / `ipconfig`).
2. Launch the game on both machines. The sidecar starts automatically, without
   a terminal window.
3. Press **F9**, type the other player's IP, and click **Connect** (or press
   **F11**). Do this on **both** machines.
4. Move around: the other player's ghost should appear and follow their
   position when you are in the same area.

Console alternative (`~` or F10): `lc_connect <IP>`, `lc_disconnect`,
`lc_status`.

> Connecting on both sides is recommended. If one side has no peer configured,
> the new sidecar still replies to the sender (using `replyAddr`) and sends its
> own positions; the old version only worked in one direction.

### Dedicated coordination server

Run the server on a VPS, home server, or Tailscale node:

```bash
server/bin/lc-coop-server-linux-x86_64 \
  --port 27020 \
  --save /var/lib/lc-coop/save.json
```

Then, on both clients, press **F9** and use:

```text
server:100.x.y.z:27020
```

See [Dedicated server](#dedicated-server) and
[`server/README.md`](server/README.md) for deployment, systemd, the save
format, and the Pelican egg.

### Relay fallback

If direct UDP is blocked, run the relay and use:

```text
relay:host:port
```

The relay only forwards packets; it does not store state.

### Manual sidecar

If auto-start is disabled or unavailable:

```bash
# P2P: peer IP (Linux/macOS)
scripts/run_sidecar.sh 192.168.1.55

# Dedicated server
python3 sidecar/coop_net.py --server 100.x.y.z:27020 \
  --dir "<...>/Voyage/Binaries/Win64"

# Windows (PowerShell sidecar)
sidecar\run_sidecar.bat "<...>\Voyage\Binaries\Win64"

# Windows, dedicated server mode (requires Python)
sidecar\run_sidecar_server.bat "<...>\Voyage\Binaries\Win64"
```

Use `python3 sidecar/coop_net.py --help` for all options.

> `run_sidecar.bat` uses the PowerShell sidecar, which supports P2P/relay only.
> For `server:` mode on Windows, use `run_sidecar_server.bat` with Python 3.

Logs are written to the game folder: `lc_sidecar.log`,
`lc_sidecar_launch.log`, and `ue4ss/UE4SS.log`.

## Connection status (HELLO/ACK)

The sidecar sends a **HELLO every 2 seconds**. If the other client is listening,
it replies with an **ACK**, and the F9 menu shows one of these states:

| State | F9 label | Meaning |
|---|---|---|
| `confirmed` | `SI (ACK)` | The other side receives our packets and replies. |
| `one_way` | `NO (recibo, sin ACK)` | We receive their packets, but ours do not reach them (firewall / Shields-up). |
| `waiting` | `? (esperando)` | No packets yet: wrong IP, sidecar offline, or Tailscale disconnected. |
| `no_peer` | `sin peer` | No peer configured. |
| `stopped` | `sidecar detenido` | The sidecar stopped. |

`lc_status` shows the same information in the console (`~` or F10).

> ACK requires the current sidecar on **both** sides. With an old version on
> one side, the status may stay at `one_way` even if positions work in one
> direction.

To check whether a client is listening **without launching the game** (only the
sidecar needs to be running):

```bash
scripts/check_peer.sh 100.64.0.2
# OK: 100.64.0.2:27015 is listening (client: pc-juan)
# TIMEOUT: ... did not reply
```

On Windows (with Python 3):

```powershell
python sidecar\coop_net.py --probe 100.64.0.2 --port 27015
```

The same command works against a dedicated server:

```bash
scripts/check_peer.sh 100.x.y.z 27020
```

## Tailscale and firewall

If `check_peer.sh` works from A to B but not from B to A, the problem is on the
side that **does not receive**:

- `ping <tailscale-ip>` and `tailscale ping <tailscale-ip>` must work in both
  directions.
- Allow **UDP 27015** on the receiving side. Windows: Windows Defender Firewall
  → Inbound Rule → UDP 27015. Linux with ufw:
  `sudo ufw allow 27015/udp`.
- Disable **Shields-up** on the receiving machine (Tailscale → Settings, or
  `tailscale set --shields-up=false`).
- Check that the Tailscale ACLs allow traffic between both machines.
- If you cannot open the port, use the relay: `relay:host:port` (see
  [`server/README.md`](server/README.md)).

For the dedicated server, open its UDP port on the server/node instead (for
example `27020`). Clients do not need inbound ports.

## Debug overlay (Ctrl+F6)

Press **Ctrl+F6** in game to toggle an on-screen overlay with:

- `NET`: state (`confirmed`, `one_way`, `waiting`, `no_peer`), peer, name,
  address, `rx_pos`/`tx_pos`, ACK/position age, and port.
- `SRV` (server mode): online/other players, saved players, containers, and
  save age.
- `GAME`: area/dimension, world/menu, ghost status, and local/remote
  coordinates.
- `IPC`: contents of `coords_out.txt` and `coords_in.txt`.
- `SIDECAR (últimas)`: the last 8 lines of `lc_sidecar.log` (HELLO/ACK, peer,
  positions, events, state).
- `MOD (últimas)`: the last 6 lines of the mod log (ghost spawn, doors, remote
  `STAT`, F9 menu actions, etc.).

It refreshes every second. In `config.lua`:

- `debugKey = "F6"` changes the key (always with Ctrl).
- `debugScale = 0.58` changes the visual scale (0.5 small, 1.0 large).
- `debugOverlay = false` disables it.

**Avoid F1–F4**: KDE uses them to switch virtual desktops, which is why the
default is F6.

## Chat (proximity and global)

The mod has two text channels:

- **LOCAL (proximity)**: only players in the **same area/dimension** and within
  `chatRadius` receive it. The default is **2500 UE units = 25 m** (1 unit = 1
  cm). It is a distance check, not a line-of-sight check, so a wall does **not**
  block the message if both players are close enough.
- **GLOBAL**: every client connected to the same coordination server or relay
  receives it, regardless of area or distance.

Keys:

| Key | Action |
|---|---|
| **Enter** | Open the local chat. While it is open, Enter sends. |
| **Ctrl+Enter** | Open global chat. While it is open, Ctrl+Enter sends the message as global. |
| **Tab** | Switch LOCAL/GLOBAL while the chat is open. |
| **ESC** | Close the chat. |

When a message arrives while the chat is closed, it stays on screen for
`chatToastSeconds` (default 8 s). The chat panel has a **Canal** button, an
**Enviar** button, and a **Cerrar** button, so the mouse also works.

The visible name is the sidecar `--client-name`, or `lc_player_name.txt` /
`playerName` in `config.lua`. Change it in game with:

```text
lc_name Javier
```

The sidecar reads `lc_chat_radius.txt` (written by the mod) for P2P/relay. In
**server mode** the server decides the radius with `--chat-radius` /
`CHAT_RADIUS`; the value is shown in the chat status line and the Ctrl+F6
overlay.

Chat is **plain UDP text**, not encrypted, and is **not saved**: closing the
game or restarting the server clears the history. It is text only (no voice).
On Windows, `server:` mode and chat need the **Python sidecar**
(`sidecar\run_sidecar_server.bat`); the PowerShell sidecar only implements
P2P/relay.

## Solo testing

You do not need a second player to validate most of the mod. `fake_peer.py`
simulates the other player by writing `coords_in.txt` (no network):

```bash
# Ghost orbits around you
python3 sidecar/fake_peer.py --dir "<...>/Binaries/Win64" \
  --mode orbit --radius 400

# Ghost appears 200 units away on X
python3 sidecar/fake_peer.py --dir "<...>/Binaries/Win64" \
  --mode mirror --offset 200,0,0

# Inject a door event (to test door sync)
python3 sidecar/fake_peer.py --dir "<...>/Binaries/Win64" \
  --mode orbit --event DOOR,DoorName,1
```

Do not run it together with `coop_net.py`: both write `coords_in.txt`.

This validates that the mod loads, that the ghost spawns/moves, and that door
events apply. It does **not** validate latency, packet loss, or the two-way
handshake; use two sidecars in loopback or two real machines for that.

Tip: connecting the sidecar to your own IP (loopback) makes a ghost that mirrors
you, which is a quick sanity check.

## Configuration

Edit `mods/LC_Coop/Scripts/config.lua` (or the installed copy in
`.../ue4ss/Mods/LC_Coop/Scripts/config.lua`):

| Key | Default | Purpose |
|---|---|---|
| `intervalMs` | `16` | Loop interval (~60 Hz). |
| `interp` | `0.35` | Ghost interpolation smoothing (0..1). |
| `spawnZOffset` | `50` | Raise the ghost so it does not sink into the ground. |
| `ghostMovementMode` | `1` | Ghost movement mode: `0` None, `1` Walking (idle pose, no gravity). |
| `syncFlashlight` | `true` | Copy the local flashlight/light components to the ghost (best effort). |
| `syncDoors` | `true` | Synchronize doors (`false` = movement only). |
| `saveContainers` | `true` | Report container snapshots to the server. |
| `syncContainers` | `false` | Apply server container snapshots on the client (experimental). |
| `chatEnabled` | `true` | Enable proximity/global chat. |
| `chatRadius` | `2500` | Proximity radius in UE units (2500 = 25 m). |
| `chatMaxLen` | `240` | Maximum chat text length (approximate bytes). |
| `chatToastSeconds` | `8` | How long incoming messages stay on screen when the chat is closed. |
| `playerName` | `""` | Visible chat name; empty = sidecar hostname. |
| `verbose` | `true` | Write logs to UE4SS. |
| `debugOverlay` | `true` | Enable the Ctrl+`debugKey` overlay. |
| `debugKey` | `"F6"` | F-key (with Ctrl) that toggles the overlay. |
| `debugScale` | `0.58` | Overlay visual scale (0.5 small, 1.0 large). |
| `simulatePeer` | `true` | Enable the F7/F8 peer simulator. |
| `autoStartSidecar` | `true` | Launch the sidecar when the game starts. |
| `sidecarCmdLinux` | placeholders | Linux/Proton auto-start command; filled by `scripts/install.sh`. |
| `sidecarCmdWindows` | PowerShell command | Windows auto-start command. |
| `debugInventory` | `false` | Verbose inventory diagnostics. |
| `recon` | `false` | Class/property reconnaissance helper. |

## Dedicated server

There are two server modes, and they are not interchangeable:

| Mode | Purpose | Client syntax |
|---|---|---|
| **Dedicated coordination server** | Stores state (positions per area/dimension, doors, containers) and coordinates clients. This is the recommended mode for an external server. | `server:host:port` |
| **Packet relay** | Forwards UDP between clients only. Useful when direct P2P is blocked and you do not need a save. | `relay:host:port` |

Neither mode **hosts the game world**. The retail build only ships the client
(`VoyageSteam-Win64-Shipping.exe`); there is no `VoyageServer`. Each player
keeps running their own save. A true world server would require the UE5 server
target or a reimplementation of the game.

### Standalone binary (Linux x86_64)

`server/bin/lc-coop-server-linux-x86_64` is a static Rust/musl binary
(~701 KB) with no Python or glibc dependency:

```bash
scp server/bin/lc-coop-server-linux-x86_64 user@server:/opt/lc-coop/
ssh user@server
chmod +x /opt/lc-coop/lc-coop-server-linux-x86_64
/opt/lc-coop/lc-coop-server-linux-x86_64 \
  --port 27020 \
  --save /var/lib/lc-coop/save.json
```

Open **UDP 27020** on the server firewall.

Options:

```text
--port N            UDP port (default: env PORT or 27020)
--save PATH         JSON state file (default: env SAVE or lc-coop-server-save.json)
--timeout S         seconds without activity before a client expires (default: 30)
--state-hz N        STATE frequency sent to clients (default: 60)
--save-interval S   seconds between saves when dirty (default: 1)
--chat-radius N     proximity chat radius in UE units (default: 2500)
--name STR          server display name
--dump-save         print the save and exit
-h, --help / -V, --version
```

Environment variable equivalents: `PORT`, `SAVE`, `TIMEOUT`, `STATE_HZ`,
`SAVE_INTERVAL`, `CHAT_RADIUS`, `NAME`.

A systemd unit example is included at
[`server/lc-coop-server.service`](server/lc-coop-server.service).

### Save file

The server stores at least positions, plus doors and containers:

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
    "DoorName": 1
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

- Saved every `--save-interval` seconds when dirty, and on SIGINT/SIGTERM.
- `lc-coop-server --save path.json --dump-save` prints the current state.
- **Positions per area/dimension**: each player has a `positions` map keyed by
  area. The server only sends a remote player's position when both clients are
  in the same area. Changing area removes the ghost (`PEER_OFFLINE`).
- **Containers**: the mod reports snapshots (`saveContainers = true`). The
  server stores and replays them live and on join. Applying them on the client
  (`syncContainers = true`) clears and re-adds items; it is experimental and
  disabled by default.
- **Doors**: last state per name; sent to clients that join.
- **Chat is not persisted**: messages are live only. The save does not contain a
  chat history.

This is **not a full game save**: it does not store machines, fluids, missions,
or the player's inventory.

## Pelican Panel

A ready-to-import egg is available in the repository:

```text
server/pelican/egg-lc-coop-coordination-server.json
```

You can import it directly from the panel with **Import from URL**:

```text
https://raw.githubusercontent.com/jberr98/last-caretaker-coop/main/server/pelican/egg-lc-coop-coordination-server.json
```

1. **Admin → Eggs → Import** and upload the JSON, or use the URL above.
2. Create a server with that egg and a **UDP** allocation.
3. Use **1 GB of RAM for the install** (it compiles Rust); 128–256 MB is enough
   at runtime.
4. The first install downloads `server/pelican/install.sh` from this repository
   and compiles the server from the repo source (`rust:slim`, roughly 1–3
   minutes). Set `LC_COOP_BINARY_URL` to download a prebuilt Linux ELF instead.
5. The egg's `meta.update_url` points to the repository, so updating the egg
   re-fetches the latest version.
6. The save lives in `/home/container/save.json` and survives reinstalls.

> **Port mismatch:** if the console says `escuchando en :8766` but the panel
> allocation is `[::]:27665`, the server received a stale `SERVER_PORT`. Stop
> it, set `27665` as the primary allocation (or hardcode the port in
> **Startup**), and restart. The port in the console must match the allocation.

Full guide: [`server/pelican/README.md`](server/pelican/README.md). Regenerate
the egg after server changes with:

```bash
python3 server/pelican/generate_egg.py
```

## Repository layout

```text
mods/LC_Coop/          UE4SS Lua mod (client)
sidecar/               Python UDP sidecar (Linux/Windows) + PowerShell legacy sidecar
server/                Rust coordination server, relay, Pelican egg, docs
scripts/               install/test/package helpers
windows/               Windows installer
dist/                  versioned packages (generated, gitignored)
VERSION                package version (used by scripts/package.sh)
reference/             local research clones (not distributed; gitignored)
PLAN.md                technical notes and roadmap
README.md              this file (English)
README.es.md           Spanish translation
LICENSE, NOTICE        GPL-3.0-or-later and copyright notice
```

`reference/` contains third-party proof-of-concept clones used for research. It
is intentionally ignored by Git and is **not** part of the distributed mod.

## Limitations

- The ghost has no animations (it slides); there is no skeleton sync yet.
- The dedicated server **does not host the world**: each player runs their own
  game. Its save covers positions per area, doors, and containers, not the full
  game state.
- Containers are saved as snapshots by persistent ID (items/quantities).
  Applying them on the client (`syncContainers = true`) is experimental: it
  clears and re-adds the container's items; it is disabled by default.
- **Areas/dimensions** are detected as world + level (`area_out.txt`). If the
  game uses a separate sublevel/dimension, the area changes and ghosts are not
  mixed. If a new zone does not change the level, it is treated as the same
  area and the ghost remains visible.
- Door identification by actor name can fail if there are duplicates.
- Game updates may require revisiting class/property names (`/Script/Voyage.…`).
- Only one remote ghost is supported (two players). Chat can carry messages
  from more clients, but the ghost is still limited to one.
- Proximity chat is **distance-based**, not occlusion-based: a wall does not
  block a message if both players are within the radius. It is text only, has no
  history after closing the game, and is not encrypted (plain UDP).
- The mod is a **mirror/coordination layer**, not a world server. Each player
  runs their own `VoyageWorld2`; items, enemies, the boat, AI, physics, missions,
  and the world save are local. Only the implemented mirrors are shared.
- **Duplicate world pickups are expected**: picking up an item in one world does
  not remove the same actor in the other world. Container snapshots
  (`syncContainers`) only cover container inventories and are experimental.
- The **boat** cannot be shared as a mobile base with this architecture. A
  transform clone would be a separate actor without the same inventory,
  interior, collision, or players standing on it. True sharing requires an
  authoritative world server; the retail build has no `VoyageServer`.
- **Enemies are not synchronized.** Mirroring their transforms would still
  diverge because each client runs its own AI/physics simulation.
- Flashlight sync is **best effort**: it copies matching light components from
  the local pawn to the ghost. Use `lc_lights` in the console to inspect them.
- Windows server mode requires the Python sidecar; the PowerShell sidecar only
  implements P2P/relay.
- The retail game has no `VoyageServer`; a true world server is out of scope
  without the UE5 server target or a reimplementation.

## Roadmap

1. Validate the dedicated server between two real machines over LAN and
   Tailscale, including the UDP firewall on the VPS.
2. Test in-game **inside the world** (the last local test reached the menu /
   `Empty`) and verify the real `area_out.txt` token for the new zone/dimension.
3. Test `syncContainers=true` on a real container and fix duplication/clear
   edge cases.
4. Test the Python sidecar server mode on native Windows.
5. Test the new chat UI in-game with two real clients (LOCAL/GLOBAL, Tab, Esc).
6. Test the F9 menu visually on Windows.
7. Import the Pelican egg in a real panel and verify install/start/save across a
   reinstall.
8. Evaluate selected actor mirroring (boat transform, world pickups by
   persistent ID) and whether a true world server is feasible; full object,
   enemy, and boat sync is out of scope for the current Lua/sidecar design.

## Credits

- Built with [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) and the game's Lua API.
- Inspired by the community proof-of-concept mods in `reference/` (not
  distributed with this repository).
- *The Last Caretaker* and its assets belong to their respective owners. This is
  an unofficial fan project.

## Support

This is a free, GPL-3.0 project. If you find it useful, you can support
development with a donation:

- **Ko-fi:** <https://ko-fi.com/jberr>

Donations are optional and do not grant a different license, warranty, or
priority support.

## License

LC_Coop is free software licensed under the **GNU General Public License,
version 3 or later** (**GPL-3.0-or-later**). See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE).

This is a **copyleft** license: you can use, study, share, and modify the
project, but if you distribute a modified version, it must remain under the same
license and you must provide the source. It does not grant a
proprietary/closed-source license.

The license covers the project's original code only. It does **not** grant any
rights to *The Last Caretaker*, its assets, or UE4SS. The game's EULA/ToS may
impose additional restrictions, including on commercial use.

GPL-3.0 allows commercial distribution of copies, but any derivative must remain
under the GPL and provide its source.
