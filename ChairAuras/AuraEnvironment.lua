local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Custom Lua: where it is compiled, and what it may touch
-------------------------------------------------------------------------------
-- WeakAuras lets an aura carry its own Lua, and so does this. The probe
-- confirmed loadstring and setfenv both work on this client, so the model is
-- WeakAuras' own (its AuraEnvironment.lua): code is compiled once, cached by
-- its text, and run in an environment of its own that reads through to the
-- game's globals -- minus the ones nobody should be handing to code pasted in
-- from a stranger. The mail and trade money calls, RunScript, macro editing,
-- guild disbanding, the chat edit box and the saved variables of every addon
-- in this suite are all refused, the same list WeakAuras refuses.
--
-- aura_env is the aura's own table, the WeakAuras name for it, so code written
-- for WeakAuras finds what it expects. Globals custom code writes land on
-- the real _G, as they do in WeakAuras -- all but the blocked names.

local Env = {}
ns.Env = Env

local BLOCKED_FUNCTIONS = {
    getfenv = true, setfenv = true, loadstring = true, pcall = true, xpcall = true,
    SendMail = true, SetTradeMoney = true, AddTradeMoney = true, PickupTradeMoney = true,
    PickupPlayerMoney = true, SetSendMailMoney = true, AcceptTrade = true,
    RunScript = true, securecall = true, DeleteCursorItem = true,
    EditMacro = true, CreateMacro = true, SetBindingMacro = true, DeleteMacro = true,
    GuildDisband = true, GuildUninvite = true, GuildLeave = true,
    ChatEdit_SendText = true, ChatEdit_ActivateChat = true, ChatEdit_ParseText = true,
    ChatEdit_OnEnterPressed = true, EnumerateFrames = true,
    hooksecurefunc = true, issecurevariable = true,
}
local BLOCKED_TABLES = {
    SlashCmdList = true, DEFAULT_CHAT_FRAME = true, ChatFrame1 = true,
    MailFrame = true, SendMailFrame = true, TradeFrame = true,
    ChairAurasDB = true, ChairPlusDB = true, SnapSnackDB = true,
    WOWFTrackerDB = true, WOWFTrackerAccountDB = true, WeakAurasSaved = true,
}
Env.BLOCKED_FUNCTIONS = BLOCKED_FUNCTIONS
Env.BLOCKED_TABLES = BLOCKED_TABLES

-- The aura whose code is running, so aura_env resolves to the right one.
local current = nil
local auraEnvs = {}

-- One per aura, made on first use and kept for the session. WeakAuras' fields:
-- id, and config (author options, filled in by a later phase). saved is kept
-- across sessions by a later phase too.
-- Custom options (WeakAuras' author options): what aura_env.config holds is
-- each option's default, overlaid by what the user set. A simple group is a
-- table of its own options; an array group, the list the user made.
local SKIP = { header = true, description = true, space = true }
local function OptionValues(options, saved)
    local out = {}
    saved = type(saved) == "table" and saved or {}
    for _, option in ipairs(type(options) == "table" and options or {}) do
        local key = option.key
        if key ~= nil and not SKIP[option.type] then
            if option.type == "group" then
                if option.groupType == "array" then
                    out[key] = type(saved[key]) == "table" and saved[key] or {}
                else
                    out[key] = OptionValues(option.subOptions, saved[key])
                end
            else
                local value = saved[key]
                if value == nil then value = option.default end
                if type(value) == "table" then
                    local copy = {}
                    for k, v in pairs(value) do copy[k] = v end
                    value = copy
                end
                out[key] = value
            end
        end
    end
    return out
end
Env.OptionValues = OptionValues

function Env:For(aura)
    local id = aura and aura.id or "?"
    local env = auraEnvs[id]
    if not env then
        env = { id = id, config = OptionValues(aura and aura.authorOptions, aura and aura.config) }
        auraEnvs[id] = env
    end
    return env
end

-- After an option changes.
function Env:RefreshConfig(aura)
    local env = self:For(aura)
    env.config = OptionValues(aura.authorOptions, aura.config)
end

function Env:Forget(id)
    auraEnvs[id] = nil
end

local function Refuse(name)
    error(name .. " is not available to custom code", 3)
end

local sandbox = setmetatable({}, {
    __index = function(_, key)
        if key == "aura_env" then return current end
        if BLOCKED_FUNCTIONS[key] then
            return function() Refuse(key) end
        end
        if BLOCKED_TABLES[key] then Refuse(key) end
        if key == "_G" then return nil end
        return _G[key]
    end,
    -- A global written by custom code lands on the real _G, as it does in
    -- WeakAuras: auras pass values to each other that way. The blocked names
    -- cannot be overwritten, so no code can swap RunScript for its own.
    __newindex = function(_, key, value)
        if key == "aura_env" then Refuse("replacing aura_env") end
        if BLOCKED_FUNCTIONS[key] or BLOCKED_TABLES[key] then Refuse(key) end
        _G[key] = value
    end,
    __metatable = false,
})
Env.sandbox = sandbox

-- Compiled once per distinct text. The value is the function the text
-- evaluates to (WeakAuras stores "function(...) ... end" and compiles
-- "return " .. that), or false with the compile error kept beside it.
local cache, errors = {}, {}

-- Returns the function, or nil and the compile error.
function Env:Compile(source, label)
    if type(source) ~= "string" or source:match("^%s*$") then return nil, "empty" end
    local cached = cache[source]
    if cached ~= nil then
        if cached then return cached end
        return nil, errors[source]
    end
    local load, set = _G.loadstring, _G.setfenv
    if type(load) ~= "function" or type(set) ~= "function" then
        return nil, "this client cannot run custom Lua"
    end
    local chunk, err = load("return " .. source, "=" .. tostring(label or "custom"))
    if not chunk then
        cache[source], errors[source] = false, err
        return nil, err
    end
    set(chunk, sandbox)
    local ok, fn = pcall(chunk)
    if not ok or type(fn) ~= "function" then
        local message = ok and "does not evaluate to a function" or fn
        cache[source], errors[source] = false, message
        return nil, message
    end
    cache[source] = fn
    return fn
end

-- Run fn as aura's code: aura_env set for the duration, every error caught.
-- Returns ok, then whatever fn returned (up to four values).
function Env:Call(aura, fn, ...)
    local previous = current
    current = self:For(aura)
    local ok, a, b, c, d = pcall(fn, ...)
    current = previous
    return ok, a, b, c, d
end

-- Errors are said once per aura and message a session, not once per sweep.
local reported = {}
function Env:Report(aura, what, err)
    local key = tostring(aura and aura.id) .. "|" .. tostring(what) .. "|" .. tostring(err)
    if reported[key] then return end
    reported[key] = true
    ns.Print("|cffff5555" .. tostring(aura and (aura.name or aura.id) or "an aura")
        .. " -- " .. tostring(what) .. ":|r " .. tostring(err))
end
