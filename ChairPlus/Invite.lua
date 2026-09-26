-- ChairPlus Invite.lua
-- Invite whoever sends one of your keywords: "inv" in a whisper and they are
-- in the group.
--
-- Where a keyword counts is up to you -- whispers, Battle.net whispers, guild
-- chat, say and yell -- and so is how: the whole message, or anywhere in it
-- as a word of its own ("can I get an inv please"). A party that is full
-- becomes a raid if you let it. Nothing is sent while you are in a group you
-- cannot invite to, and nobody is invited twice in ten seconds, so a player
-- repeating "inv" does not get a stack of invites.
--
-- The keywords and switches live in their own small window, opened from the
-- Plus page or with /chair plus keywords.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local driver
local lastInvited = {}
local REPEAT_GAP = 10

-------------------------------------------------------------------------------
-- Keywords
-------------------------------------------------------------------------------

local function Trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The keywords, lower case, in the order they were added.
function ns.InviteKeywords()
    local out = {}
    for word in (ns.Get("keywordInviteWords") or ""):gmatch("[^,]+") do
        word = Trim(word):lower()
        if word ~= "" then out[#out + 1] = word end
    end
    return out
end

local function SaveKeywords(list)
    ns.Set("keywordInviteWords", table.concat(list, ","))
end

-- False, and why, when the word is empty or already there. Commas separate
-- the saved list, so they cannot be part of a keyword.
function ns.AddInviteKeyword(word)
    word = Trim(tostring(word or ""):gsub(",", " ")):lower()
    if word == "" then return false, "type a keyword first" end
    local list = ns.InviteKeywords()
    for _, have in ipairs(list) do
        if have == word then return false, "already a keyword" end
    end
    list[#list + 1] = word
    SaveKeywords(list)
    return true
end

function ns.RemoveInviteKeyword(word)
    local list, out = ns.InviteKeywords(), {}
    for _, have in ipairs(list) do
        if have ~= word then out[#out + 1] = have end
    end
    SaveKeywords(out)
end

local function Escape(text)
    return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- The keyword this message asks with, or nil.
function ns.InviteKeywordIn(message)
    message = ns.Text(message)
    if not message then return nil end
    local text = Trim(message:lower())
    -- "inv!" and "inv pls" read the same as "inv" when the whole message has
    -- to match: trailing punctuation is not part of what was asked.
    local bare = Trim((text:gsub("[%p%s]+$", "")))
    local exact = ns.Get("keywordInviteExact")
    for _, word in ipairs(ns.InviteKeywords()) do
        if exact then
            if text == word or bare == word then return word end
        elseif (" " .. text .. " "):find("[^%w]" .. Escape(word) .. "[^%w]") then
            return word
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Inviting
-------------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function Yes(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, ...)
    return ok and value and true or false
end

local function GroupSize()
    local ok, n = pcall(_G.GetNumGroupMembers)
    return ok and ns.Num(n) or 0
end

-- True when this player may send an invite right now, or false and why.
local function CanInvite()
    if GroupSize() == 0 then return true end
    if Yes(_G.UnitIsGroupLeader, "player") then return true end
    if Yes(_G.IsInRaid) and Yes(_G.UnitIsGroupAssistant, "player") then return true end
    return false, "you are not the group leader"
end

-- Makes room, or says why there is none.
local function MakeRoom()
    local size, raid = GroupSize(), Yes(_G.IsInRaid)
    if raid then
        if size >= 40 then return false, "the raid is full" end
        return true
    end
    if size < 5 then return true end
    if not ns.Get("keywordInviteRaid") then return false, "the party is full" end
    local party = _G.C_PartyInfo
    local convert = (party and party.ConvertToRaid) or _G.ConvertToRaid
    if not Call(convert) then return false, "the party is full and could not become a raid" end
    ns.Print("Party full -- turned it into a raid.")
    return true
end

local function Bare(name)
    return name and name:match("^[^%-]+") or nil
end

local function AlreadyGrouped(name)
    return Yes(_G.UnitInParty, name) or Yes(_G.UnitInRaid, name)
        or Yes(_G.UnitInParty, Bare(name)) or Yes(_G.UnitInRaid, Bare(name))
end

local function Invite(name, word)
    name = ns.Text(name)
    if not name or name == "" then return end
    local okMe, me = pcall(_G.UnitName, "player")
    if okMe and (name == me or Bare(name) == me) then return end

    local now = ns.Num(GetTime()) or 0
    if lastInvited[name] and now - lastInvited[name] < REPEAT_GAP then return end

    if AlreadyGrouped(name) then return end
    local can, why = CanInvite()
    if can then can, why = MakeRoom() end
    if not can then
        ns.Print(string.format("%s asked for an invite (\"%s\") but %s.", name, word, why))
        return
    end

    local party = _G.C_PartyInfo
    local invite = (party and party.InviteUnit) or _G.InviteUnit
    if Call(invite, name) then
        lastInvited[name] = now
        ns.Print(string.format("Invited %s (\"%s\").", name, word))
    end
end

-- A Battle.net whisper names an account, not a character: the invite goes to
-- whoever they are playing, if it is WoW.
local function BattleNetCharacter(accountID)
    local bnet = _G.C_BattleNet
    if not (bnet and type(bnet.GetAccountInfoByID) == "function") then return nil end
    local ok, info = pcall(bnet.GetAccountInfoByID, accountID)
    local game = ok and type(info) == "table" and info.gameAccountInfo
    if type(game) ~= "table" or not game.isOnline then return nil end
    local name = ns.Text(game.characterName)
    if not name then return nil end
    local realm = ns.Text(game.realmName)
    return realm and (name .. "-" .. realm) or name
end

local SOURCES = {
    CHAT_MSG_WHISPER = "keywordInviteWhisper",
    CHAT_MSG_BN_WHISPER = "keywordInviteBNet",
    CHAT_MSG_GUILD = "keywordInviteGuild",
    CHAT_MSG_SAY = "keywordInviteSay",
    CHAT_MSG_YELL = "keywordInviteSay",
}

local function OnChat(event, message, sender, ...)
    local word = ns.InviteKeywordIn(message)
    if not word then return end
    if event == "CHAT_MSG_BN_WHISPER" then
        -- The account's ID is the 13th argument, 11 after the sender.
        local accountID = select(11, ...)
        sender = BattleNetCharacter(accountID)
        if not sender then return end
    end
    Invite(sender, word)
end

ns.RegisterModule("keywordInvite", {
    title = "Invite on keyword",
    desc = "Invite players who send one of your keywords.",
    Apply = function(enabled)
        if not driver then
            driver = CreateFrame("Frame")
            driver:SetScript("OnEvent", function(_, event, ...)
                local ok, err = pcall(OnChat, event, ...)
                if not ok then ns.Print("|cffff5555Keyword invite failed:|r", ns.Text(err)) end
            end)
        end
        for event, key in pairs(SOURCES) do
            if enabled and ns.Get(key) then
                pcall(driver.RegisterEvent, driver, event)
            else
                pcall(driver.UnregisterEvent, driver, event)
            end
        end
        if ns.RefreshKeywordPanel then ns.RefreshKeywordPanel() end
    end,
})

-------------------------------------------------------------------------------
-- The keyword window
-------------------------------------------------------------------------------
-- Built the first time it is opened, with the menu's own buttons and
-- checkboxes (Commands.lua lends them), so it looks like the rest.

local window
local ROWS_SHOWN = 8
local listOffset = 0

local SWITCHES = {
    { key = "keywordInvite",        label = "Invite on keyword" },
    { key = "keywordInviteWhisper", label = "Whispers",            sub = true },
    { key = "keywordInviteBNet",    label = "Battle.net whispers", sub = true },
    { key = "keywordInviteGuild",   label = "Guild chat",          sub = true },
    { key = "keywordInviteSay",     label = "Say and yell",        sub = true },
    { key = "keywordInviteExact",   label = "Whole message must match", sub = true },
    { key = "keywordInviteRaid",    label = "Make a raid when the party is full", sub = true },
}

function ns.RefreshKeywordPanel()
    if not window or not window:IsShown() then return end
    local on = ns.IsEnabled("keywordInvite")
    for _, entry in ipairs(window.switches) do
        entry.check:SetChecked(ns.IsEnabled(entry.key))
        local live = not entry.sub or on
        entry.check:SetEnabled(live)
        local shade = live and 1 or 0.5
        entry.label:SetTextColor(shade, shade, shade)
    end

    local words = ns.InviteKeywords()
    listOffset = math.max(0, math.min(listOffset, #words - ROWS_SHOWN))
    for i, row in ipairs(window.rows) do
        local word = words[i + listOffset]
        row.word = word
        row.label:SetText(word and (word:gsub("|", "||")) or "")
        row.remove:SetShown(word ~= nil)
        row.label:SetShown(word ~= nil)
    end
    window.empty:SetShown(#words == 0)
    window.more:SetText(#words > ROWS_SHOWN
        and string.format("%d-%d of %d, scroll for more", listOffset + 1,
            math.min(#words, listOffset + ROWS_SHOWN), #words) or "")
end

local function BuildWindow()
    if window then return window end
    local MakeButton, MakeCheckButton = ns.MakeButton, ns.MakeCheckButton

    window = CreateFrame("Frame", "ChairPlusKeywordPanel", UIParent)
    window:SetFrameStrata("DIALOG")
    window:SetSize(300, 470)
    window:SetPoint("CENTER")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetScript("OnShow", function() ns.RefreshKeywordPanel() end)
    -- Escape closes it, like the game's own windows.
    if type(_G.UISpecialFrames) == "table" then
        table.insert(_G.UISpecialFrames, "ChairPlusKeywordPanel")
    end

    local bg = window:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.96)

    local title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("|cff9d7cffInvite keywords|r")

    local close = MakeButton(window, 22, "x")
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetScript("OnClick", function() window:Hide() end)

    window.switches = {}
    local y = -44
    for _, switch in ipairs(SWITCHES) do
        local check = MakeCheckButton(window)
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", switch.sub and 32 or 14, y)
        local label = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        label:SetText(switch.label)
        local key = switch.key
        check:SetScript("OnClick", function(self)
            ns.Set(key, self:GetChecked() and true or false)
            ns.RefreshKeywordPanel()
        end)
        window.switches[#window.switches + 1] = { key = key, sub = switch.sub, check = check, label = label }
        y = y - 24
    end

    local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, y - 8)
    hint:SetText("Add a keyword, then press Add or Enter.")

    local box = CreateFrame("EditBox", nil, window)
    box:SetSize(190, 22)
    box:SetPoint("TOPLEFT", 16, y - 26)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlight")
    box:SetMaxLetters(40)
    box:SetTextInsets(6, 6, 0, 0)
    local boxBg = box:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints()
    boxBg:SetColorTexture(1, 1, 1, 0.08)
    local function AddTyped()
        local ok, why = ns.AddInviteKeyword(box:GetText())
        if ok then
            box:SetText("")
            ns.RefreshKeywordPanel()
        else
            ns.Print("Keyword not added: " .. why .. ".")
        end
    end
    box:SetScript("OnEnterPressed", AddTyped)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    window.box = box

    local add = MakeButton(window, 70, "Add")
    add:SetPoint("LEFT", box, "RIGHT", 8, 0)
    add:SetScript("OnClick", AddTyped)

    -- The list: a fixed set of rows, scrolled with the mouse wheel.
    local listTop = y - 58
    window.rows = {}
    for i = 1, ROWS_SHOWN do
        local rowY = listTop - (i - 1) * 24
        local remove = MakeButton(window, 22, "x")
        remove:SetPoint("TOPLEFT", 16, rowY)
        local label = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", remove, "RIGHT", 8, 0)
        label:SetWidth(230)
        label:SetJustifyH("LEFT")
        local row = { remove = remove, label = label }
        remove:SetScript("OnClick", function()
            if row.word then ns.RemoveInviteKeyword(row.word) end
            ns.RefreshKeywordPanel()
        end)
        window.rows[i] = row
    end
    window:EnableMouseWheel(true)
    window:SetScript("OnMouseWheel", function(_, delta)
        listOffset = listOffset - (ns.Num(delta) or 0)
        ns.RefreshKeywordPanel()
    end)

    local empty = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 16, listTop - 4)
    empty:SetText("No keywords yet.")
    window.empty = empty

    local more = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    more:SetPoint("TOPLEFT", 16, listTop - ROWS_SHOWN * 24 - 4)
    window.more = more

    window:Hide()
    return window
end

function ns.ToggleKeywordPanel()
    BuildWindow()
    if window:IsShown() then window:Hide() else window:Show() end
    ns.RefreshKeywordPanel()
end
