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

-------------------------------------------------------------------------------
-- Threat % on the nameplates
-------------------------------------------------------------------------------
-- A number inside each enemy plate's health bar during combat, so a whole
-- pack can be read at a glance without tabbing through it:
--
--   you are the tank, and it is on you     the highest threat behind you,
--                                          as a % of what pulls it off you
--   you are the tank, and someone else     who has it, and your own % toward
--   has it                                 taking it back ("Brakk 76%"), red
--   you are not the tank                   your own %: 100 is where you pull
--
-- Green under 70%, amber to 90%, red past it. The % is the client's scaled
-- threat (UnitDetailedThreatSituation), readable in combat on this client;
-- rows it will not read are simply left out.

local NP_TICK = 0.3
local labels = {}      -- nameplate frame -> { frame, text }
ns.npThreatLabels = labels   -- for the tests
local npTicker

local function NumberColor(pct)
    if pct >= 90 then return 1, 0.25, 0.2 end
    if pct >= 70 then return 1, 0.75, 0.2 end
    return 0.4, 1, 0.4
end

local function FirstName(row)
    local plain = row and ns.Text(row.name)
    return plain and plain:match("^(%S+)") or nil
end

-- What a mob's plate says, and its color, or nil for nothing.
function ns.NameplateThreatText(unit)
    if not Bool(_G.UnitAffectingCombat, unit) then return nil end
    local rows = ns.ThreatRows and ns.ThreatRows(unit)
    if type(rows) ~= "table" or #rows == 0 then return nil end
    local me, holder, bestOther
    for _, row in ipairs(rows) do
        if row.isMe then me = row
        else
            if row.tanking and not holder then holder = row end
            if not bestOther then bestOther = row end   -- rows come highest first
        end
    end

    if ns.PlayerIsTank and ns.PlayerIsTank() then
        if me and me.tanking then
            if not bestOther then return nil end
            local pct = math.floor(bestOther.pct + 0.5)
            return pct .. "%", NumberColor(pct)
        end
        if holder and me then
            local pct = math.floor(me.pct + 0.5)
            local name = FirstName(holder)
            return (name and (name .. " ") or "") .. pct .. "%", 1, 0.25, 0.2
        end
        return nil
    end

    if not me then return nil end
    local pct = math.floor(me.pct + 0.5)
    return pct .. "%", NumberColor(pct)
end

local function Plate(unit)
    local api = _G.C_NamePlate
    if not (api and type(api.GetNamePlateForUnit) == "function") then return nil end
    local ok, plate = pcall(api.GetNamePlateForUnit, unit)
    if ok and type(plate) == "table" then return plate end
    return nil
end

-- Our own frame on the plate, over its health bar: nothing of the plate's is
-- changed, only anchored to.
local function Label(unit)
    local plate = Plate(unit)
    local bar = HealthBar(unit)
    if not (plate and bar) then return nil end
    local label = labels[plate]
    if not label then
        local frame = CreateFrame("Frame", nil, plate)
        frame:SetFrameLevel((ns.Num(bar:GetFrameLevel()) or 1) + 5)
        local text = frame:CreateFontString(nil, "OVERLAY")
        local okF = pcall(text.SetFont, text, "Fonts\FRIZQT__.TTF", 10, "OUTLINE")
        if not okF then text:SetFontObject("GameFontHighlightSmall") end
        label = { frame = frame, text = text }
        labels[plate] = label
    end
    label.frame:ClearAllPoints()
    label.frame:SetAllPoints(bar)
    local align = ns.Get("npThreatTextAlign") or "CENTER"
    local x = (align == "LEFT" and 3) or (align == "RIGHT" and -3) or 0
    label.text:ClearAllPoints()
    label.text:SetPoint(align, label.frame, align, x, 0)
    label.text:SetJustifyH(align)
    return label
end

local function ShowText(unit)
    local label = Label(unit)
    if not label then return end
    local text, r, g, b
    if ns.IsEnabled("npThreatText") then
        local ok, t, rr, gg, bb = pcall(ns.NameplateThreatText, unit)
        if ok then text, r, g, b = t, rr, gg, bb end
    end
    if text then
        label.text:SetText(text)
        label.text:SetTextColor(r or 1, g or 1, b or 1)
        label.frame:Show()
    else
        label.frame:Hide()
    end
end
ns.ShowNameplateThreatText = ShowText

local textPlates = {}   -- unit -> true, the enemy plates on screen

local function ShowAllText()
    for unit in pairs(textPlates) do ShowText(unit) end
end

local function HideAllText()
    for _, label in pairs(labels) do label.frame:Hide() end
end

local function StartTicker()
    if npTicker or not (C_Timer and C_Timer.NewTicker) then return end
    npTicker = C_Timer.NewTicker(NP_TICK, function() pcall(ShowAllText) end)
end

local function StopTicker()
    if npTicker then npTicker:Cancel() end
    npTicker = nil
end

local textDriver

local function OnTextEvent(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        if type(unit) == "string" and not Bool(_G.UnitIsFriend, "player", unit) then
            textPlates[unit] = true
            ShowText(unit)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if type(unit) == "string" then
            local plate = Plate(unit)
            if plate and labels[plate] then labels[plate].frame:Hide() end
            textPlates[unit] = nil
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        StartTicker()
        ShowAllText()
    elseif event == "PLAYER_REGEN_ENABLED" then
        StopTicker()
        HideAllText()
    elseif event == "UNIT_THREAT_LIST_UPDATE" then
        if type(unit) == "string" and textPlates[unit] then ShowText(unit) end
    end
end

local TEXT_EVENTS = { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_THREAT_LIST_UPDATE",
                      "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }

ns.RegisterModule("npThreatText", {
    title = "Threat % on nameplates",
    desc = "During combat, a threat % inside each enemy nameplate's health bar. As the tank: the highest "
        .. "threat behind you, or who has the mob and how close you are to taking it back. Otherwise: "
        .. "your own threat on each mob.",
    Apply = function(enabled)
        if not textDriver then
            textDriver = CreateFrame("Frame")
            textDriver:SetScript("OnEvent", OnTextEvent)
        end
        for _, event in ipairs(TEXT_EVENTS) do
            if enabled then
                pcall(textDriver.RegisterEvent, textDriver, event)
            else
                pcall(textDriver.UnregisterEvent, textDriver, event)
            end
        end
        if enabled then
            -- Plates already on screen when it is switched on.
            for i = 1, 40 do
                local unit = "nameplate" .. i
                if Bool(_G.UnitExists, unit) and not Bool(_G.UnitIsFriend, "player", unit) then
                    textPlates[unit] = true
                end
            end
            if Bool(_G.UnitAffectingCombat, "player") then StartTicker() end
            ShowAllText()
        else
            StopTicker()
            HideAllText()
        end
    end,
})
