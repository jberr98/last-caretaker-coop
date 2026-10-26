-- Configuración de LC_Coop
-- Los archivos IPC son relativos al working directory del juego:
--   ~/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64/
-- El sidecar debe apuntar a la MISMA carpeta (parámetro --dir).

return {
    -- Archivos IPC
    coordsOut = "coords_out.txt",  -- vos -> sidecar
    coordsIn  = "coords_in.txt",   -- sidecar -> vos
    areaOut   = "area_out.txt",    -- área/dimensión actual (para el servidor)
    eventOut  = "event_out.txt",
    eventIn   = "event_in.txt",
    chatOut   = "chat_out.txt",    -- vos -> sidecar (mensajes que enviás)
    chatIn    = "chat_in.txt",     -- sidecar -> vos (mensajes recibidos)

    -- Ajustes de sincronización
    intervalMs   = 16,    -- cada cuánto corre el loop (16 ms = ~60 Hz)
    interp       = 0.35,  -- 0..1 suavizado del ghost
    spawnZOffset = 50.0,  -- elevar el ghost para evitar que se hunda
    -- Modo de movimiento del ghost: 0 = None, 1 = Walking. Con gravedad 0,
    -- Walking suele mostrar idle en vez de la pose de caída.
    ghostMovementMode = 1,
    -- Copiar las luces (linterna) del pawn local al ghost.
    syncFlashlight = true,

    -- Logging
    verbose = true,

    -- Overlay de debug en vivo: Ctrl + debugKey (por defecto Ctrl+F6).
    -- Muestra estado de red, ghost, coords y las últimas líneas de logs.
    debugOverlay = true,
    debugKey = "F6",
    debugScale = 0.58,  -- tamaño visual del overlay (0.5 = chico, 1.0 = grande)

    -- Puertas (Fase 2, experimental). Poné false si querés solo movimiento.
    syncDoors = true,

    -- Contenedores: reportar snapshots al servidor (save persistente).
    saveContainers = true,
    -- Aplicar snapshots de contenedores del servidor (experimental; puede
    -- limpiar/duplicar ítems si los mundos no coinciden).
    syncContainers = false,

    -- Chat de proximidad (LOCAL) y global (GLOBAL).
    -- Entrar: Enter = local, Ctrl+Enter = global. Tab cambia de canal.
    -- El LOCAL solo llega a jugadores de la misma área/dimensión y dentro de
    -- chatRadius. 1 unidad UE = 1 cm, así que 2500 = 25 m.
    chatEnabled = true,
    chatRadius = 2500,
    chatMaxLen = 240,
    chatToastSeconds = 8,
    -- Nombre visible en el chat. Vacío = hostname del sidecar.
    -- También se puede cambiar en caliente con: lc_name <nombre>
    playerName = "",

    -- Log detallado de toda mutación de inventario (diagnóstico Fase 3).
    debugInventory = false,

    -- Simulador de peer in-game (F7 = ghost orbitando, F8 = peer agrega item).
    simulatePeer = true,

    -- Auto-lanzar el sidecar al entrar al juego (sin ventana de terminal).
    -- Linux/Proton: el script usa setsid y redirige stdio, así la consola que
    -- Wine crea para cmd.exe se cierra enseguida y no queda pegada al juego.
    autoStartSidecar = true,
    -- Comando para Linux/Proton. scripts/install.sh reemplaza los placeholders
    -- __LC_COOP_PROJECT__ y __LC_COOP_GAME_BIN__ en la copia instalada. Si
    -- copiás el mod a mano, editá esta línea con tus rutas absolutas.
    sidecarCmdLinux = 'start /unix /bin/sh __LC_COOP_PROJECT__/scripts/launch_sidecar.sh __LC_COOP_GAME_BIN__',
    -- Comando para Windows nativo (el .ps1 debe estar en la carpeta del juego):
    sidecarCmdWindows = 'start "" /b cmd /c run_sidecar_auto.bat "%CD%"',

    -- Reconocimiento de clases (temporal, para Fase 3: inventario).
    recon = false,
}
