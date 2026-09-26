-- ChairPlus Quests.lua
-- Select, accept and turn in quests automatically.
--
-- The safety checks are the substance of this file, not the automation. Picking
-- up a quest is free and always reversible; handing one in is not. A turn-in
-- can spend gold, consume a currency, eat a stack of crafting reagents or take
-- an account-bound item, and none of that can be undone by abandoning anything.
-- So every refusal below stays in even where it costs a convenience.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

local qFrame

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return unpack(results, 2)
end

-- The NPC we are talking to, as the ID string the blocklists are keyed by.
-- UnitGUID is documented as not secret on this build, but it is read through a
-- guard anyway: this runs inside a quest event, which is exactly the tainted
-- call stack where a value that normally behaves starts throwing.
local function CurrentNpcID()
    local guid = Call("UnitGUID", "npc")
    if guid == nil then return nil end
    if ns.IsSecret(guid) then return nil end
    -- A creature GUID is Creature-0-<server>-<instance>-<zone>-<npcID>-<spawn>,
    -- so the ID is the sixth field. pcall puts its own success flag in front of
    -- those, which is why there are six placeholders here and not five.
    local ok, _, _, _, _, _, npcID = pcall(strsplit, "-", guid)
    if not ok then return nil end
    return ns.Text(npcID)
end

-- actionType is "Select", "Accept" or "Complete". Anything on the main list is
-- blocked for all three; the select-only list covers NPCs whose quests are
-- harmless to finish but whose quest list must not be opened automatically,
-- because the only thing those quests do is consume an item you are carrying.
local function IsNpcBlocked(actionType)
    local npcID = CurrentNpcID()
    if not npcID then return false end
    if ns.blockedNPCs[npcID] then return true end
    if actionType == "Select" and ns.blockedSelectNPCs[npcID] then return true end
    return false
end

local function QuestRequiresGold()
    local amount = ns.Num(Call("GetQuestMoneyToGet"))
    return amount ~= nil and amount > 0
end

local function IsItemAccountBound(itemID)
    local info = _G.C_TooltipInfo
    if not info or type(info.GetItemByID) ~= "function" then return false end
    local ok, data = pcall(info.GetItemByID, itemID)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return false end
    for _, line in ipairs(data.lines) do
        local text = line and ns.Text(line.leftText)
        if text and (text == _G.ITEM_BNETACCOUNTBOUND
            or text == _G.ITEM_BIND_TO_BNETACCOUNT
            or text == _G.ITEM_BIND_TO_ACCOUNT
            or text == _G.ITEM_ACCOUNTBOUND) then
            return true
        end
    end
    return false
end

-- True if the quest in the progress window wants something back that should be
-- a deliberate decision: a currency, a crafting reagent, or an account-bound
-- item. Reads the progress frames rather than any quest data, because that is
-- the only place the required-item list is exposed at this point.
local function QuestRequiresSomethingPrecious()
    for i = 1, 6 do
        local progItem = _G["QuestProgressItem" .. i]
        if progItem and progItem:IsShown() and progItem.type == "required" then
            if progItem.objectType == "currency" then
                return true
            elseif progItem.objectType == "item" then
                local name, _, _, _, _, itemID = Call("GetQuestItemInfo", "required", i)
                if name and itemID then
                    local getInfo = ns.GetItemInfo
                    if type(getInfo) == "function" then
                        local ok, r = pcall(function()
                            return select(17, getInfo(itemID))
                        end)
                        if ok and r then return true end
                    end
                    if IsItemAccountBound(itemID) then return true end
                end
            end
        end
    end
    return false
end

-- One gate in front of every turn-in path, so a new one cannot be added later
-- without inheriting the refusals.
local function MayTurnIn()
    if not ns.Get("questsTurnIn") then return false end
    if IsNpcBlocked("Complete") then return false end
    if QuestRequiresSomethingPrecious() then return false end
    if QuestRequiresGold() then return false end
    return true
end

local function MayAcceptAnything()
    return ns.Get("questsAccept") or ns.Get("questsDaily") or ns.Get("questsWeekly")
end

-- Quest frequency constants, which only exist as an Enum on newer clients.
local FREQ = _G.Enum and _G.Enum.QuestFrequency or nil
local FREQ_DEFAULT = FREQ and FREQ.Default or 1
local FREQ_DAILY   = FREQ and FREQ.Daily or 2
local FREQ_WEEKLY  = FREQ and FREQ.Weekly or 3

local function WantFrequency(frequency)
    if frequency == FREQ_DAILY then return ns.Get("questsDaily") and true or false end
    if frequency == FREQ_WEEKLY then return ns.Get("questsWeekly") and true or false end
    return ns.Get("questsAccept") and true or false
end

local function IsQuestBlocked(questID)
    if not questID then return false end
    return ns.blockedQuests[questID] and true or false
end

-------------------------------------------------------------------------------
-- Event handling
-------------------------------------------------------------------------------

local function OnQuestDetail()
    if not MayAcceptAnything() then return end

    local isDaily = Call("QuestIsDaily")
    local isWeekly = Call("QuestIsWeekly")

    if isDaily then
        if not ns.Get("questsDaily") then return end
    elseif isWeekly then
        if not ns.Get("questsWeekly") then return end
    else
        if not ns.Get("questsAccept") then return end
    end

    if IsNpcBlocked("Accept") then return end

    if Call("QuestGetAutoAccept") then
        -- The client already took this one; all that is left is the window.
        Call("CloseQuest")
    else
        Call("AcceptQuest")
    end
end

local function OnGossipOrGreeting(event)
    local greetingShown = _G.QuestFrameGreetingPanel and _G.QuestFrameGreetingPanel:IsShown()
    if not Call("UnitExists", "npc") and not greetingShown then return end

    -- A gossip option carrying a colour code or angle brackets is a special
    -- one -- a dungeon skip, a flight path, a vendor -- and selecting a quest
    -- past it is how automation walks someone into a choice they did not make.
    local gossip = _G.C_GossipInfo
    if gossip and type(gossip.GetOptions) == "function" then
        local ok, options = pcall(gossip.GetOptions)
        if ok and type(options) == "table" then
            for i = 1, #options do
                local nameText = options[i] and ns.Text(options[i].name)
                if nameText then
                    local upper = strupper(nameText)
                    if string.find(upper, "|C", 1, true) or string.find(upper, "<", 1, true) then
                        return
                    end
                end
            end
        end
    end

    if IsNpcBlocked("Select") then return end

    if event == "QUEST_GREETING" then
        if ns.Get("questsTurnIn") and not IsNpcBlocked("Complete") then
            local num = ns.Num(Call("GetNumActiveQuests")) or 0
            for i = 1, num do
                local title, isComplete = Call("GetActiveTitle", i)
                if title and isComplete then
                    return Call("SelectActiveQuest", i)
                end
            end
        end
        if MayAcceptAnything() then
            local num = ns.Num(Call("GetNumAvailableQuests")) or 0
            for i = 1, num do
                local title, isComplete = Call("GetAvailableTitle", i)
                if title and not isComplete then
                    local _, frequency = Call("GetAvailableQuestInfo", i)
                    if WantFrequency(frequency or FREQ_DEFAULT) then
                        return Call("SelectAvailableQuest", i)
                    end
                end
            end
        end
        return
    end

    if not gossip then return end

    if ns.Get("questsTurnIn") and not IsNpcBlocked("Complete")
        and type(gossip.GetActiveQuests) == "function" then
        local ok, quests = pcall(gossip.GetActiveQuests)
        if ok and type(quests) == "table" then
            for _, questInfo in ipairs(quests) do
                if questInfo.title and questInfo.isComplete and questInfo.questID then
                    return pcall(gossip.SelectActiveQuest, questInfo.questID)
                end
            end
        end
    end

    if MayAcceptAnything() and type(gossip.GetAvailableQuests) == "function" then
        local ok, quests = pcall(gossip.GetAvailableQuests)
        if ok and type(quests) == "table" then
            for _, questInfo in ipairs(quests) do
                if WantFrequency(questInfo.frequency or FREQ_DEFAULT)
                    and questInfo.questID and not IsQuestBlocked(questInfo.questID) then
                    return pcall(gossip.SelectAvailableQuest, questInfo.questID)
                end
            end
        end
    end
end

local function OnEvent(_, event, arg1)
    -- Progress frames are reused between NPCs and are not cleared by the
    -- client, so a stale "required item" row from the last conversation would
    -- otherwise keep blocking turn-ins at the next one.
    if event == "QUEST_FINISHED" then
        for i = 1, 6 do
            local progItem = _G["QuestProgressItem" .. i]
            if progItem and progItem:IsShown() then progItem:Hide() end
        end
        return
    end

    -- The manual override. Holding shift stops everything here without needing
    -- to open an options panel mid-conversation, which is the only practical
    -- way to take one quest by hand.
    if ns.Get("questsShiftOverride") and Call("IsShiftKeyDown") then return end

    if event == "QUEST_DETAIL" then
        OnQuestDetail()

    elseif event == "QUEST_ACCEPT_CONFIRM" then
        -- Shared and escort quests. Only ever an accept, never a turn-in.
        if ns.Get("questsAccept") then
            Call("ConfirmAcceptQuest")
            Call("StaticPopup_Hide", "QUEST_ACCEPT")
        end

    elseif event == "QUEST_PROGRESS" then
        if Call("IsQuestCompletable") and MayTurnIn() then
            Call("CompleteQuest")
        end

    elseif event == "QUEST_COMPLETE" then
        if MayTurnIn() then
            local choices = ns.Num(Call("GetNumQuestChoices")) or 0
            -- More than one reward on offer is a decision, and picking for
            -- someone is worse than making them click.
            if choices <= 1 then
                Call("GetQuestReward", choices)
            end
        end

    elseif event == "QUEST_AUTOCOMPLETE" then
        if not ns.Get("questsTurnIn") then return end
        local log = _G.C_QuestLog
        if not log then return end
        local ok, index = pcall(log.GetLogIndexForQuestID, arg1)
        if not ok or not index then return end
        local okInfo, info = pcall(log.GetInfo, index)
        if okInfo and info and info.isAutoComplete then
            pcall(log.SetSelectedQuest, arg1)
            Call("ShowQuestComplete", arg1)
        end

    elseif event == "GOSSIP_SHOW" or event == "QUEST_GREETING" then
        OnGossipOrGreeting(event)
    end
end

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

local EVENTS = {
    "QUEST_DETAIL", "QUEST_ACCEPT_CONFIRM", "QUEST_PROGRESS", "QUEST_COMPLETE",
    "QUEST_GREETING", "QUEST_AUTOCOMPLETE", "GOSSIP_SHOW", "QUEST_FINISHED",
}

ns.RegisterModule("quests", {
    title = "Automate quests",
    desc = "Select, accept and turn in quests. Hold shift to do one by hand.",
    Apply = function(enabled)
        if not qFrame then
            qFrame = CreateFrame("Frame")
            qFrame:SetScript("OnEvent", OnEvent)
        end
        if enabled then
            for i = 1, #EVENTS do qFrame:RegisterEvent(EVENTS[i]) end
        else
            qFrame:UnregisterAllEvents()
        end
    end,
})
