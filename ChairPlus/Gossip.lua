-- ChairPlus Gossip.lua
-- Skip the one-option gossip window.
--
-- There is no curated NPC blocklist to lean on, so the safety has to come from
-- the rule itself, and the rule is deliberately narrow:
--
--   * exactly one gossip option on offer, and
--   * no quests attached to the window at all, and
--   * the option is not one of the kinds that costs something.
--
-- Anything else is left alone. A gossip window with two options is a choice, and
-- a choice made for you by an addon is the thing people uninstall addons over.
--
-- The quest check is not redundant with Quests.lua. That module selects quests
-- out of a gossip window; this one must not fire first and close the window
-- underneath it.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

local gossipFrame

-- Option types that are never auto-selected, whatever else is true.
--
-- Every one of these either spends money, moves the player, or commits them to
-- something that is awkward to undo. A taxi flight is the clearest case: one
-- option, no quests, and selecting it charges gold and flies you somewhere.
-- The enum is newer than some of the clients in the TOC, so each name is looked
-- up rather than assumed, and an unknown name simply never matches.
local BLOCKED_TYPE_NAMES = {
    "Taxi",         -- flight master; costs gold and moves you
    "Vendor",       -- opens a shop, but some are "pay to browse"
    "Trainer",      -- class/profession trainer
    "Binder",       -- innkeeper: rebinds your hearthstone
    "Banker",
    "Battlemaster", -- queues you
    "Petition",
    "Tabard",
    "Auctioneer",
    "StableMaster",
    "Transmogrifier",
}

local blockedTypes = {}
do
    local enum = _G.Enum and _G.Enum.GossipOptionRewardType
    local optionType = _G.Enum and _G.Enum.GossipOptionType
    for _, name in ipairs(BLOCKED_TYPE_NAMES) do
        -- Different generations put this enum in different places, and on some
        -- clients the option carries a plain string instead. Record every form
        -- so the lookup below can match whichever one turns up.
        blockedTypes[name] = true
        blockedTypes[name:lower()] = true
        if optionType and optionType[name] ~= nil then
            blockedTypes[optionType[name]] = true
        end
        if enum and enum[name] ~= nil then
            blockedTypes[enum[name]] = true
        end
    end
end

local function IsBlockedOption(option)
    if type(option) ~= "table" then return true end

    -- Any of these fields may carry the kind, depending on the client.
    for _, key in ipairs({ "type", "gossipOptionType", "flags", "icon" }) do
        local value = option[key]
        if value ~= nil and blockedTypes[value] then return true end
    end

    local name = ns.Text(option.name)
    if not name or name == "" then return true end

    -- A coloured or bracketed option is a special one -- a dungeon skip, a
    -- scripted choice, a warning -- and the same rule already guards quest
    -- selection in Quests.lua.
    local upper = strupper(name)
    if string.find(upper, "|C", 1, true) or string.find(upper, "<", 1, true) then
        return true
    end

    return false
end

-- True if this window has any quest on it. Quests.lua owns those.
local function HasQuests()
    local gossip = _G.C_GossipInfo
    if not gossip then return true end

    for _, fn in ipairs({ "GetAvailableQuests", "GetActiveQuests" }) do
        if type(gossip[fn]) == "function" then
            local ok, quests = pcall(gossip[fn])
            if not ok then return true end
            if type(quests) == "table" and #quests > 0 then return true end
        end
    end

    -- The pre-gossip quest frames, for the clients that use them.
    local numAvailable = ns.Num(_G.GetNumAvailableQuests and GetNumAvailableQuests())
    local numActive = ns.Num(_G.GetNumActiveQuests and GetNumActiveQuests())
    if (numAvailable or 0) > 0 or (numActive or 0) > 0 then return true end

    return false
end

local function OnGossipShow()
    if not ns.Get("autoGossip") then return end

    -- Same escape hatch as the rest of the merchant and quest automation.
    if ns.Get("autoGossipShiftOverride") and _G.IsShiftKeyDown and IsShiftKeyDown() then
        return
    end

    local gossip = _G.C_GossipInfo
    if not gossip or type(gossip.GetOptions) ~= "function" then return end

    local ok, options = pcall(gossip.GetOptions)
    if not ok or type(options) ~= "table" then return end

    -- Exactly one. Not "the first of several".
    if #options ~= 1 then return end
    if HasQuests() then return end
    if IsBlockedOption(options[1]) then return end

    local option = options[1]
    local selected = false

    -- Newer clients select by ID, older ones by index. Try the ID first,
    -- because an index is positional and this is the one call that commits.
    if option.gossipOptionID ~= nil and type(gossip.SelectOption) == "function" then
        selected = pcall(gossip.SelectOption, option.gossipOptionID)
    elseif option.orderIndex ~= nil and type(gossip.SelectOption) == "function" then
        selected = pcall(gossip.SelectOption, option.orderIndex)
    elseif type(_G.SelectGossipOption) == "function" then
        selected = pcall(_G.SelectGossipOption, 1)
    end

    if selected and ns.Get("autoGossipSummary") then
        ns.Print("Skipped gossip:", ns.Text(option.name) or "?")
    end
end

ns.RegisterModule("autoGossip", {
    title = "Skip single-option gossip",
    desc = "Take the only option when a gossip window has exactly one and no quests.",
    Apply = function(enabled)
        if not gossipFrame then
            gossipFrame = CreateFrame("Frame")
            gossipFrame:SetScript("OnEvent", OnGossipShow)
        end
        if enabled then
            gossipFrame:RegisterEvent("GOSSIP_SHOW")
        else
            gossipFrame:UnregisterAllEvents()
        end
    end,
})
