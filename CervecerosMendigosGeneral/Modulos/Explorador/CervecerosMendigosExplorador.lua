-- CervecerosMendigos · modulo Explorador (para el addon grande CervecerosMendigosGeneral).
-- Descubre el mapa:
--  * % explorado por zona, a partir de las texturas descubiertas (C_MapExplorationInfo).
--  * Puntos de vuelo conocidos y por descubrir (C_TaxiMap).
--  * Subzonas que faltan, si el cliente tiene logros de exploracion (GetAchievementCriteriaInfo).
--  * "Ir al mas cercano": marca en el mapa (C_Map.SetUserWaypoint) el punto de vuelo por descubrir
--    o la zona sin explorar mas cercana.
--  * Pins opcionales sobre el mapa del mundo y aviso al completar una zona.
-- IMPORTANTE: el cliente solo da las texturas que YA has descubierto, no el total. Por eso el
-- porcentaje es real solo con el logro de exploracion o tras "Calibrar 100%" (ver LEEME).
-- Configuracion: pestana "Explorador" del panel. Comandos: /explorador, /cmexplorador

local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local mod, S, DATA, CH     -- S = ajustes (mod.db); DATA = referencias e historial (fuera de mod.db); CH = datos de este personaje
local function Icon() return mod and mod.icon or "Interface\\Icons\\INV_Misc_QuestionMark" end
local function On() return S and DATA and mod and mod.enabled end

local DEFAULTS = {
    overlay = true,       -- pins sobre el mapa del mundo
    flightPins = true,    -- ... pins de puntos de vuelo por descubrir
    holePins = true,      -- ... pins de zonas sin explorar
    announce = true,      -- aviso al completar una zona
    announceSound = false, -- sonido al completar una zona
    maxPins = 8,          -- maximo de "huecos sin explorar" dibujados
    holeSpacing = 3,      -- separacion minima entre huecos (celdas)
    pinSize = 16,         -- tamano de los pins
    pinAlpha = 100,       -- opacidad de los pins (%)
    windowScale = 100,    -- tamano de la ventana (%)
}

local OpenConfig, Refresh  -- se definen mas abajo

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Explorador:|r " .. msg)
end

local ACC = { ["á"] = "a", ["é"] = "e", ["í"] = "i", ["ó"] = "o", ["ú"] = "u", ["ü"] = "u", ["ñ"] = "n",
              ["Á"] = "a", ["É"] = "e", ["Í"] = "i", ["Ó"] = "o", ["Ú"] = "u", ["Ñ"] = "n" }
local function Norm(s)
    s = tostring(s or "")
    s = s:gsub("[\195][\128-\191]", function(c) return ACC[c] or c end)
    return (s:lower():gsub("[^%w]", ""))
end

local function Vec(x, y)
    if CreateVector2D then return CreateVector2D(x, y) end
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

local function XY(v)
    if not v then return nil end
    if v.GetXY then return v:GetXY() end
    return v.x, v.y
end

local function Call(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, a, b, c = pcall(f, ...)
    if ok then return a, b, c end
end

local T_CONT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local T_ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

----------------------------------------------------------------------
-- Mapas: continente y zonas
----------------------------------------------------------------------
local function Info(id)
    return id and C_Map and C_Map.GetMapInfo and Call(C_Map.GetMapInfo, id)
end

local function MapName(id)
    local i = Info(id)
    return i and i.name or ("mapa " .. tostring(id))
end

-- Sube por los padres hasta un mapa del tipo pedido (o el propio).
local function Climb(id, mapType)
    local d = 0
    while id and id > 0 and d < 8 do
        local i = Info(id)
        if not i then return nil end
        if i.mapType == mapType then return id end
        id = i.parentMapID
        d = d + 1
    end
end

local function PlayerMap()
    return C_Map and C_Map.GetBestMapForUnit and Call(C_Map.GetBestMapForUnit, "player")
end

local function ContinentList()
    local list, seen = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = { id = id, name = MapName(id) }
        end
    end
    add(Climb(PlayerMap(), T_CONT))
    if C_Map and C_Map.GetMapChildrenInfo then
        for _, world in ipairs({ 947, 946 }) do
            local l = Call(C_Map.GetMapChildrenInfo, world, T_CONT, false)
            if type(l) == "table" then
                for _, i in ipairs(l) do add(i.mapID) end
            end
        end
    end
    if #list == 0 then add(1414); add(1415) end
    return list
end

local function ZoneList(cont)
    local out = {}
    local l = C_Map and C_Map.GetMapChildrenInfo and Call(C_Map.GetMapChildrenInfo, cont, T_ZONE, true)
    if type(l) == "table" then
        for _, i in ipairs(l) do
            if i.mapType == T_ZONE and i.name then out[#out + 1] = { id = i.mapID, name = i.name } end
        end
    end
    table.sort(out, function(a, b) return Norm(a.name) < Norm(b.name) end)
    return out
end

----------------------------------------------------------------------
-- Exploracion: cobertura, huecos y subzonas
----------------------------------------------------------------------
local function Layer(mapID)
    local l = C_Map and C_Map.GetMapArtLayers and Call(C_Map.GetMapArtLayers, mapID)
    local L = type(l) == "table" and l[1]
    if L and L.layerWidth and L.layerWidth > 0 and L.layerHeight and L.layerHeight > 0 then return L end
end

local function Textures(mapID)
    local t = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
        and Call(C_MapExplorationInfo.GetExploredMapTextures, mapID)
    return type(t) == "table" and t or {}
end

local cache = {}   -- mapID -> { cov=, holes=, subs=, ach= }
local function Slot(mapID)
    local s = cache[mapID]
    if not s then s = {}; cache[mapID] = s end
    return s
end

-- fraccion del mapa cubierta por las texturas descubiertas y numero de piezas
local function Coverage(mapID)
    local s = Slot(mapID)
    if s.cov ~= nil then return s.cov or nil end
    local L = Layer(mapID)
    if not L then s.cov = false; return nil end
    local tex = Textures(mapID)
    local area = 0
    for _, t in ipairs(tex) do
        local w = math.min(t.textureWidth or 0, L.layerWidth)
        local h = math.min(t.textureHeight or 0, L.layerHeight)
        area = area + w * h
    end
    s.cov = { frac = math.min(1, area / (L.layerWidth * L.layerHeight)), n = #tex }
    return s.cov
end

local N = 40
-- cuadricula N x N de celdas exploradas
local function Raster(mapID)
    local L = Layer(mapID)
    if not L then return nil end
    local cells = {}
    for i = 1, N * N do cells[i] = false end
    local count = 0
    for _, t in ipairs(Textures(mapID)) do
        local x0 = (t.offsetX or 0) / L.layerWidth
        local y0 = (t.offsetY or 0) / L.layerHeight
        local x1 = x0 + (t.textureWidth or 0) / L.layerWidth
        local y1 = y0 + (t.textureHeight or 0) / L.layerHeight
        local i0, i1 = math.max(1, math.floor(x0 * N) + 1), math.min(N, math.ceil(x1 * N))
        local j0, j1 = math.max(1, math.floor(y0 * N) + 1), math.min(N, math.ceil(y1 * N))
        for j = j0, j1 do
            local cy = (j - 0.5) / N
            if cy >= y0 and cy <= y1 then
                for i = i0, i1 do
                    local cx = (i - 0.5) / N
                    if cx >= x0 and cx <= x1 and not cells[(j - 1) * N + i] then
                        cells[(j - 1) * N + i] = true
                        count = count + 1
                    end
                end
            end
        end
    end
    return cells, count
end

local function WorldXY(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos) then return nil end
    local cont, pos = Call(C_Map.GetWorldPosFromMapPos, mapID, Vec(x, y))
    local wx, wy = XY(pos)
    if cont and wx then return cont, wx, wy end
end

local function PlayerWorld()
    local id = PlayerMap()
    if not id or not C_Map.GetPlayerMapPosition then return nil end
    local pos = Call(C_Map.GetPlayerMapPosition, id, "player")
    local x, y = XY(pos)
    if not x or (x == 0 and y == 0) then return nil end
    local cont, wx, wy = WorldXY(id, x, y)
    return cont, wx, wy, id, x, y
end

local function Dist(cont, wx, wy, c2, x2, y2)
    if not cont or cont ~= c2 then return nil end
    local dx, dy = wx - x2, wy - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- Huecos: celdas sin descubrir pegadas a zonas descubiertas (asi se descarta el mar lejano).
-- Una zona sin nada descubierto devuelve el centro.
local function Holes(mapID)
    local s = Slot(mapID)
    if s.holes then return s.holes end
    local cells, count = Raster(mapID)
    local out = {}
    if cells then
        if count == 0 then
            out[1] = { x = 0.5, y = 0.5 }
        else
            local function near(i, j)
                for dj = -2, 2 do
                    for di = -2, 2 do
                        local a, b = i + di, j + dj
                        if a >= 1 and a <= N and b >= 1 and b <= N and cells[(b - 1) * N + a] then return true end
                    end
                end
            end
            for j = 2, N - 1 do
                for i = 2, N - 1 do
                    if not cells[(j - 1) * N + i] and (i + j) % 2 == 0 and near(i, j) then
                        out[#out + 1] = { x = (i - 0.5) / N, y = (j - 0.5) / N, i = i, j = j }
                    end
                end
            end
        end
    end
    for _, h in ipairs(out) do h.c = (h.x - 0.5) ^ 2 + (h.y - 0.5) ^ 2 end
    s.holes = out
    return out
end

-- copia de los huecos con la distancia actual al jugador, del mas cercano al mas lejano
local function HolesNear(mapID)
    local pc, px, py = PlayerWorld()
    local out = {}
    for k, h in ipairs(Holes(mapID)) do
        local c, wx, wy = WorldXY(mapID, h.x, h.y)
        out[k] = { x = h.x, y = h.y, i = h.i, j = h.j, c = h.c, d = pc and Dist(pc, px, py, c, wx, wy) or nil }
    end
    table.sort(out, function(a, b)
        if a.d and b.d then return a.d < b.d end
        if a.d then return true end
        if b.d then return false end
        return a.c < b.c
    end)
    return out
end

-- Elige hasta k huecos separados entre si
local function Spaced(list, k, minCells)
    local out = {}
    for _, h in ipairs(list) do
        local ok = true
        for _, o in ipairs(out) do
            if h.i and o.i and math.abs(h.i - o.i) < minCells and math.abs(h.j - o.j) < minCells then ok = false; break end
        end
        if ok then out[#out + 1] = h end
        if #out >= k then break end
    end
    return out
end

-- Nombres de subzonas descubiertas (se muestrea el mapa y se pregunta que areas estan exploradas)
local function Subzones(mapID)
    local s = Slot(mapID)
    if s.subs then return s.subs end
    local names, seen = {}, {}
    if C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition and C_Map.GetAreaInfo then
        local G = 16
        for j = 1, G do
            for i = 1, G do
                local ids = Call(C_MapExplorationInfo.GetExploredAreaIDsAtPosition, mapID, Vec((i - 0.5) / G, (j - 0.5) / G))
                if type(ids) == "table" then
                    for _, id in ipairs(ids) do
                        if not seen[id] then
                            seen[id] = true
                            local n = Call(C_Map.GetAreaInfo, id)
                            if n and n ~= "" then names[#names + 1] = n end
                        end
                    end
                end
            end
        end
        table.sort(names)
    end
    s.subs = names
    return names
end

----------------------------------------------------------------------
-- Logros de exploracion (si el cliente los tiene): dan el % real y los nombres de lo que falta
----------------------------------------------------------------------
local achList  -- { {name=, norm=, crit={{name=,done=}}, done=, total=} }
local function BuildAch()
    achList = {}
    if type(GetCategoryList) ~= "function" or type(GetCategoryInfo) ~= "function"
        or type(GetCategoryNumAchievements) ~= "function" or type(GetAchievementInfo) ~= "function"
        or type(GetAchievementNumCriteria) ~= "function" or type(GetAchievementCriteriaInfo) ~= "function" then
        return
    end
    local cats = Call(GetCategoryList)
    if type(cats) ~= "table" then return end
    local isExp = {}
    for _, id in ipairs(cats) do
        local title, parent = Call(GetCategoryInfo, id)
        if title and Norm(title):find("explor", 1, true) then isExp[id] = true end
    end
    for _, id in ipairs(cats) do   -- hijas de una categoria de exploracion (dos niveles)
        local _, parent = Call(GetCategoryInfo, id)
        if parent and parent > 0 and isExp[parent] then isExp[id] = true end
    end
    for _, id in ipairs(cats) do
        if isExp[id] then
            local total = Call(GetCategoryNumAchievements, id) or 0
            for k = 1, total do
                local achID, name = Call(GetAchievementInfo, id, k)
                if achID and name then
                    local a = { name = name, norm = Norm(name), crit = {}, done = 0, total = 0 }
                    local nc = Call(GetAchievementNumCriteria, achID) or 0
                    for c = 1, nc do
                        local cname, _, completed = Call(GetAchievementCriteriaInfo, achID, c)
                        if cname and cname ~= "" then
                            a.crit[#a.crit + 1] = { name = cname, done = completed and true or false }
                            a.total = a.total + 1
                            if completed then a.done = a.done + 1 end
                        end
                    end
                    if a.total > 0 then achList[#achList + 1] = a end
                end
            end
        end
    end
end

local function AchFor(mapID)
    local s = Slot(mapID)
    if s.ach ~= nil then return s.ach or nil end
    if not achList then BuildAch() end
    local mn = Norm(MapName(mapID))
    local best
    if #mn >= 4 then
        for _, a in ipairs(achList) do
            if a.norm:find(mn, 1, true) and (not best or #a.norm < #best.norm) then best = a end
        end
    end
    s.ach = best or false
    return best
end

----------------------------------------------------------------------
-- Puntos de vuelo
----------------------------------------------------------------------
local flights = {}   -- continente -> lista de nodos
local function FactionOK(node)
    local g = UnitFactionGroup and UnitFactionGroup("player")
    local F = Enum and Enum.FlightPathFaction
    if F and node.faction == F.Horde then return g == "Horde" end
    if F and node.faction == F.Alliance then return g == "Alliance" end
    return true
end

local function NodesOf(mapID)
    if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return {} end
    local show = Call(C_TaxiMap.ShouldMapShowTaxiNodes, mapID)
    if show == false then return {} end
    local l = Call(C_TaxiMap.GetTaxiNodesForMap, mapID)
    return type(l) == "table" and l or {}
end

local function Flights(cont)
    if flights[cont] then return flights[cont] end
    local out, byId = {}, {}
    local function add(node, mapID, zone)
        if not FactionOK(node) or not node.nodeID then return end
        local x, y = XY(node.position)
        if not x then return end
        local rec = { id = node.nodeID, name = node.name or "?", map = mapID, x = x, y = y,
                      und = node.isUndiscovered and true or false, zone = zone }
        local old = byId[rec.id]
        if old then   -- preferir las coordenadas de la zona (mas precisas)
            if zone and old.map ~= mapID then
                old.map, old.x, old.y = rec.map, rec.x, rec.y
            end
            if zone then old.zone = zone end
        else
            byId[rec.id] = rec
            out[#out + 1] = rec
        end
    end
    for _, n in ipairs(NodesOf(cont)) do
        local x, y = XY(n.position)
        local z
        if x and C_Map.GetMapInfoAtPosition then
            local i = Call(C_Map.GetMapInfoAtPosition, cont, x, y)
            z = i and Climb(i.mapID, T_ZONE)
        end
        add(n, cont, z)
    end
    for _, zone in ipairs(ZoneList(cont)) do
        for _, n in ipairs(NodesOf(zone.id)) do add(n, zone.id, zone.id) end
    end
    flights[cont] = out
    return out
end

local function FlightCounts(cont)
    local u, t = {}, {}
    for _, f in ipairs(Flights(cont)) do
        local z = f.zone
        if z then
            t[z] = (t[z] or 0) + 1
            if f.und then u[z] = (u[z] or 0) + 1 end
        end
    end
    return u, t
end

----------------------------------------------------------------------
-- Progreso, historial y aviso
----------------------------------------------------------------------
-- devuelve fraccion 0..1, tipo ("logro" | "calibrado" | "cobertura") y la cobertura cruda
local function Progress(mapID)
    local c = Coverage(mapID)
    local a = AchFor(mapID)
    if a then return a.done / a.total, "logro", c and c.frac end
    if not c then return nil end
    local ref = DATA.ref[mapID]
    if ref and ref > 0 then return math.min(1, c.frac / ref), "calibrado", c.frac end
    return c.frac, "cobertura", c.frac
end

local function IsComplete(mapID)
    local a = AchFor(mapID)
    if a then return a.done >= a.total end
    local c = Coverage(mapID)
    local ref = DATA.ref[mapID]
    return c and ref and ref > 0 and c.frac >= ref * 0.995 and true or false
end

local lastCheck = 0
local function CheckCurrent()
    if not On() or not CH then return end
    local id = Climb(PlayerMap(), T_ZONE)
    if not id then return end
    local s = Slot(id); s.cov = nil; s.ach = nil
    local a = AchFor(id)
    local c = Coverage(id)
    -- un logro completo calibra la zona sola
    if a and a.done >= a.total and c and c.frac > 0 and not DATA.ref[id] then
        DATA.ref[id] = c.frac; DATA.refSrc[id] = "logro"
    end
    local complete = IsComplete(id)
    if CH.known[id] == nil then
        CH.known[id] = true             -- primera lectura: no avisar de lo ya hecho
        if complete then CH.done[id] = CH.done[id] or { t = time(), name = MapName(id) } end
    elseif complete and not CH.done[id] then
        CH.done[id] = { t = time(), name = MapName(id) }
        if S.announce then Print("|cff33ff33Zona explorada al 100%:|r " .. MapName(id)) end
        if S.announceSound and PlaySound and SOUNDKIT then
            local kit = SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.UI_70_ARTIFACT_FORGE_TRAIT_RANKUP
            if kit then pcall(PlaySound, kit) end
        end
    end
end

----------------------------------------------------------------------
-- Marcas en el mapa
----------------------------------------------------------------------
local function Waypoint(mapID, x, y, label)
    if mapID and UiMapPoint and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(mapID) then
        local pt = UiMapPoint.CreateFromCoordinates(mapID, x, y)
        if C_Map.SetUserWaypoint(pt) then
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
            Print(string.format("marca puesta: %s (%.1f, %.1f en %s)", label, x * 100, y * 100, MapName(mapID)))
            return true
        end
    end
    Print(string.format("no pude poner la marca en el mapa. %s esta en %s (%.1f, %.1f)", label, MapName(mapID), x * 100, y * 100))
end

-- punto de vuelo por descubrir mas cercano (continente = el de la zona elegida o el tuyo)
local function NearestFlight(cont)
    local pc, px, py = PlayerWorld()
    local best, bd
    for _, f in ipairs(Flights(cont)) do
        if f.und then
            local c, wx, wy = WorldXY(f.map, f.x, f.y)
            local d = pc and Dist(pc, px, py, c, wx, wy)
            if d and (not bd or d < bd) then best, bd = f, d end
        end
    end
    if not best then   -- sin posicion conocida: el primero por defecto
        for _, f in ipairs(Flights(cont)) do if f.und then best = f; break end end
    end
    return best, bd
end

local function GoFlight(cont)
    local f, d = NearestFlight(cont)
    if not f then Print("no queda ningun punto de vuelo por descubrir en este continente (o el cliente no los muestra)"); return end
    Waypoint(f.map, f.x, f.y, f.name .. (d and string.format(" (a ~%.0f yardas)", d) or ""))
end

local function GoHole(zone)
    local list = HolesNear(zone)
    local h = list[1]
    if not h then Print("no encuentro zonas sin explorar en " .. MapName(zone) .. " (o el cliente no da texturas de exploracion)"); return end
    Waypoint(zone, h.x, h.y, "zona sin explorar (puede ser mar o inaccesible)" .. (h.d and string.format(" a ~%.0f yardas", h.d) or ""))
end

----------------------------------------------------------------------
-- Pins sobre el mapa del mundo
----------------------------------------------------------------------
local pins = {}
local function GetPin(i)
    if pins[i] then return pins[i] end
    local p = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
    mod:Track(p)
    p:SetSize(S.pinSize or 16, S.pinSize or 16)
    p:SetFrameStrata("HIGH")
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints(p)
    p:EnableMouse(true)
    p:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.title or "", 0.2, 1, 0.6)
        if self.sub then GameTooltip:AddLine(self.sub, 1, 1, 1) end
        GameTooltip:Show()
    end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pins[i] = p
    return p
end

local shownMap
local function UpdatePins()
    for _, p in ipairs(pins) do p:Hide() end
    if not On() or not S.overlay or not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    local mapID = WorldMapFrame:GetMapID()
    shownMap = mapID
    if not mapID then return end
    local canvas = WorldMapFrame:GetCanvas()
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local n = 0
    local function place(x, y, tex, title, sub)
        n = n + 1
        local p = GetPin(n)
        p.tex:SetTexture(tex)
        p:SetSize(S.pinSize or 16, S.pinSize or 16)
        p:SetAlpha((S.pinAlpha or 100) / 100)
        p.title, p.sub = title, sub
        p:ClearAllPoints()
        p:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
        p:Show()
    end
    for _, node in ipairs(NodesOf(mapID)) do
        if S.flightPins and node.isUndiscovered and FactionOK(node) then
            local x, y = XY(node.position)
            if x then place(x, y, "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", node.name or "Punto de vuelo", "Punto de vuelo por descubrir") end
        end
    end
    local i = Info(mapID)
    if S.holePins and i and i.mapType == T_ZONE then
        for _, hole in ipairs(Spaced(HolesNear(mapID), S.maxPins, S.holeSpacing or 3)) do
            place(hole.x, hole.y, "Interface\\Icons\\INV_Misc_Map_01", "Zona sin explorar", "Puede ser mar o inaccesible")
        end
    end
end

----------------------------------------------------------------------
-- Ayudas de interfaz
----------------------------------------------------------------------
local MakeWindow = UI.MakeWindow

local widgets = {}
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
-- Ventana principal
----------------------------------------------------------------------
local win, rows, scroll
local ROWS, RH, LIST_TOP = 11, 22, -92
local items, offset = {}, 0
local conts, contIdx = {}, 1
local sel               -- uiMapID de la zona elegida
local showHist = false
local contLabel, detail

local function Pct(p) return p and string.format("%d%%", math.floor(p * 100 + 0.5)) or "-" end
local KIND_TXT = { logro = "logro", calibrado = "calibrado", cobertura = "cobertura" }
local KIND_COL = { logro = { 0.2, 0.9, 0.3 }, calibrado = { 0.3, 0.6, 1 }, cobertura = { 0.9, 0.7, 0.2 } }

local function BuildItems()
    items = {}
    local cont = conts[contIdx] and conts[contIdx].id
    if not cont then return end
    local u, t = FlightCounts(cont)
    for _, z in ipairs(ZoneList(cont)) do
        local p, kind, raw = Progress(z.id)
        items[#items + 1] = { id = z.id, name = z.name, p = p, kind = kind, raw = raw,
                              fu = u[z.id] or 0, ft = t[z.id] or 0, done = CH and CH.done[z.id] and true or false }
    end
end

local function DetailText()
    if showHist then
        local list = {}
        for id, d in pairs(CH.done) do list[#list + 1] = { id = id, d = d } end
        table.sort(list, function(a, b) return (a.d.t or 0) > (b.d.t or 0) end)
        local out = { "|cffffd100Zonas completadas (este personaje)|r" }
        if #list == 0 then out[#out + 1] = "Todavia ninguna. Se anotan al llegar al 100% (con logro o tras calibrar)." end
        for i = 1, math.min(#list, 12) do
            out[#out + 1] = string.format("%s - %s", list[i].d.name or MapName(list[i].id), date("%d/%m/%Y", list[i].d.t or 0))
        end
        return table.concat(out, "\n")
    end
    if not sel then return "Elige una zona de la lista." end
    local out = {}
    local p, kind, raw = Progress(sel)
    out[#out + 1] = "|cffffd100" .. MapName(sel) .. "|r"
    if not raw and not p then
        out[#out + 1] = "El cliente no da texturas de exploracion para este mapa."
    elseif kind == "logro" then
        local a = AchFor(sel)
        out[#out + 1] = string.format("Logro de exploracion: |cff33ff33%d/%d|r subzonas (%s)", a.done, a.total, Pct(p))
        local miss = {}
        for _, c in ipairs(a.crit) do if not c.done then miss[#miss + 1] = c.name end end
        if #miss > 0 then
            local shown = {}
            for i = 1, math.min(#miss, 8) do shown[i] = miss[i] end
            out[#out + 1] = "Faltan: " .. table.concat(shown, ", ") .. (#miss > 8 and (" y " .. (#miss - 8) .. " mas") or "")
        else
            out[#out + 1] = "|cff33ff33Zona completa.|r"
        end
    elseif kind == "calibrado" then
        out[#out + 1] = string.format("Explorado: |cff4d99ff~%s|r (referencia guardada, %s)", Pct(p), DATA.refSrc[sel] == "logro" and "por logro" or "calibrada por ti")
    else
        out[#out + 1] = string.format("Cobertura del mapa: |cffe6b333%s|r. Sin calibrar: el cliente no dice cuanto falta.", Pct(p))
        out[#out + 1] = "Cuando termines la zona, pulsa |cffffffffCalibrar 100%|r para tener el % real."
    end
    local c = Coverage(sel)
    if c then out[#out + 1] = string.format("Piezas del mapa descubiertas: %d", c.n) end
    if kind ~= "logro" then
        local subs = Subzones(sel)
        if #subs > 0 then
            local shown = {}
            for i = 1, math.min(#subs, 6) do shown[i] = subs[i] end
            out[#out + 1] = string.format("Subzonas descubiertas (%d): %s%s", #subs, table.concat(shown, ", "), #subs > 6 and "..." or "")
        end
    end
    local cont = Climb(sel, T_CONT)
    if cont then
        local und, tot = {}, 0
        for _, f in ipairs(Flights(cont)) do
            if f.zone == sel then
                tot = tot + 1
                if f.und then und[#und + 1] = f.name end
            end
        end
        if tot == 0 then
            out[#out + 1] = "Puntos de vuelo: ninguno en esta zona."
        elseif #und == 0 then
            out[#out + 1] = string.format("Puntos de vuelo: |cff33ff33los %d descubiertos|r", tot)
        else
            out[#out + 1] = string.format("Puntos de vuelo por descubrir (%d de %d): %s", #und, tot, table.concat(und, ", "))
        end
    end
    local h = HolesNear(sel)[1]
    if h then
        out[#out + 1] = "Zona sin explorar mas cercana: " .. (h.d and string.format("a ~%.0f yardas", h.d) or "(no se tu posicion)") .. " (puede ser mar)"
    end
    return table.concat(out, "\n")
end

local function UpdateRows()
    for i = 1, ROWS do
        local row, it = rows[i], items[i + offset]
        row.item = it
        if not it then
            row:Hide()
        else
            row:Show()
            row.text:SetText((it.done and "|cff33ff33*|r " or "") .. it.name)
            local col = KIND_COL[it.kind or "cobertura"]
            row.fill:SetColorTexture(col[1], col[2], col[3], 0.9)
            row.fill:SetWidth(math.max(1, 150 * (it.p or 0)))
            row.pct:SetText(it.p and ((it.kind == "cobertura" and "cob. " or (it.kind == "calibrado" and "~" or "")) .. Pct(it.p)) or "-")
            row.fp:SetText(it.ft > 0 and (it.fu > 0 and ("|cffffd100PV " .. it.fu .. " por descubrir|r") or "|cff33ff33PV completos|r") or "")
            if it.id == sel then row.bg:SetColorTexture(0.2, 0.4, 0.5, 0.6)
            else row.bg:SetColorTexture(0, 0, 0, (i % 2 == 0) and 0.15 or 0) end
        end
    end
end

local function SetupScroll()
    local maxOff = math.max(0, #items - ROWS)
    scroll.loading = true
    scroll:SetMinMaxValues(0, maxOff)
    if offset > maxOff then offset = maxOff end
    scroll:SetValue(offset)
    scroll.loading = false
    scroll:SetShown(maxOff > 0)
    UpdateRows()
end

local function SelectZone(id)
    sel = id
    showHist = false
    Refresh()
end

function Refresh()
    if not win or not win:IsShown() then return end
    contLabel:SetText(conts[contIdx] and conts[contIdx].name or "?")
    BuildItems()
    SetupScroll()
    detail:SetText(DetailText())
    for _, w in ipairs(widgets) do w:Refresh() end
end

local function ChangeCont(d)
    if #conts == 0 then return end
    contIdx = (contIdx - 1 + d) % #conts + 1
    sel, offset = nil, 0
    Refresh()
end

local function BuildRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(496, RH)
    row:SetPoint("TOPLEFT", 16, LIST_TOP - (i - 1) * RH)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0); row.text:SetWidth(180); row.text:SetJustifyH("LEFT")
    local back = row:CreateTexture(nil, "ARTWORK")
    back:SetPoint("LEFT", 190, 0); back:SetSize(150, 12)
    back:SetColorTexture(0.1, 0.1, 0.12, 1)
    row.fill = row:CreateTexture(nil, "OVERLAY")
    row.fill:SetPoint("LEFT", 190, 0); row.fill:SetHeight(12)
    row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.pct:SetPoint("LEFT", 190, 0); row.pct:SetWidth(150); row.pct:SetJustifyH("CENTER")
    row.fp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.fp:SetPoint("LEFT", 346, 0); row.fp:SetWidth(146); row.fp:SetJustifyH("LEFT")
    row:SetScript("OnClick", function(self) if self.item then SelectZone(self.item.id) end end)
    row:SetScript("OnEnter", function(self)
        local it = self.item
        if not it then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(it.name, 0.2, 1, 0.6)
        GameTooltip:AddLine("Clic para ver el detalle", 1, 1, 1)
        if it.kind == "cobertura" then
            GameTooltip:AddLine("Cobertura cruda: el cliente no da el total. Calibra al terminar la zona.", 0.9, 0.7, 0.2, true)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function Calibrate()
    if not sel then Print("elige primero una zona en la lista"); return end
    local c = Coverage(sel)
    if not c or c.frac <= 0 then Print("esa zona no tiene nada descubierto"); return end
    DATA.ref[sel] = c.frac; DATA.refSrc[sel] = "manual"
    if CH then CH.known[sel] = true; CH.done[sel] = CH.done[sel] or { t = time(), name = MapName(sel) } end
    Print(string.format("calibrado: %s se toma como 100%% con la cobertura actual (%s)", MapName(sel), Pct(c.frac)))
    Refresh()
end

local function ToChat()
    for line in (DetailText() .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then Print(line) end
    end
end

local function BuildConfig()
    win = MakeWindow("CervecerosMendigosExploradorConfig", "Explorador - Descubre el mapa", 540, 640)
    win:SetScale((S.windowScale or 100) / 100)
    local logo = win:CreateTexture(nil, "ARTWORK")
    logo:SetSize(36, 36); logo:SetPoint("TOPLEFT", 16, -30)
    logo:SetTexture(Icon())
    MakeButton(win, "<", 24, 24, "TOPLEFT", 60, -32, function() ChangeCont(-1) end)
    MakeButton(win, ">", 24, 24, "TOPLEFT", 440, -32, function() ChangeCont(1) end)
    contLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    contLabel:SetPoint("TOPLEFT", 90, -36); contLabel:SetWidth(346); contLabel:SetJustifyH("CENTER")

    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -74); hint:SetWidth(500); hint:SetJustifyH("LEFT")
    hint:SetText("Verde = logro (real) | azul ~ = calibrado | naranja cob. = cobertura cruda. PV = puntos de vuelo.")

    rows = {}
    for i = 1, ROWS do rows[i] = BuildRow(win, i) end

    scroll = CreateFrame("Slider", nil, win)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, ROWS * RH)
    scroll:SetPoint("TOPLEFT", 516, LIST_TOP)
    scroll:SetValueStep(1)
    if scroll.SetObeyStepOnDrag then scroll:SetObeyStepOnDrag(true) end
    local sbar = scroll:CreateTexture(nil, "BACKGROUND")
    sbar:SetColorTexture(0.2, 0.2, 0.25, 1)
    sbar:SetPoint("TOP"); sbar:SetPoint("BOTTOM"); sbar:SetWidth(6)
    scroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scroll:GetThumbTexture():SetSize(16, 24)
    scroll:SetScript("OnValueChanged", function(self, v)
        if self.loading then return end
        offset = math.floor(v + 0.5)
        UpdateRows()
    end)
    win:EnableMouseWheel(true)
    win:SetScript("OnMouseWheel", function(_, d)
        local maxOff = math.max(0, #items - ROWS)
        offset = math.max(0, math.min(maxOff, offset - d * 2))
        scroll.loading = true; scroll:SetValue(offset); scroll.loading = false
        UpdateRows()
    end)

    local dTop = LIST_TOP - ROWS * RH - 8
    detail = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail:SetPoint("TOPLEFT", 16, dTop); detail:SetWidth(508); detail:SetHeight(150)
    detail:SetJustifyH("LEFT"); detail:SetJustifyV("TOP")

    local by = dTop - 158
    MakeButton(win, "Punto de vuelo más cercano", 190, 24, "TOPLEFT", 16, by, function()
        local cont = (sel and Climb(sel, T_CONT)) or (conts[contIdx] and conts[contIdx].id)
        if cont then GoFlight(cont) end
    end)
    MakeButton(win, "Zona sin explorar más cercana", 190, 24, "TOPLEFT", 212, by, function()
        if sel then GoHole(sel) else Print("elige primero una zona en la lista") end
    end)
    MakeButton(win, "Mi zona", 100, 24, "TOPLEFT", 408, by, function()
        local z = Climb(PlayerMap(), T_ZONE)
        local c = Climb(PlayerMap(), T_CONT)
        for i, k in ipairs(conts) do if k.id == c then contIdx = i end end
        if z then sel = z end
        showHist = false
        Refresh()
    end)
    MakeButton(win, "Calibrar 100%", 120, 24, "TOPLEFT", 16, by - 28, Calibrate)
    MakeButton(win, "Historial", 100, 24, "TOPLEFT", 142, by - 28, function() showHist = not showHist; Refresh() end)
    MakeButton(win, "Al chat", 80, 24, "TOPLEFT", 248, by - 28, ToChat)
    MakeButton(win, "Quitar calibración", 140, 24, "TOPLEFT", 334, by - 28, function()
        if sel and DATA.ref[sel] then
            DATA.ref[sel], DATA.refSrc[sel] = nil, nil
            Print("calibración quitada en " .. MapName(sel)); Refresh()
        end
    end)

    MakeCheck(win, "Pins en el mapa del mundo", 16, by - 58,
        function() return S.overlay end, function(v) S.overlay = v; UpdatePins() end)
    MakeCheck(win, "Avisar al completar una zona", 200, by - 58,
        function() return S.announce end, function(v) S.announce = v end)
end

function OpenConfig()
    if not On() then return end
    if not win then BuildConfig() end
    win:SetScale((S.windowScale or 100) / 100)
    conts = ContinentList()
    local pc = Climb(PlayerMap(), T_CONT)
    contIdx = 1
    for i, k in ipairs(conts) do if k.id == pc then contIdx = i end end
    sel = Climb(PlayerMap(), T_ZONE)
    showHist = false
    if win:IsShown() then win:Hide() else win:Show() end
    Refresh()
end

----------------------------------------------------------------------
-- Diagnostico
----------------------------------------------------------------------
local function Diag()
    local function has(v) return v and "si" or "NO" end
    Print("APIs: GetExploredMapTextures " .. has(C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures)
        .. ", GetExploredAreaIDsAtPosition " .. has(C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition)
        .. ", GetTaxiNodesForMap " .. has(C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap)
        .. ", GetMapArtLayers " .. has(C_Map and C_Map.GetMapArtLayers)
        .. ", SetUserWaypoint " .. has(C_Map and C_Map.SetUserWaypoint)
        .. ", logros " .. has(type(GetCategoryList) == "function"))
    local id = PlayerMap()
    local z = Climb(id, T_ZONE)
    Print(string.format("Tu mapa: %s (%s). Zona: %s. Continente: %s", tostring(id), MapName(id), z and MapName(z) or "?", tostring(Climb(id, T_CONT))))
    if z then
        local c = Coverage(z)
        local L = Layer(z)
        Print(string.format("%s: piezas %s, cobertura %s, capa %s", MapName(z), c and c.n or "?", c and Pct(c.frac) or "?",
            L and (L.layerWidth .. "x" .. L.layerHeight) or "sin capa"))
        local a = AchFor(z)
        Print("Logro de exploracion: " .. (a and (a.name .. " " .. a.done .. "/" .. a.total) or "no encontrado (" .. (achList and #achList or 0) .. " logros de exploracion leidos)"))
        Print("Subzonas descubiertas: " .. #Subzones(z) .. ", huecos candidatos: " .. #Holes(z))
    end
    local cont = Climb(id, T_CONT)
    if cont then
        local list = Flights(cont)
        local u = 0
        for _, f in ipairs(list) do if f.und then u = u + 1 end end
        Print(string.format("Puntos de vuelo del continente: %d (por descubrir %d). Zonas: %d", #list, u, #ZoneList(cont)))
    end
end

----------------------------------------------------------------------
-- Diagnostico
----------------------------------------------------------------------
local function Diag()
    local function has(v) return v and "si" or "NO" end
    Print("APIs: GetExploredMapTextures " .. has(C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures)
        .. ", GetExploredAreaIDsAtPosition " .. has(C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition)
        .. ", GetTaxiNodesForMap " .. has(C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap)
        .. ", GetMapArtLayers " .. has(C_Map and C_Map.GetMapArtLayers)
        .. ", SetUserWaypoint " .. has(C_Map and C_Map.SetUserWaypoint)
        .. ", logros " .. has(type(GetCategoryList) == "function"))
    local id = PlayerMap()
    local z = Climb(id, T_ZONE)
    Print(string.format("Tu mapa: %s (%s). Zona: %s. Continente: %s", tostring(id), MapName(id), z and MapName(z) or "?", tostring(Climb(id, T_CONT))))
    if z then
        local c = Coverage(z)
        local L = Layer(z)
        Print(string.format("%s: piezas %s, cobertura %s, capa %s", MapName(z), c and c.n or "?", c and Pct(c.frac) or "?",
            L and (L.layerWidth .. "x" .. L.layerHeight) or "sin capa"))
        local a = AchFor(z)
        Print("Logro de exploracion: " .. (a and (a.name .. " " .. a.done .. "/" .. a.total) or "no encontrado (" .. (achList and #achList or 0) .. " logros de exploracion leidos)"))
        Print("Subzonas descubiertas: " .. #Subzones(z) .. ", huecos candidatos: " .. #Holes(z))
    end
    local cont = Climb(id, T_CONT)
    if cont then
        local list = Flights(cont)
        local u = 0
        for _, f in ipairs(list) do if f.und then u = u + 1 end end
        Print(string.format("Puntos de vuelo del continente: %d (por descubrir %d). Zonas: %d", #list, u, #ZoneList(cont)))
    end
end

----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local dirty, acc, checkAt = false, 0, nil
local function OnEvent(event)
    if not On() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        checkAt = (GetTime() or 0) + 3
        dirty = true
    else
        if event == "TAXI_NODE_STATUS_CHANGED" then wipe(flights) end
        if event == "MAP_EXPLORATION_UPDATED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ACHIEVEMENT_EARNED" or event == "CRITERIA_UPDATE" then
            wipe(cache)
            if event == "ACHIEVEMENT_EARNED" then achList = nil end
        end
        if event ~= "CRITERIA_UPDATE" then checkAt = (GetTime() or 0) + 2 end
        dirty = true
    end
end

local function OnUpdate(_, elapsed)
    acc = acc + elapsed
    if acc < 0.5 then return end
    acc = 0
    local now = GetTime() or 0
    if checkAt and now >= checkAt then
        checkAt = nil
        CheckCurrent()
    end
    local wm = WorldMapFrame and WorldMapFrame:IsVisible() and WorldMapFrame:GetMapID() or nil
    if dirty or (wm and wm ~= shownMap) or (not wm and shownMap) then
        dirty = false
        if not wm then shownMap = nil end
        UpdatePins()
        Refresh()
    end
end

local function OnSlash(_, msg)
    local cmd = string.match(strlower(msg or ""), "^(%S*)")
    if cmd == "" or cmd == "config" then
        OpenConfig()
    elseif cmd == "ir" or cmd == "pv" or cmd == "vuelo" then
        local cont = Climb(PlayerMap(), T_CONT)
        if cont then GoFlight(cont) else Print("no se en que continente estas") end
    elseif cmd == "hueco" or cmd == "zona" then
        local z = Climb(PlayerMap(), T_ZONE)
        if z then GoHole(z) else Print("no se en que zona estas") end
    elseif cmd == "calibrar" then
        sel = Climb(PlayerMap(), T_ZONE)
        Calibrate()
    elseif cmd == "pins" or cmd == "overlay" then
        S.overlay = not S.overlay; UpdatePins()
        Print("pins en el mapa del mundo: " .. (S.overlay and "activados" or "desactivados"))
    elseif cmd == "aviso" then
        S.announce = not S.announce
        Print("aviso al completar zona: " .. (S.announce and "activado" or "desactivado"))
    elseif cmd == "historial" then
        OpenConfig(); showHist = true; Refresh()
    elseif cmd == "minimap" then
        Print("el boton del minimapa se controla en la pestana Explorador (Boton en el minimapa).")
    elseif cmd == "diag" then
        wipe(cache); wipe(flights); Diag()
    else
        Print("/explorador = ventana | ir (punto de vuelo cercano) | hueco (zona sin explorar cercana) | calibrar | pins | aviso | historial | diag (ajustes en la pestana Explorador)")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local function BuildTab(m, L)
    L:Header("Explorador")
    L:Text("Mira el % explorado de cada zona, los puntos de vuelo por descubrir y marca en el mapa el sitio mas cercano. El cliente no da el total de zonas: el % es real con el logro de exploracion o tras Calibrar 100%.", true)
    L:Button("Abrir el explorador de zonas", 240, function() OpenConfig() end)
    L:Button("Punto de vuelo por descubrir mas cercano", 300, function() OnSlash(m, "ir") end)
    L:Button("Zona sin explorar mas cercana", 300, function() OnSlash(m, "hueco") end)
    L:Header("Avisos")
    L:Check("Avisar al completar una zona al 100%", function() return S.announce end, function(v) S.announce = v end)
    L:Check("Sonido al completar una zona", function() return S.announceSound end, function(v) S.announceSound = v end)
    L:Header("Pins en el mapa del mundo")
    L:Check("Mostrar pins en el mapa del mundo", function() return S.overlay end,
        function(v) S.overlay = v; UpdatePins() end)
    L:Check("... de puntos de vuelo por descubrir", function() return S.flightPins end,
        function(v) S.flightPins = v; UpdatePins() end)
    L:Check("... de zonas sin explorar", function() return S.holePins end,
        function(v) S.holePins = v; UpdatePins() end)
    L:Slider("Maximo de zonas sin explorar dibujadas", 1, 30, 1, function() return S.maxPins end,
        function(v) S.maxPins = v; UpdatePins() end)
    L:Slider("Separacion minima entre ellas", 1, 8, 1, function() return S.holeSpacing end,
        function(v) S.holeSpacing = v; UpdatePins() end)
    L:Slider("Tamano de los pins", 8, 40, 1, function() return S.pinSize end,
        function(v) S.pinSize = v; UpdatePins() end)
    L:Slider("Opacidad de los pins", 20, 100, 5, function() return S.pinAlpha end,
        function(v) S.pinAlpha = v; UpdatePins() end, "%d%%")
    L:Header("Ventana")
    L:Slider("Tamano de la ventana del explorador", 60, 130, 5, function() return S.windowScale end,
        function(v) S.windowScale = v; if win then win:SetScale(v / 100) end end, "%d%%")
end

local EVENTS = { "PLAYER_ENTERING_WORLD", "MAP_EXPLORATION_UPDATED", "TAXI_NODE_STATUS_CHANGED",
                 "ZONE_CHANGED_NEW_AREA", "ACHIEVEMENT_EARNED", "CRITERIA_UPDATE" }

mod = Hub:Register{
    key = "explorador", dir = "Explorador", name = "Explorador",
    desc = "Zonas por explorar, puntos de vuelo por descubrir y marca en el mapa del sitio mas cercano; pins opcionales en el mapa del mundo.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosExploradorDB",
    slash = { "explorador", "cmexplorador" },
    OnSlash = OnSlash,
    BuildConfig = BuildTab,
    rightHint = "mostrar/ocultar los pins del mapa del mundo",
    OnRightClick = function() S.overlay = not S.overlay; UpdatePins() end,
    OnReset = function() UpdatePins() end,
    Init = function(m)
        S = m.db
        ns.DB.data = ns.DB.data or {}
        local D = ns.DB.data.explorador
        if not D then D = {}; ns.DB.data.explorador = D end
        -- datos del addon suelto antiguo (llegan a mod.db por la migracion)
        for _, k in ipairs({ "ref", "refSrc", "chars" }) do
            if S[k] ~= nil and D[k] == nil then D[k] = S[k] end
            S[k] = nil
        end
        S.minimap = nil
        D.ref = D.ref or {}; D.refSrc = D.refSrc or {}; D.chars = D.chars or {}
        DATA = D
        local key = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
        DATA.chars[key] = DATA.chars[key] or {}
        CH = DATA.chars[key]
        CH.done = CH.done or {}
        CH.known = CH.known or {}
        for _, name in ipairs(EVENTS) do
            if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(name) then
                m:Event(name, function(_, event) OnEvent(event) end)
            end
        end
        m:OnUpdate(OnUpdate)
    end,
    Enable = function(m)
        S = m.db
        checkAt = (GetTime() or 0) + 3
        dirty = true
    end,
    Disable = function(m)
        for _, p in ipairs(pins) do p:Hide() end
        shownMap = nil
        if win then win:Hide() end
    end,
}
