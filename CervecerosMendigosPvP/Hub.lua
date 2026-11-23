-- CervecerosMendigos · Hub comun de los tres addons grandes (PvP, PvpOutdoor, General).
-- Este archivo es IDENTICO en los tres: lo copia _suite/construir.py. No editar la copia.
--
-- Contrato de un modulo (ver _suite/LEEME_MODULOS.md):
--   local ADDON, ns = ...
--   ns.Hub:Register{
--     key = "banco", dir = "Banco", name = "Banco", desc = "Buscador de inventario de todos tus personajes.",
--     defaults = { ... },            -- se mezclan en mod.db (SavedVariables)
--     legacyDB = "CervecerosMendigosBancoDB",   -- opcional: migra los datos del addon suelto antiguo
--     slash = { "banco", "cmbanco" },           -- opcional: comandos; por defecto abren la pestana
--     Init = function(mod) end,      -- una sola vez, la primera vez que se activa
--     Enable = function(mod) end,    -- cada vez que se activa (muestra marcos, registra cosas)
--     Disable = function(mod) end,   -- cada vez que se desactiva (oculta todo)
--     BuildConfig = function(mod, L, parent) end,  -- rellena la pestana (L = layout, ver Hub.UI)
--     OnSlash = function(mod, msg) end,  -- opcional
--   }
-- Ayudas en mod: mod.db, mod.path (ruta Interface\AddOns\... del modulo), mod:Event(ev, fn),
-- mod:OnUpdate(fn), mod:Frame(...), mod:Print(msg), mod:IsEnabled().

local ADDON, ns = ...
local CFG = ns.HubConfig
local Hub = { modules = {}, order = {}, byKey = {} }
ns.Hub = Hub

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local DB
local window, tabButtons, panels = nil, {}, {}
local minimapButtons = {}
local currentTab

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. CFG.title .. ":|r " .. tostring(msg)) end
Hub.Print = Print

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end
Hub.CopyDefaults = CopyDefaults

local function Safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Print("|cffff5555error:|r " .. tostring(err)) end
    return ok
end

----------------------------------------------------------------------
-- Widgets y layout (los mismos que usaban los addons sueltos)
----------------------------------------------------------------------
local UI = {}
Hub.UI = UI

function UI.MakeWindow(name, title, w, h)
    local f
    local ok = pcall(function() f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset") end)
    if not ok or not f then
        f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
        f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                        edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        f.hdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.hdr:SetPoint("TOP", 0, -10); f.hdr:SetText(title)
        local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        x:SetPoint("TOPRIGHT", -2, -2)
    elseif f.SetTitle then f:SetTitle(title)
    elseif f.TitleText then f.TitleText:SetText(title) end
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if name then tinsert(UISpecialFrames, name) end
    f:Hide()
    return f
end

-- Desplazamiento propio con rueda del raton y barra fina. Devuelve scroll, hijo.
function UI.MakeScroll(parent, w, h)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetSize(w, h)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(w, 10)
    sf:SetScrollChild(child)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetSize(10, h)
    bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, 0)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0.1, 0.1, 0.12, 0.8)
    bar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Vertical")
    bar:SetMinMaxValues(0, 0); bar:SetValue(0)
    local function Range()
        local r = math.max(0, child:GetHeight() - sf:GetHeight())
        bar:SetMinMaxValues(0, r)
        if r <= 0 then bar:Hide() else bar:Show() end
        if sf:GetVerticalScroll() > r then sf:SetVerticalScroll(r) end
        return r
    end
    bar:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, d)
        local r = Range()
        local v = math.min(r, math.max(0, sf:GetVerticalScroll() - d * 40))
        sf:SetVerticalScroll(v); bar:SetValue(v)
    end)
    sf.UpdateRange = Range
    sf.bar = bar
    return sf, child
end

local function NewCheck(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(26, 26)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Refresh = function(self) self:SetChecked(get()) end
    return cb
end
UI.NewCheck = NewCheck

local function NewSlider(parent, label, minv, maxv, step, x, y, get, set, fmt, w)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(w or 260, 16)
    s:SetPoint("TOPLEFT", x, y - 20)
    s:SetMinMaxValues(minv, maxv)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    local bar = s:CreateTexture(nil, "BACKGROUND")
    bar:SetColorTexture(0.25, 0.25, 0.3, 1)
    bar:SetPoint("LEFT"); bar:SetPoint("RIGHT"); bar:SetHeight(6)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local function Show(v) fs:SetText(label .. ": |cffffffff" .. string.format(fmt or "%d", v) .. "|r") end
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
    return s
end
UI.NewSlider = NewSlider

local function NewButton(parent, label, w, point, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 24)
    b:SetPoint(point, x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end
UI.NewButton = NewButton

-- Layout vertical: L:Header, L:Text, L:Check, L:Slider, L:Button, L:Row, L:Space.
-- Los widgets con Refresh se refrescan solos al mostrar la pestana (L:Refresh()).
function UI.Layout(parent, x0, y0, width)
    local L = { parent = parent, x = x0 or 8, y = -(y0 or 8), width = width or 520, widgets = {} }
    function L:Space(n) self.y = self.y - (n or 10); return self end
    function L:Header(text)
        self.y = self.y - 6
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        fs:SetPoint("TOPLEFT", self.x, self.y); fs:SetText(text)
        self.y = self.y - 26
        return fs
    end
    function L:Text(text, small)
        local fs = parent:CreateFontString(nil, "OVERLAY", small and "GameFontHighlightSmall" or "GameFontHighlight")
        fs:SetPoint("TOPLEFT", self.x, self.y)
        fs:SetWidth(self.width - 8); fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
        fs:SetText(text)
        local h = (fs.GetStringHeight and fs:GetStringHeight()) or 14
        if not h or h < 12 then h = 14 end
        self.y = self.y - h - 6
        return fs
    end
    function L:Check(label, get, set)
        local cb = NewCheck(parent, label, self.x, self.y, get, set)
        self.widgets[#self.widgets + 1] = cb
        self.y = self.y - 28
        return cb
    end
    function L:Slider(label, minv, maxv, step, get, set, fmt)
        local s = NewSlider(parent, label, minv, maxv, step, self.x, self.y, get, set, fmt, math.min(300, self.width - 20))
        self.widgets[#self.widgets + 1] = s
        self.y = self.y - 48
        return s
    end
    function L:Button(label, w, onClick, sameRow)
        if sameRow and self.lastBtn then
            local b = NewButton(parent, label, w, "TOPLEFT", self.lastBtnX + self.lastBtnW + 8, self.lastBtnY, onClick)
            self.lastBtnX = self.lastBtnX + self.lastBtnW + 8; self.lastBtnW = w
            return b
        end
        local b = NewButton(parent, label, w, "TOPLEFT", self.x, self.y, onClick)
        self.lastBtn, self.lastBtnX, self.lastBtnY, self.lastBtnW = b, self.x, self.y, w
        self.y = self.y - 30
        return b
    end
    -- Selector de color: get() -> r,g,b ; set(r,g,b)
    function L:Color(label, get, set)
        local sw = CreateFrame("Button", nil, parent)
        sw:SetSize(22, 22); sw:SetPoint("TOPLEFT", self.x + 2, self.y)
        local border = sw:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints(); border:SetColorTexture(1, 1, 1, 0.9)
        local fill = sw:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 2, -2); fill:SetPoint("BOTTOMRIGHT", -2, 2)
        local fs = sw:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", sw, "RIGHT", 8, 0); fs:SetText(label)
        sw.Refresh = function() local r, g, b = get(); fill:SetColorTexture(r or 1, g or 1, b or 1, 1) end
        sw:SetScript("OnClick", function()
            local r, g, b = get()
            local function Apply()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                set(nr, ng, nb); sw.Refresh()
            end
            if ColorPickerFrame.SetupColorPickerAndShow then
                ColorPickerFrame:SetupColorPickerAndShow({
                    r = r or 1, g = g or 1, b = b or 1, hasOpacity = false,
                    swatchFunc = Apply, cancelFunc = function() set(r, g, b); sw.Refresh() end,
                })
            else
                ColorPickerFrame.func = Apply
                ColorPickerFrame.cancelFunc = function() set(r, g, b); sw.Refresh() end
                ColorPickerFrame:SetColorRGB(r or 1, g or 1, b or 1)
                ColorPickerFrame:Show()
            end
        end)
        self.widgets[#self.widgets + 1] = sw
        self.y = self.y - 30
        return sw
    end
    -- Selector por pulsaciones: options = { {valor, "Texto"}, ... }; get() -> valor ; set(valor)
    function L:Choice(label, options, get, set)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", self.x, self.y - 4); fs:SetText(label)
        local b = NewButton(parent, "", 170, "TOPLEFT", self.x + 230, self.y, function(self2)
            local cur, idx = get(), 1
            for i, o in ipairs(options) do if o[1] == cur then idx = i end end
            idx = idx % #options + 1
            set(options[idx][1]); self2.Refresh(self2)
        end)
        b.Refresh = function(self2)
            local cur, txt = get(), options[1][2]
            for _, o in ipairs(options) do if o[1] == cur then txt = o[2] end end
            self2:SetText(txt)
        end
        self.widgets[#self.widgets + 1] = b
        self.y = self.y - 32
        return b
    end
    -- Cuadro de texto / numero: kind = "text" | "number"
    function L:Edit(label, get, set, kind, w)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", self.x, self.y - 4); fs:SetText(label)
        local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        eb:SetSize(w or 110, 22); eb:SetPoint("TOPLEFT", self.x + 230, self.y)
        eb:SetAutoFocus(false)
        if kind == "number" and eb.SetNumeric then eb:SetNumeric(false) end
        eb:SetScript("OnEnterPressed", function(s)
            local v = s:GetText()
            if kind == "number" then v = tonumber(v); if not v then s.Refresh(s); s:ClearFocus(); return end end
            set(v); s:ClearFocus()
        end)
        eb:SetScript("OnEscapePressed", function(s) s.Refresh(s); s:ClearFocus() end)
        eb.Refresh = function(s) s:SetText(tostring(get() or "")) end
        self.widgets[#self.widgets + 1] = eb
        self.y = self.y - 32
        return eb
    end
    function L:Refresh() for _, w in ipairs(self.widgets) do if w.Refresh then w:Refresh() end end end
    function L:Add(widget, height) self.widgets[#self.widgets + 1] = widget; self.y = self.y - (height or 0); return widget end
    function L:Height() return -self.y + 12 end
    return L
end

----------------------------------------------------------------------
-- Modulos
----------------------------------------------------------------------
local ModMT = {}
ModMT.__index = ModMT

function ModMT:IsEnabled() return self.enabled end
function ModMT:Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. self.def.name .. ":|r " .. tostring(msg)) end

function ModMT:Event(event, fn)
    self.events[event] = fn
    if self.enabled then pcall(self.evf.RegisterEvent, self.evf, event) end
end

function ModMT:UnEvent(event)
    self.events[event] = nil
    self.evf:UnregisterEvent(event)
end

function ModMT:OnUpdate(fn)
    self.updateFn = fn
    if self.enabled then self.evf:SetScript("OnUpdate", function(_, e) fn(self, e) end) end
end

function ModMT:Frame(ftype, name, parent, template)
    local f = CreateFrame(ftype or "Frame", name, parent or UIParent, template)
    self.frames[#self.frames + 1] = f
    return f
end

function ModMT:Track(frame) self.frames[#self.frames + 1] = frame; return frame end

function Hub:Register(def)
    assert(def and def.key, "Hub:Register necesita key")
    local mod = setmetatable({
        key = def.key, def = def, enabled = false, inited = false,
        events = {}, frames = {}, path = "Interface\\AddOns\\" .. ADDON .. "\\Modulos\\" .. (def.dir or def.key) .. "\\",
    }, ModMT)
    mod.evf = CreateFrame("Frame")
    mod.evf:SetScript("OnEvent", function(_, event, ...)
        local fn = mod.events[event]
        if fn then
            local ok, err = pcall(fn, mod, event, ...)
            if not ok then Print("|cffff5555error en " .. def.name .. ":|r " .. tostring(err)) end
        end
    end)
    mod.icon = def.icon or (mod.path .. "icon.tga")
    self.modules[#self.modules + 1] = mod
    self.byKey[def.key] = mod
    -- slash propio del modulo
    if def.slash then
        local id = "CMHUB_" .. string.upper(ADDON) .. "_" .. string.upper(def.key)
        for i, cmd in ipairs(def.slash) do _G["SLASH_" .. id .. i] = "/" .. cmd end
        SlashCmdList[id] = function(msg)
            if not mod.enabled then
                mod:Print("modulo desactivado. Activalo en la pestana '" .. def.name .. "' (/" .. CFG.slashes[1] .. ").")
                Hub:Open(def.key)
                return
            end
            if def.OnSlash then
                local ok, err = pcall(def.OnSlash, mod, msg or "")
                if not ok then Print("|cffff5555error:|r " .. tostring(err)) end
            else
                Hub:Open(def.key)
            end
        end
    end
    if DB then self:Attach(mod) end
    return mod
end

-- Une el modulo con la base de datos (cuando ya esta cargada).
function Hub:Attach(mod)
    if mod.attached then return end
    mod.attached = true
    DB.mod[mod.key] = DB.mod[mod.key] or {}
    local legacy
    local ld = mod.def.legacyDB
    if type(ld) == "string" then ld = { ld } end
    if ld then for _, name in ipairs(ld) do if _G[name] then legacy = _G[name]; break end end end
    if legacy and next(DB.mod[mod.key]) == nil and not DB.migrated[mod.key] then
        for k, v in pairs(legacy) do DB.mod[mod.key][k] = v end
        DB.migrated[mod.key] = true
    end
    mod.db = DB.mod[mod.key]
    if mod.def.defaults then CopyDefaults(mod.db, mod.def.defaults) end
    if DB.enabled[mod.key] == nil then DB.enabled[mod.key] = (mod.def.defaultOn ~= false) end
    DB.minimap[mod.key] = DB.minimap[mod.key] or {}
end

function Hub:GetModule(key) return self.byKey[key] end

-- Vuelve los ajustes de un modulo a sus valores por defecto (no toca el estado activado).
function Hub:ResetModule(key)
    local mod = self.byKey[key]
    if not mod or not mod.db then return end
    -- Solo se restauran las claves que estan en `defaults`: los datos del usuario
    -- (historiales, inventarios, listas, precios...) que no sean ajustes NO se borran.
    if mod.def.defaults then
        for k in pairs(mod.def.defaults) do mod.db[k] = nil end
        CopyDefaults(mod.db, mod.def.defaults)
    end
    if mod.def.OnReset then Safe(mod.def.OnReset, mod) end
    self:RefreshUI(key)
    Print(mod.def.name .. ": ajustes restaurados a los valores por defecto.")
end

function Hub:SetEnabled(key, on, silent)
    local mod = self.byKey[key]
    if not mod then return end
    on = on and true or false
    DB.enabled[key] = on
    if on and not mod.enabled then
        mod.enabled = true
        if not mod.inited then
            mod.inited = true
            if mod.def.Init then Safe(mod.def.Init, mod) end
        end
        for ev in pairs(mod.events) do pcall(mod.evf.RegisterEvent, mod.evf, ev) end  -- un evento que no exista no rompe nada
        if mod.updateFn then
            local fn = mod.updateFn
            mod.evf:SetScript("OnUpdate", function(_, e) fn(mod, e) end)
        end
        if mod.def.Enable then Safe(mod.def.Enable, mod) end
    elseif not on and mod.enabled then
        mod.enabled = false
        mod.evf:UnregisterAllEvents()
        mod.evf:SetScript("OnUpdate", nil)
        if mod.def.Disable then Safe(mod.def.Disable, mod) end
        for _, f in ipairs(mod.frames) do if f.Hide then f:Hide() end end
    end
    self:RefreshUI(key)
    if not silent then
        Print(mod.def.name .. (on and ": |cff55ff55activado|r" or ": |cffff7755desactivado|r"))
    end
end

----------------------------------------------------------------------
-- Botones del minimapa
----------------------------------------------------------------------
local function PlaceButton(b)
    local cfgb = b.cfg
    if not cfgb or not Minimap then return end
    local hidden = cfgb.hide
    if hidden then b:Hide(); return end
    local a = math.rad(cfgb.angle or 200)
    local r = (Minimap:GetWidth() / 2) + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
    b:Show()
end

local function MakeMinimapButton(name, iconPath, cfgb, isModule, onClick, tooltip)
    local b = CreateFrame("Button", name, Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20); bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20); icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture(iconPath)
    b.icon = icon
    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53, 53); ring:SetPoint("TOPLEFT")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b.cfg, b.isModule = cfgb, isModule
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", onClick)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            cfgb.angle = math.deg(atan2(py / s - my, px / s - mx))
            PlaceButton(self)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        tooltip(GameTooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceButton(b)
    return b
end

function Hub:BuildMinimapButtons()
    -- Un unico boton por addon grande: abre el panel con todas las pestanas.
    DB.minimap._hub = DB.minimap._hub or {}
    if DB.minimap._hub.angle == nil then DB.minimap._hub.angle = CFG.angleBase end
    minimapButtons._hub = MakeMinimapButton(ADDON .. "MinimapButton", CFG.minimapIcon, DB.minimap._hub, false,
        function() Hub:Toggle() end,
        function(tt)
            tt:AddLine(CFG.title, 0.2, 1, 0.6)
            tt:AddLine(CFG.subtitle, 0.8, 0.8, 0.8)
            tt:AddLine("Clic: abrir/cerrar el panel", 1, 1, 1)
            tt:AddLine("Arrastrar: mover el boton", 0.7, 0.7, 0.7)
        end)
end

----------------------------------------------------------------------
-- Ventana principal
----------------------------------------------------------------------
local WIN_W, WIN_H, TAB_W = 820, 600, 176

local function SelectTab(key)
    currentTab = key
    for k, p in pairs(panels) do p:SetShown(k == key) end
    for k, b in pairs(tabButtons) do
        if b.sel then b.sel:SetShown(k == key) end
    end
    local p = panels[key]
    if p and p.OnOpen then p.OnOpen() end
end

local function StatusColor(mod)
    if mod.enabled then return 0.2, 0.9, 0.3 else return 0.6, 0.2, 0.2 end
end

local function MakeTabButton(index, key, label, iconPath, mod)
    local b = CreateFrame("Button", nil, window)
    b:SetSize(TAB_W - 8, 30)
    b:SetPoint("TOPLEFT", window, "TOPLEFT", 12, -96 - (index - 1) * 32)
    local hl = b:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.07)
    b:SetHighlightTexture(hl)
    local sel = b:CreateTexture(nil, "BORDER")
    sel:SetAllPoints(); sel:SetColorTexture(0.2, 0.7, 0.45, 0.28)
    sel:Hide()
    b.sel = sel
    local ic = b:CreateTexture(nil, "ARTWORK")
    ic:SetSize(22, 22); ic:SetPoint("LEFT", 6, 0)
    ic:SetTexture(iconPath)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", ic, "RIGHT", 6, 0)
    fs:SetWidth(TAB_W - 70); fs:SetJustifyH("LEFT")
    fs:SetText(label)
    if mod then
        local dot = b:CreateTexture(nil, "OVERLAY")
        dot:SetSize(9, 9); dot:SetPoint("RIGHT", -6, 0)
        dot:SetColorTexture(StatusColor(mod))
        b.dot = dot
    end
    b:SetScript("OnClick", function() SelectTab(key) end)
    tabButtons[key] = b
    return b
end

local function BuildHome(content)
    local sf, child = UI.MakeScroll(content, WIN_W - TAB_W - 70, WIN_H - 170)
    sf:SetPoint("TOPLEFT", 6, -6)
    local L = UI.Layout(child, 6, 4, WIN_W - TAB_W - 90)
    L:Header("Que hay dentro")
    L:Text(CFG.intro)
    L:Space(4)
    L:Header("Opciones generales")
    L:Slider("Tamano de esta ventana", 70, 130, 5,
        function() return math.floor((DB.scale or 1) * 100 + 0.5) end,
        function(v) DB.scale = v / 100; if window then window:SetScale(DB.scale) end end, "%d%%")
    L:Button("Recolocar el boton del minimapa", 230, function()
        DB.minimap._hub.angle = CFG.angleBase
        if minimapButtons._hub then PlaceButton(minimapButtons._hub) end
    end)
    L:Space(6)
    L:Header("Modulos")
    for _, mod in ipairs(Hub.modules) do
        local ic = child:CreateTexture(nil, "ARTWORK")
        ic:SetSize(24, 24); ic:SetPoint("TOPLEFT", 8, L.y)
        ic:SetTexture(mod.icon)
        local title = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 40, L.y - 2); title:SetText(mod.def.name)
        local cb = NewCheck(child, "Activado", WIN_W - TAB_W - 210, L.y + 2,
            function() return mod.enabled end,
            function(v) Hub:SetEnabled(mod.key, v) end)
        L:Add(cb, 0)
        L.y = L.y - 22
        local old = L.x
        L.x = 40
        local savedW = L.width; L.width = savedW - 40
        L:Text(mod.def.desc or "", true)
        L.x = old; L.width = savedW
        L:Space(8)
    end
    child:SetHeight(L:Height())
    sf:UpdateRange()
    local powered = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    powered:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -12, 8)
    powered:SetText("Powered by |cff33ff99@ddlstudios|r")
    content.homeLayout = L
    content.OnOpen = function() L:Refresh() end
    return L
end

local function BuildModuleTab(content, mod)
    local def = mod.def
    local head = CreateFrame("Frame", nil, content)
    head:SetPoint("TOPLEFT", 0, 0); head:SetPoint("TOPRIGHT", 0, 0); head:SetHeight(84)
    local title = head:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 10, -8); title:SetText(def.name)
    local desc = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -34); desc:SetWidth(WIN_W - TAB_W - 60); desc:SetJustifyH("LEFT")
    desc:SetText(def.desc or "")
    local on = NewCheck(head, "Activar este modulo", 6, -52,
        function() return mod.enabled end, function(v) Hub:SetEnabled(mod.key, v) end)
    local state = head:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    state:SetPoint("TOPRIGHT", -34, -12)
    local reset = NewButton(head, "Restaurar valores", 130, "TOPRIGHT", -34, -46, function()
        Hub:ResetModule(mod.key)
    end)
    local line = head:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetPoint("BOTTOMLEFT", 0, 0); line:SetPoint("BOTTOMRIGHT", 0, 0); line:SetHeight(1)

    local sf, child = UI.MakeScroll(content, WIN_W - TAB_W - 70, WIN_H - 190)
    sf:SetPoint("TOPLEFT", 6, -92)
    local L = UI.Layout(child, 6, 4, WIN_W - TAB_W - 90)
    if def.BuildConfig then
        local ok, err = pcall(def.BuildConfig, mod, L, child)
        if not ok then L:Text("|cffff5555Error al construir la pestana:|r " .. tostring(err)) end
    else
        L:Text("Este modulo no tiene opciones propias.")
    end
    child:SetHeight(math.max(L:Height(), 40))
    sf:UpdateRange()
    local function Refresh()
        on:Refresh(); L:Refresh()
        state:SetText(mod.enabled and "|cff55ff55ACTIVADO|r" or "|cffff7755DESACTIVADO|r")
        sf:SetAlpha(mod.enabled and 1 or 0.55)
    end
    content.OnOpen = Refresh
    content.Refresh = Refresh
    mod.panel = content
end

function Hub:BuildWindow()
    if window then return end
    window = UI.MakeWindow(ADDON .. "Window", CFG.title, WIN_W, WIN_H)
    window:SetScale(DB.scale or 1)
    -- cabecera con logo y nombre
    local logo = window:CreateTexture(nil, "ARTWORK")
    logo:SetSize(58, 58); logo:SetPoint("TOPLEFT", 16, -30)
    logo:SetTexture(CFG.logo)
    local name = window:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    name:SetPoint("TOPLEFT", logo, "TOPRIGHT", 12, -6); name:SetText(CFG.title)
    local sub = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4); sub:SetText(CFG.subtitle)

    local idx = 1
    MakeTabButton(idx, "_inicio", "Inicio", CFG.logo, nil)
    local homeContent = CreateFrame("Frame", nil, window)
    homeContent:SetPoint("TOPLEFT", window, "TOPLEFT", TAB_W + 18, -96)
    homeContent:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -14, 14)
    panels._inicio = homeContent
    BuildHome(homeContent)
    for _, mod in ipairs(self.modules) do
        idx = idx + 1
        MakeTabButton(idx, mod.key, mod.def.name, mod.icon, mod)
        local c = CreateFrame("Frame", nil, window)
        c:SetPoint("TOPLEFT", window, "TOPLEFT", TAB_W + 18, -96)
        c:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -14, 14)
        c:Hide()
        panels[mod.key] = c
        BuildModuleTab(c, mod)
    end
    -- separador vertical
    local sep = window:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.15)
    sep:SetPoint("TOPLEFT", window, "TOPLEFT", TAB_W + 12, -96)
    sep:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", TAB_W + 12, 14)
    sep:SetWidth(1)
    SelectTab("_inicio")
end

function Hub:Open(key)
    self:BuildWindow()
    window:Show()
    SelectTab(key or currentTab or "_inicio")
end

function Hub:Toggle()
    self:BuildWindow()
    if window:IsShown() then window:Hide() else self:Open() end
end

function Hub:RefreshUI(key)
    local b = tabButtons[key]
    local mod = self.byKey[key]
    if b and b.dot and mod then b.dot:SetColorTexture(StatusColor(mod)) end
    if window then
        if panels[key] and panels[key].Refresh then panels[key].Refresh() end
        if panels._inicio and panels._inicio.OnOpen and currentTab == "_inicio" then panels._inicio.OnOpen() end
    end
    if minimapButtons[key] and minimapButtons[key].icon then
        minimapButtons[key].icon:SetDesaturated(mod and not mod.enabled or false)
    end
end

----------------------------------------------------------------------
-- Arranque
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, arg)
    if event == "ADDON_LOADED" and arg == ADDON then
        _G[CFG.svName] = _G[CFG.svName] or {}
        DB = _G[CFG.svName]
        DB.enabled = DB.enabled or {}
        DB.mod = DB.mod or {}
        DB.minimap = DB.minimap or {}
        DB.migrated = DB.migrated or {}
        ns.DB = DB
        for _, mod in ipairs(Hub.modules) do Hub:Attach(mod) end
    elseif event == "PLAYER_LOGIN" then
        if not DB then return end
        Hub:BuildMinimapButtons()
        for _, mod in ipairs(Hub.modules) do
            if DB.enabled[mod.key] then Hub:SetEnabled(mod.key, true, true) end
            Hub:RefreshUI(mod.key)
        end
    end
end)

-- /cmpvp, /pvp ... : abre el panel; "/x <modulo>" abre su pestana; "/x lista" lista modulos.
do
    local id = "CMHUB_" .. string.upper(ADDON)
    for i, cmd in ipairs(CFG.slashes) do _G["SLASH_" .. id .. i] = "/" .. cmd end
    SlashCmdList[id] = function(msg)
        msg = (msg or ""):lower():match("^%s*(.-)%s*$")
        if msg == "" then Hub:Toggle(); return end
        if msg == "lista" then
            for _, mod in ipairs(Hub.modules) do
                Print(mod.key .. ": " .. (mod.enabled and "activado" or "desactivado") .. " - " .. mod.def.name)
            end
            return
        end
        local verb, k = msg:match("^(%S+)%s+(%S+)$")
        if verb == "activar" or verb == "desactivar" then
            if Hub.byKey[k] then Hub:SetEnabled(k, verb == "activar") else Print("modulo desconocido: " .. k) end
            return
        end
        if Hub.byKey[msg] then Hub:Open(msg) else Hub:Toggle() end
    end
end
