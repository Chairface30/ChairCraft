local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Conditions: when a trigger's values say so, the aura changes
-------------------------------------------------------------------------------
-- WeakAuras' Conditions tab, in its own shape so its auras map across:
--
--   aura.conditions = {
--     { check = { trigger = 1, variable = "stacks", op = ">=", value = 3 },
--       changes = { { property = "color", value = { 1, 0, 0, 1 } },
--                   { property = "sound", value = { sound = "12867" } } },
--       linked = false },                      -- true: else-if the one above
--   }
--
-- A check is one of:
--   { trigger = n, variable = ..., op = ..., value = ... }   one trigger's value
--   { trigger = -2, variable = "AND"|"OR", checks = { ... } } several of them
--   { trigger = -1, variable = "customcheck", value = "function(states) ... end" }
--
-- Values are read from the trigger's state the way every value is read (see
-- ns.AuraField): a value the client keeps secret is unknown, and an unknown
-- value never matches. Later conditions override earlier ones for the same
-- property, as in WeakAuras. Sounds, chat and custom code fire once, on the
-- moment their condition becomes true.

local Conditions = {}
ns.Conditions = Conditions

-- What a check can ask of a trigger. `kind` decides the operators offered.
Conditions.VARIABLES = {
    { value = "show",           text = "Active",        kind = "bool" },
    { value = "stacks",         text = "Stacks",        kind = "number" },
    { value = "expirationTime", text = "Time left",     kind = "timer" },
    { value = "duration",       text = "Duration",      kind = "number" },
    { value = "name",           text = "Name",          kind = "string" },
    { value = "assumed",        text = "Assumed (in combat)", kind = "bool" },
    { value = "custom",         text = "Other value...", kind = "number" },
}
local KIND = {}
for _, v in ipairs(Conditions.VARIABLES) do KIND[v.value] = v.kind end
function Conditions.KindOf(variable) return KIND[variable] or "number" end

-- What a change can do. `once` ones fire on the edge; the rest hold while true.
Conditions.PROPERTIES = {
    { value = "alpha",      text = "Transparency",   kind = "percent" },
    { value = "color",      text = "Color",          kind = "color" },
    { value = "desaturate", text = "Grayed out",     kind = "bool" },
    { value = "glow",       text = "Glow",           kind = "bool" },
    { value = "scale",      text = "Size",           kind = "scale" },
    { value = "text",       text = "Text",           kind = "text" },
    { value = "sound",      text = "Play a sound",   kind = "sound", once = true },
    { value = "chat",       text = "Chat message",   kind = "chat", once = true },
    { value = "customcode", text = "Run custom code", kind = "code", once = true },
}
local PROPERTY = {}
for _, p in ipairs(Conditions.PROPERTIES) do PROPERTY[p.value] = p end
Conditions.PROPERTY = PROPERTY

-------------------------------------------------------------------------------
-- Reading and comparing
-------------------------------------------------------------------------------

-- One value of a trigger's state.
local function Read(ts, variable, now, field)
    if not ts then return nil end
    if variable == "show" then return ts.met and true or false end
    if variable == "assumed" then return ts.assumed and true or false end
    if variable == "stacks" then return ts.count end
    if variable == "duration" then return ts.duration end
    if variable == "name" then return ts.name end
    if variable == "expirationTime" then
        if not (ts.start and ts.duration) then return nil end
        return math.max(0, ts.start + ts.duration - now)
    end
    -- Anything else: a field of the state, a state updater's included.
    local key = (variable == "custom") and field or variable
    if not key or key == "" then return nil end
    local chosen = ts.chosenState
    local value = chosen and chosen[key]
    if value == nil then value = ts[key] end
    if type(value) == "number" then return ns.SafeNumber(value) end
    if type(value) == "string" then return ns.SafeText(value) end
    return value
end
Conditions.Read = Read

local function Compare(value, op, wanted, kind)
    if value == nil then return false end
    if kind == "bool" then
        local want = (wanted == true or wanted == 1 or wanted == "true")
        if op == "~=" then return (value and true or false) ~= want end
        return (value and true or false) == want
    end
    if kind == "string" then
        value, wanted = tostring(value):lower(), tostring(wanted or ""):lower()
        if op == "find" then return value:find(wanted, 1, true) ~= nil end
        if op == "~=" then return value ~= wanted end
        return value == wanted
    end
    value, wanted = tonumber(value), tonumber(wanted)
    if value == nil or wanted == nil then return false end
    return ns.CompareOp(value, op or ">=", wanted)
end

local function Check(aura, state, check, now)
    if type(check) ~= "table" then return false end
    local trigger = tonumber(check.trigger) or 1
    if trigger == -2 then
        local any = check.variable == "OR"
        local list = check.checks or {}
        if #list == 0 then return false end
        for _, sub in ipairs(list) do
            local ok = Check(aura, state, sub, now)
            if any and ok then return true end
            if not any and not ok then return false end
        end
        return not any
    elseif trigger == -1 then
        if aura.untrusted then return false end
        local fn = ns.Env:Compile(check.value, tostring(aura.name or aura.id) .. " condition")
        if not fn then return false end
        local ok, result = ns.Env:Call(aura, fn, state.triggers or {})
        if not ok then
            ns.Env:Report(aura, "condition check", result)
            return false
        end
        return result and true or false
    end
    local ts = state.triggers and state.triggers[trigger]
    local kind = Conditions.KindOf(check.variable)
    return Compare(Read(ts, check.variable, now, check.field), check.op, check.value, kind)
end
Conditions.Check = Check

-------------------------------------------------------------------------------
-- The one-off changes
-------------------------------------------------------------------------------

local CHAT_CHANNELS = { PRINT = true, SAY = true, YELL = true, PARTY = true, RAID = true,
                        GUILD = true, EMOTE = true, INSTANCE_CHAT = true }

local function Fire(aura, state, change)
    local value = change.value
    if change.property == "sound" then
        local sound = type(value) == "table" and value.sound or value
        if sound and sound ~= "" and ns.Sounds then
            ns.Sounds:Play(sound, type(value) == "table" and value.channel or "Master")
        end
    elseif change.property == "chat" then
        local message = type(value) == "table" and value.message or value
        if not message or message == "" then return end
        local text = ns.Engine:FormatText(message, aura, state)
        local channel = type(value) == "table" and value.channel or "PRINT"
        if channel == "PRINT" or not CHAT_CHANNELS[channel] then
            ns.Print(text)
        elseif not pcall(SendChatMessage, text, channel) then
            ns.Print(text)
        end
    elseif change.property == "customcode" then
        if aura.untrusted then return end
        local source = type(value) == "table" and value.custom or value
        local fn = ns.Env:Compile(source, tostring(aura.name or aura.id) .. " condition code")
        if fn then
            local ok, err = ns.Env:Call(aura, fn)
            if not ok then ns.Env:Report(aura, "condition code", err) end
        end
    end
end

-------------------------------------------------------------------------------
-- Every sweep
-------------------------------------------------------------------------------

-- Works out which conditions hold, and so what the aura's properties are
-- this sweep; fires the one-offs of any that have just become true.
function Conditions:Evaluate(aura, state, now)
    local list = aura.conditions
    if type(list) ~= "table" or #list == 0 then
        state.props = nil
        return
    end
    now = now or GetTime()
    local props = {}
    local was = state.conditionWas or {}
    local matched = {}
    local previousMatched = false
    for index, condition in ipairs(list) do
        local on = false
        if type(condition) == "table" then
            -- Else-if: only when the one above did not hold.
            if not (condition.linked and previousMatched) then
                on = state.loaded ~= false and Check(aura, state, condition.check, now)
            end
            if condition.linked then
                previousMatched = previousMatched or on
            else
                previousMatched = on
            end
            if on then
                for _, change in ipairs(condition.changes or {}) do
                    local def = PROPERTY[change.property]
                    if def and not def.once then props[change.property] = change.value end
                end
                if not was[index] then
                    for _, change in ipairs(condition.changes or {}) do
                        local def = PROPERTY[change.property]
                        if def and def.once then Fire(aura, state, change) end
                    end
                end
            end
        end
        matched[index] = on
    end
    state.conditionWas = matched
    state.props = next(props) and props or nil
end

-- Old rules from before conditions came back (2026-09-25 shape: property,
-- op, value, effect) are not WeakAuras' shape and cannot be read as it.
function Conditions.IsCurrentShape(condition)
    return type(condition) == "table" and (condition.check ~= nil or condition.changes ~= nil)
end
