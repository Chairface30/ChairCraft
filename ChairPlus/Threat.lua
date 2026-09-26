-- ChairPlus Threat.lua
-- Everyone's threat on your current target, as a short list of bars.
--
-- When it shows is up to the Threat page of the menu: by group (solo, party,
-- raid), by place (world, dungeon, raid, battleground), in or out of combat,
-- and only once your own threat is past a line. Out of the box it is what it
-- always was -- in a group, in combat, with a target you can attack.
--
-- Locking and click-through are separate. Locked means it cannot be dragged or
-- resized; click-through means the mouse passes straight through it to the
-- world, always or only in combat. A locked meter that still takes the mouse
-- answers a right-click by opening its options.
--
-- UnitDetailedThreatSituation is asked once per group member (and pet) per
-- refresh. Plater calls it on this client, so it exists; if a build ever drops
-- it the module says so once and stays dark rather than erroring every tick.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local TICK = 0.5
local PAD = 4
local TITLE_H = 20
local MIN_W, MAX_W = 120, 600
local MIN_ROWS, MAX_ROWS = 1, 40

local frame, title, bg, grip
local rows = {}
local elapsed = 0
local warnedMissing = false
local warned = false
local lastWanted
local sizing = false
local wasLocked
local reported = {}

-- Session only: the menu's Preview button. Not saved, because a meter stuck
-- showing sample bars after a reload is a bug report waiting to happen.
ns.threatPreview = false

local function Clamp(v, lo, hi)
    v = ns.Num(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Now()
    local ok, t = pcall(_G.GetTime)
    return ok and ns.Num(t) or 0
end

-- Combat as the regen events see it, which is what click-through listens to.
local function InCombat()
    if type(_G.InCombatLockdown) == "function" then
        local ok, locked = pcall(_G.InCombatLockdown)
        return (ok and locked) and true or false
    end
    local okC, fighting = pcall(_G.UnitAffectingCombat, "player")
    return (okC and fighting) and true or false
end

-------------------------------------------------------------------------------
-- Reading threat
-------------------------------------------------------------------------------

local function Units()
    local pets = ns.Get("threatShowPets")
    local units = {}
    local okRaid, inRaid = pcall(_G.IsInRaid)
    if okRaid and inRaid then
        for i = 1, 40 do
            units[#units + 1] = "raid" .. i
            if pets then units[#units + 1] = "raidpet" .. i end
        end
    else
        units[#units + 1] = "player"
        if pets then units[#units + 1] = "pet" end
        for i = 1, 4 do
            units[#units + 1] = "party" .. i
            if pets then units[#units + 1] = "partypet" .. i end
        end
    end
    return units
end

local function IsMe(unit)
    if unit == "player" then return true end
    local ok, same = pcall(_G.UnitIsUnit, unit, "player")
    return (ok and same) and true or false
end

-- One sorted list of { name, pct, tanking, status, class, isMe }, highest
-- first, for threat on `mob` (the target unless told otherwise).
function ns.ThreatRows(mob)
    mob = mob or "target"
    local detailed = _G.UnitDetailedThreatSituation
    if type(detailed) ~= "function" then return nil, "missing" end

    local out = {}
    for _, unit in ipairs(Units()) do
        local okE, exists = pcall(_G.UnitExists, unit)
        if okE and exists then
            local ok, tanking, status, scaledPct = pcall(detailed, unit, mob)
            local pct = ok and ns.Num(scaledPct) or nil
            if pct then
                local okN, name = pcall(_G.UnitName, unit)
                local okC, _, class = pcall(_G.UnitClass, unit)
                out[#out + 1] = {
                    -- Display only: a name can come back secret, and a secret
                    -- cannot be compared, so nothing sorts or tests by it.
                    name = (okN and ns.DisplayText(name)) or unit,
                    order = #out + 1,
                    pct = pct,
                    tanking = (ok and tanking) and true or false,
                    status = ok and ns.Num(status) or 0,
                    class = okC and ns.Text(class) or nil,
                    isMe = IsMe(unit),
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        return a.order < b.order
    end)
    return out
end

local function Hostile(unit)
    local okT, exists = pcall(_G.UnitExists, unit)
    if not (okT and exists) then return false end
    local okA, attackable = pcall(_G.UnitCanAttack, "player", unit)
    return (okA and attackable) and true or false
end

-- The mob whose threat is shown: your target, or -- for a healer with the tank
-- targeted -- what your target is fighting.
function ns.ThreatUnit()
    if Hostile("target") then return "target" end
    if ns.Get("threatTargetTarget") and Hostile("targettarget") then
        return "targettarget"
    end
    return nil
end

local ZONE_KEYS = {
    none = "threatWorld",
    party = "threatDungeon",
    scenario = "threatDungeon",
    raid = "threatRaidZone",
    pvp = "threatPvP",
    arena = "threatPvP",
}

-- Whether the meter should be up at all, and on which mob.
function ns.ThreatWanted()
    local okI, inInstance, kind = pcall(_G.IsInInstance)
    kind = (okI and inInstance) and ns.Text(kind) or "none"
    if not ns.Get(ZONE_KEYS[kind] or "threatWorld") then return false end

    local okR, inRaid = pcall(_G.IsInRaid)
    local okG, inGroup = pcall(_G.IsInGroup)
    if okR and inRaid then
        if not ns.Get("threatRaid") then return false end
    elseif okG and inGroup then
        if not ns.Get("threatParty") then return false end
    elseif not ns.Get("threatSolo") then
        return false
    end

    local okC, fighting = pcall(_G.UnitAffectingCombat, "player")
    fighting = (okC and fighting) and true or false
    if not fighting and not ns.Get("threatOutOfCombat") then return false end

    -- Out of combat the meter is asked to stay up, so it does, with or without
    -- a target: a mob nobody is fighting has no threat list at all, and waiting
    -- for one would mean it never showed. The third return says so, so that
    -- the in-combat filters (nobody on it yet, my threat under the line) do not
    -- hide it again.
    local unit = ns.ThreatUnit()
    if not unit and fighting then return false end
    return true, unit, not fighting
end

-- Stand-in bars for arranging the meter when there is no fight to show.
local SAMPLE = {
    { "Tank", 100, "WARRIOR", 3 }, { nil, 82, nil, 1 }, { "Rogue", 64, "ROGUE", 1 },
    { "Mage", 51, "MAGE", 0 }, { "Healer", 38, "PRIEST", 0 }, { "Hunter", 27, "HUNTER", 0 },
    { "Warlock", 20, "WARLOCK", 0 }, { "Druid", 12, "DRUID", 0 },
    { "Shaman", 8, "SHAMAN", 0 }, { "Paladin", 5, "PALADIN", 0 },
}

local function SampleRows(count)
    local okN, me = pcall(_G.UnitName, "player")
    local okC, _, myClass = pcall(_G.UnitClass, "player")
    local out = {}
    for i = 1, count do
        local s = SAMPLE[i]
        if s then
            out[i] = {
                name = s[1] or (okN and ns.Text(me)) or "You",
                pct = s[2],
                tanking = (i == 1),
                status = s[4],
                class = s[3] or (okC and ns.Text(myClass)) or nil,
                isMe = (s[1] == nil),
            }
        else
            out[i] = { name = "Raider " .. i, pct = math.max(1, 5 - (i - 10) * 0.4),
                       tanking = false, status = 0 }
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

local STATUS_COLOURS = {
    [0] = { 0.69, 0.69, 0.69 },
    [1] = { 1, 1, 0.47 },
    [2] = { 1, 0.6, 0 },
    [3] = { 1, 0, 0 },
}

local function BarColour(entry)
    if ns.Get("threatClassColours") then
        local colours = _G.RAID_CLASS_COLORS
        local c = entry.class and colours and colours[entry.class]
        if c then return c.r, c.g, c.b end
        return 0.6, 0.6, 0.6
    end
    local status = ns.Num(entry.status) or 0
    local ok, r, g, b = pcall(_G.GetThreatStatusColor, status)
    r, g, b = ns.Num(r), ns.Num(g), ns.Num(b)
    if ok and r and g and b then return r, g, b end
    local c = STATUS_COLOURS[status] or STATUS_COLOURS[0]
    return c[1], c[2], c[3]
end

local function HeaderH()
    return ns.Get("threatShowTitle") and TITLE_H or PAD
end

local function RowH()
    return Clamp(ns.Get("threatRowHeight"), 10, 40)
end

local function Width()
    return Clamp(ns.Get("threatWidth"), MIN_W, MAX_W)
end

local function MaxRows()
    return math.floor(Clamp(ns.Get("threatMaxRows"), MIN_ROWS, MAX_ROWS))
end

local function SetFontSize(fs, size)
    local ok, font, _, flags = pcall(fs.GetFont, fs)
    if ok and type(font) == "string" then
        pcall(fs.SetFont, fs, font, size, flags)
    end
end

local function Row(i)
    if rows[i] then return rows[i] end
    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 100)
    local back = bar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 0.5)
    bar.name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.name:SetPoint("LEFT", 4, 0)
    bar.name:SetJustifyH("LEFT")
    bar.value = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.value:SetPoint("RIGHT", -4, 0)
    rows[i] = bar
    return bar
end

local function UpdateMouse()
    if not frame then return end
    local mouse
    if not ns.Get("threatLocked") then
        mouse = true            -- it has to take the mouse to be dragged
    elseif ns.Get("threatClickThrough") then
        mouse = false
    elseif ns.Get("threatClickThroughCombat") and InCombat() then
        mouse = false
    else
        mouse = true
    end
    frame:EnableMouse(mouse)
end

-- Your threat against the warning line. Fires once per climb: it re-arms when
-- you drop well back below the line or change target.
local function Warn(list)
    if not ns.Get("threatWarn") then
        warned = false
        return
    end
    local me
    for _, entry in ipairs(list) do
        if entry.isMe then me = entry break end
    end
    local at = Clamp(ns.Get("threatWarnAt"), 50, 130)
    if not me or me.tanking then
        warned = false
        return
    end
    if me.pct >= at then
        if warned then return end
        warned = true
        local text = string.format("Threat %d%% -- ease off!", math.floor(me.pct + 0.5))
        local errors = _G.UIErrorsFrame
        if not (errors and pcall(errors.AddMessage, errors, text, 1, 0.1, 0.1)) then
            ns.Print("|cffff5555" .. text .. "|r")
        end
        if ns.Get("threatWarnSound") then ns.PlayThreatWarning() end
    elseif me.pct < at - 10 then
        warned = false
    end
end

-- The warning's sound: the one picked from the auras' sound list, or the
-- raid warning when none has been. Played through the auras' player, which
-- knows the difference between a sound ID and a file.
local warningHandle

function ns.PlayThreatWarning()
    ns.StopThreatWarning()
    local chosen = ns.Get("threatWarnSoundID")
    local sounds = Chaircraft.ChairAuras and Chaircraft.ChairAuras.Sounds
    if type(chosen) == "string" and chosen ~= "" and sounds and sounds.Play then
        local ok, played, handle = pcall(sounds.Play, sounds, chosen, "Master")
        if ok and played then
            warningHandle = handle
            return
        end
    end
    local kit = _G.SOUNDKIT
    local ok, _, handle = pcall(_G.PlaySound, (kit and kit.RAID_WARNING) or 8959)
    if ok then warningHandle = handle end
end

-- Cut the warning off, for the long ones in the list.
function ns.StopThreatWarning()
    if warningHandle ~= nil and type(_G.StopSound) == "function" then
        pcall(_G.StopSound, warningHandle)
    end
    warningHandle = nil
end

local function Draw(list, heading, mobName)
    local limit = MaxRows()
    local shown = math.min(#list, limit)

    -- Your own bar stays on the meter even when it would fall off the bottom,
    -- since it is the one you are here to read.
    if ns.Get("threatAlwaysMe") and shown > 0 and #list > shown then
        local mine
        for i = shown + 1, #list do
            if list[i].isMe then mine = list[i] break end
        end
        if mine then list[shown] = mine end
    end

    local width, rowH, headerH = Width(), RowH(), HeaderH()
    local fontSize = math.max(8, math.min(18, rowH - 4))
    for i = 1, shown do
        local entry, bar = list[i], Row(i)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", PAD, -headerH - (i - 1) * rowH)
        bar:SetSize(width - PAD * 2, rowH - 2)
        bar:SetValue(math.min(100, entry.pct))
        bar:SetStatusBarColor(BarColour(entry))
        SetFontSize(bar.name, fontSize)
        SetFontSize(bar.value, fontSize)
        -- The concat is inside the pcall too: the name may be secret.
        local okName = pcall(function()
            bar.name:SetText((entry.tanking and "|cffff5555>|r " or "") .. entry.name)
        end)
        if not okName then pcall(bar.name.SetText, bar.name, entry.name) end
        bar.value:SetText(string.format("%d%%", math.floor(entry.pct + 0.5)))
        bar:Show()
    end
    for i = shown + 1, #rows do rows[i]:Hide() end

    -- The mob's name may be secret, so it is joined on inside the pcall, and
    -- the plain heading stands in if even that fails.
    local okTitle = mobName and pcall(function()
        title:SetText(heading .. ": " .. mobName)
    end)
    if not okTitle then pcall(title.SetText, title, heading) end
    if not sizing then
        frame:SetSize(width, headerH + math.max(shown, 1) * rowH + PAD)
    end
    frame:Show()
end

local function Refresh()
    if not frame then return end
    UpdateMouse()
    -- Sample bars come from the preview flag alone. Unlocking switches it on
    -- and locking switches it off (see Apply), but Preview can still turn it
    -- off while unlocked -- it used to be forced on by the lock, which is why
    -- pressing End preview on an unlocked meter did nothing.
    local previewing = ns.threatPreview
    local unlocked = not ns.Get("threatLocked")

    local wanted, mob, idle = ns.ThreatWanted()
    if not wanted then
        if previewing then
            Draw(SampleRows(MaxRows()),
                unlocked and "Threat (drag me)" or "Threat (preview)")
            return
        end
        -- Unlocked with no preview: an empty meter, still there to be dragged.
        if unlocked then
            Draw({}, "Threat (drag me)")
            return
        end
        -- Linger: stay up a few seconds after the fight, so the meter does not
        -- blink out the moment the last mob drops.
        local linger = Clamp(ns.Get("threatLinger"), 0, 30)
        if frame:IsShown() and lastWanted and (Now() - lastWanted) < linger then return end
        frame:Hide()
        return
    end
    lastWanted = Now()

    local list, why
    if mob then
        list, why = ns.ThreatRows(mob)
    else
        list = {}     -- out of combat with nothing targeted
    end
    if not list then
        if why == "missing" and not warnedMissing then
            warnedMissing = true
            ns.Print("|cffff5555Threat meter:|r this client has no "
                .. "UnitDetailedThreatSituation, so there is nothing to show.")
        end
        frame:Hide()
        return
    end

    Warn(list)

    if not (previewing or unlocked or idle) then
        if #list == 0 and not ns.Get("threatShowEmpty") then
            frame:Hide()
            return
        end
        local above = Clamp(ns.Get("threatShowAbove"), 0, 100)
        if above > 0 then
            local mine = 0
            for _, entry in ipairs(list) do
                if entry.isMe then mine = entry.pct break end
            end
            if mine < above then
                frame:Hide()
                return
            end
        end
    elseif #list == 0 and previewing then
        list = SampleRows(MaxRows())
    end

    local mobName
    if mob then
        local okN, name = pcall(_G.UnitName, mob)
        mobName = okN and ns.DisplayText(name) or nil
    end
    Draw(list, "Threat", mobName)
end

-- Refresh runs inside a pcall so one bad tick cannot take the meter down, but
-- a swallowed error is how a bug hides on the real client while the harness
-- stays green. So each distinct error is printed once.
local function SafeRefresh()
    local ok, err = pcall(Refresh)
    if ok then return end
    local text = ns.Text(err) or "unknown error"
    if reported[text] then return end
    reported[text] = true
    ns.Print("|cffff5555Threat meter error:|r", text)
end

-------------------------------------------------------------------------------
-- Position and size
-------------------------------------------------------------------------------
-- The saved point is always the edge that should stay still: the top edge
-- normally, the bottom edge when the meter grows upward. Otherwise a meter
-- placed near the bottom of the screen would grow down off it, and one placed
-- after a fight with five bars would come back a reload later somewhere else.

local function CurrentSpot()
    local growUp = ns.Get("threatGrowUp")
    local left = ns.Num(frame:GetLeft())
    local edge = ns.Num(growUp and frame:GetBottom() or frame:GetTop())
    if left and edge then
        if growUp then
            return { threatAnchor = "BOTTOMLEFT", threatRelAnchor = "BOTTOMLEFT",
                     threatX = left, threatY = edge }
        end
        local uiTop = ns.Num(UIParent:GetTop())
        local okS, fs = pcall(frame.GetEffectiveScale, frame)
        local okU, us = pcall(UIParent.GetEffectiveScale, UIParent)
        fs, us = okS and ns.Num(fs) or 1, okU and ns.Num(us) or 1
        if uiTop then
            local ratio = (fs and fs > 0) and (us / fs) or 1
            return { threatAnchor = "TOPLEFT", threatRelAnchor = "TOPLEFT",
                     threatX = left, threatY = edge - uiTop * ratio }
        end
    end
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if type(point) ~= "string" then return nil end
    return {
        threatAnchor = point,
        threatRelAnchor = type(relPoint) == "string" and relPoint or point,
        threatX = ns.Num(x) or 0,
        threatY = ns.Num(y) or 0,
    }
end

local function SavePosition()
    local spot = CurrentSpot()
    if spot then ns.SetMany(spot) end
end

local function ApplyPosition()
    frame:ClearAllPoints()
    local ok = pcall(frame.SetPoint, frame, ns.Get("threatAnchor") or "TOP", UIParent,
        ns.Get("threatRelAnchor") or "TOP",
        ns.Num(ns.Get("threatX")) or 0, ns.Num(ns.Get("threatY")) or -230)
    if not ok then
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", 0, -230)
    end
end

-- After a grow-direction change or a reset, re-save the spot by the edge that
-- should now hold still. Written straight into the settings rather than
-- through SetMany: the frame is already where it should be, and this runs
-- from inside Apply, where re-applying everything would be a loop.
local function Normalise()
    local anchor = ns.Get("threatAnchor") or ""
    local bottom = anchor:find("^BOTTOM") ~= nil
    if bottom == (ns.Get("threatGrowUp") and true or false) then return end
    local spot = CurrentSpot()
    if not spot or spot.threatAnchor == anchor then return end
    for key, value in pairs(spot) do
        ns.settings[key] = value
        if ns.saved then ns.saved[key] = value end
    end
    ApplyPosition()
end

local function StopSizing()
    if not sizing then return end
    sizing = false
    frame:StopMovingOrSizing()
    local w = ns.Num(frame:GetWidth())
    local h = ns.Num(frame:GetHeight())
    local values = CurrentSpot() or {}
    if w then values.threatWidth = math.floor(Clamp(w, MIN_W, MAX_W) + 0.5) end
    if h then
        values.threatMaxRows = math.floor(Clamp(
            (h - HeaderH() - PAD) / RowH() + 0.5, MIN_ROWS, MAX_ROWS))
    end
    ns.SetMany(values)
end

-- The event frame lives apart from the display, so the meter can hide itself
-- and still hear the combat that should bring it back.
local driver

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "ChairPlusThreat", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetSize(Width(), 40)
    bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.75)
    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 6, -4)
    title:SetPoint("TOPRIGHT", -6, -4)
    title:SetJustifyH("LEFT")
    title:SetText("Threat")

    frame:SetScript("OnDragStart", function(self)
        if ns.Get("threatLocked") then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    -- Locked but not click-through: a right-click is the way to its options.
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and ns.OpenPanel then ns.OpenPanel("threat") end
    end)
    frame:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        pcall(function()
            tip:SetOwner(self, "ANCHOR_TOP")
            tip:AddLine("Threat meter")
            if not ns.Get("threatLocked") then
                tip:AddLine("Drag to move, drag the corner to resize.", 1, 1, 1)
            end
            tip:AddLine("Right-click for options.", 1, 1, 1)
            tip:Show()
        end)
    end)
    frame:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if tip then pcall(tip.Hide, tip) end
    end)

    -- The corner grip. Dragging it sets the width and how many bars fit.
    grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        if ns.Get("threatLocked") then return end
        sizing = true
        local ok = pcall(frame.StartSizing, frame,
            ns.Get("threatGrowUp") and "TOPRIGHT" or "BOTTOMRIGHT")
        if not ok then sizing = false end
    end)
    grip:SetScript("OnMouseUp", StopSizing)
    grip:SetScript("OnHide", StopSizing)

    driver = CreateFrame("Frame")
    driver:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_TARGET_CHANGED" then warned = false end
        SafeRefresh()
    end)
    driver:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (ns.Num(dt) or 0)
        if elapsed < TICK then return end
        elapsed = 0
        SafeRefresh()
    end)
end

local EVENTS = {
    "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE",
    "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ZONE_CHANGED_NEW_AREA", "UNIT_TARGET",
}

ns.RegisterModule("threat", {
    title = "Threat meter",
    desc = "Every group member's threat on your target, while in combat.",
    Apply = function(enabled)
        if not enabled then
            if driver then
                driver:UnregisterAllEvents()
                driver:Hide()
            end
            if frame then frame:Hide() end
            return
        end
        Build()
        local locked = ns.Get("threatLocked") and true or false
        -- Unlocking is for placing and sizing, which needs bars to see; locking
        -- again puts the samples away.
        if wasLocked ~= nil and wasLocked ~= locked then ns.threatPreview = not locked end
        wasLocked = locked
        pcall(frame.SetScale, frame, Clamp(ns.Get("threatScale"), 0.5, 3))
        frame:SetAlpha(Clamp(ns.Get("threatAlpha"), 0.1, 1))
        bg:SetColorTexture(0.05, 0.05, 0.07, Clamp(ns.Get("threatBgAlpha"), 0, 1))
        title:SetShown(ns.Get("threatShowTitle") and true or false)
        frame:SetMovable(true)
        pcall(frame.SetResizable, frame, true)
        if frame.SetResizeBounds then
            pcall(frame.SetResizeBounds, frame, MIN_W, 24, MAX_W, 1200)
        else
            pcall(frame.SetMinResize, frame, MIN_W, 24)
            pcall(frame.SetMaxResize, frame, MAX_W, 1200)
        end
        if locked then frame:RegisterForDrag() else frame:RegisterForDrag("LeftButton") end
        grip:ClearAllPoints()
        grip:SetPoint(ns.Get("threatGrowUp") and "TOPRIGHT" or "BOTTOMRIGHT")
        grip:SetShown(not locked)
        ApplyPosition()
        pcall(Normalise)
        for _, event in ipairs(EVENTS) do pcall(driver.RegisterEvent, driver, event) end
        driver:Show()
        SafeRefresh()
    end,
})

function ns.RefreshThreat() SafeRefresh() end

function ns.SetThreatPreview(on)
    ns.threatPreview = on and true or false
    SafeRefresh()
end
