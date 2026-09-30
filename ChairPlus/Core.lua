-- ChairPlus Core.lua
-- Shared namespace, secret-safe value handling, API shims and the module
-- registry. Loaded first; every other file expects what this file defines.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus
ns.name = addonName
-- The suite's release version (Suite/Namespace.lua reads it from the TOC).
ns.version = Chaircraft.version

_G.ChairPlusNS = ns

-------------------------------------------------------------------------------
-- Secret values
-------------------------------------------------------------------------------
-- This client hands back "secret" values from some APIs. A secret reports its
-- real underlying type through type(), survives tostring() still secret, and
-- throws only when something finally reads it -- a concat, a string.format, a
-- SetText, or even a plain comparison once the call stack is tainted. The error
-- lands on the innocent-looking line that formatted the value, never on the
-- call that produced it, and it takes the whole enclosing function with it.
--
-- Money is why this matters here: the OSD formats GetMoney() into a string
-- every time it updates, and formatting is exactly the operation a secret
-- kills. So nothing is tested for secrecy and then used as-is. Values are
-- laundered on the way in, and what comes back out is an ordinary Lua number,
-- or nil when it could not be read at all.

-- The client ships two native detectors, canaccessvalue and issecretvalue. Use whichever is present and
-- fall back to the pcall trick, which works everywhere but costs more.
local issecretvalue = _G.issecretvalue
local canaccessvalue = _G.canaccessvalue

function ns.IsSecret(value)
    if issecretvalue then
        local ok, res = pcall(issecretvalue, value)
        if ok then return res and true or false end
    end
    if canaccessvalue then
        local ok, res = pcall(canaccessvalue, value)
        if ok then return not res end
    end
    return not pcall(function() return "" .. tostring(value) end)
end

-- Launder a number rather than test it. Formatting the value and reading the
-- result back is what turns a secret into an ordinary number; the throwaway
-- comparison afterwards is what proves it took, because under a tainted stack
-- a secret will format happily and then throw on the very next compare. Both
-- steps live inside the same pcall on purpose -- a guard that attempts a
-- different operation than the caller will is not a guard.
--
-- The format is %.14g, not %d. Two of the settings here are fractions -- the
-- loot delay and the OSD scale -- and %d would launder 0.3 into 0 and call it
-- a success, which is a far worse failure than not reading the value at all.
-- %.14g round-trips both whole numbers and fractions.
function ns.Num(value)
    if type(value) ~= "number" then return nil end
    local ok, plain = pcall(function()
        local n = tonumber(string.format("%.14g", value))
        if type(n) ~= "number" then return nil end
        -- True of any real number. The point is that it answers at all.
        if not (n >= 0 or n < 0) then return nil end
        return n
    end)
    return (ok and type(plain) == "number") and plain or nil
end

-- A yes/no that is safe to branch on: true, false, or nil when the client
-- keeps it secret. Even testing a secret boolean throws on a tainted stack,
-- so the test itself is what sits inside the pcall.
function ns.Bool(value)
    if ns.IsSecret(value) then return nil end
    if value == nil then return nil end
    local ok, answer = pcall(function()
        if value then return true end
        return false
    end)
    if ok then return answer end
    return nil
end

-- A string that is safe to concat and compare. nil comes back as nil so
-- callers can tell "absent" apart from "unreadable".
--
-- The comparison lives inside the pcall, the same as in ns.Num. A secret
-- string concatenates happily and comes out the other side still secret; it is
-- the first comparison that throws, and only once the stack is tainted. With
-- the `~= ""` outside the pcall, a secret unit name in the threat meter got
-- through the concat and then threw here, from the line meant to guard it.
function ns.Text(value)
    if ns.IsSecret(value) then return nil end
    if value == nil then return nil end
    local ok, text = pcall(function()
        local s = "" .. tostring(value)
        if s == "" then return nil end
        return s
    end)
    if ok then return text end
    return nil
end

-- For a font string, and nothing else. A secret string cannot be tested or
-- compared, but a widget will still show it, so a name the client keeps
-- secret is handed on as it is rather than dropped. Never branch on the
-- result, sort by it or save it.
function ns.DisplayText(value)
    local text = ns.Text(value)
    if text then return text end
    if type(value) == "string" then return value end
    return nil
end

local PREFIX = "|cff9d7cffChairPlus|r:"

function ns.Print(...)
    local parts = { PREFIX }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = ns.Text((select(i, ...))) or "<unreadable>"
    end
    local ok, line = pcall(table.concat, parts, " ")
    print(ok and line or PREFIX .. " <unprintable message>")
end

-------------------------------------------------------------------------------
-- API shims
-------------------------------------------------------------------------------
-- Forever runs the retail engine, so the item and container globals are gone
-- and only the C_ namespaces answer. The older clients in the TOC still have
-- the globals. Nothing below assumes either: take the namespaced function when
-- the client has one, fall back to the global, and record which answered so
-- "/chair plus api" can report what this client actually has.

local apiSource = {}
ns.apiSource = apiSource

local function Pick(namespace, namespaceName, key, globalName)
    local fn = namespace and namespace[key]
    if type(fn) == "function" then
        apiSource[key] = namespaceName
        return fn
    end
    fn = _G[globalName or key]
    apiSource[key] = (type(fn) == "function") and "global" or "MISSING"
    return fn
end

local C_Container = _G.C_Container
local C_Item = _G.C_Item
local C_CurrencyInfo = _G.C_CurrencyInfo

ns.GetContainerNumSlots     = Pick(C_Container, "C_Container", "GetContainerNumSlots")
ns.GetContainerNumFreeSlots = Pick(C_Container, "C_Container", "GetContainerNumFreeSlots")
ns.GetContainerItemInfo     = Pick(C_Container, "C_Container", "GetContainerItemInfo")
ns.GetContainerItemLink     = Pick(C_Container, "C_Container", "GetContainerItemLink")
ns.UseContainerItem         = Pick(C_Container, "C_Container", "UseContainerItem")
ns.GetItemInfo              = Pick(C_Item, "C_Item", "GetItemInfo")
ns.GetItemCount             = Pick(C_Item, "C_Item", "GetItemCount")

-- Reading a bag's family off the bag itself. The second return of
-- GetContainerNumFreeSlots is meant to be the family but cannot be relied on
-- here -- see BagFamily in OSD.lua.
ns.ContainerIDToInventoryID = Pick(C_Container, "C_Container", "ContainerIDToInventoryID")
ns.GetItemFamily            = Pick(C_Item, "C_Item", "GetItemFamily")

-- Money formatted the way the client does it, for the chat summaries only. The
-- OSD builds its own line because it wants icons in a fixed order.
ns.GetCoinText = Pick(C_CurrencyInfo, "C_CurrencyInfo", "GetCoinText", "GetCoinTextureString")

ns.After = (_G.C_Timer and _G.C_Timer.After) or function(_, fn) fn() end

-- Highest bag index to walk. Retail-engine clients put the reagent bag one
-- past the normal bags; older ones have no such thing and the constant is nil.
ns.LAST_BAG = _G.NUM_BAG_SLOTS or 4
ns.REAGENT_BAG = (_G.Enum and _G.Enum.BagIndex and _G.Enum.BagIndex.ReagentBag) or nil

-------------------------------------------------------------------------------
-- Module registry
-------------------------------------------------------------------------------
-- Every feature is a module with an Apply(enabled) that must be safe to call
-- repeatedly and must fully undo itself when passed false. That is the whole
-- contract, and it is what lets every option here be toggled without a reload
-- -- unlike the addon this ports from, where several need one.
--
-- Apply runs inside a pcall. On a client this unfinished, one feature hitting a
-- missing API should cost that feature and nothing else.

ns.modules = {}
ns.moduleOrder = {}

function ns.RegisterModule(key, def)
    def.key = key
    ns.modules[key] = def
    ns.moduleOrder[#ns.moduleOrder + 1] = key
end

function ns.ApplyModule(key)
    local mod = ns.modules[key]
    if not mod or not mod.Apply then return end
    local ok, err = pcall(mod.Apply, ns.IsEnabled(key))
    if not ok then
        mod.broken = ns.Text(err) or "unknown error"
        ns.Print("|cffff5555" .. (mod.title or key) .. " failed:|r", mod.broken)
    else
        mod.broken = nil
    end
end

function ns.ApplyAll()
    for i = 1, #ns.moduleOrder do
        ns.ApplyModule(ns.moduleOrder[i])
    end
end

-------------------------------------------------------------------------------
-- Boot
-------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == suiteName then
        ns.LoadSettings()
    elseif event == "PLAYER_LOGIN" then
        -- Settings are normally in by now. On a cold start where the client
        -- never hands the saved file back they are the in-code defaults, which
        -- is the whole reason those exist.
        -- The GUID is not always readable as early as ADDON_LOADED. If the
        -- profile was picked by name then, pick again now it is: otherwise
        -- the settings land under a key this character never finds again.
        if not ns.settings or not ns.profileKeyFromGuid then ns.LoadSettings() end
        ns.ApplyAll()
    end
end)
