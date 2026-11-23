-- Configuracion del addon grande CervecerosMendigosGeneral (todo lo demas).
local ADDON, ns = ...
ns.HubConfig = {
    title = "CervecerosMendigosGeneral",
    subtitle = "Leveo, profesiones, economia y comodidad",
    slashes = { "cmgeneral", "cervecerosmendigos" },
    svName = "CervecerosMendigosGeneralHubDB",
    logo = "Interface\\AddOns\\" .. ADDON .. "\\logo.tga",
    minimapIcon = "Interface\\AddOns\\" .. ADDON .. "\\badge.tga",
    angleBase = 190, angleStep = 12,
    intro = "El resto de herramientas: ayuda para levear y explorar, profesiones, subasta, banco y lista de la compra, marcas de mapa para el grupo, avisos de equipo y bolsas, contador de objetos y colores de enfriamiento. Cada pestana de la izquierda es un modulo con su propia configuracion; puedes activarlo o desactivarlo sin tocar los demas, y todos los ajustes se pueden cambiar para adaptarlos a tu forma de jugar.",
}
