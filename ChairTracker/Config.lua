----------------------------------------------------------------------
-- Config.lua — Defaults for ChairTracker
----------------------------------------------------------------------

WOWFTracker_Defaults = {
    -- Bar appearance
    barWidth    = 220,
    barHeight   = 16,
    rowSpacing  = 2,
    barTexture  = "Interface\\TargetingFrame\\UI-StatusBar",
    fontFace    = "Fonts\\FRIZQT__.TTF",
    fontSize    = 10,
    bgAlpha     = 0.80,
    borderAlpha = 0.70,
    frameAlpha  = 1.0,
    locked      = false,
    showHeader  = true,
    windowVisible = false,   -- a new install starts with the window off

    -- Sorting: "name_asc", "name_desc", "standing_asc", "standing_desc", "progress", "category", "custom"
    sortMode    = "name_asc",

    -- Auto-hide: bar list hides after delay, fades in on header hover
    autoHide    = false,
    fadeTime    = 0.3,   -- seconds for fade in/out
    showTime    = 5.0,   -- seconds to keep visible after mouse leaves

    -- Display: show cumulative progress toward Exalted
    showTotalToExalted = false,

    -- Which factions to track (faction ID = true)
    factions = {},

    -- Which skills to track (key = "skill:SkillName" = true)
    skills = {},
}

-- Ordered list for custom sort (array of faction IDs and "skill:Name" keys)
WOWFTracker_DefaultOrder = {}

----------------------------------------------------------------------
-- Default window position
----------------------------------------------------------------------
-- Screen centre. A saved position wins over this, so dragging the window
-- sticks; this is only where a fresh install puts it.
WOWFTracker_DefaultPosition = {
    point    = "CENTER",
    relPoint = "CENTER",
    x        = 0,
    y        = 0,
}

-- Colors for each standing level (r, g, b)
WOWFTracker_StandingColors = {
    [1] = { r = 0.80, g = 0.13, b = 0.13 },  -- Hated
    [2] = { r = 0.90, g = 0.20, b = 0.20 },  -- Hostile
    [3] = { r = 0.90, g = 0.45, b = 0.15 },  -- Unfriendly
    [4] = { r = 0.90, g = 0.80, b = 0.20 },  -- Neutral
    [5] = { r = 0.30, g = 0.80, b = 0.30 },  -- Friendly
    [6] = { r = 0.20, g = 0.70, b = 0.50 },  -- Honored
    [7] = { r = 0.30, g = 0.50, b = 0.90 },  -- Revered
    [8] = { r = 0.60, g = 0.40, b = 0.90 },  -- Exalted
}

-- Skill bar colors by category
WOWFTracker_SkillColors = {
    profession = { r = 0.85, g = 0.55, b = 0.15 },  -- Warm orange/copper
    weapon     = { r = 0.70, g = 0.70, b = 0.75 },  -- Silver
    secondary  = { r = 0.55, g = 0.75, b = 0.35 },  -- Olive green
    default    = { r = 0.60, g = 0.60, b = 0.60 },  -- Gray
}

-- Known profession names (for color categorization)
WOWFTracker_Professions = {
    ["Alchemy"] = "profession", ["Blacksmithing"] = "profession",
    ["Enchanting"] = "profession", ["Engineering"] = "profession",
    ["Herbalism"] = "profession", ["Jewelcrafting"] = "profession",
    ["Leatherworking"] = "profession", ["Mining"] = "profession",
    ["Skinning"] = "profession", ["Tailoring"] = "profession",
    ["Cooking"] = "secondary", ["First Aid"] = "secondary",
    ["Fishing"] = "secondary", ["Archaeology"] = "secondary",
}

-- Weapon skill lines, keyed by the item subclass that trains them. On a
-- client whose skills panel an addon cannot read, the subclass of whatever
-- is equipped is the only thing that names the skill behind it.
WOWFTracker_WeaponSkills = {
    ["One-Handed Axes"]   = "Axes",
    ["Two-Handed Axes"]   = "Two-Handed Axes",
    ["One-Handed Maces"]  = "Maces",
    ["Two-Handed Maces"]  = "Two-Handed Maces",
    ["One-Handed Swords"] = "Swords",
    ["Two-Handed Swords"] = "Two-Handed Swords",
    ["Daggers"]           = "Daggers",
    ["Fist Weapons"]      = "Fist Weapons",
    ["Polearms"]          = "Polearms",
    ["Staves"]            = "Staves",
    ["Bows"]              = "Bows",
    ["Crossbows"]         = "Crossbows",
    ["Guns"]              = "Guns",
    ["Thrown"]            = "Thrown",
    ["Wands"]             = "Wands",
}

-- Every weapon skill line, including the ones no item can name: Defense
-- comes off a shield or nothing at all, Unarmed off an empty hand, and
-- Feral Combat off a druid's forms. Used to tell whether the skill list a
-- client handed back covers weapons at all.
WOWFTracker_WeaponSkillNames = {
    ["Axes"] = true, ["Two-Handed Axes"] = true,
    ["Maces"] = true, ["Two-Handed Maces"] = true,
    ["Swords"] = true, ["Two-Handed Swords"] = true,
    ["Daggers"] = true, ["Fist Weapons"] = true, ["Polearms"] = true,
    ["Staves"] = true, ["Unarmed"] = true,
    ["Bows"] = true, ["Crossbows"] = true, ["Guns"] = true,
    ["Thrown"] = true, ["Wands"] = true,
    ["Defense"] = true, ["Feral Combat"] = true,
}

WOWFTracker_StandingLabels = {
    [1] = "Hated", [2] = "Hostile", [3] = "Unfriendly", [4] = "Neutral",
    [5] = "Friendly", [6] = "Honored", [7] = "Revered", [8] = "Exalted",
}

WOWFTracker_SortModes = {
    -- Plain ">" rather than an arrow character: this client's font has no
    -- arrow, and drew each one as an empty square.
    { key = "name_asc",     label = "Name (A > Z)" },
    { key = "name_desc",    label = "Name (Z > A)" },
    { key = "standing_desc",label = "Standing (High > Low)" },
    { key = "standing_asc", label = "Standing (Low > High)" },
    { key = "progress",     label = "Progress %" },
    { key = "category",     label = "Category" },
    { key = "custom",       label = "Custom Order" },
}

-- Group order for the Category sort: "faction", then the skill categories
-- from WOWFTracker_SkillColors. Name A → Z within each group.
WOWFTracker_CategoryOrder = { "faction", "profession", "secondary", "weapon" }

-- Skill headers and names to exclude from the picker
WOWFTracker_SkillFilters = {
    -- Entire header categories to skip
    headers = {
        ["Class Skills"] = true,
        ["Armor"] = true,
        ["Armor Proficiencies"] = true,
        ["Languages"] = true,
    },
    -- Individual skill names to skip
    names = {
        ["Riding"] = true,
        ["Cloth"] = true,
        ["Leather"] = true,
        ["Mail"] = true,
        ["Plate Mail"] = true,
        ["Shield"] = true,
    },
}

WOWFTracker_BarTextures = {
    { name = "Default",    path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { name = "Smooth",     path = "Interface\\Buttons\\WHITE8X8" },
    { name = "Raid",       path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { name = "Blizzard",   path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
}

----------------------------------------------------------------------
-- TBC Dungeon → Faction rep guide
-- maxStanding: highest standing where this source still gives rep
--   8 = Exalted, 7 = Revered, 6 = Honored, 5 = Friendly
----------------------------------------------------------------------
WOWFTracker_DungeonData = {
    -- Honor Hold (Alliance)
    [946] = {
        { name = "Hellfire Ramparts",   mode = "Normal",  maxStanding = 6 },
        { name = "The Blood Furnace",   mode = "Normal",  maxStanding = 6 },
        { name = "The Shattered Halls", mode = "Normal",  maxStanding = 8 },
        { name = "Hellfire Ramparts",   mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Blood Furnace",   mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Shattered Halls", mode = "Heroic",  maxStanding = 8, minStanding = 7 },
    },
    -- Thrallmar (Horde)
    [947] = {
        { name = "Hellfire Ramparts",   mode = "Normal",  maxStanding = 6 },
        { name = "The Blood Furnace",   mode = "Normal",  maxStanding = 6 },
        { name = "The Shattered Halls", mode = "Normal",  maxStanding = 8 },
        { name = "Hellfire Ramparts",   mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Blood Furnace",   mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Shattered Halls", mode = "Heroic",  maxStanding = 8, minStanding = 7 },
    },
    -- Cenarion Expedition
    [942] = {
        { name = "The Slave Pens",      mode = "Normal",  maxStanding = 6 },
        { name = "The Underbog",        mode = "Normal",  maxStanding = 6 },
        { name = "The Steamvault",      mode = "Normal",  maxStanding = 8 },
        { name = "The Slave Pens",      mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Underbog",        mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Steamvault",      mode = "Heroic",  maxStanding = 8, minStanding = 7 },
    },
    -- Lower City
    [1011] = {
        { name = "Auchenai Crypts",     mode = "Normal",  maxStanding = 6 },
        { name = "Sethekk Halls",       mode = "Normal",  maxStanding = 8 },
        { name = "Shadow Labyrinth",    mode = "Normal",  maxStanding = 8 },
        { name = "Auchenai Crypts",     mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "Sethekk Halls",       mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "Shadow Labyrinth",    mode = "Heroic",  maxStanding = 8, minStanding = 7 },
    },
    -- The Sha'tar
    [935] = {
        { name = "The Mechanar",        mode = "Normal",  maxStanding = 8 },
        { name = "The Botanica",        mode = "Normal",  maxStanding = 8 },
        { name = "The Arcatraz",        mode = "Normal",  maxStanding = 8 },
        { name = "The Mechanar",        mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Botanica",        mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Arcatraz",        mode = "Heroic",  maxStanding = 8, minStanding = 7 },
    },
    -- Keepers of Time
    [989] = {
        { name = "Old Hillsbrad Foothills", mode = "Normal",  maxStanding = 6 },
        { name = "The Black Morass",        mode = "Normal",  maxStanding = 8 },
        { name = "Old Hillsbrad Foothills", mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        { name = "The Black Morass",        mode = "Heroic",  maxStanding = 8, minStanding = 7 },
    },
    -- The Consortium
    [933] = {
        { name = "Mana-Tombs",          mode = "Normal",  maxStanding = 6 },
        { name = "Mana-Tombs",          mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        note = "Also: Ethereum Prison keys, Zaxxis Insignia turn-ins, Nagrand crystal turn-ins.",
    },
    -- The Violet Eye
    [967] = {
        { name = "Karazhan",            mode = "Raid",    maxStanding = 8 },
    },
    -- The Scale of the Sands
    [990] = {
        { name = "Hyjal Summit",        mode = "Raid",    maxStanding = 8 },
    },
    -- Ashtongue Deathsworn
    [1012] = {
        { name = "Black Temple",        mode = "Raid",    maxStanding = 8 },
    },
    -- Sporeggar
    [970] = {
        { name = "The Underbog",        mode = "Normal",  maxStanding = 6 },
        { name = "The Underbog",        mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        note = "Also: Mature Spore Sac, Bog Lord Tendril, and Sanguine Hibiscus turn-ins.",
    },
    -- Shattered Sun Offensive
    [1077] = {
        { name = "Magisters' Terrace",  mode = "Normal",  maxStanding = 8 },
        { name = "Magisters' Terrace",  mode = "Heroic",  maxStanding = 8, minStanding = 7 },
        note = "Also: Isle of Quel'Danas daily quests.",
    },
    -- Netherwing
    [1015] = {
        note = "Daily quests at Netherwing Ledge (requires flying mount). No dungeons.",
    },
    -- Ogri'la
    [1038] = {
        note = "Daily quests at Ogri'la plateau in Blade's Edge Mountains. No dungeons.",
    },
    -- The Scryers
    [934] = {
        note = "Turn-ins: Firewing Signets (to Honored), Sunfury Signets (to Exalted), Arcane Tomes (to Exalted).",
    },
    -- The Aldor
    [932] = {
        note = "Turn-ins: Marks of Kil'jaeden (to Honored), Marks of Sargeras (to Exalted), Fel Armaments (to Exalted).",
    },
    -- Mag'har (Horde)
    [941] = {
        note = "Quests in Nagrand. Obsidian Warbeads turn-in. Ogre grinding in Nagrand.",
    },
    -- Kurenai (Alliance)
    [978] = {
        note = "Quests in Nagrand. Obsidian Warbeads turn-in. Ogre grinding in Nagrand.",
    },
}
