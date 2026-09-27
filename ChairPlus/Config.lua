-- ChairPlus Config.lua
-- Defaults, the baked overrides, and the layering that resolves them against
-- whatever the client managed to hand back from SavedVariables.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

-------------------------------------------------------------------------------
-- Defaults
-------------------------------------------------------------------------------
-- Every feature ships off. Nothing automates, and nothing is drawn, until it is
-- switched on in /chair. Only the master switches are off: the options under
-- each one keep their usual values, so turning a feature on gives the whole
-- feature rather than an empty shell of it.

ns.defaults = {
    -- On-screen display
    osd                 = false,    -- show the OSD at all
    osdMoney            = true,      -- gold / silver / copper section
    osdBags             = true,      -- backpack icon and free general slots
    osdBagsProfession   = true,      -- profession bags, counted on their own
    osdBackground       = true,      -- dark plate behind the text
    osdDurability       = false,     -- lowest durability of anything worn
    osdAmmo             = false,     -- arrows or bullets in the ammo slot
    osdShards           = false,     -- soul shards carried
    osdCoords           = false,     -- your position on the zone map
    osdXP               = false,     -- XP to level, and rested
    osdXPMode           = "pct",     -- "pct" 10.47%, "num" 1047/10000, or "both"
    osdClock            = false,     -- the time
    osdClockServer      = false,     -- the realm's time rather than this computer's
    osdClock24          = true,      -- 24-hour; off: 12-hour with AM/PM
    osdAlarm            = false,     -- the in-game alarm's time; click it to set one
    osdZone             = false,     -- the zone and subzone
    osdThreat           = false,     -- your threat on your target, color coded
    osdTracker          = false,     -- ChairTracker's window, dropped down on hover
    osdLatency          = false,     -- frame rate and latency
    osdBagsTotal        = false,     -- bag space as free/total rather than free
    osdSession          = false,     -- time since logging in
    osdSessionGold      = false,     -- gold made or lost since logging in
    osdGPH              = false,     -- gold per hour, on its own counter
    osdSpeed            = false,     -- movement speed, 100% a normal run
    osdPet              = false,     -- a hunter's pet: happiness and health
    osdMail             = false,     -- a mail icon while there is unread mail
    osdSocial           = false,     -- friends online
    osdGuild            = false,     -- guildmates online
    osdRep              = false,     -- the reputation you watch
    osdBgAlpha          = 0.45,      -- how dark the background is
    osdMaxWidth         = 0,         -- wrap onto another line past this; 0 never
    osdCasino           = false,     -- a Chairface's Casino table in your group
    osdIgnore           = false,     -- ChairIgnore: the list's size, click to open
    osdCooldowns        = false,     -- profession cooldowns ready, every character
    osdBrokers          = "",        -- other addons' feeds that are on, by key
    hideStatusBars      = false,     -- hide the game's XP bar and status bar 2
    osdHideMinimap      = false,     -- hide minimap buttons of addons on the display
    -- Display order, left to right. Items missing from it (a new one, or a
    -- hand-edited list) are added at the end in their default place.
    osdOrder            = "money,bags,profession,durability,ammo,shards,coords,zone,xp,rep,threat,clock,alarm,tracker,latency,session,gph,sessiongold,speed,pet,mail,social,guild,casino,ignore,cooldowns",
    osdLocked           = true,     -- click-through until "/chair plus osd unlock"
    osdFontSize         = 14,
    osdScale            = 1.0,
    -- Position is stored as the full anchor tuple rather than a point and an
    -- offset. Dragging a frame can leave it anchored by a different point than
    -- it started on, and re-anchoring it by a guessed point is how a window
    -- walks across the screen a little further every reload.
    osdAnchor           = "CENTER",   -- point on the OSD itself
    osdRelAnchor        = "CENTER",   -- point on UIParent it attaches to
    osdX                = 0,
    osdY                = 0,

    -- Automate quests
    quests              = false,
    questsAccept        = true,      -- accept regular quests
    questsDaily         = true,      -- accept daily quests
    questsWeekly        = true,      -- accept weekly quests
    questsTurnIn        = true,      -- hand in completed quests
    questsShiftOverride = true,     -- hold shift to suppress all of the above

    -- Gossip
    autoGossip              = false,
    autoGossipShiftOverride = true,   -- hold shift to get the window anyway
    autoGossipSummary       = false,  -- say which option was taken

    -- Vendor
    sellJunk            = false,
    sellJunkSummary     = true,      -- report the take in chat
    sellJunkKeepGear    = false,    -- keep unbound grey gear back for the AH
    repairGear          = false,
    repairSummary       = true,
    -- Spends someone else's gold, so it stays off even when repair is on.
    repairGuildFunds    = false,

    -- Loot
    fasterLoot          = false,
    fasterLootDelay     = 0.3,      -- a safe floor; 0.1 is faster

    -- Flight paths
    flight              = false,
    flightCountdown     = true,      -- the big clock while in the air
    flightTooltip       = true,      -- the time on a flight map node
    flightSummary       = false,    -- report the time in chat on landing
    flightFontSize      = 32,
    flightLocked        = true,     -- click-through until unlocked to move it
    flightAnchor        = "TOP",
    flightRelAnchor     = "TOP",
    flightX             = 0,
    -- Near the top edge with a margin. It used to sit at -180, which is where
    -- the zone name arrives -- a large clock and a zone change sharing a line
    -- is the one moment you cannot read either.
    flightY             = -30,

    -- Camera
    maxCameraZoom       = false,

    -- Tooltip extras (Tooltips.lua)
    tooltipExtras       = false,
    tooltipSellPrice    = true,     -- what it sells to a merchant for
    tooltipIDs          = false,    -- item and spell IDs

    -- Mail and small automations (Mail.lua)
    mailOpenAll         = false,    -- an "Open all" button on the inbox
    autoReleaseBG       = false,    -- release on dying in a battleground
    skipCinematics      = false,    -- the in-game cutscenes
    autoDismount        = false,    -- dismount / stand on those errors

    -- Nameplate threat colors (Nameplates.lua)
    nameplateThreat     = false,
    npMine              = true,  npMineR = 0.2,  npMineG = 0.8,  npMineB = 0.2,
    npChanging          = true,  npChangingR = 1, npChangingG = 0.6, npChangingB = 0,
    npNonTank           = true,  npNonTankR = 1, npNonTankG = 0.1, npNonTankB = 0.1,
    npOtherTank         = true,  npOtherTankR = 0.25, npOtherTankG = 0.5, npOtherTankB = 1,

    -- Invites, duels, resurrection (Social.lua). Hold shift to answer yourself.
    autoInvite          = false,    -- accept group invites from...
    autoInviteFriends   = true,     -- ... friends
    autoInviteGuild     = true,     -- ... guildmates
    keywordInvite       = false,    -- invite players who send a keyword
    keywordInviteWords  = "inv,invite", -- the keywords, comma separated
    restock             = false,    -- buy back your consumables at merchants
    restockList         = "",       -- "itemID:count,..." per character
    restockSummary      = true,     -- say in chat what was bought
    restockCap          = 10,       -- gold per visit at most (0: no limit)
    restockFloor        = 0,        -- never spend below this much gold
    cooldownNotify      = false,    -- say when a profession cooldown is ready
    keywordInviteWhisper = true,    -- ... in a whisper
    keywordInviteBNet   = true,     -- ... in a Battle.net whisper
    keywordInviteGuild  = false,    -- ... in guild chat
    keywordInviteSay    = false,    -- ... in say or yell
    keywordInviteExact  = true,     -- the whole message must be the keyword
    keywordInviteRaid   = true,     -- a full party becomes a raid
    declineDuels        = false,
    declineGuildInvites = false,
    autoResurrect       = false,
    autoSummon          = false,
    filterErrors        = false,    -- drop "Not enough rage" and friends

    -- Group finder player filters (LFG.lua)
    lfgFilters          = false,
    lfgClasses          = "",       -- ticked classes, "MAGE,PRIEST"; none: any
    lfgRoles            = "",       -- ticked roles, "TANK,HEALER"; none: any
    lfgMinLevel         = 0,        -- 0: no lower bound
    lfgMaxLevel         = 0,        -- 0: no upper bound
    lfgPlayersOnly      = true,     -- hide groups, leaving the individuals
    lfgPanelOpen        = false,    -- the filter panel flown out beside the finder

    -- Waypoint arrow: top centre, pointing at the tracked quest or the map pin
    arrow               = false,
    arrowLocked         = true,     -- click-through until unlocked to move it
    arrowScale          = 1.0,
    arrowStyle          = "bevel",  -- see ARROW_STYLES in Arrow.lua
    arrowDirectionColour = true,    -- green ahead, red behind; off: always green
    arrowCustomColor    = false,    -- one color of your choosing; overrides the above
    arrowColorR         = 0.2,
    arrowColorG         = 1.0,
    arrowColorB         = 0.25,
    arrowShowDistance   = true,
    arrowShowName       = true,
    arrowAlpha          = 1.0,
    arrowAnchor         = "TOP",
    arrowRelAnchor      = "TOP",
    arrowX              = 0,
    arrowY              = -60,

    -- Threat meter: every group member's threat on your target, in combat
    threat              = false,
    threatLocked        = true,     -- no dragging or resizing
    threatClickThrough  = true,     -- the mouse passes through, always
    threatClickThroughCombat = true, -- ... or only while in combat
    -- Bars
    threatClassColours  = true,     -- off: coloured by threat status
    threatShowPets      = true,
    threatAlwaysMe      = true,     -- keep your own bar on a full meter
    threatShowTitle     = true,
    threatGrowUp        = false,    -- the bottom edge holds still instead
    -- Warning
    threatWarn          = false,
    threatWarnSound     = true,
    threatWarnSoundID   = "",       -- from the auras' sound list; blank: raid warning
    threatWarnAt        = 90,       -- percent of the tank's threat
    -- Size and look
    threatWidth         = 220,
    threatRowHeight     = 16,
    threatMaxRows       = 10,
    threatScale         = 1.0,
    threatAlpha         = 1.0,
    threatBgAlpha       = 0.75,
    -- When to show
    threatSolo          = false,
    threatParty         = true,
    threatRaid          = true,
    threatOutOfCombat   = false,
    threatShowEmpty     = false,    -- keep it up when nobody has threat yet
    threatTargetTarget  = false,    -- a friend targeted: use what they fight
    threatShowAbove     = 0,        -- only once your threat passes this
    threatLinger        = 0,        -- seconds to stay up after the fight
    -- Where to show
    threatWorld         = true,
    threatDungeon       = true,
    threatRaidZone      = true,
    threatPvP           = false,
    threatAnchor        = "TOP",
    threatRelAnchor     = "TOP",
    threatX             = 0,
    threatY             = -230,
}

-------------------------------------------------------------------------------
-- Baked overrides
-------------------------------------------------------------------------------
-- This client does not read per-account or per-character SavedVariables back on
-- a cold start -- it writes them correctly on logout and then comes up blank.
-- A /reload round-trips fine, so a setting changed in game holds until the
-- client is closed and then reverts to defaults.
--
-- That is a client bug and no addon can fix it. What an addon can do is carry
-- its settings in code, which is what this table is for: anything set here wins
-- over the defaults above and survives a cold start, because it is not saved
-- data, it is source. "/chair plus bake" prints the lines to paste in.
--
-- Settings changed in game still win over this table for the rest of the
-- session, so baking something does not stop you toggling it.

ns.baked = {
    -- ["repairGuildFunds"] = true,
    -- ["osdAnchor"] = "TOPLEFT", ["osdX"] = 20, ["osdY"] = -20,
}

-------------------------------------------------------------------------------
-- Quest automation blocklists
-------------------------------------------------------------------------------
-- NPCs whose quests must never be automated, because handing one in has a
-- consequence you cannot take back -- it consumes an item, spends a currency,
-- or locks in a faction choice. Cut to NPCs that exist in this client's
-- world, since an ID for a Dragonflight NPC can never
-- match here and only makes the list harder to read.
--
-- Keyed by NPC ID as a string, because that is what strsplit gives back from a
-- GUID. Add your own; this is source, so entries here survive a cold start.

ns.blockedNPCs = {
    ["15192"] = "Anachronos (Caverns of Time)",
    ["6566"]  = "Estelle Gendry (Heirloom Curator, Undercity)",
    ["6294"]  = "Krom Stoutarm (Heirloom Curator, Ironforge)",
    ["18166"] = "Khadgar (Aldor/Scryer allegiance, Shattrath)",
    ["55402"] = "Korgol Crushskull (Darkmoon Faire, Pit Master)",
}

-- NPCs that are safe to accept and turn in for, but must not have their quest
-- list auto-selected -- their quests exist only to eat an item you are holding.
ns.blockedSelectNPCs = {
    ["12944"] = "Lokhtos Darkbargainer (Thorium Brotherhood, BRD)",
    ["10307"] = "Witch Doctor Mau'ari (E'Ko quests, Winterspring)",
}

-- Quest IDs never to select or accept.
ns.blockedQuests = {
}

-- Item IDs never to sell, even though they are grey and have a sell price.
-- Some grey items are quest starters or turn-ins, and the only thing that
-- distinguishes them from vendor trash is knowing. Add IDs here as you find
-- them; being source, they survive a cold start.
ns.blockedItems = {
    -- [1234] = "Something you would rather keep",
}

-------------------------------------------------------------------------------
-- Settings resolution
-------------------------------------------------------------------------------
-- Three layers, lowest first: the defaults above, then the baked table, then
-- whatever this character's profile in ChairPlusDB holds. Only keys that
-- exist in the defaults are honoured from the saved file, so a stale key from
-- an older version cannot quietly reappear as a live setting.

local function CoerceToDefault(key, value)
    local want = type(ns.defaults[key])
    if want == "nil" then return nil end
    local got = type(value)
    if got ~= want then return nil end
    if want == "number" then return ns.Num(value) end
    return value
end

-------------------------------------------------------------------------------
-- Per-character profiles
-------------------------------------------------------------------------------
-- Settings and window positions belong to the character. They live in
-- ChairPlusDB.profiles, keyed by player GUID the way ChairTracker keys its
-- own: a name and a realm are strings the client can render differently from
-- one login to the next, and a key that comes back different is a key that is
-- not there. What was learned rather than chosen -- flight times, the flight
-- speed factor -- stays at the top of ChairPlusDB, shared by every character.
--
-- Settings used to be account-wide, in ChairPlusDB.settings and .movers. Those
-- are left in place as the starting point for any character that has no
-- profile yet, so each character keeps the setup it had the day this changed
-- and nobody logs in to find everything reset.

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = DeepCopy(inner) end
    return out
end

-- The key, and whether it came from the GUID. Before the GUID can be read the
-- name is used, and PLAYER_LOGIN asks again (see Core.lua).
function ns.ProfileKey()
    local okG, guid = pcall(_G.UnitGUID, "player")
    guid = okG and ns.Text(guid) or nil
    if guid then return "guid:" .. guid, true end
    local okN, name = true, Chaircraft.UnitFullName("player")
    local okR, realm = pcall(_G.GetRealmName)
    return (okN and ns.Text(name) or "Unknown") .. "-"
        .. (okR and ns.Text(realm) or "Unknown"), false
end

-- This character's profile: { label, settings, movers }.
function ns.Profile()
    local db = _G.ChairPlusDB
    if type(db) ~= "table" then
        db = {}
        _G.ChairPlusDB = db
    end
    if type(db.profiles) ~= "table" then db.profiles = {} end

    local key, fromGuid = ns.ProfileKey()
    local profile = db.profiles[key]
    -- A profile made under this session's name-based key, before the GUID
    -- could be read, moves to the GUID key rather than being left behind.
    if type(profile) ~= "table" and fromGuid and ns.profileKey
        and not ns.profileKeyFromGuid and type(db.profiles[ns.profileKey]) == "table" then
        profile = db.profiles[ns.profileKey]
        db.profiles[ns.profileKey] = nil
        db.profiles[key] = profile
    end
    if type(profile) ~= "table" then
        profile = {
            settings = type(db.settings) == "table" and DeepCopy(db.settings) or {},
            movers = type(db.movers) == "table" and DeepCopy(db.movers) or {},
        }
        db.profiles[key] = profile
        ns.profileWasNew = true
    end
    if type(profile.settings) ~= "table" then profile.settings = {} end
    if type(profile.movers) ~= "table" then profile.movers = {} end
    local okN, name = true, Chaircraft.UnitFullName("player")
    local okR, realm = pcall(_G.GetRealmName)
    name, realm = okN and ns.Text(name) or nil, okR and ns.Text(realm) or nil
    if name then profile.label = realm and (name .. "-" .. realm) or name end

    ns.profileKey, ns.profileKeyFromGuid = key, fromGuid
    return profile
end

-------------------------------------------------------------------------------
-- Copying another character's settings
-------------------------------------------------------------------------------
-- Every part that keeps settings per character keys them the same way --
-- "guid:" and the character's GUID -- so one character can be copied across
-- all of them at once: ChairPlus here, ChairSnack's bars and ChairTracker's
-- bars and factions. Auras are account-wide and have nothing to copy.

local function Stores()
    local snack = Chaircraft.ChairSnack
    local snackDB = _G.SnapSnackDB
    local tracker = _G.WOWFTrackerAccountDB
    return {
        plus = type(_G.ChairPlusDB) == "table" and _G.ChairPlusDB.profiles or nil,
        snack = type(snackDB) == "table" and snackDB.profiles or nil,
        snackAddon = snack,
        tracker = type(tracker) == "table" and tracker.profiles or nil,
    }
end

-- Every other character with settings in any part: { key, label, parts }.
function ns.OtherCharacters()
    ns.Profile()
    local here = ns.profileKey
    local stores = Stores()
    local byKey = {}
    local function Add(key, label, part)
        if type(key) ~= "string" or key == here then return end
        -- Only GUID keys: a name key is a leftover from before the GUID could
        -- be read, and is the same character as a GUID one.
        if key:sub(1, 5) ~= "guid:" then return end
        local entry = byKey[key]
        if not entry then
            entry = { key = key, parts = {} }
            byKey[key] = entry
        end
        if type(label) == "string" and label ~= "" and (not entry.label or label:find("-", 1, true)) then
            entry.label = label
        end
        entry.parts[#entry.parts + 1] = part
    end
    for key, p in pairs(stores.plus or {}) do Add(key, type(p) == "table" and p.label, "Plus") end
    for key, p in pairs(stores.snack or {}) do Add(key, type(p) == "table" and p.label, "Snack") end
    for key, p in pairs(stores.tracker or {}) do Add(key, type(p) == "table" and p.label, "Tracker") end

    local list = {}
    for _, entry in pairs(byKey) do
        entry.label = entry.label or "Unnamed character"
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

-- Copy `key`'s settings over this character's in every part that has them.
-- ChairPlus takes effect at once; the other parts read their profile at load,
-- so the caller reloads the UI afterwards. Returns the parts copied.
function ns.CopyCharacter(key)
    local stores = Stores()
    local copied = {}
    if type(key) ~= "string" or key == ns.profileKey then return copied end

    local source = stores.plus and stores.plus[key]
    if type(source) == "table" then
        local profile = ns.Profile()
        -- In place, so everything holding this character's tables sees it.
        wipe(profile.settings)
        for k, v in pairs(DeepCopy(source.settings or {})) do profile.settings[k] = v end
        wipe(profile.movers)
        for k, v in pairs(DeepCopy(source.movers or {})) do profile.movers[k] = v end
        ns.LoadSettings()
        ns.ApplyAll()
        copied[#copied + 1] = "Plus"
    end

    local snack = stores.snackAddon
    if stores.snack and stores.snack[key] and snack and type(snack.CopyProfileFrom) == "function" then
        local ok, done = pcall(snack.CopyProfileFrom, snack, key)
        if ok and done then copied[#copied + 1] = "Snack" end
    end

    local tracker = stores.tracker
    local mine = ns.profileKey
    if tracker and type(tracker[key]) == "table" and mine then
        local copy = DeepCopy(tracker[key])
        copy.label = tracker[mine] and tracker[mine].label or copy.label
        tracker[mine] = copy
        copied[#copied + 1] = "Tracker"
    end
    return copied
end

function ns.LoadSettings()
    local profile = ns.Profile()

    local resolved = {}
    for key, value in pairs(ns.defaults) do
        resolved[key] = value
    end
    for key, value in pairs(ns.baked) do
        local clean = CoerceToDefault(key, value)
        if clean ~= nil then resolved[key] = clean end
    end
    for key, value in pairs(profile.settings) do
        local clean = CoerceToDefault(key, value)
        if clean ~= nil then resolved[key] = clean end
    end

    ns.settings = resolved
    ns.saved = profile.settings

    -- Tells the truth about the bug rather than guessing: a session that came
    -- up with nothing saved is a cold start the client blanked, and /chair plus status
    -- says so instead of leaving you wondering where a setting went.
    ns.savedWasEmpty = (next(profile.settings) == nil)
end

-- The shipped position, as the four keys that describe it. Read off the
-- defaults rather than written out again, so "reset" and "default" cannot
-- drift apart the next time the corner changes.
function ns.DefaultOSDPosition()
    return {
        osdAnchor = ns.defaults.osdAnchor,
        osdRelAnchor = ns.defaults.osdRelAnchor,
        osdX = ns.defaults.osdX,
        osdY = ns.defaults.osdY,
    }
end

function ns.IsEnabled(key)
    local settings = ns.settings or ns.defaults
    return settings[key] and true or false
end

function ns.Get(key)
    local settings = ns.settings or ns.defaults
    return settings[key]
end

-- Write a setting, persist it, and re-apply everything. Re-applying all modules
-- rather than just the one that changed is deliberate: sub-options like
-- osdBagsAll belong to a different module than the key implies, and a full pass
-- over a handful of cheap Apply functions is not worth being clever about.
function ns.Set(key, value)
    if ns.defaults[key] == nil then return false end
    local clean = CoerceToDefault(key, value)
    if clean == nil then return false end
    if not ns.settings then ns.LoadSettings() end
    ns.settings[key] = clean
    if ns.saved then ns.saved[key] = clean end
    ns.ApplyAll()
    return true
end

-- Write several settings as one change. Saving a dragged frame means writing
-- four keys, and doing that through ns.Set would re-apply the OSD after each
-- one -- re-anchoring it three times from half-updated values on the way to the
-- right answer, which is visible as a twitch at the end of every drag.
function ns.SetMany(values)
    if not ns.settings then ns.LoadSettings() end
    local wrote = false
    for key, value in pairs(values) do
        if ns.defaults[key] ~= nil then
            local clean = CoerceToDefault(key, value)
            if clean ~= nil then
                ns.settings[key] = clean
                if ns.saved then ns.saved[key] = clean end
                wrote = true
            end
        end
    end
    if wrote then ns.ApplyAll() end
    return wrote
end

-- Everything that currently differs from the shipped defaults, which is exactly
-- what would be lost on a cold start and therefore what is worth baking.
function ns.Diffs()
    local out = {}
    local settings = ns.settings or ns.defaults
    for key, value in pairs(ns.defaults) do
        if settings[key] ~= value then
            out[#out + 1] = { key = key, value = settings[key] }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end
