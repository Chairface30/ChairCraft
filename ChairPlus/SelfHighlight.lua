-- ChairPlus SelfHighlight.lua
-- The game's Self Highlight only in combat.
--
-- Self Highlight (Accessibility options) is a handful of CVars, one per style:
-- circle, outline and, on newer clients, icon. Out of combat each one this
-- client has is written to "0"; on entering combat the player's own values go
-- back. Nothing of Blizzard's settings panel is called -- only the CVars.
--
-- The player's values are kept in the saved profile, not just in a local: a
-- reload or logout out of combat leaves the CVars at "0", and the next session
-- would otherwise read those back as the player's choice and lose it.
--
-- The values go back from PLAYER_REGEN_DISABLED, which fires before combat
-- lockdown starts, so the write is not refused.
--
-- A change the player makes in the options while it is held off is theirs:
-- the held values are dropped and whatever they picked becomes the setting.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local CVARS = { "findYourselfModeCircle", "findYourselfModeOutline", "findYourselfModeIcon" }

local enabled = false
local writing = false   -- our own SetCVar, not to be taken for the player's
local driver

local function GetCVarValue(name)
    local get = (_G.C_CVar and _G.C_CVar.GetCVar) or _G.GetCVar
    if type(get) ~= "function" then return nil end
    local ok, value = pcall(get, name)
    if not ok or value == nil then return nil end
    return tostring(value)
end

local function Write(name, value)
    local set = _G.SetCVar or (_G.C_CVar and _G.C_CVar.SetCVar)
    if type(set) ~= "function" then return end
    writing = true
    pcall(set, name, value)
    writing = false
end

local function Held()
    local profile = ns.Profile()
    return type(profile.selfHighlightHeld) == "table" and profile.selfHighlightHeld or nil
end

local function SetHeld(values)
    ns.Profile().selfHighlightHeld = values
end

-- Out of combat: remember the player's values and switch every style off.
-- With every style already off there is nothing to hold.
local function HideHighlight()
    if Held() then return end
    local values, anyOn = {}, false
    for _, name in ipairs(CVARS) do
        local value = GetCVarValue(name)
        if value then
            values[name] = value
            if value ~= "0" then anyOn = true end
        end
    end
    if not anyOn then return end
    SetHeld(values)
    for name in pairs(values) do Write(name, "0") end
end

-- In combat, or switched off: the player's values back. A style turned on
-- while held means the player picked something new; that stands.
local function ShowHighlight()
    local held = Held()
    if not held then return end
    SetHeld(nil)
    for name in pairs(held) do
        local value = GetCVarValue(name)
        if value and value ~= "0" then return end
    end
    for name, value in pairs(held) do Write(name, value) end
end

local function InCombat()
    local ok, locked = pcall(_G.InCombatLockdown)
    return ok and locked == true
end

local function OnEvent(_, event, name)
    if not enabled then return end
    if event == "PLAYER_REGEN_DISABLED" then
        ShowHighlight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        HideHighlight()
    elseif event == "CVAR_UPDATE" and not writing and Held() then
        for _, cvar in ipairs(CVARS) do
            if name == cvar then
                -- The player's pick replaces the held values; out of combat
                -- it is held off again from there.
                SetHeld(nil)
                if not InCombat() then HideHighlight() end
                return
            end
        end
    end
end

ns.RegisterModule("selfHighlightCombat", {
    title = "Self Highlight only in combat",
    desc = "Turn the game's Self Highlight off out of combat, and back to your setting in combat.",
    Apply = function(on)
        enabled = on and true or false
        if enabled then
            if not driver then
                driver = CreateFrame("Frame")
                driver:SetScript("OnEvent", OnEvent)
            end
            driver:RegisterEvent("PLAYER_REGEN_DISABLED")
            driver:RegisterEvent("PLAYER_REGEN_ENABLED")
            pcall(driver.RegisterEvent, driver, "CVAR_UPDATE")
            if InCombat() then ShowHighlight() else HideHighlight() end
        else
            if driver then driver:UnregisterAllEvents() end
            ShowHighlight()
        end
    end,
})
