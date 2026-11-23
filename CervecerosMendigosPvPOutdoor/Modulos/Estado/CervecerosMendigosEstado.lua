-- CervecerosMendigosEstado para WoW Forever (cliente moderno, Interface 16001).
-- Avisa de TU propio estado en PvP: vida baja, mana (o recurso) bajo y perdida de control
-- (aturdido, asustado, silenciado, desarmado, enraizado, incapacitado, polimorfado).
-- Aviso visual (pulso en los bordes + texto grande) y de voz (español / ingles / sonido del juego).
-- Los valores "secretos" del cliente nunca se comparan: si la vida es secreta, el pulso sigue
-- funcionando con una curva (SetAlpha admite secretos) y la voz/texto se omiten; /estado diag lo dice.
-- Configuracion: boton del minimapa, o /estado

local ADDON, ns = ...
local Hub = ns.Hub
local mod            -- se asigna en Register
local unpack = table.unpack or unpack

local DEFAULTS = {
    always = false,      -- true: avisar tambien fuera de PvP
    hpOn = true,
    hpWarn = 35,         -- % de vida: aviso
    hpCrit = 20,         -- % de vida: aviso critico
    powOn = true,
    powWarn = 20,        -- % de recurso: aviso
    powOther = false,    -- avisar tambien con recursos distintos del mana
    rearm = 10,          -- puntos por encima del umbral para rearmar el aviso
    locOn = true,
    locTypes = { aturdido = true, asustado = true, silenciado = true, desarmado = true,
                 enraizado = true, incapacitado = true, polimorfado = true, sin_control = true },
    locBar = true,       -- barra de tiempo de la perdida de control
    vis = true,          -- pulso en los bordes
    visIntensity = 70,   -- % de intensidad del pulso
    visDuration = 1.5,   -- segundos de pulso al saltar un aviso
    text = true,         -- texto grande central
    textScale = 100,
    textSeconds = 1.5,   -- segundos minimos que se ve el texto grande
    sound = true,        -- voz / sonido
    voiceOn = { hp = true, pow = true, loc = true },   -- que avisos hablan
    voice = "es",        -- "es" | "en" | "game"
    channel = "Master",  -- canal de sonido: Master | Dialog | SFX
    volume = 100,        -- volumen de las voces (0-100): se aplica al canal mientras suena la voz
    boost = true,        -- subir el canal si esta por debajo del volumen elegido
    cooldown = 3,        -- segundos minimos entre avisos del mismo tipo
    locked = true,
    colHp = { 1.0, 0.45, 0.10 },
    colCrit = { 1.0, 0.10, 0.10 },
    colPow = { 0.30, 0.55, 1.0 },
    colLoc = { 1.0, 0.62, 0.10 },
    pos = { point = "CENTER", x = 0, y = 170 },
}

-- locType del cliente -> clave de voz
local LOCMAP = {
    STUN = "aturdido", STUN_MECHANIC = "aturdido",
    FEAR = "asustado", FEAR_MECHANIC = "asustado", HORROR = "asustado",
    SILENCE = "silenciado", PACIFYSILENCE = "silenciado", SCHOOL_INTERRUPT = "silenciado",
    DISARM = "desarmado",
    ROOT = "enraizado",
    CONFUSE = "incapacitado", DISORIENT = "incapacitado", INCAPACITATE = "incapacitado",
    PACIFY = "incapacitado", SLEEP = "incapacitado", FREEZE = "incapacitado",
    CHARM = "sin_control", POSSESS = "sin_control",
}

-- polimorfia y maleficio (ids sacados de la tabla de voces de PvpOutdoor)
local POLY = {}
for _, id in ipairs({ 118, 11641, 12824, 12825, 12826, 13323, 14621, 15534, 16097, 16707, 16708, 16709, 17172,
    18503, 22566, 24053, 27760, 28271, 28272, 29124, 29848, 434754, 450600, 457326, 1236174, 1236290,
    1283409, 1320379, 1324187, 1324188, 1324189 }) do POLY[id] = true end

local KINDS = {
    vida_baja    = { text = "¡VIDA BAJA!",    grp = "hp" },
    vida_critica = { text = "¡VIDA CRÍTICA!", grp = "hp" },
    mana_bajo    = { text = "¡MANÁ BAJO!",    grp = "pow" },
    recurso_bajo = { text = "¡RECURSO BAJO!", grp = "pow", noVoice = true },
    aturdido     = { text = "¡ATURDIDO!",     grp = "loc", loc = true },
    asustado     = { text = "¡ASUSTADO!",     grp = "loc", loc = true },
    silenciado   = { text = "¡SILENCIADO!",   grp = "loc", loc = true },
    desarmado    = { text = "¡DESARMADO!",    grp = "loc", loc = true },
    enraizado    = { text = "¡ENRAIZADO!",    grp = "loc", loc = true },
    incapacitado = { text = "¡INCAPACITADO!", grp = "loc", loc = true },
    polimorfado  = { text = "¡POLIMORFADO!",  grp = "loc", loc = true },
    sin_control  = { text = "¡SIN CONTROL!",  grp = "loc", loc = true },
}

local DB
local Refresh -- se define mas abajo

local function LocColor() return DB.colLoc end
local function KindColor(key)
    if key == "vida_baja" then return DB.colHp
    elseif key == "vida_critica" then return DB.colCrit
    elseif KINDS[key] and KINDS[key].grp == "pow" then return DB.colPow end
    return DB.colLoc
end
local lvl = { hp = 0, pow = 0 }
local diag = { hp = "?", hpPct = nil, pow = "?", powName = "?", ctx = false, locApi = false }
local last = {}

local function Print(msg) if mod then mod:Print(msg) end end

----------------------------------------------------------------------
-- Valores secretos: nunca se comparan ni se operan
----------------------------------------------------------------------
local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function SafeNum(v)
    if IsSecret(v) then return nil end
    if type(v) == "number" then return v end
    return nil
end

local function Clamp01(x)
    if x < 0 then return 0 elseif x > 1 then return 1 end
    return x
end

-- Devuelve fraccion 0..1 y el modo de lectura: "num", "pct", "secret" o "nodata".
local function ReadFrac(kind, ptype)
    local cur, max
    if kind == "hp" then
        local ok1, a = pcall(UnitHealth, "player")
        local ok2, b = pcall(UnitHealthMax, "player")
        if ok1 and ok2 then cur, max = SafeNum(a), SafeNum(b) end
    else
        local ok1, a = pcall(UnitPower, "player", ptype)
        local ok2, b = pcall(UnitPowerMax, "player", ptype)
        if ok1 and ok2 then cur, max = SafeNum(a), SafeNum(b) end
    end
    if cur and max and max > 0 then return Clamp01(cur / max), "num" end

    local ok, p
    if kind == "hp" and UnitHealthPercent then
        ok, p = pcall(UnitHealthPercent, "player", true)
    elseif kind ~= "hp" and UnitPowerPercent then
        ok, p = pcall(UnitPowerPercent, "player", ptype, false)
    end
    if ok then
        if IsSecret(p) then return nil, "secret" end
        if type(p) == "number" then
            if p > 1.0001 then p = p / 100 end
            return Clamp01(p), "pct"
        end
    end
    return nil, "nodata"
end

----------------------------------------------------------------------
-- Contexto: solo en PvP salvo que se pida "siempre"
----------------------------------------------------------------------
local function InPvP()
    if IsInInstance then
        local ok, _, itype = pcall(IsInInstance)
        if ok and (itype == "pvp" or itype == "arena") then return true end
    end
    if C_PvP and C_PvP.IsPVPMap then
        local ok, r = pcall(C_PvP.IsPVPMap)
        if ok and r == true then return true end
    end
    if UnitIsPVP and UnitIsPVP("player") and UnitAffectingCombat and UnitAffectingCombat("player") then
        return true
    end
    return false
end

local function Allowed()
    if not DB or not mod or not mod.enabled then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    local ctx = DB.always or InPvP()
    diag.ctx = ctx
    return ctx
end

----------------------------------------------------------------------
-- Sonido / voz
----------------------------------------------------------------------
local function Speak(key)
    if not DB.sound then return end
    local k = KINDS[key]
    if k and k.grp and DB.voiceOn[k.grp] == false then return end
    if DB.voice == "game" or (k and k.noVoice) then
        local id = SOUNDKIT and (SOUNDKIT.RAID_WARNING or SOUNDKIT.ALARM_CLOCK_WARNING_3) or 8959
        local Vol = ns.PO_Vol
        local ch = DB.channel or "Master"
        if Vol then ch = Vol.Apply(ch, DB.volume, DB.boost, 2) end
        pcall(PlaySound, id, ch)
        return
    end
    local file = mod.path .. "sounds\\" .. DB.voice .. "\\" .. key .. ".ogg"
    local dur = CMEstadoDur and CMEstadoDur[DB.voice] and CMEstadoDur[DB.voice][key]
    local Vol = ns.PO_Vol
    if Vol then pcall(Vol.Play, file, DB.channel or "Master", DB.volume, DB.boost, dur)
    else pcall(PlaySoundFile, file, DB.channel or "Master") end
end

local function Cooldown(key)
    local t = GetTime()
    if last[key] and (t - last[key]) < (DB.cooldown or 0) then return false end
    last[key] = t
    return true
end

----------------------------------------------------------------------
-- Aviso visual: pulso en los bordes y texto central
----------------------------------------------------------------------
local edge, holder, alertText, loc

local function CreateEdge()
    edge = mod:Frame("Frame", "CMEstadoBordes", UIParent)
    edge:SetAllPoints(UIParent)
    edge:SetFrameStrata("BACKGROUND")
    edge:EnableMouse(false)
    edge.tex = edge:CreateTexture(nil, "BACKGROUND")
    edge.tex:SetAllPoints()
    edge.tex:SetTexture(mod.path .. "vignette.tga")
    edge:SetAlpha(0)
    edge:Hide()
    edge:SetScript("OnUpdate", function(self)
        local now = GetTime()
        local pulse = 0.65 + 0.35 * math.sin(now * 7)
        if self.secret then self:SetAlpha(pulse); return end
        if self.flashEnd then
            if now < self.flashEnd then
                local left = (self.flashEnd - now) / self.flashDur
                self:SetAlpha((DB.visIntensity / 100) * pulse * math.min(1, left * 2))
            else
                self.flashEnd = nil
                self:SetAlpha(0)
                self:Hide()
            end
        end
    end)
end

local function Flash(color)
    if not DB.vis or not edge then return end
    local dur = DB.visDuration or 1.5
    edge.secret = false
    edge.tex:SetAlpha(1)
    edge.tex:SetVertexColor(color[1], color[2], color[3])
    edge.flashDur = dur
    edge.flashEnd = GetTime() + dur
    edge:Show()
end

-- curva alfa(vida): con vida secreta no se puede comparar, pero SetAlpha acepta el resultado
local hpCurve
local function BuildHpCurve()
    hpCurve = nil
    if not (C_CurveUtil and C_CurveUtil.CreateCurve) then return end
    local ok, c = pcall(C_CurveUtil.CreateCurve)
    if not ok or not c then return end
    local I = (DB.visIntensity or 70) / 100
    local w = DB.hpWarn / 100
    local k = DB.hpCrit / 100
    pcall(function() c:SetType(Enum.LuaCurveType.Linear) end)
    c:AddPoint(0, I)
    c:AddPoint(k, I)
    c:AddPoint(w, I * 0.35)
    c:AddPoint(math.min(0.99, w + 0.02), 0)
    c:AddPoint(1, 0)
    hpCurve = c
end

local function UpdateSecretGlow(active)
    if not edge then return end
    if active and hpCurve and UnitHealthPercent and DB.vis and DB.hpOn then
        local ok, a = pcall(UnitHealthPercent, "player", true, hpCurve)
        if ok then
            edge.secret = true
            edge.flashEnd = nil
            edge.tex:SetVertexColor(1, 0.1, 0.1)
            pcall(edge.tex.SetAlpha, edge.tex, a)
            edge:Show()
            return
        end
    end
    if edge.secret then
        edge.secret = false
        edge.tex:SetAlpha(1)
        edge:SetAlpha(0)
        edge:Hide()
    end
end

local function SavePos()
    local point, _, _, x, y = holder:GetPoint()
    DB.pos.point, DB.pos.x, DB.pos.y = point or "CENTER", x or 0, y or 0
end

local function ApplyHolderPos()
    holder:ClearAllPoints()
    holder:SetPoint(DB.pos.point or "CENTER", UIParent, DB.pos.point or "CENTER", DB.pos.x or 0, DB.pos.y or 170)
end

local function CreateHolder()
    holder = mod:Frame("Frame", "CMEstadoTexto", UIParent)
    holder:SetSize(420, 140)
    holder:SetFrameStrata("HIGH")
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)
    holder:RegisterForDrag("LeftButton")
    holder:SetScript("OnDragStart", function(self) if not DB.locked then self:StartMoving() end end)
    holder:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)

    alertText = holder:CreateFontString(nil, "OVERLAY")
    alertText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 38, "THICKOUTLINE")
    alertText:SetPoint("TOP", holder, "TOP", 0, 0)
    alertText:SetText("")

    holder.hint = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    holder.hint:SetPoint("BOTTOM", holder, "BOTTOM", 0, 0)
    holder.hint:SetText("")

    holder:SetScript("OnUpdate", function(self)
        if self.textEnd then
            local now = GetTime()
            if now >= self.textEnd then
                self.textEnd = nil
                alertText:SetText("")
            elseif self.textEnd - now < 0.5 then
                alertText:SetAlpha((self.textEnd - now) / 0.5)
            end
        end
    end)
    ApplyHolderPos()
    holder:SetScale((DB.textScale or 100) / 100)
    holder:EnableMouse(not DB.locked)
    holder:Show()
end

local function ShowText(text, color)
    if not DB.text or not alertText then return end
    alertText:SetText(text)
    alertText:SetTextColor(color[1], color[2], color[3])
    alertText:SetAlpha(1)
    holder.textEnd = GetTime() + math.max(0.5, DB.textSeconds or 1.5)
end

local function CreateLoc()
    loc = CreateFrame("Frame", "CMEstadoControl", holder)
    loc:SetSize(330, 60)
    loc:SetPoint("TOP", holder, "TOP", 0, -52)
    loc.icon = loc:CreateTexture(nil, "ARTWORK")
    loc.icon:SetSize(44, 44)
    loc.icon:SetPoint("LEFT", 0, 0)
    loc.icon:SetTexture("Interface\\Icons\\Spell_Frost_Stun")
    loc.name = loc:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    loc.name:SetPoint("TOPLEFT", loc.icon, "TOPRIGHT", 8, 0)
    loc.name:SetTextColor(unpack(LocColor()))
    loc.time = loc:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    loc.time:SetPoint("TOPRIGHT", loc, "TOPRIGHT", 0, 0)
    loc.bar = CreateFrame("StatusBar", nil, loc)
    loc.bar:SetSize(270, 12)
    loc.bar:SetPoint("BOTTOMLEFT", loc.icon, "BOTTOMRIGHT", 8, 2)
    loc.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    loc.bar:SetStatusBarColor(unpack(LocColor()))
    loc.bar:SetMinMaxValues(0, 1)
    loc.bar:SetValue(1)
    loc.bar.bg = loc.bar:CreateTexture(nil, "BACKGROUND")
    loc.bar.bg:SetAllPoints()
    loc.bar.bg:SetColorTexture(0, 0, 0, 0.55)
    loc:Hide()

    loc:SetScript("OnUpdate", function(self)
        local f = self.fake
        if f then
            local left = f.endT - GetTime()
            if left <= 0 then self.fake = nil; self:Hide(); return end
            self.time:SetText(string.format("%.1f", left))
            self.bar:SetMinMaxValues(0, f.dur)
            self.bar:SetValue(left)
            return
        end
        if not (C_LossOfControl and C_LossOfControl.GetActiveLossOfControlDataCount) then self:Hide(); return end
        local okc, count = pcall(C_LossOfControl.GetActiveLossOfControlDataCount)
        if not okc or not count or count == 0 then self:Hide(); return end
        local okd, d = pcall(C_LossOfControl.GetActiveLossOfControlData, 1)
        if not okd or not d or d.displayType == 0 then self:Hide(); return end

        if self.useText then pcall(self.name.SetText, self.name, d.displayText) end
        local tr, du = SafeNum(d.timeRemaining), SafeNum(d.duration)
        if tr then
            self.time:SetText(string.format("%.1f", tr))
            if du and du > 0 then
                self.bar:SetMinMaxValues(0, du)
                self.bar:SetValue(tr)
            end
        elseif C_LossOfControl.GetActiveLossOfControlDuration then
            -- datos secretos: la barra se alimenta con el objeto de duracion
            local okx, dur = pcall(C_LossOfControl.GetActiveLossOfControlDuration, "player", 1)
            if okx and dur then
                if self.needTimer and self.bar.SetTimerDuration then
                    local RT = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime
                    pcall(self.bar.SetTimerDuration, self.bar, dur, nil, RT)
                    self.needTimer = false
                end
                if dur.GetRemainingDuration then
                    local okf = pcall(self.time.SetFormattedText, self.time, "%.1f", dur:GetRemainingDuration())
                    if not okf then self.time:SetText("") end
                end
            end
        end
    end)
end

----------------------------------------------------------------------
-- Avisos
----------------------------------------------------------------------
-- key de KINDS; color opcional; force salta el cooldown (pruebas)
local function Alert(key, force)
    local k = KINDS[key]
    if not k then return end
    if not force and not Cooldown(key) then return end
    local color = KindColor(key)
    ShowText(k.text, color)
    Flash(color)
    Speak(key)
end

local function CheckHealth()
    if not DB.hpOn then lvl.hp = 0; UpdateSecretGlow(false); return end
    if not Allowed() then lvl.hp = 0; UpdateSecretGlow(false); return end
    local frac, mode = ReadFrac("hp")
    diag.hp, diag.hpPct = mode, frac and frac * 100 or nil
    if not frac then
        UpdateSecretGlow(mode == "secret")
        return
    end
    UpdateSecretGlow(false)
    local pct = frac * 100
    local old = lvl.hp
    local raw = (pct <= DB.hpCrit) and 2 or ((pct <= DB.hpWarn) and 1 or 0)
    local new = old
    if raw > old then
        new = raw
    else
        if old == 2 and pct > DB.hpCrit + DB.rearm then new = 1 end
        if new == 1 and pct > DB.hpWarn + DB.rearm then new = 0 end
    end
    lvl.hp = new
    if new > old then Alert(new == 2 and "vida_critica" or "vida_baja") end
end

local function CheckPower()
    if not DB.powOn or not Allowed() then lvl.pow = 0; return end
    local ok, ptype, token = pcall(UnitPowerType, "player")
    if not ok or type(ptype) ~= "number" then return end
    local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
    diag.powName = token or tostring(ptype)
    local isMana = ptype == MANA
    if not isMana and not DB.powOther then lvl.pow = 0; diag.pow = "no vigilado"; return end
    local frac, mode = ReadFrac("pow", ptype)
    diag.pow = mode
    if not frac then return end
    local pct = frac * 100
    local old = lvl.pow
    local new = old
    if pct <= DB.powWarn then new = 1
    elseif old == 1 and pct > DB.powWarn + DB.rearm then new = 0 end
    lvl.pow = new
    if new > old then Alert(isMana and "mana_bajo" or "recurso_bajo") end
end

local function ShowLoc(d, key, useText)
    local k = KINDS[key]
    loc.fake = nil
    loc.needTimer = true
    loc.useText = useText
    loc.name:SetText(k.text)
    local icon = d and d.iconTexture
    if icon and not IsSecret(icon) then loc.icon:SetTexture(icon) end
    if icon and IsSecret(icon) then pcall(loc.icon.SetTexture, loc.icon, icon) end
    loc:Show()
end

local function OnLocAdded(index)
    diag.locApi = C_LossOfControl ~= nil
    if not DB.locOn or not Allowed() then return end
    if not (C_LossOfControl and C_LossOfControl.GetActiveLossOfControlData) then return end
    local ok, d = pcall(C_LossOfControl.GetActiveLossOfControlData, index or 1)
    if not ok or not d then return end
    if d.displayType == 0 then return end -- no se muestra en la interfaz del juego

    local key
    local sid = d.spellID
    if not IsSecret(sid) and type(sid) == "number" and POLY[sid] then
        key = "polimorfado"
    else
        local lt = d.locType
        if IsSecret(lt) or type(lt) ~= "string" then key = "sin_control" else key = LOCMAP[lt] or "sin_control" end
    end
    if DB.locTypes[key] == false then return end
    local useText = (key == "sin_control") -- tipo desconocido/secreto: se intenta el texto del propio juego
    if DB.locBar then ShowLoc(d, key, useText) end
    if Cooldown("loc_" .. key) then
        local k = KINDS[key]
        ShowText(k.text, LocColor())
        Flash(LocColor())
        Speak(key)
    end
end

local function CheckAll()
    CheckHealth()
    CheckPower()
end

----------------------------------------------------------------------
-- Pruebas
----------------------------------------------------------------------
local function TestHealth() Alert("vida_critica", true) end
local function TestMana() Alert("mana_bajo", true) end
local function TestLoc()
    local keys = { "aturdido", "asustado", "silenciado", "polimorfado" }
    local key = keys[math.random(1, #keys)]
    if DB.locBar then
        loc.fake = { endT = GetTime() + 4, dur = 4 }
        loc.useText = false
        loc.name:SetText(KINDS[key].text)
        loc.icon:SetTexture("Interface\\Icons\\Spell_Frost_Stun")
        loc:Show()
    end
    ShowText(KINDS[key].text, LocColor())
    Flash(LocColor())
    Speak(key)
end

----------------------------------------------------------------------
-- Estilo, refresco
----------------------------------------------------------------------
local function ApplyStyle()
    if not DB or not holder then return end
    holder:SetScale((DB.textScale or 100) / 100)
    holder:EnableMouse(not DB.locked)
    if loc then
        loc.name:SetTextColor(unpack(LocColor()))
        loc.bar:SetStatusBarColor(unpack(LocColor()))
    end
end

Refresh = function(rebuild)
    if not DB or not holder or not mod.enabled then return end
    ApplyStyle()
    if rebuild then BuildHpCurve() end
    CheckAll()
end

local function Apply() if mod.inited then Refresh(true) end end

local function ModeText(m)
    if m == "num" then return "legible (numeros)"
    elseif m == "pct" then return "legible (porcentaje)"
    elseif m == "secret" then return "SECRETO (solo pulso, sin voz ni texto)"
    elseif m == "nodata" then return "sin dato"
    end
    return tostring(m)
end

local function NeedEnabled()
    if mod.enabled and holder then return true end
    Print("activa primero el modulo (casilla de arriba).")
    return false
end

local function SetMoving(on)
    DB.locked = not on
    if holder then
        holder.hint:SetText(on and "Arrastra para mover (/estado bloquear)" or "")
        holder:EnableMouse(on)
        if on then ShowText("¡TEXTO DE PRUEBA!", { 1, 1, 1 }); holder.textEnd = nil
        elseif alertText then alertText:SetText("") end
    end
end

----------------------------------------------------------------------
-- Configuracion (pestana)
----------------------------------------------------------------------
local function BuildConfig(m, L)
    DB = m.db
    L:Text("Te avisa de tu propio estado en PvP: vida baja, maná bajo y pérdida de control, con pulso en los bordes, texto grande y voz. Si el juego oculta tu vida (valor secreto), el pulso sigue funcionando pero no suenan la voz ni el texto: usa /estado diag para comprobarlo.", true)
    L:Check("Avisar tambien fuera de PvP", function() return DB.always end, function(v) DB.always = v; Apply() end)

    L:Header("Vida")
    L:Check("Vigilar la vida", function() return DB.hpOn end, function(v) DB.hpOn = v; Apply() end)
    L:Slider("Vida baja (%)", 5, 90, 1, function() return DB.hpWarn end,
        function(v) DB.hpWarn = v; if DB.hpCrit >= v then DB.hpCrit = math.max(1, v - 1) end; Apply() end)
    L:Slider("Vida critica (%)", 1, 60, 1, function() return DB.hpCrit end,
        function(v) if v >= DB.hpWarn then v = DB.hpWarn - 1 end DB.hpCrit = math.max(1, v); Apply() end)
    L:Color("Color del aviso de vida baja", function() return unpack(DB.colHp) end,
        function(r, g, b) DB.colHp = { r, g, b } end)
    L:Color("Color del aviso de vida critica", function() return unpack(DB.colCrit) end,
        function(r, g, b) DB.colCrit = { r, g, b } end)

    L:Header("Mana y otros recursos")
    L:Check("Vigilar el mana", function() return DB.powOn end, function(v) DB.powOn = v; Apply() end)
    L:Check("Vigilar otros recursos (energia, ira...)", function() return DB.powOther end,
        function(v) DB.powOther = v; Apply() end)
    L:Slider("Recurso bajo (%)", 5, 90, 1, function() return DB.powWarn end,
        function(v) DB.powWarn = v; Apply() end)
    L:Color("Color del aviso de recurso bajo", function() return unpack(DB.colPow) end,
        function(r, g, b) DB.colPow = { r, g, b } end)

    L:Header("Perdida de control")
    L:Check("Avisar de perdida de control", function() return DB.locOn end, function(v) DB.locOn = v end)
    L:Check("Barra con el tiempo restante", function() return DB.locBar end, function(v) DB.locBar = v end)
    L:Text("Avisar cuando me:", true)
    local LT = {
        { "aturdido", "Aturdan" }, { "asustado", "Asusten" }, { "silenciado", "Silencien" },
        { "desarmado", "Desarmen" }, { "enraizado", "Enraicen" }, { "incapacitado", "Incapaciten" },
        { "polimorfado", "Polimorfen" }, { "sin_control", "Quiten el control de otra forma" },
    }
    for _, t in ipairs(LT) do
        L:Check(t[2], function() return DB.locTypes[t[1]] ~= false end, function(v) DB.locTypes[t[1]] = v end)
    end
    L:Color("Color del aviso de perdida de control", function() return unpack(DB.colLoc) end,
        function(r, g, b) DB.colLoc = { r, g, b }; Apply() end)

    L:Header("Frecuencia")
    L:Slider("Pausa entre avisos iguales (segundos)", 0, 10, 1, function() return DB.cooldown end,
        function(v) DB.cooldown = v end, "%d s")
    L:Slider("Puntos de recuperacion para volver a avisar", 2, 40, 1, function() return DB.rearm end,
        function(v) DB.rearm = v end)

    L:Header("Aviso visual")
    L:Check("Pulso en los bordes de la pantalla", function() return DB.vis end, function(v) DB.vis = v; Apply() end)
    L:Slider("Intensidad del pulso", 10, 100, 5, function() return DB.visIntensity end,
        function(v) DB.visIntensity = v; Apply() end, "%d%%")
    L:Slider("Duracion del pulso (segundos)", 0.5, 5, 0.5, function() return DB.visDuration end,
        function(v) DB.visDuration = v end, "%.1f s")
    L:Check("Texto grande en el centro", function() return DB.text end, function(v) DB.text = v end)
    L:Slider("Tamano del texto", 50, 200, 10, function() return DB.textScale end,
        function(v) DB.textScale = v; Apply() end, "%d%%")
    L:Slider("Duracion del texto (segundos)", 0.5, 6, 0.5, function() return DB.textSeconds end,
        function(v) DB.textSeconds = v end, "%.1f s")
    local move
    move = L:Button(DB.locked and "Mover el texto" or "Fijar el texto", 160, function()
        if not NeedEnabled() then return end
        SetMoving(DB.locked)
        move:SetText(DB.locked and "Mover el texto" or "Fijar el texto")
    end)
    L:Add({ Refresh = function() move:SetText(DB.locked and "Mover el texto" or "Fijar el texto") end }, 0)

    L:Header("Sonido")
    L:Check("Voz / sonido", function() return DB.sound end, function(v) DB.sound = v end)
    L:Check("   Hablar en los avisos de vida", function() return DB.voiceOn.hp end, function(v) DB.voiceOn.hp = v end)
    L:Check("   Hablar en los avisos de recurso", function() return DB.voiceOn.pow end, function(v) DB.voiceOn.pow = v end)
    L:Check("   Hablar en los avisos de perdida de control", function() return DB.voiceOn.loc end,
        function(v) DB.voiceOn.loc = v end)
    L:Choice("Voz", { { "es", "Español" }, { "en", "English" }, { "game", "Sonido del juego" } },
        function() return DB.voice end, function(v) DB.voice = v; if mod.enabled then Speak("vida_baja") end end)
    L:Choice("Canal de sonido", { { "Master", "Maestro" }, { "Dialog", "Dialogos" }, { "SFX", "Efectos" } },
        function() return DB.channel end, function(v) DB.channel = v end)
    L:Slider("Volumen de las voces", 0, 100, 5,
        function() return DB.volume or 100 end, function(v) DB.volume = v end, "%d%%")
    L:Check("Subir el canal si esta por debajo de ese volumen",
        function() return DB.boost ~= false end, function(v) DB.boost = v end)
    L:Text("Aviso: el juego solo tiene volumen por canal, no por sonido. Mientras suena una voz se ajusta temporalmente el volumen del canal elegido arriba (afecta a todo lo que suene en ese canal durante esa voz, ~1-2 s) y despues se deja exactamente como lo tenias. Con la casilla desmarcada solo se baja, nunca se sube.", true)
    L:Button("Probar voz", 140, function() if NeedEnabled() then Speak("vida_baja") end end)

    L:Header("Pruebas")
    L:Button("Probar vida baja", 150, function() if NeedEnabled() then TestHealth() end end)
    L:Button("Probar mana", 120, function() if NeedEnabled() then TestMana() end end, true)
    L:Button("Probar perdida de control", 190, function() if NeedEnabled() then TestLoc() end end, true)
end

----------------------------------------------------------------------
-- Comandos antiguos (/estado, /cmestado)
----------------------------------------------------------------------
local function OnSlash(m, msg)
    local cmd, arg = string.match(strlower(msg or ""), "^(%S*)%s*(%S*)")
    if cmd == "" or cmd == "config" then
        Hub:Open("estado")
    elseif cmd == "diag" then
        CheckAll()
        local ctx = DB.always or InPvP()
        Print("contexto PvP: " .. (InPvP() and "si" or "no") .. " | avisos permitidos: " .. ((Allowed() and "si") or "no"
            .. (ctx and "" or " (fuera de PvP; usa /estado siempre)")))
        Print("vida: " .. ModeText(diag.hp) .. (diag.hpPct and string.format(" %d%%", math.floor(diag.hpPct + 0.5)) or ""))
        Print("recurso (" .. tostring(diag.powName) .. "): " .. ModeText(diag.pow))
        Print("perdida de control: " .. (C_LossOfControl and "API disponible" or "API NO disponible")
            .. " | curva de pulso: " .. (hpCurve and "si" or "no"))
        Print("voz: " .. tostring(DB.voice) .. " | canal: " .. tostring(DB.channel) .. " | sonido " .. (DB.sound and "si" or "no"))
    elseif cmd == "probar" then
        if arg == "mana" then TestMana() elseif arg == "control" then TestLoc() else TestHealth() end
    elseif cmd == "mover" then
        SetMoving(true)
        Print("arrastra el texto con el raton. /estado bloquear para fijarlo.")
    elseif cmd == "bloquear" then
        SetMoving(false)
        Print("texto bloqueado.")
    elseif cmd == "siempre" then
        DB.always = not DB.always; Refresh()
        Print("avisar tambien fuera de PvP: " .. (DB.always and "si" or "no"))
    elseif cmd == "minimap" then
        local c = ns.DB.minimap.estado
        Hub:SetModuleButton("estado", c.hide and true or false)
        Print("boton del minimapa: " .. (c.hide and "oculto" or "visible"))
    else
        Print("/estado = configuracion | diag | probar [vida|mana|control] | mover | bloquear | siempre | minimap")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local function Init(m)
    DB = m.db
    CreateEdge()
    CreateHolder()
    CreateLoc()
    BuildHpCurve()
    diag.locApi = C_LossOfControl ~= nil

    local function OnPlayer(fn)
        return function(_, _, unit) if unit == "player" then fn() end end
    end
    m:Event("UNIT_HEALTH", OnPlayer(CheckHealth))
    m:Event("UNIT_MAXHEALTH", OnPlayer(CheckHealth))
    m:Event("UNIT_POWER_UPDATE", OnPlayer(CheckPower))
    m:Event("UNIT_MAXPOWER", OnPlayer(CheckPower))
    m:Event("UNIT_DISPLAYPOWER", OnPlayer(CheckPower))
    m:Event("LOSS_OF_CONTROL_ADDED", function(_, _, _, arg2) OnLocAdded(arg2) end)
    m:Event("LOSS_OF_CONTROL_UPDATE", function() if loc then loc.needTimer = true end end)
    m:Event("PLAYER_DEAD", function()
        lvl.hp, lvl.pow = 0, 0
        UpdateSecretGlow(false)
        if edge then edge.flashEnd = nil; edge:SetAlpha(0); edge:Hide() end
        if loc then loc.fake = nil; loc:Hide() end
    end)
    local function Revive() lvl.hp, lvl.pow = 0, 0; CheckAll() end
    m:Event("PLAYER_ALIVE", Revive)
    m:Event("PLAYER_UNGHOST", Revive)
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
        "PLAYER_FLAGS_CHANGED", "PVP_MATCH_ACTIVE", "PVP_MATCH_COMPLETE" }) do
        m:Event(e, function() CheckAll() end)
    end
end

mod = Hub:Register{
    key = "estado", dir = "Estado", name = "Estado",
    desc = "Te avisa de tu propio estado en PvP: vida baja, maná bajo y pérdida de control (aturdido, asustado, silenciado...), con pulso rojo en los bordes, texto grande y voz.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosEstadoDB",
    slash = { "estado", "cmestado" },
    Init = function(m) if ns.PO_Vol then ns.PO_Vol.Recover() end; Init(m) end,
    Enable = function(m)
        DB = m.db
        if holder then holder:Show() end
        ApplyStyle()
        lvl.hp, lvl.pow = 0, 0
        CheckAll()
    end,
    Disable = function(m)
        lvl.hp, lvl.pow = 0, 0
        if edge then UpdateSecretGlow(false); edge.flashEnd = nil; edge:SetAlpha(0) end
        if loc then loc.fake = nil end
        if alertText then alertText:SetText("") end
        if holder then holder.textEnd = nil end
        if ns.PO_Vol then ns.PO_Vol.RestoreAll() end
    end,
    BuildConfig = BuildConfig,
    OnSlash = OnSlash,
    OnReset = function(m)
        DB = m.db
        if holder then ApplyStyle(); if mod.enabled then BuildHpCurve() end end
    end,
}
