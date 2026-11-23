-- Modulo Contador (CervecerosMendigosGeneral) para WoW Forever (Interface 16001).
-- Barra de iconos en pantalla con cuantas unidades tienes de los objetos (o monedas) que elijas,
-- sin abrir la mochila. Colores segun umbrales, objetivo opcional y avisos al quedarte corto.
-- Todo se configura en su pestana del panel (o con /contador, /cmcontador).

local ADDON, ns = ...
local Hub = ns.Hub
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local DEFAULTS = {
    style = {
        orient = "H",       -- "H" horizontal, "V" vertical
        iconSize = 36,
        fontSize = 16,
        spacing = 6,
        scale = 100,
        alpha = 100,
        locked = false,
        textBelow = false,  -- numero debajo del icono en vez de encima
        warnDefault = 5,    -- aviso (ambar) con <= N unidades (0 = sin aviso)
        chat = true,
        sound = false,
        soundWarn = "IG_QUEST_LIST_COMPLETE",
        soundCrit = "RAID_WARNING",
        alertEvery = 20,    -- segundos minimos entre avisos de la misma entrada
        deferCombat = true, -- no avisar en combate
        tooltip = true,     -- desglose en el tooltip
        preset = 1,
        colors = {
            normal = { 1, 1, 1 }, warn = { 1, 0.78, 0.1 }, crit = { 1, 0.15, 0.1 }, ok = { 0.3, 1, 0.4 },
        },
        clickAdd = "ctrlalt", -- "ctrlalt" | "shiftcfg" | "off"
        maxEntries = 24,
        refresh = 0.25,     -- segundos entre lecturas tras un cambio
        hideInCombat = false, -- ocultar la barra en combate
        showEmpty = true,   -- mostrar el hueco "+" cuando la lista esta vacia
    },
    pos = { point = "TOPLEFT", rel = "CENTER", x = -120, y = -160 },
    chars = {},
}

local PRESETS = {
    { name = "Clasico",        normal = { 1, 1, 1 },          warn = { 1, 0.78, 0.1 }, crit = { 1, 0.15, 0.1 }, ok = { 0.3, 1, 0.4 } },
    { name = "Daltonico",      normal = { 1, 1, 1 },          warn = { 0.35, 0.7, 1 }, crit = { 1, 0.35, 0.95 }, ok = { 0.9, 0.9, 0.2 } },
    { name = "Suave",          normal = { 0.85, 0.9, 0.95 },  warn = { 0.95, 0.65, 0.3 }, crit = { 0.95, 0.35, 0.35 }, ok = { 0.5, 0.9, 0.6 } },
    { name = "Alto contraste", normal = { 1, 1, 1 },          warn = { 1, 1, 0 },      crit = { 1, 0, 0 },      ok = { 0, 1, 0 } },
}

local SOUND_OPTIONS = {
    { "RAID_WARNING", "Aviso de banda" },
    { "IG_QUEST_LIST_COMPLETE", "Mision completada" },
    { "READY_CHECK", "Comprobacion de listos" },
    { "IG_MAINMENU_OPEN", "Menu abierto" },
}

local CLICK_OPTIONS = {
    { "ctrlalt", "Ctrl+Alt+clic en un objeto" },
    { "shiftcfg", "Mayus+clic (con esta pestana abierta)" },
    { "off", "Desactivado" },
}

local mod
local DB, CH, KEY
local rt = setmetatable({}, { __mode = "k" })   -- estado de ejecucion por entrada (nivel, ultimo aviso)
local Render, RefreshConfig, SavePos, ApplyStyle
local bar, buttons = nil, {}
local catWin
local charsRef          -- referencia a DB.chars (sobrevive a "Restaurar valores")
local extra             -- marco con eventos opcionales (pueden no existir en el cliente)

local function Print(msg)
    mod:Print(msg)
end


local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = DeepCopy(v) end
    return r
end

local function Clean(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function Num(v)
    v = Clean(v)
    return tonumber(v)
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

local function Entries()
    return (CH and CH.entries) or {}
end

local function FmtNum(n)
    n = n or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local function Palette()
    return DB.style.colors
end

----------------------------------------------------------------------
-- Datos de objetos y monedas
----------------------------------------------------------------------
local function Instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, a, b, c, d, e, cl, sc = pcall(f, id)
    if not ok or not a then return nil end
    -- itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID
    return a, b, c, d, e, cl, sc
end

local function ItemInfo(id)
    local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not f then return nil end
    local ok, name, link = pcall(f, id)
    if ok and name then return name, link end
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    return nil
end

local function CurrencyInfo(id)
    if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return nil end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
    if ok and type(info) == "table" then return info end
    return nil
end

local function EntryIcon(e)
    if e.kind == "currency" then
        local info = CurrencyInfo(e.id)
        return (info and Clean(info.iconFileID)) or QMARK
    end
    local _, _, _, _, icon = Instant(e.id)
    return icon or QMARK
end

local function EntryName(e)
    if e.kind == "currency" then
        local info = CurrencyInfo(e.id)
        return (info and Clean(info.name)) or ("moneda " .. e.id), true
    end
    local name = ItemInfo(e.id)
    return name or ("objeto " .. e.id), name ~= nil
end

local function EntryLabel(kind, id)
    if kind == "currency" then
        local info = CurrencyInfo(id)
        return (info and Clean(info.name)) or ("moneda " .. id)
    end
    local name, link = ItemInfo(id)
    return link or name or ("objeto " .. id)
end

-- Cuenta de una entrada. Devuelve total y desglose.
local function CountOf(e)
    if e.kind == "currency" then
        local info = CurrencyInfo(e.id)
        local q = info and Num(info.quantity) or 0
        return q, { cur = q, max = info and Num(info.maxQuantity) or 0 }
    end
    local get = C_Item and C_Item.GetItemCount
    if not get then return 0, { bags = 0, bank = 0, others = 0 } end
    local ok, bags = pcall(get, e.id, false)
    bags = ok and Num(bags) or 0
    local bank = 0
    if e.bank then
        local ok2, all = pcall(get, e.id, true, false, true)
        all = ok2 and Num(all) or bags
        bank = math.max(0, all - bags)
    end
    local others = 0
    if e.others and type(CMBancoCount) == "function" then
        local ok3, o = pcall(CMBancoCount, e.id, true)
        others = ok3 and Num(o) or 0
    end
    return bags + bank + others, { bags = bags, bank = bank, others = others }
end

-- 0 normal, 1 aviso, 2 critico
local function LevelOf(e, count)
    if count <= 0 then return 2 end
    local warn = e.warn
    if warn == nil then warn = DB.style.warnDefault end
    if warn and warn > 0 and count <= warn then return 1 end
    return 0
end

----------------------------------------------------------------------
-- Alta y baja de entradas
----------------------------------------------------------------------
local function Find(kind, id)
    for i, e in ipairs(Entries()) do
        if e.kind == kind and e.id == id then return i, e end
    end
end

local function AddEntry(kind, id, quiet)
    if not DB or not CH then return false end
    id = tonumber(id)
    if not id or id <= 0 then return false end
    if Find(kind, id) then
        if not quiet then Print("ya esta en la lista: " .. EntryLabel(kind, id)) end
        return false
    end
    local list = Entries()
    if #list >= (DB.style.maxEntries or 24) then
        Print("maximo " .. (DB.style.maxEntries or 24) .. " entradas por personaje.")
        return false
    end
    if kind == "item" then
        if not Instant(id) then Print("no conozco el objeto " .. id .. "."); return false end
    else
        if not CurrencyInfo(id) then Print("no conozco la moneda " .. id .. "."); return false end
    end
    list[#list + 1] = { kind = kind, id = id, bank = false, others = false }
    Print("anadido: " .. EntryLabel(kind, id))
    Render()
    if RefreshConfig then RefreshConfig() end
    return true
end

local function RemoveEntry(entry)
    local list = Entries()
    for i, e in ipairs(list) do
        if e == entry then
            table.remove(list, i)
            Print("quitado: " .. EntryLabel(e.kind, e.id))
            Render()
            if RefreshConfig then RefreshConfig() end
            return true
        end
    end
    return false
end

local function MoveEntry(i, j)
    local list = Entries()
    if i < 1 or i > #list or j < 1 or j > #list or i == j then return false end
    local e = table.remove(list, i)
    table.insert(list, j, e)
    Render()
    if RefreshConfig then RefreshConfig() end
    return true
end

local function AskRemove(entry)
    if not entry then return end
    if StaticPopup_Show and StaticPopupDialogs then
        StaticPopupDialogs["CERVECEROSMENDIGOSCONTADOR_QUITAR"] = StaticPopupDialogs["CERVECEROSMENDIGOSCONTADOR_QUITAR"] or {
            text = "Quitar %s del contador?",
            button1 = "Quitar", button2 = "Cancelar",
            OnAccept = function(dialog, data)
                data = data or (dialog and dialog.data)
                if data then RemoveEntry(data) end
            end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("CERVECEROSMENDIGOSCONTADOR_QUITAR", (EntryName(entry)), nil, entry)
    else
        RemoveEntry(entry)
    end
end

-- Interpreta un enlace, "currency:ID", un numero o un nombre
local function ParseTarget(arg)
    arg = arg and strtrim and strtrim(arg) or arg
    if not arg or arg == "" then return nil end
    local id = string.match(arg, "|Hitem:(%d+)")
    if id then return "item", tonumber(id) end
    id = string.match(arg, "|Hcurrency:(%d+)")
    if id then return "currency", tonumber(id) end
    id = string.match(arg, "^currency:(%d+)$") or string.match(arg, "^moneda:(%d+)$")
    if id then return "currency", tonumber(id) end
    id = string.match(arg, "^item:(%d+)$") or string.match(arg, "^(%d+)$")
    if id then return "item", tonumber(id) end
    local found = Instant(arg)
    if found then return "item", tonumber(found) end
    return nil
end

local function CursorThing()
    if not GetCursorInfo then return nil end
    local t, a = GetCursorInfo()
    if Clean(t) == nil or Clean(a) == nil then return nil end
    if t == "item" then return "item", tonumber(a) end
    if t == "currency" then return "currency", tonumber(a) end
    return nil
end

local function AddFromCursor()
    local kind, id = CursorThing()
    if not kind or not id then return false end
    AddEntry(kind, id)
    if ClearCursor then ClearCursor() end
    return true
end

----------------------------------------------------------------------
-- Avisos al quedarte corto
----------------------------------------------------------------------
local function Notify(e, count, level)
    local r = rt[e]
    local now = GetTime()
    if r.t and now - r.t < (DB.style.alertEvery or 20) then return end
    r.t = now
    local label = EntryLabel(e.kind, e.id)
    local msg
    if level == 2 then
        msg = "|cffff3030Te has quedado sin|r " .. label .. "."
    else
        local warn = e.warn
        if warn == nil then warn = DB.style.warnDefault end
        msg = string.format("|cffffc61aTe quedan %d|r de %s (aviso con %d o menos).", count, label, warn or 0)
    end
    if DB.style.chat then Print(msg) end
    if DB.style.sound and PlaySound and SOUNDKIT then
        PlaySound(SOUNDKIT[level == 2 and DB.style.soundCrit or DB.style.soundWarn] or SOUNDKIT.RAID_WARNING)
    end
end

-- Avisa solo cuando el nivel sube (cruce de umbral). La primera lectura es silenciosa.
-- En combate no cambia el nivel recordado: se avisa en la primera lectura posterior.
local function CheckAlert(e, count, level)
    local r = rt[e]
    if not r then r = {}; rt[e] = r end
    if not r.init then r.init = true; r.level = level; return end
    if level < r.level then r.level = level; return end
    if level > r.level then
        if DB.style.deferCombat and InCombat() then return end
        r.level = level
        Notify(e, count, level)
    end
end

----------------------------------------------------------------------
-- Barra en pantalla
----------------------------------------------------------------------
local drag = { active = false }
local ghost

local function Nearest(x, y)
    local best, bd
    for i = 1, #Entries() do
        local b = buttons[i]
        if b and b:IsShown() then
            local cx, cy = b:GetCenter()
            if cx then
                local d = (cx - x) ^ 2 + (cy - y) ^ 2
                if not bd or d < bd then best, bd = i, d end
            end
        end
    end
    return best
end

local function StartReorder(b)
    if not b.entry then return false end
    drag.active, drag.from = true, b.index
    if not ghost then
        ghost = mod:Frame("Frame", nil, UIParent)
        ghost:SetSize(32, 32)
        ghost:SetFrameStrata("TOOLTIP")
        ghost.tex = ghost:CreateTexture(nil, "OVERLAY")
        ghost.tex:SetAllPoints()
        ghost:Hide()
    end
    ghost:SetSize(DB.style.iconSize, DB.style.iconSize)
    ghost.tex:SetTexture(EntryIcon(b.entry))
    ghost:SetAlpha(0.8)
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)
    end)
    ghost:Show()
    return true
end

local function StopReorder()
    if not drag.active then return end
    drag.active = false
    if ghost then ghost:Hide(); ghost:SetScript("OnUpdate", nil) end
    local x, y = GetCursorPosition()
    local s = bar:GetEffectiveScale()
    local target = Nearest(x / s, y / s)
    if target and drag.from and target ~= drag.from then MoveEntry(drag.from, target) end
end

local function TooltipFor(b)
    local e = b.entry
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    if not e then
        GameTooltip:AddLine("CervecerosMendigosContador", 0.2, 1, 0.6)
        GameTooltip:AddLine("Arrastra aqui un objeto o una moneda,", 1, 1, 1)
        GameTooltip:AddLine("o usa /contador para configurarlo.", 1, 1, 1)
        GameTooltip:Show()
        return
    end
    if e.kind == "currency" then
        local done = false
        if GameTooltip.SetCurrencyByID then done = pcall(GameTooltip.SetCurrencyByID, GameTooltip, e.id) end
        if not done then GameTooltip:AddLine((EntryName(e)), 1, 1, 1) end
    else
        local done = false
        if GameTooltip.SetItemByID then done = pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end
        if not done then GameTooltip:AddLine((EntryName(e)), 1, 1, 1) end
    end
    if DB.style.tooltip then
        GameTooltip:AddLine(" ")
        local total, d = CountOf(e)
        if e.kind == "currency" then
            GameTooltip:AddLine("Tienes: " .. total .. ((d.max and d.max > 0) and (" / " .. d.max) or ""), 0.6, 1, 0.8)
        else
            local get = C_Item and C_Item.GetItemCount
            local bags = d.bags or 0
            local bankAll = 0
            if get then
                local ok, all = pcall(get, e.id, true, false, true)
                all = ok and Num(all) or bags
                bankAll = math.max(0, all - bags)
            end
            GameTooltip:AddLine("Total mostrado: " .. total, 0.6, 1, 0.8)
            GameTooltip:AddLine("  En bolsas: " .. bags, 1, 1, 1)
            GameTooltip:AddLine("  En el banco: " .. bankAll .. (e.bank and "" or " (no cuenta)"), 1, 1, 1)
            if type(CMBancoCount) == "function" then
                local ok, others = pcall(CMBancoCount, e.id, true)
                others = ok and Num(others) or 0
                GameTooltip:AddLine("  Otros personajes: " .. others .. (e.others and "" or " (no cuenta)"), 1, 1, 1)
                if others > 0 and type(CMBancoDetalle) == "function" then
                    local ok2, txt = pcall(CMBancoDetalle, e.id, true)
                    if ok2 and type(txt) == "string" and txt ~= "" then GameTooltip:AddLine("    " .. txt, 0.7, 0.7, 0.7, true) end
                end
            end
        end
        if e.goal then GameTooltip:AddLine("Objetivo: " .. e.goal, 1, 0.82, 0) end
    end
    GameTooltip:AddLine("Clic derecho: quitar", 0.7, 0.7, 0.7)
    if not DB.style.locked then GameTooltip:AddLine("Arrastrar: mover la barra | Mayus+arrastrar: reordenar", 0.7, 0.7, 0.7) end
    GameTooltip:Show()
end

local function MakeButton(i)
    local b = mod:Frame("Button", nil, bar)
    b.index = i
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.border:SetPoint("TOPLEFT", b.icon, "TOPLEFT", -2, 2)
    b.border:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 2, -2)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b:SetScript("OnEnter", TooltipFor)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, button)
        if CursorThing() then AddFromCursor(); return end
        if button == "RightButton" and self.entry then AskRemove(self.entry) end
    end)
    b:SetScript("OnReceiveDrag", function() AddFromCursor() end)
    b:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown and IsShiftKeyDown() then
            StartReorder(self)
        elseif not DB.style.locked then
            bar:StartMoving()
            bar.moving = true
        end
    end)
    b:SetScript("OnDragStop", function()
        if drag.active then
            StopReorder()
        elseif bar.moving then
            bar:StopMovingOrSizing(); bar.moving = false; SavePos()
        end
    end)
    return b
end

local function GetButton(i)
    if not buttons[i] then buttons[i] = MakeButton(i) end
    return buttons[i]
end

local function ColorOf(level, done)
    local p = Palette()
    if level == 2 then return p.crit end
    if level == 1 then return p.warn end
    if done then return p.ok end
    return p.normal
end

Render = function()
    if not bar or not DB then return end
    if not mod:IsEnabled() then return end
    if DB.style.hideInCombat and InCombat() then bar:Hide(); return end
    bar:Show()
    local list, st = Entries(), DB.style
    local n = #list
    local size, fsz, sp = st.iconSize, st.fontSize, st.spacing
    local horiz = st.orient ~= "V"
    local x, y, maxW, maxH = 0, 0, 1, 1
    local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    local used = n
    if n == 0 and st.showEmpty then used = 1 end
    for i = 1, used do
        local b = GetButton(i)
        local e = list[i]
        b.entry = e
        b.index = i
        b.icon:SetSize(size, size)
        b.icon:ClearAllPoints()
        b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
        b.count:SetFont(font, fsz, "OUTLINE")
        b.count:ClearAllPoints()
        if e then
            local count, _ = CountOf(e)
            local level = LevelOf(e, count)
            local done = e.goal and count >= e.goal or false
            CheckAlert(e, count, level)
            b.icon:SetTexture(EntryIcon(e))
            if b.icon.SetDesaturated then b.icon:SetDesaturated(count <= 0) end
            b.icon:SetAlpha(count <= 0 and 0.55 or 1)
            local c = ColorOf(level, done)
            b.count:SetTextColor(c[1], c[2], c[3])
            if level == 0 and not done then
                b.border:SetColorTexture(0, 0, 0, 0.85)
            else
                b.border:SetColorTexture(c[1], c[2], c[3], 1)
            end
            b.count:SetText(e.goal and (FmtNum(count) .. "/" .. FmtNum(e.goal)) or FmtNum(count))
        else
            b.icon:SetTexture(QMARK)
            if b.icon.SetDesaturated then b.icon:SetDesaturated(true) end
            b.icon:SetAlpha(0.6)
            b.border:SetColorTexture(0.4, 0.4, 0.4, 0.9)
            b.count:SetTextColor(1, 1, 1)
            b.count:SetText("+")
        end
        local textW = tonumber(b.count:GetStringWidth()) or 0
        local w, h = size, size
        if st.textBelow then
            b.count:SetPoint("TOP", b.icon, "BOTTOM", 0, -2)
            h = size + fsz + 4
        else
            b.count:SetPoint("BOTTOM", b.icon, "BOTTOM", 0, 2)
        end
        w = math.max(size, textW + 2)
        b:SetSize(w, h)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, y)
        b:Show()
        if w > maxW then maxW = w end
        if h > maxH then maxH = h end
        if horiz then x = x + w + sp else y = y - (h + sp) end
    end
    for i = used + 1, #buttons do
        buttons[i].entry = nil
        buttons[i]:Hide()
    end
    if horiz then bar:SetSize(math.max(1, x - sp), maxH) else bar:SetSize(maxW, math.max(1, -y - sp)) end
end

SavePos = function()
    if not bar then return end
    local point, _, rel, x, y = bar:GetPoint()
    DB.pos = { point = point or "TOPLEFT", rel = rel or "CENTER", x = x or 0, y = y or 0 }
end

local function CreateBar()
    bar = mod:Frame("Frame", "CervecerosMendigosContadorBarra", UIParent)
    bar:SetSize(40, 40)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScale((DB.style.scale or 100) / 100)
    bar:SetAlpha((DB.style.alpha or 100) / 100)
    local p = DB.pos
    bar:SetPoint(p.point or "TOPLEFT", UIParent, p.rel or "CENTER", p.x or 0, p.y or 0)
    bar:SetScript("OnDragStart", function(self)
        if not DB.style.locked then self:StartMoving(); self.moving = true end
    end)
    bar:SetScript("OnDragStop", function(self)
        if self.moving then self:StopMovingOrSizing(); self.moving = false; SavePos() end
    end)
    bar:SetScript("OnReceiveDrag", function() AddFromCursor() end)
end

local function ApplyPos()
    if not bar then return end
    local p = DB.pos
    bar:ClearAllPoints()
    bar:SetPoint(p.point or "TOPLEFT", UIParent, p.rel or "CENTER", p.x or 0, p.y or 0)
end

ApplyStyle = function()
    if bar then
        bar:SetScale((DB.style.scale or 100) / 100)
        bar:SetAlpha((DB.style.alpha or 100) / 100)
    end
    Render()
end

----------------------------------------------------------------------
-- Categorias (se construyen al vuelo con las bolsas, sin tablas grandes)
----------------------------------------------------------------------
local function NameHas(name, ...)
    if not name then return false end
    name = string.lower(name)
    for i = 1, select("#", ...) do
        if string.find(name, select(i, ...), 1, true) then return true end
    end
    return false
end

local CATS = {
    { name = "Pociones y elixires", test = function(id, cl, sc) return cl == 0 and (sc == 1 or sc == 2 or sc == 3) end },
    { name = "Comida y bebida",     test = function(id, cl, sc) return cl == 0 and sc == 5 end },
    { name = "Vendas",              test = function(id, cl, sc) return cl == 0 and sc == 7 end },
    { name = "Municion",            test = function(id, cl, sc) return cl == 6 end },
    { name = "Reactivos de clase",  test = function(id, cl, sc) return cl == 5 or id == 6265 end },
    { name = "Venenos",             test = function(id, cl, sc, name) return NameHas(name, "veneno", "poison") end },
    { name = "Piedras de hogar",    test = function(id, cl, sc, name) return id == 6948 or NameHas(name, "piedra de hogar", "hearthstone") end },
    { name = "Afilado y aceites",   test = function(id, cl, sc, name) return NameHas(name, "afilar", "sharpening", "contrapeso", "weightstone", "aceite", "wizard oil", "mana oil") end },
    { name = "Materiales",          test = function(id, cl, sc) return cl == 7 end },
    { name = "Monedas",             currency = true },
}

local function ScanBags()
    local found, order = {}, {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and Num(info.itemID)
            if id then
                if not found[id] then found[id] = { id = id, count = 0 }; order[#order + 1] = id end
                found[id].count = found[id].count + (Num(info.stackCount) or 1)
            end
        end
    end
    local res = {}
    for _, id in ipairs(order) do res[#res + 1] = found[id] end
    return res
end

local function CategoryResults(cat)
    local res = {}
    if cat.currency then
        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
            for i = 1, C_CurrencyInfo.GetCurrencyListSize() do
                local info = C_CurrencyInfo.GetCurrencyListInfo(i)
                if info and not Clean(info.isHeader) then
                    local link = C_CurrencyInfo.GetCurrencyListLink and C_CurrencyInfo.GetCurrencyListLink(i)
                    local id = link and tonumber(string.match(link, "currency:(%d+)"))
                    if id then res[#res + 1] = { kind = "currency", id = id, name = Clean(info.name) or ("moneda " .. id), count = Num(info.quantity) or 0 } end
                end
            end
        end
    else
        for _, it in ipairs(ScanBags()) do
            local _, _, _, _, _, cl, sc = Instant(it.id)
            local name = ItemInfo(it.id)
            if cl and cat.test(it.id, cl, sc, name) then
                res[#res + 1] = { kind = "item", id = it.id, name = name or ("objeto " .. it.id), count = it.count }
            end
        end
    end
    table.sort(res, function(a, b) return a.name < b.name end)
    return res
end
----------------------------------------------------------------------
-- Ayudas de interfaz (las ventanas de DATOS siguen existiendo; los ajustes van en la pestana)
----------------------------------------------------------------------
local UI = Hub.UI

local function MakeButtonUI(parent, text, w, h, point, x, y, onclick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h); b:SetPoint(point, x, y)
    b:SetText(text)
    b:SetScript("OnClick", onclick)
    return b
end

local function MakeCheckSimple(parent, label, x, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(26, 26)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    fs:SetText(label)
    cb.label = fs
    return cb
end

local function MakeEdit(parent, w, x, y, maxLetters)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(w, 20)
    eb:SetPoint("TOPLEFT", x, y)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters or 40)
    eb:SetFontObject("GameFontHighlight")
    return eb
end

----------------------------------------------------------------------
-- Ventana de categorias (ventana de datos)
----------------------------------------------------------------------
local catSel, catOffset, catRows, catResults = 1, 0, {}, {}
local CAT_ROWS = 12

local function RefreshCat()
    if not catWin then return end
    catResults = CategoryResults(CATS[catSel])
    local maxOff = math.max(0, #catResults - CAT_ROWS)
    if catOffset > maxOff then catOffset = maxOff end
    catWin.title:SetText(CATS[catSel].name .. (CATS[catSel].currency and " (tu lista de monedas)" or " (en tus bolsas)"))
    for i, r in ipairs(catRows) do
        local it = catResults[catOffset + i]
        if it then
            r.it = it
            local tex = it.kind == "currency" and EntryIcon({ kind = "currency", id = it.id }) or select(5, Instant(it.id)) or QMARK
            r.icon:SetTexture(tex)
            r.name:SetText(it.name .. "  |cffaaaaaa x" .. FmtNum(it.count) .. "|r")
            if Find(it.kind, it.id) then r.add:SetText("En lista"); r.add:Disable() else r.add:SetText("Anadir"); r.add:Enable() end
            r:Show()
        else
            r.it = nil
            r:Hide()
        end
    end
    catWin.empty:SetShown(#catResults == 0)
end

local function BuildCat()
    catWin = UI.MakeWindow("CervecerosMendigosContadorCategorias", "Anadir por categoria", 500, 440)
    mod:Track(catWin)
    catWin.title = catWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    catWin.title:SetPoint("TOPLEFT", 170, -34)
    for i, c in ipairs(CATS) do
        MakeButtonUI(catWin, c.name, 146, 24, "TOPLEFT", 14, -34 - (i - 1) * 27, function()
            catSel, catOffset = i, 0
            RefreshCat()
        end)
    end
    for i = 1, CAT_ROWS do
        local r = CreateFrame("Frame", nil, catWin)
        r:SetSize(320, 26)
        r:SetPoint("TOPLEFT", 170, -56 - (i - 1) * 28)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 0, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetWidth(190); r.name:SetJustifyH("LEFT")
        r.add = MakeButtonUI(r, "Anadir", 70, 22, "RIGHT", 0, 0, function()
            if r.it then AddEntry(r.it.kind, r.it.id); RefreshCat() end
        end)
        r:Hide()
        catRows[i] = r
    end
    catWin.empty = catWin:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    catWin.empty:SetPoint("TOPLEFT", 176, -70)
    catWin.empty:SetWidth(310); catWin.empty:SetJustifyH("LEFT")
    catWin.empty:SetText("No hay nada de esta categoria. Cuando lo tengas en las bolsas, vuelve a abrir esta lista.")
    catWin:EnableMouseWheel(true)
    catWin:SetScript("OnMouseWheel", function(_, delta)
        catOffset = math.max(0, math.min(math.max(0, #catResults - CAT_ROWS), catOffset - delta))
        RefreshCat()
    end)
    catWin:SetScript("OnShow", RefreshCat)
end

local function OpenCat(index)
    if not DB then return end
    if not mod:IsEnabled() then Print("modulo desactivado."); return end
    if not catWin then BuildCat() end
    if index then catSel, catOffset = index, 0 end
    catWin:Show()
    RefreshCat()
end

----------------------------------------------------------------------
-- Pestana: lista de objetos (editor de la entrada elegida) + ajustes
----------------------------------------------------------------------
local ROWS = 8
local sel, offset = 1, 0
local rows = {}
local edit = {}
local listEmpty

local function CurrentEntry()
    return Entries()[sel]
end

local function RefreshEdit()
    local e = CurrentEntry()
    if not edit.title then return end
    if not e then
        edit.title:SetText("Selecciona una entrada de la lista")
        edit.bank:Hide(); edit.others:Hide(); edit.warn:Hide(); edit.goal:Hide()
        edit.warnLbl:Hide(); edit.goalLbl:Hide(); edit.hint:Hide()
        return
    end
    edit.title:SetText("Editando: |cffffffff" .. (EntryName(e)) .. "|r")
    local isItem = e.kind == "item"
    edit.bank:SetShown(isItem); edit.others:SetShown(isItem)
    edit.bank:SetChecked(e.bank and true or false)
    edit.others:SetChecked(e.others and true or false)
    edit.warn:Show(); edit.goal:Show(); edit.warnLbl:Show(); edit.goalLbl:Show(); edit.hint:Show()
    edit.warn:SetText(e.warn ~= nil and tostring(e.warn) or "")
    edit.goal:SetText(e.goal and tostring(e.goal) or "")
    if isItem and type(CMBancoCount) ~= "function" then
        edit.others.label:SetText("Incluir otros personajes (necesita el modulo Banco)")
    else
        edit.others.label:SetText("Incluir otros personajes")
    end
end

RefreshConfig = function()
    if not DB or #rows == 0 then return end
    local list = Entries()
    if sel > #list then sel = #list end
    if sel < 1 then sel = 1 end
    local maxOff = math.max(0, #list - ROWS)
    if offset > maxOff then offset = maxOff end
    for i, r in ipairs(rows) do
        local idx = offset + i
        local e = list[idx]
        if e then
            r.idx = idx
            r.icon:SetTexture(EntryIcon(e))
            local count = CountOf(e)
            local name = EntryName(e)
            r.name:SetText(string.format("%s  |cffaaaaaa(%s)|r", name, FmtNum(count)))
            r.hl:SetShown(idx == sel)
            r.up:SetEnabled(idx > 1); r.down:SetEnabled(idx < #list)
            r:Show()
        else
            r.idx = nil
            r:Hide()
        end
    end
    if listEmpty then listEmpty:SetShown(#list == 0) end
    RefreshEdit()
end

local function ApplyEditBoxes()
    local e = CurrentEntry()
    if not e then return end
    local w = tonumber(edit.warn:GetText())
    e.warn = w and math.max(0, math.floor(w)) or nil
    local g = tonumber(edit.goal:GetText())
    e.goal = (g and g > 0) and math.floor(g) or nil
    Render()
    RefreshConfig()
end

local function AddFromText()
    local text = edit.add:GetText()
    local kind, id = ParseTarget(text)
    if not kind then
        Print("no encuentro ese objeto. Prueba con el enlace, el ID o arrastralo desde la mochila.")
        return
    end
    if AddEntry(kind, id) then edit.add:SetText("") end
end

-- Construye el bloque "objetos" dentro de un marco de 480x420 situado en L.y
local function BuildObjectsBlock(L, parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(480, 430)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", L.x, L.y)
    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Lo que se muestra en pantalla (clic para editar)")

    local listArea = CreateFrame("Frame", nil, p)
    listArea:SetPoint("TOPLEFT", 0, 0)
    listArea:SetSize(460, 22 + ROWS * 27)
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, listArea)
        r:SetSize(400, 26)
        r:SetPoint("TOPLEFT", 4, -22 - (i - 1) * 27)
        r.hl = r:CreateTexture(nil, "BACKGROUND")
        r.hl:SetAllPoints(); r.hl:SetColorTexture(0.2, 0.5, 0.9, 0.3); r.hl:Hide()
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 4, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetWidth(240); r.name:SetJustifyH("LEFT")
        r.up = MakeButtonUI(r, "^", 24, 22, "RIGHT", -56, 0, function() if r.idx then MoveEntry(r.idx, r.idx - 1); sel = math.max(1, r.idx - 1) end RefreshConfig() end)
        r.down = MakeButtonUI(r, "v", 24, 22, "RIGHT", -30, 0, function() if r.idx then MoveEntry(r.idx, r.idx + 1); sel = r.idx + 1 end RefreshConfig() end)
        r.del = MakeButtonUI(r, "x", 24, 22, "RIGHT", -2, 0, function() if r.idx then AskRemove(Entries()[r.idx]) end end)
        r:SetScript("OnClick", function(self) if self.idx then sel = self.idx; RefreshConfig() end end)
        r:SetScript("OnEnter", function(self)
            local e = self.idx and Entries()[self.idx]
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local ok = false
            if e.kind == "item" and GameTooltip.SetItemByID then ok = pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end
            if not ok then GameTooltip:AddLine((EntryName(e)), 1, 1, 1) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        rows[i] = r
    end
    listEmpty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    listEmpty:SetPoint("TOPLEFT", 14, -40)
    listEmpty:SetWidth(380); listEmpty:SetJustifyH("LEFT")
    listEmpty:SetText("La lista esta vacia. Arrastra un objeto de la mochila al cuadro de abajo o a la barra, o usa las categorias.")
    listArea:EnableMouseWheel(true)
    listArea:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, math.min(math.max(0, #Entries() - ROWS), offset - delta))
        RefreshConfig()
    end)

    -- editor de la entrada elegida
    local y = -246
    edit.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    edit.title:SetPoint("TOPLEFT", 4, y)
    edit.bank = MakeCheckSimple(p, "Incluir el banco", 0, y - 14)
    edit.bank:SetScript("OnClick", function(self)
        local e = CurrentEntry(); if e then e.bank = self:GetChecked() and true or false; Render(); RefreshConfig() end
    end)
    edit.others = MakeCheckSimple(p, "Incluir otros personajes", 0, y - 38)
    edit.others:SetScript("OnClick", function(self)
        local e = CurrentEntry(); if e then e.others = self:GetChecked() and true or false; Render(); RefreshConfig() end
    end)
    edit.warnLbl = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    edit.warnLbl:SetPoint("TOPLEFT", 8, y - 68)
    edit.warnLbl:SetText("Avisar con (o menos):")
    edit.warn = MakeEdit(p, 54, 160, y - 64, 5)
    edit.goalLbl = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    edit.goalLbl:SetPoint("TOPLEFT", 232, y - 68)
    edit.goalLbl:SetText("Objetivo:")
    edit.goal = MakeEdit(p, 54, 296, y - 64, 5)
    for _, box in ipairs({ edit.warn, edit.goal }) do
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyEditBoxes() end)
        box:SetScript("OnEditFocusLost", function() ApplyEditBoxes() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); RefreshEdit() end)
    end
    edit.hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    edit.hint:SetPoint("TOPLEFT", 8, y - 88)
    edit.hint:SetText("Aviso vacio = el valor por defecto de abajo. Objetivo vacio = sin objetivo.")

    -- anadir
    local y2 = -350
    local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 4, y2)
    lbl:SetText("Anadir")
    local drop = MakeButtonUI(p, "Suelta aqui un objeto o moneda", 400, 30, "TOPLEFT", 4, y2 - 18, function()
        if not AddFromCursor() then Print("coge un objeto o una moneda con el raton y sueltalo aqui.") end
    end)
    drop:SetScript("OnReceiveDrag", function() AddFromCursor() end)
    edit.add = MakeEdit(p, 270, 12, y2 - 56, 120)
    edit.add:SetScript("OnEnterPressed", function(self) self:ClearFocus(); AddFromText() end)
    MakeButtonUI(p, "Anadir", 110, 22, "TOPLEFT", 294, y2 - 55, AddFromText)
    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 8, y2 - 78)
    hint:SetText("Pega un enlace, un ID o un nombre. Tambien: arrastra a la barra o usa el clic con modificador.")
    MakeButtonUI(p, "Por categoria...", 190, 24, "TOPLEFT", 4, y2 - 96, function() OpenCat() end)
    MakeButtonUI(p, "Monedas...", 190, 24, "TOPLEFT", 214, y2 - 96, function() OpenCat(#CATS) end)
    L:Add({ Refresh = RefreshConfig }, 440)
    return p
end

local function ApplyPreset(i)
    local pr = PRESETS[i]
    if not pr then return end
    DB.style.preset = i
    DB.style.colors = { normal = { unpack(pr.normal) }, warn = { unpack(pr.warn) }, crit = { unpack(pr.crit) }, ok = { unpack(pr.ok) } }
end

local function BuildConfig(m, L, parent)
    local st = DB.style
    L:Header("Objetos de la barra")
    L:Text("Cada personaje tiene su propia lista. Con /contador copiar Nombre-Reino copias la de otro.", true)
    BuildObjectsBlock(L, parent)

    L:Header("Aspecto de la barra")
    L:Choice("Orientacion", { { "H", "Horizontal" }, { "V", "Vertical" } },
        function() return st.orient end, function(v) st.orient = v; ApplyStyle() end)
    L:Slider("Tamano del icono", 20, 72, 1, function() return st.iconSize end, function(v) st.iconSize = v; ApplyStyle() end)
    L:Slider("Tamano del numero", 8, 32, 1, function() return st.fontSize end, function(v) st.fontSize = v; ApplyStyle() end)
    L:Slider("Separacion", 0, 30, 1, function() return st.spacing end, function(v) st.spacing = v; ApplyStyle() end)
    L:Slider("Escala de la barra (%)", 50, 200, 5, function() return st.scale end, function(v) st.scale = v; ApplyStyle() end)
    L:Slider("Opacidad (%)", 20, 100, 5, function() return st.alpha end, function(v) st.alpha = v; ApplyStyle() end)
    L:Check("Numero debajo del icono", function() return st.textBelow end, function(v) st.textBelow = v; ApplyStyle() end)
    L:Check("Mostrar el hueco '+' cuando la lista esta vacia", function() return st.showEmpty end, function(v) st.showEmpty = v; ApplyStyle() end)
    L:Check("Ocultar la barra en combate", function() return st.hideInCombat end, function(v) st.hideInCombat = v; Render() end)
    L:Check("Bloquear la posicion de la barra", function() return st.locked end, function(v) st.locked = v end)
    L:Check("Desglose en el tooltip", function() return st.tooltip end, function(v) st.tooltip = v end)

    L:Header("Colores")
    local presetBtn = L:Choice("Esquema de color (rellena los 4 colores)", (function()
        local o = {}
        for i, pr in ipairs(PRESETS) do o[i] = { i, pr.name } end
        return o
    end)(), function() return st.preset end, function(v) ApplyPreset(v); ApplyStyle(); L:Refresh() end)
    L:Color("Normal", function() return unpack(st.colors.normal) end, function(r, g, b) st.colors.normal = { r, g, b }; ApplyStyle() end)
    L:Color("Aviso (te quedan pocos)", function() return unpack(st.colors.warn) end, function(r, g, b) st.colors.warn = { r, g, b }; ApplyStyle() end)
    L:Color("Critico (te has quedado sin)", function() return unpack(st.colors.crit) end, function(r, g, b) st.colors.crit = { r, g, b }; ApplyStyle() end)
    L:Color("Objetivo cumplido", function() return unpack(st.colors.ok) end, function(r, g, b) st.colors.ok = { r, g, b }; ApplyStyle() end)

    L:Header("Avisos")
    L:Slider("Aviso por defecto (unidades o menos, 0 = sin aviso)", 0, 50, 1,
        function() return st.warnDefault end, function(v) st.warnDefault = v; Render() end)
    L:Check("Avisar en el chat al quedarte corto", function() return st.chat end, function(v) st.chat = v end)
    L:Check("Sonido al avisar", function() return st.sound end, function(v) st.sound = v end)
    L:Choice("Sonido de aviso", SOUND_OPTIONS, function() return st.soundWarn end, function(v) st.soundWarn = v end)
    L:Choice("Sonido de aviso critico", SOUND_OPTIONS, function() return st.soundCrit end, function(v) st.soundCrit = v end)
    L:Slider("Pausa minima entre avisos de un objeto (segundos)", 0, 300, 5,
        function() return st.alertEvery end, function(v) st.alertEvery = v end)
    L:Check("No avisar en combate (esperar a salir)", function() return st.deferCombat end, function(v) st.deferCombat = v end)

    L:Header("Avanzado")
    L:Choice("Anadir objetos con clic", CLICK_OPTIONS, function() return st.clickAdd end, function(v) st.clickAdd = v end)
    L:Slider("Maximo de entradas por personaje", 4, 40, 1, function() return st.maxEntries end, function(v) st.maxEntries = v end)
    L:Slider("Lectura tras un cambio (segundos)", 0.1, 2, 0.05,
        function() return st.refresh end, function(v) st.refresh = v end, "%.2f")
    L:Button("Mover la barra", 140, function()
        st.locked = false; L:Refresh()
        Print("barra desbloqueada: arrastrala con el raton. Marca 'Bloquear la posicion' para fijarla.")
    end)
    L:Button("Vaciar mi lista", 140, function()
        CH.entries = {}; sel, offset = 1, 0
        Render(); RefreshConfig()
        Print("lista vaciada.")
    end, true)
end

----------------------------------------------------------------------
-- Anadir con clic (gancho seguro sobre HandleModifiedItemClick)
----------------------------------------------------------------------
local hooked = false
local function HookClicks()
    if hooked or not hooksecurefunc or type(HandleModifiedItemClick) ~= "function" then return end
    hooked = true
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not mod or not mod:IsEnabled() or not DB or type(link) ~= "string" then return end
        if issecretvalue and issecretvalue(link) then return end
        local mode = DB.style.clickAdd
        local use = false
        if mode == "ctrlalt" then
            use = IsControlKeyDown() and IsAltKeyDown()
        elseif mode == "shiftcfg" then
            local editing = ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow()
            local open = mod.panel and mod.panel.IsVisible and mod.panel:IsVisible()
            use = IsShiftKeyDown() and open and not editing
        end
        if not use then return end
        local kind, id = ParseTarget(link)
        if kind and id then AddEntry(kind, id) end
    end)
end

----------------------------------------------------------------------
-- Comandos
----------------------------------------------------------------------
local function FindChar(text)
    text = string.lower(text or "")
    if text == "" then return nil end
    local exact, partial
    for key, c in pairs(DB.chars) do
        local k = string.lower(key)
        if key ~= KEY and c.entries and #c.entries > 0 then
            if k == text then exact = key
            elseif string.find(k, text, 1, true) == 1 then partial = partial or key end
        end
    end
    return exact or partial
end

local function OnSlash(m, msg)
    msg = msg or ""
    local cmd, rest = string.match(msg, "^(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    if cmd == "" or cmd == "config" then
        Hub:Open("contador")
    elseif cmd == "anadir" or cmd == "añadir" or cmd == "add" then
        local kind, id = ParseTarget(rest)
        if kind then AddEntry(kind, id) else Print("uso: /contador anadir [enlace del objeto] | ID | nombre | currency:ID") end
    elseif cmd == "quitar" or cmd == "borrar" or cmd == "del" then
        local kind, id = ParseTarget(rest)
        local _, e = nil, nil
        if kind then _, e = Find(kind, id) end
        if e then RemoveEntry(e) else Print("ese objeto no esta en tu lista.") end
    elseif cmd == "lista" or cmd == "estado" then
        local list = Entries()
        if #list == 0 then Print("la lista esta vacia.") end
        for i, e in ipairs(list) do
            local count = CountOf(e)
            Print(string.format("%d. %s: %s%s", i, EntryLabel(e.kind, e.id), FmtNum(count), e.goal and ("/" .. e.goal) or ""))
        end
    elseif cmd == "mover" or cmd == "desbloquear" then
        DB.style.locked = false
        Print("barra desbloqueada: arrastrala con el raton. /contador bloquear para fijarla.")
    elseif cmd == "bloquear" then
        DB.style.locked = true
        Print("barra bloqueada.")
    elseif cmd == "copiar" then
        local key = FindChar(rest)
        if not key then
            local names = {}
            for k, c in pairs(DB.chars) do if k ~= KEY and c.entries and #c.entries > 0 then names[#names + 1] = k end end
            table.sort(names)
            Print("uso: /contador copiar Nombre-Reino. Disponibles: " .. (#names > 0 and table.concat(names, ", ") or "ninguno"))
        else
            CH.entries = DeepCopy(DB.chars[key].entries)
            sel, offset = 1, 0
            Render(); RefreshConfig()
            Print("copiada la lista de " .. key .. " (" .. #CH.entries .. " entradas).")
        end
    elseif cmd == "colores" then
        ApplyPreset(DB.style.preset % #PRESETS + 1)
        ApplyStyle()
        Print("colores: " .. PRESETS[DB.style.preset].name)
    elseif cmd == "vaciar" then
        CH.entries = {}
        sel, offset = 1, 0
        Render(); RefreshConfig()
        Print("lista vaciada.")
    else
        Print("/contador = configuracion | anadir X | quitar X | lista | mover | bloquear | copiar Nombre-Reino | colores | vaciar")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local dirty, acc = true, 0
local EXTRA_EVENTS = { "ITEM_COUNT_CHANGED", "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "CURRENCY_DISPLAY_UPDATE" }

local function BindChar()
    local name = UnitName and UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    KEY = tostring(name) .. "-" .. tostring(realm)
    DB.chars = DB.chars or charsRef or {}
    charsRef = DB.chars
    DB.chars[KEY] = DB.chars[KEY] or {}
    CH = DB.chars[KEY]
    CH.entries = CH.entries or {}
end

mod = Hub:Register{
    key = "contador", dir = "Contador", name = "Contador de objetos",
    desc = "Barra en pantalla con cuantas unidades tienes de los objetos o monedas que elijas, sin abrir la mochila. Colores por umbrales, objetivos y avisos.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosContadorDB",
    slash = { "contador", "cmcontador" },

    Init = function(m)
        DB = m.db
        BindChar()
        CreateBar()
        HookClicks()
        local function Mark() dirty = true end
        m:Event("PLAYER_LOGIN", function()
            HookClicks(); dirty = true
            if #Entries() == 0 and not CH.hinted then
                CH.hinted = true
                Print("barra vacia: arrastra un objeto de la mochila a la barra o usa /contador. Con /contador copiar Nombre-Reino copias la lista de otro personaje.")
            end
        end)
        m:Event("PLAYER_ENTERING_WORLD", Mark)
        m:Event("BAG_UPDATE_DELAYED", Mark)
        m:Event("PLAYER_EQUIPMENT_CHANGED", Mark)
        m:Event("PLAYER_REGEN_ENABLED", function() dirty = true end)
        m:Event("PLAYER_REGEN_DISABLED", function() if DB.style.hideInCombat then dirty = true end end)
        m:Event("GET_ITEM_INFO_RECEIVED", function()
            dirty = true
            RefreshConfig()
            if catWin and catWin:IsShown() then RefreshCat() end
        end)
        -- eventos que puede que el cliente no tenga: se registran con pcall en otro marco
        extra = m:Frame("Frame")
        extra:SetScript("OnEvent", function() dirty = true end)
        m:OnUpdate(function(_, elapsed)
            if not dirty then return end
            acc = acc + elapsed
            if acc < (DB.style.refresh or 0.25) then return end
            acc = 0
            dirty = false
            Render()
            if m.panel and m.panel.IsVisible and m.panel:IsVisible() then RefreshConfig() end
        end)
    end,

    Enable = function(m)
        DB = m.db
        BindChar()
        for _, e in ipairs(EXTRA_EVENTS) do pcall(extra.RegisterEvent, extra, e) end
        ApplyStyle(); ApplyPos()
        dirty = true; acc = 99
        bar:Show()
        Render()
    end,

    Disable = function(m)
        if extra then extra:UnregisterAllEvents() end
        if bar then bar:Hide() end
        if catWin then catWin:Hide() end
        StopReorder()
    end,

    OnReset = function(m)
        -- Hub vacia mod.db: devolvemos las listas de objetos de todos los personajes
        if charsRef then m.db.chars = charsRef end
        DB = m.db
        BindChar()
        if m:IsEnabled() then ApplyStyle(); ApplyPos(); RefreshConfig() end
    end,

    BuildConfig = BuildConfig,
    OnSlash = OnSlash,
}
