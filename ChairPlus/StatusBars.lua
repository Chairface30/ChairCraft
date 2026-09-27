-- ChairPlus StatusBars.lua
-- Hide the game's experience bar and status bar 2 together.
--
-- The OSD can show XP itself, which makes the long bars under the action bars
-- redundant. Which frames draw them depends on the engine: the retail one has
-- two status tracking containers (Edit Mode's "Experience Bar" and "Status
-- Bar 2"), the classic one an XP bar and a reputation bar. Every name that
-- exists here is hidden, and the rest are not asked about.
--
-- Made see-through and click-through rather than hidden. Hide() and Show()
-- run the bars' own OnHide/OnShow, and asking Blizzard's bar manager to lay
-- them out again is its code run from ours -- the kind of call that taints a
-- frame on this client (changed 2026-09-26). Alpha and the mouse are the
-- widget's own switches: nothing of Blizzard's runs.
--
-- Blizzard reshows these whenever what they track changes, which can put the
-- alpha back, so each is hooked to go see-through again after its own OnShow.

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
local mouseTaken = {}   -- frame -> true: the mouse we switched off, to give back

local function Bars()
    local out = {}
    for _, name in ipairs(NAMES) do
        local bar = _G[name]
        if type(bar) == "table" and bar.SetAlpha then
            out[#out + 1] = bar
        end
    end
    return out
end

-- The bar and the frames inside it, which carry the tooltips.
local function Parts(bar)
    local parts = { bar }
    local ok, children = pcall(function() return { bar:GetChildren() } end)
    if ok then
        for _, child in ipairs(children) do parts[#parts + 1] = child end
    end
    return parts
end

local function Locked()
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked
end

-- Set while we set the alpha ourselves, so our own SetAlpha(0) is not taken
-- for the client's.
local concealing = false

local function Conceal(bar)
    concealing = true
    pcall(bar.SetAlpha, bar, 0)
    concealing = false
    -- The mouse cannot be changed on some frames in combat; that waits.
    if Locked() then return end
    for _, part in ipairs(Parts(bar)) do
        local ok, enabled = pcall(part.IsMouseEnabled, part)
        if ok and enabled then
            if pcall(part.EnableMouse, part, false) then mouseTaken[part] = true end
        end
    end
end

local function Reveal(bar)
    pcall(bar.SetAlpha, bar, 1)
end

local waiter
local settled = false

-- The client puts a bar's alpha back without showing it again -- its bar
-- layout does, a moment after login (2026-09-26: on /reload the XP bar came
-- back until the setting was toggled). So besides OnShow, a change of alpha
-- while hiding is undone: a post-hook, after the client's own call.
local function Watch(bar)
    if hooked[bar] then return end
    hooked[bar] = true
    if bar.HookScript then
        pcall(bar.HookScript, bar, "OnShow", function(self)
            if hiding then Conceal(self) end
        end)
    end
    if type(hooksecurefunc) == "function" and bar.SetAlpha ~= nil then
        pcall(hooksecurefunc, bar, "SetAlpha", function(self, alpha)
            if hiding and not concealing and (tonumber(alpha) or 0) > 0 then Conceal(self) end
        end)
    end
end

local function Apply(enabled)
    local bars = Bars()
    if enabled then
        hiding = true
        for _, bar in ipairs(bars) do
            Watch(bar)
            Conceal(bar)
        end
        -- And once more when the client has finished laying the bars out
        -- after login, whatever it did to them in between.
        if not settled and ns.After then
            settled = true
            ns.After(1, function() if hiding then Apply(true) end end)
            ns.After(3, function() if hiding then Apply(true) end end)
        end
    elseif hiding then
        hiding = false
        for _, bar in ipairs(bars) do Reveal(bar) end
        if not Locked() then
            for part in pairs(mouseTaken) do pcall(part.EnableMouse, part, true) end
            wipe(mouseTaken)
        end
    end

    -- What had to wait for combat to end: the mouse, either way.
    if not waiter then
        waiter = CreateFrame("Frame")
        waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        -- The bar layout loads with these; bars it makes late are hooked here.
        for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "EDIT_MODE_LAYOUTS_UPDATED" }) do
            pcall(waiter.RegisterEvent, waiter, event)
        end
        waiter:SetScript("OnEvent", function()
            if hiding then
                for _, bar in ipairs(Bars()) do
                    Watch(bar)
                    Conceal(bar)
                end
            else
                for part in pairs(mouseTaken) do pcall(part.EnableMouse, part, true) end
                wipe(mouseTaken)
            end
        end)
    end
end

ns.RegisterModule("hideStatusBars", {
    title = "Hide XP and status bars",
    desc = "Hide the game's experience bar and status bar 2.",
    Apply = Apply,
})
