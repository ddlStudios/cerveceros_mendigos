-- Volumen de las voces (compartido por "Voces de hechizos" y "Estado").
-- LIMITE DEL CLIENTE: PlaySoundFile no admite volumen por sonido; solo existe el volumen del CANAL
-- (Sound_MasterVolume / Sound_DialogVolume / Sound_SFXVolume). Por eso, mientras suena una voz:
--   * si el volumen elegido es MENOR que el del canal, se baja el canal a ese valor;
--   * si es MAYOR y "subir el canal" esta activado, se sube el canal a ese valor;
-- y al terminar el clip (+0,3 s) se restaura EXACTAMENTE lo que tenia el usuario.
-- Con clips solapados el valor original se guarda una sola vez y se restaura al acabar el ultimo.
-- Si el modulo se desactiva o el jugador sale, se restaura al instante. El valor original se anota
-- tambien en las SavedVariables y se recupera al cargar por si el juego se cierra a mitad de un clip.
local ADDON, ns = ...

local Vol = {}
ns.PO_Vol = Vol

local CVARS = { Master = "Sound_MasterVolume", Dialog = "Sound_DialogVolume", SFX = "Sound_SFXVolume" }
local state = {}      -- cvar -> { orig = valor del usuario, count = clips activos }
local gen = 0         -- sube al restaurar de golpe: los temporizadores antiguos no hacen nada

local function GetCV(name)
    local f = (C_CVar and C_CVar.GetCVar) or GetCVar
    local ok, v = pcall(f, name)
    return ok and tonumber(v) or nil
end

local function SetCV(name, value)
    local f = (C_CVar and C_CVar.SetCVar) or SetCVar
    return pcall(f, name, string.format("%.3f", value))
end

local function Persist(name, orig)
    if ns.DB then
        ns.DB.volRestore = ns.DB.volRestore or {}
        ns.DB.volRestore[name] = orig
    end
end

local function Restore(name)
    local st = state[name]
    if not st then return end
    SetCV(name, st.orig)
    state[name] = nil
    if ns.DB and ns.DB.volRestore then ns.DB.volRestore[name] = nil end
end

function Vol.RestoreAll()
    gen = gen + 1
    for name in pairs(state) do Restore(name) end
end

-- Recupera un valor que se quedo cambiado si el juego se cerro a mitad de un clip.
function Vol.Recover()
    local r = ns.DB and ns.DB.volRestore
    if not r then return end
    for name, orig in pairs(r) do
        if not state[name] and tonumber(orig) then SetCV(name, tonumber(orig)) end
        r[name] = nil
    end
end

-- Ajusta el canal para un clip de `dur` segundos. pct: 0-100, boost: subir si esta mas bajo.
-- Devuelve el canal valido.
function Vol.Apply(channel, pct, boost, dur)
    if not CVARS[channel] then channel = "Master" end
    local name = CVARS[channel]
    local target = math.max(0, math.min(100, tonumber(pct) or 100)) / 100
    local st = state[name]
    local cur = st and st.orig or GetCV(name)
    if cur then
        local want
        if target < cur - 0.001 then want = target
        elseif target > cur + 0.001 and boost then want = target end
        if want then
            if not st then
                st = { orig = cur, count = 0 }
                state[name] = st
                Persist(name, cur)
            end
            st.count = st.count + 1
            SetCV(name, want)
            local g = gen
            local function Done()
                if g ~= gen then return end
                local s = state[name]
                if not s then return end
                s.count = s.count - 1
                if s.count <= 0 then Restore(name) end
            end
            local wait = (tonumber(dur) or 3) + 0.3
            if C_Timer and C_Timer.After then C_Timer.After(wait, Done) else Done() end
        end
    end
    return channel
end

-- Reproduce un archivo de voz con el volumen elegido.
function Vol.Play(file, channel, pct, boost, dur)
    channel = Vol.Apply(channel, pct, boost, dur)
    return PlaySoundFile(file, channel)
end

-- Por seguridad: nunca dejar el volumen cambiado al salir.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LEAVING_WORLD")
f:SetScript("OnEvent", function() Vol.RestoreAll() end)
