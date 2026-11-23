-- CervecerosMendigos · modulo Profesiones (para el addon grande CervecerosMendigosGeneral).
-- Asistente de profesiones: lee tu nivel (C_SkillInfo), y con los datos embebidos (Datos.lua,
-- solo ids numericos) calcula que recetas hacer para subir, cuantas veces, y que materiales
-- te faltan (bolsas + banco + otros personajes si el modulo Banco esta activado).
-- Nada de esto toca el combate, asi que no hay "valores secretos" que manejar.

local ADDON, ns = ...
local Hub = ns.Hub
local UI = Hub.UI

local mod, S, DATA            -- mod = modulo; S = ajustes (mod.db); DATA = datos guardados (recetas vistas)

local DEFAULTS = {
    target = "tramo",      -- tramo | max | 300
    useAlts = true,        -- contar tambien lo de tus otros personajes (si el modulo Banco esta activado)
    onlyKnown = true,      -- solo recetas aprendidas (si el juego deja comprobarlo)
    scanKnown = true,      -- leer y recordar tus recetas al abrir la ventana de profesion
    openOnTradeSkill = false, -- abrir el asistente al abrir la ventana de una profesion
    chanceOrange = 100,    -- % de probabilidad de subir punto con receta naranja
    chanceYellow = 75,     -- amarilla
    chanceGreen = 25,      -- verde
    stockWeight = 10,      -- % del valor de los materiales que ya tienes que cuenta como coste
    defaultCost = 100,     -- cobre por unidad si el juego aun no conoce el precio del objeto
    cartPriority = 2,      -- prioridad con la que se envian los faltantes al Carrito (1 alta - 3 baja)
    windowScale = 100,     -- tamano de la ventana del asistente (%)
}

local TIERS = { "Aprendiz", "Oficial", "Experto", "Artesano", "Maestro", "Gran maestro" }
-- Probabilidad aproximada de subir punto: naranja, amarillo, verde (gris = 0); configurable
local COLOR_HEX = { "ff8030", "ffe020", "40d040", "909090" }
local COLOR_NAME = { "Naranja", "Amarilla", "Verde", "Gris" }

local CHAR
local Data                       -- CMProfData preparado
local byName, bySkill = {}, {}   -- indices para reconocer la profesion del cliente
local profs = {}                 -- profesiones del personaje: { key, name, rank, max, p }
local selKey, tab = nil, "plan"
local state = {}                 -- ultimo calculo (para los comandos)
local dirty, scanDirty = true, false
local OpenWindow, Refresh        -- se definen mas abajo

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Profesiones:|r " .. msg)
end

local function ChanceOf(ci)
    if ci == 1 then return (S.chanceOrange or 100) / 100
    elseif ci == 2 then return (S.chanceYellow or 75) / 100
    elseif ci == 3 then return (S.chanceGreen or 25) / 100 end
    return nil
end
local function On() return S and mod and mod.enabled end

local function num(v) return type(v) == "number" and v == v and v or nil end

----------------------------------------------------------------------
-- Datos
----------------------------------------------------------------------
local function PrepData()
    Data = CMProfData or {}
    for key, p in pairs(Data) do
        p.key = key
        p.list = {}
        for _, r in ipairs(p.rows or {}) do
            local reag = {}
            local rr = r[7]
            for i = 1, #rr, 2 do reag[#reag + 1] = { id = rr[i], c = rr[i + 1] } end
            p.list[#p.list + 1] = {
                spell = r[1], req = r[2], yellow = r[3], gray = r[4],
                green = math.floor((r[3] + r[4]) / 2),
                item = r[5], count = r[6], reag = reag,
            }
        end
        p.rows = nil
        bySkill[p.skill] = p
        byName[strlower(p.es)] = p
        byName[strlower(p.en)] = p
    end
end

-- 1 naranja, 2 amarillo, 3 verde, 4 gris (0 = aun no la puedes hacer)
local function ColorIdx(row, skill)
    if skill < row.req then return 0 end
    if skill >= row.gray then return 4 end
    if skill >= row.green then return 3 end
    if skill >= row.yellow then return 2 end
    return 1
end

----------------------------------------------------------------------
-- Objetos (nombres localizados del cliente, existencias, precio de venta)
----------------------------------------------------------------------
local haveCache = {}
local function Have(id)
    local v = haveCache[id]
    if v == nil then
        local ok, n = pcall(C_Item.GetItemCount, id, true)
        v = (ok and num(n)) or 0
        haveCache[id] = v
    end
    return v
end

-- Otros personajes: solo con CervecerosMendigosBanco cargado (se detecta en ejecucion) y la opcion activa.
local otherCache = {}
local function BancoOn()
    local b = Hub:GetModule("banco")
    return S and S.useAlts and b and b.enabled and type(CMBancoCount) == "function"
end
local function Others(id)
    if not BancoOn() then return 0 end
    local v = otherCache[id]
    if v == nil then
        local ok, n = pcall(CMBancoCount, id, true)   -- total de los demas personajes (sin el actual)
        v = (ok and num(n)) or 0
        otherCache[id] = v
    end
    return v
end
local function HaveAll(id) return Have(id) + Others(id) end
-- Texto "Pj1 (banco 3), Pj2 (correo 2)" de los demas personajes, si el Banco lo ofrece
local function OthersText(id)
    if not BancoOn() or type(CMBancoDetalle) ~= "function" then return nil end
    local ok, t = pcall(CMBancoDetalle, id, true)
    if ok and type(t) == "string" and t ~= "" then return t end
end

local unitCache = {}
local function Unit(id)
    local v = unitCache[id]
    if v then return v end
    local ok, a, b, c, d, e, f, g, h, i, j, price = pcall(C_Item.GetItemInfo, id)
    if ok and type(a) == "string" then
        v = (num(price) and price > 0) and price or (S.defaultCost or 100)
        unitCache[id] = v
        return v
    end
    pcall(C_Item.RequestLoadItemDataByID, id)
    return S.defaultCost or 100
end

local function ItemName(id)
    local ok, name = pcall(C_Item.GetItemNameByID, id)
    if ok and type(name) == "string" then return name end
    local ok2, n2 = pcall(C_Item.GetItemInfo, id)
    if ok2 and type(n2) == "string" then return n2 end
    pcall(C_Item.RequestLoadItemDataByID, id)
    return "objeto " .. id
end

local function RecipeName(row)
    local ok, name = pcall(C_Spell.GetSpellName, row.spell)
    if ok and type(name) == "string" and name ~= "" then return name end
    if row.item and row.item > 0 then return ItemName(row.item) end
    return "receta " .. row.spell
end

local function Money(c)
    c = math.floor(c + 0.5)
    local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "o" end
    if s > 0 or g > 0 then t[#t + 1] = s .. "p" end
    t[#t + 1] = cc .. "c"
    return table.concat(t, " ")
end

----------------------------------------------------------------------
-- Lectura de las profesiones del personaje (C_SkillInfo, con adaptador)
----------------------------------------------------------------------
local function SkillAPI()
    local c = C_SkillInfo
    local function pick(name)
        if type(_G[name]) == "function" then return _G[name] end
        if type(c) == "table" and type(c[name]) == "function" then return c[name] end
    end
    return { num = pick("GetNumSkillLines"), info = pick("GetSkillLineInfo"),
             expand = pick("ExpandSkillHeader"), collapse = pick("CollapseSkillHeader") }
end

-- (nombre, skillID, esCabecera, expandida, rango, maximo)
local function SkillRow(api, i)
    local r = { pcall(api.info, i) }
    if not r[1] then return nil end
    local t = r[2]
    if type(t) == "table" then
        return t.name or t.skillName, num(t.skillID), t.isHeader and true or false, t.isExpanded,
               num(t.rank or t.skillRank), num(t.maxRank or t.skillMaxRank or t.maxSkillRank)
    end
    return r[2], nil, r[3] and true or false, r[4], num(r[5]), num(r[8])
end

local function ScanSkills(api)
    local out = {}
    local total = 0
    local okn, n = pcall(api.num)
    if okn then total = num(n) or 0 end
    local headers, collapsed = 0, {}
    for i = 1, total do
        local name, sid, header, expanded, rank, max = SkillRow(api, i)
        if header then
            headers = headers + 1
            if expanded == nil or expanded == false then collapsed[#collapsed + 1] = name end
        elseif name or sid then
            local p = (sid and bySkill[sid]) or (type(name) == "string" and byName[strlower(name)]) or nil
            if p and rank then
                out[#out + 1] = { key = p.key, name = (type(name) == "string" and name) or p.es,
                                  rank = rank, max = max, p = p }
            end
        end
    end
    return out, #collapsed > 0
end

local function ReadProfessions()
    local api = SkillAPI()
    if not api.num or not api.info then return {} end
    local out, hasCollapsed = ScanSkills(api)
    -- Los encabezados plegados esconden filas: se despliegan para leer y se vuelven a plegar.
    if #out == 0 and hasCollapsed and api.expand and api.collapse then
        local wasCollapsed = {}
        local okn, n = pcall(api.num)
        for i = 1, (okn and num(n)) or 0 do
            local name, _, header, expanded = SkillRow(api, i)
            if header and type(name) == "string" and (expanded == nil or expanded == false) then
                wasCollapsed[name] = true
            end
        end
        pcall(api.expand, 0)
        out = ScanSkills(api)
        local okn2, n2 = pcall(api.num)
        for i = (okn2 and num(n2)) or 0, 1, -1 do
            local name, _, header = SkillRow(api, i)
            if header and wasCollapsed[name] then pcall(api.collapse, i) end
        end
    end
    -- sin duplicados, orden alfabetico
    local seen, res = {}, {}
    for _, e in ipairs(out) do
        if not seen[e.key] then seen[e.key] = true; res[#res + 1] = e end
    end
    table.sort(res, function(a, b) return a.name < b.name end)
    return res
end

----------------------------------------------------------------------
-- Recetas aprendidas
----------------------------------------------------------------------
local function KnownTable()
    DATA.known[CHAR] = DATA.known[CHAR] or {}
    return DATA.known[CHAR]
end

local function SpellKnown(spell)
    if KnownTable()[spell] then return true end
    local ok, v = pcall(function()
        if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spell) end
        if IsPlayerSpell then return IsPlayerSpell(spell) end
        if IsSpellKnown then return IsSpellKnown(spell) end
    end)
    return ok and v and true or false
end

-- Con la ventana de profesion abierta se leen las recetas aprendidas y se guardan.
local function ScanTradeSkill()
    local T = C_TradeSkillUI
    if type(T) ~= "table" then return 0 end
    local ids
    for _, fname in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
        if type(T[fname]) == "function" then
            local ok, r = pcall(T[fname])
            if ok and type(r) == "table" and #r > 0 then ids = r; break end
        end
    end
    if not ids or type(T.GetRecipeInfo) ~= "function" then return 0 end
    local kt, added = KnownTable(), 0
    for _, id in ipairs(ids) do
        local ok, info = pcall(T.GetRecipeInfo, id)
        if ok and type(info) == "table" and info.learned and not kt[id] then
            kt[id] = true; added = added + 1
        end
    end
    return added
end

-- Recetas candidatas de una profesion. Devuelve (lista, nota)
local function Candidates(p)
    if not S.onlyKnown then return p.list, nil end
    local out = {}
    for _, row in ipairs(p.list) do
        if SpellKnown(row.spell) then out[#out + 1] = row end
    end
    if #out == 0 then
        return p.list, "No he podido comprobar tus recetas aprendidas: se muestran todas (abre una vez la ventana de la profesion)."
    end
    return out, nil
end

----------------------------------------------------------------------
-- Plan de subida
----------------------------------------------------------------------
local function TargetFor(rank, max)
    local mode = S.target
    local t
    if mode == "max" then t = max or 300
    elseif mode == "300" then t = 300
    else t = (math.floor(rank / 75) + 1) * 75 end
    if max and t > max then t = max end
    return t
end

local TARGET_LABEL = { tramo = "Siguiente tramo", max = "Maximo de tu rango", ["300"] = "Hasta 300" }
local TARGET_NEXT = { tramo = "max", max = "300", ["300"] = "tramo" }

-- Simula punto a punto: en cada nivel elige la receta mas barata por punto esperado
-- (coste de lo que te falta + una fraccion de lo que ya tienes, dividido entre la
-- probabilidad de subir). Devuelve segmentos, necesidades totales y coste.
local function BuildPlan(rows, rank, target)
    local segs, need, stock = {}, {}, {}
    local cost = 0
    local prev -- receta del punto anterior: se mantiene salvo que otra sea claramente mas barata
    local function PointCost(row, r)
        local ch = ChanceOf(ColorIdx(row, r))
        if not ch then return nil end
        local c = 0
        for _, rg in ipairs(row.reag) do
            local have = stock[rg.id]
            if have == nil then have = HaveAll(rg.id); stock[rg.id] = have end
            local miss = math.max(0, rg.c - have)
            local u = Unit(rg.id)
            c = c + miss * u + (rg.c - miss) * u * ((S.stockWeight or 10) / 100)
        end
        return c / ch, ch
    end
    for r = rank, target - 1 do
        local best, bestCost, bestCh
        for _, row in ipairs(rows) do
            if r >= row.req and r < row.gray and #row.reag > 0 then
                local c, ch = PointCost(row, r)
                if c and (not bestCost or c < bestCost - 1e-9 or (math.abs(c - bestCost) <= 1e-9 and ch > bestCh)) then
                    best, bestCost, bestCh = row, c, ch
                end
            end
        end
        if best and prev and prev ~= best and r >= prev.req and r < prev.gray then
            local c, ch = PointCost(prev, r)
            if c and c <= bestCost * 1.5 + 1e-9 then best, bestCost, bestCh = prev, c, ch end
        end
        prev = best
        local last = segs[#segs]
        if not best then
            if last and last.gap then last.to = r + 1
            else segs[#segs + 1] = { gap = true, from = r, to = r + 1 } end
        else
            local crafts = 1 / bestCh
            for _, rg in ipairs(best.reag) do
                need[rg.id] = (need[rg.id] or 0) + rg.c * crafts
                cost = cost + rg.c * crafts * Unit(rg.id)
            end
            if last and last.row == best then
                last.to = r + 1; last.crafts = last.crafts + crafts
            else
                segs[#segs + 1] = { row = best, from = r, to = r + 1, crafts = crafts }
            end
        end
    end
    local mats = {}
    for id, n in pairs(need) do
        local total = math.ceil(n - 1e-9)
        local have, oth = Have(id), Others(id)
        mats[#mats + 1] = { id = id, need = total, have = have, oth = oth,
            miss = math.max(0, total - have - oth), name = ItemName(id) }
    end
    table.sort(mats, function(a, b)
        if (a.miss > 0) ~= (b.miss > 0) then return a.miss > 0 end
        return a.name < b.name
    end)
    for _, s in ipairs(segs) do if s.crafts then s.n = math.ceil(s.crafts - 1e-9) end end
    return segs, mats, cost
end

----------------------------------------------------------------------
-- Calculo y lineas de la lista
----------------------------------------------------------------------
local function ReagText(row, times)
    local t = {}
    for _, rg in ipairs(row.reag) do
        t[#t + 1] = (rg.c * times) .. "x " .. ItemName(rg.id)
    end
    return table.concat(t, ", ")
end

local function ShopLines(mats)
    local t = {}
    for _, m in ipairs(mats) do
        if m.miss > 0 then t[#t + 1] = m.miss .. "x " .. ItemName(m.id) end
    end
    return t
end

local function RecipeChat(row, times, rank)
    local c = ColorIdx(row, rank)
    Print(string.format("%s (%s) x%d: %s", RecipeName(row), COLOR_NAME[c] and strlower(COLOR_NAME[c]) or "?", times, ReagText(row, times)))
    for _, rg in ipairs(row.reag) do
        local need, have = rg.c * times, HaveAll(rg.id)
        if have < need then
            Print(string.format("   falta |cffff4040%d|r x %s (tienes %d)", need - have, ItemName(rg.id), have))
        end
    end
end

local function Compute()
    local cur
    for _, e in ipairs(profs) do if e.key == selKey then cur = e end end
    if not cur then cur = profs[1]; selKey = cur and cur.key end
    state = { cur = cur }
    if not cur then return end
    local rows, note = Candidates(cur.p)
    local target = TargetFor(cur.rank, cur.max)
    state.rows, state.note, state.target = rows, note, target
    if target > cur.rank then
        state.segs, state.mats, state.cost = BuildPlan(rows, cur.rank, target)
    else
        state.segs, state.mats, state.cost = {}, {}, 0
    end
    -- Recetas utiles ahora
    local useful = {}
    for _, row in ipairs(rows) do
        local ci = ColorIdx(row, cur.rank)
        if ci >= 1 and ci <= 3 and #row.reag > 0 then useful[#useful + 1] = { row = row, ci = ci } end
    end
    table.sort(useful, function(a, b)
        if a.ci ~= b.ci then return a.ci < b.ci end
        return a.row.yellow < b.row.yellow
    end)
    state.useful = useful
end

local function BuildLines()
    local lines = {}
    local cur = state.cur
    if not cur then return lines end
    local function Add(text, extra) extra = extra or {}; extra.text = text; lines[#lines + 1] = extra end

    if state.note then Add("|cffffc040" .. state.note .. "|r") end

    if tab == "plan" then
        if state.target <= cur.rank then
            if cur.max and cur.rank >= cur.max then
                Add("|cffffd100Estas en el maximo de tu rango actual (" .. cur.max .. "). Entrena el siguiente rango en un maestro de la profesion.|r")
            else
                Add("|cffffd100Ya estas por encima del objetivo elegido. Cambia el objetivo arriba.|r")
            end
        else
            local ncr = 0
            for _, s in ipairs(state.segs) do ncr = ncr + (s.n or 0) end
            Add(string.format("|cffffd100De %d a %d: unas %d fabricaciones. Coste aprox. (precio de venta de los materiales): %s|r",
                cur.rank, state.target, ncr, Money(state.cost)))
            for _, s in ipairs(state.segs) do
                if s.gap then
                    Add(string.format("|cffff4040Del %d al %d no tengo ninguna receta tuya util. Aprende mas recetas.|r", s.from, s.to))
                else
                    local ci = ColorIdx(s.row, s.from)
                    Add(string.format("|cff%s%s|r  x%d   |cffa0a0a0(%d > %d)|r", COLOR_HEX[ci] or "ffffff", RecipeName(s.row), s.n, s.from, s.to),
                        { tip = s.row.item, chat = function() RecipeChat(s.row, s.n, s.from) end,
                          chatText = function() return RecipeName(s.row) .. " x" .. s.n .. ": " .. ReagText(s.row, s.n) end })
                end
            end
        end
    elseif tab == "mats" then
        if #state.mats == 0 then
            Add("|cffa0a0a0No hay materiales: no hay plan que hacer con este objetivo.|r")
        else
            for _, m in ipairs(state.mats) do
                local col = m.miss > 0 and "ff5050" or ((m.have < m.need) and "ffd040" or "50e050")
                local extra = m.miss > 0 and string.format("   |cffff5050faltan %d|r", m.miss) or ""
                local text, altText
                if m.oth and m.oth > 0 then
                    altText = OthersText(m.id)
                    local who = altText and (": " .. (#altText > 48 and (string.sub(altText, 1, 45) .. "...") or altText)) or ""
                    text = string.format("|cff%s%s|r:  llevas %d  |cffa0a0a0.|r  en otros %d%s  /  necesitas %d%s",
                        col, m.name, m.have, m.oth, who, m.need, extra)
                    if m.miss == 0 and m.have < m.need then
                        text = text .. "   |cffffd040(ve a buscarlo)|r"
                    end
                else
                    text = string.format("|cff%s%s|r:  tienes %d / necesitas %d%s", col, m.name, m.have, m.need, extra)
                end
                Add(text, { tip = m.id, alt = altText, oth = m.oth })
            end
        end
    else -- recetas
        if #state.useful == 0 then
            Add("|cffa0a0a0No hay recetas que den punto ahora mismo con tu habilidad.|r")
        else
            Add("|cffa0a0a0Orden: naranja > amarilla > verde. Clic en una fila: sus materiales al chat.|r")
            for _, u in ipairs(state.useful) do
                local row = u.row
                Add(string.format("|cff%s%s|r   |cffa0a0a0%s  (%d/%d/%d/%d)|r", COLOR_HEX[u.ci], RecipeName(row), ReagText(row, 1),
                    row.req, row.yellow, row.green, row.gray),
                    { tip = row.item, chat = function() RecipeChat(row, 1, cur.rank) end,
                      chatText = function() return RecipeName(row) .. ": " .. ReagText(row, 1) end })
            end
        end
    end
    return lines
end

----------------------------------------------------------------------
-- Chat
----------------------------------------------------------------------
local function OpenChatWith(text)
    if #text > 250 then text = string.sub(text, 1, 247) .. "..." end
    if ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(text)
    elseif ChatFrame_OpenChat then ChatFrame_OpenChat(text)
    else Print(text) end
end

-- Manda los faltantes a CervecerosMendigosCarrito (por su comando /carrito importar, sin tocar su codigo)
local function ShopToCart()
    if not state.cur then return end
    local parts = {}
    for _, m in ipairs(state.mats or {}) do
        if m.miss > 0 then parts[#parts + 1] = m.id .. ":" .. m.miss .. ":" .. (S.cartPriority or 2) end
    end
    if #parts == 0 then
        Print("No te falta nada para el plan de " .. state.cur.name .. ".")
        return
    end
    local text = table.concat(parts, ";")
    local h = SlashCmdList and SlashCmdList["CMHUB_" .. string.upper(ADDON) .. "_CARRITO"]
    if type(h) == "function" and pcall(h, "importar " .. text) then
        Print(#parts .. " materiales enviados al Carrito.")
    else
        Print("El modulo Carrito no esta activado. Lista para importar con /carrito importar:")
        Print(text)
    end
end

local function ShopToChat(toEditBox)
    if not state.cur then return end
    local list = ShopLines(state.mats or {})
    if #list == 0 then
        Print("No te falta nada para el plan de " .. state.cur.name .. ".")
        return
    end
    if toEditBox then
        OpenChatWith("Me faltan para " .. state.cur.name .. ": " .. table.concat(list, ", "))
    else
        Print("Lista de la compra de " .. state.cur.name .. " (" .. state.cur.rank .. " > " .. state.target .. "):")
        for _, l in ipairs(list) do Print("  " .. l) end
    end
end


----------------------------------------------------------------------
-- Ventana
----------------------------------------------------------------------
local win, profBtns, tabBtns, rows = nil, {}, {}, {}
local scroll, header, targetBtn, knownBtn, altsBtn
local lines, offset = {}, 0
local ROWS, RH = 16, 20
local LIST_X, LIST_Y, LIST_W = 168, -118, 392

local MakeWindow = UI.MakeWindow

local function MakeButton(parent, label, w, point, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetPoint(point, x, y)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function UpdateRows()
    for i = 1, ROWS do
        local row, ln = rows[i], lines[offset + i]
        if ln then
            row.line = ln
            row.fs:SetText(ln.text)
            row.chatBtn:SetShown(ln.chat ~= nil)
            row:Show()
        else
            row.line = nil
            row:Hide()
        end
    end
end

local function SetupScroll()
    local maxOff = math.max(0, #lines - ROWS)
    scroll.loading = true
    scroll:SetMinMaxValues(0, maxOff)
    if offset > maxOff then offset = maxOff end
    scroll:SetValue(offset)
    scroll.loading = false
    scroll:SetShown(maxOff > 0)
    UpdateRows()
end

local TAB_LABEL = { plan = "Plan", mats = "Materiales", recetas = "Recetas utiles" }

local function UpdateWindow()
    if not win then return end
    -- botones de profesion
    for i, b in ipairs(profBtns) do
        local e = profs[i]
        if e then
            local max = e.max and ("/" .. e.max) or ""
            b:SetText(string.format("%s  %d%s", e.name, e.rank, max))
            if e.key == selKey then b:LockHighlight() else b:UnlockHighlight() end
            b:Show()
        else
            b:Hide()
        end
    end
    for k, b in pairs(tabBtns) do
        if k == tab then b:LockHighlight() else b:UnlockHighlight() end
    end
    targetBtn:SetText("Objetivo: " .. (TARGET_LABEL[S.target] or S.target))
    knownBtn:SetText("Aprendidas: " .. (S.onlyKnown and "si" or "no"))
    if BancoOn() or (type(CMBancoCount) == "function" and Hub:GetModule("banco") and Hub:GetModule("banco").enabled) then
        altsBtn:Enable()
        altsBtn:SetText(S.useAlts and "Cuenta: todos" or "Cuenta: este pj")
    else
        altsBtn:SetText("Sin Banco")
        altsBtn:Disable()
    end

    local cur = state.cur
    if not cur then
        header:SetText("|cffff8040No encuentro ninguna profesion (de las que se fabrican) en tu personaje.|r")
        lines = {}
    else
        local tier = TIERS[math.min(#TIERS, math.floor(cur.rank / 75) + 1)]
        local max = cur.max and ("/" .. cur.max) or ""
        header:SetText(string.format("|cffffd100%s|r - %s (%d%s)   objetivo: %d", cur.name, tier, cur.rank, max, state.target or cur.rank))
        lines = BuildLines()
    end
    SetupScroll()
end

Refresh = function()
    profs = ReadProfessions()
    Compute()
    UpdateWindow()
    dirty = false
end

local function BuildRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(LIST_W, RH)
    row:SetPoint("TOPLEFT", LIST_X, LIST_Y - (i - 1) * RH)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.fs:SetPoint("LEFT", 2, 0)
    row.fs:SetWidth(LIST_W - 64)
    row.fs:SetJustifyH("LEFT")
    row.chatBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.chatBtn:SetSize(52, 18)
    row.chatBtn:SetPoint("RIGHT", -2, 0)
    row.chatBtn:SetText("Chat")
    row.chatBtn:SetScript("OnClick", function()
        local ln = row.line
        if not ln or not ln.chat then return end
        if IsShiftKeyDown and IsShiftKeyDown() and ln.chatText then OpenChatWith(ln.chatText()) else ln.chat() end
    end)
    row:SetScript("OnEnter", function(self)
        local ln = self.line
        if ln and ln.tip and ln.tip > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local ok = pcall(GameTooltip.SetItemByID, GameTooltip, ln.tip)
            if not ok then pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. ln.tip) end
            if ln.oth and ln.oth > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("En otros personajes: " .. ln.oth, 1, 0.82, 0.25)
                if ln.alt then GameTooltip:AddLine(ln.alt, 0.8, 0.8, 0.8, true) end
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    return row
end

local function BuildWindow()
    win = MakeWindow("CervecerosMendigosProfesionesWindow", "Profesiones - asistente de subida", 600, 520)
    win:SetScale((S.windowScale or 100) / 100)

    -- columna izquierda: profesiones
    local lt = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lt:SetPoint("TOPLEFT", 16, -36); lt:SetText("Tus profesiones")
    for i = 1, 12 do
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(140, 24)
        b:SetPoint("TOPLEFT", 16, -58 - (i - 1) * 26)
        b.index = i
        b:SetScript("OnClick", function(self)
            local e = profs[self.index]
            if e then selKey = e.key; offset = 0; Compute(); UpdateWindow() end
        end)
        b:Hide()
        profBtns[i] = b
    end

    -- derecha: cabecera, pestanas, opciones
    header = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", LIST_X, -36)
    header:SetWidth(LIST_W + 20); header:SetJustifyH("LEFT")

    local x = LIST_X
    for _, k in ipairs({ "plan", "mats", "recetas" }) do
        tabBtns[k] = MakeButton(win, TAB_LABEL[k], 120, "TOPLEFT", x, -58, function()
            tab = k; offset = 0; UpdateWindow()
        end)
        x = x + 124
    end
    targetBtn = MakeButton(win, "Objetivo", 150, "TOPLEFT", LIST_X, -86, function()
        S.target = TARGET_NEXT[S.target] or "tramo"; offset = 0; Compute(); UpdateWindow()
    end)
    knownBtn = MakeButton(win, "Aprendidas", 110, "TOPLEFT", LIST_X + 154, -86, function()
        S.onlyKnown = not S.onlyKnown; offset = 0; Compute(); UpdateWindow()
    end)
    altsBtn = MakeButton(win, "Cuenta", 124, "TOPLEFT", LIST_X + 268, -86, function()
        S.useAlts = not S.useAlts; wipe(otherCache); offset = 0; Compute(); UpdateWindow()
    end)
    altsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Contar lo de tus otros personajes", 1, 1, 1)
        GameTooltip:AddLine("Necesita el modulo Banco activado. 'todos' = bolsas, banco, correo y equipado de tus personajes; 'este pj' = solo el actual.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    altsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    for i = 1, ROWS do rows[i] = BuildRow(win, i) end

    scroll = CreateFrame("Slider", nil, win)
    scroll:SetOrientation("VERTICAL")
    scroll:SetSize(16, ROWS * RH)
    scroll:SetPoint("TOPLEFT", LIST_X + LIST_W + 6, LIST_Y)
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

    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMLEFT", LIST_X, 54)
    hint:SetWidth(LIST_W + 20); hint:SetJustifyH("LEFT")
    hint:SetText("|cffff8030naranja|r siempre sube, |cffffe020amarilla|r casi siempre, |cff40d040verde|r a veces. Mayus+clic en \"Chat\" escribe la fila en la caja de chat.")

    MakeButton(win, "Compra al chat", 96, "BOTTOMLEFT", LIST_X, 20, function() ShopToChat(false) end)
    MakeButton(win, "Compra a la caja", 104, "BOTTOMLEFT", LIST_X + 100, 20, function() ShopToChat(true) end)
    MakeButton(win, "Actualizar", 78, "BOTTOMLEFT", LIST_X + 208, 20, function() Refresh() end)
    MakeButton(win, "Al Carrito", 100, "BOTTOMLEFT", LIST_X + 290, 20, function() ShopToCart() end)

    local note = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 16, 24)
    note:SetText("Ajustes: pestana Profesiones")

    win:SetScript("OnShow", function() win:SetScale((S.windowScale or 100) / 100); Refresh() end)
end

OpenWindow = function()
    if not On() then return end
    if not win then BuildWindow() end
    if win:IsShown() then win:Hide() else win:Show() end
end

----------------------------------------------------------------------
-- Eventos
----------------------------------------------------------------------
local function OnEvent(event)
    if not On() then return end
    if event == "BAG_UPDATE_DELAYED" then
        wipe(haveCache); wipe(otherCache); dirty = true
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        dirty = true
    elseif event == "SKILL_LINES_CHANGED" or event == "NEW_RECIPE_LEARNED" then
        dirty = true
        if event == "NEW_RECIPE_LEARNED" and S.scanKnown then scanDirty = true end
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_SHOW" then
        if S.scanKnown then scanDirty = true end
        if event == "TRADE_SKILL_SHOW" and S.openOnTradeSkill then
            if not win then BuildWindow() end
            if not win:IsShown() then win:Show() end
        end
    end
end

local acc = 0
local function OnUpdate(_, elapsed)
    acc = acc + elapsed
    if acc < 0.5 then return end
    acc = 0
    if scanDirty and CHAR then
        scanDirty = false
        if ScanTradeSkill() > 0 then dirty = true end
    end
    if dirty and win and win:IsShown() then Refresh() end
end

----------------------------------------------------------------------
-- Comandos
----------------------------------------------------------------------
local function OnSlash(_, msg)
    local cmd = string.match(strlower(msg or ""), "^(%S*)") or ""
    if cmd == "" or cmd == "config" then
        OpenWindow()
    elseif cmd == "minimap" then
        Print("el boton del minimapa se controla en la pestana Profesiones (Boton en el minimapa).")
    elseif cmd == "lista" then
        profs = ReadProfessions(); Compute(); ShopToChat(false)
    elseif cmd == "solo" then
        S.onlyKnown = not S.onlyKnown
        Print("solo recetas aprendidas: " .. (S.onlyKnown and "si" or "no"))
        Refresh()
    elseif cmd == "alts" then
        S.useAlts = not S.useAlts; wipe(otherCache)
        if not BancoOn() and S.useAlts then
            Print("El modulo Banco no esta activado: no hay datos de otros personajes.")
        end
        Print("contar otros personajes: " .. (S.useAlts and "si" or "no (solo este)"))
        Refresh()
    elseif cmd == "carrito" then
        profs = ReadProfessions(); Compute(); ShopToCart()
    elseif cmd == "debug" then
        local api = SkillAPI()
        Print("C_SkillInfo=" .. type(C_SkillInfo) .. " num=" .. type(api.num) .. " info=" .. type(api.info))
        profs = ReadProfessions()
        Print("profesiones reconocidas: " .. #profs)
        for _, e in ipairs(profs) do
            local known = 0
            for _, row in ipairs(e.p.list) do if SpellKnown(row.spell) then known = known + 1 end end
            Print(string.format("  %s %d/%s: %d recetas en la base, %d detectadas como aprendidas",
                e.name, e.rank, tostring(e.max), #e.p.list, known))
        end
        local n = 0
        for _ in pairs(KnownTable()) do n = n + 1 end
        Print("recetas guardadas al abrir la ventana de profesion: " .. n)
    else
        Print("/cmprof = ventana | lista (faltan al chat) | solo (aprendidas si/no) | alts (contar otros personajes si/no) | carrito (faltantes al Carrito) | debug")
    end
end

----------------------------------------------------------------------
-- Registro en el Hub
----------------------------------------------------------------------
local TARGET_OPTS = { { "tramo", "Siguiente tramo" }, { "max", "Maximo de tu rango" }, { "300", "Hasta 300" } }

local function BuildConfig(m, L)
    L:Header("Plan de subida")
    L:Text("Calcula que fabricar para subir cada profesion, cuantas veces y que materiales te faltan.", true)
    L:Choice("Objetivo del plan", TARGET_OPTS, function() return S.target end,
        function(v) S.target = v; if win and win:IsShown() then Refresh() end end)
    L:Check("Solo recetas que ya sabes (si el juego deja comprobarlo)", function() return S.onlyKnown end,
        function(v) S.onlyKnown = v; if win and win:IsShown() then Refresh() end end)
    L:Check("Contar lo de mis otros personajes (necesita el modulo Banco activado)", function() return S.useAlts end,
        function(v) S.useAlts = v; wipe(otherCache); if win and win:IsShown() then Refresh() end end)
    L:Check("Leer y recordar mis recetas al abrir la ventana de una profesion", function() return S.scanKnown end,
        function(v) S.scanKnown = v end)
    L:Check("Abrir este asistente al abrir la ventana de una profesion", function() return S.openOnTradeSkill end,
        function(v) S.openOnTradeSkill = v end)
    L:Header("Calculo")
    L:Slider("Probabilidad de subir con receta naranja", 10, 100, 5, function() return S.chanceOrange end,
        function(v) S.chanceOrange = v; dirty = true end, "%d%%")
    L:Slider("Probabilidad de subir con receta amarilla", 10, 100, 5, function() return S.chanceYellow end,
        function(v) S.chanceYellow = v; dirty = true end, "%d%%")
    L:Slider("Probabilidad de subir con receta verde", 5, 100, 5, function() return S.chanceGreen end,
        function(v) S.chanceGreen = v; dirty = true end, "%d%%")
    L:Slider("Coste de los materiales que ya tienes", 0, 100, 5, function() return S.stockWeight end,
        function(v) S.stockWeight = v; dirty = true end, "%d%%")
    L:Slider("Valor por unidad si no se conoce el precio (cobre)", 1, 1000, 1, function() return S.defaultCost end,
        function(v) S.defaultCost = v; dirty = true end)
    L:Header("Lista de la compra y ventana")
    L:Slider("Prioridad al enviar faltantes al Carrito (1 alta - 3 baja)", 1, 3, 1, function() return S.cartPriority end,
        function(v) S.cartPriority = v end)
    L:Slider("Tamano de la ventana del asistente", 60, 130, 5, function() return S.windowScale end,
        function(v) S.windowScale = v; if win then win:SetScale(v / 100) end end, "%d%%")
    L:Button("Abrir el asistente", 200, function() OpenWindow() end)
    L:Button("Faltantes al chat", 200, function() profs = ReadProfessions(); Compute(); ShopToChat(false) end)
    L:Button("Faltantes al Carrito", 200, function() profs = ReadProfessions(); Compute(); ShopToCart() end)
end

local EVENTS = { "SKILL_LINES_CHANGED", "BAG_UPDATE_DELAYED", "ITEM_DATA_LOAD_RESULT",
                 "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_SHOW", "NEW_RECIPE_LEARNED" }

mod = Hub:Register{
    key = "profesiones", dir = "Profesiones", name = "Profesiones",
    desc = "Plan para subir cada profesion: que fabricar, cuantas veces y que materiales te faltan (cuenta tambien tus otros personajes con el modulo Banco).",
    defaults = DEFAULTS,
    legacyDB = "CervecerosMendigosProfesionesDB",
    slash = { "cmprof", "profesiones" },
    OnSlash = OnSlash,
    BuildConfig = BuildConfig,
    OnReset = function() wipe(haveCache); wipe(otherCache); wipe(unitCache); dirty = true end,
    Init = function(m)
        S = m.db
        ns.DB.data = ns.DB.data or {}
        local D = ns.DB.data.profesiones
        if not D then D = {}; ns.DB.data.profesiones = D end
        if S.known ~= nil and D.known == nil then D.known = S.known end   -- datos del addon suelto antiguo
        S.known = nil; S.minimap = nil
        D.known = D.known or {}
        DATA = D
        PrepData()
        local realm = (GetRealmName and GetRealmName()) or ""
        CHAR = (UnitName("player") or "?") .. "-" .. realm
        for _, name in ipairs(EVENTS) do
            if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(name) then
                m:Event(name, function(_, event) OnEvent(event) end)
            end
        end
        m:OnUpdate(OnUpdate)
    end,
    Enable = function(m)
        S = m.db
        wipe(haveCache); wipe(otherCache); dirty = true
    end,
    Disable = function(m)
        if win then win:Hide() end
    end,
}
