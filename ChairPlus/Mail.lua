-- ChairPlus Mail.lua
-- Small automations, each its own switch, all off out of the box. (An "Open
-- all" mail button lived here until the game got its own.)
--
--   battleground release   release your spirit on dying in a battleground,
--                      unless you could come back where you fell
--   skip cinematics    the in-game cutscenes (not pre-rendered movies)
--   dismount and stand     on the "You are mounted" and "You must be
--                      standing" errors, out of combat, and on opening the
--                      flight map
--
-- Holding shift leaves each of them to you. Every call is a client function
-- (RepopMe, StopCinematic, Dismount...), looked up when used:
-- nothing of Blizzard's own interface is made to run from here.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local function Shift()
    local ok, down = pcall(_G.IsShiftKeyDown)
    return ok and ns.Bool(down) == true
end

local function Locked()
    local ok, locked = pcall(_G.InCombatLockdown)
    return ok and ns.Bool(locked) == true
end

local function Call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

-------------------------------------------------------------------------------
-- The rest
-------------------------------------------------------------------------------

-- Error strings, the client's own so any language matches.
local MOUNTED = { "ERR_ATTACK_MOUNTED", "ERR_NOT_WHILE_MOUNTED", "SPELL_FAILED_NOT_MOUNTED",
                  "ERR_TAXIPLAYERALREADYMOUNTED", "ERR_MOUNT_SHAPESHIFTED" }
local STANDING = { "ERR_CANTATTACK_NOTSTANDING", "SPELL_FAILED_NOT_STANDING", "ERR_LOOT_NOTSTANDING" }
local function Matches(message, list)
    local text = ns.Text(message)
    if not text then return false end
    for _, key in ipairs(list) do
        if ns.Text(_G[key]) == text then return true end
    end
    return false
end
ns.MailMatchesError = Matches

local driver

local function OnEvent(_, event, a, b)
    if event == "PLAYER_DEAD" then
        if not ns.IsEnabled("autoReleaseBG") or Shift() then return end
        local ok, inside, kind = pcall(_G.IsInInstance)
        if not (ok and inside and kind == "pvp") then return end
        -- A soulstone or reincarnation brings you back where you fell:
        -- worth more than a run from the graveyard.
        local okS, self = pcall(_G.HasSoulstone)
        if okS and ns.Text(self) then return end
        Call("RepopMe")
    elseif event == "CINEMATIC_START" then
        if not ns.IsEnabled("skipCinematics") or Shift() then return end
        Call("StopCinematic")
    elseif event == "UI_ERROR_MESSAGE" then
        if not ns.IsEnabled("autoDismount") or Locked() then return end
        local message = (type(b) == "string" and b) or a
        if Matches(message, MOUNTED) then
            Call("Dismount")
        elseif Matches(message, STANDING) then
            Call("DoEmote", "STAND")
        end
    elseif event == "TAXIMAP_OPENED" then
        if not ns.IsEnabled("autoDismount") or Locked() then return end
        local ok, mounted = pcall(_G.IsMounted)
        if ok and ns.Bool(mounted) then Call("Dismount") end
    end
end

local EVENTS = {
    autoReleaseBG = { "PLAYER_DEAD" },
    skipCinematics = { "CINEMATIC_START" },
    autoDismount = { "UI_ERROR_MESSAGE", "TAXIMAP_OPENED" },
}

local function ApplyAll()
    if not driver then
        driver = CreateFrame("Frame")
        driver:SetScript("OnEvent", OnEvent)
    end
    pcall(driver.UnregisterAllEvents, driver)
    for key, events in pairs(EVENTS) do
        if ns.IsEnabled(key) then
            for _, event in ipairs(events) do pcall(driver.RegisterEvent, driver, event) end
        end
    end
end

ns.RegisterModule("autoReleaseBG", {
    title = "Release in battlegrounds",
    desc = "Release your spirit on dying in a battleground, unless you can come back where you fell. Hold shift to stay.",
    Apply = ApplyAll,
})
ns.RegisterModule("skipCinematics", {
    title = "Skip cinematics",
    desc = "Skip the in-game cutscenes. Hold shift when one starts to watch it.",
    Apply = ApplyAll,
})
ns.RegisterModule("autoDismount", {
    title = "Dismount and stand when needed",
    desc = "On \"You are mounted\" or \"You must be standing\", dismount or stand up, out of combat. Also dismounts when you open the flight map.",
    Apply = ApplyAll,
})
