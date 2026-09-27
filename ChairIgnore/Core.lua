-- ChairIgnore Core.lua
-- One ignore list for the whole account, with a reason and an optional expiry
-- for each player.
--
-- The game's own ignore list holds 50 names per character. ChairIgnore keeps
-- the full list itself and, with sync on, fills each character's game list
-- from it (newest first) and picks up anything you ignore or unignore the
-- normal way. Players past the 50 are still kept out of chat by the chat
-- filter (Filters.lua), which reads this list, not the game's.
--
-- Saved:
--   ChairIgnoreDB       account: the players, the chat filters
--   ChairIgnoreCharDB   this character: the switches, and which names this
--                       character's game list held last time it was read
--                       (how a name you unignored is told from one never added)

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairIgnore

ns.ICON = "Interface\\FriendsFrame\\Battlenet-Portrait"
ns.GAME_LIST_MAX = 50

-------------------------------------------------------------------------------
-- Safe values
-------------------------------------------------------------------------------
-- Chat senders and unit names can come back as secret values on this client:
-- they concatenate, then throw on the first comparison. Everything read from
-- the client goes through here first; nil means unreadable.

function ns.Text(value)
    if value == nil then return nil end
    local ok, text = pcall(function()
        local s = "" .. tostring(value)
        if s == "" then return nil end
        return s
    end)
    if ok then return text end
    return nil
end

local PREFIX = "|cff9d7cffChairIgnore|r:"
function ns.Print(...)
    local parts = { PREFIX }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = ns.Text((select(i, ...))) or "<unreadable>"
    end
    local ok, line = pcall(table.concat, parts, " ")
    print(ok and line or PREFIX .. " <unprintable message>")
end

local function Now()
    return (type(time) == "function" and time()) or 0
end
ns.Now = Now

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
-- Per character, like the rest of Chaircraft, and all off out of the box. The
-- master switch covers everything: sync, chat, filters and the menu entry.

ns.DEFAULTS = {
    enabled        = false,
    syncGameList   = true,   -- fill this character's game ignore list from ours
    hideListed     = true,   -- hide chat from anyone on the list
    filterPublic   = true,   -- trade, general and other channels
    filterSayYell  = true,
    filterWhisper  = true,
    filterGroup    = false,  -- party, raid, instance, guild, officer
    spareFriends   = true,   -- the chat filters never hide a friend or guildmate
    expireDays     = 0,      -- for new entries; 0 is never
}

function ns.Get(key)
    local char = _G.ChairIgnoreCharDB
    local settings = type(char) == "table" and char.settings or nil
    if settings and settings[key] ~= nil then return settings[key] end
    return ns.DEFAULTS[key]
end

function ns.Set(key, value)
    if type(_G.ChairIgnoreCharDB) ~= "table" then return end
    _G.ChairIgnoreCharDB.settings = _G.ChairIgnoreCharDB.settings or {}
    _G.ChairIgnoreCharDB.settings[key] = value
    if ns.OnSettingChanged then ns.OnSettingChanged(key, value) end
end

-- A switch that only counts while ChairIgnore itself is on.
function ns.On(key)
    return ns.Get("enabled") == true and (key == nil or ns.Get(key) == true)
end

-------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------
-- Every player is stored as "Name-Realm", the realm without spaces, which is
-- how chat names them. A name typed or read without a realm is on yours.

local function HomeRealm()
    local realm = ns.Text(type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName())
    if not realm and type(GetRealmName) == "function" then
        realm = ns.Text(GetRealmName())
        realm = realm and realm:gsub("[%s%-]", "")
    end
    return realm or ""
end
ns.HomeRealm = HomeRealm

-- Forever names are a first and a last name with a space between them
-- ("Chairface Chippendale"), and chat gives them with the realm after a
-- hyphen: "Chairface Chippendale-Realm". A realm is stored without spaces
-- or hyphens, so the realm is whatever follows the last hyphen.
--
-- "chairface chippendale", "Chairface  Chippendale-Some Realm"
--   -> "Chairface Chippendale-HomeRealm", "Chairface Chippendale-SomeRealm".
-- nil for anything that is not a name: "Arthas" has no surname.
function ns.FullName(name, realm)
    name = ns.Text(name)
    if not name then return nil end
    name = name:match("^%s*(.-)%s*$"):gsub("%s+", " ")
    local base, fromName = name:match("^(.-)%-([^%-]+)$")
    if base then name, realm = base:match("^%s*(.-)%s*$"), fromName end
    -- Every Forever name is a first name and a surname, each 2 to 12
    -- letters, with one space between. Anything else is not a player (the
    -- client's "Unknown" placeholder included).
    local first, last = name:match("^(%S+) (%S+)$")
    if not first or first:find("[%d%p]") or last:find("[%d%p]") then return nil end
    local function Letters(word)
        -- Characters, not bytes: an accented letter is two bytes.
        return select(2, word:gsub("[^\128-\191]", ""))
    end
    local a, b = Letters(first), Letters(last)
    if a < 2 or a > 12 or b < 2 or b > 12 then return nil end
    realm = ns.Text(realm)
    realm = (realm and realm:gsub("[%s%-]", "")) or ""
    if realm == "" then realm = HomeRealm() end
    -- Typed all in lowercase: each word's first letter up. Anything else is
    -- kept as given, since a name like "McRae" has capitals of its own.
    if name == name:lower() then
        name = name:gsub("(%a)(%S*)", function(first, rest) return first:upper() .. rest end)
    end
    return name .. "-" .. realm
end

-- The lookup key: case-blind.
local function Key(full)
    return full and full:lower() or nil
end
ns.Key = Key

-- "Arthas-HomeRealm" -> "Arthas", for names on your own realm.
function ns.ShortName(full)
    local name, realm = tostring(full or ""):match("^(.-)%-([^%-]+)$")
    if name and realm:lower() == HomeRealm():lower() then return name end
    return full
end

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

local function DB()
    return _G.ChairIgnoreDB
end

function ns.Players()
    local db = DB()
    return type(db) == "table" and db.players or {}
end

function ns.Find(name)
    local key = Key(ns.FullName(name))
    return key and ns.Players()[key] or nil
end

function ns.IsListed(name)
    return ns.Find(name) ~= nil
end

-- Sorted for showing: newest first.
function ns.SortedPlayers()
    local out = {}
    for _, entry in pairs(ns.Players()) do out[#out + 1] = entry end
    table.sort(out, function(a, b)
        if (a.added or 0) ~= (b.added or 0) then return (a.added or 0) > (b.added or 0) end
        return a.name < b.name
    end)
    return out
end

function ns.Count()
    local n = 0
    for _ in pairs(ns.Players()) do n = n + 1 end
    return n
end

local function Changed()
    if ns.RefreshWindow then ns.RefreshWindow() end
end

-- Returns the entry, or nil and why not.
function ns.Add(name, note, days)
    local db = DB()
    if type(db) ~= "table" then return nil, "not loaded yet" end
    local full = ns.FullName(name)
    if not full then return nil, "that is not a player name" end
    if Key(full) == Key(ns.FullName(ns.Text(UnitName and UnitName("player")))) then
        return nil, "you cannot ignore yourself"
    end
    local key = Key(full)
    local entry = db.players[key]
    if not entry then
        entry = { name = full, added = Now() }
        db.players[key] = entry
    end
    if note ~= nil then entry.note = (note ~= "" and note) or nil end
    days = tonumber(days)
    if days == nil then days = tonumber(ns.Get("expireDays")) or 0 end
    ns.SetExpiry(full, days)
    if ns.On("syncGameList") then ns.SyncGameList() end
    Changed()
    return entry
end

function ns.Remove(name)
    local db = DB()
    local full = ns.FullName(name)
    local key = Key(full)
    if not (type(db) == "table" and key and db.players[key]) then return false end
    local entry = db.players[key]
    db.players[key] = nil
    if ns.On("syncGameList") then ns.RemoveFromGameList(entry.name) end
    Changed()
    return true
end

function ns.SetNote(name, note)
    local entry = ns.Find(name)
    if not entry then return false end
    entry.note = (note and note ~= "") and note or nil
    Changed()
    return true
end

-- Days from now; 0 or less clears it.
function ns.SetExpiry(name, days)
    local entry = ns.Find(name)
    if not entry then return false end
    days = tonumber(days) or 0
    entry.expires = (days > 0) and (Now() + math.floor(days * 86400)) or nil
    Changed()
    return true
end

-- Takes out everyone whose time is up. Returns how many.
function ns.PruneExpired()
    local now, gone = Now(), {}
    for _, entry in pairs(ns.Players()) do
        if entry.expires and entry.expires <= now then gone[#gone + 1] = entry.name end
    end
    for _, name in ipairs(gone) do ns.Remove(name) end
    return #gone
end

-------------------------------------------------------------------------------
-- The game's own list
-------------------------------------------------------------------------------

local FL = function() return _G.C_FriendList end

-- What ChairIgnore has seen of the game's list this session, for
-- /chair ignore status: which calls it is watching, how many ignores it saw
-- go through them, how many list updates arrived.
ns.probe = { hooks = {}, calls = 0, updates = 0 }

-- ChairIgnore's own calls into the game's list, told apart from yours so
-- they are never taken for an ignore to ask about.
local ownCall = false
local function OwnCall(fn, ...)
    ownCall = true
    local ok = pcall(fn, ...)
    ownCall = false
    return ok
end

-- What this character's game list holds now: key -> full name.
local function GameList()
    local fl, out = FL(), {}
    if not (fl and fl.GetNumIgnores and fl.GetIgnoreName) then return nil end
    local okN, count = pcall(fl.GetNumIgnores)
    count = okN and tonumber(count) or 0
    for i = 1, count do
        local ok, name = pcall(fl.GetIgnoreName, i)
        local full = ok and ns.FullName(name)
        -- The client names a player it has not heard from yet "Unknown":
        -- not a name, and never to be taken as one.
        if full and not full:match("^Unknown%-") then out[Key(full)] = full end
    end
    return out, count
end
ns.GameList = GameList

-- The game wants "Name" for your own realm, "Name-Realm" for another.
local function GameName(full)
    return ns.ShortName(full)
end

function ns.RemoveFromGameList(full)
    local fl = FL()
    local current = GameList()
    if not (fl and fl.DelIgnore and current and current[Key(full)]) then return end
    ns.expectSystem = (ns.expectSystem or 0) + 1
    OwnCall(fl.DelIgnore, GameName(full))
end

-- Two-way: first what changed on the game list since it was last read (you
-- used /ignore, /unignore or the game's menus), then filling its free slots
-- from ours, newest first.
function ns.SyncGameList()
    local fl, char = FL(), _G.ChairIgnoreCharDB
    if not (fl and fl.AddIgnore and type(char) == "table" and type(DB()) == "table") then return end
    local current, count = GameList()
    if not current then return end
    local seen = char.gameList or {}
    local players = ns.Players()

    -- Anyone ignored the normal way (the game's own right-click Ignore,
    -- /ignore) comes onto ChairIgnore's list. After the very first read,
    -- which only takes in what the game list already held, each one is
    -- asked about: the reason prompt opens for them.
    local picked = {}
    for key, full in pairs(current) do
        if not seen[key] and not players[key] then
            players[key] = { name = full, added = Now() }
            if char.gameListRead then
                picked[#picked + 1] = full
                local days = tonumber(ns.Get("expireDays")) or 0
                if days > 0 then players[key].expires = Now() + math.floor(days * 86400) end
            end
        end
    end
    -- Only names this character's list really held last time: a name that
    -- could not be added (the list was full) never counts as unignored.
    if char.gameListRead then
        for key in pairs(seen) do
            if not current[key] and players[key] then players[key] = nil end
        end
    end

    -- What was read is what is remembered. A name asked for here only counts
    -- once the game's list is read back holding it, so one the server
    -- refuses (no such player) is never later taken for one you unignored.
    -- Each is asked for once a session, so a refusal is not repeated on
    -- every update.
    ns.asked = ns.asked or {}
    local free = ns.Get("syncGameList") and (ns.GAME_LIST_MAX - (count or 0)) or 0
    for _, entry in ipairs(ns.SortedPlayers()) do
        if free <= 0 then break end
        local key = Key(entry.name)
        if not current[key] and not ns.asked[key] then
            ns.asked[key] = true
            ns.expectSystem = (ns.expectSystem or 0) + 1
            if OwnCall(fl.AddIgnore, GameName(entry.name)) then free = free - 1 end
        end
    end

    char.gameList = current
    char.gameListRead = true
    Changed()
    if ns.OnIgnoredNormally then
        for _, full in ipairs(picked) do ns.OnIgnoredNormally(full) end
    end
end

-- Ignoring the normal way, seen as it happens. The game's right-click
-- Ignore and /ignore both end in a C_FriendList call carrying the name, and
-- hooksecurefunc watches those calls without touching them. This does not
-- depend on the game's list being readable afterwards, which the sync above
-- does.

local function PickUp(name)
    local full = ns.FullName(name)
    if not full then return end
    local players, key = ns.Players(), Key(full)
    if players[key] then return end
    players[key] = { name = full, added = Now() }
    local days = tonumber(ns.Get("expireDays")) or 0
    if days > 0 then players[key].expires = Now() + math.floor(days * 86400) end
    Changed()
    if ns.OnIgnoredNormally then ns.OnIgnoredNormally(full) end
end

local function DropOff(name)
    local key = Key(ns.FullName(name))
    local players = ns.Players()
    if key and players[key] then
        players[key] = nil
        Changed()
    end
end

-- The game's "is this player ignored", or nil when it will not say.
local function GameSaysIgnored(name)
    local fl = FL()
    if not (fl and fl.IsIgnored) then return nil end
    local ok, answer = pcall(fl.IsIgnored, name)
    if ok and (answer == true or answer == false) then return answer end
    return nil
end

-- A call reached through two names (a global that forwards to
-- C_FriendList) is one ignore, not two.
local lastSeen = {}
local function Seen(name)
    local now = (type(GetTime) == "function" and GetTime()) or 0
    local key = Key(ns.FullName(name)) or tostring(name)
    if lastSeen[key] and now - lastSeen[key] < 1 then return true end
    lastSeen[key] = now
    return false
end

local function Watching(name)
    if ownCall or not ns.On() then return nil end
    local text = ns.Text(name)
    ns.probe.calls = ns.probe.calls + 1
    ns.probe.last = text or "<unreadable>"
    if not text or Seen(text) then return nil end
    return text
end

local function OnAdd(name)
    name = Watching(name)
    if name then PickUp(name) end
end

local function OnDel(name)
    name = Watching(name)
    if name then DropOff(name) end
end

-- AddOrDelIgnore flips it: ignore if not ignored, unignore if it was. Which
-- one happened is only known once the server has answered, so it is looked
-- at a moment later. If the game will not say, ChairIgnore's own list
-- decides: listed means this was the unignore.
local function OnToggle(name)
    name = Watching(name)
    if not name then return end
    local listedBefore = ns.IsListed(name)
    local function Decide()
        local ignored = GameSaysIgnored(name)
        ns.probe.lastAnswer = ignored
        if ignored == nil then ignored = not listedBefore end
        if ignored then PickUp(name) else DropOff(name) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(1, Decide) else Decide() end
end

local function Hook(owner, ownerName, key, fn)
    if type(hooksecurefunc) ~= "function" or type(owner) ~= "table" or type(owner[key]) ~= "function" then
        return
    end
    local ok = (owner == _G) and pcall(hooksecurefunc, key, fn) or pcall(hooksecurefunc, owner, key, fn)
    if ok then ns.probe.hooks[#ns.probe.hooks + 1] = ownerName .. key end
end

do
    local fl = FL()
    Hook(fl, "C_FriendList.", "AddIgnore", OnAdd)
    Hook(fl, "C_FriendList.", "DelIgnore", OnDel)
    Hook(fl, "C_FriendList.", "AddOrDelIgnore", OnToggle)
    Hook(_G, "", "AddIgnore", OnAdd)
    Hook(_G, "", "DelIgnore", OnDel)
    Hook(_G, "", "AddOrDelIgnore", OnToggle)
end

-- The game says "X is now being ignored" once per name it adds. A first sync
-- can add fifty, so the lines ChairIgnore caused are hidden (and only those).
local function SystemPatterns()
    local out = {}
    for _, key in ipairs({ "ERR_IGNORE_ADDED_S", "ERR_IGNORE_REMOVED_S", "ERR_IGNORE_ALREADY_S" }) do
        local format = ns.Text(_G[key])
        if format then
            -- Every magic character escaped, "%" included, so the "%s" in the
            -- format arrives as "%%s" and becomes the name's ".+".
            local escaped = format:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
            out[#out + 1] = "^" .. escaped:gsub("%%%%s", ".+") .. "$"
        end
    end
    return out
end

function ns.IsSyncMessage(message)
    if (ns.expectSystem or 0) <= 0 then return false end
    local text = ns.Text(message)
    if not text then return false end
    for _, pattern in ipairs(SystemPatterns()) do
        if text:match(pattern) then
            ns.expectSystem = ns.expectSystem - 1
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Commands: /chair ignore ...
-------------------------------------------------------------------------------

local function Command(input)
    input = tostring(input or "")
    local verb, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    verb = (verb or ""):lower()
    if verb == "" then
        local part = Chaircraft.FindPart("ignore")
        if part and part.Open then part.Open() end
    elseif verb == "add" then
        -- Names have spaces in them, so the reason comes after a colon:
        -- "add Chairface Chippendale: spams trade".
        local name, note = rest:match("^([^:]+):%s*(.*)$")
        name = name or rest
        local entry, why = ns.Add(name, (note and note ~= "") and note or nil)
        if entry then ns.Print(entry.name, "is on the list.") else ns.Print("Not added:", why .. ".") end
    elseif verb == "remove" or verb == "del" then
        if ns.Remove(rest) then ns.Print(ns.FullName(rest), "is off the list.")
        else ns.Print("Not on the list:", rest) end
    elseif verb == "list" then
        local players = ns.SortedPlayers()
        ns.Print(#players .. " on the list.")
        for _, entry in ipairs(players) do
            print("  " .. entry.name .. (entry.note and ("  |cff808080" .. entry.note .. "|r") or ""))
        end
    elseif verb == "sync" then
        ns.SyncGameList()
        ns.Print("Synced with this character's ignore list.")
    elseif verb == "status" then
        local function YesNo(v) return v and "|cff55ff55yes|r" or "|cffff5555no|r" end
        local game = GameList()
        local gameCount = 0
        for _ in pairs(game or {}) do gameCount = gameCount + 1 end
        ns.Print("status")
        print("  turned on: " .. YesNo(ns.Get("enabled")))
        print("  keep the game's list in step: " .. YesNo(ns.Get("syncGameList")))
        print("  on the list: " .. ns.Count() .. ", on this character's game list: "
            .. (game and gameCount or "unreadable"))
        print("  hide chat from the list: " .. YesNo(ns.Get("hideListed"))
            .. ", chat filters switched on: " .. ns.FiltersOn())
        local fl = FL()
        local okN, raw = pcall(function() return fl and fl.GetNumIgnores and fl.GetNumIgnores() end)
        local probe = ns.probe
        print("  watching: " .. (#probe.hooks > 0 and table.concat(probe.hooks, ", ") or "|cffff5555nothing|r"))
        print("  this session: " .. probe.calls .. " ignore call(s) seen"
            .. (probe.last and (" (last: " .. probe.last .. ", game said ignored: "
                .. tostring(probe.lastAnswer) .. ")") or "")
            .. ", " .. probe.updates .. " list update(s)"
            .. ", game's own count: " .. tostring(okN and ns.Text(raw) or "unreadable"))
    else
        ns.Print("|cffffd100/chair ignore|r opens the window. Also: |cffffd100add|r <name>[: reason], "
            .. "|cffffd100remove|r <name>, |cffffd100list|r, |cffffd100sync|r, |cffffd100status|r.")
    end
end

-- Registered for /chair to forward to, with no slash command of its own.
if SlashCmdList then SlashCmdList.CHAIRIGNORE = Command end

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

local function InitDB()
    if type(_G.ChairIgnoreDB) ~= "table" then _G.ChairIgnoreDB = {} end
    local db = _G.ChairIgnoreDB
    db.players = type(db.players) == "table" and db.players or {}
    if type(_G.ChairIgnoreCharDB) ~= "table" then _G.ChairIgnoreCharDB = {} end
    local char = _G.ChairIgnoreCharDB
    char.settings = type(char.settings) == "table" and char.settings or {}
    if ns.InitFilters then ns.InitFilters(db) end
end
ns.InitDB = InitDB

local driver = CreateFrame("Frame")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("IGNORELIST_UPDATE")
driver:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" and arg == suiteName then
        InitDB()
        ns.loaded = true
    elseif event == "PLAYER_LOGIN" then
        if not ns.loaded then InitDB() ns.loaded = true end
        if ns.On() then ns.PruneExpired() end
        if ns.ApplyChat then ns.ApplyChat() end
        -- The game list can still be empty this early. IGNORELIST_UPDATE
        -- syncs when it arrives; this covers a client that sent it before
        -- login, or not at all.
        if C_Timer and C_Timer.After then
            C_Timer.After(5, function()
                if ns.On() then pcall(ns.SyncGameList) end
            end)
        end
    elseif event == "IGNORELIST_UPDATE" then
        ns.probe.updates = ns.probe.updates + 1
        if ns.On() and not ns.syncing then
            ns.syncing = true
            local ok, err = pcall(ns.SyncGameList)
            ns.syncing = false
            if not ok then ns.Print("|cffff5555Sync failed:|r", err) end
        end
    end
end)

function ns.OnSettingChanged(key)
    if key == "enabled" or key == "syncGameList" then
        if ns.On() then ns.SyncGameList() end
    end
    if ns.ApplyChat then ns.ApplyChat() end
    Changed()
end
