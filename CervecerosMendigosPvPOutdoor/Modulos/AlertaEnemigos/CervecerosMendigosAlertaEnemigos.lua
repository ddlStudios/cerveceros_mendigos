-- CervecerosMendigosAlertaEnemigos para WoW Forever (cliente moderno, Interface 16001).
-- Cuando ves enemigos jugadores en el mundo abierto, avisa a tu grupo (mensaje de addon);
-- los demas con el addon reciben un aviso, un pin en el mapa/minimapa y una flecha.
-- Configuracion: boton del minimapa, o /cmalerta

local ADDON, ns = ...
local Hub = ns.Hub
local mod            -- se asigna en Register
local PREFIX = "CMAlertaEnem"      -- prefijo propio (max 16 caracteres)
local PROTO = "1"

local issecret = issecretvalue or function() return false end
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local DEFAULTS = {
    receiveOnly = false,   -- solo recibir, no enviar
    outdoorOnly = true,    -- no actuar en instancias / campos de batalla / arenas
    sound = true,          -- sonido al recibir un aviso
    soundKit = "RAID_WARNING",  -- sonido: RAID_WARNING / ALARM_CLOCK_WARNING_3 / IG_PVP_UPDATE
    soundGap = 5,          -- seg. minimos entre sonidos
    chat = true,           -- mensaje en el chat al recibir
    arrow = true,          -- flecha en pantalla con distancia
    pinMap = true,         -- pins en el mapa del mundo
    pinMini = true,        -- marcadores en el minimapa
    minCount = 1,          -- enemigos minimos para avisar
    minLevel = 0,          -- nivel minimo del enemigo mas alto (0 = cualquiera)
    ttl = 90,              -- segundos que dura un pin
    window = 4,            -- segundos que un enemigo cuenta como "visto"
    sendInterval = 4,      -- seg. minimos entre mis envios
    zoneInterval = 20,     -- seg. minimos entre avisos de la misma zona con el mismo numero
    maxAlerts = 8,         -- avisos recibidos que se guardan a la vez
    senderLimit = 8,       -- avisos por minuto que se aceptan de cada emisor
    senderGap = 3,         -- seg. minimos entre avisos del mismo emisor
    pinScale = 100,        -- tamano (%) de los pins
    arrowScale = 100,      -- tamano (%) de la flecha
    arrowColor = { 1, 0.25, 0.25 },
    lock = false,
    units = { nameplate = true, target = true, mouseover = true, focus = true },  -- de donde detecto enemigos
    muted = {},
    arrowPos = {},
}

local DB

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
local function Print(msg) if mod then mod:Print(msg) end end

local function Clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
end

-- Quita codigos de color/escape y caracteres de control de un texto ajeno.
local function Clean(s)
    s = tostring(s or "")
    s = s:gsub("|", ""):gsub("%c", "")
    return s
end

local CLASSES = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    DEATHKNIGHT = true, SHAMAN = true, MAGE = true, WARLOCK = true, MONK = true,
    DRUID = true, DEMONHUNTER = true, EVOKER = true,
}

local function ClassName(cf)
    if not CLASSES[cf] then return nil end
    local n = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf]
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cf]
    n = n or cf
    if c then return string.format("|cff%02x%02x%02x%s|r", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5), n) end
    return n
end

local function MapName(mapID)
    if mapID and C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and info and info.name then return info.name end
    end
    return "zona desconocida"
end

local function ShortName(name)
    name = Clean(name)
    if Ambiguate then
        local ok, n = pcall(Ambiguate, name, "short")
        if ok and n then return n end
    end
    return (name:gsub("%-.*$", ""))
end

local function Active()
    if not DB or not mod or not mod.enabled then return false end
    if DB.outdoorOnly then
        local ok, inInstance = pcall(IsInInstance)
        if ok and inInstance then return false end
    end
    return true
end

local function PlayerPosition()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or issecret(mapID) then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return mapID end
    local x, y = pos:GetXY()
    if issecret(x) or issecret(y) or not x or not y then return mapID end
    return mapID, x, y
end

-- Vectores del mundo (yardas) de los ejes este y sur del mapa; sirven para distancia y rumbo.
local axisCache = {}
local function MapAxes(mapID)
    local a = axisCache[mapID]
    if a ~= nil then return a or nil end
    a = false
    if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local function W(x, y)
            local ok, _, v = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
            if ok and v then
                local vx, vy = v.x, v.y
                if not vx and v.GetXY then vx, vy = v:GetXY() end
                return vx, vy
            end
        end
        local x0, y0 = W(0, 0)
        local x1, y1 = W(1, 0)
        local x2, y2 = W(0, 1)
        if x0 and x1 and x2 then
            a = { ex = x1 - x0, ey = y1 - y0, sx = x2 - x0, sy = y2 - y0 }
            a.w = math.sqrt(a.ex * a.ex + a.ey * a.ey)
            a.h = math.sqrt(a.sx * a.sx + a.sy * a.sy)
            if a.w < 1 or a.h < 1 then a = false end
        end
    end
    axisCache[mapID] = a
    return a or nil
end

-- Distancia (yardas) y rumbo (rad, 0 = norte, horario) de tu posicion a (mapID, x, y).
local function DistanceBearing(mapID, x, y)
    local pm, px, py = PlayerPosition()
    if not pm or pm ~= mapID or not px or not x or x <= 0 then return nil end
    local ax = MapAxes(mapID)
    local dx, dy = x - px, y - py          -- en unidades de mapa (este, sur)
    if ax then
        local wx = dx * ax.ex + dy * ax.sx
        local wy = dx * ax.ey + dy * ax.sy
        local dist = math.sqrt(wx * wx + wy * wy)
        return dist, atan2(dx * ax.w, -dy * ax.h)
    end
    -- sin datos del mundo: distancia en "porcentaje de mapa", sin yardas
    return math.sqrt(dx * dx + dy * dy) * 1000, atan2(dx, -dy), true
end

----------------------------------------------------------------------
-- Envio: deteccion de enemigos
----------------------------------------------------------------------
local seen = {}          -- key -> { t, class, level }
local lastSend, lastCount = 0, 0
local lastZone = {}      -- mapID -> { t, count }
local seq = 0

local function IsEnemyPlayer(unit)
    local ok, res = pcall(function()
        return UnitExists(unit) and UnitIsPlayer(unit) and UnitIsEnemy("player", unit) and not UnitIsDeadOrGhost(unit)
    end)
    return ok and res and true or false
end

local function Observe(unit)
    if not DB or not Active() then return end
    if not IsEnemyPlayer(unit) then return end
    local key
    local okg, guid = pcall(UnitGUID, unit)
    if okg and guid and not issecret(guid) then
        key = guid
    elseif string.find(unit, "^nameplate") then
        key = "np:" .. unit
    else
        key = "u:" .. unit
    end
    local e = seen[key]
    if not e then e = {}; seen[key] = e end
    e.t = GetTime()
    local okc, _, cf = pcall(UnitClass, unit)
    if okc and cf and not issecret(cf) and CLASSES[cf] then e.class = cf end
    local okl, lvl = pcall(UnitLevel, unit)
    if okl and type(lvl) == "number" and not issecret(lvl) then e.level = lvl end
end

local function ScanNameplates()
    if DB.units.nameplate then
        for i = 1, 40 do
            local u = "nameplate" .. i
            local ok, ex = pcall(UnitExists, u)
            if ok and ex then Observe(u) end
        end
    end
    if DB.units.target then Observe("target") end
    if DB.units.mouseover then Observe("mouseover") end
    if DB.units.focus then Observe("focus") end
end

-- Resumen de los enemigos vistos dentro de la ventana.
local function Summary()
    local now = GetTime()
    local count, maxLevel, classCount = 0, nil, {}
    local unknownLevel = false
    for key, e in pairs(seen) do
        if now - e.t > DB.window then
            seen[key] = nil
        else
            count = count + 1
            if e.level and e.level > 0 then
                if not maxLevel or e.level > maxLevel then maxLevel = e.level end
            else
                unknownLevel = true
            end
            if e.class then classCount[e.class] = (classCount[e.class] or 0) + 1 end
        end
    end
    local bestClass, bestN = nil, 0
    for cf, n in pairs(classCount) do
        if n > bestN then bestClass, bestN = cf, n end
    end
    return count, maxLevel, bestClass, unknownLevel
end

local function Channel()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

local function SendAlert(mapID, x, y, count, class, level)
    local chan = Channel()
    if not chan then return false end
    seq = (seq % 99999) + 1
    local msg = table.concat({
        PROTO,
        tostring(mapID or 0),
        tostring(x and math.floor(Clamp(x, 0, 1) * 1000 + 0.5) or 0),
        tostring(y and math.floor(Clamp(y, 0, 1) * 1000 + 0.5) or 0),
        tostring(Clamp(count, 1, 99)),
        class or "?",
        level and tostring(Clamp(level, 1, 999)) or "?",
        tostring(seq),
    }, "|")
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, chan)
    if not ok then return false end
    -- 0 = Success; cualquier otro valor (p. ej. 3 = limite de mensajes) no cuenta como enviado
    if res ~= nil and res ~= 0 and res ~= true then return false end
    return true
end

local function EvaluateSend()
    if not DB or not Active() or DB.receiveOnly then return end
    if not Channel() then return end
    local okd, dead = pcall(UnitIsDeadOrGhost, "player")
    if okd and dead then return end
    local count, maxLevel, class, unknownLevel = Summary()
    if count < DB.minCount or count < 1 then lastCount = count; return end
    if DB.minLevel > 0 and maxLevel and maxLevel < DB.minLevel and not unknownLevel then return end
    local now = GetTime()
    if now - lastSend < DB.sendInterval then return end
    local mapID, x, y = PlayerPosition()
    local zkey = mapID or 0
    local z = lastZone[zkey]
    if z and now - z.t < DB.zoneInterval and z.count == count then return end
    if SendAlert(mapID, x, y, count, class, maxLevel) then
        lastSend = now
        lastCount = count
        lastZone[zkey] = { t = now, count = count }
    end
end

----------------------------------------------------------------------
-- Recepcion: alertas
----------------------------------------------------------------------
local alerts = {}        -- lista de alertas activas
local senders = {}       -- anti-spam por emisor
local lastSound = 0
local UpdateMapPins, UpdateMinimapPins, UpdateArrow

local function Validate(text)
    if type(text) ~= "string" or #text > 60 then return nil end
    local parts = {}
    for p in string.gmatch(text .. "|", "([^|]*)|") do parts[#parts + 1] = p end
    if #parts ~= 8 or parts[1] ~= PROTO then return nil end
    local mapID = tonumber(parts[2])
    local x, y = tonumber(parts[3]), tonumber(parts[4])
    local count = tonumber(parts[5])
    if not (mapID and x and y and count) then return nil end
    if mapID ~= math.floor(mapID) or mapID < 0 or mapID > 100000 then return nil end
    local alert = {
        mapID = mapID,
        x = Clamp(x, 0, 1000) / 1000,
        y = Clamp(y, 0, 1000) / 1000,
        count = Clamp(math.floor(count), 1, 99),
    }
    if CLASSES[parts[6]] then alert.class = parts[6] end
    local lvl = tonumber(parts[7])
    if lvl then alert.level = Clamp(math.floor(lvl), 1, 999) end
    return alert
end

local function PlayerShortName()
    local ok, n = pcall(UnitName, "player")
    if ok and n and not issecret(n) then return n end
end

local function Receive(sender, text, force)
    if not DB or not mod.enabled then return end
    if issecret(text) or issecret(sender) then return end
    sender = ShortName(sender)
    if sender == "" then return end
    if not force and sender == PlayerShortName() then return end
    if DB.muted[sender] then return end
    local a = Validate(text)
    if not a then return end

    -- anti-spam por emisor: 3 s entre alertas y 8 por minuto
    local now = GetTime()
    local s = senders[sender]
    if not s then s = { last = -100, recent = {} }; senders[sender] = s end
    if not force then
        if now - s.last < DB.senderGap then return end
        local n = 0
        for i = #s.recent, 1, -1 do
            if now - s.recent[i] > 60 then table.remove(s.recent, i) else n = n + 1 end
        end
        if n >= DB.senderLimit then return end
        s.recent[#s.recent + 1] = now
    end
    s.last = now

    a.sender = sender
    a.t = now
    a.expire = now + DB.ttl
    -- una alerta nueva del mismo emisor y mapa sustituye a la anterior
    for i = #alerts, 1, -1 do
        if alerts[i].sender == sender then table.remove(alerts, i) end
    end
    alerts[#alerts + 1] = a
    while #alerts > math.max(1, DB.maxAlerts) do table.remove(alerts, 1) end

    if DB.chat then
        local cn = a.class and ClassName(a.class)
        local det = {}
        if cn then det[#det + 1] = cn end
        det[#det + 1] = a.level and ("nivel " .. a.level) or "nivel ??"
        Print(string.format("|cffff4040%s ve %d enemigo%s|r (%s) en %s",
            sender, a.count, a.count == 1 and "" or "s", table.concat(det, ", "), MapName(a.mapID)))
    end
    local kit = SOUNDKIT and (SOUNDKIT[DB.soundKit] or SOUNDKIT.RAID_WARNING)
    if DB.sound and kit and now - lastSound > DB.soundGap then
        lastSound = now
        pcall(PlaySound, kit)
    end
    if UpdateMapPins then UpdateMapPins() end
end

local function ExpireAlerts()
    local now, changed = GetTime(), false
    for i = #alerts, 1, -1 do
        if now >= alerts[i].expire then table.remove(alerts, i); changed = true end
    end
    return changed
end

----------------------------------------------------------------------
-- Pines del mapa del mundo
----------------------------------------------------------------------
local mapPins = {}
local function AlertTooltip(self, a)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Enemigos avisados por " .. a.sender, 1, 0.3, 0.3)
    GameTooltip:AddLine(a.count .. " enemigo" .. (a.count == 1 and "" or "s"), 1, 1, 1)
    local cn = a.class and ClassName(a.class)
    if cn then GameTooltip:AddLine(cn, 1, 1, 1) end
    GameTooltip:AddLine(a.level and ("Nivel " .. a.level) or "Nivel ??", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Hace " .. math.floor(GetTime() - a.t) .. " s", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function NewPin(parent, size)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(size, size)
    p:SetFrameStrata("HIGH")
    p.tex = p:CreateTexture(nil, "ARTWORK")
    p.tex:SetAllPoints(p)
    p.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_7")
    p.num = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.num:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 3, -3)
    p.num:SetTextColor(1, 1, 1)
    p:EnableMouse(true)
    p:SetScript("OnEnter", function(self) if self.alert then AlertTooltip(self, self.alert) end end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return p
end

UpdateMapPins = function()
    for _, p in ipairs(mapPins) do p:Hide() end
    if not mod.enabled or not DB.pinMap then return end
    if not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    local mapID = WorldMapFrame:GetMapID()
    local canvas = WorldMapFrame:GetCanvas()
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local n = 0
    for _, a in ipairs(alerts) do
        if a.mapID == mapID and a.x > 0 then
            n = n + 1
            local p = mapPins[n]
            if not p then p = NewPin(canvas, 20); mapPins[n] = p end
            p.alert = a
            p.num:SetText(a.count)
            p:SetSize(20 * DB.pinScale / 100, 20 * DB.pinScale / 100)
            p:ClearAllPoints()
            p:SetPoint("CENTER", canvas, "TOPLEFT", a.x * w, -a.y * h)
            p:Show()
        end
    end
end

----------------------------------------------------------------------
-- Marcadores del minimapa (en el borde, apuntan hacia la alerta)
----------------------------------------------------------------------
local OUTDOOR_DIAM = { [0] = 466.67, [1] = 400, [2] = 333.33, [3] = 266.67, [4] = 200, [5] = 133.33 }
local INDOOR_DIAM = { [0] = 300, [1] = 240, [2] = 180, [3] = 120, [4] = 80, [5] = 50 }
local miniPins = {}

local function MinimapRadiusYards()
    local zoom = Minimap.GetZoom and Minimap:GetZoom() or 0
    local indoors = false
    if IsIndoors then local ok, r = pcall(IsIndoors); indoors = ok and r end
    local t = indoors and INDOOR_DIAM or OUTDOOR_DIAM
    return (t[zoom] or t[3]) / 2
end

local function RotateMinimap()
    return GetCVar and GetCVar("rotateMinimap") == "1"
end

UpdateMinimapPins = function()
    for _, p in ipairs(miniPins) do p:Hide() end
    if not Minimap or not DB or not mod.enabled or not DB.pinMini then return end
    local n = 0
    local rpx = Minimap:GetWidth() / 2
    local ryd = MinimapRadiusYards()
    local facing = RotateMinimap() and GetPlayerFacing and GetPlayerFacing() or 0
    for _, a in ipairs(alerts) do
        local dist, bearing = DistanceBearing(a.mapID, a.x, a.y)
        if dist and bearing then
            n = n + 1
            local p = miniPins[n]
            if not p then p = NewPin(Minimap, 14); p:SetFrameLevel(Minimap:GetFrameLevel() + 6); miniPins[n] = p end
            p.alert = a
            p.num:SetText(a.count)
            p:SetSize(14 * DB.pinScale / 100, 14 * DB.pinScale / 100)
            local rel = bearing + (facing or 0)
            local frac = Clamp(dist / ryd, 0, 1)
            local r = rpx * (frac >= 1 and 0.92 or math.max(frac * 0.92, 0.1))
            p:ClearAllPoints()
            p:SetPoint("CENTER", Minimap, "CENTER", math.sin(rel) * r, math.cos(rel) * r)
            p:SetAlpha(frac >= 1 and 0.7 or 1)
            p:Show()
        end
    end
end

----------------------------------------------------------------------
-- Flecha en pantalla con distancia
----------------------------------------------------------------------
local arrow
local function BuildArrow()
    local f = mod:Frame("Frame", "CMAlertaEnemigosArrow", UIParent)
    f:SetSize(150, 56)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not DB.lock then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, rel, x, y = self:GetPoint()
        DB.arrowPos = { point = point, rel = rel, x = x, y = y }
    end)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetSize(36, 36)
    f.tex:SetPoint("TOP", 0, 0)
    f.tex:SetTexture(mod.path .. "arrow.tga")
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.text:SetPoint("TOP", f.tex, "BOTTOM", 0, -2)
    local pos = DB.arrowPos
    f:ClearAllPoints()
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.rel or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
    f:Hide()
    arrow = f
end

local function ApplyArrowStyle()
    if not arrow then return end
    local c = DB.arrowColor
    arrow:SetScale((DB.arrowScale or 100) / 100)
    arrow.tex:SetVertexColor(c[1], c[2], c[3])
    arrow.text:SetTextColor(c[1], c[2], c[3])
end

UpdateArrow = function()
    if not DB or not mod.enabled or not DB.arrow then if arrow then arrow:Hide() end return end
    local best, bd, bb
    for _, a in ipairs(alerts) do
        local dist, bearing = DistanceBearing(a.mapID, a.x, a.y)
        if dist and (not bd or dist < bd) then best, bd, bb = a, dist, bearing end
    end
    if not best then if arrow then arrow:Hide() end return end
    if not arrow then BuildArrow(); ApplyArrowStyle() end
    local facing = GetPlayerFacing and GetPlayerFacing() or 0
    local rel = bb + (facing or 0)          -- rumbo horario respecto a donde miras
    arrow.tex:SetRotation(-rel)             -- SetRotation gira en sentido antihorario
    arrow.text:SetText(string.format("%s: %d enemigo%s - %d m", best.sender, best.count,
        best.count == 1 and "" or "s", math.floor(bd * 0.9144 + 0.5)))
    arrow:Show()
end

----------------------------------------------------------------------
-- Silenciados
----------------------------------------------------------------------
local mutedText
local function MutedList()
    local t = {}
    for n in pairs(DB.muted) do t[#t + 1] = n end
    table.sort(t)
    return t
end

local function RefreshMuted()
    if not mutedText then return end
    local t = MutedList()
    mutedText:SetText(#t > 0 and ("Silenciados: |cffffffff" .. table.concat(t, ", ") .. "|r") or "Silenciados: ninguno")
end

local function Mute(name, on)
    name = ShortName(name)
    if name == "" then return end
    DB.muted[name] = on and true or nil
    RefreshMuted()
    Print(name .. (on and " silenciado" or " ya no esta silenciado"))
end

----------------------------------------------------------------------
-- Prueba local
----------------------------------------------------------------------
local function DoTest()
    local mapID, x, y = PlayerPosition()
    mapID = mapID or 0
    x = Clamp((x or 0.5) + 0.03, 0.01, 0.99)
    y = Clamp((y or 0.5) - 0.02, 0.01, 0.99)
    local msg = table.concat({ PROTO, mapID, math.floor(x * 1000), math.floor(y * 1000), 3, "MAGE", 60, 1 }, "|")
    Print("prueba: simulo un aviso recibido de \"Prueba\"")
    Receive("Prueba", msg, true)
end

local function ClearAlerts()
    wipe(alerts); UpdateMapPins(); UpdateMinimapPins(); UpdateArrow()
end

----------------------------------------------------------------------
-- Configuracion (pestana)
----------------------------------------------------------------------
local function NeedEnabled()
    if mod.enabled then return true end
    Print("activa primero el modulo (casilla de arriba).")
    return false
end

local function BuildConfig(m, L)
    DB = m.db
    L:Text("Tu grupo (con el addon) recibe aviso, pin y flecha cuando ves enemigos en el mundo abierto, y tu recibes lo mismo cuando ellos los ven.", true)

    L:Header("Enviar avisos")
    L:Check("Solo recibir (no avisar yo)", function() return DB.receiveOnly end, function(v) DB.receiveOnly = v end)
    L:Check("Solo en el mundo abierto (no en instancias, campos de batalla ni arenas)",
        function() return DB.outdoorOnly end, function(v) DB.outdoorOnly = v end)
    L:Slider("Avisar a partir de N enemigos", 1, 10, 1,
        function() return DB.minCount end, function(v) DB.minCount = v end)
    L:Slider("Nivel minimo del enemigo (0 = cualquiera)", 0, 90, 1,
        function() return DB.minLevel end, function(v) DB.minLevel = v end)
    L:Slider("Un enemigo cuenta como visto durante (segundos)", 2, 15, 1,
        function() return DB.window end, function(v) DB.window = v end)
    L:Slider("Pausa minima entre mis avisos (segundos)", 2, 30, 1,
        function() return DB.sendInterval end, function(v) DB.sendInterval = v end)
    L:Slider("Pausa en la misma zona con el mismo numero (segundos)", 5, 120, 5,
        function() return DB.zoneInterval end, function(v) DB.zoneInterval = v end)
    L:Text("Detectar enemigos con:", true)
    L:Check("Placas de nombre", function() return DB.units.nameplate end, function(v) DB.units.nameplate = v end)
    L:Check("Objetivo", function() return DB.units.target end, function(v) DB.units.target = v end)
    L:Check("Foco", function() return DB.units.focus end, function(v) DB.units.focus = v end)
    L:Check("Mouseover", function() return DB.units.mouseover end, function(v) DB.units.mouseover = v end)

    L:Header("Cuando recibo un aviso")
    L:Check("Mensaje en el chat", function() return DB.chat end, function(v) DB.chat = v end)
    L:Check("Sonido", function() return DB.sound end, function(v) DB.sound = v end)
    L:Choice("Tipo de sonido", {
        { "RAID_WARNING", "Aviso de banda" }, { "ALARM_CLOCK_WARNING_3", "Alarma" }, { "IG_PVP_UPDATE", "Aviso PvP" },
    }, function() return DB.soundKit end, function(v)
        DB.soundKit = v
        if SOUNDKIT and SOUNDKIT[v] then pcall(PlaySound, SOUNDKIT[v]) end
    end)
    L:Slider("Pausa minima entre sonidos (segundos)", 1, 30, 1,
        function() return DB.soundGap end, function(v) DB.soundGap = v end)
    L:Check("Pins en el mapa del mundo", function() return DB.pinMap end,
        function(v) DB.pinMap = v; UpdateMapPins() end)
    L:Check("Marcadores en el minimapa", function() return DB.pinMini end,
        function(v) DB.pinMini = v; UpdateMinimapPins() end)
    L:Check("Flecha en pantalla con distancia", function() return DB.arrow end,
        function(v) DB.arrow = v; UpdateArrow() end)
    L:Check("Bloquear la flecha (no moverla)", function() return DB.lock end, function(v) DB.lock = v end)
    L:Color("Color de la flecha", function() return DB.arrowColor[1], DB.arrowColor[2], DB.arrowColor[3] end,
        function(r, g, b) DB.arrowColor = { r, g, b }; ApplyArrowStyle() end)
    L:Slider("Tamano de la flecha", 50, 200, 5,
        function() return DB.arrowScale end, function(v) DB.arrowScale = v; ApplyArrowStyle() end, "%d%%")
    L:Slider("Tamano de los pins", 50, 200, 5,
        function() return DB.pinScale end, function(v) DB.pinScale = v; UpdateMapPins(); UpdateMinimapPins() end, "%d%%")
    L:Slider("Duracion de un pin (segundos)", 15, 300, 5,
        function() return DB.ttl end, function(v) DB.ttl = v end)
    L:Slider("Avisos guardados a la vez", 1, 20, 1,
        function() return DB.maxAlerts end, function(v) DB.maxAlerts = v end)

    L:Header("Anti-spam de emisores")
    L:Slider("Pausa minima entre avisos del mismo emisor (segundos)", 1, 30, 1,
        function() return DB.senderGap end, function(v) DB.senderGap = v end)
    L:Slider("Avisos por minuto aceptados de cada emisor", 1, 30, 1,
        function() return DB.senderLimit end, function(v) DB.senderLimit = v end)
    mutedText = L:Text("", true)
    L:Add({ Refresh = RefreshMuted }, 0)
    L:Edit("Silenciar a (nombre y Enter)", function() return "" end, function(v) Mute(v, true) end, "text")
    L:Edit("Quitar silencio a (nombre y Enter)", function() return "" end, function(v) Mute(v, false) end, "text")

    L:Header("Pruebas")
    L:Button("Probar aviso", 130, function() if NeedEnabled() then DoTest() end end)
    L:Button("Limpiar pines", 130, function() ClearAlerts() end, true)
end

----------------------------------------------------------------------
-- Comandos antiguos (/cmalerta, /alertaenemigos)
----------------------------------------------------------------------
local function OnSlash(m, msg)
    local cmd, arg = string.match(strlower(msg or ""), "^(%S*)%s*(.-)$")
    local rawArg = string.match(msg or "", "^%S*%s*(.-)$") or ""
    if cmd == "" or cmd == "config" then
        Hub:Open("alerta")
    elseif cmd == "prueba" or cmd == "test" then
        DoTest()
    elseif cmd == "limpiar" then
        ClearAlerts()
        Print("pines borrados")
    elseif cmd == "silenciar" and arg ~= "" then
        Mute(rawArg, true)
    elseif cmd == "quitar" and arg ~= "" then
        Mute(rawArg, false)
    elseif cmd == "minimap" then
        local c = ns.DB.minimap.alerta
        Hub:SetModuleButton("alerta", c.hide and true or false)
        Print("boton del minimapa: " .. (c.hide and "oculto" or "visible"))
    elseif cmd == "estado" then
        local count = Summary()
        Print(string.format("activo=%s, grupo=%s, solo recibir=%s, enemigos vistos=%d, alertas activas=%d",
            tostring(Active()), tostring(Channel() or "no"), tostring(DB.receiveOnly), count, #alerts))
    else
        Print("/cmalerta = configuracion | prueba | limpiar | silenciar <nombre> | quitar <nombre> | minimap | estado")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local hooked = false

local function Init(m)
    DB = m.db
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    end
    if WorldMapFrame and not hooked then
        hooked = true
        WorldMapFrame:HookScript("OnShow", function() if mod.enabled then UpdateMapPins() end end)
        if WorldMapFrame.OnMapChanged then
            hooksecurefunc(WorldMapFrame, "OnMapChanged", function() if mod.enabled then UpdateMapPins() end end)
        end
    end
    m:Event("CHAT_MSG_ADDON", function(_, _, prefix, text, _, sender)
        if issecret(prefix) or prefix ~= PREFIX then return end
        Receive(sender, text)
    end)
    m:Event("NAME_PLATE_UNIT_ADDED", function(_, _, unit) if DB.units.nameplate then Observe(unit) end end)
    m:Event("PLAYER_TARGET_CHANGED", function() if DB.units.target then Observe("target") end end)
    m:Event("UPDATE_MOUSEOVER_UNIT", function() if DB.units.mouseover then Observe("mouseover") end end)
    m:Event("PLAYER_ENTERING_WORLD", function()
        wipe(seen); wipe(lastZone); wipe(alerts)
        axisCache = {}
    end)

    local scanAcc, evalAcc, pinAcc = 0, 0, 0
    m:OnUpdate(function(_, elapsed)
        scanAcc = scanAcc + elapsed
        evalAcc = evalAcc + elapsed
        pinAcc = pinAcc + elapsed
        if scanAcc >= 0.5 then
            scanAcc = 0
            if Active() and not DB.receiveOnly then ScanNameplates() end
        end
        if evalAcc >= 1 then
            evalAcc = 0
            EvaluateSend()
            if ExpireAlerts() then UpdateMapPins() end
        end
        if pinAcc >= 0.25 then
            pinAcc = 0
            if #alerts > 0 or (arrow and arrow:IsShown()) or #miniPins > 0 then
                UpdateMinimapPins()
                UpdateArrow()
            end
        end
    end)
end

mod = Hub:Register{
    key = "alerta", dir = "AlertaEnemigos", name = "Alerta de enemigos",
    desc = "Cuando ves enemigos jugadores en el mundo abierto, avisa a tu grupo; los que tengan el addon reciben un aviso, un pin en el mapa y el minimapa y una flecha con la distancia.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosAlertaEnemigosDB",
    slash = { "cmalerta", "alertaenemigos" },
    Init = Init,
    Enable = function(m)
        DB = m.db
        ApplyArrowStyle()
        UpdateMapPins(); UpdateMinimapPins(); UpdateArrow()
    end,
    Disable = function(m)
        wipe(seen)
        UpdateMapPins(); UpdateMinimapPins()
        if arrow then arrow:Hide() end
    end,
    BuildConfig = BuildConfig,
    OnSlash = OnSlash,
    OnReset = function(m)
        DB = m.db
        ApplyArrowStyle()
        UpdateMapPins(); UpdateMinimapPins(); UpdateArrow()
    end,
}
