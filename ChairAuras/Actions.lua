local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Actions: what an aura does, not how it looks
-------------------------------------------------------------------------------
-- WeakAuras' Actions tab:
--
--   on init     custom code, once, the first time the aura is set up
--   on load     custom code, each time its load conditions start to hold
--   on unload   custom code, each time they stop
--   on show     a sound (the existing onShow), a chat message, custom code
--   on hide     the same, as it goes
--   glow        another frame glows while the aura shows: your player,
--               target, focus or pet frame, one named, or the action
--               button carrying the trigger's spell
--
-- The display finds the moments (it already found show and hide for the
-- sounds); this does what they ask. Custom code runs in the sandbox, and an
-- imported aura's waits for approval like the rest.

local Actions = {}
ns.Actions = Actions

local CHAT = { SAY = true, YELL = true, PARTY = true, RAID = true, GUILD = true,
               EMOTE = true, INSTANCE_CHAT = true }

local function RunCode(aura, key, state)
    local source = ns.ActionField(aura, key)
    if not source or source == "" or aura.untrusted then return end
    local fn, err = ns.Env:Compile(source, tostring(aura.name or aura.id) .. " " .. key)
    if not fn then
        ns.Env:Report(aura, key, err)
        return
    end
    local env = ns.Env:For(aura)
    env.state = state
    local ok, runErr = ns.Env:Call(aura, fn)
    if not ok then ns.Env:Report(aura, key, runErr) end
end

local function Say(aura, state, messageKey, channelKey)
    local message = ns.ActionField(aura, messageKey)
    if not message or message == "" then return end
    local text = ns.Engine:FormatText(message, aura, state)
    local channel = ns.ActionField(aura, channelKey)
    if CHAT[channel] and pcall(SendChatMessage, text, channel) then return end
    ns.Print(text)
end

-- One of the moments. `which` is "show", "hide", "load", "unload".
function Actions:Fire(aura, state, which)
    if which == "show" then
        Say(aura, state, "onShowMessage", "onShowChannel")
        RunCode(aura, "onShowCode", state)
    elseif which == "hide" then
        Say(aura, state, "onHideMessage", "onHideChannel")
        RunCode(aura, "onHideCode", state)
    elseif which == "load" then
        self:Init(aura, state)
        RunCode(aura, "loadCode", state)
    elseif which == "unload" then
        RunCode(aura, "unloadCode", state)
    end
end

-- Once per aura per session: the first time it loads.
local initialised = {}
function Actions:Init(aura, state)
    if initialised[aura.id] then return end
    initialised[aura.id] = true
    RunCode(aura, "initCode", state)
end
function Actions:Reset() wipe(initialised) end

-------------------------------------------------------------------------------
-- Glowing another frame
-------------------------------------------------------------------------------

local UNIT_FRAMES = { player = "PlayerFrame", target = "TargetFrame", focus = "FocusFrame",
                      pet = "PetFrame" }
local BAR_PREFIXES = { "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
                       "MultiBarRightButton", "MultiBarLeftButton" }

-- The spells an aura's triggers name, as IDs and names.
local function TriggerSpells(aura)
    local ids, names = {}, {}
    for i = 1, ns.TriggerCount(aura) do
        local id = ns.Trigger(aura, i).spellID
        if id then
            ids[id] = true
            local name = ns.Engine:SpellName(id)
            if name then names[name:lower()] = true end
        end
    end
    return ids, names
end

-- The action buttons carrying one of those spells.
local function ButtonsFor(aura)
    local ids, names = TriggerSpells(aura)
    if not next(ids) then return {} end
    local out = {}
    for _, prefix in ipairs(BAR_PREFIXES) do
        for i = 1, 12 do
            local button = _G[prefix .. i]
            local slot = button and ns.SafeNumber(button.action)
            if slot then
                local ok, kind, id = pcall(GetActionInfo, slot)
                id = ok and ns.SafeNumber(id) or nil
                if ok and kind == "spell" and id then
                    local name = ns.Engine:SpellName(id)
                    if ids[id] or (name and names[name:lower()]) then out[#out + 1] = button end
                end
            end
        end
    end
    return out
end

local function Targets(aura)
    local where = ns.ActionField(aura, "glowFrame")
    if where == "button" then return ButtonsFor(aura) end
    local name = UNIT_FRAMES[where]
    if where == "name" then name = ns.ActionField(aura, "glowFrameName") end
    local frame = name and name ~= "" and _G[name]
    if type(frame) == "table" and frame.GetObjectType then return { frame } end
    return {}
end
Actions.Targets = Targets

-- Glows made for other frames: [auraID] = { [frame] = glow holder }.
local glowing = {}

function Actions:UpdateGlow(aura, state)
    local want = {}
    local where = ns.ActionField(aura, "glowFrame")
    if where and where ~= "none" and state and state.shown and state.loaded then
        for _, frame in ipairs(Targets(aura)) do want[frame] = true end
    end
    local held = glowing[aura.id] or {}
    for frame, holder in pairs(held) do
        if not want[frame] then
            ns.Display.Glow(holder, false)
            held[frame] = nil
        end
    end
    for frame in pairs(want) do
        local holder = held[frame] or { target = frame }
        held[frame] = holder
        ns.Display.Glow(holder, true, frame)
    end
    glowing[aura.id] = next(held) and held or nil
end

function Actions:GlowingFor(aura)
    local out = {}
    for frame in pairs(glowing[aura.id] or {}) do out[#out + 1] = frame end
    return out
end
