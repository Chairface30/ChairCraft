-- SnapSnack ItemData.lua
-- What the consumables are, by item ID and by spell ID.
--
-- Classification used to be read out of the tooltip: find the word "health" on
-- a line, parse the number in front of it, decide from that what an item was.
-- That worked until it did not. On a client where the scanning tooltip came
-- back with nothing to read, every item in the game classified as restoring
-- nothing -- no food, no drink, no potions, no bandages -- and there was no
-- error anywhere to say why. Prose is also the one part of an item that gets
-- translated, reworded between patches, and shared with items that are not
-- consumables at all.
--
-- So nothing here reads words. There are two sources of truth, in this order:
--
--   1. CONSUMABLE_DATA below -- item ID to exactly what it is and what it
--      restores, read from each item's own Wowhead TBC tooltip. This is what
--      makes "the strongest potion I am carrying" a fact rather than a guess.
--
--   2. The item's use SPELL, from GetItemSpell. Every consumable line in the
--      game shares one spell per effect family: all food is Food, all water is
--      Drink, every healing potion from Minor to Auchenai is Healing Potion,
--      mana gems are Replenish Mana, bandages are First Aid. Ale and wine are
--      Weak Alcohol, so they fall out on their own -- which is what the old
--      "does it restore anything" check was really for.
--
-- The second is what covers the long tail: the hundreds of cooked foods, and
-- anything a later patch adds. It needs no list and no words, only the anchor
-- spell IDs below -- a family is matched by comparing against the localised
-- name the client gives for those IDs, so it holds on any locale.
--
-- Every row carries the item's `name`. Nothing reads it at runtime; it is there
-- so `/chair snack data` can ask the client what each ID actually is and say which rows
-- disagree. An ID list is only as good as its IDs, and a typo in one is
-- otherwise completely silent -- the item it describes simply never appears,
-- and some unrelated item quietly gains a classification it should not have.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

-------------------------------
-- Spell Anchors
-------------------------------
-- One known spell ID per effect family. The name is never written down here:
-- it is asked of the client at runtime, so a French client matches French
-- tooltips with no translation table.
--
-- Ranks all share a name, so any one rank anchors the whole family:
--   food          433 Food            (434, 435, 1127 ... 33253 all "Food")
--   drink         430 Drink           (431, 432, 1133 ... 27089 all "Drink")
--   refreshment 44166 Refreshment     restores health AND mana: table food
--   healing       439 Healing Potion  (440, 441, 2024 ... 28495)
--   mana          437 Restore Mana    (438, 2023, 11903 ... 28499)
--   gem          5405 Replenish Mana  mage mana gems, distinct from potions
--   bandage       746 First Aid       (27030 and every cloth tier between)
local SPELL_ANCHORS = {
    food        = 433,
    -- Buff food on this build casts its own spell line: "Nutritious Food"
    -- rather than "Food". That is why a Herb Baked Egg reached none of the food
    -- paths at all -- its use spell was in no family, so it was not food, so
    -- nothing downstream could see it. Anchored on the same principle as the
    -- rest: one known member of the line, matched by the name the client gives
    -- it, with no English in the code.
    nutritious  = 1248377,
    drink       = 430,
    refreshment = 44166,
    healing     = 439,
    mana        = 437,
    gem         = 5405,
    bandage     = 746,
}
addon.SPELL_ANCHORS = SPELL_ANCHORS

-- The plain food ranks: restore only, with no Well Fed buff riding along.
--
-- On this build the separation is cleaner than this list -- buff food is its
-- own spell line, the nutritious family above -- but the list still decides for
-- any client where both share the name "Food", so it stays. 7737 was found in
-- the wild on a Raw Brilliant Smallfish, which restores and nothing else; it
-- was missing here, so anything using it read as buff food.
local PLAIN_FOOD_SPELLS = {
    [433] = true, [434] = true, [435] = true, [1127] = true,
    [1129] = true, [1131] = true, [7737] = true, [29073] = true,
}
addon.PLAIN_FOOD_SPELLS = PLAIN_FOOD_SPELLS

-------------------------------
-- Consumable Data
-------------------------------
-- kind:     "food" | "drink" | "health" | "mana" | "gem" | "bandage"
-- amount:   what it restores. Ranges are averaged, which is how the bars rank.
-- name:     what the client should call this ID. Checked by /chair snack data, never
--           shown -- the client's own name is what appears on a tooltip.
-- conjured: mage-made, which gets its own slot on the food bar.
-- zone:     only works in one place, which gets its own slot on the potion bar.
-- zones:    the places it actually works, for an item whose tooltip does not
--           say so in prose the zone gate can read. Matched as a substring
--           against every zone name the client offers, so "Skywall" also
--           covers a sub-zone that carries the name. Listing zones is what
--           keeps an item off the bar everywhere else -- without it, an item
--           whose tooltip says nothing is offered wherever you stand.
-- Skywall and the instances inside it. Zone names are matched as substrings,
-- so the open zone needs the one entry however its sub-zones read; the
-- instances are written out because their own zone text never says Skywall.
local SKYWALL_ZONES = { "Skywall", "The Vortex Pinnacle", "Throne of the Four Winds" }

local CONSUMABLE_DATA = {

    -- Healing potions -------------------------------------------------
    [118]   = { kind = "health", amount = 80,   name = "Minor Healing Potion" },
    [858]   = { kind = "health", amount = 160,  name = "Lesser Healing Potion" },
    [929]   = { kind = "health", amount = 320,  name = "Healing Potion" },
    [1710]  = { kind = "health", amount = 520,  name = "Greater Healing Potion" },
    [3928]  = { kind = "health", amount = 800,  name = "Superior Healing Potion" },
    [13446] = { kind = "health", amount = 1400, name = "Major Healing Potion" },
    [22829] = { kind = "health", amount = 2000, name = "Super Healing Potion" },
    [32947] = { kind = "health", amount = 2000, name = "Auchenai Healing Potion" },

    -- Mana potions ----------------------------------------------------
    [2455]  = { kind = "mana", amount = 160,  name = "Minor Mana Potion" },
    [3385]  = { kind = "mana", amount = 320,  name = "Lesser Mana Potion" },
    [3827]  = { kind = "mana", amount = 520,  name = "Mana Potion" },
    [6149]  = { kind = "mana", amount = 800,  name = "Greater Mana Potion" },
    [13443] = { kind = "mana", amount = 1200, name = "Superior Mana Potion" },
    [13444] = { kind = "mana", amount = 1800, name = "Major Mana Potion" },
    [22832] = { kind = "mana", amount = 2400, name = "Super Mana Potion" },
    [32948] = { kind = "mana", amount = 2400, name = "Auchenai Mana Potion" },

    -- Zone consumables ------------------------------------------------
    -- Free healing and mana that only works in one place, which is why they
    -- take the slot ahead of a potion while you are standing in it.
    [32905] = { kind = "health", amount = 2000, zone = true,
                name = "Bottled Nethergon Vapor" },
    [32902] = { kind = "mana",   amount = 2400, zone = true,
                name = "Bottled Nethergon Energy" },
    [32904] = { kind = "health", amount = 2000, zone = true,
                name = "Cenarion Healing Salve" },
    [32903] = { kind = "mana",   amount = 2400, zone = true,
                name = "Cenarion Mana Salve" },
    [32784] = { kind = "health", amount = 1400, zone = true,
                name = "Red Ogre Brew" },
    [32783] = { kind = "mana",   amount = 2400, zone = true,
                name = "Blue Ogre Brew" },

    -- Skywall ---------------------------------------------------------
    -- A zone item that restores nothing measurable, so it ranks against no
    -- potion: it earns its place by working here at all, and takes a slot of
    -- its own rather than standing in front of the health or mana pick.
    [255663] = { kind = "zone", zone = true, zones = SKYWALL_ZONES,
                 name = "Windstone" },

    -- Mana gems -------------------------------------------------------
    [5514]  = { kind = "gem", amount = 400,  conjured = true, name = "Mana Agate" },
    [5513]  = { kind = "gem", amount = 600,  conjured = true, name = "Mana Jade" },
    [8007]  = { kind = "gem", amount = 850,  conjured = true, name = "Mana Citrine" },
    [8008]  = { kind = "gem", amount = 1100, conjured = true, name = "Mana Ruby" },
    [22044] = { kind = "gem", amount = 2400, conjured = true, name = "Mana Emerald" },

    -- Bandages --------------------------------------------------------
    [1251]  = { kind = "bandage", amount = 66,   name = "Linen Bandage" },
    [2581]  = { kind = "bandage", amount = 114,  name = "Heavy Linen Bandage" },
    [3530]  = { kind = "bandage", amount = 161,  name = "Wool Bandage" },
    [3531]  = { kind = "bandage", amount = 301,  name = "Heavy Wool Bandage" },
    [6450]  = { kind = "bandage", amount = 400,  name = "Silk Bandage" },
    [6451]  = { kind = "bandage", amount = 640,  name = "Heavy Silk Bandage" },
    [8544]  = { kind = "bandage", amount = 800,  name = "Mageweave Bandage" },
    [8545]  = { kind = "bandage", amount = 1104, name = "Heavy Mageweave Bandage" },
    [14529] = { kind = "bandage", amount = 1360, name = "Runecloth Bandage" },
    [14530] = { kind = "bandage", amount = 2000, name = "Heavy Runecloth Bandage" },
    [21990] = { kind = "bandage", amount = 2800, name = "Netherweave Bandage" },
    [21991] = { kind = "bandage", amount = 3400, name = "Heavy Netherweave Bandage" },

    -- Conjured food ---------------------------------------------------
    [5349]  = { kind = "food", amount = 61,   conjured = true, name = "Conjured Muffin" },
    [1113]  = { kind = "food", amount = 244,  conjured = true, name = "Conjured Bread" },
    [1114]  = { kind = "food", amount = 552,  conjured = true, name = "Conjured Rye" },
    [1487]  = { kind = "food", amount = 875,  conjured = true, name = "Conjured Pumpernickel" },
    [8075]  = { kind = "food", amount = 1392, conjured = true, name = "Conjured Sourdough" },
    [8076]  = { kind = "food", amount = 2148, conjured = true, name = "Conjured Sweet Roll" },
    [22895] = { kind = "food", amount = 4320, conjured = true, name = "Conjured Cinnamon Roll" },

    -- Conjured water --------------------------------------------------
    [5350]  = { kind = "drink", amount = 151,  conjured = true, name = "Conjured Water" },
    [2288]  = { kind = "drink", amount = 437,  conjured = true, name = "Conjured Fresh Water" },
    [2136]  = { kind = "drink", amount = 835,  conjured = true, name = "Conjured Purified Water" },
    [3772]  = { kind = "drink", amount = 1345, conjured = true, name = "Conjured Spring Water" },
    [8077]  = { kind = "drink", amount = 1992, conjured = true, name = "Conjured Mineral Water" },
    [8078]  = { kind = "drink", amount = 2934, conjured = true, name = "Conjured Sparkling Water" },
    [8079]  = { kind = "drink", amount = 4200, conjured = true, name = "Conjured Crystal Water" },
    [34065] = { kind = "drink", amount = 7200, conjured = true, name = "Conjured Glacier Water" },

    -- Table food ------------------------------------------------------
    -- Restores both, so it fills the food slot and the water slot at once.
    [34062] = { kind = "food", amount = 7500, manaAmount = 7200,
                conjured = true, tableFood = true,
                name = "Conjured Manna Biscuit" },
}
addon.CONSUMABLE_DATA = CONSUMABLE_DATA

-- Every Healthstone, by rank, with what it restores.
--
-- These need their own table for a different reason than everything above:
-- their use spell is named per rank -- Minor Healthstone, Lesser Healthstone,
-- on up to Master Healthstone -- so there is no single family name to anchor
-- to. The set is small, fixed and fully known: five ranks plus Master, each
-- with a base and two Improved Healthstone variants at +10% and +20%.
--
-- The three variants of a rank share one name, which is why the names below
-- repeat. That is the client's doing, not a mistake in the table.
local HEALTHSTONE_ITEMS = {
    [5512]  = { amount = 100,  name = "Minor Healthstone" },
    [19004] = { amount = 110,  name = "Minor Healthstone" },
    [19005] = { amount = 120,  name = "Minor Healthstone" },

    [5511]  = { amount = 250,  name = "Lesser Healthstone" },
    [19006] = { amount = 275,  name = "Lesser Healthstone" },
    [19007] = { amount = 300,  name = "Lesser Healthstone" },

    [5509]  = { amount = 500,  name = "Healthstone" },
    [19008] = { amount = 550,  name = "Healthstone" },
    [19009] = { amount = 600,  name = "Healthstone" },

    [5510]  = { amount = 800,  name = "Greater Healthstone" },
    [19010] = { amount = 880,  name = "Greater Healthstone" },
    [19011] = { amount = 960,  name = "Greater Healthstone" },

    [9421]  = { amount = 1200, name = "Major Healthstone" },
    [19012] = { amount = 1320, name = "Major Healthstone" },
    [19013] = { amount = 1440, name = "Major Healthstone" },

    -- Master (TBC)
    [22103] = { amount = 2080, name = "Master Healthstone" },
    [22104] = { amount = 2288, name = "Master Healthstone" },
    [22105] = { amount = 2496, name = "Master Healthstone" },
}
addon.HEALTHSTONE_ITEMS = HEALTHSTONE_ITEMS

-------------------------------
-- Weapon Enhancements
-------------------------------
-- Sharpening stones, weightstones, oils and weapon coatings, with the weapon
-- types each one will go on.
--
-- These are listed by ID for the reason the Healthstones are -- their use
-- spells are named per rank, Sharpen Blade II and Enhance Blunt Weapon III, so
-- no one family name anchors them -- and for a second reason of their own: the
-- item class does not identify them either. On this client every stone, oil and
-- coating is Consumable/Other, the same shelf as fishing lures, Comfortable
-- Insoles and the Runes of Warding, and two of the oils are not even that
-- (Lesser Wizard Oil and Lesser Mana Oil are shelved under Trade Goods). The
-- subclass that IS named Item Enhancement holds armor kits, spellthreads,
-- shield spikes and weapon chains -- permanent, one-shot applications that must
-- never be offered from a bar. Classifying by that subclass, which is what this
-- used to do, found no stone at all and stood ready to hand out an armor kit.
--
-- `weapons` is the set of weapon subclass IDs the enchant applies to, taken
-- from each spell's own equipped-item requirement rather than from "sharp" and
-- "blunt" as a rule of thumb -- the rule of thumb is wrong twice over, since an
-- Elemental Sharpening Stone goes on maces and staves and a Consecrated one
-- goes on anything. ANY is for the spells that restrict by inventory slot only,
-- which is every oil and both coatings.
local WEAPON_CLASS_ID = 2
addon.WEAPON_CLASS_ID = WEAPON_CLASS_ID

local AXE_1H,   AXE_2H            = 0, 1
local MACE_1H,  MACE_2H           = 4, 5
local POLEARM,  SWORD_1H, SWORD_2H = 6, 7, 8
local STAFF,    FIST,     DAGGER  = 10, 13, 15

local function WeaponSet(...)
    local set = {}
    for _, subclassID in ipairs({ ... }) do set[subclassID] = true end
    return set
end

local ANY   = true
local SHARP = WeaponSet(AXE_1H, AXE_2H, POLEARM, SWORD_1H, SWORD_2H, DAGGER)
local BLUNT = WeaponSet(MACE_1H, MACE_2H, STAFF, FIST)
local BOTH  = WeaponSet(AXE_1H, AXE_2H, MACE_1H, MACE_2H, POLEARM,
                        SWORD_1H, SWORD_2H, STAFF, FIST, DAGGER)

local WEAPON_ENHANCEMENTS = {
    -- Sharpening stones
    [2862]  = { name = "Rough Sharpening Stone",       weapons = SHARP },
    [2863]  = { name = "Coarse Sharpening Stone",      weapons = SHARP },
    [2871]  = { name = "Heavy Sharpening Stone",       weapons = SHARP },
    [7964]  = { name = "Solid Sharpening Stone",       weapons = SHARP },
    [12404] = { name = "Dense Sharpening Stone",       weapons = SHARP },
    [23528] = { name = "Fel Sharpening Stone",         weapons = SHARP },
    [23529] = { name = "Adamantite Sharpening Stone",  weapons = SHARP },
    -- Both of these are called sharpening stones and neither is only for sharp
    -- weapons. Elemental takes maces and staves too; Consecrated takes anything.
    [18262] = { name = "Elemental Sharpening Stone",   weapons = BOTH },
    [23122] = { name = "Consecrated Sharpening Stone", weapons = ANY },

    -- Weightstones
    [3239]  = { name = "Rough Weightstone",            weapons = BLUNT },
    [3240]  = { name = "Coarse Weightstone",           weapons = BLUNT },
    [3241]  = { name = "Heavy Weightstone",            weapons = BLUNT },
    [7965]  = { name = "Solid Weightstone",            weapons = BLUNT },
    [12643] = { name = "Dense Weightstone",            weapons = BLUNT },
    [28420] = { name = "Fel Weightstone",              weapons = BLUNT },
    [28421] = { name = "Adamantite Weightstone",       weapons = BLUNT },

    -- Oils. Shadow and Frost Oil are the two that name a weapon list rather
    -- than a slot, and ranged weapons are what it leaves out.
    [3824]  = { name = "Shadow Oil",                   weapons = BOTH },
    [3829]  = { name = "Frost Oil",                    weapons = BOTH },
    [20744] = { name = "Minor Wizard Oil",             weapons = ANY },
    [20746] = { name = "Lesser Wizard Oil",            weapons = ANY },
    [20750] = { name = "Wizard Oil",                   weapons = ANY },
    [20749] = { name = "Brilliant Wizard Oil",         weapons = ANY },
    [22522] = { name = "Superior Wizard Oil",          weapons = ANY },
    [23123] = { name = "Blessed Wizard Oil",           weapons = ANY },
    [20745] = { name = "Minor Mana Oil",               weapons = ANY },
    [20747] = { name = "Lesser Mana Oil",              weapons = ANY },
    [20748] = { name = "Brilliant Mana Oil",           weapons = ANY },
    [22521] = { name = "Superior Mana Oil",            weapons = ANY },

    -- Weapon coatings
    [34538] = { name = "Blessed Weapon Coating",       weapons = ANY },
    [34539] = { name = "Righteous Weapon Coating",     weapons = ANY },
}
addon.WEAPON_ENHANCEMENTS = WEAPON_ENHANCEMENTS

-- Will this enhancement go on a weapon of this subclass?
--
-- An unknown weapon subclass fails open: not being able to read what is
-- equipped is no reason to empty the bar, and the worst case is one refused
-- use. A missing weapon is a different answer -- see the caller.
function addon.EnhancementFitsWeapon(itemID, weaponSubclassID)
    local entry = WEAPON_ENHANCEMENTS[itemID]
    if not entry then return false end
    if entry.weapons == ANY or weaponSubclassID == nil then return true end
    return entry.weapons[weaponSubclassID] == true
end
