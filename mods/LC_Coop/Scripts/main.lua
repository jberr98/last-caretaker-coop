--[[
    LC_Coop — main.lua
    Fork mejorado del PoC "MultiplayerSync" de skelegamerYT11.
    Fase 1: sincronizar la posición de los jugadores (verse) + puertas (extra).

    Corre dentro de UE4SS (Lua). No hace red: lee/escribe archivos IPC que un
    sidecar nativo (sidecar/coop_net.py) convierte en UDP.
]]

local config = require("config")
local UEHelpers = require("UEHelpers")
local debugLog = require("debug_log")

local PREFIX = "[LC_Coop] "

local function log(msg)
    debugLog.add("[MOD] ", msg)
    if config.verbose then print(PREFIX .. msg) end
end

-- Limpiar estado IPC viejo al cargar (evita un ghost "fantasma" tras reiniciar).
pcall(function() local f = io.open(config.coordsIn, "w"); if f then f:close() end end)
pcall(function() local f = io.open(config.eventIn, "w"); if f then f:close() end end)
pcall(function() local f = io.open(config.chatIn or "chat_in.txt", "w"); if f then f:close() end end)
pcall(function() local f = io.open(config.chatOut or "chat_out.txt", "w"); if f then f:close() end end)

-- Configuración que lee el sidecar al arrancar (radio del chat y nombre).
pcall(function()
    local r = tonumber(config.chatRadius) or 2500
    if r < 0 then r = 0 end
    if r > 100000 then r = 100000 end
    local f = io.open("lc_chat_radius.txt", "w")
    if f then f:write(string.format("%.0f\n", r)); f:close() end

    local name = tostring(config.playerName or "")
    name = name:gsub("[;\r\n\t]", " ")
    name = name:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 32)
    if name ~= "" then
        local g = io.open("lc_player_name.txt", "w")
        if g then g:write(name .. "\n"); g:close() end
    end
end)

-- Detectar si corremos bajo Proton/Wine (Linux) o Windows nativo.
-- Bajo Proton, WINEPREFIX/STEAM_COMPAT_DATA_PATH están definidos y Wine mapea
-- la raíz Unix en Z:. En Windows nativo no debería existir ninguno de los dos.
local function isProton()
    local prefix = os.getenv("WINEPREFIX")
    if prefix and prefix ~= "" then return true end
    if os.getenv("STEAM_COMPAT_DATA_PATH") then return true end
    local f = io.open("Z:\\etc\\os-release", "r")
    if f then f:close(); return true end
    return false
end

-- Auto-lanzar el sidecar (una vez por sesión; no se repite en hot-reload).
-- Se ejecuta SOLO el comando de la plataforma actual: lanzar también el de la
-- otra plataforma deja procesos Wine colgados y una consola abierta.
if config.autoStartSidecar then
    local launched = false
    pcall(function() launched = Mod:GetSharedVariable("lc_sidecar_launched") end)
    if not launched then
        local onProton = isProton()
        local cmd = onProton and config.sidecarCmdLinux or config.sidecarCmdWindows
        if cmd and cmd ~= "" then
            pcall(function() os.execute(cmd) end)
            log("sidecar auto-lanzado (" .. (onProton and "Proton" or "Windows") .. ")")
        end
        pcall(function() Mod:SetSharedVariable("lc_sidecar_launched", true) end)
    end
end

-- Estado persistente (¡fuera del loop! el PoC lo tenía mal ubicado)
local ghost = nil
local ghostClass = nil
local spawnFailAt = 0
local lastRemote = nil
local lastMoveLogAt = 0
local lastLightSyncAt = 0
local peerSim = false
local peerSimAngle = 0
local connectUI = nil
local chatUI = nil
local debugOverlay = nil
local currentArea = "?"
local pendingLocal = nil
local lastSent = { x = nil, y = nil, z = nil, yaw = nil }
local lastRecvSeq = -1
local lastRecvAt = 0
local lastReceivedDoorStates = {}
local lastSentDoorStates = {}
local outSeq = 0

local function now()
    return os.time()
end

-- =====================================================================
-- Lectura / escritura de archivos IPC
-- =====================================================================

local function readCoordsIn()
    local f = io.open(config.coordsIn, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data or data == "" then return nil end
    -- formato: x,y,z,yaw,seq[,area]
    local xs, ys, zs, yaws, seqs, areas = string.match(data,
        "([^,]+),([^,]+),([^,]+),([^,]+),([^,]*),?([^,\r\n]*)")
    if not xs then return nil end
    -- Si el servidor manda el área y no coincide, no aplicar el ghost.
    if areas and areas ~= "" and areas ~= "?"
        and currentArea and currentArea ~= "?" and areas ~= currentArea then
        return nil
    end
    -- Sin filtro por seq: los contadores se reinician al reiniciar el peer/juego.
    -- El archivo siempre contiene el último estado, así que aplicamos siempre.
    return {
        x = tonumber(xs), y = tonumber(ys), z = tonumber(zs),
        yaw = tonumber(yaws) or 0, seq = tonumber(seqs) or 0,
        area = areas or "",
    }
end

local function writeCoordsOut(s)
    if s.x == lastSent.x and s.y == lastSent.y and s.z == lastSent.z and s.yaw == lastSent.yaw then
        return -- sin cambios, no ensuciamos el disco
    end
    lastSent = s
    outSeq = outSeq + 1
    local f = io.open(config.coordsOut, "w")
    if not f then return end
    f:write(("%s,%s,%s,%s,%d"):format(
        tostring(s.x), tostring(s.y), tostring(s.z), tostring(s.yaw), outSeq))
    f:close()
end

local function drainEventsIn()
    local f = io.open(config.eventIn, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local g = io.open(config.eventIn, "w")
    if g then g:close() end -- limpiar ya, incluso si falla el parseo
    local events = {}
    if data and data ~= "" then
        for line in data:gmatch("[^\r\n]+") do events[#events + 1] = line end
    end
    return events
end

local function emitEventRaw(kind, name, value)
    local f = io.open(config.eventOut, "a")
    if not f then return end
    f:write(("%s,%s,%s\n"):format(kind, name, tostring(value)))
    f:close()
end

local function emitEvent(kind, name, value)
    local key = kind .. ":" .. name
    if lastSentDoorStates[key] == value then return end
    lastSentDoorStates[key] = value
    emitEventRaw(kind, name, value)
    log("evento enviado: " .. kind .. " " .. name .. " -> " .. tostring(value))
end

-- =====================================================================
-- Fase 3: contenedores compartidos (solo ADD)
-- =====================================================================

local applyingRemote = false
local handleContainerEvent = nil
local scheduleContainerSnapshot = nil
local lastContainerId = nil
local lastContainerInv = nil

local function container_id_from_actor(actor)
    if not actor or not actor:IsValid() then return nil end
    local cls = nil
    pcall(function() cls = actor:GetClass():GetFullName() end)
    if not cls then return nil end
    -- Excluir al jugador: sus inventarios no son contenedores compartidos.
    local low = cls:lower()
    if low:find("character", 1, true)
        or low:find("playercontroller", 1, true)
        or low:find("playerstate", 1, true) then return nil end
    local ppa = nil
    pcall(function() ppa = actor["VoyagePersistentActor"] end)
    if not ppa then return nil end
    local id = nil
    pcall(function() id = ppa["PersistentUniqueId"] end)
    if id == nil then pcall(function() id = ppa["PersistentUniqueIdRuntime"] end) end
    return id
end

local function container_id_of_inventory(inv)
    local actor = nil
    pcall(function() actor = inv:GetOwner() end)
    if not actor or not actor:IsValid() then
        pcall(function() actor = inv:GetOuter() end)
    end
    return container_id_from_actor(actor)
end

local function clean_path(p)
    if not p then return nil end
    local i = p:find(" ", 1, true)
    if i then return p:sub(i + 1) end
    return p
end

local function on_container_add(inv, asset)
    if applyingRemote then return end
    local id = container_id_of_inventory(inv)
    if id == nil then return end
    lastContainerId = id
    lastContainerInv = inv
    local raw = nil
    pcall(function() raw = asset:GetFullName() end)
    local path = clean_path(raw)
    if not path then return end
    emitEvent("INV", tostring(id), path)
    log("contenedor " .. tostring(id) .. " + " .. path)
    if scheduleContainerSnapshot then
        scheduleContainerSnapshot(inv)
    end
end

local function find_container_inventory(id)
    for _, inv in pairs(FindAllOf("VoyageBaseInventoryComponent") or {}) do
        local cid = container_id_of_inventory(inv)
        if cid ~= nil and tostring(cid) == tostring(id) then return inv end
    end
    return nil
end

local function apply_add_to_inv(inv, path)
    local asset = StaticFindObject(clean_path(path) or path)
    if not asset or not asset:IsValid() then
        log("INV: asset no encontrado " .. tostring(path))
        return
    end
    applyingRemote = true
    local ok, err = pcall(function() inv:AddItem(asset, nil, true, true) end)
    applyingRemote = false
    if ok then log("INV aplicado: + " .. path)
    else log("INV error: " .. tostring(err)) end
end

local function apply_inventory_event(id, path)
    local inv = find_container_inventory(id)
    if not inv then
        log("INV: contenedor " .. tostring(id) .. " no encontrado")
        return
    end
    apply_add_to_inv(inv, path)
end

-- =====================================================================
-- Acceso al juego (solo dentro del game thread)
-- =====================================================================

local function getLocalState()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return nil end
    local pawn = PC.Pawn
    if not pawn or not pawn:IsValid() then return nil end
    local loc = pawn:K2_GetActorLocation()
    local rot = pawn:K2_GetActorRotation()
    if not loc then return nil end
    local yaw = 0
    if rot then yaw = rot.Yaw or rot.yaw or 0 end
    return { x = loc.X or loc.x or 0, y = loc.Y or loc.y or 0, z = loc.Z or loc.z or 0, yaw = yaw }
end

-- Área/dimensión actual: mundo + nivel (streaming). Sirve para no mezclar
-- jugadores que están en mapas/dimensiones distintas.
local lastAreaWritten = nil

local function getAreaName()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return "menu" end
    local world = nil
    pcall(function() world = PC:GetWorld() end)
    if not world or not world:IsValid() then return "?" end
    local worldName = nil
    pcall(function() worldName = world:GetName() end)
    if not worldName then
        pcall(function() worldName = world:GetFName():ToString() end)
    end
    local levelName = nil
    local pawn = PC.Pawn
    if pawn and pawn:IsValid() then
        pcall(function()
            local lvl = pawn:GetLevel()
            if lvl and lvl:IsValid() then
                local outer = lvl:GetOuter()
                if outer and outer:IsValid() then
                    levelName = outer:GetName()
                end
            end
        end)
    end
    local s = tostring(worldName or "?")
    if levelName and tostring(levelName) ~= "" then
        s = s .. "/" .. tostring(levelName)
    end
    s = s:gsub("[,;%s]", "_")
    if #s > 40 then s = s:sub(1, 40) end
    return s
end

local function writeAreaFile(area)
    if area == lastAreaWritten then return end
    lastAreaWritten = area
    local f = io.open(config.areaOut, "w")
    if f then
        f:write(area .. "\n")
        f:close()
    end
end

local function lerp(a, b, t) return a + (b - a) * t end

-- "Endurece" el ghost: sin colisión, sin audio, sin daño, sin gravedad.
local function harden_ghost(g)
    if not g or not g:IsValid() then return end
    pcall(function() g:SetActorEnableCollision(false) end)
    pcall(function() g:SetCanBeDamaged(false) end)
    -- sin gravedad (no cae) pero SIN congelar el tick (para que la animación muestre idle)
    pcall(function()
        local mv = g["CharacterMovement"]
        if mv then
            mv.GravityScale = 0
            pcall(function() mv:StopMovementImmediately() end)
            local mode = tonumber(config.ghostMovementMode)
            if mode == nil then mode = 1 end
            -- 0=MOVE_None, 1=MOVE_Walking. Walking + gravedad 0 evita la
            -- pose de caída en muchos personajes.
            pcall(function() mv:SetMovementMode(mode) end)
        end
    end)
    pcall(function()
        local audioClass = StaticFindObject("/Script/Engine.AudioComponent")
        for _, comp in pairs(g:K2_GetComponentsByClass(audioClass) or {}) do
            pcall(function() comp:Stop() end)
            pcall(function() comp:SetActive(false) end)
        end
    end)
end

-- Copia las luces del pawn local (linterna) al ghost. Es best-effort: si la
-- linterna es un actor separado, el ghost puede no tener el componente.
local lightClass = nil

local function get_lights(actor)
    local out = {}
    if not actor or not actor:IsValid() then return out end
    if not lightClass then
        lightClass = StaticFindObject("/Script/Engine.LightComponent")
    end
    if not lightClass then return out end
    pcall(function()
        for _, c in pairs(actor:K2_GetComponentsByClass(lightClass) or {}) do
            if c and c:IsValid() then out[#out + 1] = c end
        end
    end)
    return out
end

local function copy_light(src, dst)
    if not src or not dst then return end
    local vis = false
    pcall(function() vis = src:IsVisible() end)
    pcall(function() dst:SetVisibility(vis) end)
    pcall(function() dst:SetIntensity(src.Intensity) end)
    pcall(function() dst:SetLightColor(src.LightColor) end)
    pcall(function() dst:SetAttenuationRadius(src.AttenuationRadius) end)
    pcall(function() dst:SetInnerConeAngle(src.InnerConeAngle) end)
    pcall(function() dst:SetOuterConeAngle(src.OuterConeAngle) end)
    pcall(function() dst:SetTemperature(src.Temperature) end)
    pcall(function() dst:SetUseTemperature(src.bUseTemperature) end)
    pcall(function() dst:SetVolumetricScatteringIntensity(src.VolumetricScatteringIntensity) end)
    pcall(function() dst:SetCastShadows(src.CastShadows) end)
    pcall(function() dst:SetSourceRadius(src.SourceRadius) end)
    pcall(function() dst:SetSoftSourceRadius(src.SoftSourceRadius) end)
end

local function sync_flashlight()
    if config.syncFlashlight == false then return end
    if not ghost or not ghost:IsValid() then return end
    local PC = UEHelpers.GetPlayerController()
    local pawn = PC and PC.Pawn
    if not pawn or not pawn:IsValid() then return end
    local src = get_lights(pawn)
    if #src == 0 then return end
    local dstByName = {}
    for _, c in ipairs(get_lights(ghost)) do
        local n = nil
        pcall(function() n = c:GetFName():ToString() end)
        if n then dstByName[n] = c end
    end
    for _, l in ipairs(src) do
        local n = nil
        pcall(function() n = l:GetFName():ToString() end)
        if n and dstByName[n] then copy_light(l, dstByName[n]) end
    end
end

local function applyRemote(remote)
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end
    local World = PC:GetWorld()
    if not World or not World:IsValid() then return end

    if not ghost or not ghost:IsValid() then
        if now() - spawnFailAt < 2 then return end -- no reintentar cada tick
        spawnFailAt = now()
        local pawn = PC.Pawn
        if not pawn or not pawn:IsValid() then return end
        ghostClass = pawn:GetClass() -- SIEMPRE fresca (evita cachear la del menú)
        local loc = { X = remote.x, Y = remote.y, Z = remote.z }
        local rot = { Pitch = 0, Yaw = remote.yaw, Roll = 0 }
        ghost = World:SpawnActor(ghostClass, loc, rot)
        local cls = "?"
        pcall(function() cls = ghostClass:GetFullName() end)
        if ghost and ghost:IsValid() then
            harden_ghost(ghost)
            log("ghost spawneado OK (" .. cls .. ")")
        else
            log("spawn FALLO con clase " .. cls .. " en " ..
                string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z))
        end
        return
    end

    -- interpolación suave en vez de teletransporte seco
    local cur = ghost:K2_GetActorLocation()
    local t = config.interp
    local dest = {
        X = lerp(cur.X or cur.x, remote.x, t),
        Y = lerp(cur.Y or cur.y, remote.y, t),
        Z = lerp(cur.Z or cur.z, remote.z, t),
    }
    ghost:K2_TeleportTo(dest, { Pitch = 0, Yaw = remote.yaw, Roll = 0 })

    if now() - lastMoveLogAt >= 2 then
        lastMoveLogAt = now()
        log(string.format("ghost en %.0f,%.0f,%.0f  ->  objetivo %.0f,%.0f,%.0f",
            dest.X, dest.Y, dest.Z, remote.x, remote.y, remote.z))
    end
end

local function applyIncomingEvents(events)
    for _, line in ipairs(events) do
        local kind, name, valueStr = string.match(line, "([^,]+),([^,]+),(.*)")
        if kind == "DOOR" and name and config.syncDoors then
            local value = tonumber(valueStr)
            if value ~= nil and lastReceivedDoorStates[name] ~= value then
                lastReceivedDoorStates[name] = value
                for _, d in pairs(FindAllOf("VoyageDoorActor") or {}) do
                    if d:IsValid() and d:GetFName():ToString() == name then
                        pcall(function()
                            d.DoorStateDesired = value
                            d.DoorState = value
                            d:SetDoorPosition(value == 0 and 0.0 or 1.0, true)
                        end)
                        log("puerta sincronizada: " .. name .. " -> " .. tostring(value))
                    end
                end
            end
        elseif kind == "INV" and name and config.syncContainers then
            apply_inventory_event(name, valueStr)
        elseif kind == "PEER_OFFLINE" then
            if ghost and ghost:IsValid() then
                pcall(function() ghost:K2_DestroyActor() end)
            end
            ghost = nil
            lastRemote = nil
            log("peer offline: ghost eliminado")
        elseif kind == "CONT" then
            if handleContainerEvent then
                pcall(handleContainerEvent, name, valueStr)
            end
        elseif kind == "STAT" then
            log("[STAT remoto] " .. tostring(name) .. " | " .. tostring(valueStr))
        end
    end
end

-- =====================================================================
-- Estado transmitido (diagnóstico remoto): el mod manda su estado cada ~5s.
-- Así el otro ve, en SU log, si te recibe y con qué datos.
-- =====================================================================
local statSeq = 0
local lastStatAt = 0
local lastDebugAt = 0
local lastAreaCheckAt = 0

local function read_trim(path)
    local f = io.open(path, "r")
    if not f then return "?" end
    local d = f:read("*a") or ""
    f:close()
    d = d:gsub("%s+", "")
    return d
end

local function emit_status()
    statSeq = statSeq + 1
    local s = getLocalState()
    local world = s and "world" or "menu"
    local out = read_trim(config.coordsOut)
    local incoming = read_trim(config.coordsIn)
    local hasGhost = (ghost and ghost:IsValid()) and "1" or "0"
    local payload = string.format("seq=%d out=%s in=%s ghost=%s", statSeq, out, incoming, hasGhost)
    local f = io.open(config.eventOut, "a")
    if f then
        f:write(string.format("STAT,%s,%s\n", world, payload))
        f:close()
    end
end

-- =====================================================================
-- Loop principal
-- =====================================================================

log("iniciado (Fase 1: movimiento). verbose=" .. tostring(config.verbose))

LoopAsync(config.intervalMs, function()
    -- 1) leer remoto (sin game thread)
    local remote = readCoordsIn()
    local events = drainEventsIn()
    if remote then lastRemote = remote end

    -- 2) game thread: leer local + aplicar remoto
    ExecuteInGameThread(function()
        local s = getLocalState()
        if s then pendingLocal = s end
        debugLog.set("world", s and "world" or "menu")
        if s then
            debugLog.set("local", string.format("%.1f,%.1f,%.1f", s.x, s.y, s.z))
        end
        local area = currentArea
        if lastAreaCheckAt == 0 or now() - lastAreaCheckAt >= 1 then
            lastAreaCheckAt = now()
            area = getAreaName()
        end
        if area ~= currentArea then
            currentArea = area
            writeAreaFile(area)
            debugLog.set("area", area)
            log("área actual: " .. area)
            if ghost and ghost:IsValid() then
                pcall(function() ghost:K2_DestroyActor() end)
            end
            ghost = nil
            lastRemote = nil
        end
        -- Simulador de peer: si está activo, el "otro jugador" orbita alrededor.
        if peerSim and pendingLocal then
            peerSimAngle = peerSimAngle + 0.05
            lastRemote = {
                x = pendingLocal.x + 300 * math.cos(peerSimAngle),
                y = pendingLocal.y + 300 * math.sin(peerSimAngle),
                z = pendingLocal.z,
                yaw = (peerSimAngle * 57.29577951308232) % 360,
            }
        end
        if lastRemote then applyRemote(lastRemote) end
        if now() - lastLightSyncAt >= 0.5 then
            lastLightSyncAt = now()
            pcall(sync_flashlight)
        end
        debugLog.set("ghost", (ghost and ghost:IsValid()) and "OK" or "NO")
        if lastRemote then
            debugLog.set("remote", string.format("%.1f,%.1f,%.1f",
                lastRemote.x, lastRemote.y, lastRemote.z))
        end
        if #events > 0 then applyIncomingEvents(events) end
        if connectUI then pcall(function() connectUI.poll() end) end
        if chatUI then pcall(function() chatUI.poll() end) end
        if debugOverlay then pcall(function() debugOverlay.poll() end) end
        if now() - lastDebugAt >= 5 then
            lastDebugAt = now()
            debugLog.add("[MOD] ", string.format(
                "world=%s ghost=%s local=%s remote=%s",
                debugLog.get("world") or "?", debugLog.get("ghost") or "?",
                debugLog.get("local") or "?", debugLog.get("remote") or "?"))
        end
        if now() - lastStatAt >= 5 then
            lastStatAt = now()
            pcall(emit_status)
        end
    end)

    -- 3) escribir local (sin game thread)
    if pendingLocal then writeCoordsOut(pendingLocal) end

    return false -- seguir
end)

-- =====================================================================
-- Hooks de eventos (puertas) — Fase 2, experimentales
-- =====================================================================

if config.syncDoors then
    pcall(function()
        RegisterHook("/Script/Voyage.VoyageDoorActor:SetDoorState", function(Context)
            pcall(function()
                local obj = Context:get()
                if not obj or not obj:IsValid() then return end
                local name = obj:GetFName():ToString()
                local value = obj.DoorStateDesired
                if value == nil then value = obj.DoorState end
                if value ~= nil then emitEvent("DOOR", name, value) end
            end)
        end)
        log("hook de puertas registrado")
    end)
end

-- =====================================================================
-- Hook de contenedores — Fase 3 (solo ADD)
-- =====================================================================

if config.syncContainers or config.saveContainers then
    local function arg_text(a)
        if a == nil then return "nil" end
        local g = nil
        pcall(function() g = a:get() end)
        if g ~= nil then
            local n = nil
            pcall(function() n = g:GetFullName() end)
            if n ~= nil then return n end
            return tostring(g)
        end
        local n = nil
        pcall(function() n = a:GetFullName() end)
        if n ~= nil then return n end
        return tostring(a)
    end

    local function dbg(label, ctx_obj, ...)
        local cls = "?"
        pcall(function() cls = ctx_obj:GetClass():GetFullName() end)
        log("[inv] " .. label .. "  ctx=" .. cls)
        for i = 1, select("#", ...) do
            log("[inv]   arg" .. i .. " = " .. arg_text(select(i, ...)))
        end
    end

    -- Cuenta ítems de un inventario como multiset {assetPath -> cantidad}.
    local function item_multiset(inv)
        local m = {}
        local all = nil
        pcall(function() all = inv:GetAllItems() end)
        if type(all) ~= "table" then return m end
        for _, e in pairs(all) do
            local g = nil
            pcall(function() g = e:get() end)
            local n = nil
            pcall(function() n = (g or e):GetFullName() end)
            n = clean_path(n)
            if n then m[n] = (m[n] or 0) + 1 end
        end
        return m
    end

    local pendingTransfer = {}

    local function ms_total(m)
        local s = 0
        for _, c in pairs(m) do s = s + c end
        return s
    end

    local pendingContainerSnapshots = {}
    local snapshotScheduled = {}

    local function count_items(items)
        local n = 0
        for _, c in pairs(items) do n = n + c end
        return n
    end

    local function emit_container_snapshot(inv)
        if not inv or not inv:IsValid() then return end
        local id = container_id_of_inventory(inv)
        if id == nil then return end
        local key = tostring(id)
        local area = currentArea or "?"
        local m = item_multiset(inv)
        emitEventRaw("CONT", key, area .. ";BEGIN;0")
        for path, cnt in pairs(m) do
            emitEventRaw("CONT", key,
                area .. ";ITEM;" .. path .. ";" .. tostring(cnt))
        end
        emitEventRaw("CONT", key, area .. ";END;0")
        log("snapshot contenedor " .. key .. " items=" .. ms_total(m) ..
            " area=" .. area)
    end

    local function schedule_container_snapshot(inv)
        if not inv or not inv:IsValid() then return end
        local id = container_id_of_inventory(inv)
        if id == nil then return end
        local key = tostring(id)
        if snapshotScheduled[key] then return end
        snapshotScheduled[key] = true
        ExecuteWithDelay(300, function()
            snapshotScheduled[key] = false
            ExecuteInGameThread(function()
                if inv:IsValid() then emit_container_snapshot(inv) end
            end)
        end)
    end
    scheduleContainerSnapshot = schedule_container_snapshot

    local function apply_container_snapshot(id, snap)
        local inv = find_container_inventory(id)
        if not inv then
            log("CONT: contenedor no encontrado " .. tostring(id))
            return
        end
        applyingRemote = true
        local ok = pcall(function() inv:ClearItems() end)
        if not ok then
            applyingRemote = false
            log("CONT: ClearItems fallo en " .. tostring(id))
            return
        end
        for path, cnt in pairs(snap.items) do
            local asset = StaticFindObject(clean_path(path) or path)
            if asset and asset:IsValid() then
                for _ = 1, cnt do
                    pcall(function() inv:AddItem(asset, nil, true, true) end)
                end
            else
                log("CONT: asset no encontrado " .. tostring(path))
            end
        end
        applyingRemote = false
        log("CONT aplicado: " .. tostring(id) ..
            " items=" .. count_items(snap.items))
    end

    handleContainerEvent = function(id, rest)
        local parts = {}
        for p in rest:gmatch("[^;]+") do parts[#parts + 1] = p end
        local area = parts[1] or "?"
        local op = parts[2] or ""
        if currentArea and currentArea ~= "?" and area ~= "?"
            and area ~= currentArea then
            return
        end
        if op == "BEGIN" then
            pendingContainerSnapshots[id] = { area = area, items = {} }
        elseif op == "ITEM" then
            local snap = pendingContainerSnapshots[id]
            if not snap then return end
            local path = parts[3]
            local cnt = tonumber(parts[4])
            if path and cnt and cnt > 0 then
                snap.items[path] = cnt
            end
        elseif op == "END" then
            local snap = pendingContainerSnapshots[id]
            pendingContainerSnapshots[id] = nil
            if not snap then return end
            log("snapshot de contenedor recibido: " .. tostring(id) ..
                " items=" .. count_items(snap.items) .. " area=" .. area)
            if config.syncContainers then
                apply_container_snapshot(id, snap)
            end
        end
    end

    -- Tras un TransferSlot, compara el destino antes/después y emite lo agregado.
    local function on_transfer_slot(src, dest, slot)
        if applyingRemote then return end
        if config.saveContainers then
            schedule_container_snapshot(src)
            schedule_container_snapshot(dest)
        end
        local destId = container_id_of_inventory(dest)
        if destId == nil then
            log("[xfer] destino no es contenedor (sin id); slot=" .. tostring(slot))
            return
        end
        lastContainerId = destId
        lastContainerInv = dest
        local key = tostring(destId)
        if pendingTransfer[key] then return end
        pendingTransfer[key] = true
        local before = item_multiset(dest)
        log("[xfer] contenedor " .. key .. " antes=" .. ms_total(before))
        ExecuteWithDelay(250, function()
            pendingTransfer[key] = false
            ExecuteInGameThread(function()
                local inv = find_container_inventory(destId)
                if not inv then
                    log("[xfer] no encontre el contenedor " .. key)
                    return
                end
                local after = item_multiset(inv)
                log("[xfer] contenedor " .. key .. " despues=" .. ms_total(after))
                for item, c in pairs(after) do
                    local delta = c - (before[item] or 0)
                    if delta > 0 then
                        for _ = 1, delta do
                            emitEvent("INV", key, item)
                        end
                        log("transfer -> contenedor " .. key .. " + " .. item .. " x" .. delta)
                    end
                end
            end)
        end)
    end

    local function reg(path, label)
        pcall(function()
            RegisterHook(path, function(Context, ...)
                local inv = Context:get()
                if not inv or not inv:IsValid() then return end
                if label == "AddItem" then
                    local item = select(1, ...)
                    if item then
                        local asset = item
                        pcall(function()
                            local g = item:get(); if g ~= nil then asset = g end
                        end)
                        on_container_add(inv, asset)
                    end
                elseif label == "TransferSlot" then
                    local dest = select(1, ...)
                    local slot = select(2, ...)
                    local slotNum = nil
                    pcall(function() slotNum = slot:get() end)
                    if dest then
                        pcall(function()
                            local g = dest:get(); if g ~= nil then dest = g end
                        end)
                    end
                    on_transfer_slot(inv, dest, slotNum)
                end
                if config.saveContainers and scheduleContainerSnapshot then
                    scheduleContainerSnapshot(inv)
                end
                if config.debugInventory then dbg(label, inv, ...) end
            end)
        end)
    end

    reg("/Script/Voyage.VoyageBaseInventoryComponent:AddItem", "AddItem")
    reg("/Script/Voyage.VoyageBaseInventoryComponent:AddItems", "AddItems")
    reg("/Script/Voyage.VoyageBaseInventoryComponent:AddItemsWithData", "AddItemsWithData")
    reg("/Script/Voyage.VoyageBaseInventoryComponent:TransferItems", "TransferItems")
    reg("/Script/Voyage.VoyageBaseInventoryComponent:TransferSlot", "TransferSlot")
    reg("/Script/Voyage.VoyageBaseInventoryComponent:StackSlot", "StackSlot")
    log("hooks de inventario registrados")
end

-- =====================================================================
-- Simulador de peer in-game (probar coop sin segunda máquina)
-- =====================================================================
if config.simulatePeer then
    local SIM_ITEMS = {
        "/Game/Data/Assets/Trash/RandomScraps/DA_Fabric_Scraps.DA_Fabric_Scraps",
        "/Game/Data/Assets/MaterialsFood/DA_Material_Bio_Waste.DA_Material_Bio_Waste",
    }

    RegisterKeyBind(Key.F7, function()
        peerSim = not peerSim
        log("SIM peer (ghost orbitando): " .. tostring(peerSim))
    end)

    RegisterKeyBind(Key.F8, function()
        ExecuteInGameThread(function()
            if not lastContainerInv or not lastContainerInv:IsValid() then
                log("SIM: todavia no interactuaste con ningun contenedor")
                return
            end
            local item = SIM_ITEMS[1]
            pcall(function() apply_add_to_inv(lastContainerInv, item) end)
            log("SIM: peer agrego " .. item .. " al contenedor " .. tostring(lastContainerId))
        end)
    end)

    log("simulador de peer: F7 = ghost orbitando, F8 = peer agrega item al contenedor mas cercano")
end

-- =====================================================================
-- Conexión desde el juego:  lc_connect <IP>  (escribe lc_peer.txt)
-- El sidecar lee ese archivo y se conecta/reconecta a esa IP.
-- =====================================================================
local function write_peer_file(ip)
    local f = io.open("lc_peer.txt", "wb")
    if not f then return false end
    f:write(ip .. "\n")
    f:close()
    return true
end

local function read_net_status()
    local f = io.open("lc_net_status.txt", "r")
    if not f then return nil end
    local d = f:read("*a") or ""
    f:close()
    local t = {}
    for line in d:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = v end
    end
    return t
end

pcall(function()
    RegisterConsoleCommandHandler("lc_connect", function(cmd, params, ar)
        local ip = params and params[1]
        if not ip or ip == "" then
            log("uso: lc_connect <IP>  (ej: lc_connect 100.64.0.2)")
            return true
        end
        if write_peer_file(ip) then log("conectando a " .. ip .. " ...")
        else log("no pude escribir lc_peer.txt") end
        return true
    end)

    RegisterConsoleCommandHandler("lc_disconnect", function(cmd, params, ar)
        write_peer_file("")
        log("desconectado")
        return true
    end)

    RegisterConsoleCommandHandler("lc_status", function(cmd, params, ar)
        local f = io.open("lc_peer.txt", "r")
        local ip = f and f:read("*a") or ""
        if f then f:close() end
        ip = ip:gsub("%s+", "")
        log("peer configurado: " .. (ip ~= "" and ip or "(ninguno)"))
        local st = read_net_status()
        if st then
            local estado = st.state or "?"
            if estado == "confirmed" then estado = "confirmado (ACK)"
            elseif estado == "one_way" then estado = "solo recepcion (sin ACK)"
            elseif estado == "waiting" then estado = "esperando"
            elseif estado == "no_peer" then estado = "sin peer"
            elseif estado == "stopped" then estado = "sidecar detenido" end
            log(string.format(
                "estado: %s | peer=%s (%s) | rx_pos=%s tx_pos=%s | pos_hace=%ss",
                estado, st.peer_addr or "?", st.peer_name or "",
                st.rx_pos or "0", st.tx_pos or "0", st.last_pos_age or "-1"))
            if st.mode == "server" then
                log(string.format(
                    "servidor: online=%s otros=%s guardados=%s contenedores=%s area=%s",
                    st.server_online_players or "0", st.server_players or "0",
                    st.server_saved_players or "0", st.server_saved_containers or "0",
                    st.local_area or "?"))
            end
            log(string.format(
                "chat: tx=%s rx=%s radio=%s (servidor=%s)",
                st.chat_tx or "0", st.chat_rx or "0", st.chat_radius or "?",
                st.server_chat_radius or "-"))
        else
            log("sidecar sin estado (lc_net_status.txt no existe)")
        end
        return true
    end)

    RegisterConsoleCommandHandler("lc_lights", function(cmd, params, ar)
        local PC = UEHelpers.GetPlayerController()
        local function dump(label, actor)
            if not actor or not actor:IsValid() then
                log(label .. ": sin actor")
                return
            end
            local cls = StaticFindObject("/Script/Engine.LightComponent")
            local n = 0
            local lights = nil
            pcall(function() lights = actor:K2_GetComponentsByClass(cls) end)
            for _, c in pairs(lights or {}) do
                n = n + 1
                local name, cname, intensity, vis = "?", "?", -1, false
                pcall(function() name = c:GetFName():ToString() end)
                pcall(function() cname = c:GetClass():GetFullName() end)
                pcall(function() intensity = c.Intensity end)
                pcall(function() vis = c:IsVisible() end)
                log(string.format("%s luz %d: %s (%s) intensity=%s visible=%s",
                    label, n, name, cname, tostring(intensity), tostring(vis)))
            end
            log(label .. ": luces=" .. n)
        end
        dump("local", PC and PC.Pawn)
        dump("ghost", ghost)
        return true
    end)

    RegisterConsoleCommandHandler("lc_name", function(cmd, params, ar)
        local name = table.concat(params or {}, " ")
        name = name:gsub("[;\r\n\t]", " ")
        name = name:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 32)
        if name == "" then
            log("uso: lc_name <nombre>")
            return true
        end
        local f = io.open("lc_player_name.txt", "w")
        if f then
            f:write(name .. "\n")
            f:close()
            log("nombre de chat: " .. name)
        else
            log("no pude escribir lc_player_name.txt")
        end
        return true
    end)
    log("comandos in-game: lc_connect <IP> | lc_disconnect | lc_status | lc_name <nombre> | lc_lights")
end)

-- =====================================================================
-- Menú in-game (widget UMG): F9 abre/cierra, F11 conecta a la IP escrita.
-- =====================================================================
pcall(function()
    local ui = require("connect_ui")
    connectUI = ui
    RegisterKeyBind(Key.F9, function()
        if chatUI then pcall(function() chatUI.close(false) end) end
        pcall(function() ui.toggle() end)
    end)
    RegisterKeyBind(Key.F11, function() pcall(function() ui.connect_from_box() end) end)
    RegisterKeyBind(Key.ESCAPE, function() pcall(function() ui.close() end) end)
    log("menú in-game: F9 = abrir/cerrar, F11 o botón = conectar, ESC = cerrar")
end)

-- =====================================================================
-- Chat de proximidad/global: Enter local, Ctrl+Enter global, Tab canal.
-- =====================================================================
if config.chatEnabled ~= false then
    pcall(function()
        local chat = require("chat_ui")
        chatUI = chat
        local function enter_chat(global)
            if connectUI and connectUI.is_open() then return end
            pcall(function() chat.on_enter(global) end)
        end
        RegisterKeyBind(Key.RETURN, function() enter_chat(false) end)
        RegisterKeyBind(Key.RETURN, { ModifierKey.CONTROL }, function()
            enter_chat(true)
        end)
        RegisterKeyBind(Key.TAB, function()
            if connectUI and connectUI.is_open() then return end
            if chat.is_open() then
                pcall(function() chat.toggle_mode() end)
            end
        end)
        RegisterKeyBind(Key.ESCAPE, function()
            pcall(function() chat.close(false) end)
        end)
        log("chat: Enter = local, Ctrl+Enter = global, Tab = canal, Esc = cerrar")
    end)
end

-- Overlay de debug en vivo: Ctrl + debugKey (F6 por defecto; F1-F4 los usa KDE).
if config.debugOverlay ~= false then
    pcall(function()
        local overlay = require("debug_overlay")
        debugOverlay = overlay
        local keyName = config.debugKey or "F6"
        local key = (Key and Key[keyName]) or Key.F1
        RegisterKeyBind(key, { ModifierKey.CONTROL }, function()
            pcall(function() overlay.toggle() end)
        end)
        log("debug overlay: Ctrl+" .. tostring(keyName) .. " (red + logs en pantalla)")
    end)
end

-- (UE4SS descarga el mod automáticamente al cerrar el juego)

-- Reconocimiento temporal (Fase 3)
if config.recon then
    pcall(function() require("recon").run() end)
end
