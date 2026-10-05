local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Triggers
-------------------------------------------------------------------------------
-- An aura has one or more triggers (see "Several triggers, one aura"), each
-- of a registered type: aura (a buff or debuff) or cooldown. Out of combat
-- both read plain values. In combat this client refuses aura reads and makes
-- cooldowns secret -- see "What combat hides" for what is done about that.
--
-- There is deliberately no health or power trigger. UnitHealth and UnitPower are
-- secret on this build: the number can be compared against its max but never
-- formatted, never shown and never saved, so a health trigger would be a text
-- field that cannot print its own value. It waits until there is an honest way
-- to do it rather than shipping something that throws the first time it draws.
--
-- There is no combat-log trigger either, and that is the client's doing:
-- registering COMBAT_LOG_EVENT_UNFILTERED is refused and every accessor is gone --
-- CombatLogGetCurrentEventInfo, CombatLogGetNumEntries, CombatLogGetEventInfo
-- and C_CombatLog.GetCurrentEventInfo are all missing -- so the event arrives
-- with nothing readable attached.

local Engine = {}
ns.Engine = Engine

local states = {}
Engine.states = states

-------------------------------------------------------------------------------
-- Spell lookup
-------------------------------------------------------------------------------
-- Cached because the answer cannot change within a session and these are called
-- on every sweep. Cleared on SPELLS_CHANGED, which is the one thing that can
-- make a previously unknown spell resolve.

local nameCache, iconCache = {}, {}

function Engine:ClearSpellCache()
    wipe(nameCache)
    wipe(iconCache)
end

function Engine:SpellName(spellID)
    if not spellID then return nil end
    local cached = nameCache[spellID]
    if cached ~= nil then return cached end
    local name = ns.SafeText(C_Spell.GetSpellName(spellID)) or ("spell " .. spellID)
    nameCache[spellID] = name
    return name
end

function Engine:SpellIcon(spellID)
    if not spellID then return 134400 end
    local cached = iconCache[spellID]
    if cached ~= nil then return cached end
    local icon = ns.SafeNumber(C_Spell.GetSpellTexture(spellID))
        or 134400 -- the question mark, so a missing icon is visibly a bug
    iconCache[spellID] = icon
    return icon
end

-- Accepts an ID or a name, and answers only for a spell this client admits
-- exists -- a typo that silently became an aura that never fires would be worse
-- than a refusal.
function ns.ResolveSpell(text)
    if not text or text == "" then return nil end

    local id = tonumber(text)
    if id then
        if C_Spell.DoesSpellExist and not C_Spell.DoesSpellExist(id) then return nil end
        if not C_Spell.GetSpellName(id) then return nil end
        return id
    end

    local info = C_Spell.GetSpellInfo(text)
    if type(info) == "table" then
        return ns.SafeNumber(info.spellID)
    end
    return nil
end

-- GetCursorInfo answers for a spell with four values, and the spell ID is the
-- LAST of them: "spell", spellbook index, book type, spellID. Reading the second
-- one -- as this did until it was checked against what WeakAuras reads -- takes
-- the spellbook index and resolves it as though it were an ID, which is why a
-- dragged spell used to arrive as an unrelated one while typing its name worked.
--
-- The tail is still searched rather than trusted blindly, because the payload
-- has moved between builds and an ID that this client denies exists is not an
-- ID. The order is what matters: last first.
function ns.SpellFromCursor()
    local what, a, b, c = GetCursorInfo()
    if what ~= "spell" then return nil, what end

    for _, candidate in ipairs({ c, b, a }) do
        local id = ns.SafeNumber(candidate)
        if id and ns.ResolveSpell(id) then return id, what end
    end
    return nil, what
end

-------------------------------------------------------------------------------
-- What combat hides, and what is known anyway
-------------------------------------------------------------------------------
-- The probe (2026-09-26) found this client refuses every aura read to addon
-- code in combat -- by index, by slot, by spell ID, by instance ID -- and
-- hands spell cooldowns back as secret values. Your own casts, though, still
-- arrive readable. So two things are learned out of combat and used in it:
--
--   how long a spell's buff lasts, and how long its cooldown is -- whenever
--   they are seen readable;
--
--   when you last cast each spell -- from UNIT_SPELLCAST_SUCCEEDED, which
--   still names the spell in combat.
--
-- In combat a buff you had at the pull is known to run until its recorded
-- expiry, and recasting the spell that applies it refreshes it from the cast.
-- A state worked out that way is marked assumed, so nothing mistakes it for a
-- reading. A buff that appears in combat from nothing you cast cannot be
-- known here by anyone, WeakAuras included.

local COOLDOWN_START, COOLDOWN_DURATION
local learnedAuraDuration = {}   -- spellID -> seconds
local learnedCooldown = {}       -- spellID -> seconds
local spellForName = {}          -- lower-case aura name -> spellID
local lastCast = {}              -- spellID -> GetTime() of the cast
Engine.lastCast = lastCast
Engine.learnedAuraDuration = learnedAuraDuration
Engine.learnedCooldown = learnedCooldown

do
    local casts = CreateFrame("Frame")
    pcall(casts.RegisterUnitEvent or casts.RegisterEvent, casts, "UNIT_SPELLCAST_SUCCEEDED", "player")
    casts:SetScript("OnEvent", function(_, _, unit, _, spellID)
        if unit ~= "player" then return end
        local id = ns.SafeNumber(spellID)
        if id then
            lastCast[id] = GetTime()
            ns.RequestUpdate()
        end
    end)
end

-------------------------------------------------------------------------------
-- Aura scan
-------------------------------------------------------------------------------
-- Two ways to match, because there are two kinds of thing people watch.
--
-- By ID is exact and is what a dragged or typed spell gives. The comparison is
-- on spellId -- note the lower-case d, which is what this client returns.
--
-- By name is for everything whose spell you cannot name: "Well Fed" is a dozen
-- different spell IDs depending on what you ate, and a proc you only know by
-- the text on your screen has one that changes with rank. The name on the aura
-- is the thing the player recognises, so it is a first-class way to match --
-- exactly, or as a substring for a family of them.

local MAX_AURAS = 40

-- Answers twice: whether this aura is the one, and whether it could be read at
-- all. An aura whose fields come back secret is not one that failed to match,
-- it is a question this client refused -- and the two have opposite
-- consequences for an inverted watcher.
-- "Also match": more names and IDs beside the main one, typed with commas.
local alsoCache = {}
local function AlsoList(trigger)
    local text = trigger.also
    if type(text) ~= "string" or text == "" then return nil end
    local list = alsoCache[text]
    if not list then
        list = { ids = {}, names = {} }
        for part in text:gmatch("[^,]+") do
            part = part:match("^%s*(.-)%s*$")
            local id = tonumber(part)
            if id then list.ids[id] = true elseif part ~= "" then list.names[part:lower()] = true end
        end
        alsoCache[text] = list
    end
    return list
end

local MatchesMain

local function Matches(data, trigger)
    local matched, blind = MatchesMain(data, trigger)
    if matched then return true, false end
    local also = AlsoList(trigger)
    if also then
        local spellID = ns.AuraField(data, "spellId")
        if spellID and also.ids[spellID] then return true, false end
        local name = ns.AuraField(data, "name")
        if name and also.names[name:lower()] then return true, false end
    end
    return false, blind
end

MatchesMain = function(data, trigger)
    if ns.TriggerFieldValue(trigger, "match") == "name" then
        local wanted = trigger.text
        if not wanted or wanted == "" then return false, false end

        local name = ns.AuraField(data, "name")
        if not name then return false, true end

        if ns.TriggerFieldValue(trigger, "partial") then
            return name:lower():find(wanted:lower(), 1, true) ~= nil, false
        end
        return name:lower() == wanted:lower(), false
    end

    if trigger.spellID == nil then return false, false end

    local spellID = ns.AuraField(data, "spellId")
    if not spellID then return false, true end
    if spellID == trigger.spellID then return true, false end
    -- The spell you cast and the buff it puts on you often have different
    -- IDs (Plainsrunning: 1259918 cast, 1299038 on you). So a buff wearing
    -- the chosen spell's name counts too -- which is what picking the ability
    -- from the spellbook means.
    local wanted = nameCache[trigger.spellID] or ns.Engine:SpellName(trigger.spellID)
    local name = ns.AuraField(data, "name")
    if wanted and name and not wanted:find("^spell %d+$") and name:lower() == wanted:lower() then
        return true, false
    end
    return false, false
end

local function StacksSatisfied(trigger, count)
    local wanted = ns.TriggerFieldValue(trigger, "stacks")
    if not wanted or wanted <= 0 then return true end
    local op = ns.TriggerFieldValue(trigger, "stacksOp")
    count = count or 0
    if op == "<=" then return count <= wanted end
    if op == "==" then return count == wanted end
    return count >= wanted
end

local function FindAura(unit, trigger)
    if not UnitExists(unit) then return nil end

    local filter = ns.TriggerFieldValue(trigger, "harmful") and "HARMFUL" or "HELPFUL"
    if ns.TriggerFieldValue(trigger, "mine") then filter = filter .. "|PLAYER" end

    local unreadable = false

    for index = 1, MAX_AURAS do
        local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)

        -- A refusal is not the end of the list: this client will not hand an
        -- aura to addon code in combat, and all there is to do is know that.
        if not ok then return nil, true end
        if not data then return nil, unreadable end

        local matched, blind = Matches(data, trigger)
        if blind then unreadable = true end

        if matched then
            -- The same field search the stack count shown uses, so the two agree.
            if StacksSatisfied(trigger, (ns.StackCount(data))) then
                return data
            end
            -- Same aura, wrong size: keep walking.
        end
    end

    return nil, unreadable
end

-- Every match on one unit, into `out`. Answers whether anything was refused.
local function FindAll(unit, trigger, out)
    local okE, exists = pcall(UnitExists, unit)
    if not okE or not exists then return false end

    local filter = ns.TriggerFieldValue(trigger, "harmful") and "HARMFUL" or "HELPFUL"
    if ns.TriggerFieldValue(trigger, "mine") then filter = filter .. "|PLAYER" end

    local unreadable = false
    for index = 1, MAX_AURAS do
        local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
        if not ok then return true end
        if not data then return unreadable end
        local matched, blind = Matches(data, trigger)
        if blind then unreadable = true end
        if matched and StacksSatisfied(trigger, (ns.StackCount(data))) then
            out[#out + 1] = { unit = unit, data = data, index = index }
        end
    end
    return unreadable
end

-- Units beyond the four: every member of a group, or the bosses.
local function Range(prefix, count, withPlayer)
    local out = withPlayer and { "player" } or {}
    for i = 1, count do out[#out + 1] = prefix .. i end
    return out
end
local GROUP_UNITS = {
    party = function() return Range("party", 4, true) end,
    raid  = function() return Range("raid", 40) end,
    boss  = function() return Range("boss", 5) end,
    group = function()
        local okR, raid = pcall(IsInRaid)
        if okR and raid then return Range("raid", 40) end
        return Range("party", 4, true)
    end,
}
Engine.GROUP_UNITS = GROUP_UNITS

-------------------------------------------------------------------------------
-- One trigger's evaluation
-------------------------------------------------------------------------------
-- Each trigger has its own state -- met, timer, stacks, name, icon -- and the
-- aura's state is put together from them afterwards (see Combine). Zero
-- stacks, deliberately: a buff that is not on you is one you have none of.
-- nil stays reachable and means unknown.

local function ClearState(state)
    state.met, state.start, state.duration, state.count = false, nil, nil, 0
    state.durationObject, state.assumed = nil, false
end

-- The spell a trigger stands for, when it can be named: its ID, or the ID
-- last seen wearing the name it matches.
local function TriggerSpell(trigger)
    if ns.TriggerFieldValue(trigger, "match") == "name" then
        local text = ns.SafeText(trigger.text)
        return text and spellForName[text:lower()] or nil
    end
    return trigger.spellID
end

-- In combat, with the reads refused: what can still honestly be said.
local function AssumeAura(trigger, ts, now)
    ts.assumed = true
    -- Recast since it was last known: it is back, for as long as it lasts.
    local spell = TriggerSpell(trigger)
    local cast = spell and lastCast[spell]
    local lasts = spell and learnedAuraDuration[spell]
    if cast and cast > (ts.castSeen or 0) and lasts and lasts > 0 then
        ts.castSeen = cast
        ts.met = true
        ts.start, ts.duration = cast, lasts
        return
    end
    -- Known to be up until a time that has now passed: gone.
    if ts.met and ts.start and ts.duration and now >= ts.start + ts.duration then
        ts.met = false
        ts.start, ts.duration = nil, nil
    end
end

-- In combat, with the read refused, nothing the aura shows can be vouched
-- for. Whether it is shown stays the last answer (see AssumeAura), but the
-- stack count is dropped rather than kept: a stale number reads as a true one.
-- The display draws a stale aura as unknown (see Display's MarkStale), and
-- the first read after combat puts everything back.
local function GoStale(ts)
    ts.stale = true
    ts.count, ts.countKnown = nil, false
end

local FillFromAura

-- How many matches, against the trigger's count setting. Zero wanted means
-- any at all.
local function CountSatisfied(trigger, count)
    local wanted = tonumber(trigger.matchCount) or 0
    if wanted <= 0 then return count > 0 end
    local op = ns.TriggerFieldValue(trigger, "matchOp")
    if op == "<=" then return count <= wanted end
    if op == "==" then return count == wanted end
    return count >= wanted
end

-- The long way round: a group of units, a count, or one region per match.
local function EvaluateMatches(trigger, ts, now, unit)
    local list = GROUP_UNITS[unit]
    if list then ns.watchesGroupUnits = true end
    local matches, refused = {}, false
    for _, one in ipairs(list and list() or { unit }) do
        if FindAll(one, trigger, matches) then refused = true end
    end
    if #matches == 0 and refused then
        ts.unknown = true
        AssumeAura(trigger, ts, now)
        GoStale(ts)
        return
    end
    ts.unknown, ts.assumed, ts.stale = false, false, false
    ts.castSeen = now
    ts.matchCount = #matches
    ts.met = CountSatisfied(trigger, #matches)

    local first = matches[1]
    if first then
        FillFromAura(ts, first.data, now)
        ts.met = CountSatisfied(trigger, #matches)
        ts.unit = first.unit
        local okN, name = true, Chaircraft.UnitFullName(first.unit)
        ts.unitName = okN and ns.SafeText(name) or nil
    else
        local met = ts.met
        ClearState(ts)
        ts.met = met
        ts.icon, ts.name, ts.unit, ts.unitName = nil, nil, nil, nil
    end

    -- One region per match, for a group to lay out.
    if trigger.cloneMatches and #matches > 0 then
        local clones = {}
        for i, match in ipairs(matches) do
            local data = match.data
            local okN, unitName = true, Chaircraft.UnitFullName(match.unit)
            clones[i] = { key = string.format("%s:%02d", match.unit, match.index), state = {
                show = true, name = ns.AuraField(data, "name"), icon = ns.AuraField(data, "icon"),
                stacks = ns.StackCount(data), duration = ns.AuraField(data, "duration"),
                expirationTime = ns.AuraField(data, "expires"), unit = match.unit,
                unitName = okN and ns.SafeText(unitName) or nil,
            } }
        end
        ts.cloneStates = clones
    else
        ts.cloneStates = nil
    end
end

local function EvaluateAura(trigger, ts, now)
    local unit = ns.TriggerFieldValue(trigger, "unit")
    if GROUP_UNITS[unit] or (tonumber(trigger.matchCount) or 0) > 0 or trigger.cloneMatches then
        return EvaluateMatches(trigger, ts, now, unit)
    end
    ts.matchCount, ts.cloneStates = nil, nil
    local data, unknown = FindAura(unit, trigger)

    if not data and unknown then
        -- "I could not look" is not "it is not there". An aura set to show when
        -- something is MISSING would read a refused scan as missing and light
        -- up the moment combat started. So the last answer stands -- carried
        -- forward by what is known (see AssumeAura), never guessed at.
        ts.unknown = true
        AssumeAura(trigger, ts, now)
        GoStale(ts)
        return
    end

    ts.unknown, ts.assumed, ts.stale = false, false, false
    ts.castSeen = now

    if not data then
        ClearState(ts)
        ts.icon, ts.name = nil, nil
        return
    end

    FillFromAura(ts, data, now)
end

-- A found aura's values, onto the trigger's state.
FillFromAura = function(ts, data, now)
    ts.met = true
    -- applications is the current name for the stack count; older clients
    -- fill in others. nil means the count could not be read, never zero.
    ts.count = ns.StackCount(data)
    ts.countKnown = ts.count ~= nil

    -- A duration of zero is a permanent aura, not a zero-second one.
    local duration = ns.AuraField(data, "duration")
    local expires  = ns.AuraField(data, "expires")
    if duration and duration > 0 and expires and expires > 0 then
        ts.duration = duration
        ts.start = expires - duration
    else
        ts.duration, ts.start = nil, nil
    end
    ts.durationObject = nil

    -- Learned for combat, when none of this can be read.
    local spellID = ns.AuraField(data, "spellId")
    local name = ns.AuraField(data, "name")
    if spellID then
        if duration and duration > 0 then learnedAuraDuration[spellID] = duration end
        if name then spellForName[name:lower()] = spellID end
    end

    ts.icon = ns.AuraField(data, "icon")
    ts.source = ns.AuraField(data, "source")
    ts.dispel = ns.AuraField(data, "dispel")
    ts.name = name
end

local function EvaluateCooldown(trigger, ts, now)
    local spellID = trigger.spellID
    if not spellID then
        ClearState(ts)
        return
    end

    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok then
        ts.unknown = true
        return
    end

    if type(info) ~= "table" then
        ts.unknown = false
        ClearState(ts)
        return
    end

    -- In combat the start and duration come back secret. They cannot be
    -- compared, but the client still hands out a duration object that a
    -- cooldown swipe draws correctly -- so the display stays right, and the
    -- ready-or-not answer is worked out from what is known.
    if ns.IsSecret(info.startTime) or ns.IsSecret(info.duration) then
        ts.unknown, ts.assumed = true, true
        local okD, object = pcall(C_Spell.GetSpellCooldownDuration, spellID)
        ts.durationObject = okD and object or nil
        local cast = lastCast[spellID]
        local base = learnedCooldown[spellID]
        if cast and base and cast > (ts.castSeen or 0) then
            ts.castSeen = cast
            ts.start, ts.duration = cast, base
        end
        if ts.start and ts.duration then
            ts.met = now >= ts.start + ts.duration
            if ts.met then ts.start, ts.duration = nil, nil end
        end
        ts.count = nil
        return
    end

    ts.unknown, ts.assumed = false, false
    ts.durationObject = nil
    ts.castSeen = now

    local duration = ns.ReadField(info, COOLDOWN_DURATION) or 0
    local start    = ns.ReadField(info, COOLDOWN_START) or 0

    -- The global cooldown runs on every spell at once and says nothing about
    -- whether this one is ready.
    local onRealCooldown = duration > 1.5 and start > 0

    ts.met = not onRealCooldown
    -- A spell cooldown has no stacks, which is not the same as having none.
    ts.count = nil
    if onRealCooldown then
        ts.start, ts.duration = start, duration
        learnedCooldown[spellID] = duration
    else
        ts.start, ts.duration = nil, nil
    end
end

-- The names a cooldown table has used for its two numbers.
COOLDOWN_START = { "startTime", "start" }
COOLDOWN_DURATION = { "duration" }

local EVALUATORS = {
    aura = EvaluateAura,
    cooldown = EvaluateCooldown,
}
Engine.EVALUATORS = EVALUATORS

-- What the icon should call itself and wear before any trigger has run. A
-- name-matched aura has the text the user typed and no spell at all.
function Engine:Describe(aura)
    local trigger = ns.Trigger(aura)
    local display = aura.display or {}
    local borrowed = display.iconSpell

    -- One picked out of the list is a decision, and outranks anything worked
    -- out from a spell or remembered from a sighting.
    local chosen = display.icon

    if ns.TriggerFieldValue(trigger, "match") == "name" then
        local text = ns.SafeText(trigger.text)
        local icon = chosen or (borrowed and self:SpellIcon(borrowed)) or 134400
        return aura.name or text or "unnamed", icon
    end

    -- An item trigger wears the item.
    if trigger.itemID and not trigger.spellID and ns.ItemInfo then
        local itemName, itemIcon = ns.ItemInfo(trigger.itemID)
        return aura.name or itemName or ("item " .. trigger.itemID) or "unnamed",
               chosen or (borrowed and self:SpellIcon(borrowed)) or itemIcon or 134400
    end

    local spellID = trigger.spellID
    if not spellID then
        return aura.name or "unnamed", chosen or (borrowed and self:SpellIcon(borrowed)) or 134400
    end
    return aura.name or self:SpellName(spellID) or "unnamed",
           chosen or self:SpellIcon(borrowed or spellID)
end

-------------------------------------------------------------------------------
-- Several triggers, one aura
-------------------------------------------------------------------------------
-- WeakAuras' model. Every trigger is evaluated, then:
--
--   "all"    shows when every trigger is met
--   "any"    shows when at least one is
--   "custom" asks a Lua function, given the triggers' answers as a list
--
-- and one trigger supplies what the aura shows -- its timer, stacks, name and
-- icon: the first one met (activeTriggerMode -10, WeakAuras' "first active"),
-- or a chosen one.

local FIRST_ACTIVE = -10

local function Combine(aura, state, count)
    local mode = ns.TriggerMode(aura)
    local answers = {}
    for i = 1, count do answers[i] = state.triggers[i].met and true or false end

    local met
    if mode == "any" then
        met = false
        for i = 1, count do if answers[i] then met = true break end end
    elseif mode == "custom" then
        local source = aura.triggers and aura.triggers.customTriggerLogic
        local fn, err
        if aura.untrusted then
            err = "imported code waits for your approval"
        else
            fn, err = ns.Env:Compile(source, (aura.name or aura.id) .. " activation")
        end
        if not fn then
            state.error = err
            met = false
        else
            local ok, result = ns.Env:Call(aura, fn, answers)
            if not ok then
                state.error = result
                ns.Env:Report(aura, "custom activation", result)
                met = false
            else
                state.error = nil
                met = result and true or false
            end
        end
    else
        met = count > 0
        for i = 1, count do if not answers[i] then met = false break end end
    end

    -- Which trigger speaks for the aura.
    local chosen = ns.ActiveTriggerMode(aura)
    local source
    if chosen == FIRST_ACTIVE then
        for i = 1, count do
            if answers[i] then source = state.triggers[i] break end
        end
    else
        source = state.triggers[chosen]
    end
    source = source or state.triggers[1] or {}

    state.met = met
    state.start, state.duration = source.start, source.duration
    state.durationObject = source.durationObject
    state.live = source.live
    -- The trigger that speaks, for text codes that name one of its fields.
    state.source = source
    state.count, state.countKnown = source.count, source.countKnown
    state.assumed = source.assumed and true or false

    local unknown = false
    for i = 1, count do if state.triggers[i].unknown then unknown = true end end
    state.unknown = unknown
    local stale = false
    for i = 1, count do if state.triggers[i].stale then stale = true end end
    state.stale = stale

    -- The icon the thing itself wears beats the one the spell implies, unless
    -- the user picked one. Remembered, so a Well Fed that has dropped still
    -- shows the meal rather than a question mark.
    local display = aura.display or {}
    if source.icon then
        state.lastIcon = source.icon
        if not display.icon then state.icon = source.icon end
    elseif state.lastIcon and not display.icon and not display.iconSpell then
        state.icon = state.lastIcon
    end
    if source.name then state.name = source.name end
end

-- One clone of a state-updater trigger, as a state of its own: what the
-- display draws in the clone's region. It shares the aura's triggers and
-- conditions; its name, icon, stacks and timer are the clone's.
local function CloneState(base, key, st)
    local clone = {
        id = base.id, cloneKey = key, loaded = base.loaded, met = base.met,
        shown = base.shown, props = base.props, triggers = base.triggers,
        assumed = base.assumed, stale = base.stale,
    }
    clone.name = ns.SafeText(st.name) or base.name
    clone.icon = st.icon or base.icon
    clone.count = ns.SafeNumber(st.stacks)
    clone.countKnown = clone.count ~= nil
    local duration = ns.SafeNumber(st.duration)
    local expires = ns.SafeNumber(st.expirationTime)
    if duration and duration > 0 and expires then
        clone.start, clone.duration = expires - duration, duration
    end
    clone.source = { chosenState = st, name = clone.name, icon = clone.icon,
                     count = clone.count, start = clone.start, duration = clone.duration }
    return clone
end
Engine.CloneState = CloneState

function Engine:Evaluate(aura, state)
    state.id = aura.id
    state.name, state.icon = self:Describe(aura)

    state.loaded = ns.Load:Test(aura)
    if not state.loaded then
        ClearState(state)
        state.shown = false
        state.props, state.conditionWas = nil, nil
        state.clones = nil
        return
    end

    local now = GetTime()
    local count = ns.TriggerCount(aura)
    state.triggers = state.triggers or {}
    for i = 1, count do
        local ts = state.triggers[i]
        if not ts then
            ts = { met = false, count = 0 }
            state.triggers[i] = ts
        end
        local trigger = ns.Trigger(aura, i)
        local evaluate = EVALUATORS[ns.TriggerFieldValue(trigger, "type")] or EvaluateAura
        evaluate(trigger, ts, now, aura, i)
    end
    for i = count + 1, #state.triggers do state.triggers[i] = nil end
    if ns.Custom then ns.Custom:AfterTriggers(aura, state) end

    Combine(aura, state, count)

    -- Inversion is applied once, here, so nothing downstream has to know.
    state.shown = state.met
    if ns.DisplayField(aura, "invert") then state.shown = not state.shown end

    -- A state updater with several states shown: one region each, WeakAuras'
    -- clones. The first is the aura's own state.
    local list = state.shown and state.source and state.source.cloneStates
    if type(list) == "table" and #list > 1 then
        state.clones = {}
        for i, entry in ipairs(list) do
            state.clones[i] = CloneState(state, entry.key, entry.state)
        end
    else
        state.clones = nil
    end

    -- And then the conditions, which read everything above.
    if ns.Conditions then ns.Conditions:Evaluate(aura, state, now) end
end

-------------------------------------------------------------------------------
-- Text
-------------------------------------------------------------------------------
-- What a text or a bar says. One formatter for both, because "name then time
-- left" should mean the same thing wherever it is written.
--
-- Time is worked out here rather than stored, so a bar redrawing sixty times a
-- second gets a fresh number without the engine having to sweep that often.

-- How far through its duration a state is, as a fraction that has already been
-- clamped: callers use it to set a bar and should never have to think about a
-- timer that ran past its own end.
function Engine:Progress(state, now)
    if not (state and state.start and state.duration and state.duration > 0) then
        return nil, nil
    end

    now = now or GetTime()
    local left = state.start + state.duration - now
    if left < 0 then left = 0 end
    if left > state.duration then left = state.duration end

    return left / state.duration, left
end

-- Engine:FormatText lives in Text.lua, with WeakAuras' text codes.

-------------------------------------------------------------------------------
-- Sweep
-------------------------------------------------------------------------------

function Engine:StateFor(id)
    return states[id]
end

function Engine:Rebuild()
    wipe(states)
    self:ClearSpellCache()
    -- An edited aura is set up again, so its on-init code runs again, as in
    -- WeakAuras.
    if ns.Actions then ns.Actions:Reset() end
    if ns.Custom then ns.Custom:Rebuild() end
    ns.Display:Rebuild()
    -- So an aura added from a slash command shows up in an open window, and the
    -- two configuration surfaces cannot disagree about what exists.
    if ns.Config then ns.Config:RefreshIfShown() end
end

function Engine:UpdateAll()
    -- Once per sweep, not once per aura: twenty auras asking whether you are in
    -- a raid is one question, asked here.
    ns.Load:Refresh()

    local auras = ns.GetAuras()
    local live = {}

    for _, aura in ipairs(auras) do
        ns.NormalizeTriggers(aura)
        if not ns.IsGroup(aura) then
            local state = states[aura.id]
            if not state then
                state = {}
                states[aura.id] = state
            end
            self:Evaluate(aura, state)
            live[aura.id] = true
        end
    end

    -- States left over from an aura that was just removed would otherwise be
    -- drawn by a region that no longer has one.
    for id in pairs(states) do
        if not live[id] then states[id] = nil end
    end

    ns.Display:Refresh(states)
end
