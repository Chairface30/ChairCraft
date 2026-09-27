local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Sharing
-------------------------------------------------------------------------------
-- An aura leaves here as a line of text and arrives somewhere else as the same
-- aura, by copy and paste through the Export and Import boxes. Two parts:
--
--   serialise   the aura table into text, and back
--   encode      that text into something an edit box cannot mangle
--
-- There are no chat links. They were removed on 2026-09-24: making them work
-- meant wrapping every chat window, and on this client that wrapper met secret
-- chat text and dropped lines from chat. The export string does the same job.
--
-- Since 1.2 the strings go out as !CA:3!: LibSerialize, then LibDeflate,
-- both embedded in Libs, which makes them far shorter. CA1: strings, which
-- needed no library, still import. WeakAuras' own strings are not read
-- (removed 2026-09-26, at the owner's call).

local Share = {}
ns.Share = Share

local PREFIX = "CA1"          -- bumped if the format ever stops being readable

-------------------------------------------------------------------------------
-- Serialising
-------------------------------------------------------------------------------
-- A tagged, comma-separated form: every value says what it is, so reading it
-- back never has to guess whether "1" was a number or a string. Keys are
-- written the same way, because an aura's tables are a mix of the two.

-- Three digits, always. The first version wrote as many as the byte needed
-- and read back with %d+, which is greedy: a comma followed by a digit came
-- out as \\44 then "2", read back as byte 442, and string.char refused it --
-- taking the whole import down with it rather than one character. Any escaped
-- character with a digit after it did that, which includes a file path like
-- Sound\\2.ogg and a format string with a number in it.
local function Escape(text)
    return (text:gsub("[\\~|,{}=]", function(char)
        return string.format("\\%03d", string.byte(char))
    end))
end

local function Unescape(text)
    return (text:gsub("\\(%d%d%d)", function(byte)
        local value = tonumber(byte)
        if not value or value < 0 or value > 255 then return "" end
        return string.char(value)
    end))
end

local Serialise

local function SerialiseValue(value)
    local kind = type(value)
    if kind == "string" then return "s" .. Escape(value) end
    if kind == "number" then return "n" .. tostring(value) end
    if kind == "boolean" then return value and "t" or "f" end
    if kind == "table" then return Serialise(value) end
    -- Functions and userdata cannot cross, and an aura has none: anything that
    -- turns up here is a bug rather than a thing to preserve.
    return "z"
end

Serialise = function(tbl)
    local parts = {}
    for key, value in pairs(tbl) do
        local kind = type(key)
        if kind == "string" or kind == "number" then
            parts[#parts + 1] = SerialiseValue(key) .. "=" .. SerialiseValue(value)
        end
    end
    -- Sorted so the same aura always makes the same string: two exports that
    -- differ only in table order would look like different auras to anyone
    -- comparing them.
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end
Share.Serialise = Serialise

-- The reader is a cursor over the string rather than a pattern match, because
-- the values nest and patterns do not.
local function ReadValue(text, pos)
    local tag = text:sub(pos, pos)

    if tag == "t" then return true, pos + 1 end
    if tag == "f" then return false, pos + 1 end
    if tag == "z" then return nil, pos + 1 end

    if tag == "{" then
        local out = {}
        pos = pos + 1
        if text:sub(pos, pos) == "}" then return out, pos + 1 end

        while true do
            local key, value
            key, pos = ReadValue(text, pos)
            if text:sub(pos, pos) ~= "=" then return nil, pos, "expected =" end
            value, pos = ReadValue(text, pos + 1)
            if key ~= nil then out[key] = value end

            local char = text:sub(pos, pos)
            if char == "}" then return out, pos + 1 end
            if char ~= "," then return nil, pos, "expected , or }" end
            pos = pos + 1
        end
    end

    -- s and n both run to the next separator.
    local finish = text:find("[,}=]", pos + 1)
    finish = (finish or #text + 1) - 1
    local body = text:sub(pos + 1, finish)

    if tag == "s" then return Unescape(body), finish + 1 end
    if tag == "n" then return tonumber(body), finish + 1 end
    return nil, pos + 1, "unknown value"
end

function Share.Deserialise(text)
    if type(text) ~= "string" or text == "" then return nil, "nothing to read" end
    local ok, value, _, err = pcall(ReadValue, text, 1)
    if not ok then return nil, "unreadable" end
    if type(value) ~= "table" then return nil, err or "not an aura" end
    return value
end

-------------------------------------------------------------------------------
-- Encoding
-------------------------------------------------------------------------------
-- Base64, so the string survives a chat box, an edit box and a forum post. The
-- alphabet is the standard one: every character in it is one the client's own
-- text fields accept without interpreting.

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Encode(text)
    local out, length = {}, #text

    for index = 1, length, 3 do
        local a, b, c = text:byte(index, index + 2)
        local packed = a * 65536 + (b or 0) * 256 + (c or 0)

        local chars = {
            B64:sub(math.floor(packed / 262144) % 64 + 1, math.floor(packed / 262144) % 64 + 1),
            B64:sub(math.floor(packed / 4096) % 64 + 1, math.floor(packed / 4096) % 64 + 1),
            B64:sub(math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1),
            B64:sub(packed % 64 + 1, packed % 64 + 1),
        }

        -- Padding says how many of the last three bytes were real.
        if not b then chars[3], chars[4] = "=", "="
        elseif not c then chars[4] = "=" end

        out[#out + 1] = table.concat(chars)
    end

    return table.concat(out)
end

Share.__Encode = Encode

local DECODE = {}
for index = 1, #B64 do DECODE[B64:sub(index, index)] = index - 1 end

local function Decode(text)
    text = text:gsub("[^%w+/=]", "")
    local out = {}

    for index = 1, #text, 4 do
        local chunk = text:sub(index, index + 3)
        local a = DECODE[chunk:sub(1, 1)]
        local b = DECODE[chunk:sub(2, 2)]
        local c = DECODE[chunk:sub(3, 3)]
        local d = DECODE[chunk:sub(4, 4)]
        if not (a and b) then return nil end

        local packed = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        out[#out + 1] = string.char(math.floor(packed / 65536) % 256)
        if c then out[#out + 1] = string.char(math.floor(packed / 256) % 256) end
        if d then out[#out + 1] = string.char(packed % 256) end
    end

    return table.concat(out)
end

-------------------------------------------------------------------------------
-- Exporting
-------------------------------------------------------------------------------
-- A group goes with its children, because a group without them is an empty box
-- and nobody means that when they share one. Ids come along only so the parent
-- links inside the bundle survive; the importer throws them away and issues its
-- own, so an import can never collide with something already here.

local function Bundle(aura)
    local list = { aura }
    if ns.IsGroup(aura) then
        for _, child in ipairs(ns.Descendants(aura.id)) do
            list[#list + 1] = child
        end
    end

    local copies = {}
    for index, one in ipairs(list) do
        local copy = {}
        for key, value in pairs(one) do
            if key ~= "pos" or index == 1 then copy[key] = value end
        end
        copies[index] = copy
    end

    return {
        v = 1,
        who = ns.SafeText(UnitName("player")) or "?",
        auras = copies,
    }
end

-- The compressed pipeline, when its libraries are here.
local function Lib(name)
    local stub = _G.LibStub
    if not stub then return nil end
    local ok, lib = pcall(stub.GetLibrary, stub, name, true)
    return ok and lib or nil
end

local function Libraries()
    local serialize, deflate = Lib("LibSerialize"), Lib("LibDeflate")
    if serialize and deflate then return serialize, deflate end
    return nil
end

function Share:Export(aura)
    if not aura then return nil end
    local bundle = Bundle(aura)
    local serialize, deflate = Libraries()
    if serialize then
        local ok, text = pcall(function()
            local packed = serialize:SerializeEx({ errorOnUnserializableType = false }, bundle)
            return "!CA:3!" .. deflate:EncodeForPrint(deflate:CompressDeflate(packed, { level = 9 }))
        end)
        if ok and text then return text end
    end
    local ok, text = pcall(Serialise, bundle)
    if not ok then return nil end
    return PREFIX .. ":" .. Encode(text)
end

-------------------------------------------------------------------------------
-- Importing
-------------------------------------------------------------------------------

-- What is in the string, without putting anything anywhere: the import window
-- shows this before the button that commits it.
function Share:Peek(text)
    if type(text) ~= "string" then return nil, "nothing pasted" end

    text = text:gsub("%s", "")

    if text:match("^!CA:3!") then
        local serialize, deflate = Libraries()
        if not serialize then return nil, "this copy is missing LibSerialize or LibDeflate" end
        local decoded = deflate:DecodeForPrint(text:sub(7))
        local raw = decoded and deflate:DecompressDeflate(decoded)
        if not raw then return nil, "the string is damaged" end
        local ok, bundle = serialize:Deserialize(raw)
        if not ok or type(bundle) ~= "table" or type(bundle.auras) ~= "table" or not bundle.auras[1] then
            return nil, "the string is damaged"
        end
        return bundle
    end

    local prefix, body = text:match("^(%w+):(.*)$")
    if prefix ~= PREFIX then
        return nil, "that is not a ChairAuras string"
    end

    local raw = Decode(body)
    if not raw then return nil, "the string is damaged" end

    local bundle, err = Share.Deserialise(raw)
    if not bundle then return nil, err or "the string is damaged" end
    if type(bundle.auras) ~= "table" or not bundle.auras[1] then
        return nil, "no aura in there"
    end

    return bundle
end

function Share:Import(text)
    local bundle, err = self:Peek(text)
    if not bundle then return nil, err end

    local profile = ns.GetProfile()
    if not profile then return nil, "not loaded yet" end

    -- New ids all round, and the old ones kept only long enough to rebuild the
    -- parent links between them.
    local mapping = {}
    local added = {}

    for _, incoming in ipairs(bundle.auras) do
        local aura = {}
        for key, value in pairs(incoming) do aura[key] = value end

        local oldID = aura.id
        aura.id = ns.NextID(profile)
        if oldID then mapping[oldID] = aura.id end
        -- An export from before version 3 carries one trigger, not a list.
        ns.NormalizeTriggers(aura)
        -- Custom Lua from someone else runs only once you have read it and
        -- said yes (the aura's Trigger tab, or /chair auras trust).
        aura.untrusted = nil
        if ns.Custom and #ns.Custom:CodeOf(aura) > 0 then aura.untrusted = true end

        profile.auras[#profile.auras + 1] = aura
        added[#added + 1] = aura
    end

    for _, aura in ipairs(added) do
        if aura.parent then
            -- A parent that was not in the bundle means a child shared on its
            -- own: it comes in loose rather than pointing at a group that is
            -- not here.
            aura.parent = mapping[aura.parent]
        end
    end

    ns.Engine:Rebuild()
    ns.RequestUpdate()

    return added
end
