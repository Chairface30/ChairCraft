local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Custom triggers: the aura's own Lua decides
-------------------------------------------------------------------------------
-- WeakAuras' three kinds, with its field names so its auras map across:
--
--   status       custom = function(event, ...) return on end, run on the
--                events listed (or every update, check = "update"). With a
--                customUntrigger, once on it stays on until that says off.
--   event        custom fires it on an event; it then hides after `duration`
--                seconds (customHide = "timed", the default) or when
--                customUntrigger says so (customHide = "custom").
--   stateupdate  custom = function(allstates, event, ...) -- WeakAuras' TSU.
--                allstates[cloneId] = { show = true, changed = true, name,
--                icon, stacks, duration, expirationTime, autoHide }. The aura
--                shows the first shown state; one region per clone comes with
--                the display phase.
--
-- and, for status and event: customDuration (returns duration and
-- expirationTime), customName, customIcon, customStacks.
--
-- Events are a list, as WeakAuras writes them: "PLAYER_TARGET_CHANGED
-- UNIT_AURA:player:target" -- a unit after a colon filters on the event's
-- first argument. TRIGGER:n fires when trigger n of the same aura changes.
-- Anything the client will not register is taken for a custom event, sent
-- by WeakAuras.ScanEvents. CLEU is named for what it is: the combat log does
-- not exist on this client (probe, 2026-09-26).
--
-- The trigger runs every sweep it is due, in the sandbox, with aura_env.

local Custom = {}
ns.Custom = Custom

local UPDATE_EVENT = "FRAME_UPDATE"

-- Where each custom trigger listens: event -> list of { auraID, index, units }.
local listeners = {}
local frame = CreateFrame("Frame")
local registered = {}      -- game events this frame took
local everyUpdate = {}     -- "auraID:index" -> true, for FRAME_UPDATE triggers
local refused = {}         -- events the client would not register

local function Parse(text)
    local out = {}
    for word in tostring(text or ""):gmatch("[^%s,]+") do
        local event, rest = word:match("^([^:]+):?(.*)$")
        if event then
            local units
            if rest ~= "" then
                units = {}
                for unit in rest:gmatch("[^:]+") do units[unit:lower()] = true end
            end
            out[#out + 1] = { event = event:upper(), units = units }
        end
    end
    return out
end
Custom.Parse = Parse

-- Whether the client will register an event, remembered.
local function Register(event)
    if registered[event] then return true end
    if refused[event] then return false end
    local ok = pcall(frame.RegisterEvent, frame, event)
    local okR, took = pcall(frame.IsEventRegistered, frame, event)
    if ok and (not okR or took ~= false) then
        registered[event] = true
        return true
    end
    refused[event] = true
    return false
end

local function Kind(trigger)
    local kind = trigger.custom_type or trigger.customType
    if kind == "event" or kind == "stateupdate" then return kind end
    return "status"
end
Custom.Kind = Kind

local function Label(aura, index, what)
    return tostring(aura.name or aura.id) .. " trigger " .. index .. " " .. what
end

-- Compile one of the trigger's functions, with the aura's trust in mind.
local function Function(aura, index, trigger, field)
    local source = trigger[field]
    if not source or source == "" then return nil end
    if aura.untrusted then return nil, "imported code waits for your approval" end
    return ns.Env:Compile(source, Label(aura, index, field))
end

local function Call(aura, index, ts, trigger, field, ...)
    local fn, err = Function(aura, index, trigger, field)
    if not fn then
        if err and err ~= "empty" then ts.error = err end
        return false
    end
    local ok, a, b, c, d = ns.Env:Call(aura, fn, ...)
    if not ok then
        ts.error = a
        ns.Env:Report(aura, "trigger " .. index .. " " .. field, a)
        return false
    end
    return true, a, b, c, d
end

-- Name, icon, stacks and timer, from the optional functions.
local function Describe(aura, index, ts, trigger)
    local ok, a, b = Call(aura, index, ts, trigger, "customDuration")
    if ok then
        local duration, expires = ns.SafeNumber(a), ns.SafeNumber(b)
        if duration and duration > 0 and expires and expires > 0 then
            ts.start, ts.duration = expires - duration, duration
        elseif duration and duration > 0 then
            ts.start, ts.duration = GetTime(), duration
        end
    end
    local okN, name = Call(aura, index, ts, trigger, "customName")
    if okN and name ~= nil then ts.name = ns.SafeText(name) end
    local okI, icon = Call(aura, index, ts, trigger, "customIcon")
    if okI and icon ~= nil then ts.icon = icon end
    local okS, stacks = Call(aura, index, ts, trigger, "customStacks")
    if okS and stacks ~= nil then
        ts.count = ns.SafeNumber(stacks)
        ts.countKnown = ts.count ~= nil
    end
end

-------------------------------------------------------------------------------
-- Running a trigger
-------------------------------------------------------------------------------

local function RunStatus(aura, index, ts, trigger, event, ...)
    local ok, result = Call(aura, index, ts, trigger, "custom", event, ...)
    if not ok then return end
    ts.error = nil
    if result then
        ts.met = true
    elseif (trigger.customUntrigger or "") ~= "" then
        -- With an untrigger, off is its decision, not the trigger's.
        local okU, off = Call(aura, index, ts, trigger, "customUntrigger", event, ...)
        if okU and off then ts.met = false end
    else
        ts.met = false
    end
    if ts.met then Describe(aura, index, ts, trigger) else ts.start, ts.duration = nil, nil end
end

local function RunEvent(aura, index, ts, trigger, event, ...)
    local ok, result = Call(aura, index, ts, trigger, "custom", event, ...)
    if ok then ts.error = nil end
    if ok and result then
        ts.met = true
        ts.start, ts.duration = nil, nil
        if (trigger.customHide or "timed") == "timed" then
            local seconds = ns.SafeNumber(trigger.duration) or 1
            ts.start, ts.duration = GetTime(), seconds
        end
        Describe(aura, index, ts, trigger)
        return
    end
    if ts.met and trigger.customHide == "custom" then
        local okU, off = Call(aura, index, ts, trigger, "customUntrigger", event, ...)
        if okU and off then ts.met = false end
    end
end

local function RunStateUpdate(aura, index, ts, trigger, event, ...)
    ts.allstates = ts.allstates or {}
    local ok = Call(aura, index, ts, trigger, "custom", ts.allstates, event, ...)
    if ok then ts.error = nil end
end

local RUN = { status = RunStatus, event = RunEvent, stateupdate = RunStateUpdate }

-- Deliver an event to every custom trigger listening for it.
local function Dispatch(event, ...)
    local list = listeners[event]
    if not list then return end
    local unit = select(1, ...)
    unit = type(unit) == "string" and unit:lower() or nil
    local touched = false
    for _, entry in ipairs(list) do
        if not entry.units or (unit and entry.units[unit]) then
            local aura = ns.FindAura(entry.auraID)
            local state = ns.Engine.states[entry.auraID]
            local ts = state and state.triggers and state.triggers[entry.index]
            if aura and ts and (state.loaded ~= false) then
                local trigger = ns.Trigger(aura, entry.index)
                RUN[Kind(trigger)](aura, entry.index, ts, trigger, event, ...)
                touched = true
            end
        end
    end
    if touched then ns.RequestUpdate() end
end
Custom.Dispatch = Dispatch

frame:SetScript("OnEvent", function(_, event, ...) Dispatch(event, ...) end)

-- Rebuilt whenever the auras change: who listens to what.
function Custom:Rebuild()
    for event in pairs(registered) do pcall(frame.UnregisterEvent, frame, event) end
    wipe(registered)
    wipe(listeners)
    wipe(everyUpdate)
    for _, aura in ipairs(ns.GetAuras()) do
        if not ns.IsGroup(aura) then
            for index = 1, ns.TriggerCount(aura) do
                local trigger = ns.Trigger(aura, index)
                if ns.TriggerFieldValue(trigger, "type") == "custom" then
                    if trigger.check == "update" then everyUpdate[aura.id .. ":" .. index] = true end
                    for _, spec in ipairs(Parse(trigger.events)) do
                        local event = spec.event
                        if event == UPDATE_EVENT then everyUpdate[aura.id .. ":" .. index] = true end
                        listeners[event] = listeners[event] or {}
                        table.insert(listeners[event], { auraID = aura.id, index = index, units = spec.units })
                        if event ~= UPDATE_EVENT and event ~= "TRIGGER" and event ~= "CLEU"
                            and event ~= "COMBAT_LOG_EVENT_UNFILTERED" and event ~= "OPTIONS" then
                            Register(event)
                        end
                    end
                end
            end
        end
    end
end

-- Problems with a trigger's event list, said on the aura.
local function EventProblem(trigger)
    for _, spec in ipairs(Parse(trigger.events)) do
        if spec.event == "CLEU" or spec.event == "COMBAT_LOG_EVENT_UNFILTERED" then
            return "the combat log does not exist on this client"
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- The engine's side: what the trigger says this sweep
-------------------------------------------------------------------------------

local function EvaluateCustom(trigger, ts, now, aura, index)
    if not aura then return end
    ts.unknown, ts.assumed = false, false
    local kind = Kind(trigger)
    ts.error = ts.error or EventProblem(trigger)

    -- First time seen: a status trigger gets an answer straight away, as
    -- WeakAuras' does when it loads.
    if not ts.primed then
        ts.primed = true
        if kind == "status" then RunStatus(aura, index, ts, trigger, "OPTIONS") end
        if kind == "stateupdate" then RunStateUpdate(aura, index, ts, trigger, "OPTIONS") end
    end

    if kind == "status" and (trigger.check == "update" or everyUpdate[aura.id .. ":" .. index]) then
        RunStatus(aura, index, ts, trigger, UPDATE_EVENT)
    elseif kind == "event" then
        if ts.met and ts.start and ts.duration and now >= ts.start + ts.duration then
            ts.met = false
            ts.start, ts.duration = nil, nil
        end
    elseif kind == "stateupdate" then
        -- The first shown state speaks for the aura; timed-out ones with
        -- autoHide go, as they do in WeakAuras. Every shown one is kept, in
        -- order, for the display: one region per clone.
        local shown = {}
        for key, st in pairs(ts.allstates or {}) do
            if type(st) == "table" then
                local expires = ns.SafeNumber(st.expirationTime)
                if st.autoHide and expires and now >= expires then st.show = false end
                if st.show then shown[#shown + 1] = { key = key, state = st } end
            end
        end
        table.sort(shown, function(a, b) return tostring(a.key) < tostring(b.key) end)
        local chosen = shown[1] and shown[1].state
        ts.cloneStates = shown[1] and shown or nil
        ts.met = chosen ~= nil
        ts.chosenState = chosen
        if chosen then
            ts.name = ns.SafeText(chosen.name)
            ts.icon = chosen.icon
            ts.count = ns.SafeNumber(chosen.stacks)
            ts.countKnown = ts.count ~= nil
            local duration = ns.SafeNumber(chosen.duration)
            local expires = ns.SafeNumber(chosen.expirationTime)
            if duration and duration > 0 and expires then
                ts.start, ts.duration = expires - duration, duration
            else
                ts.start, ts.duration = nil, nil
            end
        else
            ts.start, ts.duration = nil, nil
        end
    end
end

ns.Engine.EVALUATORS.custom = EvaluateCustom

-- TRIGGER:n -- after an aura's other triggers have run, the custom ones that
-- watch them hear about it: ("TRIGGER", n, that trigger's state).
function Custom:AfterTriggers(aura, state)
    local list = listeners.TRIGGER
    if not list then return end
    for _, entry in ipairs(list) do
        if entry.auraID == aura.id then
            local ts = state.triggers[entry.index]
            local trigger = ns.Trigger(aura, entry.index)
            for watched in pairs(entry.units or {}) do
                local n = tonumber(watched)
                local other = n and state.triggers[n]
                if other and ts and other.met ~= other.lastSent then
                    other.lastSent = other.met
                    RUN[Kind(trigger)](aura, entry.index, ts, trigger, "TRIGGER", n, other)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- The WeakAuras global, for code written against it
-------------------------------------------------------------------------------
-- Only when the real one is not loaded. What custom code most often calls.

if _G.WeakAuras == nil then
    local shim = {}
    function shim.ScanEvents(event, ...) Dispatch(tostring(event):upper(), ...) end
    function shim.GetData(id)
        for _, aura in ipairs(ns.GetAuras()) do
            if aura.id == id or aura.name == id then return aura end
        end
    end
    function shim.IsOptionsOpen() return ns.Config and ns.Config.IsShown and ns.Config:IsShown() or false end
    function shim.IsClassicEra() return true end
    function shim.IsRetail() return false end
    function shim.IsClassicOrBCCOrWrath() return true end
    shim.IsChairAuras = true
    _G.WeakAuras = shim
    ns.WeakAurasShim = shim
end

-------------------------------------------------------------------------------
-- Imported code waits for approval
-------------------------------------------------------------------------------

local CODE_FIELDS = { "custom", "customUntrigger", "customDuration", "customName",
                      "customIcon", "customStacks" }
Custom.CODE_FIELDS = CODE_FIELDS

-- Every piece of custom Lua an aura carries, as { label, source }.
function Custom:CodeOf(aura)
    local out = {}
    local list = aura.triggers
    if type(list) == "table" and (list.customTriggerLogic or "") ~= "" then
        out[#out + 1] = { "activation", list.customTriggerLogic }
    end
    for index = 1, ns.TriggerCount(aura) do
        local trigger = ns.Trigger(aura, index)
        for _, field in ipairs(CODE_FIELDS) do
            if (trigger[field] or "") ~= "" then
                out[#out + 1] = { "trigger " .. index .. " " .. field, trigger[field] }
            end
        end
    end
    local function Checks(check, where)
        if type(check) ~= "table" then return end
        if tonumber(check.trigger) == -1 and (check.value or "") ~= "" then
            out[#out + 1] = { where .. " check", check.value }
        end
        for _, sub in ipairs(check.checks or {}) do Checks(sub, where) end
    end
    for index, condition in ipairs(aura.conditions or {}) do
        local where = "condition " .. index
        Checks(condition.check, where)
        for _, change in ipairs(condition.changes or {}) do
            local value = change.value
            local source = type(value) == "table" and value.custom or (change.property == "customcode" and value)
            if type(source) == "string" and source ~= "" then
                out[#out + 1] = { where .. " code", source }
            end
        end
    end
    for _, key in ipairs({ "onShowCode", "onHideCode", "initCode", "loadCode", "unloadCode" }) do
        local source = ns.ActionField(aura, key)
        if source and source ~= "" then out[#out + 1] = { "action " .. key, source } end
    end
    if (ns.DisplayField(aura, "customText") or "") ~= "" then
        out[#out + 1] = { "custom text", ns.DisplayField(aura, "customText") }
    end
    -- A group's own layout code: custom growth and sort.
    for _, key in ipairs({ "growCustom", "sortCustom" }) do
        if type(aura[key]) == "string" and aura[key] ~= "" then
            out[#out + 1] = { "group " .. key, aura[key] }
        end
    end
    -- Animation paths written as functions.
    for _, which in ipairs({ "start", "main", "finish" }) do
        local anim = ns.Animation and ns.Animation(aura, which)
        if anim then
            for _, part in ipairs({ "alpha", "translate", "scale", "rotate", "color" }) do
                local source = anim[part .. "Func"]
                if anim[part .. "Type"] == "custom" and type(source) == "string" and source ~= "" then
                    out[#out + 1] = { which .. " animation " .. part, source }
                end
            end
        end
    end
    return out
end
