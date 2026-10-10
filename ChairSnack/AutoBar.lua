-- SnapSnack AutoBar.lua
-- The automatic bars: what goes on them and why.
--
-- Food & Drink bar -- food, drink, conjured food, conjured drink, feed pet
-- Potion bar       -- health/mana potion, their zone-only counterparts,
--                    healthstone, mana gem, bandage
-- Ammo bar         -- what is in the hunter ammo slot, and how much of it
-- Teleport bar     -- hearthstone, engineering, parachute, mage portals, extras
--
-- Three slots are AGGREGATE slots: they stand for a set of items rather than
-- one. The count shows the summed on-hand total across the whole set while the
-- button acts on a single chosen member -- the strongest for Healthstones and
-- Mana Gems, the first available in list order for pet food.
--
-- The mage portal slot is a FLYOUT: one button that fans out into a button per
-- portal the character knows. Those are spells, not items.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

local GetItemInfo          = addon.GetItemInfo
local GetItemInfoInstant   = addon.GetItemInfoInstant
local GetItemCount         = addon.GetItemCount
local GetItemSpell         = addon.GetItemSpell
local GetSpellInfo         = addon.GetSpellInfo
local GetSpellTexture      = addon.GetSpellTexture
local GetSpellBookItemName = addon.GetSpellBookItemName
local GetSpellBookItemInfo = addon.GetSpellBookItemInfo

local GetContainerNumSlots = addon.GetContainerNumSlots
local GetContainerItemID = addon.GetContainerItemID

local FOOD_SLOT_ORDER = { "food", "drink", "conjuredFood", "conjuredDrink", "feedPet" }
-- Classes with no mana have nothing to drink for, so the drink slot stays off
-- the bar for them. Read from the class because power is secret on Forever.
local NO_MANA_CLASSES = { WARRIOR = true, ROGUE = true }
-- Healthstone sits at the far right of the bar by choice, away from the
-- potions, so its position stays constant as other slots come and go.
local POTION_SLOT_ORDER = { "health", "zoneHealth", "mana", "zoneMana",
                            "zoneItem", "manaGem", "bandage", "healthstone" }

-- Ammo has a bar to itself. It rode on the potion bar until there was no way
-- to put the count anywhere but second from the right of a bar of buttons.
local AMMO_SLOT_ORDER = { "ammo" }

addon.FOOD_SLOT_ORDER = FOOD_SLOT_ORDER
addon.POTION_SLOT_ORDER = POTION_SLOT_ORDER
addon.AMMO_SLOT_ORDER = AMMO_SLOT_ORDER

-- What each bar is currently showing, for the config readouts and /chair snack auto.
addon.autoSelection = {}
addon.potionSelection = {}
addon.teleportSelection = {}
addon.enchantSelection = {}
addon.ammoSelection = {}

-- [slotKey] = ordered list of every candidate for that potion slot. Kept out
-- of grid.items deliberately: that table is saved to disk.
addon.potionAlternatives = {}

-- The slots where a weaker choice is a real choice. An aggregate slot is one
-- effect at different ranks, and ammo is not clickable at all, so neither
-- gains anything from a list.
local POTION_ALTERNATIVE_SLOTS = {
    health = true, mana = true,
    zoneHealth = true, zoneMana = true, zoneItem = true,
    bandage = true,
}

-- True when something in the bags was not cached yet, so the next
-- GET_ITEM_INFO_RECEIVED should re-run selection.
local selectionIncomplete = false

local FEED_PET_SPELL_ID = 6991

local SPELL_BOOK = addon.SPELL_BOOK

-------------------------------
-- Shared Helpers
-------------------------------

-- Every distinct item in the bags, with its classification attached.
-- Counts are on-hand only, matching what the bars display.
local function BagContents()
    local list = {}
    local seen = {}

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID and not seen[itemID] then
                seen[itemID] = true

                local itemName, _, _, _, itemMinLevel = GetItemInfo(itemID)
                if not itemName then
                    -- Not cached yet. GET_ITEM_INFO_RECEIVED drives the retry;
                    -- queueing a callback per item would rescan once per item
                    -- as a bagful of them resolved on login.
                    selectionIncomplete = true
                else
                    local info = addon.ClassifyItem(itemID, bag, slot)
                    if info then
                        table.insert(list, {
                            itemID = itemID,
                            name = itemName,
                            minLevel = itemMinLevel or 0,
                            count = GetItemCount(itemID),
                            info = info,
                            -- Where it sits, so the usability check can build
                            -- the contextual tooltip rather than a generic one.
                            bag = bag,
                            slot = slot,
                        })
                    end
                end
            end
        end
    end

    return list
end

local function BestBy(pool, isBetter)
    local best = nil
    for _, candidate in ipairs(pool) do
        if not best or isBetter(candidate, best) then
            best = candidate
        end
    end
    return best
end

-- An aggregate slot: total the whole pool, act on the best member.
local function Aggregate(pool, isBetter)
    if #pool == 0 then return nil end

    local total = 0
    for _, candidate in ipairs(pool) do
        total = total + (candidate.count or 0)
    end
    if total <= 0 then return nil end

    local best = BestBy(pool, isBetter)
    if not best then return nil end

    return {
        itemID = best.itemID,
        name = best.name,
        minLevel = best.minLevel,
        amount = best.amount,
        isTableFood = best.isTableFood,
        isZoneItem = best.isZoneItem,
        total = total,
        members = pool,
    }
end

-------------------------------
-- Make Your Own
-------------------------------
-- When a slot is empty because you are out, and you can simply make more, the
-- bar offers the spell instead of showing nothing. A warlock with no
-- Healthstone gets Create Healthstone; a mage with no conjured food or water
-- gets the conjure.
--
-- One reference spell id per spell where every rank shares a single name, and
-- casting by name uses the highest rank you know -- the same reason the mage
-- portal scan only needs a reference id to recover the localised prefix. A
-- wrong id here costs the button, nothing else.
--
-- Mana gems are the exception: each rank is a differently *named* spell
-- (Conjure Mana Agate, Jade, Citrine, Ruby, Emerald), so one reference cannot
-- stand for the line. They are listed weakest first and the strongest one
-- actually in the spellbook wins.
local CREATE_SPELL_REFS = {
    healthstone   = { class = "WARLOCK", refs = { 6201 } },
    conjuredFood  = { class = "MAGE",    refs = { 587 } },
    conjuredDrink = { class = "MAGE",    refs = { 5504 } },
    manaGem       = { class = "MAGE",    refs = { 759, 3552, 10053, 10054, 27101 } },
}

-- Walking the spellbook is only worth doing when it has changed.
-- Astral Recall is a hearthstone that happens to be a spell: same job, same
-- cooldown, and a shaman uses whichever of the two is pointing somewhere
-- useful. So it belongs beside the stones rather than in a group of its own,
-- and it answers to the same slot toggle.
local ASTRAL_RECALL = 556

local cachedRecall = nil
local recallScanned = false

function addon.InvalidateRecallSpell()
    cachedRecall = nil
    recallScanned = false
end

local function ScanRecallSpell()
    local _, class = UnitClass("player")
    if class ~= "SHAMAN" then return nil end

    local name, _, icon = GetSpellInfo(ASTRAL_RECALL)
    if not name then return nil end

    -- Known only if it is actually in the spellbook. GetSpellInfo answers for
    -- any spell in the game, trained or not, so it cannot be the test -- the
    -- same reason the create-spell scan below walks the book by name.
    local index = 1
    while true do
        local bookName = GetSpellBookItemName(index, SPELL_BOOK)
        if not bookName then break end
        if bookName == name
            and GetSpellBookItemInfo(index, SPELL_BOOK) == "SPELL" then
            return {
                name = name,
                icon = icon or (GetSpellTexture and GetSpellTexture(ASTRAL_RECALL)),
            }
        end
        index = index + 1
    end

    return nil
end

-- The bar entry for it, or nil for anyone who is not a shaman who has learned
-- it. Cached like the create spells: walking the spellbook is only worth doing
-- when the spellbook has changed.
local function RecallSpellEntry()
    if not recallScanned then
        cachedRecall = ScanRecallSpell()
        recallScanned = true
    end
    if not cachedRecall then return nil end

    return {
        slotKey = "hearthstone",
        isSpell = true,
        spellID = ASTRAL_RECALL,
        spellName = cachedRecall.name,
        iconOverride = cachedRecall.icon,
        hideOnZero = false,
        showInCombat = false,
        hideCount = true,
        tooltipTitle = cachedRecall.name,
    }
end

local cachedCreateSpells = nil

function addon.InvalidateCreateSpells()
    cachedCreateSpells = nil
end

local function ScanCreateSpells()
    local _, class = UnitClass("player")

    local wanted = {}
    for slotKey, entry in pairs(CREATE_SPELL_REFS) do
        if entry.class == class then
            for rank, spellID in ipairs(entry.refs) do
                local name, _, icon = GetSpellInfo(spellID)
                if name then
                    wanted[name] = {
                        slotKey = slotKey, name = name, icon = icon, rank = rank,
                    }
                end
            end
        end
    end
    if not next(wanted) then return {} end

    -- Known only if it is actually in the spellbook; GetSpellInfo answers for
    -- any spell in the game, trained or not.
    local found = {}
    local index = 1
    while true do
        local spellName = GetSpellBookItemName(index, SPELL_BOOK)
        if not spellName then break end

        local match = wanted[spellName]
        if match and GetSpellBookItemInfo(index, SPELL_BOOK) == "SPELL" then
            -- Strongest rank wins where a line spans several named spells.
            local current = found[match.slotKey]
            if not current or match.rank > current.rank then
                found[match.slotKey] = match
            end
        end
        index = index + 1
    end

    return found
end

local function GetCreateSpells()
    if not cachedCreateSpells then
        cachedCreateSpells = ScanCreateSpells()
    end
    return cachedCreateSpells
end

addon.GetCreateSpells = GetCreateSpells

-- The bar entry offering to make one, or nil when there is nothing to offer.
local function CreateSpellEntry(slotKey)
    local spell = GetCreateSpells()[slotKey]
    if not spell then return nil end

    return {
        slotKey = slotKey,
        isCreateSpell = true,
        spellName = spell.name,
        iconOverride = spell.icon,
        hideOnZero = false,
        showInCombat = false,
        hideCount = true,
        tooltipTitle = spell.name,
        tooltipHint = "You have none left -- click to make one",
    }
end

-- The same spell as a right-click on a slot that is *not* empty. Running out
-- is not the only time you want another: topping the stack up before a run is
-- the normal case, and the alternative is going to the spellbook for a spell
-- the bar already knows about. Returns nil for slots with nothing to make.
local function CreateSpellRightClick(slotKey)
    local spell = GetCreateSpells()[slotKey]
    if not spell then return nil, nil end
    return spell.name, "Right-click to cast " .. spell.name
end

-------------------------------
-- Food & Drink
-------------------------------

-- Raw fish and meat are cooking reagents that happen to be edible. The client
-- files them as item class 7, Trade Goods, while food proper is class 0,
-- Consumable -- so this separates them with no item IDs, no names and no
-- English, the same way everything else here does it.
local ITEM_CLASS_CONSUMABLE = 0

local function IsReagentFood(itemID)
    if not GetItemInfoInstant then return false end
    local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
    return classID ~= nil and classID ~= ITEM_CLASS_CONSUMABLE
end

local function IsBetterFood(a, b)
    if a.isTableFood ~= b.isTableFood then
        return a.isTableFood
    end

    -- Real food beats a reagent. Both a Red Delicious Stormapple and a Raw
    -- Longjaw Mud Snapper are gated at level 5 and both estimate to the same
    -- restore amount, so every test below this one tied and the decision fell
    -- through to the name -- where "Raw" sorts before "Red" and the fish won.
    if a.isReagent ~= b.isReagent then
        return not a.isReagent
    end

    -- How much it actually restores, which is the thing being chosen between.
    --
    -- This used to compare required level and then fall straight back to the
    -- NAME, so two foods gated at the same level were decided alphabetically.
    -- That is a coin flip dressed up as a rule, and it is why a raw fish beat
    -- an apple: "Raw" sorts before "Red".
    --
    -- Only compared when both numbers are real. EstimatedAmount is a
    -- level-based stand-in calibrated for potions, so weighing an estimate
    -- against a figure out of the data table would be comparing two different
    -- units -- and would quietly favour whichever item the table happens not
    -- to list. Where either is estimated the level below decides, which is
    -- what the estimate is derived from anyway.
    if not a.estimated and not b.estimated and (a.amount or 0) ~= (b.amount or 0) then
        return (a.amount or 0) > (b.amount or 0)
    end

    if a.minLevel ~= b.minLevel then
        return a.minLevel > b.minLevel
    end
    return a.name < b.name
end

-- Vendor food and water come in tiers gated at these character levels. If what
-- you are carrying sits below the highest tier you now qualify for, a better
-- one is buyable -- which is what the green arrow on the icon means.
--
-- Level thresholds rather than item IDs: the actual items differ by faction,
-- expansion and vendor, but the gates have been these since vanilla.
local FOOD_TIER_LEVELS = { 1, 5, 15, 25, 35, 45, 55, 65 }

local function BestTierForLevel(level)
    local best = FOOD_TIER_LEVELS[1]
    for _, tier in ipairs(FOOD_TIER_LEVELS) do
        if tier <= level then best = tier end
    end
    return best
end

local function GatherFoodPools(contents)
    local pools = { food = {}, drink = {}, conjuredFood = {}, conjuredDrink = {} }

    for _, entry in ipairs(contents) do
        -- The same two predicates the pet food picker uses, so "food the
        -- player bar would show" means one thing across the addon.
        local isFood = addon.IsPlayerFood(entry.itemID)
        local isDrink = addon.IsPlayerDrink(entry.itemID)

        -- Buff food has a bar of its own. Without this the strongest food in
        -- the bags won the plain slot whether or not it carried a Well Fed, so
        -- a Longjaw Mud Snapper sat on the food bar and the buff bar at once.
        if (isFood or isDrink) and not addon:BuffFoodBarClaims(entry.itemID) then
            local candidate = {
                itemID = entry.itemID,
                name = entry.name,
                minLevel = entry.minLevel,
                count = entry.count,
                isTableFood = addon.IsTableFood(entry.itemID),
                isReagent = IsReagentFood(entry.itemID),
                -- Carried through so the ranking can weigh what a food does
                -- rather than only what level it is gated at. estimated says
                -- whether the number is real or worked out from the level,
                -- because the two are not on the same scale.
                amount = (entry.info and entry.info.healAmount) or 0,
                estimated = (entry.info and entry.info.estimated) or false,
            }
            if entry.info.conjured then
                if isFood then table.insert(pools.conjuredFood, candidate) end
                if isDrink then table.insert(pools.conjuredDrink, candidate) end
            else
                if isFood then table.insert(pools.food, candidate) end
                if isDrink then table.insert(pools.drink, candidate) end
            end
        end
    end

    return pools
end

-------------------------------
-- Pet Diet
-------------------------------
-- Feed Pet only grants happiness while the food is within 30 levels below the
-- pet. That gap is what the colours in the food picker mean.

local PET_FOOD_LEVEL_RANGE = 30

addon.PET_FOOD_COLORS = {
    good   = { 1.0, 0.82, 0.0 },   -- yellow: right level for this pet
    low    = { 0.2, 1.0,  0.2 },   -- green:  works, but well below the pet
    toolow = { 0.5, 0.5,  0.5 },   -- grey:   too low to give happiness
}

-- Diet per tameable family in this era, from wow-petopia.com/classic family
-- pages. Lets the config show a diet and hold a food list for a family you have
-- not tamed yet -- GetPetFoodTypes only answers for a pet that is currently out.
--
-- Keys are the English family names UnitCreatureFamily returns. On a non-English
-- client the lookup misses and the live GetPetFoodTypes value is used instead,
-- which is why that is always preferred when a pet is present.
local FAMILY_DIETS = {
    ["Bat"]          = { "Fruit", "Fungus" },
    ["Bear"]         = { "Bread", "Cheese", "Fish", "Fruit", "Fungus", "Meat" },
    ["Boar"]         = { "Bread", "Cheese", "Fish", "Fruit", "Fungus", "Meat" },
    ["Carrion Bird"] = { "Fish", "Meat" },
    ["Cat"]          = { "Fish", "Meat" },
    ["Crab"]         = { "Bread", "Fish", "Fruit", "Fungus" },
    ["Crocolisk"]    = { "Fish", "Meat" },
    ["Gorilla"]      = { "Fruit", "Fungus" },
    ["Hyena"]        = { "Fruit", "Meat" },
    ["Owl"]          = { "Meat" },
    ["Raptor"]       = { "Meat" },
    ["Scorpid"]      = { "Meat" },
    ["Spider"]       = { "Meat" },
    ["Tallstrider"]  = { "Cheese", "Fruit", "Fungus" },
    ["Turtle"]       = { "Fish", "Fruit", "Fungus" },
    ["Wind Serpent"] = { "Bread", "Cheese", "Fish" },
    ["Wolf"]         = { "Meat" },
}

local FAMILY_ORDER = {}
for family in pairs(FAMILY_DIETS) do
    table.insert(FAMILY_ORDER, family)
end
table.sort(FAMILY_ORDER)

addon.FAMILY_DIETS = FAMILY_DIETS
addon.FAMILY_ORDER = FAMILY_ORDER

function addon:GetPetFamily()
    if not UnitExists("pet") then return nil end
    -- (nil too when the client keeps it secret: it is compared and looked up)
    local family = addon.Text(UnitCreatureFamily and UnitCreatureFamily("pet"))
    if family == "" then return nil end
    return family
end

-- Diet for any family, pet out or not. The live call wins when available since
-- it is authoritative and localised.
function addon:GetDietForFamily(family)
    if family and family == self:GetPetFamily() then
        local live = self:GetPetDiet()
        if live then return live end
    end
    return family and FAMILY_DIETS[family] or nil
end

-- The current pet diet, e.g. { "Meat", "Fish" }. Pet-side only; there is no
-- matching per-item call, which is why this is shown rather than filtered on.
function addon:GetPetDiet()
    if type(GetPetFoodTypes) ~= "function" then return nil end
    if not UnitExists("pet") then return nil end

    local types = { GetPetFoodTypes() }
    if #types == 0 then return nil end
    return types
end

-- Colour band for a food against the pet it is being chosen for. Without a
-- matching pet out there is no level to compare against, so everything reads as
-- usable rather than being falsely greyed out.
function addon:RatePetFood(itemID, family)
    if family and family ~= self:GetPetFamily() then return "good" end

    local petLevel = addon.Num(UnitLevel("pet"))
    if not petLevel or petLevel <= 0 then return "good" end

    local _, _, _, _, minLevel = GetItemInfo(itemID)
    local gap = petLevel - (minLevel or 0)

    if gap > PET_FOOD_LEVEL_RANGE then return "toolow" end
    if gap > PET_FOOD_LEVEL_RANGE / 2 then return "low" end
    return "good"
end

-- Pet food is remembered per pet family, so swapping from a cat to a boar
-- brings up that pet's own list rather than one shared setting.
--
-- Pass a family to read or preset a specific one; omit it for whichever pet is
-- currently out.
function addon:GetPetFoodList(family)
    local grid = self:GetGrid(self.AUTO_GRID_ID)
    if not grid then return nil end

    grid.petFood = grid.petFood or {}
    grid.petFoodByFamily = grid.petFoodByFamily or {}

    family = family or self:GetPetFamily()
    if not family then
        -- No pet out and none asked for: the shared list, which also seeds each
        -- family the first time it appears.
        return grid.petFood
    end

    local list = grid.petFoodByFamily[family]
    if not list then
        list = addon.DeepCopy(grid.petFood)
        grid.petFoodByFamily[family] = list
    end
    return list
end

-------------------------------
-- Learned Pet Diets
-------------------------------
-- The client exposes the pet's diet but not which diet type a given food item
-- is, so the only way to know whether this pet will eat that item is to try it.
-- Each attempt is recorded, account-wide, so the guess only has to be wrong
-- once per family and every hunter benefits from what any one of them learned.

-- The feed just attempted, so a rejection can be attributed to the right item.
local pendingFeed = nil

-- Called from the button click, before the game has said anything.
--
-- Only rejections are recorded. Success needs no handling at all: there is no
-- reliable success event, and nothing depends on knowing a food worked -- what
-- matters is dropping the ones that do not.
function addon.NotePetFeed(family, itemID)
    if not family or not itemID then return end

    pendingFeed = { family = family, itemID = itemID }

    -- Close the attribution window so a later unrelated error cannot be blamed
    -- on this feed.
    C_Timer.After(2, function()
        if pendingFeed and pendingFeed.family == family
            and pendingFeed.itemID == itemID then
            pendingFeed = nil
        end
    end)
end

-- Called when the game rejects the food. Drops it and moves on without saying
-- anything.
function addon.NotePetFeedRejected()
    local attempt = pendingFeed
    if not attempt then return end
    pendingFeed = nil

    addon:RecordPetFoodResult(attempt.family, attempt.itemID, false)

    -- Move on to the next candidate immediately.
    addon:UpdateAutoBar()
    addon:RequestUpdate()
end

function addon:GetPetFoodKnowledge(family)
    if not family then return nil end
    local store = self:GetGlobal().petFoodKnowledge
    if not store then return nil end
    return store[family]
end

function addon:RecordPetFoodResult(family, itemID, accepted)
    if not family or not itemID then return end

    local global = self:GetGlobal()
    global.petFoodKnowledge = global.petFoodKnowledge or {}
    global.petFoodKnowledge[family] = global.petFoodKnowledge[family] or {}

    local known = global.petFoodKnowledge[family]
    if known[itemID] == accepted then return false end

    known[itemID] = accepted
    return true
end

-- Auto mode: everything in the bags a pet could eat, minus what this family has
-- already refused, highest level first. Nothing to configure.
--
-- Low-level food is kept rather than filtered out -- a pet will still eat it,
-- it just gains less from it -- so it simply sorts to the bottom and acts as a
-- fallback once the good stuff runs out. Sorting on required level does that on
-- its own; the colour bands are only there to be read.
function addon:GetAutoPetFood(family)
    local known = self:GetPetFoodKnowledge(family)
    local candidates = {}

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID and not candidates[itemID] and addon.IsPetEdible(itemID) then
                local rejected = known and known[itemID] == false
                if not rejected then
                    local itemName, _, _, _, minLevel = GetItemInfo(itemID)
                    if itemName then
                        candidates[itemID] = {
                            itemID = itemID,
                            name = itemName,
                            minLevel = minLevel or 0,
                            rating = self:RatePetFood(itemID),
                        }
                    end
                end
            end
        end
    end

    local list = {}
    for _, candidate in pairs(candidates) do
        table.insert(list, candidate)
    end

    -- A hand-set order, if there is one, takes precedence. It is only a partial
    -- list: anything not in it still falls in by level, so newly looted food
    -- appears on its own without needing to be added.
    local rank = {}
    local order = self:GetPetFoodOrder(family)
    if order then
        for index, itemID in ipairs(order) do
            rank[itemID] = index
        end
    end

    -- Pinned items in their chosen order, then the rest highest level first,
    -- then by name so the order is stable between updates.
    table.sort(list, function(a, b)
        local ra, rb = rank[a.itemID], rank[b.itemID]
        if ra and rb then return ra < rb end
        if ra then return true end
        if rb then return false end
        if a.minLevel ~= b.minLevel then return a.minLevel > b.minLevel end
        return a.name < b.name
    end)

    return list
end

function addon:GetPetFoodOrder(family)
    if not family then return nil end
    local grid = self:GetGrid(self.AUTO_GRID_ID)
    if not grid or not grid.petFoodOrder then return nil end
    return grid.petFoodOrder[family]
end

function addon:HasPetFoodOrder(family)
    local order = self:GetPetFoodOrder(family)
    return order ~= nil and #order > 0
end

-- Move a food up or down the feed order.
--
-- The first move freezes the order as it currently appears and then swaps
-- within it, so nudging one item does not silently reshuffle everything else.
function addon:MovePetFood(family, itemID, delta)
    if not family or not itemID then return false end

    local grid = self:GetGrid(self.AUTO_GRID_ID)
    if not grid then return false end

    local order = {}
    for _, candidate in ipairs(self:GetAutoPetFood(family)) do
        table.insert(order, candidate.itemID)
    end

    local index
    for position, id in ipairs(order) do
        if id == itemID then index = position break end
    end
    if not index then return false end

    local target = index + delta
    if target < 1 or target > #order then return false end

    order[index], order[target] = order[target], order[index]

    grid.petFoodOrder = grid.petFoodOrder or {}
    grid.petFoodOrder[family] = order

    self:UpdateAutoBar()
    self:RequestUpdate()
    return true
end

-- Back to picking the order itself.
function addon:ResetPetFoodOrder(family)
    if not family then return end
    local grid = self:GetGrid(self.AUTO_GRID_ID)
    if grid and grid.petFoodOrder then
        grid.petFoodOrder[family] = nil
    end
    self:UpdateAutoBar()
    self:RequestUpdate()
end

-- Everything edible in the bags for this family, split into what will be fed
-- (in order) and what has been ruled out -- by the pet refusing it, or by hand.
--
-- Only ruled-out items still in the bags are listed, so the panel stays a view
-- of what is actionable rather than an ever-growing history.
function addon:GetPetFoodOverview(family)
    local included = self:GetAutoPetFood(family)
    local known = self:GetPetFoodKnowledge(family)

    local excluded, seen = {}, {}
    if known then
        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and not seen[itemID] and known[itemID] == false
                    and addon.IsPetEdible(itemID) then
                    local itemName = GetItemInfo(itemID)
                    if itemName then
                        seen[itemID] = true
                        table.insert(excluded, { itemID = itemID, name = itemName })
                    end
                end
            end
        end
        table.sort(excluded, function(a, b) return a.name < b.name end)
    end

    return included, excluded
end

-- Rule a food in or out by hand. Writes to the same store the pet teaches, so
-- a manual exclusion and a refusal are the same fact.
function addon:SetPetFoodExcluded(family, itemID, excluded)
    if not family or not itemID then return end

    if excluded then
        self:RecordPetFoodResult(family, itemID, false)
    else
        -- Back to unknown: nothing is recorded about food that works.
        local store = self:GetGlobal().petFoodKnowledge
        if store and store[family] then
            store[family][itemID] = nil
        end
    end

    self:UpdateAutoBar()
    self:RequestUpdate()
end

-- How many foods a family already has configured, for the picker labels.
function addon:CountPetFoodFor(family)
    local grid = self:GetGrid(self.AUTO_GRID_ID)
    if not grid or not grid.petFoodByFamily then return 0 end
    local list = grid.petFoodByFamily[family]
    return list and #list or 0
end

-- Items worth offering in the pet food picker.
function addon:GetPetFoodChoices(showAll)
    local list = {}
    for itemID, data in pairs(self.knownConsumables) do
        if showAll or addon.IsPetEdible(itemID) then
            table.insert(list, { id = itemID, name = data.name })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-------------------------------
-- Feed Pet
-------------------------------

-- Aggregate over the curated pet food list, in the order the user arranged it.
--
-- Always returns a state for a hunter rather than nil, so the button explains
-- itself instead of silently vanishing the moment a precondition is unmet --
-- which is what happened when picking a food with no pet out.
local function SelectPetFood(grid)
    if not addon:IsHunter() then return nil end

    -- No pet, no button. Checked ahead of every other state so the slot cannot
    -- appear under one condition and vanish under another.
    if not UnitExists("pet") then return nil end

    local spellName, _, spellIcon = GetSpellInfo(FEED_PET_SPELL_ID)
    if not spellName then return nil end
    local icon = (GetSpellTexture and GetSpellTexture(FEED_PET_SPELL_ID)) or spellIcon

    local family = addon:GetPetFamily()
    local auto = (grid.petFoodMode or "auto") == "auto"

    -- Auto mode needs no list at all; manual uses the curated one.
    local candidates = {}
    if auto then
        candidates = addon:GetAutoPetFood(family)
    else
        for _, itemData in ipairs(addon:GetPetFoodList() or {}) do
            local itemID = addon.GetItemIDFromData(itemData)
            if itemID then
                table.insert(candidates, { itemID = itemID, name = GetItemInfo(itemID) })
            end
        end

        -- Manual mode with an empty list is the only case that still needs
        -- setting up, so it keeps the X prompt.
        if #candidates == 0 then
            return {
                state = "setup",
                needsSetup = true,
                spellName = spellName,
                icon = icon,
                total = 0,
                members = {},
            }
        end
    end

    local total = 0
    local chosen = nil
    local members = {}

    for _, candidate in ipairs(candidates) do
        local itemID = candidate.itemID
        local itemName = candidate.name or GetItemInfo(itemID)
        local count = GetItemCount(itemID)
        total = total + count
        table.insert(members, { itemID = itemID, name = itemName, count = count })
        -- First in order that is actually on hand.
        if not chosen and count > 0 and itemName then
            chosen = { itemID = itemID, name = itemName, count = count }
        end
    end

    if not chosen then
        return {
            state = "empty",
            spellName = spellName,
            icon = icon,
            total = 0,
            members = members,
            hint = auto and "No food your pet can eat" or "Out of pet food",
        }
    end

    return {
        state = "ready",
        itemID = chosen.itemID,
        name = chosen.name,
        total = total,
        members = members,
        spellName = spellName,
        icon = icon,
        -- Two-step feed: the cast leaves an item-target cursor that /use fills.
        macrotext = "/cast " .. spellName .. "\n/use " .. chosen.name,
    }
end

-------------------------------
-- Food & Drink Bar
-------------------------------

-- Recompute the Food & Drink bar. Returns true when the contents changed.
function addon:UpdateAutoBar()
    local grid = self:GetGrid(self.AUTO_GRID_ID)
    if not grid then return false end

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = addon.GetItemIDFromData(itemData)
    end

    local items = {}
    local selection = {}

    if grid.enabled then
        selectionIncomplete = false

        local pools = GatherFoodPools(BagContents())
        local slots = grid.autoSlots or {}
        local added = {}
        local _, class = UnitClass("player")
        local noMana = NO_MANA_CLASSES[class]

        for _, slotName in ipairs(FOOD_SLOT_ORDER) do
            if slots[slotName] ~= false and not (noMana and slotName == "drink") then
                if slotName == "feedPet" then
                    local pet = SelectPetFood(grid)
                    if pet and pet.needsSetup then
                        selection.feedPet = pet
                        table.insert(items, {
                            slotKey = slotName,
                            needsSetup = true,
                            iconOverride = pet.icon,
                            tooltipTitle = pet.spellName,
                            hideOnZero = false,
                            showInCombat = false,
                            hideCount = true,
                        })
                    elseif pet and pet.state ~= "ready" then
                        -- Configured but not usable right now. Stays on the bar
                        -- dimmed with the reason, rather than disappearing.
                        selection.feedPet = pet
                        table.insert(items, {
                            slotKey = slotName,
                            inactive = true,
                            iconOverride = pet.icon,
                            tooltipTitle = pet.spellName,
                            tooltipHint = pet.hint,
                            hideOnZero = false,
                            showInCombat = false,
                            hideCount = true,
                        })
                    elseif pet then
                        selection.feedPet = pet
                        table.insert(items, {
                            slotKey = slotName,
                            itemID = pet.itemID,
                            hideOnZero = true,
                            showInCombat = false,
                            countOverride = pet.total,
                            iconOverride = pet.icon,
                            macrotext = pet.macrotext,
                            tooltipTitle = pet.spellName,
                            aggregate = pet.members,
                            isFeedPet = true,
                            petFamily = addon:GetPetFamily(),
                        })
                    end
                else
                    local best = BestBy(pools[slotName], IsBetterFood)
                    if not best then
                        local offer = CreateSpellEntry(slotName)
                        if offer then
                            selection[slotName] = {
                                name = offer.spellName,
                                minLevel = 0,
                                isCreateSpell = true,
                            }
                            table.insert(items, offer)
                        end
                    end
                    if best then
                        -- Only the generic vendor slots can have an upgrade to
                        -- point at; conjured items are not bought in tiers.
                        if slotName == "food" or slotName == "drink" then
                            best.hasUpgrade =
                                best.minLevel < BestTierForLevel(UnitLevel("player") or 1)
                        end

                        selection[slotName] = best
                        -- A combo item can win both a food and a drink slot;
                        -- show it once rather than as a duplicated pair.
                        if not added[best.itemID] then
                            added[best.itemID] = true
                            -- Only the conjured slots have anything to make,
                            -- so this is nil on vendor food and water.
                            local rightSpell, rightHint = CreateSpellRightClick(slotName)
                            table.insert(items, {
                                slotKey = slotName,
                                itemID = best.itemID,
                                hideOnZero = true,
                                showInCombat = false,
                                showUpgrade = best.hasUpgrade,
                                rightSpell = rightSpell,
                                tooltipHint = rightHint,
                            })
                        end
                    end
                end
            end
        end
    end

    grid.items = items
    self.autoSelection = selection

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if itemData.itemID ~= previous[i] then return true end
    end
    return false
end

-------------------------------
-- Potion Bar
-------------------------------

-- Biggest restore, then alphabetical. Candidates carry the amount relevant to
-- the pool they were put in, so one comparer serves every slot.
--
-- Zone consumables used to be tiered above ordinary potions here. They now have
-- slots of their own instead, so your normal potion is never displaced and a
-- raid consumable simply appears next to it when you are somewhere it works.
local function IsBetterPotion(a, b)
    if a.amount ~= b.amount then
        return a.amount > b.amount
    end
    return a.name < b.name
end

local function GatherPotionPools(contents)
    local pools = {
        health = {}, mana = {},
        zoneHealth = {}, zoneMana = {}, zoneItem = {},
        healthstone = {}, manaGem = {}, bandage = {},
    }

    for _, entry in ipairs(contents) do
        local info = entry.info

        -- Bandages get their own slot rather than competing with potions.
        -- A bandage above your First Aid skill shows a red requirement line,
        -- so IsUsableNow already keeps it off the bar.
        if info.isBandage and info.healAmount > 0 and entry.count > 0 then
            if addon.IsUsableNow(entry.itemID, entry.bag, entry.slot) then
                table.insert(pools.bandage, {
                    itemID = entry.itemID, name = entry.name,
                    count = entry.count, amount = info.healAmount,
                    isZoneItem = false,
                    estimated = info.estimated,
                })
            end
        end

        -- A zone item restores nothing, so every pool below would skip it on
        -- a zero amount. It belongs on the bar for where it works rather than
        -- for what it gives back, and IsUsableNow is what decides that.
        if info.isZoneItem and entry.count > 0 then
            if addon.IsUsableNow(entry.itemID, entry.bag, entry.slot) then
                table.insert(pools.zoneItem, {
                    itemID = entry.itemID, name = entry.name,
                    count = entry.count, amount = 0,
                    isZoneItem = true,
                    estimated = false,
                })
            end
        end

        -- isPotion means "restores something and is not food class", so it is
        -- what separates a Healthstone from conjured food and a Mana Gem from
        -- conjured water.
        if info.isPotion and entry.count > 0 then
            -- Excludes over-level potions and anything restricted to a zone
            -- you are not currently in.
            if addon.IsUsableNow(entry.itemID, entry.bag, entry.slot) then
                local isZoneItem = addon.IsZoneConsumable(entry.itemID, entry.bag, entry.slot)

                -- Zone consumables are kept out of the ordinary pools entirely,
                -- so they cannot displace the potion you always want to see --
                -- and cannot end up on the bar twice.
                local function Place(amount, conjuredPool, zonePool, normalPool)
                    if amount <= 0 then return end
                    local candidate = {
                        itemID = entry.itemID, name = entry.name,
                        count = entry.count, amount = amount,
                        isZoneItem = isZoneItem,
                        -- Not in the item data, so the number is a stand-in
                        -- worked out from the required level. The readouts say
                        -- so rather than presenting a guess as a fact.
                        estimated = info.estimated,
                    }
                    if info.conjured then
                        table.insert(conjuredPool, candidate)
                    elseif isZoneItem then
                        table.insert(zonePool, candidate)
                    else
                        table.insert(normalPool, candidate)
                    end
                end

                Place(info.healAmount, pools.healthstone, pools.zoneHealth, pools.health)
                Place(info.manaAmount, pools.manaGem, pools.zoneMana, pools.mana)
            end
        end
    end

    return pools
end

-- Recompute the potion bar. Returns true when the contents changed.
function addon:UpdatePotionBar()
    local grid = self:GetGrid(self.POTION_GRID_ID)
    if not grid then return false end

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = addon.GetItemIDFromData(itemData)
    end

    local items = {}
    local selection = {}

    wipe(self.potionAlternatives)

    if grid.enabled then
        local pools = GatherPotionPools(BagContents())
        local slots = grid.autoSlots or {}
        local added = {}

        for _, slotName in ipairs(POTION_SLOT_ORDER) do
            if slots[slotName] ~= false then
                local pool = pools[slotName]

                local pick
                if slotName == "healthstone" or slotName == "manaGem" then
                    -- Aggregate: total every rank on hand, use the strongest.
                    pick = Aggregate(pool, IsBetterPotion)
                else
                    pick = BestBy(pool, IsBetterPotion)
                end

                if not pick then
                    local offer = CreateSpellEntry(slotName)
                    if offer then
                        selection[slotName] = {
                            name = offer.spellName,
                            amount = 0,
                            isCreateSpell = true,
                        }
                        table.insert(items, offer)
                    end
                end

                if pick then
                    selection[slotName] = pick

                    -- More than one usable candidate means the weaker ones are
                    -- worth reaching -- the big potion is often on its shared
                    -- cooldown when you need the next one.
                    local alternatives = nil
                    if POTION_ALTERNATIVE_SLOTS[slotName] and pool and #pool > 1 then
                        alternatives = {}
                        for _, candidate in ipairs(pool) do
                            table.insert(alternatives, candidate)
                        end
                        table.sort(alternatives, function(a, b)
                            if a.amount ~= b.amount then return a.amount > b.amount end
                            return (a.name or "") < (b.name or "")
                        end)
                        self.potionAlternatives[slotName] = alternatives
                    end

                    if not added[pick.itemID] then
                        added[pick.itemID] = true

                        -- Healthstone and Mana Gem are the makeable slots, and
                        -- they are exactly the ones with no alternatives list,
                        -- so the two right-click meanings never collide. The
                        -- guard is here anyway: one right button, one action.
                        local rightSpell, rightHint = CreateSpellRightClick(slotName)
                        if alternatives then rightSpell = nil end

                        local entry = {
                            slotKey = slotName,
                            itemID = pick.itemID,
                            hideOnZero = true,
                            showInCombat = true,
                            countOverride = pick.total,
                            aggregate = pick.members,
                            hasAlternatives = alternatives ~= nil,
                            rightSpell = rightSpell,
                            tooltipHint = alternatives
                                and "Right-click for the others you are carrying"
                                or rightHint,
                        }

                        -- One bandage button, two targets: left click patches
                        -- you up, right click patches up the pet. A macro
                        -- conditional aims the use without retargeting, so
                        -- your current target is never touched -- "target=pet"
                        -- is the pre-3.x spelling of "@pet" and is what this
                        -- client understands, the same as the bar visibility
                        -- rules use.
                        if slotName == "bandage" and UnitExists("pet") then
                            entry.petMacro = "/use [target=pet] " .. pick.name
                            entry.petTarget = true
                            entry.tooltipHint = "Right-click to bandage " ..
                                (UnitName("pet") or "your pet")
                            -- One right button, one action. The alternatives
                            -- tray fans out as plain item buttons, which would
                            -- bandage you rather than the pet, so it yields
                            -- while there is a pet and comes back when there
                            -- is not.
                            entry.hasAlternatives = false
                        end

                        table.insert(items, entry)
                    end
                end
            end
        end
    end

    grid.items = items
    self.potionSelection = selection

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if itemData.itemID ~= previous[i] then return true end
    end
    return false
end

-------------------------------
-- Teleport Bar
-------------------------------

-- Known teleport items, grouped so each group gets its own on/off toggle.
-- Every one you have shows its own button -- these are not ranked against each
-- other, you just want whichever are available.
--
-- NOTE: these item IDs are the one part of this file that cannot be derived at
-- runtime, so they are the first thing to check if a button fails to appear.
-- The Extra Teleports list on the config panel covers anything missing here.
local TELEPORT_GROUPS = {
    hearthstone = {
        6948,   -- Hearthstone
    },
    engineering = {
        18986,  -- Ultrasafe Transporter: Gadgetzan
        18984,  -- Dimensional Ripper - Everlook
        30544,  -- Ultrasafe Transporter: Toshley's Station
        30542,  -- Dimensional Ripper - Area 52
    },
    parachute = {},  -- detected, see ParachuteGroup
}

-- Supplement to the detection below, for anything it misses.
local PARACHUTE_ITEM_IDS = {
    [32757] = true,  -- Parachute Cloak
}

local HEARTHSTONE_ITEM_ID = 6948

-- Substitute hearthstones are normally found by their use spell matching the
-- Hearthstone's (see HearthstoneGroup); this is the override for ones that
-- cast a spell of their own instead.
local HEARTHSTONE_SUBSTITUTES = {
    [260221] = true,  -- Naaru's Embrace
}

-- Hearthstone substitutes that are TOYS rather than bag items.
--
-- A toy is learned into the Toy Box and never appears in a bag or an equipment
-- slot, so no amount of bag scanning finds it -- which is why Naaru's Embrace
-- never showed up. It also casts its own spell rather than the Hearthstone's,
-- so the use-spell match missed it twice over.
local HEARTHSTONE_TOYS = {
    260221,  -- Naaru's Embrace
}

local TELEPORT_GROUP_ORDER = { "hearthstone", "engineering", "parachute" }
addon.TELEPORT_GROUP_ORDER = TELEPORT_GROUP_ORDER

local TELEPORT_SLOT_ORDER = { "hearthstone", "engineering", "parachute",
                              "mageTeleports", "magePortals", "extras" }
addon.TELEPORT_SLOT_ORDER = TELEPORT_SLOT_ORDER

-- Reference spells whose names supply the localised "Teleport"/"Portal"
-- prefixes, so the spellbook scan below never compares English literals.
--
-- A tray each, not one shared tray: taking yourself somewhere and opening a
-- door for the group are different intentions, and by Outland a mage knows
-- enough of both that one list is a column of a dozen icons to read through.
local MAGE_SPELL_FAMILIES = {
    { slotKey = "mageTeleports", ref = 3561 },   -- Teleport: Stormwind
    { slotKey = "magePortals",   ref = 10059 },  -- Portal: Stormwind
}

-- Item IDs held in bags and worn, kept apart because the Parachute Cloak
-- behaves differently depending on which it is.
local function CarriedOrWorn()
    local bags, worn = {}, {}

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then bags[itemID] = true end
        end
    end

    for slot = 1, 19 do
        local itemID = GetInventoryItemID("player", slot)
        if itemID then worn[itemID] = true end
    end

    local owned = {}
    for itemID in pairs(bags) do owned[itemID] = true end
    for itemID in pairs(worn) do owned[itemID] = true end

    return owned, bags, worn
end

-- Every hearthstone-equivalent the player is carrying, substitutes first.
--
-- A substitute is identified by casting the same spell as the Hearthstone
-- rather than by item ID, so anything that stands in for it -- Naaru's Embrace
-- and whatever else exists -- is picked up without being listed here.
local function HearthstoneGroup(owned)
    local _, hearthSpellID = GetItemSpell(HEARTHSTONE_ITEM_ID)

    local plain, substitutes = nil, {}

    -- Toys first: they are owned rather than carried, so the bag scan above
    -- has nothing to say about them.
    if PlayerHasToy then
        for _, itemID in ipairs(HEARTHSTONE_TOYS) do
            local ok, has = pcall(PlayerHasToy, itemID)
            if ok and has then
                table.insert(substitutes, { itemID = itemID, isToy = true })
            end
        end
    end

    for itemID in pairs(owned) do
        if itemID == HEARTHSTONE_ITEM_ID then
            plain = itemID
        else
            local isSubstitute = HEARTHSTONE_SUBSTITUTES[itemID] or false
            if not isSubstitute and hearthSpellID then
                local _, spellID = GetItemSpell(itemID)
                isSubstitute = spellID == hearthSpellID
            end
            if isSubstitute then
                table.insert(substitutes, { itemID = itemID })
            end
        end
    end

    table.sort(substitutes, function(a, b) return a.itemID < b.itemID end)

    -- A substitute supersedes the plain Hearthstone; only fall back to the
    -- stone itself when there is nothing better.
    if #substitutes > 0 then
        return substitutes
    end
    return plain and { { itemID = plain } } or {}
end

-- Cloaks that can be used, not merely worn -- which in this era means the
-- engineering Parachute Cloak.
--
-- Detected from the equip slot plus having a use effect rather than by item ID:
-- ordinary cloaks have no use spell, and a wrong hardcoded ID would leave the
-- button silently missing with nothing to point at.
local function ParachuteGroup(owned)
    local found, seen = {}, {}

    for itemID in pairs(owned) do
        local matches = PARACHUTE_ITEM_IDS[itemID] or false

        if not matches and GetItemInfoInstant then
            local _, _, _, equipLoc = GetItemInfoInstant(itemID)
            if equipLoc == "INVTYPE_CLOAK" and GetItemSpell(itemID) then
                matches = true
            end
        end

        if matches and not seen[itemID] then
            seen[itemID] = true
            table.insert(found, itemID)
        end
    end

    table.sort(found)
    return found
end

-- Every mage teleport and portal the character actually knows, split by which
-- prefix its name carries. Returns one entry per family, always -- an empty
-- spell list rather than a missing key, so callers never branch on nil.
local function ScanMagePortals()
    local byPrefix = {}
    local found = {}

    for _, family in ipairs(MAGE_SPELL_FAMILIES) do
        found[family.slotKey] = { spells = {} }

        local name, _, icon = GetSpellInfo(family.ref)
        local prefix = name and name:match("^(.-):")
        if prefix and prefix ~= "" then
            -- First family claims a shared prefix rather than both taking it.
            -- A locale that spells the two the same then lands everything on
            -- one tray, which is the old behaviour -- not the same spell
            -- listed twice on two.
            if not byPrefix[prefix] then
                byPrefix[prefix] = family.slotKey
            end
            found[family.slotKey].title = prefix
            found[family.slotKey].icon = icon
        end
    end
    if not next(byPrefix) then return found end

    local seen = {}
    local index = 1
    while true do
        local spellName = GetSpellBookItemName(index, SPELL_BOOK)
        if not spellName then break end

        local kind = GetSpellBookItemInfo(index, SPELL_BOOK)
        if kind == "SPELL" and not seen[spellName] then
            local prefix = spellName:match("^(.-):")
            local slotKey = prefix and byPrefix[prefix]
            if slotKey then
                seen[spellName] = true
                table.insert(found[slotKey].spells, {
                    name = spellName,
                    icon = select(3, GetSpellInfo(spellName)),
                })
            end
        end
        index = index + 1
    end

    for _, family in pairs(found) do
        table.sort(family.spells, function(a, b) return a.name < b.name end)
    end
    return found
end

-- The spellbook only changes on SPELLS_CHANGED, so cache the walk rather than
-- repeating a few hundred iterations on every BAG_UPDATE.
local cachedPortals = nil

function addon.InvalidateMagePortals()
    cachedPortals = nil
end

local function GetMagePortals()
    if not cachedPortals then
        cachedPortals = ScanMagePortals()
    end
    return cachedPortals
end

-- Recompute the teleport bar. Returns true when the contents changed.
function addon:UpdateTeleportBar()
    local grid = self:GetGrid(self.TELEPORT_GRID_ID)
    if not grid then return false end

    -- What a bar entry is, for telling one layout from the next.
    --
    -- Not every entry is an item. A mage portal flyout stands for a set of
    -- spells and the shaman recall is a spell outright, so neither has an item
    -- ID -- and storing nil for those left a hole in the array, which made
    -- every rebuild look like a change and relayout the bar on every bag scan.
    local function EntryKey(itemData)
        if type(itemData) ~= "table" then return itemData or false end
        return itemData.itemID or itemData.spellID or itemData.slotKey or false
    end

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = EntryKey(itemData)
    end

    local items = {}
    local selection = {}

    if grid.enabled then
        local owned, _, worn = CarriedOrWorn()
        local slots = grid.autoSlots or {}
        local added = {}

        local function AddItem(itemID, extra)
            if added[itemID] then return nil end
            local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
            if not itemName then
                selectionIncomplete = true
                return nil
            end
            added[itemID] = true

            local data = {
                itemID = itemID,
                hideOnZero = false,
                showInCombat = false,
                -- Teleports are not stacks, and a worn cloak counts as zero in
                -- the bags, so a number here would be noise or a lie.
                hideCount = true,
            }
            if extra then
                for key, value in pairs(extra) do data[key] = value end
            end

            table.insert(items, data)
            return { itemID = itemID, name = itemName, icon = itemIcon }
        end

        -- The Parachute Cloak only earns a slot when a transporter is also on
        -- hand: its job here is surviving a teleporter malfunction, so on its
        -- own it is not a teleport at all.
        local hasTransporter = false
        for _, itemID in ipairs(TELEPORT_GROUPS.engineering) do
            if owned[itemID] then hasTransporter = true break end
        end

        for _, group in ipairs(TELEPORT_GROUP_ORDER) do
            if slots[group] ~= false then
                local candidates
                if group == "hearthstone" then
                    candidates = HearthstoneGroup(owned)
                elseif group == "parachute" then
                    candidates = hasTransporter and ParachuteGroup(owned) or {}
                else
                    candidates = TELEPORT_GROUPS[group]
                end

                local picked = {}
                for _, candidate in ipairs(candidates) do
                    -- Candidates come through as either a bare item ID or a
                    -- table carrying flags; normalise both here.
                    local itemID = candidate
                    local isToy = false
                    if type(candidate) == "table" then
                        itemID = candidate.itemID
                        isToy = candidate.isToy or false
                    end

                    -- A toy is owned rather than carried, so the bag scan has
                    -- nothing to say about it.
                    if isToy or owned[itemID] then
                        local extra = isToy and { isToy = true } or nil

                        if group == "parachute" then
                            local itemName = GetItemInfo(itemID)
                            local isWorn = worn[itemID] or false
                            if itemName then
                                -- One button, two states. The bar rebuilds on
                                -- PLAYER_EQUIPMENT_CHANGED, so clicking to
                                -- equip flips it to the use action by itself.
                                extra = {
                                    macrotext = isWorn
                                        and ("/use " .. itemName)
                                        or ("/equip " .. itemName),
                                    notReady = not isWorn,
                                    tooltipHint = isWorn
                                        and "Click to open the parachute"
                                        or "Click to equip, then click again to open",
                                }
                            end
                        end

                        local entry = AddItem(itemID, extra)
                        if entry then
                            entry.worn = worn[itemID] or false
                            table.insert(picked, entry)
                        end
                    end
                end
                if #picked > 0 then selection[group] = picked end

                -- Straight after the stones, so it lands next to them on the
                -- bar rather than at the end behind every other teleport.
                if group == "hearthstone" then
                    local recall = RecallSpellEntry()
                    if recall then
                        table.insert(items, recall)
                        selection.hearthstone = selection.hearthstone or {}
                        table.insert(selection.hearthstone, {
                            name = recall.spellName,
                            icon = recall.iconOverride,
                        })
                    end
                end
            end
        end

        -- One button per family, each fanning out into every spell in it.
        local mageSpells = GetMagePortals()
        for _, family in ipairs(MAGE_SPELL_FAMILIES) do
            local slotKey = family.slotKey
            local group = mageSpells[slotKey]
            if slots[slotKey] ~= false and group and #group.spells > 0 then
                selection[slotKey] = group.spells
                table.insert(items, {
                    slotKey = slotKey,
                    flyout = group.spells,
                    iconOverride = group.icon or group.spells[1].icon,
                    tooltipTitle = group.title or slotKey,
                    hideOnZero = false,
                    showInCombat = false,
                })
            end
        end

        -- Anything the item table above misses, added by hand.
        if slots.extras ~= false then
            local picked = {}
            for _, itemData in ipairs(grid.extras or {}) do
                local itemID = addon.GetItemIDFromData(itemData)
                if itemID and owned[itemID] then
                    local entry = AddItem(itemID)
                    if entry then table.insert(picked, entry) end
                end
            end
            if #picked > 0 then selection.extras = picked end
        end
    end

    grid.items = items
    self.teleportSelection = selection

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if EntryKey(itemData) ~= previous[i] then return true end
    end
    return false
end

-- What is loaded in the ammo slot, for hunters.
--
-- Running out empties the slot, which is exactly when the bar matters most, so
-- the last ammo seen is remembered and shown at 0 -- the low-supply warning
-- then marks it -- rather than the bar vanishing as the last arrow flies.
function addon:AmmoInfo()
    local slot = _G.INVSLOT_AMMO or 0
    local itemID = GetInventoryItemID("player", slot)
    if not itemID then
        local last = self.lastAmmo
        if not last then return nil end
        return { itemID = last.itemID, name = last.name, icon = last.icon, count = 0 }
    end

    local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    if not name then return nil end

    local count = GetInventoryItemCount and GetInventoryItemCount("player", slot)
        or GetItemCount(itemID)

    self.lastAmmo = { itemID = itemID, name = name, icon = icon }
    return { itemID = itemID, name = name, icon = icon, count = count or 0 }
end

-------------------------------
-- Ammo Bar
-------------------------------

-- Recompute the ammo bar. Returns true when the contents changed.
--
-- One slot, and a count rather than a button: nothing useful happens when you
-- click ammo, so this reports what is loaded and how much of it is left. Any
-- other class produces an empty bar, which never draws a frame.
function addon:UpdateAmmoBar()
    local grid = self:GetGrid(self.AMMO_GRID_ID)
    if not grid then return false end

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = addon.GetItemIDFromData(itemData)
    end

    local items = {}
    local selection = {}

    if grid.enabled and self:IsHunter() then
        local slots = grid.autoSlots or {}
        for _, slotName in ipairs(AMMO_SLOT_ORDER) do
            if slots[slotName] ~= false then
                local ammo = self:AmmoInfo()
                if ammo then
                    selection[slotName] = ammo
                    table.insert(items, {
                        slotKey = slotName,
                        itemID = ammo.itemID,
                        hideOnZero = false,
                        showInCombat = true,
                        countOverride = ammo.count,
                        inactive = true,
                        iconOverride = ammo.icon,
                        tooltipTitle = ammo.name,
                        tooltipHint = ammo.count .. " remaining",
                    })
                end
            end
        end
    end

    grid.items = items
    self.ammoSelection = selection

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if itemData.itemID ~= previous[i] then return true end
    end
    return false
end

-------------------------------
-- Weapon Enchant Bar
-------------------------------
-- Sharpening stones, weightstones and oils, with the time left on the enchant
-- currently on the weapon.

local ENCHANT_SLOT_ORDER = { "mainHand", "offHand" }
addon.ENCHANT_SLOT_ORDER = ENCHANT_SLOT_ORDER

-- Applying one is a two-step action, the same shape as Feed Pet: use the stone,
-- then apply it to a weapon slot. 16 is the main hand, 17 the off hand.
local WEAPON_SLOT = { mainHand = 16, offHand = 17 }
addon.WEAPON_SLOT = WEAPON_SLOT

-- Rogue poisons are weapon enchants in every way that matters here: they are
-- applied to a weapon slot, they expire, and GetWeaponEnchantInfo counts down
-- for them exactly as it does for a sharpening stone.
--
-- They are listed by item ID rather than recognised from a subclass or from
-- wording, for the same reason the Healthstone lineup is: the set is small,
-- fixed and fully known, and the poison *line* an item belongs to is what
-- decides which hand it goes on -- which no amount of tooltip reading reveals.
local POISON_LINES = {
    instant     = { 6947, 6949, 6950, 8926, 8927, 8928, 21927 },
    deadly      = { 2892, 2893, 8984, 8985, 20844, 22053, 22054 },
    wound       = { 10918, 10920, 10921, 10922, 22055 },
    crippling   = { 3775, 3776 },
    mindNumbing = { 5237, 6951, 9186 },
    anesthetic  = { 21835 },
}

-- Display order, and the labels the config uses.
local POISON_LINE_ORDER = { "instant", "deadly", "wound", "crippling",
                            "mindNumbing", "anesthetic" }
local POISON_LINE_NAMES = {
    instant     = "Instant Poison",
    deadly      = "Deadly Poison",
    wound       = "Wound Poison",
    crippling   = "Crippling Poison",
    mindNumbing = "Mind-numbing Poison",
    anesthetic  = "Anesthetic Poison",
}
addon.POISON_LINE_ORDER = POISON_LINE_ORDER
addon.POISON_LINE_NAMES = POISON_LINE_NAMES

local poisonLineOf = {}
for line, ids in pairs(POISON_LINES) do
    for _, itemID in ipairs(ids) do
        poisonLineOf[itemID] = line
    end
end

-- The standard pairing, so a rogue gets a working bar without opening anything.
-- Overridden per slot from the Weapon Enchants tab.
local DEFAULT_POISON_SLOT = { mainHand = "instant", offHand = "deadly" }
addon.DEFAULT_POISON_SLOT = DEFAULT_POISON_SLOT

-- Highest rank of one poison line in the bags, or of any line when `line` is
-- nil. Ranked by required level, so the ID list never has to be in rank order
-- and a rank I got wrong or missed cannot mis-sort the rest.
local function BestPoison(contents, line)
    local best = nil
    for _, entry in ipairs(contents) do
        local entryLine = poisonLineOf[entry.itemID]
        if entryLine and entry.count > 0 and (not line or entryLine == line) then
            if addon.IsUsableNow(entry.itemID, entry.bag, entry.slot) then
                if not best or entry.minLevel > best.minLevel
                    or (entry.minLevel == best.minLevel and entry.name < best.name) then
                    best = entry
                    best.poisonLine = entryLine
                end
            end
        end
    end
    return best
end

-- What is in a hand: whether it holds a weapon at all, and the weapon subclass
-- the enhancement list keys on. A shield or a held-in-off-hand is not a weapon
-- and takes none of this. The subclass comes back nil when the client cannot
-- say yet, which the fit check treats as fitting.
local function EquippedWeapon(slotName)
    local itemID = GetInventoryItemID("player", WEAPON_SLOT[slotName])
    if not itemID then return false, nil end
    if not GetItemInfoInstant then return true, nil end

    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemID)
    if classID == nil then return true, nil end
    if classID ~= addon.WEAPON_CLASS_ID then return false, nil end
    return true, subclassID
end

-- Best enhancement in the bags for the weapon in this hand, by required level.
--
-- The weapon type is part of the question, not a detail: a stone that cannot
-- go on what you are holding is not the best one, it is a button that refuses.
local function BestEnhancement(contents, weaponSubclass)
    local best = nil
    for _, entry in ipairs(contents) do
        if entry.info.isEnhancement and entry.count > 0
            and addon.EnhancementFitsWeapon(entry.itemID, weaponSubclass) then
            if addon.IsUsableNow(entry.itemID, entry.bag, entry.slot) then
                if not best or entry.minLevel > best.minLevel
                    or (entry.minLevel == best.minLevel and entry.name < best.name) then
                    best = entry
                end
            end
        end
    end
    return best
end

-- Seconds left on each weapon enchant, or nil where there is none.
--
-- The number of values per hand is not the same on every build: this client
-- returns four -- has, expiry, charges and the enchant id -- where older ones
-- return three. Assuming three read the off hand's "has" flag as its expiry
-- and did arithmetic on a boolean, which threw and took every bar with it, so
-- the stride is measured from the return count rather than assumed, and every
-- value is type-checked before it is used as a number.
function addon:WeaponEnchantTime()
    if type(GetWeaponEnchantInfo) ~= "function" then return nil, nil end

    local function Pack(...) return select("#", ...), { ... } end
    local count, values = Pack(GetWeaponEnchantInfo())
    local perHand = (count >= 8) and 4 or 3

    local function Seconds(has, expiry)
        if not has or type(expiry) ~= "number" or expiry <= 0 then return nil end
        -- Expiry arrives in milliseconds.
        return expiry / 1000
    end

    return Seconds(values[1], values[2]),
           Seconds(values[perHand + 1], values[perHand + 2])
end

-- Recompute the weapon enchant bar. Returns true when the contents changed.
function addon:UpdateEnchantBar()
    local grid = self:GetGrid(self.ENCHANT_GRID_ID)
    if not grid then return false end

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = addon.GetItemIDFromData(itemData)
    end

    local items = {}
    local selection = {}

    if grid.enabled then
        local contents = BagContents()
        local mainTime, offTime = self:WeaponEnchantTime()
        local slots = grid.autoSlots or {}
        local isRogue = self:IsRogue()
        local poisonSlots = grid.poisonSlots or {}

        for _, slotName in ipairs(ENCHANT_SLOT_ORDER) do
            -- A hand with no weapon in it has nothing to enchant. That covers
            -- the off hand holding a shield or nothing at all, and the main
            -- hand of someone who has unequipped -- which used to be assumed
            -- occupied and offered a stone with nowhere to go.
            local applicable, weaponSubclass = EquippedWeapon(slotName)
            local stone = BestEnhancement(contents, weaponSubclass)

            -- A rogue coats weapons rather than sharpening them, so poisons
            -- take the slot and the stones are the fallback. The two hands
            -- default to the standard pairing -- Instant on the main, Deadly
            -- on the off -- and drop to whatever poison is on hand when the
            -- preferred line is not.
            local pick = nil
            if isRogue then
                local wanted = poisonSlots[slotName]
                if wanted == nil then wanted = DEFAULT_POISON_SLOT[slotName] end
                if wanted == "auto" then wanted = nil end
                pick = BestPoison(contents, wanted) or BestPoison(contents, nil)
            end
            pick = pick or stone

            if slots[slotName] ~= false and applicable and pick then
                local remaining = slotName == "mainHand" and mainTime or offTime
                selection[slotName] = {
                    itemID = pick.itemID,
                    name = pick.name,
                    remaining = remaining,
                    poisonLine = pick.poisonLine,
                }
                table.insert(items, {
                    slotKey = slotName,
                    itemID = pick.itemID,
                    hideOnZero = true,
                    showInCombat = true,
                    -- Either hand from either button: left applies to the main
                    -- hand, right to the off hand. Which slot a button belongs
                    -- to still decides what it holds and whose timer it shows.
                    macrotext = "/use " .. pick.name ..
                                "\n/use " .. WEAPON_SLOT.mainHand,
                    macrotext2 = "/use " .. pick.name ..
                                 "\n/use " .. WEAPON_SLOT.offHand,
                    -- The countdown replaces the stack count; a lapsed enchant
                    -- is the thing worth noticing.
                    enchantSlot = slotName,
                    tooltipHint = "Left-click: main hand   Right-click: off hand",
                })
            end
        end
    end

    grid.items = items
    self.enchantSelection = selection

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if itemData.itemID ~= previous[i] then return true end
    end
    return false
end

-------------------------------
-- Combined Entry Point
-------------------------------

-- One updater must not be able to take the others down with it. This is called
-- from the event handler, so an error here aborted the handler mid-way and the
-- relayout that follows never ran -- one wrong assumption about a single API
-- left every bar off the screen. Each is isolated, and a failure is reported
-- once rather than swallowed.
local reportedFailures = {}

function addon:UpdateAutoBars()
    local changed = false

    for _, updater in ipairs({ "UpdateAutoBar", "UpdateBuffFoodBar",
                               "UpdatePotionBar", "UpdateAmmoBar",
                               "UpdateTeleportBar", "UpdateEnchantBar" }) do
        local ok, result = pcall(self[updater], self)
        if ok then
            changed = changed or result
        elseif not reportedFailures[updater] then
            reportedFailures[updater] = true
            self:Print("|cffff5555" .. updater .. " failed:|r " .. tostring(result))
        end
    end

    return changed
end

function addon:AutoBarNeedsRetry()
    return selectionIncomplete
end
