-- CervecerosMendigos · modulo Subasta (para el addon grande CervecerosMendigosGeneral).
-- * Guarda los precios de la casa de subastas (de tus busquedas y de un escaneo de tus bolsas).
-- * Los muestra en el tooltip de cualquier objeto, junto al precio de vendedor.
-- * Ventana "Tesoros de mi inventario": objetos de tus bolsas que valen mucho mas en
--   la casa que al vendedor, con avisos en el chat.
-- La casa de subastas de Forever es la moderna (C_AuctionHouse con "commodities"):
-- busqueda por itemKey, eventos COMMODITY_/ITEM_SEARCH_RESULTS_UPDATED y limite de
-- 100 consultas por minuto (IsThrottledMessageSystemReady).
-- Configuracion: pestana "Subasta" del panel. Comandos: /subasta, /cmsub

local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI
local TAG = "|cff33ff99Subasta|r: "

local mod, S, DATA     -- S = ajustes (mod.db); DATA = precios guardados (fuera de mod.db: "Restaurar valores" no los borra)
local function Icon() return mod and mod.icon or "Interface\\Icons\\INV_Misc_QuestionMark" end
local function On() return S and DATA and mod and mod.enabled end

local DEFAULTS = {
    ratio = 3,            -- aviso si la subasta vale al menos X veces el precio del vendedor
    minGain = 50,         -- ... y gana al menos esta cantidad (en PLATA)
    hideGray = true,      -- ocultar objetos de calidad gris
    onlyTreasures = false,
    chat = true,          -- avisos en el chat
    alertOpen = true,     -- avisar al abrir la casa de subastas
    alertBags = true,     -- avisar al abrir las bolsas
    alertLoot = true,     -- avisar al recoger un objeto valioso nuevo
    bagCooldown = 20,     -- segundos minimos entre avisos al abrir bolsas
    chatItems = 5,        -- objetos maximos por aviso en el chat
    cut = false,          -- descontar la comision de la casa (5%)
    tooltip = true,       -- linea de precio en los tooltips
    tooltipAge = true,    -- mostrar la antiguedad del dato en el tooltip
    tooltipHint = true,   -- frases "mejor subastarlo" / "mas barato en subasta"
    tooltipColor = { 0.4, 0.8, 1 },
    freshMin = 15,        -- no vuelve a consultar datos de menos de X minutos
    scanGap = 0.9,        -- segundos entre consultas del escaneo (el limite del juego es 100/min)
    scanTimeout = 10,     -- segundos de espera por respuesta antes de darla por perdida
    pruneDays = 30,       -- borrar precios de mas de X dias al entrar
    windowScale = 100,    -- tamano de la ventana "Tesoros" (%)
}

local OpenWindow

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
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

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(TAG .. msg)
end

-- Numero seguro: nil si no hay valor o es un "valor secreto"
local function Num(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return tonumber(v)
end

local function Coin(c)
    c = math.floor((c or 0) + 0.5)
    if c <= 0 then return "0" end
    if GetCoinTextureString then return GetCoinTextureString(c) end
    local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    return (g > 0 and g .. "g " or "") .. (s > 0 and s .. "s " or "") .. (cc > 0 and cc .. "c" or "")
end

local function Age(t)
    local d = time() - (t or 0)
    if d < 90 then return "ahora" end
    if d < 3600 then return "hace " .. math.floor(d / 60) .. " min" end
    if d < 86400 then return "hace " .. math.floor(d / 3600) .. " h" end
    return "hace " .. math.floor(d / 86400) .. " d"
end

local function Realm() return (GetRealmName and GetRealmName()) or "?" end

local function Prices()
    local r = Realm()
    local p = DATA.prices[r]
    if not p then p = {}; DATA.prices[r] = p end
    return p
end

-- Clave de precio: "id" para commodities / objetos sin nivel; "id:nivel:sufijo" para equipo
local function KeyOf(itemKey)
    if type(itemKey) ~= "table" then return nil end
    local id = Num(itemKey.itemID)
    if not id then return nil end
    local lvl = Num(itemKey.itemLevel) or 0
    local suf = Num(itemKey.itemSuffix) or 0
    if lvl > 0 or suf > 0 then return id .. ":" .. lvl .. ":" .. suf, id end
    return tostring(id), id
end

local function Store(key, id, unit, qty, approx)
    local P = Prices()
    local e = P[key]
    if approx and e and not e.a and (time() - (e.t or 0)) < 6 * 3600 then return end
    if not e then e = {}; P[key] = e end
    e.p = math.floor(unit or 0); e.n = qty or 0; e.t = time(); e.a = approx and 1 or nil
    -- copia por id (variante) para equipo, como respaldo de los tooltips
    local idk = tostring(id)
    if key ~= idk then
        local v = P[idk]
        if not v then v = {}; P[idk] = v end
        if not v.t or v.t <= e.t then v.p, v.n, v.t, v.a = e.p, e.n, e.t, 1 end
    end
    return e
end

local function Lookup(id, key)
    local P = Prices()
    return (key and P[key]) or P[tostring(id)]
end

local function PruneOld()
    local limit = time() - (S.pruneDays or 30) * 86400
    for _, P in pairs(DATA.prices) do
        for k, e in pairs(P) do
            if type(e) ~= "table" or (e.t or 0) < limit then P[k] = nil end
        end
    end
end

local function CountPrices()
    local n = 0
    for _ in pairs(Prices()) do n = n + 1 end
    return n
end

----------------------------------------------------------------------
-- Casa de subastas: estado y lectura de resultados
----------------------------------------------------------------------
local ahOpen = false
local function IsAHOpen()
    if ahOpen then return true end
    return AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() and true or false
end

local function HasAH() return C_AuctionHouse and C_AuctionHouse.SendSearchQuery and true or false end

local function ReadCommodity(itemID, storeEmpty)
    local AH = C_AuctionHouse
    local n = Num(AH.GetNumCommoditySearchResults(itemID)) or 0
    if n == 0 and not storeEmpty then return nil end
    local best
    for i = 1, math.min(n, 100) do
        local r = AH.GetCommoditySearchResultInfo(itemID, i)
        local u = r and Num(r.unitPrice)
        if u and u > 0 and (not best or u < best) then best = u end
    end
    local total = AH.GetCommoditySearchResultsQuantity and Num(AH.GetCommoditySearchResultsQuantity(itemID)) or 0
    return Store(tostring(itemID), itemID, best or 0, total), tostring(itemID)
end

local function ReadItem(itemKey, storeEmpty)
    local AH = C_AuctionHouse
    local key, id = KeyOf(itemKey)
    if not key then return nil end
    local n = Num(AH.GetNumItemSearchResults(itemKey)) or 0
    if n == 0 and not storeEmpty then return nil end
    local best
    for i = 1, math.min(n, 100) do
        local r = AH.GetItemSearchResultInfo(itemKey, i)
        local buy = r and Num(r.buyoutAmount)
        if buy and buy > 0 then
            local q = Num(r.quantity) or 1
            if q < 1 then q = 1 end
            local u = buy / q
            if not best or u < best then best = u end
        end
    end
    local total = AH.GetItemSearchResultsQuantity and Num(AH.GetItemSearchResultsQuantity(itemKey)) or n
    return Store(key, id, best or 0, total), key
end

----------------------------------------------------------------------
-- Inventario: lista de objetos con su valoracion
----------------------------------------------------------------------
local function ExactKey(bag, slot)
    if not (ItemLocation and C_AuctionHouse and C_AuctionHouse.GetItemKeyFromItem) then return nil end
    local ok, itemKey = pcall(function()
        return C_AuctionHouse.GetItemKeyFromItem(ItemLocation:CreateFromBagAndSlot(bag, slot))
    end)
    if ok and itemKey then return itemKey end
    return nil
end

local function VendorPrice(id, info)
    if info.hasNoValue then return 0 end
    if C_Item and C_Item.GetItemInfo then
        local sp = select(11, C_Item.GetItemInfo(id))
        sp = Num(sp)
        if sp then return sp end
        if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    end
    return nil
end

local function Eval(e)
    local sell = e.sell or 0
    e.gain, e.ratio, e.treasure, e.noOffers = nil, nil, false, false
    if e.bound then e.grp = 5; return end
    local rec = e.rec
    if not rec then e.grp = 4; return end
    if (rec.p or 0) <= 0 then e.grp = 4; e.noOffers = true; return end
    local net = rec.p * (S.cut and 0.95 or 1)
    e.gain = (net - sell) * e.count
    e.ratio = sell > 0 and (rec.p / sell) or nil
    e.treasure = e.gain >= S.minGain * 100 and (sell == 0 or rec.p >= sell * S.ratio)
    e.grp = e.treasure and 1 or (e.gain > 0 and 2 or 3)
end

local function BuildList(includeGray)
    local list, by = {}, {}
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return list end
    for bag = 0, 6 do
        local n = Num(C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, n do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and Num(info.itemID)
            if id then
                local q = Num(info.quality) or 1
                if includeGray or not (S.hideGray and q == 0) then
                    local bound = info.isBound and true or false
                    local itemKey = ExactKey(bag, slot)
                    local key = itemKey and KeyOf(itemKey) or tostring(id)
                    local mk = key .. (bound and "b" or "")
                    local e = by[mk]
                    if not e then
                        e = { mk = mk, key = key, id = id, link = info.hyperlink, icon = info.iconFileID,
                              quality = q, count = 0, bound = bound, name = info.itemName or ("#" .. id),
                              bag = bag, slot = slot }
                        e.sell = VendorPrice(id, info)
                        e.rec = Lookup(id, key)
                        by[mk] = e
                        list[#list + 1] = e
                    end
                    e.count = e.count + (Num(info.stackCount) or 1)
                end
            end
        end
    end
    for _, e in ipairs(list) do Eval(e) end
    table.sort(list, function(a, b)
        if a.grp ~= b.grp then return a.grp < b.grp end
        local ga, gb = a.gain or -1e12, b.gain or -1e12
        if ga ~= gb then return ga > gb end
        return tostring(a.name) < tostring(b.name)
    end)
    return list
end

----------------------------------------------------------------------
-- Avisos en el chat
----------------------------------------------------------------------
local alerted = {}
local lastBagAlert = 0

local function AlertTreasures(source, all)
    if not On() or not S.chat then return end
    local list = BuildList()
    local show, total = {}, 0
    for _, e in ipairs(list) do
        if e.treasure then
            total = total + 1
            if all or not alerted[e.mk] then show[#show + 1] = e end
            alerted[e.mk] = true
        end
    end
    if #show == 0 then return end
    local head = source == "subasta" and "en tus bolsas hay objetos que valen mas en la casa de subastas:"
        or (all and "objetos de tus bolsas que valen mas en subasta:" or "nuevo objeto que vale mas en subasta:")
    Print(head)
    for i = 1, math.min(#show, S.chatItems or 5) do
        local e = show[i]
        Print(string.format("  %s x%d -> subasta %s/u (vendedor %s/u), ganancia %s",
            e.link or e.name, e.count, Coin(e.rec.p), Coin(e.sell or 0), Coin(e.gain)))
    end
    if #show > (S.chatItems or 5) then Print("  ... y " .. (#show - (S.chatItems or 5)) .. " mas. /subasta para ver la lista") end
end

----------------------------------------------------------------------
-- Escaneo secuencial del inventario (respeta el limite de consultas)
----------------------------------------------------------------------
local scan = { active = false, queue = {}, i = 0, waiting = nil, sentAt = 0, lastSend = 0,
               ok = 0, fail = 0 }
local RefreshWindow  -- se define con la ventana

local function MakeScanEntry(e)
    local AH = C_AuctionHouse
    local itemKey = ExactKey(e.bag, e.slot)
    if not itemKey and AH.MakeItemKey then itemKey = AH.MakeItemKey(e.id) end
    if not itemKey then return nil end
    if (Num(itemKey.battlePetSpeciesID) or 0) > 0 then return nil end
    local commodity = false
    if AH.GetItemKeyInfo then
        local ok, ki = pcall(AH.GetItemKeyInfo, itemKey)
        if ok and ki and ki.isCommodity then commodity = true end
    end
    if commodity then itemKey = AH.MakeItemKey(e.id) end
    local key = KeyOf(itemKey)
    if not key then return nil end
    return { key = key, id = e.id, itemKey = itemKey, commodity = commodity, name = e.name, tries = 0 }
end

local function UpdateProgress()
    if not RefreshWindow then return end
    RefreshWindow("progress")
end

local function FinishScan(reason)
    local was = scan.active
    scan.active = false; scan.waiting = nil
    if was then
        Print(reason or string.format("escaneo terminado: %d precios nuevos, %d sin respuesta.", scan.ok, scan.fail))
        if reason == nil then AlertTreasures("escaneo", true) end
    end
    UpdateProgress()
    if RefreshWindow then RefreshWindow("list") end
end

local function StartScan(force)
    if scan.active then Print("ya hay un escaneo en marcha"); return end
    if not HasAH() then Print("este cliente no tiene la API de la casa de subastas"); return end
    if not IsAHOpen() then Print("abre la casa de subastas para escanear"); return end
    local list = BuildList()
    local queue, seen, skipped = {}, {}, 0
    local P = Prices()
    for _, e in ipairs(list) do
        if not e.bound then
            local se = MakeScanEntry(e)
            if se and not seen[se.key] then
                seen[se.key] = true
                local rec = P[se.key]
                if not force and rec and not rec.a and (time() - (rec.t or 0)) < S.freshMin * 60 then
                    skipped = skipped + 1
                else
                    queue[#queue + 1] = se
                end
            end
        end
    end
    if #queue == 0 then
        Print("nada que consultar" .. (skipped > 0 and (" (" .. skipped .. " con precio reciente; Mayus+clic fuerza el escaneo)") or ""))
        return
    end
    scan.active, scan.queue, scan.i, scan.waiting = true, queue, 0, nil
    scan.ok, scan.fail, scan.lastSend = 0, 0, 0
    Print(string.format("escaneando %d objetos (~%d s)%s", #queue, math.ceil(#queue * (S.scanGap or 0.9)),
        skipped > 0 and (", " .. skipped .. " con precio reciente omitidos") or ""))
    UpdateProgress()
end

local function ScanAdvance(ok)
    if ok then scan.ok = scan.ok + 1 else scan.fail = scan.fail + 1 end
    scan.waiting = nil
    if scan.i >= #scan.queue then FinishScan() else UpdateProgress() end
end

local function ScanSend()
    local entry = scan.queue[scan.i + 1]
    scan.i = scan.i + 1
    entry.tries = entry.tries + 1
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    local ok = pcall(C_AuctionHouse.SendSearchQuery, entry.itemKey, sorts, false)
    scan.lastSend = GetTime()
    if not ok then
        scan.fail = scan.fail + 1
        if scan.i >= #scan.queue then FinishScan() end
        return
    end
    scan.waiting, scan.sentAt = entry, GetTime()
    UpdateProgress()
end

local function ScanTick()
    if not scan.active then return end
    if not IsAHOpen() then FinishScan("escaneo cancelado: se cerro la casa de subastas."); return end
    local t = GetTime()
    if scan.waiting then
        if t - scan.sentAt > (S.scanTimeout or 10) then ScanAdvance(false) end
        return
    end
    if scan.i >= #scan.queue then FinishScan(); return end
    if t - scan.lastSend < (S.scanGap or 0.9) then return end
    local AH = C_AuctionHouse
    if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then return end
    ScanSend()
end

local function CancelScan()
    if scan.active then FinishScan("escaneo cancelado.") end
end

----------------------------------------------------------------------
-- Resultados de busqueda (del jugador o de nuestro escaneo)
----------------------------------------------------------------------
local browseDirty, browseAt = false, 0
local listDirty = false

local function OnCommodityUpdated(itemID)
    itemID = Num(itemID)
    if not (itemID and HasAH()) then return end
    local e, key = ReadCommodity(itemID, true)
    if e then
        listDirty = true
        if scan.waiting and scan.waiting.key == key then ScanAdvance(true) end
    end
end

local function OnItemUpdated(itemKey)
    if not (itemKey and HasAH()) then return end
    local e, key = ReadItem(itemKey, true)
    if e then
        listDirty = true
        if scan.waiting and scan.waiting.key == key then ScanAdvance(true) end
    end
end

-- Respaldo: algunos resultados solo avisan con NEW_RESULTS_RECEIVED / RECEIVED
local function OnNewResults(itemKey)
    if not (scan.waiting and HasAH()) then return end
    local w = scan.waiting
    local e
    if w.commodity then e = ReadCommodity(w.id, false)
    elseif itemKey then
        local key = KeyOf(itemKey)
        if key == w.key then e = ReadItem(itemKey, false) end
    end
    if e then listDirty = true; ScanAdvance(true) end
end

local function ProcessBrowse()
    if not (C_AuctionHouse and C_AuctionHouse.GetBrowseResults) then return end
    local res = C_AuctionHouse.GetBrowseResults()
    if type(res) ~= "table" then return end
    for i = 1, math.min(#res, 3000) do
        local r = res[i]
        local key, id = KeyOf(r.itemKey)
        local minp = Num(r.minPrice)
        if key and minp and minp > 0 and (Num(r.itemKey.battlePetSpeciesID) or 0) == 0 then
            Store(key, id, minp, Num(r.totalQuantity) or 0, true)
            listDirty = true
        end
    end
end

----------------------------------------------------------------------
-- Tooltip
----------------------------------------------------------------------
local function LinkParts(link)
    if type(link) ~= "string" then return nil end
    local suf = tonumber(link:match("item:%-?%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d*)")) or 0
    if suf < 0 then suf = 0 end
    local lvl = 0
    if C_Item and C_Item.GetDetailedItemLevelInfo then lvl = Num(C_Item.GetDetailedItemLevelInfo(link)) or 0 end
    return lvl, suf
end

local function PriceFor(id, link)
    local P = Prices()
    local lvl, suf = LinkParts(link)
    if lvl and lvl > 0 then
        local e = P[id .. ":" .. lvl .. ":" .. suf]
        if e then return e end
    end
    return P[tostring(id)]
end

local function OnTooltipItem(tt, data)
    if not On() or not S.tooltip then return end
    if tt.IsForbidden and tt:IsForbidden() then return end
    local id = data and Num(data.id)
    if not id then return end
    local e = PriceFor(id, data.hyperlink)
    if not e then return end
    if (e.p or 0) <= 0 then
        local c0 = S.tooltipColor or { 0.4, 0.8, 1 }
        tt:AddDoubleLine("Subasta:", "sin ofertas" .. (S.tooltipAge and (" (" .. Age(e.t) .. ")") or ""), c0[1], c0[2], c0[3], 0.7, 0.7, 0.7)
        return
    end
    local right = Coin(e.p) .. (e.a and " ~" or "") .. (S.tooltipAge and ("  |cff999999(" .. Age(e.t) .. ")|r") or "")
    local c = S.tooltipColor or { 0.4, 0.8, 1 }
    tt:AddDoubleLine("Subasta (min.):", right, c[1], c[2], c[3], 1, 1, 1)
    if not S.tooltipHint then return end
    local sell = C_Item and C_Item.GetItemInfo and Num(select(11, C_Item.GetItemInfo(id)))
    if sell and sell > 0 and e.p >= sell * S.ratio then
        tt:AddLine(string.format("|cff33ff33x%.1f el precio de vendedor: mejor subastarlo|r", e.p / sell))
    elseif sell and sell > 0 and e.p < sell then
        tt:AddLine("|cffff6060Mas barato en subasta que al vendedor|r")
    end
end


----------------------------------------------------------------------
-- Ventana "Tesoros de mi inventario"
----------------------------------------------------------------------
local win
local widgets = {}
local items, offset = {}, 0
local rows = {}
local scroll, bar, statusFS, scanBtn, cancelBtn
local ROWS, RH = 14, 24
local ROW_W = 590

local MakeWindow = UI.MakeWindow

local function UpdateRows()
    for i = 1, ROWS do
        local row, e = rows[i], items[offset + i]
        row.e = e
        if not e then
            row:Hide()
        else
            row:Show()
            row.icon:SetTexture(e.icon)
            local r, g, b = 1, 1, 1
            if C_Item and C_Item.GetItemQualityColor then
                local cr, cg, cb2 = C_Item.GetItemQualityColor(e.quality or 1)
                if cr then r, g, b = cr, cg, cb2 end
            end
            row.name:SetText(e.name); row.name:SetTextColor(r, g, b)
            row.count:SetText("x" .. e.count)
            local sell = e.sell and Coin(e.sell) or "?"
            if e.bound then
                row.ah:SetText("|cff888888ligado: no se vende|r"); row.sell:SetText(sell); row.gain:SetText("")
            elseif not e.rec then
                row.ah:SetText("|cff888888sin dato|r"); row.sell:SetText(sell); row.gain:SetText("")
            elseif e.noOffers then
                row.ah:SetText("|cff888888sin ofertas|r"); row.sell:SetText(sell); row.gain:SetText("")
            else
                row.ah:SetText(Coin(e.rec.p) .. (e.rec.a and " ~" or ""))
                row.sell:SetText(sell)
                local col = e.treasure and "|cff33ff33" or (e.gain > 0 and "|cffffffff" or "|cffff6060")
                row.gain:SetText(col .. (e.gain < 0 and "-" or "") .. Coin(math.abs(e.gain)) .. "|r")
            end
            row.mark:SetShown(e.treasure and true or false)
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

local function RebuildItems()
    local list = BuildList()
    items = {}
    for _, e in ipairs(list) do
        if not S.onlyTreasures or e.treasure then items[#items + 1] = e end
    end
    SetupScroll()
end

local function BuildRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_W, RH)
    row:SetPoint("TOPLEFT", 16, -178 - (i - 1) * RH)
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(); row.hl:SetColorTexture(1, 1, 1, 0.08)
    row.mark = row:CreateTexture(nil, "BACKGROUND")
    row.mark:SetAllPoints(); row.mark:SetColorTexture(0.1, 0.6, 0.2, 0.18)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT", 2, 0)
    local function FS(x, w, just)
        local f = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f:SetPoint("LEFT", x, 0); f:SetWidth(w); f:SetJustifyH(just or "LEFT")
        f:SetWordWrap(false)
        return f
    end
    row.name = FS(28, 186)
    row.count = FS(216, 36, "RIGHT")
    row.ah = FS(258, 128, "RIGHT")
    row.sell = FS(392, 100, "RIGHT")
    row.gain = FS(494, 94, "RIGHT")
    row:SetScript("OnEnter", function(self)
        local e = self.e
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if e.link and GameTooltip.SetHyperlink then GameTooltip:SetHyperlink(e.link) else GameTooltip:AddLine(e.name) end
        if e.rec then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Dato de subasta: " .. Age(e.rec.t) .. (e.rec.a and " (aproximado, de la lista)" or "")
                .. (e.rec.n and e.rec.n > 0 and (" - " .. e.rec.n .. " a la venta") or ""), 0.6, 0.8, 1)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function UpdateStatus()
    if not win then return end
    local open = IsAHOpen()
    if scan.active then
        local total = #scan.queue
        bar:SetMinMaxValues(0, math.max(total, 1))
        bar:SetValue(scan.ok + scan.fail)
        local w = scan.waiting
        statusFS:SetText(string.format("Escaneando %d/%d%s", scan.ok + scan.fail, total, w and (": " .. tostring(w.name)) or ""))
    else
        bar:SetMinMaxValues(0, 1); bar:SetValue(0)
        statusFS:SetText(string.format("Reino %s - %d precios guardados - Casa de subastas: %s",
            Realm(), CountPrices(), open and "|cff33ff33abierta|r" or "|cffff6060cerrada|r"))
    end
    if scanBtn then
        if scanBtn.SetEnabled then scanBtn:SetEnabled(open and not scan.active) end
        if cancelBtn and cancelBtn.SetEnabled then cancelBtn:SetEnabled(scan.active) end
    end
end

RefreshWindow = function(what)
    if not win or not win:IsShown() then return end
    if what == "list" or what == nil then RebuildItems() end
    UpdateStatus()
end

local function RefreshWidgets()
    for _, w in ipairs(widgets) do if w.Refresh then w:Refresh() end end
end

local function BuildWindow()
    win = MakeWindow("CervecerosMendigosSubastaWindow", "Tesoros de mi inventario", 640, 540)
    win:SetScale((S.windowScale or 100) / 100)

    local logo = win:CreateTexture(nil, "ARTWORK")
    logo:SetSize(40, 40); logo:SetPoint("TOPLEFT", 16, -34)
    logo:SetTexture(Icon())
    local intro = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", logo, "TOPRIGHT", 8, -2)
    intro:SetWidth(550); intro:SetJustifyH("LEFT")
    intro:SetText("Objetos de tus bolsas que valen mucho mas en la casa de subastas que al vendedor. Abre la casa y pulsa Escanear para actualizar los precios (Mayus+clic: consultarlo todo).")

    scanBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    scanBtn:SetSize(190, 24); scanBtn:SetPoint("TOPLEFT", 16, -86)
    scanBtn:SetText("Escanear mi inventario")
    scanBtn:SetScript("OnClick", function() StartScan(IsShiftKeyDown and IsShiftKeyDown()) end)
    cancelBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    cancelBtn:SetSize(90, 24); cancelBtn:SetPoint("LEFT", scanBtn, "RIGHT", 6, 0)
    cancelBtn:SetText("Cancelar")
    cancelBtn:SetScript("OnClick", CancelScan)

    bar = CreateFrame("StatusBar", nil, win)
    bar:SetSize(ROW_W, 12); bar:SetPoint("TOPLEFT", 16, -118)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.2, 0.8, 0.5)
    local bbg = bar:CreateTexture(nil, "BACKGROUND")
    bbg:SetAllPoints(); bbg:SetColorTexture(0.1, 0.1, 0.15, 0.9)
    statusFS = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusFS:SetPoint("TOPLEFT", 16, -134); statusFS:SetWidth(ROW_W); statusFS:SetJustifyH("LEFT")

    local function Col(text, x, w, just)
        local f = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetPoint("TOPLEFT", x + 16, -160); f:SetWidth(w); f:SetJustifyH(just or "LEFT"); f:SetText(text)
    end
    Col("Objeto", 28, 186); Col("Cant.", 216, 36, "RIGHT"); Col("Subasta /u", 258, 128, "RIGHT")
    Col("Vendedor /u", 392, 100, "RIGHT"); Col("Ganancia", 494, 94, "RIGHT")

    for i = 1, ROWS do rows[i] = BuildRow(win, i) end

    scroll = CreateFrame("Slider", nil, win)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, ROWS * RH)
    scroll:SetPoint("TOPLEFT", 612, -178)
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

    local legend = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMLEFT", 16, 14); legend:SetWidth(600); legend:SetJustifyH("LEFT")
    legend:SetText("Fondo verde = tesoro. ~ = precio aproximado (de la lista de la casa). Ajustes: pestana Subasta. Comandos: /subasta (escanear, cancelar, limpiar, precio [objeto], debug).")

    win:SetScript("OnShow", function() win:SetScale((S.windowScale or 100) / 100); RefreshWidgets(); RebuildItems(); UpdateStatus() end)
end

OpenWindow = function()
    if not On() then return end
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show() end
end

----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local ready = false
local bagPending = false
local hooked = false
local EVENTS = {
    "PLAYER_ENTERING_WORLD", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "AUCTION_HOUSE_DISABLED", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "AUCTION_HOUSE_NEW_RESULTS_RECEIVED", "COMMODITY_SEARCH_RESULTS_RECEIVED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
}

local function After(sec, fn)
    if C_Timer and C_Timer.After then C_Timer.After(sec, fn) else fn() end
end

local function HookBags()
    if hooked then return end
    hooked = true
    local last = 0
    local function OnBags()
        if not On() or not S.alertBags then return end
        After(0.4, function()
            if not On() or not S.alertBags then return end
            if GetTime() - last < (S.bagCooldown or 20) then return end
            local open = (IsBagOpen and IsBagOpen(0))
                or (ContainerFrameCombinedBags and ContainerFrameCombinedBags.IsShown and ContainerFrameCombinedBags:IsShown())
            if IsBagOpen and not open then return end
            last = GetTime()
            AlertTreasures("bolsas", true)
        end)
    end
    for _, fn in ipairs({ "OpenAllBags", "ToggleAllBags", "ToggleBackpack" }) do
        if type(_G[fn]) == "function" then pcall(hooksecurefunc, fn, OnBags) end
    end
end

local function OnEvent(event, a1)
    if not On() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        After(10, function() ready = true end)
    elseif event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        UpdateStatus()
        if S.alertOpen then After(1.5, function() if ahOpen and On() then AlertTreasures("subasta", true) end end) end
    elseif event == "AUCTION_HOUSE_CLOSED" or event == "AUCTION_HOUSE_DISABLED" then
        ahOpen = false
        if scan.active then FinishScan("escaneo cancelado: se cerro la casa de subastas.") end
        UpdateStatus()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodityUpdated(a1)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnItemUpdated(a1)
    elseif event == "AUCTION_HOUSE_NEW_RESULTS_RECEIVED" then
        if a1 then OnNewResults(a1) else browseDirty, browseAt = true, GetTime() end
    elseif event == "COMMODITY_SEARCH_RESULTS_RECEIVED" then
        OnNewResults(nil)
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        browseDirty, browseAt = true, GetTime()
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        -- el servidor descarto la consulta: se reintenta una vez
        local w = scan.waiting
        if w then
            scan.waiting = nil
            if w.tries < 2 then scan.queue[#scan.queue + 1] = w end
            scan.lastSend = GetTime() + 2
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if win and win:IsShown() then listDirty = true end
        if ready and not bagPending and S.chat and S.alertLoot then
            bagPending = true
            After(1.0, function()
                bagPending = false
                if On() then AlertTreasures("loot", false) end
            end)
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if win and win:IsShown() then listDirty = true end
    end
end

local acc, accList = 0, 0
local function OnUpdate(_, elapsed)
    acc = acc + elapsed
    if acc >= 0.1 then
        acc = 0
        ScanTick()
        if browseDirty and GetTime() - browseAt > 1.0 then
            browseDirty = false
            ProcessBrowse()
        end
    end
    accList = accList + elapsed
    if accList >= 0.5 then
        accList = 0
        if listDirty then
            listDirty = false
            RefreshWindow("list")
        end
    end
end

----------------------------------------------------------------------
-- Comandos: /subasta  /cmsub
----------------------------------------------------------------------
local function OnSlash(_, msg)
    msg = msg or ""
    local cmd, arg = string.match(strlower(msg), "^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "config" or cmd == "ventana" then
        OpenWindow()
    elseif cmd == "escanear" or cmd == "scan" then
        StartScan(arg == "todo")
    elseif cmd == "cancelar" then
        if scan.active then CancelScan() else Print("no hay ningun escaneo en marcha") end
    elseif cmd == "limpiar" then
        DATA.prices[Realm()] = {}
        listDirty = true
        Print("precios de este reino borrados")
    elseif cmd == "minimap" then
        Print("el boton del minimapa se controla en la pestana Subasta (Boton en el minimapa).")
    elseif cmd == "aviso" then
        S.chat = not S.chat
        Print("avisos en el chat: " .. (S.chat and "activados" or "desactivados"))
    elseif cmd == "precio" then
        local link = msg:match("|Hitem:[^|]+|h[^|]*|h")
        local id = link and tonumber(link:match("item:(%d+)"))
        if not id then Print("uso: /subasta precio [objeto]  (pega el enlace del objeto)"); return end
        local e = PriceFor(id, link)
        if not e then Print("sin datos de subasta para ese objeto")
        elseif (e.p or 0) <= 0 then Print("sin ofertas (" .. Age(e.t) .. ")")
        else Print(Coin(e.p) .. "/u " .. (e.a and "(aprox.) " or "") .. Age(e.t) .. ", " .. (e.n or 0) .. " a la venta") end
    elseif cmd == "debug" then
        local AH = C_AuctionHouse
        Print("C_AuctionHouse=" .. tostring(AH ~= nil) .. " SendSearchQuery=" .. tostring(AH and AH.SendSearchQuery ~= nil)
            .. " GetItemKeyFromItem=" .. tostring(AH and AH.GetItemKeyFromItem ~= nil)
            .. " Throttle=" .. tostring(AH and AH.IsThrottledMessageSystemReady ~= nil))
        Print("TooltipDataProcessor=" .. tostring(TooltipDataProcessor ~= nil) .. " C_Container=" .. tostring(C_Container ~= nil)
            .. " subasta abierta=" .. tostring(IsAHOpen()) .. " precios=" .. CountPrices())
        if AH and AH.IsThrottledMessageSystemReady then Print("listo para consultar=" .. tostring(AH.IsThrottledMessageSystemReady())) end
    else
        Print("/subasta = ventana | escanear [todo] | cancelar | precio [objeto] | aviso | limpiar | debug (ajustes en la pestana Subasta)")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local function BuildConfig(m, L)
    L:Header("Que es un tesoro")
    L:Text("Un objeto de tus bolsas que vale mucho mas en la casa de subastas que al vendedor.", true)
    L:Slider("Vale al menos x veces el vendedor", 1, 20, 1, function() return S.ratio end,
        function(v) S.ratio = v; RefreshWindow("list") end)
    L:Slider("...y gana al menos (plata)", 0, 2000, 10, function() return S.minGain end,
        function(v) S.minGain = v; RefreshWindow("list") end)
    L:Check("Descontar la comision de la casa (5%)", function() return S.cut end,
        function(v) S.cut = v; RefreshWindow("list") end)
    L:Check("Ocultar objetos de calidad gris", function() return S.hideGray end,
        function(v) S.hideGray = v; RefreshWindow("list") end)
    L:Check("Mostrar solo los tesoros en la ventana", function() return S.onlyTreasures end,
        function(v) S.onlyTreasures = v; RefreshWindow("list") end)
    L:Header("Avisos en el chat")
    L:Check("Avisos en el chat (interruptor general)", function() return S.chat end, function(v) S.chat = v end)
    L:Check("Al abrir la casa de subastas", function() return S.alertOpen end, function(v) S.alertOpen = v end)
    L:Check("Al abrir las bolsas", function() return S.alertBags end, function(v) S.alertBags = v end)
    L:Check("Al recoger un objeto valioso nuevo", function() return S.alertLoot end, function(v) S.alertLoot = v end)
    L:Slider("Segundos minimos entre avisos al abrir bolsas", 5, 120, 5, function() return S.bagCooldown end,
        function(v) S.bagCooldown = v end)
    L:Slider("Objetos maximos por aviso", 1, 15, 1, function() return S.chatItems end, function(v) S.chatItems = v end)
    L:Header("Tooltips")
    L:Check("Precio de subasta en los tooltips", function() return S.tooltip end, function(v) S.tooltip = v end)
    L:Check("Mostrar la antiguedad del dato", function() return S.tooltipAge end, function(v) S.tooltipAge = v end)
    L:Check("Frases 'mejor subastarlo' / 'mas barato en subasta'", function() return S.tooltipHint end,
        function(v) S.tooltipHint = v end)
    L:Color("Color de la linea de subasta",
        function() local c = S.tooltipColor; return c[1], c[2], c[3] end,
        function(r, g, b) S.tooltipColor = { r, g, b } end)
    L:Header("Escaneo y datos")
    L:Slider("No repetir datos de menos de (minutos)", 1, 120, 1, function() return S.freshMin end,
        function(v) S.freshMin = v end)
    L:Slider("Segundos entre consultas del escaneo", 0.7, 3, 0.1, function() return S.scanGap end,
        function(v) S.scanGap = v end, "%.1f")
    L:Slider("Segundos de espera por respuesta", 3, 30, 1, function() return S.scanTimeout end,
        function(v) S.scanTimeout = v end)
    L:Slider("Borrar precios de mas de (dias)", 1, 120, 1, function() return S.pruneDays end,
        function(v) S.pruneDays = v end)
    L:Slider("Tamano de la ventana de tesoros", 60, 130, 5, function() return S.windowScale end,
        function(v) S.windowScale = v; if win then win:SetScale(v / 100) end end, "%d%%")
    L:Button("Abrir 'Tesoros de mi inventario'", 230, function() OpenWindow() end)
    L:Button("Escanear mi inventario", 230, function() StartScan(false) end)
    L:Button("Borrar los precios de este reino", 230, function()
        DATA.prices[Realm()] = {}; listDirty = true; Print("precios de este reino borrados")
    end)
end

mod = Hub:Register{
    key = "subasta", dir = "Subasta", name = "Subasta",
    desc = "Guarda precios de la casa de subastas, los muestra en los tooltips y lista los objetos de tu inventario que valen mas alli que al vendedor.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosSubastaDB",
    slash = { "subasta", "cmsub" },
    OnSlash = OnSlash,
    BuildConfig = BuildConfig,
    Init = function(m)
        S = m.db
        ns.DB.data = ns.DB.data or {}
        local D = ns.DB.data.subasta
        if not D then D = {}; ns.DB.data.subasta = D end
        if S.prices ~= nil and D.prices == nil then D.prices = S.prices end   -- datos del addon suelto antiguo
        S.prices = nil; S.minimap = nil
        D.prices = D.prices or {}
        DATA = D
        PruneOld()
        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
           and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
            pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, OnTooltipItem)
        end
        HookBags()
        for _, name in ipairs(EVENTS) do
            if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(name) then
                m:Event(name, function(_, event, a1) OnEvent(event, a1) end)
            end
        end
        m:OnUpdate(OnUpdate)
    end,
    Enable = function(m)
        S = m.db
        if not ready then After(10, function() ready = true end) end
    end,
    Disable = function(m)
        if scan.active then FinishScan("escaneo cancelado.") end
        ahOpen = false
        if win then win:Hide() end
    end,
}
