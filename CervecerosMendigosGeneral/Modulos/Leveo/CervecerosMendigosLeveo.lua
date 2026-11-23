-- CervecerosMendigos · modulo Leveo (para el addon grande CervecerosMendigosGeneral).
-- 1) Ruta de leveo: lista las misiones de tu zona que te tocan por nivel, sin hacer,
--    con requisitos cumplidos, ordenadas por cercania a tu nivel y agrupadas por dador.
--    Boton "Marcar" pone una marca en el mapa en las coordenadas del dador.
-- 2) Contador de experiencia por hora y tiempo estimado hasta subir de nivel.
-- Datos de misiones en Datos.lua (generado por _herramientas/generar_datos.py).
-- Configuracion: pestana "Leveo" del panel. Comandos: /leveo, /cmleveo

local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local mod, S, DB, DATA   -- S = ajustes (mod.db); DATA = sesion de xp y mapas aprendidos (fuera de mod.db)
local function Icon() return mod and mod.icon or "Interface\\Icons\\INV_Misc_QuestionMark" end
local function On() return S and DATA and mod and mod.enabled end

local DEFAULTS = {
    auto = true,          -- seguir la zona en la que estas
    zone = nil,           -- slug de la zona elegida a mano
    below = 7,            -- ocultar misiones mas de N niveles por debajo del tuyo
    above = 4,            -- ocultar misiones mas de N niveles por encima del tuyo
    showLocked = false,   -- mostrar misiones cuyos requisitos aun no cumples
    showActive = true,    -- mostrar misiones ya aceptadas
    showNoLevel = false,  -- mostrar misiones de nivel desconocido
    bar = { show = false, point = "CENTER", x = 0, y = -220, scale = 100, width = 380, alpha = 60, color = { 0.55, 0.25, 0.85 }, locked = false },
    sessionMinutes = 30,  -- una sesion sin ganar xp tanto tiempo se da por terminada
    minActive = 20,       -- segundos activos minimos para calcular xp/hora
    idleCap = 120,        -- segundos maximos que cuentan entre dos ganancias de xp
    showRested = true,    -- mostrar la xp descansada
    windowScale = 100,    -- tamano de la ventana de la ruta (%)
}

local ZONES = CMLZones or {}
local QUESTS = CMLQuests or {}
local OpenConfig, RefreshList, RefreshXP  -- se definen mas abajo

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Leveo:|r " .. msg)
end


----------------------------------------------------------------------
-- Zonas y mapas
----------------------------------------------------------------------
local ACC = { ["á"] = "a", ["é"] = "e", ["í"] = "i", ["ó"] = "o", ["ú"] = "u", ["ü"] = "u", ["ñ"] = "n",
              ["Á"] = "a", ["É"] = "e", ["Í"] = "i", ["Ó"] = "o", ["Ú"] = "u", ["Ñ"] = "n" }
local function Norm(s)
    s = tostring(s or "")
    s = s:gsub("[\195][\128-\191]", function(c) return ACC[c] or c end)
    return (s:lower():gsub("[^%w]", ""))
end

local zoneBySlug, zoneByName, mapOf, mapOK, slugOfMap = {}, {}, {}, {}, {}
local zoneIndex = {}  -- slug -> indice en ZONES

local function BuildZoneIndex()
    for i, z in ipairs(ZONES) do
        zoneBySlug[z[1]] = z
        zoneIndex[z[1]] = i
        zoneByName[Norm(z[2])] = z
        zoneByName[Norm(z[3])] = z
    end
end

-- Comprueba cada uiMapID con el nombre que da el cliente; si no cuadra, busca la zona por nombre
-- entre las zonas de los continentes. Lo que no se puede comprobar se deja con el id de serie.
local function ResolveMaps()
    wipe(mapOf); wipe(mapOK); wipe(slugOfMap)
    local byName = {}
    if C_Map and C_Map.GetMapChildrenInfo then
        local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
        for _, cont in ipairs({ 1414, 1415, 947, 946 }) do
            local ok, list = pcall(C_Map.GetMapChildrenInfo, cont, zoneType, true)
            if ok and type(list) == "table" then
                for _, info in ipairs(list) do
                    if info.name and info.mapID then byName[Norm(info.name)] = info.mapID end
                end
            end
        end
    end
    for _, z in ipairs(ZONES) do
        local slug, id = z[1], z[7]
        local ok = false
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        if info and info.name then
            local n = Norm(info.name)
            ok = (n == Norm(z[2]) or n == Norm(z[3]))
        end
        if not ok then
            local alt = DATA.maps[slug] or byName[Norm(z[2])] or byName[Norm(z[3])]
            if alt then id = alt; ok = true end
        end
        mapOf[slug] = id
        mapOK[slug] = ok
        slugOfMap[id] = slug
    end
end

local function CurrentSlug()
    local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local depth = 0
    while id and id > 0 and depth < 6 do
        if slugOfMap[id] then return slugOfMap[id] end
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        id = info and info.parentMapID
        depth = depth + 1
    end
    for _, txt in ipairs({ GetRealZoneText and GetRealZoneText() or "", GetZoneText and GetZoneText() or "" }) do
        local z = zoneByName[Norm(txt)]
        if z then return z[1] end
    end
end

----------------------------------------------------------------------
-- Misiones
----------------------------------------------------------------------
local done = {}          -- cache de IsQuestFlaggedCompleted en cada pasada
local function IsDone(id)
    local v = done[id]
    if v == nil then
        v = C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
        done[id] = v
    end
    return v
end

local function IsActive(id)
    return C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) and true or false
end

local function MySide()
    local f = UnitFactionGroup("player")
    if f == "Alliance" then return 1 elseif f == "Horda" or f == "Horde" then return 2 end
    return 0
end

local function QLevel(q) return (q[3] and q[3] > 0) and q[3] or q[4] end

-- devuelve "ok" | "active" | "done" | "locked" | "side" y el motivo si esta bloqueada
local function Status(q, level, side)
    local id = q[1]
    if q[5] ~= 0 and side ~= 0 and q[5] ~= side then return "side" end
    if IsDone(id) then return "done" end
    if IsActive(id) then return "active" end
    if q[4] > level then return "locked", "Necesitas nivel " .. q[4] end
    for _, p in ipairs(q[12]) do
        if not IsDone(p) then return "locked", "Antes: mision " .. p end
    end
    return "ok"
end

local function Title(q)
    local t = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(q[1])
    if t and t ~= "" then return t end
    return q[2]
end

-- color segun diferencia de nivel (como el juego)
local function DiffColor(lv, plvl)
    local d = lv - plvl
    if d >= 5 then return 1, 0.1, 0.1
    elseif d >= 3 then return 1, 0.5, 0.25
    elseif d >= -2 then return 1, 1, 0
    elseif d >= -7 then return 0.25, 0.75, 0.25
    end
    return 0.6, 0.6, 0.6
end


-- cuantas misiones utiles tiene cada zona a tu nivel (para sugerir la siguiente zona): una sola pasada
local function ZoneScores(level, side)
    local sc = {}
    for _, q in ipairs(QUESTS) do
        local lv = q[3]
        if lv > 0 and lv >= level - 2 and lv <= level + 3 and q[4] <= level and Status(q, level, side) == "ok" then
            local e = sc[q[11]]
            if not e then e = { n = 0, xp = 0 }; sc[q[11]] = e end
            e.n = e.n + 1; e.xp = e.xp + q[6]
        end
    end
    return sc
end

local items, summary, banner = {}, {}, {}
local barFrame

local function BuildList()
    wipe(done); wipe(items); wipe(banner)
    summary.n, summary.xp, summary.zone, summary.noZone = 0, 0, nil, false
    local level, side = UnitLevel("player") or 1, MySide()
    local slug
    if S.auto then slug = CurrentSlug() end
    if not slug then slug = S.zone end
    if not slug and ZONES[1] then slug = ZONES[1][1] end
    if S.auto and not CurrentSlug() then summary.noZone = true end
    local z = zoneBySlug[slug]
    if not z then return end
    summary.zone = z
    summary.level = level
    local zi = zoneIndex[slug]

    local groups, order = {}, {}
    for _, q in ipairs(QUESTS) do
        if q[11] == zi then
            local lv = QLevel(q)
            local unknown = not (q[3] and q[3] > 0)
            local visible = true
            if unknown then
                visible = S.showNoLevel
            elseif lv < level - S.below or lv > level + S.above then
                visible = false
            end
            if visible then
                local st, why = Status(q, level, side)
                if st == "ok" or (st == "active" and S.showActive) or (st == "locked" and S.showLocked) then
                    local key = (q[7] ~= "" and q[7] or "?") .. "|" .. q[8] .. "|" .. q[9] .. "|" .. q[10]
                    local g = groups[key]
                    if not g then
                        g = { name = q[7] ~= "" and q[7] or "Dador desconocido", q = q, list = {}, best = 999 }
                        groups[key] = g; order[#order + 1] = g
                    end
                    local dist = unknown and 90 or math.abs(lv - level)
                    if st ~= "ok" then dist = dist + 0.5 end
                    g.list[#g.list + 1] = { q = q, st = st, why = why, dist = dist, lv = lv }
                    if dist < g.best then g.best = dist end
                    if st == "ok" then summary.n = summary.n + 1; summary.xp = summary.xp + q[6] end
                end
            end
        end
    end
    table.sort(order, function(a, b)
        if a.best ~= b.best then return a.best < b.best end
        return a.name < b.name
    end)
    for _, g in ipairs(order) do
        table.sort(g.list, function(a, b)
            if a.dist ~= b.dist then return a.dist < b.dist end
            if a.lv ~= b.lv then return a.lv < b.lv end
            return a.q[2] < b.q[2]
        end)
        local zs = g.q[8] > 0 and ZONES[g.q[8]] or nil
        items[#items + 1] = { kind = "head", g = g, q = g.q, zname = zs and zs[2] or "", n = #g.list }
        for _, e in ipairs(g.list) do
            items[#items + 1] = { kind = "quest", q = e.q, st = e.st, why = e.why, lv = e.lv }
        end
    end

    -- sugerencia de siguiente zona
    local sc = ZoneScores(level, side)
    local n = sc[zi] and sc[zi].n or 0
    if level > z[5] or n < 5 then
        local cands = {}
        for i, other in ipairs(ZONES) do
            local e = sc[i]
            if i ~= zi and e and e.n >= 5 and (other[6] == 0 or side == 0 or other[6] == side) then
                cands[#cands + 1] = { z = other, n = e.n, xp = e.xp }
            end
        end
        table.sort(cands, function(a, b) return a.n > b.n end)
        for i = 1, math.min(3, #cands) do banner[i] = cands[i] end
        summary.why = (level > z[5]) and ("Ya pasas el rango de la zona (" .. z[4] .. "-" .. z[5] .. ")")
            or "Quedan pocas misiones utiles aqui"
    end
end

----------------------------------------------------------------------
-- Marcar en el mapa y copiar
----------------------------------------------------------------------
local function Waypoint(q)
    if q[8] == 0 or q[9] == 0 then Print("esa mision no tiene coordenadas del dador en los datos"); return end
    local z = ZONES[q[8]]
    local id = mapOf[z[1]]
    local x, y = q[9] / 100, q[10] / 100
    local txt = string.format("%s, %s (%.1f, %.1f)", q[7] ~= "" and q[7] or "dador", z[2], q[9], q[10])
    if id and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(id) and UiMapPoint then
        local pt = UiMapPoint.CreateFromCoordinates(id, x, y)
        if C_Map.SetUserWaypoint(pt) then
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
            Print("marca puesta en " .. txt)
            return
        end
    end
    Print("no pude poner la marca en el mapa. Esta en " .. txt)
end

local copyBox
local function CopyName(text)
    if not copyBox then
        copyBox = CreateFrame("Frame", "CervecerosMendigosLeveoCopy", UIParent, "BackdropTemplate")
        copyBox:SetSize(360, 58)
        copyBox:SetPoint("CENTER", 0, 120)
        copyBox:SetFrameStrata("FULLSCREEN_DIALOG")
        copyBox:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                              edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                              edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        local l = copyBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", 14, -10); l:SetText("Ctrl+C para copiar, Esc para cerrar")
        local eb = CreateFrame("EditBox", nil, copyBox, "InputBoxTemplate")
        eb:SetSize(330, 20); eb:SetPoint("TOPLEFT", 16, -26); eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() copyBox:Hide() end)
        eb:SetScript("OnEnterPressed", function() copyBox:Hide() end)
        copyBox.eb = eb
        copyBox:Hide()
    end
    copyBox:Show()
    copyBox.eb:SetText(text)
    copyBox.eb:SetFocus()
    copyBox.eb:HighlightText()
end

----------------------------------------------------------------------
-- Contador de experiencia
----------------------------------------------------------------------
local xpState = { lastXP = nil, lastMax = nil, lastT = nil }

local function IsMaxLevel()
    local lv = UnitLevel("player") or 1
    local mx = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
    return lv >= mx
end

local function OnXP()
    if not On() then return end
    local xp, mx = UnitXP("player"), UnitXPMax("player")
    if xpState.lastXP then
        local delta
        if xp >= xpState.lastXP then delta = xp - xpState.lastXP
        else delta = (xpState.lastMax - xpState.lastXP) + xp end  -- ha subido de nivel
        if delta > 0 then
            local now = GetTime()
            DATA.sess.gained = DATA.sess.gained + delta
            if xpState.lastT then DATA.sess.active = DATA.sess.active + math.min(now - xpState.lastT, S.idleCap or 120) end
            xpState.lastT = now
            DATA.sess.last = time()
        end
    end
    xpState.lastXP, xpState.lastMax = xp, mx
end

local function FmtNum(n)
    if n >= 1000000 then return string.format("%.2fM", n / 1000000)
    elseif n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n + 0.5))
end

local function FmtTime(s)
    if not s or s ~= s or s == math.huge then return "--" end
    s = math.floor(s + 0.5)
    if s >= 3600 then return string.format("%dh %02dmin", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
    if s >= 60 then return string.format("%d min", math.floor(s / 60 + 0.5)) end
    return s .. " s"
end

-- devuelve xp/hora, segundos hasta subir (o nil)
local function XPStats()
    local xp, mx = UnitXP("player"), UnitXPMax("player")
    local active = DATA.sess.active
    local rate
    if active >= (S.minActive or 20) and DATA.sess.gained > 0 then rate = DATA.sess.gained / active * 3600 end
    local eta
    if rate and rate > 0 then eta = (mx - xp) / rate * 3600 end
    return rate, eta, xp, mx
end

local function ResetSession()
    DATA.sess.gained, DATA.sess.active, DATA.sess.last = 0, 0, 0
    xpState.lastT = nil
    xpState.lastXP, xpState.lastMax = UnitXP("player"), UnitXPMax("player")
    if RefreshXP then RefreshXP() end
end


----------------------------------------------------------------------
-- Ayudas de interfaz
----------------------------------------------------------------------
local MakeWindow = UI.MakeWindow

local widgets = {}

local function MakeSlider(parent, label, minv, maxv, step, x, y, width, get, set)
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
    local function Show(v) fs:SetText(label .. ": |cffffffff" .. string.format("%d", v) .. "|r") end
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
-- Ventana principal
----------------------------------------------------------------------
local win, rows, scroll = nil, {}, nil
local ROWS, RH = 13, 24
local LIST_TOP = -138
local offset = 0
local zoneLabel, infoLabel, bannerLabel, bannerBtns = nil, nil, nil, {}
local xpLine1, xpLine2

local function ShowQuestTooltip(row)
    local it = row.item
    if not it then return end
    local q = it.q
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if it.kind == "head" then
        GameTooltip:AddLine(it.g.name, 1, 0.82, 0)
        local zs = q[8] > 0 and ZONES[q[8]]
        if zs and q[9] > 0 then
            GameTooltip:AddLine(string.format("%s  (%.1f, %.1f)", zs[2], q[9], q[10]), 1, 1, 1)
            if not mapOK[zs[1]] then
                GameTooltip:AddLine("Mapa sin comprobar: si la marca sale mal, usa /leveo diag", 1, 0.5, 0.2, true)
            end
        else
            GameTooltip:AddLine("Sin coordenadas en los datos", 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine(it.n .. " mision(es) de este dador", 0.8, 0.8, 0.8)
    else
        local plvl = UnitLevel("player") or 1
        local r, g, b = DiffColor(it.lv, plvl)
        GameTooltip:AddLine(Title(q), r, g, b)
        if Title(q) ~= q[2] then GameTooltip:AddLine(q[2], 0.6, 0.6, 0.6) end
        local lvtxt = (q[3] > 0) and ("Nivel " .. q[3]) or "Nivel desconocido"
        GameTooltip:AddLine(string.format("%s - minimo %d - %s xp", lvtxt, q[4], q[6] > 0 and FmtNum(q[6]) or "?"), 1, 1, 1)
        if q[7] ~= "" then GameTooltip:AddLine("Dador: " .. q[7], 0.8, 0.8, 0.8) end
        if q[13] and q[13] ~= "" then GameTooltip:AddLine(q[13], 1, 1, 1, true) end
        if it.st == "active" then GameTooltip:AddLine("En tu registro de misiones", 0.2, 1, 0.2)
        elseif it.st == "locked" then GameTooltip:AddLine(it.why or "Bloqueada", 1, 0.4, 0.4) end
    end
    GameTooltip:Show()
end

local function UpdateRows()
    for i = 1, ROWS do
        local row, it = rows[i], items[i + offset]
        row.item = it
        if not it then
            row:Hide()
        else
            row:Show()
            if it.kind == "head" then
                row.text:SetText("|cffffd100" .. it.g.name .. "|r |cff9d9d9d" .. (it.zname ~= "" and ("- " .. it.zname) or "") .. "|r")
                row.lvl:SetText(""); row.xp:SetText("")
                row.text:SetPoint("LEFT", 2, 0)
                row.mark:SetShown(it.q[9] > 0)
                row.copy:Hide()
                row.bg:SetColorTexture(0.2, 0.2, 0.25, 0.7)
            else
                local plvl = UnitLevel("player") or 1
                local r, g, b = DiffColor(it.lv, plvl)
                local name = Title(it.q)
                if it.st == "active" then name = name .. " |cff33ff33(en curso)|r"
                elseif it.st == "locked" then name = "|cff888888" .. name .. "|r" end
                row.text:SetText(name)
                row.text:SetPoint("LEFT", 16, 0)
                row.lvl:SetText((it.q[3] > 0 and tostring(it.q[3]) or "?"))
                row.lvl:SetTextColor(r, g, b)
                row.xp:SetText(it.q[6] > 0 and FmtNum(it.q[6]) or "")
                row.mark:SetShown(it.q[9] > 0)
                row.copy:Show()
                row.bg:SetColorTexture(0, 0, 0, (i % 2 == 0) and 0.15 or 0)
            end
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

local function BuildRow(parent, i)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(496, RH)
    row:SetPoint("TOPLEFT", 16, LIST_TOP - (i - 1) * RH)
    row:EnableMouse(true)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetWidth(330); row.text:SetJustifyH("LEFT")
    row.lvl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.lvl:SetPoint("LEFT", 352, 0); row.lvl:SetWidth(26)
    row.xp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.xp:SetPoint("LEFT", 380, 0); row.xp:SetWidth(44); row.xp:SetJustifyH("RIGHT")
    row.mark = MakeButton(row, "Marcar", 48, 20, "LEFT", 430, 0, function()
        if row.item then Waypoint(row.item.q) end
    end)
    row.copy = MakeButton(row, "C", 20, 20, "LEFT", 480, 0, function()
        if row.item then CopyName(row.item.q[2]) end
    end)
    row:SetScript("OnEnter", ShowQuestTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function ChangeZone(delta)
    local cur = summary.zone and zoneIndex[summary.zone[1]] or 1
    local n = cur + delta
    if n < 1 then n = #ZONES elseif n > #ZONES then n = 1 end
    S.auto = false
    S.zone = ZONES[n][1]
    if win and win.autoCheck then win.autoCheck:Refresh() end
    RefreshList()
end

local function UpdateBanner()
    for i = 1, 3 do bannerBtns[i]:Hide() end
    if #banner == 0 then
        bannerLabel:SetText("")
        return
    end
    bannerLabel:SetText("|cffffd100" .. (summary.why or "") .. ". Siguiente zona:|r")
    local x = 0
    for i, c in ipairs(banner) do
        local b = bannerBtns[i]
        b:SetText(string.format("%s (%d)", c.z[2], c.n))
        b:SetWidth(math.max(90, 8 * #b:GetText() * 0.62 + 20))
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", win, "TOPLEFT", 16 + x, -118)
        x = x + b:GetWidth() + 4
        b.slug = c.z[1]
        b:Show()
    end
end

RefreshList = function()
    if not On() or not win then return end
    BuildList()
    local z = summary.zone
    if z then
        zoneLabel:SetText(string.format("%s |cff9d9d9d(%d-%d)|r", z[2], z[4], z[5]))
        local extra = ""
        if S.auto and summary.noZone then extra = " |cffff8040(zona sin datos: elige una con las flechas)|r" end
        infoLabel:SetText(string.format("Nivel %d - %d misiones disponibles, %s xp en total%s",
            summary.level or 0, summary.n, FmtNum(summary.xp), extra))
    else
        zoneLabel:SetText("Sin datos")
        infoLabel:SetText("")
    end
    UpdateBanner()
    SetupScroll()
    if RefreshXP then RefreshXP() end
end

RefreshXP = function()
    if not On() then return end
    local line1, line2
    if IsMaxLevel() then
        line1 = "|cffffd100Nivel maximo|r"
        line2 = ""
    else
        local rate, eta, xp, mx = XPStats()
        local pct = mx > 0 and (xp / mx * 100) or 0
        local rest = GetXPExhaustion and GetXPExhaustion()
        line1 = string.format("|cffffd100Nivel %d|r  %.1f%%  (%s / %s)%s", UnitLevel("player"), pct, FmtNum(xp), FmtNum(mx),
            (rest and S.showRested) and (" |cff4080ffdescansado " .. FmtNum(rest) .. "|r") or "")
        line2 = string.format("Sesion: %s xp en %s  -  |cff33ff99%s xp/h|r  -  sube en |cff33ff99%s|r",
            FmtNum(DATA.sess.gained), FmtTime(DATA.sess.active), rate and FmtNum(rate) or "--", FmtTime(eta))
    end
    if xpLine1 then xpLine1:SetText(line1); xpLine2:SetText(line2) end
    -- barra flotante
    local bar = barFrame
    if bar then
        if S.bar.show then
            bar:Show()
            bar.t1:SetText(line1); bar.t2:SetText(line2)
            if not IsMaxLevel() then
                local _, _, xp, mx = XPStats()
                bar.fill:SetWidth(math.max(1, (bar:GetWidth() - 4) * (mx > 0 and xp / mx or 0)))
            end
        else
            bar:Hide()
        end
    end
end

local function StyleBar()
    local f = barFrame
    if not f then return end
    f:SetSize(S.bar.width or 380, 40)
    f:SetScale((S.bar.scale or 100) / 100)
    f:SetBackdropColor(0, 0, 0, (S.bar.alpha or 60) / 100)
    local bc = S.bar.color or { 0.55, 0.25, 0.85 }
    f.fill:SetColorTexture(bc[1], bc[2], bc[3], 0.55)
    RefreshXP()
end

local function BuildBar()
    local f = CreateFrame("Frame", "CervecerosMendigosLeveoBar", UIParent, "BackdropTemplate")
    f:SetSize(S.bar.width or 380, 40)
    f:SetScale((S.bar.scale or 100) / 100)
    f:SetPoint(S.bar.point or "CENTER", UIParent, S.bar.point or "CENTER", S.bar.x or 0, S.bar.y or -220)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, (S.bar.alpha or 60) / 100); f:SetBackdropBorderColor(0.4, 0.3, 0.1, 1)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not S.bar.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, x, y = self:GetPoint()
        S.bar.point, S.bar.x, S.bar.y = p, x, y
        -- el punto de anclaje guardado debe ser relativo a UIParent y a si mismo
        self:ClearAllPoints()
        self:SetPoint(p, UIParent, p, x, y)
    end)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    local bc = S.bar.color or { 0.55, 0.25, 0.85 }
    f.fill:SetColorTexture(bc[1], bc[2], bc[3], 0.55)
    f.fill:SetPoint("TOPLEFT", 2, -2); f.fill:SetPoint("BOTTOMLEFT", 2, 2); f.fill:SetWidth(1)
    f.t1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.t1:SetPoint("TOP", 0, -5)
    f.t2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.t2:SetPoint("BOTTOM", 0, 5)
    f:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then OpenConfig() end end)
    f:Hide()
    barFrame = f
    mod:Track(f)
end

local function BuildConfig()
    win = MakeWindow("CervecerosMendigosLeveoConfig", "Leveo - Ruta de misiones", 540, 620)
    win:SetScale((S.windowScale or 100) / 100)

    local logo = win:CreateTexture(nil, "ARTWORK")
    logo:SetSize(36, 36); logo:SetPoint("TOPLEFT", 16, -30)
    logo:SetTexture(Icon())

    local prev = MakeButton(win, "<", 24, 24, "TOPLEFT", 60, -30, function() ChangeZone(-1) end)
    local nxt = MakeButton(win, ">", 24, 24, "TOPLEFT", 400, -30, function() ChangeZone(1) end)
    zoneLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    zoneLabel:SetPoint("TOPLEFT", 90, -34); zoneLabel:SetWidth(306); zoneLabel:SetJustifyH("CENTER")
    win.autoCheck = MakeCheck(win, "Seguir mi zona", 428, -30,
        function() return S.auto end,
        function(v) S.auto = v; RefreshList() end)

    infoLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoLabel:SetPoint("TOPLEFT", 16, -76); infoLabel:SetWidth(500); infoLabel:SetJustifyH("LEFT")

    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -94); hint:SetWidth(500); hint:SetJustifyH("LEFT")
    hint:SetText("Ordenadas por cercania a tu nivel. Marcar = marca en el mapa en el dador. C = copiar nombre.")

    bannerLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bannerLabel:SetPoint("TOPLEFT", 16, -108); bannerLabel:SetWidth(500); bannerLabel:SetJustifyH("LEFT")
    for i = 1, 3 do
        local b = MakeButton(win, "", 120, 18, "TOPLEFT", 16, -118, function(self)
            if self.slug then
                S.auto = false; S.zone = self.slug
                win.autoCheck:Refresh(); RefreshList()
            end
        end)
        b:Hide()
        bannerBtns[i] = b
    end

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
    win:SetScript("OnMouseWheel", function(_, delta)
        if scroll:IsShown() then scroll:SetValue(scroll:GetValue() - delta * 3) end
    end)

    local y0 = LIST_TOP - ROWS * RH - 10   -- bajo la lista
    MakeSlider(win, "Ocultar mas de N niveles por debajo", 0, 20, 1, 16, y0, 230,
        function() return S.below end, function(v) S.below = v; RefreshList() end)
    MakeSlider(win, "Ocultar mas de N niveles por encima", 0, 20, 1, 270, y0, 230,
        function() return S.above end, function(v) S.above = v; RefreshList() end)
    local y1 = y0 - 40
    MakeCheck(win, "Mostrar en curso", 12, y1,
        function() return S.showActive end, function(v) S.showActive = v; RefreshList() end)
    MakeCheck(win, "Mostrar bloqueadas", 150, y1,
        function() return S.showLocked end, function(v) S.showLocked = v; RefreshList() end)
    MakeCheck(win, "Nivel desconocido", 300, y1,
        function() return S.showNoLevel end, function(v) S.showNoLevel = v; RefreshList() end)

    local y2 = y1 - 34
    local sep = win:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.5, 0.4, 0.1, 0.6)
    sep:SetPoint("TOPLEFT", 16, y2 + 6); sep:SetSize(500, 1)
    xpLine1 = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    xpLine1:SetPoint("TOPLEFT", 16, y2 - 4); xpLine1:SetWidth(500); xpLine1:SetJustifyH("LEFT")
    xpLine2 = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    xpLine2:SetPoint("TOPLEFT", 16, y2 - 24); xpLine2:SetWidth(500); xpLine2:SetJustifyH("LEFT")

    MakeButton(win, "Barra de XP", 110, 24, "BOTTOMLEFT", 16, 14, function()
        S.bar.show = not S.bar.show; RefreshXP()
    end)
    MakeButton(win, "Reiniciar sesion", 120, 24, "BOTTOMLEFT", 134, 14, function()
        ResetSession(); Print("sesion de experiencia reiniciada")
    end)
    local note = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMRIGHT", -16, 20)
    note:SetText("Ajustes: pestana Leveo")

    win:SetScript("OnShow", function() win:SetScale((S.windowScale or 100) / 100); RefreshList(); for _, w in ipairs(widgets) do w:Refresh() end end)
    win:SetScript("OnHide", function() GameTooltip:Hide() end)
end

OpenConfig = function()
    if not On() then return end
    if not win then BuildConfig() end
    if win:IsShown() then win:Hide() else win:Show() end
end

----------------------------------------------------------------------
-- Diagnostico
----------------------------------------------------------------------
local function Diag()
    ResolveMaps()
    local ok, bad = 0, 0
    for _, z in ipairs(ZONES) do
        if mapOK[z[1]] then ok = ok + 1 else bad = bad + 1 end
    end
    Print(string.format("%d misiones, %d zonas. Mapas comprobados con el cliente: %d, sin comprobar: %d", #QUESTS, #ZONES, ok, bad))
    for _, z in ipairs(ZONES) do
        if not mapOK[z[1]] then
            local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapOf[z[1]])
            Print(string.format("  sin comprobar: %s -> mapa %d (el cliente dice: %s)", z[3], mapOf[z[1]], info and info.name or "nada"))
        end
    end
    local id = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local info = id and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    Print(string.format("Tu mapa: %s (%s). Zona detectada: %s", tostring(id), info and info.name or "?", tostring(CurrentSlug())))
    Print(string.format("Nivel %d, bando %d (1 alianza, 2 horda)", UnitLevel("player") or 0, MySide()))
end


----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local dirty, acc, accXP = false, 0, 0
local function OnEvent(event)
    if not On() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        ResolveMaps()
        xpState.lastXP, xpState.lastMax = UnitXP("player"), UnitXPMax("player")
        dirty = true
    elseif event == "PLAYER_XP_UPDATE" then
        OnXP(); dirty = true
    else
        dirty = true  -- zona, nivel o misiones cambiadas
    end
end

local function OnUpdate(_, elapsed)
    acc = acc + elapsed
    accXP = accXP + elapsed
    if dirty and acc >= 0.5 then
        dirty = false; acc = 0
        if win and win:IsShown() then RefreshList() else RefreshXP() end
    end
    if accXP >= 1 then
        accXP = 0
        if (win and win:IsShown()) or S.bar.show then RefreshXP() end
    end
end

local function OnSlash(_, msg)
    local cmd, arg = string.match(strlower(msg or ""), "^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "config" then
        OpenConfig()
    elseif cmd == "barra" or cmd == "xp" then
        S.bar.show = not S.bar.show; RefreshXP()
        Print("barra de experiencia: " .. (S.bar.show and "visible" or "oculta"))
    elseif cmd == "reset" then
        ResetSession(); Print("sesion de experiencia reiniciada")
    elseif cmd == "minimap" then
        Print("el boton del minimapa se controla en la pestana Leveo (Boton en el minimapa).")
    elseif cmd == "zona" then
        local z = zoneByName[Norm(arg)] or zoneBySlug[arg]
        if arg == "" or arg == "auto" then
            S.auto = true; Print("siguiendo tu zona")
        elseif z then
            S.auto = false; S.zone = z[1]; Print("zona fijada: " .. z[2])
        else
            Print("no conozco esa zona. Ejemplos: /leveo zona Elwynn Forest | /leveo zona auto")
        end
        if win and win:IsShown() then RefreshList() end
    elseif cmd == "diag" then
        Diag()
    else
        Print("/leveo = ventana | barra | reset | zona <nombre|auto> | diag (ajustes en la pestana Leveo)")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local function BuildTab(m, L)
    L:Header("Ruta de misiones")
    L:Text("Misiones de tu zona y nivel que aun no has hecho, con marca en el mapa en el dador.", true)
    L:Button("Abrir la ruta de misiones", 220, function() OpenConfig() end)
    L:Check("Seguir automaticamente la zona en la que estoy", function() return S.auto end,
        function(v) S.auto = v; if win and win.autoCheck then win.autoCheck:Refresh() end; RefreshList() end)
    L:Slider("Ocultar misiones mas de N niveles por debajo", 0, 30, 1, function() return S.below end,
        function(v) S.below = v; RefreshList() end)
    L:Slider("Ocultar misiones mas de N niveles por encima", 0, 30, 1, function() return S.above end,
        function(v) S.above = v; RefreshList() end)
    L:Check("Mostrar las ya aceptadas (en curso)", function() return S.showActive end,
        function(v) S.showActive = v; RefreshList() end)
    L:Check("Mostrar las bloqueadas (requisitos sin cumplir)", function() return S.showLocked end,
        function(v) S.showLocked = v; RefreshList() end)
    L:Check("Mostrar las de nivel desconocido", function() return S.showNoLevel end,
        function(v) S.showNoLevel = v; RefreshList() end)
    L:Slider("Tamano de la ventana de la ruta", 60, 130, 5, function() return S.windowScale end,
        function(v) S.windowScale = v; if win then win:SetScale(v / 100) end end, "%d%%")
    L:Header("Experiencia por hora")
    L:Check("Mostrar la barra de experiencia en pantalla", function() return S.bar.show end,
        function(v) S.bar.show = v; RefreshXP() end)
    L:Check("Bloquear la posicion de la barra", function() return S.bar.locked end, function(v) S.bar.locked = v end)
    L:Slider("Ancho de la barra", 200, 700, 10, function() return S.bar.width end,
        function(v) S.bar.width = v; StyleBar() end)
    L:Slider("Tamano de la barra", 50, 200, 5, function() return S.bar.scale end,
        function(v) S.bar.scale = v; StyleBar() end, "%d%%")
    L:Slider("Opacidad del fondo de la barra", 0, 100, 5, function() return S.bar.alpha end,
        function(v) S.bar.alpha = v; StyleBar() end, "%d%%")
    L:Color("Color de la barra",
        function() local c = S.bar.color; return c[1], c[2], c[3] end,
        function(r, g, b) S.bar.color = { r, g, b }; StyleBar() end)
    L:Check("Mostrar la xp descansada", function() return S.showRested end,
        function(v) S.showRested = v; RefreshXP() end)
    L:Slider("Una sesion sin xp se da por terminada tras (min)", 5, 240, 5, function() return S.sessionMinutes end,
        function(v) S.sessionMinutes = v end)
    L:Slider("Segundos activos minimos para calcular xp/hora", 5, 120, 5, function() return S.minActive end,
        function(v) S.minActive = v end)
    L:Slider("Segundos maximos que cuentan entre dos ganancias", 30, 600, 10, function() return S.idleCap end,
        function(v) S.idleCap = v end)
    L:Button("Reiniciar la sesion de experiencia", 260, function() ResetSession(); Print("sesion de experiencia reiniciada") end)
end

local EVENTS = { "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_XP_UPDATE",
                 "PLAYER_LEVEL_UP", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED" }

mod = Hub:Register{
    key = "leveo", dir = "Leveo", name = "Leveo",
    desc = "Ruta de misiones de tu zona y nivel con marca en el mapa, y contador de experiencia por hora.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosLeveoDB",
    slash = { "leveo", "cmleveo" },
    OnSlash = OnSlash,
    BuildConfig = BuildTab,
    rightHint = "mostrar/ocultar la barra de experiencia",
    OnRightClick = function() S.bar.show = not S.bar.show; RefreshXP() end,
    OnReset = function() if barFrame then StyleBar() end; RefreshList() end,
    Init = function(m)
        S = m.db
        ns.DB.data = ns.DB.data or {}
        local D = ns.DB.data.leveo
        if not D then D = {}; ns.DB.data.leveo = D end
        -- datos del addon suelto antiguo (llegan a mod.db por la migracion)
        for _, k in ipairs({ "sess", "maps" }) do
            if S[k] ~= nil and D[k] == nil then D[k] = S[k] end
            S[k] = nil
        end
        S.minimap = nil
        D.sess = D.sess or { gained = 0, active = 0, last = 0 }
        D.maps = D.maps or {}
        DATA = D
        DB = S
        -- una sesion larga sin ganar xp se da por terminada
        if DATA.sess.last > 0 and time() - DATA.sess.last > (S.sessionMinutes or 30) * 60 then
            DATA.sess.gained, DATA.sess.active, DATA.sess.last = 0, 0, 0
        end
        BuildZoneIndex()
        BuildBar()
        for _, name in ipairs(EVENTS) do
            if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(name) then
                m:Event(name, function(_, event) OnEvent(event) end)
            end
        end
        m:OnUpdate(OnUpdate)
    end,
    Enable = function(m)
        S = m.db
        ResolveMaps()
        xpState.lastXP, xpState.lastMax, xpState.lastT = UnitXP("player"), UnitXPMax("player"), nil
        dirty = true
        RefreshXP()
    end,
    Disable = function(m)
        if win then win:Hide() end
        if barFrame then barFrame:Hide() end
        if copyBox then copyBox:Hide() end
    end,
}
