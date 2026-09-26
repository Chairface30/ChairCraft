-- ChairPlus StatusBars.lua
-- Hide the game's experience bar and status bar 2 together.
--
-- The OSD can show XP itself, which makes the long bars under the action bars
-- redundant. Which frames draw them depends on the engine: the retail one has
-- two status tracking containers (Edit Mode's "Experience Bar" and "Status
-- Bar 2"), the classic one an XP bar and a reputation bar. Every name that
-- exists here is hidden, and the rest are not asked about.
--
-- Blizzard reshows these whenever what they track changes, so a bare Hide()
-- lasts until the next kill. Each one is hooked to hide itself again, and
-- alpha 0 covers a Show() that lands in combat, when Hide() is off limits.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local NAMES = {
    "MainStatusTrackingBarContainer",       -- the experience bar
    "SecondaryStatusTrackingBarContainer",  -- status bar 2
    "MainMenuExpBar",
    "ReputationWatchBar",
    "MainMenuBarMaxLevelBar",
}

local hiding = false
local hooked = {}
local wasShown = {}

local function Conceal(bar)
    pcall(bar.SetAlpha, bar, 0)
    if not InCombatLockdown() then pcall(bar.Hide, bar) end
end

local function Bars()
    local out = {}
    for _, name in ipairs(NAMES) do
        local bar = _G[name]
        if type(bar) == "table" and bar.Hide then
            out[#out + 1] = bar
        end
    end
    return out
end

local waiter

local function Apply(enabled)
    local bars = Bars()
    if enabled then
        hiding = true
        for _, bar in ipairs(bars) do
            if not hooked[bar] and bar.HookScript then
                pcall(bar.HookScript, bar, "OnShow", function(self)
                    if hiding then Conceal(self) end
                end)
                hooked[bar] = true
            end
            if wasShown[bar] == nil then
                local ok, shown = pcall(bar.IsShown, bar)
                wasShown[bar] = ok and shown and true or false
            end
            Conceal(bar)
        end
    elseif hiding then
        hiding = false
        for _, bar in ipairs(bars) do
            pcall(bar.SetAlpha, bar, 1)
            if wasShown[bar] and not InCombatLockdown() then pcall(bar.Show, bar) end
        end
        wipe(wasShown)
        -- The retail manager decides which of its bars belong on screen; let it
        -- say again rather than trusting what was up before.
        local manager = _G.StatusTrackingBarManager
        if manager and type(manager.UpdateBarsShown) == "function" then
            pcall(manager.UpdateBarsShown, manager)
        end
    end

    -- A bar that reshowed in combat is only see-through; hide it properly
    -- once combat ends.
    if not waiter then
        waiter = CreateFrame("Frame")
        waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        waiter:SetScript("OnEvent", function()
            if not hiding then return end
            for _, bar in ipairs(Bars()) do Conceal(bar) end
        end)
    end
end

ns.RegisterModule("hideStatusBars", {
    title = "Hide XP and status bars",
    desc = "Hide the game's experience bar and status bar 2.",
    Apply = Apply,
})
