-- CervecerosMendigosCampoBatalla para WoW Forever (cliente moderno, Interface 16001).
-- Panel compacto con contadores de campo de batalla:
--   Cuenca de Arathi : bases, cuenta atras de captura, recursos y proyeccion de ganador.
--   Valle de Alterac : torres y cementerios, cuenta atras de 4 min, refuerzos, torres quemadas.
--   Garganta Grito de Guerra : portadores de bandera, tiempo, reaparicion, puntuacion.
-- Lee los widgets de la interfaz (arriba al centro), los puntos de interes del mapa
-- y los mensajes de sistema del campo de batalla (ES/EN).
-- Configuracion: boton del minimapa, o /cmcb  (/campobatalla). Diagnostico: /cmcb diag

local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local DEFAULTS = {
    -- panel
    scale = 1.0,
    alpha = 0.85,
    bgAlpha = 0.6,        -- opacidad del fondo del panel
    locked = false,
    maxRows = 16,         -- lineas maximas del panel
    showElapsed = true,   -- tiempo de partida junto al titulo
    showHint = true,      -- texto de ayuda en el panel cuando esta desbloqueado
    colA = { 0.29, 0.56, 1 },   -- color de la Alianza
    colH = { 1, 0.25, 0.25 },   -- color de la Horda
    -- campos de batalla en los que se muestra
    modeAB = true, modeAV = true, modeWSG = true, modeOther = true,
    -- avisos
    warnSound = true,
    warnSoundKind = "raid",     -- raid | ready
    warnChat = true,
    warn1 = 10,
    warn2 = 5,
    warnObjectives = true,      -- avisar de bases/torres/cementerios
    warnFlags = true,           -- avisar de la reaparicion de banderas
    -- tiempos y reglas (se pueden corregir si Forever las cambia)
    captureAB = 60,             -- segundos para capturar una base en Arathi
    captureAV = 240,            -- segundos de quemado de torre / captura de cementerio en Alterac
    abMax = 2000,               -- puntuacion maxima en Arathi
    flagRespawn = 20,           -- segundos de reaparicion de banderas en Warsong
    wsgCaps = 3,                -- capturas para ganar en Warsong
    showProjection = true,      -- "Gana X en mm:ss" en Arathi
}

-- Ajustes por campo de batalla. Todo lo que se asume y no se ha podido comprobar
-- en el juego real esta aqui arriba para poder cambiarlo facilmente.
local MAPS = {
    ab  = { id = 529, names = { "arathi" }, title = "Cuenca de Arathi",
            capture = 60, maxScore = 2000 },
    av  = { id = 30,  names = { "alterac" }, title = "Valle de Alterac",
            capture = 240 },
    wsg = { id = 489, names = { "warsong", "grito de guerra" }, title = "Garganta Grito de Guerra",
            flagRespawn = 20, winCaps = 3, timeLimit = 25 * 60 },
}
-- Puntos por segundo segun bases controladas en Arathi (10 puntos cada 12/9/6/3/1 s).
-- Solo es la estimacion inicial: en cuanto hay datos se usa el ritmo medido.
local AB_RATE = { [0] = 0, 10 / 12, 10 / 9, 10 / 6, 10 / 3, 10 / 1 }

local FACTION = { A = "Alianza", H = "Horda" }
local FCOLOR = { A = "|cff4a90ff", H = "|cffff4040", N = "|cffaaaaaa" }

-- Palabras clave (ya sin tildes ni mayusculas) para entender los mensajes del campo.
local KW = {
    assault = { "assaulted", "claimed", "asaltad", "reclamad" },
    capture = { "has taken", "taken", "captured", "capturad", "tomad", "conquistad" },
    defend  = { "defended", "defendid" },
    destroy = { "destroyed", "burned", "burnt", "destruid", "destroz", "quemad", "incendi" },
    pickup  = { "picked up", "recogid", "cogid" },
    drop    = { "dropped", "soltad", "dejad", "caid", "cayo" },
    ret     = { "returned", "devuelt", "regres", "retorn" },
    tower   = { "tower", "torre", "bunker" },
    gy      = { "graveyard", "cementerio" },
    flag    = { "flag", "bandera" },
    ali     = { "alliance", "alianza" },
    hor     = { "horde", "horda" },
}

local mod
local DB
local panel
local rows = {}
local MAX_ROWS = 16
local ApplyColors

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
local function Print(msg) if mod then mod:Print(msg) end end

-- Valores secretos: nunca se comparan ni se guardan.
local function Safe(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local ACCENTS = { ["á"] = "a", ["é"] = "e", ["í"] = "i", ["ó"] = "o", ["ú"] = "u", ["ü"] = "u", ["ñ"] = "n",
                  ["Á"] = "a", ["É"] = "e", ["Í"] = "i", ["Ó"] = "o", ["Ú"] = "u", ["Ü"] = "u", ["Ñ"] = "n" }

-- Quita codigos de color/textura del texto.
local function Clean(s)
    s = Safe(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:gsub("|n", " "):gsub("\n", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- minusculas, sin tildes: para comparar textos en cualquier idioma.
local function Norm(s)
    s = Clean(s)
    s = s:gsub("[\195][\128-\191]", function(c) return ACCENTS[c] or c end)
    return s:lower()
end

local function Has(n, list)
    for i = 1, #list do
        if n:find(list[i], 1, true) then return true end
    end
    return false
end

local function FactionIn(n)
    local a = nil
    for i = 1, #KW.ali do
        local p = n:find(KW.ali[i], 1, true)
        if p and (not a or p < a) then a = p end
    end
    local h = nil
    for i = 1, #KW.hor do
        local p = n:find(KW.hor[i], 1, true)
        if p and (not h or p < h) then h = p end
    end
    if a and (not h or a < h) then return "A" end
    if h then return "H" end
    return nil
end

local function MMSS(sec)
    sec = math.max(0, math.floor((sec or 0) + 0.5))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function PlayerSide()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    f = Safe(f)
    if f == "Alliance" then return "A" end
    if f == "Horde" then return "H" end
    return nil
end

----------------------------------------------------------------------
-- Estado de la partida
----------------------------------------------------------------------
local S

local function NewState()
    return {
        mode = nil,           -- "ab" | "av" | "wsg" | "otro"
        mapName = "",
        obj = {}, order = {},
        sc = { A = {}, H = {} },     -- {cur, max, bases}
        hist = { A = {}, H = {} },   -- muestras de recursos para medir el ritmo
        wlines = {},                 -- texto crudo de los widgets
        flags = { A = {}, H = {} },  -- por bandera: carrier, since, state
        caps = { A = 0, H = 0 },
        burned = { A = 0, H = 0 },
        respawnAt = nil,
        timeLeft = nil, timeAt = nil,
        msgs = {},
        demo = false,
    }
end

local function ObjKey(name) return Norm(name) end

local function GetObj(name, create)
    local key = ObjKey(name)
    if key == "" then return nil end
    local o = S.obj[key]
    if not o and create then
        o = { key = key, name = Clean(name), owner = nil, warned = {} }
        S.obj[key] = o
        S.order[#S.order + 1] = key
    end
    return o
end

local function ObjKind(o)
    local n = o.key
    if Has(n, KW.gy) then return "gy" end
    if Has(n, KW.tower) then return "tower" end
    return "base"
end

----------------------------------------------------------------------
-- Deteccion del campo de batalla
----------------------------------------------------------------------
local function DetectModeRaw()
    local inInst, itype = false, nil
    if IsInInstance then
        local ok, a, b = pcall(IsInInstance)
        if ok then inInst, itype = a, b end
    end
    local isBG = (itype == "pvp")
    if not isBG and C_PvP and C_PvP.IsBattleground then
        local ok, r = pcall(C_PvP.IsBattleground)
        isBG = ok and r and true or false
    end
    if not isBG then return nil end
    local name, instID = "", nil
    if GetInstanceInfo then
        local ok, n, _, _, _, _, _, _, id = pcall(GetInstanceInfo)
        if ok then name, instID = Safe(n) or "", Safe(id) end
    end
    local norm = Norm(name)
    for key, m in pairs(MAPS) do
        if instID == m.id then return key, m.title end
    end
    for key, m in pairs(MAPS) do
        for _, w in ipairs(m.names) do
            if norm:find(w, 1, true) then return key, m.title end
        end
    end
    return "otro", name ~= "" and name or "Campo de batalla"
end

local MODE_FLAG = { ab = "modeAB", av = "modeAV", wsg = "modeWSG", otro = "modeOther" }
local function DetectMode()
    local mode, title = DetectModeRaw()
    if mode and DB[MODE_FLAG[mode]] == false then return nil end
    return mode, title
end

----------------------------------------------------------------------
-- Lectura de widgets (arriba al centro y bajo el minimapa)
----------------------------------------------------------------------
local WIDGET_GETTERS  -- tipo -> nombre de funcion, se arma la primera vez

local function BuildGetters()
    WIDGET_GETTERS = {}
    local VT = Enum and Enum.UIWidgetVisualizationType
    if not VT then return end
    local pairs_ = {
        IconAndText = "GetIconAndTextWidgetVisualizationInfo",
        TextWithState = "GetTextWithStateWidgetVisualizationInfo",
        DoubleIconAndText = "GetDoubleIconAndTextWidgetVisualizationInfo",
        DoubleStatusBar = "GetDoubleStatusBarWidgetVisualizationInfo",
        IconTextAndCurrencies = "GetIconTextAndCurrenciesWidgetVisualizationInfo",
        TextWithSubtext = "GetTextWithSubtextWidgetVisualizationInfo",
        StatusBar = "GetStatusBarWidgetVisualizationInfo",
        CaptureBar = "GetCaptureBarWidgetVisualizationInfo",
        ZoneControl = "GetZoneControlVisualizationInfo",
    }
    for t, fn in pairs(pairs_) do
        if VT[t] ~= nil and C_UIWidgetManager and C_UIWidgetManager[fn] then
            WIDGET_GETTERS[VT[t]] = { fn = fn, name = t }
        end
    end
end

local function AddLine(list, text, tip, order, tag, extra)
    text = Clean(text)
    if text == "" and not extra then return end
    local l = { text = text, tip = Clean(tip), order = order or 0, tag = Clean(tag) }
    if extra then for k, v in pairs(extra) do l[k] = v end end
    l.fac = FactionIn(Norm(l.text .. " " .. l.tip .. " " .. l.tag))
    list[#list + 1] = l
end

local function ScanWidgets()
    local lines = {}
    if not (C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID) then return lines end
    if not WIDGET_GETTERS then BuildGetters() end
    local sets = {}
    for _, fn in ipairs({ "GetTopCenterWidgetSetID", "GetBelowMinimapWidgetSetID" }) do
        local f = C_UIWidgetManager[fn]
        if f then
            local ok, id = pcall(f)
            if ok and type(id) == "number" then sets[#sets + 1] = id end
        end
    end
    for _, setID in ipairs(sets) do
        local ok, ws = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
        if ok and type(ws) == "table" then
            for _, w in ipairs(ws) do
                local g = WIDGET_GETTERS[w.widgetType]
                if g then
                    local ok2, info = pcall(C_UIWidgetManager[g.fn], w.widgetID)
                    if ok2 and type(info) == "table" then
                        local ord = Safe(info.orderIndex) or 0
                        local tag = Safe(info.widgetTag)
                        local shown = Safe(info.shownState)
                        local st = Safe(info.state)
                        if (shown == nil or shown ~= 0) and (st == nil or st ~= 0) then
                            if g.name == "IconAndText" or g.name == "TextWithState" or g.name == "IconTextAndCurrencies" then
                                AddLine(lines, info.text, info.tooltip, ord, tag)
                            elseif g.name == "TextWithSubtext" then
                                AddLine(lines, (Clean(info.text) .. " " .. Clean(info.subText)), "", ord, tag)
                            elseif g.name == "DoubleIconAndText" then
                                local lab = Clean(info.label)
                                AddLine(lines, lab .. " " .. Clean(info.leftText), info.leftTooltip, ord, tag, { side = "A" })
                                AddLine(lines, lab .. " " .. Clean(info.rightText), info.rightTooltip, ord + 0.1, tag, { side = "H" })
                            elseif g.name == "DoubleStatusBar" then
                                local lv, lm = Safe(info.leftBarValue), Safe(info.leftBarMax)
                                local rv, rm = Safe(info.rightBarValue), Safe(info.rightBarMax)
                                if lv and lm then
                                    AddLine(lines, string.format("%d/%d", lv, lm), info.leftBarTooltip, ord, tag, { side = "A", cur = lv, max = lm })
                                end
                                if rv and rm then
                                    AddLine(lines, string.format("%d/%d", rv, rm), info.rightBarTooltip, ord + 0.1, tag, { side = "H", cur = rv, max = rm })
                                end
                                if Clean(info.text) ~= "" then AddLine(lines, info.text, "", ord + 0.2, tag) end
                            elseif g.name == "StatusBar" then
                                AddLine(lines, info.overrideBarText ~= nil and info.overrideBarText or "", info.tooltip, ord, tag)
                            elseif g.name == "CaptureBar" then
                                local v, lo, hi = Safe(info.barValue), Safe(info.barMinValue), Safe(info.barMaxValue)
                                if v and lo and hi and hi > lo then
                                    AddLine(lines, string.format("Captura %d%%", math.floor((v - lo) / (hi - lo) * 100 + 0.5)), info.tooltip, ord, tag)
                                end
                            elseif g.name == "ZoneControl" then
                                local ze = Safe(info.zoneEntries)
                                if type(ze) == "table" then
                                    for i, z in ipairs(ze) do
                                        local cur, mx = Safe(z.current), Safe(z.max)
                                        if cur and mx then
                                            AddLine(lines, string.format("Zona %d: %d/%d", i, cur, mx), z.tooltip, ord + i / 100, tag)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(lines, function(a, b) return a.order < b.order end)
    return lines
end

-- Interpreta lineas de widgets: recursos, bases, refuerzos, tiempo restante.
local function ParseWidgetLines(lines)
    local cand = {}
    local timeLeft
    for _, l in ipairs(lines) do
        local n = Norm(l.text)
        -- tiempo restante "Tiempo restante: 12:34"
        local mm, ss = n:match("(%d+):(%d%d)")
        if mm and (n:find("tiempo", 1, true) or n:find("time", 1, true) or n:find("restante", 1, true) or n:find("remaining", 1, true)) then
            timeLeft = tonumber(mm) * 60 + tonumber(ss)
        end
        local cur, mx
        if l.cur then
            cur, mx = l.cur, l.max
        else
            local c, m = l.text:match("(%d+)%s*/%s*(%d+)")
            cur, mx = tonumber(c), tonumber(m)
        end
        if cur and mx then
            local c = { cur = cur, max = mx, fac = l.side or l.fac, text = l.text, order = l.order }
            local b = l.text:match("^[^%d]-(%d+)[^%d/]+%d+%s*/%s*%d+")
            c.bases = tonumber(b)
            cand[#cand + 1] = c
        elseif S.mode == "av" and (n:find("refuerzo", 1, true) or n:find("reinforc", 1, true)) then
            local v = tonumber(l.text:match("(%d+)"))
            if v then
                cand[#cand + 1] = { cur = v, max = nil, fac = l.side or l.fac, text = l.text, order = l.order, reinf = true }
            end
        end
    end
    -- reparto por bando: primero por palabra clave, luego por orden (1.o Alianza, 2.o Horda)
    local sc = { A = {}, H = {} }
    local pend = {}
    for _, c in ipairs(cand) do
        if c.fac and not sc[c.fac].cur then sc[c.fac] = c else pend[#pend + 1] = c end
    end
    for _, c in ipairs(pend) do
        if not sc.A.cur then sc.A = c elseif not sc.H.cur then sc.H = c end
    end
    return sc, timeLeft
end

----------------------------------------------------------------------
-- Puntos de interes del mapa (bases, torres, cementerios)
----------------------------------------------------------------------
local function POIOwner(info)
    local blob = Norm((Safe(info.atlasName) or "") .. " " .. (Safe(info.uiTextureKit) or ""))
    if blob:find("alliance", 1, true) or blob:find("alianza", 1, true) then return "A" end
    if blob:find("horde", 1, true) or blob:find("horda", 1, true) then return "H" end
    if blob:find("neutral", 1, true) then return "N" end
    local fid = Safe(info.factionID)
    if fid ~= nil and Enum and Enum.PvPFaction then
        if fid == Enum.PvPFaction.Alliance then return "A" end
        if fid == Enum.PvPFaction.Horde then return "H" end
    end
    local d = FactionIn(Norm(Safe(info.description) or ""))
    return d or "N"
end

local function ScanPOIs()
    if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap and C_Map and C_Map.GetBestMapForUnit) then return end
    local okm, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    mapID = okm and Safe(mapID) or nil
    if not mapID then return end
    local ok, ids = pcall(C_AreaPoiInfo.GetAreaPOIForMap, mapID)
    if not ok or type(ids) ~= "table" then return end
    local now = GetTime()
    for _, id in ipairs(ids) do
        local oki, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, id)
        if oki and type(info) == "table" then
            local name = Clean(info.name)
            if name ~= "" then
                local o = GetObj(name, true)
                local owner = POIOwner(info)
                if o.owner ~= owner then
                    if o.owner ~= nil and not o.timed then o.endsAt = nil end
                    o.owner = owner
                    o.destroyed = nil
                end
                o.poiID = id
                o.desc = Clean(info.description)
                -- cuenta atras oficial si el punto es temporizado
                local secs
                if C_AreaPoiInfo.IsAreaPOITimed and C_AreaPoiInfo.GetAreaPOISecondsLeft then
                    local okt, timed = pcall(C_AreaPoiInfo.IsAreaPOITimed, id)
                    if okt and timed then
                        local oks, s = pcall(C_AreaPoiInfo.GetAreaPOISecondsLeft, id)
                        s = oks and Safe(s) or nil
                        if type(s) == "number" and s > 0 then secs = s end
                    end
                end
                if secs then
                    o.timed = true
                    o.endsAt = now + secs
                elseif o.timed then
                    o.timed = nil
                    o.endsAt = nil
                end
                o.seen = now
            end
        end
    end
end

----------------------------------------------------------------------
-- Mensajes de sistema del campo de batalla
----------------------------------------------------------------------
local function Alert(msg)
    if DB.warnChat then Print(msg) end
    if DB.warnSound and PlaySound then
        local kit = SOUNDKIT and ((DB.warnSoundKind == "ready" and SOUNDKIT.READY_CHECK) or SOUNDKIT.RAID_WARNING)
        pcall(PlaySound, kit or 8959)
    end
end

local function FindObjectiveIn(n)
    local best, bl = nil, 0
    for _, key in ipairs(S.order) do
        if #key > bl and n:find(key, 1, true) then best, bl = S.obj[key], #key end
    end
    return best
end

local function ExtractName(text)
    local t = Clean(text)
    local by = t:match("%f[%a]by%s+(.-)[%s!%.]*$") or t:match("%f[%a]por%s+(.-)[%s!%.]*$")
    return by
end

local function HandleFlag(text, n, evFac)
    local flagFac = FactionIn(n)
    -- "La Horda ha capturado la bandera de la Alianza": el primero es quien la captura
    if Has(n, KW.pickup) then
        local f = flagFac or ((evFac == "A") and "H" or "A")
        local carrier = ExtractName(text)
        S.flags[f].carrier = carrier or "?"
        S.flags[f].since = GetTime()
        S.flags[f].state = "portada"
    elseif Has(n, KW.drop) then
        local f = flagFac
        if f then S.flags[f].state = "caida"; S.flags[f].carrier = nil; S.flags[f].since = nil end
    elseif Has(n, KW.ret) then
        local f = flagFac
        if f then S.flags[f] = {} end
    elseif Has(n, KW.capture) then
        local capturer = flagFac or evFac
        if capturer then S.caps[capturer] = S.caps[capturer] + 1 end
        S.flags = { A = {}, H = {} }
        S.respawnAt = GetTime() + (DB.flagRespawn or 20)
    end
end

local function HandleObjective(text, n, evFac)
    local o = FindObjectiveIn(n)
    local f = FactionIn(n) or evFac
    local kindOf = Has(n, KW.assault) and "assault" or Has(n, KW.destroy) and "destroy"
        or Has(n, KW.defend) and "defend" or Has(n, KW.capture) and "capture" or nil
    if not kindOf then return end
    if not o then
        -- sin punto de interes legible: se crea un objetivo suelto con el texto del mensaje
        o = GetObj(Clean(text):sub(1, 40), true)
    end
    local now = GetTime()
    local m = MAPS[S.mode] or {}
    if kindOf == "assault" then
        o.assaulter = f
        if not o.timed then
            local cap = (S.mode == "av" and DB.captureAV) or (S.mode == "ab" and DB.captureAB) or m.capture or 60
            o.endsAt = now + cap
            o.warned = {}
        end
    elseif kindOf == "capture" then
        o.owner = f or o.owner
        o.assaulter = nil
        if not o.timed then o.endsAt = nil end
    elseif kindOf == "defend" then
        o.assaulter = nil
        if not o.timed then o.endsAt = nil end
    elseif kindOf == "destroy" then
        o.destroyed = true
        o.assaulter = nil
        o.endsAt = nil
        if f and ObjKind(o) == "tower" then S.burned[f] = S.burned[f] + 1 end
    end
end

local function HandleSystemMessage(text, evFac)
    if not S or not S.mode then return end
    text = Safe(text)
    if type(text) ~= "string" then return end
    local n = Norm(text)
    S.msgs[#S.msgs + 1] = Clean(text)
    if #S.msgs > 30 then table.remove(S.msgs, 1) end
    if S.mode == "wsg" and Has(n, KW.flag) then
        HandleFlag(text, n, evFac)
    elseif S.mode ~= "wsg" then
        HandleObjective(text, n, evFac)
    end
end

----------------------------------------------------------------------
-- Ritmo de recursos y proyeccion (Arathi)
----------------------------------------------------------------------
local function PushSample(f, cur, bases)
    local h = S.hist[f]
    local now = GetTime()
    if h.bases ~= bases then h.s = {}; h.bases = bases end
    h.s = h.s or {}
    local last = h.s[#h.s]
    if not last or last.cur ~= cur then h.s[#h.s + 1] = { t = now, cur = cur } end
    while #h.s > 40 do table.remove(h.s, 1) end
end

local function Rate(f, bases)
    local h = S.hist[f]
    local s = h and h.s
    if s and #s >= 2 then
        local a, b = s[1], s[#s]
        local dt = b.t - a.t
        if dt >= 8 and b.cur > a.cur then return (b.cur - a.cur) / dt, true end
    end
    return AB_RATE[math.min(bases or 0, 5)] or 0, false
end

----------------------------------------------------------------------
-- Refresco de datos
----------------------------------------------------------------------
local function RefreshData()
    local mode, title = DetectMode()
    if mode ~= S.mode then
        local demo = S.demo
        S = NewState(); S.demo = demo
        S.mode = mode
    end
    S.mapName = title or ""
    if not mode then return end
    local ok1 = pcall(function()
        S.wlines = ScanWidgets()
        local sc, tl = ParseWidgetLines(S.wlines)
        S.sc = sc
        if tl then S.timeLeft, S.timeAt = tl, GetTime() end
    end)
    pcall(ScanPOIs)
    if S.mode == "ab" then
        for _, f in ipairs({ "A", "H" }) do
            local c = S.sc[f]
            if c.cur then
                local bases = c.bases
                if not bases then
                    bases = 0
                    for _, o in pairs(S.obj) do if o.owner == f and not o.destroyed then bases = bases + 1 end end
                    c.bases = bases
                end
                PushSample(f, c.cur, bases)
            end
        end
    end
    return ok1
end

----------------------------------------------------------------------
-- Alertas de cuenta atras
----------------------------------------------------------------------
local function CheckWarnings()
    if not S or not S.mode then return end
    local now = GetTime()
    for _, key in ipairs(S.order) do
        local o = S.obj[key]
        if o.endsAt and DB.warnObjectives then
            local rem = math.ceil(o.endsAt - now)
            o.warned = o.warned or {}
            for _, w in ipairs({ DB.warn1, DB.warn2 }) do
                if rem == w and not o.warned[w] then
                    o.warned[w] = true
                    local who = o.assaulter and (FACTION[o.assaulter] .. " ") or ""
                    Alert(o.name .. ": " .. who .. "cambia de manos en " .. w .. " s")
                end
            end
        end
    end
    if S.respawnAt then
        local rem = math.ceil(S.respawnAt - now)
        S.rw = S.rw or {}
        for _, w in ipairs({ DB.warn1, DB.warn2 }) do
            if DB.warnFlags and rem == w and not S.rw[w] then
                S.rw[w] = true
                Alert("Las banderas reaparecen en " .. w .. " s")
            end
        end
        if rem <= 0 then S.respawnAt = nil; S.rw = nil end
    end
end

----------------------------------------------------------------------
-- Contenido del panel
----------------------------------------------------------------------
local function OwnerTag(f)
    return (FCOLOR[f] or FCOLOR.N) .. "●|r"
end

local function ObjectiveLine(o, now)
    local owner = o.destroyed and "destruida" or (o.owner == "A" and "Alianza" or o.owner == "H" and "Horda" or "libre")
    local txt = OwnerTag(o.owner) .. " " .. o.name .. "  |cffcccccc" .. owner .. "|r"
    if o.endsAt then
        local rem = o.endsAt - now
        if rem > 0 then
            local who = o.assaulter and (FCOLOR[o.assaulter] .. FACTION[o.assaulter] .. "|r ") or ""
            txt = txt .. "  → " .. who .. "|cffffd100" .. MMSS(rem) .. "|r"
        end
    end
    return txt
end

local function SortedObjectives(filter)
    local list = {}
    for _, key in ipairs(S.order) do
        local o = S.obj[key]
        if not filter or filter(o) then list[#list + 1] = o end
    end
    local now = GetTime()
    table.sort(list, function(a, b)
        local ta = a.endsAt and (a.endsAt - now) or 1e9
        local tb = b.endsAt and (b.endsAt - now) or 1e9
        if ta ~= tb then return ta < tb end
        return a.name < b.name
    end)
    return list
end

local function ElapsedText()
    if C_PvP and C_PvP.GetActiveMatchDuration then
        local ok, d = pcall(C_PvP.GetActiveMatchDuration)
        d = ok and Safe(d) or nil
        if type(d) == "number" and d > 0 then return "  |cff999999" .. MMSS(d) .. "|r" end
    end
    return ""
end

local function BuildLinesAB(L, now)
    for _, f in ipairs({ "A", "H" }) do
        local c = S.sc[f]
        if c.cur then
            local bases = c.bases or 0
            local rate, measured = Rate(f, bases)
            local mx = c.max or DB.abMax or MAPS.ab.maxScore
            local txt = string.format("%s%s|r  %d bases  |cffffffff%d/%d|r", FCOLOR[f], FACTION[f], bases, c.cur, mx)
            if rate > 0 then txt = txt .. string.format("  |cff999999+%.1f/s%s|r", rate, measured and "" or "~") end
            L[#L + 1] = txt
        else
            L[#L + 1] = FCOLOR[f] .. FACTION[f] .. "|r  |cff999999sin datos|r"
        end
    end
    local a, h = S.sc.A, S.sc.H
    if DB.showProjection and a.cur and h.cur then
        local ra = Rate("A", a.bases)
        local rh = Rate("H", h.bases)
        local mxs = DB.abMax or 2000
        local ta = ra > 0 and ((a.max or mxs) - a.cur) / ra or nil
        local th = rh > 0 and ((h.max or mxs) - h.cur) / rh or nil
        if ta and (not th or ta <= th) then
            L[#L + 1] = "Gana " .. FCOLOR.A .. "Alianza|r en |cffffd100" .. MMSS(ta) .. "|r si nada cambia"
        elseif th then
            L[#L + 1] = "Gana " .. FCOLOR.H .. "Horda|r en |cffffd100" .. MMSS(th) .. "|r si nada cambia"
        end
    end
    for _, o in ipairs(SortedObjectives()) do L[#L + 1] = ObjectiveLine(o, now) end
end

local function BuildLinesAV(L, now)
    for _, f in ipairs({ "A", "H" }) do
        local c = S.sc[f]
        L[#L + 1] = string.format("%s%s|r  refuerzos  |cffffffff%s|r", FCOLOR[f], FACTION[f], c.cur and tostring(c.cur) or "?")
    end
    local gy = { A = 0, H = 0, N = 0 }
    local tw = { A = 0, H = 0 }
    for _, o in pairs(S.obj) do
        local k = ObjKind(o)
        if k == "gy" then gy[o.owner or "N"] = (gy[o.owner or "N"] or 0) + 1
        elseif k == "tower" and not o.destroyed and (o.owner == "A" or o.owner == "H") then tw[o.owner] = tw[o.owner] + 1 end
    end
    L[#L + 1] = string.format("Cementerios  %sA %d|r  %sH %d|r  |cffaaaaaaN %d|r", FCOLOR.A, gy.A, FCOLOR.H, gy.H, gy.N)
    L[#L + 1] = string.format("Torres en pie  %sA %d|r  %sH %d|r", FCOLOR.A, tw.A, FCOLOR.H, tw.H)
    L[#L + 1] = string.format("Torres quemadas por  %sA %d|r  %sH %d|r", FCOLOR.A, S.burned.A, FCOLOR.H, S.burned.H)
    local timed = SortedObjectives(function(o) return o.endsAt and o.endsAt > now end)
    for _, o in ipairs(timed) do L[#L + 1] = ObjectiveLine(o, now) end
end

local function BuildLinesWSG(L, now)
    local capsA, capsH = S.caps.A, S.caps.H
    if S.sc.A.cur then capsA = S.sc.A.cur end
    if S.sc.H.cur then capsH = S.sc.H.cur end
    L[#L + 1] = string.format("%sAlianza %d|r  -  %sHorda %d|r  |cff999999(a %d)|r", FCOLOR.A, capsA, FCOLOR.H, capsH, DB.wsgCaps or MAPS.wsg.winCaps)
    -- la bandera de un bando la lleva el bando contrario
    for _, f in ipairs({ "A", "H" }) do
        local fl = S.flags[f]
        local txt = "Bandera " .. FCOLOR[f] .. FACTION[f] .. "|r: "
        if fl.state == "portada" then
            local t = fl.since and MMSS(now - fl.since) or "?"
            txt = txt .. "|cffffffff" .. (fl.carrier or "?") .. "|r  |cffffd100" .. t .. "|r"
        elseif fl.state == "caida" then
            txt = txt .. "|cffff8800en el suelo|r"
        else
            txt = txt .. "|cff99ff99en su base|r"
        end
        L[#L + 1] = txt
    end
    if S.respawnAt and S.respawnAt > now then
        L[#L + 1] = "Reaparicion de banderas: |cffffd100" .. MMSS(S.respawnAt - now) .. "|r"
    end
    if S.timeLeft and S.timeAt then
        L[#L + 1] = "Tiempo restante: |cffffffff" .. MMSS(S.timeLeft - (now - S.timeAt)) .. "|r"
    end
end

local function BuildLinesOther(L, now)
    local n = 0
    for _, l in ipairs(S.wlines) do
        if l.text ~= "" and n < 8 then
            L[#L + 1] = (l.fac and (FCOLOR[l.fac] .. "●|r ") or "") .. l.text
            n = n + 1
        end
    end
    for _, o in ipairs(SortedObjectives(function(o) return o.endsAt and o.endsAt > now end)) do
        L[#L + 1] = ObjectiveLine(o, now)
    end
end

local function BuildLines()
    local L = {}
    local now = GetTime()
    local title = S.mapName ~= "" and S.mapName or "Campo de batalla"
    L[1] = "|cffffd100" .. title .. "|r" .. (DB.showElapsed and ElapsedText() or "")
    if S.mode == "ab" then BuildLinesAB(L, now)
    elseif S.mode == "av" then BuildLinesAV(L, now)
    elseif S.mode == "wsg" then BuildLinesWSG(L, now)
    else BuildLinesOther(L, now) end
    return L
end

----------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------
local function SavePosition()
    if not panel then return end
    local p, _, rp, x, y = panel:GetPoint()
    DB.point = { p = p, rp = rp, x = x, y = y }
end

local function ApplyPanelSettings()
    if not panel then return end
    panel:SetScale(DB.scale)
    panel:SetAlpha(DB.alpha)
    panel:EnableMouse(not DB.locked)
    panel:SetBackdropColor(0, 0, 0, DB.bgAlpha or 0.6)
    if panel.grip then panel.grip:SetShown((not DB.locked) and DB.showHint) end
end

local function CreatePanel()
    local f = mod:Frame("Frame", "CervecerosMendigosCampoBatallaPanel", UIParent, "BackdropTemplate")
    f:SetSize(250, 40)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0, 0, 0, 0.6)
    f:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
    f:SetScript("OnDragStart", function(self) if not DB.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
    f:SetScript("OnMouseUp", function(self, btn) if btn == "RightButton" then Hub:Open("campobatalla") end end)
    local p = DB.point
    if p then f:SetPoint(p.p or "TOPLEFT", UIParent, p.rp or "TOPLEFT", p.x or 20, p.y or -200)
    else f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -240) end
    local grip = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    grip:SetPoint("BOTTOMRIGHT", -6, 4)
    grip:SetText("arrastrar · clic der. ajustes")
    f.grip = grip
    for i = 1, MAX_ROWS do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 14)
        fs:SetWidth(240)
        fs:Hide()
        rows[i] = fs
    end
    f:Hide()
    panel = f
    ApplyPanelSettings()
end

local function RenderPanel()
    if not panel then return end
    local visible = S and (S.mode or S.demo)
    if not visible then panel:Hide(); return end
    local L = BuildLines()
    local n = math.min(#L, math.min(MAX_ROWS, DB.maxRows or MAX_ROWS))
    for i = 1, MAX_ROWS do
        if i <= n then rows[i]:SetText(L[i]); rows[i]:Show() else rows[i]:Hide() end
    end
    panel:SetHeight(n * 14 + 18 + ((DB.locked or not DB.showHint) and 0 or 10))
    panel:Show()
end

----------------------------------------------------------------------
-- Datos de demostracion (/cmcb test)
----------------------------------------------------------------------
local function LoadDemo()
    local now = GetTime()
    S = NewState()
    S.demo = true
    S.mode = "ab"
    S.mapName = "Cuenca de Arathi (prueba)"
    S.sc = { A = { cur = 850, max = 2000, bases = 3 }, H = { cur = 640, max = 2000, bases = 2 } }
    local names = { { "Herreria", "A" }, { "Granja", "A" }, { "Establos", "H" }, { "Mina", "H" }, { "Aserradero", "A" } }
    for _, nf in ipairs(names) do
        local o = GetObj(nf[1], true)
        o.owner = nf[2]
    end
    local o = GetObj("Establos", true)
    o.assaulter = "A"; o.endsAt = now + 42
    S.hist.A = { bases = 3, s = { { t = now - 30, cur = 850 - 50 }, { t = now, cur = 850 } } }
    S.hist.H = { bases = 2, s = { { t = now - 30, cur = 640 - 35 }, { t = now, cur = 640 } } }
end

local function ToggleDemo()
    if S and S.demo then
        S = NewState()
        Print("panel de prueba oculto")
    else
        LoadDemo()
        Print("panel de prueba visible (se oculta con /cmcb test)")
    end
    RenderPanel()
end


----------------------------------------------------------------------
-- Diagnostico: sirve para ajustar los textos reales del juego
----------------------------------------------------------------------
local function Diag()
    local mode, title = DetectMode()
    Print("modo=" .. tostring(mode) .. " mapa=" .. tostring(title))
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
        Print("uiMapID=" .. tostring(ok and Safe(id) or "?"))
    end
    RefreshData()
    Print("widgets leidos: " .. #S.wlines)
    for i, l in ipairs(S.wlines) do
        if i > 12 then Print("  ..."); break end
        Print("  [" .. string.format("%.1f", l.order) .. "] " .. l.text .. (l.fac and (" {" .. l.fac .. "}") or ""))
    end
    local n = 0
    for _, key in ipairs(S.order) do
        local o = S.obj[key]
        n = n + 1
        if n <= 12 then
            Print(string.format("  POI %s dueno=%s ataca=%s tiempo=%s", o.name, tostring(o.owner), tostring(o.assaulter),
                o.endsAt and MMSS(o.endsAt - GetTime()) or "-"))
        end
    end
    Print("puntos de interes: " .. n)
    Print("A: " .. tostring(S.sc.A.cur) .. "/" .. tostring(S.sc.A.max) .. " bases " .. tostring(S.sc.A.bases)
        .. "  H: " .. tostring(S.sc.H.cur) .. "/" .. tostring(S.sc.H.max) .. " bases " .. tostring(S.sc.H.bases))
    Print("ultimos mensajes del campo: " .. #S.msgs)
    for i = math.max(1, #S.msgs - 5), #S.msgs do Print("  > " .. S.msgs[i]) end
end

----------------------------------------------------------------------
-- Colores de bando configurables
----------------------------------------------------------------------
local function HexColor(c)
    return string.format("|cff%02x%02x%02x", math.floor((c[1] or 1) * 255 + 0.5), math.floor((c[2] or 1) * 255 + 0.5), math.floor((c[3] or 1) * 255 + 0.5))
end

function ApplyColors()
    FCOLOR.A = HexColor(DB.colA)
    FCOLOR.H = HexColor(DB.colH)
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local acc, accData = 0, 0

local function OnChat(fac)
    return function(_, _, msg)
        if not S then return end
        HandleSystemMessage(msg, fac); RenderPanel()
    end
end

mod = Hub:Register{
    key = "campobatalla", dir = "CampoBatalla", name = "Campos de batalla",
    desc = "Panel con bases y recursos de Arathi, torres y cementerios de Alterac y banderas de Warsong, con avisos antes de cada cambio.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosCampoBatallaDB",
    slash = { "cmcb", "campobatalla" },

    Init = function(m)
        DB = m.db
        DB.minimap = nil
    end,

    Enable = function(m)
        DB = m.db
        ApplyColors()
        S = NewState()
        if not panel then CreatePanel() end
        ApplyPanelSettings()
        m:Event("PLAYER_ENTERING_WORLD", function()
            if S and S.demo then return end
            S = NewState()
            pcall(RefreshData)
            RenderPanel()
        end)
        m:Event("ZONE_CHANGED_NEW_AREA", function()
            if S and S.demo then return end
            S = NewState()
            pcall(RefreshData)
            RenderPanel()
        end)
        m:Event("CHAT_MSG_BG_SYSTEM_ALLIANCE", OnChat("A"))
        m:Event("CHAT_MSG_BG_SYSTEM_HORDE", OnChat("H"))
        m:Event("CHAT_MSG_BG_SYSTEM_NEUTRAL", OnChat(nil))
        -- eventos que pueden no existir en el cliente: se registran sin romper nada
        for _, e in ipairs({ "AREA_POIS_UPDATED", "UPDATE_UI_WIDGET", "UPDATE_ALL_UI_WIDGETS", "BATTLEGROUND_POINTS_UPDATE" }) do
            if pcall(m.evf.RegisterEvent, m.evf, e) then
                m.events[e] = function() accData = 1 end   -- releer en el siguiente ciclo
            end
        end
        acc, accData = 0, 1
        m:OnUpdate(function(_, elapsed)
            if not S then return end
            acc = acc + elapsed
            accData = accData + elapsed
            if acc < 0.25 then return end
            acc = 0
            if not S.demo and accData >= 1 then
                accData = 0
                pcall(RefreshData)
            end
            if S.mode or S.demo then
                CheckWarnings()
                RenderPanel()
            elseif panel and panel:IsShown() then
                panel:Hide()
            end
        end)
        -- si se activa dentro de un campo de batalla, empieza a leer ya
        pcall(RefreshData)
        RenderPanel()
    end,

    Disable = function(m)
        S = NewState()
        if panel then panel:Hide() end
    end,

    OnReset = function(m)
        DB = m.db
        DB.minimap = nil
        ApplyColors()
        if panel then
            panel:ClearAllPoints(); panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -240)
        end
        ApplyPanelSettings(); RenderPanel()
    end,

    BuildConfig = function(m, L)
        DB = m.db
        local function Redraw() ApplyPanelSettings(); RenderPanel() end
        L:Header("Panel")
        L:Slider("Tamano del panel (%)", 50, 200, 5,
            function() return math.floor(DB.scale * 100 + 0.5) end,
            function(v) DB.scale = v / 100; Redraw() end)
        L:Slider("Opacidad del panel (%)", 30, 100, 5,
            function() return math.floor(DB.alpha * 100 + 0.5) end,
            function(v) DB.alpha = v / 100; Redraw() end)
        L:Slider("Opacidad del fondo (%)", 0, 100, 5,
            function() return math.floor((DB.bgAlpha or 0.6) * 100 + 0.5) end,
            function(v) DB.bgAlpha = v / 100; Redraw() end)
        L:Slider("Lineas maximas del panel", 4, 16, 1,
            function() return DB.maxRows end, function(v) DB.maxRows = v; Redraw() end)
        L:Check("Bloquear el panel (no se puede arrastrar)", function() return DB.locked end,
            function(v) DB.locked = v; Redraw() end)
        L:Check("Mostrar el texto de ayuda cuando esta desbloqueado", function() return DB.showHint end,
            function(v) DB.showHint = v; Redraw() end)
        L:Check("Mostrar el tiempo de partida junto al titulo", function() return DB.showElapsed end,
            function(v) DB.showElapsed = v; RenderPanel() end)
        L:Color("Color de la Alianza", function() return unpack(DB.colA) end,
            function(r, g, b) DB.colA = { r, g, b }; ApplyColors(); RenderPanel() end)
        L:Color("Color de la Horda", function() return unpack(DB.colH) end,
            function(r, g, b) DB.colH = { r, g, b }; ApplyColors(); RenderPanel() end)
        L:Button("Restablecer la posicion del panel", 240, function()
            DB.point = nil
            if panel then panel:ClearAllPoints(); panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -240) end
        end)

        L:Header("En que campos de batalla se muestra")
        L:Check("Cuenca de Arathi", function() return DB.modeAB end, function(v) DB.modeAB = v end)
        L:Check("Valle de Alterac", function() return DB.modeAV end, function(v) DB.modeAV = v end)
        L:Check("Garganta Grito de Guerra", function() return DB.modeWSG end, function(v) DB.modeWSG = v end)
        L:Check("Otros campos de batalla (marcadores del propio juego)", function() return DB.modeOther end,
            function(v) DB.modeOther = v end)

        L:Header("Avisos antes del cambio")
        L:Check("Aviso en el chat", function() return DB.warnChat end, function(v) DB.warnChat = v end)
        L:Check("Aviso sonoro", function() return DB.warnSound end, function(v) DB.warnSound = v end)
        L:Choice("Sonido del aviso", { { "raid", "Aviso de banda" }, { "ready", "Comprobacion de listos" } },
            function() return DB.warnSoundKind end,
            function(v) DB.warnSoundKind = v; if PlaySound and SOUNDKIT then pcall(PlaySound, (v == "ready" and SOUNDKIT.READY_CHECK) or SOUNDKIT.RAID_WARNING) end end)
        L:Check("Avisar de bases, torres y cementerios", function() return DB.warnObjectives end,
            function(v) DB.warnObjectives = v end)
        L:Check("Avisar de la reaparicion de banderas", function() return DB.warnFlags end,
            function(v) DB.warnFlags = v end)
        L:Slider("Primer aviso (segundos antes)", 3, 30, 1,
            function() return DB.warn1 end, function(v) DB.warn1 = v end)
        L:Slider("Segundo aviso (segundos antes)", 1, 15, 1,
            function() return DB.warn2 end, function(v) DB.warn2 = v end)

        L:Header("Tiempos y reglas")
        L:Text("Por si Forever los cambia: se usan cuando el juego no da la cuenta atras oficial.", true)
        L:Check("Proyeccion de quien gana en Arathi", function() return DB.showProjection end,
            function(v) DB.showProjection = v; RenderPanel() end)
        L:Slider("Captura de una base en Arathi (seg)", 15, 180, 5,
            function() return DB.captureAB end, function(v) DB.captureAB = v end)
        L:Slider("Torre / cementerio en Alterac (seg)", 60, 600, 10,
            function() return DB.captureAV end, function(v) DB.captureAV = v end)
        L:Slider("Puntuacion maxima en Arathi", 500, 3000, 100,
            function() return DB.abMax end, function(v) DB.abMax = v; RenderPanel() end)
        L:Slider("Reaparicion de banderas en Warsong (seg)", 5, 60, 1,
            function() return DB.flagRespawn end, function(v) DB.flagRespawn = v end)
        L:Slider("Capturas para ganar en Warsong", 1, 10, 1,
            function() return DB.wsgCaps end, function(v) DB.wsgCaps = v; RenderPanel() end)

        L:Header("Pruebas")
        L:Button("Probar panel", 130, ToggleDemo)
        L:Button("Diagnostico (chat)", 160, function() Diag() end, true)
    end,

    OnSlash = function(m, msg)
        DB = m.db
        local cmd = string.match(strlower(msg or ""), "^(%S*)")
        if cmd == "" or cmd == "config" then
            Hub:Open("campobatalla")
        elseif cmd == "test" then
            ToggleDemo()
        elseif cmd == "lock" then
            DB.locked = true; ApplyPanelSettings(); RenderPanel(); Print("panel bloqueado")
        elseif cmd == "unlock" then
            DB.locked = false; ApplyPanelSettings(); RenderPanel(); Print("panel desbloqueado: arrastralo con el raton")
        elseif cmd == "diag" then
            Diag()
        else
            Print("/cmcb = ajustes | test | lock | unlock | diag")
        end
    end,
}
