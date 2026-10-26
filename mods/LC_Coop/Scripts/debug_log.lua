-- debug_log.lua — buffer en memoria de logs del mod para el overlay Ctrl+F6.
-- No escribe archivos: el overlay también lee lc_sidecar.log y lc_net_status.txt.

local M = {}
local lines = {}
local state = {}
local MAX_LINES = 400

function M.add(tag, msg)
    local line = string.format("[%s] %s%s",
        os.date("%H:%M:%S"), tag or "", tostring(msg or ""))
    lines[#lines + 1] = line
    if #lines > MAX_LINES then
        table.remove(lines, 1)
    end
end

function M.set(k, v)
    state[k] = tostring(v or "")
end

function M.get(k)
    return state[k]
end

function M.tail(n)
    local out = {}
    local first = math.max(1, #lines - (n or 20) + 1)
    for i = first, #lines do
        out[#out + 1] = lines[i]
    end
    return out
end

function M.clear()
    lines = {}
end

return M
