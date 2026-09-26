-- SnapSnack Items.lua
-- Bag and bank scanning, item classification, and player buff/zone tracking.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

local GetItemInfo    = addon.GetItemInfo
local GetItemCount   = addon.GetItemCount
local GetItemSpell   = addon.GetItemSpell
local IsUsableItem   = addon.IsUsableItem
local GetSpellInfo   = addon.GetSpellInfo
local BuffData       = addon.BuffData
local GetZonePVPInfo = addon.GetZonePVPInfo

local GetContainerNumSlots = addon.GetContainerNumSlots
local GetContainerItemID = addon.GetContainerItemID
local GetContainerItemInfo = addon.GetContainerItemInfo

local knownConsumables = addon.knownConsumables
local state = addon.state

local playerBuffs = {}
local buffToItem = {}

-------------------------------
-- Item Data Helpers
-------------------------------
-- Grid entries were plain itemIDs in v1.0 and are tables now. Both shapes have
-- to keep working.

function addon.GetItemIDFromData(itemData)
    if type(itemData) == "table" then
        return itemData.itemID
    end
    return itemData
end

-- What a keybind is attached to.
--
-- Keybinds used to be stored by the button's position in the bar, which meant
-- they belonged to a slot on screen rather than to anything you own. Automatic
-- bars skip empty slots, so spending the last Healthstone shifted every key
-- after it onto a different item -- and the ammo and enchant slots made that
-- worse, since a bar can now gain or lose a slot from an equipment change.
--
-- An automatic slot is identified by the slot itself: "the key for my food"
-- should follow the food slot as the item in it changes with your level. Every
-- other entry, including teleports and anything on a hand-made grid, is
-- identified by its item, so the key follows that item wherever it moves.
function addon.KeybindID(itemData)
    if type(itemData) == "table" and itemData.slotKey then
        return "slot:" .. itemData.slotKey
    end
    local itemID = addon.GetItemIDFromData(itemData)
    return itemID and ("item:" .. itemID) or nil
end

function addon.GetHideOnZeroFromData(itemData)
    if type(itemData) == "table" then
        return itemData.hideOnZero
    end
    return false
end

function addon.GetShowInCombatFromData(itemData)
    if type(itemData) == "table" then
        return itemData.showInCombat
    end
    return false
end

-------------------------------
-- Tooltip Scanner
-------------------------------

local scanner = CreateFrame("GameTooltip", "SnapSnackScanTooltip", UIParent, "GameTooltipTemplate")
scanner:SetOwner(UIParent, "ANCHOR_NONE")

local classifyCache = {}

-- Prefix of a format string, up to its first substitution.
local function FormatPrefix(fmt)
    if not fmt then return nil end
    local prefix = fmt:match("^(.-)%%")
    if not prefix or prefix == "" then return nil end
    return prefix
end

-- The restore keywords. Used both to read a restore amount and to tell an
-- effect line apart from a restriction line.
--
-- Built from the localised globals, with the English words kept as a floor.
-- These lists being empty is silent and total -- no line matches, every item
-- classifies as restoring nothing, and all four bars come up blank -- so a
-- client that does not define one of these globals must not be able to empty
-- the list. Duplicates are harmless: the first match wins and the word itself
-- is only used to locate the number.
local function KeywordList(...)
    local words, seen = {}, {}
    for _, word in ipairs({ ... }) do
        if type(word) == "string" and word ~= "" then
            local lower = word:lower()
            if not seen[lower] then
                seen[lower] = true
                table.insert(words, lower)
            end
        end
    end
    return words
end

local HEALTH_WORDS = KeywordList(HEALTH, "health")
local MANA_WORDS = KeywordList(MANA, "mana")
local DAMAGE_WORDS = KeywordList(DAMAGE, "damage")

-- The first of these keywords present in the text, or nil.
local function FindKeyword(lowerText, words)
    for _, word in ipairs(words) do
        if word and lowerText:find(word, 1, true) then return word end
    end
    return nil
end

local LEVEL_PREFIX = FormatPrefix(ITEM_MIN_LEVEL)      -- "Requires Level "
-- ITEM_REQ_SKILL is the usual source of the bare "Requires " prefix; if this
-- client does not define it, take the first word of the level line instead.
local REQUIRES_PREFIX = FormatPrefix(ITEM_REQ_SKILL)
    or (LEVEL_PREFIX and LEVEL_PREFIX:match("^(%S+%s)"))

-- Which effect family an item's use spell belongs to, or nil.
--
-- GetItemSpell reports the spell an item casts, and every consumable line in
-- the game shares one spell name per effect: all food is Food, all water is
-- Drink, every healing potion is Healing Potion. Comparing that name against
-- the name the client gives for one known rank of each family identifies the
-- family without a word of English in the code, on any locale, and without
-- reading a tooltip at all.
--
-- This is also what excludes ale and wine for free: their spell is Weak
-- Alcohol, which is in no family, so they are not food.
local familyByName = nil

local function SpellFamily(itemID)
    if not GetItemSpell then return nil, nil end

    -- Built on first use rather than at load: spell names are not necessarily
    -- available while the addon files are still running. An empty result is
    -- not cached, so this retries rather than answering nil forever.
    if not familyByName then
        local resolved = {}
        local any = false
        for family, spellID in pairs(addon.SPELL_ANCHORS) do
            local name = GetSpellInfo(spellID)
            if name then
                resolved[name] = family
                any = true
            end
        end
        if not any then return nil, nil end
        familyByName = resolved
    end

    local spellName, spellID = GetItemSpell(itemID)
    if not spellName then return nil, nil end
    return familyByName[spellName], spellID
end

-- Stand-in restore amount for a consumable the data table does not list.
--
-- The family says what it is; only the size is unknown. Required level is the
-- one number the API gives for free and it tracks potion tiers closely, so it
-- ranks a new or unlisted potion sensibly among known ones instead of the
-- alternative -- an amount of zero, which drops it off the bar entirely.
local function EstimatedAmount(itemID)
    local _, _, _, _, minLevel = GetItemInfo(itemID)
    return math.max(1, (minLevel or 1) * 10)
end

-- Everything the automatic bars need to know about an item. Results are
-- cached: they describe the item, not the situation. Usability is deliberately
-- NOT part of this -- see IsUsableNow.
--
-- Nothing here reads tooltip prose. What an item is comes from its ID in
-- CONSUMABLE_DATA, from its use spell's family, or from the item class the API
-- reports -- see the header of ItemData.lua for why.
local function ClassifyItem(itemID, bag, slot)
    if classifyCache[itemID] ~= nil then
        return classifyCache[itemID]
    end

    -- Not cached by the client yet. Leave it unclassified so the caller can
    -- retry on GET_ITEM_INFO_RECEIVED rather than remembering a guess.
    if not GetItemInfo(itemID) then
        return nil
    end

    local info = {
        food = false, drink = false, conjured = false,
        healAmount = 0, manaAmount = 0,
        isPotion = false, isBandage = false, zone = false, isZoneItem = false,
        isEnhancement = false, buffFood = false, isTableFood = false,
        estimated = false,
    }

    -- Sharpening stones, weightstones, oils and weapon coatings, named by ID
    -- in ItemData.lua. The item class cannot answer this -- see the table's
    -- header for what is actually on those shelves.
    info.isEnhancement = addon.WEAPON_ENHANCEMENTS[itemID] ~= nil

    local known = addon.CONSUMABLE_DATA[itemID]
    local family, spellID = SpellFamily(itemID)

    if known then
        -- The data table is the authority wherever it has something to say.
        local amount = known.amount or 0
        if known.kind == "food" then
            info.food = true
            info.healAmount = amount
            if known.tableFood then
                info.drink = true
                info.isTableFood = true
                info.manaAmount = known.manaAmount or amount
            end
        elseif known.kind == "drink" then
            info.drink = true
            info.manaAmount = amount
        elseif known.kind == "health" then
            info.isPotion = true
            info.healAmount = amount
        elseif known.kind == "mana" or known.kind == "gem" then
            info.isPotion = true
            info.manaAmount = amount
        elseif known.kind == "bandage" then
            info.isBandage = true
            info.healAmount = amount
        elseif known.kind == "zone" then
            -- Not a potion: it restores nothing the bars can rank, so it
            -- reaches none of the potion pools and gets a slot to itself.
            info.isZoneItem = true
        end
        info.conjured = known.conjured or false
        info.zone = known.zone or false

    elseif family == "food" then
        info.food = true
        info.healAmount = EstimatedAmount(itemID)
        info.estimated = true
        -- Plain food restores and nothing else. Anything else in the family
        -- also grants Well Fed, which is wasted on a pet.
        info.buffFood = not addon.PLAIN_FOOD_SPELLS[spellID or 0]

    elseif family == "nutritious" then
        -- Food that carries a buff, as its own spell line rather than as an
        -- exception to the plain one. Being in this family IS the answer, so
        -- there is no list of ranks to keep up to date.
        info.food = true
        info.healAmount = EstimatedAmount(itemID)
        info.estimated = true
        info.buffFood = true

    elseif family == "drink" then
        info.drink = true
        info.manaAmount = EstimatedAmount(itemID)
        info.estimated = true

    elseif family == "refreshment" then
        -- Restores both at once: a mage table, which fills the food slot and
        -- the water slot from the one item.
        info.food = true
        info.drink = true
        info.isTableFood = true
        info.conjured = true
        info.healAmount = EstimatedAmount(itemID)
        info.manaAmount = info.healAmount
        info.estimated = true

    elseif family == "healing" then
        info.isPotion = true
        info.healAmount = EstimatedAmount(itemID)
        info.estimated = true

    elseif family == "mana" then
        info.isPotion = true
        info.manaAmount = EstimatedAmount(itemID)
        info.estimated = true

    elseif family == "gem" then
        -- Replenish Mana is the mage gem line and nothing else, so this is a
        -- gem whether or not the tooltip ever said Conjured Item.
        info.isPotion = true
        info.conjured = true
        info.manaAmount = EstimatedAmount(itemID)
        info.estimated = true

    elseif family == "bandage" then
        info.isBandage = true
        info.healAmount = EstimatedAmount(itemID)
        info.estimated = true
    end

    -- Healthstones name their use spell per rank -- Minor Healthstone through
    -- Master Healthstone -- so no one family name reaches them. The table is
    -- the whole answer, and it wins over anything decided above.
    local healthstone = addon.HEALTHSTONE_ITEMS[itemID]
    if healthstone then
        info.healAmount = healthstone.amount
        info.manaAmount = 0
        info.isPotion = true
        info.isBandage = false
        info.food = false
        info.drink = false
        info.conjured = true
        info.isTableFood = false
        info.estimated = false
    end

    classifyCache[itemID] = info
    return info
end

addon.ClassifyItem = ClassifyItem

-- Can this be used right here, right now?
--
-- An unmet requirement renders red in the tooltip, so one colour check covers
-- zone restriction, character level and skill together with no hardcoded
-- strings. This is what makes a Bottled Nethergon Energy appear on entering
-- Tempest Keep and disappear on leaving, so it must never be cached.
local usableCache = {}
-- Declared here, beside the cache it is cleared with: a local declared further
-- down the file would be a global (nil) inside ClearRestrictionCache below.
local restrictionCache = {}

-- Usability only changes when the player moves, so one cache generation per
-- zone keeps this off the per-bag-update path without ever going stale.
function addon.ClearUsableCache()
    wipe(usableCache)
end

-- Exposed for the diagnostic, which should always read live tooltips.
function addon.ClearRestrictionCache()
    wipe(restrictionCache)
end

-- Classification describes the item rather than the situation, so it is cached
-- for the session. That also means one bad read -- a tooltip that came back
-- empty -- would stick for the session, which is why the rescan commands throw
-- it away rather than trusting it.
function addon.ClearClassifyCache()
    wipe(classifyCache)
end

-- Build the scan tooltip for an item, preferring the bag slot.
--
-- This distinction is the whole trick: SetHyperlink produces a context-free
-- tooltip, so unmet requirements are never coloured -- which is why a
-- zone-locked item like Bottled Nethergon Energy looked usable everywhere.
-- SetBagItem produces the contextual tooltip, where the requirement you fail
-- renders red.
local function BuildScanTooltip(itemID, bag, slot)
    if bag and slot then
        scanner:SetOwner(UIParent, "ANCHOR_NONE")
        scanner:ClearLines()
        pcall(scanner.SetBagItem, scanner, bag, slot)
        if (scanner:NumLines() or 0) > 0 then return true end
    end

    -- Slot moved, emptied, or the call gave nothing. Re-own before the
    -- fallback: a tooltip left in a half-built state does not reliably
    -- repopulate from SetHyperlink alone.
    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner:ClearLines()
    pcall(scanner.SetHyperlink, scanner, "item:" .. itemID)
    return (scanner:NumLines() or 0) > 0
end

-- Every red line in the tooltip, which is how the client marks a requirement
-- you do not meet. Returned rather than just counted so the diagnostic command
-- can show exactly what was found.
local function RedLines(itemID, bag, slot)
    if not BuildScanTooltip(itemID, bag, slot) then return nil end

    local found = {}
    for i = 1, scanner:NumLines() do
        local fontString = _G["SnapSnackScanTooltipTextLeft" .. i]
        local text = fontString and fontString:GetText()
        if text then
            local r, g, b = fontString:GetTextColor()
            if r and g and b and r > 0.9 and g < 0.3 and b < 0.3 then
                table.insert(found, text)
            end
        end
    end
    return found
end

addon.ScanRedLines = RedLines

-- Prefixes that introduce an item's spell effect, so those lines can be told
-- apart from a restriction that follows them.
local TRIGGER_PREFIXES = {}
for _, prefix in ipairs({ ITEM_SPELL_TRIGGER_ONUSE, ITEM_SPELL_TRIGGER_ONEQUIP,
                          ITEM_SPELL_TRIGGER_ONPROC }) do
    if type(prefix) == "string" and prefix ~= "" then
        table.insert(TRIGGER_PREFIXES, prefix)
    end
end

-- Lines stating WHERE an item may be used.
--
-- Green is the spell-effect colour, so a zone-locked consumable has two green
-- lines and an ordinary potion has one:
--
--   Use: Restores 1500 to 2500 health.                    <- green, a trigger
--   Only works inside Tempest Keep: The Eye, ...          <- green, no trigger
--
-- A green line that does not open with Use:/Equip:/Chance on hit: is therefore
-- a usage restriction. That structural test needs no item IDs at all, which
-- matters because the restriction is otherwise plain prose -- it carries no
-- Requires prefix and is never coloured red, so the red-line check cannot see
-- it and every hardcoded list of these items goes stale.
local function RestrictionLines(itemID, bag, slot)
    if restrictionCache[itemID] then return restrictionCache[itemID] end

    -- Item data not in yet: answer for now, but do not remember the answer.
    if not GetItemInfo(itemID) then return nil end
    if not BuildScanTooltip(itemID, bag, slot) then return nil end

    -- Structural, not colour-based.
    --
    -- Colour turned out to be unreliable: the restriction line does not come
    -- back green from a scanned tooltip even though it renders green in game,
    -- so a colour test found nothing and every zone item read as unrestricted.
    -- The layout, though, is completely consistent:
    --
    --   Bottled Nethergon Vapor                     <- name        (line 1)
    --   Requires Level 55                           <- requirement
    --   Use: Restores 1500 to 2500 health.          <- the effect
    --                                               <- blank
    --   Only works inside Tempest Keep: ...         <- RESTRICTION
    --   "Inhale deeply."                            <- flavour, quoted
    --
    -- So: prose after the effect line that is neither a requirement nor the
    -- quoted flavour text is a usage restriction. An ordinary potion has
    -- nothing there at all.
    local lines = {}
    local effectLine = nil

    -- Flatten first. A single tooltip line can carry several lines of text
    -- separated by newlines, and the zone restriction is glued to the end of
    -- the Use line rather than standing on its own -- which is why iterating
    -- tooltip lines alone never found it.
    local segments = {}
    for i = 2, scanner:NumLines() do
        local fontString = _G["SnapSnackScanTooltipTextLeft" .. i]
        local text = fontString and fontString:GetText()
        if text then
            for segment in text:gmatch("[^\n]+") do
                table.insert(segments, segment)
            end
        end
    end

    for i, text in ipairs(segments) do
        if text ~= "" then
            if not effectLine then
                local lower = text:lower()
                for _, prefix in ipairs(TRIGGER_PREFIXES) do
                    if text:sub(1, #prefix) == prefix then effectLine = i break end
                end
                if not effectLine then
                    if FindKeyword(lower, HEALTH_WORDS)
                        or FindKeyword(lower, MANA_WORDS)
                        or FindKeyword(lower, DAMAGE_WORDS) then
                        effectLine = i
                    end
                end
            elseif i > effectLine then
                local isFlavour = text:sub(1, 1) == '"' or text:sub(1, 1) == "'"

                local isRequirement = false
                if REQUIRES_PREFIX and text:sub(1, #REQUIRES_PREFIX) == REQUIRES_PREFIX then
                    isRequirement = true
                end

                -- A crafter tag, <Made by Someone>, is not a restriction.
                if text:sub(1, 1) == "<" then isRequirement = true end

                -- A second effect line is an effect, not a restriction: an item
                -- can carry both Equip: and Use:.
                for _, prefix in ipairs(TRIGGER_PREFIXES) do
                    if text:sub(1, #prefix) == prefix then
                        isRequirement = true
                        break
                    end
                end

                -- A restriction names places and carries no numbers. Spell text
                -- does, and "Deals 900 to 1100 fire damage" was being read as
                -- a restriction on a Fire Bomb.
                if text:find("%d") then isRequirement = true end

                -- "Only works inside Tempest Keep: ..." runs to 80-odd
                -- characters. A cooldown or a class tag does not, and reading
                -- one as a restriction would block the item everywhere.
                local isProse = #text >= 25

                if isProse and not isFlavour and not isRequirement then
                    table.insert(lines, text)
                end
            end
        end
    end

    restrictionCache[itemID] = lines
    return lines
end

addon.RestrictionLines = RestrictionLines

-- Every tooltip line with its colour, for the diagnostic. Never cached.
function addon.DumpTooltip(itemID, bag, slot)
    if not BuildScanTooltip(itemID, bag, slot) then return nil end

    local dump = {}
    for i = 1, scanner:NumLines() do
        local fontString = _G["SnapSnackScanTooltipTextLeft" .. i]
        local text = fontString and fontString:GetText()
        if text then
            local r, g, b = fontString:GetTextColor()
            table.insert(dump, { text = text, r = r or 1, g = g or 1, b = b or 1 })
        end
    end
    return dump
end

function addon.HasUsageRestriction(itemID, bag, slot)
    local lines = RestrictionLines(itemID, bag, slot)
    return lines ~= nil and #lines > 0
end

-- Every name the client has for where we are standing. Four of them, because
-- no single one is reliable: an instance answers with its own name, an inn
-- answers with the inn, and a restriction line can be written against any of
-- them.
local function CurrentZoneNames()
    local names = {}
    for _, fn in ipairs({ GetRealZoneText, GetSubZoneText, GetZoneText,
                          GetMinimapZoneText }) do
        if fn then
            local ok, text = pcall(fn)
            if ok and type(text) == "string" and text ~= "" then
                names[#names + 1] = text
            end
        end
    end
    return names
end
addon.CurrentZoneNames = CurrentZoneNames

-- Where the item data says this one works, if it says anything.
--
-- Returns nil when the item names no zones, which is not the same answer as
-- false: nil means "nothing listed, ask the tooltip", false means "listed, and
-- this is not one of them". An item that only works somewhere, on a client
-- whose tooltip never says so, can be gated no other way.
--
-- Matched as a substring and case-insensitively, so a list of "Skywall" covers
-- every sub-zone carrying the name without each having to be written down.
local function ListedZoneSatisfied(itemID)
    local known = addon.CONSUMABLE_DATA[itemID]
    local zones = known and known.zones
    if not zones then return nil end

    for _, here in ipairs(CurrentZoneNames()) do
        local haystack = here:lower()
        for _, zone in ipairs(zones) do
            if haystack:find(zone:lower(), 1, true) then return true end
        end
    end

    return false
end

-- Does a restriction line name the place we are standing in?
local function ZoneRestrictionSatisfied(itemID, bag, slot)
    -- The item data is the authority wherever it has something to say, exactly
    -- as it is for what an item restores.
    local listed = ListedZoneSatisfied(itemID)
    if listed ~= nil then return listed end

    local restrictions = RestrictionLines(itemID, bag, slot)
    -- Unreadable, or simply unrestricted.
    if not restrictions or #restrictions == 0 then return true end

    local here = CurrentZoneNames()

    for _, line in ipairs(restrictions) do
        for _, zone in ipairs(here) do
            if line:find(zone, 1, true) then
                return true
            end
        end
    end

    return false
end

function addon.IsUsableNow(itemID, bag, slot)
    if usableCache[itemID] ~= nil then
        return usableCache[itemID]
    end

    if not GetItemInfo(itemID) then return true end

    -- Two separate gates: red lines catch failed Requires lines (level, skill),
    -- and the zone check catches restrictions written as prose.
    --
    -- The red-line gate fails OPEN and the zone gate fails CLOSED, and that
    -- asymmetry is deliberate. A scan failure used to do both wrong at once:
    -- ordinary potions vanished while zone items showed everywhere.
    local red = RedLines(itemID, bag, slot)
    if not red then
        -- Nothing readable. Do not cache a guess, and do not hide the item:
        -- a scan failure is not evidence, and hiding every potion is far worse
        -- than briefly offering one you cannot drink.
        return true
    end

    local usable = #red == 0 and ZoneRestrictionSatisfied(itemID, bag, slot)
    usableCache[itemID] = usable
    return usable
end

-- Could a pet plausibly eat this?
--
-- Note this is "is food", not "matches this pet's diet". The 2.5.6 API does not
-- expose an individual food item's diet type -- only the pet side, through
-- GetPetFoodTypes -- so the picker narrows the list and colours it by level
-- rather than claiming to filter by diet exactly. Diet itself is learned by
-- feeding.
-- Is this item within the character's level requirement?
function addon.MeetsPlayerLevel(itemID)
    local _, _, _, _, minLevel = GetItemInfo(itemID)
    return (minLevel or 0) <= (UnitLevel("player") or 1)
end

-- One definition of "food that belongs on the player food bar", used both by
-- the bar itself and by the pet food picker, so the two cannot drift apart.
--
-- Food & Drink class AND an actual health restore. The restore is what does the
-- work: requiring only the class let alcohol through (Food & Drink, restores
-- nothing) and, while Trade Goods was included to catch raw meat, every cooking
-- reagent in the Meat subclass -- which is where Spider Ichor and Gooey Spider
-- Legs came from. Reagents have no restore line at all.
function addon.IsPlayerFood(itemID)
    local info = ClassifyItem(itemID)
    -- Not cached yet. Excluded for now and retried on GET_ITEM_INFO_RECEIVED,
    -- so a half-loaded bag never shows junk.
    if not info or not info.food then return false end
    return addon.MeetsPlayerLevel(itemID)
end

function addon.IsPlayerDrink(itemID)
    local info = ClassifyItem(itemID)
    if not info or not info.drink then return false end
    return addon.MeetsPlayerLevel(itemID)
end

-- Crafted food: food by the spell it casts, and not one of the plain vendor
-- ranks. The distinction is the use spell -- not the name, not the quality, and
-- emphatically not the tooltip prose, which is what keeps recipes, camp kits and
-- everything else that happens to mention experience off a bar meant to hold
-- food you can eat.
--
-- Anything the data table already describes is left alone: that table is the
-- vendor food and water, which is exactly what this is trying to exclude.
function addon.IsBuffFoodItem(itemID)
    if not addon.IsPlayerFood(itemID) then return false end
    local info = ClassifyItem(itemID)
    return (info and info.buffFood) or false
end

function addon.IsPetEdible(itemID)
    -- Exactly the food that would populate the player food bar...
    if not addon.IsPlayerFood(itemID) then return false end

    local info = ClassifyItem(itemID)

    -- ...minus what is no use to a pet.
    --
    -- Pets do not drink, which rules out every water and combo items like
    -- conjured biscuits.
    if info.drink then return false end

    -- Buff food would be wasted -- the pet gains nothing from the stats. Which
    -- food is buff food comes from its use spell: the plain ranks restore and
    -- do nothing else, so anything else in the Food family carries a Well Fed.
    if info.buffFood then return false end

    return true
end

-- Escape hatch for anything the "requirement beyond level" heuristic misses.
-- Add item IDs here to force zone-consumable priority.
local ZONE_CONSUMABLE_OVERRIDE = {}

function addon.IsZoneConsumable(itemID, bag, slot)
    if ZONE_CONSUMABLE_OVERRIDE[itemID] then return true end

    -- An item that names its own zones is a zone consumable by that fact.
    local known = addon.CONSUMABLE_DATA[itemID]
    if known and known.zones then return true end

    -- Listed by ID, which is the whole answer for every zone consumable in the
    -- game as it stands.
    local info = ClassifyItem(itemID, bag, slot)
    if info and info.zone then return true end

    -- For anything unlisted, a green "only works inside ..." line still says
    -- so. This one stays a tooltip read on purpose: where an item works is not
    -- a property of the item alone, it depends on where you are standing, and
    -- no ID list can answer it -- see IsUsableNow.
    return addon.HasUsageRestriction(itemID, bag, slot)
end

-- Safety net in case a future item breaks the restores-both signature.
local TABLE_FOOD_OVERRIDE = {}

function addon.IsTableFood(itemID)
    if TABLE_FOOD_OVERRIDE[itemID] then return true end
    local info = ClassifyItem(itemID)
    return info and info.isTableFood or false
end

-- Replaces the old name-substring guess. "Conjured Item" is an exact,
-- localised tooltip line.
function addon.IsConjuredItem(itemID)
    local info = ClassifyItem(itemID)
    return info and info.conjured or false
end

-------------------------------
-- Usable Item Detection
-------------------------------

local CONSUMABLE_TYPES = {
    ["Consumable"] = true,
    ["Trade Goods"] = true,
    ["Miscellaneous"] = true,
}

local CONSUMABLE_SUBTYPES = {
    ["Food & Drink"] = true,
    ["Potion"] = true,
    ["Elixir"] = true,
    ["Flask"] = true,
    ["Bandage"] = true,
    ["Scroll"] = true,
    ["Other"] = true,
    ["Item Enhancement"] = true,
    ["Consumable"] = true,
    ["Junk"] = true,
    ["Reagent"] = true,
}

local ALWAYS_INCLUDE_ITEMS = {
    [6948] = true,   -- Hearthstone
}

-- Returns true/false, or nil when the item is not cached yet.
local function IsUsableItem(itemID)
    if ALWAYS_INCLUDE_ITEMS[itemID] then
        return true
    end

    local itemName, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
    if not itemName then return nil end

    local spellName = GetItemSpell(itemID)

    if CONSUMABLE_TYPES[itemType] then
        if CONSUMABLE_SUBTYPES[itemSubType] or itemSubType == "" or spellName then
            return true
        end
    end

    if spellName then
        return true
    end

    return false
end

-------------------------------
-- Bag Scanning
-------------------------------

local function Remember(itemID)
    if knownConsumables[itemID] then return end
    local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
    if itemName then
        knownConsumables[itemID] = {
            name = itemName,
            icon = itemIcon,
            itemID = itemID,
        }
    end
end

function addon:ScanBags()
    local seen = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID and not seen[itemID] then
                seen[itemID] = true
                local usable = IsUsableItem(itemID)
                if usable then
                    Remember(itemID)
                elseif usable == nil then
                    -- Not cached yet; retry when the client has the data.
                    local item = Item:CreateFromItemID(itemID)
                    item:ContinueOnItemLoad(function()
                        if IsUsableItem(itemID) then
                            Remember(itemID)
                        end
                    end)
                end
            end
        end
    end
end

-- Every itemID any profile has on a bar. Used to keep the bank snapshot from
-- recording the entire bank.
local function TrackedItemIDs()
    local tracked = {}
    for _, profile in pairs(SnapSnackDB.profiles or {}) do
        for _, grid in pairs(profile.grids or {}) do
            for _, itemData in ipairs(grid.items or {}) do
                local itemID = addon.GetItemIDFromData(itemData)
                if itemID then tracked[itemID] = true end
            end
            -- A generated bar's contents are not written to disk; the flat
            -- list of IDs left in their place is how a character who is not
            -- logged in still contributes to what the bank scan records.
            for _, itemID in ipairs(grid.autoItems or {}) do
                tracked[itemID] = true
            end
        end
    end
    return tracked
end

function addon:ScanBank()
    if not SnapSnackDB then return end

    -- Keyed by the readable name, not the profile key: these entries are
    -- printed straight into tooltips as "who else is carrying this", and a
    -- GUID there would tell nobody anything.
    local charKey = self:CharLabel()
    local bankItems = self:GetGlobal().bankItems
    local tracked = TrackedItemIDs()

    bankItems[charKey] = {}
    local store = bankItems[charKey]

    -- -1 is the main bank, 5-11 the bank bag slots.
    local bankBags = { -1, 5, 6, 7, 8, 9, 10, 11 }
    for _, bag in ipairs(bankBags) do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID and tracked[itemID] then
                local itemInfo = GetContainerItemInfo(bag, slot)
                local count = itemInfo and itemInfo.stackCount or 1
                store[itemID] = (store[itemID] or 0) + count
            end
        end
    end
end

function addon:GetBankAndAltCount(itemID)
    if not SnapSnackDB then return 0, {} end

    local currentCharKey = self:CharLabel()
    local bankCount = 0
    local altCounts = {}

    for charKey, items in pairs(self:GetGlobal().bankItems) do
        if charKey == currentCharKey then
            bankCount = items[itemID] or 0
        elseif items[itemID] and items[itemID] > 0 then
            altCounts[charKey] = items[itemID]
        end
    end

    return bankCount, altCounts
end

-- Everything on a bar that is at or below that bar's low-supply threshold,
-- with what is waiting in the bank and on other characters.
--
-- Two callers want different slices of the same walk: the instance-entry
-- warning only wants bars that opted into warning, and /chair snack restock wants every
-- enabled bar, because asking is the opt-in.
--
-- Bank and alt counts come from the account-wide snapshot the tooltips already
-- use, which is the difference between "buy more" and "it is in the bank".
function addon:GetLowSupplyReport(warnedBarsOnly)
    local report = {}
    local anyThreshold = false

    for _, db in pairs(self:GetGrids()) do
        local threshold = db.lowSupply or 0
        if db.enabled and threshold > 0 then
            if not warnedBarsOnly or db.warnOnInstanceEntry then
                anyThreshold = true

                local short = {}
                local seen = {}
                for _, itemData in ipairs(db.items or {}) do
                    local itemID = addon.GetItemIDFromData(itemData)
                    if itemID and not seen[itemID] then
                        seen[itemID] = true
                        local count = (type(itemData) == "table"
                            and itemData.countOverride) or GetItemCount(itemID)
                        local name = GetItemInfo(itemID)
                        if name and count <= threshold then
                            local bank, alts = self:GetBankAndAltCount(itemID)
                            table.insert(short, {
                                itemID = itemID, name = name, count = count,
                                threshold = threshold, bank = bank, alts = alts,
                            })
                        end
                    end
                end

                if #short > 0 then
                    table.sort(short, function(a, b) return a.name < b.name end)
                    table.insert(report, { name = db.name or "?", items = short })
                end
            end
        end
    end

    table.sort(report, function(a, b) return a.name < b.name end)
    return report, anyThreshold
end

-------------------------------
-- Buff & Zone Tracking
-------------------------------

-- Scanned into a table of its own and only swapped in once the whole scan
-- came back. A refused read (see addon.BuffData) used to wipe the snapshot and
-- then abort, which read as "no buffs at all" -- the buff food bar would come
-- up and every on-icon timer would vanish, on a client that had simply
-- declined to answer. Keeping the previous snapshot leaves the timers a little
-- stale instead, and the next UNIT_AURA replaces it.
function addon:CheckPlayerBuffs()
    local scanned = {}

    for i = 1, 40 do
        local aura, refused = BuffData("player", i)
        if refused then return false end
        if not aura or not aura.name then break end

        local buff = {
            name = aura.name, icon = aura.icon, spellId = aura.spellId,
            -- Already on the aura; previously discarded, and the only thing an
            -- on-icon countdown needs.
            duration = aura.duration, expirationTime = aura.expirationTime,
        }
        -- Keyed by both, but only by an ID the client actually gave us: a nil
        -- key is an error, not an empty slot.
        if aura.spellId then scanned[aura.spellId] = buff end
        scanned[aura.name] = buff
    end

    wipe(playerBuffs)
    for key, buff in pairs(scanned) do playerBuffs[key] = buff end
    return true
end

-- A read-only view of the player's buffs, keyed by both spell ID and name.
-- Exported so nothing else has to run a second scan of its own: this one is
-- already refreshed on every UNIT_AURA.
function addon:PlayerBuffs()
    return playerBuffs
end

function addon:CheckIfInCity()
    -- A client with neither the global nor C_PvP still rests in an inn, which
    -- covers most of what this is asked about.
    local pvpType = GetZonePVPInfo and GetZonePVPInfo()
    state.inCity = (pvpType == "sanctuary") or IsResting()
end

local function GetItemBuffSpellID(itemID)
    local spellName, spellID = GetItemSpell(itemID)
    if spellID then
        buffToItem[spellID] = itemID
        buffToItem[spellName] = itemID
        return spellID, spellName
    end
    return nil
end

-- Seconds remaining on the buff this item applies, or nil when it is not up or
-- has no duration. Timeless buffs report expirationTime 0.
function addon.BuffTimeRemaining(itemID)
    local spellID, spellName = GetItemBuffSpellID(itemID)
    local buff = (spellID and playerBuffs[spellID]) or (spellName and playerBuffs[spellName])
    if not buff or not buff.expirationTime or buff.expirationTime <= 0 then
        return nil
    end

    local remaining = buff.expirationTime - GetTime()
    if remaining <= 0 then return nil end
    return remaining
end

function addon.IsBuffActive(itemID)
    local spellID, spellName = GetItemBuffSpellID(itemID)
    if spellID and playerBuffs[spellID] then return true end
    if spellName and playerBuffs[spellName] then return true end
    return false
end

function addon.HasAssociatedBuff(itemID)
    local _, spellID = GetItemSpell(itemID)
    return spellID ~= nil
end

-------------------------------
-- Dropdown Item List
-------------------------------

function addon:GetSortedConsumableList()
    local list = {}
    for itemID, data in pairs(knownConsumables) do
        table.insert(list, { id = itemID, name = data.name })
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end
