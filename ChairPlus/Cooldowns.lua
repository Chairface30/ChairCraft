-- ChairPlus Cooldowns.lua
-- Profession cooldowns across every character on the account: transmutes,
-- Mooncloth, the Salt Shaker. An OSD item (off out of the box) shows how many
-- are ready, its tooltip lists every character's, and an optional chat line
-- says when one comes up.
--
-- How it knows: this client keeps spell cooldowns secret from addons most of
-- the time, but your own casts are readable. So a tracked cast is recorded
-- when it happens (UNIT_SPELLCAST_SUCCEEDED on "player"). A moment later the
-- game's own cooldown is read if the client allows it; if not, the duration
-- below is used. /chair cooldowns probe prints the next casts' spell IDs and
-- what the game said, to confirm or correct the table.
--
-- Saved account-wide in ChairPlusDB.cooldowns, by character: data, like the
-- learned flight times, not a setting.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local HOUR, DAY = 3600, 86400

-- spell ID -> name shown, and the duration used when the game will not say.
-- Classic Era values; /chair cooldowns probe checks them on this client.
local TRACKED = {
    [17187] = { name = "Transmute: Arcanite",           duration = 2 * DAY },
    [11479] = { name = "Transmute: Iron to Gold",       duration = 2 * DAY },
    [11480] = { name = "Transmute: Mithril to Truesilver", duration = 2 * DAY },
    [17559] = { name = "Transmute: Air to Fire",        duration = DAY },
    [17560] = { name = "Transmute: Fire to Earth",      duration = DAY },
    [17561] = { name = "Transmute: Earth to Water",     duration = DAY },
    [17562] = { name = "Transmute: Water to Air",       duration = DAY },
    [17563] = { name = "Transmute: Undeath to Water",   duration = DAY },
    [17564] = { name = "Transmute: Water to Undeath",   duration = DAY },
    [17565] = { name = "Transmute: Life to Earth",      duration = DAY },
    [17566] = { name = "Transmute: Earth to Life",      duration = DAY },
    [18560] = { name = "Mooncloth",                     duration = 4 * DAY },
    [19566] = { name = "Salt Shaker",                   duration = 3 * DAY },
}
ns.TRACKED_COOLDOWNS = TRACKED

local ICON = "Interface\\Icons\\Trade_Alchemy"
ns.COOLDOWN_ICON = ICON

local function Now()
    return (type(time) == "function" and time()) or 0
end

local function Store()
    local db = _G.ChairPlusDB
    if type(db) ~= "table" then return nil end
    db.cooldowns = type(db.cooldowns) == "table" and db.cooldowns or {}
    return db.cooldowns
end

-- This character's record: { name = "First Last", spells = { [id] = readyAt } }.
local function Mine()
    local store = Store()
    if not store then return nil end
    local key = ns.ProfileKey and ns.ProfileKey() or "player"
    local rec = store[key]
    if type(rec) ~= "table" then
        rec = { spells = {} }
        store[key] = rec
    end
    rec.spells = type(rec.spells) == "table" and rec.spells or {}
    local ok, name = pcall(_G.UnitName, "player")
    rec.name = (ok and ns.Text(name)) or rec.name or "?"
    return rec
end

-- The game's own cooldown for a spell, as seconds left, or nil when the
-- client keeps it secret (or has none to give).
local function GameSecondsLeft(spellID)
    local C = _G.C_Spell
    local start, duration
    if C and C.GetSpellCooldown then
        local ok, info = pcall(C.GetSpellCooldown, spellID)
        if ok and type(info) == "table" then start, duration = info.startTime, info.duration end
    elseif type(_G.GetSpellCooldown) == "function" then
        local ok, s, d = pcall(_G.GetSpellCooldown, spellID)
        if ok then start, duration = s, d end
    end
    start, duration = ns.Num(start), ns.Num(duration)
    local now = ns.Num(type(GetTime) == "function" and GetTime())
    if not (start and duration and now) or duration <= 60 then return nil end
    return math.max(0, start + duration - now)
end

-- The probe: the next casts, whatever they are.
local probing, probed = false, {}

local function Record(spellID)
    local tracked = TRACKED[spellID]
    if probing then
        probed[#probed + 1] = spellID
        ns.After(1, function()
            local left = GameSecondsLeft(spellID)
            ns.Print(string.format("cast %d%s: the game's cooldown %s", spellID,
                tracked and (" (" .. tracked.name .. ")") or "",
                left and string.format("is %.1f hours", left / HOUR) or "is not readable here"))
        end)
    end
    if not tracked then return end
    local rec = Mine()
    if not rec then return end
    rec.spells[spellID] = Now() + tracked.duration
    rec.announced = rec.announced or {}
    rec.announced[spellID] = nil
    -- The game's own figure, when the client lets it be read, beats the table.
    ns.After(1, function()
        local left = GameSecondsLeft(spellID)
        if left and left > 0 then rec.spells[spellID] = Now() + math.floor(left) end
    end)
    if ns.RefreshOSD then ns.RefreshOSD() end
end
ns.RecordCooldownCast = Record

-- Every character's cooldowns, for the OSD tooltip:
-- { { name, list = { { spell, name, left } ... } } ... }, sorted by name.
function ns.AllCooldowns()
    local out, now = {}, Now()
    for _, rec in pairs(Store() or {}) do
        if type(rec) == "table" and type(rec.spells) == "table" then
            local list = {}
            for spellID, readyAt in pairs(rec.spells) do
                local t = TRACKED[spellID]
                if t and type(readyAt) == "number" then
                    list[#list + 1] = { spell = spellID, name = t.name, left = math.max(0, readyAt - now) }
                end
            end
            if #list > 0 then
                table.sort(list, function(a, b) return a.left < b.left end)
                out[#out + 1] = { name = tostring(rec.name or "?"), list = list }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- How many are ready, and how many are tracked at all.
function ns.CooldownCounts()
    local ready, total = 0, 0
    for _, char in ipairs(ns.AllCooldowns()) do
        for _, cd in ipairs(char.list) do
            total = total + 1
            if cd.left <= 0 then ready = ready + 1 end
        end
    end
    return ready, total
end

function ns.CooldownLeftText(seconds)
    if seconds <= 0 then return "ready" end
    if seconds >= DAY then return string.format("%dd %dh", seconds / DAY, (seconds % DAY) / HOUR) end
    if seconds >= HOUR then return string.format("%dh %dm", seconds / HOUR, (seconds % HOUR) / 60) end
    return string.format("%dm", math.max(1, math.floor(seconds / 60)))
end

-- The chat line when one comes up, once each, for any character.
function ns.AnnounceReadyCooldowns()
    if not ns.Get("cooldownNotify") then return end
    local now = Now()
    for _, rec in pairs(Store() or {}) do
        if type(rec) == "table" and type(rec.spells) == "table" then
            rec.announced = rec.announced or {}
            for spellID, readyAt in pairs(rec.spells) do
                local t = TRACKED[spellID]
                if t and type(readyAt) == "number" and readyAt <= now and not rec.announced[spellID] then
                    rec.announced[spellID] = true
                    ns.Print(t.name .. " is ready on " .. tostring(rec.name or "?") .. ".")
                end
            end
        end
    end
end

function ns.CooldownsCommand(rest)
    local sub = tostring(rest or ""):lower():match("^%s*(%S*)")
    if sub == "probe" then
        probing = not probing
        wipe(probed)
        ns.Print(probing and "Probe on: cast a profession cooldown and the spell ID and what the game says "
            .. "about its cooldown are printed. |cffffd100/chair cooldowns probe|r again to stop."
            or "Probe off.")
        return
    end
    local all = ns.AllCooldowns()
    if #all == 0 then
        ns.Print("No profession cooldowns recorded yet. They are picked up when you cast one.")
        return
    end
    for _, char in ipairs(all) do
        ns.Print(char.name .. ":")
        for _, cd in ipairs(char.list) do
            print("    " .. cd.name .. ": " .. ns.CooldownLeftText(cd.left))
        end
    end
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "PLAYER_LOGIN" then
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(60, function() pcall(ns.AnnounceReadyCooldowns) end)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(10, function() pcall(ns.AnnounceReadyCooldowns) end)
        end
        return
    end
    if ns.Text(unit) ~= "player" then return end
    local id = ns.Num(spellID)
    if id then pcall(Record, id) end
end)
