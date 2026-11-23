-- CervecerosMendigosCarrito para WoW Forever (cliente moderno, Interface 16001).
-- * Lista de la compra de materiales (objeto + cantidad + prioridad + nota + etiqueta).
-- * La lista es de la cuenta: la comparten todos tus personajes. Cada personaje guarda
--   cuantos lleva (bolsas + banco), y si esta CervecerosMendigosBanco se usa su total.
-- * Recordatorios discretos al abrir la subasta, el banco, un vendedor, el buzon o una
--   profesion, y aviso al completar un objeto.
-- * Compartir la lista con el grupo (mensajes de addon, con aceptacion del que recibe)
--   e importar/exportar en texto: id:cantidad:prioridad;id:cantidad:prioridad
-- Configuracion: boton del minimapa, o /carrito

-- Modulo Carrito (CervecerosMendigosGeneral) para WoW Forever (Interface 16001).
-- * Lista de la compra de materiales (objeto + cantidad + prioridad + nota + etiqueta).
-- * La lista es de la cuenta: la comparten todos tus personajes. Cada personaje guarda
--   cuantos lleva (bolsas + banco), y si esta el modulo Banco se usa su total.
-- * Recordatorios discretos al abrir la subasta, el banco, un vendedor, el buzon o una
--   profesion, y aviso al completar un objeto.
-- * Compartir la lista con el grupo (mensajes de addon, con aceptacion del que recibe)
--   e importar/exportar en texto: id:cantidad:prioridad;id:cantidad:prioridad
-- Todo se configura en su pestana del panel (o con /carrito, /cmcarrito).

local ADDON, ns = ...
local Hub = ns.Hub
local ICON = ""
local PREFIX = "CMCARRITO"
local PER_CHUNK = 12           -- objetos por mensaje de addon (cada mensaje < 255 bytes) [protocolo]
local PROTO_MAX_SHARE = 60     -- maximo que se acepta recibir por oferta [protocolo]

local DEFAULTS = {
    remind = true,             -- recordatorios al abrir subasta/banco/vendedor/buzon
    sources = { AUCTION_HOUSE_SHOW = true, BANKFRAME_OPENED = true, MERCHANT_SHOW = true, MAIL_SHOW = true, TRADE_SKILL_SHOW = true },
    chat = false,              -- ademas del aviso en pantalla, una linea en el chat
    sound = true,              -- sonido al completar un objeto
    soundName = "IG_QUEST_LIST_COMPLETE",
    hideDone = false,          -- ocultar los objetos ya completos
    acceptAny = false,         -- aceptar ofertas de jugadores que no estan en tu grupo
    useBank = true,            -- usar el total del modulo Banco (otros personajes) si existe
    clickAdd = "both",         -- "both" | "ctrlalt" | "shift" | "off"
    toastTime = 16,            -- segundos que se ve el aviso
    toastLines = 5,            -- objetos que lista el aviso
    toastScale = 100,
    remindEvery = 60,          -- segundos minimos entre avisos del mismo sitio
    maxItems = 300,            -- tamano maximo de la lista
    maxShare = 60,             -- objetos por lista compartida
    offerTTL = 120,            -- segundos que vive una oferta/aceptacion
    list = {},                 -- { {id=, need=, prio=1..3, note=, tag=} }
    counts = {},               -- counts[reino-personaje] = { name=, t=, n={[id]=cantidad} }
    ignored = {},              -- ignored[nombre] = true
}

local SOUND_OPTIONS = {
    { "IG_QUEST_LIST_COMPLETE", "Mision completada" },
    { "RAID_WARNING", "Aviso de banda" },
    { "READY_CHECK", "Comprobacion de listos" },
    { "IG_MAINMENU_OPEN", "Menu abierto" },
}
local CLICK_OPTIONS = {
    { "both", "Ctrl+Alt+clic, y Mayus+clic con la ventana abierta" },
    { "ctrlalt", "Solo Ctrl+Alt+clic" },
    { "shift", "Solo Mayus+clic con la ventana abierta" },
    { "off", "Desactivado" },
}

local mod
local keep = {}   -- referencias a list/counts/ignored (sobreviven a "Restaurar valores")
local DB
local OpenWindow

local unpack = unpack or table.unpack

----------------------------------------------------------------------
-- Utilidades
----------------------------------------------------------------------
local function MaxItems() return (DB and DB.maxItems) or 300 end
local function MaxShare() return math.min(PROTO_MAX_SHARE, (DB and DB.maxShare) or 60) end
local function OfferTTL() return (DB and DB.offerTTL) or 120 end

local function Print(msg)
    mod:Print(msg)
end

-- Numero seguro: nil si no hay valor o es un "valor secreto"
local function Num(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return tonumber(v)
end

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- Texto seguro para mostrar: sin codigos de color/enlace ni caracteres de control
local function Clean(s, maxLen)
    s = tostring(s or "")
    s = s:gsub("|", ""):gsub("%c", " ")
    if maxLen and #s > maxLen then s = s:sub(1, maxLen) end
    return s
end

local function After(sec, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(sec, function() if mod and mod:IsEnabled() then fn() end end)
    else
        fn()
    end
end

local function Realm() return (GetRealmName and GetRealmName()) or "?" end
local function MyName() return (UnitName and UnitName("player")) or "?" end
local function MyKey() return Realm() .. "-" .. MyName() end

----------------------------------------------------------------------
-- Informacion de objetos (con reintento de cache)
----------------------------------------------------------------------
local requested = {}   -- id -> intentos
local function RequestItem(id)
    local n = (requested[id] or 0) + 1
    if n > 6 then return end
    requested[id] = n
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end

local function ItemInfo(id)
    local name, link, quality, icon
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if fn then
        local ok, n, l, q, _, _, _, _, _, _, tex = pcall(fn, id)
        if ok then name, link, quality, icon = n, l, q, tex end
    end
    if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then name = nil end
    if not name then RequestItem(id) end
    if not icon then
        local f2 = C_Item and C_Item.GetItemIconByID
        if f2 then local ok, t = pcall(f2, id); if ok then icon = t end end
    end
    return name, link, quality or 1, icon or 134400
end

local function ItemName(id)
    local name = ItemInfo(id)
    return name or ("Objeto #" .. id)
end

----------------------------------------------------------------------
-- La lista
----------------------------------------------------------------------
local dirty = false

local function FindItem(id)
    for i, e in ipairs(DB.list) do
        if e.id == id then return e, i end
    end
end

-- Cuenta lo que lleva ESTE personaje (bolsas + banco + banco de banda si se puede)
local function CountMine(id)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, id, true, false, true, true)
        if ok and Num(n) then return Num(n) end
    end
    if GetItemCount then
        local ok, n = pcall(GetItemCount, id, true)
        if ok and Num(n) then return Num(n) end
    end
    return 0
end

local function RecordMine(onlyId)
    if not DB then return end
    local key = MyKey()
    local c = DB.counts[key]
    if not c then c = { name = MyName(), n = {} }; DB.counts[key] = c end
    c.name = MyName(); c.t = time()
    if onlyId then
        c.n[onlyId] = CountMine(onlyId)
    else
        local keep = {}
        for _, e in ipairs(DB.list) do keep[e.id] = CountMine(e.id) end
        c.n = keep
    end
end

-- Total de un objeto entre tus personajes y desglose por personaje
local function Have(id)
    local total, parts = 0, {}
    for key, c in pairs(DB.counts) do
        local n = c.n and c.n[id]
        if n and n > 0 then
            total = total + n
            parts[#parts + 1] = { name = c.name or key, n = n, me = (key == MyKey()) }
        end
    end
    local bankTotal
    if DB.useBank and type(CMBancoCount) == "function" then
        local ok, v = pcall(CMBancoCount, id)
        v = ok and Num(v) or nil
        if v and v > total then bankTotal = v; total = v end
    end
    table.sort(parts, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    return total, parts, bankTotal
end

local lastDone = {}
local function SyncDone()
    for _, e in ipairs(DB.list) do
        lastDone[e.id] = (Have(e.id) >= e.need)
    end
end

local function AddItem(id, need, prio, note, tag, mode)
    id = Num(id)
    if not id or id < 1 or id > 99999999 or id ~= math.floor(id) then return nil, "id" end
    need = Clamp(math.floor(Num(need) or 1), 1, 9999)
    local e = FindItem(id)
    if e then
        if mode == "max" then e.need = math.max(e.need, need)
        elseif mode == "set" then e.need = need
        else e.need = math.min(9999, e.need + need) end
        if prio then e.prio = Clamp(prio, 1, 3) end
        if note and note ~= "" then e.note = Clean(note, 60) end
        if tag and tag ~= "" then e.tag = Clean(tag, 24) end
    else
        if #DB.list >= MaxItems() then return nil, "lleno" end
        e = { id = id, need = need, prio = Clamp(prio or 2, 1, 3), note = Clean(note, 60), tag = Clean(tag, 24) }
        DB.list[#DB.list + 1] = e
    end
    RecordMine(id)
    lastDone[id] = (Have(id) >= e.need)
    dirty = true
    return e
end

local function RemoveItem(id)
    local e, i = FindItem(id)
    if not e then return false end
    table.remove(DB.list, i)
    lastDone[id] = nil
    dirty = true
    return true
end

local function Missing()
    local res = {}
    for _, e in ipairs(DB.list) do
        local have = Have(e.id)
        if have < e.need then res[#res + 1] = { e = e, have = have, miss = e.need - have } end
    end
    table.sort(res, function(a, b)
        if a.e.prio ~= b.e.prio then return a.e.prio < b.e.prio end
        return a.miss > b.miss
    end)
    return res
end

----------------------------------------------------------------------
-- Texto: exportar / importar  ->  id:cantidad:prioridad;id:cantidad:prioridad
----------------------------------------------------------------------
local function Serialize(onlyMissing)
    local out = {}
    for _, e in ipairs(DB.list) do
        if not onlyMissing or Have(e.id) < e.need then
            out[#out + 1] = e.id .. ":" .. e.need .. ":" .. e.prio
        end
    end
    return table.concat(out, ";")
end

-- Devuelve una lista validada { {id, need, prio}, ... } (o nil, motivo)
local function ParseText(text, limit)
    limit = limit or 200
    if type(text) ~= "string" then return nil, "texto vacio" end
    if issecretvalue and issecretvalue(text) then return nil, "dato secreto" end
    local items, seen = {}, {}
    for id, need, prio in text:gmatch("(%d+)[:xX*]+(%d+):?(%d?)") do
        if #id <= 8 and #need <= 4 then
            local i, n = tonumber(id), tonumber(need)
            local p = tonumber(prio) or 2
            if i >= 1 and n >= 1 and not seen[i] then
                seen[i] = true
                items[#items + 1] = { id = i, need = n, prio = Clamp(p, 1, 3) }
                if #items >= limit then break end
            end
        end
    end
    if #items == 0 then return nil, "no se encontro ningun id:cantidad" end
    return items
end

local function ImportItems(items, who)
    local added, merged = 0, 0
    for _, it in ipairs(items) do
        local existed = FindItem(it.id) ~= nil
        local e = AddItem(it.id, it.need, it.prio, nil, who and ("de " .. who) or "importado", "max")
        if e then if existed then merged = merged + 1 else added = added + 1 end end
    end
    return added, merged
end

local function ReadableList(onlyMissing)
    local parts = {}
    for _, e in ipairs(DB.list) do
        local have = Have(e.id)
        if not onlyMissing or have < e.need then
            parts[#parts + 1] = ItemName(e.id) .. " x" .. (onlyMissing and (e.need - have) or e.need)
        end
    end
    return parts
end

local function OpenChatWith(text)
    if #text > 250 then text = text:sub(1, 247) .. "..." end
    if ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(text)
    elseif ChatFrame_OpenChat then ChatFrame_OpenChat(text)
    else Print(text) end
end

----------------------------------------------------------------------
-- Interfaz: ayudantes
----------------------------------------------------------------------
local widgets = {}

local function MakeWindow(name, title, w, h)
    local f = Hub.UI.MakeWindow(name, title, w, h)
    mod:Track(f)
    return f
end

local function MakeButton(parent, text, w, x, y, onClick, anchor)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetPoint(anchor or "TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeCheck(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Refresh = function(self) self:SetChecked(get()) end
    widgets[#widgets + 1] = cb
    return cb
end

local function MakeEdit(parent, w, x, y, numeric, maxLetters, onCommit)
    local e
    local ok = pcall(function() e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate") end)
    if not ok or not e then
        e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        e:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
                        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        e:SetBackdropColor(0, 0, 0, 0.6)
        e:SetFontObject("GameFontHighlightSmall")
        e:SetTextInsets(5, 5, 0, 0)
    end
    e:SetSize(w, 20)
    e:SetPoint("TOPLEFT", x, y)
    e:SetAutoFocus(false)
    if numeric and e.SetNumeric then e:SetNumeric(true) end
    if maxLetters then e:SetMaxLetters(maxLetters) end
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if onCommit then e:SetScript("OnEditFocusLost", function(self) onCommit(self:GetText()) end) end
    return e
end

----------------------------------------------------------------------
-- Ventana de texto (exportar / importar / enviar a un jugador)
----------------------------------------------------------------------
local textWin
local function ShowTextWindow(mode, text)
    if not textWin then
        textWin = MakeWindow("CervecerosMendigosCarritoTexto", "Texto", 600, 150)
        textWin:SetFrameStrata("FULLSCREEN_DIALOG")
        textWin.info = textWin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        textWin.info:SetPoint("TOPLEFT", 16, -34); textWin.info:SetWidth(566); textWin.info:SetJustifyH("LEFT")
        textWin.edit = MakeEdit(textWin, 560, 18, -80, false, 6000)
        textWin.go = MakeButton(textWin, "Aceptar", 110, 16, -112, function() end)
        textWin.close = MakeButton(textWin, "Cerrar", 90, 134, -112, function() textWin:Hide() end)
    end
    local w = textWin
    w.mode = mode
    w.edit:SetText(text or "")
    if mode == "export" then
        w.info:SetText("Selecciona todo (Ctrl+A), copia (Ctrl+C) y pegalo donde quieras. Formato: id:cantidad:prioridad separado por ;")
        w.go:SetText("Pegar en chat")
        w.go:SetScript("OnClick", function() OpenChatWith(w.edit:GetText()); end)
        w:Show()
        w.edit:SetFocus(); w.edit:HighlightText()
    elseif mode == "import" then
        w.info:SetText("Pega aqui una lista con el formato id:cantidad (o id:cantidad:prioridad), separada por ; o espacios. Se mezcla con tu lista (queda la cantidad mayor).")
        w.go:SetText("Importar")
        w.go:SetScript("OnClick", function()
            local items, why = ParseText(w.edit:GetText())
            if not items then Print("no se pudo importar: " .. tostring(why)); return end
            local a, m = ImportItems(items)
            Print("importados: " .. a .. " nuevos, " .. m .. " actualizados.")
            w:Hide()
        end)
        w:Show()
        w.edit:SetFocus()
    end
end

----------------------------------------------------------------------
-- Recordatorios (aviso discreto en pantalla)
----------------------------------------------------------------------
local toast, toastToken = nil, 0
local SOURCES = {
    AUCTION_HOUSE_SHOW = "la casa de subastas", BANKFRAME_OPENED = "el banco",
    MERCHANT_SHOW = "el vendedor", MAIL_SHOW = "el buzon", TRADE_SKILL_SHOW = "la profesion",
}
local lastRemind = {}

local function HideToast() if toast then toast:Hide() end end

local function ShowToast(miss, srcText)
    if not toast then
        toast = mod:Frame("Frame", "CervecerosMendigosCarritoAviso", UIParent, "BackdropTemplate")
        toast:SetSize(300, 100)
        toast:SetPoint("TOP", UIParent, "TOP", 0, -140)
        toast:SetFrameStrata("HIGH")
        toast:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
                            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        toast:SetBackdropColor(0.05, 0.08, 0.08, 0.88)
        toast:SetBackdropBorderColor(0.2, 1, 0.6, 0.9)
        toast:EnableMouse(true)
        toast.icon = toast:CreateTexture(nil, "ARTWORK")
        toast.icon:SetSize(22, 22); toast.icon:SetPoint("TOPLEFT", 8, -8); toast.icon:SetTexture(ICON)
        toast.title = toast:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        toast.title:SetPoint("TOPLEFT", 36, -12); toast.title:SetWidth(250); toast.title:SetJustifyH("LEFT")
        toast.lines = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        toast.lines:SetPoint("TOPLEFT", 12, -36); toast.lines:SetWidth(276); toast.lines:SetJustifyH("LEFT")
        toast.go = CreateFrame("Button", nil, toast, "UIPanelButtonTemplate")
        toast.go:SetSize(110, 20); toast.go:SetPoint("BOTTOMLEFT", 10, 8); toast.go:SetText("Ir a la lista")
        toast.go:SetScript("OnClick", function() HideToast(); OpenWindow(true) end)
        toast.x = CreateFrame("Button", nil, toast, "UIPanelButtonTemplate")
        toast.x:SetSize(70, 20); toast.x:SetPoint("BOTTOMRIGHT", -10, 8); toast.x:SetText("Cerrar")
        toast.x:SetScript("OnClick", HideToast)
    end
    local lines = {}
    local maxL = DB.toastLines or 5
    for i = 1, math.min(maxL, #miss) do
        local m = miss[i]
        lines[#lines + 1] = string.format("%s |cffffd100%d/%d|r", ItemName(m.e.id), m.have, m.e.need)
    end
    if #miss > maxL then lines[#lines + 1] = "|cff999999... y " .. (#miss - maxL) .. " mas|r" end
    toast.title:SetText(string.format("Te faltan %d objetos del carrito", #miss))
    toast.lines:SetText(table.concat(lines, "\n"))
    toast:SetHeight(56 + #lines * 12 + 12)
    toast:SetScale((DB.toastScale or 100) / 100)
    toast:Show()
    toastToken = toastToken + 1
    local my = toastToken
    After(DB.toastTime or 16, function() if my == toastToken then HideToast() end end)
end

local function Remind(event)
    if not DB.remind then return end
    if DB.sources and DB.sources[event] == false then return end
    local now = GetTime()
    if lastRemind[event] and now - lastRemind[event] < (DB.remindEvery or 60) then return end
    RecordMine()
    local miss = Missing()
    if #miss == 0 then return end
    lastRemind[event] = now
    ShowToast(miss, SOURCES[event])
    if DB.chat then Print("te faltan " .. #miss .. " objetos del carrito (" .. (SOURCES[event] or "") .. "). /carrito") end
end

-- Aviso al completar un objeto
local function CheckDone(quiet)
    RecordMine()
    for _, e in ipairs(DB.list) do
        local done = (Have(e.id) >= e.need)
        if done and lastDone[e.id] == false and not quiet then
            Print("|cff33ff33Completo:|r " .. ItemName(e.id) .. " (" .. e.need .. "/" .. e.need .. ")")
            if DB.sound and PlaySound and SOUNDKIT then
                pcall(PlaySound, SOUNDKIT[DB.soundName] or SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.RAID_WARNING, "Master")
            end
        end
        lastDone[e.id] = done
    end
end

----------------------------------------------------------------------
-- Ventana principal
----------------------------------------------------------------------
local win
local view, offset, selId = {}, 0, nil
local rows = {}
local scroll, statusFS, selFS, needEdit, prioBtn, tagEdit, noteEdit, delBtn, addEdit, addQty
local ROWS, RH, ROW_W = 11, 24, 596
local PRIO_NAME = { [1] = "|cffff6060Alta|r", [2] = "|cffffd100Media|r", [3] = "|cff9fd0ffBaja|r" }

local function BuildView()
    view = {}
    for _, e in ipairs(DB.list) do
        local have = Have(e.id)
        local done = have >= e.need
        if not (DB.hideDone and done) then
            view[#view + 1] = { e = e, have = have, done = done, name = ItemName(e.id) }
        end
    end
    table.sort(view, function(a, b)
        if a.done ~= b.done then return not a.done end
        if a.e.prio ~= b.e.prio then return a.e.prio < b.e.prio end
        return a.name < b.name
    end)
end

local function UpdateEditor()
    local e = selId and FindItem(selId)
    if not e then
        selFS:SetText("|cff888888Selecciona un objeto de la lista para editarlo.|r")
        needEdit:SetText(""); tagEdit:SetText(""); noteEdit:SetText("")
        prioBtn:SetText("Prioridad")
        return
    end
    local _, link = ItemInfo(e.id)
    selFS:SetText("Seleccionado: " .. (link or ItemName(e.id)) .. "  |cff888888(id " .. e.id .. ")|r")
    needEdit:SetText(tostring(e.need)); tagEdit:SetText(e.tag or ""); noteEdit:SetText(e.note or "")
    prioBtn:SetText(PRIO_NAME[e.prio] or "Media")
end

local function UpdateRows()
    for i = 1, ROWS do
        local row, v = rows[i], view[offset + i]
        row.v = v
        if not v then
            row:Hide()
        else
            row:Show()
            local e = v.e
            local name, _, q, icon = ItemInfo(e.id)
            row.icon:SetTexture(icon)
            local r, g, b = 1, 1, 1
            if C_Item and C_Item.GetItemQualityColor then
                local cr, cg, cb = C_Item.GetItemQualityColor(q or 1)
                if cr then r, g, b = cr, cg, cb end
            end
            row.name:SetText(name or ("Objeto #" .. e.id))
            row.name:SetTextColor(r, g, b)
            if v.done then
                row.have:SetText("|cff33ff33" .. v.have .. "/" .. e.need .. " ok|r")
                row.mark:SetColorTexture(0.1, 0.6, 0.2, 0.16)
            else
                local col = (v.have > 0) and "|cffffd100" or "|cffff6060"
                row.have:SetText(col .. v.have .. "/" .. e.need .. "|r")
                row.mark:SetColorTexture(0, 0, 0, 0)
            end
            local _, parts = Have(e.id)
            local who = {}
            for _, p in ipairs(parts) do who[#who + 1] = p.name .. " " .. p.n end
            row.where:SetText(#who > 0 and table.concat(who, ", ") or "|cff888888nadie|r")
            row.prio:SetText(PRIO_NAME[e.prio] or "")
            row.tagfs:SetText(Clean(e.tag, 12))
            row.sel:SetShown(selId == e.id)
        end
    end
end

local function SetupScroll()
    local maxOff = math.max(0, #view - ROWS)
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
    local miss = Missing()
    local ctr = {}
    for _ in pairs(DB.counts) do ctr[#ctr + 1] = 1 end
    statusFS:SetText(string.format("%d objetos - |cffff8030%d por conseguir|r - %d personajes guardados%s",
        #DB.list, #miss, #ctr, (type(CMBancoCount) == "function") and " - usando CervecerosMendigosBanco" or ""))
end

local function RefreshWindow()
    if not win or not win:IsShown() then return end
    RecordMine()
    BuildView()
    SetupScroll()
    UpdateEditor()
    UpdateStatus()
end

local function SelectItem(id)
    selId = id
    UpdateRows()
    UpdateEditor()
end

local function AddFromInput()
    local text = addEdit:GetText() or ""
    local id = tonumber(text:match("item:(%d+)"))
    if not id then
        local plain = text:match("^%s*(%d+)%s*$")
        id = plain and tonumber(plain)
    end
    if not id and text ~= "" then
        local fn = C_Item and C_Item.GetItemInfoInstant
        if fn then
            local ok, v = pcall(fn, text)
            if ok and Num(v) then id = Num(v) end
        end
    end
    if not id then Print("escribe un enlace de objeto, su id o su nombre exacto (si esta en la cache)."); return end
    local qty = tonumber(addQty:GetText()) or 1
    local e, why = AddItem(id, qty, 2, nil, nil, "add")
    if not e then Print(why == "lleno" and "la lista esta llena" or "id no valido"); return end
    Print("anadido " .. ItemName(id) .. " (" .. e.need .. ")")
    addEdit:SetText(""); addEdit:ClearFocus()
    selId = id
    RefreshWindow()
end

local function CommitEdit(field, text)
    local e = selId and FindItem(selId)
    if not e then return end
    if field == "need" then
        local n = tonumber(text)
        if n and n >= 1 then e.need = Clamp(math.floor(n), 1, 9999) end
        lastDone[e.id] = (Have(e.id) >= e.need)
    elseif field == "tag" then e.tag = Clean(text, 24)
    elseif field == "note" then e.note = Clean(text, 60) end
    dirty = true
end

local function BuildRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_W, RH)
    row:SetPoint("TOPLEFT", 14, -140 - (i - 1) * RH)
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(); row.hl:SetColorTexture(1, 1, 1, 0.08)
    row.mark = row:CreateTexture(nil, "BACKGROUND")
    row.mark:SetAllPoints()
    row.sel = row:CreateTexture(nil, "BORDER")
    row.sel:SetAllPoints(); row.sel:SetColorTexture(0.2, 0.5, 1, 0.22)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT", 2, 0)
    local function FS(x, w, just)
        local f = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f:SetPoint("LEFT", x, 0); f:SetWidth(w); f:SetJustifyH(just or "LEFT")
        f:SetWordWrap(false)
        return f
    end
    row.name = FS(28, 190)
    row.have = FS(220, 76, "RIGHT")
    row.where = FS(304, 160)
    row.prio = FS(468, 40)
    row.tagfs = FS(510, 66)
    row.del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.del:SetSize(18, 18); row.del:SetPoint("RIGHT", -2, 0); row.del:SetText("x")
    row.del:SetScript("OnClick", function()
        local v = row.v
        if not v then return end
        if selId == v.e.id then selId = nil end
        RemoveItem(v.e.id)
        RefreshWindow()
    end)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self) if self.v then SelectItem(self.v.e.id) end end)
    row:SetScript("OnEnter", function(self)
        local v = self.v
        if not v then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local _, link = ItemInfo(v.e.id)
        if link and GameTooltip.SetHyperlink then GameTooltip:SetHyperlink(link) else GameTooltip:AddLine(ItemName(v.e.id)) end
        GameTooltip:AddLine(" ")
        local total, parts, bankTotal = Have(v.e.id)
        GameTooltip:AddLine(string.format("Tienes %d de %d", total, v.e.need), 1, 1, 1)
        for _, p in ipairs(parts) do
            GameTooltip:AddLine("  " .. p.name .. ": " .. p.n .. (p.me and " (este personaje)" or ""), 0.8, 0.8, 0.8)
        end
        if bankTotal then GameTooltip:AddLine("  Total segun CervecerosMendigosBanco: " .. bankTotal, 0.6, 0.8, 1) end
        if v.e.note and v.e.note ~= "" then GameTooltip:AddLine("Nota: " .. v.e.note, 1, 0.9, 0.5, true) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-- Se define mas abajo (compartir)
local ShareList

local function RefreshWidgets()
    for _, w in ipairs(widgets) do if w.Refresh then w:Refresh() end end
end

local function BuildWindow()
    win = MakeWindow("CervecerosMendigosCarritoWindow", "Carrito de materiales", 650, 612)

    local logo = win:CreateTexture(nil, "ARTWORK")
    logo:SetSize(40, 40); logo:SetPoint("TOPLEFT", 16, -30)
    logo:SetTexture(ICON)
    local intro = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", logo, "TOPRIGHT", 8, -2)
    intro:SetWidth(570); intro:SetJustifyH("LEFT")
    intro:SetText("Tu lista de la compra, compartida entre tus personajes. Arrastra un objeto de las bolsas a esta ventana, o Mayus+clic sobre un objeto con la ventana abierta (Ctrl+Alt+clic funciona siempre).")

    -- anadir por enlace / id / nombre
    local lab = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lab:SetPoint("TOPLEFT", 16, -84); lab:SetText("Anadir objeto (enlace, id o nombre) y cantidad:")
    addEdit = MakeEdit(win, 300, 18, -102, false, 200)
    addEdit:SetScript("OnEnterPressed", function() AddFromInput() end)
    addQty = MakeEdit(win, 44, 330, -102, true, 4)
    addQty:SetText("1")
    MakeButton(win, "Anadir", 80, 384, -101, AddFromInput)

    local function Col(text, x, w, just)
        local f = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetPoint("TOPLEFT", x + 14, -126); f:SetWidth(w); f:SetJustifyH(just or "LEFT"); f:SetText(text)
    end
    Col("Objeto", 28, 190); Col("Tienes", 220, 76, "RIGHT"); Col("Quien lo tiene", 304, 160)
    Col("Prioridad", 468, 40); Col("Etiqueta", 510, 66)

    for i = 1, ROWS do rows[i] = BuildRow(win, i) end

    scroll = CreateFrame("Slider", nil, win)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, ROWS * RH)
    scroll:SetPoint("TOPLEFT", 614, -140)
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

    -- soltar un objeto desde las bolsas
    local function OnDrop()
        local kind, id = GetCursorInfo()
        if kind == "item" and Num(id) then
            local e = AddItem(id, 1, 2, nil, nil, "add")
            if e then Print("anadido " .. ItemName(id) .. " (" .. e.need .. ")"); selId = id end
            ClearCursor()
            RefreshWindow()
        end
    end
    win:SetScript("OnReceiveDrag", OnDrop)
    win:HookScript("OnMouseUp", function() if GetCursorInfo and GetCursorInfo() then OnDrop() end end)

    -- editor del objeto seleccionado
    selFS = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    selFS:SetPoint("TOPLEFT", 18, -416); selFS:SetWidth(610); selFS:SetJustifyH("LEFT")
    local function Lbl(text, x)
        local f = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetPoint("TOPLEFT", x, -440); f:SetText(text)
    end
    Lbl("Cant.", 18)
    needEdit = MakeEdit(win, 44, 56, -436, true, 4, function(t) CommitEdit("need", t); RefreshWindow() end)
    prioBtn = MakeButton(win, "Prioridad", 84, 110, -435, function()
        local e = selId and FindItem(selId)
        if not e then return end
        e.prio = (e.prio % 3) + 1
        dirty = true
        RefreshWindow()
    end)
    Lbl("Etiqueta", 204)
    tagEdit = MakeEdit(win, 100, 254, -436, false, 24, function(t) CommitEdit("tag", t); RefreshWindow() end)
    Lbl("Nota", 366)
    noteEdit = MakeEdit(win, 170, 398, -436, false, 60, function(t) CommitEdit("note", t) end)
    delBtn = MakeButton(win, "Quitar", 64, 578, -435, function()
        if not selId then return end
        RemoveItem(selId); selId = nil
        RefreshWindow()
    end)

    -- botones inferiores
    MakeButton(win, "Compartir", 100, 16, -472, function() ShareList() end)
    MakeButton(win, "Importar", 90, 120, -472, function() ShowTextWindow("import", "") end)
    MakeButton(win, "Exportar", 90, 214, -472, function() ShowTextWindow("export", Serialize(false)) end)
    MakeButton(win, "Faltan al chat", 110, 308, -472, function()
        local p = ReadableList(true)
        if #p == 0 then Print("no te falta nada.") else OpenChatWith("Me faltan: " .. table.concat(p, ", ")) end
    end)
    MakeButton(win, "Quitar completos", 120, 422, -472, function()
        local n = 0
        for i = #DB.list, 1, -1 do
            local e = DB.list[i]
            if Have(e.id) >= e.need then table.remove(DB.list, i); lastDone[e.id] = nil; n = n + 1 end
        end
        Print(n .. " objetos completos quitados")
        RefreshWindow()
    end)
    MakeButton(win, "Borrar todo", 90, 546, -472, function()
        if win.confirmClear then
            for i = #DB.list, 1, -1 do table.remove(DB.list, i) end; lastDone = {}; selId = nil; win.confirmClear = false
            Print("lista borrada")
            RefreshWindow()
        else
            win.confirmClear = true
            Print("pulsa otra vez Borrar todo para confirmar")
            After(6, function() win.confirmClear = false end)
        end
    end)

    statusFS = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusFS:SetPoint("BOTTOMLEFT", 16, 30); statusFS:SetWidth(610); statusFS:SetJustifyH("LEFT")
    local legend = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMLEFT", 16, 14); legend:SetWidth(610); legend:SetJustifyH("LEFT")
    legend:SetText("Comandos: /carrito, /cmcarrito (anadir, quitar, lista, falta, exportar, importar, enviar, prueba). Los ajustes estan en el panel CervecerosMendigosGeneral.")

    win:SetScript("OnShow", function() RefreshWidgets(); RefreshWindow() end)
end

OpenWindow = function(forceShow)
    if not DB then return end
    if not win then BuildWindow() end
    if win:IsShown() and not forceShow then win:Hide() else win:Show() end
end

----------------------------------------------------------------------
-- Compartir con el grupo (mensajes de addon)
--   O|sid|nObjetos|nTrozos        oferta (grupo)
--   A|sid                         aceptacion (susurro al que ofrece)
--   D|sid|idx|id:cant:prio;...    trozo de datos (susurro al que acepto)
----------------------------------------------------------------------
local sent = {}        -- ofertas que he enviado: sent[sid] = { chunks=, n=, t=, accepted={} }
local offers = {}      -- ofertas recibidas: offers[sid] = { from=, n=, chunks=, state=, got={}, t= }
local offerQueue = {}  -- ofertas esperando la decision del usuario
local rate = {}        -- rate[remitente] = { t1, t2, ... }
local sendQueue = {}   -- { msg, chan, target }

local function RawSend(msg, chan, target)
    local fn = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    if not fn then return false, "no hay API de mensajes de addon" end
    local ok, r = pcall(fn, PREFIX, msg, chan, target)
    if not ok then return false, "error" end
    if r == nil or r == true or r == 0 then return true end
    local locked = Enum and Enum.SendAddonMessageResult and r == Enum.SendAddonMessageResult.AddOnMessageLockdown
    if locked or r == 11 then return false, "bloqueado" end
    return false, r
end

local function GroupChannel()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

local function NewSid()
    local s = ""
    for _ = 1, 6 do s = s .. string.format("%x", math.random(0, 15)) end
    return s
end

local function Chunks(items)
    local out, cur = {}, {}
    for _, it in ipairs(items) do
        cur[#cur + 1] = it.id .. ":" .. it.need .. ":" .. it.prio
        if #cur >= PER_CHUNK then out[#out + 1] = table.concat(cur, ";"); cur = {} end
    end
    if #cur > 0 then out[#out + 1] = table.concat(cur, ";") end
    return out
end

local function BuildShareItems()
    local items = {}
    for _, e in ipairs(DB.list) do
        items[#items + 1] = { id = e.id, need = e.need, prio = e.prio }
        if #items >= MaxShare() then break end
    end
    return items
end

-- Ofrece la lista al grupo (target nil) o a un jugador (target = nombre)
ShareList = function(target)
    local items = BuildShareItems()
    if #items == 0 then Print("tu lista esta vacia."); return end
    local chan = target and "WHISPER" or GroupChannel()
    if not chan then Print("no estas en grupo. Usa /carrito enviar Nombre para enviarla a un jugador."); return end
    local chunks = Chunks(items)
    local sid = NewSid()
    sent[sid] = { chunks = chunks, n = #items, t = GetTime(), accepted = {} }
    local ok, why = RawSend(string.format("O|%s|%d|%d", sid, #items, #chunks), chan, target)
    if not ok then
        sent[sid] = nil
        if why == "bloqueado" then Print("los mensajes de addon estan bloqueados ahora mismo (combate o instancia). Prueba despues.")
        else Print("no se pudo enviar la oferta (" .. tostring(why) .. ")") end
        return
    end
    Print("oferta enviada (" .. #items .. " objetos). Quien la acepte la recibira en unos segundos.")
end

local function RecentOffers(sender)
    local r = rate[sender]
    if not r then r = {}; rate[sender] = r end
    local now, keep = GetTime(), {}
    for _, t in ipairs(r) do if now - t < 60 then keep[#keep + 1] = t end end
    rate[sender] = keep
    return keep
end

local dialog
local ShowNextOffer

local function CloseOffer(sid, state)
    local o = offers[sid]
    if o then o.state = state end
    if dialog then dialog:Hide(); dialog.sid = nil end
    After(0.2, function() ShowNextOffer() end)
end

local function ApplyReceived(o)
    local list = {}
    for idx = 1, o.chunks do
        local c = o.got[idx]
        if c then for _, it in ipairs(c) do list[#list + 1] = it end end
    end
    if #list == 0 then Print("la lista de " .. o.from .. " llego vacia."); return end
    local added, merged = ImportItems(list, Clean(o.fromShort, 20))
    Print(string.format("recibida la lista de |cffffd100%s|r: %d nuevos, %d actualizados.", Clean(o.fromShort, 30), added, merged))
    dirty = true
end

local function BuildDialog()
    dialog = mod:Frame("Frame", "CervecerosMendigosCarritoOferta", UIParent, "BackdropTemplate")
    dialog:SetSize(360, 120)
    dialog:SetPoint("CENTER", 0, 120)
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                         edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                         edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    dialog:EnableMouse(true)
    dialog.icon = dialog:CreateTexture(nil, "ARTWORK")
    dialog.icon:SetSize(28, 28); dialog.icon:SetPoint("TOPLEFT", 14, -14); dialog.icon:SetTexture(ICON)
    dialog.text = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dialog.text:SetPoint("TOPLEFT", 50, -14); dialog.text:SetWidth(296); dialog.text:SetJustifyH("LEFT")
    dialog.ok = MakeButton(dialog, "Aceptar", 100, 14, -86, function()
        local sid = dialog.sid
        local o = sid and offers[sid]
        if not o then dialog:Hide(); return end
        if o.test then
            local fake = { chunks = 1, from = o.from, fromShort = o.from, got = { [1] = {
                { id = 2770, need = 20, prio = 2 }, { id = 2589, need = 40, prio = 2 }, { id = 118, need = 5, prio = 1 } } } }
            ApplyReceived(fake)
            CloseOffer(sid, "done")
            return
        end
        local ok, why = RawSend("A|" .. sid, "WHISPER", o.from)
        if not ok then Print("no se pudo aceptar (" .. tostring(why) .. ")"); CloseOffer(sid, "ignored"); return end
        o.state = "wait"; o.t = GetTime()
        Print("aceptada, esperando los datos de " .. Clean(o.fromShort, 30) .. "...")
        if dialog then dialog:Hide() end
        dialog.sid = nil
        After(0.2, function() ShowNextOffer() end)
    end)
    dialog.no = MakeButton(dialog, "Ignorar", 100, 120, -86, function() if dialog.sid then CloseOffer(dialog.sid, "ignored") end end)
    dialog.block = MakeButton(dialog, "Bloquear", 100, 226, -86, function()
        local o = dialog.sid and offers[dialog.sid]
        if o then DB.ignored[o.from] = true; Print("ya no recibiras listas de " .. Clean(o.fromShort, 30)) end
        if dialog.sid then CloseOffer(dialog.sid, "ignored") end
    end)
    dialog:Hide()
end

ShowNextOffer = function()
    if not dialog then BuildDialog() end
    if dialog:IsShown() then return end
    while #offerQueue > 0 do
        local sid = table.remove(offerQueue, 1)
        local o = offers[sid]
        if o and o.state == "ask" and GetTime() - o.t < OfferTTL() then
            dialog.sid = sid
            dialog.text:SetText(string.format("|cffffd100%s|r te envia una lista de |cff33ff99%d objetos|r.\nSe mezclara con tu carrito.", Clean(o.fromShort, 30), o.n))
            dialog:Show()
            return
        end
    end
end

local function IsGroupMember(sender)
    local name = Ambiguate and Ambiguate(sender, "none") or sender
    if UnitInParty and UnitInParty(name) then return true end
    if UnitInRaid and UnitInRaid(name) then return true end
    return false
end

local function IsMe(sender)
    local me = MyName()
    if sender == me then return true end
    local short = Ambiguate and Ambiguate(sender, "short") or sender
    return short == me
end

local function ParseChunk(text)
    local out = {}
    for id, need, prio in text:gmatch("(%d+):(%d+):(%d)") do
        if #id <= 8 and #need <= 4 then
            local i, n, p = tonumber(id), tonumber(need), tonumber(prio)
            if i >= 1 and n >= 1 and p >= 1 and p <= 3 then out[#out + 1] = { id = i, need = n, prio = p } end
        end
        if #out >= PER_CHUNK then break end
    end
    return out
end

-- Procesa un mensaje de addon recibido (validacion estricta de todo)
local function HandleMessage(text, channel, sender)
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    if issecretvalue and (issecretvalue(text) or issecretvalue(sender) or issecretvalue(channel)) then return end
    if #text > 255 or #sender > 80 then return end
    if IsMe(sender) then return end
    if DB.ignored[sender] then return end
    local kind = text:sub(1, 2)
    local fromShort = Ambiguate and Ambiguate(sender, "short") or sender

    if kind == "O|" then
        local sid, n, nch = text:match("^O|(%x%x%x%x%x%x)|(%d+)|(%d+)$")
        n, nch = tonumber(n), tonumber(nch)
        if not sid or not n or not nch then return end
        if n < 1 or n > PROTO_MAX_SHARE or nch < 1 or nch > 10 or nch ~= math.ceil(n / PER_CHUNK) then return end
        if not IsGroupMember(sender) and not DB.acceptAny then return end
        if offers[sid] then return end
        local r = RecentOffers(sender)
        if #r >= 3 then return end
        r[#r + 1] = GetTime()
        if #offerQueue >= 3 then return end
        offers[sid] = { from = sender, fromShort = fromShort, n = n, chunks = nch, state = "ask", got = {}, t = GetTime() }
        offerQueue[#offerQueue + 1] = sid
        ShowNextOffer()

    elseif kind == "A|" then
        local sid = text:match("^A|(%x%x%x%x%x%x)$")
        local s = sid and sent[sid]
        if not s or GetTime() - s.t > OfferTTL() then return end
        if s.accepted[sender] then return end
        local cnt = 0
        for _ in pairs(s.accepted) do cnt = cnt + 1 end
        if cnt >= 10 then return end
        s.accepted[sender] = true
        for idx, c in ipairs(s.chunks) do
            sendQueue[#sendQueue + 1] = { string.format("D|%s|%d|%s", sid, idx, c), "WHISPER", sender }
        end
        Print(Clean(fromShort, 30) .. " ha aceptado tu lista, enviando...")

    elseif kind == "D|" then
        local sid, idx, body = text:match("^D|(%x%x%x%x%x%x)|(%d+)|([%d:;]+)$")
        idx = tonumber(idx)
        local o = sid and offers[sid]
        if not o or o.state ~= "wait" or o.from ~= sender then return end
        if GetTime() - o.t > OfferTTL() then o.state = "expired"; return end
        if not idx or idx < 1 or idx > o.chunks or o.got[idx] then return end
        local parsed = ParseChunk(body)
        if #parsed == 0 then return end
        o.got[idx] = parsed
        local have = 0
        for i = 1, o.chunks do if o.got[i] then have = have + 1 end end
        if have == o.chunks then
            o.state = "done"
            ApplyReceived(o)
        end
    end
end

-- Oferta falsa para probar sin tener grupo
local function TestOffer()
    local sid = NewSid()
    offers[sid] = { from = "Probador", fromShort = "Probador", n = 3, chunks = 1, state = "ask", got = {}, t = GetTime(), test = true }
    offerQueue[#offerQueue + 1] = sid
    ShowNextOffer()
end

----------------------------------------------------------------------
-- Clic con modificador: anadir objetos desde bolsas, chat, etc.
----------------------------------------------------------------------
local function OnModifiedClick(link)
    if not mod or not mod:IsEnabled() or not DB or type(link) ~= "string" then return end
    local cm = DB.clickAdd or "both"
    if cm == "off" then return end
    if issecretvalue and issecretvalue(link) then return end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return end
    local ctrlAlt = cm ~= "shift" and IsControlKeyDown and IsAltKeyDown and IsControlKeyDown() and IsAltKeyDown()
    local shiftOpen = false
    if cm ~= "ctrlalt" and IsShiftKeyDown and IsShiftKeyDown() and win and win:IsShown() then
        local box = ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow()
            or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
        shiftOpen = not box
    end
    if not (ctrlAlt or shiftOpen) then return end
    local e = AddItem(id, 1, 2, nil, nil, "add")
    if e then
        Print("+ " .. ItemName(id) .. " (" .. e.need .. ")")
        selId = id
        RefreshWindow()
    end
end

----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local extra
local EVENTS = {
    "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
    "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "CHAT_MSG_ADDON",
    "AUCTION_HOUSE_SHOW", "MERCHANT_SHOW", "MAIL_SHOW", "TRADE_SKILL_SHOW", "PLAYER_LOGOUT",
}

local ready, bagPending = false, false
local bankOpen = false

local function OnEvent(event, a1, a2, a3, a4)
    if not DB then return end
    if event == "PLAYER_ENTERING_WORLD" then
        After(6, function()
            RecordMine(); SyncDone(); ready = true
            dirty = true
        end)
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYERBANKSLOTS_CHANGED" then
        if ready and not bagPending then
            bagPending = true
            After(0.8, function()
                bagPending = false
                CheckDone(false)
                dirty = true
            end)
        end
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        After(1.2, function() RecordMine(); dirty = true end)
        if ready then Remind(event) end
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
        RecordMine()
    elseif event == "AUCTION_HOUSE_SHOW" or event == "MERCHANT_SHOW" or event == "MAIL_SHOW"
        or event == "TRADE_SKILL_SHOW" then
        if ready then After(0.6, function() Remind(event) end) end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if win and win:IsShown() then dirty = true end
    elseif event == "CHAT_MSG_ADDON" then
        if a1 == PREFIX then HandleMessage(a2, a3, a4) end
    elseif event == "PLAYER_LOGOUT" then
        pcall(RecordMine)
    end
end

local acc, accSend = 0, 0
local function OnUpdate(_, elapsed)
    if not DB then return end
    acc = acc + elapsed
    if acc >= 0.5 then
        acc = 0
        if dirty then
            dirty = false
            RefreshWindow()
        end
        -- caducan las ofertas viejas
        local now = GetTime()
        for sid, s in pairs(sent) do if now - s.t > OfferTTL() * 2 then sent[sid] = nil end end
        for sid, o in pairs(offers) do
            if o.state ~= "ask" and now - o.t > OfferTTL() * 2 then offers[sid] = nil end
        end
    end
    -- cola de envio: un mensaje cada 0,4 s para no saturar al servidor
    accSend = accSend + elapsed
    if accSend >= 0.4 and #sendQueue > 0 then
        accSend = 0
        local m = table.remove(sendQueue, 1)
        local ok, why = RawSend(m[1], m[2], m[3])
        if not ok and why ~= "bloqueado" and (m.tries or 0) < 3 then
            m.tries = (m.tries or 0) + 1
            table.insert(sendQueue, 1, m)
        elseif not ok then
            Print("no se pudo enviar un trozo de la lista (" .. tostring(why) .. ")")
            sendQueue = {}
        end
    end
end

----------------------------------------------------------------------
-- Comandos: /carrito  /cmcarrito
----------------------------------------------------------------------
local function ItemFromText(text)
    local id = tonumber(text:match("item:(%d+)"))
    if id then return id end
    return tonumber(text:match("^%s*(%d+)"))
end

local function OnSlash(m, msg)
    msg = msg or ""
    local cmd, arg = string.match(msg, "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    if cmd == "" or cmd == "config" or cmd == "ventana" then
        OpenWindow()
    elseif cmd == "anadir" or cmd == "a\195\177adir" or cmd == "add" then
        local id = ItemFromText(arg)
        if not id then Print("uso: /carrito anadir [objeto] 20   (pega el enlace del objeto o su id)"); return end
        local qty = tonumber(arg:match("|h|r%s+(%d+)")) or tonumber(arg:match("^%d+%s+(%d+)")) or 1
        local e, why = AddItem(id, qty, 2, nil, nil, "add")
        if not e then Print(why == "lleno" and "la lista esta llena" or "id no valido"); return end
        Print("anadido " .. ItemName(id) .. " (" .. e.need .. ")")
        RefreshWindow()
    elseif cmd == "quitar" or cmd == "remove" then
        local id = ItemFromText(arg)
        if id and RemoveItem(id) then Print("quitado " .. ItemName(id)); RefreshWindow()
        else Print("uso: /carrito quitar [objeto]  (o su id; debe estar en la lista)") end
    elseif cmd == "lista" then
        if #DB.list == 0 then Print("la lista esta vacia."); return end
        for _, e in ipairs(DB.list) do
            local have = Have(e.id)
            Print(string.format("%s %s%d/%d|r", ItemName(e.id), have >= e.need and "|cff33ff33" or "|cffff6060", have, e.need))
        end
    elseif cmd == "falta" then
        local miss = Missing()
        if #miss == 0 then Print("no te falta nada."); return end
        for _, m in ipairs(miss) do Print(string.format("%s: faltan %d (%d/%d)", ItemName(m.e.id), m.miss, m.have, m.e.need)) end
    elseif cmd == "exportar" then
        ShowTextWindow("export", Serialize(false))
    elseif cmd == "importar" then
        if arg ~= "" then
            local items, why = ParseText(arg)
            if not items then Print("no se pudo importar: " .. tostring(why)); return end
            local a, m = ImportItems(items)
            Print("importados: " .. a .. " nuevos, " .. m .. " actualizados.")
            RefreshWindow()
        else
            ShowTextWindow("import", "")
        end
    elseif cmd == "enviar" then
        local who = arg ~= "" and Clean(arg, 60) or nil
        ShareList(who)
    elseif cmd == "prueba" then
        TestOffer()
    elseif cmd == "aviso" then
        DB.chat = not DB.chat
        Print("aviso en el chat: " .. (DB.chat and "activado" or "desactivado"))
    elseif cmd == "recordar" then
        DB.remind = not DB.remind
        Print("recordatorios: " .. (DB.remind and "activados" or "desactivados"))
    elseif cmd == "borrar" then
        if arg == "si" then for i = #DB.list, 1, -1 do table.remove(DB.list, i) end; lastDone = {}; selId = nil; Print("lista borrada"); RefreshWindow()
        else Print("para borrar toda la lista escribe: /carrito borrar si") end
    elseif cmd == "debug" then
        Print("objetos=" .. #DB.list .. " Banco=" .. tostring(type(CMBancoCount) == "function")
            .. " C_Item.GetItemCount=" .. tostring(C_Item and C_Item.GetItemCount ~= nil)
            .. " SendAddonMessage=" .. tostring((C_ChatInfo and C_ChatInfo.SendAddonMessage) ~= nil)
            .. " grupo=" .. tostring(GroupChannel()))
    else
        Print("/carrito = ventana | anadir [objeto] N | quitar [objeto] | lista | falta | exportar | importar [texto] | enviar [Nombre] | aviso | recordar | prueba | borrar si | debug")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local hooked = false
local function BindData()
    DB.list = DB.list or keep.list or {}
    DB.counts = DB.counts or keep.counts or {}
    DB.ignored = DB.ignored or keep.ignored or {}
    keep.list, keep.counts, keep.ignored = DB.list, DB.counts, DB.ignored
    -- limpieza de datos que no sean validos (por si se editaron a mano)
    for i = #DB.list, 1, -1 do
        local e = DB.list[i]
        if type(e) ~= "table" or not Num(e.id) or not Num(e.need) then table.remove(DB.list, i)
        else e.prio = Clamp(Num(e.prio) or 2, 1, 3); e.note = Clean(e.note, 60); e.tag = Clean(e.tag, 24) end
    end
end

local function RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, PREFIX)
    end
end

mod = Hub:Register{
    key = "carrito", dir = "Carrito", name = "Carrito de materiales",
    desc = "Lista de la compra compartida entre tus personajes y con tu grupo, con recordatorios al abrir subasta, banco, vendedor o buzon. Avisos, sonidos y comparticion configurables.",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosCarritoDB",
    slash = { "carrito", "cmcarrito" },

    Init = function(m)
        DB = m.db
        ICON = m.path .. "icon.tga"
        BindData()
        RegisterPrefix()
        if hooksecurefunc and type(HandleModifiedItemClick) == "function" and not hooked then
            hooked = true
            pcall(hooksecurefunc, "HandleModifiedItemClick", OnModifiedClick)
        end
        extra = m:Frame("Frame")
        extra:SetScript("OnEvent", function(_, event, a1, a2, a3, a4) OnEvent(event, a1, a2, a3, a4) end)
        m:OnUpdate(OnUpdate)
    end,

    Enable = function(m)
        DB = m.db
        BindData()
        RegisterPrefix()
        for _, ev in ipairs(EVENTS) do pcall(extra.RegisterEvent, extra, ev) end
        After(1, function() RecordMine(); SyncDone(); ready = true; dirty = true end)
    end,

    Disable = function(m)
        if extra then extra:UnregisterAllEvents() end
        ready = false; bagPending = false
        toastToken = toastToken + 1
        wipe(sendQueue)
    end,

    OnReset = function(m)
        -- Hub vacia mod.db: devolvemos la lista, los recuentos y los bloqueos del usuario
        m.db.list, m.db.counts, m.db.ignored = keep.list, keep.counts, keep.ignored
        DB = m.db
        BindData()
        dirty = true
    end,

    BuildConfig = function(m, L)
        local db = m.db
        L:Header("Tu carrito")
        L:Text("Las listas se guardan por cuenta: las comparten todos tus personajes.", true)
        L:Button("Abrir la lista del carrito", 220, function() OpenWindow(true) end)
        L:Button("Compartir con el grupo", 200, function() ShareList() end)
        L:Button("Importar...", 110, function() ShowTextWindow("import", "") end, true)
        L:Button("Exportar...", 110, function() ShowTextWindow("export", Serialize(false)) end, true)

        L:Header("Recordatorios")
        L:Check("Recordar lo que falta al abrir estos sitios", function() return db.remind end, function(v) db.remind = v end)
        L:Check("  Casa de subastas", function() return db.sources.AUCTION_HOUSE_SHOW end, function(v) db.sources.AUCTION_HOUSE_SHOW = v end)
        L:Check("  Banco", function() return db.sources.BANKFRAME_OPENED end, function(v) db.sources.BANKFRAME_OPENED = v end)
        L:Check("  Vendedor", function() return db.sources.MERCHANT_SHOW end, function(v) db.sources.MERCHANT_SHOW = v end)
        L:Check("  Buzon", function() return db.sources.MAIL_SHOW end, function(v) db.sources.MAIL_SHOW = v end)
        L:Check("  Profesion", function() return db.sources.TRADE_SKILL_SHOW end, function(v) db.sources.TRADE_SKILL_SHOW = v end)
        L:Slider("Segundos que se ve el aviso", 3, 60, 1, function() return db.toastTime end, function(v) db.toastTime = v end)
        L:Slider("Objetos que lista el aviso", 1, 10, 1, function() return db.toastLines end, function(v) db.toastLines = v end)
        L:Slider("Tamano del aviso (%)", 50, 200, 5, function() return db.toastScale end, function(v) db.toastScale = v end)
        L:Slider("Pausa minima entre avisos del mismo sitio (s)", 0, 600, 10, function() return db.remindEvery end, function(v) db.remindEvery = v end)
        L:Check("Aviso tambien en el chat", function() return db.chat end, function(v) db.chat = v end)

        L:Header("Al completar un objeto")
        L:Check("Sonido al completar", function() return db.sound end, function(v) db.sound = v end)
        L:Choice("Sonido", SOUND_OPTIONS, function() return db.soundName end, function(v) db.soundName = v end)

        L:Header("La lista")
        L:Check("Ocultar los objetos completos", function() return db.hideDone end, function(v) db.hideDone = v; dirty = true end)
        L:Check("Usar el total de otros personajes del modulo Banco (si esta)", function() return db.useBank end, function(v) db.useBank = v; dirty = true end)
        L:Choice("Anadir objetos con clic", CLICK_OPTIONS, function() return db.clickAdd end, function(v) db.clickAdd = v end)
        L:Slider("Tamano maximo de la lista", 20, 1000, 10, function() return db.maxItems end, function(v) db.maxItems = v end)

        L:Header("Compartir con el grupo")
        L:Check("Aceptar listas de quien no es de mi grupo", function() return db.acceptAny end, function(v) db.acceptAny = v end)
        L:Slider("Objetos por lista que envio", 5, 60, 5, function() return db.maxShare end, function(v) db.maxShare = v end)
        L:Slider("Segundos que vive una oferta", 30, 600, 10, function() return db.offerTTL end, function(v) db.offerTTL = v end)
        L:Button("Quitar todos los bloqueos", 200, function()
            for k in pairs(db.ignored) do db.ignored[k] = nil end
            Print("bloqueos quitados.")
        end)
        L:Button("Recibir una lista de prueba", 200, function() TestOffer() end, true)
    end,

    OnSlash = OnSlash,
}
