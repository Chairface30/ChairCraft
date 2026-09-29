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
    ns.Print("  threat %: " .. (not ns.IsEnabled("npThreatText") and "switched off on this character"
        or (ns.NameplateTankView and ns.NameplateTankView() and "on, tank view (the highest behind you)"
        or "on, your own threat")))
    local shown = 0
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if Bool(_G.UnitExists, unit) then
            shown = shown + 1
            if shown <= 5 then
                local okS, status = pcall(_G.UnitThreatSituation, "player", unit)
                local statusText = not okS and "refused" or (ns.IsSecret(status) and "secret")
                    or (status == nil and "none")
                    or (ns.Num(status) and tostring(ns.Num(status)) or "secret")
                local okT, onMe = pcall(_G.UnitIsUnit, unit .. "target", "player")
                local targetText = not okT and "refused" or (ns.Bool(onMe) == nil and "secret" or tostring(ns.Bool(onMe)))
                ns.Print(string.format("  %s: threat status %s, targeting me %s, health bar %s, state %s",
                    unit, statusText, targetText, HealthBar(unit) and "yes" or "no",
                    tostring(ns.NameplateState(unit))))
                -- Your own % asked through the plate, and through the name the
                -- plate borrows (the meter's way), to see which one answers.
                local function Pct(mob)
                    local ok, _, _, scaled = pcall(_G.UnitDetailedThreatSituation, "player", mob)
                    if not ok then return "refused" end
                    if ns.IsSecret(scaled) then return "secret" end
                    if scaled == nil then return "none" end
                    local plain = ns.Num(scaled)
                    return plain and (tostring(math.floor(plain + 0.5)) .. "%") or "secret"
                end
                local alias = ns.ThreatAlias(unit)
                ns.Print(string.format("    my threat: as %s %s; as %s %s", unit, Pct(unit),
                    alias or "(no other name)", alias and Pct(alias) or "-"))
                -- What the plate shows now, and why.
                if ns.IsEnabled("npThreatText") and ns.ShowNameplateThreatText then
                    ns.ShowNameplateThreatText(unit)
                    ns.Print("    plate: " .. tostring(ns.npThreatWhy and ns.npThreatWhy[unit] or "nothing drawn"))
                end
            end
        end
    end
    if shown == 0 then ns.Print("  no nameplates on screen -- stand near some enemies.") end
    -- Combo points: which call answers, and whether it answers in the clear.
    -- Run it with a few points up to know the pips will fill.
    if ns.ComboPointCount then
        local n, from = ns.ComboPointCount()
        local plain = ns.Num(n)
        ns.Print("  combo points: " .. (from or "no call answered") .. ", "
            .. (type(n) ~= "number" and "none" or (plain and tostring(plain) or "secret")))
    end
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
--   you are not the tank                   your own %: 100 is where you pull,
--                                          on every mob in the fight, so 0%
--                                          on one you have not touched yet
--
-- Green under 70%, amber to 90%, red past it. The % is the client's scaled
-- threat (UnitDetailedThreatSituation). Forever answers it in the clear for
-- "target" (and a group member's target) but keeps it secret through a
-- "nameplateN" unit, so each plate borrows such a name for its mob when one
-- is going. Otherwise your own secret % is drawn as it is: as white text if
-- the client will print it, else as a thin bar in the three color bands.
-- The tank's view is for groups only. Each plate's reason is kept for
-- /chair threat nameplates probe.

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

-- The threat meter reads everyone's % on "target" in the clear, while the same
-- question asked of a "nameplateN" unit comes back secret. So a plate borrows
-- another name for its mob when one is going: your target first, then focus,
-- mouseover, your pet's target, a group member's target, or a boss. Nil when
-- none of them is this mob (or the client won't say).
local ALIASES = { "target", "focus", "mouseover", "softenemy", "pettarget" }
for i = 1, 4 do ALIASES[#ALIASES + 1] = "party" .. i .. "target" end
for i = 1, 40 do ALIASES[#ALIASES + 1] = "raid" .. i .. "target" end
for i = 1, 5 do ALIASES[#ALIASES + 1] = "boss" .. i end
ns.npThreatAliases = ALIASES   -- for the tests

function ns.ThreatAlias(unit)
    for _, alias in ipairs(ALIASES) do
        if Bool(_G.UnitExists, alias) then
            local ok, same = pcall(_G.UnitIsUnit, unit, alias)
            if ok and ns.Bool(same) then return alias end
        end
    end
    return nil
end

-- Rows for a plate's mob: through a borrowed name first, since that is what
-- answers in the clear, then the plate's own name.
local function PlateRows(unit, alias)
    if not ns.ThreatRows then return nil end
    if alias then
        local rows = ns.ThreatRows(alias)
        if type(rows) == "table" and #rows > 0 then return rows end
    end
    return ns.ThreatRows(unit)
end

-- Your own scaled threat on a mob when the client keeps it secret (Forever
-- does, in combat), or nil. A secret can't be rounded, compared or colored,
-- but a font string can still draw it.
local function SecretOwnPct(unit)
    local detailed = _G.UnitDetailedThreatSituation
    if type(detailed) ~= "function" then return nil end
    local ok, _, _, scaled = pcall(detailed, "player", unit)
    if ok and ns.IsSecret(scaled) then return scaled end
    return nil
end

-- Why each plate last showed what it did, for the probe.
local whyByUnit = {}
ns.npThreatWhy = whyByUnit
local function Why(unit, reason)
    whyByUnit[unit] = reason
    return nil
end

local function InGroup()
    local ok, inGroup = pcall(_G.IsInGroup)
    return (ok and ns.Bool(inGroup)) and true or false
end

-- The tank's view only in a group: solo there is nobody behind you to show,
-- and the group finder's ticked roles would otherwise make a solo player with
-- Tank ticked see nothing at all.
local function TankView()
    return InGroup() and ns.PlayerIsTank ~= nil and ns.PlayerIsTank() and true or false
end
ns.NameplateTankView = TankView

-- What a mob's plate says, and its color, or nil for nothing. A fifth value,
-- a secret %, is drawn as it is when there is no text.
function ns.NameplateThreatText(unit)
    local alias = ns.ThreatAlias(unit)
    local mob = alias or unit
    -- In the fight? Asked the same way as the rows. A client that won't say is
    -- let through while you are fighting yourself.
    local fighting = Bool(_G.UnitAffectingCombat, mob)
    if fighting == nil and alias then fighting = Bool(_G.UnitAffectingCombat, unit) end
    if fighting == false then return Why(unit, "the mob is not in combat") end
    local meFighting = Bool(_G.UnitAffectingCombat, "player")
    if fighting == nil and not meFighting then
        return Why(unit, "you are out of combat, and the game won't say whether the mob is in it")
    end
    local rows = PlateRows(unit, alias)
    if type(rows) ~= "table" then return Why(unit, "no threat API on this client") end
    local via = "through " .. mob
    local me, holder, bestOther
    for _, row in ipairs(rows) do
        if row.isMe then me = row
        else
            if row.tanking and not holder then holder = row end
            if not bestOther then bestOther = row end   -- rows come highest first
        end
    end

    if TankView() then
        if me and me.tanking then
            if not bestOther then return Why(unit, "tank view: you hold it and nobody else is on its list") end
            local pct = math.floor(bestOther.pct + 0.5)
            Why(unit, "tank view: the highest behind you, " .. via)
            return pct .. "%", NumberColor(pct)
        end
        if holder and me then
            local pct = math.floor(me.pct + 0.5)
            local name = FirstName(holder)
            Why(unit, "tank view: someone else holds it, your % to take it back, " .. via)
            return (name and (name .. " ") or "") .. pct .. "%", 1, 0.25, 0.2
        end
        if alias then return Why(unit, "tank view: no readable threat list " .. via) end
        return Why(unit, "tank view: nobody has this mob targeted, and its threat list is secret "
            .. "through the nameplate")
    end

    -- Anyone else: their own threat on every mob in the fight. The mob being
    -- on you is 100% whatever the number says: solo, the client can leave you
    -- off the list (or give no number) while the mob beats on you. A mob you
    -- are not on the list of, and that is not on you, is 0%.
    if not meFighting and not me then return Why(unit, "you are out of combat and not on its list") end
    local pct = me and math.floor(me.pct + 0.5) or 0
    local reason = me and ("your %, " .. via) or "not on its list"
    if pct < 100 then
        local okS, status = pcall(_G.UnitThreatSituation, "player", mob)
        status = okS and ns.Num(status) or nil
        if (me and me.tanking) or status == 2 or status == 3
                or Bool(_G.UnitIsUnit, mob .. "target", "player") then
            pct = 100
            reason = "the mob is on you"
        elseif not me then
            -- Left off the list because the number is secret: hand it on as it
            -- is, since a secret can't be rounded or pick its own color.
            local secret = SecretOwnPct(mob)
            if not ns.IsSecret(secret) and alias then secret = SecretOwnPct(unit) end
            if ns.IsSecret(secret) then
                Why(unit, "your % is secret " .. via)
                return nil, 1, 1, 1, secret
            end
            if status == 1 then
                -- Past the tank, no number to say by how much.
                Why(unit, "past the tank, no number")
                return "high", NumberColor(100)
            end
            if fighting == nil then
                -- Not on its list, and the game won't say whether it is in the
                -- fight: nothing, rather than 0% on every mob around.
                return Why(unit, "not on its list, and the game won't say whether it is in the fight")
            end
        end
    end
    Why(unit, reason)
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
        -- A font that did not take leaves the string with none, and SetText
        -- then throws: check it is there, not just that the call returned.
        local okF, took = pcall(text.SetFont, text, "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        local okG, font = pcall(text.GetFont, text)
        if not (okF and took ~= false and okG and font) then text:SetFontObject("GameFontHighlightSmall") end
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

-- A secret % as a thin bar along the top of the health bar, for a client that
-- won't print it. Three status bars side by side, one per color band (green to
-- 70, amber to 90, red to 100), each handed the secret as it is and clamping
-- it the way the combo pips do, so the fill and its color are exact without
-- the number ever being read. nil hides it. True when it drew.
local BANDS = {
    { 0, 70, 0.4, 1, 0.4 },
    { 70, 90, 1, 0.75, 0.2 },
    { 90, 100, 1, 0.25, 0.2 },
}
local BAR_H = 3

local function SecretBar(label, secret)
    if not ns.IsSecret(secret) then
        if label.bands then
            for _, band in ipairs(label.bands) do band:Hide() end
        end
        return false
    end
    if not label.bands then
        label.bands = {}
        for i, b in ipairs(BANDS) do
            local band = CreateFrame("StatusBar", nil, label.frame)
            band:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            band:SetStatusBarColor(b[3], b[4], b[5])
            band:SetMinMaxValues(b[1], b[2])
            local back = band:CreateTexture(nil, "BACKGROUND")
            back:SetAllPoints()
            back:SetColorTexture(0, 0, 0, 0.6)
            label.bands[i] = band
        end
    end
    local okW, width = pcall(label.frame.GetWidth, label.frame)
    width = okW and ns.Num(width) or 0
    if width <= 0 then width = 110 end
    local x = 0
    local drew = true
    for i, b in ipairs(BANDS) do
        local band = label.bands[i]
        local w = width * (b[2] - b[1]) / 100
        band:ClearAllPoints()
        band:SetPoint("TOPLEFT", label.frame, "TOPLEFT", x, 0)
        band:SetSize(w, BAR_H)
        x = x + w
        if not pcall(band.SetValue, band, secret) then drew = false end
        band:Show()
    end
    if not drew then
        for _, band in ipairs(label.bands) do band:Hide() end
    end
    return drew
end

local function ShowText(unit)
    local label = Label(unit)
    if not label then return end
    local text, r, g, b, secret
    if ns.IsEnabled("npThreatText") then
        local ok, t, rr, gg, bb, sp = pcall(ns.NameplateThreatText, unit)
        if ok then text, r, g, b, secret = t, rr, gg, bb, sp end
    end
    SecretBar(label, nil)
    if text then
        label.text:SetText(text)
        label.text:SetTextColor(r or 1, g or 1, b or 1)
        label.text:Show()
        label.frame:Show()
    elseif ns.IsSecret(secret) then
        -- A secret as text, if the client will print it; if not, as a bar,
        -- which takes a secret the way the combo pips do.
        local shown = pcall(label.text.SetFormattedText, label.text, "%d%%", secret)
            or pcall(function() label.text:SetText(string.format("%d%%", secret)) end)
        if shown then
            label.text:SetTextColor(r or 1, g or 1, b or 1)
            label.text:Show()
            whyByUnit[unit] = (whyByUnit[unit] or "") .. " (drawn as text)"
        else
            label.text:Hide()
            shown = SecretBar(label, secret)
            whyByUnit[unit] = (whyByUnit[unit] or "") .. (shown and " (drawn as a bar: the game won't print it)"
                or " (the game refused both the text and the bar)")
        end
        if shown then label.frame:Show() else label.frame:Hide() end
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
        .. "your own threat on every mob in the fight.",
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

-------------------------------------------------------------------------------
-- Combo points on the target's nameplate
-------------------------------------------------------------------------------
-- A rogue's combo points as a row of pips along the bottom of the target's
-- plate health bar.
--
-- Power reads come back secret on this client, and a secret cannot be
-- compared or printed. So nothing here does either: each pip is its own
-- status bar spanning one point (pip 3 runs from 2 to 3) and is handed the
-- count as it is. The bar clamps it, so pip 3 is full at 3 or more and empty
-- at 2 or less -- exact, secret or not.

local PIP_H, PIP_GAP = 4, 2
local combos = {}      -- nameplate frame -> { frame, pips }
ns.npComboPips = combos   -- for the tests
local comboDriver

local ENERGY = 3   -- Enum.PowerType.Energy, where the enum is missing

-- Who has combo points right now: a rogue always, a druid in Cat Form. Cat
-- Form is the druid's energy form, so the power type says so without form
-- numbers, which differ between clients. False comes with the reason.
local function ComboClass()
    local ok, _, class = pcall(_G.UnitClass, "player")
    class = ok and ns.Text(class) or nil
    if class == "ROGUE" then return true end
    if class == "DRUID" then
        local enum = _G.Enum and _G.Enum.PowerType
        local energy = (enum and ns.Num(enum.Energy)) or ENERGY
        local okP, powerType = pcall(_G.UnitPowerType, "player")
        if okP and ns.Num(powerType) == energy then return true end
        return false, "a druid out of Cat Form"
    end
    return false, "not a rogue or druid"
end
ns.NameplateComboClass = ComboClass

local COMBO_POWER = 4   -- Enum.PowerType.ComboPoints, where the enum is missing

local function ComboPower()
    local enum = _G.Enum and _G.Enum.PowerType
    return (enum and ns.Num(enum.ComboPoints)) or COMBO_POWER
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, n = pcall(fn, ...)
    if ok and type(n) == "number" then return n end
    return nil
end

-- The count, secret or plain, and which call gave it. The classic call first:
-- there the points sit on the target. A plain 0 from it is not the last word,
-- since on this engine the points can live on the player instead: then the
-- player's combo power answers, if it has anything (or will not say).
function ns.ComboPointCount()
    local classic = Call(_G.GetComboPoints, "player", "target")
    local classicPlain = classic and ns.Num(classic)
    if classic and classicPlain ~= 0 then return classic, "GetComboPoints" end
    local power = Call(_G.UnitPower, "player", ComboPower())
    local powerPlain = power and ns.Num(power)
    if power and powerPlain ~= 0 then return power, "UnitPower" end
    if classic then return classic, "GetComboPoints" end
    if power then return power, "UnitPower" end
    return nil
end

local function ComboMax()
    local ok, n = pcall(_G.UnitPowerMax, "player", ComboPower())
    n = ok and ns.Num(n) or nil
    if not n or n < 1 then return 5 end
    return math.min(math.floor(n), 10)
end

local function Pips(plate, bar)
    local combo = combos[plate]
    if not combo then
        local frame = CreateFrame("Frame", nil, plate)
        combo = { frame = frame, pips = {} }
        combos[plate] = combo
    end
    combo.frame:SetFrameLevel((ns.Num(bar:GetFrameLevel()) or 1) + 6)
    combo.frame:ClearAllPoints()
    combo.frame:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    combo.frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    combo.frame:SetHeight(PIP_H)
    return combo
end

local function LayOut(combo, bar, count)
    local okW, width = pcall(bar.GetWidth, bar)
    width = okW and ns.Num(width) or 0
    if width <= 0 then width = 110 end
    local size = (width - PIP_GAP * (count - 1)) / count
    for i = 1, math.max(count, #combo.pips) do
        local pip = combo.pips[i]
        if i <= count then
            if not pip then
                pip = CreateFrame("StatusBar", nil, combo.frame)
                pip:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
                pip:SetStatusBarColor(1, 0.82, 0.1)
                local back = pip:CreateTexture(nil, "BACKGROUND")
                back:SetAllPoints()
                back:SetColorTexture(0, 0, 0, 0.6)
                combo.pips[i] = pip
            end
            pip:SetMinMaxValues(i - 1, i)
            pip:ClearAllPoints()
            pip:SetPoint("BOTTOMLEFT", combo.frame, "BOTTOMLEFT", (i - 1) * (size + PIP_GAP), 0)
            pip:SetSize(size, PIP_H)
            pip:Show()
        elseif pip then
            pip:Hide()
        end
    end
end

local function HideCombos()
    for _, combo in pairs(combos) do combo.frame:Hide() end
end

-- Why the pips last did or did not show, for /chair threat combo.
local comboWhy = "not run yet"

local function ShowCombo()
    HideCombos()
    if not ns.IsEnabled("npComboPoints") then comboWhy = "switched off" return end
    local fits, whyNot = ComboClass()
    if not fits then comboWhy = whyNot return end
    if not Bool(_G.UnitExists, "target") then comboWhy = "no target" return end
    -- Only a plain "no" stops it: a client that will not say is let through.
    if Bool(_G.UnitCanAttack, "player", "target") == false then comboWhy = "target is friendly" return end
    local plate = Plate("target")
    if not plate then comboWhy = "no nameplate for the target (plates off, or a protected one)" return end
    local bar = HealthBar("target")
    if not bar then comboWhy = "the target's nameplate has no health bar I can find" return end
    local combo = Pips(plate, bar)
    local count = ComboMax()
    LayOut(combo, bar, count)
    local points = ns.ComboPointCount() or 0
    local failed
    for i = 1, count do
        -- The count straight in: see above.
        local ok, err = pcall(combo.pips[i].SetValue, combo.pips[i], points)
        if not ok and not failed then failed = ns.Text(err) or "refused" end
    end
    combo.frame:Show()
    comboWhy = failed and ("shown, but the pips refused the count: " .. failed)
        or ("shown, " .. count .. " pips")
end
ns.ShowNameplateCombo = ShowCombo

local function OnComboEvent(_, event, unit)
    if (event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER"
            or event == "UNIT_DISPLAYPOWER") and unit ~= "player" then
        return
    end
    ShowCombo()
end

local COMBO_EVENTS = { "PLAYER_TARGET_CHANGED", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
                       "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER",
                       "PLAYER_ENTERING_WORLD",
                       -- A druid shifting in or out of Cat Form.
                       "UPDATE_SHAPESHIFT_FORM", "UNIT_DISPLAYPOWER",
                       -- The older clients' own event, where it still exists.
                       "UNIT_COMBO_POINTS" }

-- /chair threat combo: what each call says, and why the pips did or did not
-- show. Run it with a target and a few points up.
function ns.ProbeCombo()
    ShowCombo()
    local function Say(n)
        if type(n) ~= "number" then return "nothing" end
        local plain = ns.Num(n)
        return plain and tostring(plain) or "secret"
    end
    ns.Print("Combo points probe:")
    ns.Print("  GetComboPoints(player, target): " .. Say(Call(_G.GetComboPoints, "player", "target")))
    ns.Print("  UnitPower(player, " .. ComboPower() .. "): " .. Say(Call(_G.UnitPower, "player", ComboPower())))
    ns.Print("  UnitPowerMax: " .. Say(Call(_G.UnitPowerMax, "player", ComboPower())))
    local _, from = ns.ComboPointCount()
    ns.Print("  using: " .. (from or "neither"))
    ns.Print("  pips: " .. comboWhy)
end

ns.RegisterModule("npComboPoints", {
    title = "Combo points on nameplates",
    desc = "Rogues, and druids in Cat Form: your combo points as pips along the bottom of your target's nameplate health bar.",
    Apply = function(enabled)
        if not comboDriver then
            comboDriver = CreateFrame("Frame")
            comboDriver:SetScript("OnEvent", OnComboEvent)
        end
        for _, event in ipairs(COMBO_EVENTS) do
            if enabled then
                pcall(comboDriver.RegisterEvent, comboDriver, event)
            else
                pcall(comboDriver.UnregisterEvent, comboDriver, event)
            end
        end
        ShowCombo()
    end,
})
