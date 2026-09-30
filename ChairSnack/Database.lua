-- SnapSnack Database.lua
-- SavedVariables schema, migration, and per-character profiles.
--
-- Shape:
--   SnapSnackDB.version              -- schema version
--   SnapSnackDB.profiles["Name-Realm"] = { grids, nextGridID, minimap }
--   SnapSnackDB.global               = { bankItems, altItems }
--
-- Bank/alt item counts are deliberately account-wide: the item tooltips show
-- what your other characters are carrying, which only works if every character
-- writes into one shared table.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

local GetItemInfo = addon.GetItemInfo

local DB_VERSION = 2

-- Keybind storage schema. Up here with the other schema constant rather
-- than beside the migration that reads it: compaction consults it too,
-- and a local declared further down the file is not in scope up here.
local KEYBIND_SCHEMA = 2

-- The auto food/drink bar is a reserved grid. String IDs work everywhere a
-- numeric one does; user grids only ever get integer IDs.
addon.AUTO_GRID_ID = "auto"
addon.POTION_GRID_ID = "potions"
addon.TELEPORT_GRID_ID = "teleports"
addon.ENCHANT_GRID_ID = "enchants"
addon.AMMO_GRID_ID = "ammo"
addon.BUFF_FOOD_GRID_ID = "bufffood"
local AUTO_GRID_ID = addon.AUTO_GRID_ID
local POTION_GRID_ID = addon.POTION_GRID_ID
local TELEPORT_GRID_ID = addon.TELEPORT_GRID_ID
local ENCHANT_GRID_ID = addon.ENCHANT_GRID_ID
local AMMO_GRID_ID = addon.AMMO_GRID_ID
local BUFF_FOOD_GRID_ID = addon.BUFF_FOOD_GRID_ID

-- Reserved grids are generated, cannot be deleted, and get their own config
-- panels instead of an editable item list.
local RESERVED_GRIDS = {
    [AUTO_GRID_ID] = true,
    [POTION_GRID_ID] = true,
    [TELEPORT_GRID_ID] = true,
    [ENCHANT_GRID_ID] = true,
    [AMMO_GRID_ID] = true,
    [BUFF_FOOD_GRID_ID] = true,
}
addon.RESERVED_GRIDS = RESERVED_GRIDS

-------------------------------
-- Defaults
-------------------------------

local gridDefaults = {
    name = "Grid 1",
    enabled = false,
    items = {},              -- { {itemID=, hideOnZero=, showInCombat=}, ... }
    keybinds = {},           -- ["slot:<name>" | "item:<id>"] = "KEY"
    anchor = { point = "CENTER", x = 0, y = 0 },  -- legacy; converted to pos on first layout
    columns = 4,
    iconSize = 36,
    padding = 2,
    showInCombat = false,
    showTooltips = true,
    columnGrowth = "RIGHT",  -- LEFT, CENTER, RIGHT
    rowGrowth = "DOWN",      -- UP, CENTER, DOWN
    hideWhenDead = false,
    -- Instance and group state have no macro conditional, so unlike combat and
    -- death these are evaluated in Lua at layout time.
    onlyInInstance = false,
    onlyInGroup = false,
    -- Counts at or below this turn amber; zero turns red. 0 disables it.
    lowSupply = 5,
    warnOnInstanceEntry = false,
}
addon.gridDefaults = gridDefaults

-- The auto grid carries the same appearance keys plus its own slot toggles.
local autoGridDefaults = {
    name = "Food & Drink (Auto)",
    enabled = false,
    isAuto = true,
    items = {},
    keybinds = {},
    anchor = { point = "CENTER", x = 0, y = -200 },
    columns = 4,
    iconSize = 36,
    padding = 2,
    showInCombat = false,
    showTooltips = true,
    columnGrowth = "RIGHT",
    rowGrowth = "DOWN",
    autoSlots = {
        food = true,
        drink = true,
        conjuredFood = true,
        conjuredDrink = true,
        feedPet = true,
    },
    -- Hunter pet food. In "auto" mode the list is worked out from your bags and
    -- refined by what the pet accepts, so there is nothing to configure;
    -- "manual" uses the hand-picked lists below.
    petFoodMode = "auto",
    -- petFood is the shared/default list; each pet family gets its own copy in
    -- petFoodByFamily the first time that family is summoned.
    petFood = {},
    petFoodByFamily = {},
    -- [family] = { itemID, ... } -- a hand-set feed order for the auto list.
    -- Partial: anything absent still falls in by level automatically.
    petFoodOrder = {},
    hideWhenDead = true,
    onlyInInstance = false,
    onlyInGroup = false,
    lowSupply = 5,
    warnOnInstanceEntry = false,
}
addon.autoGridDefaults = autoGridDefaults

-- Potions default to showing in combat: unlike food, this is a combat button,
-- and a bar that hides the moment you need it would be pointless.
local potionGridDefaults = {
    name = "Potions (Auto)",
    enabled = false,
    isAuto = true,
    items = {},
    keybinds = {},
    anchor = { point = "CENTER", x = 0, y = -240 },
    columns = 4,
    iconSize = 36,
    padding = 2,
    showInCombat = true,
    showTooltips = true,
    columnGrowth = "RIGHT",
    rowGrowth = "DOWN",
    autoSlots = {
        health = true,
        mana = true,
        zoneHealth = true,
        zoneMana = true,
        zoneItem = true,
        healthstone = true,
        manaGem = true,
        bandage = true,
    },
    hideWhenDead = true,
    onlyInInstance = false,
    onlyInGroup = false,
    lowSupply = 5,
    warnOnInstanceEntry = false,
}
addon.potionGridDefaults = potionGridDefaults

local teleportGridDefaults = {
    name = "Teleports (Auto)",
    enabled = false,
    isAuto = true,
    items = {},
    keybinds = {},
    anchor = { point = "CENTER", x = 0, y = -280 },
    columns = 6,
    iconSize = 36,
    padding = 2,
    showInCombat = false,
    showTooltips = true,
    columnGrowth = "RIGHT",
    rowGrowth = "DOWN",
    autoSlots = {
        hearthstone = true,
        engineering = true,
        parachute = true,
        mageTeleports = true,
        magePortals = true,
        extras = true,
    },
    -- Teleport items the built-in table does not know about.
    extras = {},
    hideWhenDead = true,
    onlyInInstance = false,
    onlyInGroup = false,
    lowSupply = 5,
    warnOnInstanceEntry = false,
}
addon.teleportGridDefaults = teleportGridDefaults

-- Weapon enhancements: sharpening stones, weightstones, oils. Shows in combat
-- because a lapsed enchant is most often noticed mid-fight.
local enchantGridDefaults = {
    name = "Weapon Enchants (Auto)",
    enabled = false,
    isAuto = true,
    items = {},
    keybinds = {},
    anchor = { point = "CENTER", x = 0, y = -320 },
    columns = 2,
    iconSize = 36,
    padding = 2,
    showInCombat = true,
    showTooltips = true,
    columnGrowth = "RIGHT",
    rowGrowth = "DOWN",
    hideWhenDead = true,
    onlyInInstance = false,
    onlyInGroup = false,
    lowSupply = 5,
    warnOnInstanceEntry = false,
    autoSlots = {
        mainHand = true,
        offHand = true,
    },
    -- Which poison line a rogue wants on each hand. Empty means the standard
    -- pairing, Instant on the main hand and Deadly on the off hand.
    poisonSlots = {},
}
addon.enchantGridDefaults = enchantGridDefaults

-- Hunter ammo. Its own bar rather than a slot on the potion bar, because a
-- count you want in the corner of your eye and a row of buttons you click in a
-- fight want to live in different places. Non-hunters never get a frame for it.
--
-- One column, and shown in combat: it is a readout, and the moment it matters
-- is the moment you are shooting.
local ammoGridDefaults = {
    name = "Ammo (Auto)",
    enabled = false,
    isAuto = true,
    items = {},
    keybinds = {},
    anchor = { point = "CENTER", x = 0, y = -200 },
    columns = 1,
    iconSize = 36,
    padding = 2,
    showInCombat = true,
    showTooltips = true,
    columnGrowth = "RIGHT",
    rowGrowth = "DOWN",
    autoSlots = {
        ammo = true,
    },
    -- Never drawn for anyone but a hunter; see PassesVisibilityRules.
    hunterOnly = true,
    hideWhenDead = true,
    onlyInInstance = false,
    onlyInGroup = false,
    -- Ammo is counted in hundreds, so the low-supply warning is set where a
    -- quiver actually starts looking thin rather than at the 5 that suits a
    -- stack of potions.
    lowSupply = 200,
    warnOnInstanceEntry = false,
}
addon.ammoGridDefaults = ammoGridDefaults

-- Buff food. Its own bar rather than a slot on the food bar, because it answers
-- a different question: the food bar is "I am hurt or low", this one is "I am
-- not buffed". Everything the player is carrying that grants a buff goes on it,
-- not just the best one -- which food you want depends on what you are about to
-- do, and the bar cannot know that.
--
-- hideWhileBuffed is the point of the whole thing: the bar is a reminder, and a
-- reminder that stays up after you have acted on it stops being read.
local buffFoodGridDefaults = {
    name = "Buff Food (Auto)",
    enabled = false,
    isAuto = true,
    items = {},
    keybinds = {},
    anchor = { point = "CENTER", x = 0, y = -160 },
    columns = 6,
    iconSize = 32,
    padding = 2,
    -- Eating is a ten second channel that breaks on damage, so a combat button
    -- would be a lie.
    showInCombat = false,
    showTooltips = true,
    columnGrowth = "RIGHT",
    rowGrowth = "DOWN",
    hideWhileBuffed = true,
    -- What the bar is allowed to pick up: "auto" trusts the classifier alone,
    -- "manual" trusts only what you ticked, "both" is the classifier plus your
    -- additions. Both is the default because the classifier is right about
    -- ordinary crafted food and cannot be right about everything.
    mode = "both",
    hideWhenDead = true,
    onlyInInstance = false,
    onlyInGroup = false,
    lowSupply = 0,
}
addon.buffFoodGridDefaults = buffFoodGridDefaults

-- Account-wide settings a fresh install starts with. Empty: the config
-- window opens centred and the buff food picker has no hand corrections.
local globalDefaults = {}

-- minimapPos: degrees round the minimap, counter-clockwise from the right,
-- the way LibDBIcon keeps it. 225 is the lower left.
local minimapDefaults = { minimapPos = 225, hide = false }
addon.minimapDefaults = minimapDefaults

local function NewProfile()
    return {
        grids = {
            [1] = addon.DeepCopy(gridDefaults),
            [AUTO_GRID_ID] = addon.DeepCopy(autoGridDefaults),
            [POTION_GRID_ID] = addon.DeepCopy(potionGridDefaults),
            [TELEPORT_GRID_ID] = addon.DeepCopy(teleportGridDefaults),
            [ENCHANT_GRID_ID] = addon.DeepCopy(enchantGridDefaults),
            [AMMO_GRID_ID] = addon.DeepCopy(ammoGridDefaults),
            [BUFF_FOOD_GRID_ID] = addon.DeepCopy(buffFoodGridDefaults),
        },
        nextGridID = 2,
        minimap = addon.DeepCopy(minimapDefaults),
    }
end

-------------------------------
-- Profile Access
-------------------------------
-- Profiles are addressed by the player GUID, not by "Name-Realm".
--
-- A name-and-realm string is not a dependable address. The client does not
-- always hand back the same one: a beta realm gets renamed, a character copy
-- comes back spelled differently, and the two are not even in agreement
-- inside WTF, which on this kind of client can file one character under two
-- different folders in the same evening. A key that comes back even slightly
-- different is a key that is not in the table, and from the outside that
-- reads as "the addon forgot everything I set up".
--
-- The readable name still matters -- it is what the profile list shows -- so
-- it is stored inside the profile instead of being used as its address.

local resolvedKey = nil

-- This client hands back "secret" values from some APIs. A secret survives
-- tostring() and throws only when something actually reads it, so the concat --
-- not the call above it -- is where the error lands. An unguarded one here would
-- take the whole profile lookup with it and leave the addon on defaults, which
-- is exactly what "it forgot my settings" looks like from the outside.
local function SafeText(value)
    if Chaircraft.IsSecret(value) then return nil end
    if value == nil then return nil end
    local ok, text = pcall(function()
        local s = "" .. tostring(value)
        if s == "" then return nil end
        return s
    end)
    if ok then return text end
    return nil
end

function addon:CharLabel()
    return (SafeText(Chaircraft.UnitFullName("player")) or "Unknown")
        .. "-" .. (SafeText(GetRealmName()) or "Unknown")
end

-- Letters and digits only, lower case. Two spellings of the same character --
-- "Chairface Chippendale" against "Chairface-Chippendale" -- collapse to one
-- string here, which is what lets an old profile still be recognised.
local function Squash(text)
    return (tostring(text or ""):lower():gsub("[^%w]", ""))
end

local function IsGUIDKey(key)
    return type(key) == "string" and key:sub(1, 5) == "guid:"
end

-- Re-file a profile written under the old name-shaped key onto the GUID key.
-- Exact spelling first, then the loose comparison above. Returns the old key
-- so the load can say what it picked up.
local function AdoptLegacyProfile(key)
    local profiles = SnapSnackDB and SnapSnackDB.profiles
    if not profiles or profiles[key] then return nil end

    local label = addon:CharLabel()
    local legacyKey = profiles[label] and label or nil

    if not legacyKey then
        local wanted = Squash(label)
        for otherKey in pairs(profiles) do
            if not IsGUIDKey(otherKey) and Squash(otherKey) == wanted then
                legacyKey = otherKey
                break
            end
        end
    end

    if not legacyKey then return nil end

    profiles[key] = profiles[legacyKey]
    profiles[legacyKey] = nil
    return legacyKey
end

-- Resolved once, then fixed for the session. A key that changed halfway
-- through would file the second half of a session's settings somewhere the
-- first half is not, which is the failure this whole scheme exists to stop.
function addon:CharKey()
    if resolvedKey then return resolvedKey end

    local guid = SafeText(UnitGUID and UnitGUID("player"))
    if not guid then
        -- No GUID yet. Answer with the name rather than inventing something,
        -- and do not cache it, so the GUID is taken the moment it exists.
        return self:CharLabel()
    end

    resolvedKey = "guid:" .. guid
    self.adoptedProfileFrom = AdoptLegacyProfile(resolvedKey)
    return resolvedKey
end

-- What to call a stored profile in the UI, now that the key no longer says.
function addon:ProfileLabel(key)
    local profile = SnapSnackDB and SnapSnackDB.profiles
        and SnapSnackDB.profiles[key]
    local label = profile and profile.label
    if type(label) == "string" and label ~= "" then return label end
    if IsGUIDKey(key) then return "Unnamed character" end
    return tostring(key)
end

function addon:GetProfile()
    local key = self:CharKey()
    local profile = SnapSnackDB.profiles[key]
    if not profile then
        profile = NewProfile()
        profile.label = self:CharLabel()
        SnapSnackDB.profiles[key] = profile
    end
    return profile
end

function addon:GetGrids()
    return self:GetProfile().grids
end

function addon:GetGrid(gridID)
    return self:GetProfile().grids[gridID]
end

function addon:GetMinimapDB()
    return self:GetProfile().minimap
end

-- Nil-safe: the database is not built until PLAYER_LOGIN now, and a few
-- read-only callers (the cooldown-number check, the bank scan) can be reached
-- from a draw that happens before then.
function addon:GetGlobal()
    return SnapSnackDB and SnapSnackDB.global
end

-------------------------------
-- Migration
-------------------------------

-- v1 stored everything flat and account-wide. Move it into the current
-- character profile; other characters start fresh.
local function MigrateV1(charKey)
    local profile = {
        grids = SnapSnackDB.grids or {},
        nextGridID = SnapSnackDB.nextGridID or 2,
        minimap = SnapSnackDB.minimap or addon.DeepCopy(minimapDefaults),
    }

    SnapSnackDB.profiles = { [charKey] = profile }
    SnapSnackDB.global = {
        bankItems = SnapSnackDB.bankItems or {},
        altItems = SnapSnackDB.altItems or {},
    }

    SnapSnackDB.grids = nil
    SnapSnackDB.nextGridID = nil
    SnapSnackDB.minimap = nil
    SnapSnackDB.bankItems = nil
    SnapSnackDB.altItems = nil
end

function addon:InitDatabase()
    -- Whether the saved data was there at all. If it was not, nothing below
    -- could have been remembered, and that is a different fault from a
    -- profile that was saved and then not found again -- so /chair snack profiles
    -- reports which of the two happened rather than leaving it to guesswork.
    self.dbWasEmpty = (SnapSnackDB == nil)

    if not SnapSnackDB then
        SnapSnackDB = {}
    end

    local charKey = self:CharKey()

    if SnapSnackDB.version == nil and SnapSnackDB.grids then
        MigrateV1(charKey)
    end

    SnapSnackDB.version = DB_VERSION
    SnapSnackDB.profiles = SnapSnackDB.profiles or {}
    SnapSnackDB.global = SnapSnackDB.global or {}
    SnapSnackDB.global.bankItems = SnapSnackDB.global.bankItems or {}
    SnapSnackDB.global.altItems = SnapSnackDB.global.altItems or {}

    -- Only fills what the file did not bring, so anything loaded still wins.
    for key, value in pairs(globalDefaults) do
        if SnapSnackDB.global[key] == nil then
            SnapSnackDB.global[key] = addon.DeepCopy(value)
        end
    end
    -- [family][itemID] = true accepted / false rejected, learned by feeding.
    SnapSnackDB.global.petFoodKnowledge = SnapSnackDB.global.petFoodKnowledge or {}

    if not SnapSnackDB.profiles[charKey] then
        -- Starting from nothing is normal on a new character and alarming on
        -- one that has been set up before, and the two are indistinguishable
        -- once the bars are on screen. Count what else is stored so the load
        -- can say so out loud instead of quietly handing back the defaults.
        local others = 0
        for _ in pairs(SnapSnackDB.profiles) do others = others + 1 end
        self.profileWasNew = true
        self.otherProfileCount = others

        SnapSnackDB.profiles[charKey] = NewProfile()
    end

    SnapSnackDB.profiles[charKey].label = self:CharLabel()

    self:RepairProfile(SnapSnackDB.profiles[charKey])
    -- Runs against the grid contents the previous session left behind, so it
    -- has to happen before the bars are rebuilt.
    self:MigrateKeybinds(SnapSnackDB.profiles[charKey])

end

-------------------------------
-- Compaction
-------------------------------
-- Drop every value that is only its own default, just before the client
-- writes the file.
--
-- Six bars each storing twenty-odd settings makes a large file out of almost
-- nothing: the great majority of those values have never been changed from
-- what the addon ships with. On this client a saved file over about four
-- kilobytes is written correctly and then never read back, and this one has
-- been over that since the day the reserved bars were added -- which is
-- exactly as long as it has been "not saving".
--
-- Nothing is lost by leaving a default out. RepairProfile fills in every
-- missing key from the same tables consulted here, so a stripped profile and
-- a full one load to the same thing.

local function StripDefaults(target, defaults)
    for key, default in pairs(defaults) do
        local current = target[key]
        if type(default) == "table" then
            if type(current) == "table" then
                StripDefaults(current, default)
                -- Emptied by the walk above, or empty to begin with: either
                -- way ApplyDefaults rebuilds it on the way back in.
                if next(current) == nil then
                    target[key] = nil
                end
            end
        elseif current == default then
            target[key] = nil
        end
    end
end

local DEFAULTS_FOR = {
    [AUTO_GRID_ID] = autoGridDefaults,
    [POTION_GRID_ID] = potionGridDefaults,
    [TELEPORT_GRID_ID] = teleportGridDefaults,
    [ENCHANT_GRID_ID] = enchantGridDefaults,
    [AMMO_GRID_ID] = ammoGridDefaults,
    [BUFF_FOOD_GRID_ID] = buffFoodGridDefaults,
}

-- Screen coordinates carry fourteen digits of precision describing a
-- position nobody can see: at this client's UI scale a whole unit is about
-- two thirds of a pixel, so the tail is pure file size.
local function Round(value)
    if type(value) ~= "number" then return value end
    return math.floor(value + 0.5)
end

local function CompactGrid(gridID, grid, keybindsMigrated)
    StripDefaults(grid, DEFAULTS_FOR[gridID] or gridDefaults)

    -- Re-derived from the grid's own ID by RepairProfile.
    grid.isAuto = nil

    if grid.pos then
        -- The v1 anchor is only ever consulted to invent a pos when there is
        -- none, and there is one.
        grid.anchor = nil
        grid.pos.x = Round(grid.pos.x)
        grid.pos.y = Round(grid.pos.y)

        -- The pivot is a function of the two growth directions, and both of
        -- those are in the file. Storing it too is storing the same fact
        -- twice; RepairProfile works it back out.
        if addon.GetPivot and grid.posPivot == addon.GetPivot(grid) then
            grid.posPivot = nil
        end
    end

    -- A generated bar decides its own contents from your bags on every login,
    -- before anything reads them, so the copy on disk is never the copy that
    -- gets used -- it is the single largest thing in the file and it is
    -- entirely dead weight.
    --
    -- The item IDs alone are kept, flat, because the bank snapshot reads them
    -- to decide what is worth recording for characters that are not logged
    -- in. Dropping those would quietly cost the alt counts in tooltips.
    --
    -- Only once the keybind conversion is done: until then the previous
    -- session's contents are what tells a saved key which item it belonged
    -- to.
    if RESERVED_GRIDS[gridID] and keybindsMigrated then
        local ids
        for _, itemData in ipairs(grid.items or {}) do
            local itemID = addon.GetItemIDFromData(itemData)
            if itemID then
                ids = ids or {}
                ids[#ids + 1] = itemID
            end
        end
        grid.items = nil
        grid.autoItems = ids
    end
end

-- Drop everything the next load can work out for itself, just before the
-- client serialises. Nothing here is a judgement call about what the user
-- might miss: every key removed is one RepairProfile puts back.
function addon:CompactProfile()
    if not SnapSnackDB then return end

    -- A witness for the next cold start. Whether the saved global ever turned up
    -- this session, and how late, is the one thing a file that comes back as
    -- defaults tomorrow cannot otherwise say.
    SnapSnackDB.lastLoad = {
        arrival = self.dbArrival,
        atAddonLoaded = self.dbAtAddonLoaded and true or false,
        atPlayerLogin = self.dbAtPlayerLogin and true or false,
        atEnteringWorld = self.dbAtEnteringWorld and true or false,
        profileWasNew = self.profileWasNew and true or false,
    }

    local profile = SnapSnackDB.profiles and SnapSnackDB.profiles[self:CharKey()]
    if profile then
        local migrated = (profile.keybindSchema or 1) >= KEYBIND_SCHEMA
        for gridID, grid in pairs(profile.grids or {}) do
            CompactGrid(gridID, grid, migrated)

            -- A reserved bar left holding nothing is a bar still set up
            -- exactly as it shipped, and RepairProfile creates those from
            -- the defaults whether they are in the file or not. A hand-made
            -- bar is not the same case: an empty one still has to be written,
            -- because its mere existence is the setting.
            if RESERVED_GRIDS[gridID] and next(grid) == nil then
                profile.grids[gridID] = nil
            end
        end

        if profile.minimap then
            StripDefaults(profile.minimap, minimapDefaults)
            if next(profile.minimap) == nil then profile.minimap = nil end
        end

        if profile.nextGridID == 2 then profile.nextGridID = nil end
    end

    -- The account-wide tables are recreated empty by InitDatabase, so an
    -- empty one on disk is two lines saying nothing.
    local global = SnapSnackDB.global
    if global then
        for key, value in pairs(global) do
            if type(value) == "table" and next(value) == nil then
                global[key] = nil
            end
        end
        if next(global) == nil then SnapSnackDB.global = nil end
    end
end

-------------------------------
-- Keybind Schema Migration
-------------------------------
-- Keys used to be stored by button position. They are now stored against what
-- the button holds -- a slot name on an automatic bar, an itemID everywhere
-- else -- so a key stops wandering onto a different item when a slot appears
-- or disappears.
--
-- The conversion runs in two phases because only half the answer exists at
-- load time. When this runs, grid.items still holds what the previous session
-- had on the bar, so position gives us the itemID a key belonged to. Which
-- automatic *slot* that item now sits in is not known until the bars have been
-- rebuilt, so those are parked and resolved straight afterwards.

local pendingByItem = {}

local function NeedsKeybindMigration(profile)
    return (profile.keybindSchema or 1) < KEYBIND_SCHEMA
end

function addon:MigrateKeybinds(profile)
    if not NeedsKeybindMigration(profile) then return end

    for gridID, grid in pairs(profile.grids or {}) do
        local old = grid.keybinds
        if type(old) == "table" then
            local converted = {}
            local parked = {}

            for index, key in pairs(old) do
                if type(index) == "number" then
                    local itemData = (grid.items or {})[index]
                    local itemID = itemData and addon.GetItemIDFromData(itemData)
                    if grid.isAuto then
                        -- Resolved once the bar has been rebuilt.
                        if itemID then parked[itemID] = key end
                    elseif itemID then
                        converted["item:" .. itemID] = key
                    end
                else
                    -- Already an identity key; leave it alone.
                    converted[index] = key
                end
            end

            grid.keybinds = converted
            if next(parked) then
                pendingByItem[gridID] = parked
            end
        end
    end

    profile.keybindSchema = KEYBIND_SCHEMA
end

-- Second phase: the automatic bars have been rebuilt, so every itemID parked
-- above can be mapped to the slot now holding it. Anything that no longer has
-- a home is dropped rather than guessed at.
function addon:ResolveKeybindMigration()
    if not next(pendingByItem) then return end

    for gridID, parked in pairs(pendingByItem) do
        local grid = self:GetGrid(gridID)
        if grid then
            grid.keybinds = grid.keybinds or {}
            for _, itemData in ipairs(grid.items or {}) do
                local itemID = addon.GetItemIDFromData(itemData)
                local key = itemID and parked[itemID]
                if key then
                    local bindID = addon.KeybindID(itemData)
                    if bindID and not grid.keybinds[bindID] then
                        grid.keybinds[bindID] = key
                    end
                end
            end
        end
    end

    pendingByItem = {}
end

-- Back-fill any keys added since the profile was written, and guarantee the
-- reserved auto grid exists.
function addon:RepairProfile(profile)
    profile.grids = profile.grids or {}
    profile.nextGridID = profile.nextGridID or 2
    profile.minimap = profile.minimap or {}
    addon.ApplyDefaults(profile.minimap, minimapDefaults)

    if not profile.grids[AUTO_GRID_ID] then
        profile.grids[AUTO_GRID_ID] = addon.DeepCopy(autoGridDefaults)
    end
    if not profile.grids[POTION_GRID_ID] then
        profile.grids[POTION_GRID_ID] = addon.DeepCopy(potionGridDefaults)
    end
    if not profile.grids[TELEPORT_GRID_ID] then
        profile.grids[TELEPORT_GRID_ID] = addon.DeepCopy(teleportGridDefaults)
    end
    -- Added in 2.55. An existing profile has never heard of it, and a grid that
    -- only appears on brand new characters would be the same bug as not
    -- shipping it at all.
    if not profile.grids[BUFF_FOOD_GRID_ID] then
        profile.grids[BUFF_FOOD_GRID_ID] = addon.DeepCopy(buffFoodGridDefaults)
    end
    if not profile.grids[ENCHANT_GRID_ID] then
        profile.grids[ENCHANT_GRID_ID] = addon.DeepCopy(enchantGridDefaults)
    end
    if not profile.grids[AMMO_GRID_ID] then
        local ammoGrid = addon.DeepCopy(ammoGridDefaults)

        -- Ammo used to be a slot on the potion bar. A profile that predates
        -- this bar has a potion bar the user has already placed, so the new
        -- frame starts just below it rather than at the middle of the screen,
        -- where nobody put it and nobody would look for it.
        local potionGrid = profile.grids[POTION_GRID_ID]
        if potionGrid and potionGrid.pos then
            ammoGrid.pos = addon.DeepCopy(potionGrid.pos)
            ammoGrid.posPivot = potionGrid.posPivot
            ammoGrid.pos.y = ammoGrid.pos.y
                - ((potionGrid.iconSize or 36) + (potionGrid.padding or 2) + 6)
        end

        -- The slot could never be switched off from the old potion panel, but
        -- a profile that did have it off keeps it off.
        local previous = potionGrid and potionGrid.autoSlots
            and potionGrid.autoSlots.ammo
        if previous == false then
            ammoGrid.autoSlots.ammo = false
        end

        profile.grids[AMMO_GRID_ID] = ammoGrid
    end

    -- The potion bar no longer owns the ammo slot; leaving the key behind would
    -- keep it in the potion panel's readout forever.
    local potionGrid = profile.grids[POTION_GRID_ID]
    if potionGrid and potionGrid.autoSlots then
        potionGrid.autoSlots.ammo = nil
    end

    -- 2.55 and 2.56 had no branch for the buff food grid in the loop below, so
    -- it was repaired from the hand-made-grid defaults: it came back named
    -- "Grid 1" with isAuto off, and that name was then written to the file
    -- because it no longer matched the default it was compared against. The
    -- loop cannot produce it again; this clears what those versions left.
    local buffFoodGrid = profile.grids[BUFF_FOOD_GRID_ID]
    if buffFoodGrid and buffFoodGrid.name == gridDefaults.name then
        buffFoodGrid.name = nil
    end

    for gridID, grid in pairs(profile.grids) do
        -- Retired in v2.43. Bars are movable while the config window is open
        -- and pinned when it is closed, so there is no lock to store and no
        -- handle to place. Left behind, these would be dead keys that look
        -- like settings.
        grid.locked = nil
        grid.dragHandleCorner = nil
        grid.hideDragHandle = nil

        -- Driven off the defaults table rather than a branch per grid. The
        -- hand-written chain this replaces had to be extended every time a
        -- reserved grid was added, and the one time it was not, the new grid
        -- was quietly repaired as a hand-made bar -- wrong name, wrong panel,
        -- and an item list something else overwrites on every bag scan.
        local reserved = DEFAULTS_FOR[gridID]
        if reserved then
            addon.ApplyDefaults(grid, reserved)
            grid.isAuto = true
        else
            addon.ApplyDefaults(grid, gridDefaults)
            grid.isAuto = nil
        end

        -- Left out of the file when it was only what the growth directions
        -- already imply. Both of those are back by now, so it derives again.
        if grid.pos and not grid.posPivot and addon.GetPivot then
            grid.posPivot = addon.GetPivot(grid)
        end
    end
end

-------------------------------
-- Profile Management
-------------------------------

-- Every stored profile except the current one, sorted by the name it shows
-- under rather than by its key, which is now a GUID and sorts meaninglessly.
function addon:ListOtherProfiles()
    local current = self:CharKey()
    local list = {}
    for key in pairs(SnapSnackDB.profiles) do
        if key ~= current then
            table.insert(list, key)
        end
    end
    table.sort(list, function(a, b)
        return self:ProfileLabel(a):lower() < self:ProfileLabel(b):lower()
    end)
    return list
end

function addon:CopyProfileFrom(sourceKey)
    local source = SnapSnackDB.profiles[sourceKey]
    if not source or sourceKey == self:CharKey() then return false end

    local copy = addon.DeepCopy(source)
    -- The copy belongs to this character now; carrying the donor's name over
    -- would leave the profile list showing two of them.
    copy.label = self:CharLabel()
    SnapSnackDB.profiles[self:CharKey()] = copy
    self:RepairProfile(copy)
    return true
end

function addon:ResetProfile()
    local fresh = NewProfile()
    fresh.label = self:CharLabel()
    SnapSnackDB.profiles[self:CharKey()] = fresh
end

function addon:DeleteProfile(key)
    if key == self:CharKey() then return false end
    SnapSnackDB.profiles[key] = nil
    return true
end

-------------------------------
-- Grid Management
-------------------------------

function addon:CreateNewGrid()
    local grids = self:GetGrids()

    local id = 1
    while grids[id] do
        id = id + 1
    end

    local grid = addon.DeepCopy(gridDefaults)
    grid.name = "Grid " .. id
    grid.anchor = { point = "CENTER", x = 50 * (id - 1), y = 0 }
    grids[id] = grid

    self.itemButtons[id] = {}
    self:CreateGridFrame(id)
    self:UpdateAllGrids()
    return id
end

function addon:DeleteGrid(gridID)
    if RESERVED_GRIDS[gridID] then return false end

    local frame = self.frames[gridID]
    if frame then
        frame:Hide()
        frame:SetParent(nil)
        self.frames[gridID] = nil
    end

    for _, button in ipairs(self.itemButtons[gridID] or {}) do
        ClearOverrideBindings(button)
    end
    self.itemButtons[gridID] = nil
    self:GetGrids()[gridID] = nil
    return true
end

-------------------------------
-- Dropping Items Onto A Bar
-------------------------------

-- Which list, if any, a dropped item joins.
--
-- The automatic bars generate their own contents, so a drop has to be answered
-- rather than silently swallowed. Teleports is the exception: its Extra
-- Teleports list exists for exactly this.
function addon:DropTargetList(gridID)
    if gridID == self.TELEPORT_GRID_ID then
        local grid = self:GetGrid(gridID)
        if grid then
            grid.extras = grid.extras or {}
            return grid.extras, "Extra Teleports"
        end
        return nil
    end

    if self.RESERVED_GRIDS[gridID] then return nil end

    local grid = self:GetGrid(gridID)
    if not grid then return nil end
    grid.items = grid.items or {}
    return grid.items, grid.name
end

-- Add a dropped item. index inserts at that position; nil appends.
function addon:DropItemOnGrid(gridID, itemID, index)
    if not itemID then return false end

    local list, label = self:DropTargetList(gridID)
    if not list then
        self:Print("That bar chooses its own contents.")
        return false
    end

    for _, existing in ipairs(list) do
        if addon.GetItemIDFromData(existing) == itemID then
            return false   -- already there; a silent no-op reads as "accepted"
        end
    end

    local entry = {
        itemID = itemID,
        hideOnZero = addon.IsConjuredItem(itemID),
        showInCombat = false,
    }

    if index and index <= #list then
        table.insert(list, index, entry)
    else
        table.insert(list, entry)
    end

    local name = GetItemInfo(itemID)
    if name and label then
        self:Print(name .. " added to " .. label .. ".")
    end
    return true
end

-- Remove the entry a button stands for. Only hand-made lists can be edited this
-- way; a generated bar would simply put it back.
function addon:RemoveItemFromGrid(gridID, index)
    local list = self:DropTargetList(gridID)
    if not list or not index or not list[index] then return nil end

    local itemID = addon.GetItemIDFromData(list[index])
    table.remove(list, index)
    return itemID
end

-- Auto grid first, then user grids by name.
function addon:GetGridList()
    local list = {}
    for id, data in pairs(self:GetGrids()) do
        -- The ammo bar is hunter-only. The grid still exists in every profile
        -- so a hunter alt keeps its settings, but it is not offered anywhere a
        -- warrior could wonder what it is for.
        if id ~= AMMO_GRID_ID or self:IsHunter() then
            table.insert(list, { id = id, name = data.name })
        end
    end
    local order = { [AUTO_GRID_ID] = 1, [BUFF_FOOD_GRID_ID] = 2,
                    [POTION_GRID_ID] = 3, [AMMO_GRID_ID] = 4,
                    [TELEPORT_GRID_ID] = 5, [ENCHANT_GRID_ID] = 6 }
    table.sort(list, function(a, b)
        local ra, rb = order[a.id], order[b.id]
        if ra or rb then
            if ra and rb then return ra < rb end
            return ra ~= nil
        end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return list
end
