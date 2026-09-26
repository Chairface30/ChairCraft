-- ChairPlus OSD.lua
-- The on-screen display: one line of small items -- money, free bag slots,
-- durability, ammo, soul shards, coordinates, XP, the time, frame rate and
-- latency, the session, pet, mail and friends, and other addons' feeds --
-- each switched on or off on its own and drawn in the order set on the OSD
-- page of the menu.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

-- Inline texture escapes. The two numbers after the path are height and width;
-- the coin art is square so both take the font size and the line grows with it.
-- The bag icon carries the usual icon border, so it gets the extra four texture
-- coordinates that crop it away -- 5/64 in from each edge.
local COIN = {
    { key = "gold",   tex = "Interface\\MoneyFrame\\UI-GoldIcon" },
    { key = "silver", tex = "Interface\\MoneyFrame\\UI-SilverIcon" },
    { key = "copper", tex = "Interface\\MoneyFrame\\UI-CopperIcon" },
}
local BAG_ICON = "Interface\\ICONS\\INV_Misc_Bag_08"
-- A visibly different bag, so the two counts cannot be read as one number split
-- in half. Swap the path if you would rather have something else.
local PROFESSION_BAG_ICON = "Interface\\ICONS\\INV_Misc_Bag_09"

local frame, backdrop
local dirty = false

-------------------------------------------------------------------------------
-- Reading the numbers
-------------------------------------------------------------------------------

-- Money is the one value in this addon most likely to come back secret, and it
-- is read straight into a string.format every update, so it is laundered here
-- and never touched raw. nil means the client would not let us read it, which
-- the display shows honestly rather than printing a confident zero.
local function GetMoneyParts()
    local getMoney = _G.GetMoney
    if type(getMoney) ~= "function" then return nil end
    local ok, raw = pcall(getMoney)
    if not ok then return nil end
    local money = ns.Num(raw)
    if not money then return nil end
    if money < 0 then money = 0 end
    local gold = math.floor(money / 10000)
    local silver = math.floor((money % 10000) / 100)
    local copper = money % 100
    return gold, silver, copper
end

-- What kind of bag is in this slot, and did we find out from the bag itself?
--
-- The obvious source is the second return of GetContainerNumFreeSlots, and it
-- is the wrong one. It describes the *slot*, not what is in it, so an empty
-- reagent or profession slot can answer with a real family and zero free slots
-- -- which is exactly how the display came to show a profession count of 0
-- while the actual profession bag's free slots were being added to the general
-- count instead.
--
-- So ask the equipped bag what it is. A bag is an item; the item knows its own
-- family, and an empty slot has no item and is therefore generic, which is the
-- honest answer. The free-slot return is kept only as a fallback for a client
-- where the item route is unavailable.
--
-- The item ID of the bag equipped in a slot, or nil for the backpack and for
-- any slot that is empty or cannot be resolved.
local function EquippedBagID(bag)
    if bag == 0 then return nil, "backpack" end

    local toInventory = ns.ContainerIDToInventoryID
    local getInvItem = _G.GetInventoryItemID
    if type(toInventory) ~= "function" or type(getInvItem) ~= "function" then
        return nil, "noapi"
    end

    local okSlot, invSlot = pcall(toInventory, bag)
    if not okSlot or not invSlot then return nil, "noslot" end

    local okItem, itemID = pcall(getInvItem, "player", invSlot)
    if not okItem then return nil, "noitem" end
    if not itemID then return nil, "empty" end

    return ns.Num(itemID), "item"
end

-- Is the bag in this slot a profession bag?
--
-- Decided from the bag item's own class, not from the bag family. The family
-- route needs GetItemFamily, which this client does not appear to have, and the
-- previous version of this function required it for the whole branch -- so one
-- missing API silently sent every bag back to the slot's own claim, which is
-- the wrong answer and the reason the count stayed broken.
--
-- GetItemInfo is used instead because it demonstrably works here: the vendor
-- code reads item class and price through it on every merchant visit.
--
--   classID 1  = Container. subclass 0 is a plain bag; every other subclass is
--                a profession bag (herb, enchanting, mining, and so on).
--   classID 11 = Quiver / Ammo pouch. Always specialist.
local function IsProfessionBag(bag)
    local itemID = EquippedBagID(bag)

    if not itemID then
        -- No bag, or no way to tell what bag. Either way it is not treated as a
        -- profession bag: a slot that cannot be identified must never invent a
        -- profession count, which is what produced a standing "0" on screen.
        return false
    end

    local getInfo = ns.GetItemInfo
    if type(getInfo) == "function" then
        local ok, classID, subclassID = pcall(function()
            local a, b, c, d, e, f, g, h, i, j, k, class, subclass = getInfo(itemID)
            return class, subclass
        end)
        if ok then
            classID = ns.Num(classID)
            subclassID = ns.Num(subclassID)
            if classID == 11 then
                return true
            elseif classID == 1 then
                return (subclassID or 0) ~= 0
            elseif classID ~= nil then
                return false
            end
        end
    end

    -- Secondary: the item's family, where the client offers it.
    local getFamily = ns.GetItemFamily
    if type(getFamily) == "function" then
        local ok, family = pcall(getFamily, itemID)
        if ok then
            family = ns.Num(family) or 0
            return family ~= 0
        end
    end

    -- Last resort: the slot's own claim. Only consulted for a slot we know has
    -- a bag in it, so an empty slot can no longer speak.
    local getFree = ns.GetContainerNumFreeSlots
    if type(getFree) == "function" then
        local ok, _, family = pcall(getFree, bag)
        if ok then
            family = ns.Num(family) or 0
            return family ~= 0
        end
    end

    return false
end
ns.IsProfessionBag = IsProfessionBag

-- Free slots across the bags, counted in two piles.
--
-- The two are never added together. A herb bag with eleven slots free does not
-- mean there is room for the sword that just dropped, so rolling it into the
-- general count produces a number that is arithmetically true and useless at
-- the moment you actually look at it -- standing over a corpse deciding whether
-- to loot. Kept apart, each number answers its own question.
--
-- Returns: free general slots, free specialist slots, whether any specialist
-- bag is equipped at all.
local function GetFreeSlots()
    local getFree = ns.GetContainerNumFreeSlots
    if type(getFree) ~= "function" then return nil end

    local last = ns.LAST_BAG or 4
    if ns.REAGENT_BAG and ns.REAGENT_BAG > last then last = ns.REAGENT_BAG end

    local general, special = 0, 0
    local generalTotal, specialTotal = 0, 0
    local sawAny, sawSpecial = false, false
    local getSlots = ns.GetContainerNumSlots

    for bag = 0, last do
        local ok, free = pcall(getFree, bag)
        if ok then
            free = ns.Num(free)
            if free then
                sawAny = true
                local size = 0
                if type(getSlots) == "function" then
                    local okS, n = pcall(getSlots, bag)
                    size = okS and ns.Num(n) or 0
                end
                if IsProfessionBag(bag) then
                    special = special + free
                    specialTotal = specialTotal + size
                    -- Only a bag that is actually there counts as "there is a
                    -- profession bag to report". A typed but empty slot must
                    -- not make the count appear at all.
                    sawSpecial = true
                else
                    general = general + free
                    generalTotal = generalTotal + size
                end
            end
        end
    end

    if not sawAny then return nil end
    return general, special, sawSpecial, generalTotal, specialTotal
end

-- "12", or "12/80" with the bag total setting on.
local function SlotsText(free, total)
    local text = free and string.format("%d", free) or "--"
    if free and ns.Get("osdBagsTotal") and total and total > 0 then
        text = text .. string.format("/%d", total)
    end
    return text
end

-------------------------------------------------------------------------------
-- Building the line
-------------------------------------------------------------------------------

local function Segment(tex, amount, size, crop)
    local icon
    if crop then
        icon = string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", tex, size, size)
    else
        icon = string.format("|T%s:%d:%d:0:0|t", tex, size, size)
    end
    local text = amount and string.format("%d", amount) or "--"
    return icon .. " " .. text
end

-- Plain text in a colour, for the items that go red when they matter.
local function Coloured(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

local function IconOnly(tex, size, crop)
    if crop then
        return string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", tex, size, size)
    end
    return string.format("|T%s:%d:%d:0:0|t", tex, size, size)
end

-- The lowest durability of anything worn, as a percentage, or nil when
-- nothing worn has durability (or the client will not say).
local function LowestDurability()
    local get = _G.GetInventoryItemDurability
    if type(get) ~= "function" then return nil end
    local lowest
    for slot = 1, 19 do
        local ok, current, maximum = pcall(get, slot)
        current, maximum = ok and ns.Num(current), ok and ns.Num(maximum)
        if current and maximum and maximum > 0 then
            local pct = current / maximum * 100
            if not lowest or pct < lowest then lowest = pct end
        end
    end
    return lowest
end

-- The ammo slot is inventory slot 0 on the clients that have one.
local AMMO_SLOT = 0

local SOUL_SHARD = 6265

local function PlayerCoords()
    local map = _G.C_Map
    if not map then return nil end
    local okM, mapID = pcall(map.GetBestMapForUnit, "player")
    mapID = okM and ns.Num(mapID) or nil
    if not mapID then return nil end
    local okP, pos = pcall(map.GetPlayerMapPosition, mapID, "player")
    if not okP or not pos then return nil end
    local x, y
    if pos.GetXY then
        local ok, a, b = pcall(pos.GetXY, pos)
        if ok then x, y = a, b end
    end
    if x == nil then x, y = pos.x, pos.y end
    x, y = ns.Num(x), ns.Num(y)
    -- Inside an instance the client answers 0, 0 rather than nothing.
    if not x or not y or (x == 0 and y == 0) then return nil end
    return x * 100, y * 100
end

-------------------------------------------------------------------------------
-- The clock and the alarm
-------------------------------------------------------------------------------

-- Hours and minutes now: the realm's, or this computer's.
local function TimeNow(server)
    if server then
        local ok, h, m = pcall(_G.GetGameTime)
        h, m = ok and ns.Num(h), ok and ns.Num(m)
        if h and m then return h, m end
        return nil
    end
    local ok, t = pcall(date, "*t")
    if ok and type(t) == "table" then return ns.Num(t.hour), ns.Num(t.min) end
    return nil
end

-- "07:05" or "7:05 AM", by the OSD's 24-hour setting.
local function FormatTime(h, m)
    if not h or not m then return nil end
    if ns.Get("osdClock24") then return string.format("%02d:%02d", h, m) end
    local suffix = h < 12 and "AM" or "PM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m, suffix)
end
ns.FormatClock = FormatTime

local function CVar(name)
    local cvars = _G.C_CVar
    if cvars and type(cvars.GetCVar) == "function" then
        local ok, value = pcall(cvars.GetCVar, name)
        if ok and value ~= nil then return value end
    end
    local ok, value = pcall(_G.GetCVar, name)
    return ok and value or nil
end

-- The in-game alarm, as Blizzard's clock (the Time Manager) keeps it: on or
-- off, and the time as minutes after midnight, in whichever of realm or local
-- time that clock is set to. nil when this client keeps no alarm at all.
function ns.AlarmTime()
    local minutes = tonumber(CVar("timeMgrAlarmTime") or "")
    if not minutes then return nil end
    local enabled = tostring(CVar("timeMgrAlarmEnabled") or "0") == "1"
    local message = ns.Text(CVar("timeMgrAlarmMessage"))
    return enabled, math.floor(minutes / 60) % 24, minutes % 60, message
end

-- The alarm's message, cut short so a long one cannot take over the line, and
-- with any | doubled so it cannot be read as a colour or texture code.
local function AlarmMessage(message)
    if not message or message == "" then return nil end
    if #message > 24 then message = message:sub(1, 23) .. "..." end
    return (message:gsub("|", "||"))
end

-- Open Blizzard's clock window, where the alarm is set. It loads on demand.
function ns.OpenAlarm()
    if not _G.TimeManagerFrame then
        local addons = _G.C_AddOns
        local load = (addons and addons.LoadAddOn) or _G.LoadAddOn
        if type(load) == "function" then pcall(load, "Blizzard_TimeManager") end
    end
    if type(_G.TimeManager_Toggle) == "function" and pcall(_G.TimeManager_Toggle) then
        return true
    end
    local frame = _G.TimeManagerFrame
    if frame then
        if frame:IsShown() then frame:Hide() else frame:Show() end
        return true
    end
    ns.Print("This client has no in-game clock window to set an alarm in.")
    return false
end

-------------------------------------------------------------------------------
-- The session: how long, and how much gold
-------------------------------------------------------------------------------
-- Kept in ChairPlusDB rather than in a local, so a /reload carries on the same
-- session instead of starting a new one. A new session starts at login, and
-- whenever the stored one belongs to a different character.

local sessionWatch = CreateFrame("Frame")

-- Wall-clock seconds, which survive a /reload where GetTime's would not
-- line up with a stored start.
local function time()
    local ok, now = pcall(_G.time)
    now = ok and ns.Num(now) or nil
    if now then return now end
    local okT, t = pcall(_G.GetTime)
    return okT and ns.Num(t) or 0
end

local function SessionStore()
    local db = _G.ChairPlusDB
    if type(db) ~= "table" then return nil end
    if type(db.sessions) ~= "table" then db.sessions = {} end
    local ok, guid = pcall(_G.UnitGUID, "player")
    guid = ok and ns.Text(guid) or "player"
    if type(db.sessions[guid]) ~= "table" then db.sessions[guid] = {} end
    return db.sessions[guid]
end

local function ReadMoney()
    local ok, raw = pcall(_G.GetMoney)
    return ok and ns.Num(raw) or nil
end

local function StartSession(keepTime)
    local store = SessionStore()
    if not store then return end
    if not keepTime then store.start = time() end
    store.money = ReadMoney()
end

-- Money this session, in copper, or nil before a baseline could be read.
function ns.SessionGold()
    local store = SessionStore()
    if not store then return nil end
    local now = ReadMoney()
    if not now then return nil end
    if not ns.Num(store.money) then store.money = now end
    return now - store.money
end

-- Seconds since the session started.
function ns.SessionSeconds()
    local store = SessionStore()
    if not store then return nil end
    if not ns.Num(store.start) then store.start = time() end
    return math.max(0, time() - store.start)
end

-- Start counting gold again from what is in the bags now.
function ns.ResetSessionGold()
    StartSession(true)
    ns.RefreshOSD()
end

sessionWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
sessionWatch:SetScript("OnEvent", function(_, _, isLogin, isReload)
    local store = SessionStore()
    if not store then return end
    -- A client that sends neither flag: only start one when there is none.
    if isLogin or not ns.Num(store.start) then StartSession(false) end
end)

-- "1:02:03", or "2:03" under an hour.
local function Duration(seconds)
    seconds = math.floor(seconds)
    local h, m, s = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- Copper as coins, dropping the empty larger ones: "3g 2s 1c" as icons.
local function Coins(copper, size)
    copper = math.floor(math.abs(copper))
    local parts = {}
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if gold > 0 then parts[#parts + 1] = Segment(COIN[1].tex, gold, size, false) end
    if gold > 0 or silver > 0 then parts[#parts + 1] = Segment(COIN[2].tex, silver, size, false) end
    parts[#parts + 1] = Segment(COIN[3].tex, rest, size, false)
    return table.concat(parts, " ")
end

-------------------------------------------------------------------------------
-- Pet, mail and friends
-------------------------------------------------------------------------------

local HAPPINESS = {
    [1] = { "Unhappy", 1, 0.2, 0.2, 48 },
    [2] = { "Content", 1, 0.82, 0, 24 },
    [3] = { "Happy", 0.3, 1, 0.3, 0 },
}
local HAPPINESS_TEX = "Interface\\PetPaperDollFrame\\UI-PetHappiness"

local function IsHunter()
    local ok, _, class = pcall(_G.UnitClass, "player")
    return ok and ns.Text(class) == "HUNTER"
end

-- Happiness (1-3), damage percentage and loyalty rate, or nil without a pet.
local function PetHappiness()
    local okE, exists = pcall(_G.UnitExists, "pet")
    if not (okE and exists) then return nil end
    if type(_G.GetPetHappiness) ~= "function" then return nil end
    local ok, happy, damage, loyalty = pcall(_G.GetPetHappiness)
    if not ok then return nil end
    return ns.Num(happy), ns.Num(damage), ns.Num(loyalty)
end

local function PetHealthPct()
    local okH, hp = pcall(_G.UnitHealth, "pet")
    local okM, max = pcall(_G.UnitHealthMax, "pet")
    hp, max = okH and ns.Num(hp), okM and ns.Num(max)
    if not hp or not max or max <= 0 then return nil end
    return hp / max * 100
end

local function HasMail()
    local ok, has = pcall(_G.HasNewMail)
    return ok and has and true or false
end

-- Online friends, as names, and how many. Both friend list APIs are tried:
-- this client could answer to either generation.
local function OnlineFriends()
    local names = {}
    local list = _G.C_FriendList
    if list and type(list.GetNumFriends) == "function" and type(list.GetFriendInfoByIndex) == "function" then
        local ok, count = pcall(list.GetNumFriends)
        for i = 1, (ok and ns.Num(count) or 0) do
            local okI, info = pcall(list.GetFriendInfoByIndex, i)
            if okI and type(info) == "table" and info.connected then
                names[#names + 1] = { ns.Text(info.name) or "?", ns.Num(info.level), ns.Text(info.area) }
            end
        end
    elseif type(_G.GetNumFriends) == "function" and type(_G.GetFriendInfo) == "function" then
        local ok, count = pcall(_G.GetNumFriends)
        for i = 1, (ok and ns.Num(count) or 0) do
            local okI, name, level, _, area, connected = pcall(_G.GetFriendInfo, i)
            if okI and connected then
                names[#names + 1] = { ns.Text(name) or "?", ns.Num(level), ns.Text(area) }
            end
        end
    end
    local bnet = 0
    if type(_G.BNGetNumFriends) == "function" then
        local ok, _, online = pcall(_G.BNGetNumFriends)
        bnet = ok and ns.Num(online) or 0
    end
    return names, bnet
end

-- Online guildmates, as names; nil when not in a guild.
local function OnlineGuild()
    local okG, inGuild = pcall(_G.IsInGuild)
    if not (okG and inGuild) then return nil end
    local names = {}
    local ok, total = pcall(_G.GetNumGuildMembers)
    for i = 1, (ok and ns.Num(total) or 0) do
        local okI, name, _, _, level, _, zone, _, _, online = pcall(_G.GetGuildRosterInfo, i)
        if okI and online then
            names[#names + 1] = { (ns.Text(name) or "?"):gsub("%-.*$", ""), ns.Num(level), ns.Text(zone) }
        end
    end
    return names
end

-- The server only sends the guild roster when asked, and throttles asking.
local function RequestRosters()
    local info = _G.C_GuildInfo
    local ask = (info and info.GuildRoster) or _G.GuildRoster
    if type(ask) == "function" then pcall(ask) end
    local list = _G.C_FriendList
    local show = (list and list.ShowFriends) or _G.ShowFriends
    if type(show) == "function" then pcall(show) end
end

local function AddPeople(tip, title, people)
    tip:AddLine(title, 1, 0.82, 0)
    for i, person in ipairs(people) do
        if i > 20 then
            tip:AddLine(string.format("  and %d more", #people - 20), 0.6, 0.6, 0.6)
            break
        end
        tip:AddDoubleLine("  " .. person[1] .. (person[2] and (" (" .. person[2] .. ")") or ""),
            person[3] or "", 1, 1, 1, 0.6, 0.6, 0.6)
    end
end

-- The player's base run speed, which 100% is measured against.
local BASE_SPEED = 7

-------------------------------------------------------------------------------
-- Chairface's Casino
-------------------------------------------------------------------------------
-- The casino publishes no data feed, so its lobby is asked directly: the same
-- question its own lobby buttons ask, "is any game past idle and not yet
-- settled". Its games only run inside a group, so a running table is one in
-- yours.

local CASINO_ICON = "Interface\\AddOns\\Chairfaces Casino\\Textures\\icon"
local CASINO_HOSTS = {
    blackjack = "Multiplayer", poker = "PokerMultiplayer", holdem = "HoldemMultiplayer",
    hilo = "HiLoMultiplayer", deathroll = "DeathRollMultiplayer", bingo = "BingoMultiplayer",
    roulette = "RouletteMultiplayer", liarsdice = "LiarsDiceMultiplayer", crash = "CrashMultiplayer",
}

local function CasinoLobby()
    local casino = _G.ChairfacesCasino
    local ui = type(casino) == "table" and casino.UI
    local lobby = type(ui) == "table" and ui.Lobby
    return type(lobby) == "table" and lobby or nil
end

-- The running game's name and its host, or nil when no table is up.
local function CasinoTable()
    local lobby = CasinoLobby()
    if not lobby or type(lobby.IsAnyGameActive) ~= "function" then return nil end
    local ok, active, key = pcall(lobby.IsAnyGameActive, lobby)
    if not (ok and active) then return nil end
    local name = key
    if type(lobby.GetGameName) == "function" then
        local okN, n = pcall(lobby.GetGameName, lobby, key)
        name = okN and ns.Text(n) or key
    end
    local mp = CASINO_HOSTS[key] and _G.ChairfacesCasino[CASINO_HOSTS[key]]
    local host = type(mp) == "table" and ns.Text(mp.currentHost) or nil
    return name and (name:gsub("|", "||")) or "A table", host and (host:gsub("%-.*$", "")) or nil
end

-------------------------------------------------------------------------------
-- Clicks and tooltips
-------------------------------------------------------------------------------
-- What the items do when clicked. Each game window is opened through
-- whichever call this client has, and a missing one is a shrug, not an error.

local function Try(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return false end
    return (pcall(fn, ...))
end

local function OpenBags()
    if not Try("ToggleAllBags") then Try("OpenAllBags") end
end

local function OpenMap()
    if Try("ToggleWorldMap") then return end
    local map = _G.WorldMapFrame
    if map then
        if map:IsShown() then map:Hide() else map:Show() end
    end
end

local function OpenCharacter(tab)
    Try("ToggleCharacter", tab or "PaperDollFrame")
end

-- A hidden tooltip to read item, buff and debuff text through, for the
-- speed tooltip. Lines come back as plain strings; one the client will not
-- let us read is skipped.
local scanTip
local function TipLines(method, ...)
    if not scanTip then
        local ok, tip = pcall(CreateFrame, "GameTooltip", "ChairPlusScanTip", nil, "GameTooltipTemplate")
        if not ok or not tip then return {} end
        scanTip = tip
    end
    local lines = {}
    if type(scanTip[method]) ~= "function" then return lines end
    pcall(scanTip.SetOwner, scanTip, UIParent, "ANCHOR_NONE")
    pcall(scanTip.ClearLines, scanTip)
    if not pcall(scanTip[method], scanTip, ...) then return lines end
    local okN, count = pcall(scanTip.NumLines, scanTip)
    for i = 1, (okN and ns.Num(count) or 0) do
        local fs = _G["ChairPlusScanTipTextLeft" .. i]
        local text = fs and ns.Text(fs:GetText())
        if text then lines[#lines + 1] = text end
    end
    return lines
end

-- A line about how fast you move, not how fast you swing or cast.
local function SpeedLine(text)
    local lower = text:lower()
    if not lower:find("speed") then return nil end
    for _, other in ipairs({ "attack speed", "casting speed", "cast speed", "attack and casting" }) do
        if lower:find(other, 1, true) then return nil end
    end
    return text
end

-- A buff or debuff's name, by index, from whichever aura API this client has.
local function AuraName(index, filter)
    local auras = _G.C_UnitAuras
    if auras and type(auras.GetAuraDataByIndex) == "function" then
        local ok, data = pcall(auras.GetAuraDataByIndex, "player", index, filter)
        if ok then return type(data) == "table" and ns.Text(data.name) or nil end
    end
    if type(_G.UnitAura) == "function" then
        local ok, name = pcall(_G.UnitAura, "player", index, filter)
        return ok and ns.Text(name) or nil
    end
    return nil
end

-- Everything found to be changing your speed: { what, detail, r, g, b }.
local function SpeedCauses()
    local causes = {}
    local function Add(what, detail, slower)
        causes[#causes + 1] = { what, detail or "",
            slower and 1 or 0.3, slower and 0.3 or 1, slower and 0.3 or 0.3 }
    end
    local function Slower(text)
        local lower = text:lower()
        return (lower:find("reduc") or lower:find("decreas") or lower:find("slow")) and true or false
    end

    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for index = 1, 40 do
            local name = AuraName(index, filter)
            if not name then break end
            for _, text in ipairs(TipLines("SetUnitAura", "player", index, filter)) do
                local line = SpeedLine(text)
                if line then
                    Add(name, line:match("(%d+%%)") or "", filter == "HARMFUL" or Slower(line))
                    break
                end
            end
            -- A debuff that says nothing readable about speed may still be
            -- the one: Dazed has no number on it.
            if filter == "HARMFUL" and name == "Dazed" then Add(name, "", true) end
        end
    end

    for slot = 1, 19 do
        local okL, link = pcall(_G.GetInventoryItemLink, "player", slot)
        if okL and link then
            for _, text in ipairs(TipLines("SetInventoryItem", "player", slot)) do
                local line = SpeedLine(text)
                if line and not line:lower():find("^durability") then
                    local okN, itemName = pcall(_G.GetItemInfo, link)
                    Add(okN and ns.Text(itemName) or "Gear", line, Slower(line))
                    break
                end
            end
        end
    end

    local function Is(fn, ...)
        if type(fn) ~= "function" then return false end
        local ok, yes = pcall(fn, ...)
        return ok and yes and true or false
    end
    if Is(_G.IsMounted) then Add("Mounted", "", false) end
    if Is(_G.UnitOnTaxi, "player") then Add("On a flight path", "", false) end
    if Is(_G.IsSwimming) then Add("Swimming", "swim speed applies", true) end
    if Is(_G.IsStealthed) then Add("Stealthed", "", true) end
    if Is(_G.UnitIsGhost, "player") then Add("Ghost", "", false) end
    if Is(_G.IsFalling) then Add("Falling", "", false) end
    return causes
end

local SLOT_NAMES = {
    [1] = "Head", [3] = "Shoulders", [5] = "Chest", [6] = "Waist", [7] = "Legs",
    [8] = "Feet", [9] = "Wrists", [10] = "Hands", [16] = "Main hand",
    [17] = "Off hand", [18] = "Ranged",
}

local function DurabilityLines(tip)
    local rows = {}
    for slot, label in pairs(SLOT_NAMES) do
        local ok, current, maximum = pcall(_G.GetInventoryItemDurability, slot)
        current, maximum = ok and ns.Num(current), ok and ns.Num(maximum)
        if current and maximum and maximum > 0 then
            rows[#rows + 1] = { label, current / maximum * 100 }
        end
    end
    table.sort(rows, function(a, b) return a[2] < b[2] end)
    for _, row in ipairs(rows) do
        local pct = row[2]
        local r, g = 1, 1
        if pct < 25 then r, g = 1, 0.2 elseif pct < 50 then r, g = 1, 0.82 end
        tip:AddDoubleLine(row[1], string.format("%d%%", math.floor(pct + 0.5)), 1, 1, 1, r, g, pct < 50 and 0.2 or 1)
    end
    if #rows == 0 then tip:AddLine("Nothing worn wears out.", 0.6, 0.6, 0.6) end
end

local function BagLines(tip)
    local getFree, getSlots = ns.GetContainerNumFreeSlots, ns.GetContainerNumSlots
    if type(getFree) ~= "function" or type(getSlots) ~= "function" then return end
    local last = ns.LAST_BAG or 4
    if ns.REAGENT_BAG and ns.REAGENT_BAG > last then last = ns.REAGENT_BAG end
    for bag = 0, last do
        local okF, free = pcall(getFree, bag)
        local okS, size = pcall(getSlots, bag)
        free, size = okF and ns.Num(free), okS and ns.Num(size)
        if size and size > 0 then
            local label = bag == 0 and "Backpack" or ("Bag " .. bag)
            if IsProfessionBag(bag) then label = label .. " (profession)" end
            tip:AddDoubleLine(label, string.format("%d of %d free", free or 0, size), 1, 1, 1, 1, 1, 1)
        end
    end
end

-- The heaviest addons by memory, for the latency tooltip.
local function MemoryLines(tip)
    if type(_G.UpdateAddOnMemoryUsage) ~= "function" or type(_G.GetAddOnMemoryUsage) ~= "function" then return end
    pcall(_G.UpdateAddOnMemoryUsage)
    local addons = _G.C_AddOns
    local count = (addons and addons.GetNumAddOns) or _G.GetNumAddOns
    local info = (addons and addons.GetAddOnInfo) or _G.GetAddOnInfo
    local ok, n = pcall(count)
    local rows, total = {}, 0
    for i = 1, (ok and ns.Num(n) or 0) do
        local okM, kb = pcall(_G.GetAddOnMemoryUsage, i)
        kb = okM and ns.Num(kb) or 0
        if kb > 0 then
            local okI, name, title = pcall(info, i)
            rows[#rows + 1] = { okI and (ns.Text(title) or ns.Text(name)) or ("#" .. i), kb }
            total = total + kb
        end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local function Size(kb)
        return kb >= 1024 and string.format("%.1f MB", kb / 1024) or string.format("%d KB", kb)
    end
    tip:AddLine(" ")
    tip:AddDoubleLine("Addon memory", Size(total), 1, 0.82, 0, 1, 1, 1)
    for i = 1, math.min(10, #rows) do
        tip:AddDoubleLine("  " .. rows[i][1]:gsub("|", "||"), Size(rows[i][2]), 1, 1, 1, 0.7, 0.7, 0.7)
    end
end

-- Hint lines at the foot of a tooltip.
local function Hint(tip, text)
    tip:AddLine(text, 0.6, 0.6, 0.6)
end

-- Every item the line can hold. `setting` switches it on; `build` returns its
-- text, or nil to leave it out this time (a count you do not carry, a
-- position the client will not give). `ticks` marks the ones that change
-- without an event, which the frame redraws a few times a second.
local ITEMS = {
    {
        key = "money", setting = "osdMoney", label = "Money",
        click = OpenBags,
        tooltip = function(tip)
            tip:AddLine("Money", 1, 0.82, 0)
            local delta = ns.SessionGold and ns.SessionGold()
            if delta then
                tip:AddDoubleLine("This session", (delta < 0 and "-" or "+") .. Coins(delta, 12), 1, 1, 1, 1, 1, 1)
            end
            Hint(tip, "Click to open your bags.")
        end,
        build = function(size)
            local amounts = { GetMoneyParts() }
            local coins = {}
            for i = 1, #COIN do
                coins[#coins + 1] = Segment(COIN[i].tex, amounts[i], size, false)
            end
            return table.concat(coins, "  ")
        end,
    },
    {
        key = "bags", setting = "osdBags", label = "Free bag slots",
        click = OpenBags,
        tooltip = function(tip)
            tip:AddLine("Bags", 1, 0.82, 0)
            BagLines(tip)
            Hint(tip, "Click to open your bags.")
        end,
        build = function(size)
            local general, _, _, total = GetFreeSlots()
            return IconOnly(BAG_ICON, size, true) .. " " .. SlotsText(general, total)
        end,
    },
    {
        -- Only shown when a profession bag is actually equipped. A standing
        -- zero for something you do not carry is noise, and this line is read
        -- at a glance or not at all.
        key = "profession", setting = "osdBagsProfession", label = "Profession bags, separately",
        click = OpenBags,
        tooltip = function(tip)
            tip:AddLine("Bags", 1, 0.82, 0)
            BagLines(tip)
            Hint(tip, "Click to open your bags.")
        end,
        build = function(size)
            local _, special, sawSpecial, _, total = GetFreeSlots()
            if not sawSpecial then return nil end
            return IconOnly(PROFESSION_BAG_ICON, size, true) .. " " .. SlotsText(special, total)
        end,
    },
    {
        key = "durability", setting = "osdDurability", label = "Durability",
        click = function() OpenCharacter() end,
        tooltip = function(tip)
            tip:AddLine("Durability", 1, 0.82, 0)
            DurabilityLines(tip)
            Hint(tip, "Click to open your character.")
        end,
        build = function(size)
            local pct = LowestDurability()
            if not pct then return nil end
            local text = string.format("%d%%", math.floor(pct + 0.5))
            if pct < 25 then text = Coloured(text, 1, 0.2, 0.2)
            elseif pct < 50 then text = Coloured(text, 1, 0.82, 0) end
            return IconOnly("Interface\\ICONS\\Trade_BlackSmithing", size, true) .. " " .. text
        end,
    },
    {
        key = "ammo", setting = "osdAmmo", label = "Ammo",
        click = function() OpenCharacter() end,
        tooltip = function(tip)
            local okL, link = pcall(_G.GetInventoryItemLink, "player", AMMO_SLOT)
            local okN, name = pcall(_G.GetItemInfo, okL and link or 0)
            tip:AddLine(okN and ns.Text(name) or "Ammo", 1, 0.82, 0)
            local okC, count = pcall(_G.GetInventoryItemCount, "player", AMMO_SLOT)
            count = okC and ns.Num(count)
            if count then tip:AddLine(string.format("%d left", count), 1, 1, 1) end
            Hint(tip, "Click to open your character.")
        end,
        build = function(size)
            local okT, tex = pcall(_G.GetInventoryItemTexture, "player", AMMO_SLOT)
            tex = okT and tex or nil
            if not tex then return nil end         -- nothing in the ammo slot
            local okC, count = pcall(_G.GetInventoryItemCount, "player", AMMO_SLOT)
            count = okC and ns.Num(count) or nil
            local text = count and string.format("%d", count) or "--"
            if count and count < 200 then text = Coloured(text, 1, 0.2, 0.2) end
            return IconOnly(tex, size, true) .. " " .. text
        end,
    },
    {
        -- Shown for a warlock, or for anyone carrying shards; a zero on a
        -- warrior is noise.
        key = "shards", setting = "osdShards", label = "Soul shards",
        click = OpenBags,
        tip = "Soul shards -- click to open your bags.",
        build = function(size)
            local count
            if type(ns.GetItemCount) == "function" then
                local ok, n = pcall(ns.GetItemCount, SOUL_SHARD)
                count = ok and ns.Num(n) or nil
            end
            local okC, _, class = pcall(_G.UnitClass, "player")
            local warlock = okC and ns.Text(class) == "WARLOCK"
            if not warlock and not (count and count > 0) then return nil end
            return IconOnly("Interface\\ICONS\\INV_Misc_Gem_Amethyst_02", size, true)
                .. " " .. (count and string.format("%d", count) or "--")
        end,
    },
    {
        key = "coords", setting = "osdCoords", label = "Coordinates", ticks = true,
        click = OpenMap,
        tip = "Your position on the zone map -- click to open the map.",
        sample = function(size)
            return IconOnly("Interface\\ICONS\\INV_Misc_Map_01", size, true) .. " 88.8, 88.8"
        end,
        build = function(size)
            local x, y = PlayerCoords()
            if not x then return nil end
            return IconOnly("Interface\\ICONS\\INV_Misc_Map_01", size, true)
                .. string.format(" %.1f, %.1f", x, y)
        end,
    },
    {
        -- Nothing at the level cap, where there is no bar to fill.
        key = "xp", setting = "osdXP", label = "XP and rested",
        tooltip = function(tip)
            local okL, level = pcall(_G.UnitLevel, "player")
            tip:AddLine("Level " .. tostring(okL and ns.Num(level) or "?"), 1, 0.82, 0)
            local okX, xp = pcall(_G.UnitXP, "player")
            local okM, maxXP = pcall(_G.UnitXPMax, "player")
            xp, maxXP = okX and ns.Num(xp), okM and ns.Num(maxXP)
            if xp and maxXP and maxXP > 0 then
                tip:AddDoubleLine("XP", string.format("%d / %d (%.1f%%)", xp, maxXP, xp / maxXP * 100),
                    1, 1, 1, 1, 1, 1)
                tip:AddDoubleLine("To level", string.format("%d", maxXP - xp), 1, 1, 1, 1, 1, 1)
                local okR, rested = pcall(_G.GetXPExhaustion)
                rested = okR and ns.Num(rested)
                if rested and rested > 0 then
                    tip:AddDoubleLine("Rested", string.format("%d (%.1f%%)", rested, rested / maxXP * 100),
                        0.4, 0.6, 1, 0.4, 0.6, 1)
                end
            end
        end,
        build = function(size)
            local okX, xp = pcall(_G.UnitXP, "player")
            local okM, maxXP = pcall(_G.UnitXPMax, "player")
            xp, maxXP = okX and ns.Num(xp), okM and ns.Num(maxXP)
            if not xp or not maxXP or maxXP <= 0 then return nil end
            -- As a percentage, as XP out of the level's total, or both, by
            -- the XP display setting. Rested follows the same choice.
            local mode = ns.Get("osdXPMode")
            local pct = string.format("%.2f%%", xp / maxXP * 100)
            local num = string.format("%d/%d", xp, maxXP)
            local text
            if mode == "num" then text = num
            elseif mode == "both" then text = num .. " (" .. pct .. ")"
            else text = pct end
            local okR, rested = pcall(_G.GetXPExhaustion)
            rested = okR and ns.Num(rested) or nil
            if rested and rested > 0 then
                local restedPct = string.format("+%.2f%%", rested / maxXP * 100)
                local restedNum = string.format("+%d", rested)
                local restedText = (mode == "num" and restedNum)
                    or (mode == "both" and (restedNum .. " (" .. restedPct .. ")"))
                    or restedPct
                text = text .. Coloured(" " .. restedText, 0.4, 0.6, 1)
            end
            return IconOnly("Interface\\ICONS\\INV_Misc_Note_01", size, true) .. " " .. text
        end,
    },
    {
        -- Realm or local time, 24- or 12-hour, by the two clock settings.
        key = "clock", setting = "osdClock", label = "Clock", ticks = true,
        click = function() ns.OpenAlarm() end,
        tooltip = function(tip)
            tip:AddLine("Time", 1, 0.82, 0)
            local here, realm = FormatTime(TimeNow(false)), FormatTime(TimeNow(true))
            if here then tip:AddDoubleLine("Local", here, 1, 1, 1, 1, 1, 1) end
            if realm then tip:AddDoubleLine("Realm", realm, 1, 1, 1, 1, 1, 1) end
            Hint(tip, "Click to open the clock.")
        end,
        sample = function(size)
            return IconOnly("Interface\\ICONS\\INV_Misc_PocketWatch_01", size, true)
                .. " " .. (ns.Get("osdClock24") and "88:88" or "88:88 PM")
        end,
        build = function(size)
            local text = FormatTime(TimeNow(ns.Get("osdClockServer")))
            if not text then return nil end
            return IconOnly("Interface\\ICONS\\INV_Misc_PocketWatch_01", size, true) .. " " .. text
        end,
    },
    {
        -- The in-game alarm's time, dimmed when it is switched off. Clicking
        -- it opens Blizzard's clock, where the alarm is set.
        key = "alarm", setting = "osdAlarm", label = "Alarm (click it to set)", ticks = true,
        -- Its message changes its width only when the alarm is changed.
        click = function() ns.OpenAlarm() end,
        tip = "Alarm -- click to open the clock and set it.",
        sample = function(size)
            return IconOnly("Interface\\ICONS\\INV_Misc_Horn_01", size, true)
                .. " " .. (ns.Get("osdClock24") and "88:88" or "88:88 PM")
        end,
        build = function(size)
            local icon = IconOnly("Interface\\ICONS\\INV_Misc_Horn_01", size, true)
            local enabled, h, m, message = ns.AlarmTime()
            if enabled == nil then return icon .. " " .. Coloured("--:--", 0.5, 0.5, 0.5) end
            local text = FormatTime(h, m)
            -- The alarm's own message rides after its time, as it will pop up.
            local note = AlarmMessage(message)
            if note then text = text .. "  " .. note end
            if not enabled then return icon .. " " .. Coloured(text .. " off", 0.5, 0.5, 0.5) end
            return icon .. " " .. text
        end,
    },
    {
        -- The zone, and the subzone when you are in one: "Elwynn Forest:
        -- Goldshire".
        key = "zone", setting = "osdZone", label = "Zone name",
        click = OpenMap,
        tooltip = function(tip)
            local okZ, zone = pcall(_G.GetZoneText)
            tip:AddLine(okZ and ns.Text(zone) or "Zone", 1, 0.82, 0)
            local okS, sub = pcall(_G.GetSubZoneText)
            sub = okS and ns.Text(sub)
            if sub and sub ~= "" then tip:AddLine(sub, 1, 1, 1) end
            local okP, pvp = pcall(_G.GetZonePVPInfo)
            pvp = okP and ns.Text(pvp)
            local kinds = { sanctuary = "Sanctuary", friendly = "Friendly territory",
                            hostile = "Hostile territory", contested = "Contested territory",
                            combat = "Combat zone", arena = "Arena" }
            if pvp and kinds[pvp] then tip:AddLine(kinds[pvp], 0.7, 0.7, 0.7) end
            local x, y = PlayerCoords()
            if x then tip:AddLine(string.format("%.1f, %.1f", x, y), 0.7, 0.7, 0.7) end
            Hint(tip, "Click to open the map.")
        end,
        build = function()
            local okZ, zone = pcall(_G.GetZoneText)
            local okS, sub = pcall(_G.GetSubZoneText)
            zone, sub = okZ and ns.Text(zone) or nil, okS and ns.Text(sub) or nil
            if not zone then return nil end
            if sub and sub ~= zone then zone = zone .. ": " .. sub end
            return (zone:gsub("|", "||"))
        end,
    },
    {
        -- Your threat on your target, while there is any: white while it is
        -- comfortable, yellow past half, orange past 80%, red once you are
        -- tanking it (or past 100% and about to).
        key = "threat", setting = "osdThreat", label = "My threat on target", ticks = true,
        tooltip = function(tip)
            local okN, name = pcall(_G.UnitName, "target")
            tip:AddLine("Threat on " .. (okN and ns.Text(name) or "target"), 1, 0.82, 0)
            local detailed = _G.UnitDetailedThreatSituation
            if type(detailed) == "function" then
                local ok, tanking, _, pct = pcall(detailed, "player", "target")
                if ok and tanking then tip:AddLine("You are tanking it.", 1, 0.3, 0.3) end
                if ok and ns.Num(pct) then tip:AddLine(string.format("%d%% of the aggro threshold", ns.Num(pct)), 1, 1, 1) end
            end
        end,
        sample = function() return "Threat 888%" end,
        build = function()
            local detailed = _G.UnitDetailedThreatSituation
            if type(detailed) ~= "function" then return nil end
            local okE, exists = pcall(_G.UnitExists, "target")
            if not (okE and exists) then return nil end
            local ok, tanking, _, pct = pcall(detailed, "player", "target")
            pct = ok and ns.Num(pct) or nil
            if not pct then return nil end
            local text = string.format("Threat %d%%", math.floor(pct + 0.5))
            if tanking or pct >= 100 then return Coloured(text, 1, 0.15, 0.15) end
            if pct >= 80 then return Coloured(text, 1, 0.55, 0) end
            if pct >= 50 then return Coloured(text, 1, 0.9, 0.2) end
            return text
        end,
    },
    {
        -- ChairTracker's window, living here instead of on its own: hovering
        -- the item drops it down underneath, and it fades once the mouse has
        -- gone. With this on, the standalone window stays shut.
        key = "tracker", setting = "osdTracker", label = "ChairTracker (hover to show)",
        hover = function(button)
            local tracker = _G.WOWFTrackerNS
            if tracker and tracker.DockShow then pcall(tracker.DockShow) end
        end,
        click = function()
            local tracker = _G.WOWFTrackerNS
            if tracker and tracker.DockShow then pcall(tracker.DockShow) end
        end,
        build = function(size)
            local tracker = _G.WOWFTrackerNS
            if not (tracker and tracker.Dock) then return nil end
            return IconOnly("Interface\\ICONS\\INV_Scroll_03", size, true) .. " Tracker"
        end,
    },
    {
        -- Right-aligned in its box: the numbers change several times a
        -- second, and a right edge that stays put is what stops them wiggling.
        key = "latency", setting = "osdLatency", label = "Frame rate and latency", ticks = true,
        click = function()
            local before = collectgarbage("count")
            collectgarbage("collect")
            ns.Print(string.format("Freed %.1f MB of unused addon memory.",
                math.max(0, before - collectgarbage("count")) / 1024))
        end,
        tooltip = function(tip)
            tip:AddLine("Performance", 1, 0.82, 0)
            local okF, fps = pcall(_G.GetFramerate)
            if okF and ns.Num(fps) then tip:AddDoubleLine("Frame rate", string.format("%.0f fps", ns.Num(fps)), 1, 1, 1, 1, 1, 1) end
            local okN, _, _, home, world = pcall(_G.GetNetStats)
            if okN then
                if ns.Num(home) then tip:AddDoubleLine("Home latency", string.format("%d ms", ns.Num(home)), 1, 1, 1, 1, 1, 1) end
                if ns.Num(world) then tip:AddDoubleLine("World latency", string.format("%d ms", ns.Num(world)), 1, 1, 1, 1, 1, 1) end
            end
            MemoryLines(tip)
            Hint(tip, "Click to free unused addon memory.")
        end,
        justify = "RIGHT",
        sample = function() return "888 fps  8888 ms" end,
        build = function()
            local parts = {}
            local okF, fps = pcall(_G.GetFramerate)
            fps = okF and ns.Num(fps) or nil
            if fps then parts[#parts + 1] = string.format("%d fps", math.floor(fps + 0.5)) end
            local okN, _, _, home, world = pcall(_G.GetNetStats)
            local ms = okN and (ns.Num(world) or ns.Num(home)) or nil
            if ms and ms > 0 then
                local text = string.format("%d ms", ms)
                if ms > 300 then text = Coloured(text, 1, 0.2, 0.2)
                elseif ms > 150 then text = Coloured(text, 1, 0.82, 0) end
                parts[#parts + 1] = text
            end
            if #parts == 0 then return nil end
            return table.concat(parts, "  ")
        end,
    },
    {
        -- How long since you logged in. A /reload carries on the same session.
        key = "session", setting = "osdSession", label = "Session time", ticks = true,
        sample = function(size)
            return IconOnly("Interface\\ICONS\\INV_Misc_PocketWatch_02", size, true) .. " 88:88:88"
        end,
        tooltip = function(tip)
            tip:AddLine("Session time", 1, 0.82, 0)
            local seconds = ns.SessionSeconds()
            if seconds then
                local okD, started = pcall(date, "%H:%M", time() - seconds)
                if okD then tip:AddLine("Logged in at " .. started, 1, 1, 1) end
            end
        end,
        build = function(size)
            local seconds = ns.SessionSeconds()
            if not seconds then return nil end
            return IconOnly("Interface\\ICONS\\INV_Misc_PocketWatch_02", size, true)
                .. " " .. Duration(seconds)
        end,
    },
    {
        -- Gold made or lost since logging in: green up, red down. Clicking it
        -- starts the count again from now.
        key = "sessiongold", setting = "osdSessionGold", label = "Gold this session",
        click = function() ns.ResetSessionGold() end,
        tooltip = function(tip)
            tip:AddLine("Gold this session", 1, 0.82, 0)
            local delta, seconds = ns.SessionGold(), ns.SessionSeconds()
            if delta and seconds and seconds >= 60 then
                local perHour = delta / seconds * 3600
                tip:AddLine((perHour < 0 and "-" or "") .. Coins(perHour, 12) .. " per hour", 1, 1, 1)
            end
            tip:AddLine("Click to start counting again.", 0.6, 0.6, 0.6)
        end,
        build = function(size)
            local delta = ns.SessionGold()
            if not delta then return nil end
            if delta < 0 then return Coloured("-", 1, 0.2, 0.2) .. Coins(delta, size) end
            if delta > 0 then return Coloured("+", 0.3, 1, 0.3) .. Coins(delta, size) end
            return Coloured("+", 0.6, 0.6, 0.6) .. Coins(0, size)
        end,
    },
    {
        -- Moving, how fast you are going; standing still, how fast you would
        -- run, dimmed. 100% is a normal run.
        key = "speed", setting = "osdSpeed", label = "Movement speed", ticks = true,
        tooltip = function(tip)
            tip:AddLine("Movement speed", 1, 0.82, 0)
            if type(_G.GetUnitSpeed) == "function" then
                local ok, current, run, flight, swim = pcall(_G.GetUnitSpeed, "player")
                local function Pct(v) return string.format("%d%%", math.floor((ns.Num(v) or 0) / BASE_SPEED * 100 + 0.5)) end
                if ok then
                    tip:AddDoubleLine("Now", Pct(current), 1, 1, 1, 1, 1, 1)
                    tip:AddDoubleLine("Running", Pct(run), 1, 1, 1, 1, 1, 1)
                    if ns.Num(swim) then tip:AddDoubleLine("Swimming", Pct(swim), 1, 1, 1, 1, 1, 1) end
                end
            end
            local causes = SpeedCauses()
            tip:AddLine(" ")
            if #causes == 0 then
                tip:AddLine("Nothing is changing your speed: 100% is a normal run.", 0.7, 0.7, 0.7, true)
            else
                tip:AddLine("Changing it:", 1, 0.82, 0)
                for _, cause in ipairs(causes) do
                    tip:AddDoubleLine("  " .. cause[1], cause[2], cause[3], cause[4], cause[5], 0.8, 0.8, 0.8)
                end
            end
            Hint(tip, "Walking backward is always slower.")
        end,
        justify = "RIGHT",
        sample = function(size)
            return IconOnly("Interface\\ICONS\\Ability_Rogue_Sprint", size, true) .. " 888%"
        end,
        build = function(size)
            if type(_G.GetUnitSpeed) ~= "function" then return nil end
            local ok, current, run = pcall(_G.GetUnitSpeed, "player")
            current, run = ok and ns.Num(current), ok and ns.Num(run)
            if not current then return nil end
            local icon = IconOnly("Interface\\ICONS\\Ability_Rogue_Sprint", size, true)
            if current > 0 then
                return icon .. string.format(" %d%%", math.floor(current / BASE_SPEED * 100 + 0.5))
            end
            local text = string.format(" %d%%", math.floor((run or BASE_SPEED) / BASE_SPEED * 100 + 0.5))
            return icon .. Coloured(text, 0.6, 0.6, 0.6)
        end,
    },
    {
        -- A hunter's pet: its name, how happy it is, and its health. Nothing
        -- without a pet out, or on any other class.
        key = "pet", setting = "osdPet", label = "Hunter pet", ticks = true,
        click = function() OpenCharacter("PetPaperDollFrame") end,
        tooltip = function(tip)
            local okN, name = pcall(_G.UnitName, "pet")
            tip:AddLine(okN and ns.Text(name) or "Pet", 1, 0.82, 0)
            local happy, damage, loyalty = PetHappiness()
            local mood = happy and HAPPINESS[happy]
            if mood then tip:AddLine(mood[1], mood[2], mood[3], mood[4]) end
            if damage then tip:AddLine(string.format("Doing %d%% damage", damage), 1, 1, 1) end
            if loyalty and loyalty ~= 0 then
                tip:AddLine(loyalty > 0 and "Gaining loyalty" or "Losing loyalty",
                    loyalty > 0 and 0.3 or 1, loyalty > 0 and 1 or 0.2, loyalty > 0 and 0.3 or 0.2)
            end
            Hint(tip, "Click to open the pet window.")
        end,
        build = function(size)
            if not IsHunter() then return nil end
            local happy = PetHappiness()
            if happy == nil then return nil end
            local okN, name = pcall(_G.UnitName, "pet")
            name = okN and ns.Text(name) or "Pet"
            local mood = HAPPINESS[happy]
            local icon = ""
            if mood then
                icon = string.format("|T%s:%d:%d:0:0:128:64:%d:%d:0:23|t ", HAPPINESS_TEX,
                    size, size, mood[5], mood[5] + 24)
            end
            local text = icon .. (name:gsub("|", "||"))
            local pct = PetHealthPct()
            if pct then
                local hp = string.format(" %d%%", math.floor(pct + 0.5))
                if pct < 35 then hp = Coloured(hp, 1, 0.2, 0.2) end
                text = text .. hp
            end
            return text
        end,
    },
    {
        -- Only there while there is unread mail. Hover for who sent it.
        key = "mail", setting = "osdMail", label = "New mail",
        tooltip = function(tip)
            tip:AddLine("New mail", 1, 0.82, 0)
            if type(_G.GetLatestThreeSenders) == "function" then
                local ok, a, b, c = pcall(_G.GetLatestThreeSenders)
                if ok then
                    for _, sender in ipairs({ a, b, c }) do
                        if ns.Text(sender) then tip:AddLine("  " .. ns.Text(sender), 1, 1, 1) end
                    end
                end
            end
        end,
        build = function(size)
            if not HasMail() then return nil end
            return IconOnly("Interface\\ICONS\\INV_Letter_15", size, true) .. " Mail"
        end,
    },
    {
        -- Friends and guildmates online. Hover for who; click for the
        -- friends list.
        key = "social", setting = "osdSocial", label = "Friends and guild online",
        click = function()
            if type(_G.ToggleFriendsFrame) == "function" then pcall(_G.ToggleFriendsFrame) end
        end,
        tooltip = function(tip)
            local friends, bnet = OnlineFriends()
            AddPeople(tip, string.format("Friends online: %d", #friends), friends)
            if bnet > 0 then tip:AddLine(string.format("Battle.net friends online: %d", bnet), 0.5, 0.8, 1) end
            local guild = OnlineGuild()
            if guild then
                tip:AddLine(" ")
                AddPeople(tip, string.format("Guild online: %d", #guild), guild)
            end
            tip:AddLine(" ")
            tip:AddLine("Click for the friends list.", 0.6, 0.6, 0.6)
        end,
        build = function(size)
            local friends, bnet = OnlineFriends()
            local text = string.format("Friends %d", #friends + bnet)
            local guild = OnlineGuild()
            if guild then text = text .. string.format("  Guild %d", #guild) end
            return IconOnly("Interface\\ICONS\\INV_Misc_Head_Human_01", size, true) .. " " .. text
        end,
    },
    {
        -- Chairface's Casino, while a table is running in your group or raid:
        -- the game, and who is hosting it. Click to open the casino's lobby.
        key = "casino", setting = "osdCasino", label = "Casino table (while one is up)",
        ticks = true,
        click = function()
            local lobby = CasinoLobby()
            if lobby and type(lobby.Show) == "function" then pcall(lobby.Show, lobby) end
        end,
        tooltip = function(tip)
            tip:AddLine("Chairface's Casino", 1, 0.82, 0)
            local game, host = CasinoTable()
            if game then tip:AddLine(game .. (host and (" hosted by " .. host) or ""), 1, 1, 1) end
            tip:AddLine("Click to open the lobby.", 0.6, 0.6, 0.6)
        end,
        build = function(size)
            local game, host = CasinoTable()
            if not game then return nil end
            return IconOnly(CASINO_ICON, size, false) .. " " .. game
                .. (host and Coloured(" (" .. host .. ")", 0.6, 0.6, 0.6) or "")
        end,
    },
}
ns.OSD_ITEMS = ITEMS

local byKey = {}
for _, item in ipairs(ITEMS) do byKey[item.key] = item end

-------------------------------------------------------------------------------
-- Other addons' feeds (LibDataBroker)
-------------------------------------------------------------------------------
-- Any addon that publishes a LibDataBroker object -- the thing Titan Panel
-- and the like read -- shows up in the OSD page's item list, off until ticked.
-- A data source shows its icon and text; a launcher, its icon. Clicks,
-- tooltips and hovers go straight to the addon's own handlers.
--
-- Keyed "ldb:" plus the object's name with anything that is not a plain name
-- character escaped, so a name with a space or a comma cannot break the saved
-- order. Which ones are on is the comma list in osdBrokers.

local OWN_BROKER = "Chaircraft"
local brokers, brokerList = {}, {}
local LDB

local function BrokerKey(name)
    return "ldb:" .. (name:gsub("[^%w_%.%-]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local brokersOn, brokersOnFrom = {}, nil
local function BrokerOn(key)
    local saved = ns.Get("osdBrokers") or ""
    if saved ~= brokersOnFrom then
        brokersOn, brokersOnFrom = {}, saved
        for k in saved:gmatch("[^,]+") do brokersOn[k] = true end
    end
    return brokersOn[key] == true
end

-- Is this item switched on? Built-in items have a setting each; addons' feeds
-- share the one list.
function ns.OSDItemOn(item)
    if item.broker then return BrokerOn(item.key) end
    return ns.Get(item.setting) and true or false
end

function ns.SetOSDItemOn(item, on)
    if not item.broker then return ns.Set(item.setting, on and true or false) end
    BrokerOn(item.key)
    local keys = {}
    for k in pairs(brokersOn) do
        if k ~= item.key then keys[#keys + 1] = k end
    end
    if on then keys[#keys + 1] = item.key end
    table.sort(keys)
    return ns.Set("osdBrokers", table.concat(keys, ","))
end

local function BrokerIcon(obj, size)
    local icon = obj.icon
    if type(icon) ~= "string" and type(icon) ~= "number" then return nil end
    local c = obj.iconCoords
    if type(c) == "table" and #c == 4 then
        return string.format("|T%s:%d:%d:0:0:64:64:%d:%d:%d:%d|t", tostring(icon), size, size,
            c[1] * 64, c[2] * 64, c[3] * 64, c[4] * 64)
    end
    return string.format("|T%s:%d:%d:0:0|t", tostring(icon), size, size)
end

local function AddBroker(name, obj)
    if type(name) ~= "string" or name == OWN_BROKER or type(obj) ~= "table" then return end
    local key = BrokerKey(name)
    if brokers[key] then return end
    local label = ns.Text(obj.label) or name
    local launcher = obj.type == "launcher"
    local item = {
        key = key, broker = name,
        label = label .. (launcher and " |cff808080(addon button)|r" or " |cff808080(addon)|r"),
        build = function(size)
            local text
            if not launcher then
                text = obj.text
                if text == nil and obj.value ~= nil then
                    text = tostring(obj.value) .. (obj.suffix and (" " .. tostring(obj.suffix)) or "")
                end
                text = text ~= nil and tostring(text) or nil
                if text == "" then text = nil end
            end
            local icon = BrokerIcon(obj, size)
            if not icon and not text then text = label end
            if icon and text then return icon .. " " .. text end
            return icon or text
        end,
        click = function(button, mouse)
            if type(obj.OnClick) == "function" then obj.OnClick(button, mouse or "LeftButton") end
        end,
        -- An addon with OnEnter draws its own tooltip, and must be told when
        -- the mouse leaves.
        enter = function(button)
            if type(obj.OnEnter) ~= "function" then return false end
            obj.OnEnter(button)
            return true
        end,
        leave = function(button)
            if type(obj.OnLeave) == "function" then obj.OnLeave(button) end
        end,
        tooltip = function(tip)
            if type(obj.OnTooltipShow) == "function" then
                obj.OnTooltipShow(tip)
            else
                tip:AddLine(label, 1, 0.82, 0)
            end
        end,
    }
    brokers[key] = item
    brokerList[#brokerList + 1] = item
    table.sort(brokerList, function(a, b) return a.broker:lower() < b.broker:lower() end)
    if BrokerOn(key) and ns.RefreshOSD then ns.RefreshOSD() end
end

-- Every feed another addon has published, in name order, for the OSD page.
function ns.OSDBrokers()
    return brokerList
end

local function HookBrokers()
    if LDB then return true end
    local stub = _G.LibStub
    if type(stub) ~= "table" or type(stub.GetLibrary) ~= "function" then return false end
    local ok, lib = pcall(stub.GetLibrary, stub, "LibDataBroker-1.1", true)
    if not (ok and type(lib) == "table") then return false end
    LDB = lib
    ns.LDB = lib
    if type(lib.DataObjectIterator) == "function" then
        for name, obj in lib:DataObjectIterator() do AddBroker(name, obj) end
    end
    if type(lib.RegisterCallback) == "function" then
        lib.RegisterCallback(brokers, "LibDataBroker_DataObjectCreated", function(_, name, obj)
            AddBroker(name, obj)
        end)
        lib.RegisterCallback(brokers, "LibDataBroker_AttributeChanged", function(_, name)
            if type(name) == "string" and BrokerOn(BrokerKey(name)) then ns.RefreshOSD() end
        end)
    end
    return true
end
ns.HookBrokers = HookBrokers
HookBrokers()

-- The items in display order: the saved order first, skipping anything it
-- does not recognise, then any item it leaves out, in its default place.
-- Dividers: a | between items, as many as wanted (up to MAX_DIVIDERS),
-- saved in osdOrder as "|" and moved like any item. Each is known by its
-- place among the dividers -- "|1", "|2" -- which is all that tells two
-- identical things apart.
local MAX_DIVIDERS = 30
ns.OSD_MAX_DIVIDERS = MAX_DIVIDERS

local function Divider(n)
    return {
        key = "|" .. n, divider = true, label = "Divider",
        build = function() return Coloured("||", 0.55, 0.55, 0.55) end,
    }
end

-- The items in display order: the saved order first, skipping anything it
-- does not recognise, then any item it leaves out, in its default place.
function ns.OSDOrder()
    local out, seen, dividers = {}, {}, 0
    local saved = ns.Get("osdOrder")
    if type(saved) == "string" then
        for key in saved:gmatch("[^,%s]+") do
            if key == "|" then
                if dividers < MAX_DIVIDERS then
                    dividers = dividers + 1
                    out[#out + 1] = Divider(dividers)
                end
            elseif (byKey[key] or brokers[key]) and not seen[key] then
                out[#out + 1] = byKey[key] or brokers[key]
                seen[key] = true
            end
        end
    end
    for _, item in ipairs(ITEMS) do
        if not seen[item.key] then out[#out + 1] = item end
    end
    for _, item in ipairs(brokerList) do
        if not seen[item.key] then out[#out + 1] = item end
    end
    return out
end

local function SaveOrder(order)
    local keys = {}
    for _, entry in ipairs(order) do keys[#keys + 1] = entry.divider and "|" or entry.key end
    ns.Set("osdOrder", table.concat(keys, ","))
end

-- Move item `key` one place earlier (-1) or later (+1).
function ns.MoveOSDItem(key, step)
    local order = ns.OSDOrder()
    for i, item in ipairs(order) do
        if item.key == key then
            local j = i + step
            if j < 1 or j > #order then return false end
            order[i], order[j] = order[j], order[i]
            SaveOrder(order)
            return true
        end
    end
    return false
end

-- Move item `key` to place `index` in the order (1 is the far left).
function ns.MoveOSDItemTo(key, index)
    local order = ns.OSDOrder()
    for i, item in ipairs(order) do
        if item.key == key then
            index = math.max(1, math.min(#order, math.floor(index)))
            if index == i then return false end
            table.remove(order, i)
            table.insert(order, index, item)
            SaveOrder(order)
            return true
        end
    end
    return false
end

-- A new divider, at the end of the line. False once there are MAX_DIVIDERS.
function ns.AddOSDDivider()
    local order = ns.OSDOrder()
    local count = 0
    for _, item in ipairs(order) do if item.divider then count = count + 1 end end
    if count >= MAX_DIVIDERS then return false end
    order[#order + 1] = Divider(count + 1)
    SaveOrder(order)
    return true
end

function ns.RemoveOSDDivider(key)
    local order = ns.OSDOrder()
    for i, item in ipairs(order) do
        if item.divider and item.key == key then
            table.remove(order, i)
            SaveOrder(order)
            return true
        end
    end
    return false
end

local function WantsTicks()
    for _, item in ipairs(ITEMS) do
        if item.ticks and ns.OSDItemOn(item) then return true end
    end
    return false
end

-- Each item has its own font string in its own slot, laid out left to right.
-- A slot is as wide as the widest text it has shown (or its sample, for the
-- items that tick), and never narrower. One line of centred text, which this
-- used to be, moved everything whenever any number changed width: the frame
-- rate alone made the whole bar twitch several times a second.
local slots, reserved = {}, {}
local reservedSize
local lastLine = ""

local function Slot(key)
    local fs = slots[key]
    if not fs then
        fs = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        slots[key] = fs
    end
    return fs
end

-- A button laid over an item's slot, for the items that can be clicked. It
-- takes the mouse even while the display is locked and the rest of it lets
-- clicks through -- it is only as big as the one item.
local hotspots = {}
-- For the tests, which click and hover items as a player would.
function ns.OSDHotspot(key) return hotspots[key] end

local function Hotspot(item)
    local button = hotspots[item.key]
    if not button then
        button = CreateFrame("Button", nil, frame)
        pcall(button.RegisterForClicks, button, "AnyUp")
        pcall(button.RegisterForDrag, button, "LeftButton")
        button:SetScript("OnDragStart", function()
            local start = frame:GetScript("OnDragStart")
            if start then start(frame) end
        end)
        button:SetScript("OnDragStop", function()
            local stop = frame:GetScript("OnDragStop")
            if stop then stop(frame) end
        end)
        button:SetScript("OnClick", function(self, mouse)
            if item.click then pcall(item.click, self, mouse) end
        end)
        button:SetScript("OnEnter", function(self)
            if item.hover then pcall(item.hover, self) end
            if item.enter then
                local ok, handled = pcall(item.enter, self)
                if ok and handled then return end
            end
            local tip = _G.GameTooltip
            if not tip or not (item.tip or item.tooltip) then return end
            pcall(function()
                tip:SetOwner(self, "ANCHOR_BOTTOM")
                if item.tooltip then
                    item.tooltip(tip)
                else
                    tip:AddLine(item.tip, 1, 1, 1)
                end
                tip:Show()
            end)
        end)
        button:SetScript("OnLeave", function(self)
            if item.leave then pcall(item.leave, self) end
            local tip = _G.GameTooltip
            if tip then pcall(tip.Hide, tip) end
        end)
        hotspots[item.key] = button
    end
    return button
end

-- ChairTracker hangs from the OSD's tracker item while it is showing, and is
-- a window of its own again the moment it is not. Only undocks what this
-- docked, so a tracker left alone is never touched.
local dockedHere = false
function ns.DockTracker(button)
    local tracker = _G.WOWFTrackerNS
    if not (tracker and tracker.Dock) then return end
    if button then
        dockedHere = true
        pcall(tracker.Dock, button)
    elseif dockedHere then
        dockedHere = false
        pcall(tracker.Dock, nil)
    end
end

-- The thin lines the dividers are drawn as.
local dividerLines = {}

local function DividerLine(key)
    local line = dividerLines[key]
    if not line then
        line = frame:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.6, 0.6, 0.6, 0.7)
        dividerLines[key] = line
    end
    return line
end

local function Measure(fs, text)
    if not pcall(fs.SetText, fs, text) then return 0 end
    return ns.Num(fs:GetStringWidth()) or 0
end

-- The whole line as one string, the way it reads on screen. For tests and for
-- anything that wants to know what the display is saying.
function ns.OSDLine()
    return lastLine
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

local function SavePosition()
    if not frame then return end
    local point, relTo, relPoint, x, y = frame:GetPoint(1)
    if type(point) ~= "string" then return end
    ns.SetMany({
        osdAnchor = point,
        osdRelAnchor = type(relPoint) == "string" and relPoint or point,
        osdX = ns.Num(x) or 0,
        osdY = ns.Num(y) or 0,
    })
end

local function ApplyPosition()
    if not frame then return end
    frame:ClearAllPoints()
    local anchor = ns.Get("osdAnchor") or "TOPRIGHT"
    local relAnchor = ns.Get("osdRelAnchor") or anchor
    local x = ns.Num(ns.Get("osdX")) or -20
    local y = ns.Num(ns.Get("osdY")) or -20
    -- A bad anchor name is a hard error from SetPoint, and an anchor name is
    -- exactly the sort of thing a hand-edited baked table gets wrong.
    local ok = pcall(frame.SetPoint, frame, anchor, UIParent, relAnchor, x, y)
    if not ok then
        frame:ClearAllPoints()
        frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -20)
    end
end

local PAD = 8

local function Refresh()
    if not frame then return end

    local size = ns.Num(ns.Get("osdFontSize")) or 14
    -- A new text size makes every reserved width wrong.
    if reservedSize ~= size then
        wipe(reserved)
        reservedSize = size
    end
    -- A wider gap between items than inside one (between the coins), so each
    -- reads as its own thing rather than a fourth denomination.
    local gap = math.floor(size * 0.8 + 0.5)

    -- What is actually showing this time, dividers included. A divider with
    -- nothing on one side of it -- first, last, or next to another divider
    -- once an item has had nothing to say -- is left out.
    local showing = {}
    for _, item in ipairs(ns.OSDOrder()) do
        if item.divider then
            showing[#showing + 1] = { item = item }
        elseif ns.OSDItemOn(item) then
            local ok, built = pcall(item.build, size)
            if ok and type(built) == "string" and built ~= "" then
                showing[#showing + 1] = { item = item, text = built }
            end
        end
    end
    local kept = {}
    for _, entry in ipairs(showing) do
        if entry.item.divider then
            local last = kept[#kept]
            if last and not last.item.divider then kept[#kept + 1] = entry end
        else
            kept[#kept + 1] = entry
        end
    end
    while kept[#kept] and kept[#kept].item.divider do kept[#kept] = nil end

    local x, height, used, parts = PAD, size, {}, {}
    local lines = {}
    for _, entry in ipairs(kept) do
        local item = entry.item
        local text = entry.text
        if item.divider then
            -- A divider is a thin line, not a character: almost the full
            -- height of the background, which is only known once every item
            -- is measured, so it is sized after the loop.
            local line = DividerLine(item.key)
            line:ClearAllPoints()
            line:SetPoint("LEFT", frame, "LEFT", x, 0)
            line:Show()
            lines[#lines + 1] = line
            used[item.key] = true
            parts[#parts + 1] = "|"
            x = x + 1 + gap
        elseif text then
            local fs = Slot(item.key)
            local font, _, flags = fs:GetFont()
            if font then pcall(fs.SetFont, fs, font, size, flags) end
            local widest = reserved[item.key] or 0
            if item.sample and widest == 0 then
                local okS, sample = pcall(item.sample, size)
                if okS and sample then widest = Measure(fs, sample) end
            end
            -- SetText is one of the operations a secret kills, and everything
            -- reaching it has been laundered -- but it is guarded anyway.
            widest = math.max(widest, Measure(fs, text))
            reserved[item.key] = widest
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", frame, "LEFT", x, 0)
            fs:SetWidth(widest + 2)
            pcall(fs.SetJustifyH, fs, item.justify or "LEFT")
            fs:Show()
            height = math.max(height, ns.Num(fs:GetStringHeight()) or size)
            x = x + widest + gap
            used[item.key] = true
            if item.click or item.hover or item.tooltip or item.enter then
                local button = Hotspot(item)
                button:ClearAllPoints()
                button:SetPoint("LEFT", frame, "LEFT", x - widest - gap, 0)
                button:SetSize(widest + 2, (ns.Num(fs:GetStringHeight()) or size) + 6)
                button:EnableMouse(true)
                button:Show()
            end
            parts[#parts + 1] = text
        end
    end
    for key, fs in pairs(slots) do
        if not used[key] then fs:Hide() end
    end
    for key, line in pairs(dividerLines) do
        if not used[key] then line:Hide() end
    end
    for key, button in pairs(hotspots) do
        if not used[key] then button:Hide() end
    end
    ns.DockTracker(used.tracker and hotspots.tracker or nil)

    local ok, line = pcall(table.concat, parts, "   ")
    lastLine = ok and line or ""

    local width = (#parts > 0) and (x - gap + PAD) or 24
    local frameHeight = math.max(height + 8, 16)
    frame:SetSize(math.max(width, 24), frameHeight)
    for _, line in ipairs(lines) do
        line:SetSize(1, math.max(frameHeight - 4, 4))
    end

    backdrop:SetShown(ns.Get("osdBackground") and true or false)
end

-- Updates are coalesced. BAG_UPDATE fires once per bag and PLAYER_MONEY can
-- arrive several times for one loot, so the events only set a flag and the next
-- frame does the single rebuild that covers all of them.
local function MarkDirty()
    dirty = true
end

local function CreateFrame_OSD()
    if frame then return end

    frame = CreateFrame("Frame", "ChairPlusOSD", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetSize(160, 20)

    backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints()
    backdrop:SetColorTexture(0, 0, 0, 0.45)


    frame:SetScript("OnDragStart", function(self)
        if ns.Get("osdLocked") then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    -- Coordinates, the clock and the frame rate change without an event, so
    -- while any of them is on the line is redrawn four times a second.
    local since, sinceRoster = 0, 0
    frame:SetScript("OnUpdate", function(_, dt)
        since = since + (ns.Num(dt) or 0)
        sinceRoster = sinceRoster + (ns.Num(dt) or 0)
        if since >= 0.25 then
            since = 0
            if WantsTicks() then dirty = true end
        end
        -- Online counts only move when the server sends a roster, and it
        -- sends one only when asked.
        if sinceRoster >= 60 then
            sinceRoster = 0
            if ns.Get("osdSocial") then RequestRosters() end
        end
        if dirty then
            dirty = false
            Refresh()
        end
    end)

    frame:RegisterEvent("PLAYER_MONEY")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("BAG_UPDATE")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    for _, event in ipairs({ "UPDATE_INVENTORY_DURABILITY", "UNIT_INVENTORY_CHANGED",
            "PLAYER_XP_UPDATE", "UPDATE_EXHAUSTION", "PLAYER_LEVEL_UP",
            "UPDATE_PENDING_MAIL", "MAIL_CLOSED", "UNIT_PET", "UNIT_HAPPINESS",
            "PET_UI_UPDATE", "FRIENDLIST_UPDATE", "GUILD_ROSTER_UPDATE",
            "PLAYER_GUILD_UPDATE", "BN_FRIEND_ACCOUNT_ONLINE",
            "BN_FRIEND_ACCOUNT_OFFLINE" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", MarkDirty)
end

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

ns.RegisterModule("osd", {
    title = "On-screen display",
    desc = "Money, bag slots and more on one line on screen.",
    Apply = function(enabled)
        if not enabled then
            if frame then frame:Hide() end
            ns.DockTracker(nil)
            return
        end
        CreateFrame_OSD()

        local scale = ns.Num(ns.Get("osdScale")) or 1
        if scale < 0.5 then scale = 0.5 elseif scale > 3 then scale = 3 end
        frame:SetScale(scale)

        -- Mouse off while locked, so the OSD cannot swallow a click meant for
        -- whatever is behind it. That is the reason it is locked by default.
        local locked = ns.Get("osdLocked") and true or false
        frame:EnableMouse(not locked)
        frame:SetMovable(not locked)
        if locked then
            frame:RegisterForDrag()
        else
            frame:RegisterForDrag("LeftButton")
        end

        ApplyPosition()
        frame:Show()
        if ns.Get("osdSocial") then RequestRosters() end
        Refresh()
    end,
})

-- Let the rest of the addon nudge the display -- selling junk changes both the
-- money and the free slots, and the events for that can lag the sale.
function ns.RefreshOSD()
    MarkDirty()
end
