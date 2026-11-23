-- Modulo Resumen (CervecerosMendigosPvP): resumen de cada partida PvP con consejos sencillos.
-- Cliente WoW Forever (Interface 16001). Solo usa lo que el cliente deja leer a tu propio
-- personaje (eventos de tu jugador y el marcador). NO usa el registro de combate
-- (COMBAT_LOG_EVENT_UNFILTERED tiene restricciones). Todo dato ajeno pasa por issecretvalue.
local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local issecret = issecretvalue or function() return false end

local DEFAULTS = {
    auto = true,          -- abrir el resumen al terminar cada partida
    noArena = false,      -- no abrirlo solo en arenas (se guarda igualmente)
    maxHist = 30,         -- resumenes guardados
    revealDelay = 2.5,    -- segundos de espera para que llegue el marcador final
    scale = 100,          -- tamano de la ventana (%)
    trackCasts = true,    -- contar tus hechizos lanzados
    trackObjs = true,     -- apuntar mensajes del campo de batalla que te nombran
    showCasts = true,     -- seccion de hechizos y objetivos en el resumen
    showBaseline = true,  -- comparar con tus partidas anteriores
    baselineN = 10,       -- cuantas partidas anteriores comparar
    baselineMin = 3,      -- minimo de partidas para comparar
    adviceMax = 3,        -- numero maximo de consejos
    advMinDur = 120,      -- partidas mas cortas no dan consejos (segundos)
    lowHp = 30,           -- "vida baja" por debajo de este % de vida
    lowMana = 20,         -- "mana bajo" por debajo de este %
    advDeaths = 3,        -- aconsejar si moriste N veces o mas
    advDeadPct = 15,      -- ...o pasaste este % de la partida muerto
    advBelow = 30,        -- aconsejar si tu dano/curacion esta este % por debajo de la media del equipo
    advCombatBG = 30,     -- aconsejar si estuviste menos de este % del tiempo vivo en combate (campo)
    advCombatArena = 50,  -- idem en arena
    advLowHp = 25,        -- aconsejar si pasaste este % del combate con vida baja
    advLowMana = 25,      -- aconsejar si pasaste este % del combate con mana bajo
    colWin = { 0.25, 1, 0.25 },
    colLoss = { 1, 0.25, 0.25 },
    colDraw = { 1, 0.82, 0.25 },
}

local mod
local DB
local ui = {}

-- El historial vive en la base del Hub (fuera de mod.db) para que "Restaurar valores"
-- no borre tus partidas.
local function Hist()
    ns.DB.data = ns.DB.data or {}
    ns.DB.data.resumen = ns.DB.data.resumen or {}
    return ns.DB.data.resumen
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
local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function Fmt(n)
    if not n then return "sin dato" end
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 10000 then return string.format("%.0fk", n / 1000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n + 0.5))
end
local function FmtDur(s)
    if not s then return "sin dato" end
    s = math.floor(s)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
local function Pct(x)
    if not x then return "sin dato" end
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end

local RESULT_TXT = { win = "Victoria", loss = "Derrota", draw = "Empate", unk = "Sin dato" }
local KIND_TXT = { arena = "Arena", bg = "Campo de batalla", other = "Partida PvP" }

local function Hex(c)
    return string.format("|cff%02x%02x%02x", math.floor((c[1] or 1) * 255 + 0.5), math.floor((c[2] or 1) * 255 + 0.5), math.floor((c[3] or 1) * 255 + 0.5))
end
local function ResultColor(r)
    if r == "win" then return Hex(DB.colWin) elseif r == "loss" then return Hex(DB.colLoss)
    elseif r == "draw" then return Hex(DB.colDraw) end
    return "|cff999999"
end

local function Now() return GetTime and GetTime() or 0 end

----------------------------------------------------------------------
-- Seguimiento de la partida en curso (solo datos de tu personaje)
----------------------------------------------------------------------
local M            -- partida en curso
local lastDone = -100

local function NewMatch(active)
    M = {
        active = active and true or false,
        t0 = Now(),
        deaths = 0, deadT = 0, deadSince = nil,
        combatT = 0, combatSince = nil,
        combatAlive = 0, lowHpT = 0, lowManaT = 0, manaT = 0, hpSeen = false, manaSeen = false,
        casts = {}, castN = 0, castSecret = 0, ints = 0, ccs = 0,
        objs = {}, objN = 0,
    }
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then M.deadSince = M.t0 end
    if UnitAffectingCombat and UnitAffectingCombat("player") then M.combatSince = M.t0 end
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local n = SafeCall(C_Spell.GetSpellName, id)
        if Str(n) then return n end
    end
    if GetSpellInfo then
        local n = SafeCall(GetSpellInfo, id)
        if type(n) == "table" then n = n.name end
        if Str(n) then return n end
    end
    return nil
end

local function OnCast(spellID)
    if not DB.trackCasts then return end
    if not M or not M.active then return end
    if issecret(spellID) or type(spellID) ~= "number" then
        M.castSecret = M.castSecret + 1
        return
    end
    local name = SpellName(spellID) or ("#" .. spellID)
    M.casts[name] = (M.casts[name] or 0) + 1
    M.castN = M.castN + 1
    local k = CMResumenSpells and CMResumenSpells[spellID]
    if k == "int" then M.ints = M.ints + 1
    elseif k == "cc" then M.ccs = M.ccs + 1 end
end

local function OnChatObjective(msg)
    if not DB.trackObjs then return end
    if not M or not M.active then return end
    msg = Str(msg)
    local me = UnitName and UnitName("player")
    if not msg or not me then return end
    if msg:find(me, 1, true) then
        M.objN = M.objN + 1
        if #M.objs < 8 then M.objs[#M.objs + 1] = msg end
    end
end

local function Sample()
    if not M or not M.active or M.deadSince then return end
    if not M.combatSince then return end
    M.combatAlive = M.combatAlive + 1
    local lowHp, lowMana = (DB.lowHp or 30) / 100, (DB.lowMana or 20) / 100
    local h, hm = Num(UnitHealth and UnitHealth("player")), Num(UnitHealthMax and UnitHealthMax("player"))
    if h and hm and hm > 0 then
        M.hpSeen = true
        if h / hm < lowHp then M.lowHpT = M.lowHpT + 1 end
    end
    local pt = UnitPowerType and UnitPowerType("player")
    if pt == 0 then
        local p, pm = Num(UnitPower and UnitPower("player", 0)), Num(UnitPowerMax and UnitPowerMax("player", 0))
        if p and pm and pm > 0 then
            M.manaSeen = true
            M.manaT = M.manaT + 1
            if p / pm < lowMana then M.lowManaT = M.lowManaT + 1 end
        end
    end
end

local function CloseIntervals(now)
    if M.deadSince then M.deadT = M.deadT + (now - M.deadSince); M.deadSince = nil end
    if M.combatSince then M.combatT = M.combatT + (now - M.combatSince); M.combatSince = nil end
end

local function CanInterrupt()
    if not CMResumenSpells then return false end
    local known = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsPlayerSpell or IsSpellKnown
    if not known then return nil end
    for id, k in pairs(CMResumenSpells) do
        if k == "int" and SafeCall(known, id) then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Marcador final
----------------------------------------------------------------------
local STATS = { kb = "killingBlows", hk = "honorableKills", deaths = "deaths",
                honor = "honorGained", dmg = "damageDone", heal = "healingDone" }

local function MyTeam()
    local t = Num(SafeCall(GetBattlefieldArenaFaction))
    if t then return t end
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Alliance" then return 1 elseif f == "Horde" then return 0 end
    return nil
end

local function FillScore(R)
    if not (C_PvP and C_PvP.GetScoreInfo and GetNumBattlefieldScores) then return false end
    local n = Num(SafeCall(GetNumBattlefieldScores)) or 0
    if n == 0 then return false end
    local me = UnitName and UnitName("player")
    local rows, mine = {}, nil
    for i = 1, n do
        local info = SafeCall(C_PvP.GetScoreInfo, i)
        if type(info) == "table" then
            rows[#rows + 1] = info
            if Str(info.name) and me and info.name:match("^[^-]+") == me then mine = info end
        end
    end
    if not mine and C_PvP.GetScoreInfoByPlayerGuid and UnitGUID then
        local g = UnitGUID("player")
        if g and not issecret(g) then
            local info = SafeCall(C_PvP.GetScoreInfoByPlayerGuid, g)
            if type(info) == "table" then mine = info end
        end
    end
    if not mine then return false end

    local fac = Num(mine.faction) or R.team
    R.me, R.ally, R.enemy, R.rank = {}, {}, {}, {}
    local allyV, enemyV = {}, {}
    R.nAlly, R.nEnemy = 0, 0
    for stat, field in pairs(STATS) do
        R.me[stat] = Num(mine[field])
        allyV[stat], enemyV[stat] = {}, {}
    end
    for _, info in ipairs(rows) do
        local f = Num(info.faction)
        local isAlly = (f ~= nil and fac ~= nil and f == fac)
        local isEnemy = (f ~= nil and fac ~= nil and f ~= fac)
        if isAlly then R.nAlly = R.nAlly + 1 elseif isEnemy then R.nEnemy = R.nEnemy + 1 end
        if isAlly or isEnemy then
            local dst = isAlly and allyV or enemyV
            for stat, field in pairs(STATS) do
                local v = Num(info[field])
                if v then dst[stat][#dst[stat] + 1] = v end
            end
        end
    end
    for stat in pairs(STATS) do
        local function Avg(list)
            if #list == 0 then return nil end
            local s = 0
            for _, v in ipairs(list) do s = s + v end
            return s / #list
        end
        R.ally[stat], R.enemy[stat] = Avg(allyV[stat]), Avg(enemyV[stat])
        local mv = R.me[stat]
        if mv and #allyV[stat] > 0 then
            local pos = 1
            for _, v in ipairs(allyV[stat]) do if v > mv then pos = pos + 1 end end
            R.rank[stat] = { pos, #allyV[stat] }
        end
    end
    local sp = Str(mine.talentSpec)
    if sp then R.spec = sp end
    R.scored = true
    return true
end

----------------------------------------------------------------------
-- Analisis: consejos honestos con reglas simples (umbrales configurables)
----------------------------------------------------------------------
local function Metric(rec, k)
    if not rec then return nil end
    if k == "deaths" then
        return (rec.me and rec.me.deaths) or rec.deaths
    end
    return (rec.me and rec.me[k]) or rec[k]
end

local function Baseline(R, idx)
    local list = {}
    local maxN = DB.baselineN or 10
    local function Take(src)
        for _, e in ipairs(src) do
            if #list >= maxN then break end
            if e ~= R and not e.fake and math.abs((e.t or 0) - (R.t or 0)) > 120 then list[#list + 1] = e end
        end
    end
    local older = {}
    for i, e in ipairs(Hist()) do
        if not idx or i > idx then older[#older + 1] = e end
    end
    Take(older)
    local src = "propias"
    local need = DB.baselineMin or 3
    if #list < need then
        -- opcional: el historial del modulo Combates, si esta activado
        local cm = Hub:GetModule("combates")
        if cm and cm:IsEnabled() and cm.GetLog then
            local log = cm.GetLog()
            if type(log) == "table" then
                list = {}
                Take(log)
                src = "del historial de Combates"
            end
        end
    end
    if #list < need then return nil end
    return list, src
end

local function Advice(R)
    local t = {}
    local function Add(score, text) t[#t + 1] = { score = score, text = text } end
    local dur = R.dur
    local longEnough = dur and dur >= (DB.advMinDur or 120)

    -- Muertes
    if R.deaths and R.deaths >= 1 then
        local pct = R.deadPct
        if R.deaths >= (DB.advDeaths or 3) or (pct and pct >= (DB.advDeadPct or 15) / 100) then
            local txt = "Moriste " .. R.deaths .. (R.deaths == 1 and " vez" or " veces")
            if pct then txt = txt .. " y pasaste el " .. Pct(pct) .. " de la partida muerto" end
            txt = txt .. ". Usa defensivos antes y evita entrar solo."
            Add(R.deaths * 10 + (pct or 0) * 100, txt)
        end
    end

    -- Dano o curacion frente a tu equipo (curador si curas mas de lo que haces de dano)
    local me = R.me
    if me and R.nAlly and R.nAlly >= 3 then
        local role
        if me.dmg and me.heal then role = (me.heal > me.dmg) and "heal" or "dmg" end
        local mv, av = role and me[role], role and R.ally and R.ally[role]
        local lim = 1 - (DB.advBelow or 30) / 100
        if mv and av and av > 0 and mv < av * lim then
            local below = math.floor((1 - mv / av) * 100 + 0.5)
            Add(below, string.format("Tu %s esta un %d%% por debajo de la media de tu equipo.",
                role == "heal" and "curacion" or "dano", below))
        end
    end

    -- Interrupciones
    if R.canInt and R.ints == 0 and R.castN and R.castN > 0 and dur and dur >= 180 then
        Add(40, "No usaste ninguna interrupcion aunque tu clase tiene. Cortar un casteo clave puede decidir un combate.")
    end

    -- Tiempo en combate
    if R.combatPct and dur and dur >= 240 then
        local lim = ((R.kind == "arena") and (DB.advCombatArena or 50) or (DB.advCombatBG or 30)) / 100
        if R.combatPct < lim then
            Add(35 + (lim - R.combatPct) * 50, "Solo estuviste en combate el " .. Pct(R.combatPct) ..
                " del tiempo que seguiste vivo. Ve antes hacia la accion o los objetivos.")
        end
    end

    -- Vida / mana bajos
    if R.lowHpPct and R.lowHpPct >= (DB.advLowHp or 25) / 100 then
        Add(30 + R.lowHpPct * 20, "Pasaste el " .. Pct(R.lowHpPct) .. " del combate con menos del " .. (DB.lowHp or 30) .. "% de vida. Piensa en retirarte o usar un defensivo antes.")
    end
    if R.lowManaPct and R.lowManaPct >= (DB.advLowMana or 25) / 100 then
        Add(28 + R.lowManaPct * 20, "Pasaste el " .. Pct(R.lowManaPct) .. " del combate con menos del " .. (DB.lowMana or 20) .. "% de mana. Administra mejor el mana o usa pociones.")
    end

    table.sort(t, function(a, b) return a.score > b.score end)
    local out = {}
    for i = 1, math.min(DB.adviceMax or 3, #t) do out[i] = t[i].text end
    if #out == 0 then
        if longEnough then
            out[1] = "No veo fallos claros en lo que puedo medir. Buena partida."
        else
            out[1] = "Partida demasiado corta para sacar consejos fiables."
        end
    end
    return out
end

----------------------------------------------------------------------
-- Cierre de partida
----------------------------------------------------------------------
local pending, pendingUntil

local function Finalize(winner, duration)
    if not M then NewMatch(true) end
    local now = Now()
    CloseIntervals(now)
    local dur = Num(duration)
    if not dur or dur <= 0 then
        local d2 = Num(SafeCall(C_PvP and C_PvP.GetActiveMatchDuration))
        dur = (d2 and d2 > 0) and d2 or (now - M.t0)
    end
    winner = Num(winner)
    local team = MyTeam()
    local result = "unk"
    if winner ~= nil and team ~= nil then
        result = "draw"
        if winner == team then result = "win"
        elseif winner == (team + 1) % 2 then result = "loss" end
    end
    local kind = "other"
    if C_PvP then
        if SafeCall(C_PvP.IsArena) then kind = "arena"
        elseif SafeCall(C_PvP.IsBattleground) then kind = "bg" end
    end
    local map = Str(SafeCall(GetRealZoneText)) or Str(SafeCall(GetZoneText)) or "?"
    local className, classToken
    if UnitClass then
        local a, b = UnitClass("player")
        className, classToken = Str(a), Str(b)
    end

    local casts = {}
    for name, n in pairs(M.casts) do casts[#casts + 1] = { name = name, n = n } end
    table.sort(casts, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    while #casts > 8 do table.remove(casts) end

    local alive = math.max(dur - M.deadT, 1)
    local R = {
        t = time(), map = map, kind = kind, result = result, dur = dur, team = team,
        class = classToken, className = className,
        deaths = M.deaths, deadT = M.deadT,
        deadPct = dur > 0 and (M.deadT / dur) or nil,
        combatT = M.combatT,
        combatPct = (dur > 0 and M.combatT > 0) and math.min(1, M.combatT / alive) or nil,
        lowHpPct = (M.hpSeen and M.combatAlive > 0) and (M.lowHpT / M.combatAlive) or nil,
        lowManaPct = (M.manaSeen and M.manaT > 0) and (M.lowManaT / M.manaT) or nil,
        castN = M.castN, castSecret = M.castSecret, casts = casts,
        ints = M.ints, ccs = M.ccs, canInt = CanInterrupt(),
        objs = M.objs, objN = M.objN,
    }
    M = nil
    lastDone = now
    return R
end

local function AddToHistory(R)
    local h = Hist()
    table.insert(h, 1, R)
    while #h > (DB.maxHist or 30) do table.remove(h) end
end

local ShowSummary

local function OnMatchComplete(winner, duration)
    if not M and (Now() - lastDone) < 20 then return end   -- evento repetido
    local R = Finalize(winner, duration)
    AddToHistory(R)
    FillScore(R)
    pending, pendingUntil = R, Now() + 20
    if RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
    local function Retry()
        if not mod:IsEnabled() then return end
        if pending == R then
            if RequestBattlefieldScoreData then pcall(RequestBattlefieldScoreData) end
            FillScore(R)
            if ui.win and ui.win:IsShown() then ui.Refresh() end
        end
    end
    local function Reveal()
        if not mod:IsEnabled() then return end
        if pending == R then FillScore(R) end
        local autoShow = DB.auto and not (R.kind == "arena" and DB.noArena)
        if autoShow then
            ShowSummary(1)
        else
            Print("resumen de la partida guardado. Escribe /resumen para verlo.")
        end
    end
    if C_Timer and C_Timer.After then
        local d = DB.revealDelay or 2.5
        C_Timer.After(1.5, Retry)
        C_Timer.After(d, Reveal)
        C_Timer.After(math.max(6, d + 1), Retry)
        C_Timer.After(12, Retry)
        C_Timer.After(21, function() if pending == R then pending = nil end end)
    else
        Reveal()
    end
end

local function OnScoreUpdate()
    if not pending then return end
    if pendingUntil and Now() > pendingUntil then pending = nil; return end
    if FillScore(pending) and ui.win and ui.win:IsShown() then ui.Refresh() end
end

----------------------------------------------------------------------
-- Textos del resumen
----------------------------------------------------------------------
local function RankTxt(R, stat)
    local r = R.rank and R.rank[stat]
    if not r or r[2] < 2 then return "" end
    return string.format("  (%d.\194\186 de %d)", r[1], r[2])
end

local function Cols(R)
    local c1, c2, c3, c4 = {}, {}, {}, {}
    local function Row(a, b, c, d)
        c1[#c1 + 1], c2[#c2 + 1], c3[#c3 + 1], c4[#c4 + 1] = a, b, c, d
    end
    Row("|cffffd100Dato|r", "|cffffd100Tu|r", "|cffffd100Media equipo|r", "|cffffd100Media rival|r")
    local me = R.me or {}
    local function Stat(label, stat, fmtf)
        fmtf = fmtf or Fmt
        local v = me[stat]
        if stat == "deaths" and v == nil then v = R.deaths end
        Row(label, v ~= nil and (fmtf(v) .. RankTxt(R, stat)) or "sin dato",
            R.ally and R.ally[stat] and fmtf(R.ally[stat]) or "-",
            R.enemy and R.enemy[stat] and fmtf(R.enemy[stat]) or "-")
    end
    local function One(x) return string.format("%.1f", x) end
    Row("Muertes", tostring(R.deaths or "sin dato"),
        R.ally and R.ally.deaths and One(R.ally.deaths) or "-",
        R.enemy and R.enemy.deaths and One(R.enemy.deaths) or "-")
    Row("Tiempo muerto", R.deadPct and (Pct(R.deadPct) .. " (" .. FmtDur(R.deadT) .. ")") or "sin dato", "-", "-")
    Row("Tiempo en combate", R.combatPct and (Pct(R.combatPct) .. " (" .. FmtDur(R.combatT) .. ")") or "sin dato", "-", "-")
    Row("Vida < " .. (DB.lowHp or 30) .. "% (en combate)", Pct(R.lowHpPct), "-", "-")
    Row("Mana < " .. (DB.lowMana or 20) .. "% (en combate)", R.lowManaPct and Pct(R.lowManaPct) or "no aplica", "-", "-")
    Stat("Golpes de gracia", "kb")
    Stat("Bajas de honor", "hk")
    Stat("Dano", "dmg")
    Stat("Curacion", "heal")
    Stat("Honor", "honor")
    return table.concat(c1, "\n"), table.concat(c2, "\n"), table.concat(c3, "\n"), table.concat(c4, "\n")
end

local function CastsTxt(R)
    local L = {}
    local parts = {}
    for i, c in ipairs(R.casts or {}) do
        if i > 6 then break end
        parts[#parts + 1] = c.name .. " x" .. c.n
    end
    if #parts > 0 then
        L[#L + 1] = "Hechizos mas usados: |cffffffff" .. table.concat(parts, ", ") .. "|r"
    elseif (R.castSecret or 0) > 0 then
        L[#L + 1] = "Hechizos: el cliente ocult\195\179 " .. R.castSecret .. " lanzamientos (sin dato)."
    else
        L[#L + 1] = "Hechizos: sin lanzamientos registrados."
    end
    L[#L + 1] = string.format("Interrupciones usadas: |cffffffff%d|r   Control usado: |cffffffff%d|r%s",
        R.ints or 0, R.ccs or 0, (R.castSecret or 0) > 0 and ("   (" .. R.castSecret .. " lanzamientos ocultos)") or "")
    if (R.objN or 0) > 0 then
        L[#L + 1] = "Objetivos: |cffffffff" .. R.objN .. "|r mensaje(s) del campo de batalla te nombran:"
        for _, m in ipairs(R.objs) do L[#L + 1] = "  - " .. m end
    else
        L[#L + 1] = "Objetivos: ningun mensaje del campo de batalla te nombra."
    end
    return table.concat(L, "\n")
end

local METRICS = {
    { "deaths", "Muertes", true }, { "dmg", "Dano" }, { "heal", "Curacion" },
    { "kb", "Golpes de gracia" }, { "honor", "Honor" },
}

local function BaselineTxt(R, idx)
    local list, src = Baseline(R, idx)
    if not list then return "Aun no hay al menos " .. (DB.baselineMin or 3) .. " partidas anteriores con las que comparar." end
    local L = { "Frente a tus " .. #list .. " partidas anteriores (" .. src .. "):" }
    for _, m in ipairs(METRICS) do
        local k, label, lowerBetter = m[1], m[2], m[3]
        local mine = Metric(R, k)
        local sum, n = 0, 0
        for _, e in ipairs(list) do
            local v = Metric(e, k)
            if v then sum = sum + v; n = n + 1 end
        end
        if mine and n >= 3 then
            local avg = sum / n
            local txt
            if avg > 0 then
                local d = (mine - avg) / avg * 100
                local good = (d >= 0) ~= (lowerBetter and true or false)
                txt = string.format("%s%+.0f%%|r", good and "|cff40ff40" or "|cffff6040", d)
            else
                txt = "-"
            end
            L[#L + 1] = string.format("  %s: |cffffffff%s|r (tu media %s)  %s", label,
                k == "deaths" and tostring(mine) or Fmt(mine),
                k == "deaths" and string.format("%.1f", avg) or Fmt(avg), txt)
        end
    end
    if #L == 1 then L[#L + 1] = "  sin datos del marcador en esas partidas." end
    return table.concat(L, "\n")
end

local function ChatLines(R, idx)
    local L = {}
    L[#L + 1] = string.format("%s - %s - %s - %s", RESULT_TXT[R.result] or "?", R.map or "?", KIND_TXT[R.kind] or "", FmtDur(R.dur))
    local me = R.me or {}
    L[#L + 1] = string.format("Muertes %s | Golpes de gracia %s | Dano %s | Curacion %s | Honor %s",
        tostring(me.deaths or R.deaths or "sin dato"), tostring(me.kb or "sin dato"), Fmt(me.dmg), Fmt(me.heal), Fmt(me.honor))
    L[#L + 1] = string.format("Combate %s | Muerto %s | Interrupciones %d | Control %d",
        Pct(R.combatPct), Pct(R.deadPct), R.ints or 0, R.ccs or 0)
    for i, a in ipairs(Advice(R)) do L[#L + 1] = i .. ") " .. a end
    return L
end

----------------------------------------------------------------------
-- Ventana de datos (el resumen en si)
----------------------------------------------------------------------
local function MakeButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 24)
    b:SetText(text)
    return b
end

local viewIdx   -- indice en el historial que se esta viendo (nil = prueba)
local viewRec

function ui.Refresh()
    if not ui.win or not viewRec then return end
    local R = viewRec
    ui.head:SetText(ResultColor(R.result) .. (RESULT_TXT[R.result] or "?") .. "|r  -  " .. (R.map or "?"))
    local who = (R.className or "") .. (R.spec and (" - " .. R.spec) or "")
    ui.sub:SetText(string.format("%s  -  %s  -  duracion %s  -  %s%s",
        date("%d/%m/%Y %H:%M", R.t or 0), KIND_TXT[R.kind] or "Partida PvP", FmtDur(R.dur), who,
        R.fake and "   |cffff8020(prueba)|r" or ""))
    local a, b, c, d = Cols(R)
    ui.c1:SetText(a); ui.c2:SetText(b); ui.c3:SetText(c); ui.c4:SetText(d)
    ui.casts:SetText(DB.showCasts and CastsTxt(R) or "")
    local adv = Advice(R)
    local L = {}
    for i, t in ipairs(adv) do L[#L + 1] = "|cffffd100" .. i .. ".|r " .. t end
    ui.adv:SetText(table.concat(L, "\n"))
    ui.base:SetText(DB.showBaseline and BaselineTxt(R, viewIdx) or "")
    if not R.scored then
        ui.note:SetText("|cff999999El marcador final aun no ha llegado o el cliente no lo da; los datos con \"sin dato\" pueden completarse en unos segundos.|r")
    else
        ui.note:SetText("")
    end
    local n = #Hist()
    if viewIdx then
        ui.navText:SetText(viewIdx .. " / " .. n)
        ui.prev:SetEnabled(viewIdx < n)
        ui.next:SetEnabled(viewIdx > 1)
    else
        ui.navText:SetText("prueba")
        ui.prev:SetEnabled(false); ui.next:SetEnabled(false)
    end
end

local function BuildUI()
    local win = UI.MakeWindow("CervecerosMendigosResumenWindow", "Resumen de la partida", 640, 560)
    mod:Track(win)
    ui.win = win
    win:SetScale((DB.scale or 100) / 100)

    ui.head = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.head:SetPoint("TOPLEFT", 20, -36)
    ui.sub = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.sub:SetPoint("TOPLEFT", 20, -60)

    ui.next = MakeButton(win, ">", 28, 22)
    ui.next:SetPoint("TOPRIGHT", -16, -36)
    ui.next:SetScript("OnClick", function() if viewIdx and viewIdx > 1 then ShowSummary(viewIdx - 1) end end)
    ui.prev = MakeButton(win, "<", 28, 22)
    ui.prev:SetPoint("RIGHT", ui.next, "LEFT", -4, 0)
    ui.prev:SetScript("OnClick", function() if viewIdx and viewIdx < #Hist() then ShowSummary(viewIdx + 1) end end)
    ui.navText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.navText:SetPoint("RIGHT", ui.prev, "LEFT", -8, 0)

    local function Col(x, w)
        local fs = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", x, -92)
        fs:SetWidth(w); fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
        return fs
    end
    ui.c1 = Col(20, 170)
    ui.c2 = Col(195, 190)
    ui.c3 = Col(390, 120)
    ui.c4 = Col(515, 110)

    ui.casts = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.casts:SetPoint("TOPLEFT", 20, -262)
    ui.casts:SetWidth(600); ui.casts:SetJustifyH("LEFT"); ui.casts:SetJustifyV("TOP")

    local h2 = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h2:SetPoint("TOPLEFT", 20, -338); h2:SetText("Consejos")
    ui.adv = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.adv:SetPoint("TOPLEFT", 20, -358)
    ui.adv:SetWidth(600); ui.adv:SetJustifyH("LEFT"); ui.adv:SetJustifyV("TOP")

    ui.base = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.base:SetPoint("TOPLEFT", 20, -436)
    ui.base:SetWidth(600); ui.base:SetJustifyH("LEFT"); ui.base:SetJustifyV("TOP")

    ui.note = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.note:SetPoint("BOTTOMLEFT", 20, 50)
    ui.note:SetWidth(600); ui.note:SetJustifyH("LEFT")

    local copy = MakeButton(win, "Copiar al chat", 140, 24)
    copy:SetPoint("BOTTOMLEFT", 16, 14)
    copy:SetScript("OnClick", function()
        if not viewRec then return end
        for _, l in ipairs(ChatLines(viewRec, viewIdx)) do Print(l) end
    end)
    local close = MakeButton(win, "Cerrar", 120, 24)
    close:SetPoint("BOTTOMRIGHT", -16, 14)
    close:SetScript("OnClick", function() win:Hide() end)

    win:SetScript("OnShow", function() ui.Refresh() end)
end

function ShowSummary(idx, rec)
    if not mod:IsEnabled() then return end
    if rec then
        viewIdx, viewRec = nil, rec
    else
        local R = Hist()[idx or 1]
        if not R then
            Print("todavia no hay ninguna partida guardada. Prueba /resumen prueba para ver un ejemplo.")
            return false
        end
        viewIdx, viewRec = idx or 1, R
    end
    if not ui.win then BuildUI() end
    ui.win:Show()
    ui.Refresh()
    return true
end

local function ToggleWindow()
    if ui.win and ui.win:IsShown() then ui.win:Hide(); return end
    ShowSummary(viewIdx or 1)
end

----------------------------------------------------------------------
-- Partida de ejemplo
----------------------------------------------------------------------
local function FakeRecord()
    return {
        t = time(), map = "Cuenca de Arathi", kind = "bg", result = "win", dur = 847, team = 1,
        class = "MAGE", className = "Mago", spec = "Escarcha", fake = true,
        deaths = 4, deadT = 190, deadPct = 190 / 847, combatT = 240, combatPct = 240 / 657,
        lowHpPct = 0.31, lowManaPct = 0.12,
        castN = 120, castSecret = 0,
        casts = { { name = "Rayo de Escarcha", n = 48 }, { name = "Bola de fuego", n = 22 }, { name = "Contrahechizo", n = 0 } },
        ints = 0, ccs = 3, canInt = true, objN = 1, objs = { "Dani ha asaltado la herreria." },
        me = { kb = 5, hk = 21, deaths = 4, honor = 420, dmg = 180000, heal = 3000 },
        ally = { kb = 3.2, hk = 14, deaths = 2.6, honor = 380, dmg = 260000, heal = 40000 },
        enemy = { kb = 3.0, hk = 13, deaths = 3.1, honor = 300, dmg = 240000, heal = 38000 },
        rank = { dmg = { 7, 10 }, kb = { 2, 10 } }, nAlly = 10, nEnemy = 10, scored = true,
    }
end

local function InPvpInstance()
    if not IsInInstance then return false end
    local inInst, kind = IsInInstance()
    return inInst and (kind == "pvp" or kind == "arena")
end

local function TrimHist()
    local h = Hist()
    while #h > (DB.maxHist or 30) do table.remove(h) end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
mod = Hub:Register{
    key = "resumen", dir = "Resumen", name = "Resumen de partida",
    desc = "Panel al terminar cada partida PvP: tus numeros, tu puesto en el equipo, consejos y comparacion con tus partidas anteriores.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosResumenDB",
    slash = { "resumen", "cmresumen" },

    Init = function(m)
        DB = m.db
        -- el historial del addon suelto (db.hist) pasa a la base de datos del Hub
        if type(DB.hist) == "table" then
            local h = Hist()
            if #h == 0 then for i, e in ipairs(DB.hist) do h[i] = e end end
            DB.hist = nil
        end
        DB.minimap = nil
    end,

    Enable = function(m)
        DB = m.db
        m:Event("PLAYER_ENTERING_WORLD", function()
            if not M then
                local active = C_PvP and SafeCall(C_PvP.IsMatchActive)
                if active then NewMatch(true)
                elseif InPvpInstance() then NewMatch(false) end
            elseif not InPvpInstance() and not (C_PvP and SafeCall(C_PvP.IsMatchActive)) then
                M = nil   -- saliste sin que terminara la partida
            end
        end)
        m:Event("PVP_MATCH_ACTIVE", function() if not M or not M.active then NewMatch(true) end end)
        m:Event("PVP_MATCH_COMPLETE", function(_, _, a1, a2) OnMatchComplete(a1, a2) end)
        m:Event("UPDATE_BATTLEFIELD_SCORE", function() OnScoreUpdate() end)
        m:Event("PLAYER_DEAD", function()
            if not M then return end
            local now = Now()
            M.deaths = M.deaths + 1
            M.deadSince = M.deadSince or now
            if M.combatSince then M.combatT = M.combatT + (now - M.combatSince); M.combatSince = nil end
        end)
        local function Alive()
            if not M then return end
            if M.deadSince and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
                M.deadT = M.deadT + (Now() - M.deadSince)
                M.deadSince = nil
            end
        end
        m:Event("PLAYER_ALIVE", Alive)
        m:Event("PLAYER_UNGHOST", Alive)
        m:Event("PLAYER_REGEN_DISABLED", function()
            if M and not M.deadSince then M.combatSince = M.combatSince or Now() end
        end)
        m:Event("PLAYER_REGEN_ENABLED", function()
            if M and M.combatSince then M.combatT = M.combatT + (Now() - M.combatSince); M.combatSince = nil end
        end)
        m:Event("UNIT_SPELLCAST_SUCCEEDED", function(_, _, a1, _, a3)
            if M and (a1 == "player" or issecret(a1)) then OnCast(a3) end
        end)
        local function Chat(_, _, msg) if M then OnChatObjective(msg) end end
        m:Event("CHAT_MSG_BG_SYSTEM_ALLIANCE", Chat)
        m:Event("CHAT_MSG_BG_SYSTEM_HORDE", Chat)
        m:Event("CHAT_MSG_BG_SYSTEM_NEUTRAL", Chat)
        -- solo los lanzamientos de tu jugador
        if m.evf.RegisterUnitEvent then
            m.evf:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            m.evf:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        end
        local acc = 0
        m:OnUpdate(function(_, dt)
            acc = acc + (dt or 0)
            if acc >= 1 then acc = 0; Sample() end
        end)
        -- si se activa en mitad de una partida, empieza a seguirla
        if not M then
            local active = C_PvP and SafeCall(C_PvP.IsMatchActive)
            if active then NewMatch(true) end
        end
    end,

    Disable = function(m)
        M, pending = nil, nil
        if ui.win then ui.win:Hide() end
    end,

    OnReset = function(m)
        DB = m.db
        DB.hist = nil; DB.minimap = nil
        TrimHist()
        if ui.win then ui.win:SetScale((DB.scale or 100) / 100); ui.Refresh() end
    end,

    BuildConfig = function(m, L)
        DB = m.db
        local function Redraw() if ui.win and ui.win:IsShown() then ui.Refresh() end end
        L:Header("Cuando aparece")
        L:Check("Abrir el resumen automaticamente al terminar cada partida", function() return DB.auto end, function(v) DB.auto = v end)
        L:Check("No abrirlo solo en arenas (se guarda igualmente)", function() return DB.noArena end, function(v) DB.noArena = v end)
        L:Slider("Espera para que llegue el marcador final (seg)", 1, 8, 0.5,
            function() return DB.revealDelay end, function(v) DB.revealDelay = v end, "%.1f")

        L:Header("Que se mide")
        L:Check("Contar los hechizos que lanzas (interrupciones y control)", function() return DB.trackCasts end, function(v) DB.trackCasts = v end)
        L:Check("Apuntar los mensajes del campo de batalla que te nombran", function() return DB.trackObjs end, function(v) DB.trackObjs = v end)
        L:Slider("Vida baja por debajo de (%)", 10, 60, 5,
            function() return DB.lowHp end, function(v) DB.lowHp = v; Redraw() end, "%d%%")
        L:Slider("Mana bajo por debajo de (%)", 5, 50, 5,
            function() return DB.lowMana end, function(v) DB.lowMana = v; Redraw() end, "%d%%")

        L:Header("Que muestra el resumen")
        L:Check("Seccion de hechizos y objetivos", function() return DB.showCasts end, function(v) DB.showCasts = v; Redraw() end)
        L:Check("Comparacion con tus partidas anteriores", function() return DB.showBaseline end, function(v) DB.showBaseline = v; Redraw() end)
        L:Slider("Partidas anteriores a comparar", 3, 30, 1,
            function() return DB.baselineN end, function(v) DB.baselineN = v; Redraw() end)
        L:Slider("Minimo de partidas para comparar", 1, 10, 1,
            function() return DB.baselineMin end, function(v) DB.baselineMin = v; Redraw() end)
        L:Slider("Resumenes guardados", 5, 100, 5,
            function() return DB.maxHist end, function(v) DB.maxHist = v; TrimHist() end)
        L:Slider("Tamano de la ventana (%)", 70, 130, 5,
            function() return DB.scale end, function(v) DB.scale = v; if ui.win then ui.win:SetScale(v / 100) end end, "%d%%")
        L:Color("Color de las victorias", function() return unpack(DB.colWin) end,
            function(r, g, b) DB.colWin = { r, g, b }; Redraw() end)
        L:Color("Color de las derrotas", function() return unpack(DB.colLoss) end,
            function(r, g, b) DB.colLoss = { r, g, b }; Redraw() end)
        L:Color("Color de los empates", function() return unpack(DB.colDraw) end,
            function(r, g, b) DB.colDraw = { r, g, b }; Redraw() end)

        L:Header("Consejos")
        L:Slider("Numero maximo de consejos", 1, 5, 1,
            function() return DB.adviceMax end, function(v) DB.adviceMax = v; Redraw() end)
        L:Slider("Sin consejos si la partida dura menos de (seg)", 30, 600, 30,
            function() return DB.advMinDur end, function(v) DB.advMinDur = v; Redraw() end)
        L:Slider("Avisar si mueres N veces o mas", 1, 10, 1,
            function() return DB.advDeaths end, function(v) DB.advDeaths = v; Redraw() end)
        L:Slider("...o pasas este % de la partida muerto", 5, 50, 5,
            function() return DB.advDeadPct end, function(v) DB.advDeadPct = v; Redraw() end, "%d%%")
        L:Slider("Dano/curacion por debajo de la media del equipo (%)", 10, 70, 5,
            function() return DB.advBelow end, function(v) DB.advBelow = v; Redraw() end, "%d%%")
        L:Slider("Poco combate en campo de batalla: menos de (%)", 10, 80, 5,
            function() return DB.advCombatBG end, function(v) DB.advCombatBG = v; Redraw() end, "%d%%")
        L:Slider("Poco combate en arena: menos de (%)", 10, 90, 5,
            function() return DB.advCombatArena end, function(v) DB.advCombatArena = v; Redraw() end, "%d%%")
        L:Slider("Mucho tiempo con vida baja: a partir de (%)", 10, 80, 5,
            function() return DB.advLowHp end, function(v) DB.advLowHp = v; Redraw() end, "%d%%")
        L:Slider("Mucho tiempo con mana bajo: a partir de (%)", 10, 80, 5,
            function() return DB.advLowMana end, function(v) DB.advLowMana = v; Redraw() end, "%d%%")

        L:Header("Resumenes")
        L:Button("Ver el ultimo resumen", 170, function() ShowSummary(1) end)
        L:Button("Ver un ejemplo", 140, function() ShowSummary(nil, FakeRecord()) end, true)
        L:Button("Borrar resumenes guardados", 200, function()
            wipe(Hist()); viewIdx, viewRec = nil, nil
            if ui.win then ui.win:Hide() end
            Print("historial de resumenes borrado")
        end, true)
    end,

    OnSlash = function(m, msg)
        DB = m.db
        msg = (msg or ""):lower()
        local cmd = msg:match("^(%S*)")
        if cmd == "" or cmd == "abrir" then
            ToggleWindow()
        elseif cmd == "config" then
            Hub:Open("resumen")
        elseif cmd == "ultimo" then
            ShowSummary(1)
        elseif cmd == "auto" then
            DB.auto = not DB.auto
            Print(DB.auto and "se abrira el resumen al terminar cada partida" or "el resumen ya no se abre solo (usa /resumen)")
        elseif cmd == "arena" then
            DB.noArena = not DB.noArena
            Print(DB.noArena and "no se abrira solo en arenas" or "tambien se abrira solo en arenas")
        elseif cmd == "copiar" then
            local R = Hist()[1]
            if not R then Print("no hay partidas guardadas"); return end
            for _, l in ipairs(ChatLines(R, 1)) do Print(l) end
        elseif cmd == "prueba" then
            ShowSummary(nil, FakeRecord())
        elseif cmd == "borrar" then
            wipe(Hist())
            viewIdx, viewRec = nil, nil
            if ui.win then ui.win:Hide() end
            Print("historial de resumenes borrado")
        elseif cmd == "estado" then
            Print(string.format("partida en curso: %s | guardadas: %d | auto: %s | no arena: %s",
                M and (M.active and "si" or "preparacion") or "no", #Hist(), tostring(DB.auto), tostring(DB.noArena)))
            if M then
                Print(string.format("muertes %d | combate %.0fs | lanzamientos %d (ocultos %d)", M.deaths, M.combatT + (M.combatSince and (Now() - M.combatSince) or 0), M.castN, M.castSecret))
            end
        else
            Print("comandos: /resumen (abrir), config, ultimo, auto, arena, copiar, prueba, borrar, estado")
        end
    end,
}
