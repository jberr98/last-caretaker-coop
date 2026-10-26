-- connect_ui.lua — menú in-game (widget UMG creado desde Lua).
-- F9: abrir/cerrar el menú.   F11: conectar a la IP escrita en la caja.

local M = {}
local UEHelpers = require("UEHelpers")
local debugLog = require("debug_log")

local root = nil
local ipBox = nil
local statusText = nil
local connectBtn = nil
local wasPressed = false
local lastStatusAt = 0
local lastUiState = nil

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
end

local function set_text(tb, s)
    if not tb then return end
    safe(function() tb:SetText(FText(s)) end)
end

local function read_status_file()
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

local function short(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n - 1) .. "..." end
    return s
end

-- Poner el juego en modo UI (para que la caja de texto reciba las teclas).
local function set_ui_input(on)
    local PC = UEHelpers.GetPlayerController()
    if not PC or not PC:IsValid() then return end
    safe(function() PC:SetShowMouseCursor(on) end)
    if on then
        safe(function() PC:SetInputModeGameAndUI({}) end)
    else
        safe(function() PC:SetInputModeGameOnly() end)
    end
end

function M.is_open()
    return root ~= nil and root:IsValid()
end

function M.close()
    if not M.is_open() then return end
    safe(function() root:RemoveFromViewport() end)
    root = nil; ipBox = nil; statusText = nil; connectBtn = nil; wasPressed = false
    lastStatusAt = 0
    set_ui_input(false)
    debugLog.add("[UI] ", "menu cerrado")
    print("[LC_UI] menu cerrado\n")
end

-- Lee el estado que escribe el sidecar y muestra si el otro lado confirma
-- el HELLO (escuchando: SI) o si solo estamos recibiendo (sin ACK).
function M.refresh_status()
    if not statusText or not statusText:IsValid() then return end
    local st = read_status_file()
    if not st then
        set_text(statusText, "sidecar sin estado (esta corriendo?)")
        return
    end
    local state = st.state or "?"
    local esc
    if state == "confirmed" then
        esc = "SI (ACK)"
    elseif state == "one_way" then
        esc = "NO (recibo, sin ACK)"
    elseif state == "waiting" then
        esc = "? (esperando)"
    elseif state == "no_peer" then
        esc = "sin peer"
    elseif state == "stopped" then
        esc = "sidecar detenido"
    else
        esc = state
    end
    local ts = tonumber(st.ts or "0") or 0
    if ts > 0 and state ~= "stopped" and os.time() - ts > 5 then
        esc = "? (sidecar sin reportar)"
    end
    local peer = st.peer_addr or st.peer or "?"
    local name = st.peer_name or ""
    if name ~= "" then peer = peer .. " (" .. short(name, 16) .. ")" end
    local posAge = tonumber(st.last_pos_age or "-1") or -1
    local pos = "NO"
    if posAge >= 0 and posAge <= 5 then
        pos = string.format("SI (%.1fs)", posAge)
    elseif posAge > 5 then
        pos = string.format("NO (%.0fs)", posAge)
    end
    local rx = st.rx_pos or "0"
    local tx = st.tx_pos or "0"
    if state ~= lastUiState then
        lastUiState = state
        debugLog.add("[NET] ", string.format("estado UI: %s | %s", esc, peer))
    end
    set_text(statusText, string.format(
        "peer %s | escuchando: %s | pos: %s | rx=%s tx=%s",
        short(peer, 42), esc, pos, rx, tx))
end

function M.toggle()
    if root and root:IsValid() then
        M.close()
        return
    end
    M.create()
end

function M.create()
    ExecuteInGameThread(function()
        local gi = UEHelpers.GetGameInstance()
        if not gi then print("[LC_UI] sin GameInstance\n"); return end

        local hud = StaticConstructObject(StaticFindObject("/Script/UMG.UserWidget"), gi, FName("LC_Coop_Menu"))
        if not hud then print("[LC_UI] no pude crear UserWidget\n"); return end

        local tree = StaticConstructObject(StaticFindObject("/Script/UMG.WidgetTree"), hud, FName("LC_Tree"))
        hud.WidgetTree = tree
        local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("LC_Canvas"))
        tree.RootWidget = canvas

        local border = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), canvas, FName("LC_Border"))
        safe(function() border:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.75 }) end)
        safe(function() border:SetPadding({ Left = 24, Top = 14, Right = 24, Bottom = 14 }) end)

        local vbox = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), border, FName("LC_VBox"))
        if not vbox then print("[LC_UI] no pude crear VerticalBox\n"); return end

        local title = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), vbox, FName("LC_Title"))
        set_text(title, "LC_Coop — Conexion")

        local hint = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), vbox, FName("LC_Hint"))
        set_text(hint, "IP/dominio  o  relay:host:puerto  o  server:host:puerto")

        local box = StaticConstructObject(StaticFindObject("/Script/UMG.EditableTextBox"), vbox, FName("LC_IP"))
        safe(function() box:SetText(FText("")) end)

        local status = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), vbox, FName("LC_Status"))
        set_text(status, "F11 o el boton = conectar")

        local btn = StaticConstructObject(StaticFindObject("/Script/UMG.Button"), vbox, FName("LC_Btn"))
        local btnText = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), btn, FName("LC_BtnText"))
        set_text(btnText, "Conectar")
        safe(function() btn:SetContent(btnText) end)

        safe(function() vbox:AddChildToVerticalBox(title) end)
        safe(function() vbox:AddChildToVerticalBox(hint) end)
        safe(function() vbox:AddChildToVerticalBox(box) end)
        safe(function() vbox:AddChildToVerticalBox(btn) end)
        safe(function() vbox:AddChildToVerticalBox(status) end)
        safe(function() border:SetContent(vbox) end)

        local slot = canvas:AddChildToCanvas(border)
        safe(function() slot:SetAutoSize(true) end)
        safe(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } }) end)
        safe(function() slot:SetAlignment({ X = 0.5, Y = 0 }) end)
        safe(function() slot:SetPosition({ X = 0, Y = 80 }) end)

        safe(function() canvas.Visibility = 4 end)
        safe(function() border.Visibility = 4 end)

        hud:AddToViewport(99)
        root = hud; ipBox = box; statusText = status; connectBtn = btn
        lastStatusAt = 0
        lastUiState = nil
        set_ui_input(true)
        safe(function() box:SetKeyboardFocus() end)
        debugLog.add("[UI] ", "menu creado")
        print("[LC_UI] menu creado\n")
    end)
end

-- Se llama cada tick: detecta el click en el botón "Conectar".
function M.poll()
    if connectBtn and connectBtn:IsValid() then
        local pressed = false
        safe(function() pressed = connectBtn:IsPressed() end)
        if pressed and not wasPressed then
            wasPressed = true
            M.connect_from_box()
        elseif not pressed then
            wasPressed = false
        end
    end
    local now = os.time()
    if now ~= lastStatusAt then
        lastStatusAt = now
        M.refresh_status()
    end
end

function M.connect_from_box()
    if not ipBox or not ipBox:IsValid() then
        debugLog.add("[UI] ", "conectar: menu no abierto")
        print("[LC_UI] el menu no esta abierto\n")
        return
    end
    local t = nil
    safe(function() t = ipBox:GetText():ToString() end)
    if not t then
        safe(function() t = ipBox:GetText() end)
    end
    t = tostring(t or ""):gsub("%s+", ""):gsub('"', ""):gsub("'", "")
    if t == "" then
        debugLog.add("[UI] ", "conectar: IP vacia")
        set_text(statusText, "escribi una IP primero")
        return
    end
    local f = io.open("lc_peer.txt", "wb")
    if f then f:write(t .. "\n"); f:close() end
    debugLog.add("[UI] ", "conectar a " .. t)
    set_text(statusText, "conectando a " .. t)
    lastStatusAt = 0
    print("[LC_UI] conectar a " .. t .. "\n")
end

return M
