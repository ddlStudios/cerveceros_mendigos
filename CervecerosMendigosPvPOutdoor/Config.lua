-- Configuracion del addon grande CervecerosMendigosPvPOutdoor (PvP en mundo abierto).
local ADDON, ns = ...
ns.HubConfig = {
    title = "CervecerosMendigosPvPOutdoor",
    subtitle = "PvP en mundo abierto",
    slashes = { "cmoutdoor", "pvpmundo" },
    svName = "CervecerosMendigosPvPOutdoorHubDB",
    logo = "Interface\\AddOns\\" .. ADDON .. "\\logo.tga",
    minimapIcon = "Interface\\AddOns\\" .. ADDON .. "\\badge.tga",
    angleBase = 110, angleStep = 12,
    intro = "Herramientas para sobrevivir y ganar en el mundo abierto: lista de enemigos cercanos con alertas, avisos de voz por hechizo, aviso al grupo cuando ves enemigos y avisos de tu propio estado. Cada pestana de la izquierda es un modulo con su propia configuracion; puedes activarlo o desactivarlo sin tocar los demas, y todos los ajustes se pueden cambiar para adaptarlos a tu forma de jugar.",
}
