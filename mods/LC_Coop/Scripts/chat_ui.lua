-- chat_ui.lua — chat de proximidad y global (widget UMG).
--
-- Canales:
--   LOCAL  = misma área/dimensión y dentro de chatRadius (por defecto 25 m).
--   GLOBAL = todos los clientes conectados al mismo servidor/relay.
--
-- Teclas:
--   Enter       abrir chat local / enviar el mensaje actual
--   Ctrl+Enter  abrir chat global / enviar como global
--   Tab         cambiar de canal mientras el chat está abierto
--   Esc         cerrar
--
-- El mod escribe chat_out.txt y lee chat_in.txt; el sidecar los convierte en
-- paquetes UDP. No hay historial persistente: al cerrar el juego se pierde.

local M = {}
local UEHelpers = require("UEHelpers")
local debugLog = require("debug_log")
local config = require("config")

local PANEL_WIDTH = 620
local MAX_HISTORY = 120
local VISIBLE_LINES = 8
local TOAST_LINES = 4
local BODY_FONT = 14
local TITLE_FONT = 15
local SMALL_FONT = 12
local CHAT_MAX_BYTES = tonumber(config.chatMaxLen) or 240
if CHAT_MAX_BYTES < 20 then CHAT_MAX_BYTES = 20 end
if CHAT_MAX_BYTES > 500 then CHAT_MAX_BYTES = 500 end

local root = nil
local canvas = nil
local panel = nil
local titleText = nil
local logText = nil
local statusText = nil
local inputBox = nil
local buttonsRow = nil
local modeBtn = nil
local modeBtnText = nil
local sendBtn = nil
local closeBtn = nil

local open = false
local mode = "local"
local history = {}
local dirty = true
local toastUntil = 0
local lastCreateAttempt = 0
local lastStatusAt = 0
local lastFocusAt = 0
local wasModePressed = false
local wasSendPressed = false
local wasClosePressed = false
local cachedOwnName = nil
local cachedOwnNameAt = 0

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
end

local function now()
    return os.time()
end

local function set_text(tb, s)
    if not tb then return end
    safe(function() tb:SetText(FText(s)) end)
end

local function set_font_size(tb, size)
    if not tb then return end
    safe(function()
        local font = tb:GetFont()
        font.Size = size
        tb:SetFont(font)
    end)
end

local function set_visibility(w, v)
    if not w then return end
    local ok = pcall(function() w:SetVisibility(v) end)
    if not ok then safe(function() w.Visibility = v end) end
end

local function trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Prefijo UTF-8 válido de como máximo max_bytes.
local function utf8_prefix(s, max_bytes)
    s = tostring(s or "")
    if #s <= max_bytes then return s end
    local i = max_bytes
    while i > 1 do
        local b = s:byte(i)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    local b = s:byte(i)
    local len = 1
    if b and b >= 0xF0 then len = 4
    elseif b and b >= 0xE0 then len = 3
    elseif b and b >= 0xC0 then len = 2 end
    if i + len - 1 <= max_bytes then
        return s:sub(1, i + len - 1)
    end
    return s:sub(1, math.max(0, i - 1))
end

local function clean_text(s, max_bytes)
    s = tostring(s or "")
    s = s:gsub("[\r\n\t]", " ")
    s = s:gsub("%c", " ")
    s = s:gsub("%s+", " ")
    s = trim(s)
    if max_bytes then s = utf8_prefix(s, max_bytes) end
    return s
end

local function short(s, n)
    s = clean_text(s, nil)
    n = tonumber(n) or 24
    if #s <= n then return s end
    return utf8_prefix(s, n) .. "..."
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a") or ""
    f:close()
    return d
end

local function read_kv(path)
    local d = read_file(path)
    if not d then return nil end
    local t = {}
    for line in d:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = v end
    end
    return t
end

local function write_chat_out(scope, ts, text)
    local path = config.chatOut or "chat_out.txt"
    local f = io.open(path, "a")
    if not f then return false end
    local ok = pcall(function()
        f:write(scope .. "\t" .. tostring(ts) .. "\t" .. text .. "\n")
    end)
    f:close()
    return ok
end

local function write_chat_radius()
    local r = tonumber(config.chatRadius) or 2500
    if r < 0 then r = 0 end
    if r > 100000 then r = 100000 end
    local f = io.open("lc_chat_radius.txt", "w")
    if f then
        f:write(string.format("%.0f\n", r))
        f:close()
    end
end

local function write_player_name(name)
    name = clean_text(name, 32)
    if name == "" then return end
    local f = io.open("lc_player_name.txt", "w")
    if f then
        f:write(name .. "\n")
        f:close()
    end
end

local function own_name()
    local t = now()
    if cachedOwnName and t - cachedOwnNameAt < 5 then
        return cachedOwnName
    end
    cachedOwnNameAt = t
    local name = clean_text(config.playerName or "", 32)
    if name == "" then
        name = clean_text(read_file("lc_player_name.txt") or "", 32)
    end
    if name == "" then
        local st = read_kv("lc_net_status.txt")
        name = clean_text(st and st.client_name or "", 32)
    end
    if name == "" then name = "Yo" end
    cachedOwnName = name
    return name
end

local function net_state_label(st)
    if not st then return "sidecar sin estado" end
    local state = st.state or "?"
    local ts = tonumber(st.ts or "0") or 0
    if ts > 0 and state ~= "stopped" and now() - ts > 5 then
        return "sin reportar"
    end
    if state == "confirmed" then return "confirmado (ACK)" end
    if state == "one_way" then return "solo recepción" end
    if state == "waiting" then return "esperando" end
    if state == "no_peer" then return "sin peer" end
    if state == "stopped" then return "sidecar detenido" end
    return state
end

local function mode_label()
    if mode == "global" then return "GLOBAL (todos)" end
    return "LOCAL (cerca)"
end

local function refresh_title()
    if open then
        set_text(titleText, "LC_Coop Chat — " .. mode_label() ..
            "\nEnter envía | Ctrl+Enter global | Tab cambia | Esc cierra")
    else
        set_text(titleText, "LC_Coop Chat — Enter local | Ctrl+Enter global")
    end
end

local function refresh_status()
    if not statusText or not statusText:IsValid() then return end
    local st = read_kv("lc_net_status.txt")
    local peer = ""
    if st then
        peer = clean_text(st.peer_name or "", 24)
        if peer == "" then peer = clean_text(st.peer or "", 24) end
    end
    if peer == "" then peer = "-" end
    local radius = 0
    if st then
        radius = tonumber(st.server_chat_radius or "0") or 0
        if radius <= 0 then
            radius = tonumber(st.chat_radius or "0") or 0
        end
    end
    if radius <= 0 then radius = tonumber(config.chatRadius) or 2500 end
    local meters = radius / 100.0 -- UE: 1 unidad = 1 cm
    set_text(statusText, string.format(
        "red: %s | peer: %s | radio: %.0f m",
        net_state_label(st), short(peer, 28), meters))
end

local function add_message(scope, ts, name, text, own)
    scope = (scope == "global" and "global") or
        (scope == "system" and "system") or "local"
    ts = tonumber(ts) or now()
    if ts < 0 or ts > now() + 86400 then ts = now() end
    text = clean_text(text, CHAT_MAX_BYTES)
    if text == "" then return end
    history[#history + 1] = {
        scope = scope, ts = ts, name = clean_text(name, 32),
        text = text, own = own and true or false,
    }
    if #history > MAX_HISTORY then table.remove(history, 1) end
    dirty = true
end

local function add_system(text)
    add_message("system", now(), "", text, false)
end

local function build_log()
    local limit = open and VISIBLE_LINES or TOAST_LINES
    local lines = {}
    local first = math.max(1, #history - limit + 1)
    for i = first, #history do
        local m = history[i]
        local ts = os.date("%H:%M", m.ts)
        if m.scope == "system" then
            lines[#lines + 1] = string.format("%s [S] %s", ts, m.text)
        else
            local tag = (m.scope == "global") and "G" or "L"
            lines[#lines + 1] = string.format("%s [%s] %s: %s",
                ts, tag, m.name, m.text)
        end
    end
    if #lines == 0 then
        lines[1] = "Todavía no hay mensajes."
    end
    return table.concat(lines, "\n")
end

local function refresh_log(force)
    if not dirty and not force then return end
    dirty = false
    set_text(logText, build_log())
end

local function enter_input()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end
    safe(function() PC:SetShowMouseCursor(true) end)
    -- UIOnly evita que el personaje se mueva mientras escribís. Si la firma
    -- no existe en este build, caemos a GameAndUI (igual se puede escribir).
    local ok = pcall(function() PC:SetInputModeUIOnly({}) end)
    if not ok then safe(function() PC:SetInputModeGameAndUI({}) end) end
    if inputBox and inputBox:IsValid() then
        safe(function() inputBox:SetKeyboardFocus() end)
    end
end

local function leave_input()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end
    safe(function() PC:SetShowMouseCursor(false) end)
    safe(function() PC:SetInputModeGameOnly() end)
end

local function focus_input()
    if not open then return end
    if inputBox and inputBox:IsValid() then
        safe(function() inputBox:SetKeyboardFocus() end)
    end
end

local function apply_state()
    if not root or not root:IsValid() then return end
    if open then
        set_visibility(root, 0)
        set_visibility(canvas, 4)
        set_visibility(panel, 0)
        set_visibility(inputBox, 0)
        set_visibility(buttonsRow, 0)
        set_visibility(statusText, 0)
        refresh_title()
        refresh_log(true)
        refresh_status()
    elseif toastUntil > 0 and now() < toastUntil and #history > 0 then
        set_visibility(root, 0)
        set_visibility(canvas, 4)
        set_visibility(panel, 4)
        set_visibility(inputBox, 1)
        set_visibility(buttonsRow, 1)
        set_visibility(statusText, 1)
        refresh_title()
        refresh_log(true)
    else
        set_visibility(root, 1)
    end
end

local function can_open()
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return false end
    local pawn = PC.Pawn
    if not pawn or not pawn:IsValid() then return false end
    local paused = false
    pcall(function() paused = PC:IsPaused() end)
    return not paused
end

function M.is_open()
    return open
end

function M.set_mode(new_mode)
    mode = (new_mode == "global") and "global" or "local"
    set_text(modeBtnText, "Canal: " .. mode_label())
    if open then
        refresh_title()
        focus_input()
    end
end

function M.toggle_mode()
    if mode == "global" then
        M.set_mode("local")
    else
        M.set_mode("global")
    end
    -- Tab puede mover el foco en UMG; lo devolvemos un instante después.
    ExecuteWithDelay(20, function()
        ExecuteInGameThread(function() focus_input() end)
    end)
end

function M.create()
    if root and root:IsValid() then return end
    local t = now()
    if t - lastCreateAttempt < 1 then return end
    lastCreateAttempt = t

    ExecuteInGameThread(function()
        local gi = UEHelpers.GetGameInstance()
        if not gi then
            debugLog.add("[CHAT] ", "sin GameInstance; reintento")
            return
        end

        local hud = StaticConstructObject(
            StaticFindObject("/Script/UMG.UserWidget"), gi, FName("LC_Chat"))
        if not hud then
            debugLog.add("[CHAT] ", "no pude crear UserWidget")
            return
        end

        local tree = StaticConstructObject(
            StaticFindObject("/Script/UMG.WidgetTree"), hud, FName("LC_ChatTree"))
        hud.WidgetTree = tree
        local cv = StaticConstructObject(
            StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("LC_ChatCanvas"))
        tree.RootWidget = cv

        local border = StaticConstructObject(
            StaticFindObject("/Script/UMG.Border"), cv, FName("LC_ChatBorder"))
        safe(function()
            border:SetBrushColor({ R = 0.01, G = 0.01, B = 0.01, A = 0.82 })
        end)
        safe(function()
            border:SetPadding({ Left = 18, Top = 12, Right = 18, Bottom = 12 })
        end)

        local vbox = StaticConstructObject(
            StaticFindObject("/Script/UMG.VerticalBox"), border, FName("LC_ChatVBox"))
        if not vbox then
            debugLog.add("[CHAT] ", "no pude crear VerticalBox")
            return
        end

        local title = StaticConstructObject(
            StaticFindObject("/Script/UMG.TextBlock"), vbox, FName("LC_ChatTitle"))
        set_font_size(title, TITLE_FONT)

        local log = StaticConstructObject(
            StaticFindObject("/Script/UMG.TextBlock"), vbox, FName("LC_ChatLog"))
        set_font_size(log, BODY_FONT)
        safe(function() log:SetAutoWrapText(true) end)
        safe(function() log:SetWrapTextAt(PANEL_WIDTH - 36) end)
        safe(function() log:SetMinDesiredWidth(PANEL_WIDTH - 36) end)

        local status = StaticConstructObject(
            StaticFindObject("/Script/UMG.TextBlock"), vbox, FName("LC_ChatStatus"))
        set_font_size(status, SMALL_FONT)

        local box = StaticConstructObject(
            StaticFindObject("/Script/UMG.EditableTextBox"), vbox, FName("LC_ChatInput"))
        set_font_size(box, BODY_FONT)
        safe(function() box:SetHintText(FText("Escribí un mensaje y Enter...")) end)

        local row = StaticConstructObject(
            StaticFindObject("/Script/UMG.HorizontalBox"), vbox, FName("LC_ChatButtons"))
        local mbtn = StaticConstructObject(
            StaticFindObject("/Script/UMG.Button"), row, FName("LC_ChatModeBtn"))
        local mtext = StaticConstructObject(
            StaticFindObject("/Script/UMG.TextBlock"), mbtn, FName("LC_ChatModeText"))
        set_font_size(mtext, SMALL_FONT)
        safe(function() mbtn:SetContent(mtext) end)

        local sbtn = StaticConstructObject(
            StaticFindObject("/Script/UMG.Button"), row, FName("LC_ChatSendBtn"))
        local stext = StaticConstructObject(
            StaticFindObject("/Script/UMG.TextBlock"), sbtn, FName("LC_ChatSendText"))
        set_text(stext, "  Enviar  ")
        set_font_size(stext, SMALL_FONT)
        safe(function() sbtn:SetContent(stext) end)

        local cbtn = StaticConstructObject(
            StaticFindObject("/Script/UMG.Button"), row, FName("LC_ChatCloseBtn"))
        local ctext = StaticConstructObject(
            StaticFindObject("/Script/UMG.TextBlock"), cbtn, FName("LC_ChatCloseText"))
        set_text(ctext, "  Cerrar  ")
        set_font_size(ctext, SMALL_FONT)
        safe(function() cbtn:SetContent(ctext) end)

        safe(function() vbox:AddChildToVerticalBox(title) end)
        safe(function() vbox:AddChildToVerticalBox(log) end)
        safe(function() vbox:AddChildToVerticalBox(status) end)
        safe(function() vbox:AddChildToVerticalBox(box) end)
        safe(function() vbox:AddChildToVerticalBox(row) end)
        safe(function() row:AddChildToHorizontalBox(mbtn) end)
        safe(function() row:AddChildToHorizontalBox(sbtn) end)
        safe(function() row:AddChildToHorizontalBox(cbtn) end)
        safe(function() border:SetContent(vbox) end)

        local slot = cv:AddChildToCanvas(border)
        safe(function() slot:SetAutoSize(true) end)
        safe(function()
            slot:SetAnchors({
                Minimum = { X = 0, Y = 1 },
                Maximum = { X = 0, Y = 1 },
            })
        end)
        safe(function() slot:SetAlignment({ X = 0, Y = 1 }) end)
        safe(function() slot:SetPosition({ X = 28, Y = -28 }) end)

        safe(function() cv.Visibility = 4 end)
        safe(function() border.Visibility = 4 end)
        hud:AddToViewport(97)

        root = hud
        canvas = cv
        panel = border
        titleText = title
        logText = log
        statusText = status
        inputBox = box
        buttonsRow = row
        modeBtn = mbtn
        modeBtnText = mtext
        sendBtn = sbtn
        closeBtn = cbtn
        dirty = true

        set_text(modeBtnText, "Canal: " .. mode_label())
        apply_state()
        if open then enter_input() end
        debugLog.add("[CHAT] ", "widget creado")
        print("[LC_CHAT] widget creado\n")
    end)
end

function M.open(new_mode)
    if config.chatEnabled == false then return end
    if not open and not can_open() then
        debugLog.add("[CHAT] ", "no se puede abrir (sin pawn o juego pausado)")
        return
    end
    if open then
        M.set_mode(new_mode)
        focus_input()
        return
    end
    open = true
    toastUntil = 0
    mode = (new_mode == "global") and "global" or "local"
    set_text(modeBtnText, "Canal: " .. mode_label())
    if root and root:IsValid() then
        apply_state()
        enter_input()
    else
        M.create()
    end
    debugLog.add("[CHAT] ", "abierto en " .. mode)
    print("[LC_CHAT] abierto (" .. mode .. ")\n")
end

function M.close(keep_toast)
    if not open then
        if toastUntil > 0 then
            toastUntil = 0
            apply_state()
        end
        return
    end
    open = false
    toastUntil = keep_toast and (now() + 2) or 0
    if inputBox and inputBox:IsValid() then
        safe(function() inputBox:SetText(FText("")) end)
    end
    leave_input()
    apply_state()
    debugLog.add("[CHAT] ", "cerrado")
end

function M.send(force_scope)
    if not open then return false end
    local text = ""
    if inputBox and inputBox:IsValid() then
        safe(function() text = inputBox:GetText():ToString() end)
        if text == "" then
            safe(function() text = tostring(inputBox:GetText() or "") end)
        end
    end
    text = clean_text(text, CHAT_MAX_BYTES)
    if text == "" then
        add_system("Escribí un mensaje primero.")
        apply_state()
        return false
    end
    local scope = force_scope and ((force_scope == "global") and "global" or "local") or mode
    if force_scope then
        mode = scope
        set_text(modeBtnText, "Canal: " .. mode_label())
    end
    local ts = now()
    local name = own_name()
    if not write_chat_out(scope, ts, text) then
        add_system("No pude escribir chat_out.txt.")
        apply_state()
        return false
    end
    add_message(scope, ts, name, text, true)
    debugLog.add("[CHAT] ", string.format("%s: %s", scope, text))
    if inputBox and inputBox:IsValid() then
        safe(function() inputBox:SetText(FText("")) end)
    end
    M.close(true)
    return true
end

-- Enter: abrir local / enviar; Ctrl+Enter: abrir global / enviar como global.
function M.on_enter(global)
    if not open then
        M.open(global and "global" or "local")
    else
        M.send(global and "global" or nil)
    end
end

local function pressed(btn)
    local p = false
    if btn and btn:IsValid() then
        safe(function() p = btn:IsPressed() end)
    end
    return p
end

local function poll_buttons()
    local p = pressed(modeBtn)
    if p and not wasModePressed then M.toggle_mode() end
    wasModePressed = p

    p = pressed(sendBtn)
    if p and not wasSendPressed then M.send(nil) end
    wasSendPressed = p

    p = pressed(closeBtn)
    if p and not wasClosePressed then M.close(false) end
    wasClosePressed = p
end

local function read_chat_in()
    local path = config.chatIn or "chat_in.txt"
    local f = io.open(path, "r")
    if not f then return 0 end
    local data = f:read("*a") or ""
    f:close()
    local g = io.open(path, "w")
    if g then g:close() end
    local n = 0
    for line in data:gmatch("[^\r\n]+") do
        -- scope<TAB>ts<TAB>name<TAB>area<TAB>x<TAB>y<TAB>z<TAB>texto
        local scope, ts, name, _area, _x, _y, _z, text = string.match(line,
            "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if scope and text then
            add_message(scope, tonumber(ts), name, text, false)
            n = n + 1
        end
    end
    return n
end

function M.poll()
    local t = now()
    local incoming = read_chat_in()
    if incoming > 0 then
        if not open then
            toastUntil = t + (tonumber(config.chatToastSeconds) or 8)
        end
        dirty = true
        if not open and (not root or not root:IsValid()) then
            M.create()
        end
        if not open and root and root:IsValid() then
            apply_state()
        end
    end

    if open then
        if not root or not root:IsValid() then
            M.create()
        else
            poll_buttons()
            if t - lastStatusAt >= 2 then
                lastStatusAt = t
                refresh_status()
            end
            refresh_log(false)
            if t - lastFocusAt >= 30 then
                lastFocusAt = t
                focus_input()
            end
        end
    else
        if toastUntil > 0 and t >= toastUntil then
            toastUntil = 0
            apply_state()
        elseif root and root:IsValid() then
            refresh_log(false)
        end
    end
end

-- Escribe los archivos de configuración que lee el sidecar. Se llama al
-- cargar el mod y también desde main.lua antes de lanzar el sidecar.
function M.write_runtime_config()
    write_chat_radius()
    local name = clean_text(config.playerName or "", 32)
    if name ~= "" then write_player_name(name) end
end

M.write_runtime_config()

return M
