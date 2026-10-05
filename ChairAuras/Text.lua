local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Text replacements
-------------------------------------------------------------------------------
-- What a text, a bar or the words on an icon say, WeakAuras' way:
--
--   %n name   %s stacks   %i the icon, drawn in the text   %% a per-cent sign
--   %c        custom text: display.customText is a Lua function; %c is what
--             it returns, %c1 %c2 ... each of several returns
--   %field  %{field}   any value of the trigger's state -- stacks, name,
--             expirationTime, or anything a state updater put there
--   %2.p  %{2.name}    the same, from trigger 2 rather than the one shown
--
-- and the timer, which is where ChairAuras and WeakAuras disagree:
--
--                  ChairAuras (the default)    WeakAuras codes
--   %t             time left                   the full duration
--   %p             per cent left               time left
--   %d             the full duration           (not a WeakAuras code)
--
-- Existing auras were written with ChairAuras' meaning, and the default bar
-- says "%n  %t", so that stays. An aura set to WeakAuras codes (every one
-- imported from WeakAuras is) reads them WeakAuras' way.
--
-- Time is shown by the aura's time format: auto (2h, 4:05, 12, 3.4), clock
-- (m:ss) or seconds, with a chosen number of decimals.

local Engine = ns.Engine

local function FormatAuto(seconds)
    if seconds >= 3600 then
        return string.format("%dh", math.floor(seconds / 3600 + 0.5))
    end
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
    end
    if seconds >= 10 then
        return string.format("%d", math.floor(seconds))
    end
    return string.format("%.1f", seconds)
end

local function FormatTime(seconds, aura)
    if not seconds or seconds < 0 then return "" end
    local style = aura and ns.DisplayField(aura, "timeFormat") or "auto"
    local places = aura and ns.DisplayField(aura, "timePrecision")
    if style == "clock" then
        -- m:ss, as a clock reads; decimals are for the other two.
        local minutes = math.floor(seconds / 60)
        return string.format("%d:%02d", minutes, math.floor(seconds - minutes * 60))
    elseif style == "seconds" then
        return string.format("%." .. (places or 0) .. "f", seconds)
    end
    if places and places ~= 1 and seconds < 10 then
        return string.format("%." .. places .. "f", seconds)
    end
    return FormatAuto(seconds)
end
ns.FormatTime = function(seconds, aura) return FormatTime(seconds, aura) end

local function Left(state, now)
    local fraction, left = Engine:Progress(state, now)
    return fraction, left
end

-- WeakAuras' names for a state's fields, onto ours.
local ALIASES = {
    stacks = "count", progress = "p", icon = "icon", name = "name",
    duration = "duration", expirationTime = "expirationTime",
}

-- One value out of a trigger state, or an aura's.
local function Field(ts, key, now)
    if not ts then return nil end
    local chosen = ts.chosenState
    if chosen and chosen[key] ~= nil then return chosen[key] end
    if key == "expirationTime" and ts.start and ts.duration then return ts.start + ts.duration end
    local mapped = ALIASES[key] or key
    local value = ts[mapped]
    if value == nil and chosen then value = chosen[mapped] end
    return value
end

-- A value as text: numbers tidied, anything unreadable left out.
local function Show(value)
    if value == nil then return "" end
    if type(value) == "number" then
        if value == math.floor(value) then return tostring(value) end
        return string.format("%.1f", value)
    end
    if type(value) == "boolean" then return value and "true" or "false" end
    return ns.SafeText(value) or ""
end

local function IconText(icon)
    if not icon then return "" end
    return "|T" .. tostring(icon) .. ":0|t"
end

-- The single-letter codes, for one state (the aura's, or one trigger's).
local function Letter(letter, aura, state, now, weakauras)
    local fraction, left = Left(state, now)
    if letter == "n" then return state and state.name or "" end
    if letter == "s" then
        -- Unread in combat: the count is not known, and says so.
        if state and state.stale then return "?" end
        local count = state and state.count or 0
        return (count and count > 0) and tostring(count) or ""
    end
    if letter == "i" then return IconText(state and state.icon) end
    if weakauras then
        if letter == "p" then return FormatTime(left, aura) end
        if letter == "t" then return FormatTime(state and state.duration, aura) end
    else
        if letter == "t" then return FormatTime(left, aura) end
        if letter == "d" then return FormatTime(state and state.duration, aura) end
        if letter == "p" then
            if not fraction then return "" end
            return tostring(math.floor(fraction * 100 + 0.5))
        end
    end
    return nil
end

-- %c: the aura's custom text function, run once per call of FormatText.
local function CustomText(aura, state)
    local source = ns.DisplayField(aura, "customText")
    if not source or source == "" then return {} end
    if aura.untrusted then return { "(imported code waits for approval)" } end
    local fn, err = ns.Env:Compile(source, tostring(aura.name or aura.id) .. " custom text")
    if not fn then return { "|cffff5555" .. tostring(err) .. "|r" } end
    local env = ns.Env:For(aura)
    env.state = state
    local results = { ns.Env:Call(aura, fn) }
    if not results[1] then
        ns.Env:Report(aura, "custom text", results[2])
        return {}
    end
    table.remove(results, 1)
    return results
end

-- Resolve one code to its text. `token` is what came after the %, without
-- braces: "n", "stacks", "2.p", "c", "c2".
local function Resolve(token, aura, state, now, weakauras, custom)
    -- %c, %c1, %c2 ...
    local cIndex = token:match("^c(%d*)$")
    if cIndex then
        custom.values = custom.values or CustomText(aura, state)
        return Show(custom.values[tonumber(cIndex) or 1])
    end

    -- %2.p -- one trigger's own value.
    local n, rest = token:match("^(%d+)%.(.+)$")
    if n then
        local ts = state and state.triggers and state.triggers[tonumber(n)]
        if not ts then return "" end
        if #rest == 1 then
            local letter = Letter(rest, aura, ts, now, weakauras)
            if letter then return letter end
        end
        return Show(Field(ts, rest, now))
    end

    if #token == 1 then
        local letter = Letter(token, aura, state, now, weakauras)
        if letter then return letter end
        return nil   -- an unknown single letter is left as typed
    end

    -- %stacks, %{name}: a field of the trigger that speaks for the aura.
    local source = state and state.source
    local value = Field(source, token, now)
    if value == nil then value = Field(state, token, now) end
    return Show(value)
end

-- Formatters, after a colon inside braces: %{stacks:abbr}, %{unitName:norealm:class}.
local function Abbreviate(n)
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.1fb", n / 1e9) end
    if a >= 1e6 then return string.format("%.1fm", n / 1e6) end
    if a >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

-- The unit a value came from, for class colors: a clone's, or the trigger's.
local function UnitOf(state)
    local source = state and state.source
    local chosen = source and source.chosenState
    return (chosen and chosen.unit) or (source and source.unit) or (state and state.unit)
end

local FORMATTERS = {
    abbr = function(text) local n = tonumber(text) return n and Abbreviate(n) or text end,
    round = function(text) local n = tonumber(text) return n and tostring(math.floor(n + 0.5)) or text end,
    floor = function(text) local n = tonumber(text) return n and tostring(math.floor(n)) or text end,
    ceil = function(text) local n = tonumber(text) return n and tostring(math.ceil(n)) or text end,
    norealm = function(text) return (text:gsub("%-.*$", "")) end,
    upper = function(text) return text:upper() end,
    lower = function(text) return text:lower() end,
    time = function(text, aura) local n = tonumber(text) return n and FormatTime(n, aura) or text end,
    class = function(text, aura, state)
        local unit = UnitOf(state)
        if not unit or text == "" then return text end
        local ok, _, token = pcall(UnitClass, unit)
        token = ok and ns.SafeText(token)
        local colours = _G.RAID_CLASS_COLORS
        local colour = token and colours and colours[token]
        if type(colour) ~= "table" then return text end
        local hex = colour.colorStr or string.format("ff%02x%02x%02x", math.floor((colour.r or 1) * 255 + 0.5),
            math.floor((colour.g or 1) * 255 + 0.5), math.floor((colour.b or 1) * 255 + 0.5))
        return "|c" .. hex .. text .. "|r"
    end,
}
Engine.FORMATTERS = FORMATTERS

local function Format(text, mods, aura, state)
    for mod in mods:gmatch("[^:]+") do
        local most = tonumber(mod:match("^max(%d+)$"))
        if most then
            text = text:sub(1, most)
        elseif FORMATTERS[mod:lower()] then
            text = FORMATTERS[mod:lower()](text, aura, state) or text
        end
    end
    return text
end

function Engine:FormatText(template, aura, state, now)
    if not template or template == "" then return "" end
    now = now or GetTime()
    local weakauras = aura and ns.DisplayField(aura, "textStyle") == "weakauras"
    local custom = {}
    local out, i, length = {}, 1, #template
    while i <= length do
        local char = template:sub(i, i)
        if char ~= "%" then
            local stop = template:find("%", i, true) or (length + 1)
            out[#out + 1] = template:sub(i, stop - 1)
            i = stop
        else
            local nextChar = template:sub(i + 1, i + 1)
            if nextChar == "%" then
                out[#out + 1] = "%"
                i = i + 2
            elseif nextChar == "{" then
                local close = template:find("}", i + 2, true)
                if not close then
                    out[#out + 1] = template:sub(i)
                    break
                end
                local inside = template:sub(i + 2, close - 1)
                local token, mods = inside:match("^([^:]*):(.*)$")
                token = token or inside
                local resolved = Resolve(token, aura, state, now, weakauras, custom)
                if resolved and mods then resolved = Format(resolved, mods, aura, state) end
                out[#out + 1] = resolved or ("%{" .. inside .. "}")
                i = close + 1
            else
                -- %2.p, %c2, %stacks, %n: digits-dot-word, or a word.
                local token = template:match("^%d+%.[%a_][%w_]*", i + 1)
                    or template:match("^c%d+", i + 1)
                    or template:match("^[%a_][%w_]*", i + 1)
                if not token then
                    out[#out + 1] = "%"
                    i = i + 1
                else
                    local resolved = Resolve(token, aura, state, now, weakauras, custom)
                    if resolved == nil and #token > 1 then
                        -- A single known letter followed by more text: "%nfoo"
                        -- is %n then "foo" only if "nfoo" is no field at all.
                        resolved = ""
                    end
                    out[#out + 1] = resolved or ("%" .. token)
                    i = i + 1 + #token
                end
            end
        end
    end
    return table.concat(out)
end

ns.FormatTimeFor = FormatTime
