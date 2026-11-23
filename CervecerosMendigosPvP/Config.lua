-- Configuracion del addon grande CervecerosMendigosPvP (campos de batalla y arenas).
local ADDON, ns = ...
ns.HubConfig = {
    title = "CervecerosMendigosPvP",
    subtitle = "Campos de batalla y arenas",
    slashes = { "cmpvp", "pvpbg" },
    svName = "CervecerosMendigosPvPHubDB",
    logo = "Interface\\AddOns\\" .. ADDON .. "\\logo.tga",
    minimapIcon = "Interface\\AddOns\\" .. ADDON .. "\\badge.tga",
    angleBase = 20, angleStep = 12,
    intro = "Todo lo que necesitas dentro de un campo de batalla o una arena: contadores de objetivos, resumen al terminar cada partida, historial con estadisticas y seguimiento de tu honor y rango. Cada pestana de la izquierda es un modulo con su propia configuracion; puedes activarlo o desactivarlo sin tocar los demas, y todos los ajustes se pueden cambiar para adaptarlos a tu forma de jugar.",
}
