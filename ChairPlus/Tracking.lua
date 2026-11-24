-- ChairPlus Tracking.lua
-- Keep your minimap tracking on.
--
-- Find Minerals, Find Herbs, Find Treasure, a hunter's Track Beasts: the last
-- one you picked is remembered, per character, and whenever it goes off --
-- dying, a reload, a zone change, anything else that clears it -- it is turned
-- back on as soon as it can be.
--
-- "As soon as it can be" means: alive, out of combat, not on a flight path and
-- not casting. Turning tracking on is a spell cast (it takes the global
-- cooldown), so trying in the middle of one is just a red error. A try that
-- doesn't take is tried again a few seconds later, and after a few misses only
-- every half minute, so a spell that can't be cast right now doesn't spam.
--
-- Switching it off yourself from the minimap's tracking menu is respected: the
-- menu's own SetTracking(.., false) / ClearAllTracking is hooked, and that
-- forgets the remembered tracking until you pick one again. Death and the like
-- clear it without calling either, so those are put back.
--
-- Only spell tracking is handled. The town trackers on newer clients (flight
-- master, repair...) are many at once and don't drop on death; they are left
-- alone.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local RETRY = 3          -- seconds between tries
local SLOW_RETRY = 30    -- ... after this many misses in a row
local MISSES_BEFORE_SLOW = 3

local enabled = false
local driver
local lastTry = -1000
local misses = 0
local hooked = false
local applying = false   -- our own SetTracking, not the player's
local testing = false    -- /chair plus tracking test is running; leave it be
local onNow              -- name of the spell tracker the last check saw on
local deathAt = -1000    -- GetTime() of the last death or revive

local function Minimap() return _G.C_Minimap end

local function NumTypes()
    local C = Minimap()
    local fn = (C and C.GetNumTrackingTypes) or _G.GetNumTrackingTypes
    if type(fn) ~= "function" then return 0 end
    local ok, n = pcall(fn)
    return ok and (ns.Num(n) or 0) or 0
end

-- The tracking spells by name. This client doesn't always say an entry is a
-- spell (no type, no spell ID), so the name is enough -- GatherMate2 goes by
-- the name alone too. "Find ...", "Track ..." and "Sense ..." cover the rest.
local SPELL_NAMES = {
    ["Find Minerals"] = true, ["Find Herbs"] = true, ["Find Treasure"] = true, ["Find Fish"] = true,
    ["Sense Undead"] = true, ["Sense Demons"] = true, ["Track Beasts"] = true, ["Track Humanoids"] = true,
    ["Track Undead"] = true, ["Track Hidden"] = true, ["Track Elementals"] = true, ["Track Demons"] = true,
    ["Track Giants"] = true, ["Track Dragonkin"] = true,
}
local function IsSpellName(name)
    if not name then return false end
    if SPELL_NAMES[name] then return true end
    return (name:find("^Find ") or name:find("^Track ") or name:find("^Sense ")) ~= nil
end

-- This client can say a spell tracker is off (active=false) while Find
-- Minerals is plainly on. So a spell tracker is also taken as on when the
-- player has its aura, or when the minimap's tracking icon is its icon.
-- Each returns true/false, or nil when it can't be read.
local function SafeEq(a, b)
    local ok, same = pcall(function() return a == b end)
    return ok and same == true
end

local function AuraOn(name, spellID)
    local CU = _G.C_UnitAuras
    if spellID and CU and type(CU.GetPlayerAuraBySpellID) == "function" then
        local ok, aura = pcall(CU.GetPlayerAuraBySpellID, spellID)
        if ok and aura ~= nil then return true end
    end
    local AU = _G.AuraUtil
    if name and AU and type(AU.FindAuraByName) == "function" then
        local ok, found = pcall(AU.FindAuraByName, name, "player", "HELPFUL")
        if ok then return found ~= nil end
    end
    return nil
end

local function SpellTexture(name, spellID)
    local CS = _G.C_Spell
    for _, key in ipairs({ spellID or false, name or false }) do
        if key then
            if CS and type(CS.GetSpellTexture) == "function" then
                local ok, t = pcall(CS.GetSpellTexture, key)
                if ok and t ~= nil then return t end
            end
            if type(_G.GetSpellTexture) == "function" then
                local ok, t = pcall(_G.GetSpellTexture, key)
                if ok and t ~= nil then return t end
            end
        end
    end
    return nil
end

local function IconOn(name, spellID, entryTex)
    local fn = _G.GetTrackingTexture
    if type(fn) ~= "function" then return nil end
    local ok, cur = pcall(fn)
    if not ok then return nil end
    if cur == nil then return false end
    if entryTex ~= nil and SafeEq(cur, entryTex) then return true end
    local tex = SpellTexture(name, spellID)
    if tex == nil then return nil end
    return SafeEq(cur, tex)
end

-- What the client last said about each entry, raw, saved for working out
-- what it hands back (profile.trackingSeen, and /chair plus tracking).
local seen = {}

-- name, active, isSpell, spellID for one tracking entry. Newer clients return
-- a table; older ones name, texture, active, category, nested[, spellID].
local function Info(i)
    local C = Minimap()
    local fn = (C and C.GetTrackingInfo) or _G.GetTrackingInfo
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, _, f = pcall(fn, i)
    if not ok or a == nil then return nil end
    local name, active, kind, spellID, tex
    if type(a) == "table" then
        name, active, kind, spellID, tex = a.name, a.active, a.type, a.spellID, a.texture
    else
        name, active, kind, spellID, tex = a, c, d, f, b
    end
    local rawActive = ns.Bool(active)
    name = ns.Text(name)
    kind = ns.Text(kind)
    spellID = ns.Num(spellID)
    -- A type the client gives is trusted: "Track Quest POIs" is type "other"
    -- and must not pass as a spell on its "Track " name. The name is only a
    -- guess for entries that come with no type and no spell ID.
    local isSpell
    if kind == "spell" or (spellID ~= nil and spellID > 0) then
        isSpell = true
    elseif kind ~= nil then
        isSpell = false
    else
        isSpell = IsSpellName(name)
    end
    local aura, icon
    if isSpell then
        aura = AuraOn(name, spellID)
        icon = IconOn(name, spellID, tex)
    end
    seen[i] = string.format("%s | active=%s | aura=%s | icon=%s | type=%s | spellID=%s | %s",
        name or "?", tostring(rawActive), tostring(aura), tostring(icon), ns.Text(kind) or "nil",
        tostring(spellID), type(a) == "table" and "table" or "values")
    -- The aura decides when it can be read: after a death the client can
    -- keep saying active=true while the tracking is gone, and say false while
    -- it is plainly on. The raw flag (and the icon) only count without it.
    local active = rawActive
    if isSpell then
        if aura ~= nil then active = aura
        elseif icon ~= nil then active = icon end
    end
    return name, active, isSpell, spellID
end

-- The spell tracking that is on now: name, spellID. Second return of false
-- means it couldn't be read at all (kept secret), so nothing should be done.
local function Current()
    local readable = false
    for k in pairs(seen) do seen[k] = nil end
    for i = 1, NumTypes() do
        local name, active, isSpell, spellID = Info(i)
        if active ~= nil then readable = true end
        if isSpell and active and name then return { name = name, spellID = spellID }, true end
    end
    -- Oldest clients: one tracking at a time, known only by its icon.
    if NumTypes() == 0 then
        local tex = _G.GetTrackingTexture
        if type(tex) == "function" then
            local ok, t = pcall(tex)
            return nil, ok
        end
    end
    return nil, readable
end

local function Store()
    local profile = ns.Profile()
    if type(profile.trackingLast) ~= "table" then profile.trackingLast = {} end
    return profile.trackingLast
end

-- This character. The GUID when it can be read; the name otherwise, so a
-- GUID the client keeps secret doesn't stop it remembering.
local function CharKey()
    local key = ns.CharacterKey()
    if key then return key end
    local ok, name = pcall(_G.UnitName, "player")
    name = ok and ns.Text(name) or nil
    return name and ("name:" .. name) or nil
end

local function Remembered()
    local key = CharKey()
    if not key then return nil end
    local entry = Store()[key]
    return type(entry) == "table" and type(entry.name) == "string" and entry or nil
end

local function Remember(entry)
    local key = CharKey()
    if not key then return end
    Store()[key] = entry and { name = entry.name, spellID = entry.spellID } or nil
end

-- The index of the remembered tracking in today's list: spell ID first, the
-- name if the ID isn't given (or the rank changed).
local function FindIndex(entry)
    local byName
    for i = 1, NumTypes() do
        local name, _, isSpell, spellID = Info(i)
        if isSpell then
            if entry.spellID and spellID == entry.spellID then return i end
            if name == entry.name then byName = byName or i end
        end
    end
    return byName
end

local function Bool(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn, ...)
    return ok and ns.Bool(v) == true
end

-- Whether a cast could go through now. Unreadable counts as "not now".
local function CanTry()
    local dead = _G.UnitIsDeadOrGhost
    if type(dead) == "function" then
        local ok, v = pcall(dead, "player")
        if not ok or ns.Bool(v) ~= false then return false end
    end
    if Bool(_G.InCombatLockdown) then return false end
    if Bool(_G.UnitOnTaxi, "player") then return false end
    for _, name in ipairs({ "UnitCastingInfo", "UnitChannelInfo" }) do
        local fn = _G[name]
        if type(fn) == "function" then
            local ok, v = pcall(fn, "player")
            if not ok or v ~= nil then return false end
        end
    end
    return true
end

local function SetTrackingFn()
    local C = Minimap()
    return (C and C.SetTracking) or _G.SetTracking
end

-- What happened last, for /chair plus tracking.
local lastResult

-- One pass: remember what's on, or put the remembered one back.
local function Check()
    if not enabled or testing then return end
    local current, readable = Current()
    local snap = { key = CharKey() or "unreadable", count = NumTypes() }
    for i, line in pairs(seen) do snap[i] = line end
    ns.Profile().trackingSeen = snap
    snap.result = lastResult
    if not readable then lastResult = "tracking can't be read right now"; return end
    onNow = current and current.name or nil
    if current then
        Remember(current)
        misses = 0
        lastResult = "on: " .. current.name
        if driver then driver:Hide() end
        return
    end
    local want = Remembered()
    if not want then lastResult = "nothing to put back"; if driver then driver:Hide() end return end
    if driver then driver:Show() end   -- keep checking until it's back

    local now = ns.Num(GetTime()) or 0
    local wait = misses >= MISSES_BEFORE_SLOW and SLOW_RETRY or RETRY
    if now - lastTry < wait then return end
    if not CanTry() then lastResult = "waiting to put back " .. want.name; return end

    local index = FindIndex(want)
    local set = SetTrackingFn()
    if not index then
        -- Remembered by an older version that took a town tracker for a
        -- spell: it is in the list, just not as a spell. Forget it.
        for i = 1, NumTypes() do
            if Info(i) == want.name then
                Remember(nil)
                lastResult = want.name .. " isn't a spell tracker; forgotten"
                if driver then driver:Hide() end
                return
            end
        end
    end
    if not index or type(set) ~= "function" then
        lastResult = want.name .. " isn't in this character's tracking list"
        return
    end
    lastTry = now
    misses = misses + 1
    applying = true
    local ok = pcall(set, index, true)
    applying = false
    -- Count it as on until the next check reads otherwise, so the player
    -- switching it off straight after isn't taken for "it wasn't on".
    if ok then onNow = want.name end
    lastResult = (ok and "turned back on: " or "couldn't turn on: ") .. want.name
end
ns.TrackingCheck = Check

local function Hook()
    if hooked then return end
    local hook = _G.hooksecurefunc
    if type(hook) ~= "function" then return end
    hooked = true
    -- The player switching it off from the minimap menu: forget it, so it
    -- isn't fought. But only a real switch-off: after a death the client can
    -- still call the tracker active while it's gone, so the menu's toggle
    -- sends "off" for something already off. That, or anything while dead or
    -- just revived, is not the player turning it off.
    local function Off(how)
        if not enabled or applying or testing then return end
        local why
        if not onNow then why = "it wasn't on"
        else
            local dead = _G.UnitIsDeadOrGhost
            local ok, v = pcall(dead or function() return false end, "player")
            if not ok or ns.Bool(v) ~= false then why = "dead"
            elseif (ns.Num(GetTime()) or 0) - deathAt < 15 then why = "just revived" end
        end
        -- Every off call and what was made of it, with its caller.
        local log = ns.Profile().trackingOffLog
        if type(log) ~= "table" then log = {}; ns.Profile().trackingOffLog = log end
        local stack = type(_G.debugstack) == "function" and _G.debugstack(3, 4, 0) or ""
        table.insert(log, string.format("%.0f %s on=%s -> %s | %s", ns.Num(GetTime()) or 0, how,
            tostring(onNow), why and ("ignored, " .. why) or "forgot", (stack:gsub("\n", " / "))))
        while #log > 10 do table.remove(log, 1) end
        if why then return end
        Remember(nil)
        onNow = nil
        lastResult = "switched off by you; nothing to put back"
    end
    local function OnSet(i, on)
        if not on and select(3, Info(i)) then Off("SetTracking(" .. tostring(i) .. ", false)") end
    end
    local C = Minimap()
    if C and type(C.SetTracking) == "function" then
        pcall(hook, C, "SetTracking", OnSet)
    elseif type(_G.SetTracking) == "function" then
        pcall(hook, "SetTracking", OnSet)
    end
    local function OnClear() Off("ClearAllTracking") end
    if C and type(C.ClearAllTracking) == "function" then
        pcall(hook, C, "ClearAllTracking", OnClear)
    elseif type(_G.ClearAllTracking) == "function" then
        pcall(hook, "ClearAllTracking", OnClear)
    end
end

local EVENTS = {
    "MINIMAP_UPDATE_TRACKING", "PLAYER_ENTERING_WORLD", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOSTED",
    "PLAYER_REGEN_ENABLED", "PLAYER_CONTROL_GAINED", "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_FAILED", "ZONE_CHANGED_NEW_AREA",
}

ns.RegisterModule("keepTracking", {
    title = "Keep tracking on",
    desc = "Turn Find Minerals, Find Herbs and the like back on whenever they go off.",
    Apply = function(on)
        enabled = on and true or false
        if not driver then
            driver = CreateFrame("Frame")
            driver:Hide()
            local elapsed = 0
            driver:SetScript("OnUpdate", function(_, dt)
                elapsed = elapsed + (dt or 0)
                if elapsed < 1 then return end
                elapsed = 0
                Check()
            end)
            driver:SetScript("OnEvent", function(_, event, unit)
                if event:find("^UNIT_") and unit ~= "player" then return end
                if event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOSTED" then misses = 0 end
                if event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOSTED" then
                    deathAt = ns.Num(GetTime()) or 0
                    onNow = nil   -- whatever was on, death took it
                end
                if event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOSTED" then
                    -- What it saw around a death, for working out a miss.
                    ns.After(1, function()
                        local log = ns.Profile().trackingDeathLog
                        if type(log) ~= "table" then log = {}; ns.Profile().trackingDeathLog = log end
                        local line = event .. " -> " .. tostring(lastResult)
                        for i in pairs(seen) do line = line .. " || " .. seen[i] end
                        table.insert(log, line)
                        while #log > 10 do table.remove(log, 1) end
                    end)
                end
                -- A beat later: the client sends these before the tracking
                -- list or the player's state has settled.
                ns.After(0.5, Check)
            end)
        end
        if enabled then
            Hook()
            for _, event in ipairs(EVENTS) do pcall(driver.RegisterEvent, driver, event) end
            misses = 0
            Check()
        else
            driver:UnregisterAllEvents()
            driver:Hide()
        end
    end,
})

-- /chair plus tracking
function ns.ProbeTracking()
    local want = Remembered()
    local current, readable = Current()
    ns.Print("Tracking now:", current and current.name or (readable and "none" or "unreadable"),
        "- remembered:", want and want.name or "none",
        "- list entries:", tostring(NumTypes()),
        "- SetTracking:", type(SetTrackingFn()) == "function" and "found" or "MISSING")
    ns.Print("Last:", lastResult or "nothing yet", ns.IsEnabled("keepTracking") and "" or "(option is off)")
    for i = 1, NumTypes() do if seen[i] then ns.Print("  " .. i .. ":", seen[i]) end end
    local offs = ns.Profile().trackingOffLog
    if type(offs) == "table" and #offs > 0 then ns.Print("Last off call:", offs[#offs]) end
end

-- /chair plus tracking test
-- Whether this addon can switch tracking at all. Detection works; this checks
-- the other half. It turns the current (or remembered) spell tracker off, then
-- on again, then off and on once more, reading the state 2s after each. Steps
-- 1 and 2 run straight from the slash command (a key press is behind them);
-- steps 3 and 4 run from a timer, like the keep-on code does after a death.
-- ADDON_ACTION_BLOCKED / FORBIDDEN fired during a step are reported too, since
-- a blocked call still returns without an error.
local watcher
local blockedNow
function ns.TestTracking()
    if testing then ns.Print("Tracking test is already running.") return end
    local current = Current()
    local want = current or Remembered()
    if not want then
        ns.Print("Tracking test: turn on Find Minerals (or any tracking spell) first.")
        return
    end
    local index = FindIndex(want)
    local set = SetTrackingFn()
    if not index or type(set) ~= "function" then
        ns.Print("Tracking test:", want.name, index and "" or "isn't in the list;",
            type(set) == "function" and "" or "SetTracking is missing")
        return
    end
    if not watcher then
        watcher = CreateFrame("Frame")
        watcher:SetScript("OnEvent", function(_, event, addon, func)
            if testing then
                blockedNow = (blockedNow and blockedNow .. "; " or "") ..
                    event .. " " .. tostring(addon) .. " " .. tostring(func)
            end
        end)
        pcall(watcher.RegisterEvent, watcher, "ADDON_ACTION_BLOCKED")
        pcall(watcher.RegisterEvent, watcher, "ADDON_ACTION_FORBIDDEN")
    end
    testing = true
    local results = {}
    local function IsOn()
        local _, active = Info(index)
        return active
    end
    local function Step(n, on, from)
        blockedNow = nil
        local before = IsOn()
        applying = true
        local ok, err = pcall(set, index, on)
        applying = false
        ns.After(2, function()
            local after = IsOn()
            local worked = (after == on)
            local line = string.format("%d. %s (%s): call %s, before=%s after=%s -> %s%s",
                n, on and "ON " or "OFF", from, ok and "ok" or ("error: " .. tostring(err)),
                tostring(before), tostring(after),
                worked and "|cff40ff40WORKED|r" or "|cffff4040NO CHANGE|r",
                blockedNow and (" [" .. blockedNow .. "]") or "")
            results[n] = worked
            ns.Print(line)
            if n == 1 then Step(2, true, "timer")
            elseif n == 2 then Step(3, false, "timer")
            elseif n == 3 then Step(4, true, "timer")
            else
                testing = false
                ns.Print(string.format("Tracking test done - off: %s/2, on: %s/2.",
                    (results[1] and 1 or 0) + (results[3] and 1 or 0),
                    (results[2] and 1 or 0) + (results[4] and 1 or 0)))
                ns.Profile().trackingTest = {
                    off1 = results[1], on2 = results[2], off3 = results[3], on4 = results[4],
                }
                Check()
            end
        end)
    end
    ns.Print("Tracking test on", want.name, "(entry " .. index .. ") - 4 steps, 2s apart. Stay still, out of combat.")
    Step(1, false, "key press")
end
