-- Modulo "Enemigos cercanos" (PvPOutdoor) para WoW Forever (cliente moderno, Interface 16001)
-- 1) Alerta de enemigos cercanos  2) Habilidades clave del enemigo
-- 3) Alerta de casteos peligrosos 4) Registro de muertes + marcas en el mapa
--
-- El cliente de Forever restringe el registro de combate y muchos datos de unidades
-- ("valores secretos"), asi que NO se usa COMBAT_LOG_EVENT_UNFILTERED: los enemigos se
-- detectan por placas de nombre (nameplates), objetivo, foco y mouseover.
-- Activa las placas de enemigos (Mayus+V) para ver a todos los cercanos.

local ADDON, ns = ...
local Hub = ns.Hub
local issecret = issecretvalue or function() return false end

local mod            -- se asigna en Register
local DB             -- = mod.db
local unlocked = false

local DEFAULTS = {
    outdoorOnly = true,   -- no actuar en instancias / BG / arenas
    sound = true,         -- interruptor general de sonidos
    enemyTTL = 25,        -- seg. sin ver a un enemigo antes de quitarlo de la lista
    dangerLevelDiff = 10, -- alerta si el enemigo es >= nivel propio + esto (o ??)
    groupSize = 3,        -- alerta de grupo a partir de N enemigos
    longCast = 2.5,       -- casteos >= esto (seg) se muestran aunque no sean peligrosos
    show = { enemies = true, cds = true, casts = true, map = true },
    alerts = { group = true, danger = true, new = true, cast = true },  -- sonido de cada aviso
    alertText = true,     -- mensaje grande en pantalla
    alertSeconds = 3,     -- duracion del mensaje grande
    groupCooldown = 15,   -- seg. minimos entre avisos de grupo
    listMax = 8,          -- filas de la lista de enemigos (1-8)
    cdMax = 10,           -- iconos de habilidades a la vez (3-10)
    cdLow = 20, cdHigh = 80,  -- % de tiempo restante: verde por debajo / rojo por encima
    castWidth = 260,      -- ancho de las barras de casteo
    bgAlpha = 45,         -- opacidad (%) del fondo de la lista al mover/mostrar
    scale = { list = 100, cds = 100, casts = 100, alert = 100 },  -- escala (%) de cada marco
    deathMax = 50,        -- muertes guardadas
    pos = {},
    deaths = {},
}

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
local function Print(msg) if mod then mod:Print(msg) end end

local function Clean(v)
    if issecret(v) then return nil end
    return v
end

local function Active()
    if not DB or not mod or not mod.enabled then return false end
    if DB.outdoorOnly then
        local ok, inInstance = pcall(IsInInstance)
        if ok and inInstance then return false end
    end
    return true
end

local function IsEnemyPlayer(unit)
    local ok, res = pcall(function()
        if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsEnemy("player", unit) then
            return true
        end
        return false
    end)
    return ok and res
end

local function TargetsMe(unit)
    local ok, res = pcall(function()
        if UnitIsUnit(unit .. "target", "player") then return true end
        return false
    end)
    return ok and res
end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

local function FormatTime(t)
    if t >= 60 then return math.floor(t / 60) .. ":" .. string.format("%02d", math.floor(t % 60))
    elseif t >= 10 then return tostring(math.floor(t + 0.5))
    else return string.format("%.1f", t) end
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return nil
end

local function SpellInfo(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info then return info.name, info.iconID end
    end
    return nil
end

-- kit = nombre en SOUNDKIT; flag = clave de DB.alerts que lo controla
local function Sound(kit, flag)
    if not DB or not DB.sound then return end
    if flag and DB.alerts[flag] == false then return end
    if SOUNDKIT and SOUNDKIT[kit] then PlaySound(SOUNDKIT[kit]) end
end

----------------------------------------------------------------------
-- Marcos
----------------------------------------------------------------------
local MAX_ROWS, MAX_ICONS = 8, 10
local listFrame, cdFrame, alertFrame
local castBars = {}
local movables = {}
local enemies, cds = {}, {}
local lastGroupAlert, lastNewSound = 0, 0
local lastTargeter
local pins = {}
local keyCD, keyIcon, dangerSpells = {}, {}, {}

local function Alert(text, r, g, b)
    if not DB or not DB.alertText or not alertFrame then return end
    alertFrame.text:SetText(text)
    alertFrame.text:SetTextColor(r or 1, g or 0.2, b or 0.2)
    alertFrame.t = 0
    alertFrame:SetAlpha(1)
    alertFrame:Show()
end

local function MakeMovable(f, key, point, x, y)
    f.key, f.defPoint, f.defX, f.defY = key, point, x, y
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if unlocked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, px, py = self:GetPoint()
        DB.pos[self.key] = { p, rp, px, py }
    end)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(f)
    f.bg:SetColorTexture(0, 0, 0, 0.45)
    f.bg:Hide()
    movables[#movables + 1] = f
end

local function ApplyPos(f)
    f:ClearAllPoints()
    local p = DB.pos[f.key]
    if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else f:SetPoint(f.defPoint, UIParent, f.defPoint, f.defX, f.defY) end
end

local function ApplyLayout()
    if not DB or not listFrame then return end
    local s = DB.scale
    listFrame:SetScale((s.list or 100) / 100)
    cdFrame:SetScale((s.cds or 100) / 100)
    alertFrame:SetScale((s.alert or 100) / 100)
    local a = (DB.bgAlpha or 45) / 100
    for _, f in ipairs(movables) do
        f.bg:SetColorTexture(0, 0, 0, a)
    end
    for _, bar in ipairs(castBars) do
        bar:SetScale((s.casts or 100) / 100)
        bar:SetWidth(DB.castWidth or 260)
    end
    cdFrame:SetWidth(math.max(1, DB.cdMax) * 38)
end

----------------------------------------------------------------------
-- 1) ENEMIGOS CERCANOS
----------------------------------------------------------------------
local function CountEnemies()
    local n = 0
    for _ in pairs(enemies) do n = n + 1 end
    return n
end

local function IsDangerLevel(level)
    if not level then return false end
    if level == -1 then return true end
    local mine = Clean(UnitLevel("player"))
    return mine and level >= mine + DB.dangerLevelDiff or false
end

local function CheckGroupAlert()
    local n = CountEnemies()
    local now = GetTime()
    if n >= DB.groupSize and now - lastGroupAlert > DB.groupCooldown then
        lastGroupAlert = now
        Alert("¡GRUPO ENEMIGO CERCA (" .. n .. ")!", 1, 0.5, 0)
        Sound("RAID_WARNING", "group")
    end
end

local function ScanUnit(unit)
    if not DB or not DB.show.enemies or not Active() then return end
    if not IsEnemyPlayer(unit) then return end
    local now = GetTime()
    local guid = Clean(UnitGUID(unit))
    local key = guid or unit
    local name = Clean(UnitName(unit)) or "Jugador"
    local e = enemies[key]
    local isNew = false
    if not e then
        isNew = true
        e = { name = name, first = now }
        enemies[key] = e
    end
    e.seen = now
    e.name = name
    local loc, eng = UnitClass(unit)
    loc, eng = Clean(loc), Clean(eng)
    if eng then e.loc, e.class = loc, eng end
    local lvl = Clean(UnitLevel(unit))
    if lvl then e.level = lvl end
    if TargetsMe(unit) then lastTargeter = { e = e, t = now } end

    if isNew then
        if now - lastNewSound > 3 then
            lastNewSound = now
            Sound("IG_PVP_UPDATE", "new")
        end
        CheckGroupAlert()
    end
    if e.level and not e.warned and IsDangerLevel(e.level) then
        e.warned = true
        local lv = (e.level == -1) and "??" or e.level
        Alert("¡PELIGRO! " .. e.name .. " (" .. (e.loc or "?") .. " " .. lv .. ")", 1, 0, 0)
        Sound("RAID_WARNING", "danger")
    end
end

local function ScanAll()
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) then ScanUnit(u) end
    end
    ScanUnit("target")
    ScanUnit("focus")
    ScanUnit("mouseover")
end

local function UpdateEnemyList()
    local now = GetTime()
    for key, e in pairs(enemies) do
        if now - e.seen > DB.enemyTTL then enemies[key] = nil end
    end
    if not DB.show.enemies or not Active() then listFrame:Hide(); return end

    local arr = {}
    for _, e in pairs(enemies) do arr[#arr + 1] = e end
    table.sort(arr, function(a, b) return a.first < b.first end)

    if #arr == 0 and not unlocked then listFrame:Hide(); return end
    listFrame:Show()
    local n = #arr
    if unlocked and n == 0 then
        listFrame.title:SetText("Enemigos cerca (arrastra)")
    else
        local col = (n >= DB.groupSize) and "|cffff3030" or "|cffffd100"
        listFrame.title:SetText(col .. "Enemigos cerca: " .. n .. "|r")
    end
    local maxRows = math.max(1, math.min(MAX_ROWS, DB.listMax))
    for i = 1, MAX_ROWS do
        local e, fs = arr[i], listFrame.rows[i]
        if e and i <= maxRows then
            local lv = e.level and (e.level == -1 and "|cffff0000??|r" or tostring(e.level)) or "?"
            local mark = IsDangerLevel(e.level) and "|cffff0000! |r" or ""
            fs:SetText(mark .. ClassColor(e.class) .. e.name .. "|r  " .. (e.loc or "") .. " " .. lv)
        else
            fs:SetText("")
        end
    end
    local shown = math.min(n, maxRows)
    listFrame:SetHeight(20 + 14 * shown)
    listFrame.bg:Show()
end

----------------------------------------------------------------------
-- 2) HABILIDADES CLAVE DEL ENEMIGO (UNIT_SPELLCAST_SUCCEEDED)
----------------------------------------------------------------------
-- {idDeHechizo, cooldown en segundos}. Se compara por NOMBRE, asi vale para cualquier rango.
local KEY_SPELLS = {
    -- Picaro
    { 408, 20 }, { 2094, 180 }, { 1766, 10 }, { 1856, 180 }, { 1776, 10 },
    { 2983, 180 }, { 5277, 180 }, { 14177, 180 }, { 36554, 30 }, { 31224, 90 }, { 14185, 480 },
    -- Mago
    { 2139, 24 }, { 45438, 300 }, { 1953, 15 }, { 122, 25 }, { 11958, 384 }, { 12472, 180 },
    -- Paladin
    { 853, 60 }, { 642, 300 }, { 1022, 300 }, { 633, 3600 }, { 1044, 25 }, { 10278, 300 },
    -- Guerrero
    { 5246, 180 }, { 100, 15 }, { 20252, 30 }, { 6552, 10 }, { 72, 12 }, { 1719, 300 },
    { 12292, 180 }, { 871, 300 }, { 676, 60 },
    -- Druida
    { 5211, 60 }, { 16979, 15 }, { 22812, 60 }, { 29166, 180 }, { 18562, 15 },
    -- Brujo
    { 6789, 120 }, { 5484, 40 }, { 19647, 24 }, { 17928, 40 }, { 18288, 180 },
    -- Sacerdote
    { 8122, 30 }, { 6346, 180 }, { 15487, 45 }, { 10060, 120 }, { 33206, 180 },
    -- Cazador
    { 5384, 30 }, { 19503, 30 }, { 1499, 30 }, { 19577, 60 }, { 19263, 300 }, { 23989, 300 },
    -- Chaman
    { 8042, 6 }, { 8177, 15 }, { 16188, 180 }, { 2484, 15 }, { 57994, 6 }, { 51514, 45 },
    -- Razas
    { 20572, 120 }, { 20549, 120 }, { 7744, 120 }, { 20589, 60 }, { 20594, 180 },
    { 20580, 120 }, { 28730, 120 }, { 20600, 180 }, { 20577, 120 }, { 59752, 120 },
}
local function BuildKeySpells()
    for _, s in ipairs(KEY_SPELLS) do
        local name, icon = SpellInfo(s[1])
        if name and not keyCD[name] then keyCD[name] = s[2]; keyIcon[name] = icon end
    end
end

local function AddCD(src, spell)
    local total = keyCD[spell]
    cds[src .. "|" .. spell] = { src = src, spell = spell, icon = keyIcon[spell],
                                 expire = GetTime() + total, total = total }
end

local function UpdateCDs()
    local now = GetTime()
    local arr = {}
    for k, c in pairs(cds) do
        if c.expire <= now then cds[k] = nil else arr[#arr + 1] = c end
    end
    table.sort(arr, function(a, b) return a.expire < b.expire end)
    if not DB.show.cds or not Active() or (#arr == 0 and not unlocked) then
        cdFrame:Hide(); return
    end
    cdFrame:Show()
    local maxIcons = math.max(1, math.min(MAX_ICONS, DB.cdMax))
    local lo, hi = DB.cdLow / 100, DB.cdHigh / 100
    for i = 1, MAX_ICONS do
        local b, c = cdFrame.icons[i], arr[i]
        if c and i <= maxIcons then
            local rem = c.expire - now
            b.tex:SetTexture(c.icon)
            b.time:SetText(FormatTime(rem))
            local pct = rem / c.total
            if pct < lo then b.time:SetTextColor(0.1, 1, 0.1)
            elseif pct <= hi then b.time:SetTextColor(1, 0.6, 0)
            else b.time:SetTextColor(1, 0.1, 0.1) end
            b.name:SetText(string.sub(c.src or "", 1, 8))
            b:Show()
        else
            b:Hide()
        end
    end
end

local function OnSpellSucceeded(unit, _, spellID)
    if not DB or not DB.show.cds or not Active() then return end
    if issecret(unit) or type(unit) ~= "string" then return end
    if not (unit == "target" or unit == "focus" or unit == "mouseover"
            or string.find(unit, "^nameplate")) then return end
    if issecret(spellID) or not spellID then return end
    if not IsEnemyPlayer(unit) then return end
    local name = Clean(SpellName(spellID))
    if not name or not keyCD[name] then return end
    AddCD(Clean(UnitName(unit)) or "Enemigo", name)
end

----------------------------------------------------------------------
-- 3) ALERTA DE CASTEOS
----------------------------------------------------------------------
local function BuildDangerSpells()
    local ids = {
        118, 12824, 12825, 12826, 28272, 28271, 61305, 61721, 61780,   -- polimorfia
        5782, 6213, 6215, 5484, 6358, 710, 2637, 18657, 18658,         -- miedo, aullido, seduccion, destierro, hibernar
        51514, 605, 20066, 33786, 9484, 9485, 10955,                   -- hex, control mental, arrepentimiento, ciclon, grilletes
        11366, 8129, 10797,                                            -- piroexplosion, mana burn, estrella
    }
    for _, id in ipairs(ids) do
        local n = SpellName(id)
        if n then dangerSpells[n] = true end
    end
end

local function CreateCastBar(unit, key, y)
    local f = mod:Frame("StatusBar", "CMPvPOutdoorCast_" .. unit, UIParent)
    f:SetSize(DB.castWidth or 260, 24)
    f:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    f:SetMinMaxValues(0, 1)
    f.unit = unit
    MakeMovable(f, key, "CENTER", 0, y)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(24, 24)
    f.icon:SetPoint("RIGHT", f, "LEFT", -2, 0)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("CENTER", 0, 0)
    f.bg2 = f:CreateTexture(nil, "BACKGROUND")
    f.bg2:SetAllPoints(f); f.bg2:SetColorTexture(0, 0, 0, 0.6)
    f:Hide()
    return f
end

-- Casteo con datos secretos (en combate restringido): sin nombre ni tiempos legibles,
-- pero la barra se anima con el objeto de duracion del propio juego.
local function SecretCast(bar)
    local unit = bar.unit
    local dur
    if UnitCastingDuration then dur = UnitCastingDuration(unit) end
    if not dur and UnitChannelDuration then dur = UnitChannelDuration(unit) end
    if not dur or not bar.SetTimerDuration then bar:Hide(); return end
    bar:SetTimerDuration(dur)
    bar:SetStatusBarColor(1, 0.6, 0)
    bar.text:SetText("¡Casteo enemigo!")
    bar.icon:SetTexture(nil)
    bar:Show()
end

local function DoCheckCast(bar)
    local unit = bar.unit
    if not DB.show.casts or not Active() then bar:Hide(); return end
    if unlocked then
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0.6); bar:SetStatusBarColor(1, 0.5, 0)
        bar.text:SetText("Casteo " .. unit .. " (arrastra)")
        bar.icon:SetTexture(nil); bar:Show(); return
    end
    if not IsEnemyPlayer(unit) then bar:Hide(); return end

    -- UnitCastingInfo: nombre, texto, icono, inicio, fin, _, castID, noInterrumpible, spellID
    local name, _, tex, st, et, _, _, ni = UnitCastingInfo(unit)
    local channel = false
    if issecret(name) then SecretCast(bar); return end
    if not name then
        -- UnitChannelInfo: nombre, texto, icono, inicio, fin, _, noInterrumpible, spellID
        name, _, tex, st, et, _, ni = UnitChannelInfo(unit)
        channel = true
        if issecret(name) then SecretCast(bar); return end
    end
    if not name then bar.curStart = nil; bar:Hide(); return end
    if issecret(st) or issecret(et) or issecret(ni) or issecret(tex) then SecretCast(bar); return end

    local total = (et - st) / 1000
    local rem = et / 1000 - GetTime()
    if rem < 0 then rem = 0 end
    local dangerous = dangerSpells[name]
    if not dangerous and total < DB.longCast then bar:Hide(); return end

    bar:SetMinMaxValues(0, total)
    bar:SetValue(channel and rem or (total - rem))
    bar.icon:SetTexture(tex)
    if ni then
        bar:SetStatusBarColor(0.5, 0.5, 0.6)
        bar.text:SetText(name .. "  (no interrumpible)  " .. string.format("%.1f", rem))
    elseif dangerous then
        bar:SetStatusBarColor(1, 0.1, 0.1)
        bar.text:SetText("¡INTERRUMPE! " .. name .. "  " .. string.format("%.1f", rem))
    else
        bar:SetStatusBarColor(1, 0.6, 0)
        bar.text:SetText(name .. "  " .. string.format("%.1f", rem))
    end
    if bar.curStart ~= st then
        bar.curStart = st
        if dangerous and not ni then Sound("ALARM_CLOCK_WARNING_3", "cast") end
    end
    bar:Show()
end

local function CheckCast(bar)
    local ok = pcall(DoCheckCast, bar)
    if not ok then bar:Hide() end
end

local function RefreshCasts()
    for _, bar in ipairs(castBars) do CheckCast(bar) end
end

----------------------------------------------------------------------
-- 4) REGISTRO DE MUERTES + MARCAS EN EL MAPA
----------------------------------------------------------------------
local function UpdatePins()
    for _, p in ipairs(pins) do p:Hide() end
    if not DB or not mod.enabled or not DB.show.map or not WorldMapFrame or not WorldMapFrame:IsVisible() then return end
    local mapID = WorldMapFrame:GetMapID()
    local canvas = WorldMapFrame:GetCanvas()
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local n = 0
    for _, d in ipairs(DB.deaths) do
        if d.mapID == mapID and d.x and d.x > 0 then
            n = n + 1
            local p = pins[n]
            if not p then
                p = CreateFrame("Frame", nil, canvas)
                p:SetSize(16, 16)
                p:SetFrameStrata("HIGH")
                p.tex = p:CreateTexture(nil, "OVERLAY")
                p.tex:SetAllPoints(p)
                p.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
                p:EnableMouse(true)
                p:SetScript("OnEnter", function(self)
                    local dd = self.death
                    if not dd then return end
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine("Muerte: " .. dd.when, 1, 0.2, 0.2)
                    GameTooltip:AddLine("Killer: " .. dd.killer ..
                        (dd.class and (" (" .. dd.class .. (dd.level and (" " .. (dd.level == -1 and "??" or dd.level)) or "") .. ")") or ""), 1, 1, 1)
                    if dd.sub and dd.sub ~= "" then GameTooltip:AddLine(dd.sub, 0.6, 0.6, 1) end
                    GameTooltip:Show()
                end)
                p:SetScript("OnLeave", function() GameTooltip:Hide() end)
                pins[n] = p
            end
            p.death = d
            p:ClearAllPoints()
            p:SetPoint("CENTER", canvas, "TOPLEFT", d.x * w, -d.y * h)
            p:Show()
        end
    end
end

local function RecordDeath()
    if not Active() then return end
    local now = GetTime()
    local killer
    if lastTargeter and now - lastTargeter.t < 20 then killer = lastTargeter.e end

    local mapID = C_Map.GetBestMapForUnit("player")
    local x, y
    if mapID then
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then x, y = pos:GetXY() end
    end
    local d = {
        killer = killer and killer.name or "?",
        class = killer and killer.loc or nil,
        level = killer and killer.level or nil,
        zone = GetRealZoneText(), sub = GetSubZoneText(),
        mapID = mapID, x = x, y = y, when = date("%d/%m %H:%M"),
    }
    table.insert(DB.deaths, 1, d)
    while #DB.deaths > math.max(1, DB.deathMax) do table.remove(DB.deaths) end
    Print("Muerte registrada: " .. d.killer .. " en " .. (d.zone or "?") ..
          ((x and x > 0) and string.format(" %.0f,%.0f", x * 100, y * 100) or ""))
    lastTargeter = nil
end

----------------------------------------------------------------------
-- Mover marcos / prueba
----------------------------------------------------------------------
local function SetUnlocked(v, silent)
    unlocked = v
    for _, f in ipairs(movables) do
        f:EnableMouse(v)
        if v then f.bg:Show() else f.bg:Hide() end
    end
    if alertFrame then
        if v then
            alertFrame.text:SetText("Aqui saldran los avisos (arrastra)")
            alertFrame.text:SetTextColor(1, 0.5, 0)
            alertFrame:SetAlpha(1); alertFrame:Show()
        else
            alertFrame:Hide()
        end
    end
    if DB and listFrame then UpdateEnemyList(); UpdateCDs(); RefreshCasts() end
    if not silent then
        Print(v and "marcos desbloqueados: arrastralos con el raton. /pvpo lock para fijar." or "marcos fijados.")
    end
end

local function DoTest()
    local now = GetTime()
    local fake = {
        { "Asesino", "ROGUE", "Pícaro", 60 }, { "Magox", "MAGE", "Mago", -1 },
        { "Pala", "PALADIN", "Paladín", 58 }, { "Cazador", "HUNTER", "Cazador", 60 },
    }
    for i, f in ipairs(fake) do
        enemies["test" .. i] = { name = f[1], class = f[2], loc = f[3], level = f[4], seen = now, first = now + i, warned = true }
    end
    for i, id in ipairs({ 408, 2139, 853, 2094 }) do
        local name, icon = SpellInfo(id)
        if name then
            cds["test" .. i] = { src = fake[i][1], spell = name, icon = icon,
                                 expire = now + 5 + i * 8, total = 40 }
        end
    end
    Alert("¡PRUEBA DE ALERTA!", 1, 0.5, 0)
    Print("datos de prueba creados.")
end

----------------------------------------------------------------------
-- Creacion de marcos (una vez, al activar por primera vez)
----------------------------------------------------------------------
local function BuildFrames()
    alertFrame = mod:Frame("Frame", nil, UIParent)
    alertFrame:SetSize(600, 40)
    alertFrame:SetFrameStrata("HIGH")
    alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    alertFrame.text:SetPoint("CENTER")
    MakeMovable(alertFrame, "alert", "TOP", 0, -170)
    alertFrame.bg:SetAllPoints(alertFrame)
    alertFrame:Hide()
    alertFrame:SetScript("OnUpdate", function(self, elapsed)
        if unlocked then return end
        self.t = (self.t or 0) + elapsed
        local dur = DB.alertSeconds or 3
        if self.t > dur then self:Hide(); return end
        if self.t > dur - 1 then self:SetAlpha(dur - self.t) end
    end)

    listFrame = mod:Frame("Frame", "CMPvPOutdoorEnemyList", UIParent)
    listFrame:SetSize(210, 20)
    MakeMovable(listFrame, "enemies", "TOPLEFT", 20, -200)
    listFrame.title = listFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listFrame.title:SetPoint("TOPLEFT", 4, -3)
    listFrame.rows = {}
    for i = 1, MAX_ROWS do
        local fs = listFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 4, -3 - 14 * i)
        fs:SetJustifyH("LEFT")
        listFrame.rows[i] = fs
    end
    listFrame:Hide()

    cdFrame = mod:Frame("Frame", "CMPvPOutdoorCDs", UIParent)
    cdFrame:SetSize(MAX_ICONS * 38, 52)
    MakeMovable(cdFrame, "cds", "TOP", 0, -140)
    cdFrame.icons = {}
    for i = 1, MAX_ICONS do
        local b = CreateFrame("Frame", nil, cdFrame)
        b:SetSize(34, 34)
        b:SetPoint("TOPLEFT", (i - 1) * 38, -2)
        b.tex = b:CreateTexture(nil, "ARTWORK"); b.tex:SetAllPoints(b)
        b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.shade = b:CreateTexture(nil, "OVERLAY"); b.shade:SetAllPoints(b)
        b.shade:SetColorTexture(0, 0, 0, 0.55)
        b.time = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
        b.time:SetPoint("CENTER", 0, 0)
        b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.name:SetPoint("TOP", b, "BOTTOM", 0, -1)
        b:Hide()
        cdFrame.icons[i] = b
    end
    cdFrame:Hide()

    castBars[1] = CreateCastBar("target", "cast_target", -120)
    castBars[2] = CreateCastBar("focus", "cast_focus", -160)
    for _, bar in ipairs(castBars) do
        bar.acc = 0
        bar:SetScript("OnUpdate", function(self, elapsed)
            self.acc = self.acc + elapsed
            if self.acc > 0.05 then self.acc = 0; CheckCast(self) end
        end)
    end
    for _, f in ipairs(movables) do ApplyPos(f) end
    ApplyLayout()
end

----------------------------------------------------------------------
-- Configuracion (pestana)
----------------------------------------------------------------------
local function NeedEnabled()
    if mod.enabled and listFrame then return true end
    Print("activa primero el modulo (casilla de arriba).")
    return false
end

local function Pct(v) return math.floor((v or 0) + 0.5) end

local function BuildConfig(m, L)
    DB = m.db
    L:Header("Que mostrar")
    local function Show(key, label)
        L:Check(label, function() return DB.show[key] end, function(v) DB.show[key] = v; UpdatePins() end)
    end
    Show("enemies", "Lista de enemigos cercanos")
    Show("cds", "Habilidades clave del enemigo (cooldowns)")
    Show("casts", "Alerta de casteos del objetivo y el foco")
    Show("map", "Marcas de tus muertes en el mapa")

    L:Header("Cuando actuar")
    L:Check("Solo en el mundo abierto (no instancias, campos de batalla ni arenas)",
        function() return DB.outdoorOnly end, function(v) DB.outdoorOnly = v end)
    L:Slider("Quitar a un enemigo de la lista tras (segundos sin verlo)", 5, 120, 5,
        function() return DB.enemyTTL end, function(v) DB.enemyTTL = v end)

    L:Header("Avisos")
    L:Check("Sonidos activados (interruptor general)", function() return DB.sound end, function(v) DB.sound = v end)
    L:Check("   Sonido al detectar un enemigo nuevo",
        function() return DB.alerts.new end, function(v) DB.alerts.new = v end)
    L:Check("   Sonido de alerta de grupo enemigo",
        function() return DB.alerts.group end, function(v) DB.alerts.group = v end)
    L:Check("   Sonido de alerta de peligro (nivel)",
        function() return DB.alerts.danger end, function(v) DB.alerts.danger = v end)
    L:Check("   Sonido de casteo peligroso",
        function() return DB.alerts.cast end, function(v) DB.alerts.cast = v end)
    L:Check("Mensaje grande en pantalla", function() return DB.alertText end, function(v) DB.alertText = v end)
    L:Slider("Duracion del mensaje grande (segundos)", 1, 8, 0.5,
        function() return DB.alertSeconds end, function(v) DB.alertSeconds = v end, "%.1f")
    L:Slider("Pausa entre avisos de grupo (segundos)", 3, 60, 1,
        function() return DB.groupCooldown end, function(v) DB.groupCooldown = v end)

    L:Header("Umbrales")
    L:Slider("Alerta de grupo desde (enemigos)", 2, 10, 1,
        function() return DB.groupSize end, function(v) DB.groupSize = v end)
    L:Slider("Peligro si lleva +niveles que tu", 1, 60, 1,
        function() return DB.dangerLevelDiff end, function(v) DB.dangerLevelDiff = v end)
    L:Slider("Casteos largos desde (segundos)", 0, 6, 0.5,
        function() return DB.longCast end, function(v) DB.longCast = v end, "%.1f")
    L:Slider("Cooldown en verde por debajo de (% restante)", 5, 50, 5,
        function() return DB.cdLow end, function(v) DB.cdLow = v end, "%d%%")
    L:Slider("Cooldown en rojo por encima de (% restante)", 50, 95, 5,
        function() return DB.cdHigh end, function(v) DB.cdHigh = v end, "%d%%")

    L:Header("Aspecto y posicion")
    L:Slider("Filas de la lista de enemigos", 1, 8, 1,
        function() return DB.listMax end, function(v) DB.listMax = v end)
    L:Slider("Iconos de habilidades a la vez", 3, 10, 1,
        function() return DB.cdMax end, function(v) DB.cdMax = v; ApplyLayout() end)
    L:Slider("Ancho de las barras de casteo", 150, 400, 10,
        function() return DB.castWidth end, function(v) DB.castWidth = v; ApplyLayout() end)
    L:Slider("Escala de la lista", 50, 200, 5,
        function() return Pct(DB.scale.list) end, function(v) DB.scale.list = v; ApplyLayout() end, "%d%%")
    L:Slider("Escala de las habilidades", 50, 200, 5,
        function() return Pct(DB.scale.cds) end, function(v) DB.scale.cds = v; ApplyLayout() end, "%d%%")
    L:Slider("Escala de las barras de casteo", 50, 200, 5,
        function() return Pct(DB.scale.casts) end, function(v) DB.scale.casts = v; ApplyLayout() end, "%d%%")
    L:Slider("Escala del mensaje grande", 50, 250, 5,
        function() return Pct(DB.scale.alert) end, function(v) DB.scale.alert = v; ApplyLayout() end, "%d%%")
    L:Slider("Opacidad del fondo al mover los marcos", 0, 100, 5,
        function() return Pct(DB.bgAlpha) end, function(v) DB.bgAlpha = v; ApplyLayout() end, "%d%%")
    local move
    move = L:Button(unlocked and "Fijar marcos" or "Mover marcos", 150, function()
        if not NeedEnabled() then return end
        SetUnlocked(not unlocked)
        move:SetText(unlocked and "Fijar marcos" or "Mover marcos")
    end)
    L:Button("Probar", 120, function() if NeedEnabled() then DoTest() end end, true)
    L:Add({ Refresh = function() move:SetText(unlocked and "Fijar marcos" or "Mover marcos") end }, 0)

    L:Header("Registro de muertes")
    L:Slider("Muertes guardadas", 10, 100, 10,
        function() return DB.deathMax end, function(v) DB.deathMax = v end)
    L:Button("Ver muertes (chat)", 150, function()
        if #DB.deaths == 0 then Print("sin muertes registradas.") end
        for i = 1, math.min(10, #DB.deaths) do
            local d = DB.deaths[i]
            Print(string.format("%d) %s - %s en %s%s", i, d.when, d.killer, d.zone or "?",
                (d.sub and d.sub ~= "") and (" / " .. d.sub) or ""))
        end
    end)
    L:Button("Borrar muertes", 150, function()
        DB.deaths = {}; UpdatePins(); Print("registro de muertes borrado.")
    end, true)
end

----------------------------------------------------------------------
-- Comandos antiguos (/pvpo, /cmpvp)
----------------------------------------------------------------------
local function OnSlash(m, msg)
    local cmd, arg = string.match(strlower(msg or ""), "^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "config" then Hub:Open("enemigos")
    elseif cmd == "minimap" then
        local c = ns.DB.minimap.enemigos
        Hub:SetModuleButton("enemigos", c.hide and true or false)
    elseif cmd == "voz" then Hub:Open("voces")
    elseif cmd == "vozinfo" then if ns.PO_VoiceDiag then ns.PO_VoiceDiag() end
    elseif cmd == "voztest" then if ns.PO_VoiceTest then ns.PO_VoiceTest() end
    elseif cmd == "unlock" then SetUnlocked(true)
    elseif cmd == "lock" then SetUnlocked(false)
    elseif cmd == "test" then DoTest()
    elseif cmd == "toggle" and DB.show[arg] ~= nil then
        DB.show[arg] = not DB.show[arg]
        Print(arg .. ": " .. (DB.show[arg] and "ON" or "OFF"))
        UpdatePins()
    elseif cmd == "sound" then
        DB.sound = not DB.sound; Print("sonido: " .. (DB.sound and "ON" or "OFF"))
    elseif cmd == "outdoor" then
        DB.outdoorOnly = not DB.outdoorOnly
        Print("solo outdoor: " .. (DB.outdoorOnly and "ON" or "OFF"))
    elseif cmd == "group" and tonumber(arg) then
        DB.groupSize = tonumber(arg); Print("alerta de grupo a partir de " .. arg)
    elseif cmd == "level" and tonumber(arg) then
        DB.dangerLevelDiff = tonumber(arg); Print("alerta de nivel +" .. arg)
    elseif cmd == "longcast" and tonumber(arg) then
        DB.longCast = tonumber(arg); Print("casteos largos desde " .. arg .. "s")
    elseif cmd == "log" then
        if #DB.deaths == 0 then Print("sin muertes registradas.") end
        for i = 1, math.min(10, #DB.deaths) do
            local d = DB.deaths[i]
            Print(string.format("%d) %s - %s en %s%s", i, d.when, d.killer, d.zone or "?",
                (d.sub and d.sub ~= "") and (" / " .. d.sub) or ""))
        end
    elseif cmd == "clear" then
        DB.deaths = {}; UpdatePins(); Print("registro de muertes borrado.")
    else
        Print("/pvpo = configuracion | voz | vozinfo | voztest | unlock | lock | test | sound | outdoor | log | clear | minimap")
        Print("/pvpo toggle enemies|cds|casts|map  -  /pvpo group <n>  |  level <n>  |  longcast <seg>")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local hooked = false

local function Init(m)
    DB = m.db
    DB.voice = nil   -- la voz vive ahora en el modulo "voces"
    -- ajustes de versiones antiguas (otoriPvpOutdoorDB / PvPOutdoorDB)
    if not DB._legacyChecked then
        DB._legacyChecked = true
        local old = otoriPvpOutdoorDB or PvPOutdoorDB
        if old and #DB.deaths == 0 and old ~= _G.CervecerosMendigosPvpOutdoorDB then
            for k, v in pairs(old) do
                if k ~= "voice" and k ~= "minimap" and type(v) ~= "nil" and k ~= "scale" then DB[k] = v end
            end
            Hub.CopyDefaults(DB, DEFAULTS)
        end
    end
    if type(DB.alerts) ~= "table" then DB.alerts = {} end
    Hub.CopyDefaults(DB, DEFAULTS)
    DB.minimap = nil
    BuildKeySpells()
    BuildDangerSpells()
    BuildFrames()
    if WorldMapFrame and not hooked then
        hooked = true
        WorldMapFrame:HookScript("OnShow", function() if mod.enabled then UpdatePins() end end)
        hooksecurefunc(WorldMapFrame, "OnMapChanged", function() if mod.enabled then UpdatePins() end end)
    end

    m:Event("PLAYER_ENTERING_WORLD", function() wipe(enemies) end)
    m:Event("NAME_PLATE_UNIT_ADDED", function(_, _, unit) ScanUnit(unit) end)
    m:Event("PLAYER_TARGET_CHANGED", function() ScanUnit("target"); RefreshCasts() end)
    m:Event("PLAYER_FOCUS_CHANGED", function() ScanUnit("focus"); RefreshCasts() end)
    m:Event("UPDATE_MOUSEOVER_UNIT", function() ScanUnit("mouseover") end)
    local function CastStart(_, _, unit)
        if unit == "target" or unit == "focus" then RefreshCasts() end
    end
    m:Event("UNIT_SPELLCAST_START", CastStart)
    m:Event("UNIT_SPELLCAST_CHANNEL_START", CastStart)
    m:Event("UNIT_SPELLCAST_SUCCEEDED", function(_, _, ...) OnSpellSucceeded(...) end)
    m:Event("PLAYER_DEAD", function() RecordDeath() end)

    local acc, scanAcc = 0, 0
    m:OnUpdate(function(_, elapsed)
        acc = acc + elapsed
        scanAcc = scanAcc + elapsed
        if scanAcc >= 0.5 then scanAcc = 0; ScanAll() end
        if acc < 0.1 then return end
        acc = 0
        UpdateEnemyList()
        UpdateCDs()
    end)
end

mod = Hub:Register{
    key = "enemigos", dir = "PvpOutdoor", name = "Enemigos cercanos",
    desc = "Lista de enemigos jugadores cercanos con alerta de grupo y de peligro por nivel, cooldowns de sus habilidades clave, alerta de casteos peligrosos en tu objetivo y foco, y marcas de tus muertes en el mapa.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosPvpOutdoorDB",
    slash = { "pvpo", "cmpvp" },
    Init = Init,
    Enable = function(m)
        if not listFrame then return end
        for _, f in ipairs(movables) do ApplyPos(f) end
        ApplyLayout()
        RefreshCasts()
        UpdatePins()
    end,
    Disable = function(m)
        if listFrame then SetUnlocked(false, true) end
        wipe(enemies)
        for _, p in ipairs(pins) do p:Hide() end
    end,
    BuildConfig = BuildConfig,
    OnSlash = OnSlash,
    OnReset = function(m)
        DB = m.db
        DB.voice = nil
        DB._legacyChecked = true
        if listFrame then
            for _, f in ipairs(movables) do ApplyPos(f) end
            ApplyLayout()
        end
    end,
}
