-- ChairPlus QueuedCost.lua
-- An on-next-swing ability's cost shown on the Personal Resource Display.
--
-- Queue Heroic Strike and the last 15 rage of the power bar lights up: the
-- rage the swing will take. Cancel the queue, or let the swing land, and it
-- goes away. Cleave, Maul and Raptor Strike the same.
--
-- The player's power is secret on this client, so it is never read. The
-- highlight is a texture pinned to the end of the bar's own fill texture and
-- stretching back from it by cost / max of the bar's width: the client draws
-- the fill from the secret value, and the highlight just follows its edge.
-- With less power than the cost it would reach past the start of the bar, so
-- it sits in a frame that clips its children to the bar.
--
-- The max is read when the client allows it; for rage it is 100 when it does
-- not. Mana (Raptor Strike) shows nothing while the max can't be read.
--
-- What is queued: IsCurrentSpell on every rank's spell ID, the same thing
-- that lights the action button. Should that be kept secret, the action bars
-- are searched for a button that is lit and holds one of these abilities.
-- CURRENT_SPELL_CAST_CHANGED fires on queueing, cancelling and the swing; a
-- short check while the highlight is up catches a missed event.
--
-- Only a texture of our own is added, inside a frame of our own. Nothing of
-- the display's is called but reads (its fill texture, width and min/max).

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local RAGE = 1   -- Enum.PowerType, where the enum is missing

-- Every rank, and the cost to fall back on when the client won't say.
local ABILITIES = {
    { name = "Heroic Strike", cost = 15, ids = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286 } },
    { name = "Cleave",        cost = 20, ids = { 845, 7369, 11608, 11609, 20569 } },
    { name = "Maul",          cost = 15, ids = { 6807, 6808, 6809, 8972, 9745, 9880, 9881 } },
    { name = "Raptor Strike",            ids = { 2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266 } },
}
local BY_ID, BY_NAME = {}, {}
for _, ability in ipairs(ABILITIES) do
    BY_NAME[ability.name] = ability
    for _, id in ipairs(ability.ids) do BY_ID[id] = ability end
end

local DISPLAY = "PersonalResourceDisplayFrame"
local KEYS = { "PowerBar", "ManaBar", "powerBar", "manabar" }
local RECHECK = 0.2   -- seconds between checks while the highlight is up
local LAST_SLOT = 180

local enabled = false
local driver, clip, mark
local found, foundAs
local queued, queuedBy   -- the spell ID queued, and how it was seen
local drawnWidth         -- the highlight's width when last drawn

local function IsBar(value)
    if type(value) ~= "table" then return false end
    local ok, get = pcall(function() return value.GetStatusBarTexture end)
    return ok and get ~= nil
end

local function Find()
    if found then return found, foundAs end
    local display = _G[DISPLAY]
    if type(display) ~= "table" then return nil end
    for _, key in ipairs(KEYS) do
        local ok, value = pcall(rawget, display, key)
        if ok and IsBar(value) then
            found, foundAs = value, DISPLAY .. "." .. key
            return found, foundAs
        end
    end
    -- Any status bar named like "...Power..." or "...Mana..." that is not the
    -- alternate one, on the display or one level down.
    local function Scan(frame, path, depth)
        for key, value in pairs(frame) do
            if type(key) == "string" and IsBar(value) then
                local lower = key:lower()
                if not lower:find("^alt") and (lower:find("power") or lower:find("mana")) then
                    return value, path .. "." .. key
                end
            end
        end
        if depth > 0 then
            for key, value in pairs(frame) do
                if type(key) == "string" and type(value) == "table" and value ~= frame
                   and type(rawget(value, 0)) == "userdata" then
                    local bar, name = Scan(value, path .. "." .. key, depth - 1)
                    if bar then return bar, name end
                end
            end
        end
    end
    local ok, bar, name = pcall(Scan, display, DISPLAY, 1)
    if ok and bar then found, foundAs = bar, name end
    return found, foundAs
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function SpellName(id)
    local spell = _G.C_Spell
    local name = spell and Call(spell.GetSpellName, id)
    if not name and spell and type(spell.GetSpellInfo) == "function" then
        local info = Call(spell.GetSpellInfo, id)
        name = type(info) == "table" and info.name or nil
    end
    if not name then name = Call(_G.GetSpellInfo, id) end
    return ns.Text(name)
end

-- The queued ability's spell ID, or nil. How it was seen goes in queuedBy.
local function FindQueued()
    local isCurrent = _G.IsCurrentSpell or (_G.C_Spell and _G.C_Spell.IsCurrentSpell)
    if type(isCurrent) == "function" then
        for id in pairs(BY_ID) do
            if ns.Bool(Call(isCurrent, id)) then return id, "IsCurrentSpell" end
        end
    end
    -- A lit action button holding one of them, by ID or by name.
    local isAction, info = _G.IsCurrentAction, _G.GetActionInfo
    if type(isAction) ~= "function" or type(info) ~= "function" then return nil end
    for slot = 1, LAST_SLOT do
        if ns.Bool(Call(isAction, slot)) then
            local ok, kind, id = pcall(info, slot)
            id = ok and ns.Text(kind) == "spell" and ns.Num(id) or nil
            if id and (BY_ID[id] or BY_NAME[SpellName(id) or ""]) then
                return id, "action button " .. slot
            end
        end
    end
    return nil
end

local function PlayerPowerType()
    local ok, powerType = pcall(_G.UnitPowerType, "player")
    return ok and ns.Num(powerType) or nil
end

local function RageType()
    local enum = _G.Enum and _G.Enum.PowerType
    return (enum and ns.Num(enum.Rage)) or RAGE
end

-- What the ability costs, and the power type it costs it in.
local function Cost(id)
    local ability = BY_ID[id] or BY_NAME[SpellName(id) or ""]
    local get = (_G.C_Spell and _G.C_Spell.GetSpellPowerCost) or _G.GetSpellPowerCost
    local costs = Call(get, id)
    if type(costs) == "table" then
        local mine = PlayerPowerType()
        local pick
        pcall(function()
            for _, entry in ipairs(costs) do
                if type(entry) == "table" then
                    pick = pick or entry
                    if mine and ns.Num(entry.type) == mine then pick = entry break end
                end
            end
        end)
        if pick then
            local cost = ns.Num(pick.cost) or ns.Num(pick.minCost)
            if cost and cost > 0 then return cost, ns.Num(pick.type) end
        end
    end
    if ability and ability.cost then return ability.cost, RageType() end
    return nil
end

local function MaxPower(bar, powerType)
    if powerType then
        local max = ns.Num(Call(_G.UnitPowerMax, "player", powerType))
        if max and max > 0 then return max end
    end
    local ok, low, high = pcall(bar.GetMinMaxValues, bar)
    low, high = ok and ns.Num(low), ok and ns.Num(high)
    if low and high and high > low then return high - low end
    if powerType == RageType() then return 100 end
    return nil
end

local function Build(bar)
    if clip and clip:GetParent() == bar then return end
    clip = clip or CreateFrame("Frame")
    clip:SetParent(bar)
    clip:ClearAllPoints()
    clip:SetAllPoints(bar)
    pcall(clip.SetClipsChildren, clip, true)
    pcall(clip.SetFrameLevel, clip, (ns.Num(Call(bar.GetFrameLevel, bar)) or 0) + 2)
    if not mark then
        mark = clip:CreateTexture(nil, "OVERLAY")
        mark:SetColorTexture(1, 1, 1, 0.45)
    end
    clip:Hide()
end

local function Hide()
    if clip then clip:Hide() end
end

-- Draw the highlight for what is queued now, or take it away.
local function Update()
    queued, queuedBy = nil, nil
    if not enabled then Hide() return end
    local bar = Find()
    if not bar then return end
    local id, how = FindQueued()
    if not id then Hide() return end
    local cost, powerType = Cost(id)
    local fill = Call(bar.GetStatusBarTexture, bar)
    local width = ns.Num(Call(bar.GetWidth, bar))
    local max = cost and MaxPower(bar, powerType or PlayerPowerType())
    if not (cost and fill and width and width > 0 and max) then Hide() return end
    queued, queuedBy = id, how
    Build(bar)
    -- The fill grows from the right on a reverse-filled bar: pin to its left.
    local reverse = ns.Bool(Call(bar.GetReverseFill, bar))
    local edge = reverse and "LEFT" or "RIGHT"
    mark:ClearAllPoints()
    mark:SetPoint("TOP" .. edge, fill, "TOP" .. edge)
    mark:SetPoint("BOTTOM" .. edge, fill, "BOTTOM" .. edge)
    drawnWidth = math.max(1, width * math.min(cost / max, 1))
    mark:SetWidth(drawnWidth)
    clip:Show()
end
ns.QueuedCostUpdate = Update

-- For the tests: whether the highlight is up, and how wide.
function ns.QueuedCostState()
    local shown = clip and clip:IsShown() or false
    return shown, shown and drawnWidth or nil, queued
end

local elapsed = 0
local function OnUpdate(_, delta)
    if not (clip and clip:IsShown()) then return end
    elapsed = elapsed + (delta or 0)
    if elapsed < RECHECK then return end
    elapsed = 0
    Update()
end

local function Apply(on)
    enabled = on and true or false
    if enabled and not driver then
        driver = CreateFrame("Frame")
        for _, event in ipairs({ "CURRENT_SPELL_CAST_CHANGED", "ACTIONBAR_UPDATE_STATE",
                                 "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
                                 "PLAYER_TARGET_CHANGED", "EDIT_MODE_LAYOUTS_UPDATED" }) do
            pcall(driver.RegisterEvent, driver, event)
        end
        pcall(driver.RegisterUnitEvent, driver, "UNIT_SPELLCAST_SUCCEEDED", "player")
        pcall(driver.RegisterUnitEvent, driver, "UNIT_DISPLAYPOWER", "player")
        pcall(driver.RegisterUnitEvent, driver, "UNIT_MAXPOWER", "player")
        driver:SetScript("OnEvent", function() Update() end)
        driver:SetScript("OnUpdate", OnUpdate)
    end
    Update()
end

-- /chair plus queued: the bar, what is queued and how it was seen.
function ns.ProbeQueuedCost()
    local bar, name = Find()
    ns.Print("Power bar: " .. (name or ("not found on " .. DISPLAY
        .. " (is the Personal Resource Display turned on?)")))
    Update()
    if queued then
        local cost, powerType = Cost(queued)
        ns.Print(("  queued: %s (%d), seen by %s; cost %s, max %s"):format(
            SpellName(queued) or "?", queued, queuedBy or "?",
            tostring(cost or "unreadable"), tostring(bar and MaxPower(bar, powerType or PlayerPowerType()) or "unreadable")))
    else
        local id, how = FindQueued()
        ns.Print("  queued: " .. (id and ((SpellName(id) or id) .. " by " .. how .. ", but not drawn")
            or "nothing. Queue Heroic Strike and run this again (bind it to a macro to try it in combat)."))
    end
    ns.Print("  option " .. (enabled and "on" or "off"))
end

ns.RegisterModule("queuedCost", {
    title = "Queued ability cost on the resource bar",
    desc = "Heroic Strike, Cleave, Maul or Raptor Strike queued: the power it will take lights up on the Personal Resource Display.",
    Apply = Apply,
})
