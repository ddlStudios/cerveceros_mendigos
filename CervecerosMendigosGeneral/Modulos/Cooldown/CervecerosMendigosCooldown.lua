-- Modulo Cooldown (CervecerosMendigosGeneral) para WoW Forever (Interface 16001).
-- Colorea el numero de enfriamiento que el propio juego pinta en cada boton de accion,
-- segun el % de tiempo restante: verde < low, naranja entre low y high, rojo > high.
-- Usa objetos de duracion + curva de color, asi tambien funciona en combate, cuando
-- los tiempos son "valores secretos" y no se pueden leer ni comparar desde Lua.
-- Todo se configura en su pestana del panel (o con /cdc, /cmcd).

local ADDON, ns = ...
local Hub = ns.Hub

local BARS = {
    { key = "main",   name = "Barra principal",         prefix = "ActionButton" },
    { key = "bl",     name = "Barra inferior izquierda", prefix = "MultiBarBottomLeftButton" },
    { key = "br",     name = "Barra inferior derecha",   prefix = "MultiBarBottomRightButton" },
    { key = "right",  name = "Barra derecha 1",          prefix = "MultiBarRightButton" },
    { key = "left",   name = "Barra derecha 2",          prefix = "MultiBarLeftButton" },
    { key = "bar5",   name = "Barra extra 5",            prefix = "MultiBar5Button" },
    { key = "bar6",   name = "Barra extra 6",            prefix = "MultiBar6Button" },
    { key = "bar7",   name = "Barra extra 7",            prefix = "MultiBar7Button" },
}

local DEFAULTS = {
    low = 20,   -- % restante por debajo del cual es VERDE
    high = 80,  -- % restante por encima del cual es ROJO
    green  = { 0.1, 1.0, 0.1 },
    orange = { 1.0, 0.6, 0.0 },
    red    = { 1.0, 0.1, 0.1 },
    interval = 0.1,      -- segundos entre repintados
    forceCountdown = true, -- activar la opcion del juego "numeros de enfriamiento"
    bars = { main = true, bl = true, br = true, right = true, left = true, bar5 = true, bar6 = true, bar7 = true },
}

local curve
local buttons = {}
local painted = setmetatable({}, { __mode = "k" })   -- fontstring -> color original
local acc = 0

local mod

local function DB() return mod.db end

-- Curva "escalon": x = fraccion restante (0..1) -> color.
local function BuildCurve()
    local db = DB()
    local c = C_CurveUtil.CreateColorCurve()
    c:SetType(Enum.LuaCurveType.Step)
    c:AddPoint(0, CreateColor(db.green[1], db.green[2], db.green[3], 1))
    c:AddPoint(db.low / 100, CreateColor(db.orange[1], db.orange[2], db.orange[3], 1))
    c:AddPoint(db.high / 100 + 0.0001, CreateColor(db.red[1], db.red[2], db.red[3], 1))
    curve = c
end

local function CollectButtons()
    wipe(buttons)
    local db = DB()
    for _, bar in ipairs(BARS) do
        if db.bars[bar.key] then
            for i = 1, 12 do
                local b = _G[bar.prefix .. i]
                if b and b.cooldown then buttons[#buttons + 1] = b end
            end
        end
    end
end

local function ActionOf(button)
    return button.action or (button.GetAttribute and button:GetAttribute("action"))
end

local function PaintButton(button)
    local cd = button.cooldown
    if not cd or not cd:IsShown() then return end
    local action = ActionOf(button)
    if not action then return end
    local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not fs then return end
    local dur = C_ActionBar.GetActionCooldownDuration and C_ActionBar.GetActionCooldownDuration(action)
    if not dur then return end
    local color = dur:EvaluateRemainingPercent(curve)
    if color then
        if painted[fs] == nil then
            -- guarda el color original para poder devolverlo al desactivar
            local ok, r, g, b, a = pcall(fs.GetTextColor, fs)
            painted[fs] = ok and { r, g, b, a } or false
        end
        fs:SetTextColor(color:GetRGBA())
    end
end

local function PaintAll()
    for i = 1, #buttons do PaintButton(buttons[i]) end
end

-- Devuelve el color original a todos los numeros que hayamos tocado.
local function RestoreAll()
    for fs, c in pairs(painted) do
        if c and c[1] then pcall(fs.SetTextColor, fs, c[1], c[2], c[3], c[4] or 1) end
        painted[fs] = nil
    end
end

local function EnsureCVar()
    if DB().forceCountdown and C_CVar and C_CVar.GetCVar("countdownForCooldowns") ~= "1" then
        C_CVar.SetCVar("countdownForCooldowns", "1")
    end
end

local function Rebuild()
    BuildCurve()
    CollectButtons()
end

local function Debug()
    CollectButtons()
    mod:Print("botones encontrados: " .. #buttons)
    local b = buttons[1]
    if b then
        local cd = b.cooldown
        mod:Print("boton1 accion=" .. tostring(ActionOf(b)) .. " cooldown visible=" .. tostring(cd and cd:IsShown()))
        mod:Print("fontstring=" .. tostring(cd and cd.GetCountdownFontString and cd:GetCountdownFontString() ~= nil))
    end
    mod:Print("CVar numeros=" .. tostring(C_CVar.GetCVar("countdownForCooldowns")))
end

mod = Hub:Register{
    key = "cooldown", dir = "Cooldown", name = "Colores de enfriamiento",
    desc = "Colorea el numero de recarga de tus botones de accion: verde cuando casi termina, naranja a mitad y rojo al empezar. Umbrales, colores y barras configurables.",
    defaults = DEFAULTS,
    legacyDB = (_G.CervecerosMendigosCooldownDB and "CervecerosMendigosCooldownDB")
        or (_G.otoriCooldownDB and "otoriCooldownDB") or (_G.CooldownColorDB and "CooldownColorDB"),
    slash = { "cdc", "cmcd" },

    Init = function(m)
        Rebuild()
        m:Event("PLAYER_ENTERING_WORLD", function()
            CollectButtons()
            EnsureCVar()
        end)
        m:OnUpdate(function(_, elapsed)
            acc = acc + elapsed
            if acc < (DB().interval or 0.1) then return end
            acc = 0
            if #buttons == 0 then CollectButtons() end
            PaintAll()
        end)
    end,

    Enable = function(m)
        Rebuild()
        EnsureCVar()
    end,

    Disable = function(m)
        RestoreAll()
        wipe(buttons)
    end,

    OnReset = function(m)
        if m:IsEnabled() then Rebuild() end
    end,

    BuildConfig = function(m, L)
        local db = m.db
        L:Header("Umbrales")
        L:Slider("Verde por debajo de (% restante)", 1, 99, 1,
            function() return db.low end,
            function(v) if v >= db.high then v = db.high - 1 end db.low = v; BuildCurve() end)
        L:Slider("Rojo por encima de (% restante)", 2, 100, 1,
            function() return db.high end,
            function(v) if v <= db.low then v = db.low + 1 end db.high = v; BuildCurve() end)
        L:Text("Entre los dos valores el numero sale en naranja.", true)

        L:Header("Colores")
        L:Color("Verde (poco tiempo restante)",
            function() return db.green[1], db.green[2], db.green[3] end,
            function(r, g, b) db.green = { r, g, b }; BuildCurve() end)
        L:Color("Naranja (tiempo intermedio)",
            function() return db.orange[1], db.orange[2], db.orange[3] end,
            function(r, g, b) db.orange = { r, g, b }; BuildCurve() end)
        L:Color("Rojo (mucho tiempo restante)",
            function() return db.red[1], db.red[2], db.red[3] end,
            function(r, g, b) db.red = { r, g, b }; BuildCurve() end)

        L:Header("Barras que se colorean")
        for _, bar in ipairs(BARS) do
            L:Check(bar.name,
                function() return db.bars[bar.key] end,
                function(v) db.bars[bar.key] = v and true or false; CollectButtons() end)
        end

        L:Header("Avanzado")
        L:Slider("Repintar cada (segundos)", 0.05, 0.5, 0.05,
            function() return db.interval end,
            function(v) db.interval = v end, "%.2f")
        L:Check("Activar los numeros de enfriamiento del juego",
            function() return db.forceCountdown end,
            function(v) db.forceCountdown = v and true or false; if v then EnsureCVar() end end)
        L:Button("Diagnostico (chat)", 160, function() Debug() end)
    end,

    OnSlash = function(m, msg)
        local db = m.db
        local cmd, arg = string.match(strlower(msg or ""), "^(%S*)%s*(.-)$")
        local n = tonumber(arg)
        if cmd == "" or cmd == "config" then
            Hub:Open("cooldown")
        elseif cmd == "low" and n then
            db.low = n; BuildCurve()
            m:Print("verde por debajo de " .. n .. "% restante")
        elseif cmd == "high" and n then
            db.high = n; BuildCurve()
            m:Print("rojo por encima de " .. n .. "% restante")
        elseif cmd == "debug" then
            Debug()
        else
            m:Print("/cdc = configuracion | low <n> | high <n> | debug")
        end
    end,
}
