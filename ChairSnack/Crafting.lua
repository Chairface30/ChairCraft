-- SnapSnack Crafting.lua
-- The crafting bar: a profession's button while you stand at its station.
--
-- Anvil        -> Blacksmithing
-- Forge        -> Smelting
-- Cooking fire -> Cooking
--
-- This client has no "near an anvil" call that works: IsNearProfessionSpellFocus
-- answers false everywhere, and spell usability ignores the station. What does
-- work is a recipe's own requirement list, the "Requires: Anvil" line the
-- professions window draws red or white: C_TradeSkillUI.GetRecipeRequirements
-- hands back { name = "Anvil", met = true/false }, with the window open or shut
-- (confirmed in game for Rough Bronze Shoulders).
--
-- So each station is asked through a recipe that needs it. A few known recipes
-- are tried first; any recipe seen in an opened professions window that needs a
-- station is remembered too, so a character with none of the starting ones
-- still gets an answer after opening the window once.
--
-- Checked once a second out of combat. The bar can't change in combat anyway --
-- its buttons are secure -- so a change seen then waits for combat to end.

local suiteName, Chaircraft = ...
local addon = Chaircraft.ChairSnack

local GetSpellInfo = addon.GetSpellInfo

local POLL = 1   -- seconds between checks

-- requirement: the name in the recipe's requirement list.
-- recipes:     recipes that need it, tried in order.
-- spells:      the profession's spell ranks; any one known gives the button.
local STATIONS = {
    { key = "anvil", label = "Anvil: Blacksmithing", requirement = "Anvil",
      recipes = { 3328, 2663, 2662, 2665 },        -- Rough Bronze Shoulders, Copper Bracers...
      spells = { 2018, 3100, 3538, 9785, 9787, 9788, 17039, 17040, 17041 } },
    { key = "forge", label = "Forge: Smelting", requirement = "Forge",
      recipes = { 2657, 3304, 2659, 3307, 3308 },  -- Smelt Copper, Tin, Bronze, Iron, Gold
      spells = { 2656 } },
    { key = "fire", label = "Cooking fire: Cooking", requirement = "Cooking Fire",
      recipes = { 2538, 2540, 8604, 2539, 2541 },  -- Charred Wolf Meat, Roasted Boar Meat...
      spells = { 2550, 3102, 3413, 18260 } },
}
addon.CRAFT_STATIONS = STATIONS

local function TradeSkillUI()
    local T = _G.C_TradeSkillUI
    return type(T) == "table" and T or nil
end

-- true/false for whether this recipe's requirement is met now; nil when the
-- recipe doesn't list it (or can't be asked).
local function RequirementMet(recipeID, requirement)
    local T = TradeSkillUI()
    if not T or type(T.GetRecipeRequirements) ~= "function" then return nil end
    local ok, list = pcall(T.GetRecipeRequirements, recipeID)
    if not ok or type(list) ~= "table" then return nil end
    for _, r in ipairs(list) do
        if type(r) == "table" and r.name == requirement then
            return r.met == true
        end
    end
    return nil
end

-- Recipes seen needing a station, by requirement name. Filled from the
-- professions window; the session's answer, not saved.
local learned = {}

local function LearnFromWindow()
    local T = TradeSkillUI()
    if not T or type(T.GetAllRecipeIDs) ~= "function" then return end
    local ok, ids = pcall(T.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return end
    local wanted = {}
    for _, station in ipairs(STATIONS) do
        if not learned[station.requirement] then wanted[station.requirement] = true end
    end
    if not next(wanted) then return end
    for _, id in ipairs(ids) do
        local okR, list = pcall(T.GetRecipeRequirements, id)
        if okR and type(list) == "table" then
            for _, r in ipairs(list) do
                if type(r) == "table" and wanted[r.name] then
                    learned[r.name] = id
                    wanted[r.name] = nil
                end
            end
        end
        if not next(wanted) then return end
    end
end

-- Which recipe answers for this station: the one that answered last time,
-- else the first that lists the requirement.
local answering = {}

local function StationMet(station)
    local id = answering[station.key]
    if id then
        local met = RequirementMet(id, station.requirement)
        if met ~= nil then return met end
        answering[station.key] = nil
    end
    local candidates = { learned[station.requirement] }
    for _, r in ipairs(station.recipes) do candidates[#candidates + 1] = r end
    for _, r in ipairs(candidates) do
        local met = RequirementMet(r, station.requirement)
        if met ~= nil then
            answering[station.key] = r
            return met
        end
    end
    return nil   -- nothing to ask
end

local function Known(spellID)
    for _, name in ipairs({ "IsPlayerSpell", "IsSpellKnown" }) do
        local fn = _G[name]
        if type(fn) == "function" then
            local ok, v = pcall(fn, spellID)
            if ok and v then return true end
        end
    end
    return false
end

-- The profession spell this character knows for a station: name, icon, ID.
local function ProfessionSpell(station)
    for i = #station.spells, 1, -1 do
        local id = station.spells[i]
        if Known(id) then
            local name, _, icon = GetSpellInfo(id)
            if name then return name, icon, id end
        end
    end
    return nil
end

-- The stations you are at now, as a set of keys.
function addon:CraftStationsNearby()
    local near = {}
    for _, station in ipairs(STATIONS) do
        if ProfessionSpell(station) and StationMet(station) then near[station.key] = true end
    end
    return near
end

-- What /chair snack crafting and the options page show.
addon.craftingSelection = {}

function addon:UpdateCraftingBar()
    local grid = self:GetGrid(self.CRAFT_GRID_ID)
    if not grid then return false end

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = type(itemData) == "table" and itemData.slotKey or false
    end

    local items, selection = {}, {}
    if grid.enabled then
        local slots = grid.autoSlots or {}
        for _, station in ipairs(STATIONS) do
            local name, icon, id = ProfessionSpell(station)
            local met = name and StationMet(station)
            selection[station.key] = { known = name ~= nil, near = met, spell = name,
                                       recipe = answering[station.key] }
            if slots[station.key] ~= false and name and met then
                table.insert(items, {
                    slotKey = station.key,
                    isSpell = true,
                    spellID = id,
                    spellName = name,
                    iconOverride = icon,
                    hideOnZero = false,
                    showInCombat = false,
                    hideCount = true,
                    tooltipTitle = name,
                })
            end
        end
    end

    grid.items = items
    self.craftingSelection = selection

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if itemData.slotKey ~= previous[i] then return true end
    end
    return false
end

-- The once-a-second check. Only rebuilds the bar when what is near changes.
local lastKey
local function NearKey()
    local near = addon:CraftStationsNearby()
    local keys = {}
    for _, station in ipairs(STATIONS) do
        if near[station.key] then keys[#keys + 1] = station.key end
    end
    return table.concat(keys, ",")
end

function addon.CraftingTick()
    if not addon.isReady then return end   -- no profile before login
    local grid = addon:GetGrid(addon.CRAFT_GRID_ID)
    if not grid or not grid.enabled then
        if lastKey ~= nil and grid then
            lastKey = nil
            if addon:UpdateCraftingBar() then addon:RequestUpdate() end
        end
        return
    end
    if InCombatLockdown() then return end
    local key = NearKey()
    if key == lastKey then return end
    lastKey = key
    if addon:UpdateCraftingBar() then addon:RequestUpdate() end
end

local driver = CreateFrame("Frame")
local elapsed = 0
driver:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < POLL then return end
    elapsed = 0
    local ok, err = pcall(addon.CraftingTick)
    if not ok and not addon.craftingFailed then
        addon.craftingFailed = true
        if addon.Print then addon:Print("|cffff5555crafting bar check failed:|r " .. tostring(err)) end
    end
end)
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE" }) do
    pcall(driver.RegisterEvent, driver, event)
end
driver:SetScript("OnEvent", function()
    pcall(LearnFromWindow)
end)

-- /chair snack crafting
function addon:CraftingCommand()
    self:UpdateCraftingBar()
    local grid = self:GetGrid(self.CRAFT_GRID_ID)
    print("|cffFFD100Crafting|r" .. ((grid and grid.enabled) and "" or " |cff808080(bar is off)|r"))
    for _, station in ipairs(STATIONS) do
        local s = self.craftingSelection[station.key] or {}
        local state
        if not s.known then
            state = "|cff808080profession not known|r"
        elseif s.near == nil then
            state = "|cffff5555no recipe to ask|r - open the professions window once"
        else
            state = s.near and "|cff00ff00here|r" or "|cff808080not here|r"
        end
        print("  " .. station.label .. ": " .. state ..
              (s.recipe and (" |cff808080(recipe " .. s.recipe .. ")|r") or ""))
    end
end
