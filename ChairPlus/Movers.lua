-- ChairPlus Movers.lua
-- Blizzard's windows -- the character panel, bank, auction house, professions,
-- quest log, spellbook, talents, mail, merchant, trainer, friends, the group
-- finder and the rest in TARGETS below -- and the combined backpack, all
-- draggable by their headers.
--
-- Always on: there is nothing to switch, only somewhere to put them. A thin
-- handle is laid over each window's title strip, so dragging works from the
-- header and nowhere else -- a click on a bag slot or the paper doll is never
-- taken for the start of a drag.
--
-- Blizzard puts both windows back where it thinks they belong every time it
-- lays out the screen: the character panel, the bank, the auction house and
-- the profession window through the UI panel manager
-- (UpdateUIPanelPositions), the bags through UpdateContainerFrameAnchors. So
-- the saved spot is re-applied after each of those, and after each show. A
-- window with no saved spot is left entirely to Blizzard.
--
-- Positions are saved per character, in this character's ChairPlusDB profile,
-- as an offset from the screen centre. "/chair plus movers reset" hands them all back to Blizzard.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local HEADER_H = 24

-- name -> how Blizzard re-lays it out.
local TARGETS = {
    { name = "CharacterFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "BankFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    -- The auction house UI loads on demand, so this frame only exists after
    -- its first visit; ADDON_LOADED and AUCTION_HOUSE_SHOW both catch that.
    -- Newer clients call it AuctionHouseFrame, older ones AuctionFrame;
    -- whichever this client lacks is simply skipped.
    { name = "AuctionHouseFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "AuctionFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    -- The profession window loads on demand too, on the first time a
    -- profession is opened. Classic splits it in two: TradeSkillFrame for
    -- most professions, CraftFrame for enchanting and beast training; newer
    -- clients use ProfessionsFrame. Absent ones are skipped, as above.
    { name = "TradeSkillFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "CraftFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "ProfessionsFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "ContainerFrameCombinedBags", layout = "UpdateContainerFrameAnchors", insetLeft = 58 },

    -- The rest of the panel-manager windows. Several have had more than one
    -- name across the clients in the TOC, so every name is listed and the ones
    -- this client lacks are skipped. The load-on-demand ones (talents, the
    -- trainer, macros, inspect, the group finder) are caught by ADDON_LOADED
    -- the first time they open.
    { name = "QuestLogFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "SpellBookFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "PlayerTalentFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "TalentFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "MailFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "MerchantFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "ClassTrainerFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "FriendsFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "GossipFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "QuestFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "TradeFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "InspectFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "DressUpFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "MacroFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "PVPFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "HonorFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "TabardFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "GuildRegistrarFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "PetStableFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    -- The group finder (LFG). Classic's is LFGParentFrame (with LFGFrame and
    -- LFMFrame as its two tabs); the retail engine's is PVEFrame. Only the
    -- parent is made movable -- the tabs ride inside it.
    { name = "LFGParentFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "PVEFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
}

-- Names, for the menu and the reset message.
ns.MOVER_NAMES = {}
for _, target in ipairs(TARGETS) do ns.MOVER_NAMES[#ns.MOVER_NAMES + 1] = target.name end

local prepared = {}
local pending = {}

-- Per character, like every other ChairPlus setting (see Config.lua).
local function Store()
    if not ns.Profile then return nil end
    local ok, profile = pcall(ns.Profile)
    if not ok or type(profile) ~= "table" then return nil end
    return profile.movers
end

local function Blocked(frame)
    local okL, locked = pcall(_G.InCombatLockdown)
    if not (okL and locked) then return false end
    local okP, protected = pcall(frame.IsProtected, frame)
    return okP and protected and true or false
end

-- Put a window at its saved spot, if it has one.
local function Apply(name)
    local frame = _G[name]
    local store = Store()
    local spot = store and store[name]
    if not frame or type(spot) ~= "table" then return end
    local x, y = ns.Num(spot.x), ns.Num(spot.y)
    if not x or not y then return end
    if Blocked(frame) then
        pending[name] = true
        return
    end
    pending[name] = nil
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
end
ns.ApplyMover = Apply

local function Save(name)
    local frame = _G[name]
    local store = Store()
    if not frame or not store then return end
    local okF, fx, fy = pcall(frame.GetCenter, frame)
    local okU, ux, uy = pcall(UIParent.GetCenter, UIParent)
    fx, fy, ux, uy = ns.Num(fx), ns.Num(fy), ns.Num(ux), ns.Num(uy)
    if not (okF and okU and fx and fy and ux and uy) then return end
    -- Centres come back in each frame's own scale; offsets are read in the
    -- window's, so the screen centre is converted into it.
    local okS, fs = pcall(frame.GetEffectiveScale, frame)
    local okT, us = pcall(UIParent.GetEffectiveScale, UIParent)
    fs, us = okS and ns.Num(fs) or 1, okT and ns.Num(us) or 1
    local ratio = (fs and fs > 0) and (us / fs) or 1
    store[name] = { x = fx - ux * ratio, y = fy - uy * ratio }
    Apply(name)
end

local function Prepare(target)
    local name = target.name
    if prepared[name] then return end
    local frame = _G[name]
    if not frame then return end
    prepared[name] = true

    pcall(frame.SetMovable, frame, true)
    pcall(frame.SetClampedToScreen, frame, true)

    local handle = CreateFrame("Frame", nil, frame)
    handle:SetPoint("TOPLEFT", frame, "TOPLEFT", target.insetLeft, 0)
    handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -28, 0)
    handle:SetHeight(HEADER_H)
    pcall(handle.SetFrameLevel, handle, (ns.Num(frame:GetFrameLevel()) or 1) + 20)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        if Blocked(frame) then return end
        frame:StartMoving()
    end)
    handle:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        Save(name)
    end)
    frame.chairMoverHandle = handle

    if frame.HookScript then
        pcall(frame.HookScript, frame, "OnShow", function() Apply(name) end)
    end
    if type(_G[target.layout]) == "function" then
        hooksecurefunc(target.layout, function() Apply(name) end)
    end
    Apply(name)
end

local function PrepareAll()
    for _, target in ipairs(TARGETS) do pcall(Prepare, target) end
end

-- The bag frame may not exist until the bags are first opened, and the
-- character frame's addon can load late, so this keeps trying at the moments
-- either could have appeared.
local driver = CreateFrame("Frame")
-- Not every client has every event (this beta has no CRAFT_SHOW), and
-- registering an unknown one throws, which would stop this file loading and
-- leave every window unmovable. So each is tried on its own.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED",
        "BANKFRAME_OPENED", "AUCTION_HOUSE_SHOW", "TRADE_SKILL_SHOW", "CRAFT_SHOW" }) do
    pcall(driver.RegisterEvent, driver, event)
end
driver:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        for name in pairs(pending) do Apply(name) end
        return
    end
    PrepareAll()
end)

for _, opener in ipairs({ "ToggleCharacter", "ToggleAllBags", "OpenAllBags", "ToggleBackpack" }) do
    if type(_G[opener]) == "function" then
        hooksecurefunc(opener, PrepareAll)
    end
end

-- Forgets the saved spots. Blizzard's own layout takes over the next time each
-- window opens; calling its layout functions from here would taint the panel
-- manager, which is a far worse outcome than waiting for a close and reopen.
function ns.ResetMovers()
    local store = Store()
    if store then wipe(store) end
end
