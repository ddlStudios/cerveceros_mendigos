-- CervecerosMendigosMarcas para WoW Forever (cliente moderno, Interface 16001).
-- Marcas de mapa compartidas con el grupo: pones una marca (reunion, atacar, peligro, ayuda,
-- objetivo, recurso, nota) y le aparece a quien tenga el addon en tu grupo/banda/campo de batalla:
-- en el mapa del mundo, en el minimapa y con una flecha en pantalla.
-- Comunicacion: mensajes de addon con prefijo CMMARCAS. Protocolo (version 1):
--   crear : 1|uiMapID|x*10000|y*10000|tipo|texto|id
--   borrar: D|dueno|id
-- Todo lo recibido se valida (los datos ajenos no son de fiar). Si la persona no tiene el addon, no pasa nada.
-- Configuracion: boton del minimapa, o /marcas

local ADDON, ns = ...
local Hub = ns.Hub
local ICON = ""
local ARROW = ""
local PREFIX = "CMMARCAS"
local PROTO = "1"
local MAX_TEXT = 40          -- caracteres de texto por marca [protocolo]

local DEFAULTS = {
    kind = "reunion",        -- tipo por defecto al marcar
    expire = 10,             -- minutos (0 = nunca)
    sound = true,            -- sonido al recibir una marca
    soundName = "UI_MAP_WAYPOINT_CONTROL_CLICK",
    chat = true,             -- aviso en el chat al recibir una marca
    alertCooldown = 2,       -- segundos minimos entre avisos del mismo jugador
    onlyLeaders = false,     -- solo aceptar marcas del lider y asistentes
    receive = true,          -- recibir marcas de otros
    send = true,             -- enviar mis marcas al grupo
    resendNew = true,        -- reenviar mis marcas a quien entra al grupo
    miniPins = true,         -- mostrar marcas en el minimapa
    mapPins = true,          -- mostrar marcas en el mapa del mundo
    pinSize = 22,            -- tamano de los iconos en el mapa del mundo
    miniSize = 14,           -- tamano de los iconos en el minimapa
    maxPerOwner = 10,        -- marcas activas por jugador
    maxTotal = 60,           -- marcas activas en total
    rateLimit = 12,          -- maximo de mensajes por emisor cada 10 s antes de bloquearlo 30 s
    modifier = "alt",        -- alt | shift | ctrl | ctrlshift (con clic izquierdo en el mapa)
    arrow = { show = true, locked = true, point = "CENTER", x = 0, y = 200, scale = 100, alpha = 100 },
    colors = {
        reunion = { 1.00, 0.85, 0.20 }, atacar = { 1.00, 0.30, 0.30 }, peligro = { 1.00, 0.55, 0.10 },
        ayuda = { 0.35, 0.65, 1.00 }, objetivo = { 0.75, 0.40, 1.00 }, recurso = { 0.30, 0.90, 0.40 },
        nota = { 0.95, 0.95, 0.95 },
    },
    muted = {},              -- nombre -> true
}

local SOUND_OPTIONS = {
    { "UI_MAP_WAYPOINT_CONTROL_CLICK", "Marca de mapa" },
    { "RAID_WARNING", "Aviso de banda" },
    { "IG_QUEST_LIST_COMPLETE", "Mision completada" },
    { "READY_CHECK", "Comprobacion de listos" },
}

local mod

-- tipo, nombre, icono de marca de banda (1..8), color
local TYPES = {
    { "reunion",  "Reunión",  1, { 1.00, 0.85, 0.20 } },
    { "atacar",   "Atacar",   8, { 1.00, 0.30, 0.30 } },
    { "peligro",  "Peligro",  7, { 1.00, 0.55, 0.10 } },
    { "ayuda",    "Ayuda",    6, { 0.35, 0.65, 1.00 } },
    { "objetivo", "Objetivo", 3, { 0.75, 0.40, 1.00 } },
    { "recurso",  "Recurso",  4, { 0.30, 0.90, 0.40 } },
    { "nota",     "Nota",     2, { 0.95, 0.95, 0.95 } },
}
local TYPE = {}
for i, t in ipairs(TYPES) do TYPE[t[1]] = t end

local DB
local TCol = function(t) return (DB and DB.colors and DB.colors[t[1]]) or t[4] end
local issecret = issecretvalue or function() return false end
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local OpenMain, RefreshAll, RefreshList  -- se definen mas abajo

local function Print(msg)
    mod:Print(msg)
end

----------------------------------------------------------------------
-- Utilidades de texto
----------------------------------------------------------------------
-- recorta a n caracteres UTF-8 sin partir ninguno
local function TrimChars(s, n)
    local count, i, len = 0, 1, #s
    while i <= len do
        local b = s:byte(i)
        if b < 128 or b >= 192 then   -- empieza un caracter nuevo
            count = count + 1
            if count > n then return s:sub(1, i - 1) end
        end
        i = i + 1
    end
    return s
end

-- quita barras, codigos de color, saltos y caracteres de control
local function CleanText(s)
    s = tostring(s or "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h", ""):gsub("|h", "")
    s = s:gsub("[%c|]", " "):gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return TrimChars(s, MAX_TEXT)
end

local function ShortName(name)
    if not name then return "?" end
    if Ambiguate then return Ambiguate(name, "short") end
    return (name:gsub("%-.*$", ""))
end

local function Me() return (UnitName("player")) or "?" end

local function ZoneName(mapID)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    return (info and info.name) or ("mapa " .. tostring(mapID))
end

local function FmtDist(d)
    if not d then return "?" end
    if d >= 1000 then return string.format("%.1f km", d / 1000) end
    return string.format("%d m", math.floor(d + 0.5))
end

local function FmtAge(s)
    if s < 60 then return string.format("%ds", math.floor(s)) end
    return string.format("%dm", math.floor(s / 60))
end

local function Hex(c)
    return string.format("%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

----------------------------------------------------------------------
-- Estado de las marcas
----------------------------------------------------------------------
local marks = {}       -- lista (la mas nueva al final)
local byKey = {}       -- clave -> marca
local activeKey        -- marca seguida por la flecha (nil = la mas reciente)
local selectedKey      -- fila elegida en la ventana
local counter = 0
local lastPlaced = 0

local function NewId()
    counter = (counter + 1) % 256
    return string.format("%x%02x", math.floor(time() % 1048576), counter)
end

local function KeyOf(owner, id) return owner .. "-" .. id end

local function RemoveMark(key)
    local m = byKey[key]
    if not m then return false end
    byKey[key] = nil
    for i = #marks, 1, -1 do
        if marks[i] == m then table.remove(marks, i) break end
    end
    if activeKey == key then activeKey = nil end
    if selectedKey == key then selectedKey = nil end
    return true
end

local function CountOf(owner)
    local n = 0
    for _, m in ipairs(marks) do if m.owner == owner then n = n + 1 end end
    return n
end

local function OldestOf(owner)
    for _, m in ipairs(marks) do
        if not owner or m.owner == owner then return m end
    end
end

-- Mete o actualiza una marca. Devuelve la marca y si es nueva.
local function AddMark(m)
    m.key = KeyOf(m.owner, m.id)
    local old = byKey[m.key]
    if old then
        for k, v in pairs(m) do old[k] = v end
        old.t = GetTime()
        return old, false
    end
    while CountOf(m.owner) >= (DB.maxPerOwner or 10) do
        local o = OldestOf(m.owner)
        if not o then break end
        RemoveMark(o.key)
    end
    while #marks >= (DB.maxTotal or 60) do
        local o = OldestOf(nil)
        if not o then break end
        RemoveMark(o.key)
    end
    m.t = GetTime()
    byKey[m.key] = m
    marks[#marks + 1] = m
    return m, true
end

local function ActiveMark()
    if activeKey and byKey[activeKey] then return byKey[activeKey] end
    return marks[#marks]
end

----------------------------------------------------------------------
-- Grupo
----------------------------------------------------------------------
local function GroupUnit(name)
    if name == Me() then return "player" end
    if IsInRaid and IsInRaid() then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 40) do
            local u = "raid" .. i
            if UnitExists(u) and (UnitName(u)) == name then return u end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and (UnitName(u)) == name then return u end
        end
    end
end

local function IsLeader(name)
    local u = GroupUnit(name)
    if not u then return false end
    return (UnitIsGroupLeader and UnitIsGroupLeader(u)) and true or false
end

local function IsLeaderOrAssist(name)
    local u = GroupUnit(name)
    if not u then return false end
    return ((UnitIsGroupLeader and UnitIsGroupLeader(u)) or (UnitIsGroupAssistant and UnitIsGroupAssistant(u))) and true or false
end

local function Channel()
    local inst = LE_PARTY_CATEGORY_INSTANCE or (Enum and Enum.PartyCategory and Enum.PartyCategory.Instance)
    if IsInGroup and inst and IsInGroup(inst) then return "INSTANCE_CHAT" end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

local CHANNEL_NAME = { INSTANCE_CHAT = "instancia/campo de batalla", RAID = "banda", PARTY = "grupo" }

----------------------------------------------------------------------
-- Envio (cola con limite de ritmo y bloqueo de comunicaciones)
----------------------------------------------------------------------
local queue = {}
local tokens, lastRefill = 8, 0
local lockdownWarned = false

local function Locked()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, v = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and v then return true end
    end
    if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum and Enum.AddOnRestrictionType then
        local ok, v = pcall(C_RestrictedActions.IsAddOnRestrictionActive, Enum.AddOnRestrictionType.Chat)
        if ok and v then return true end
    end
    return false
end

local function Enqueue(text)
    if not Channel() then return end
    queue[#queue + 1] = { text = text, t = GetTime(), tries = 0 }
end

local function FlushQueue()
    local now = GetTime()
    tokens = math.min(8, tokens + (now - lastRefill) * 1)
    lastRefill = now
    while queue[1] do
        local q = queue[1]
        if now - q.t > 60 or q.tries >= 5 then
            table.remove(queue, 1)  -- demasiado viejo: se descarta
        else
            local ch = Channel()
            if not ch then table.remove(queue, 1)
            elseif tokens < 1 then return
            elseif Locked() then
                if not lockdownWarned then
                    lockdownWarned = true
                    Print("las comunicaciones de addons estan bloqueadas ahora (combate/partida); enviare las marcas en cuanto se pueda.")
                end
                return
            else
                lockdownWarned = false
                tokens = tokens - 1
                local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, q.text, ch)
                local R = Enum and Enum.SendAddonMessageResult
                if ok and (res == nil or res == 0 or (R and res == R.Success)) then
                    table.remove(queue, 1)
                elseif ok and R and (res == R.AddonMessageThrottle or res == R.ChannelThrottle or res == R.AddOnMessageLockdown) then
                    q.tries = q.tries + 1
                    return  -- se reintenta mas tarde
                else
                    table.remove(queue, 1)
                end
            end
        end
    end
end

local function SendCreate(m)
    if not DB.send then return end
    Enqueue(string.format("%s|%d|%d|%d|%s|%s|%s", PROTO, m.mapID,
        math.floor(m.x * 10000 + 0.5), math.floor(m.y * 10000 + 0.5), m.kind, m.text or "", m.id))
end

local function SendDelete(owner, id)
    if not DB.send then return end
    Enqueue(string.format("D|%s|%s", owner, id))
end

----------------------------------------------------------------------
-- Recepcion y validacion
----------------------------------------------------------------------
local rate = {}   -- emisor -> { t0, n, block }

local function RateOK(sender)
    local now = GetTime()
    local r = rate[sender]
    if not r then r = { t0 = now, n = 0, block = 0 }; rate[sender] = r end
    if now < r.block then return false end
    if now - r.t0 > 10 then r.t0 = now; r.n = 0 end
    r.n = r.n + 1
    if r.n > (DB.rateLimit or 12) then r.block = now + 30; return false end
    return true
end

local function DecodeCreate(text)
    local mp, xs, ys, kind, txt, id = text:match("^" .. PROTO .. "|(%d+)|(%d+)|(%d+)|(%a+)|([^|]*)|(%w+)$")
    if not mp then return nil end
    if #mp > 6 or #xs > 6 or #ys > 6 or #id > 8 then return nil end
    mp, xs, ys = tonumber(mp), tonumber(xs), tonumber(ys)
    if not mp or mp < 1 or mp > 99999 then return nil end
    if not TYPE[kind] then return nil end
    local x = math.max(0, math.min(1, xs / 10000))
    local y = math.max(0, math.min(1, ys / 10000))
    return { mapID = mp, x = x, y = y, kind = kind, text = CleanText(txt), id = id }
end

local function DecodeDelete(text)
    local owner, id = text:match("^D|([^|]+)|(%w+)$")
    if not owner or #owner > 40 or #id > 8 then return nil end
    return CleanText(owner), id
end

local lastAlert = {}

local function Alert(m)
    local now = GetTime()
    if lastAlert[m.owner] and now - lastAlert[m.owner] < (DB.alertCooldown or 2) then return end
    lastAlert[m.owner] = now
    if DB.chat then
        local t = TYPE[m.kind]
        Print(string.format("%s marcó |cff%s%s|r en %s%s", m.owner,
            Hex(TCol(t)), t[2], ZoneName(m.mapID),
            (m.text ~= "" and (": " .. m.text) or "")))
    end
    if DB.sound and PlaySound then
        local snd = (SOUNDKIT and (SOUNDKIT[DB.soundName] or SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK)) or 8959
        pcall(PlaySound, snd)
    end
end

-- force: se salta el filtro de lider (lo usa el modo de prueba)
local function OnAddonMessage(prefix, text, channel, sender, force)
    if prefix ~= PREFIX then return end
    if issecret(text) or issecret(sender) or issecret(channel) then return end
    if type(text) ~= "string" or type(sender) ~= "string" or #text > 200 then return end
    if not force and channel ~= "PARTY" and channel ~= "RAID" and channel ~= "INSTANCE_CHAT" then return end
    sender = ShortName(sender)
    if sender == Me() and not force then return end   -- eco de mis propios mensajes
    if DB.muted[sender] then return end
    if not RateOK(sender) then return end
    if not force and DB.onlyLeaders and not IsLeaderOrAssist(sender) then return end

    if text:sub(1, 2) == "D|" then
        local owner, id = DecodeDelete(text)
        if not owner then return end
        -- solo el dueno, o el lider del grupo
        if owner == sender or force or IsLeader(sender) then
            if RemoveMark(KeyOf(owner, id)) then RefreshAll() end
        end
        return
    end

    local m = DecodeCreate(text)
    if not m then return end
    m.owner = sender
    local mk, isNew = AddMark(m)
    if isNew then Alert(mk) end
    RefreshAll()
end

----------------------------------------------------------------------
-- Posiciones y distancias
----------------------------------------------------------------------
local function XY(pos)
    if not pos then return end
    local x, y
    if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
    if type(x) ~= "number" or type(y) ~= "number" or issecret(x) or issecret(y) then return end
    return x, y
end

local function PlayerPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
    local mid = C_Map.GetBestMapForUnit("player")
    if not mid then return end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mid, "player")
    if not ok then return end
    local x, y = XY(pos)
    if not x then return end
    local w, h = 0, 0
    if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(mid) end
    if not w or w <= 0 or not h or h <= 0 then return end
    return mid, x, y, w, h
end

-- coordenadas de la marca en otro mapa (padre/hijo/continente), usando el mundo como puente
local function ToMap(m, mapID)
    if m.mapID == mapID then return m.x, m.y end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
    local ok, cont, wpos = pcall(C_Map.GetWorldPosFromMapPos, m.mapID, CreateVector2D(m.x, m.y))
    if not ok or not cont or not wpos then return end
    local ok2, id, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, wpos, mapID)
    if not ok2 or not pos then return end
    if id and id ~= mapID then return end
    local x, y = XY(pos)
    return x, y
end

-- este (+) y norte (+) en yardas desde el jugador hasta la marca
local function Vector(m, pmap, px, py, w, h)
    local mx, my = ToMap(m, pmap)
    if not mx then return end
    local east, north = (mx - px) * w, -(my - py) * h
    return east, north, math.sqrt(east * east + north * north)
end

local function Facing()
    local f = GetPlayerFacing and GetPlayerFacing()
    if type(f) ~= "number" or issecret(f) then return 0 end
    return f
end

local function RotateMinimap()
    return GetCVar and GetCVar("rotateMinimap") == "1"
end

-- pasa (este, norte) a (derecha, arriba) segun la orientacion
local function Screen(east, north, rotated)
    if not rotated then return east, north end
    local f = Facing()
    local c, s = math.cos(f), math.sin(f)
    return east * c + north * s, -east * s + north * c
end

local pp = {}   -- posicion del jugador cacheada en cada pasada

local function Recompute()
    local mid, px, py, w, h = PlayerPos()
    pp.mid, pp.px, pp.py, pp.w, pp.h = mid, px, py, w, h
    for _, m in ipairs(marks) do
        m.east, m.north, m.dist = nil, nil, nil
        if mid then m.east, m.north, m.dist = Vector(m, mid, px, py, w, h) end
    end
end

----------------------------------------------------------------------
-- Poner y quitar marcas
----------------------------------------------------------------------
local function CanDelete(m)
    if m.owner == Me() then return true end
    return IsLeader(Me())
end

local function PlaceMark(kind, text, mapID, x, y)
    if not TYPE[kind] then kind = "reunion" end
    if not mapID or not x or x < 0 or x > 1 or y < 0 or y > 1 then
        Print("no puedo poner la marca ahi."); return
    end
    local now = GetTime()
    if now - lastPlaced < 1 then Print("vas muy rapido, espera un momento."); return end
    lastPlaced = now
    local m = { owner = Me(), id = NewId(), mapID = mapID, x = x, y = y, kind = kind, text = CleanText(text) }
    local mk = AddMark(m)
    SendCreate(mk)
    local t = TYPE[kind]
    local ch = Channel()
    Print(string.format("marca «%s» puesta en %s%s.", t[2], ZoneName(mapID),
        (ch and DB.send) and (" y enviada al " .. CHANNEL_NAME[ch]) or (ch and " (solo local: envio desactivado)" or " (solo local: no estas en grupo)")))
    RefreshAll()
end

local function PlaceHere(kind, text)
    local mid, px, py = PlayerPos()
    if not mid then Print("no consigo tu posicion (en interiores o instancias el mapa no la da)."); return end
    PlaceMark(kind, text, mid, px, py)
end

local function DeleteMark(m)
    if not m then return end
    if not CanDelete(m) then Print("solo puedes borrar tus marcas (o cualquiera si eres el lider)."); return end
    local owner, id = m.owner, m.id
    RemoveMark(m.key)
    SendDelete(owner, id)
    RefreshAll()
end

local function ClearMine()
    local n = 0
    for i = #marks, 1, -1 do
        local m = marks[i]
        if m.owner == Me() then
            SendDelete(m.owner, m.id); RemoveMark(m.key); n = n + 1
        end
    end
    RefreshAll()
    return n
end

local function ClearAll()
    local n = 0
    local leader = IsLeader(Me())
    for i = #marks, 1, -1 do
        local m = marks[i]
        if m.owner == Me() or leader then
            SendDelete(m.owner, m.id); RemoveMark(m.key); n = n + 1
        else
            RemoveMark(m.key)  -- las ajenas solo se quitan en local
        end
    end
    RefreshAll()
    return n
end

local function GoTo(m)
    if not m then return end
    local id = m.mapID
    if C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(id) and UiMapPoint then
        local pt = UiMapPoint.CreateFromCoordinates(id, m.x, m.y)
        if C_Map.SetUserWaypoint(pt) then
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
            Print(string.format("marca del juego puesta en %s (%.1f, %.1f).", ZoneName(id), m.x * 100, m.y * 100))
            return
        end
    end
    Print(string.format("no pude poner la marca del juego. Esta en %s (%.1f, %.1f).", ZoneName(id), m.x * 100, m.y * 100))
end

----------------------------------------------------------------------
-- Prueba local: simula recibir marcas de otro jugador
----------------------------------------------------------------------
local function RunTest()
    local mid, px, py = PlayerPos()
    if not mid then mid, px, py = (C_Map.GetBestMapForUnit("player") or 1429), 0.5, 0.5 end
    local fake = {
        { 0.020, 0.000, "peligro", "Patrulla enemiga" },
        { -0.015, 0.025, "atacar", "Aqui!" },
        { 0.000, -0.030, "reunion", "Nos vemos" },
    }
    for i, f in ipairs(fake) do
        local x = math.max(0, math.min(1, px + f[1]))
        local y = math.max(0, math.min(1, py + f[2]))
        local txt = string.format("%s|%d|%d|%d|%s|%s|%s", PROTO, mid, math.floor(x * 10000 + 0.5),
            math.floor(y * 10000 + 0.5), f[3], f[4], "t" .. i)
        OnAddonMessage(PREFIX, txt, "PARTY", "Prueba-Reino", true)
    end
    Print("3 marcas de prueba de «Prueba» creadas (no se envian). /marcas prueba borrar las quita.")
end

local function ClearTest()
    local n = 0
    for i = #marks, 1, -1 do
        if marks[i].owner == "Prueba" then RemoveMark(marks[i].key); n = n + 1 end
    end
    RefreshAll()
    Print(n .. " marcas de prueba borradas.")
end

----------------------------------------------------------------------
-- Pines en el mapa del mundo
----------------------------------------------------------------------
local worldPins = {}

local function ShowMarkTooltip(owner, m)
    local t = TYPE[m.kind]
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(t[2] .. (m.text ~= "" and (": " .. m.text) or ""), TCol(t)[1], TCol(t)[2], TCol(t)[3])
    GameTooltip:AddLine("de " .. m.owner .. " · " .. ZoneName(m.mapID), 1, 1, 1)
    GameTooltip:AddLine("hace " .. FmtAge(GetTime() - m.t) .. (m.dist and (" · a " .. FmtDist(m.dist)) or ""), 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Clic: seguir con la flecha", 0.6, 0.8, 1)
    if CanDelete(m) then GameTooltip:AddLine("Clic derecho: borrar", 0.6, 0.8, 1) end
    GameTooltip:Show()
end

local function GetWorldPin(i)
    if worldPins[i] then return worldPins[i] end
    local canvas = WorldMapFrame:GetCanvas()
    local p = CreateFrame("Button", nil, canvas)
    mod:Track(p)
    p:SetSize(DB.pinSize or 22, DB.pinSize or 22)
    p:SetFrameStrata("HIGH")
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints(p)
    p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    p:SetScript("OnEnter", function(self) if self.mark then ShowMarkTooltip(self, self.mark) end end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p:SetScript("OnClick", function(self, button)
        local m = self.mark
        if not m then return end
        if button == "RightButton" then DeleteMark(m)
        else activeKey = m.key; RefreshAll() end
    end)
    worldPins[i] = p
    return p
end

local function UpdateWorldPins()
    for _, p in ipairs(worldPins) do p:Hide(); p.mark = nil end
    if not DB or not mod:IsEnabled() or not DB.mapPins or not WorldMapFrame or not WorldMapFrame.IsVisible or not WorldMapFrame:IsVisible() then return end
    local mid = WorldMapFrame:GetMapID()
    if not mid then return end
    local canvas = WorldMapFrame:GetCanvas()
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local n = 0
    for _, m in ipairs(marks) do
        local x, y = ToMap(m, mid)
        if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            n = n + 1
            local p = GetWorldPin(n)
            p.mark = m
            p:SetSize(DB.pinSize or 22, DB.pinSize or 22)
            local t = TYPE[m.kind]
            p.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. t[3])
            p:ClearAllPoints()
            p:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
            p:Show()
        end
    end
end

----------------------------------------------------------------------
-- Pines en el minimapa
----------------------------------------------------------------------
local miniPins = {}

local function GetMiniPin(i)
    if miniPins[i] then return miniPins[i] end
    local p = CreateFrame("Frame", nil, Minimap)
    mod:Track(p)
    p:SetSize(DB.miniSize or 14, DB.miniSize or 14)
    p:SetFrameStrata("MEDIUM")
    p:SetFrameLevel(9)
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints(p)
    p.arrow = p:CreateTexture(nil, "ARTWORK")
    p.arrow:SetSize(14, 14)
    p.arrow:SetTexture(ARROW)
    p:EnableMouse(false)
    miniPins[i] = p
    return p
end

local function UpdateMinimap()
    for _, p in ipairs(miniPins) do p:Hide() end
    if not DB.miniPins or not mod:IsEnabled() or not pp.mid or not Minimap or not Minimap:IsVisible() then return end
    local radiusY = (C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()) or 150
    if type(radiusY) ~= "number" or issecret(radiusY) or radiusY <= 0 then radiusY = 150 end
    local half = Minimap:GetWidth() / 2
    local pxPerYard = half / radiusY
    local maxr = half - 6
    local rotated = RotateMinimap()
    local n = 0
    for _, m in ipairs(marks) do
        if m.east then
            n = n + 1
            local p = GetMiniPin(n)
            local t = TYPE[m.kind]
            p:SetSize(DB.miniSize or 14, DB.miniSize or 14)
            local sx, sy = Screen(m.east, m.north, rotated)
            local ox, oy = sx * pxPerYard, sy * pxPerYard
            local d = math.sqrt(ox * ox + oy * oy)
            p.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. t[3])
            if d > maxr and d > 0 then
                ox, oy = ox / d * maxr, oy / d * maxr
                p.tex:SetAlpha(0.8)
                p.arrow:SetVertexColor(TCol(t)[1], TCol(t)[2], TCol(t)[3])
                p.arrow:SetRotation(atan2(-sx, sy))
                p.arrow:ClearAllPoints()
                p.arrow:SetPoint("CENTER", p, "CENTER", ox / d * 9, oy / d * 9)
                p.arrow:Show()
            else
                p.tex:SetAlpha(1)
                p.arrow:Hide()
            end
            p:ClearAllPoints()
            p:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
            p:Show()
        end
    end
end

----------------------------------------------------------------------
-- Flecha en pantalla
----------------------------------------------------------------------
local arrowFrame

local function BuildArrow()
    local f = mod:Frame("Frame", "CervecerosMendigosMarcasArrow", UIParent)
    f:SetSize(120, 90)
    f:SetFrameStrata("MEDIUM")
    f:SetPoint(DB.arrow.point or "CENTER", UIParent, DB.arrow.point or "CENTER", DB.arrow.x or 0, DB.arrow.y or 200)
    f:SetMovable(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not DB.arrow.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, x, y = self:GetPoint()
        DB.arrow.point, DB.arrow.x, DB.arrow.y = p, x, y
    end)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetSize(48, 48)
    f.tex:SetPoint("TOP", 0, 0)
    f.tex:SetTexture(ARROW)
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.name:SetPoint("TOP", f.tex, "BOTTOM", 0, -2)
    f.dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.dist:SetPoint("TOP", f.name, "BOTTOM", 0, -2)
    f:Hide()
    arrowFrame = f
end

local function UpdateArrow()
    if not arrowFrame then return end
    local m = ActiveMark()
    arrowFrame:EnableMouse(not DB.arrow.locked)
    arrowFrame:SetScale((DB.arrow.scale or 100) / 100)
    arrowFrame:SetAlpha((DB.arrow.alpha or 100) / 100)
    if not DB.arrow.show or not m or not m.east then arrowFrame:Hide(); return end
    local t = TYPE[m.kind]
    if m.dist < 8 then
        arrowFrame.tex:SetVertexColor(0.3, 1, 0.3)
        arrowFrame.dist:SetText("¡Aquí!")
    else
        local sx, sy = Screen(m.east, m.north, true)
        arrowFrame.tex:SetVertexColor(TCol(t)[1], TCol(t)[2], TCol(t)[3])
        arrowFrame.tex:SetRotation(atan2(-sx, sy))
        arrowFrame.dist:SetText(FmtDist(m.dist))
    end
    arrowFrame.name:SetText(t[2] .. (m.text ~= "" and (": " .. m.text) or ""))
    arrowFrame:Show()
end

----------------------------------------------------------------------
-- Ayudas de interfaz
----------------------------------------------------------------------
local function MakeWindow(name, title, w, h)
    local f = Hub.UI.MakeWindow(name, title, w, h)
    mod:Track(f)
    return f
end

local widgets = {}

local function MakeSlider(parent, label, minv, maxv, step, x, y, width, get, set, fmt)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(width, 16)
    s:SetPoint("TOPLEFT", x, y - 16)
    s:SetMinMaxValues(minv, maxv)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    local bar = s:CreateTexture(nil, "BACKGROUND")
    bar:SetColorTexture(0.25, 0.25, 0.3, 1)
    bar:SetPoint("LEFT"); bar:SetPoint("RIGHT"); bar:SetHeight(6)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local function Show(v) fs:SetText(label .. ": |cffffffff" .. (fmt and fmt(v) or string.format("%d", v)) .. "|r") end
    s:SetScript("OnValueChanged", function(self, v)
        if self.loading then return end
        v = math.floor(v / step + 0.5) * step
        set(v); Show(v)
    end)
    s.Refresh = function(self)
        self.loading = true
        local v = get()
        self:SetValue(v); Show(v)
        self.loading = false
    end
    widgets[#widgets + 1] = s
    return s
end

local function MakeCheck(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Refresh = function(self) self:SetChecked(get()) end
    widgets[#widgets + 1] = cb
    return cb
end

local function MakeButton(parent, label, w, h, point, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h); b:SetPoint(point, x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

----------------------------------------------------------------------
-- Ventana principal: lista de marcas
----------------------------------------------------------------------
local win, rows, typeButtons = nil, {}, {}
local noteBox, infoLabel, countLabel
local ROWS, RH = 8, 40
local LIST_TOP = -118
local offset = 0
local clearArmed = false

local function SortedMarks()
    local list = {}
    for i = #marks, 1, -1 do list[#list + 1] = marks[i] end  -- la mas nueva arriba
    return list
end

local function SelectedMark() return selectedKey and byKey[selectedKey] or nil end

local function UpdateTypeButtons()
    for _, b in ipairs(typeButtons) do
        local t = TYPE[b.kind]
        local sel = (DB.kind == b.kind)
        b:SetText(sel and ("|cffffffff[" .. t[2] .. "]|r") or t[2])
    end
end

RefreshList = function()
    if not win or not win:IsShown() then return end
    local list = SortedMarks()
    local n = #list
    if offset > math.max(0, n - ROWS) then offset = math.max(0, n - ROWS) end
    for i = 1, ROWS do
        local row, m = rows[i], list[offset + i]
        if m then
            local t = TYPE[m.kind]
            row.mark = m
            row.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. t[3])
            row.l1:SetText(string.format("|cff%s%s|r%s", Hex(TCol(t)),
                t[2], (m.text ~= "" and (": " .. m.text) or "")))
            row.l2:SetText(string.format("%s%s · %s · %s · hace %s",
                (activeKey == m.key or (not activeKey and m == marks[#marks])) and "|cff55ff55> |r" or "",
                m.owner .. (DB.muted[m.owner] and " (silenciado)" or ""), ZoneName(m.mapID),
                FmtDist(m.dist), FmtAge(GetTime() - m.t)))
            row.sel:SetShown(selectedKey == m.key)
            row:Show()
        else
            row.mark = nil
            row:Hide()
        end
    end
    local ch = Channel()
    infoLabel:SetText(ch and ("Canal: |cff55ff55" .. CHANNEL_NAME[ch] .. "|r") or "|cffffaa55Sin grupo: las marcas son solo locales|r")
    countLabel:SetText(string.format("%d marcas", n))
end

local function BuildRow(parent, i)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(430, RH - 2)
    r:SetPoint("TOPLEFT", 10, LIST_TOP - (i - 1) * RH)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(r)
    r.sel:SetColorTexture(0.2, 0.5, 0.9, 0.25)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", 4, 0)
    r.l1 = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.l1:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, -1)
    r.l1:SetJustifyH("LEFT")
    r.l2 = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.l2:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 6, 1)
    r.l2:SetJustifyH("LEFT")
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        if not self.mark then return end
        selectedKey = self.mark.key
        if button == "RightButton" then activeKey = self.mark.key end
        RefreshList()
    end)
    r:SetScript("OnDoubleClick", function(self) if self.mark then GoTo(self.mark) end end)
    r:SetScript("OnEnter", function(self) if self.mark then ShowMarkTooltip(self, self.mark) end end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return r
end

local function PlaceFromWindow()
    PlaceHere(DB.kind, noteBox and noteBox:GetText() or "")
    if noteBox then noteBox:SetText("") end
end

local function BuildMain()
    win = MakeWindow("CervecerosMendigosMarcasWindow", "Marcas compartidas", 460, 520)
    win:SetScript("OnShow", function() RefreshList() end)
    win:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta); RefreshList()
    end)
    win:EnableMouseWheel(true)

    local lbl = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 14, -32); lbl:SetText("Tipo de marca:")
    for i, t in ipairs(TYPES) do
        local b = MakeButton(win, t[2], 58, 22, "TOPLEFT", 12 + (i - 1) * 61, -48, function(self)
            DB.kind = self.kind; UpdateTypeButtons()
        end)
        b.kind = t[1]
        typeButtons[#typeButtons + 1] = b
    end
    UpdateTypeButtons()

    noteBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    noteBox:SetSize(280, 22)
    noteBox:SetPoint("TOPLEFT", 20, -80)
    noteBox:SetAutoFocus(false)
    noteBox:SetMaxLetters(MAX_TEXT)
    noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); PlaceFromWindow() end)
    local nl = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nl:SetPoint("BOTTOMLEFT", noteBox, "TOPLEFT", -4, 0); nl:SetText("Texto corto (opcional)")
    MakeButton(win, "Marcar aquí", 110, 24, "TOPLEFT", 316, -79, PlaceFromWindow)

    infoLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoLabel:SetPoint("TOPLEFT", 14, -106)
    countLabel = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countLabel:SetPoint("TOPRIGHT", -16, -106)

    for i = 1, ROWS do rows[i] = BuildRow(win, i) end

    local y = LIST_TOP - ROWS * RH - 8
    MakeButton(win, "Ir (mapa)", 80, 24, "TOPLEFT", 12, y, function() GoTo(SelectedMark() or ActiveMark()) end)
    MakeButton(win, "Seguir", 70, 24, "TOPLEFT", 96, y, function()
        local m = SelectedMark()
        if m then activeKey = m.key; RefreshAll() else Print("elige una marca de la lista primero.") end
    end)
    MakeButton(win, "Borrar", 70, 24, "TOPLEFT", 170, y, function()
        local m = SelectedMark()
        if m then DeleteMark(m) else Print("elige una marca de la lista primero.") end
    end)
    local clearBtn
    clearBtn = MakeButton(win, "Borrar todas", 96, 24, "TOPLEFT", 244, y, function()
        if not clearArmed then
            clearArmed = true
            clearBtn:SetText("¿Seguro?")
            if C_Timer then C_Timer.After(3, function() clearArmed = false; clearBtn:SetText("Borrar todas") end) end
            return
        end
        clearArmed = false
        clearBtn:SetText("Borrar todas")
        Print(ClearAll() .. " marcas borradas.")
    end)
    MakeButton(win, "Silenciar", 80, 24, "TOPLEFT", 344, y, function()
        local m = SelectedMark()
        if not m then Print("elige una marca de la lista primero."); return end
        if m.owner == Me() then Print("no puedes silenciarte a ti mismo."); return end
        DB.muted[m.owner] = (not DB.muted[m.owner]) or nil
        Print(m.owner .. (DB.muted[m.owner] and " silenciado: no veras sus marcas." or " ya no esta silenciado."))
        RefreshList()
    end)
    MakeButton(win, "Opciones", 90, 24, "TOPLEFT", 12, y - 30, function() Hub:Open("marcas") end)
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 112, y - 36)
    hint:SetText("Doble clic: marca del juego · Clic derecho: seguir con la flecha")
end

OpenMain = function()
    if not win then BuildMain() end
    if win:IsShown() then win:Hide() else win:Show() end
end

----------------------------------------------------------------------
-- Opciones: ahora son la pestana del modulo en el panel
----------------------------------------------------------------------
local MODS = { "alt", "shift", "ctrl", "ctrlshift" }
local MODNAME = { alt = "Alt", shift = "Mayus", ctrl = "Ctrl", ctrlshift = "Ctrl+Mayus" }
local OpenOptions = function() Hub:Open("marcas") end

----------------------------------------------------------------------
-- Actualizacion
----------------------------------------------------------------------
RefreshAll = function()
    Recompute()
    UpdateWorldPins()
    UpdateMinimap()
    UpdateArrow()
    RefreshList()
end

local acc, acc2 = 0, 0
local function Tick(dt)
    if not DB then return end
    acc = acc + dt
    acc2 = acc2 + dt
    if queue[1] then FlushQueue() end
    if acc >= 0.1 then
        acc = 0
        if #marks > 0 then
            Recompute()
            UpdateMinimap()
            UpdateArrow()
        else
            UpdateMinimap()
            UpdateArrow()
        end
    end
    if acc2 >= 1 then
        acc2 = 0
        local changed = false
        if DB.expire and DB.expire > 0 then
            local now = GetTime()
            for i = #marks, 1, -1 do
                if now - marks[i].t > DB.expire * 60 then RemoveMark(marks[i].key); changed = true end
            end
        end
        if changed then RefreshAll() else RefreshList(); if WorldMapFrame and WorldMapFrame:IsVisible() then UpdateWorldPins() end end
    end
end

----------------------------------------------------------------------
-- Clic en el mapa del mundo
----------------------------------------------------------------------
local function ModifierDown()
    local m = DB.modifier
    local a, s, c = IsAltKeyDown(), IsShiftKeyDown(), IsControlKeyDown()
    if m == "alt" then return a and not s and not c
    elseif m == "shift" then return s and not a and not c
    elseif m == "ctrl" then return c and not a and not s
    elseif m == "ctrlshift" then return c and s and not a end
    return false
end

local mapHooked = false
local downX, downY
local function HookMap()
    if mapHooked or not WorldMapFrame or not WorldMapFrame.ScrollContainer then return end
    mapHooked = true
    local sc = WorldMapFrame.ScrollContainer
    sc:HookScript("OnMouseDown", function(_, button)
        if not mod:IsEnabled() then return end
        downX, downY = GetCursorPosition()
    end)
    sc:HookScript("OnMouseUp", function(_, button)
        if not mod:IsEnabled() or button ~= "LeftButton" or not ModifierDown() then return end
        local cx, cy = GetCursorPosition()
        if downX and (math.abs(cx - downX) > 6 or math.abs(cy - downY) > 6) then return end  -- fue un arrastre
        local mid = WorldMapFrame:GetMapID()
        local x, y = WorldMapFrame:GetNormalizedCursorPosition()
        if not mid or type(x) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then return end
        local text = noteBox and noteBox:GetText() or ""
        PlaceMark(DB.kind, text, mid, x, y)
        if noteBox then noteBox:SetText("") end
    end)
    WorldMapFrame:HookScript("OnShow", UpdateWorldPins)
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", UpdateWorldPins) end
end

----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local lastGroupSize = 0
local resendPending = false

local function ResendMine()
    resendPending = false
    if not Channel() then return end
    for _, m in ipairs(marks) do
        if m.owner == Me() then SendCreate(m) end
    end
end

local function OnEvent(event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 == "Blizzard_WorldMap" and DB then HookMap() end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        if DB then
            HookMap()
            lastGroupSize = GetNumGroupMembers and GetNumGroupMembers() or 0
        end
    elseif event == "CHAT_MSG_ADDON" then
        if DB and DB.receive then OnAddonMessage(a1, a2, a3, a4) end
    elseif event == "GROUP_ROSTER_UPDATE" then
        if not DB then return end
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        if DB.resendNew and n > lastGroupSize and CountOf(Me()) > 0 and not resendPending then
            resendPending = true   -- alguien nuevo: le reenvio mis marcas
            if C_Timer then C_Timer.After(3, function() if mod:IsEnabled() then ResendMine() else resendPending = false end end) else ResendMine() end
        end
        lastGroupSize = n
        RefreshList()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        lockdownWarned = false
        if queue[1] then FlushQueue() end
    end
end

----------------------------------------------------------------------
-- Comandos
----------------------------------------------------------------------
local function ParseKind(word)
    if not word then return nil end
    word = word:lower()
    local alias = { reunion = "reunion", ["reunión"] = "reunion", atacar = "atacar", ataque = "atacar",
        peligro = "peligro", ayuda = "ayuda", objetivo = "objetivo", recurso = "recurso", nota = "nota" }
    return alias[word]
end

local function Diag()
    local ch = Channel()
    Print("canal: " .. (ch or "ninguno (no estas en grupo)") .. " · prefijo registrado: " ..
        tostring(C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered and C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)))
    Print("comunicaciones bloqueadas: " .. tostring(Locked()) .. " · mensajes en cola: " .. #queue)
    local mid, px, py, w, h = PlayerPos()
    Print(mid and string.format("tu posicion: mapa %d (%.1f, %.1f), %d x %d yardas", mid, px * 100, py * 100, w, h)
        or "no consigo tu posicion (interior/instancia o valor secreto)")
    Print(#marks .. " marcas activas (" .. CountOf(Me()) .. " tuyas)")
end

local function OnSlash(m, msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "abrir" or cmd == "lista" then
        OpenMain()
    elseif cmd == "aqui" or cmd == "aquí" then
        local kind, text = DB.kind, rest
        local first, remain = rest:match("^(%S+)%s*(.*)$")
        local k = ParseKind(first)
        if k then kind, text = k, remain end
        PlaceHere(kind, text)
    elseif cmd == "prueba" then
        if rest:lower() == "borrar" then ClearTest() else RunTest() end
    elseif cmd == "borrar" then
        Print(ClearMine() .. " marcas tuyas borradas.")
    elseif cmd == "borrartodas" then
        Print(ClearAll() .. " marcas borradas.")
    elseif cmd == "flecha" then
        local a = rest:lower()
        if a == "mover" or a == "desbloquear" then DB.arrow.locked = false; DB.arrow.show = true; Print("flecha desbloqueada: arrastrala.")
        elseif a == "bloquear" then DB.arrow.locked = true; Print("flecha bloqueada.")
        else DB.arrow.show = not DB.arrow.show; Print("flecha " .. (DB.arrow.show and "activada" or "desactivada") .. ".") end
        RefreshAll()
    elseif cmd == "expira" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 60 then DB.expire = math.floor(n); Print("las marcas caducan a los " .. DB.expire .. " min (0 = nunca).")
        else Print("uso: /marcas expira <0-60>") end
    elseif cmd == "silenciar" then
        local who = ShortName(rest)
        if rest == "" then Print("uso: /marcas silenciar <nombre>")
        else
            DB.muted[who] = (not DB.muted[who]) or nil
            Print(who .. (DB.muted[who] and " silenciado." or " ya no esta silenciado."))
        end
    elseif cmd == "opciones" or cmd == "config" then
        OpenOptions()
    elseif cmd == "diag" then
        Diag()
    else
        Print("comandos: /marcas (lista) · aqui [tipo] [texto] · borrar · borrartodas · flecha [mover|bloquear] · expira <min> · silenciar <nombre> · prueba [borrar] · opciones · diag")
        Print("tipos: reunion, atacar, peligro, ayuda, objetivo, recurso, nota")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local function ClearLocal()
    for k in pairs(byKey) do byKey[k] = nil end
    for i = #marks, 1, -1 do marks[i] = nil end
    activeKey, selectedKey = nil, nil
end

mod = Hub:Register{
    key = "marcas", dir = "Marcas", name = "Marcas de mapa del grupo",
    desc = "Pon una marca en el mapa (reunion, atacar, peligro, ayuda...) y le aparece a todo tu grupo en el mapa, el minimapa y con una flecha en pantalla. Tipos, colores, avisos y limites configurables.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosMarcasDB",
    slash = { "marcas", "cmmarcas" },

    Init = function(m)
        DB = m.db
        ICON = m.path .. "icon.tga"
        ARROW = m.path .. "arrow.tga"
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        end
        BuildArrow()
        m:Event("ADDON_LOADED", function(_, e, a1) OnEvent(e, a1) end)
        m:Event("PLAYER_LOGIN", function(_, e) OnEvent(e) end)
        m:Event("PLAYER_ENTERING_WORLD", function(_, e) OnEvent(e) end)
        m:Event("GROUP_ROSTER_UPDATE", function(_, e) OnEvent(e) end)
        m:Event("CHAT_MSG_ADDON", function(_, e, a1, a2, a3, a4) OnEvent(e, a1, a2, a3, a4) end)
        m:Event("ADDON_RESTRICTION_STATE_CHANGED", function(_, e) OnEvent(e) end)
        m:OnUpdate(function(_, dt) Tick(dt) end)
    end,

    Enable = function(m)
        DB = m.db
        lastRefill = GetTime()
        lastGroupSize = GetNumGroupMembers and GetNumGroupMembers() or 0
        HookMap()
        RefreshAll()
    end,

    Disable = function(m)
        ClearLocal()
        resendPending = false
        if arrowFrame then arrowFrame:Hide() end
        if win then win:Hide() end
    end,

    OnReset = function(m)
        DB = m.db
        if m:IsEnabled() then RefreshAll() end
    end,

    BuildConfig = function(m, L)
        local db = m.db
        L:Header("Poner marcas")
        L:Text("Marca en el mapa del mundo con el boton izquierdo mas la tecla elegida, o con /marcas aqui [tipo] [texto].", true)
        L:Button("Abrir la lista de marcas", 220, function() OpenMain() end)
        L:Choice("Tecla para marcar en el mapa", (function()
            local o = {}
            for i, k in ipairs(MODS) do o[i] = { k, MODNAME[k] } end
            return o
        end)(), function() return db.modifier end, function(v) db.modifier = v end)
        L:Text("Con Ctrl el juego pone ademas su propia marca, y se pisan.", true)
        L:Choice("Tipo de marca por defecto", (function()
            local o = {}
            for i, t in ipairs(TYPES) do o[i] = { t[1], t[2] } end
            return o
        end)(), function() return db.kind end, function(v) db.kind = v; UpdateTypeButtons() end)

        L:Header("Colores de cada tipo")
        for _, t in ipairs(TYPES) do
            L:Color(t[2], function() local c = TCol(t); return c[1], c[2], c[3] end,
                function(r, g, b) db.colors[t[1]] = { r, g, b }; RefreshAll() end)
        end

        L:Header("Que veo")
        L:Check("Marcas en el mapa del mundo", function() return db.mapPins end, function(v) db.mapPins = v; RefreshAll() end)
        L:Check("Marcas en el minimapa", function() return db.miniPins end, function(v) db.miniPins = v; RefreshAll() end)
        L:Slider("Tamano de los iconos en el mapa", 12, 48, 1, function() return db.pinSize end, function(v) db.pinSize = v; RefreshAll() end)
        L:Slider("Tamano de los iconos en el minimapa", 8, 32, 1, function() return db.miniSize end, function(v) db.miniSize = v; RefreshAll() end)
        L:Slider("Caducidad de las marcas (min, 0 = nunca)", 0, 60, 1, function() return db.expire end, function(v) db.expire = v end)

        L:Header("Flecha en pantalla")
        L:Check("Flecha hacia la marca activa", function() return db.arrow.show end, function(v) db.arrow.show = v; RefreshAll() end)
        L:Check("Bloquear la flecha (desmarcar para moverla)", function() return db.arrow.locked end, function(v) db.arrow.locked = v; RefreshAll() end)
        L:Slider("Tamano de la flecha (%)", 50, 250, 5, function() return db.arrow.scale end, function(v) db.arrow.scale = v; RefreshAll() end)
        L:Slider("Opacidad de la flecha (%)", 20, 100, 5, function() return db.arrow.alpha end, function(v) db.arrow.alpha = v; RefreshAll() end)

        L:Header("Avisos al recibir una marca")
        L:Check("Sonido", function() return db.sound end, function(v) db.sound = v end)
        L:Choice("Sonido elegido", SOUND_OPTIONS, function() return db.soundName end, function(v) db.soundName = v end)
        L:Check("Aviso en el chat", function() return db.chat end, function(v) db.chat = v end)
        L:Slider("Pausa minima entre avisos del mismo jugador (s)", 0, 30, 1, function() return db.alertCooldown end, function(v) db.alertCooldown = v end)

        L:Header("Comunicacion con el grupo")
        L:Check("Recibir las marcas de otros", function() return db.receive end, function(v) db.receive = v end)
        L:Check("Enviar mis marcas al grupo", function() return db.send end, function(v) db.send = v end)
        L:Check("Solo aceptar marcas del lider y asistentes", function() return db.onlyLeaders end, function(v) db.onlyLeaders = v end)
        L:Check("Reenviar mis marcas a quien entra al grupo", function() return db.resendNew end, function(v) db.resendNew = v end)
        L:Slider("Maximo de marcas activas por jugador", 1, 30, 1, function() return db.maxPerOwner end, function(v) db.maxPerOwner = v end)
        L:Slider("Maximo de marcas activas en total", 5, 100, 5, function() return db.maxTotal end, function(v) db.maxTotal = v end)
        L:Slider("Mensajes por jugador antes de bloquearlo 30 s", 4, 40, 1, function() return db.rateLimit end, function(v) db.rateLimit = v end)
        L:Button("Quitar a todos los silenciados", 220, function()
            for k in pairs(db.muted) do db.muted[k] = nil end
            Print("lista de silenciados vaciada.")
            RefreshList()
        end)

        L:Header("Pruebas")
        L:Button("Probar con marcas falsas", 190, RunTest)
        L:Button("Quitar pruebas", 130, ClearTest, true)
        L:Button("Diagnostico (chat)", 160, Diag, true)
    end,

    OnSlash = OnSlash,
}
