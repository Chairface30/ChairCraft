-- ChairPlus Chat.lua
-- Chat scroll bar on the left.
--
-- Each chat window's scroll bar (with its arrows) and its jump-to-bottom
-- button sit in a strip Blizzard adds to the right of the text: the window's
-- dark background runs 15 pixels past the text's right edge to hold them.
-- The lines of text are laid out at the chat frame's own width, anchored to
-- its left edge, so they cannot be indented inside the frame. Instead, this
-- swaps the strip: the background reaches 15 pixels past the text's left
-- edge, the bar and button move into that room, and the right edge closes in
-- to where the text ends. The text itself does not move, and the window's
-- saved position and size are never touched.
--
-- Only anchors change, and Blizzard's own functions are hooked, never
-- called: when Blizzard re-anchors the bar or the background, the hook puts
-- them back on the left. Switching off puts back Blizzard's own anchors (the
-- values below are copied from its chat frame code) on every window this
-- moved.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

-- Blizzard's strip: 7 pixels of margin plus the 8-pixel bar.
local STRIP = 15

local hooked = false
local moved = {}

local function QuickButtonHeight(chatFrame)
    local quick = chatFrame.CombatLogQuickButtonFrame
    return quick and quick:GetHeight() or 0
end

-- The edit box's right end is tied to the scroll bar. Moving the bar left
-- would drag it along, so it is re-anchored too -- but only while it is
-- still tied to the bar, so a box another addon has placed is left alone.
local function EditBoxOnBar(chatFrame)
    local box, bar = chatFrame.editBox, chatFrame.ScrollBar
    if not (box and box.GetNumPoints) then return false end
    for i = 1, box:GetNumPoints() do
        local _, relativeTo = box:GetPoint(i)
        if relativeTo == bar then return true end
    end
    return false
end

local function PlaceLeft(chatFrame)
    local bar, bottom, bg = chatFrame.ScrollBar, chatFrame.ScrollToBottomButton, chatFrame.Background
    local quick = QuickButtonHeight(chatFrame)

    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", chatFrame, "TOPLEFT", -STRIP, 3 + quick)
    bg:SetPoint("BOTTOMRIGHT", chatFrame, "BOTTOMRIGHT", 2, -6)

    -- Blizzard stands it on the resize grip, 14 pixels up from the corner;
    -- the left corner has no grip, so the same height is kept by hand.
    if bottom then
        bottom:ClearAllPoints()
        bottom:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 2, 14)
    end

    bar:ClearAllPoints()
    bar:SetPoint("TOPRIGHT", chatFrame, "TOPLEFT", 0, 0)
    if bottom and bottom:IsShown() then
        bar:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT", 0, 2)
    else
        bar:SetPoint("BOTTOMRIGHT", chatFrame, "BOTTOMLEFT", 0, 0)
    end

    local box = chatFrame.editBox
    if box and (moved[chatFrame] == "box" or EditBoxOnBar(chatFrame)) then
        -- Blizzard's box overhangs the background by 3 on the text side and
        -- 1 on the bar side; mirrored, that is 16 left and 5 right.
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", chatFrame, "BOTTOMLEFT", -(STRIP + 1), -2)
        box:SetPoint("TOPRIGHT", chatFrame, "BOTTOMRIGHT", 5, -2)
        moved[chatFrame] = "box"
    elseif not moved[chatFrame] then
        moved[chatFrame] = true
    end
end

-- Blizzard's anchors, from FloatingChatFrame_UpdateBackgroundAnchors,
-- FCF_UpdateScrollbarAnchors and the chat frame template.
local function PlaceRight(chatFrame)
    local bar, bottom, bg = chatFrame.ScrollBar, chatFrame.ScrollToBottomButton, chatFrame.Background
    local quick = QuickButtonHeight(chatFrame)

    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", chatFrame, "TOPLEFT", -2, 3 + quick)
    bg:SetPoint("BOTTOMRIGHT", chatFrame, "BOTTOMRIGHT", STRIP, -6)

    if bottom and chatFrame.ResizeButton then
        bottom:ClearAllPoints()
        bottom:SetPoint("BOTTOMRIGHT", chatFrame.ResizeButton, "TOPRIGHT", -2, -2)
    end

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", chatFrame, "TOPRIGHT", 0, 0)
    if bottom and bottom:IsShown() then
        bar:SetPoint("BOTTOMLEFT", bottom, "TOPLEFT", 0, 2)
    elseif chatFrame.ResizeButton and chatFrame.ResizeButton:IsShown() then
        bar:SetPoint("BOTTOM", chatFrame.ResizeButton, "TOP", 0, 0)
    else
        bar:SetPoint("BOTTOMLEFT", chatFrame, "BOTTOMRIGHT", 0, 0)
    end

    local box = chatFrame.editBox
    if box and moved[chatFrame] == "box" then
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", chatFrame, "BOTTOMLEFT", -5, -2)
        box:SetPoint("RIGHT", bar, "RIGHT", 8, 0)
    end
    moved[chatFrame] = nil
end

-- Only windows built the way this expects are touched: one without a
-- scroll bar or background has nothing to move.
local function Usable(chatFrame)
    return type(chatFrame) == "table" and chatFrame.ScrollBar and chatFrame.Background
        and chatFrame.ScrollBar.SetPoint and chatFrame.Background.SetPoint
end

local function Place(chatFrame)
    if not Usable(chatFrame) then return end
    if ns.IsEnabled("chatScrollLeft") then
        pcall(PlaceLeft, chatFrame)
    elseif moved[chatFrame] then
        pcall(PlaceRight, chatFrame)
    end
end

local function EachChatFrame(fn)
    local seen = {}
    local names = _G.CHAT_FRAMES
    if type(names) == "table" then
        for _, name in pairs(names) do
            local frame = _G[name]
            if frame and not seen[frame] then seen[frame] = true; fn(frame) end
        end
    end
    for i = 1, (_G.NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame and not seen[frame] then seen[frame] = true; fn(frame) end
    end
    for frame in pairs(moved) do
        if not seen[frame] then seen[frame] = true; fn(frame) end
    end
end

local function Hook()
    if hooked then return end
    hooked = true
    -- Blizzard re-anchors the bar whenever the resize grip shows or hides
    -- (locking, docking), and the background when the window is set up.
    if type(_G.FCF_UpdateScrollbarAnchors) == "function" then
        hooksecurefunc("FCF_UpdateScrollbarAnchors", Place)
    end
    if type(_G.FloatingChatFrame_UpdateBackgroundAnchors) == "function" then
        hooksecurefunc("FloatingChatFrame_UpdateBackgroundAnchors", Place)
    end
    -- Whisper windows and other temporary ones are made as they are needed.
    if type(_G.FCF_OpenTemporaryWindow) == "function" then
        hooksecurefunc("FCF_OpenTemporaryWindow", function()
            if ns.IsEnabled("chatScrollLeft") then EachChatFrame(Place) end
        end)
    end
end

ns.RegisterModule("chatScrollLeft", {
    title = "Chat scroll bar on the left",
    desc = "Moves each chat window's scroll bar and its arrows to the left side, with the text beside it.",
    Apply = function(enabled)
        if enabled then Hook() end
        EachChatFrame(Place)
    end,
})
