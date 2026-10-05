local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- The built-in trigger types
-------------------------------------------------------------------------------
-- WeakAuras' generic triggers (its Prototypes.lua), the ones this client can
-- answer. Each type says what it is called, which settings it has, and how it
-- is evaluated; the editor builds its settings from the list, and the engine
-- calls Evaluate(trigger, ts, now, aura, index) every sweep.
--
-- What the probe (2026-09-26) settled:
--   readable anywhere   usable, known, range, item cooldowns and counts,
--                       equipment, weapon enchants, form, threat, your own
--                       casts, XP, money, status, zone
--   display only        health and power -- secret even out of combat, so
--                       the bar is handed the value to draw and nothing here
--                       ever reads it
--   not on this client  the combat log, talents and specs
--
-- Settings are { kind, key, label, tip, values, min, max }, kinds the editor
-- already has: spell, item, text, choice, check, slider. Where WeakAuras has a
-- name for a field, it is used.

local Types = {}
ns.TriggerTypes = Types
-- The order the picker shows them in, after Aura, Cooldown and Custom.
local ORDER = {}
ns.TriggerTypeOrder = ORDER

local function Register(key, def)
    def.key = key
    Types[key] = def
    ORDER[#ORDER + 1] = key
    ns.Engine.EVALUATORS[key] = function(trigger, ts, now, aura, index)
        ts.unknown, ts.assumed = false, false
        local ok, err = pcall(def.Evaluate, trigger, ts, now, aura, index)
        if not ok then
            ts.error = err
            ts.met = false
        end
    end
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Everything the call returned, or nothing if it failed. (It used to hand
-- back the first six, which cut GetItemInfo's icon and the off hand's enchant
-- off the end.)
local function Results(ok, ...)
    if ok then return ... end
    return nil
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    return Results(pcall(fn, ...))
end

-- A yes/no from Try: true or false, or nil with the trigger marked unknown
-- when the client keeps the answer secret.
local function Yes(ts, answer)
    if ns.IsSecret(answer) then
        ts.unknown = true
        return nil
    end
    return answer and true or false
end

local function Num(v) return ns.SafeNumber(v) end

local OPS = {
    { text = ">=", value = ">=" }, { text = "<=", value = "<=" }, { text = "=", value = "==" },
    { text = ">", value = ">" }, { text = "<", value = "<" }, { text = "not", value = "~=" },
}
local function Compare(value, op, target)
    if value == nil or target == nil then return false end
    if op == "<=" then return value <= target end
    if op == "==" then return value == target end
    if op == ">" then return value > target end
    if op == "<" then return value < target end
    if op == "~=" then return value ~= target end
    return value >= target
end
ns.CompareOp = Compare

local function Field(trigger, key, default)
    local v = trigger[key]
    if v == nil then return default end
    return v
end

-- The name and icon a spell-based trigger shows.
local function WearSpell(ts, spellID)
    if not spellID then return end
    ts.name = ns.Engine:SpellName(spellID)
    ts.icon = ns.Engine:SpellIcon(spellID)
end

local function ItemInfo(itemID)
    if not itemID then return nil end
    local item = _G.C_Item
    local name = Try(item and item.GetItemNameByID, itemID)
    local icon = Try(item and item.GetItemIconByID, itemID)
    if not name then
        local n, _, _, _, _, _, _, _, _, tex = Try(_G.GetItemInfo, itemID)
        name, icon = name or n, icon or tex
    end
    return ns.SafeText(name), Num(icon) or icon
end
ns.ItemInfo = ItemInfo

local function WearItem(ts, itemID)
    local name, icon = ItemInfo(itemID)
    ts.name = name or ts.name
    ts.icon = icon or ts.icon
end

-- A cooldown from start and duration, the global cooldown counted as ready.
local function Cooldown(ts, start, duration)
    start, duration = Num(start), Num(duration)
    if start == nil or duration == nil then
        ts.unknown = true
        return nil
    end
    local on = duration > 1.5 and start > 0
    if on then ts.start, ts.duration = start, duration else ts.start, ts.duration = nil, nil end
    return on
end

local UNITS = {
    { text = "Player", value = "player" }, { text = "Target", value = "target" },
    { text = "Focus", value = "focus" }, { text = "Pet", value = "pet" },
}

local SPELL = { kind = "spell", key = "spellID", label = "Spell" }

-- Whether `unit` is in range of a spell: true, false, or nil with the trigger
-- marked unknown when the answer is secret. No target, or one the spell cannot
-- be cast at, answers nil from the client, and that is not in range.
local function InRange(ts, id, unit)
    local spell = _G.C_Spell
    local answer = Try(spell and spell.IsSpellInRange, id, unit)
    if ns.IsSecret(answer) then ts.unknown = true return nil end
    if answer == nil then answer = Try(_G.IsSpellInRange, ns.Engine:SpellName(id), unit) end
    if ns.IsSecret(answer) then ts.unknown = true return nil end
    return answer == true or answer == 1
end
local ITEM = { kind = "item", key = "itemID", label = "Item",
               tip = "An item name or numeric ID. Drag one onto the box too." }

-------------------------------------------------------------------------------
-- Spells
-------------------------------------------------------------------------------

Register("usable", {
    text = "Usable",
    tip = "WeakAuras' Action Usable: the spell can be cast right now -- known,"
       .. " enough mana or rage, and off cooldown.",
    fields = {
        SPELL,
        { kind = "check", key = "inRange", label = "and the target is in range" },
    },
    Evaluate = function(trigger, ts)
        local id = trigger.spellID
        if not id then ts.met = false return end
        WearSpell(ts, id)
        local spell = _G.C_Spell
        local usable
        if spell and spell.IsSpellUsable then usable = Try(spell.IsSpellUsable, id)
        else usable = Try(_G.IsUsableSpell, id) end
        if ns.IsSecret(usable) then ts.unknown = true return end
        local met = usable and true or false
        if met then
            -- Usable is also "off cooldown" in WeakAuras' sense.
            local info = Try(spell and spell.GetSpellCooldown, id)
            if type(info) == "table" and not ns.IsSecret(info.duration) then
                if Cooldown(ts, info.startTime, info.duration) then met = false end
            end
        end
        if met and trigger.inRange then
            local inRange = InRange(ts, id, "target")
            if inRange == nil then return end
            if not inRange then met = false end
        end
        ts.met = met
    end,
})

Register("known", {
    text = "Spell known",
    tip = "You know the spell -- learned, and not just seen.",
    fields = { SPELL },
    Evaluate = function(trigger, ts)
        local id = trigger.spellID
        if not id then ts.met = false return end
        WearSpell(ts, id)
        local known = Try(_G.IsPlayerSpell, id) or Try(_G.IsSpellKnown, id)
        if not known and _G.C_SpellBook then known = Try(_G.C_SpellBook.IsSpellKnown, id) end
        ts.met = known and true or false
    end,
})

Register("range", {
    text = "In range",
    tip = "The unit is within the spell's range. Nothing to cast at is not in range.",
    fields = { SPELL, { kind = "choice", key = "unit", label = "Unit", values = UNITS, default = "target" } },
    Evaluate = function(trigger, ts)
        local id = trigger.spellID
        if not id then ts.met = false return end
        WearSpell(ts, id)
        local unit = Field(trigger, "unit", "target")
        if unit == "player" then unit = "target" end
        local inRange = InRange(ts, id, unit)
        if inRange == nil then return end
        ts.met = inRange
    end,
})

Register("target", {
    text = "Target",
    tip = "You have a target, and it is everything ticked here. Give a spell to"
       .. " also need the target in its range: Charge, say, for a reminder that"
       .. " shows only when you can charge.",
    fields = {
        { kind = "check", key = "attackable", label = "I can attack it" },
        { kind = "check", key = "alive", label = "it is alive" },
        { kind = "check", key = "player", label = "it is a player" },
        { kind = "spell", key = "spellID", label = "In range of",
          tip = "Optional. Leave empty to skip the range check." },
    },
    -- Each test answers yes, no, or nil when the client keeps it secret; a
    -- secret answer leaves the last state standing, as everywhere else.
    Evaluate = function(trigger, ts)
        local function Decide()
            local exists = Yes(ts, Try(_G.UnitExists, "target"))
            if exists ~= true then return exists end
            if trigger.attackable then
                local yes = Yes(ts, Try(_G.UnitCanAttack, "player", "target"))
                if yes ~= true then return yes end
            end
            if trigger.alive then
                local dead = Yes(ts, Try(_G.UnitIsDeadOrGhost, "target"))
                if dead ~= false then return dead == nil and nil or false end
            end
            if trigger.player then
                local yes = Yes(ts, Try(_G.UnitIsPlayer, "target"))
                if yes ~= true then return yes end
            end
            local id = trigger.spellID
            if id then
                WearSpell(ts, id)
                return InRange(ts, id, "target")
            end
            return true
        end
        local met = Decide()
        if met ~= nil then ts.met = met end
    end,
})

Register("charges", {
    text = "Charges",
    tip = "How many charges a spell has. Few spells have any on this client.",
    fields = {
        SPELL,
        { kind = "choice", key = "chargesOp", label = "Charges", values = OPS },
        { kind = "slider", key = "charges", label = "Count", min = 0, max = 10, default = 1 },
    },
    Evaluate = function(trigger, ts)
        local id = trigger.spellID
        if not id then ts.met = false return end
        WearSpell(ts, id)
        local spell = _G.C_Spell
        local info = Try(spell and spell.GetSpellCharges, id)
        local current
        if type(info) == "table" then
            -- Read the way every aura value is (see ns.ReadField).
            current = ns.ReadField(info, { "currentCharges", "charges" })
            local most = ns.ReadField(info, { "maxCharges", "max" })
            if current and most and current < most then
                Cooldown(ts, ns.ReadField(info, { "cooldownStartTime", "startTime" }),
                    ns.ReadField(info, { "cooldownDuration", "duration" }))
            else
                ts.start, ts.duration = nil, nil
            end
        end
        if current == nil then ts.unknown = true return end
        ts.count, ts.countKnown = current, true
        ts.met = Compare(current, Field(trigger, "chargesOp", ">="), Field(trigger, "charges", 1))
    end,
})

Register("cast", {
    text = "Your cast",
    tip = "WeakAuras' Spell Cast Succeeded, for your own casts -- the only ones"
       .. " this client names in combat. Shows for a while after you cast it.",
    fields = {
        { kind = "spell", key = "spellID", label = "Spell (empty: any)" },
        { kind = "slider", key = "duration", label = "Show for (seconds)", min = 1, max = 60, default = 3 },
    },
    Evaluate = function(trigger, ts, now)
        local lasts = Field(trigger, "duration", 3)
        local when, which
        if trigger.spellID then
            when, which = ns.Engine.lastCast[trigger.spellID], trigger.spellID
        else
            for id, at in pairs(ns.Engine.lastCast) do
                if not when or at > when then when, which = at, id end
            end
        end
        if when and now - when < lasts then
            ts.met = true
            ts.start, ts.duration = when, lasts
            WearSpell(ts, which)
        else
            ts.met = false
            ts.start, ts.duration = nil, nil
        end
    end,
})

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------

Register("itemcooldown", {
    text = "Item cooldown",
    tip = "Shows while the item is ready, as a cooldown trigger does; invert it on"
       .. " the Display tab to show it while cooling down.",
    fields = { ITEM },
    Evaluate = function(trigger, ts)
        local id = trigger.itemID
        if not id then ts.met = false return end
        WearItem(ts, id)
        local item = _G.C_Item
        local start, duration
        if item and item.GetItemCooldown then start, duration = Try(item.GetItemCooldown, id)
        else start, duration = Try(_G.GetItemCooldown, id) end
        local on = Cooldown(ts, start, duration)
        if on == nil then return end
        ts.met = not on
    end,
})

local SLOTS = {
    { text = "Trinket 1", value = 13 }, { text = "Trinket 2", value = 14 },
    { text = "Main hand", value = 16 }, { text = "Off hand", value = 17 },
    { text = "Ranged", value = 18 }, { text = "Head", value = 1 },
    { text = "Neck", value = 2 }, { text = "Hands", value = 10 },
    { text = "Waist", value = 6 }, { text = "Feet", value = 8 },
}

Register("slotcooldown", {
    text = "Slot cooldown",
    tip = "The cooldown of whatever is worn in a slot -- a trinket, usually.",
    fields = { { kind = "choice", key = "slot", label = "Slot", values = SLOTS, dropdown = true } },
    Evaluate = function(trigger, ts)
        local slot = Field(trigger, "slot", 13)
        local itemID = Num(Try(_G.GetInventoryItemID, "player", slot))
        if not itemID then ts.met = false ts.start, ts.duration = nil, nil return end
        WearItem(ts, itemID)
        local start, duration = Try(_G.GetInventoryItemCooldown, "player", slot)
        local on = Cooldown(ts, start, duration)
        if on == nil then return end
        ts.met = not on
    end,
})

Register("itemcount", {
    text = "Item count",
    tip = "How many you carry.",
    fields = {
        ITEM,
        { kind = "choice", key = "countOp", label = "Count", values = OPS },
        { kind = "slider", key = "count", label = "Number", min = 0, max = 200, default = 1 },
        { kind = "check", key = "includeBank", label = "count the bank too" },
    },
    Evaluate = function(trigger, ts)
        local id = trigger.itemID
        if not id then ts.met = false return end
        WearItem(ts, id)
        local item = _G.C_Item
        local n
        if item and item.GetItemCount then n = Try(item.GetItemCount, id, trigger.includeBank, true)
        else n = Try(_G.GetItemCount, id, trigger.includeBank, true) end
        n = Num(n)
        if n == nil then ts.unknown = true return end
        ts.count, ts.countKnown = n, true
        ts.met = Compare(n, Field(trigger, "countOp", ">="), Field(trigger, "count", 1))
    end,
})

Register("equipped", {
    text = "Item equipped",
    fields = { ITEM },
    Evaluate = function(trigger, ts)
        local id = trigger.itemID
        if not id then ts.met = false return end
        WearItem(ts, id)
        local item = _G.C_Item
        local worn = Try(item and item.IsEquippedItem, id)
        if worn == nil then worn = Try(_G.IsEquippedItem, id) end
        if worn == nil then
            worn = false
            for slot = 1, 19 do
                if Num(Try(_G.GetInventoryItemID, "player", slot)) == id then worn = true break end
            end
        end
        ts.met = worn and true or false
    end,
})

local enchantLongest = {}   -- enchant ID -> the most time left ever seen, as its duration
Register("enchant", {
    text = "Weapon enchant",
    tip = "A temporary enchant on a weapon: a poison, an oil, a sharpening stone,"
       .. " a shaman's weapon imbue.",
    fields = { { kind = "choice", key = "hand", label = "Weapon",
                 values = { { text = "Main hand", value = "main" }, { text = "Off hand", value = "off" } } } },
    Evaluate = function(trigger, ts, now)
        local hasMain, mainMs, mainCharges, mainID, hasOff, offMs, offCharges, offID = Try(_G.GetWeaponEnchantInfo)
        local off = Field(trigger, "hand", "main") == "off"
        local has, ms, charges, id
        if off then has, ms, charges, id = hasOff, offMs, offCharges, offID
        else has, ms, charges, id = hasMain, mainMs, mainCharges, mainID end
        ts.met = has and true or false
        local slot = off and 17 or 16
        local itemID = Num(Try(_G.GetInventoryItemID, "player", slot))
        if itemID then WearItem(ts, itemID) end
        ms = Num(ms)
        if ts.met and ms and ms > 0 then
            local left = ms / 1000
            local key = Num(id) or 0
            enchantLongest[key] = math.max(enchantLongest[key] or 0, left)
            ts.duration = enchantLongest[key]
            ts.start = now + left - ts.duration
        else
            ts.start, ts.duration = nil, nil
        end
        charges = Num(charges)
        ts.count, ts.countKnown = charges and charges > 0 and charges or nil, charges ~= nil
    end,
})

-------------------------------------------------------------------------------
-- You
-------------------------------------------------------------------------------

Register("form", {
    text = "Stance / form",
    tip = "Your stance, form, aura or presence. Pick the spell that puts you in it"
       .. " (Bear Form, Defensive Stance), or leave it empty for 'no form at all'.",
    fields = { { kind = "spell", key = "spellID", label = "Form's spell (empty: none)" } },
    Evaluate = function(trigger, ts)
        local form = Num(Try(_G.GetShapeshiftForm)) or 0
        local current
        if form > 0 then
            local icon, _, _, spellID = Try(_G.GetShapeshiftFormInfo, form)
            current = Num(spellID)
            ts.icon = icon
        end
        if trigger.spellID then
            ts.met = current == trigger.spellID
            WearSpell(ts, trigger.spellID)
        else
            ts.met = form == 0
        end
    end,
})

Register("threat", {
    text = "Threat",
    tip = "Your threat on a unit, as a percentage of what it takes to pull it.",
    fields = {
        { kind = "choice", key = "unit", label = "On", values = {
            { text = "Target", value = "target" }, { text = "Focus", value = "focus" } } },
        { kind = "choice", key = "threatOp", label = "Threat", values = OPS },
        { kind = "slider", key = "threat", label = "Percent", min = 0, max = 130, default = 80 },
        { kind = "check", key = "tanking", label = "only while I am tanking it" },
    },
    Evaluate = function(trigger, ts)
        local unit = Field(trigger, "unit", "target")
        if not Yes(ts, Try(_G.UnitExists, unit)) then ts.met = false return end
        local tanking, _, pct = Try(_G.UnitDetailedThreatSituation, "player", unit)
        if ns.IsSecret(pct) then ts.unknown = true ts.count = nil return end
        tanking = Yes(ts, tanking)
        pct = Num(pct)
        if pct == nil then ts.met = false ts.count = nil return end
        ts.count, ts.countKnown = math.floor(pct + 0.5), true
        local met = Compare(pct, Field(trigger, "threatOp", ">="), Field(trigger, "threat", 80))
        if trigger.tanking and not tanking then met = false end
        ts.met = met
    end,
})

Register("xp", {
    text = "Experience",
    tip = "Your XP through the level, in per cent; stacks show the level.",
    fields = {
        { kind = "choice", key = "xpOp", label = "XP", values = OPS },
        { kind = "slider", key = "xp", label = "Per cent", min = 0, max = 100 },
        { kind = "check", key = "rested", label = "only while rested" },
    },
    Evaluate = function(trigger, ts)
        local xp, max = Num(Try(_G.UnitXP, "player")), Num(Try(_G.UnitXPMax, "player"))
        if not xp or not max or max <= 0 then ts.met = false return end
        local pct = xp / max * 100
        ts.count, ts.countKnown = Num(Try(_G.UnitLevel, "player")), true
        local met = Compare(pct, Field(trigger, "xpOp", ">="), Field(trigger, "xp", 0))
        if trigger.rested and not ((Num(Try(_G.GetXPExhaustion)) or 0) > 0) then met = false end
        ts.met = met
        ts.name = string.format("%.1f%%", pct)
    end,
})

-- A faction's standing: the one you watch, or one named. Stacks carry the
-- standing (1 hated .. 8 exalted), %n the faction, the bar its progress.
local STANDINGS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
local function Faction(wanted)
    local function Pack(name, standing, low, high, value)
        return { name = ns.SafeText(name), standing = Num(standing), low = Num(low),
                 high = Num(high), value = Num(value) }
    end
    if not wanted or wanted == "" then
        local reputation = _G.C_Reputation
        if reputation and type(reputation.GetWatchedFactionData) == "function" then
            local data = Try(reputation.GetWatchedFactionData)
            if type(data) == "table" then
                return Pack(data.name, data.reaction, data.currentReactionThreshold,
                            data.nextReactionThreshold, data.currentStanding)
            end
        end
        local name, standing, low, high, value = Try(_G.GetWatchedFactionInfo)
        if name then return Pack(name, standing, low, high, value) end
        return nil
    end
    wanted = wanted:lower()
    local count = Num(Try(_G.GetNumFactions)) or 0
    for i = 1, count do
        local name, _, standing, low, high, value = Try(_G.GetFactionInfo, i)
        if type(name) == "string" and name:lower() == wanted then
            return Pack(name, standing, low, high, value)
        end
    end
    return nil
end
ns.ReputationFaction = Faction

Register("reputation", {
    text = "Reputation",
    tip = "A faction's standing: the one you watch, or one named. Stacks show the standing "
       .. "(1 hated to 8 exalted), %n the faction, and a bar fills through the standing.",
    fields = {
        { kind = "text", key = "faction", label = "Faction (empty: the one you watch)" },
        { kind = "choice", key = "standingOp", label = "Standing", values = OPS },
        { kind = "choice", key = "standing", label = "Is", dropdown = true, values = {
            { text = "Hated", value = 1 }, { text = "Hostile", value = 2 }, { text = "Unfriendly", value = 3 },
            { text = "Neutral", value = 4 }, { text = "Friendly", value = 5 }, { text = "Honored", value = 6 },
            { text = "Revered", value = 7 }, { text = "Exalted", value = 8 } }, default = 1 },
    },
    Evaluate = function(trigger, ts)
        local faction = Faction(trigger.faction)
        if not faction or not faction.standing then
            ts.met = false
            ts.name, ts.live = nil, nil
            return
        end
        ts.count, ts.countKnown = faction.standing, true
        ts.name = faction.name
        ts.standingName = STANDINGS[faction.standing]
        ts.met = Compare(faction.standing, Field(trigger, "standingOp", ">="), Field(trigger, "standing", 1))
        -- Progress through the standing, drawn by a bar like health.
        if faction.low and faction.high and faction.value and faction.high > faction.low then
            ts.reputation = faction.value - faction.low
            ts.reputationMax = faction.high - faction.low
            ts.live = { kind = "value", value = ts.reputation, max = ts.reputationMax }
        else
            ts.live = nil
        end
    end,
})

Register("money", {
    text = "Money",
    tip = "The gold you carry.",
    fields = {
        { kind = "choice", key = "moneyOp", label = "Gold", values = OPS },
        { kind = "slider", key = "gold", label = "Gold", min = 0, max = 5000 },
    },
    Evaluate = function(trigger, ts)
        local copper = Num(Try(_G.GetMoney))
        if not copper then ts.unknown = true return end
        local gold = math.floor(copper / 10000)
        ts.count, ts.countKnown = gold, true
        ts.met = Compare(gold, Field(trigger, "moneyOp", ">="), Field(trigger, "gold", 0))
    end,
})

local STATUS = {
    { text = "In combat", value = "combat" }, { text = "Mounted", value = "mounted" },
    { text = "Resting", value = "resting" }, { text = "Stealthed", value = "stealthed" },
    { text = "Swimming", value = "swimming" }, { text = "Flying", value = "flying" },
    { text = "In a group", value = "group" }, { text = "In a raid", value = "raid" },
    { text = "Alive", value = "alive" }, { text = "Has target", value = "target" },
    { text = "Hostile target", value = "hostile" }, { text = "PvP flagged", value = "pvp" },
    { text = "Indoors", value = "indoors" }, { text = "On a taxi", value = "taxi" },
}
local STATUS_TEST = {
    combat    = function() return Try(_G.UnitAffectingCombat, "player") end,
    mounted   = function() return Try(_G.IsMounted) end,
    resting   = function() return Try(_G.IsResting) end,
    stealthed = function() return Try(_G.IsStealthed) end,
    swimming  = function() return Try(_G.IsSwimming) end,
    flying    = function() return Try(_G.IsFlying) end,
    group     = function() return Try(_G.IsInGroup) end,
    raid      = function() return Try(_G.IsInRaid) end,
    alive     = function()
        local dead = Try(_G.UnitIsDeadOrGhost, "player")
        if ns.IsSecret(dead) then return dead end   -- for the trigger to call unknown
        return not dead
    end,
    target    = function() return Try(_G.UnitExists, "target") end,
    hostile   = function() return Try(_G.UnitCanAttack, "player", "target") end,
    pvp       = function() return Try(_G.UnitIsPVP, "player") end,
    indoors   = function() return Try(_G.IsIndoors) end,
    taxi      = function() return Try(_G.UnitOnTaxi, "player") end,
}

Register("status", {
    text = "Player status",
    tip = "WeakAuras' Conditions trigger: one thing about you, true or not.",
    fields = {
        { kind = "choice", key = "status", label = "When I am", values = STATUS, dropdown = true },
        { kind = "check", key = "negate", label = "not" },
    },
    Evaluate = function(trigger, ts)
        local test = STATUS_TEST[Field(trigger, "status", "combat")]
        local yes = Yes(ts, test and test())
        if yes == nil then return end
        if trigger.negate then yes = not yes end
        ts.met = yes
    end,
})

Register("zone", {
    text = "Zone",
    tip = "Where you are: the zone or subzone name contains this text.",
    fields = { { kind = "text", key = "zoneName", label = "Zone or subzone" } },
    Evaluate = function(trigger, ts)
        local wanted = ns.SafeText(trigger.zoneName)
        if not wanted then ts.met = false return end
        wanted = wanted:lower()
        local found = false
        for _, fn in ipairs({ _G.GetRealZoneText, _G.GetSubZoneText, _G.GetMinimapZoneText }) do
            local text = ns.SafeText(Try(fn))
            if text and text:lower():find(wanted, 1, true) then found = true break end
        end
        ts.met = found
    end,
})

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
-- Heard as they happen and held for a while, as WeakAuras' event triggers are.

local heard = { chat = {}, ready = nil }
local CHAT_EVENTS = {
    CHAT_MSG_SAY = "say", CHAT_MSG_YELL = "yell", CHAT_MSG_PARTY = "party",
    CHAT_MSG_PARTY_LEADER = "party", CHAT_MSG_RAID = "raid", CHAT_MSG_RAID_LEADER = "raid",
    CHAT_MSG_RAID_WARNING = "raid", CHAT_MSG_GUILD = "guild", CHAT_MSG_WHISPER = "whisper",
    CHAT_MSG_MONSTER_YELL = "npc", CHAT_MSG_MONSTER_SAY = "npc", CHAT_MSG_MONSTER_EMOTE = "npc",
    CHAT_MSG_RAID_BOSS_EMOTE = "npc",
}
do
    local listen = CreateFrame("Frame")
    for event in pairs(CHAT_EVENTS) do pcall(listen.RegisterEvent, listen, event) end
    pcall(listen.RegisterEvent, listen, "READY_CHECK")
    pcall(listen.RegisterEvent, listen, "READY_CHECK_FINISHED")
    listen:SetScript("OnEvent", function(_, event, message, sender)
        if event == "READY_CHECK" then
            heard.ready = GetTime()
        elseif event == "READY_CHECK_FINISHED" then
            heard.ready = nil
        else
            local text = ns.SafeText(message)
            if text then
                table.insert(heard.chat, { at = GetTime(), channel = CHAT_EVENTS[event],
                    text = text, sender = ns.SafeText(sender) })
                if #heard.chat > 30 then table.remove(heard.chat, 1) end
            end
        end
        ns.RequestUpdate()
    end)
end
ns.Heard = heard

Register("chat", {
    text = "Chat message",
    tip = "A message containing this text was said. Messages this client hides from"
       .. " addons -- some are secret in instances -- cannot be heard.",
    fields = {
        { kind = "choice", key = "chatChannel", label = "Where", dropdown = true, values = {
            { text = "Anywhere", value = "any" }, { text = "Say", value = "say" },
            { text = "Yell", value = "yell" }, { text = "Party", value = "party" },
            { text = "Raid", value = "raid" }, { text = "Guild", value = "guild" },
            { text = "Whisper", value = "whisper" }, { text = "NPC / boss", value = "npc" } } },
        { kind = "text", key = "message", label = "Message contains" },
        { kind = "slider", key = "duration", label = "Show for (seconds)", min = 1, max = 60, default = 5 },
    },
    Evaluate = function(trigger, ts, now)
        local wanted = (ns.SafeText(trigger.message) or ""):lower()
        local channel = Field(trigger, "chatChannel", "any")
        local lasts = Field(trigger, "duration", 5)
        ts.met = false
        for i = #heard.chat, 1, -1 do
            local line = heard.chat[i]
            if now - line.at >= lasts then break end
            if (channel == "any" or line.channel == channel)
                and (wanted == "" or line.text:lower():find(wanted, 1, true)) then
                ts.met = true
                ts.start, ts.duration = line.at, lasts
                ts.name = line.sender or line.text
                return
            end
        end
        ts.start, ts.duration = nil, nil
    end,
})

Register("readycheck", {
    text = "Ready check",
    tip = "A ready check is up.",
    fields = {},
    Evaluate = function(trigger, ts, now)
        local at = heard.ready
        if at and now - at < 35 then
            ts.met = true
            ts.start, ts.duration = at, 35
        else
            ts.met = false
            ts.start, ts.duration = nil, nil
        end
    end,
})

-------------------------------------------------------------------------------
-- Health and power: display only
-------------------------------------------------------------------------------
-- Both are secret on this client, in and out of combat. They can still be
-- drawn: a status bar takes a secret value and fills to it. So the trigger is
-- met while the unit exists, and hands the display a live value to draw --
-- it cannot be compared, so there is no "below 30%" here, and a condition or
-- custom code cannot read it either.

Register("health", {
    text = "Health (bar)",
    tip = "Draws the unit's health on a bar aura. This client keeps health secret"
       .. " from addons, so it can be drawn but not compared.",
    fields = { { kind = "choice", key = "unit", label = "Unit", values = UNITS } },
    Evaluate = function(trigger, ts)
        local unit = Field(trigger, "unit", "player")
        ts.met = Yes(ts, Try(_G.UnitExists, unit)) or false
        ts.live = ts.met and { kind = "health", unit = unit } or nil
        ts.name = ns.SafeText(Chaircraft.UnitFullName(unit)) or ts.name
    end,
})

Register("power", {
    text = "Power (bar)",
    tip = "Draws the unit's mana, rage or energy on a bar aura. Secret on this client,"
       .. " so drawn but not compared.",
    fields = { { kind = "choice", key = "unit", label = "Unit", values = UNITS } },
    Evaluate = function(trigger, ts)
        local unit = Field(trigger, "unit", "player")
        ts.met = Yes(ts, Try(_G.UnitExists, unit)) or false
        ts.live = ts.met and { kind = "power", unit = unit } or nil
        ts.name = ns.SafeText(Chaircraft.UnitFullName(unit)) or ts.name
    end,
})

-- Draw a live value onto a status bar. Nothing here reads it.
function ns.DrawLive(bar, live)
    if not (bar and live) then return false end
    local current, maximum
    if live.kind == "value" then
        -- A readable number and its most (reputation), drawn the same way.
        current, maximum = live.value, live.max
    elseif live.kind == "health" then
        current, maximum = Try(_G.UnitHealth, live.unit), Try(_G.UnitHealthMax, live.unit)
    else
        current, maximum = Try(_G.UnitPower, live.unit), Try(_G.UnitPowerMax, live.unit)
    end
    -- (asked without comparing a secret: these are what the bar is here to draw)
    local function Missing(value) return not ns.IsSecret(value) and value == nil end
    if Missing(current) or Missing(maximum) then return false end
    if not pcall(bar.SetMinMaxValues, bar, 0, maximum) then return false end
    local ok = pcall(bar.SetValue, bar, current)
    return ok
end
