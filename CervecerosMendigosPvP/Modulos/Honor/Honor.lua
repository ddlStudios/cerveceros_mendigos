-- Modulo Honor (CervecerosMendigosPvP): seguimiento del rango PvP y del honor semanal en WoW Forever.
-- El rango de Forever NO es UnitPVPRank ni el nivel de honor: la pestana PvP lee la
-- "major faction" 2800 (Blizzard_UIPanels_Game/Camelot/PVPRankFrame.lua):
--   C_MajorFactions.GetMajorFactionProgressionInfo(2800) -> renownLevel (rango, 0 = Civil),
--   renownReputationEarned (puntos dentro del rango), renownLevelThreshold (los del siguiente),
--   currentWeekProgressiveMaxLevel (tope semanal);
--   C_MajorFactions.GetTotalReputationForRenownLevel(2800, nivel) (total acumulado).
local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local FACTION_ID = 2800
local HONOR_CURRENCY = 1901   -- Constants.CurrencyConsts.CLASSIC_HONOR_CURRENCY_ID

local issecret = issecretvalue or function() return false end

local DEFAULTS = {
    goal = 0,            -- objetivo semanal en puntos de rango (0 = hasta el siguiente rango)
    bar = false,         -- barra compacta en pantalla
    barLocked = false,
    barPos = nil,
    barScale = 100,      -- tamano de la barra (%)
    barAlpha = 100,      -- opacidad de la barra (%)
    barShowWeek = true,  -- texto "semana +N" en la barra
    resetDay = 3,        -- solo si el cliente no da el reinicio semanal (0 = domingo ... 6 = sabado)
    resetHour = 4,
    readEvery = 60,      -- lectura de seguridad cada N segundos
    minMatchDur = 120,   -- partidas mas cortas no cuentan para "puntos por hora" (segundos)
    scale = 100,         -- tamano de la ventana (%)
    showSources = true,  -- seccion "de donde vienen los puntos"
    showChart = true,    -- grafico de las ultimas semanas
    showBest = true,     -- mejores partidas
    colRank = { 0.85, 0.65, 0.1 },
    colWeek = { 0.25, 0.6, 0.95 },
}

-- Totales de puntos para ALCANZAR cada rango (datos de la beta, no oficiales); solo de respaldo.
local TOTALS = { [0] = 0, 750, 1650, 2700, 3900, 5250, 6750, 8400, 10200, 12150, 14250, 16600, 19100, 21750, 24750 }

local SRC_ORDER = { "bg", "world", "quest", "other" }
local SRC_TXT = { bg = "Campos de batalla y arenas", world = "Mundo abierto", quest = "Misiones", other = "Otros" }

local mod
local DB, CH            -- ajustes y datos del personaje actual
local ui = {}
local match             -- partida en curso { t0, map, pts, honor }
local lastQuest = 0

-- Los datos por personaje viven en la base del Hub (fuera de mod.db): "Restaurar valores"
-- no borra tu historial.
local function Data()
    ns.DB.data = ns.DB.data or {}
    ns.DB.data.honor = ns.DB.data.honor or {}
    ns.DB.data.honor.chars = ns.DB.data.honor.chars or {}
    return ns.DB.data.honor
end

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
local function Print(msg) if mod then mod:Print(msg) end end

local function Num(v)
    if type(v) ~= "number" or issecret(v) then return nil end
    return v
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function Fmt(n)
    if not n then return "sin dato" end
    n = math.floor(n + 0.5)
    local s = tostring(math.abs(n))
    while true do
        local k
        s, k = s:gsub("^(%d+)(%d%d%d)", "%1.%2")
        if k == 0 then break end
    end
    return (n < 0 and "-" or "") .. s
end

local function Pct(a, b)
    if not a or not b or b <= 0 then return 0 end
    return math.max(0, math.min(1, a / b))
end

local function Now() return (GetServerTime and Num(SafeCall(GetServerTime))) or time() end

local function DayKey(t) return date("%Y-%m-%d", math.floor(t)) end

----------------------------------------------------------------------
-- Lectura del rango y del honor
----------------------------------------------------------------------
local function TotalForRank(rank)
    if C_MajorFactions and C_MajorFactions.GetTotalReputationForRenownLevel then
        local t = Num(SafeCall(C_MajorFactions.GetTotalReputationForRenownLevel, FACTION_ID, rank))
        if t then return t end
    end
    return TOTALS[rank]
end

local function RankName(rank)
    if not rank or rank <= 0 then
        return (type(PVP_RANK_0_NAME) == "string" and PVP_RANK_0_NAME) or "Civil"
    end
    local name
    if GetText and Enum and Enum.PvPRanks and Enum.PvPRanks.Rank_1 then
        local sex = UnitSex and UnitSex("player") or 2
        local fac = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and 1 or 0
        local key = "PVP_RANK_" .. tostring(Enum.PvPRanks.Rank_1 + rank - 1) .. "_" .. tostring(fac)
        local ok, txt = pcall(GetText, key, sex)
        if ok and type(txt) == "string" and txt ~= "" and not issecret(txt) then name = txt end
    end
    return name or ("Rango " .. rank)
end

-- Devuelve nil si el cliente no responde ("sin dato").
local function ReadRank()
    if not (C_MajorFactions and C_MajorFactions.GetMajorFactionProgressionInfo) then return nil end
    local info = SafeCall(C_MajorFactions.GetMajorFactionProgressionInfo, FACTION_ID)
    if type(info) ~= "table" then return nil end
    local rank = Num(info.renownLevel)
    local earned = Num(info.renownReputationEarned)
    if not rank or not earned then return nil end
    local thr = Num(info.renownLevelThreshold)
    local base = TotalForRank(rank)
    local r = { rank = rank, earned = earned, thr = thr, total = base and (base + earned) or nil }
    local capLevel = Num(info.currentWeekProgressiveMaxLevel)
    if capLevel and capLevel > 0 then
        r.capLevel = capLevel
        r.capTotal = TotalForRank(capLevel)
    end
    r.maxLevel = Num(info.maxLevel)
    return r
end

local function ReadHonor()
    if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return nil end
    local info = SafeCall(C_CurrencyInfo.GetCurrencyInfo, HONOR_CURRENCY)
    if type(info) ~= "table" then return nil end
    return Num(info.quantity)
end

----------------------------------------------------------------------
-- Semana (reinicio semanal del servidor)
----------------------------------------------------------------------
local function WeekEnd(now)
    local secs
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        secs = Num(SafeCall(C_DateAndTime.GetSecondsUntilWeeklyReset))
    end
    if secs and secs > 0 then return now + secs, true end
    -- Respaldo configurable (hora local del equipo).
    local t = date("*t", math.floor(now))
    local add = ((DB.resetDay or 3) - t.wday + 1) % 7
    local target = time({ year = t.year, month = t.month, day = t.day + add, hour = DB.resetHour or 4, min = 0, sec = 0 })
    if target <= now then target = target + 7 * 86400 end
    return target, false
end

local function NewWeek(we)
    return { we = we, pts = 0, honor = 0, src = { bg = 0, world = 0, quest = 0, other = 0 } }
end

local function CurrentWeek(now)
    local we = WeekEnd(now)
    local w = CH.weeks[1]
    if not w or (we - w.we) > 3 * 86400 then
        w = NewWeek(we)
        table.insert(CH.weeks, 1, w)
        while #CH.weeks > 14 do table.remove(CH.weeks) end
    end
    return w
end

----------------------------------------------------------------------
-- Contexto y registro de ganancias
----------------------------------------------------------------------
local function InPvpInstance()
    if C_PvP then
        if SafeCall(C_PvP.IsArena) or SafeCall(C_PvP.IsBattleground) then return true end
    end
    if IsInInstance then
        local ok, inInst, kind = pcall(IsInInstance)
        if ok and inInst and (kind == "pvp" or kind == "arena") then return true end
    end
    return false
end

local function Source()
    if InPvpInstance() then return "bg" end
    if GetTime and (GetTime() - lastQuest) < 5 then return "quest" end
    local ok, inInst = pcall(IsInInstance or function() return false end)
    if ok and inInst then return "other" end
    return "world"
end

local function EnsureMatch()
    if not match then
        match = { t0 = GetTime and GetTime() or 0, map = (GetRealZoneText and SafeCall(GetRealZoneText)) or "?", pts = 0, honor = 0 }
    end
    return match
end

local function AddGain(pts, honor)
    local now = Now()
    local w = CurrentWeek(now)
    local src = Source()
    if pts and pts > 0 then
        w.pts = w.pts + pts
        w.src[src] = (w.src[src] or 0) + pts
        local dk = DayKey(now)
        local d = CH.days[dk]
        if not d then d = { pts = 0, honor = 0 }; CH.days[dk] = d end
        d.pts = d.pts + pts
    end
    if honor and honor > 0 then
        w.honor = w.honor + honor
        local dk = DayKey(now)
        local d = CH.days[dk]
        if not d then d = { pts = 0, honor = 0 }; CH.days[dk] = d end
        d.honor = d.honor + honor
    end
    if src == "bg" then
        local m = EnsureMatch()
        m.pts = m.pts + (pts or 0)
        m.honor = m.honor + (honor or 0)
    end
end

local function PruneDays()
    local limit = DayKey(Now() - 70 * 86400)
    for k in pairs(CH.days) do if k < limit then CH.days[k] = nil end end
end

-- Lee rango y honor y registra lo que haya subido desde la ultima lectura.
local function Process()
    if not CH or not mod:IsEnabled() then return end
    local r = ReadRank()
    local h = ReadHonor()
    local last = CH.last
    local pts, honor
    if r and r.total then
        if last and last.total and last.rank ~= nil then
            local d = r.total - last.total
            if d > 0 then pts = d end   -- si baja (reinicio de temporada) solo se reajusta la base
        end
    end
    if h and last and last.honor then
        local d = h - last.honor
        if d > 0 then honor = d end
    end
    CurrentWeek(Now())   -- garantiza semana al dia aunque no haya ganancias
    if (pts and pts > 0) or (honor and honor > 0) then AddGain(pts, honor) end
    CH.last = CH.last or {}
    if r then
        CH.last.rank, CH.last.total, CH.last.earned, CH.last.thr = r.rank, r.total, r.earned, r.thr
        CH.last.capLevel, CH.last.capTotal, CH.last.maxLevel = r.capLevel, r.capTotal, r.maxLevel
    end
    if h then CH.last.honor = h end
    CH.last.t = Now()
    ui.cur = r
    ui.curHonor = h
    if ui.Refresh then ui.Refresh() end
end

local pendingProcess
local function Soon(delay)
    if pendingProcess then return end
    pendingProcess = true
    local function run() pendingProcess = nil; Process() end
    if C_Timer and C_Timer.After then C_Timer.After(delay or 0.5, run) else run() end
end

local function FinishMatch(duration)
    if not match or not mod:IsEnabled() then return end
    local m = match
    match = nil
    if (m.pts or 0) <= 0 and (m.honor or 0) <= 0 then return end
    local dur = Num(duration) or ((GetTime and GetTime() or 0) - m.t0)
    local e = { t = Now(), map = m.map, dur = dur, pts = m.pts, honor = m.honor }
    if dur and dur >= (DB.minMatchDur or 120) then e.pph = m.pts / (dur / 3600) end
    table.insert(CH.matches, 1, e)
    while #CH.matches > 40 do table.remove(CH.matches) end
    if ui.Refresh then ui.Refresh() end
end

----------------------------------------------------------------------
-- Calculos de la vista
----------------------------------------------------------------------
local function Pace()
    local now = Now()
    local sum, days = 0, 0
    for i = 0, 6 do
        local d = CH.days[DayKey(now - i * 86400)]
        if d then sum = sum + (d.pts or 0) end
        days = days + 1
    end
    return sum / days
end

local function View()
    local v = { r = ui.cur }
    local now = Now()
    v.week = CurrentWeek(now)
    v.pace = Pace()
    local r = v.r
    if r and r.thr and r.earned then
        v.toNext = math.max(0, r.thr - r.earned)
        if v.pace > 0 then
            v.daysToNext = v.toNext / v.pace
        end
    end
    return v
end

----------------------------------------------------------------------
-- Interfaz: utilidades
----------------------------------------------------------------------
local function MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 24)
    b:SetText(text)
    return b
end

local function Label(parent, x, y, font, w, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    if w then fs:SetWidth(w) end
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

-- Barra de progreso propia (textura de fondo + textura de relleno).
local function MakeBar(parent, w, h, color)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.08, 0.08, 0.1, 0.9)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetPoint("TOPLEFT", 1, -1)
    f.fill:SetPoint("BOTTOMLEFT", 1, 1)
    f.fill:SetColorTexture(1, 1, 1, 1)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("CENTER")
    f.w = w
    f.colorKey = color
    function f:Set(frac, text)
        frac = math.max(0, math.min(1, frac or 0))
        local c = DB[self.colorKey] or { 0.2, 0.7, 0.4 }
        self.fill:SetColorTexture(c[1], c[2], c[3], 1)
        self.fill:SetWidth(math.max(0.001, (self.w - 2) * frac))
        self.text:SetText(text or "")
    end
    return f
end

----------------------------------------------------------------------
-- Interfaz: ventana de datos
----------------------------------------------------------------------
local CHART_W, CHART_H = 400, 70

local function ForecastText(v)
    if not v.r then return "sin dato" end
    if not v.toNext then return "sin dato" end
    if v.toNext == 0 then return "ya tienes los puntos" end
    if not v.daysToNext then return "sin ritmo todavia" end
    local d = v.daysToNext
    local when = date("%d/%m", math.floor(Now() + d * 86400))
    return string.format("en %.1f dias (%s)", d, when)
end

local function BestMatches()
    local list = {}
    for _, m in ipairs(CH.matches) do
        if m.pph and m.pts and m.pts > 0 then list[#list + 1] = m end
    end
    table.sort(list, function(a, b) return a.pph > b.pph end)
    return list
end

local function BuildUI()
    local win = UI.MakeWindow("CervecerosMendigosHonorWindow", "Honor y rango PvP", 440, 570)
    mod:Track(win)
    ui.win = win
    win:SetScale((DB.scale or 100) / 100)
    local W = 400
    ui.rankText = Label(win, 20, -34, "GameFontNormalLarge", W, "CENTER")
    ui.rankBar = MakeBar(win, W, 20, "colRank")
    ui.rankBar:SetPoint("TOPLEFT", 20, -60)
    ui.rankInfo = Label(win, 20, -86, "GameFontHighlight", W, "CENTER")
    ui.capInfo = Label(win, 20, -104, "GameFontHighlightSmall", W, "CENTER")

    Label(win, 20, -128, "GameFontNormal", W):SetText("Esta semana")
    ui.weekBar = MakeBar(win, W, 18, "colWeek")
    ui.weekBar:SetPoint("TOPLEFT", 20, -148)
    ui.weekPts = Label(win, 20, -172, "GameFontHighlight", W)
    ui.weekHonor = Label(win, 20, -190, "GameFontHighlight", W)
    ui.pace = Label(win, 20, -208, "GameFontHighlight", W)
    ui.forecast = Label(win, 20, -226, "GameFontHighlight", W)

    ui.srcTitle = Label(win, 20, -252, "GameFontNormal", W)
    ui.srcTitle:SetText("De donde vienen los puntos de esta semana")
    ui.srcLines = {}
    for i = 1, #SRC_ORDER do
        ui.srcLines[i] = Label(win, 20, -272 - (i - 1) * 16, "GameFontHighlightSmall", W)
    end

    ui.chartTitle = Label(win, 20, -344, "GameFontNormal", W)
    ui.chartTitle:SetText("Ultimas 8 semanas (puntos de rango)")
    ui.chart = CreateFrame("Frame", nil, win)
    ui.chart:SetSize(CHART_W, CHART_H + 14)
    ui.chart:SetPoint("TOPLEFT", 20, -364)
    ui.bars, ui.barVals, ui.barLbl = {}, {}, {}
    local bw = CHART_W / 8
    for i = 1, 8 do
        local t = ui.chart:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(0.25, 0.6, 0.95, 1)
        t:SetPoint("BOTTOMLEFT", (i - 1) * bw + 6, 14)
        t:SetSize(bw - 12, 1)
        ui.bars[i] = t
        local vfs = ui.chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        vfs:SetPoint("BOTTOM", t, "TOP", 0, 1)
        ui.barVals[i] = vfs
        local lfs = ui.chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lfs:SetPoint("BOTTOMLEFT", (i - 1) * bw, 0)
        lfs:SetWidth(bw); lfs:SetJustifyH("CENTER")
        ui.barLbl[i] = lfs
    end

    ui.bestTitle = Label(win, 20, -454, "GameFontNormal", W)
    ui.bestTitle:SetText("Mejores partidas (puntos por hora)")
    ui.best = {}
    for i = 1, 3 do ui.best[i] = Label(win, 20, -474 - (i - 1) * 16, "GameFontHighlightSmall", W) end

    local barBtn = MakeButton(win, "Barra en pantalla", 140, 24)
    barBtn:SetPoint("BOTTOMLEFT", 16, 14)
    barBtn:SetScript("OnClick", function() ui.ToggleBar() end)
    local cp = MakeButton(win, "Copiar al chat", 120, 24)
    cp:SetPoint("BOTTOMRIGHT", -16, 14)
    cp:SetScript("OnClick", function() ui.Export() end)

    win:SetScript("OnShow", function() Process() end)
end

local function GoalTarget(v)
    -- Devuelve (objetivo en puntos de la semana, texto).
    if DB.goal and DB.goal > 0 then return DB.goal, "objetivo semanal" end
    local r = v.r
    if r and r.thr and r.earned then
        -- puntos que habia que ganar al empezar la semana para el siguiente rango
        return (v.week.pts + (v.toNext or 0)), "hasta el siguiente rango"
    end
    return nil
end

local function RefreshWindow(v)
    local r = v.r
    if not r then
        ui.rankText:SetText("Rango PvP: sin dato")
        ui.rankBar:Set(0, "sin dato")
        ui.rankInfo:SetText("El cliente no ha devuelto el rango (prueba /honor diag).")
        ui.capInfo:SetText("")
    else
        ui.rankText:SetText((r.rank > 0 and ("Rango " .. r.rank .. " - ") or "") .. RankName(r.rank))
        ui.rankBar:Set(Pct(r.earned, r.thr), Fmt(r.earned) .. " / " .. (r.thr and Fmt(r.thr) or "?") .. "  (" .. math.floor(Pct(r.earned, r.thr) * 100 + 0.5) .. "%)")
        if v.toNext then
            ui.rankInfo:SetText("Faltan |cffffd100" .. Fmt(v.toNext) .. "|r puntos para el rango " .. (r.rank + 1))
        else
            ui.rankInfo:SetText("Rango maximo o sin dato del siguiente")
        end
        if r.capTotal and r.capTotal > 0 and r.total then
            ui.capInfo:SetText("Tope de esta semana: rango " .. r.capLevel .. " (" .. Fmt(r.capTotal) .. " puntos en total). Llevas " .. Fmt(r.total) .. ".")
        else
            ui.capInfo:SetText(r.total and ("Puntos totales: " .. Fmt(r.total)) or "")
        end
    end

    local w = v.week
    local target, label = GoalTarget(v)
    if target and target > 0 then
        ui.weekBar:Set(Pct(w.pts, target), Fmt(w.pts) .. " / " .. Fmt(target) .. "  (" .. label .. ")")
    else
        ui.weekBar:Set(0, Fmt(w.pts) .. " puntos")
    end
    ui.weekPts:SetText("Puntos de rango ganados: |cffffd100" .. Fmt(w.pts) .. "|r")
    ui.weekHonor:SetText("Honor ganado: |cffffd100" .. (ui.curHonor and Fmt(w.honor) or "sin dato") .. "|r" .. (ui.curHonor and ("   (tienes " .. Fmt(ui.curHonor) .. ")") or ""))
    ui.pace:SetText("Ritmo medio (7 dias): |cffffd100" .. Fmt(v.pace) .. "|r puntos al dia")
    ui.forecast:SetText("Siguiente rango: |cffffd100" .. ForecastText(v) .. "|r")

    -- secciones que se pueden ocultar
    ui.srcTitle:SetShown(DB.showSources)
    for i, key in ipairs(SRC_ORDER) do
        local p = w.src[key] or 0
        local pc = (w.pts > 0) and math.floor(p / w.pts * 100 + 0.5) or 0
        ui.srcLines[i]:SetText(string.format("%s: |cffffd100%s|r  (%d%%)", SRC_TXT[key], Fmt(p), pc))
        ui.srcLines[i]:SetShown(DB.showSources)
    end

    -- Grafico: la semana actual a la derecha.
    ui.chartTitle:SetShown(DB.showChart)
    ui.chart:SetShown(DB.showChart)
    local maxv = 1
    local vals = {}
    for i = 1, 8 do
        local wk = CH.weeks[9 - i]
        vals[i] = wk and wk.pts or 0
        if vals[i] > maxv then maxv = vals[i] end
    end
    local c = DB.colWeek or { 0.25, 0.6, 0.95 }
    for i = 1, 8 do
        local wk = CH.weeks[9 - i]
        local h = math.max(1, vals[i] / maxv * CHART_H)
        ui.bars[i]:SetColorTexture(c[1], c[2], c[3], 1)
        ui.bars[i]:SetHeight(h)
        ui.barVals[i]:SetText(wk and Fmt(vals[i]) or "")
        ui.barLbl[i]:SetText(wk and (i == 8 and "esta" or date("%d/%m", math.floor(wk.we - 7 * 86400))) or "-")
    end

    ui.bestTitle:SetShown(DB.showBest)
    local best = BestMatches()
    for i = 1, 3 do
        local m = best[i]
        if m then
            ui.best[i]:SetText(string.format("%d. %s: |cffffd100%s|r pts/h  (%s pts en %d min)", i, m.map or "?", Fmt(m.pph), Fmt(m.pts), math.floor((m.dur or 0) / 60 + 0.5)))
        else
            ui.best[i]:SetText(i == 1 and "Aun no hay partidas con puntos registrados." or "")
        end
        ui.best[i]:SetShown(DB.showBest)
    end
end

----------------------------------------------------------------------
-- Barra compacta en pantalla
----------------------------------------------------------------------
local function ApplyBarPos()
    if not ui.barFrame then return end
    ui.barFrame:ClearAllPoints()
    local p = DB.barPos
    if p then ui.barFrame:SetPoint(p[1] or "CENTER", UIParent, p[2] or "CENTER", p[3] or 0, p[4] or 0)
    else ui.barFrame:SetPoint("TOP", UIParent, "TOP", 0, -140) end
end

local function ApplyBarLook()
    if not ui.barFrame then return end
    ui.barFrame:SetScale((DB.barScale or 100) / 100)
    ui.barFrame:SetAlpha((DB.barAlpha or 100) / 100)
end

local function BuildBar()
    local f = mod:Frame("Frame", "CervecerosMendigosHonorBar", UIParent)
    f:SetSize(240, 34)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not DB.barLocked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        DB.barPos = { p, rp, x, y }
    end)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints(); f.bg:SetColorTexture(0, 0, 0, 0.55)
    f.line1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.line1:SetPoint("TOPLEFT", 6, -4)
    f.bar = MakeBar(f, 228, 10, "colRank")
    f.bar:SetPoint("BOTTOMLEFT", 6, 4)
    ui.barFrame = f
    ApplyBarPos()
    ApplyBarLook()
    f:SetShown(DB.bar and true or false)
end

local function RefreshBar(v)
    if not ui.barFrame then return end
    local r = v.r
    if r then
        ui.barFrame.line1:SetText("Rango " .. r.rank .. (DB.barShowWeek and ("  |  semana +" .. Fmt(v.week.pts)) or ""))
        ui.barFrame.bar:Set(Pct(r.earned, r.thr), "")
    else
        ui.barFrame.line1:SetText("Rango PvP: sin dato")
        ui.barFrame.bar:Set(0, "")
    end
end

local SyncBar

function ui.ToggleBar()
    DB.bar = not DB.bar
    SyncBar()
    Print(DB.bar and "barra en pantalla activada" or "barra en pantalla oculta")
end

function SyncBar()
    if DB.bar and not ui.barFrame then BuildBar() end
    if ui.barFrame then ui.barFrame:SetShown(DB.bar and mod:IsEnabled()) end
    if DB.bar then Process() end
end

----------------------------------------------------------------------
-- Actualizacion conjunta
----------------------------------------------------------------------
function ui.Refresh()
    if not CH then return end
    local v = View()
    if ui.win and ui.win:IsShown() then RefreshWindow(v) end
    if DB.bar then RefreshBar(v) end
end

----------------------------------------------------------------------
-- Exportar al chat (solo a tu ventana de chat)
----------------------------------------------------------------------
function ui.Export()
    Process()
    local v = View()
    local r = v.r
    if r then
        Print("Rango " .. r.rank .. " (" .. RankName(r.rank) .. "): " .. Fmt(r.earned) .. "/" .. (r.thr and Fmt(r.thr) or "?")
            .. (v.toNext and (", faltan " .. Fmt(v.toNext)) or ""))
    else
        Print("Rango: sin dato")
    end
    Print("Semana: +" .. Fmt(v.week.pts) .. " puntos, " .. Fmt(v.week.honor) .. " de honor. Ritmo " .. Fmt(v.pace) .. " pts/dia. Siguiente rango: " .. ForecastText(v))
end

function ui.Open(forceShow)
    if not mod:IsEnabled() then return end
    if not ui.win then BuildUI() end
    if forceShow then ui.win:Show()
    elseif ui.win:IsShown() then ui.win:Hide() else ui.win:Show() end
end

StaticPopupDialogs["CERVECEROSMENDIGOSPVP_HONOR_BORRAR"] = {
    text = "Borrar todo el historial de honor de este personaje?",
    button1 = "Borrar", button2 = "Cancelar",
    OnAccept = function()
        if not CH then return end
        CH.weeks, CH.days, CH.matches, CH.last = {}, {}, {}, nil
        Process()
        Print("historial borrado")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

----------------------------------------------------------------------
-- Datos de prueba
----------------------------------------------------------------------
local function RemoveFakes()
    local n = 0
    for i = #CH.weeks, 1, -1 do if CH.weeks[i].fake then table.remove(CH.weeks, i); n = n + 1 end end
    for i = #CH.matches, 1, -1 do if CH.matches[i].fake then table.remove(CH.matches, i); n = n + 1 end end
    return n
end

local function AddFakes()
    RemoveFakes()
    local cur = CH.weeks[1] and CH.weeks[1].we or (Now() + 3 * 86400)
    for i = 1, 7 do
        local w = NewWeek(cur - i * 7 * 86400)
        w.pts = 300 + i * 170 + (i % 3) * 120
        w.honor = w.pts * 6
        w.src.bg = math.floor(w.pts * 0.7); w.src.world = math.floor(w.pts * 0.2); w.src.quest = math.floor(w.pts * 0.05)
        w.src.other = w.pts - w.src.bg - w.src.world - w.src.quest
        w.fake = true
        table.insert(CH.weeks, w)
    end
    local maps = { "Garganta Grito de Guerra", "Cuenca de Arathi", "Valle de Alterac" }
    for i = 1, 5 do
        table.insert(CH.matches, { t = Now() - i * 3600, map = maps[(i % 3) + 1], dur = 600 + i * 90, pts = 90 + i * 25,
            honor = 400 + i * 50, pph = (90 + i * 25) / ((600 + i * 90) / 3600), fake = true })
    end
end

----------------------------------------------------------------------
-- Datos del personaje
----------------------------------------------------------------------
local function CharKey()
    local name = UnitName and UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    return name .. "-" .. realm
end

local function LoadChar()
    local chars = Data().chars
    local key = CharKey()
    chars[key] = chars[key] or {}
    CH = chars[key]
    CH.weeks = CH.weeks or {}
    CH.days = CH.days or {}
    CH.matches = CH.matches or {}
    PruneDays()
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
mod = Hub:Register{
    key = "honor", dir = "Honor", name = "Honor y rango",
    desc = "Tu rango PvP, los puntos que ganas por dia y por semana, de donde vienen y cuando llegaras al siguiente rango.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosHonorDB",
    slash = { "honor", "cmhonor" },

    Init = function(m)
        DB = m.db
        -- los datos por personaje del addon suelto (db.chars) pasan a la base del Hub
        if type(DB.chars) == "table" then
            local chars = Data().chars
            for k, v in pairs(DB.chars) do if chars[k] == nil then chars[k] = v end end
            DB.chars = nil
        end
        DB.minimap = nil
    end,

    Enable = function(m)
        DB = m.db
        LoadChar()
        local function Any() Soon(0.5) end
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "UPDATE_FACTION", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
            "CURRENCY_DISPLAY_UPDATE", "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED" }) do
            -- algunos eventos pueden no existir en el cliente
            if pcall(m.evf.RegisterEvent, m.evf, e) then m.events[e] = Any else m.events[e] = nil end
        end
        m:Event("PVP_MATCH_ACTIVE", function()
            match = nil
            EnsureMatch()
            Soon(0.5)
        end)
        m:Event("PVP_MATCH_COMPLETE", function(_, _, _, duration)
            Soon(0.5)
            if C_Timer and C_Timer.After then
                C_Timer.After(5, function() Process() end)
                C_Timer.After(12, function() Process(); FinishMatch(duration) end)
            else
                Process(); FinishMatch(duration)
            end
        end)
        m:Event("QUEST_TURNED_IN", function()
            lastQuest = GetTime and GetTime() or 0
            Soon(1)
        end)
        -- Red de seguridad: lectura periodica por si algun evento no llega.
        local acc = 0
        m:OnUpdate(function(_, dt)
            acc = acc + (dt or 0)
            if acc >= (DB.readEvery or 60) then acc = 0; Process() end
        end)
        SyncBar()
        Process()
    end,

    Disable = function(m)
        match = nil
        pendingProcess = nil
        if ui.win then ui.win:Hide() end
        if ui.barFrame then ui.barFrame:Hide() end
    end,

    OnReset = function(m)
        DB = m.db
        DB.chars = nil; DB.minimap = nil
        if ui.win then ui.win:SetScale((DB.scale or 100) / 100) end
        ApplyBarPos(); ApplyBarLook(); SyncBar()
        ui.Refresh()
    end,

    BuildConfig = function(m, L)
        DB = m.db
        L:Header("Objetivo")
        L:Slider("Objetivo semanal (0 = hasta el siguiente rango)", 0, 6000, 50,
            function() return DB.goal or 0 end,
            function(v) DB.goal = v; ui.Refresh() end)

        L:Header("Barra en pantalla")
        L:Check("Barra compacta en pantalla", function() return DB.bar end,
            function(v) DB.bar = v; SyncBar(); ui.Refresh() end)
        L:Check("Bloquear la barra (no se arrastra)", function() return DB.barLocked end, function(v) DB.barLocked = v end)
        L:Check("Mostrar la ganancia de la semana en la barra", function() return DB.barShowWeek end,
            function(v) DB.barShowWeek = v; ui.Refresh() end)
        L:Slider("Tamano de la barra (%)", 50, 200, 5, function() return DB.barScale end,
            function(v) DB.barScale = v; ApplyBarLook() end, "%d%%")
        L:Slider("Opacidad de la barra (%)", 20, 100, 5, function() return DB.barAlpha end,
            function(v) DB.barAlpha = v; ApplyBarLook() end, "%d%%")
        L:Button("Restablecer posicion de la barra", 230, function()
            DB.barPos = nil; ApplyBarPos()
        end)

        L:Header("Que muestra el panel")
        L:Check("De donde vienen los puntos", function() return DB.showSources end,
            function(v) DB.showSources = v; ui.Refresh() end)
        L:Check("Grafico de las ultimas semanas", function() return DB.showChart end,
            function(v) DB.showChart = v; ui.Refresh() end)
        L:Check("Mejores partidas (puntos por hora)", function() return DB.showBest end,
            function(v) DB.showBest = v; ui.Refresh() end)
        L:Slider("Tamano de la ventana (%)", 70, 130, 5, function() return DB.scale end,
            function(v) DB.scale = v; if ui.win then ui.win:SetScale(v / 100) end end, "%d%%")
        L:Color("Color de la barra de rango", function() return unpack(DB.colRank) end,
            function(r, g, b) DB.colRank = { r, g, b }; ui.Refresh() end)
        L:Color("Color de la semana y del grafico", function() return unpack(DB.colWeek) end,
            function(r, g, b) DB.colWeek = { r, g, b }; ui.Refresh() end)

        L:Header("Lectura de datos")
        L:Slider("Lectura de seguridad cada (segundos)", 15, 300, 15,
            function() return DB.readEvery end, function(v) DB.readEvery = v end)
        L:Slider("Partida minima para contar puntos/hora (seg)", 30, 600, 30,
            function() return DB.minMatchDur end, function(v) DB.minMatchDur = v end)
        L:Text("El reinicio semanal se lee del cliente. Solo si no lo da se usan estos valores de respaldo (hora local del equipo).", true)
        L:Slider("Dia de reinicio (0 = domingo)", 0, 6, 1, function() return DB.resetDay end, function(v) DB.resetDay = v end)
        L:Slider("Hora de reinicio", 0, 23, 1, function() return DB.resetHour end, function(v) DB.resetHour = v end)

        L:Header("Panel e historial")
        L:Button("Abrir el panel", 140, function() ui.Open(true) end)
        L:Button("Copiar al chat", 140, function() ui.Export() end, true)
        L:Button("Borrar mi historial de honor", 220, function() StaticPopup_Show("CERVECEROSMENDIGOSPVP_HONOR_BORRAR") end, true)
        L:Button("Anadir datos de prueba", 180, function() AddFakes(); ui.Refresh() end)
        L:Button("Quitar datos de prueba", 180, function() Print("entradas de prueba borradas: " .. RemoveFakes()); ui.Refresh() end, true)
    end,

    OnSlash = function(m, msg)
        DB = m.db
        msg = (msg or ""):lower()
        local cmd, arg = msg:match("^(%S*)%s*(.-)$")
        if cmd == "" or cmd == "abrir" then
            ui.Open()
        elseif cmd == "config" then
            Hub:Open("honor")
        elseif cmd == "barra" then
            ui.ToggleBar()
        elseif cmd == "bloquear" then
            DB.barLocked = not DB.barLocked
            Print(DB.barLocked and "barra bloqueada" or "barra desbloqueada (arrastrala)")
        elseif cmd == "objetivo" then
            local n = tonumber(arg)
            if n and n >= 0 and n <= 100000 then
                DB.goal = math.floor(n); Print(n == 0 and "objetivo: hasta el siguiente rango" or ("objetivo semanal: " .. DB.goal .. " puntos"))
                ui.Refresh()
            else
                Print("uso: /honor objetivo <puntos>   (0 = hasta el siguiente rango; ahora: " .. (DB.goal or 0) .. ")")
            end
        elseif cmd == "reinicio" then
            local d, h = arg:match("^(%d+)%s+(%d+)$")
            d, h = tonumber(d), tonumber(h)
            if d and h and d >= 0 and d <= 6 and h >= 0 and h <= 23 then
                DB.resetDay, DB.resetHour = d, h
                Print("reinicio de respaldo: dia " .. d .. ", hora " .. h)
            else
                Print("uso: /honor reinicio <dia 0-6 (0=domingo)> <hora 0-23>   (solo si el cliente no da el reinicio)")
            end
        elseif cmd == "estado" or cmd == "resumen" then
            ui.Export()
        elseif cmd == "diag" then
            local r = ReadRank()
            if not r then
                Print("diag: C_MajorFactions.GetMajorFactionProgressionInfo(" .. FACTION_ID .. ") no devuelve datos")
            else
                Print("diag: rango " .. r.rank .. ", puntos " .. r.earned .. "/" .. tostring(r.thr) .. ", total " .. tostring(r.total)
                    .. ", tope semanal rango " .. tostring(r.capLevel) .. " (" .. tostring(r.capTotal) .. ")")
            end
            local h = ReadHonor()
            Print("diag: honor " .. tostring(h) .. "; reinicio semanal del cliente: " .. tostring(select(2, WeekEnd(Now()))))
        elseif cmd == "prueba" then
            if arg == "borrar" then Print("entradas de prueba borradas: " .. RemoveFakes())
            else AddFakes(); Print("anadidas semanas y partidas de prueba. Quitalas con /honor prueba borrar") end
            ui.Refresh()
        else
            Print("comandos: /honor (abrir), config, barra, bloquear, objetivo <n>, reinicio <dia> <hora>, estado, diag, prueba [borrar]")
        end
    end,
}
