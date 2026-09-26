local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Triggers
-------------------------------------------------------------------------------
-- Two kinds, and both read APIs the probe confirmed return plain values:
-- C_UnitAuras.GetAuraDataByIndex hands back every field readable, and
-- C_Spell.GetSpellCooldown returns a plain table.
--
-- There is deliberately no health or power trigger. UnitHealth and UnitPower are
-- secret on this build: the number can be compared against its max but never
-- formatted, never shown and never saved, so a health trigger would be a text
-- field that cannot print its own value. It waits until there is an honest way
-- to do it rather than shipping something that throws the first time it draws.
--
-- There is no combat-log trigger either, and that is the client's doing:
-- COMBAT_LOG_EVENT_UNFILTERED registers fine but every accessor is gone --
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
-- Aura scan
-------------------------------------------------------------------------------
-- Two ways to match, because there are two kinds of thing people watch.
--
-- By ID is exact and is what a dragged or typed spell gives. GetAuraDataBySpellName
-- exists but two spells can share a name across ranks, so the comparison is on
-- spellId -- note the lower-case d, which is what this client actually returns.
--
-- By name is for everything whose spell you cannot name: "Well Fed" is a dozen
-- different spell IDs depending on what you ate, food a private server added has
-- no ID anyone has written down, and a proc you only know by the text on your
-- screen has one that changes with rank. The name on the aura is the thing the
-- player actually recognises, so it is a first-class way to match rather than a
-- workaround -- exactly, or as a substring for a family of them.

local MAX_AURAS = 40

-- Answers twice: whether this aura is the one, and whether it could be read at
-- all. The second matters as much as the first -- an aura whose fields come
-- back secret is not an aura that failed to match, it is a question this client
-- refused, and the two have opposite consequences for an inverted watcher.
local function Matches(data, trigger)
    if ns.TriggerFieldValue(trigger, "match") == "name" then
        local wanted = trigger.text
        if not wanted or wanted == "" then return false, false end

        local name = ns.SafeText(data.name)
        if not name then return false, true end

        if ns.TriggerFieldValue(trigger, "partial") then
            return name:lower():find(wanted:lower(), 1, true) ~= nil, false
        end
        return name:lower() == wanted:lower(), false
    end

    if trigger.spellID == nil then return false, false end

    local spellID = ns.SafeNumber(data.spellId)
    if not spellID then return false, true end
    return spellID == trigger.spellID, false
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

        -- A refusal is not the end of the list. This client will not hand an
        -- aura to tainted code once it has decided the aura is secret, which it
        -- does in combat, and every call from an addon is tainted by that
        -- addon -- so the read throws and there is nothing to be done about it
        -- except to know that it did.
        if not ok then return nil, true end
        if not data then return nil, unreadable end

        local matched, blind = Matches(data, trigger)
        if blind then unreadable = true end

        if matched then
            if StacksSatisfied(trigger, ns.SafeNumber(data.applications)) then
                return data
            end
            -- Same aura, wrong size. Keep walking: nothing says the client lists
            -- only one aura of a given name on a unit.
        end
    end

    return nil, unreadable
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

-- Zero, and deliberately so.
--
-- A buff that is not on you is a buff you have no stacks of, and that is the
-- case "grey it out at zero stacks" is mostly written for: an aura set to sit
-- there dimmed shows the player they are missing something. Reporting nil
-- here instead reads as "could not tell", no rule matches, and the icon
-- never greys -- which is the wrong answer to the question being asked.
--
-- nil is still reachable and still means unknown: it comes out of StackCount
-- when the aura is present and the count cannot be read. That is the only
-- case that deserves it.
local function ClearState(state)
    state.met, state.start, state.duration, state.count = false, nil, nil, 0
end

local function EvaluateAura(aura, state)
    local trigger = ns.Trigger(aura)
    local unit = ns.TriggerFieldValue(trigger, "unit")
    local data, unknown = FindAura(unit, trigger)

    if not data and unknown then
        -- "I could not look" is not "it is not there", and this is the one
        -- place where confusing the two does real damage: an aura set to show
        -- when something is MISSING reads a refused scan as the thing being
        -- missing, and lights up. That is exactly what happened the moment
        -- combat started -- the reads stopped working, every inverted watcher
        -- came on, and they all went off again when combat ended and the reads
        -- came back.
        --
        -- So nothing is decided here. The last answer stands until there is a
        -- new one, which also means no flash and no sound fires on the way
        -- through: an edge nobody can see is not an edge.
        state.unknown = true
        return
    end

    state.unknown = false

    if not data then
        ClearState(state)
        return
    end

    state.met = true
    -- The field an aura reports its stack count in is not the same on every
    -- generation of this API -- applications is the current name, the older
    -- ones are still what some clients fill in. Take whichever answers rather
    -- than assuming, or a stacking aura silently reads as zero.
    state.count = ns.StackCount(data)
    -- Deliberately NOT "or 0". If none of those answered we do not know the
    -- stack count, and calling that zero is a lie that does real damage: a
    -- "grey out at zero stacks" rule then matches permanently, which is
    -- exactly what it did. nil means unknown, and an unknown property never
    -- matches a condition.
    state.countKnown = state.count ~= nil

    -- A duration of zero is a permanent aura, not a zero-second one. Passing it
    -- to SetCooldown would draw a swipe that instantly completes, so the swipe
    -- is left off and the icon simply reads as on.
    local duration = ns.SafeNumber(data.duration)
    local expires  = ns.SafeNumber(data.expirationTime)
    if duration and duration > 0 and expires and expires > 0 then
        state.duration = duration
        state.start = expires - duration
    else
        state.duration, state.start = nil, nil
    end

    -- The icon the aura is actually wearing beats the one the spell ID implies:
    -- they differ for anything that overrides its own appearance, and a
    -- name-matched aura has no spell ID to take one from in the first place.
    -- What the aura itself is wearing, unless the user said otherwise.
    if not (aura.display or {}).icon then
        state.icon = ns.SafeNumber(data.icon) or state.icon
    end
    state.lastIcon = ns.SafeNumber(data.icon) or state.lastIcon
    state.name = ns.SafeText(data.name) or state.name
end

local function EvaluateCooldown(aura, state)
    local trigger = ns.Trigger(aura)
    if not trigger.spellID then
        ClearState(state)
        return
    end

    local ok, info = pcall(C_Spell.GetSpellCooldown, trigger.spellID)
    if not ok then
        state.unknown = true
        return
    end

    state.unknown = false

    if type(info) ~= "table" then
        ClearState(state)
        return
    end

    local duration = ns.SafeNumber(info.duration) or 0
    local start    = ns.SafeNumber(info.startTime) or 0

    -- The global cooldown runs on every spell at once and says nothing about
    -- whether this one is ready. Anything that short is treated as ready, which
    -- is what a player means by it.
    local onRealCooldown = duration > 1.5 and start > 0

    state.met = not onRealCooldown
    -- A spell cooldown has no stacks to report, which is not the same as
    -- having none. Left as nil so a stack rule simply never matches a
    -- cooldown-triggered aura, rather than always matching it.
    state.count = nil
    if onRealCooldown then
        state.start, state.duration = start, duration
    else
        state.start, state.duration = nil, nil
    end
end

-- What the icon should call itself and wear before any trigger has run. A
-- name-matched aura has the text the user typed and no spell at all, which is
-- the whole point of it.
function Engine:Describe(aura)
    local trigger = ns.Trigger(aura)
    local display = aura.display or {}
    local borrowed = display.iconSpell

    -- One picked out of the list is a decision, and a decision outranks
    -- anything worked out from a spell or remembered from a sighting.
    local chosen = display.icon

    if ns.TriggerFieldValue(trigger, "match") == "name" then
        local text = ns.SafeText(trigger.text)
        -- The question mark is the honest answer for an aura that has never
        -- been seen and names no spell: it says "nothing to show yet" rather
        -- than picking something at random.
        local icon = chosen or (borrowed and self:SpellIcon(borrowed)) or 134400
        return aura.name or text or "unnamed", icon
    end

    local spellID = trigger.spellID
    return aura.name or self:SpellName(spellID) or "unnamed",
           chosen or self:SpellIcon(borrowed or spellID)
end

function Engine:Evaluate(aura, state)
    state.id = aura.id
    state.name, state.icon = self:Describe(aura)

    -- An aura matched by name wears whatever icon the thing itself carries, and
    -- that is only readable while it is up. Remembering the last one means a
    -- Well Fed that has dropped still shows the meal rather than reverting to a
    -- question mark the moment it expires. An explicit choice outranks it.
    local display = aura.display or {}
    if state.lastIcon and not display.icon and not display.iconSpell then
        state.icon = state.lastIcon
    end

    state.loaded = ns.Load:Test(aura)
    if not state.loaded then
        ClearState(state)
        state.shown = false
        return
    end

    local trigger = ns.Trigger(aura)
    if ns.TriggerFieldValue(trigger, "type") == "cooldown" then
        EvaluateCooldown(aura, state)
    else
        EvaluateAura(aura, state)
    end

    -- Inversion is applied once, here, so nothing downstream has to know the
    -- aura was inverted at all.
    state.shown = state.met
    if ns.DisplayField(aura, "invert") then state.shown = not state.shown end
end

-------------------------------------------------------------------------------
-- Text
-------------------------------------------------------------------------------
-- What a text or a bar says. One formatter for both, because "name then time
-- left" should mean the same thing wherever it is written.
--
-- Time is worked out here rather than stored, so a bar redrawing sixty times a
-- second gets a fresh number without the engine having to sweep that often.

local function FormatTime(seconds)
    if not seconds or seconds < 0 then return "" end
    if seconds >= 3600 then
        return string.format("%dh", math.floor(seconds / 3600 + 0.5))
    end
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
    end
    if seconds >= 10 then
        return string.format("%d", math.floor(seconds))
    end
    -- Under ten seconds the tenths are the part you are actually reading.
    return string.format("%.1f", seconds)
end
ns.FormatTime = FormatTime

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

function Engine:FormatText(template, aura, state, now)
    if not template or template == "" then return "" end

    local fraction, left = self:Progress(state, now)

    -- gsub with a table would need every token present; a function lets each
    -- one answer for itself and leaves an unknown token alone rather than
    -- eating it.
    local text = template:gsub("%%(.)", function(token)
        if token == "n" then return state and state.name or "" end
        if token == "s" then
            local count = state and state.count or 0
            return (count > 0) and tostring(count) or ""
        end
        if token == "t" then return FormatTime(left) end
        if token == "d" then
            return FormatTime(state and state.duration)
        end
        if token == "p" then
            if not fraction then return "" end
            return tostring(math.floor(fraction * 100 + 0.5))
        end
        if token == "%" then return "%" end
        return "%" .. token
    end)

    return text
end

-------------------------------------------------------------------------------
-- Sweep
-------------------------------------------------------------------------------

function Engine:StateFor(id)
    return states[id]
end

function Engine:Rebuild()
    wipe(states)
    self:ClearSpellCache()
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
