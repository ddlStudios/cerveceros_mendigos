-- Modulo Avisos (CervecerosMendigosGeneral) para WoW Forever (Interface 16001).
-- Indicador en pantalla que solo aparece cuando hace falta: equipo roto o bolsas casi llenas.
-- Avisa una vez por cruce de umbral (chat + sonido opcional), sin molestar en combate.
-- Opcional: reparar y vender basura gris al abrir un vendedor.
-- Todo se configura en su pestana del panel (o con /avisos, /cmavisos).

local ADDON, ns = ...
local Hub = ns.Hub

local ICON_DUR = "Interface\\Icons\\INV_Hammer_20"
local ICON_BAG = "Interface\\Icons\\INV_Misc_Bag_08"

local DEFAULTS = {
    durWarn = 30,       -- % de durabilidad: aviso
    durCrit = 10,       -- % de durabilidad: aviso critico
    bagWarn = 4,        -- huecos libres <= : aviso
    bagCrit = 0,        -- huecos libres <= : aviso critico
    useAvg = false,     -- true: media del equipo; false: la pieza peor
    showDur = true,     -- vigilar durabilidad
    showBag = true,     -- vigilar bolsas
    countSpecialBags = false, -- contar tambien carcajes y bolsas especiales
    showAlways = false, -- mostrar el indicador aunque no haya aviso
    chatDur = true, chatBag = true,       -- avisar en el chat (por tipo)
    soundDur = false, soundBag = false,   -- sonido al cruzar un umbral (por tipo)
    soundWarn = "IG_QUEST_LIST_COMPLETE", -- sonido de aviso normal
    soundCrit = "RAID_WARNING",           -- sonido de aviso critico
    antispam = 60,      -- segundos minimos entre avisos del mismo tipo
    deferCombat = true, -- no avisar en combate: esperar a salir
    blink = true,       -- parpadeo suave de lo que tiene aviso
    locked = false,     -- indicador bloqueado (no se arrastra)
    autoRepair = false, -- reparar al abrir un vendedor
    autoSell = false,   -- vender basura gris al abrir un vendedor
    scale = 100,
    alpha = 100,
    refresh = 0.5,      -- segundos entre lecturas tras un cambio
    colorOk   = { 0.2, 1, 0.3 },
    colorWarn = { 1, 0.85, 0.1 },
    colorCrit = { 1, 0.15, 0.1 },
    pos = { point = "TOP", x = 0, y = -120 },
}

-- ranuras con durabilidad (se omiten camisa 4 y tabardo 19)
local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }

local mod
local state = { dur = nil, durLevel = 0, free = nil, total = nil, bagLevel = 0 }
local merchantOpen = false
local ind, durBox, bagBox
local Refresh

local function DB() return mod.db end

local function Money(c)
    if GetMoneyString then return GetMoneyString(c, true) end
    if GetCoinTextureString then return GetCoinTextureString(c) end
    return tostring(c) .. " cobre"
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

----------------------------------------------------------------------
-- Lectura de datos
----------------------------------------------------------------------
local function ReadDurability()
    local minPct, sum, n = nil, 0, 0
    for i = 1, #SLOTS do
        local cur, max = GetInventoryItemDurability(SLOTS[i])
        if cur and max and max > 0 then
            local p = cur / max * 100
            n = n + 1; sum = sum + p
            if not minPct or p < minPct then minPct = p end
        end
    end
    if n == 0 then return nil end
    if DB().useAvg then return sum / n end
    return minPct
end

local function ReadBags()
    local free, total = 0, 0
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        local f, family = C_Container.GetContainerNumFreeSlots(bag)
        local t = C_Container.GetContainerNumSlots(bag)
        if t and t > 0 and (DB().countSpecialBags or family == nil or family == 0) then
            free = free + (f or 0); total = total + t
        end
    end
    return free, total
end

local function DurLevel(p)
    if not p then return 0 end
    if p <= DB().durCrit then return 2 end
    if p <= DB().durWarn then return 1 end
    return 0
end

local function BagLevel(free)
    if not free then return 0 end
    if free <= DB().bagCrit then return 2 end
    if free <= DB().bagWarn then return 1 end
    return 0
end

local function LevelColor(level)
    local db = DB()
    if level == 2 then return db.colorCrit end
    if level == 1 then return db.colorWarn end
    return db.colorOk
end
local function Hex(level)
    local c = LevelColor(level)
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

local function RepairCostEstimate()
    local total, any = 0, false
    for i = 1, #SLOTS do
        local slot = SLOTS[i]
        local cost
        if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
            local data = C_TooltipInfo.GetInventoryItem("player", slot)
            cost = data and data.repairCost
        end
        if cost and not (issecretvalue and issecretvalue(cost)) then
            total = total + cost; any = true
        end
    end
    if any then return total end
    return nil
end

----------------------------------------------------------------------
-- Indicador en pantalla
----------------------------------------------------------------------
local function MakeBox(parent, texture)
    local b = mod:Frame("Frame", nil, parent)
    b:SetSize(80, 24)
    local ic = b:CreateTexture(nil, "ARTWORK")
    ic:SetSize(22, 22); ic:SetPoint("LEFT", 0, 0)
    ic:SetTexture(texture)
    local tx = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tx:SetPoint("LEFT", ic, "RIGHT", 4, 0)
    b.icon, b.text = ic, tx
    return b
end

local function SavePos()
    local point, _, _, x, y = ind:GetPoint()
    DB().pos = { point = point or "TOP", x = x or 0, y = y or 0 }
end

local function ApplyLook()
    if not ind then return end
    local db = DB()
    ind:SetScale((db.scale or 100) / 100)
    ind:SetAlpha((db.alpha or 100) / 100)
end

local function ApplyPos()
    if not ind then return end
    local p = DB().pos
    ind:ClearAllPoints()
    ind:SetPoint(p.point or "TOP", UIParent, p.point or "TOP", p.x or 0, p.y or -120)
end

local function CreateIndicator()
    ind = mod:Frame("Frame", "CervecerosMendigosAvisosIndicador", UIParent)
    ind:SetSize(180, 26)
    ind:SetFrameStrata("MEDIUM")
    ind:SetClampedToScreen(true)
    ind:SetMovable(true)
    ind:EnableMouse(true)
    ind:RegisterForDrag("LeftButton")
    ApplyLook(); ApplyPos()
    ind:SetScript("OnDragStart", function(self) if not DB().locked then self:StartMoving() end end)
    ind:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
    durBox = MakeBox(ind, ICON_DUR)
    bagBox = MakeBox(ind, ICON_BAG)

    ind:SetScript("OnEnter", function(self)
        local db = DB()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Avisos de equipo y bolsas", 0.2, 1, 0.6)
        if state.dur then
            GameTooltip:AddLine(string.format("Durabilidad %s: %s%d%%|r", db.useAvg and "(media)" or "(peor pieza)", Hex(state.durLevel), math.floor(state.dur + 0.5)), 1, 1, 1)
            local cost = RepairCostEstimate()
            if cost and cost > 0 then
                GameTooltip:AddLine("Reparar todo (estimado): " .. Money(cost), 1, 1, 1)
            elseif cost == 0 then
                GameTooltip:AddLine("Equipo sin desgaste", 0.7, 0.7, 0.7)
            end
        else
            GameTooltip:AddLine("Sin piezas con durabilidad", 0.7, 0.7, 0.7)
        end
        if state.free then
            GameTooltip:AddLine(string.format("Bolsas: %s%d|r libres de %d", Hex(state.bagLevel), state.free, state.total), 1, 1, 1)
        end
        GameTooltip:AddLine("Clic derecho: configuracion", 0.7, 0.7, 0.7)
        if not db.locked then GameTooltip:AddLine("Arrastrar: mover", 0.7, 0.7, 0.7) end
        GameTooltip:Show()
    end)
    ind:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ind:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then Hub:Open("avisos") end end)
    ind:Hide()
end

local blinkT = 0
local function Blink(elapsed)
    if not ind or not durBox then return end
    blinkT = blinkT + elapsed
    local a = 1
    if DB().blink then a = 0.55 + 0.45 * math.abs(math.sin(blinkT * 3)) end
    durBox:SetAlpha(state.durLevel > 0 and a or 1)
    bagBox:SetAlpha(state.bagLevel > 0 and a or 1)
end

local function Layout()
    if not ind then return end
    local db = DB()
    local showDur = db.showDur and state.dur ~= nil and (db.showAlways or state.durLevel > 0)
    local showBag = db.showBag and state.free ~= nil and (db.showAlways or state.bagLevel > 0)
    if not db.locked and ind.preview then showDur, showBag = db.showDur and state.dur ~= nil, db.showBag end
    durBox:ClearAllPoints(); bagBox:ClearAllPoints()
    local prev
    local function place(box, show)
        if not show then box:Hide(); return end
        box:Show()
        if prev then box:SetPoint("LEFT", prev, "RIGHT", 10, 0) else box:SetPoint("LEFT", ind, "LEFT", 0, 0) end
        prev = box
    end
    place(durBox, showDur)
    place(bagBox, showBag)
    if showDur then
        durBox.text:SetText(string.format("%s%d%%|r", Hex(state.durLevel), math.floor((state.dur or 0) + 0.5)))
    end
    if showBag then
        bagBox.text:SetText(string.format("%s%d|r/%d", Hex(state.bagLevel), state.free or 0, state.total or 0))
    end
    if showDur or showBag then ind:Show() else ind:Hide() end
end

----------------------------------------------------------------------
-- Avisos (una vez por cruce de umbral, sin molestar en combate)
----------------------------------------------------------------------
local last = { dur = 0, bag = 0 }
local lastTime = { dur = 0, bag = 0 }
local pending = { dur = false, bag = false }

local function Notify(kind, force)
    local db = DB()
    local now = GetTime()
    if not force and now - lastTime[kind] < (db.antispam or 60) then return end
    lastTime[kind] = now
    local lvl = kind == "dur" and state.durLevel or state.bagLevel
    local msg
    if kind == "dur" then
        msg = string.format("%sEquipo roto:|r durabilidad al %d%%%s", Hex(lvl), math.floor(state.dur + 0.5),
            lvl == 2 and " - ¡repara ya!" or ". Busca un herrero.")
    else
        if state.free == 0 then
            msg = Hex(2) .. "Bolsas llenas|r: no te queda ningun hueco."
        else
            msg = string.format("%sBolsas casi llenas:|r te quedan %d huecos.", Hex(lvl), state.free)
        end
    end
    local wantChat = force or (kind == "dur" and db.chatDur or kind == "bag" and db.chatBag)
    local wantSound = force or (kind == "dur" and db.soundDur or kind == "bag" and db.soundBag)
    if wantChat then mod:Print(msg) end
    if wantSound and PlaySound and SOUNDKIT then
        local name = lvl == 2 and db.soundCrit or db.soundWarn
        PlaySound(SOUNDKIT[name] or SOUNDKIT.RAID_WARNING)
    end
end

local function Check(kind)
    local db = DB()
    if (kind == "dur" and not db.showDur) or (kind == "bag" and not db.showBag) then return end
    local lvl = kind == "dur" and state.durLevel or state.bagLevel
    if lvl < last[kind] then last[kind] = lvl end
    if lvl > last[kind] then
        if db.deferCombat and InCombat() then
            pending[kind] = true
            return
        end
        last[kind] = lvl
        pending[kind] = false
        Notify(kind)
    end
end

local function FlushPending()
    for _, kind in ipairs({ "dur", "bag" }) do
        if pending[kind] then
            pending[kind] = false
            Check(kind)
        end
    end
end

Refresh = function(silent)
    if not mod or not mod:IsEnabled() or not ind then return end
    state.dur = ReadDurability()
    state.durLevel = DurLevel(state.dur)
    state.free, state.total = ReadBags()
    state.bagLevel = BagLevel(state.free)
    Layout()
    if not silent then
        Check("dur"); Check("bag")
    end
end

----------------------------------------------------------------------
-- Vendedor: reparar y vender basura
----------------------------------------------------------------------
local function DoRepair(manual)
    if not (CanMerchantRepair and CanMerchantRepair()) then
        if manual then mod:Print("este vendedor no repara.") end
        return
    end
    local cost, can = GetRepairAllCost()
    if not can or not cost or cost <= 0 then
        if manual then mod:Print("no hay nada que reparar.") end
        return
    end
    if GetMoney() < cost then
        mod:Print("no tienes oro para reparar (" .. Money(cost) .. ").")
        return
    end
    RepairAllItems()
    mod:Print("reparado por " .. Money(cost) .. ".")
end

local selling = false
local function DoSellJunk(manual)
    if selling then return end
    local list = {}
    local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.quality == Enum.ItemQuality.Poor and not info.hasNoValue and not info.isLocked then
                list[#list + 1] = { bag = bag, slot = slot, link = info.hyperlink, count = info.stackCount or 1 }
            end
        end
    end
    if #list == 0 then
        if manual then mod:Print("no hay basura gris que vender.") end
        return
    end
    selling = true
    local gained, sold, idx = 0, 0, 1
    local function step()
        if not merchantOpen or not mod:IsEnabled() then
            selling = false
            mod:Print(string.format("venta interrumpida: %d objetos, %s.", sold, Money(gained)))
            return
        end
        local stop = math.min(idx + 5, #list)
        for i = idx, stop do
            local e = list[i]
            local price = e.link and select(11, C_Item.GetItemInfo(e.link)) or 0
            C_Container.UseContainerItem(e.bag, e.slot)
            gained = gained + (price or 0) * e.count
            sold = sold + 1
        end
        idx = stop + 1
        if idx <= #list then
            C_Timer.After(0.15, step)
        else
            selling = false
            mod:Print(string.format("vendida la basura gris: %d objetos por %s.", sold, Money(gained)))
        end
    end
    step()
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local SOUND_OPTIONS = {
    { "RAID_WARNING", "Aviso de banda" },
    { "IG_QUEST_LIST_COMPLETE", "Mision completada" },
    { "READY_CHECK", "Comprobacion de listos" },
    { "IG_MAINMENU_OPEN", "Menu abierto" },
}

local dirty, acc = true, 0

mod = Hub:Register{
    key = "avisos", dir = "Avisos", name = "Avisos de equipo y bolsas",
    desc = "Indicador que avisa cuando el equipo esta roto o las bolsas casi llenas, con reparar y vender basura opcionales. Umbrales, colores, sonidos y posicion configurables.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosAvisosDB",
    slash = { "avisos", "cmavisos" },

    Init = function(m)
        CreateIndicator()
        m:Event("PLAYER_ENTERING_WORLD", function() dirty = true end)
        m:Event("UPDATE_INVENTORY_DURABILITY", function() dirty = true end)
        m:Event("PLAYER_EQUIPMENT_CHANGED", function() dirty = true end)
        m:Event("BAG_UPDATE_DELAYED", function() dirty = true end)
        m:Event("MERCHANT_SHOW", function()
            merchantOpen = true
            if m.db.autoRepair then DoRepair(false) end
            if m.db.autoSell then DoSellJunk(false) end
            dirty = true
        end)
        m:Event("MERCHANT_CLOSED", function() merchantOpen = false; dirty = true end)
        m:Event("PLAYER_REGEN_ENABLED", function() dirty = true; FlushPending() end)
        m:OnUpdate(function(_, elapsed)
            Blink(elapsed)
            if not dirty then return end
            acc = acc + elapsed
            if acc < (m.db.refresh or 0.5) then return end
            acc = 0
            dirty = false
            Refresh()
        end)
    end,

    Enable = function(m)
        ApplyLook(); ApplyPos()
        last.dur, last.bag = 0, 0
        dirty = true; acc = 99
        Refresh(true)
    end,

    Disable = function(m)
        if ind then ind:Hide(); ind.preview = false end
        merchantOpen = false
        pending.dur, pending.bag = false, false
    end,

    OnReset = function(m)
        ApplyLook(); ApplyPos(); dirty = true
        if m:IsEnabled() then Refresh(true) end
    end,

    BuildConfig = function(m, L)
        local db = m.db
        local function R() Refresh(true) end
        L:Header("Durabilidad")
        L:Check("Vigilar la durabilidad del equipo", function() return db.showDur end, function(v) db.showDur = v; R() end)
        L:Check("Usar la media del equipo (si no, la peor pieza)", function() return db.useAvg end, function(v) db.useAvg = v; R() end)
        L:Slider("Aviso a partir de (%)", 5, 90, 1,
            function() return db.durWarn end,
            function(v) db.durWarn = v; if db.durCrit >= v then db.durCrit = math.max(1, v - 1) end; R() end)
        L:Slider("Aviso critico a partir de (%)", 1, 50, 1,
            function() return db.durCrit end,
            function(v) if v >= db.durWarn then v = db.durWarn - 1 end db.durCrit = math.max(1, v); R() end)
        L:Check("Avisar en el chat", function() return db.chatDur end, function(v) db.chatDur = v end)
        L:Check("Sonido al avisar", function() return db.soundDur end, function(v) db.soundDur = v end)

        L:Header("Bolsas")
        L:Check("Vigilar los huecos de las bolsas", function() return db.showBag end, function(v) db.showBag = v; R() end)
        L:Check("Contar tambien carcajes y bolsas especiales", function() return db.countSpecialBags end, function(v) db.countSpecialBags = v; R() end)
        L:Slider("Aviso con estos huecos libres o menos", 1, 30, 1,
            function() return db.bagWarn end,
            function(v) db.bagWarn = v; if db.bagCrit >= v then db.bagCrit = v - 1 end; R() end)
        L:Slider("Aviso critico con estos huecos o menos", 0, 10, 1,
            function() return db.bagCrit end,
            function(v) if v >= db.bagWarn then v = db.bagWarn - 1 end db.bagCrit = math.max(0, v); R() end)
        L:Check("Avisar en el chat", function() return db.chatBag end, function(v) db.chatBag = v end)
        L:Check("Sonido al avisar", function() return db.soundBag end, function(v) db.soundBag = v end)

        L:Header("Avisos")
        L:Choice("Sonido de aviso", SOUND_OPTIONS, function() return db.soundWarn end, function(v) db.soundWarn = v end)
        L:Choice("Sonido de aviso critico", SOUND_OPTIONS, function() return db.soundCrit end, function(v) db.soundCrit = v end)
        L:Slider("Pausa minima entre avisos (segundos)", 0, 300, 5,
            function() return db.antispam end, function(v) db.antispam = v end)
        L:Check("No avisar en combate (esperar a salir)", function() return db.deferCombat end, function(v) db.deferCombat = v end)

        L:Header("Indicador en pantalla")
        L:Check("Mostrar el indicador siempre", function() return db.showAlways end, function(v) db.showAlways = v; R() end)
        L:Check("Parpadeo suave cuando hay aviso", function() return db.blink end, function(v) db.blink = v end)
        L:Check("Bloquear la posicion", function() return db.locked end, function(v) db.locked = v; if v and ind then ind.preview = false end; R() end)
        L:Slider("Tamano (%)", 50, 250, 5, function() return db.scale end, function(v) db.scale = v; ApplyLook() end)
        L:Slider("Opacidad (%)", 20, 100, 5, function() return db.alpha end, function(v) db.alpha = v; ApplyLook() end)
        L:Color("Color normal", function() return unpack(db.colorOk) end, function(r, g, b) db.colorOk = { r, g, b }; R() end)
        L:Color("Color de aviso", function() return unpack(db.colorWarn) end, function(r, g, b) db.colorWarn = { r, g, b }; R() end)
        L:Color("Color critico", function() return unpack(db.colorCrit) end, function(r, g, b) db.colorCrit = { r, g, b }; R() end)
        L:Slider("Lectura tras un cambio (segundos)", 0.1, 3, 0.1,
            function() return db.refresh end, function(v) db.refresh = v end, "%.1f")
        L:Button("Mover el indicador", 170, function()
            db.locked = false; if ind then ind.preview = true end; R()
            m:Print("indicador visible para moverlo con el raton. Marca 'Bloquear la posicion' para fijarlo.")
        end)

        L:Header("Vendedor")
        L:Check("Reparar automaticamente al abrir un vendedor", function() return db.autoRepair end, function(v) db.autoRepair = v end)
        L:Check("Vender basura gris al abrir un vendedor", function() return db.autoSell end, function(v) db.autoSell = v end)
        L:Button("Reparar ahora", 140, function()
            if merchantOpen then DoRepair(true) else m:Print("abre un vendedor con reparacion.") end
        end)
        L:Button("Vender basura ahora", 160, function()
            if merchantOpen then DoSellJunk(true) else m:Print("abre un vendedor.") end
        end, true)
        L:Button("Probar aviso", 140, function()
            local d, b = state.durLevel, state.bagLevel
            state.dur, state.durLevel = state.dur or 8, 2
            state.free, state.total, state.bagLevel = state.free or 0, state.total or 16, 2
            Notify("dur", true); Notify("bag", true)
            state.durLevel, state.bagLevel = d, b
            R()
        end)
    end,

    OnSlash = function(m, msg)
        local db = m.db
        local cmd = string.match(strlower(msg or ""), "^(%S*)")
        if cmd == "" or cmd == "config" then
            Hub:Open("avisos")
        elseif cmd == "reparar" then
            if merchantOpen then DoRepair(true) else m:Print("abre un vendedor con reparacion.") end
        elseif cmd == "vender" then
            if merchantOpen then DoSellJunk(true) else m:Print("abre un vendedor.") end
        elseif cmd == "mover" then
            db.locked = false
            ind.preview = true; Refresh(true)
            m:Print("indicador visible para moverlo con el raton. /avisos bloquear para fijarlo.")
        elseif cmd == "bloquear" then
            db.locked = true; ind.preview = false; Refresh(true)
            m:Print("indicador bloqueado.")
        elseif cmd == "siempre" then
            db.showAlways = not db.showAlways; Refresh(true)
            m:Print("mostrar siempre: " .. (db.showAlways and "si" or "no"))
        elseif cmd == "estado" then
            Refresh(true)
            m:Print(string.format("durabilidad %s | bolsas libres %s/%s",
                state.dur and (math.floor(state.dur + 0.5) .. "%") or "sin piezas", tostring(state.free), tostring(state.total)))
        else
            m:Print("/avisos = configuracion | reparar | vender | mover | bloquear | siempre | estado")
        end
    end,
}
