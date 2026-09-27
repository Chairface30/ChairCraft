-- Chaircraft Suite/Namespace.lua
-- Loaded first. Hands each merged addon its own private table.
--
-- Four addons that used to be four addons now share one. The thing that makes
-- that dangerous is the vararg header every one of them opens with:
--
--     local addonName, addon = ...
--
-- In a standalone addon that second value is a table of that addon's own. In a
-- merged one it is the *same* table for every file, so ChairSnack's `addon` and
-- ChairPlus' `ns` would be the same object -- and both define GetItemInfo,
-- Core, Config and a module registry. They would silently overwrite each other
-- and the failure would surface somewhere else entirely, hours later.
--
-- So the shared table is never used as a namespace. It only carries one
-- sub-table per addon, and each file's header was rewritten to take its own:
--
--     local suiteName, Chaircraft = ...
--     local addon = Chaircraft.ChairSnack
--
-- Everything downstream of that line is untouched from the standalone addons.

local suiteName, Chaircraft = ...

-- The name the client actually loaded us under. The three places that compare
-- ADDON_LOADED's argument need this rather than their own addon's old name,
-- and they were rewritten to use `suiteName` directly.
Chaircraft.addonName = suiteName

-- The release version, read from the TOC's "## Version:" line so the menu and
-- /chair status always show what was released. Nothing else holds a copy.
local function TocField(field)
    local addons = _G.C_AddOns
    local get = (addons and addons.GetAddOnMetadata) or _G.GetAddOnMetadata
    if type(get) ~= "function" then return nil end
    local ok, value = pcall(get, suiteName, field)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end
Chaircraft.version = TocField("Version") or "?"

-- A unit's name as chat gives it. On WoW Forever every character has a
-- surname, and UnitName returns it as its SECOND value -- the slot other
-- clients use for a realm: UnitName("player") -> "Highley", "Regarded", while
-- chat and addon messages say "Highley Regarded". Reading UnitName's first
-- value alone makes every "is this me?" check fail, so names are read here.
-- nil when the client keeps the name secret.
function Chaircraft.UnitFullName(unit)
    local ok, first, second = pcall(UnitName, unit)
    if not ok then return nil end
    local function Plain(value)
        if value == nil then return nil end
        local okText, text = pcall(function()
            local s = "" .. tostring(value)
            if s == "" then return nil end
            return s
        end)
        return okText and text or nil
    end
    first, second = Plain(first), Plain(second)
    if not first then return nil end
    return second and (first .. " " .. second) or first
end


-- One table per merged addon, created before any of their files load.
Chaircraft.ChairPlus = {}
Chaircraft.ChairAuras = {}
Chaircraft.ChairSnack = {}
Chaircraft.ChairIgnore = {}
-- ChairTracker is not listed here: it never used the vararg header. It carries
-- its own globals (WOWFTrackerNS, WOWFTracker_Defaults), which were already
-- unique, so its files needed no rebinding at all.

-------------------------------------------------------------------------------
-- The parts
-------------------------------------------------------------------------------
-- Order is the order they appear in the menu's nav row.
--
-- `cmdKey` is the client's SlashCmdList key, not a display name, so it keeps
-- its original value even where the part has been renamed -- SNAPSNACK and
-- WOWFTRACKER are what those addons registered themselves under, and Hub.lua
-- has to look them up by exactly that to capture and then remove them.
--
-- `Open` and `Present` live here rather than in Hub.lua so that adding a part
-- is a change to one file. Both are resolved late, at click or query time,
-- because two of the four build their panel on first use and any of them may
-- have failed to load.

Chaircraft.parts = {
    {
        key = "chairplus",
        title = "ChairPlus",
        blurb = "Currency and bag display, quest, vendor, loot and camera automation.",
        tokens = { "plus", "cp" },
        route = "/chair plus",
        cmdKey = "CHAIRPLUS",
        Open = function()
            local ns = Chaircraft.ChairPlus
            if ns and ns.OpenPanel then ns.OpenPanel("plus") return true end
        end,
        Present = function()
            local ns = Chaircraft.ChairPlus
            return (ns and ns.OpenPanel ~= nil) and true or false
        end,
    },
    {
        key = "chairauras",
        title = "ChairAuras",
        -- The page heading inside the menu; the nav button keeps "Auras".
        pageTitle = "ChairAuras |cffff9900*Beta*|r",
        blurb = "Aura, debuff and cooldown watchers.",
        tokens = { "auras", "ca" },
        route = "/chair auras",
        cmdKey = "CHAIRAURAS",
        Window = function()
            local ns = Chaircraft.ChairAuras
            return ns and ns.Config and ns.Config.GetWindow and ns.Config:GetWindow()
        end,
        Show = function()
            local ns = Chaircraft.ChairAuras
            if ns and ns.Config and ns.Config.Open then
                ns.Config:Open()
                return true
            end
        end,
        Present = function()
            local ns = Chaircraft.ChairAuras
            return (ns and ns.Config ~= nil) and true or false
        end,
    },
    {
        key = "chairsnack",
        title = "ChairSnack",
        blurb = "Consumable tracking and configurable icon grids.",
        tokens = { "snack", "ss" },
        route = "/chair snack",
        cmdKey = "SNAPSNACK",
        Window = function()
            local addon = Chaircraft.ChairSnack
            return addon and addon.GetConfigWindow and addon:GetConfigWindow()
        end,
        Show = function()
            local addon = Chaircraft.ChairSnack
            if addon and addon.OpenConfig then addon:OpenConfig() return true end
        end,
        Present = function()
            local addon = Chaircraft.ChairSnack
            return (addon and addon.OpenConfig ~= nil) and true or false
        end,
    },
    {
        key = "chairtracker",
        title = "ChairTracker",
        blurb = "Reputation and weapon skill bars.",
        tokens = { "tracker", "tr", "rep" },
        route = "/chair tracker",
        cmdKey = "WOWFTRACKER",
        -- Deliberately its options, not its window. The tracker's own bare
        -- command toggles the bar window instead, which would make this the
        -- only part of the four where the menu did something different from
        -- the other three.
        Window = function()
            local trackerNS = _G.WOWFTrackerNS
            return trackerNS and trackerNS.optionsFrame
        end,
        Show = function()
            local trackerNS = _G.WOWFTrackerNS
            if trackerNS and trackerNS.ShowOptions then
                trackerNS.ShowOptions()
                return true
            end
        end,
        Present = function()
            local trackerNS = _G.WOWFTrackerNS
            return (trackerNS and trackerNS.ToggleOptions ~= nil) and true or false
        end,
    },
    {
        key = "chairignore",
        title = "ChairIgnore",
        blurb = "One ignore list for every character, and chat filters.",
        tokens = { "ignore", "ci" },
        route = "/chair ignore",
        -- No slash command of its own: /chair forwards "/chair ignore add ..."
        -- to the handler it registers under this key.
        cmdKey = "CHAIRIGNORE",
        Window = function()
            local ns = Chaircraft.ChairIgnore
            return ns and ns.GetWindow and ns.GetWindow()
        end,
        Show = function()
            local ns = Chaircraft.ChairIgnore
            if ns and ns.ShowWindow then ns.ShowWindow() return true end
        end,
        Present = function()
            local ns = Chaircraft.ChairIgnore
            return (ns and ns.ShowWindow ~= nil) and true or false
        end,
        -- Its tabs and options, for the menu's search box.
        Search = function()
            local ns = Chaircraft.ChairIgnore
            return ns and ns.SearchEntries and ns.SearchEntries() or {}
        end,
    },
}

-- Opening a part's settings means hosting its window inside the Chaircraft
-- menu, with a Back button to the main page. If the menu is not there (ChairPlus
-- failed to load) the part's window opens on its own, as it always used to.
for _, part in ipairs(Chaircraft.parts) do
    if part.Window and part.Show then
        part.Open = function()
            local plus = Chaircraft.ChairPlus
            if plus and plus.OpenPage and plus.OpenPage(part) then return true end
            return part.Show()
        end
    end
end

-- token -> part, built once. Callers should use this rather than walking the
-- list, so an alias can never resolve differently in two places.
Chaircraft.partsByToken = {}
for _, part in ipairs(Chaircraft.parts) do
    Chaircraft.partsByToken[part.key] = part
    for _, token in ipairs(part.tokens) do
        Chaircraft.partsByToken[token] = part
    end
end

function Chaircraft.FindPart(token)
    if type(token) ~= "string" then return nil end
    return Chaircraft.partsByToken[token:lower()]
end
