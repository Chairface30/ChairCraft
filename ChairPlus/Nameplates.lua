-- ChairPlus Nameplates.lua
-- Enemy nameplates colored by who has aggro, each color the player's own:
--
--   I have aggro          the mob is on me, firmly (threat status 3)
--   aggro changing        it is slipping away from someone, or about to be
--                         taken (status 1 or 2)
--   a non-tank has aggro  it is on a group member whose role is not Tank
--   another tank has it   it is on another group member whose role is Tank
--
-- Only while you are the tank: your group role, or the roles ticked in the
-- group finder when you have none (ns.PlayerIsTank, Threat.lua). Anyone else
-- sees every plate in its normal colors. A mob that is not in combat, or is
-- on someone outside the group, keeps its normal color too. Each state can be
-- switched off on its own.
--
-- The color goes onto the plate's health bar, and is put back on after the
-- client recolors it (a post-hook on CompactUnitFrame_UpdateHealthColor, so
-- the client's own code has already run). The bar's own color is remembered
-- and restored when a state no longer applies. Nothing of the plate's own is
-- made to run from here: this only sets a color.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local STATES = {
    { key = "npMine",     label = "I have aggro" },
    { key = "npChanging", label = "Aggro changing" },
    { key = "npNonTank",  label = "A non-tank has aggro" },
    { key = "npOtherTank", label = "Another tank has aggro" },
}
ns.NAMEPLATE_STATES = STATES

local plates = {}      -- unit -> true, the enemy plates on screen
local original = {}    -- health bar -> { r, g, b }, the color before ours

local function Bool(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return ns.Bool(value)
end

local function HealthBar(unit)
    local api = _G.C_NamePlate
    if not (api and type(api.GetNamePlateForUnit) == "function") then return nil end
    local ok, plate = pcall(api.GetNamePlateForUnit, unit)
    if not ok or type(plate) ~= "table" then return nil end
    local frame = plate.UnitFrame or plate.unitFrame
    local bar = type(frame) == "table" and (frame.healthBar or frame.HealthBar) or nil
    if type(bar) ~= "table" or type(bar.SetStatusBarColor) ~= "function" then return nil end
    return bar
end

-- Which state a mob is in, or nil for its normal color.
function ns.NameplateState(unit)
    if not Bool(_G.UnitAffectingCombat, unit) then return nil end
    local okS, status = pcall(_G.UnitThreatSituation, "player", unit)
    status = okS and ns.Num(status) or nil
    if status == 3 then return "npMine" end
    if status == 1 or status == 2 then return "npChanging" end

    -- Someone else has it: who.
    local target = unit .. "target"
    if not Bool(_G.UnitExists, target) then return nil end
    if Bool(_G.UnitIsUnit, target, "player") then return "npMine" end
    local grouped = Bool(_G.UnitInParty, target) or Bool(_G.UnitInRaid, target)
    if not grouped then return nil end
    local okR, role = pcall(_G.UnitGroupRolesAssigned, target)
    role = okR and ns.Text(role) or nil
    if role == "TANK" then return "npOtherTank" end
    return "npNonTank"
end

local function Paint(unit)
    local bar = HealthBar(unit)
    if not bar then return end
    -- A tank's tool: for anyone else the plates keep their normal colors.
    local tanking = ns.PlayerIsTank and ns.PlayerIsTank() or false
    local state = (ns.IsEnabled("nameplateThreat") and tanking) and ns.NameplateState(unit) or nil
    if state and not ns.Get(state) then state = nil end
    if state then
        if not original[bar] then
            local ok, r, g, b = pcall(bar.GetStatusBarColor, bar)
            original[bar] = ok and { ns.Num(r) or 1, ns.Num(g) or 0, ns.Num(b) or 0 } or { 1, 0, 0 }
        end
        pcall(bar.SetStatusBarColor, bar, ns.Num(ns.Get(state .. "R")) or 1,
              ns.Num(ns.Get(state .. "G")) or 1, ns.Num(ns.Get(state .. "B")) or 1)
        bar.chairThreatState = state
    elseif original[bar] then
        local c = original[bar]
        pcall(bar.SetStatusBarColor, bar, c[1], c[2], c[3])
        original[bar] = nil
        bar.chairThreatState = nil
    end
end
ns.PaintNameplate = Paint

local function PaintAll()
    for unit in pairs(plates) do Paint(unit) end
end

local driver
local hooked = false

local function OnEvent(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        if type(unit) == "string" and not Bool(_G.UnitIsFriend, "player", unit) then
            plates[unit] = true
            Paint(unit)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if type(unit) == "string" then
            local bar = HealthBar(unit)
            if bar and original[bar] then
                local c = original[bar]
                pcall(bar.SetStatusBarColor, bar, c[1], c[2], c[3])
                original[bar] = nil
            end
            plates[unit] = nil
        end
    elseif event == "UNIT_THREAT_LIST_UPDATE" or event == "UNIT_TARGET" then
        if type(unit) == "string" and plates[unit] then Paint(unit) else PaintAll() end
    else
        PaintAll()
    end
end

local EVENTS = { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_THREAT_LIST_UPDATE",
                 "UNIT_TARGET", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
                 "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED",
                 -- Your role changing while solo or queued: the group finder's.
                 "LFG_ROLE_UPDATE", "ROLE_CHANGED_INFORM" }

ns.RegisterModule("nameplateThreat", {
    title = "Nameplate threat colors",
    desc = "While you are the tank, color enemy nameplates by who has aggro: you, another tank, someone "
        .. "who is not a tank, or aggro that is changing hands. Each color is your own.",
    Apply = function(enabled)
        if not driver then
            driver = CreateFrame("Frame")
            driver:SetScript("OnEvent", OnEvent)
        end
        for _, event in ipairs(EVENTS) do
            if enabled then
                pcall(driver.RegisterEvent, driver, event)
            else
                pcall(driver.UnregisterEvent, driver, event)
            end
        end
        -- The client recolors a plate whenever it likes; ours goes back on
        -- afterwards. A post-hook, once: it checks the switch each time.
        if enabled and not hooked and type(_G.CompactUnitFrame_UpdateHealthColor) == "function" then
            hooked = true
            hooksecurefunc("CompactUnitFrame_UpdateHealthColor", function(frame)
                local unit = type(frame) == "table" and frame.unit
                if type(unit) == "string" and plates[unit] and ns.IsEnabled("nameplateThreat") then
                    -- The client just set its own color: that is the one to
                    -- restore later, not ours.
                    local bar = HealthBar(unit)
                    if bar then original[bar] = nil end
                    Paint(unit)
                end
            end)
        end
        -- Every plate put back or painted, whichever way the switch went.
        PaintAll()
    end,
})

-- /chair plus threat nameplates probe: can this client answer the questions,
-- here and now? Run it in combat, on a pull, to know.
function ns.ProbeNameplates()
    local api = _G.C_NamePlate
    ns.Print("Nameplate probe:")
    ns.Print("  C_NamePlate.GetNamePlateForUnit: "
        .. ((api and type(api.GetNamePlateForUnit) == "function") and "yes" or "missing"))
    ns.Print("  CompactUnitFrame_UpdateHealthColor: "
        .. (type(_G.CompactUnitFrame_UpdateHealthColor) == "function" and "yes" or "missing"))
    local shown = 0
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if Bool(_G.UnitExists, unit) then
            shown = shown + 1
            if shown <= 5 then
                local okS, status = pcall(_G.UnitThreatSituation, "player", unit)
                local statusText = not okS and "refused" or (status == nil and "none")
                    or (ns.Num(status) and tostring(ns.Num(status)) or "secret")
                local okT, onMe = pcall(_G.UnitIsUnit, unit .. "target", "player")
                local targetText = not okT and "refused" or (ns.Bool(onMe) == nil and "secret" or tostring(ns.Bool(onMe)))
                ns.Print(string.format("  %s: threat status %s, targeting me %s, health bar %s, state %s",
                    unit, statusText, targetText, HealthBar(unit) and "yes" or "no",
                    tostring(ns.NameplateState(unit))))
            end
        end
    end
    if shown == 0 then ns.Print("  no nameplates on screen -- stand near some enemies.") end
end
