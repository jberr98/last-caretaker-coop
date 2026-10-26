-- recon.lua — utilidad TEMPORAL (Fase 3: contenedores compartidos).
-- Lee el VoyagePersistentActorComponent del contenedor (ID estable para mapear).

local M = {}

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function out(s) print(s .. "\n") end

local function value_str(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "userdata" then
        local g = safe(function() return v:get() end)
        local n = safe(function() return (g or v):GetFullName() end)
        return n and tostring(n) or "ud"
    end
    return tostring(v)
end

local function dump_values(obj)
    local cls = safe(function() return obj:GetClass() end)
    local guard = 0
    while cls and safe(function() return cls:IsValid() end) and guard < 8 do
        guard = guard + 1
        safe(function()
            cls:ForEachProperty(function(p)
                local n = p:GetFName():ToString()
                local t = p:GetClass():GetFName():ToString()
                local v = safe(function() return obj[n] end)
                out(string.format("[recon]   %-32s %-24s = %s", n, t, value_str(v)))
            end)
        end)
        cls = safe(function() return cls:GetSuperStruct() end)
    end
end

local function first_instance(cn)
    local insts = safe(FindAllOf, cn)
    if type(insts) == "table" then
        for _, o in pairs(insts) do return o end
    end
    return nil
end

function M.run()
    local c = first_instance("BP_Inventory_Container_Base_C")
        or first_instance("BP_Container_Base_C")
    if not c then out("[recon] sin contenedor"); return end
    out("[recon] contenedor: " .. tostring(safe(function() return c:GetFullName() end)))

    local comp = safe(function() return c["VoyagePersistentActor"] end)
    local compObj = comp
    if compObj then
        local g = safe(function() return compObj:get() end)
        if g ~= nil then compObj = g end
    end
    if not compObj then out("[recon] sin VoyagePersistentActor"); return end
    out("[recon] ===== VoyagePersistentActorComponent: " ..
        tostring(safe(function() return compObj:GetFullName() end)))
    dump_values(compObj)
end

return M
