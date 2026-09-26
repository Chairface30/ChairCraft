local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Load conditions
-------------------------------------------------------------------------------
-- What WeakAuras calls Load: the question of whether an aura exists at all right
-- now, asked before anything asks whether its trigger is met. An aura that is
-- not loaded draws nothing, costs nothing to evaluate, and leaves no gap in a
-- dynamic group.
--
-- One list, read by three things: the engine tests against it, the options
-- window draws itself from it, and the compactor strips defaults using it. Add a
-- condition here and all three follow.
--
-- Every reader is wrapped. Most of these functions were never covered by the
-- probe, and this client has already removed more globals than it kept -- so a
-- condition whose reader is missing or throws answers "cannot say", and a
-- condition that cannot say never blocks loading. An aura silently missing from
-- the screen is a far worse failure than one that loads when it should not, and
-- the options window greys out what the client cannot answer rather than
-- offering a setting that does nothing.

local Load = {}
ns.Load = Load

-------------------------------------------------------------------------------
-- Guarded readers
-------------------------------------------------------------------------------

local UNKNOWN = {}   -- a unique value meaning "this client could not tell us"
Load.UNKNOWN = UNKNOWN

-- Calls fn(...) and hands back its first return, or UNKNOWN if the function is
-- missing or threw. Secrets are screened the same way everything else in this
-- addon screens them: a value that cannot be read is not a value.
local function Read(fn, ...)
    if type(fn) ~= "function" then return UNKNOWN end
    local ok, value = pcall(fn, ...)
    if not ok then return UNKNOWN end
    return value
end

local function ReadBool(fn, ...)
    local value = Read(fn, ...)
    if value == UNKNOWN then return UNKNOWN end
    return value and true or false
end

local function ReadNumber(fn, ...)
    local value = Read(fn, ...)
    if value == UNKNOWN then return UNKNOWN end
    return ns.SafeNumber(value)
end

local function ReadText(fn, ...)
    local value = Read(fn, ...)
    if value == UNKNOWN then return UNKNOWN end
    return ns.SafeText(value)
end

-------------------------------------------------------------------------------
-- The conditions
-------------------------------------------------------------------------------
-- kind says how the option is stored and drawn:
--   "toggle"  nil = don't care, true = must be so, false = must not be
--   "range"   { min = n, max = n }, either side optional
--   "text"    a string, matched case-insensitively as a substring
--   "set"     { VALUE = true, ... }, any one of them satisfies it
--
-- test(value, ctx) returns true to load. ctx is the table of readings taken once
-- per evaluation, so twenty auras asking "am I in combat" is one call.

local CONDITIONS = {
    {
        key = "never", kind = "toggle", label = "Never load",
        tip = "Switches the aura off without deleting it.",
        test = function(value)
            return not value
        end,
        available = function() return true end,
    },
    {
        key = "combat", kind = "toggle", label = "In combat",
        tip = "Ticked: only while you are in combat. Unticked: only while you are not.",
        read = function(ctx)
            ctx.combat = ReadBool(_G.UnitAffectingCombat, "player")
        end,
        test = function(value, ctx)
            if ctx.combat == UNKNOWN then return true end
            return ctx.combat == value
        end,
    },
    {
        key = "alive", kind = "toggle", label = "Alive",
        tip = "Ticked: only while you are alive. Set to no, only while you are "
           .. "dead or a ghost -- which is how you show a release or a "
           .. "resurrection timer and nothing else.",
        read = function(ctx)
            local dead = ReadBool(_G.UnitIsDeadOrGhost, "player")
            if dead == UNKNOWN then
                -- The same question asked the two older ways, in case this
                -- client kept one of them and not the combined one.
                local isDead = ReadBool(_G.UnitIsDead, "player")
                local isGhost = ReadBool(_G.UnitIsGhost, "player")
                if isDead ~= UNKNOWN or isGhost ~= UNKNOWN then
                    dead = (isDead == true) or (isGhost == true)
                end
            end
            ctx.alive = (dead == UNKNOWN) and UNKNOWN or (not dead)
        end,
        test = function(value, ctx)
            if ctx.alive == UNKNOWN then return true end
            return ctx.alive == value
        end,
    },
    {
        key = "group", kind = "toggle", label = "In a group",
        tip = "Ticked: only in a party or raid. Unticked: only while solo.",
        read = function(ctx)
            ctx.group = ReadBool(_G.IsInGroup)
            if ctx.group == UNKNOWN then
                local members = ReadNumber(_G.GetNumGroupMembers)
                if members ~= UNKNOWN and members then ctx.group = members > 0 end
            end
        end,
        test = function(value, ctx)
            if ctx.group == UNKNOWN then return true end
            return ctx.group == value
        end,
    },
    {
        key = "raid", kind = "toggle", label = "In a raid",
        read = function(ctx) ctx.raid = ReadBool(_G.IsInRaid) end,
        test = function(value, ctx)
            if ctx.raid == UNKNOWN then return true end
            return ctx.raid == value
        end,
    },
    {
        key = "instance", kind = "toggle", label = "In an instance",
        tip = "Dungeon, raid or battleground, as the client reports it.",
        read = function(ctx) ctx.instance = ReadBool(_G.IsInInstance) end,
        test = function(value, ctx)
            if ctx.instance == UNKNOWN then return true end
            return ctx.instance == value
        end,
    },
    {
        key = "resting", kind = "toggle", label = "Resting",
        read = function(ctx) ctx.resting = ReadBool(_G.IsResting) end,
        test = function(value, ctx)
            if ctx.resting == UNKNOWN then return true end
            return ctx.resting == value
        end,
    },
    {
        key = "mounted", kind = "toggle", label = "Mounted",
        read = function(ctx) ctx.mounted = ReadBool(_G.IsMounted) end,
        test = function(value, ctx)
            if ctx.mounted == UNKNOWN then return true end
            return ctx.mounted == value
        end,
    },
    {
        key = "stealthed", kind = "toggle", label = "Stealthed",
        read = function(ctx) ctx.stealthed = ReadBool(_G.IsStealthed) end,
        test = function(value, ctx)
            if ctx.stealthed == UNKNOWN then return true end
            return ctx.stealthed == value
        end,
    },
    {
        key = "hasTarget", kind = "toggle", label = "Have a target",
        read = function(ctx) ctx.hasTarget = ReadBool(_G.UnitExists, "target") end,
        test = function(value, ctx)
            if ctx.hasTarget == UNKNOWN then return true end
            return ctx.hasTarget == value
        end,
    },
    {
        key = "hostileTarget", kind = "toggle", label = "Target is hostile",
        read = function(ctx)
            ctx.hostileTarget = ReadBool(_G.UnitCanAttack, "player", "target")
        end,
        test = function(value, ctx)
            if ctx.hostileTarget == UNKNOWN then return true end
            return ctx.hostileTarget == value
        end,
    },
    {
        key = "class", kind = "set", label = "Class",
        tip = "Loads only on the classes ticked. Nothing ticked means every class.",
        values = function() return ns.Load:ClassList() end,
        read = function(ctx)
            local _, token = pcall(function() return select(2, UnitClass("player")) end)
            ctx.class = ns.SafeText(token)
        end,
        test = function(value, ctx)
            if not next(value) then return true end
            if not ctx.class then return true end
            return value[ctx.class] and true or false
        end,
    },
    {
        key = "race", kind = "set", label = "Race",
        tip = "Loads only on the races ticked. Nothing ticked means every race.",
        values = function() return ns.Load:RaceList() end,
        read = function(ctx)
            local _, token = pcall(function() return select(2, UnitRace("player")) end)
            ctx.race = ns.SafeText(token)
        end,
        test = function(value, ctx)
            if not next(value) then return true end
            -- Unreadable is not a reason to hide an aura; an unknown race
            -- passes rather than blanking the screen.
            if not ctx.race then return true end
            return value[ctx.race] and true or false
        end,
    },
    {
        key = "level", kind = "range", label = "Level",
        tip = "Either end can be left blank.",
        read = function(ctx) ctx.level = ReadNumber(_G.UnitLevel, "player") end,
        test = function(value, ctx)
            if ctx.level == UNKNOWN or not ctx.level then return true end
            if value.min and ctx.level < value.min then return false end
            if value.max and ctx.level > value.max then return false end
            return true
        end,
    },
    {
        key = "form", kind = "set", label = "Shapeshift form",
        tip = "Matched against the client's own form constants, so the numbers "
           .. "are never written down here. Nothing ticked means any form.",
        values = function() return ns.Load:FormList() end,
        read = function(ctx) ctx.form = ReadNumber(_G.GetShapeshiftFormID) end,
        test = function(value, ctx)
            if not next(value) then return true end
            if ctx.form == UNKNOWN then return true end
            for name in pairs(value) do
                if name == "NONE" then
                    if ctx.form == nil then return true end
                elseif ns.SafeNumber(_G[name]) == ctx.form then
                    return true
                end
            end
            return false
        end,
    },
    {
        key = "zone", kind = "text", label = "Zone name contains",
        tip = "Matched against every name the client has for where you are: "
           .. "zone, sub-zone and minimap.",
        read = function(ctx)
            ctx.zones = {}
            for _, fn in ipairs({ _G.GetRealZoneText, _G.GetSubZoneText,
                                  _G.GetZoneText, _G.GetMinimapZoneText }) do
                local text = ReadText(fn)
                if text and text ~= UNKNOWN then
                    ctx.zones[#ctx.zones + 1] = text:lower()
                end
            end
        end,
        test = function(value, ctx)
            if value == "" then return true end
            if #ctx.zones == 0 then return true end
            local needle = value:lower()
            for _, zone in ipairs(ctx.zones) do
                if zone:find(needle, 1, true) then return true end
            end
            return false
        end,
    },
    {
        key = "spellKnown", kind = "text", label = "Spell known",
        tip = "A spell name or ID. Loads only while your spellbook has it -- "
           .. "which is how one aura set covers several specs.",
        test = function(value)
            if value == "" then return true end
            local spellID = ns.ResolveSpell(value)
            if not spellID then return true end
            local known = ReadBool(_G.IsSpellKnown, spellID)
            if known == UNKNOWN then
                known = ReadBool(_G.IsPlayerSpell, spellID)
            end
            if known == UNKNOWN then return true end
            return known
        end,
    },
}
Load.CONDITIONS = CONDITIONS

-- Defaults, in the shape the compactor wants: a condition left alone is absent
-- from the file entirely, so this is only what "absent" means to a reader.
local LOAD_DEFAULTS = {}
ns.LOAD_DEFAULTS = LOAD_DEFAULTS

-------------------------------------------------------------------------------
-- Value lists
-------------------------------------------------------------------------------

local CLASS_TOKENS = {
    "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST",
    "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

-- The classic roster. Only a fallback: the client's own race table is asked
-- first, so a race this build has that the list below does not still appears.
local RACE_TOKENS = {
    "Human", "Dwarf", "NightElf", "Gnome",
    "Orc", "Scourge", "Tauren", "Troll",
}

function Load:RaceList()
    local list, seen = {}, {}

    local info = _G.C_CreatureInfo
    if info and type(info.GetRaceInfo) == "function" then
        -- Walked by id because there is no "list them all" call. The range is
        -- generous and the gaps simply do not answer.
        for id = 1, 90 do
            local ok, data = pcall(info.GetRaceInfo, id)
            if ok and type(data) == "table" then
                local token = ns.SafeText(data.clientFileString)
                local label = ns.SafeText(data.raceName) or token
                if token and not seen[token] then
                    seen[token] = true
                    list[#list + 1] = { value = token, text = label }
                end
            end
        end
    end

    if #list == 0 then
        for _, token in ipairs(RACE_TOKENS) do
            list[#list + 1] = { value = token, text = token }
        end
    end

    table.sort(list, function(a, b) return a.text < b.text end)
    return list
end

function Load:ClassList()
    local list = {}
    for _, token in ipairs(CLASS_TOKENS) do
        -- The client's own localised name where it has one, the token where it
        -- does not. LOCALIZED_CLASS_NAMES_MALE is not on every build.
        local names = _G.LOCALIZED_CLASS_NAMES_MALE
        local label = names and ns.SafeText(names[token]) or token
        list[#list + 1] = { value = token, text = label }
    end
    return list
end

-- The forms this client actually has constants for. A client without them shows
-- an empty list rather than a row of numbers that mean nothing.
local FORM_TOKENS = {
    { value = "NONE",           text = "No form" },
    { value = "CAT_FORM",       text = "Cat" },
    { value = "BEAR_FORM",      text = "Bear" },
    { value = "DIRE_BEAR_FORM", text = "Dire Bear" },
    { value = "MOONKIN_FORM",   text = "Moonkin" },
    { value = "TRAVEL_FORM",    text = "Travel" },
    { value = "AQUATIC_FORM",   text = "Aquatic" },
    { value = "FLIGHT_FORM",    text = "Flight" },
    { value = "SHADOWFORM",     text = "Shadowform" },
    { value = "GHOST_WOLF",     text = "Ghost Wolf" },
}

function Load:FormList()
    local list = {}
    for _, entry in ipairs(FORM_TOKENS) do
        if entry.value == "NONE" or ns.SafeNumber(_G[entry.value]) then
            list[#list + 1] = entry
        end
    end
    return list
end

-- Can this client answer this condition at all? Asked by the options window so
-- a setting that could never do anything is visibly greyed rather than quietly
-- ignored.
function Load:Available(condition)
    if condition.available then return condition.available() end
    if condition.values then return #condition.values() > 0 end
    if not condition.read then return true end

    local probe = {}
    condition.read(probe)
    for _, value in pairs(probe) do
        if value ~= UNKNOWN then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------
-- The readings are taken once per sweep and shared by every aura, because the
-- expensive part of "am I in a raid" is asking, not comparing.

local context = {}

function Load:Refresh()
    wipe(context)
    for _, condition in ipairs(CONDITIONS) do
        if condition.read then condition.read(context) end
    end
end

function Load:Test(aura)
    local settings = aura.load
    if not settings then return true end

    for _, condition in ipairs(CONDITIONS) do
        local value = settings[condition.key]
        if value ~= nil then
            local ok = condition.test(value, context)
            if not ok then return false, condition.key end
        end
    end
    return true
end

-- A one-line answer for /chair auras load: which conditions this aura sets, and which of
-- them is currently refusing.
function Load:Explain(aura)
    self:Refresh()
    local settings = aura.load or {}
    local parts = {}

    for _, condition in ipairs(CONDITIONS) do
        local value = settings[condition.key]
        if value ~= nil then
            local ok = condition.test(value, context)
            parts[#parts + 1] = (ok and "|cff66dd66" or "|cffdd6666")
                .. condition.label .. "|r"
        end
    end

    if #parts == 0 then return "always loaded" end
    local ok, line = pcall(table.concat, parts, ", ")
    return ok and line or "<unprintable>"
end
