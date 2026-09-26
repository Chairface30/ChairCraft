local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------
-- Two client faults shape everything in this file.
--
-- The first: a saved file much over four kilobytes is written correctly and then
-- never read back, silently. An aura addon is the worst possible shape for that
-- -- every aura the user adds makes the file bigger -- so an aura is stored as
-- the few fields that cannot be worked out again, and everything equal to its
-- default is dropped on the way out. A spell's name and icon are never stored:
-- C_Spell answers both from the ID.
--
-- The second: the saved global does not arrive on schedule. ADDON_LOADED is the
-- documented moment and it is nil there on this client. PLAYER_LOGIN is right
-- for a /reload and appears not to be for a cold start. So this addon never
-- invents the global the moment it finds nil -- doing that is what turns a late
-- arrival into permanent loss, because the empty table goes in where the real
-- one was about to land and gets written back over the settings on the way out.
-- It waits, and only falls back to defaults once waiting has clearly failed.

local DB_VERSION = 2
local DB_GRACE_SECONDS = 15

-------------------------------------------------------------------------------
-- The model
-------------------------------------------------------------------------------
-- One flat list of auras, each carrying the id of its parent. WeakAuras keeps
-- the same shape -- children name their group rather than groups listing their
-- children -- and for the same reason: a tree stored as a tree has two places
-- to go wrong, the child's idea of its parent and the parent's idea of its
-- children, and they drift. Order inside a group is the order of the flat list.
--
-- An aura is one of these types:
--   icon     a square of art with a cooldown swipe on it
--   text     a line of text, which is what you want when the number is the
--            point and the picture is not
--   bar      a progress bar, for a thing with a duration worth watching run out
--   group    a container; children keep their slot whether or not they show
--   dynamic  a container that lays out only what is showing, and closes gaps
--
-- The first three are all one trigger drawn differently, so the type is a
-- display setting and changing it keeps everything else about the aura.
--
-- Every table here is also read in the other direction by the compactor, so a
-- default added here is dropped from the saved file for free.

local PROFILE_DEFAULTS = {
    locked = false,
}
ns.PROFILE_DEFAULTS = PROFILE_DEFAULTS

local AURA_DEFAULTS = {
    type = "icon",
}
ns.AURA_DEFAULTS = AURA_DEFAULTS

local TRIGGER_DEFAULTS = {
    type    = "aura",      -- aura | cooldown
    unit    = "player",    -- player | target | focus | pet
    harmful = false,       -- a debuff rather than a buff
    match   = "id",        -- id | name
    mine    = false,       -- only what I applied
    partial = false,       -- name match: contains, rather than equals
    stacksOp = ">=",       -- >= | <= | ==
    stacks  = 0,           -- 0 means "do not care"
}
ns.TRIGGER_DEFAULTS = TRIGGER_DEFAULTS

local DISPLAY_DEFAULTS = {
    size       = 40,

    -- Text and bars. A format string is written with the same tokens in both:
    --   %n the aura's name      %s stacks
    --   %t time left            %p percent of the duration left
    --   %d the full duration    %% a literal per-cent sign
    textFormat = "%n",
    fontSize   = 14,
    textWidth  = 140,
    barFormat  = "%n  %t",
    barWidth   = 160,
    barHeight  = 18,
    barIcon    = true,
    colour     = "ffffff",
    invert     = false,    -- show while NOT met
    hide       = false,    -- disappear when not met, rather than dim
    desaturate = true,     -- grey out while not met
    swipe      = true,     -- draw the cooldown swipe
    stacks     = true,     -- draw the stack count
    flash      = true,     -- flash on the edge into shown
    alpha      = 100,      -- percent, while shown
    dimAlpha   = 30,       -- percent, while not
}
ns.DISPLAY_DEFAULTS = DISPLAY_DEFAULTS

-- Actions: what happens at the moment an aura turns on or off, as opposed to
-- what it looks like while it is on. Sound is the only one so far, and it is
-- stored as whatever the player typed -- a number is a sound the client already
-- knows, anything else is a file path -- because which of those a client
-- accepts is not a thing to decide on their behalf.
local ACTION_DEFAULTS = {
    onShow = "",
    onHide = "",
    channel = "Master",
}
ns.ACTION_DEFAULTS = ACTION_DEFAULTS

local GROUP_DEFAULTS = {
    -- RIGHT | LEFT | DOWN | UP grow away from the corner they name;
    -- HCENTER | VCENTER grow both ways out of the middle and shrink back into
    -- it, which is what keeps a dynamic group centred on its own anchor.
    growth  = "RIGHT",
    spacing = 6,
    sort    = "none",      -- none | name | time
    limit   = 0,           -- dynamic only; 0 means no limit
    columns = 0,           -- 0 means a single row or column
}
ns.GROUP_DEFAULTS = GROUP_DEFAULTS

-- Load conditions live in Load.lua: the list of them is also what the options
-- window draws, so there is one place to add one.

-------------------------------------------------------------------------------
-- Profile key
-------------------------------------------------------------------------------
-- One profile for the whole account. Auras are shared between characters;
-- anything that should only run on one class says so with its own load.class
-- condition, which is where that belongs anyway.
--
-- Profiles used to be per character, keyed by GUID. Those are left in the file
-- untouched when the account profile is first made from one of them (see
-- AdoptAccountProfile), so nothing anyone set up is thrown away.

local ACCOUNT_KEY = "account"
ns.ACCOUNT_KEY = ACCOUNT_KEY

-- Every value reaching a concat goes through SafeText: this client can hand
-- back secret values, and an unguarded concat on one throws.
local function CharLabel()
    return (ns.SafeText(UnitName("player")) or "Unknown")
        .. "-" .. (ns.SafeText(GetRealmName()) or "Unknown")
end
ns.CharLabel = CharLabel

local function ProfileKey()
    return ACCOUNT_KEY
end
ns.ProfileKey = ProfileKey

-------------------------------------------------------------------------------
-- Ids
-------------------------------------------------------------------------------
-- Short on purpose: an id is written into the file once per aura and again for
-- every child that names it as a parent, and the file has four kilobytes.

local function NextID(profile)
    local highest = 0
    for _, aura in ipairs(profile.auras or {}) do
        local n = tonumber(string.match(aura.id or "", "^a(%d+)$"))
        if n and n > highest then highest = n end
    end
    return "a" .. (highest + 1)
end
ns.NextID = NextID

-------------------------------------------------------------------------------
-- Load
-------------------------------------------------------------------------------

local load = { atAddonLoaded = false, atPlayerLogin = false, atEnteringWorld = false }
ns.loadWitness = load

-- The pre-groups format: one flat list of watchers drawn as a single row, with
-- the row's size, spacing, growth and position on the profile itself.
--
-- That row is exactly a dynamic group, so it becomes one and the watchers become
-- its children. Nobody loses their setup to a model change, and the thing they
-- end up with is the thing the new model would have built for them anyway.
local function MigrateV1(profile)
    local watchers = profile.watchers
    if type(watchers) ~= "table" then return end

    profile.auras = profile.auras or {}

    local group = {
        id      = "a1",
        type    = "dynamic",
        name    = "Row",
        growth  = profile.growth,
        spacing = profile.spacing,
        pos     = profile.pos,
    }
    profile.auras[#profile.auras + 1] = group

    for index, watcher in ipairs(watchers) do
        local kind = watcher.kind or "buff"
        local aura = {
            id     = "a" .. (index + 1),
            type   = "icon",
            parent = group.id,
            trigger = {
                type    = (kind == "cooldown") and "cooldown" or "aura",
                harmful = (kind == "debuff") or nil,
                unit    = watcher.unit,
                spellID = watcher.spellID,
                mine    = watcher.mine,
            },
            display = {
                size   = profile.size,
                invert = watcher.invert,
                hide   = watcher.hide,
            },
        }
        profile.auras[#profile.auras + 1] = aura
    end

    profile.watchers = nil
    profile.size, profile.spacing, profile.growth, profile.pos = nil, nil, nil, nil
end

-- How much setup a stored profile holds, counting the pre-groups format too.
local function SetupSize(profile)
    if type(profile) ~= "table" then return 0 end
    local n = 0
    if type(profile.auras) == "table" then n = n + #profile.auras end
    if type(profile.watchers) == "table" then n = n + #profile.watchers end
    return n
end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = DeepCopy(inner) end
    return out
end

-- First login after profiles went account-wide: the account profile starts as
-- a copy of the fullest character profile, preferring this character's on a
-- tie. The character profiles stay where they are, as they were.
local function AdoptAccountProfile(db)
    if db.profiles[ACCOUNT_KEY] then return nil end
    local guid = ns.SafeText(UnitGUID and UnitGUID("player"))
    local mine = guid and db.profiles["guid:" .. guid] or nil
    local best, bestKey, bestSize = mine, mine and ("guid:" .. guid) or nil, SetupSize(mine)
    for key, profile in pairs(db.profiles) do
        local size = SetupSize(profile)
        if size > bestSize then best, bestKey, bestSize = profile, key, size end
    end
    if not best then return nil end
    db.profiles[ACCOUNT_KEY] = DeepCopy(best)
    return bestKey
end

local function InitDatabase()
    if not ChairAurasDB then ChairAurasDB = {} end
    local db = ChairAurasDB

    db.profiles = db.profiles or {}
    load.adoptedFrom = AdoptAccountProfile(db)

    local key = ProfileKey()
    local profile = db.profiles[key]
    load.profileWasNew = (profile == nil)
    if not profile then
        profile = {}
        db.profiles[key] = profile
    end

    if (db.version or 1) < 2 then MigrateV1(profile) end
    db.version = DB_VERSION

    profile.label = "Account"
    profile.auras = profile.auras or {}

    -- Conditions were removed (2026-09-25). Rules saved before then are
    -- dropped here, so nothing is left carrying a setting no window shows.
    for _, aura in ipairs(profile.auras) do
        if type(aura) == "table" then aura.conditions = nil end
    end

    -- A profile with nothing in it is either a genuine first run or this
    -- client losing the file again, and from in here those are the same
    -- thing. Either way the auras written down in Presets.lua are a better
    -- answer than an empty screen. Only ever when the list is empty: saved
    -- data that did arrive is never overridden.
    load.seeded = (ns.SeedPreset and ns.SeedPreset(profile) or 0)
    for field, value in pairs(PROFILE_DEFAULTS) do
        if profile[field] == nil then profile[field] = value end
    end

    ns.profile = profile
end

function ns.GetProfile()
    return ns.profile
end

function ns.GetAuras()
    return ns.profile and ns.profile.auras or {}
end

-- Everything an aura does not say for itself, answered from the defaults above,
-- so no reader anywhere has to remember what a missing field means.
function ns.Trigger(aura)
    return aura.trigger or {}
end

-- Two ways in, because half the callers hold an aura and the other half hold
-- the trigger they already pulled out of one.
function ns.TriggerFieldValue(trigger, field)
    local value = trigger and trigger[field]
    if value == nil then return TRIGGER_DEFAULTS[field] end
    return value
end

function ns.TriggerField(aura, field)
    return ns.TriggerFieldValue(aura.trigger, field)
end

function ns.DisplayField(aura, field)
    local display = aura.display or {}
    local value = display[field]
    if value == nil then return DISPLAY_DEFAULTS[field] end
    return value
end

function ns.ActionField(aura, field)
    local actions = aura.actions or {}
    local value = actions[field]
    if value == nil then return ACTION_DEFAULTS[field] end
    return value
end

function ns.GroupField(aura, field)
    local value = aura[field]
    if value == nil then return GROUP_DEFAULTS[field] end
    return value
end

function ns.IsGroup(aura)
    local kind = aura.type or AURA_DEFAULTS.type
    return kind == "group" or kind == "dynamic"
end

-- What to draw it as. Anything that is not a container and not one of the
-- other two shapes is an icon, which is also what every aura made before there
-- was a choice turns out to be.
function ns.RegionKind(aura)
    local kind = aura.type or AURA_DEFAULTS.type
    if kind == "text" or kind == "bar" then return kind end
    if ns.IsGroup(aura) then return "group" end
    return "icon"
end

-- The table an edit writes into, made on demand. Auras that never leave their
-- defaults never grow one, which is the difference between a file that fits in
-- four kilobytes and one that does not.
function ns.SubTable(aura, name)
    aura[name] = aura[name] or {}
    return aura[name]
end

function ns.FindAura(id)
    if not id then return nil end
    for index, aura in ipairs(ns.GetAuras()) do
        if aura.id == id then return aura, index end
    end
    return nil
end

-- Children of a group, in list order. Deliberately not cached: the list is
-- short, and a cache is one more thing that can disagree with the file.
function ns.Children(parentID)
    local list = {}
    for _, aura in ipairs(ns.GetAuras()) do
        if aura.parent == parentID then list[#list + 1] = aura end
    end
    return list
end

-- Everything under a group, at any depth, in tree order. A nested group is
-- included as well as walked through: it carries display settings of its own
-- for the children it will get later, so it has to hear about a change too.
function ns.Descendants(parentID)
    local out = {}

    local function Walk(id, seen)
        for _, aura in ipairs(ns.Children(id)) do
            if not seen[aura.id] then
                seen[aura.id] = true
                out[#out + 1] = aura
                if ns.IsGroup(aura) then Walk(aura.id, seen) end
            end
        end
    end

    Walk(parentID, {})
    return out
end

function ns.TopLevel()
    return ns.Children(nil)
end

-- Moving an aura in the list.
--
-- Order inside a group is the order of the flat list, so reordering is moving
-- one entry of that list -- and dropping something onto a group is the same
-- move with a change of parent. Both happen here so the window and the slash
-- commands cannot disagree about what a move means.
--
-- Where "onto" lands: dropping on a group puts the thing inside it, at the
-- end, which is what dragging into a container means everywhere else. Dropping
-- on an ordinary aura puts it beside that aura, in the same group, which is
-- what dragging within a list means everywhere else.
function ns.MoveAura(aura, target, inside)
    if not aura or not target or aura == target then return false end

    -- Where it would end up, asked before anything moves. The question is
    -- whether the aura would become its own ancestor, so it is the aura that
    -- is checked against the parent it is heading for -- not the other way
    -- round, which answers a different question and answers it no.
    local parentID = (inside and ns.IsGroup(target)) and target.id or target.parent
    if parentID and ns.WouldLoop(aura, parentID) then return false end

    local auras = ns.GetAuras()

    local from
    for index, one in ipairs(auras) do
        if one == aura then from = index break end
    end
    if not from then return false end

    if inside and ns.IsGroup(target) then
        aura.parent = target.id
    else
        aura.parent = target.parent
    end

    table.remove(auras, from)

    local to
    for index, one in ipairs(auras) do
        if one == target then to = index break end
    end
    if not to then
        auras[#auras + 1] = aura
        return true
    end

    -- Into a group goes after everything already in it, so a drop onto a group
    -- with six things in it does not land in the middle of them.
    if inside and ns.IsGroup(target) then
        local last = to
        for index = to + 1, #auras do
            local one = auras[index]
            local cursor = one.parent
            local within = false
            while cursor do
                if cursor == target.id then within = true break end
                local parent = ns.FindAura(cursor)
                cursor = parent and parent.parent
            end
            if within then last = index else break end
        end
        table.insert(auras, last + 1, aura)
    else
        table.insert(auras, to, aura)
    end

    return true
end

-- A group cannot end up inside itself, however the ids are edited.
function ns.WouldLoop(aura, parentID)
    local seen = {}
    local cursor = parentID
    while cursor do
        if cursor == aura.id or seen[cursor] then return true end
        seen[cursor] = true
        local parent = ns.FindAura(cursor)
        cursor = parent and parent.parent
    end
    return false
end

-------------------------------------------------------------------------------
-- Compaction
-------------------------------------------------------------------------------
-- Everything InitDatabase puts back is dropped here. Nothing in this function is
-- a judgement about what matters -- it is the same defaults tables, read in the
-- other direction.

local function CompactTable(target, defaults)
    if type(target) ~= "table" then return end
    for field, value in pairs(defaults) do
        if target[field] == value then target[field] = nil end
    end
end

local function DropIfEmpty(owner, field)
    local value = owner[field]
    if type(value) == "table" and not next(value) then owner[field] = nil end
end

local function CompactAura(aura)
    CompactTable(aura, AURA_DEFAULTS)
    CompactTable(aura.trigger, TRIGGER_DEFAULTS)
    CompactTable(aura.display, DISPLAY_DEFAULTS)
    CompactTable(aura.load, ns.LOAD_DEFAULTS or {})
    CompactTable(aura.actions, ACTION_DEFAULTS)
    if ns.IsGroup(aura) then CompactTable(aura, GROUP_DEFAULTS) end

    -- Names and icons are display, not settings: C_Spell answers both from the
    -- ID every login, so storing them is storing the same bytes twice. A name
    -- the user typed themselves is a different thing and stays.
    aura.icon = nil
    if aura.name == "" then aura.name = nil end

    local pos = aura.pos
    if pos and pos.x and pos.y then
        pos.x = math.floor(pos.x + 0.5)
        pos.y = math.floor(pos.y + 0.5)
    end

    DropIfEmpty(aura, "trigger")
    DropIfEmpty(aura, "display")
    DropIfEmpty(aura, "load")
    DropIfEmpty(aura, "actions")
    DropIfEmpty(aura, "pos")
end

local function CompactProfile(profile)
    for _, aura in ipairs(profile.auras or {}) do
        CompactAura(aura)
    end
    DropIfEmpty(profile, "auras")
    CompactTable(profile, PROFILE_DEFAULTS)
end

function ns.SaveOnLogout()
    if not ChairAurasDB then return end

    -- A witness for the next cold start. A file that comes back as defaults
    -- tomorrow cannot otherwise say whether the data ever turned up, or how
    -- late, and guessing at that has already cost days.
    ChairAurasDB.lastLoad = {
        arrival         = load.arrival,
        atAddonLoaded   = load.atAddonLoaded and true or false,
        atPlayerLogin   = load.atPlayerLogin and true or false,
        atEnteringWorld = load.atEnteringWorld and true or false,
        profileWasNew   = load.profileWasNew and true or false,
        seeded          = load.seeded or 0,
    }

    for _, profile in pairs(ChairAurasDB.profiles or {}) do
        CompactProfile(profile)
    end
end

-------------------------------------------------------------------------------
-- The gate
-------------------------------------------------------------------------------

local waitStarted

local function Bootstrap(reason, waited)
    if ns.ready then return end

    load.arrival = string.format("%s +%.1fs", reason, waited or 0)

    InitDatabase()
    ns.Display:Build()
    ns.Engine:Rebuild()
    ns.ready = true
    ns.RequestUpdate()

    ns.Print("v" .. ns.version .. " loaded,", #ns.GetAuras(),
             "aura(s). |cffffd100/chair auras|r to configure.")

    -- Said out loud, because an aura that came from the file and one that came
    -- from Presets.lua look identical on screen, and which of the two it is
    -- decides whether an edit made last session is gone.
    if (load.seeded or 0) > 0 then
        ns.Print("|cffffa500no saved auras came back, so these", load.seeded,
                 "are the ones written into the addon.|r Edits made now last "
                 .. "until the client loses the file again.")
    end
end

function ns.TryBootstrap(reason)
    if ns.ready then return end

    waitStarted = waitStarted or GetTime()
    local waited = GetTime() - waitStarted

    if ChairAurasDB ~= nil then
        Bootstrap(reason, waited)
    elseif waited >= DB_GRACE_SECONDS then
        -- Genuine first run looks exactly like this, so it cannot be an error.
        Bootstrap("never seen", waited)
    else
        C_Timer.After(0.5, function() ns.TryBootstrap("waited") end)
    end
end
