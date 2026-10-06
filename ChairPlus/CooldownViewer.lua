-- ChairPlus CooldownViewer.lua
-- The game's Cooldown Manager only in combat.
--
-- The Cooldown Manager is four Edit Mode frames: Essential and Utility
-- cooldowns, and the buff icons and bars. With this option they are
-- see-through out of combat and back when combat starts, and always shown
-- while Edit Mode is open so they can still be placed.
--
-- See-through rather than hidden, for the reason FormBar.lua gives: alpha is
-- the widget's own switch, and nothing of Blizzard's runs. Hide/Show would
-- run the viewers' own scripts from our code, which taints them (see
-- never driving Blizzard frames). SetAlpha is not refused in combat, so the
-- switch works at either edge of it.
--
-- Blizzard sets the alpha itself (its opacity setting, fades). While the
-- frames should be hidden that is undone after its own call; the alpha it
-- asked for is kept and put back when they show, so its opacity setting is
-- not lost.
--
-- The viewers live in Blizzard_CooldownViewer, which may load after us; they
-- are looked for again when it does.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local enabled = false
local hiding = false       -- the viewers are see-through right now
local concealing = false   -- our own SetAlpha, not to be taken for the client's
local editing = false      -- Edit Mode is open
local hooked = {}
local wanted = {}          -- frame -> the alpha Blizzard last asked for
local editHooked = false
local driver

local function InCombat()
    local ok, locked = pcall(_G.InCombatLockdown)
    return ok and locked == true
end

local function Frames()
    local out = {}
    for _, name in ipairs(VIEWERS) do
        local frame = _G[name]
        if type(frame) == "table" and frame.SetAlpha then out[#out + 1] = frame end
    end
    return out
end

local function SetOwnAlpha(frame, alpha)
    concealing = true
    pcall(frame.SetAlpha, frame, alpha)
    concealing = false
end

local function Watch(frame)
    if hooked[frame] then return end
    hooked[frame] = true
    local ok, alpha = pcall(frame.GetAlpha, frame)
    wanted[frame] = ok and ns.Num(alpha) or 1
    if type(hooksecurefunc) == "function" then
        pcall(hooksecurefunc, frame, "SetAlpha", function(self, a)
            if concealing then return end
            wanted[self] = ns.Num(a) or wanted[self]
            if hiding and (ns.Num(a) or 1) > 0 then SetOwnAlpha(self, 0) end
        end)
    end
    if frame.HookScript then
        pcall(frame.HookScript, frame, "OnShow", function(self)
            if hiding then SetOwnAlpha(self, 0) end
        end)
    end
end

-- Edit Mode open: show them so they can be moved; closed: back to the rule.
local Update
local function WatchEditMode()
    if editHooked then return end
    local manager = _G.EditModeManagerFrame
    if type(manager) ~= "table" or not manager.HookScript then return end
    editHooked = true
    pcall(manager.HookScript, manager, "OnShow", function() editing = true Update() end)
    pcall(manager.HookScript, manager, "OnHide", function() editing = false Update() end)
    local ok, shown = pcall(manager.IsShown, manager)
    editing = ok and shown == true
end

function Update()
    if not enabled and not hiding then return end
    WatchEditMode()
    local want = enabled and not editing and not InCombat()
    for _, frame in ipairs(Frames()) do
        Watch(frame)
        if want then
            SetOwnAlpha(frame, 0)
        elseif hiding then
            SetOwnAlpha(frame, wanted[frame] or 1)
        end
    end
    hiding = want
end
ns.CooldownViewerUpdate = Update

local function OnEvent(_, event, name)
    if event == "PLAYER_REGEN_DISABLED" then
        -- InCombatLockdown is still false here: show them outright.
        if hiding then
            hiding = false
            for _, frame in ipairs(Frames()) do SetOwnAlpha(frame, wanted[frame] or 1) end
        end
        return
    end
    if event == "ADDON_LOADED" and name ~= "Blizzard_CooldownViewer" and name ~= "Blizzard_EditMode" then
        return
    end
    Update()
end

local function Apply(on)
    enabled = on and true or false
    if enabled and not driver then
        driver = CreateFrame("Frame")
        for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
                                 "PLAYER_REGEN_ENABLED", "ADDON_LOADED",
                                 "EDIT_MODE_LAYOUTS_UPDATED" }) do
            pcall(driver.RegisterEvent, driver, event)
        end
        driver:SetScript("OnEvent", OnEvent)
    end
    Update()
    -- The viewers may be built after login; look again once it has settled.
    if enabled and #Frames() == 0 then
        ns.After(2, Update)
    end
end

ns.RegisterModule("cooldownViewerCombat", {
    title = "Cooldown Manager only in combat",
    desc = "The game's Cooldown Manager is see-through out of combat and shows when combat starts.",
    Apply = Apply,
})
