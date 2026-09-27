-- ChairPlus Social.lua
-- Answering the popups other players and the game throw at you:
--
--   group invites  accepted from friends and guildmates, left alone otherwise
--   duels          declined
--   guild invites  declined
--   resurrection   accepted
--   summons        accepted
--
-- and filtering the red error text that spams the middle of the screen while
-- you mash a button ("Not enough rage", "Spell is not ready yet").
--
-- Each is its own switch, all off out of the box. Holding shift when the popup
-- arrives leaves it to you, the same as quest and gossip automation. Every
-- call is looked up when used and made inside a pcall: these APIs have moved
-- between the clients in the TOC, and a missing one should cost that one
-- answer, not the module.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local driver

local function Shift()
    local ok, down = pcall(_G.IsShiftKeyDown)
    return (ok and down) and true or false
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function HidePopup(which)
    if type(_G.StaticPopup_Hide) == "function" then pcall(_G.StaticPopup_Hide, which) end
end

-- "Name" from "Name-Realm", for comparing against lists that leave the realm
-- off for your own.
local function Bare(name)
    name = ns.Text(name)
    return name and name:match("^[^%-]+") or nil
end

-------------------------------------------------------------------------------
-- Who is a friend, who is in the guild
-------------------------------------------------------------------------------

local function IsFriend(name, guid)
    local list = _G.C_FriendList
    if list and guid and type(list.IsFriend) == "function" then
        local ok, yes = pcall(list.IsFriend, guid)
        if ok and yes then return true end
    end
    local want = Bare(name)
    if not want or not list then return false end
    local okN, count = Call(list.GetNumFriends)
    count = okN and ns.Num(count) or 0
    for i = 1, count do
        local ok, info = Call(list.GetFriendInfoByIndex, i)
        if ok and type(info) == "table" and Bare(info.name) == want then return true end
    end
    return false
end

local function IsGuildmate(name, guid)
    if guid and type(_G.IsGuildMember) == "function" then
        local ok, yes = pcall(_G.IsGuildMember, guid)
        if ok and yes then return true end
    end
    local want = Bare(name)
    local okG, inGuild = Call(_G.IsInGuild)
    if not want or not (okG and inGuild) then return false end
    local okN, count = Call(_G.GetNumGuildMembers)
    count = okN and ns.Num(count) or 0
    for i = 1, count do
        local ok, member = Call(_G.GetGuildRosterInfo, i)
        if ok and Bare(member) == want then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- The answers
-------------------------------------------------------------------------------

local function OnPartyInvite(name, guid)
    if not ns.Get("autoInvite") or Shift() then return end
    name = ns.Text(name)
    guid = ns.Text(guid)
    local why
    if ns.Get("autoInviteFriends") and IsFriend(name, guid) then
        why = "a friend"
    elseif ns.Get("autoInviteGuild") and IsGuildmate(name, guid) then
        why = "a guildmate"
    end
    if not why then return end
    if Call(_G.AcceptGroup) then
        HidePopup("PARTY_INVITE")
        HidePopup("PARTY_INVITE_XREALM")
    end
end

local function OnDuel(name)
    if not ns.Get("declineDuels") or Shift() then return end
    if Call(_G.CancelDuel) then
        HidePopup("DUEL_REQUESTED")
    end
end

local function OnGuildInvite(inviter, guild)
    if not ns.Get("declineGuildInvites") or Shift() then return end
    if Call(_G.DeclineGuild) then
        HidePopup("GUILD_INVITE")
    end
end

local function OnResurrect(name)
    if not ns.Get("autoResurrect") or Shift() then return end
    if Call(_G.AcceptResurrect) then
        HidePopup("RESURRECT")
        HidePopup("RESURRECT_NO_SICKNESS")
        HidePopup("RESURRECT_NO_TIMER")
    end
end

local function OnSummon()
    if not ns.Get("autoSummon") or Shift() then return end
    -- The retail engine moved it into C_SummonInfo; older clients have the
    -- global. Whichever is here answers.
    local info = _G.C_SummonInfo
    local confirm = (info and info.ConfirmSummon) or _G.ConfirmSummon
    if Call(confirm) then
        HidePopup("CONFIRM_SUMMON")
    end
end

-------------------------------------------------------------------------------
-- Error spam
-------------------------------------------------------------------------------
-- While the filter is on, UIErrorsFrame stops hearing UI_ERROR_MESSAGE and
-- this module hears it instead, dropping the spam and writing everything else
-- onto the frame with its plain AddMessage, in the red it uses -- so a real
-- error ("Inventory is full") still shows. Switching the filter off hands the
-- event back.
--
-- It used to hand those on to the frame's own Lua handler instead, which is
-- Blizzard's code run from ours: the kind of call that taints a frame on this
-- client (removed 2026-09-26). AddMessage is the widget's own method, not
-- Blizzard Lua. What that costs: the error's spoken "not enough rage" is not
-- replayed while filtering.
--
-- Matched against the client's own strings, so it works in any language.
local SPAM = {
    "ERR_OUT_OF_RAGE", "ERR_OUT_OF_ENERGY", "ERR_OUT_OF_MANA", "ERR_OUT_OF_FOCUS",
    "ERR_ABILITY_COOLDOWN", "ERR_SPELL_COOLDOWN", "ERR_ITEM_COOLDOWN",
    "SPELL_FAILED_SPELL_IN_PROGRESS", "ERR_NO_ATTACK_TARGET", "SPELL_FAILED_NO_COMBO_POINTS",
    "ERR_GENERIC_NO_TARGET", "SPELL_FAILED_TARGETS_DEAD", "ERR_INVALID_ATTACK_TARGET",
}

local spamText
local function SpamText()
    if spamText then return spamText end
    spamText = {}
    for _, key in ipairs(SPAM) do
        local text = ns.Text(_G[key])
        if text then spamText[text] = true end
    end
    return spamText
end

-- True for a message the filter drops. A message that cannot be read (a
-- secret) is never dropped: better one error too many than one too few.
function ns.IsErrorSpam(message)
    local text = ns.Text(message)
    return text ~= nil and SpamText()[text] == true
end

local filtering = false

local function ErrorFilter(on)
    local errors = _G.UIErrorsFrame
    if not errors or on == filtering then return end
    if on then
        if type(errors.AddMessage) ~= "function" then return end
        pcall(errors.UnregisterEvent, errors, "UI_ERROR_MESSAGE")
        pcall(driver.RegisterEvent, driver, "UI_ERROR_MESSAGE")
    else
        pcall(driver.UnregisterEvent, driver, "UI_ERROR_MESSAGE")
        pcall(errors.RegisterEvent, errors, "UI_ERROR_MESSAGE")
    end
    filtering = on
end

local function OnError(...)
    -- Only while filtering: the error frame is hearing the event itself again.
    if not filtering then return end
    -- The message is the second argument on the retail engine (after the
    -- message type) and the first on older clients: whichever is a string.
    local a, b = ...
    local message = (type(b) == "string" and b) or a
    if ns.IsErrorSpam(message) then return end
    local errors = _G.UIErrorsFrame
    local text = ns.Text(message)
    if errors and text then
        pcall(errors.AddMessage, errors, text, 1.0, 0.1, 0.1, 1.0)
    end
end

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

local HANDLERS = {
    PARTY_INVITE_REQUEST = function(name, _, _, _, _, _, guid) OnPartyInvite(name, guid) end,
    DUEL_REQUESTED = OnDuel,
    GUILD_INVITE_REQUEST = OnGuildInvite,
    RESURRECT_REQUEST = OnResurrect,
    CONFIRM_SUMMON = OnSummon,
    UI_ERROR_MESSAGE = OnError,
}

local EVENT_SETTING = {
    PARTY_INVITE_REQUEST = "autoInvite",
    DUEL_REQUESTED = "declineDuels",
    GUILD_INVITE_REQUEST = "declineGuildInvites",
    RESURRECT_REQUEST = "autoResurrect",
    CONFIRM_SUMMON = "autoSummon",
}

-- One module for several switches, so its own key is not a setting: Apply
-- reads each switch and listens only for the events those switches need.
ns.RegisterModule("social", {
    title = "Invites, duels and resurrection",
    desc = "Accept group invites from friends and guildmates, decline duels and "
        .. "guild invites, accept resurrection and summons, filter error spam.",
    Apply = function()
        if not driver then
            driver = CreateFrame("Frame")
            driver:SetScript("OnEvent", function(_, event, ...)
                local handler = HANDLERS[event]
                if handler then
                    local ok, err = pcall(handler, ...)
                    if not ok then
                        ns.Print("|cffff5555" .. event .. " handler failed:|r", ns.Text(err))
                    end
                end
            end)
        end
        for event, key in pairs(EVENT_SETTING) do
            if ns.Get(key) then
                pcall(driver.RegisterEvent, driver, event)
            else
                pcall(driver.UnregisterEvent, driver, event)
            end
        end
        ErrorFilter(ns.Get("filterErrors") and true or false)
    end,
})
