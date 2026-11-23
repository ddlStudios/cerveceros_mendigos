-- Modulo "Voces de hechizos" (PvPOutdoor): avisos de voz por hechizo (estilo GladiatorlosSA).
-- Cuando un enemigo cercano (placas de nombre, objetivo, foco, mouseover o arena)
-- empieza o termina de lanzar un hechizo de la lista, una voz lo anuncia (espanol o ingles).
-- Cada hechizo se puede activar/desactivar y elegir si avisa al empezar a castear
-- ("Inicio") o al lanzarlo ("Lanzado").
--
-- LIMITE DEL CLIENTE: el juego devuelve OCULTO el hechizo que lanza un enemigo, salvo los
-- que Blizzard marca como visibles. Un hechizo oculto no se puede identificar ni anunciar.
-- El punto de color de cada fila indica que dice el juego de ese hechizo.

local ADDON, ns = ...
local Hub = ns.Hub
local LANG_NAME = { es = "Español", en = "English" }
local issecret = issecretvalue or function() return false end

local mod, V
local entries, byId, byName = {}, {}, {}
local built = false
local lastSaid = {}

local DEFAULTS = {
    on = true,            -- avisos de voz activados
    generic = false,      -- decir "Casteo enemigo" cuando el juego oculta el hechizo
    spam = 2,             -- pausa (s) entre avisos del mismo hechizo
    lang = "es",          -- idioma de la voz y de los nombres de la lista
    channel = "Master",   -- canal de sonido (Master / Dialog / SFX)
    volume = 100,         -- volumen de las voces (0-100): se aplica al canal mientras suena la voz
    boost = true,         -- subir el canal si esta por debajo del volumen elegido
    outdoorOnly = true,   -- no avisar dentro de instancias / campos de batalla / arenas
    units = { nameplate = true, target = true, focus = true, mouseover = true, arena = true },
    spells = {},          -- por hechizo: { on, start, succ }
}

local function Clean(v) if issecret(v) then return nil end return v end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
end
local function SpellInfo(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local i = C_Spell.GetSpellInfo(id)
        if i then return i.name, i.iconID end
    end
end

local function IsEnemyPlayer(unit)
    local ok, res = pcall(function()
        return UnitExists(unit) and UnitIsPlayer(unit) and UnitIsEnemy("player", unit) and true or false
    end)
    return ok and res
end

----------------------------------------------------------------------
-- Datos
----------------------------------------------------------------------
local function BuildEntries()
    if built then return end
    built = true
    wipe(entries); wipe(byId); wipe(byName)
    local anyResolved = false
    for _, d in ipairs(CMVoiceData or {}) do
        -- { categoria, clave, nombre ES, nombre EN, activo por defecto, disparo, {ids} }
        local e = { cat = d[1], key = d[2], es = d[3], en = d[4], imp = d[5], trig = d[6], ids = d[7] }
        for _, id in ipairs(e.ids) do
            byId[id] = e
            local n, icon = SpellInfo(id)
            if n then
                anyResolved = true
                if not byName[n] then byName[n] = e end
                e.icon = e.icon or icon
                e.firstId = e.firstId or id
                e.exists = true
            end
        end
        entries[#entries + 1] = e
    end
    -- si el cliente no sabe resolver ids, se muestran todos
    for _, e in ipairs(entries) do e.visible = e.exists or not anyResolved end
end

-- Prepara la tabla de ajustes (y migra la voz del addon antiguo la primera vez).
local function Prepare()
    V = mod.db
    if not V._legacyChecked then
        V._legacyChecked = true
        local old = _G.CervecerosMendigosPvpOutdoorDB or _G.otoriPvpOutdoorDB or _G.PvPOutdoorDB
        if old and type(old.voice) == "table" then
            for k, v in pairs(old.voice) do V[k] = v end
            Hub.CopyDefaults(V, DEFAULTS)
        end
    end
    if V.lang ~= "en" and V.lang ~= "es" then V.lang = "es" end
    V.spells = V.spells or {}
    BuildEntries()
end

local function St(e)
    local s = V.spells[e.key]
    if not s then
        s = { on = (e.imp == 1), start = (e.trig == "start"), succ = (e.trig == "succ") }
        V.spells[e.key] = s
    end
    return s
end

-- Que dice el juego de este hechizo: "never" (visible), "always" (oculto), "ctx" (depende)
local function Secrecy(e)
    if e.sec then return e.sec end
    local res = "ctx"
    if C_Secrets and C_Secrets.GetSpellCastSecrecy and e.firstId and Enum and Enum.SecrecyLevel then
        local ok, lvl = pcall(C_Secrets.GetSpellCastSecrecy, e.firstId)
        if ok then
            if lvl == Enum.SecrecyLevel.NeverSecret then res = "never"
            elseif lvl == Enum.SecrecyLevel.AlwaysSecret then res = "always" end
        end
    end
    e.sec = res
    return res
end

local SEC_COLOR = { never = { 0.2, 1, 0.2 }, ctx = { 1, 0.85, 0.1 }, always = { 1, 0.2, 0.2 } }
local SEC_TEXT = {
    never = "Visible: el juego deja identificar este hechizo",
    ctx = "Depende: contra enemigos suele estar oculto",
    always = "Oculto: el juego no deja identificarlo",
}

----------------------------------------------------------------------
-- Voz
----------------------------------------------------------------------
local function Lang() return (V and V.lang == "en") and "en" or "es" end
local function NameOf(e) return e[Lang()] end

local function Speak(key, force)
    if not V then return end
    local now = GetTime()
    if not force and lastSaid[key] and now - lastSaid[key] < (V.spam or 2) then return end
    lastSaid[key] = now
    local file = mod.path .. "sounds\\" .. Lang() .. "\\" .. key .. ".ogg"
    local dur = CMVoiceDur and CMVoiceDur[Lang()] and CMVoiceDur[Lang()][key]
    local Vol = ns.PO_Vol
    if Vol then Vol.Play(file, V.channel or "Master", V.volume, V.boost, dur)
    else PlaySoundFile(file, V.channel or "Master") end
end

local function Active()
    if not V or not mod.enabled then return false end
    if V.outdoorOnly then
        local ok, inInstance = pcall(IsInInstance)
        if ok and inInstance then return false end
    end
    return true
end

local function UnitOK(unit)
    if issecret(unit) or type(unit) ~= "string" then return false end
    local u = V.units
    if unit == "target" then return u.target end
    if unit == "focus" then return u.focus end
    if unit == "mouseover" then return u.mouseover end
    if string.find(unit, "^nameplate") ~= nil then return u.nameplate end
    if string.find(unit, "^arena%d") ~= nil then return u.arena end
    return false
end

local function Handle(kind, unit, spellID)
    if not V or not V.on or not Active() then return end
    if not UnitOK(unit) then return end
    if not IsEnemyPlayer(unit) then return end
    if issecret(spellID) or not spellID then
        -- el juego oculta el hechizo: solo se puede avisar de que hay un casteo
        if V.generic and kind == "start" then Speak("casteo") end
        return
    end
    local e = byId[spellID]
    if not e then
        local n = Clean(SpellName(spellID))
        e = n and byName[n]
    end
    if not e then return end
    local s = St(e)
    if s.on and ((kind == "start" and s.start) or (kind == "succ" and s.succ)) then
        Speak(e.key)
    end
end

----------------------------------------------------------------------
-- Lista virtualizada (dentro de la pestana)
----------------------------------------------------------------------
local ROWS, RH = 14, 24
local items, rows = {}, {}
local offset = 0
local scroll

local function BuildItems()
    wipe(items)
    local last
    for _, e in ipairs(entries) do
        if e.visible then
            if e.cat ~= last then items[#items + 1] = { header = e.cat }; last = e.cat end
            items[#items + 1] = { e = e }
        end
    end
end

local function UpdateRows()
    if #rows == 0 then return end
    for i = 1, ROWS do
        local row, it = rows[i], items[offset + i]
        if not it then
            row:Hide()
        else
            row:Show()
            if it.header then
                row.head:SetText(it.header); row.head:Show()
                row.icon:Hide(); row.name:Hide(); row.dot:Hide(); row.play:Hide()
                row.cbOn:Hide(); row.cbStart:Hide(); row.cbSucc:Hide()
                row.entry = nil
            else
                local e = it.e
                local s = St(e)
                row.entry = e
                row.head:Hide()
                row.icon:Show(); row.name:Show(); row.dot:Show(); row.play:Show()
                row.cbOn:Show(); row.cbStart:Show(); row.cbSucc:Show()
                row.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                row.name:SetText(NameOf(e))
                row.name:SetTextColor(s.on and 1 or 0.5, s.on and 1 or 0.5, s.on and 1 or 0.5)
                local c = SEC_COLOR[Secrecy(e)]
                row.dot:SetColorTexture(c[1], c[2], c[3], 1)
                row.cbOn:SetChecked(s.on)
                row.cbStart:SetChecked(s.start)
                row.cbSucc:SetChecked(s.succ)
            end
        end
    end
end

local function SetupScroll()
    if not scroll then return end
    local maxOff = math.max(0, #items - ROWS)
    scroll.loading = true
    scroll:SetMinMaxValues(0, maxOff)
    if offset > maxOff then offset = maxOff end
    scroll:SetValue(offset)
    scroll.loading = false
    scroll:SetShown(maxOff > 0)
    UpdateRows()
end

local function MakeCheck(parent, x, y, size, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(size, size)
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetScript("OnClick", onClick)
    return cb
end

local function BuildRow(parent, i)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(500, RH)
    row:SetPoint("TOPLEFT", 0, -22 - (i - 1) * RH)
    row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.head:SetPoint("LEFT", 2, 0)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 26, 0); row.name:SetWidth(178); row.name:SetJustifyH("LEFT")
    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(9, 9); row.dot:SetPoint("LEFT", 210, 0)
    row.dotHit = CreateFrame("Frame", nil, row)
    row.dotHit:SetSize(14, 14); row.dotHit:SetPoint("CENTER", row.dot)
    row.dotHit:EnableMouse(true)
    row.dotHit:SetScript("OnEnter", function(self)
        local e = row.entry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.es .. " / " .. e.en, 1, 1, 1)
        GameTooltip:AddLine(SEC_TEXT[Secrecy(e)], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row.dotHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function State() return row.entry and St(row.entry) end
    row.cbOn = MakeCheck(row, 232, -1, 22, function(self)
        local s = State(); if s then s.on = self:GetChecked() and true or false; UpdateRows() end
    end)
    row.cbStart = MakeCheck(row, 300, -1, 22, function(self)
        local s = State(); if s then s.start = self:GetChecked() and true or false end
    end)
    row.cbSucc = MakeCheck(row, 372, -1, 22, function(self)
        local s = State(); if s then s.succ = self:GetChecked() and true or false end
    end)
    row.play = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.play:SetSize(30, 20); row.play:SetPoint("LEFT", 446, 0)
    row.play:SetText(">")
    row.play:SetScript("OnClick", function() if row.entry then Speak(row.entry.key, true) end end)
    return row
end

-- Construye la lista dentro de "parent" a partir de (x, y) y devuelve el marco (con Refresh).
local function BuildList(parent, x, y)
    local lf = CreateFrame("Frame", nil, parent)
    lf:SetSize(530, 22 + ROWS * RH)
    lf:SetPoint("TOPLEFT", x, y)
    local function Col(text, cx)
        local f = lf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetPoint("TOPLEFT", cx, -4); f:SetText(text)
    end
    Col("Hechizo", 28); Col("Activo", 232); Col("Inicio", 300); Col("Lanzado", 366)
    for i = 1, ROWS do rows[i] = BuildRow(lf, i) end

    scroll = CreateFrame("Slider", nil, lf)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, ROWS * RH)
    scroll:SetPoint("TOPLEFT", 508, -22)
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
    lf:EnableMouseWheel(true)
    lf:SetScript("OnMouseWheel", function(_, delta)
        if scroll:IsShown() then scroll:SetValue(scroll:GetValue() - delta * 3) end
    end)
    lf.Refresh = function() BuildItems(); SetupScroll() end
    return lf
end

----------------------------------------------------------------------
-- Diagnostico y pruebas
----------------------------------------------------------------------
local function VoiceDiag()
    Prepare()
    local n, never, ctx, always = 0, 0, 0, 0
    for _, e in ipairs(entries) do
        if e.visible then
            n = n + 1
            local sec = Secrecy(e)
            if sec == "never" then never = never + 1 elseif sec == "always" then always = always + 1 else ctx = ctx + 1 end
        end
    end
    mod:Print(string.format("voz: %d hechizos en este cliente | visibles %d | dependen %d | ocultos %d", n, never, ctx, always))
    if never == 0 then
        mod:Print("ninguno es visible: solo funcionara el aviso generico «Casteo enemigo» (activalo en la pestana de voces).")
    end
end
ns.PO_VoiceDiag = function() if mod and mod.enabled then VoiceDiag() else if mod then mod:Print("modulo desactivado.") end end end
ns.PO_VoiceTest = function() if mod and mod.enabled and V then Speak("prueba", true) end end

----------------------------------------------------------------------
-- Configuracion (pestana)
----------------------------------------------------------------------
local function BuildConfig(m, L)
    Prepare()
    L:Header("Avisos de voz")
    L:Check("Avisos de voz activados", function() return V.on end, function(v) V.on = v end)
    L:Check("Decir «Casteo enemigo» cuando el juego oculta el hechizo",
        function() return V.generic end, function(v) V.generic = v end)
    L:Check("Solo en el mundo abierto (no instancias, campos de batalla ni arenas)",
        function() return V.outdoorOnly end, function(v) V.outdoorOnly = v end)
    L:Choice("Idioma de la voz y de la lista", { { "es", "Español" }, { "en", "English" } },
        function() return V.lang end,
        function(v) V.lang = v; UpdateRows(); Speak("prueba", true) end)
    L:Choice("Canal de sonido", { { "Master", "Maestro" }, { "Dialog", "Dialogos" }, { "SFX", "Efectos" } },
        function() return V.channel or "Master" end, function(v) V.channel = v end)
    L:Slider("Volumen de las voces", 0, 100, 5,
        function() return V.volume or 100 end, function(v) V.volume = v end, "%d%%")
    L:Check("Subir el canal si esta por debajo de ese volumen",
        function() return V.boost ~= false end, function(v) V.boost = v end)
    L:Text("Aviso: el juego solo tiene volumen por canal, no por sonido. Mientras suena una voz se ajusta temporalmente el volumen del canal elegido arriba (afecta a todo lo que suene en ese canal durante esa voz, ~1-2 s) y despues se deja exactamente como lo tenias. Con la casilla desmarcada solo se baja, nunca se sube.", true)
    L:Button("Probar voz", 140, function() Speak("prueba", true) end)
    L:Slider("Pausa entre avisos del mismo hechizo (segundos)", 0, 10, 0.5,
        function() return V.spam end, function(v) V.spam = v end, "%.1f")

    L:Header("A quien escuchar")
    L:Check("Placas de nombre (todos los enemigos cercanos)", function() return V.units.nameplate end,
        function(v) V.units.nameplate = v end)
    L:Check("Objetivo", function() return V.units.target end, function(v) V.units.target = v end)
    L:Check("Foco", function() return V.units.focus end, function(v) V.units.focus = v end)
    L:Check("Mouseover", function() return V.units.mouseover end, function(v) V.units.mouseover = v end)
    L:Check("Enemigos de arena", function() return V.units.arena end, function(v) V.units.arena = v end)

    L:Header("Hechizos")
    L:Text("Punto: |cff33ff33verde|r = visible, |cffffd91aamarillo|r = depende, |cffff3333rojo|r = oculto por el juego (no se puede avisar). Pasa el raton por el punto. «>» reproduce la voz.", true)
    L:Button("Probar voz", 110, function() Speak("prueba", true) end)
    L:Button("Activar todos", 120, function()
        for _, e in ipairs(entries) do if e.visible then St(e).on = true end end; UpdateRows()
    end, true)
    L:Button("Desactivar todos", 130, function()
        for _, e in ipairs(entries) do if e.visible then St(e).on = false end end; UpdateRows()
    end, true)
    L:Button("Hechizos por defecto", 150, function() wipe(V.spells); UpdateRows() end)
    L:Button("Diagnostico", 110, function() VoiceDiag() end, true)
    L:Space(4)
    local lf = BuildList(L.parent, L.x, L.y)
    L:Add(lf, 22 + ROWS * RH + 14)
end

local function OnSlash(m, msg)
    local cmd = string.match(strlower(msg or ""), "^(%S*)")
    if cmd == "info" or cmd == "vozinfo" then VoiceDiag()
    elseif cmd == "test" or cmd == "voztest" then Speak("prueba", true)
    else Hub:Open("voces") end
end

mod = Hub:Register{
    key = "voces", dir = "PvpOutdoor", name = "Voces de hechizos",
    icon = "Interface\\AddOns\\" .. ADDON .. "\\Modulos\\PvpOutdoor\\icono_voces.tga",
    desc = "Avisos de voz (español o inglés) cuando un enemigo cercano empieza o termina de lanzar un hechizo importante, configurables hechizo a hechizo, estilo GladiatorlosSA.",
    defaults = DEFAULTS,
    slash = { "cmvoz", "pvpovoz" },
    Init = function(m)
        Prepare()
        if ns.PO_Vol then ns.PO_Vol.Recover() end
        local function Start(_, _, unit, _, spellID) Handle("start", unit, spellID) end
        m:Event("UNIT_SPELLCAST_START", Start)
        m:Event("UNIT_SPELLCAST_CHANNEL_START", Start)
        m:Event("UNIT_SPELLCAST_SUCCEEDED", function(_, _, unit, _, spellID) Handle("succ", unit, spellID) end)
    end,
    Enable = function(m) Prepare(); wipe(lastSaid) end,
    Disable = function(m) wipe(lastSaid); if ns.PO_Vol then ns.PO_Vol.RestoreAll() end end,
    BuildConfig = BuildConfig,
    OnSlash = OnSlash,
    OnReset = function(m)
        V = m.db
        V._legacyChecked = true
        V.spells = V.spells or {}
        wipe(lastSaid)
        UpdateRows()
    end,
}
