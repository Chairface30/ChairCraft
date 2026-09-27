local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

-------------------------------------------------------------------------------
-- Buff food
-------------------------------------------------------------------------------
-- Crafted food grants a buff -- on this build, bonus experience from things you
-- kill. That makes it a different kind of consumable from everything else the
-- addon handles: you do not eat it because you are hurt, you eat it because it
-- has worn off. So it gets a bar of its own, carrying everything you own rather
-- than the single best item, and the bar hides itself the moment the buff is up.
--
-- What counts as buff food is decided by addon.IsBuffFoodItem, which asks two
-- questions the client can actually answer: is this food, by the spell the item
-- casts, and is that spell one of the plain vendor ranks. Food that casts
-- anything else grants a buff, and that is the whole test.
--
-- It is worth saying why it is not a tooltip test. Reading the tooltip for a
-- mention of experience looks like the obvious approach and is wrong: recipes
-- quote the food they teach, camp kits grant experience without being food, and
-- neither is something you can eat off a bar. The use spell has none of that
-- ambiguity -- an item either casts a food spell or it does not.
--
-- The buff itself is the one thing still matched on wording. The food casts an
-- eating spell and the spell applies the buff, so there is no link from item to
-- aura to follow. The word list lives in the saved variables so a wrong guess
-- can be corrected in game with /chair snack bufffood rather than by editing code, and
-- the first time a name match succeeds the spell ID behind it is remembered --
-- so a guess only has to be right once.

local GetItemInfo = addon.GetItemInfo
local GetItemInfoInstant = addon.GetItemInfoInstant
local GetItemSpell = addon.GetItemSpell
local GetItemCount = addon.GetItemCount
local GetContainerNumSlots = addon.GetContainerNumSlots
local GetContainerItemID = addon.GetContainerItemID

local BUFF_FOOD_GRID_ID = addon.BUFF_FOOD_GRID_ID

-- Words that mark an aura as the food buff. A default rather than something
-- written into the saved file, which has a hard size budget on this client and
-- no room for settings nobody changed.
local DEFAULT_AURA_WORDS = { "well fed" }

-- What this client files under Food & Drink, by item class rather than by use
-- spell. The spell-family test the classifier uses is the better one where it
-- works -- it tells ale from bread without a word of English in the code -- but
-- it only recognises a spell whose NAME matches a known rank, so food this
-- build named differently is not food as far as it is concerned.
--
-- The picker cannot depend on that. A list showing nothing cannot be corrected
-- by hand, which would leave no way to get a food onto the bar at all. So the
-- picker offers anything the client itself files as food, and the classifier
-- only decides what is ticked for you.
local ITEM_CLASS_CONSUMABLE = 0
local ITEM_SUBCLASS_FOOD = 5

local function LooksLikeFood(itemID)
    if addon.IsPlayerFood(itemID) then return true end
    if not GetItemInfoInstant then return false end

    local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(itemID)
    return classID == ITEM_CLASS_CONSUMABLE and subClassID == ITEM_SUBCLASS_FOOD
end

-------------------------------------------------------------------------------
-- The stores
-------------------------------------------------------------------------------

local function Global()
    return addon:GetGlobal()
end

local function AuraWords()
    local global = Global()
    local custom = global and global.buffFoodAuraWords
    if type(custom) == "table" and #custom > 0 then return custom end
    return DEFAULT_AURA_WORDS
end

-- Spell IDs known to be the buff. Small, and the only part of this worth
-- keeping between sessions: it is what turns a guess into a fact.
local function KnownSpells()
    local global = Global()
    if not global then return {} end
    global.buffFoodSpells = global.buffFoodSpells or {}
    return global.buffFoodSpells
end

local function Learn(spellID)
    if not spellID then return end
    KnownSpells()[spellID] = true
end

local function Overrides(key)
    local global = Global()
    if not global then return {} end
    global[key] = global[key] or {}
    return global[key]
end

local function MatchesAnyWord(text, words)
    if type(text) ~= "string" then return false end
    local lowered = text:lower()
    for _, word in ipairs(words) do
        if lowered:find(word, 1, true) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Is this item buff food?
-------------------------------------------------------------------------------

function addon:BuffFoodMode()
    local grid = self:GetGrid(BUFF_FOOD_GRID_ID)
    return (grid and grid.mode) or "both"
end

function addon:SetBuffFoodMode(mode)
    local grid = self:GetGrid(BUFF_FOOD_GRID_ID)
    if not grid then return end
    grid.mode = mode
    self:UpdateAutoBars()
    self:UpdateAllGrids()
end

-- A drop always wins, whatever the mode: an item you took off the bar by hand
-- was taken off for a reason, and having the classifier put it back would make
-- the tick box a suggestion rather than a setting.
function addon:IsBuffFood(itemID)
    if not itemID then return false end
    if Overrides("buffFoodExcluded")[itemID] then return false end

    local picked = Overrides("buffFoodIncluded")[itemID] and true or false
    local mode = self:BuffFoodMode()

    if mode == "manual" then return picked end
    if mode == "auto" then return addon.IsBuffFoodItem(itemID) end
    return picked or addon.IsBuffFoodItem(itemID)
end

-- Does the buff food bar have this item? Which is what the plain food and
-- drink bar asks before offering anything, so the same food is never on both:
-- the plain slot is the food you eat to top off, and that is a different
-- decision from the food you eat for the stats.
--
-- Bar membership rather than "does it grant a buff", because membership is the
-- answer that already has the player's corrections in it. A Longjaw Mud
-- Snapper is detected and drops off the plain bar; a Raw Brilliant Smallfish
-- the detection got wrong and the player unticked stays on the plain bar,
-- where they clearly want it.
--
-- With the bar switched off nothing claims anything: hiding a food from the
-- plain bar in favour of a bar that is not on screen would just lose it.
function addon:BuffFoodBarClaims(itemID)
    local grid = self:GetGrid(BUFF_FOOD_GRID_ID)
    if not (grid and grid.enabled) then return false end
    return self:IsBuffFood(itemID)
end

-- One tick box, one meaning: ticked is on the bar, unticked is off it. Which
-- of the two stores that writes to depends on what the classifier already
-- thinks, because unticking something it detected has to be recorded as a
-- refusal rather than as the absence of a pick.
function addon:SetBuffFoodPicked(itemID, picked)
    if not itemID then return end
    local included = Overrides("buffFoodIncluded")
    local excluded = Overrides("buffFoodExcluded")

    if picked then
        excluded[itemID] = nil
        -- Only recorded when it would otherwise not be there, so the saved
        -- file does not fill up with agreement.
        included[itemID] = (not addon.IsBuffFoodItem(itemID)) or nil

        -- Ticking a box in a mode that ignores ticks would do nothing and look
        -- broken, so the mode comes along.
        if self:BuffFoodMode() == "auto" and included[itemID] then
            local grid = self:GetGrid(BUFF_FOOD_GRID_ID)
            if grid then grid.mode = "both" end
        end
    else
        included[itemID] = nil
        excluded[itemID] = addon.IsBuffFoodItem(itemID) or nil
    end

    self:UpdateAutoBars()
    self:UpdateAllGrids()
end

-- Everything worth offering in the picker: the food you are carrying, plus
-- anything you have already picked, so a choice does not vanish from the list
-- the moment you run out of it.
function addon:BuffFoodCandidates()
    local list, seen = {}, {}

    local function Consider(itemID)
        if not itemID or seen[itemID] then return end
        seen[itemID] = true

        local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
        if not name then return end

        list[#list + 1] = {
            itemID = itemID,
            name = name,
            icon = icon,
            count = (GetItemCount and GetItemCount(itemID)) or 0,
            detected = addon.IsBuffFoodItem(itemID),
            -- Whether the classifier recognises it as food at all, which is a
            -- different failure from recognising it and calling it plain.
            known = addon.IsPlayerFood(itemID),
            onBar = self:IsBuffFood(itemID),
        }
    end

    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local itemID = GetContainerItemID(bag, slot)
            -- Food only. The picker is for balancing which food goes on the
            -- bar, not for putting arbitrary items there -- that is what an
            -- ordinary hand-made grid is for.
            if itemID and LooksLikeFood(itemID) then Consider(itemID) end
        end
    end

    for itemID in pairs(Overrides("buffFoodIncluded")) do Consider(itemID) end

    table.sort(list, function(a, b)
        if a.onBar ~= b.onBar then return a.onBar end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

-------------------------------------------------------------------------------
-- Is the buff up?
-------------------------------------------------------------------------------

-- The buffs come from addon.BuffData, which makes name and spellId plain
-- (or refuses the aura) before anything here lowercases or searches them.
function addon:HasFoodBuff()
    local buffs = self:PlayerBuffs()
    if not buffs then return false end

    local known = KnownSpells()
    local words = AuraWords()
    local seen = {}

    -- playerBuffs is keyed by spell ID and by name, so every buff is reached
    -- twice; the seen table keeps the work proportional to what is on the
    -- player rather than to the size of the table.
    for _, buff in pairs(buffs) do
        if type(buff) == "table" and not seen[buff] then
            seen[buff] = true

            if buff.spellId and known[buff.spellId] then return true end

            if MatchesAnyWord(buff.name, words) then
                -- Learned once, matched by ID from here on. This is also what
                -- makes a wrong guess cheap to fix: correct the word, eat once,
                -- and the ID is recorded for good.
                Learn(buff.spellId)
                return true
            end
        end
    end

    return false
end

-- The bar is hidden from inside layout, and layout only runs out of combat, so
-- a change has to actively ask for one. Tracked rather than relayed on every
-- UNIT_AURA: that event fires constantly and a full relayout per firing would
-- be the most expensive thing the addon does.
local lastBuffState

function addon:BuffFoodStateChanged()
    local state = self:HasFoodBuff()
    if state == lastBuffState then return false end
    lastBuffState = state
    return true
end

-------------------------------------------------------------------------------
-- The bar
-------------------------------------------------------------------------------

-- Every buff food carried, best-stocked first. Not the single best item: which
-- food you want depends on what you are about to do, and nothing here knows
-- that. Ordering by count is the one honest default -- it puts the stack you
-- can afford to spend at the front.
function addon:UpdateBuffFoodBar()
    local grid = self:GetGrid(BUFF_FOOD_GRID_ID)
    if not grid then return false end

    -- Compaction can strip an empty item list out of the saved file, so this
    -- cannot assume the table survived the round trip.
    grid.items = grid.items or {}

    local previous = {}
    for i, itemData in ipairs(grid.items) do
        previous[i] = addon.GetItemIDFromData(itemData)
    end

    local items = {}

    if grid.enabled then
        local candidates, seen = {}, {}

        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    if self:IsBuffFood(itemID) then
                        local itemName = GetItemInfo(itemID)
                        if itemName then
                            candidates[#candidates + 1] = {
                                itemID = itemID,
                                name = itemName,
                                count = (GetItemCount and GetItemCount(itemID)) or 0,
                            }
                        end
                    end
                end
            end
        end

        table.sort(candidates, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return (a.name or "") < (b.name or "")
        end)

        for _, candidate in ipairs(candidates) do
            items[#items + 1] = {
                itemID = candidate.itemID,
                -- A food you have run out of is exactly the one you want to
                -- stop seeing, and the bar is already conditional.
                hideOnZero = true,
                showInCombat = false,
            }
        end
    end

    grid.items = items

    if #items ~= #previous then return true end
    for i, itemData in ipairs(items) do
        if itemData.itemID ~= previous[i] then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

local function AddAuraWord(word)
    local global = Global()
    if not global then return false end

    local list = global.buffFoodAuraWords
    if type(list) ~= "table" then
        -- Seeded from the defaults on first edit, so adding a word extends the
        -- built-in list instead of replacing it with a list of one.
        list = {}
        for _, existing in ipairs(DEFAULT_AURA_WORDS) do
            list[#list + 1] = existing
        end
        global.buffFoodAuraWords = list
    end

    word = word:lower()
    for _, existing in ipairs(list) do
        if existing == word then return false end
    end
    list[#list + 1] = word
    return true
end

-- The facts behind one verdict, written out rather than summarised. The
-- interesting case is the one where the answer is wrong, and then the inputs
-- are what matter -- the use spell above all, because the family test matches a
-- spell NAME against a known rank. A spell this build named something new is in
-- no family, so the item is not food, and nothing downstream can see it.
function addon:BuffFoodExplain(itemID)
    local name = GetItemInfo(itemID)
    self:Print((name or itemID) .. " |cff808080(" .. itemID .. ")|r")

    if not name then
        print("   |cffff5555item data not cached yet|r -- open your bags and retry")
        return
    end

    local spellName, spellID
    if GetItemSpell then spellName, spellID = GetItemSpell(itemID) end
    print("   use spell:  " .. (spellName and
          ("|cff00ff00" .. spellName .. "|r (" .. tostring(spellID) .. ")")
          or "|cffff5555none|r"))

    if spellID and addon.PLAIN_FOOD_SPELLS[spellID] then
        print("   |cff808080that is one of the plain vendor ranks|r")
    end

    if GetItemInfoInstant then
        local _, itemType, itemSubType, _, _, classID, subClassID =
            GetItemInfoInstant(itemID)
        print("   item class: " .. tostring(itemType) .. " / " ..
              tostring(itemSubType) .. " (" .. tostring(classID) .. "/" ..
              tostring(subClassID) .. ")")
    end

    print("   food, says the classifier: " ..
          (addon.IsPlayerFood(itemID) and "|cff33ff33yes|r" or
           "|cffff5555no|r -- use spell is in no known family"))
    print("   grants a buff:             " ..
          (addon.IsBuffFoodItem(itemID) and "|cff33ff33yes|r" or "|cffff5555no|r"))

    if Overrides("buffFoodIncluded")[itemID] then
        print("   |cff00ff00ticked on by hand|r")
    end
    if Overrides("buffFoodExcluded")[itemID] then
        print("   |cffff5555ticked off by hand|r")
    end

    print("   on the bar:                " ..
          (self:IsBuffFood(itemID) and "|cff33ff33yes|r" or "|cffff5555no|r")
          .. " |cff808080(mode: " .. self:BuffFoodMode() .. ")|r")
end

local function Rebuild(self)
    self:UpdateAutoBars()
    self:UpdateAllGrids()
end

function addon:BuffFoodCommand(rest)
    local action, argument = rest:match("^(%S*)%s*(.-)$")
    action = (action or ""):lower()

    if action == "buff" and argument ~= "" then
        local spellID = tonumber(argument)
        if spellID then
            Learn(spellID)
            self:Print("spell |cff00ff00" .. spellID .. "|r now counts as the food buff.")
        elseif AddAuraWord(argument) then
            self:Print("buff names matching |cff00ff00" .. argument .. "|r now count.")
        else
            self:Print("already matching that name.")
        end
        self:UpdateAllGrids()
        return

    elseif action == "add" or action == "drop" then
        local itemID = tonumber(argument)
        if not itemID then
            self:Print("usage: /chair snack bufffood " .. action .. " <itemID>")
            return
        end
        -- The same door the tick boxes use, so the two cannot mean different
        -- things about the same item.
        self:SetBuffFoodPicked(itemID, action == "add")
        self:Print((GetItemInfo(itemID) or itemID)
                   .. ((action == "add") and " added to" or " removed from")
                   .. " the buff food bar.")
        return

    elseif action == "reset" then
        local global = Global()
        if global then
            global.buffFoodAuraWords = nil
            global.buffFoodSpells = nil
            global.buffFoodIncluded = nil
            global.buffFoodExcluded = nil
        end
        Rebuild(self)
        self:Print("buff food matching reset.")
        return

    elseif action == "why" then
        local itemID = tonumber(argument)
        if not itemID then
            self:Print("usage: /chair snack bufffood why <itemID>")
            return
        end
        self:BuffFoodExplain(itemID)
        return

    elseif action == "scan" then
        -- Every food carried, with the facts behind each verdict. One command
        -- rather than one per item, because the question being asked is why a
        -- whole category went missing.
        local seen, found = {}, 0
        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and not seen[itemID] and LooksLikeFood(itemID) then
                    seen[itemID] = true
                    found = found + 1
                    self:BuffFoodExplain(itemID)
                end
            end
        end
        if found == 0 then
            self:Print("no food in your bags at all -- not even by item class, " ..
                       "which would itself be worth knowing.")
        end
        return
    end

    -- Status.
    print("|cffFFFF00=== ChairSnack buff food ===|r")
    print("Buff is up right now: "
          .. (self:HasFoodBuff() and "|cff33ff33yes|r -- bar hidden"
                                 or "|cffff5555no|r -- bar shown"))
    print("What goes on the bar: |cff808080" .. self:BuffFoodMode()
          .. "|r  -- change it in /chair snack under Buff Food")
    print("Buff name words: |cff808080" .. table.concat(AuraWords(), ", ") .. "|r")

    local ids = {}
    for spellID in pairs(KnownSpells()) do ids[#ids + 1] = spellID end
    print("Learned buff spell IDs: |cff808080"
          .. (#ids > 0 and table.concat(ids, ", ") or "none yet") .. "|r")

    -- Why the bar is or is not on screen, in the same terms layout decides it.
    -- Every one of these is a separate gate and any one of them closing hides
    -- the bar, so reporting the verdict alone would say nothing useful.
    local grid = self:GetGrid(BUFF_FOOD_GRID_ID)
    local items = (grid and grid.items) or {}

    if not grid then
        print("|cffff5555The grid is not in this profile at all.|r")
    else
        local frame = addon.frames and addon.frames[BUFF_FOOD_GRID_ID]
        print("Bar:  " .. (grid.enabled and "|cff33ff33enabled|r" or "|cffff5555disabled|r")
              .. "  frame " .. (frame and "|cff33ff33built|r" or "|cffff5555never built|r")
              .. "  rules " .. (addon.PassesVisibilityRules(grid)
                                and "|cff33ff33pass|r" or "|cffff5555block it|r")
              .. "  " .. ((frame and frame:IsShown()) and "|cff33ff33on screen|r"
                          or "|cffff5555not on screen|r"))
    end

    print("On the bar: " .. #items .. " item(s)")
    for _, itemData in ipairs(items) do
        local itemID = addon.GetItemIDFromData(itemData)
        print("   " .. (GetItemInfo(itemID) or "?") .. " |cff808080(" .. itemID .. ")|r")
    end

    -- The buffs actually on the player, so a wrong guess can be corrected
    -- against what the client really calls it rather than against a memory.
    print("Your buffs right now:")
    local seen = {}
    for _, buff in pairs(self:PlayerBuffs() or {}) do
        if type(buff) == "table" and not seen[buff] then
            seen[buff] = true
            print("   " .. tostring(buff.name) .. " |cff808080(" ..
                  tostring(buff.spellId) .. ")|r")
        end
    end

    print("|cffffd100/chair snack bufffood buff <name or spellID>|r  teach it the buff")
    print("|cffffd100/chair snack bufffood why <itemID>|r  why an item is on or off")
    print("|cffffd100/chair snack bufffood scan|r  the same, for every food you carry")
    print("|cffffd100/chair snack bufffood add|drop <itemID>|r  tick an item on or off")
    print("|cff808080(the same list, with tick boxes, is in /chair snack under Buff Food)|r")
    print("|cffffd100/chair snack bufffood reset|r")
end
