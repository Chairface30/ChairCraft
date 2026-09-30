-- ChairPlus Movers.lua
-- Blizzard's windows -- the character panel, bank, auction house, professions,
-- map and quest log, spellbook, talents, mail, merchant, trainer, friends, the
-- group finder and the rest in TARGETS below -- and the combined backpack, all
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
-- as an offset from the screen centre (the map's from the screen's top left
-- corner). "/chair plus movers reset" hands them all back to Blizzard.

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
    -- The map and quest log, one window on this engine ("Map & Quest Log").
    -- It differs from the rest in four ways:
    --   * its title strip belongs to BorderFrame, which sits above the map, so
    --     the handle goes on that;
    --   * a maximize button sits beside the close button, so the handle stops
    --     short of both;
    --   * maximized it fills the screen, and Blizzard sizes and places it: it
    --     is neither dragged nor put anywhere while IsMaximized says so;
    --   * the quest log opens and shuts on its right, changing the width, so
    --     its spot is kept by the top left corner. Kept by the centre, the map
    --     would jump sideways each time.
    -- Coming back from maximized, Blizzard restores the panel without going
    -- through UpdateUIPanelPositions, hence the hook on the method that does.
    { name = "WorldMapFrame", layout = "UpdateUIPanelPositions", insetLeft = 58, insetRight = 60,
      border = "BorderFrame", fixed = "IsMaximized", corner = true,
      after = { "SynchronizeDisplayState" } },
    -- The spellbook. Older clients have SpellBookFrame, always loaded; newer
    -- ones fold the spellbook and talents into PlayerSpellsFrame (loaded on
    -- demand, Blizzard_PlayerSpells), and the one before that had talents in
    -- ClassTalentFrame. Only the outer window is made movable.
    { name = "SpellBookFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "PlayerSpellsFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "ClassTalentFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
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
    -- The guild window. Which one opens depends on the build: the guild and
    -- communities window (CommunitiesFrame, Blizzard_Communities) or an older
    -- GuildFrame. Whichever is here gets the handle; the other costs nothing.
    { name = "CommunitiesFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "GuildFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
    { name = "GuildBankFrame", layout = "UpdateUIPanelPositions", insetLeft = 58 },
}

-- Names, for the menu and the reset message.
ns.MOVER_NAMES = {}
local byName = {}
for _, target in ipairs(TARGETS) do
    ns.MOVER_NAMES[#ns.MOVER_NAMES + 1] = target.name
    byName[target.name] = target
end

local prepared = {}
local pending = {}
local layoutHooked = {}

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

-- True while the window is in a state Blizzard alone places (the maximized
-- map). A window whose answer can't be read is treated as free to move.
local function Fixed(target, frame)
    local method = target and target.fixed and frame[target.fixed]
    if type(method) ~= "function" then return false end
    local ok, answer = pcall(method, frame)
    return ok and ns.Bool(answer) == true
end

-- Put a window at its saved spot, if it has one.
local function Apply(name)
    local frame = _G[name]
    local store = Store()
    local spot = store and store[name]
    if not frame or type(spot) ~= "table" then return end
    local x, y = ns.Num(spot.x), ns.Num(spot.y)
    if not x or not y then return end
    local target = byName[name]
    if Fixed(target, frame) then return end
    if Blocked(frame) then
        pending[name] = true
        return
    end
    pending[name] = nil
    local point = (target and target.corner) and "TOPLEFT" or "CENTER"
    frame:ClearAllPoints()
    frame:SetPoint(point, UIParent, point, x, y)
end
ns.ApplyMover = Apply

local function Save(name)
    local frame = _G[name]
    local store = Store()
    if not frame or not store then return end
    -- The point the spot is measured from: the window's centre against the
    -- screen's, or for a window that changes width, top left against top left.
    local okF, fx, fy, okU, ux, uy
    if byName[name] and byName[name].corner then
        okF, fx, fy = pcall(function() return frame:GetLeft(), frame:GetTop() end)
        okU, ux, uy = pcall(function() return UIParent:GetLeft(), UIParent:GetTop() end)
    else
        okF, fx, fy = pcall(frame.GetCenter, frame)
        okU, ux, uy = pcall(UIParent.GetCenter, UIParent)
    end
    fx, fy, ux, uy = ns.Num(fx), ns.Num(fy), ns.Num(ux), ns.Num(uy)
    if not (okF and okU and fx and fy and ux and uy) then return end
    -- Both come back in each frame's own scale; offsets are read in the
    -- window's, so the screen's point is converted into it.
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

    -- The handle rides on whatever draws the title strip, so it is in that
    -- frame's strata and above it; on most windows that is the window itself.
    local host = target.border and frame[target.border]
    if type(host) ~= "table" or type(host.GetFrameLevel) ~= "function" then host = frame end
    local handle = CreateFrame("Frame", nil, host)
    handle:SetPoint("TOPLEFT", frame, "TOPLEFT", target.insetLeft, 0)
    handle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(target.insetRight or 28), 0)
    handle:SetHeight(HEADER_H)
    pcall(handle.SetFrameLevel, handle, (ns.Num(host:GetFrameLevel()) or 1) + 20)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        if Blocked(frame) or Fixed(target, frame) then return end
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
    -- The window's own methods that end by placing it. Hooked, never called.
    for _, method in ipairs(target.after or {}) do
        if type(frame[method]) == "function" then
            pcall(hooksecurefunc, frame, method, function() Apply(name) end)
        end
    end
    -- One hook per layout function, however many windows it lays out: it
    -- used to be one per window, thirty hooks on the same function.
    local layout = target.layout
    if type(_G[layout]) == "function" and not layoutHooked[layout] then
        layoutHooked[layout] = true
        hooksecurefunc(layout, function()
            for _, other in ipairs(TARGETS) do
                if prepared[other.name] and other.layout == layout then Apply(other.name) end
            end
        end)
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
        "BANKFRAME_OPENED", "AUCTION_HOUSE_SHOW", "TRADE_SKILL_SHOW", "CRAFT_SHOW",
        "GUILDBANKFRAME_OPENED" }) do
    pcall(driver.RegisterEvent, driver, event)
end
driver:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        for name in pairs(pending) do Apply(name) end
        return
    end
    PrepareAll()
end)

-- The windows' own openers, so one created late (the spellbook and talents
-- among them) gets its handle the first time it opens.
for _, opener in ipairs({ "ToggleCharacter", "ToggleAllBags", "OpenAllBags", "ToggleBackpack",
                          "ToggleGuildFrame", "ToggleCommunitiesFrame", "ToggleSpellBook",
                          "ToggleTalentFrame", "TogglePlayerSpellsFrame", "ToggleWorldMap",
                          "ToggleQuestLog" }) do
    if type(_G[opener]) == "function" then
        hooksecurefunc(opener, PrepareAll)
    end
end
-- Newer clients open the spellbook through PlayerSpellsUtil instead.
local util = _G.PlayerSpellsUtil
if type(util) == "table" then
    for _, opener in ipairs({ "ToggleSpellBookFrame", "OpenToSpellBookTab", "TogglePlayerSpellsFrame",
                              "ToggleClassTalentFrame", "OpenToClassTalentsTab" }) do
        if type(util[opener]) == "function" then
            hooksecurefunc(util, opener, PrepareAll)
        end
    end
end

-- For /chair plus movers: which of the windows this client has, and which
-- have their handle.
function ns.MoverStatus()
    local found, ready = {}, {}
    for _, target in ipairs(TARGETS) do
        if _G[target.name] then
            found[#found + 1] = target.name
            if prepared[target.name] then ready[#ready + 1] = target.name end
        end
    end
    return found, ready
end

-- Forgets the saved spots. Blizzard's own layout takes over the next time each
-- window opens; calling its layout functions from here would taint the panel
-- manager, which is a far worse outcome than waiting for a close and reopen.
function ns.ResetMovers()
    local store = Store()
    if store then wipe(store) end
end
