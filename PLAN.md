# The Last Caretaker — Coop Mod (LAN)

Documento de proyecto. Objetivo: agregar **cooperativo LAN** a *The Last Caretaker*
(UE5, single-player) para uso personal, sin modificar el juego original.

> **Estado: INVENTARIO EN PAUSA (2026-10-02).** El avatar (Fase 1) y las puertas (Fase 2)
> quedan activos y estables. La **escritura de contenedores está DESACTIVADA**
> (`config.syncContainers = false`) porque `AddItem` con `ItemData = nil` genera ítems
> inválidos/invisibles y puede crashear al vaciar el contenedor. Próximo paso para
> retomar: construir/reutilizar un `VoyageItemData` válido (ver §12).

---

## 0. Estado actual (2026-10-02)

**Fase 1 (verse): FUNCIONANDO.** ✅ Validado en un solo PC con `fake_peer`.

- UE4SS v3.0.1 inyectado bajo Proton (requiere override `dwmapi=native,builtin`).
- El mod Lua lee la posición del jugador, el sidecar/fake_peer la transporta,
  y el ghost (`BP_FirstPersonCharacter_New_C`) sigue al jugador con interpolación.
- Hook de puertas registrado (`VoyageDoorActor:SetDoorState`); pendiente de probar.

### Bugs encontrados y corregidos

1. **UE4SS no inyectaba.** Proton cargaba su `dwmapi.dll` *builtin* en vez de la
   nativa. Fix: `WINEDLLOVERRIDES="dwmapi=n,b"` o override en el `user.reg` del prefix.
2. **Spawn fallaba.** El mod cacheaba la clase del pawn **del menú**
   (`BP_VoyageMenuPawn_C`) y no se podía spawnear en el mundo. Fix: tomar la clase
   **fresca** del pawn actual en cada intento.
3. **El ghost no se movía.** El `seq` se reiniciaba al reiniciar peer/juego y el mod
   descartaba todo como "paquete viejo". Fix: sin filtro por `seq` (el archivo IPC
   siempre contiene el último estado).
4. **El ghost compartía audio/física/d año** (era un clon completo del personaje):
   se oía su muerte y caída, y al golpearlo salía volando. Fix: `harden_ghost()`
   desactiva colisión, tick, daño y componentes de audio. Además se limpian los
   archivos IPC al cargar para no dejar un ghost "fantasma" tras reiniciar.

### Limitaciones actuales

- El ghost **no tiene animaciones** (se desliza).
- Sin sincronización de inventario, máquinas, fluidos ni save.
- Los hot-reloads dejan **ghosts duplicados** (un reinicio los limpia).

---

## 1. Estado verificado del entorno

| Dato | Valor | Cómo se verificó |
|---|---|---|
| AppID | 1783560 | `appmanifest_1783560.acf` |
| Carpeta instalada | `.../steamapps/common/Voyage` (proyecto UE "Voyage") | `installdir = Voyage` |
| Ejecutable | `Voyage/Binaries/Win64/VoyageSteam-Win64-Shipping.exe` (198 MB) | filesystem |
| Motor | **UE 5.7.3** en el binario; rastros de 5.8 en el prefix | strings del .exe + `UnrealEngine/5.7` y `5.8` |
| Empaquetado | IoStore: `pakchunk0-Windows.ucas` (15,6 GB) | `Content/Paks` |
| Anti-cheat | No | categorías Steam / PCGW |
| Runtime Linux | Proton (Proton-CachyOS / GE) + GOverlay (MangoHud/HDR/FSR) | `bgmod.log`, env |
| Modo oficial | Single-player | Steam API |
| Multiplayer | **No existe** (devs lo dejaron abierto a futuro) | Steam foro |

> Nota: `bgmod.log` NO es un mod loader; es **GOverlay** configurando MangoHud/OptiScaler
> para los juegos de Proton.

## 2. Ecosistema de modding (lo que hace viable el proyecto)

- **UE4SS v3.0.1** (build sep-2026) compatible con el juego actual. Soporta mods
  **Lua** y **C++** (SDK generado desde `.usmap`).
- **`.usmap` + AES key** publicados/mantenidos por la comunidad de modders.
- **DML (DmgModLoader)**: carga mods de Blueprint/LogicMods desde `Content/Paks`.
- **Dev Menu**, **164 mods** en Nexus, guías en `github.com/Dmgvol/UE_Modding`,
  y un **Discord dedicado de modding**.
- Zona de instalación de UE4SS: `.../Voyage/Binaries/Win64/ue4ss/`.
  En `UE4SS-settings.ini`, sección `[Debug]`, poner las 3 variables en `0`.

## 3. PoCs coop existentes (referencia)

| Proyecto | Técnica | Logra | No logra |
|---|---|---|---|
| `skelegamerYT11/TheLastCaretaker_MultiplayerMod` | UE4SS + scripts de memoria | ver jugador remoto, sincronizar puertas | items, animaciones |
| `Gentlemannn/LastCaretaker-Multiplayer` | Inyección DLL (C#) + lectura/escritura memoria + P2P | ghost player, respawn, reload/save | estado del mundo |

Ambos validan el enfoque "sync externa"; ninguno resuelve inventario/máquinas.

## 4. Arquitectura propuesta

**Modelo:** host autoritativo, actualización de estado por diffs.

```
        HOST (autoridad)                     CLIENTE
 ┌──────────────────────────┐        ┌──────────────────────────┐
 │  juego (Voyage.exe)      │        │  juego (Voyage.exe)      │
 │   └─ mod UE4SS (C++)     │        │   └─ mod UE4SS (C++)     │
 │       ├─ hooks de estado │        │       ├─ hooks de estado │
 │       └─ transporte ENet │◄──────►│       └─ transporte ENet │
 └──────────────────────────┘   UDP  └──────────────────────────┘
                ▲                                 ▲
        lee/escribe memoria              lee/escribe memoria
        vía SDK del .usmap               vía SDK del .usmap
```

- **Transporte:** ENet o LiteNetLib en C++ dentro del mod.
- **Acceso al juego:** SDK C++ generado desde `.usmap` (objetos UE tipados).
- **Ruteo de desarrollo:**
  - **Lua (UE4SS)** → prototipar rápido (leer pos, probar hooks). Sin compilar.
  - **C++ (UE4SS)** → producción: rendimiento + sockets nativos + SDK tipado.
- **No** arrancar con inyección cruda de DLL: más trabajo y sin el SDK.

## 5. Problemas difíciles (por orden de dolor)

1. **Inventario / contenedores / stack** → duplicación y desincronización.
2. **Máquinas, energía, fluidos** → estado continuo, muchos diffs.
3. **Persistencia / save** → ¿un save compartido? ¿autoridad del host?
4. **Late join** → reconstruir el estado del mundo al entrar.
5. **Física y animación** → el ghost player "se desliza" (limitación conocida).
6. **Fragilidad de versión** → cada update del juego (EA) puede romper offsets/usmap.

## 6. Roadmap por fases

### Fase 0 — Entorno y verdad base
- Instalar UE4SS v3.0.1 en `Binaries/Win64/ue4ss/`.
- Confirmar **versión exacta** del juego instalado (el .exe dice 5.7.3) y bajar el `.usmap`/AES correctos.
- **Resolver el toolchain** (ver §10): es el bloqueante real para la ruta C++.
- Generar el SDK C++ (headers UHT) y compilar un mod "hola mundo" que liste objetos.
- Unirse al Discord de modding. Correr el Dev Menu como diagnóstico.

### Fase 1 — Hola, amigo (PoC de red) — ✅ HECHA
- Handshake host/cliente por LAN.
- Leer `transform` del jugador local y difundirlo.
- Spawnear un actor "ghost player" con interpolación en el otro lado.
- **Criterio de éxito:** dos PCs, cada uno ve al otro moverse suave.
- **Estado:** validado en 1 PC con `fake_peer`; falta la prueba real de 2 máquinas.

### Fase 2 — Acciones locales
- Puertas, agarrar/soltar objetos, interruptores.
- RPC por evento (no por tick) con idempotencia.

### Fase 3 — Inventario (el hueso)
- Autoridad del host sobre inventario y contenedores.
- Resolver duplicación: el cliente "pide", el host "concede".

### Fase 4 — Máquinas / energía / fluidos
- Diffs periódicos + reconciliación.

### Fase 5 — Save y late join
- Snapshot del mundo al conectar.

## 7. Herramientas / enlaces

- UE4SS (Nexus TLC): https://www.nexusmods.com/thelastcaretaker/mods/4
- Guías de modding UE: https://github.com/Dmgvol/UE_Modding
- DML: https://www.nexusmods.com/thelastcaretaker/mods/77
- PoC Lua: https://github.com/skelegamerYT11/TheLastCaretaker_MultiplayerMod
- PoC DLL: https://github.com/Gentlemannn/LastCaretaker-Multiplayer
- PCGW: https://www.pcgamingwiki.com/wiki/The_Last_Caretaker

## 9. Hallazgos de los PoC (código real)

### PoC Lua — el valioso
Archivo: `reference/poc-lua/mod_files/ue4ss/Mods/MultiplayerSync/Scripts/main.lua`

- API UE4SS usada: `UEHelpers.GetPlayerController()`, `PC.Pawn`,
  `pawn:K2_GetActorLocation()/K2_GetActorRotation()`, `World:SpawnActor(clase, loc, rot)`,
  `FindAllOf("VoyageDoorActor")`, `RegisterHook("/Script/Voyage.VoyageDoorActor:SetDoorState", ...)`,
  `LoopAsync(100)`, `ExecuteInGameThread(...)`.
- **Clases/API reales del juego descubiertas:**
  - `VoyageDoorActor`, propiedades `DoorState` y `DoorStateDesired`,
    función `SetDoorState`, y `SetDoorPosition(alpha, bool)`.
  - El módulo de script del juego se llama **`Voyage`** (`/Script/Voyage.…`).
- **Truco del ghost player:** no crea un actor genérico; **clona la clase del propio pawn**
  (`myPawn:GetClass()`) y lo spawnea en la posición remota. Luego `K2_TeleportTo` +
  setear `CharacterMovement.Velocity` para reducir el "deslizamiento".
- **Transporte (el punto débil):** el Lua escribía `coords_out.txt` / leía `coords_in.txt`,
  y un puente en **PowerShell (C#)** hacía UDP en el puerto **27015**
  (paquete byte 1 = posición float x,y,z,yaw; byte 2 = eventos como puertas).
  Los eventos también iban por archivos (`event_in.txt` / `event_out.txt`).

### PoC DLL — poco reutilizable
Archivo: `reference/poc-dll/LastCaretaker/dllmain.cpp`

- Punteros hardcodeados por build: `BASE_XZ=0x0A7C4118`, `BASE_Y=0x0A38D5A0`,
  offsets `0x21C/0x224/0xCF4`, con `__try/__except`.
- Solo **envía** la posición local por UDP a `127.0.0.1:27015`; **no recibe ni dibuja** al otro.
- Se rompe en cada update del juego (los offsets cambian).
- Conclusión: **no copiar offsets**; sí la idea de un proceso/transporte separado.

## 10. Requisitos del mod C++ de UE4SS (y el problema de Linux)

- API: clase `RC::CppUserModBase` (`#include <Mod/CppUserModBase.hpp>`),
  se exportan `start_mod()` / `uninstall_mod()`, se compila con **CMake** y se linkea contra `UE4SS`.
- Instalación: `Mods/<Nombre>/dlls/main.dll` + entrada en `Mods/mods.txt`.
- SDK tipado: UE4SS genera **headers UHT** (por defecto `Ctrl+Numpad9`) y/o un dump **CXX con offsets**.
- ⚠️ **ABI-sensible:** `CppUserModBase.hpp` avisa que el mod debe usar la **misma CRT y configuración
  (Release)** que UE4SS. El workflow oficial usa **MSVC** y requiere acceso al código de Unreal (Epic GitHub).
- Tu entorno (PikaOS): `cmake 4.3`, `gcc 16`, `clang 23`, `docker`, `wine-staging`, `qemu`.
  **No hay MinGW ni MSVC.** Cross-compilar con MinGW probablemente falle por ABI/CRT.

### Opciones de toolchain

| # | Opción | Pros | Contras |
|---|---|---|---|
| 1 | **VM Windows + Visual Studio** (qemu disponible) | Ruta soportada, ABI correcta | Pesado de montar |
| 2 | **MinGW-w64 cross-compile** en Linux | Todo en Linux | Riesgo alto de ABI/CRT |
| 3 | **Lua (sin compilar) + sidecar nativo Linux** | Funciona hoy; el juego corre como proceso Linux bajo Proton, un binario Linux puede leer/escribir los archivos de la carpeta del juego y hacer UDP | Rendimiento y "elegancia" menores |

> Nota sobre la opción 3: el PoC ya usa IPC por archivos, pero desde Windows. En Linux,
> el sidecar es un binario nativo que ve la carpeta del juego directamente. Es la vía más rápida
> para validar la Fase 1 sin pelear con el toolchain.

## 11. Decisiones abiertas

- [ ] **Toolchain** (ver §10): VM Windows+MSVC (recomendado para C++) / MinGW cross / Lua+sidecar.
- [ ] Alcance del primer hito: confirmado Fase 1 (solo verse).
- [ ] Transporte: ENet vs LiteNetLib vs UDP crudo (como el PoC).
- [ ] ¿Forquear el PoC Lua como base del lado juego e ir migrando a C++?

---

## 12. Fase 3 — Reconocimiento de inventario (hallazgos 2026-10-02)

### Clases y componentes

- El jugador: `BP_FirstPersonCharacter_New_C`, `BP_VoyagePlayerState_C`,
  `BP_VoyagePlayerController_C`.
- El inventario es un **componente nativo**: `/Script/Voyage.VoyageBaseInventoryComponent`.
  Subclases: `VoyageInventoryWeightLimitedComponent`, `VoyagePaintInventoryComponent`,
  `VoyageEquipmentComponent`, `VoyageWeaponHolsterComponent`.
- Componentes del jugador con contenido: `VaultInventory`, `WeightInventory`,
  `EquipmentComponent`, `WeaponHolsterComponent`, `PaintInventory`, `AttachmentInventory`.
- Contenedores: `BP_Container_Base_C` (propiedad `ContainerItems`) y
  `BP_Inventory_Container_Base_C` (propiedad `VoyageBaseInventory`). Se identifican por
  nombre de actor (ej. `...BP_Inventory_Container_Buoy_Small_C-1508388757`).

### Estructura de datos

- `VoyageBaseInventoryComponent.Items` es un **`MapProperty`**:
  clave = entero, valor = struct **`VoyageItemSerialize { AssetType, AssetName, Item, Data }`**.
- **Lectura por función funciona**: `GetAllItems()` devuelve un array; cada elemento se
  decodifica con `elem:get()`, que devuelve el **asset del ítem**
  (ej. `VoyageItemEquipment /Game/Data/Assets/Equipment/Head/DA_Equipment_NightVision`).
- El mapa (`GetItemsMap()`) se itera, pero los campos del struct no se leen con `v[field]`
  (pendiente: `GetSlot()` / acceso por propiedad).
- El mapa `Items` crudo devuelve `userdata` opaco → **no sirve para leer/escribir directo**.

### API disponible (UFUNCTIONs en `VoyageBaseInventoryComponent`)

`AddItem`, `AddItems`, `AddItemsWithData`, `AddToSlot`, `ClearItems`, `ChangeSlot`,
`CanAddItem`, `EstimateAddAmount`, `EstimateRemoveAmount`, `GetAllItems`, `GetItemsMap`,
`GetSlot`, `GetTotalNumItems`, `GetItemsByType`, `GetItemCountByType`, `FindItemsBySubClass`…
**No aparece un `RemoveItem` obvio** (a investigar).

### Estrategia elegida

**Sync por eventos** (no por estado): enganchar las funciones de mutación
(`AddItem`/etc.), emitir un evento `(inventario, asset del ítem, cantidad)` y, del otro
lado, encontrar el inventario equivalente y llamar a la misma función. Evita leer/escribir
el `MapProperty` opaco y el riesgo de duplicación.

### Pendiente

1. Capturar argumentos reales de `AddItem` (hook ya armado; falta la acción en el juego).
2. Encontrar la función de **remoción**.
3. Decidir inventario objetivo: contenedor compartido vs. `WeightInventory` del jugador.

### Identidad estable de contenedores (resuelto)

Cada contenedor tiene un componente **`VoyagePersistentActorComponent`** con:

- `PersistentUniqueId` (UInt64) — ID persistente del save.
- `PersistentUniqueIdRuntime` (UInt64).
- `bAlwaysPersist = true`, `RuntimeActorClass` = la clase BP.

Se usa `PersistentUniqueId` para mapear el mismo contenedor entre los dos mundos
(fallback: clase + posición).

### Implementación (Fase 3, solo ADD) — en `main.lua`

- Hook `VoyageBaseInventoryComponent:AddItem`; si el inventario pertenece a un actor
  contenedor, se emite un evento `INV,<PersistentUniqueId>,<assetPath>` por el mismo
  canal de eventos (`event_out.txt` / `event_in.txt`) que usan las puertas.
- Al recibir `INV`, se busca el contenedor por ID, se resuelve el asset con
  `StaticFindObject(path)` y se llama `AddItem(asset, nil, true, true)`.
- Guard `applyingRemote` para no re-emitir (evita bucles).
- **Vía de aplicar: VALIDADA** (evento inyectado → ítem agregado al contenedor).
- **Vía de emitir: VALIDADA** para `AddItem` (loot/auto/output), con path limpio.

### Movimientos manuales por UI (estado)

Mover ítems a mano usa `TransferSlot(ctx=origen, destino, slot, -1, flag)`, **no `AddItem`**.
No se puede leer el ítem de origen:

- `GetSlot(slot)` devuelve **nil** (UE4SS Lua no materializa `VoyageItemSerialize`).
- Campos de struct no accesibles.
- Firmas de delegates no registrables (`OnInventorySlotAdd__DelegateSignature`, etc. no existen).

**Solución implementada:** diff de `GetAllItems()` del destino antes/después
(`ExecuteWithDelay(250)`), emitiendo los ítems agregados. La detección de contenedores
se generalizó: cualquier inventario cuyo **owner no sea el jugador**
(excluye `character`/`playercontroller`/`playerstate`) y tenga `VoyagePersistentActor`
cuenta como contenedor. Esto arregló que `BP_Inventory_PlayerBox_Small_C`
(que contiene "player" en el nombre) se detectara.

**Caveats:**
- El diff solo detecta **agregados** (`despues > antes`); las extracciones no se sincronizan.
- Es frágil con acciones rápidas (la captura antes/después se pisa).
- En las pruebas, las acciones del usuario fueron mayormente **extracciones**, así que
  el camino ADD del diff aún no se confirmó con una acción real.

### Simulador in-game (probar el coop sin 2ª máquina)

En `main.lua`, con `config.simulatePeer = true`:

- **F7**: activa "peer sim" — el ghost orbita al jugador (usa el mismo `applyRemote`).
- **F8**: simula que el peer agrega un ítem (Fabric Scraps) al **último contenedor
  interactuado**, usando el componente capturado en los hooks (sin escanear).

Bugs encontrados y corregidos en este ciclo:

- El **escaneo de todos los `VoyageBaseInventoryComponent`** (~2269) **crasheaba** el
  juego al aplicarlo desde una tecla. Fix: usar el componente capturado (sin escaneo).
- `math.degrees` **no existe** en el Lua de UE4SS → usar `* 57.29577951308232`.
- Ghost "endurecido": sin colisión, tick, daño, audio ni gravedad (no cae ni suena).
- Se limpian los archivos IPC al cargar (no queda un ghost "fantasma" tras reiniciar).

### Sidecar auto-lanzado (sin terminal)

Bajo Proton, `os.execute("start /unix <binario Linux> ...")` **sí** lanza procesos
nativos → el juego arranca el sidecar solo. En Windows nativo se usa
`os.execute('start "" /b powershell -WindowStyle Hidden -File coop_net.ps1 ...')`.
Se usa `Mod:SetSharedVariable("lc_sidecar_launched", true)` para no relanzarlo en cada
hot-reload (la variable sobrevive a los reloads).

**Fix (2026-10-25): consola pegada al juego.**
- El mod detecta Proton (`WINEPREFIX` / `STEAM_COMPAT_DATA_PATH` / `Z:\etc\os-release`)
  y ejecuta **solo** el comando de esa plataforma. Antes corría también el comando de
  Windows bajo Wine, dejando procesos/consolas colgadas.
- En Linux ya no se lanza `python3` directo: se llama a
  `scripts/launch_sidecar.sh`, que usa `setsid -f` y redirige stdin/stdout/stderr.
  El sidecar queda en una sesión nueva, sin terminal, y la consola de `cmd.exe` se
  cierra enseguida. Steam puede cerrar el juego sin forzar.
- `--watch-game` ahora espera a ver el juego al menos una vez y sale ~1-2 s después de
  que se cierra (sirve también para lanzarlo a mano antes de abrir el juego). Si no
  lo ve en 60 s, también sale para no quedar colgado.
- `game_running()` en Linux ya **no** busca `Voyage.exe` en cualquier cmdline: los
  wrappers de Steam/Proton (`bgmod`, `proton`, `pv-adverb`, …) lo contienen y
  mantenían vivo al sidecar (y a la consola) después de cerrar el juego. Ahora
  mira solo `argv[0]` y busca `VoyageSteam-Win64-Shipping` (el ejecutable real).
  Medido: sidecar y `pv-adverb` terminan ~1-2 s después de cerrar el juego.
- `scripts/run_sidecar.sh` (lanzamiento manual) también usa `--watch-game` y sale
  al cerrar el juego.

### Fix P2P / Tailscale (2026-10-25)

- **Reply viejo al cambiar de peer:** `targets()` priorizaba `reply_addr` siempre.
  Si se pasaba de `relay:127.0.0.1:...` a una IP de Tailscale, seguía mandando al
  relay/peer viejo (el otro nos veía, pero nosotros no le mandábamos nada).
  Ahora `reply_addr` solo se usa si su IP coincide con el peer configurado (o si
  no hay peer), y `set_peer()` limpia reply/ACK al cambiar.
- **Descubrimiento IPv4/IPv6:** las posiciones/HELLO se mandan a todas las
  direcciones resueltas hasta que el peer responde; después se fija `reply_addr`.
  En relay se manda a una sola para no crear dos clientes. Si el DNS falla, se
  reintenta cada 10 s; las IPv6 se aceptan con o sin corchetes.
- **HELLO/ACK:** paquetes tipo 3/4 cada 2 s. El ACK confirma que el otro está
  escuchando. `lc_net_status.txt` escribe `state=confirmed|one_way|waiting|no_peer`
  con `peer_name`, edades y contadores; lo muestran el menú F9 y `lc_status`.
- **Probe:** `python3 sidecar/coop_net.py --probe <IP>` (o
  `scripts/check_peer.sh <IP>`) manda HELLO y espera ACK. Sirve para diagnosticar
  una conexión en un solo sentido (firewall/Tailscale shields-up).
- **Windows/PowerShell:** antes solo enviaba posiciones/eventos si había
  `lc_peer.txt` (`$remote`); si el peer iniciaba el contacto, no contestaba. Ahora
  usa `replyAddr` si coincide con el peer, y también implementa HELLO/ACK/estado.

### Debug en vivo (Ctrl+F6)

- `debug_log.lua`: ring buffer de 400 líneas con los logs del mod.
- `debug_overlay.lua`: overlay UMG no interactivo (Z=100), refresco 1 s.
  Muestra `NET` (estado/peer/counters/edades), `GAME` (world/ghost/local/remote),
  `IPC` (coords_out/in), últimas 8 líneas de `lc_sidecar.log` y últimas 6 del mod.
  Fuente chica (14/18) y `SetRenderTransform` escala 0.58 (`config.debugScale`)
  para que ocupe ~mitad de pantalla, no todo.
- Hotkey: `RegisterKeyBind(Key.F6, {ModifierKey.CONTROL}, ...)`.
  `config.debugOverlay` lo desactiva; `config.debugKey` cambia la F y
  `config.debugScale` el tamaño. Se usa F6 porque KDE intercepta Ctrl+F1..F4
  (cambio de escritorio) y Ctrl+F9/F10/F12.
- El sidecar ahora loguea ACK cada 10 s, posiciones recibidas cada 10 s y un
  resumen `tx_pos/rx_pos/ack/pos` cada 5 s (lo muestra el overlay).

---

## 12.5 Servidor dedicado de coordinación (2026-10-25)

- **Binario**: `server/coop-server-rs` (Rust, musl estático) →
  `server/bin/lc-coop-server-linux-x86_64` (~661 KB, sin Python).
- **Cliente**: `server:host:puerto` en `lc_peer.txt` / F9. El sidecar Python
  manda `HELLO`, `POS_AREA` (tipo 7: área + posición) y `EVENT`; recibe
  `STATE` (tipo 6, JSON) y eventos `DOOR`/`CONT`/`INV`/`STAT`.
- **Save JSON**: `players` con `area` y `positions` **por área/dimensión**,
  `doors` y `containers` (id persistente → items/cantidades). Se guarda cada
  1 s si hay cambios y al recibir SIGINT/SIGTERM. `--dump-save` lo imprime.
- **Áreas/dimensiones**: el mod calcula `area_out.txt` como mundo + nivel;
  el servidor guarda posiciones por área; cada cliente solo muestra un remoto
  de su misma área; al cambiar de área se manda `PEER_OFFLINE` y se destruye
  el ghost.
- **Contenedores**: el mod manda snapshots `CONT` (BEGIN/ITEM/END) de los
  contenedores tocados (`saveContainers = true`); el servidor los guarda,
  los reenvía en vivo y los manda al entrar. `syncContainers = true` aplica el
  snapshot en el cliente (experimental, ClearItems + AddItem).
- **ID estable**: `lc_client_id.txt` por cliente; el servidor usa ese ID para
  el save. No copiar ese archivo entre máquinas.
- **Probado**: dos sidecars Python, posiciones/áreas, puertas, contenedores,
  reload del server, `PEER_OFFLINE` al cambiar de área, y el juego real
  conectado al server (sidecar confirmado; el juego quedó en menú/Empty).
- **Limitaciones**: no hostea el mundo (no hay `VoyageServer`); el mod muestra
  un solo ghost (2 jugadores); el sidecar PowerShell no implementa server mode
  (usar Python en Windows).
- **Egg de Pelican** (`server/pelican/`): `generate_egg.py` embebe
  `Cargo.toml`/`Cargo.lock`/`main.rs` y genera
  `egg-lc-coop-coordination-server.json` (~54 KB, `PLCN_v1`). La instalación
  compila el binario musl en `rust:slim`; si se define `LC_COOP_BINARY_URL`,
  descarga un ELF ya compilado. Runtime probado en `yolks:debian` y `:alpine`,
  save persistente, UDP, stop `^SIGTERM`.

## 13. Servidor de coordinación (relay) y pruebas solo

- **`server/relay_server.py`**: relay UDP. Todos se conectan **hacia afuera** al servidor,
  que reenvía entre ellos. Resuelve que una máquina no acepte entrantes.
- **`server/bot_client.py`**: jugador falso (órbita) para probar solo. Ahora
  responde HELLO/ACK, así que en F9 el estado aparece `confirmado`.
- **Modo relay en el sidecar**: si en el menú (o `lc_peer.txt`) escribís
  `relay:host:puerto`, el sidecar manda y recibe por el servidor.
- **Docker**: `server/Dockerfile` + `server/docker-compose.yml` (puerto UDP). Sirve para
  Pelican/Pterodactyl (egg de Python; asignar el puerto como UDP).
- **Binario standalone**: `server/relay-rs` (Rust, musl estático) y
  `server/bin/lc-coop-relay-linux-x86_64` (~409 KB, sin Python). Es el **relay**,
  no un servidor de juego.
- **Servidor dedicado del juego**: el build instalado solo trae el cliente
  (`VoyageSteam-Win64-Shipping.exe`), no un `VoyageServer`. Un dedicado que hostee
  el mundo requeriría el server target de UE5 o reimplementar el juego; el relay
  solo reenvía paquetes. Un "host dedicado" con GPU sí es posible: correr el juego
  normal en una PC servidor y que el otro se conecte con el mod.
- **Prueba solo**: `scripts/relay_test.sh` levanta relay + bot; en el juego
  `relay:127.0.0.1:27020`.

### Fixes de UI/entrada

- `local_ips()` ahora incluye **todas** las IPs (hostname -I + `tailscale ip`) →
  se evita el **loopback** cuando el peer es la propia máquina (te veías duplicado).
- El ghost ya **no congela el tick** (se veía en pose de caída); sin gravedad,
  colisión, daño ni audio.
- **Escape** cierra el menú in-game y restaura el input (mouse/GameOnly).
- Se desactivó **`ConsoleEnablerMod`** (la consola in-game capturaba mouse/cámara).
