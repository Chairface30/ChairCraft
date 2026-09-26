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

-------------------------------------------------------------------------------
-- Phase 9: the rest of WeakAuras' load options this client can answer
-------------------------------------------------------------------------------
-- Lists are typed with commas, matched without regard to case: "Chair, Face"
-- loads on either character. `section` starts a new heading on the Load tab.

-- Lowered for matching, unless `keepCase`: item names go to the client as
-- typed.
local function List(text, keepCase)
    local out = {}
    for part in tostring(text or ""):gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$")
        if part ~= "" then out[#out + 1] = keepCase and part or part:lower() end
    end
    return out
end
Load.List = List

local function InList(text, ...)
    local wanted = List(text)
    if #wanted == 0 then return true end
    for i = 1, select("#", ...) do
        local have = select(i, ...)
        if have ~= nil and have ~= UNKNOWN then
            have = tostring(have):lower()
            for _, one in ipairs(wanted) do
                if one == have then return true end
            end
        end
    end
    return false
end

-- A toggle whose reading is one boolean in ctx.
local function Toggle(key, label, read, tip, section)
    return {
        key = key, kind = "toggle", label = label, tip = tip, section = section,
        read = function(ctx) ctx[key] = read() end,
        test = function(value, ctx)
            if ctx[key] == UNKNOWN then return true end
            return ctx[key] == value
        end,
    }
end

-- A range over one number in ctx.
local function Range(key, label, read, tip, section)
    return {
        key = key, kind = "range", label = label, tip = tip, section = section,
        read = function(ctx) ctx[key] = read() end,
        test = function(value, ctx)
            local n = ctx[key]
            if n == UNKNOWN or not n then return true end
            if value.min and n < value.min then return false end
            if value.max and n > value.max then return false end
            return true
        end,
    }
end

-- A set over one text in ctx; nothing ticked means any.
local function Set(key, label, values, read, tip, section)
    return {
        key = key, kind = "set", label = label, tip = tip, section = section,
        values = values,
        read = function(ctx) ctx[key] = read() end,
        test = function(value, ctx)
            if not next(value) then return true end
            local have = ctx[key]
            if have == UNKNOWN or have == nil then return true end
            return value[have] and true or false
        end,
    }
end

local function Fixed(list)
    return function()
        local out = {}
        for i, entry in ipairs(list) do out[i] = { value = entry[1], text = entry[2] } end
        return out
    end
end

-- Boss encounters, heard rather than asked: the client says when one starts
-- and ends. A client without the events cannot say at all.
local encounter = { active = false, id = nil, heard = false }
Load.__encounter = encounter
do
    local frame = CreateFrame("Frame")
    local okStart = pcall(frame.RegisterEvent, frame, "ENCOUNTER_START")
    local okEnd = pcall(frame.RegisterEvent, frame, "ENCOUNTER_END")
    encounter.heard = okStart and okEnd
    frame:SetScript("OnEvent", function(_, event, id)
        if event == "ENCOUNTER_START" then
            encounter.active, encounter.id = true, ns.SafeNumber(id)
        else
            encounter.active, encounter.id = false, nil
        end
        if ns.RequestUpdate then ns.RequestUpdate() end
    end)
end

local function Instance(index)
    local info = { pcall(_G.GetInstanceInfo) }
    if type(_G.GetInstanceInfo) ~= "function" or not info[1] then return UNKNOWN end
    return info[index + 1]
end

local MORE = {
    -- You
    {
        key = "playerName", kind = "text", label = "Character name", section = "You",
        tip = "One or more names, split by commas. Name-Realm works too.",
        read = function(ctx)
            ctx.playerName = ReadText(_G.UnitName, "player")
            ctx.realm = ReadText(_G.GetRealmName)
        end,
        test = function(value, ctx)
            local name, realm = ctx.playerName, ctx.realm
            if name == UNKNOWN or not name then return true end
            local full = (realm and realm ~= UNKNOWN) and (name .. "-" .. realm:gsub("%s", "")) or nil
            return InList(value, name, full)
        end,
    },
    {
        key = "realm", kind = "text", label = "Realm",
        tip = "One or more realms, split by commas.",
        test = function(value, ctx)
            if ctx.realm == UNKNOWN or not ctx.realm then return true end
            return InList(value, ctx.realm)
        end,
    },
    {
        key = "guild", kind = "text", label = "Guild",
        tip = "One or more guild names, split by commas.",
        read = function(ctx) ctx.guild = ReadText(_G.GetGuildInfo, "player") end,
        test = function(value, ctx)
            if ctx.guild == UNKNOWN then return true end
            return InList(value, ctx.guild)
        end,
    },
    Set("faction", "Faction", Fixed({ { "Alliance", "Alliance" }, { "Horde", "Horde" } }),
        function() return ReadText(_G.UnitFactionGroup, "player") end),
    Range("effectiveLevel", "Effective level", function()
        local level = ReadNumber(_G.UnitEffectiveLevel, "player")
        if level == UNKNOWN or not level then level = ReadNumber(_G.UnitLevel, "player") end
        return level
    end, "Your level as scaled, where a zone scales it; otherwise your level."),
    Toggle("hasPet", "Have a pet", function() return ReadBool(_G.UnitExists, "pet") end),
    Toggle("pvp", "Flagged for PvP", function() return ReadBool(_G.UnitIsPVP, "player") end),

    -- Group
    Range("groupSize", "Group size", function()
        local members = ReadNumber(_G.GetNumGroupMembers)
        if members == UNKNOWN then return UNKNOWN end
        return math.max(members or 0, 1)
    end, "How many are in your group, you included; 1 is solo.", "Group"),
    Toggle("groupLeader", "Group leader", function() return ReadBool(_G.UnitIsGroupLeader, "player") end),
    Set("role", "Group role", Fixed({ { "TANK", "Tank" }, { "HEALER", "Healer" },
        { "DAMAGER", "Damage" }, { "NONE", "None" } }),
        function() return ReadText(_G.UnitGroupRolesAssigned, "player") end,
        "The role you have in the group."),
    Set("raidRole", "Raid role", Fixed({ { "MAINTANK", "Main tank" }, { "MAINASSIST", "Main assist" },
        { "NONE", "None" } }),
        function()
            local fn = _G.GetPartyAssignment
            if type(fn) ~= "function" then return UNKNOWN end
            if Read(fn, "MAINTANK", "player") == true then return "MAINTANK" end
            if Read(fn, "MAINASSIST", "player") == true then return "MAINASSIST" end
            return "NONE"
        end),

    -- Where
    Set("instanceType", "Instance type", Fixed({ { "none", "Not in one" }, { "party", "Dungeon" },
        { "raid", "Raid" }, { "pvp", "Battleground" }, { "arena", "Arena" } }),
        function()
            local fn = _G.IsInInstance
            if type(fn) ~= "function" then return UNKNOWN end
            local ok, _, kind = pcall(fn)
            return ok and ns.SafeText(kind) or UNKNOWN
        end, nil, "Where"),
    Range("instanceSize", "Instance size", function()
        local size = Instance(5)
        if size == UNKNOWN then return UNKNOWN end
        return ns.SafeNumber(size)
    end, "The most players the instance takes: 5, 10, 20, 40."),
    {
        key = "difficulty", kind = "text", label = "Difficulty",
        tip = "The instance difficulty's name, or part of it: Normal, Heroic...",
        read = function(ctx)
            local name = Instance(4)
            ctx.difficulty = (name == UNKNOWN) and UNKNOWN or ns.SafeText(name)
        end,
        test = function(value, ctx)
            if ctx.difficulty == UNKNOWN then return true end
            local needle = value:lower()
            return ((ctx.difficulty or ""):lower()):find(needle, 1, true) ~= nil
        end,
    },
    {
        key = "zoneID", kind = "text", label = "Zone or instance ID",
        tip = "Map IDs or instance IDs, split by commas. /chair auras where shows yours.",
        read = function(ctx)
            local map = _G.C_Map
            ctx.mapID = (map and type(map.GetBestMapForUnit) == "function")
                        and ReadNumber(map.GetBestMapForUnit, "player") or UNKNOWN
            local instanceID = Instance(8)
            ctx.instanceID = (instanceID == UNKNOWN) and UNKNOWN or ns.SafeNumber(instanceID)
        end,
        test = function(value, ctx)
            if ctx.mapID == UNKNOWN and ctx.instanceID == UNKNOWN then return true end
            return InList(value, ctx.mapID, ctx.instanceID)
        end,
    },

    -- Gear
    {
        key = "equipped", kind = "text", label = "Item equipped", section = "Gear",
        tip = "Item names or IDs, split by commas. Loads while you wear any one of them.",
        test = function(value)
            local items = List(value, true)
            if #items == 0 then return true end
            if type(_G.IsEquippedItem) ~= "function" then return true end
            for _, item in ipairs(items) do
                if Read(_G.IsEquippedItem, tonumber(item) or item) == true then return true end
            end
            return false
        end,
        available = function() return type(_G.IsEquippedItem) == "function" end,
    },
    {
        key = "notEquipped", kind = "text", label = "Item not equipped",
        tip = "Item names or IDs, split by commas. Loads while you wear none of them.",
        test = function(value)
            local items = List(value, true)
            if #items == 0 or type(_G.IsEquippedItem) ~= "function" then return true end
            for _, item in ipairs(items) do
                if Read(_G.IsEquippedItem, tonumber(item) or item) == true then return false end
            end
            return true
        end,
        available = function() return type(_G.IsEquippedItem) == "function" end,
    },
    {
        key = "itemType", kind = "text", label = "Item type equipped",
        tip = "Item types as the game names them, split by commas: Shields, Daggers, "
           .. "Two-Handed Swords...",
        test = function(value)
            local fn = _G.IsEquippedItemType
            if type(fn) ~= "function" then return true end
            local any = false
            for part in tostring(value):gmatch("[^,]+") do
                part = part:match("^%s*(.-)%s*$")
                if part ~= "" then
                    any = true
                    if Read(fn, part) == true then return true end
                end
            end
            return not any
        end,
        available = function() return type(_G.IsEquippedItemType) == "function" end,
    },

    -- Spells
    {
        key = "spellNotKnown", kind = "text", label = "Spell not known", section = "Spells",
        tip = "A spell name or ID. Loads only while your spellbook lacks it.",
        test = function(value)
            if value == "" then return true end
            local spellID = ns.ResolveSpell(value)
            if not spellID then return true end
            local known = ReadBool(_G.IsSpellKnown, spellID)
            if known == UNKNOWN then known = ReadBool(_G.IsPlayerSpell, spellID) end
            if known == UNKNOWN then return true end
            return not known
        end,
    },

    -- Encounters
    {
        key = "encounter", kind = "toggle", label = "In a boss encounter", section = "Encounter",
        tip = "While a boss fight the client announces is on.",
        read = function(ctx)
            if encounter.heard then ctx.encounter = encounter.active else ctx.encounter = UNKNOWN end
        end,
        test = function(value, ctx)
            if ctx.encounter == UNKNOWN then return true end
            return ctx.encounter == value
        end,
    },
    {
        key = "encounterID", kind = "text", label = "Encounter ID",
        tip = "Encounter IDs, split by commas: loads only during those fights.",
        test = function(value)
            if not encounter.heard then return true end
            if not encounter.active then return false end
            return InList(value, encounter.id)
        end,
        available = function() return encounter.heard end,
    },
}
for _, condition in ipairs(MORE) do CONDITIONS[#CONDITIONS + 1] = condition end

-- Where you are, as the IDs the Zone or instance ID condition matches.
function Load:WhereAmI()
    local ctx = {}
    for _, condition in ipairs(CONDITIONS) do
        if condition.key == "zoneID" then condition.read(ctx) end
    end
    return ctx.mapID, ctx.instanceID
end

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

-- The races a player can be here: the classic eight and the two Skyborne,
-- High Order (Alliance) and Windshaper (Horde). The client's race table holds
-- every race the engine knows, playable or not, so it is asked about these
-- IDs only; the names and tokens still come from it, so they read as the
-- client writes them. The tokens are the fallback when it will not answer.
local PLAYABLE_RACE_IDS = { 1, 2, 3, 4, 5, 6, 7, 8, 95, 96 }
local RACE_TOKENS = {
    "Human", "Dwarf", "NightElf", "Gnome",
    "Orc", "Scourge", "Tauren", "Troll",
}

function Load:RaceList()
    local list, seen = {}, {}

    local info = _G.C_CreatureInfo
    if info and type(info.GetRaceInfo) == "function" then
        for _, id in ipairs(PLAYABLE_RACE_IDS) do
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
        -- Without the race table the Skyborne tokens are not known, so this
        -- fallback is the classic eight.
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
