-- debug_overlay.lua — overlay in-game de debug (Ctrl+F6).
-- Muestra estado de red, estado del ghost, coordenadas y las últimas líneas
-- de lc_sidecar.log y del log del mod (debug_log.lua).

local M = {}
local UEHelpers = require("UEHelpers")
local debugLog = require("debug_log")
local config = require("config")

local root = nil
local titleText = nil
local bodyText = nil
local lastRefresh = 0
local lastText = nil

local SIDECAR_LINES = 8
local MOD_LINES = 6
local MAX_CHARS = 88
local BODY_FONT_SIZE = 14
local TITLE_FONT_SIZE = 18
local OVERLAY_SCALE = tonumber((config and config.debugScale) or 0.58) or 0.58
if OVERLAY_SCALE < 0.30 then OVERLAY_SCALE = 0.30 end
if OVERLAY_SCALE > 1.00 then OVERLAY_SCALE = 1.00 end

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
end

local function set_text(tb, s)
    if not tb then return end
    safe(function() tb:SetText(FText(s)) end)
end

local function set_font_size(tb, size)
    if not tb then return end
    -- Solo modificamos la fuente existente: crear un FSlateFontInfo sin
    -- FontObject deja el TextBlock sin tamaño y el overlay invisible.
    safe(function()
        local font = tb:GetFont()
        font.Size = size
        tb:SetFont(font)
    end)
end

-- Recorta sin partir un carácter UTF-8 a la mitad.
local function clean(s, n)
    s = tostring(s or ""):gsub("\r", ""):gsub("\t", "    ")
    if #s <= n then return s end
    local cut = n
    while cut > 1 do
        local b = s:byte(cut)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut - 1) .. "..."
end

local function read_text(path, maxlen)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a") or ""
    f:close()
    d = d:gsub("[\r\n]+", " "):gsub("%s+$", "")
    return clean(d, maxlen or 70)
end

local function read_kv(path)
    local f = io.open(path, "r")
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

local function tail_lines(path, max_bytes, max_lines)
    local f = io.open(path, "r")
    if not f then return {} end
    local size = f:seek("end") or 0
    local start = math.max(0, size - (max_bytes or 8192))
    f:seek("set", start)
    local chunk = f:read("*a") or ""
    f:close()
    local lines = {}
    for line in chunk:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if start > 0 and #lines > 0 then
        table.remove(lines, 1) -- primera línea puede venir cortada
    end
    local out = {}
    local first = math.max(1, #lines - (max_lines or 16) + 1)
    for i = first, #lines do
        out[#out + 1] = clean(lines[i], MAX_CHARS)
    end
    return out
end

local function build_text()
    local lines = {}
    local st = read_kv("lc_net_status.txt")
    if st then
        local state = st.state or "?"
        local ts = tonumber(st.ts or "0") or 0
        if ts > 0 and state ~= "stopped" and os.time() - ts > 5 then
            state = state .. " (sin reportar)"
        end
        local peer = st.peer or ""
        local peerName = st.peer_name or ""
        if peer == "" then peer = "(sin configurar)" end
        if peerName ~= "" then peerName = " (" .. peerName .. ")" end
        lines[#lines + 1] = string.format(
            "NET  %s | peer=%s%s | addr=%s",
            state, clean(peer, 24), clean(peerName, 20),
            clean(st.peer_addr or "?", 30))
        lines[#lines + 1] = string.format(
            "     rx_pos=%s tx_pos=%s | ack=%ss pos=%ss | port=%s",
            st.rx_pos or "0", st.tx_pos or "0",
            st.last_ack_age or "-1", st.last_pos_age or "-1",
            st.listen_port or "?")
        if st.mode == "server" then
            local savedAt = tonumber(st.server_saved_at or "0") or 0
            local saveAge = savedAt > 0 and (os.time() - savedAt) or -1
            lines[#lines + 1] = string.format(
                "SRV  online=%s others=%s saved=%s cont=%s save_age=%ss",
                st.server_online_players or "0",
                st.server_players or "0", st.server_saved_players or "0",
                st.server_saved_containers or "0", saveAge)
        end
    else
        lines[#lines + 1] = "NET  sin lc_net_status.txt (sidecar no corriendo?)"
    end

    lines[#lines + 1] = string.format(
        "GAME area=%s world=%s ghost=%s | local=%s | remote=%s",
        clean(debugLog.get("area") or "?", 18),
        debugLog.get("world") or "?", debugLog.get("ghost") or "?",
        clean(debugLog.get("local") or "?", 24),
        clean(debugLog.get("remote") or "?", 24))
    lines[#lines + 1] = "IPC  out=" .. (read_text("coords_out.txt", 55) or "?") ..
        " | in=" .. (read_text("coords_in.txt", 55) or "?")

    lines[#lines + 1] = "---- SIDECAR (ultimas) ----"
    local sl = tail_lines("lc_sidecar.log", 8192, SIDECAR_LINES)
    if #sl == 0 then
        lines[#lines + 1] = "(sin lc_sidecar.log)"
    else
        for _, l in ipairs(sl) do lines[#lines + 1] = l end
    end

    lines[#lines + 1] = "---- MOD (ultimas) ----"
    local ml = debugLog.tail(MOD_LINES)
    if #ml == 0 then
        lines[#lines + 1] = "(sin logs del mod todavia)"
    else
        for _, l in ipairs(ml) do lines[#lines + 1] = clean(l, MAX_CHARS) end
    end
    return table.concat(lines, "\n")
end

function M.is_open()
    return root ~= nil and root:IsValid()
end

function M.close()
    if not M.is_open() then return end
    safe(function() root:RemoveFromViewport() end)
    root = nil; titleText = nil; bodyText = nil; lastText = nil; lastRefresh = 0
    debugLog.add("[DBG] ", "overlay cerrado")
end

function M.refresh()
    if not bodyText or not bodyText:IsValid() then return end
    local text = build_text()
    if text ~= lastText then
        lastText = text
        set_text(bodyText, text)
    end
end

function M.poll()
    if not M.is_open() then return end
    local now = os.time()
    if now == lastRefresh then return end
    lastRefresh = now
    M.refresh()
end

function M.create()
    ExecuteInGameThread(function()
        local gi = UEHelpers.GetGameInstance()
        if not gi then return end

        local hud = StaticConstructObject(StaticFindObject("/Script/UMG.UserWidget"),
            gi, FName("LC_DebugOverlay"))
        if not hud then return end
        local tree = StaticConstructObject(StaticFindObject("/Script/UMG.WidgetTree"),
            hud, FName("LC_DebugTree"))
        hud.WidgetTree = tree
        local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"),
            tree, FName("LC_DebugCanvas"))
        tree.RootWidget = canvas

        local border = StaticConstructObject(StaticFindObject("/Script/UMG.Border"),
            canvas, FName("LC_DebugBorder"))
        safe(function() border:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.86 }) end)
        safe(function() border:SetPadding({ Left = 16, Top = 10, Right = 16, Bottom = 10 }) end)

        local vbox = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"),
            border, FName("LC_DebugBox"))
        local title = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),
            vbox, FName("LC_DebugTitle"))
        set_text(title, "LC_Coop DEBUG  |  Ctrl+F6: cerrar  |  F9: conexion")
        set_font_size(title, TITLE_FONT_SIZE)
        local body = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),
            vbox, FName("LC_DebugBody"))
        safe(function() body:SetAutoWrapText(false) end)
        set_font_size(body, BODY_FONT_SIZE)
        safe(function() vbox:AddChildToVerticalBox(title) end)
        safe(function() vbox:AddChildToVerticalBox(body) end)
        safe(function() border:SetContent(vbox) end)

        local slot = canvas:AddChildToCanvas(border)
        safe(function() slot:SetAutoSize(true) end)
        safe(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }) end)
        safe(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
        safe(function() slot:SetPosition({ X = 18, Y = 18 }) end)

        safe(function() canvas.Visibility = 4 end)
        safe(function() border.Visibility = 4 end)
        hud:AddToViewport(100)

        -- Escalar todo el overlay para que no tape la pantalla.
        safe(function() hud:SetRenderTransformPivot({ X = 0, Y = 0 }) end)
        safe(function()
            hud:SetRenderTransform({
                Translation = { X = 0, Y = 0 },
                Scale = { X = OVERLAY_SCALE, Y = OVERLAY_SCALE },
                Shear = { X = 0, Y = 0 },
                Angle = 0,
            })
        end)

        root = hud; titleText = title; bodyText = body
        lastText = nil; lastRefresh = 0
        debugLog.add("[DBG] ", "overlay abierto")
        M.refresh()
    end)
end

function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.create()
    end
end

return M
