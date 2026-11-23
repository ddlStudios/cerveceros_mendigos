-- Modulo Combates (CervecerosMendigosPvP): registro de combates PvP con historial y estadisticas.
-- Cliente WoW Forever (Interface 16001). Evento de fin de partida verificado en el codigo
-- de la interfaz de Forever: PVP_MATCH_COMPLETE(winner, duration).
local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local issecret = issecretvalue or function() return false end

local DEFAULTS = {
    max = 500,
    recordBG = true,        -- guardar campos de batalla
    recordArena = true,     -- guardar arenas
    recordOther = true,     -- guardar otras partidas PvP
    minDur = 0,             -- ignorar partidas de menos de N segundos (0 = guardar todas)
    announce = true,        -- mensaje en el chat al guardar una partida
    autoOpen = false,       -- abrir el historial al terminar una partida
    keepComp = true,        -- guardar la composicion de clases de los equipos
    colWin = { 0.25, 1, 0.25 },
    colLoss = { 1, 0.25, 0.25 },
    colDraw = { 1, 0.82, 0.25 },
    rows = 14,              -- filas visibles del historial (6-14)
}

local mod
local DB
local ui = {}

----------------------------------------------------------------------
-- Historial: vive en la base del Hub (fuera de mod.db) para que
-- "Restaurar valores" restaure ajustes sin borrar tus partidas.
----------------------------------------------------------------------
local function Log()
    ns.DB.data = ns.DB.data or {}
    ns.DB.data.combates = ns.DB.data.combates or {}
    return ns.DB.data.combates
end

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
local function Print(msg) if mod then mod:Print(msg) end end

local function Num(v)
    if v == nil or type(v) ~= "number" or issecret(v) then return nil end
    return v
end
local function Str(v)
    if v == nil or type(v) ~= "string" or issecret(v) or v == "" then return nil end
    return v
end

local function Fmt(n)
    if not n then return "-" end
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 10000 then return string.format("%.0fk", n / 1000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n + 0.5))
end

local function FmtDur(s)
    if not s then return "-" end
    s = math.floor(s)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local DAYS = { "Domingo", "Lunes", "Martes", "Miercoles", "Jueves", "Viernes", "Sabado" }
local RESULT_TXT = { win = "Victoria", loss = "Derrota", draw = "Empate", unk = "Sin dato" }
local KIND_TXT = { arena = "Arena", bg = "Campo", other = "Otro" }

local function Hex(c)
    return string.format("|cff%02x%02x%02x", math.floor((c[1] or 1) * 255 + 0.5), math.floor((c[2] or 1) * 255 + 0.5), math.floor((c[3] or 1) * 255 + 0.5))
end
local function ResultColor(r)
    if r == "win" then return Hex(DB.colWin) elseif r == "loss" then return Hex(DB.colLoss)
    elseif r == "draw" then return Hex(DB.colDraw) end
    return "|cff999999"
end

local function ClassColor(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return string.format("|cff%02x%02x%02x", math.floor((c.r or 1) * 255 + 0.5), math.floor((c.g or 1) * 255 + 0.5), math.floor((c.b or 1) * 255 + 0.5)) end
    return "|cffffffff"
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

----------------------------------------------------------------------
-- Captura de datos de la partida
----------------------------------------------------------------------
local pending, pendingUntil

local function MyTeam()
    local t = SafeCall(GetBattlefieldArenaFaction)
    t = Num(t)
    if t then return t end
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Alliance" then return 1 elseif f == "Horde" then return 0 end
    return nil
end

local function MyScoreInfo()
    if C_PvP and C_PvP.GetScoreInfoByPlayerGuid then
        local guid = SafeCall(GetPlayerGuid) or (UnitGUID and UnitGUID("player"))
        if guid and not issecret(guid) then
            local info = SafeCall(C_PvP.GetScoreInfoByPlayerGuid, guid)
            if type(info) == "table" then return info end
        end
    end
    -- Plan B: buscar por nombre (el nombre nunca es secreto).
    if C_PvP and C_PvP.GetScoreInfo and GetNumBattlefieldScores then
        local me = UnitName and UnitName("player")
        local n = Num(SafeCall(GetNumBattlefieldScores)) or 0
        for i = 1, n do
            local info = SafeCall(C_PvP.GetScoreInfo, i)
            if type(info) == "table" and Str(info.name) and me and info.name:match("^[^-]+") == me then
                return info
            end
        end
    end
    return nil
end

-- Rellena los datos del marcador en la entrada. Devuelve true si encontro tu fila.
local function FillScore(e)
    if not C_PvP then return false end
    local mine = MyScoreInfo()
    if not mine then return false end

    e.kb = Num(mine.killingBlows) or e.kb
    e.hk = Num(mine.honorableKills) or e.hk
    e.deaths = Num(mine.deaths) or e.deaths
    e.honor = Num(mine.honorGained) or e.honor
    e.dmg = Num(mine.damageDone) or e.dmg
    e.heal = Num(mine.healingDone) or e.heal
    local rating = Num(mine.rating)
    if rating and rating > 0 then e.rating = rating end
    local rc = Num(mine.ratingChange)
    if rc and rc ~= 0 then e.ratingChange = rc end
    e.spec = Str(mine.talentSpec) or e.spec
    e.className = Str(mine.className) or e.className
    e.class = Str(mine.classToken) or e.class

    -- Composicion de equipos (clase y faccion nunca son secretas).
    local myFaction = Num(mine.faction) or e.team
    if DB.keepComp and myFaction and GetNumBattlefieldScores and C_PvP.GetScoreInfo then
        local ally, enemy = {}, {}
        local n = Num(SafeCall(GetNumBattlefieldScores)) or 0
        for i = 1, n do
            local info = SafeCall(C_PvP.GetScoreInfo, i)
            if type(info) == "table" then
                local tok, fac = Str(info.classToken), Num(info.faction)
                if tok and fac then
                    local t = (fac == myFaction) and ally or enemy
                    t[tok] = (t[tok] or 0) + 1
                end
            end
        end
        if next(ally) or next(enemy) then e.ally, e.enemy = ally, enemy end
    end
    return true
end

local function Trim()
    local max = DB.max or 500
    local log = Log()
    while #log > max do table.remove(log) end
end

local function AddEntry(e)
    table.insert(Log(), 1, e)
    Trim()
    if ui.win and ui.win:IsShown() then ui.Refresh() end
end

local lastKey, lastKeyTime = nil, 0

local function OnMatchComplete(winner, duration)
    winner = Num(winner)
    local map = Str(SafeCall(GetRealZoneText)) or Str(SafeCall(GetZoneText)) or "?"
    -- Evitar duplicados si el evento llega dos veces seguidas.
    local key = map .. ":" .. tostring(winner)
    local now = GetTime and GetTime() or 0
    if key == lastKey and (now - lastKeyTime) < 20 then return end
    lastKey, lastKeyTime = key, now

    local kind = "other"
    if C_PvP then
        if SafeCall(C_PvP.IsArena) then kind = "arena"
        elseif SafeCall(C_PvP.IsBattleground) then kind = "bg" end
    end
    if kind == "bg" and not DB.recordBG then return end
    if kind == "arena" and not DB.recordArena then return end
    if kind == "other" and not DB.recordOther then return end
    local dur = Num(duration)
    if (DB.minDur or 0) > 0 and dur and dur < DB.minDur then return end

    local team = MyTeam()
    local result = "unk"   -- ganador no legible
    if winner ~= nil and team ~= nil then
        result = "draw"
        if winner == team then result = "win"
        elseif winner == (team + 1) % 2 then result = "loss" end
    end

    local rated = false
    if C_PvP then
        rated = (SafeCall(C_PvP.IsRatedArena) or SafeCall(C_PvP.IsRatedBattleground) or SafeCall(C_PvP.IsRatedSoloShuffle)) and true or false
    end

    local className, classToken = nil, nil
    if UnitClass then
        local a, b = UnitClass("player")
        className, classToken = Str(a), Str(b)
    end
    local spec
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization and GetSpecializationInfo then
        local idx = SafeCall(C_SpecializationInfo.GetSpecialization)
        if idx then
            local ok, _, name = pcall(GetSpecializationInfo, idx)
            if ok then spec = Str(name) end
        end
    end

    local e = {
        t = time(),
        map = map,
        kind = kind,
        rated = rated,
        result = result,
        dur = dur,
        team = team,
        faction = UnitFactionGroup and Str((UnitFactionGroup("player"))) or nil,
        class = classToken,
        className = className,
        spec = spec,
    }
    FillScore(e)
    AddEntry(e)
    if DB.announce then
        Print("partida guardada: " .. map .. " - " .. ResultColor(result) .. (RESULT_TXT[result] or "?") .. "|r")
    end
    if DB.autoOpen and ui.Open then ui.Open(true) end

    -- El marcador final llega un poco despues: se pide y se completa la entrada.
    pending, pendingUntil = e, now + 15
    if RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            if mod:IsEnabled() and pending == e and RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
        end)
        C_Timer.After(16, function() if pending == e then pending = nil end end)
    end
end

local function OnScoreUpdate()
    if not pending then return end
    local now = GetTime and GetTime() or 0
    if pendingUntil and now > pendingUntil then pending = nil; return end
    if FillScore(pending) and ui.win and ui.win:IsShown() then ui.Refresh() end
end

----------------------------------------------------------------------
-- Estadisticas
----------------------------------------------------------------------
local function Stats(mapFilter)
    local s = { n = 0, w = 0, l = 0, d = 0, u = 0, honor = 0, honorN = 0, kb = 0, kbN = 0, deaths = 0, dN = 0,
                dmg = 0, dmgN = 0, heal = 0, healN = 0, dur = 0, durN = 0, maps = {}, days = {} }
    for i = 1, 7 do s.days[i] = { n = 0, w = 0 } end
    local list = {}
    for _, e in ipairs(Log()) do
        if not mapFilter or e.map == mapFilter then list[#list + 1] = e end
    end
    for _, e in ipairs(list) do
        s.n = s.n + 1
        if e.result == "win" then s.w = s.w + 1 elseif e.result == "loss" then s.l = s.l + 1
        elseif e.result == "draw" then s.d = s.d + 1 else s.u = s.u + 1 end
        if e.honor then s.honor = s.honor + e.honor; s.honorN = s.honorN + 1 end
        if e.kb then s.kb = s.kb + e.kb; s.kbN = s.kbN + 1 end
        if e.deaths then s.deaths = s.deaths + e.deaths; s.dN = s.dN + 1 end
        if e.dmg then s.dmg = s.dmg + e.dmg; s.dmgN = s.dmgN + 1 end
        if e.heal then s.heal = s.heal + e.heal; s.healN = s.healN + 1 end
        if e.dur then s.dur = s.dur + e.dur; s.durN = s.durN + 1 end
        local m = s.maps[e.map or "?"]
        if not m then m = { n = 0, w = 0, name = e.map or "?" }; s.maps[e.map or "?"] = m end
        m.n = m.n + 1
        if e.result == "win" then m.w = m.w + 1 end
        local wd = e.t and tonumber(date("%w", e.t)) or nil
        if wd then
            local dd = s.days[wd + 1]
            dd.n = dd.n + 1
            if e.result == "win" then dd.w = dd.w + 1 end
        end
    end
    -- Rachas (list va de mas reciente a mas antigua).
    s.cur, s.curType = 0, nil
    if list[1] then
        s.curType = list[1].result
        for _, e in ipairs(list) do
            if e.result == s.curType then s.cur = s.cur + 1 else break end
        end
    end
    s.bestWin, s.bestLoss = 0, 0
    local runW, runL = 0, 0
    for i = #list, 1, -1 do
        local r = list[i].result
        if r == "win" then runW = runW + 1; runL = 0
        elseif r == "loss" then runL = runL + 1; runW = 0
        else runW, runL = 0, 0 end
        if runW > s.bestWin then s.bestWin = runW end
        if runL > s.bestLoss then s.bestLoss = runL end
    end
    return s
end

local function Pct(w, n) if n == 0 then return "-" end return string.format("%.0f%%", w * 100 / n) end

local function SortedMaps(s)
    local arr = {}
    for _, m in pairs(s.maps) do arr[#arr + 1] = m end
    table.sort(arr, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    return arr
end

local function SummaryLines(mapFilter)
    local s = Stats(mapFilter)
    local out = {}
    out[#out + 1] = string.format("Combates: %d  (%d victorias, %d derrotas, %d empates)  -  %s de victorias%s",
        s.n, s.w, s.l, s.d, Pct(s.w, s.w + s.l + s.d), mapFilter and ("  [" .. mapFilter .. "]") or "")
    if s.curType then
        out[#out + 1] = string.format("Racha actual: %d %s  -  Mejor racha de victorias: %d  -  Peor de derrotas: %d",
            s.cur, (RESULT_TXT[s.curType] or "?"):lower() .. (s.cur == 1 and "" or "s"), s.bestWin, s.bestLoss)
    end
    if s.honorN > 0 then
        out[#out + 1] = string.format("Honor total: %s  -  Media por combate: %s", Fmt(s.honor), Fmt(s.honor / s.honorN))
    end
    return out
end

----------------------------------------------------------------------
-- Ventana de datos (historial y estadisticas)
----------------------------------------------------------------------
local RH = 22
local LIST_Y = -120
local LIST_W = 612
local MAXROWS = 14

local filters = { result = 1, map = 1 }   -- result: 1 todos 2 victorias 3 derrotas 4 empates; map: 1 = todos
local RES_FILTER = { nil, "win", "loss", "draw" }
local RES_FILTER_TXT = { "Todos", "Victorias", "Derrotas", "Empates" }
local view = {}
local offset = 0
local mapList = {}

local function Rows() return math.max(6, math.min(MAXROWS, DB.rows or MAXROWS)) end

local function MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 24)
    b:SetText(text)
    return b
end

local function BuildMapList()
    local seen, arr = {}, {}
    for _, e in ipairs(Log()) do
        if e.map and not seen[e.map] then seen[e.map] = true; arr[#arr + 1] = e.map end
    end
    table.sort(arr)
    mapList = arr
    if filters.map > #mapList + 1 then filters.map = 1 end
end

local function BuildView()
    wipe(view)
    local rf = RES_FILTER[filters.result]
    local mf = filters.map > 1 and mapList[filters.map - 1] or nil
    for i, e in ipairs(Log()) do
        if (not rf or e.result == rf) and (not mf or e.map == mf) then view[#view + 1] = i end
    end
end

local function EntryTooltip(row)
    local e = row.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine((e.map or "?") .. "  " .. ResultColor(e.result) .. (RESULT_TXT[e.result] or "?") .. "|r")
    GameTooltip:AddLine(date("%d/%m/%Y %H:%M", e.t or 0) .. "  -  " .. FmtDur(e.dur), 0.8, 0.8, 0.8)
    GameTooltip:AddLine((KIND_TXT[e.kind] or "Otro") .. (e.rated and " (puntuada)" or "") ..
        (e.faction and ("  -  " .. e.faction) or ""), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ClassColor(e.class) .. (e.className or e.class or "?") .. "|r" .. (e.spec and (" - " .. e.spec) or ""), 1, 1, 1)
    if e.kb or e.deaths then
        GameTooltip:AddLine(string.format("Golpes de gracia: %s   Muertes: %s   Bajas de honor: %s",
            e.kb and e.kb or "-", e.deaths and e.deaths or "-", e.hk and e.hk or "-"), 1, 1, 1)
    end
    if e.dmg or e.heal then
        GameTooltip:AddLine(string.format("Dano: %s   Curacion: %s", Fmt(e.dmg), Fmt(e.heal)), 1, 1, 1)
    end
    if e.honor then GameTooltip:AddLine("Honor: " .. Fmt(e.honor), 1, 1, 1) end
    if e.rating then
        GameTooltip:AddLine("Puntuacion: " .. e.rating .. (e.ratingChange and (" (" .. (e.ratingChange > 0 and "+" or "") .. e.ratingChange .. ")") or ""), 1, 1, 1)
    end
    local function Comp(t, label)
        if not t or not next(t) then return end
        local parts = {}
        for tok, n in pairs(t) do parts[#parts + 1] = ClassColor(tok) .. tok .. "|r x" .. n end
        table.sort(parts)
        GameTooltip:AddLine(label .. ": " .. table.concat(parts, ", "), 0.9, 0.9, 0.9, true)
    end
    if e.ally or e.enemy then
        GameTooltip:AddLine(" ")
        Comp(e.ally, "Tu equipo")
        Comp(e.enemy, "Rivales")
    end
    if e.fake then GameTooltip:AddLine("(entrada de prueba)", 1, 0.5, 0.2) end
    GameTooltip:Show()
end

local function UpdateRows()
    local nrows = Rows()
    local maxOff = math.max(0, #view - nrows)
    if offset > maxOff then offset = maxOff end
    if offset < 0 then offset = 0 end
    local log = Log()
    for i = 1, MAXROWS do
        local row = ui.rows[i]
        local idx = i <= nrows and view[offset + i]
        local e = idx and log[idx]
        row.entry = e
        if e then
            row.cFecha:SetText(date("%d/%m %H:%M", e.t or 0))
            row.cMapa:SetText(e.map or "?")
            row.cTipo:SetText((KIND_TXT[e.kind] or "Otro") .. (e.rated and "*" or ""))
            row.cRes:SetText(ResultColor(e.result) .. (RESULT_TXT[e.result] or "?") .. "|r")
            row.cDur:SetText(FmtDur(e.dur))
            row.cKB:SetText((e.kb and e.kb or "-") .. " / " .. (e.deaths and e.deaths or "-"))
            row.cHonor:SetText(e.honor and Fmt(e.honor) or "-")
            row.cClase:SetText(ClassColor(e.class) .. (e.spec or e.className or e.class or "?") .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end
    ui.scroll.loading = true
    ui.scroll:SetMinMaxValues(0, maxOff)
    ui.scroll:SetValue(offset)
    ui.scroll.loading = false
    ui.scroll:SetShown(maxOff > 0)
    ui.count:SetText(#view .. " de " .. #log .. " combates")
    ui.empty:SetShown(#view == 0)
end

local function RefreshStats()
    local mf = filters.map > 1 and mapList[filters.map - 1] or nil
    local s = Stats(mf)
    local L = {}
    local W, Lc, D = Hex(DB.colWin), Hex(DB.colLoss), Hex(DB.colDraw)
    L[#L + 1] = "|cffffd100Resumen|r" .. (mf and ("  [" .. mf .. "]") or "")
    L[#L + 1] = string.format("Combates: |cffffffff%d|r   Victorias: %s%d|r   Derrotas: %s%d|r   Empates: %s%d|r",
        s.n, W, s.w, Lc, s.l, D, s.d)
    L[#L + 1] = "Porcentaje de victorias: |cffffffff" .. Pct(s.w, s.w + s.l + s.d) .. "|r" ..
        (s.u > 0 and ("   (" .. s.u .. " sin resultado legible)") or "")
    if s.curType then
        L[#L + 1] = string.format("Racha actual: %s%d %s|r", ResultColor(s.curType), s.cur,
            (RESULT_TXT[s.curType] or "?"):lower() .. (s.cur == 1 and "" or "s"))
    else
        L[#L + 1] = "Racha actual: -"
    end
    L[#L + 1] = string.format("Mejor racha de victorias: %s%d|r   Peor racha de derrotas: %s%d|r", W, s.bestWin, Lc, s.bestLoss)
    L[#L + 1] = " "
    L[#L + 1] = "|cffffd100Honor y rendimiento|r"
    L[#L + 1] = "Honor total: |cffffffff" .. Fmt(s.honorN > 0 and s.honor or nil) .. "|r   Media: |cffffffff" ..
        Fmt(s.honorN > 0 and s.honor / s.honorN or nil) .. "|r"
    L[#L + 1] = "Golpes de gracia (media): |cffffffff" .. (s.kbN > 0 and string.format("%.1f", s.kb / s.kbN) or "-") ..
        "|r   Muertes (media): |cffffffff" .. (s.dN > 0 and string.format("%.1f", s.deaths / s.dN) or "-") .. "|r"
    L[#L + 1] = "Dano (media): |cffffffff" .. Fmt(s.dmgN > 0 and s.dmg / s.dmgN or nil) ..
        "|r   Curacion (media): |cffffffff" .. Fmt(s.healN > 0 and s.heal / s.healN or nil) .. "|r"
    L[#L + 1] = "Duracion media: |cffffffff" .. FmtDur(s.durN > 0 and s.dur / s.durN or nil) .. "|r"
    ui.statsLeft:SetText(table.concat(L, "\n"))

    local R = { "|cffffd100Por mapa|r" }
    local maps = SortedMaps(s)
    for i = 1, math.min(#maps, 9) do
        local m = maps[i]
        R[#R + 1] = string.format("%s: |cffffffff%d|r - %s", m.name, m.n, Pct(m.w, m.n))
    end
    if #maps == 0 then R[#R + 1] = "(sin datos)" end
    R[#R + 1] = " "
    R[#R + 1] = "|cffffd100Por dia de la semana|r"
    local order = { 2, 3, 4, 5, 6, 7, 1 }
    for _, di in ipairs(order) do
        local d = s.days[di]
        R[#R + 1] = string.format("%s: |cffffffff%d|r - %s", DAYS[di], d.n, Pct(d.w, d.n))
    end
    ui.statsRight:SetText(table.concat(R, "\n"))
end

local function SetTab(n)
    ui.tab = n
    ui.hist:SetShown(n == 1)
    ui.stats:SetShown(n == 2)
    ui.tabBtn[1]:SetEnabled(n ~= 1)
    ui.tabBtn[2]:SetEnabled(n ~= 2)
    ui.Refresh()
end

function ui.Refresh()
    if not ui.win then return end
    BuildMapList()
    BuildView()
    ui.resBtn:SetText("Resultado: " .. RES_FILTER_TXT[filters.result])
    ui.mapBtn:SetText(filters.map > 1 and mapList[filters.map - 1] or "Todos los mapas")
    ui.statsMapBtn:SetText(filters.map > 1 and mapList[filters.map - 1] or "Todos los mapas")
    if ui.tab == 2 then RefreshStats() else UpdateRows() end
end

local function CycleMap()
    filters.map = filters.map + 1
    if filters.map > #mapList + 1 then filters.map = 1 end
    offset = 0
    ui.Refresh()
end

StaticPopupDialogs["CERVECEROSMENDIGOSPVP_COMBATES_BORRAR"] = {
    text = "Borrar TODO el historial de combates?\nEsto no se puede deshacer.",
    button1 = "Borrar",
    button2 = "Cancelar",
    OnAccept = function()
        wipe(Log())
        filters.map, filters.result, offset = 1, 1, 0
        pending = nil
        if ui.win then ui.Refresh() end
        Print("historial borrado.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ExportToChat()
    local mf = filters.map > 1 and mapList[filters.map - 1] or nil
    Print("resumen de combates")
    for _, line in ipairs(SummaryLines(mf)) do Print(line) end
    local s = Stats(mf)
    local maps = SortedMaps(s)
    for i = 1, math.min(#maps, 5) do
        Print(string.format("  %s: %d combates, %s victorias", maps[i].name, maps[i].n, Pct(maps[i].w, maps[i].n)))
    end
end

local function BuildUI()
    local win = UI.MakeWindow("CervecerosMendigosCombatesWindow", "Historial de combates", 660, 560)
    mod:Track(win)
    ui.win = win

    -- Pestanas
    ui.tabBtn = {}
    local names = { "Historial", "Estadisticas" }
    for i = 1, 2 do
        local b = MakeButton(win, names[i], 110, 24)
        b:SetPoint("TOPLEFT", 14 + (i - 1) * 114, -32)
        b:SetScript("OnClick", function() SetTab(i) end)
        ui.tabBtn[i] = b
    end

    ----- Historial
    local hist = CreateFrame("Frame", nil, win)
    hist:SetPoint("TOPLEFT", 0, 0); hist:SetPoint("BOTTOMRIGHT", 0, 0)
    ui.hist = hist

    ui.resBtn = MakeButton(hist, "", 170, 22)
    ui.resBtn:SetPoint("TOPLEFT", 16, -64)
    ui.resBtn:SetScript("OnClick", function()
        filters.result = filters.result % 4 + 1
        offset = 0
        ui.Refresh()
    end)
    ui.mapBtn = MakeButton(hist, "", 230, 22)
    ui.mapBtn:SetPoint("LEFT", ui.resBtn, "RIGHT", 8, 0)
    ui.mapBtn:SetScript("OnClick", CycleMap)

    ui.count = hist:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.count:SetPoint("TOPRIGHT", -34, -69)

    -- Cabecera de columnas
    local cols = {
        { "Fecha", 6, 90, "cFecha" }, { "Mapa", 100, 150, "cMapa" }, { "Tipo", 255, 60, "cTipo" },
        { "Resultado", 318, 58, "cRes" }, { "Dur.", 380, 40, "cDur" }, { "GG / M", 424, 50, "cKB" },
        { "Honor", 478, 50, "cHonor" }, { "Clase", 532, 80, "cClase" },
    }
    for _, c in ipairs(cols) do
        local fs = hist:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", 20 + c[2], LIST_Y + 18)
        fs:SetText(c[1])
    end

    ui.rows = {}
    for i = 1, MAXROWS do
        local row = CreateFrame("Button", nil, hist)
        row:SetSize(LIST_W, RH)
        row:SetPoint("TOPLEFT", 20, LIST_Y - (i - 1) * RH)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(); bg:SetColorTexture(1, 1, 1, 0.04)
        end
        for _, c in ipairs(cols) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", c[2], 0)
            fs:SetWidth(c[3]); fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
            row[c[4]] = fs
        end
        row:SetScript("OnEnter", EntryTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        ui.rows[i] = row
    end

    ui.empty = hist:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    ui.empty:SetPoint("TOP", 0, LIST_Y - 90)
    ui.empty:SetText("Aun no hay combates guardados.\nSe apuntan solos al terminar una partida.")

    local scroll = CreateFrame("Slider", nil, hist)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, MAXROWS * RH)
    scroll:SetPoint("TOPLEFT", 20 + LIST_W + 4, LIST_Y)
    scroll:SetValueStep(1)
    if scroll.SetObeyStepOnDrag then scroll:SetObeyStepOnDrag(true) end
    local sbar = scroll:CreateTexture(nil, "BACKGROUND")
    sbar:SetAllPoints(); sbar:SetColorTexture(0.2, 0.2, 0.25, 0.8)
    scroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scroll:GetThumbTexture():SetSize(16, 24)
    scroll:SetScript("OnValueChanged", function(self, v)
        if self.loading then return end
        offset = math.floor(v + 0.5)
        UpdateRows()
    end)
    ui.scroll = scroll
    hist:EnableMouseWheel(true)
    hist:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta * 3
        UpdateRows()
    end)

    ----- Estadisticas
    local st = CreateFrame("Frame", nil, win)
    st:SetPoint("TOPLEFT", 0, 0); st:SetPoint("BOTTOMRIGHT", 0, 0)
    ui.stats = st

    ui.statsMapBtn = MakeButton(st, "", 230, 22)
    ui.statsMapBtn:SetPoint("TOPLEFT", 16, -64)
    ui.statsMapBtn:SetScript("OnClick", CycleMap)

    ui.statsLeft = st:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.statsLeft:SetPoint("TOPLEFT", 20, -100)
    ui.statsLeft:SetWidth(340); ui.statsLeft:SetJustifyH("LEFT"); ui.statsLeft:SetJustifyV("TOP")
    ui.statsRight = st:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.statsRight:SetPoint("TOPLEFT", 380, -100)
    ui.statsRight:SetWidth(270); ui.statsRight:SetJustifyH("LEFT"); ui.statsRight:SetJustifyV("TOP")

    ----- Botones inferiores (comunes)
    local exp = MakeButton(win, "Exportar al chat", 140, 24)
    exp:SetPoint("BOTTOMLEFT", 16, 14)
    exp:SetScript("OnClick", ExportToChat)
    local del = MakeButton(win, "Borrar historial", 140, 24)
    del:SetPoint("BOTTOMRIGHT", -16, 14)
    del:SetScript("OnClick", function() StaticPopup_Show("CERVECEROSMENDIGOSPVP_COMBATES_BORRAR") end)

    win:SetScript("OnShow", function() ui.Refresh() end)
    SetTab(1)
end

function ui.Open(forceShow)
    if not mod:IsEnabled() then return end
    if not ui.win then BuildUI() end
    if forceShow then ui.win:Show()
    elseif ui.win:IsShown() then ui.win:Hide() else ui.win:Show() end
end

----------------------------------------------------------------------
-- Datos de prueba (para ver la ventana sin jugar)
----------------------------------------------------------------------
local function RemoveFakes()
    local n, log = 0, Log()
    for i = #log, 1, -1 do
        if log[i].fake then table.remove(log, i); n = n + 1 end
    end
    return n
end

local function AddFakes()
    local maps = { "Garganta Grito de Guerra", "Cuenca de Arathi", "Valle de Alterac", "Arena de Nagrand" }
    local classes = { "MAGE", "WARRIOR", "ROGUE", "PRIEST" }
    local now = time()
    local log = Log()
    for i = 1, 8 do
        local win = (i % 3 ~= 0)
        local e = {
            t = now - i * 7200, map = maps[(i % #maps) + 1], kind = (i % 4 == 0) and "arena" or "bg",
            rated = false, result = win and "win" or "loss", dur = 300 + i * 40,
            faction = "Alliance", team = 1, class = "MAGE", className = "Mago", spec = "Escarcha",
            kb = i, hk = i * 3, deaths = i % 4, honor = 120 * i, dmg = 90000 * i, heal = 5000 * i,
            ally = { MAGE = 2, WARRIOR = 3 }, enemy = { ROGUE = 2, PRIEST = 3 }, fake = true,
        }
        e.class = classes[(i % #classes) + 1]
        table.insert(log, 1, e)
    end
    table.sort(log, function(a, b) return (a.t or 0) > (b.t or 0) end)
    Trim()
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
mod = Hub:Register{
    key = "combates", dir = "Combates", name = "Combates",
    desc = "Historial de tus campos de batalla y arenas con estadisticas por mapa y dia, rachas y honor.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosCombatesDB",
    slash = { "combates", "cmcomb" },

    Init = function(m)
        DB = m.db
        -- el historial del addon suelto (db.log) pasa a la base de datos del Hub
        if type(DB.log) == "table" then
            local log = Log()
            if #log == 0 then
                for i, e in ipairs(DB.log) do log[i] = e end
            end
            DB.log = nil
        end
        DB.minimap = nil
    end,

    Enable = function(m)
        DB = m.db
        m:Event("PVP_MATCH_COMPLETE", function(_, _, a1, a2) OnMatchComplete(a1, a2) end)
        m:Event("UPDATE_BATTLEFIELD_SCORE", function() OnScoreUpdate() end)
        if ui.win then ui.Refresh() end
    end,

    Disable = function(m)
        pending = nil
        if ui.win then ui.win:Hide() end
    end,

    OnReset = function(m)
        DB = m.db
        DB.log = nil; DB.minimap = nil
        Trim()
        if ui.win then ui.Refresh() end
    end,

    BuildConfig = function(m, L)
        DB = m.db
        L:Header("Que se guarda")
        L:Check("Campos de batalla", function() return DB.recordBG end, function(v) DB.recordBG = v end)
        L:Check("Arenas", function() return DB.recordArena end, function(v) DB.recordArena = v end)
        L:Check("Otras partidas PvP", function() return DB.recordOther end, function(v) DB.recordOther = v end)
        L:Check("Guardar la composicion de clases de los equipos", function() return DB.keepComp end, function(v) DB.keepComp = v end)
        L:Slider("Ignorar partidas de menos de (segundos)", 0, 300, 10,
            function() return DB.minDur end, function(v) DB.minDur = v end)
        L:Slider("Maximo de combates guardados", 50, 2000, 50,
            function() return DB.max end, function(v) DB.max = v; Trim() end)

        L:Header("Avisos")
        L:Check("Mensaje en el chat al guardar una partida", function() return DB.announce end, function(v) DB.announce = v end)
        L:Check("Abrir el historial al terminar una partida", function() return DB.autoOpen end, function(v) DB.autoOpen = v end)

        L:Header("Aspecto")
        L:Color("Color de las victorias", function() return unpack(DB.colWin) end,
            function(r, g, b) DB.colWin = { r, g, b }; if ui.win then ui.Refresh() end end)
        L:Color("Color de las derrotas", function() return unpack(DB.colLoss) end,
            function(r, g, b) DB.colLoss = { r, g, b }; if ui.win then ui.Refresh() end end)
        L:Color("Color de los empates", function() return unpack(DB.colDraw) end,
            function(r, g, b) DB.colDraw = { r, g, b }; if ui.win then ui.Refresh() end end)
        L:Slider("Filas visibles del historial", 6, 14, 1,
            function() return DB.rows end, function(v) DB.rows = v; if ui.win then ui.Refresh() end end)

        L:Header("Historial")
        L:Button("Abrir historial", 150, function() ui.Open(true) end)
        L:Button("Exportar al chat", 150, ExportToChat, true)
        L:Button("Borrar historial", 150, function() StaticPopup_Show("CERVECEROSMENDIGOSPVP_COMBATES_BORRAR") end, true)
        L:Button("Anadir datos de prueba", 180, function()
            AddFakes(); if ui.win and ui.win:IsShown() then ui.Refresh() end
        end)
        L:Button("Quitar datos de prueba", 180, function()
            Print("entradas de prueba borradas: " .. RemoveFakes())
            if ui.win and ui.win:IsShown() then ui.Refresh() end
        end, true)
    end,

    OnSlash = function(m, msg)
        DB = m.db
        msg = (msg or ""):lower()
        local cmd, arg = msg:match("^(%S*)%s*(.-)$")
        if cmd == "" or cmd == "abrir" then
            ui.Open()
        elseif cmd == "config" then
            Hub:Open("combates")
        elseif cmd == "stats" or cmd == "resumen" then
            ExportToChat()
        elseif cmd == "max" then
            local n = tonumber(arg)
            if n and n >= 10 and n <= 5000 then
                DB.max = math.floor(n); Trim(); Print("maximo de combates: " .. DB.max)
            else
                Print("uso: /combates max <10-5000>   (ahora: " .. (DB.max or 500) .. ")")
            end
        elseif cmd == "borrar" then
            StaticPopup_Show("CERVECEROSMENDIGOSPVP_COMBATES_BORRAR")
        elseif cmd == "prueba" then
            if arg == "borrar" then
                Print("entradas de prueba borradas: " .. RemoveFakes())
            else
                AddFakes(); Print("anadidas entradas de prueba. Quitalas con /combates prueba borrar")
            end
            if ui.win and ui.win:IsShown() then ui.Refresh() end
        else
            Print("comandos: /combates (abrir historial), config, stats, max <n>, borrar, prueba [borrar]")
        end
    end,
}

-- Para otros modulos (p. ej. Resumen): acceso de solo lectura al historial.
function mod.GetLog() return Log() end
