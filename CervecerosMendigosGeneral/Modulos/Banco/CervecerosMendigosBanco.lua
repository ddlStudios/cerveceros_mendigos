-- CervecerosMendigos · modulo Banco (para el addon grande CervecerosMendigosGeneral).
-- Recuerda lo que tiene cada uno de tus personajes en bolsas, banco, correo y equipado
-- (y el banco de banda guerra), y lo busca desde una ventana o en el tooltip de cualquier objeto.
-- * Banco: en Forever es el moderno (pestanas C_Bank.FetchPurchasedBankTabData, bankType
--   Character/Account). Se detecta en tiempo de ejecucion; si falta, se prueban los ids de bolsa.
-- * Funciones globales para otros addons: CMBancoCount, CMBancoDetalle, CMBancoFalta (solo si el modulo esta activado).
-- Configuracion: pestana "Banco" del panel. Comandos: /banco, /cmbanco

local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI
local TAG = "|cff33ff99Banco|r: "

local mod            -- se rellena con Hub:Register al final
local S              -- ajustes (mod.db)
local DB             -- datos guardados: chars, wb, meta, locale (fuera de mod.db para que "Restaurar valores" no los borre)
local OpenWindow, RefreshWindow
local function Icon() return mod and mod.icon or "Interface\\Icons\\INV_Misc_QuestionMark" end

local DEFAULTS = {
    staleDays = 7,            -- datos mas viejos se marcan en gris
    tooltip = true,           -- linea "Tienes N: ..." en los tooltips
    showCurrent = true,       -- el tooltip tambien cuenta al personaje actual
    tooltipMin = 1,           -- solo se muestra la linea si el total es al menos este
    tooltipColor = { 0.4, 0.8, 1 },
    includeWarband = true,    -- contar el banco de banda guerra (si el juego lo tiene)
    scanBags = true,          -- recordar bolsas
    scanEquipped = true,      -- recordar equipado
    scanBank = true,          -- recordar banco al abrirlo
    scanMail = true,          -- recordar correo al abrir el buzon
    chatLines = 15,           -- lineas maximas del boton "Al chat"
    windowScale = 100,        -- tamano de la ventana del buscador (%)
}

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

local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- Numero seguro: nil si no hay valor o es un "valor secreto"
local function Num(v)
    if v == nil or Secret(v) then return nil end
    return tonumber(v)
end

local function Str(v)
    if type(v) ~= "string" or Secret(v) then return nil end
    return v
end

local function After(sec, fn)
    if C_Timer and C_Timer.After then C_Timer.After(sec, fn) else fn() end
end

local function Age(t)
    local d = time() - (t or 0)
    if d < 90 then return "ahora" end
    if d < 3600 then return "hace " .. math.floor(d / 60) .. " min" end
    if d < 86400 then return "hace " .. math.floor(d / 3600) .. " h" end
    return "hace " .. math.floor(d / 86400) .. " d"
end

local function Realm() return (GetRealmName and GetRealmName()) or "?" end

-- Normaliza para buscar: minusculas y sin tildes (UTF-8 del cliente en espanol)
local ACC = {
    ["\195\161"] = "a", ["\195\169"] = "e", ["\195\173"] = "i", ["\195\179"] = "o", ["\195\186"] = "u",
    ["\195\188"] = "u", ["\195\177"] = "n",
    ["\195\129"] = "a", ["\195\137"] = "e", ["\195\141"] = "i", ["\195\147"] = "o", ["\195\154"] = "u",
    ["\195\156"] = "u", ["\195\145"] = "n",
}
local function Norm(s)
    s = string.gsub(s or "", "\195[\128-\191]", ACC)
    return string.lower(s)
end

local function MaxBagSlot()
    if NUM_TOTAL_EQUIPPED_BAG_SLOTS then return NUM_TOTAL_EQUIPPED_BAG_SLOTS end
    return (NUM_BAG_SLOTS or 4)
end

----------------------------------------------------------------------
-- Datos: personaje actual, meta de objetos
----------------------------------------------------------------------
local LOCS = { "bags", "bank", "mail", "eq" }
local LOC_NAME = { bags = "bolsas", bank = "banco", mail = "correo", eq = "equipado" }
local LOC_TITLE = { bags = "Bolsas", bank = "Banco", mail = "Correo", eq = "Equipado" }
local WB = "__wb"   -- identificador del banco de banda guerra en filtros

local function Me()
    local name = UnitName and UnitName("player")
    if not name or Secret(name) then return nil end
    local realm = Realm()
    local R = DB.chars[realm]
    if not R then R = {}; DB.chars[realm] = R end
    local c = R[name]
    if not c then
        c = { bags = {}, bank = {}, mail = {}, eq = {}, ts = {} }
        R[name] = c
    end
    c.ts = c.ts or {}
    for _, l in ipairs(LOCS) do c[l] = c[l] or {} end
    if UnitClass then
        local _, cls = UnitClass("player")
        if cls and not Secret(cls) then c.class = cls end
    end
    return c, name, realm
end

local function SetMeta(id, quality, name)
    name = Str(name)
    if not id or not name or name == "" then return end
    local q = Num(quality) or 1
    if q < 0 or q > 9 then q = 1 end
    DB.meta[id] = q .. ":" .. name
end

local pendingNames = {}
-- nombre y calidad del objeto: del cliente si esta en cache, si no de lo guardado
local function ItemName(id)
    if C_Item and C_Item.GetItemInfo then
        local ok, name, _, quality = pcall(C_Item.GetItemInfo, id)
        name = ok and Str(name) or nil
        if name and name ~= "" then
            SetMeta(id, quality, name)
            return name, Num(quality) or 1
        end
    end
    local m = DB.meta[id]
    if m then
        local q, n = string.match(m, "^(%d):(.*)$")
        if n then return n, tonumber(q) or 1 end
    end
    if C_Item and C_Item.RequestLoadItemDataByID and not pendingNames[id] then
        pendingNames[id] = true
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    return nil, 1
end

local function ItemIcon(id)
    if C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, id)
        if ok and icon then return icon end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function ItemLink(id)
    if C_Item and C_Item.GetItemInfo then
        local ok, _, link = pcall(C_Item.GetItemInfo, id)
        if ok and Str(link) then return link end
    end
end

----------------------------------------------------------------------
-- Lectura de bolsas, banco, correo y equipado
----------------------------------------------------------------------
local bankOpen, mailOpen = false, false

local function ScanContainer(bag, out)
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return false end
    local n = Num(C_Container.GetContainerNumSlots(bag))
    if not n or n <= 0 then return false end
    for slot = 1, n do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if type(info) == "table" then
            local id = Num(info.itemID)
            if id then
                local c = Num(info.stackCount) or 1
                out[id] = (out[id] or 0) + c
                SetMeta(id, info.quality, info.itemName)
            end
        end
    end
    return true
end

local listDirty = false

local function ScanBags()
    if not S.scanBags then return end
    local me = Me()
    if not me then return end
    local out, any = {}, false
    for bag = 0, MaxBagSlot() do
        if ScanContainer(bag, out) then any = true end
    end
    if not any then return end
    me.bags = out
    me.ts.bags = time()
    listDirty = true
end

local function ScanEquipped()
    if not S.scanEquipped then return end
    local me = Me()
    if not me or not GetInventoryItemID then return end
    local out = {}
    for slot = 1, 19 do
        local id = Num(GetInventoryItemID("player", slot))
        if id then
            out[id] = (out[id] or 0) + 1
            ItemName(id)
        end
    end
    me.eq = out
    me.ts.eq = time()
    listDirty = true
end

-- ids de bolsa de las pestanas de banco de un tipo (Character / Account)
local function BankTabIDs(bankType)
    local ids = {}
    if C_Bank and C_Bank.FetchPurchasedBankTabData then
        if C_Bank.CanViewBank then
            local ok, can = pcall(C_Bank.CanViewBank, bankType)
            if ok and not can then return ids end
        end
        local ok, data = pcall(C_Bank.FetchPurchasedBankTabData, bankType)
        if ok and type(data) == "table" then
            for _, t in ipairs(data) do
                local id = type(t) == "table" and Num(t.ID)
                if id then ids[#ids + 1] = id end
            end
        end
    end
    return ids
end

local function BankType(which)
    local E = Enum and Enum.BankType
    if E then return E[which] end
end

local function ScanBank()
    if not S.scanBank then return end
    local me = Me()
    if not me then return end
    -- banco del personaje
    local ids = {}
    local ct = BankType("Character")
    if ct ~= nil then ids = BankTabIDs(ct) end
    if #ids == 0 then
        -- respaldo: banco clasico / pestanas por numero de bolsa
        local first = MaxBagSlot() + 1
        ids = { Enum and Enum.BagIndex and Enum.BagIndex.Characterbanktab or -2 }
        for b = first, first + 8 do ids[#ids + 1] = b end
    end
    local out, any = {}, false
    for _, bag in ipairs(ids) do
        if ScanContainer(bag, out) then any = true end
    end
    if any then
        me.bank = out
        me.ts.bank = time()
        listDirty = true
    end
    -- banco de banda guerra (compartido por toda la cuenta)
    local at = BankType("Account")
    if at ~= nil then
        local wids = BankTabIDs(at)
        if #wids > 0 then
            local wout, wany = {}, false
            for _, bag in ipairs(wids) do
                if ScanContainer(bag, wout) then wany = true end
            end
            if wany then
                DB.wb = { t = time(), items = wout }
                listDirty = true
            end
        end
    end
end

local function ScanMail()
    if not S.scanMail then return end
    local me = Me()
    if not me or not GetInboxNumItems or not GetInboxItem then return end
    local num = Num((GetInboxNumItems())) or 0
    local out = {}
    local maxA = ATTACHMENTS_MAX_RECEIVE or 16
    for i = 1, num do
        for j = 1, maxA do
            local name, id, _, count, quality, _, isCurrency = GetInboxItem(i, j)
            id = Num(id)
            if id and not isCurrency then
                out[id] = (out[id] or 0) + (Num(count) or 1)
                SetMeta(id, quality, name)
            end
        end
    end
    me.mail = out
    me.ts.mail = time()
    listDirty = true
end

local pend = {}
local function Defer(key, sec, fn)
    if pend[key] then return end
    pend[key] = true
    After(sec, function() pend[key] = nil; if DB and mod and mod.enabled then fn() end end)
end

----------------------------------------------------------------------
-- Consultas
----------------------------------------------------------------------
local function EachChar(fn)
    for realm, R in pairs(DB.chars) do
        for name, c in pairs(R) do
            if type(c) == "table" then fn(name, realm, c) end
        end
    end
end

local function CharLabel(name, realm)
    if realm ~= Realm() then return name .. "-" .. realm end
    return name
end

local function ClassColor(class)
    local col = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if col then return string.format("|cff%02x%02x%02x", math.floor(col.r * 255 + 0.5), math.floor(col.g * 255 + 0.5), math.floor(col.b * 255 + 0.5)) end
    return "|cffffffff"
end

local function IsStale(t)
    return not t or (time() - t) > (S.staleDays or 7) * 86400
end

local function IsCurrent(name, realm)
    return UnitName and name == UnitName("player") and realm == Realm()
end

-- Desglose de un objeto: lista de { who=, label=, loc=, n=, t=, stale= } por personaje y lugar
local function Breakdown(id, skipCurrent)
    local parts, total = {}, 0
    EachChar(function(name, realm, c)
        if not (skipCurrent and IsCurrent(name, realm)) then
            for _, l in ipairs(LOCS) do
                local n = c[l] and c[l][id]
                if n and n > 0 then
                    local t = c.ts and c.ts[l]
                    parts[#parts + 1] = { who = name, realm = realm, label = CharLabel(name, realm), class = c.class,
                        loc = l, n = n, t = t, stale = IsStale(t) and not IsCurrent(name, realm) }
                    total = total + n
                end
            end
        end
    end)
    local wbn = S.includeWarband and DB.wb and DB.wb.items and DB.wb.items[id]
    if wbn and wbn > 0 then
        parts[#parts + 1] = { who = WB, label = "Banda de guerra", loc = "bank", n = wbn, t = DB.wb.t,
            stale = IsStale(DB.wb.t), wb = true }
        total = total + wbn
    end
    table.sort(parts, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return a.loc < b.loc
    end)
    return parts, total
end

-- Texto "Pj1 (banco 3, bolsas 5), Pj2 (correo 2)"; los datos viejos van en gris con *
local function BreakdownText(parts, colorize)
    local out, lastWho, buf = {}, nil, {}
    local function Flush()
        if not lastWho then return end
        local p = lastWho
        local name = p.label
        if colorize then
            name = (p.stale and "|cff888888" or ClassColor(p.class)) .. name .. "|r"
        end
        local inner = table.concat(buf, ", ")
        out[#out + 1] = p.wb and (name .. " (" .. inner .. ")") or (name .. " (" .. inner .. ")")
        buf = {}
    end
    for _, p in ipairs(parts) do
        if lastWho and lastWho.label ~= p.label then Flush() end
        lastWho = p
        local piece = (p.wb and "" or (LOC_NAME[p.loc] .. " ")) .. p.n
        if p.stale then piece = piece .. "*" end
        buf[#buf + 1] = piece
    end
    Flush()
    return table.concat(out, ", ")
end

-- Total entre todos los personajes (y banda de guerra). Para otros addons.
function CMBancoCount(itemID, skipCurrent)
    if not (DB and mod and mod.enabled) then return 0 end
    local id = Num(itemID)
    if not id then return 0 end
    local _, total = Breakdown(id, skipCurrent and true or false)
    return total
end

-- Texto con el desglose por personaje y lugar ("Pj1 (banco 3), Pj2 (correo 2)") y el total. Para otros addons.
function CMBancoDetalle(itemID, skipCurrent)
    if not (DB and mod and mod.enabled) then return "", 0 end
    local id = Num(itemID)
    if not id then return "", 0 end
    local parts, total = Breakdown(id, skipCurrent and true or false)
    return BreakdownText(parts, false), total
end

-- lista: { [itemID] = necesario } o { {id=, n=}, ... } -> { [itemID] = { need=, have=, missing= } }
function CMBancoFalta(list)
    local res = {}
    if not (DB and mod and mod.enabled) or type(list) ~= "table" then return res end
    local function Add(id, need)
        id = Num(id); need = Num(need) or 1
        if not id then return end
        local have = CMBancoCount(id)
        res[id] = { need = need, have = have, missing = math.max(0, need - have) }
    end
    for k, v in pairs(list) do
        if type(v) == "table" then Add(v.id or v[1], v.n or v.count or v[2]) else Add(k, v) end
    end
    return res
end

-- Filtros de la ventana
local filter = { who = nil, loc = nil, quality = 0, text = "" }
local QUAL_NAME = { [0] = "Cualquiera", [1] = "Comun o mejor", [2] = "Poco comun o mejor", [3] = "Raro o mejor", [4] = "Epico o mejor" }

local function CharList()
    local list = {}
    EachChar(function(name, realm, c)
        list[#list + 1] = { key = realm .. "\1" .. name, name = name, realm = realm, label = CharLabel(name, realm), class = c.class }
    end)
    table.sort(list, function(a, b) return a.label < b.label end)
    return list
end

local function Query()
    local tokens = {}
    for w in string.gmatch(Norm(filter.text), "%S+") do tokens[#tokens + 1] = w end
    local acc = {}   -- id -> { total=, parts={} }
    local function Push(id, p)
        local g = acc[id]
        if not g then g = { id = id, total = 0, parts = {} }; acc[id] = g end
        g.total = g.total + p.n
        g.parts[#g.parts + 1] = p
    end
    local function WantLoc(l) return not filter.loc or filter.loc == l end
    EachChar(function(name, realm, c)
        if not filter.who or filter.who == realm .. "\1" .. name then
            for _, l in ipairs(LOCS) do
                if WantLoc(l) and c[l] then
                    local t = c.ts and c.ts[l]
                    for id, n in pairs(c[l]) do
                        if n > 0 then
                            Push(id, { label = CharLabel(name, realm), class = c.class, loc = l, n = n, t = t,
                                stale = IsStale(t) and not IsCurrent(name, realm) })
                        end
                    end
                end
            end
        end
    end)
    if S.includeWarband and (not filter.who or filter.who == WB) and WantLoc("bank") and DB.wb and DB.wb.items then
        for id, n in pairs(DB.wb.items) do
            if n > 0 then Push(id, { label = "Banda de guerra", loc = "bank", n = n, t = DB.wb.t, stale = IsStale(DB.wb.t), wb = true }) end
        end
    end
    local list = {}
    for id, g in pairs(acc) do
        local name, quality = ItemName(id)
        g.name = name
        g.quality = quality or 1
        g.sortName = Norm(name or ("~" .. id))
        local ok = (g.quality or 1) >= (filter.quality or 0)
        if ok and #tokens > 0 then
            local hay = g.sortName .. " " .. id
            for _, w in ipairs(tokens) do
                if not string.find(hay, w, 1, true) then ok = false; break end
            end
        end
        if ok then
            table.sort(g.parts, function(a, b)
                if a.label ~= b.label then return a.label < b.label end
                return a.loc < b.loc
            end)
            list[#list + 1] = g
        end
    end
    table.sort(list, function(a, b)
        if a.sortName ~= b.sortName then return a.sortName < b.sortName end
        return a.id < b.id
    end)
    return list
end

----------------------------------------------------------------------
-- Tooltip
----------------------------------------------------------------------
local function OnTooltipItem(tt, data)
    if not (DB and mod and mod.enabled) or not S.tooltip then return end
    if tt.IsForbidden and tt:IsForbidden() then return end
    local id = data and Num(data.id)
    if not id then return end
    local parts, total = Breakdown(id, not S.showCurrent)
    if total <= 0 or total < (S.tooltipMin or 1) then return end
    local text = BreakdownText(parts, false)
    local c = S.tooltipColor or { 0.4, 0.8, 1 }
    tt:AddLine("Tienes " .. total .. ": " .. text, c[1], c[2], c[3], true)
end
----------------------------------------------------------------------
-- Ventana
----------------------------------------------------------------------
local win
local widgets = {}
local items, offset = {}, 0
local rows = {}
local scroll, statusFS, searchBox, whoBtn, locBtn, qualBtn
local ROWS, RH = 15, 24
local ROW_W = 650

local MakeWindow = UI.MakeWindow

local function UpdateRows()
    for i = 1, ROWS do
        local row, g = rows[i], items[offset + i]
        row.g = g
        if not g then
            row:Hide()
        else
            row:Show()
            row.icon:SetTexture(ItemIcon(g.id))
            local r, gg, b = 1, 1, 1
            if C_Item and C_Item.GetItemQualityColor then
                local cr, cg, cb2 = C_Item.GetItemQualityColor(g.quality or 1)
                if cr then r, gg, b = cr, cg, cb2 end
            end
            row.name:SetText(g.name or ("objeto " .. g.id))
            row.name:SetTextColor(r, gg, b)
            row.total:SetText(g.total)
            row.where:SetText(BreakdownText(g.parts, true))
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

local function UpdateStatus()
    if not win then return end
    local units = 0
    for _, g in ipairs(items) do units = units + g.total end
    local nchars = 0
    EachChar(function() nchars = nchars + 1 end)
    statusFS:SetText(string.format("%d objetos distintos, %d unidades. Personajes guardados: %d. Banco: %s. Correo: %s. |cff888888* = datos de hace mas de %d dias|r",
        #items, units, nchars,
        bankOpen and "|cff33ff33abierto|r" or "|cff999999cerrado|r",
        mailOpen and "|cff33ff33abierto|r" or "|cff999999cerrado|r", DB.staleDays or 7))
end

local function RefreshButtons()
    if not win then return end
    local who = "Todos"
    if filter.who == WB then who = "Banda de guerra"
    elseif filter.who then
        for _, c in ipairs(CharList()) do if c.key == filter.who then who = c.label end end
    end
    whoBtn:SetText("Personaje: " .. who)
    locBtn:SetText("Lugar: " .. (filter.loc and LOC_TITLE[filter.loc] or "Todos"))
    qualBtn:SetText("Calidad: " .. QUAL_NAME[filter.quality or 0])
end

local function RebuildItems()
    items = Query()
    SetupScroll()
    UpdateStatus()
    RefreshButtons()
end

RefreshWindow = function()
    if win and win:IsShown() then RebuildItems() end
end

-- botones que cambian de valor al pulsarlos (clic izquierdo: siguiente, derecho: anterior)
local function MakeCycler(parent, x, y, w, getList, apply)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetPoint("TOPLEFT", x, y)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, btn)
        local list, idx = getList()
        local n = #list
        if n == 0 then return end
        if btn == "RightButton" then idx = idx - 1 else idx = idx + 1 end
        if idx > n then idx = 1 elseif idx < 1 then idx = n end
        apply(list[idx])
        RebuildItems()
    end)
    return b
end

local function IndexIn(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return 1
end

local function WhoValues()
    local vals = { false }   -- false = todos
    for _, c in ipairs(CharList()) do vals[#vals + 1] = c.key end
    if DB.wb then vals[#vals + 1] = WB end
    return vals
end
local LOC_VALUES = { false, "bags", "bank", "mail", "eq" }
local QUAL_VALUES = { 0, 1, 2, 3, 4 }

local function ChatLine(g)
    return (ItemLink(g.id) or g.name or ("objeto " .. g.id)) .. " x" .. g.total .. ": " .. BreakdownText(g.parts, false)
end

local function SendToChat()
    if #items == 0 then Print("no hay resultados que mostrar"); return end
    Print("resultados" .. (filter.text ~= "" and (" de \"" .. filter.text .. "\"") or "") .. " (" .. #items .. "):")
    for i = 1, math.min(#items, S.chatLines or 15) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. ChatLine(items[i]))
    end
    if #items > (S.chatLines or 15) then Print("... y " .. (#items - (S.chatLines or 15)) .. " mas. Afina la busqueda para verlos.") end
end

local function DeleteSelectedChar()
    if not filter.who or filter.who == WB then
        Print("elige primero un personaje en el filtro «Personaje» (clic en el boton)")
        return
    end
    local realm, name = string.match(filter.who, "^(.-)\1(.*)$")
    if not name then return end
    if IsCurrent(name, realm) then
        Print("no puedes borrar el personaje con el que estas jugando (se volveria a guardar)")
        return
    end
    StaticPopupDialogs["CERVECEROSMENDIGOSBANCO_BORRAR"] = {
        text = "Borrar los datos guardados de %s?",
        button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true,
        OnAccept = function()
            if DB.chars[realm] then DB.chars[realm][name] = nil end
            filter.who = nil
            Print("personaje borrado de la lista: " .. name)
            RefreshWindow()
        end,
    }
    StaticPopup_Show("CERVECEROSMENDIGOSBANCO_BORRAR", CharLabel(name, realm))
end

local function BuildRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_W, RH)
    row:SetPoint("TOPLEFT", 16, -156 - (i - 1) * RH)
    row:RegisterForClicks("LeftButtonUp")
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(); row.hl:SetColorTexture(1, 1, 1, 0.08)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT", 2, 0)
    local function FS(x, w, just)
        local f = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f:SetPoint("LEFT", x, 0); f:SetWidth(w); f:SetJustifyH(just or "LEFT")
        f:SetWordWrap(false)
        return f
    end
    row.name = FS(28, 190)
    row.total = FS(220, 44, "RIGHT")
    row.where = FS(272, 376)
    row:SetScript("OnEnter", function(self)
        local g = self.g
        if not g then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local link = ItemLink(g.id)
        if link and GameTooltip.SetHyperlink then
            pcall(GameTooltip.SetHyperlink, GameTooltip, link)
        else
            GameTooltip:AddLine(g.name or ("objeto " .. g.id))
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Total: " .. g.total, 0.4, 0.8, 1)
        for _, p in ipairs(g.parts) do
            local txt = p.label .. (p.wb and "" or (" - " .. LOC_NAME[p.loc])) .. ": " .. p.n
                .. "  (" .. Age(p.t) .. ")"
            if p.stale then GameTooltip:AddLine(txt, 0.55, 0.55, 0.55) else GameTooltip:AddLine(txt, 1, 1, 1) end
        end
        GameTooltip:AddLine("Mayus+clic: poner el objeto en el chat", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        local g = self.g
        if not g then return end
        if IsShiftKeyDown and IsShiftKeyDown() then
            local text = ChatLine(g)
            if ChatEdit_InsertLink and ItemLink(g.id) then
                ChatEdit_InsertLink(ItemLink(g.id))
            elseif ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
                ChatEdit_GetActiveWindow():Insert(text)
            else
                DEFAULT_CHAT_FRAME:AddMessage("  " .. text)
            end
        end
    end)
    return row
end

local function RefreshWidgets()
    for _, w in ipairs(widgets) do if w.Refresh then w:Refresh() end end
end

local function BuildWindow()
    win = MakeWindow("CervecerosMendigosBancoWindow", "Banco de todos mis personajes", 720, 590)
    win:SetScale((S.windowScale or 100) / 100)

    local logo = win:CreateTexture(nil, "ARTWORK")
    logo:SetSize(40, 40); logo:SetPoint("TOPLEFT", 16, -34)
    logo:SetTexture(Icon())
    local lbl = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", logo, "TOPRIGHT", 8, -2)
    lbl:SetText("Buscar objeto (sin tildes, vale parte del nombre):")

    local ok = pcall(function() searchBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate") end)
    if not ok or not searchBox then searchBox = CreateFrame("EditBox", nil, win) end
    searchBox:SetSize(300, 22)
    searchBox:SetPoint("TOPLEFT", logo, "TOPRIGHT", 14, -20)
    searchBox:SetAutoFocus(false)
    if searchBox.SetFontObject then searchBox:SetFontObject("ChatFontNormal") end
    searchBox:SetMaxLetters(60)
    searchBox:SetScript("OnTextChanged", function(self, user)
        filter.text = self:GetText() or ""
        offset = 0
        Defer("search", 0.15, RebuildItems)
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local clear = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clear:SetSize(70, 22); clear:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    clear:SetText("Limpiar")
    clear:SetScript("OnClick", function()
        searchBox:SetText("")
        filter.who, filter.loc, filter.quality = nil, nil, 0
        offset = 0
        RebuildItems()
    end)

    local chatBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    chatBtn:SetSize(90, 22); chatBtn:SetPoint("LEFT", clear, "RIGHT", 6, 0)
    chatBtn:SetText("Al chat")
    chatBtn:SetScript("OnClick", SendToChat)

    whoBtn = MakeCycler(win, 16, -86, 250, function() local v = WhoValues(); return v, IndexIn(v, filter.who or false) end,
        function(v) filter.who = v or nil; offset = 0 end)
    locBtn = MakeCycler(win, 272, -86, 170, function() return LOC_VALUES, IndexIn(LOC_VALUES, filter.loc or false) end,
        function(v) filter.loc = v or nil; offset = 0 end)
    qualBtn = MakeCycler(win, 448, -86, 200, function() return QUAL_VALUES, IndexIn(QUAL_VALUES, filter.quality or 0) end,
        function(v) filter.quality = v; offset = 0 end)

    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -112)
    hint:SetText("Clic izquierdo en un filtro: siguiente. Clic derecho: anterior.")

    statusFS = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusFS:SetPoint("TOPLEFT", 16, -126); statusFS:SetWidth(ROW_W); statusFS:SetJustifyH("LEFT")

    local function Col(text, x, w, just)
        local f = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetPoint("TOPLEFT", x + 16, -140); f:SetWidth(w); f:SetJustifyH(just or "LEFT"); f:SetText(text)
    end
    Col("Objeto", 28, 190); Col("Total", 220, 44, "RIGHT"); Col("Donde esta", 272, 376)
    for i = 1, ROWS do rows[i] = BuildRow(win, i) end

    scroll = CreateFrame("Slider", nil, win)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, ROWS * RH)
    scroll:SetPoint("TOPLEFT", 16 + ROW_W + 6, -156)
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

    local scanBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    scanBtn:SetSize(150, 22); scanBtn:SetPoint("BOTTOMLEFT", 16, 40)
    scanBtn:SetText("Leer bolsas ahora")
    scanBtn:SetScript("OnClick", function()
        ScanBags(); ScanEquipped()
        if bankOpen then ScanBank() end
        if mailOpen then ScanMail() end
        RebuildItems()
    end)
    local delBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    delBtn:SetSize(190, 22); delBtn:SetPoint("LEFT", scanBtn, "RIGHT", 6, 0)
    delBtn:SetText("Borrar personaje elegido")
    delBtn:SetScript("OnClick", DeleteSelectedChar)

    local legend = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMLEFT", 16, 14); legend:SetWidth(680); legend:SetJustifyH("LEFT")
    legend:SetText("El banco se lee al abrirlo, el correo al abrir el buzon y las bolsas solas. Ajustes: pestana Banco del panel. Comandos: /banco (buscar, falta, borrar, debug).")

    win:SetScript("OnShow", function() win:SetScale((S.windowScale or 100) / 100); RefreshWidgets(); RebuildItems() end)
end

OpenWindow = function()
    if not (DB and mod and mod.enabled) then return end
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show() end
end

----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local function OnEvent(event, a1)
    if not DB then return end
    if event == "PLAYER_ENTERING_WORLD" then
        Defer("login", 3, function() ScanBags(); ScanEquipped() end)
    elseif event == "BAG_UPDATE_DELAYED" then
        Defer("bags", 0.5, function()
            ScanBags()
            if bankOpen then ScanBank() end
            if win and win:IsShown() then RefreshWindow() end
        end)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        Defer("eq", 0.5, ScanEquipped)
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        After(0.6, function() if bankOpen and DB and mod.enabled then ScanBank(); RefreshWindow() end end)
        After(2.5, function() if bankOpen and DB and mod.enabled then ScanBank(); RefreshWindow() end end)
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
        RefreshWindow()
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED"
        or event == "BANK_TABS_CHANGED" then
        if bankOpen then Defer("bank", 0.5, function() ScanBank(); RefreshWindow() end) end
    elseif event == "MAIL_SHOW" then
        mailOpen = true
        Defer("mail", 0.8, function() if mailOpen then ScanMail(); RefreshWindow() end end)
    elseif event == "MAIL_CLOSED" then
        mailOpen = false
        RefreshWindow()
    elseif event == "MAIL_INBOX_UPDATE" then
        if mailOpen then Defer("mail", 0.8, function() if mailOpen then ScanMail(); RefreshWindow() end end) end
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        local id = Num(a1)
        if id and pendingNames[id] then
            pendingNames[id] = nil
            ItemName(id)
            if win and win:IsShown() then Defer("names", 0.5, RefreshWindow) end
        end
    end
end

local EVENTS = {
    "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED",
    "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED",
    "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", "BANK_TABS_CHANGED",
    "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE",
    "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT",
}
local function RegisterEvents()
    for _, name in ipairs(EVENTS) do
        if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(name) then
            mod:Event(name, function(_, event, a1) OnEvent(event, a1) end)
        end
    end
end

----------------------------------------------------------------------
-- Comandos: /banco  /cmbanco
----------------------------------------------------------------------
local function ParseNeeds(arg)
    local list = {}
    for tok in string.gmatch(arg or "", "%S+") do
        local id, n = string.match(tok, "^(%d+)[xX*:](%d+)$")
        if not id then id = string.match(tok, "^(%d+)$") end
        if not id then
            id = string.match(tok, "|Hitem:(%d+)")
        end
        if id then list[#list + 1] = { id = tonumber(id), n = tonumber(n) or 1 } end
    end
    return list
end

local function OnSlash(_, msg)
    if not DB then return end
    msg = msg or ""
    local cmd, arg = string.match(msg, "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    if cmd == "" or cmd == "config" or cmd == "ventana" then
        OpenWindow()
    elseif cmd == "buscar" then
        if not win then BuildWindow() end
        if not win:IsShown() then win:Show() end
        searchBox:SetText(arg or "")
    elseif cmd == "falta" then
        local needs = ParseNeeds(arg)
        if #needs == 0 then
            Print("uso: /banco falta 2449x10 765x5 (id del objeto, x cantidad; tambien vale pegar enlaces)")
            return
        end
        local res = CMBancoFalta(needs)
        for _, n in ipairs(needs) do
            local r = res[n.id]
            local nm = ItemName(n.id) or ("objeto " .. n.id)
            if r.missing > 0 then
                Print(string.format("%s: tienes %d de %d (|cffff6060faltan %d|r)", nm, r.have, r.need, r.missing))
            else
                Print(string.format("%s: tienes %d de %d |cff33ff33(completo)|r", nm, r.have, r.need))
            end
        end
    elseif cmd == "borrar" then
        local name = string.lower(arg or "")
        if name == "" then Print("uso: /banco borrar NombreDelPersonaje"); return end
        local found
        EachChar(function(n, realm)
            if string.lower(n) == name and not IsCurrent(n, realm) then
                DB.chars[realm][n] = nil; found = n
            end
        end)
        if found then Print("personaje borrado de la lista: " .. found); RefreshWindow()
        else Print("no encuentro ese personaje (o es el actual)") end
    elseif cmd == "debug" then
        Print("C_Container=" .. tostring(C_Container ~= nil) .. " C_Bank=" .. tostring(C_Bank ~= nil)
            .. " FetchPurchasedBankTabData=" .. tostring(C_Bank and C_Bank.FetchPurchasedBankTabData ~= nil)
            .. " Enum.BankType=" .. tostring(Enum and Enum.BankType ~= nil)
            .. " TooltipDataProcessor=" .. tostring(TooltipDataProcessor ~= nil)
            .. " GetInboxItem=" .. tostring(GetInboxItem ~= nil))
        Print("banco abierto=" .. tostring(bankOpen) .. " correo abierto=" .. tostring(mailOpen))
        local ct, at = BankType("Character"), BankType("Account")
        Print("pestanas banco personaje=" .. (ct ~= nil and #BankTabIDs(ct) or "?")
            .. " banda de guerra=" .. (at ~= nil and #BankTabIDs(at) or "?"))
        EachChar(function(n, realm, c)
            local cnt = {}
            for _, l in ipairs(LOCS) do
                local k = 0
                for _ in pairs(c[l] or {}) do k = k + 1 end
                cnt[#cnt + 1] = LOC_NAME[l] .. "=" .. k
            end
            Print(CharLabel(n, realm) .. ": " .. table.concat(cnt, " "))
        end)
    else
        Print("/banco = ventana | buscar texto | falta id x cantidad... | borrar Personaje | debug (los ajustes estan en la pestana Banco)")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local function BuildConfig(m, L)
    L:Header("Buscador")
    L:Text("Recuerda lo que llevas, tienes en el banco, el correo y puesto en cada personaje, y lo busca en una ventana. El banco se lee al abrirlo, el correo al abrir el buzon y las bolsas solas.", true)
    L:Button("Abrir el buscador", 200, function() OpenWindow() end)
    L:Button("Leer bolsas ahora", 200, function()
        ScanBags(); ScanEquipped()
        if bankOpen then ScanBank() end
        if mailOpen then ScanMail() end
        RefreshWindow()
    end)
    L:Slider("Tamano de la ventana del buscador", 60, 130, 5, function() return S.windowScale end,
        function(v) S.windowScale = v; if win then win:SetScale(v / 100) end end, "%d%%")
    L:Slider("Lineas al enviar al chat", 5, 40, 1, function() return S.chatLines end, function(v) S.chatLines = v end)
    L:Header("Que se recuerda")
    L:Check("Bolsas", function() return S.scanBags end, function(v) S.scanBags = v end)
    L:Check("Equipado", function() return S.scanEquipped end, function(v) S.scanEquipped = v end)
    L:Check("Banco (al abrirlo)", function() return S.scanBank end, function(v) S.scanBank = v end)
    L:Check("Correo (al abrir el buzon)", function() return S.scanMail end, function(v) S.scanMail = v end)
    L:Check("Contar el banco de banda guerra (si el juego lo tiene)", function() return S.includeWarband end,
        function(v) S.includeWarband = v; RefreshWindow() end)
    L:Slider("Marcar como antiguos los datos de mas de (dias)", 1, 60, 1, function() return S.staleDays end,
        function(v) S.staleDays = v; RefreshWindow() end)
    L:Header("Tooltips")
    L:Check("Linea 'Tienes N: ...' en los tooltips de objetos", function() return S.tooltip end, function(v) S.tooltip = v end)
    L:Check("Contar tambien al personaje actual", function() return S.showCurrent end, function(v) S.showCurrent = v end)
    L:Slider("Mostrar solo si tienes al menos", 1, 100, 1, function() return S.tooltipMin end, function(v) S.tooltipMin = v end)
    L:Color("Color de la linea",
        function() local c = S.tooltipColor; return c[1], c[2], c[3] end,
        function(r, g, b) S.tooltipColor = { r, g, b } end)
    L:Header("Personajes guardados")
    local info = L:Text("", true)
    L:Add({ Refresh = function()
        local n = 0
        if DB then EachChar(function() n = n + 1 end) end
        info:SetText("Personajes guardados: " .. n .. ". Para quitar uno: /banco borrar Nombre, o en la ventana del buscador (filtro Personaje + boton).")
    end }, 0)
end

mod = Hub:Register{
    key = "banco", dir = "Banco", name = "Banco",
    desc = "Buscador del inventario de todos tus personajes (bolsas, banco, correo, equipado) y linea en los tooltips.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosBancoDB",
    slash = { "banco", "cmbanco" },
    OnSlash = OnSlash,
    BuildConfig = BuildConfig,
    Init = function(m)
        S = m.db
        ns.DB.data = ns.DB.data or {}
        local D = ns.DB.data.banco
        if not D then D = {}; ns.DB.data.banco = D end
        -- datos del addon suelto antiguo (llegan a mod.db por la migracion): se pasan a la tabla de datos
        for _, k in ipairs({ "chars", "wb", "meta", "locale" }) do
            if S[k] ~= nil and D[k] == nil then D[k] = S[k] end
            S[k] = nil
        end
        S.minimap = nil
        D.chars = D.chars or {}
        D.meta = D.meta or {}
        DB = D
        local loc = GetLocale and GetLocale()
        if DB.locale and DB.locale ~= loc then DB.meta = {} end   -- nombres de otro idioma: se rehacen
        DB.locale = loc
        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
           and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
            pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, OnTooltipItem)
        end
        RegisterEvents()
    end,
    Enable = function(m)
        S = m.db
        Defer("login", 2, function() ScanBags(); ScanEquipped() end)
    end,
    Disable = function(m)
        bankOpen, mailOpen = false, false
        if win then win:Hide() end
    end,
}
