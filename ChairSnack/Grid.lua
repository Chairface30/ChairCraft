-- SnapSnack Grid.lua
-- Grid frames, secure item buttons, layout, keybind mode, and the minimap icon.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

local GetItemInfo  = addon.GetItemInfo
local GetItemCount = addon.GetItemCount
local PickupItem   = addon.PickupItem

local frames = addon.frames
local itemButtons = addon.itemButtons
local state = addon.state

local GetItemCooldown = addon.GetItemCooldown
local GetItemIDFromData = addon.GetItemIDFromData
local GetShowInCombatFromData = addon.GetShowInCombatFromData

local bindingModeFrame = nil
local minimapButton = nil

-- Only reached on a build with no SetPortraitTexture. Tame Beast's icon has
-- been in the game since vanilla, so it is a safe stand-in for "your pet".
local PET_BADGE_FALLBACK = "Interface\\Icons\\Ability_Hunter_BeastTaming"

-------------------------------
-- Growth -> Anchor Pivot
-------------------------------
-- The point of the frame that stays put as the grid grows. Anchoring by this
-- point is what makes growth directions work; the old code instead measured how
-- far a notional anchor had moved and shoved the frame back, rewriting the
-- saved position on every relayout so grids drifted across a session.

local PIVOT = {
    UP     = { LEFT = "BOTTOMRIGHT", CENTER = "BOTTOM", RIGHT = "BOTTOMLEFT" },
    CENTER = { LEFT = "RIGHT",       CENTER = "CENTER", RIGHT = "LEFT" },
    DOWN   = { LEFT = "TOPRIGHT",    CENTER = "TOP",    RIGHT = "TOPLEFT" },
}

local function GetPivot(db)
    local row = PIVOT[db.rowGrowth or "DOWN"] or PIVOT.DOWN
    return row[db.columnGrowth or "RIGHT"] or "TOPLEFT"
end

-- Shared so the database can tell a stored pivot from a derivable one and
-- leave the derivable ones out of the file.
addon.GetPivot = GetPivot

-- Place the frame by its pivot, converting the stored position when the pivot
-- changes so the grid does not jump when growth settings are edited.
local function RepositionFrame(frame, db, width, height)
    -- A relayout can land mid-drag -- a bag update is enough to cause one --
    -- and re-anchoring a frame the mouse is carrying would tear it out from
    -- under the cursor. The drop saves the position and asks for a fresh
    -- layout, so nothing is lost by sitting this one out.
    if frame.isMoving then return end

    local pivot = GetPivot(db)

    if not db.pos then
        -- One-time conversion from the v1 anchor (frame point P pinned to the
        -- same point on UIParent) to a pivot offset from the UIParent centre.
        local anchor = db.anchor or { point = "CENTER", x = 0, y = 0 }
        local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
        local uax, uay = addon.PointOffsetFromCenter(anchor.point, uiW, uiH)
        local fax, fay = addon.PointOffsetFromCenter(anchor.point, width, height)
        local fpx, fpy = addon.PointOffsetFromCenter(pivot, width, height)
        db.pos = {
            x = uax + (anchor.x or 0) - fax + fpx,
            y = uay + (anchor.y or 0) - fay + fpy,
        }
        db.posPivot = pivot
    elseif db.posPivot ~= pivot then
        local oldX, oldY = addon.PointOffsetFromCenter(db.posPivot or pivot, width, height)
        local newX, newY = addon.PointOffsetFromCenter(pivot, width, height)
        db.pos.x = db.pos.x - oldX + newX
        db.pos.y = db.pos.y - oldY + newY
        db.posPivot = pivot
    end

    frame:ClearAllPoints()
    frame:SetPoint(pivot, UIParent, "CENTER", db.pos.x, db.pos.y)
end

-- Record where the user dropped the frame, measured at its pivot.
local function SavePosition(frame, db)
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    local width, height = frame:GetWidth(), frame:GetHeight()
    local centerX, centerY = UIParent:GetCenter()
    if not (left and bottom and centerX) then return end

    local pivot = GetPivot(db)
    local dx, dy = addon.PointOffsetFromCenter(pivot, width, height)
    db.pos = {
        x = left + width / 2 + dx - centerX,
        y = bottom + height / 2 + dy - centerY,
    }
    db.posPivot = pivot
end

-- Can bars be dragged right now?
--
-- This replaced a per-bar lock flag and a drag handle on every bar. A lock is
-- a mode you have to remember you are in -- bars left unlocked get shoved
-- around by a stray click, and a bar locked months ago is a puzzle -- and the
-- handle existed only to give the lock something to hang off. The config
-- window is already the "I am arranging things" mode, so it is the mode.
--
-- Combat is excluded because moving a frame that parents secure buttons is a
-- protected action; the layout pass is gated the same way.
local function MoveModeActive()
    if InCombatLockdown() then return false end
    return addon:IsConfigOpen()
end

addon.MoveModeActive = MoveModeActive

-- Right-drag moves a bar. Left is left alone: it drags items off a button and
-- drops them onto a bar, which has to keep working while the window is open.
local function BeginMove(frame)
    if not frame or not MoveModeActive() then return false end
    frame:StartMoving()
    frame.isMoving = true
    return true
end

local function EndMove(frame)
    if not frame or not frame.isMoving then return end
    frame.isMoving = nil
    frame:StopMovingOrSizing()
    local db = addon:GetGrid(frame.gridID)
    if db then
        SavePosition(frame, db)
    end
    -- Any layout that arrived during the drag skipped this frame, so it gets
    -- one now that the position is settled.
    addon:RequestUpdate()
end

addon.BeginMove = BeginMove
addon.EndMove = EndMove

-------------------------------
-- Click Registration
-------------------------------
-- Whether a secure action fires on the press or the release is the player's
-- choice in this client era -- "Press and Hold Casting", the
-- ActionButtonUseKeyDown CVar -- and getting it wrong is completely silent.
-- The button still draws, highlights, shows its tooltip and takes the mouse;
-- the click simply does nothing, with no error and nothing in the attributes
-- to say so.
--
-- CVars are stored per WoW account, not per character, so hardcoding one of
-- the two registrations means the bars work on one account and are inert on
-- every character of another. Blizzard's own bars read the CVar, which is why
-- only addons show the fault.

local function ClickRegistration()
    local get = GetCVarBool or (C_CVar and C_CVar.GetCVarBool)
    local ok, useKeyDown = pcall(get, "ActionButtonUseKeyDown")
    if ok and useKeyDown then return "AnyDown" end
    return "AnyUp"
end

addon.ClickRegistration = ClickRegistration

-- Registering both would fire the action twice per click on any build whose
-- secure handler does not filter by the CVar itself, so exactly one is
-- registered and it is re-registered when the setting changes.
local secureButtons = {}

local function RegisterClicks(button)
    secureButtons[button] = true
    button:RegisterForClicks(ClickRegistration())
end

addon.RegisterSecureClicks = RegisterClicks

-- RegisterForClicks on a protected button is a combat-restricted call, so a
-- change made mid-fight is picked up when combat ends instead.
function addon.RefreshClickRegistration()
    if InCombatLockdown() then return false end
    local wanted = ClickRegistration()
    for button in pairs(secureButtons) do
        button:RegisterForClicks(wanted)
    end
    return true
end

-------------------------------
-- Item Buttons
-------------------------------

local function CreateItemButton(parent, gridID, buttonIndex)
    local db = addon:GetGrid(gridID)
    local size = db.iconSize

    local button = CreateFrame("Button", addonName .. "Grid" .. gridID .. "Button" .. buttonIndex,
                               parent, "SecureActionButtonTemplate")
    button:SetSize(size, size)
    RegisterClicks(button)
    button:SetAttribute("type", "item")

    for _, region in pairs({ button:GetRegions() }) do
        if region:IsObjectType("Texture") then
            region:Hide()
            region:SetTexture(nil)
        end
    end

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0, 0, 0, 0.8)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local function Border(a1, a2, w, h)
        local tex = button:CreateTexture(nil, "OVERLAY")
        if w then tex:SetWidth(w) end
        if h then tex:SetHeight(h) end
        tex:SetPoint(a1, 0, 0)
        tex:SetPoint(a2, 0, 0)
        tex:SetColorTexture(0.4, 0.4, 0.4, 1)
        return tex
    end
    button.borderTop = Border("TOPLEFT", "TOPRIGHT", nil, 1)
    button.borderBottom = Border("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    button.borderLeft = Border("TOPLEFT", "BOTTOMLEFT", 1, nil)
    button.borderRight = Border("TOPRIGHT", "BOTTOMRIGHT", 1, nil)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)
    button.count:SetJustifyH("RIGHT")

    button.keybindText = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    button.keybindText:SetPoint("TOPLEFT", 2, -2)
    button.keybindText:SetJustifyH("LEFT")

    -- Time left on the buff this item applies, or on a weapon enchant.
    button.timerText = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    button.timerText:SetPoint("TOP", 0, -3)
    button.timerText:SetJustifyH("CENTER")

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetAllPoints(button.icon)

    -- Seconds left on the cooldown. Drawn above the cooldown frame's own
    -- sweep, which shows how much is left but never how much in numbers.
    button.cooldownText = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.cooldownText:SetPoint("CENTER", button.icon, "CENTER", 0, 0)
    button.cooldownText:SetJustifyH("CENTER")
    button.cooldownText:Hide()

    button.desaturate = button:CreateTexture(nil, "OVERLAY", nil, 1)
    button.desaturate:SetAllPoints(button.icon)
    button.desaturate:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    button.desaturate:Hide()

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetAllPoints(button.icon)
    button.highlight:SetColorTexture(1, 1, 1, 0.2)

    button.bindOverlay = button:CreateTexture(nil, "OVERLAY", nil, 2)
    button.bindOverlay:SetAllPoints()
    button.bindOverlay:SetColorTexture(0.0, 0.5, 1.0, 0.3)
    button.bindOverlay:Hide()

    button.bindHighlight = button:CreateTexture(nil, "OVERLAY", nil, 3)
    button.bindHighlight:SetAllPoints()
    button.bindHighlight:SetColorTexture(1.0, 0.8, 0.0, 0.5)
    button.bindHighlight:Hide()

    -- Green up-arrow marking "a better tier is available at your level".
    -- A plain Blizzard arrow tinted green, rather than a themed texture that
    -- may not exist on this client.
    button.upgradeIcon = button:CreateTexture(nil, "OVERLAY", nil, 4)
    button.upgradeIcon:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
    button.upgradeIcon:SetVertexColor(0.2, 1.0, 0.2)
    button.upgradeIcon:SetSize(14, 14)
    button.upgradeIcon:SetPoint("TOPRIGHT", 2, 2)
    button.upgradeIcon:Hide()

    -- Small arrow marking a flyout button.
    button.flyoutArrow = button:CreateTexture(nil, "OVERLAY", nil, 4)
    button.flyoutArrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
    button.flyoutArrow:SetSize(12, 12)
    button.flyoutArrow:SetPoint("BOTTOM", 0, -2)
    button.flyoutArrow:Hide()

    -- Marks a button aimed at your pet rather than at you. The pet's own
    -- portrait, not a generic glyph: it says which animal at a glance and
    -- needs no icon path that might not exist on this client. Bottom-left is
    -- the one free corner -- count and the setup X share bottom-right, the
    -- upgrade arrow has top-right and the keybind has top-left.
    button.petIcon = button:CreateTexture(nil, "OVERLAY", nil, 5)
    button.petIcon:SetSize(14, 14)
    button.petIcon:SetPoint("BOTTOMLEFT", -2, -2)
    button.petIcon:Hide()

    -- Red X marking a button that needs configuring before it can do anything.
    button.needsSetupIcon = button:CreateTexture(nil, "OVERLAY", nil, 5)
    button.needsSetupIcon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    button.needsSetupIcon:SetSize(14, 14)
    button.needsSetupIcon:SetPoint("BOTTOMRIGHT", 2, -2)
    button.needsSetupIcon:Hide()

    button:SetScript("OnMouseDown", function(self)
        if self.icon and not InCombatLockdown() then
            self.icon:SetPoint("TOPLEFT", 4, -4)
            self.icon:SetPoint("BOTTOMRIGHT", 0, 0)
        end
    end)
    button:SetScript("OnMouseUp", function(self)
        if self.icon then
            self.icon:SetPoint("TOPLEFT", 2, -2)
            self.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        end
    end)

    button:SetScript("OnEnter", function(self)
        local currentDB = addon:GetGrid(self.gridID)
        if not currentDB or currentDB.showTooltips == false then return end

        local data = type(self.itemData) == "table" and self.itemData or nil

        if data and data.needsSetup then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(data.tooltipTitle or "", 1, 0.82, 0)
            GameTooltip:AddLine("No pet food chosen yet", 1, 0.3, 0.3)
            GameTooltip:AddLine("Click to pick which foods to use", 0.8, 0.8, 0.8)
            GameTooltip:Show()
            return
        end

        if data and data.inactive then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(data.tooltipTitle or "", 1, 0.82, 0)
            if data.tooltipHint then
                GameTooltip:AddLine(data.tooltipHint, 1, 0.3, 0.3)
            end
            GameTooltip:Show()
            return
        end

        -- A flyout has no item, so it describes its own contents.
        if data and data.flyout then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(data.tooltipTitle or "", 1, 0.82, 0)
            GameTooltip:AddLine("Click to expand", 0.8, 0.8, 0.8)
            GameTooltip:AddLine(" ")
            for _, spell in ipairs(data.flyout) do
                GameTooltip:AddLine(spell.name, 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
            return
        end

        if not self.itemID then return end

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

        -- A slot with its own title (Feed Pet) describes the action and names
        -- the item it will consume; everything else is just the item.
        if data and data.tooltipTitle then
            GameTooltip:AddLine(data.tooltipTitle, 1, 0.82, 0)
            local chosen = GetItemInfo(self.itemID)
            if chosen then
                GameTooltip:AddLine("Will use: " .. chosen, 0.8, 0.8, 0.8)
            end
        else
            GameTooltip:SetItemByID(self.itemID)
        end

        -- Aggregate slots list what makes up the total on the icon.
        if data and data.aggregate and #data.aggregate > 1 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("On hand:", 1, 0.82, 0)
            for _, member in ipairs(data.aggregate) do
                if member.name then
                    GameTooltip:AddLine(member.name .. ": " .. (member.count or 0),
                                        0.7, 0.7, 0.7)
                end
            end
        end

        if data and data.tooltipHint then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(data.tooltipHint, 0.4, 0.8, 1.0)
        end

        local bankCount, altCounts = addon:GetBankAndAltCount(self.itemID)
        if bankCount > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Bank: " .. bankCount, 0.5, 0.8, 1.0)
        end
        for charKey, count in pairs(altCounts) do
            GameTooltip:AddLine(charKey .. ": " .. count, 0.7, 0.7, 0.7)
        end

        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    button:HookScript("PreClick", function(self)
        -- Counted for /chair snack click. PreClick runs as part of the secure button's
        -- own click handling, so a count that stays at zero while you click the
        -- icon says the click never reached the widget at all -- which is a
        -- different fault from an action that ran and did nothing.
        self.clickCount = (self.clickCount or 0) + 1

        if state.bindingMode then
            if state.pendingBindButton then
                state.pendingBindButton.bindHighlight:Hide()
            end
            state.pendingBindButton = self
            self.bindHighlight:Show()
        end
    end)

    button:HookScript("PostClick", function(self, mouseButton)
        if state.bindingMode then return end
        local data = self.itemData

        -- Right-click on a slot with alternatives fans them out instead of
        -- using anything; the secure action for that click is a no-op.
        if mouseButton == "RightButton" and type(data) == "table"
            and data.hasAlternatives then
            addon.ToggleFlyout(self, addon.AlternativeEntries(self))
            return
        end

        -- Note the attempt so the outcome can be attributed to this item.
        if type(data) == "table" and data.isFeedPet and data.itemID then
            addon.NotePetFeed(data.petFamily, data.itemID)
        end

        if type(data) == "table" and data.flyout then
            addon.ToggleFlyout(self)
        elseif type(data) == "table" and data.needsSetup then
            addon.CloseFlyout()
            addon:OpenConfigAtPetFood()
        else
            addon.CloseFlyout()
        end
    end)

    -- Dropping an item onto a button inserts it at that position; dragging one
    -- off removes it. Both are plain scripts, so neither is protected, and the
    -- lists they edit are only ever rebuilt out of combat.
    button:SetScript("OnReceiveDrag", function(self)
        addon.AcceptCursorItem(self.gridID, self.buttonIndex)
    end)
    button:HookScript("PostClick", function(self)
        if CursorHasItem and CursorHasItem() then
            addon.AcceptCursorItem(self.gridID, self.buttonIndex)
        end
    end)

    -- Left drags the item off the bar. Right moves the whole bar, and has to
    -- be answerable here as well as on the frame: the buttons cover almost all
    -- of a full bar, so a right-drag that only worked on bare background would
    -- mean hunting for a gap between icons.
    --
    -- Which buttons count as a drag is set per layout by ApplyButtonDragMode,
    -- not here. Registering RightButton permanently would mean any right-click
    -- with a twitch in it counted as a drag and swallowed the click -- and
    -- right-click on a potion is how you reach the alternatives flyout.
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self, mouseButton)
        if mouseButton == "RightButton" then
            -- Not GetParent: a button is reparented between the two combat
            -- holders, so its grid is looked up rather than walked to.
            BeginMove(frames[self.gridID])
            return
        end
        if InCombatLockdown() then return end
        local itemID = addon:RemoveItemFromGrid(self.gridID, self.buttonIndex)
        if itemID then
            PickupItem(itemID)
            addon:RequestUpdate()
        end
    end)

    button:SetScript("OnDragStop", function(self)
        EndMove(frames[self.gridID])
    end)

    button.gridID = gridID
    button.buttonIndex = buttonIndex

    return button
end

-- Take whatever item is on the cursor onto a bar.
function addon.AcceptCursorItem(gridID, index)
    if not GetCursorInfo then return end

    local kind, _, _, itemLink = GetCursorInfo()
    if kind ~= "item" then return end

    local itemID = itemLink and tonumber(itemLink:match("item:(%d+)"))
    if not itemID then return end

    if addon:DropItemOnGrid(gridID, itemID, index) then
        ClearCursor()
        addon:RequestUpdate()
    end
end

-- Point the secure action at whatever this button currently stands for.
-- Feed Pet needs a macro because feeding is a two-step cast-then-apply; every
-- other button is a plain item action.
local function ApplyButtonAction(button)
    local data = button.itemData

    -- Buttons are pooled and reused, so every attribute an earlier occupant
    -- might have set is cleared before the new one sets its own. A left-hand
    -- macro left behind on a button that is now a plain item would win the
    -- click, since type1 is consulted before type.
    button:SetAttribute("type", nil)
    button:SetAttribute("type1", nil)
    button:SetAttribute("type2", nil)
    button:SetAttribute("macrotext", nil)
    button:SetAttribute("macrotext1", nil)
    button:SetAttribute("macrotext2", nil)
    -- The action payloads matter as much as the types: a pooled button that
    -- used to be a create-spell offer kept its "spell" attribute, so the next
    -- occupant to set type="spell" for a different reason would have fired the
    -- old one.
    button:SetAttribute("spell", nil)
    button:SetAttribute("spell2", nil)
    button:SetAttribute("item", nil)
    button:SetAttribute("unit", nil)

    if data and (data.isCreateSpell or data.isSpell) and data.spellName then
        button:SetAttribute("type", "spell")
        -- The spell NAME, the same way the item path uses the item name: the
        -- secure template resolves a name, and quietly does nothing with an ID.
        button:SetAttribute("spell", data.spellName)
        return
    end

    -- Neither a flyout nor a setup prompt carries an action of its own; both
    -- are handled in PostClick.
    if data and (data.flyout or data.needsSetup or data.inactive) then
        return
    end

    if data and data.macrotext and data.macrotext2 then
        -- Two actions on one button: the weapon enchant bar puts the main hand
        -- on left click and the off hand on right click.
        button:SetAttribute("type1", "macro")
        button:SetAttribute("macrotext1", data.macrotext)
        button:SetAttribute("type2", "macro")
        button:SetAttribute("macrotext2", data.macrotext2)
    elseif data and data.macrotext then
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", data.macrotext)
    elseif data and data.isToy and button.itemID then
        -- A toy is not in a bag, so the item action has nothing to act on.
        -- Fall back to a /use macro where this client has no toy action type.
        if _G.C_ToyBox or _G.PlayerHasToy then
            button:SetAttribute("type", "toy")
            button:SetAttribute("toy", button.itemID)
        elseif button.itemName then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use " .. button.itemName)
        end
    elseif button.itemName then
        button:SetAttribute("type", "item")
        -- The item NAME, not "item:<id>": the secure template resolves this
        -- through UseItemByName, which takes a name or a real item link and
        -- silently does nothing with an "item:<id>" string.
        button:SetAttribute("item", button.itemName)

        if data and data.petMacro then
            -- Left click uses the item on you, right click on the pet. The
            -- conditional inside the macro does the aiming, so the click never
            -- changes who you have targeted.
            button:SetAttribute("type2", "macro")
            button:SetAttribute("macrotext2", data.petMacro)
        elseif data and data.rightSpell then
            -- Having some is no reason to lose the ability to make more, so a
            -- conjured or Healthstone slot keeps its spell on the right button
            -- even while the item itself is on the left.
            button:SetAttribute("type2", "spell")
            button:SetAttribute("spell2", data.rightSpell)
        elseif data and data.hasAlternatives then
            button:SetAttribute("type2", "macro")
            button:SetAttribute("macrotext2", "")
        end
    end
end

addon.ApplyButtonAction = ApplyButtonAction

-------------------------------
-- Spell Flyout
-------------------------------
-- One button standing for a set of spells -- the mage portal tray. The spell
-- buttons are secure and built out of combat; the tray itself is toggled from a
-- plain script, which is fine because nothing in a flyout is castable in combat
-- anyway.

local openFlyout = nil

-- A tray left open is one you right-click through by accident ten minutes
-- later, so it closes itself. It fades rather than vanishing, so a tray going
-- away on its own reads as a timeout and not as a misclick that dismissed it.
--
-- Hovering holds it open: reading a list of a dozen portals takes longer than
-- picking from a list of two, and the countdown restarts when you leave.
local FLYOUT_TIMEOUT = 10
local FLYOUT_FADE = 0.4
local flyoutTimer = nil

local CloseFlyout, StartFlyoutTimer

local function StopFlyoutTimer()
    if flyoutTimer then
        flyoutTimer:Cancel()
        flyoutTimer = nil
    end
end

-- Cancels a fade in progress as well as the countdown: hovering a tray that is
-- already fading brings it back rather than watching it finish.
local function HoldFlyoutOpen()
    StopFlyoutTimer()
    if openFlyout then
        if openFlyout.fadeInfo then openFlyout.fadeInfo.finishedFunc = nil end
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(openFlyout) end
        openFlyout:SetAlpha(1)
    end
end

local function FadeOutFlyout()
    flyoutTimer = nil
    local tray = openFlyout
    if not tray or not tray:IsShown() then return end

    -- Alpha alone would leave an invisible tray still taking clicks, so the
    -- fade has to end in a real Hide.
    if UIFrameFadeOut then
        UIFrameFadeOut(tray, FLYOUT_FADE, tray:GetAlpha(), 0)
        if tray.fadeInfo then tray.fadeInfo.finishedFunc = CloseFlyout end
    else
        CloseFlyout()
    end
end

function StartFlyoutTimer()
    StopFlyoutTimer()
    if not C_Timer or not C_Timer.NewTimer then return end
    flyoutTimer = C_Timer.NewTimer(FLYOUT_TIMEOUT, FadeOutFlyout)
end

function CloseFlyout()
    StopFlyoutTimer()
    if openFlyout then
        if openFlyout.fadeInfo then openFlyout.fadeInfo.finishedFunc = nil end
        if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(openFlyout) end
        openFlyout:SetAlpha(1)
        openFlyout:Hide()
        openFlyout = nil
    end
end

addon.CloseFlyout = CloseFlyout

-- entries: { { kind = "spell"|"item", name = , icon = , subtitle = }, ... }
local function BuildFlyout(button, entries, db)
    local tray = button.flyoutFrame
    if not tray then
        tray = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        tray:SetFrameStrata("DIALOG")
        tray:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        tray:SetBackdropColor(0, 0, 0, 0.9)
        tray:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        -- The tray grows upward, so a bar near the top of the screen would
        -- otherwise push it out of view.
        tray:SetClampedToScreen(true)
        tray:Hide()
        tray.buttons = {}
        button.flyoutFrame = tray
    end

    local size = db.iconSize
    local padding = db.padding

    for index, entry in ipairs(entries) do
        local spellButton = tray.buttons[index]
        if not spellButton then
            spellButton = CreateFrame("Button",
                addonName .. "Flyout" .. tostring(button.gridID) .. "_" .. index,
                tray, "SecureActionButtonTemplate")
            RegisterClicks(spellButton)

            for _, region in pairs({ spellButton:GetRegions() }) do
                if region:IsObjectType("Texture") then
                    region:Hide()
                    region:SetTexture(nil)
                end
            end

            spellButton.bg = spellButton:CreateTexture(nil, "BACKGROUND")
            spellButton.bg:SetAllPoints()
            spellButton.bg:SetColorTexture(0, 0, 0, 0.8)

            spellButton.icon = spellButton:CreateTexture(nil, "ARTWORK")
            spellButton.icon:SetPoint("TOPLEFT", 2, -2)
            spellButton.icon:SetPoint("BOTTOMRIGHT", -2, 2)
            spellButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            spellButton.highlight = spellButton:CreateTexture(nil, "HIGHLIGHT")
            spellButton.highlight:SetAllPoints()
            spellButton.highlight:SetColorTexture(1, 1, 1, 0.25)

            spellButton:SetScript("OnEnter", function(self)
                HoldFlyoutOpen()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.entryKind == "item" and self.entryItemID then
                    GameTooltip:SetHyperlink("item:" .. self.entryItemID)
                else
                    GameTooltip:AddLine(self.entryName or "", 1, 0.82, 0)
                    if self.entrySubtitle then
                        GameTooltip:AddLine(self.entrySubtitle, 0.6, 0.6, 0.6)
                    end
                end
                GameTooltip:Show()
            end)
            spellButton:SetScript("OnLeave", function()
                GameTooltip:Hide()
                StartFlyoutTimer()
            end)
            spellButton:HookScript("PostClick", CloseFlyout)

            tray.buttons[index] = spellButton
        end

        spellButton:SetSize(size, size)
        spellButton:ClearAllPoints()
        spellButton:SetPoint("TOPLEFT", tray, "TOPLEFT",
                             4, -4 - (index - 1) * (size + padding))
        local kind = entry.kind or "spell"
        spellButton.entryKind = kind
        spellButton.entryName = entry.name
        spellButton.entryItemID = entry.itemID
        spellButton.entrySubtitle = entry.subtitle
        spellButton.icon:SetTexture(entry.icon)

        -- Clear the other kind first: these buttons are pooled, and a leftover
        -- spell attribute would win over the item one.
        spellButton:SetAttribute("spell", nil)
        spellButton:SetAttribute("item", nil)
        spellButton:SetAttribute("type", kind)
        -- The item action resolves a NAME through UseItemByName; "item:<id>"
        -- silently does nothing, the same trap the main buttons hit.
        spellButton:SetAttribute(kind, entry.name)

        if entry.count then
            spellButton.count = spellButton.count
                or spellButton:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            spellButton.count:SetPoint("BOTTOMRIGHT", -2, 2)
            spellButton.count:SetText(entry.count)
            spellButton.count:Show()
        elseif spellButton.count then
            spellButton.count:Hide()
        end

        spellButton:Show()
    end

    for index = #entries + 1, #tray.buttons do
        tray.buttons[index]:Hide()
    end

    tray:SetSize(size + 8, #entries * size + (#entries - 1) * padding + 8)
    tray:ClearAllPoints()
    tray:SetPoint("BOTTOM", button, "TOP", 0, 4)
    return tray
end

function addon.ToggleFlyout(button, entries)
    local data = button.itemData
    entries = entries or (data and data.flyout)
    if not entries or #entries == 0 or InCombatLockdown() then return end

    if openFlyout and openFlyout == button.flyoutFrame and openFlyout:IsShown() then
        CloseFlyout()
        return
    end

    CloseFlyout()
    local db = addon:GetGrid(button.gridID)
    if not db then return end

    local tray = BuildFlyout(button, entries, db)
    tray:SetAlpha(1)
    tray:Show()
    openFlyout = tray
    StartFlyoutTimer()
end

-- Every usable candidate for this button's potion slot, best first, as flyout
-- entries. Built at click time so the list is never stale.
local function AlternativeEntries(button)
    local data = button.itemData
    local slotKey = type(data) == "table" and data.slotKey
    local pool = slotKey and (addon.potionAlternatives or {})[slotKey]
    if not pool then return nil end

    local entries = {}
    for _, candidate in ipairs(pool) do
        local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(candidate.itemID)
        table.insert(entries, {
            kind = "item",
            name = candidate.name,
            itemID = candidate.itemID,
            icon = icon,
            count = candidate.count,
        })
    end
    return entries
end

addon.AlternativeEntries = AlternativeEntries

-- Draws the seconds left on a cooldown, and says whether one is running so
-- the redraw ticker knows to keep going.
local function RefreshCooldownText(button, itemID)
    if not itemID or not addon.ShouldDrawCooldownNumbers() then
        button.cooldownText:Hide()
        return false
    end

    -- A secret cooldown has no number to show; the swirl still shows it.
    local start, duration = GetItemCooldown(itemID)
    start, duration = addon.Num(start), addon.Num(duration)
    if not start or not duration or duration <= 0 then
        button.cooldownText:Hide()
        return false
    end

    local remaining = start + duration - GetTime()
    if remaining <= 0 then
        button.cooldownText:Hide()
        return false
    end

    -- The short shared cooldown every consumable gets on use is noise, not
    -- information; only a real wait is worth a number.
    if duration <= 2 then
        button.cooldownText:Hide()
        return false
    end

    button.cooldownText:SetText(addon.FormatCooldown(remaining))
    button.cooldownText:SetTextColor(remaining <= 5 and 1 or 1,
                                    remaining <= 5 and 0.4 or 0.82,
                                    remaining <= 5 and 0.4 or 0)
    button.cooldownText:Show()
    return true
end

-------------------------------
-- Live State
-------------------------------
-- What a button shows that changes without the bar being rebuilt: the stack
-- count, the cooldown, and the timers.
--
-- None of these are protected calls. Only *layout* is -- moving a secure
-- button, reparenting it, showing or hiding it, setting its attributes -- and
-- that is why layout is gated on InCombatLockdown. Counts and cooldowns were
-- gated behind the same check by being folded into the layout pass, so a
-- potion used in combat kept its old number and never showed a cooldown at
-- all, which is precisely when both matter most.
--
-- So this is separated out and runs in combat as well. What it deliberately
-- does not do is change which button holds which item: that needs the
-- protected calls, so the *selection* stays frozen until combat ends while the
-- numbers on it stay live.

-- On-hand count for what this button stands for, read fresh every time.
local function LiveCount(button, itemData, isTable)
    -- An aggregate slot stands for a whole set, so its number is the sum
    -- across the set rather than any one member's stack.
    if isTable and itemData.aggregate then
        local total = 0
        for _, member in ipairs(itemData.aggregate) do
            if member.itemID then
                total = total + (GetItemCount(member.itemID) or 0)
            end
        end
        return total
    end

    -- Ammo sits in an inventory slot, where GetItemCount does not look.
    if isTable and itemData.slotKey == "ammo" then
        local ammo = addon:AmmoInfo()
        return (ammo and ammo.count) or 0
    end

    if isTable and itemData.countOverride then
        return itemData.countOverride
    end

    return button.itemID and (GetItemCount(button.itemID) or 0) or 0
end

-- Returns true when something on this button is counting down, so the redraw
-- ticker knows whether it still has work.
local function RefreshLiveButton(button, db)
    local itemData = button.itemData
    if not itemData then return false end

    local isTable = type(itemData) == "table"
    local itemID = button.itemID
    local counting = false

    -- Count area.
    if isTable and itemData.enchantSlot then
        -- The countdown replaces the stack count: what matters about a
        -- sharpening stone is whether the enchant on the weapon has lapsed.
        local main, off = addon:WeaponEnchantTime()
        local remaining = itemData.enchantSlot == "mainHand" and main or off
        if remaining then
            button.count:SetText(addon.FormatDuration(remaining))
            button.count:SetTextColor(1, 1, 1)
            counting = true
        else
            button.count:SetText("!")
            button.count:SetTextColor(1, 0.3, 0.3)
        end
        -- Dim while the weapon is enchanted, bright once it is not: the lapse
        -- is the thing worth looking at.
        button.icon:SetDesaturated(remaining ~= nil)
        button.desaturate:Hide()
    elseif isTable and itemData.hideCount then
        -- Teleports are not stacks, and a worn item counts as zero in the bags,
        -- so a number here would be noise or an outright lie.
        button.count:SetText("")
        button.count:SetTextColor(1, 1, 1)
        button.icon:SetDesaturated(false)
        button.desaturate:Hide()
    else
        local count = LiveCount(button, itemData, isTable)
        if count > 0 then
            button.count:SetText(count)
            -- Running low is worth noticing before it becomes running out, so
            -- the count says so rather than a chat line.
            local low = db.lowSupply or 0
            if low > 0 and count <= low then
                button.count:SetTextColor(1, 0.65, 0.1)
            else
                button.count:SetTextColor(1, 1, 1)
            end
            button.icon:SetDesaturated(false)
            button.desaturate:Hide()
        else
            -- Running dry mid-fight cannot hide the button, since that is a
            -- protected call, so it says zero instead of lying.
            button.count:SetText("0")
            button.count:SetTextColor(1, 0.3, 0.3)
            button.icon:SetDesaturated(true)
        end
    end

    -- Time left on the buff this item applies -- a flask, an elixir, food.
    local buffLeft = itemID and addon.BuffTimeRemaining(itemID)
    if buffLeft then
        button.timerText:SetText(addon.FormatDuration(buffLeft))
        button.timerText:Show()
        counting = true
    else
        button.timerText:SetText("")
    end

    -- Cooldown swirl and its number.
    if itemID then
        if addon.DrawCooldown(button.cooldown, GetItemCooldown(itemID)) then counting = true end
    elseif isTable and itemData.spellID and addon.GetSpellCooldown then
        -- Same reasoning as the appearance pass, but this is the one that runs
        -- while the cooldown is actually ticking.
        if addon.DrawCooldown(button.cooldown, addon.GetSpellCooldown(itemData.spellID)) then counting = true end
    else
        button.cooldown:Clear()
    end

    if RefreshCooldownText(button, itemID) then
        counting = true
    end

    -- An item whose buff is running is dimmed in cities rather than hidden.
    if itemID and not db.isAuto and state.inCity
        and addon.HasAssociatedBuff(itemID) and addon.IsBuffActive(itemID) then
        button.desaturate:Show()
        button.icon:SetDesaturated(true)
    end

    if counting then addon:StartTimerTicker() end
    return counting
end

-- Refresh every button already on screen. Safe in combat, and the only thing
-- that runs during it.
function addon:RefreshLiveState()
    for gridID, buttons in pairs(itemButtons) do
        local db = self:GetGrid(gridID)
        if db then
            for _, button in ipairs(buttons) do
                if button:IsShown() then
                    RefreshLiveButton(button, db)
                end
            end
        end
    end
end

-- Returns true when the button should take a slot in the layout.
local function UpdateButtonAppearance(button, itemData, db)
    local isTable = type(itemData) == "table"

    -- Three kinds of button stand for no item at all -- a spell flyout, an
    -- unconfigured prompt, and a configured-but-not-usable state -- so all
    -- three must be handled before the itemID check.
    if isTable and (itemData.flyout or itemData.needsSetup or itemData.inactive
        or itemData.isCreateSpell or itemData.isSpell) then
        button.itemID = nil
        button.itemName = nil
        button.itemData = itemData
        ApplyButtonAction(button)

        local inactiveIcon = itemData.iconOverride
        if not inactiveIcon and itemData.itemID then
            inactiveIcon = select(10, GetItemInfo(itemData.itemID))
        end
        button.icon:SetTexture(inactiveIcon)
        -- A display-only button with a count is reporting a real stack, so it
        -- is not dimmed the way an unconfigured prompt is.
        button.icon:SetDesaturated(
            (itemData.needsSetup or (itemData.inactive and not itemData.countOverride))
            and true or false)
        button.desaturate:Hide()

        -- A spell button has no item to read a cooldown from, so it reads the
        -- spell. Astral Recall shares the hearthstone cooldown, and a hearth
        -- button that cannot say whether it is ready is worse than no button.
        local spellStart, spellDuration
        if itemData.spellID and addon.GetSpellCooldown then
            spellStart, spellDuration = addon.GetSpellCooldown(itemData.spellID)
        end
        addon.DrawCooldown(button.cooldown, spellStart, spellDuration)
        button.cooldownText:Hide()
        button.keybindText:SetText("")
        button.upgradeIcon:Hide()
        button.petIcon:Hide()
        button.timerText:SetText("")

        if itemData.flyout then
            button.flyoutArrow:Show()
            button.needsSetupIcon:Hide()
            button.count:SetText(#itemData.flyout)
        elseif itemData.countOverride then
            button.flyoutArrow:Hide()
            button.needsSetupIcon:Hide()
            local low = db.lowSupply or 0
            button.count:SetText(itemData.countOverride)
            if itemData.countOverride == 0 then
                button.count:SetTextColor(1, 0.3, 0.3)
            elseif low > 0 and itemData.countOverride <= low then
                button.count:SetTextColor(1, 0.65, 0.1)
            else
                button.count:SetTextColor(1, 1, 1)
            end
        else
            button.flyoutArrow:Hide()
            button.count:SetText("")
            if itemData.needsSetup then
                button.needsSetupIcon:Show()
            else
                button.needsSetupIcon:Hide()
            end
        end

        if state.bindingMode then
            button.bindOverlay:Show()
        else
            button.bindOverlay:Hide()
        end

        button:Show()
        return true
    end

    local itemID = GetItemIDFromData(itemData)
    if not itemID then
        button:Hide()
        return false
    end

    local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
    if not itemName then
        button:Hide()
        return false
    end

    -- On-hand only. Bank contents belong in the tooltip, not on the icon.
    button.itemID = itemID
    local count = LiveCount(button, itemData, isTable)

    -- The auto bar opts out of buff hiding: the Food and Drink auras match by
    -- name, so the button you are actively using would vanish mid-meal.
    local hasBuff, buffActive = false, false
    if not db.isAuto then
        hasBuff = addon.HasAssociatedBuff(itemID)
        buffActive = hasBuff and addon.IsBuffActive(itemID)
        if hasBuff and buffActive and not state.inCity then
            button:Hide()
            return false
        end
    end

    if count == 0 and isTable and itemData.hideOnZero then
        button:Hide()
        return false
    end

    button.itemID = itemID
    button.itemName = itemName
    button.itemData = itemData
    ApplyButtonAction(button)

    button.icon:SetTexture((isTable and itemData.iconOverride) or itemIcon)

    RefreshLiveButton(button, db)

    local bindID = addon.KeybindID(itemData)
    if bindID and db.keybinds and db.keybinds[bindID] then
        button.keybindText:SetText(db.keybinds[bindID])
    else
        button.keybindText:SetText("")
    end

    if isTable and itemData.showUpgrade then
        button.upgradeIcon:Show()
    else
        button.upgradeIcon:Hide()
    end

    if isTable and itemData.petTarget then
        if SetPortraitTexture and UnitExists("pet") then
            SetPortraitTexture(button.petIcon, "pet")
        else
            button.petIcon:SetTexture(PET_BADGE_FALLBACK)
        end
        button.petIcon:Show()
    else
        button.petIcon:Hide()
    end

    button.needsSetupIcon:Hide()

    -- notReady means the action is a prerequisite rather than the real thing --
    -- the Parachute Cloak still sitting in a bag, waiting to be equipped.
    if isTable and itemData.notReady then
        button.icon:SetDesaturated(true)
    end

    button.flyoutArrow:Hide()

    if state.bindingMode then
        button.bindOverlay:Show()
    else
        button.bindOverlay:Hide()
    end

    button:Show()
    return true
end

-------------------------------
-- Combat Visibility
-------------------------------
-- Hiding a secure button or its parent from Lua during combat is a protected
-- action; the old code did exactly that on PLAYER_REGEN_DISABLED and threw
-- action-blocked errors. State drivers let the client do the hiding instead.
-- Only ever called out of combat, since layout is gated on InCombatLockdown.

local hasStateDrivers = type(RegisterStateDriver) == "function"
    and type(UnregisterStateDriver) == "function"

-- Death is expressed as a macro conditional rather than handled from Lua: the
-- client evaluates it, so nothing is hidden from an insecure path, and it costs
-- no events. "target=player" is the pre-3.x spelling of "@player" and is what
-- this client understands.
local DEAD_CLAUSE = "[target=player,dead] hide"
local COMBAT_CLAUSE = "[combat] hide"

local function ApplyVisibility(frame, db, hasContent, hasCombatItems)
    if hasStateDrivers then
        UnregisterStateDriver(frame, "visibility")
        UnregisterStateDriver(frame.normalHolder, "visibility")
    end
    frame.normalHolder:Show()
    frame.combatHolder:Show()

    if not db.enabled or not hasContent then
        frame:Hide()
        return
    end

    frame:Show()

    -- Without state drivers the grid simply stays visible, which is cosmetic;
    -- hiding it from Lua would throw action-blocked errors.
    if not hasStateDrivers then return end

    -- Nothing in a bag can be used while dead, so the whole frame goes --
    -- including any item that opted into showing during combat.
    local frameClauses = {}
    if db.hideWhenDead then
        table.insert(frameClauses, DEAD_CLAUSE)
    end

    if not db.showInCombat and not hasCombatItems then
        table.insert(frameClauses, COMBAT_CLAUSE)
    end

    if #frameClauses > 0 then
        table.insert(frameClauses, "show")
        RegisterStateDriver(frame, "visibility", table.concat(frameClauses, "; "))
    end

    -- Some items opt into combat: keep the frame up and hide only the buttons
    -- that do not.
    if not db.showInCombat and hasCombatItems then
        RegisterStateDriver(frame.normalHolder, "visibility", COMBAT_CLAUSE .. "; show")
    end
end

-------------------------------
-- Layout
-------------------------------

-- Group state, spelled for whichever API this client has.
function addon.IsInGroupNow()
    if IsInGroup then return IsInGroup() end
    if GetNumGroupMembers then return GetNumGroupMembers() > 0 end
    if GetNumPartyMembers then return GetNumPartyMembers() > 0 end
    return false
end

-- Instance and group have no macro conditional, so unlike combat and death
-- they are decided here -- inside layout, which only runs out of combat -- and
-- fed into the same path that hides an empty bar.
-- True when a bar would be hidden right now were the config window not open.
-- Shared, so the rule that suspends the hiding and the chrome that signals it
-- cannot come to disagree about which bars are in that state.
function addon.SuspendedForMoveMode(db)
    return (db.hideWhileBuffed and addon:HasFoodBuff()) or false
end

local function PassesVisibilityRules(db)
    -- A bar that only means anything to one class. The grid still exists for
    -- every character so a hunter alt keeps its position and settings, but on
    -- anyone else it never draws -- not even the move-mode placeholder, which
    -- is all an empty bar would otherwise put on screen.
    if db.hunterOnly and not addon:IsHunter() then return false end
    -- The buff food bar is a reminder, and a reminder that stays up after you
    -- have acted on it stops being read. Decided here rather than by a macro
    -- conditional because there is no conditional for "has this buff" -- which
    -- also means it can only change out of combat, the same as instance and
    -- group below.
    --
    -- Suspended while the config window is open. A bar you cannot see is a bar
    -- you cannot place, and this one spends most of its time hidden by design
    -- -- so without this the only way to position it would be to let the buff
    -- run out first. It is drawn dimmed while suspended, so that "on screen
    -- only because this window is open" does not read as hiding being broken.
    if addon.SuspendedForMoveMode(db) and not MoveModeActive() then
        return false
    end
    if db.onlyInInstance then
        local inInstance = IsInInstance and IsInInstance() or false
        if not inInstance then return false end
    end
    if db.onlyInGroup and not addon.IsInGroupNow() then
        return false
    end
    return true
end

addon.PassesVisibilityRules = PassesVisibilityRules

-- The border and name a bar wears while it can be dragged. Called from layout,
-- which reruns whenever the config window opens or closes.
-- Right-drag is a drag only while bars are movable; the rest of the time a
-- right-click on a button belongs to the button.
local function ApplyButtonDragMode(button)
    if MoveModeActive() then
        button:RegisterForDrag("LeftButton", "RightButton")
    else
        button:RegisterForDrag("LeftButton")
    end
end

local function UpdateMoveChrome(frame, db)
    local border = frame.moveBorder
    if not border then return end

    if not MoveModeActive() then
        border:Hide()
        if frame.moveHandle then frame.moveHandle:Hide() end
        -- Whatever the dim below set must not outlive move mode.
        frame:SetAlpha(1)
        return
    end

    frame.moveLabel:SetText(db.name or "")
    border:Show()
    if frame.moveHandle then frame.moveHandle:Show() end

    -- Ghosted when the only reason it is on screen is that this window is open.
    --
    -- The frame is faded rather than the icons desaturated: UpdateButtonAppearance
    -- and RefreshLiveButton both set SetDesaturated for reasons of their own --
    -- a lapsed enchant, an unconfigured slot, a buff already running -- so a
    -- third writer would fight them on pooled buttons and lose at random.
    frame:SetAlpha(addon.SuspendedForMoveMode(db) and 0.45 or 1)
end

-- Show or drop the move borders right now, without waiting for a relayout.
--
-- Closing the config window during combat would otherwise leave every bar
-- wearing a border that says "drag me" until combat ended, because layout is
-- combat-gated. The border is a plain frame, not a secure one, so it can be
-- shown and hidden at any time.
function addon:RefreshMoveChrome()
    for gridID, frame in pairs(frames) do
        local db = self:GetGrid(gridID)
        if db then UpdateMoveChrome(frame, db) end
    end
end

local function UpdateGridLayout(gridID)
    local db = addon:GetGrid(gridID)
    local frame = frames[gridID]
    if not db or not frame then return end

    if not PassesVisibilityRules(db) then
        for _, button in ipairs(itemButtons[gridID] or {}) do button:Hide() end
        ApplyVisibility(frame, db, false, false)
        return
    end

    if not itemButtons[gridID] then
        itemButtons[gridID] = {}
    end
    local buttons = itemButtons[gridID]

    if not db.enabled then
        for _, button in ipairs(buttons) do button:Hide() end
        CloseFlyout()
        ApplyVisibility(frame, db, false, false)
        return
    end

    local columns = db.columns
    local size = db.iconSize
    local padding = db.padding

    for _, button in ipairs(buttons) do
        button:Hide()
    end

    local visibleButtons = {}
    local hasCombatItems = false

    for i, itemData in ipairs(db.items) do
        if not buttons[i] then
            buttons[i] = CreateItemButton(frame.normalHolder, gridID, i)
        end

        local button = buttons[i]
        local showInCombat = GetShowInCombatFromData(itemData)

        -- Reparent so the combat state driver on normalHolder only affects the
        -- buttons that should hide in combat.
        local holder = showInCombat and frame.combatHolder or frame.normalHolder
        if button:GetParent() ~= holder then
            button:SetParent(holder)
        end

        button:SetSize(size, size)
        button:SetFrameLevel(frame:GetFrameLevel() + 10)

        if UpdateButtonAppearance(button, itemData, db) then
            table.insert(visibleButtons, button)
            if showInCombat then
                hasCombatItems = true
            end
        end
    end

    local totalVisible = #visibleButtons
    if totalVisible == 0 then
        -- An empty bar has nothing to show, but it still has a position worth
        -- setting, so in move mode it keeps a small placeholder to grab. The
        -- rest of the time it gets out of the way entirely.
        if MoveModeActive() then
            frame:SetSize(48, 48)
            RepositionFrame(frame, db, 48, 48)
            ApplyVisibility(frame, db, true, false)
            UpdateMoveChrome(frame, db)
        else
            ApplyVisibility(frame, db, false, false)
        end
        return
    end

    local rows = math.ceil(totalVisible / columns)
    local actualCols = math.min(totalVisible, columns)
    local contentWidth = actualCols * size + (actualCols - 1) * padding
    local contentHeight = rows * size + (rows - 1) * padding
    local gridWidth = contentWidth + 8
    local gridHeight = contentHeight + 8

    for idx, button in ipairs(visibleButtons) do
        ApplyButtonDragMode(button)
        local col = (idx - 1) % columns
        local row = math.floor((idx - 1) / columns)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", frame, "TOPLEFT",
                        4 + col * (size + padding),
                        -4 - row * (size + padding))
    end

    frame:SetSize(gridWidth, gridHeight)
    RepositionFrame(frame, db, gridWidth, gridHeight)

    ApplyVisibility(frame, db, true, hasCombatItems)
    UpdateMoveChrome(frame, db)
end

-------------------------------
-- Grid Frames
-------------------------------

function addon:CreateGridFrame(gridID)
    local db = self:GetGrid(gridID)
    if not db then return end

    local frame = CreateFrame("Frame", addonName .. "Grid" .. gridID, UIParent, "BackdropTemplate")
    frame:SetSize(100, 100)
    -- Placed from the saved position straight away, not from the legacy
    -- anchor. Layout would put it right on the first pass, but a first pass
    -- can be deferred -- logging in already in combat is enough -- and a bar
    -- that appears at the spot it shipped with reads as settings lost. No
    -- write back here: the size is a placeholder, so converting the pivot
    -- against it would move the bar rather than place it.
    if db.pos then
        frame:SetPoint(db.posPivot or "TOPLEFT", UIParent, "CENTER",
                       db.pos.x, db.pos.y)
    else
        frame:SetPoint(db.anchor.point, UIParent, db.anchor.point,
                       db.anchor.x, db.anchor.y)
    end
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    -- Mouse-enabled so the empty background can take a dropped item; child
    -- buttons still receive their own clicks first.
    frame:EnableMouse(true)
    frame:SetScript("OnReceiveDrag", function()
        addon.AcceptCursorItem(gridID, nil)
    end)
    frame:SetScript("OnMouseUp", function()
        if CursorHasItem and CursorHasItem() then
            addon.AcceptCursorItem(gridID, nil)
        end
    end)
    frame.gridID = gridID

    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    -- Buttons live in one of these two so combat visibility can be driven by
    -- the client rather than by protected Show/Hide calls from Lua.
    local normalHolder = CreateFrame("Frame", nil, frame)
    normalHolder:SetAllPoints()
    normalHolder:EnableMouse(false)
    frame.normalHolder = normalHolder

    local combatHolder = CreateFrame("Frame", nil, frame)
    combatHolder:SetAllPoints()
    combatHolder:EnableMouse(false)
    frame.combatHolder = combatHolder

    -- Move mode: while the config window is open every bar takes a coloured
    -- border and its name, so it is obvious which bar is which and that they
    -- can be dragged. Both go away with the window.
    local moveBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    moveBorder:SetPoint("TOPLEFT", -3, 3)
    moveBorder:SetPoint("BOTTOMRIGHT", 3, -3)
    moveBorder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
    })
    moveBorder:SetBackdropBorderColor(1, 0.82, 0, 0.9)
    -- Above the buttons, which sit at frame level + 10, so the outline is not
    -- half-hidden behind the icons it surrounds.
    moveBorder:SetFrameLevel(frame:GetFrameLevel() + 20)
    moveBorder:EnableMouse(false)
    moveBorder:Hide()
    frame.moveBorder = moveBorder

    local moveLabel = moveBorder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    moveLabel:SetPoint("BOTTOM", moveBorder, "TOP", 0, 2)
    moveLabel:SetTextColor(1, 0.82, 0)
    frame.moveLabel = moveLabel

    -- The grab point.
    --
    -- The whole bar already answers a right-drag, but nothing on screen says
    -- so, and a right-drag is not what anyone reaches for first. So move mode
    -- also hangs a handle off the corner: one thing that plainly means "pick
    -- me up", and one that takes a plain left-drag. It lives outside the bar,
    -- tucked against the move border, so it never sits on top of an icon and
    -- never eats a click meant for one.
    --
    -- It appears and disappears with the border, which is to say with the
    -- config window -- there is no handle to hunt for the rest of the time.
    local moveHandle = CreateFrame("Button", nil, frame)
    moveHandle:SetSize(16, 16)
    moveHandle:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", 2, 3)
    -- Above the move border, which is itself above the buttons.
    moveHandle:SetFrameLevel(frame:GetFrameLevel() + 21)

    local handleBackdrop = moveHandle:CreateTexture(nil, "BACKGROUND")
    handleBackdrop:SetAllPoints()
    handleBackdrop:SetColorTexture(0, 0, 0, 0.85)
    moveHandle.backdrop = handleBackdrop

    -- The grip is drawn rather than loaded. A three-by-three of dots reads as
    -- "drag me" at any size, and drawing it means there is no texture path to
    -- be wrong about on a client this addon has not been run on yet.
    moveHandle.dots = {}
    for row = 0, 2 do
        for col = 0, 2 do
            local dot = moveHandle:CreateTexture(nil, "ARTWORK")
            dot:SetSize(2, 2)
            dot:SetPoint("TOPLEFT", moveHandle, "TOPLEFT",
                         4 + col * 4, -(4 + row * 4))
            dot:SetColorTexture(1, 0.82, 0, 1)
            table.insert(moveHandle.dots, dot)
        end
    end

    local function SetHandleHighlight(on)
        handleBackdrop:SetColorTexture(0, 0, 0, on and 0.95 or 0.85)
        for _, dot in ipairs(moveHandle.dots) do
            if on then
                dot:SetColorTexture(1, 1, 1, 1)
            else
                dot:SetColorTexture(1, 0.82, 0, 1)
            end
        end
    end

    moveHandle:RegisterForDrag("LeftButton", "RightButton")
    moveHandle:SetScript("OnDragStart", function() BeginMove(frame) end)
    moveHandle:SetScript("OnDragStop", function() EndMove(frame) end)
    moveHandle:SetScript("OnEnter", function(self)
        SetHandleHighlight(true)
        local grid = addon:GetGrid(gridID)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText((grid and grid.name) or "ChairSnack bar", 1, 0.82, 0)
        GameTooltip:AddLine("Drag to move this bar.", 1, 1, 1)
        GameTooltip:AddLine("The handle goes away when the config window " ..
                            "closes.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    moveHandle:SetScript("OnLeave", function()
        SetHandleHighlight(false)
        GameTooltip:Hide()
    end)
    moveHandle:Hide()
    frame.moveHandle = moveHandle

    frame:RegisterForDrag("RightButton")
    frame:SetScript("OnDragStart", function(self) BeginMove(self) end)
    frame:SetScript("OnDragStop", function(self) EndMove(self) end)
    -- A bar hidden mid-drag -- by a state driver, or by going empty -- would
    -- never see its OnDragStop and would still be following the mouse when it
    -- came back.
    frame:HookScript("OnHide", function(self) EndMove(self) end)

    -- Stays hidden until the first layout sizes and places it.
    frame:Hide()

    frames[gridID] = frame
    return frame
end

-------------------------------
-- Update Scheduling
-------------------------------

function addon:UpdateAllGrids()
    if InCombatLockdown() then
        state.needsUpdate = true
        return
    end

    self:CheckPlayerBuffs()
    self:CheckIfInCity()

    for gridID in pairs(self:GetGrids()) do
        -- Laid out one bar at a time rather than in one pass that any bar can
        -- abort.
        --
        -- Positioning is the last thing a bar's layout does, so a bar that
        -- throws is a bar left wherever it was created. Worse, in one pass it
        -- took every bar after it with it, and with the client's script
        -- errors switched off -- which is the default -- the whole thing
        -- happened in silence and looked exactly like settings not loading.
        local ok, err = pcall(UpdateGridLayout, gridID)
        if not ok then
            self.lastLayoutError = tostring(err)
            if not self.reportedLayoutError then
                self.reportedLayoutError = true
                self:Print("|cffff5555a bar failed to lay out, so it is not " ..
                           "where you left it:|r " .. tostring(err) ..
                           " |cff808080(/chair snack pos for detail)|r")
            end
        end
    end

    self:ApplyKeybinds()
end

-- Coalesce bursts of events into one relayout on the next frame, instead of the
-- old unconditional twice-a-second full rebuild.
local updater = CreateFrame("Frame")
updater:Hide()
updater:SetScript("OnUpdate", function(self)
    self:Hide()
    state.needsUpdate = false
    addon:UpdateAllGrids()
end)

-------------------------------
-- Countdown Ticker
-------------------------------
-- Buff and weapon-enchant timers need a redraw about once a second. This
-- repaints only the two text fields that change -- it is not a relayout, and it
-- is deliberately not a return to the per-frame OnUpdate that v2.0 removed.
-- It runs only while something on screen is actually counting down.

local timerTicker = nil

local function RefreshTimers()
    local wanted = false

    for gridID, buttons in pairs(itemButtons) do
        local db = addon:GetGrid(gridID)
        if db then
            for _, button in ipairs(buttons) do
                if button:IsShown() then
                    if RefreshLiveButton(button, db) then wanted = true end
                end
            end
        end
    end

    -- Nothing left counting: stop until something starts again.
    if not wanted and timerTicker then
        timerTicker:Cancel()
        timerTicker = nil
    end
end

function addon:StartTimerTicker()
    if timerTicker or not C_Timer or not C_Timer.NewTicker then return end
    timerTicker = C_Timer.NewTicker(1, RefreshTimers)
end

function addon:HasTimerTicker()
    return timerTicker ~= nil
end

function addon:RequestUpdate()
    if InCombatLockdown() then
        state.needsUpdate = true
        return
    end
    updater:Show()
end

-------------------------------
-- Keybinds
-------------------------------

-- Bind to a click on the button so the secure action decides what to use; this
-- works regardless of how the item is named.
function addon:ApplyKeybinds()
    if InCombatLockdown() then return end

    for gridID, db in pairs(self:GetGrids()) do
        local buttons = itemButtons[gridID]
        if buttons then
            for _, button in pairs(buttons) do
                -- Only what is actually on the bar holds a key. A hidden
                -- button keeps the last item it showed, so binding by that
                -- would resurrect a key for something no longer there.
                local bindID = button:IsShown() and button.itemData
                    and addon.KeybindID(button.itemData) or nil
                local key = bindID and db.keybinds and db.keybinds[bindID]
                if key and button:GetName() then
                    SetOverrideBindingClick(button, false, key, button:GetName())
                    button.boundKey = key
                elseif button.boundKey then
                    ClearOverrideBindings(button)
                    button.boundKey = nil
                end
            end
        end
    end
end

local function CreateBindingModeFrame()
    if bindingModeFrame then return bindingModeFrame end

    local frame = CreateFrame("Frame", addonName .. "BindingModeFrame", UIParent, "BackdropTemplate")
    frame:SetSize(300, 100)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    frame:SetBackdropBorderColor(0.8, 0.6, 0.0, 1)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cffFFD100Keybind Mode Active|r")

    local instructions = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    instructions:SetPoint("TOP", title, "BOTTOM", 0, -5)
    instructions:SetText("Click a button, then press a key to bind")

    local escInfo = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    escInfo:SetPoint("TOP", instructions, "BOTTOM", 0, -3)
    escInfo:SetText("|cff888888Press ESC on a selected button to clear its binding|r")

    local exitBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    exitBtn:SetSize(120, 22)
    exitBtn:SetPoint("BOTTOM", 0, 10)
    exitBtn:SetText("Exit Bind Mode")
    exitBtn:SetScript("OnClick", function() addon:StopBindingMode() end)

    frame:Hide()
    bindingModeFrame = frame
    return frame
end

function addon:StartBindingMode()
    if InCombatLockdown() then
        self:Print("Cannot enter keybind mode in combat.")
        return
    end

    state.bindingMode = true
    state.pendingBindButton = nil

    CreateBindingModeFrame():Show()

    for _, buttons in pairs(itemButtons) do
        for _, button in ipairs(buttons) do
            if button:IsShown() then
                button.bindOverlay:Show()
                button:SetAttribute("type", nil)
            end
        end
    end

    self:Print("Keybind mode enabled. Click a button then press a key.")
end

function addon:StopBindingMode()
    state.bindingMode = false
    state.pendingBindButton = nil

    if bindingModeFrame then
        bindingModeFrame:Hide()
    end

    if InCombatLockdown() then return end

    for _, buttons in pairs(itemButtons) do
        for _, button in ipairs(buttons) do
            button.bindOverlay:Hide()
            button.bindHighlight:Hide()
            -- Restores whichever action this button carries; a blanket
            -- type="item" would break the Feed Pet macro button.
            ApplyButtonAction(button)
        end
    end

    self:Print("Keybind mode disabled.")
end

local function HandleKeyBind(key)
    if not state.bindingMode or not state.pendingBindButton then return end

    local button = state.pendingBindButton
    local db = addon:GetGrid(button.gridID)
    if not db then return end
    db.keybinds = db.keybinds or {}

    local bindID = button.itemData and addon.KeybindID(button.itemData)
    if not bindID then
        addon:Print("Nothing on that button to bind to.")
        button.bindHighlight:Hide()
        state.pendingBindButton = nil
        return
    end

    if key == "ESCAPE" then
        if db.keybinds[bindID] then
            ClearOverrideBindings(button)
            db.keybinds[bindID] = nil
            button.keybindText:SetText("")
            addon:Print("Binding cleared.")
        end
        button.bindHighlight:Hide()
        state.pendingBindButton = nil
        return
    end

    db.keybinds[bindID] = key
    button.keybindText:SetText(key)
    addon:Print("Bound to " .. key)

    if button:GetName() then
        SetOverrideBindingClick(button, false, key, button:GetName())
    end

    button.bindHighlight:Hide()
    state.pendingBindButton = nil
end

local keybindCaptureFrame = CreateFrame("Frame", addonName .. "KeybindCapture", UIParent)
keybindCaptureFrame:EnableKeyboard(true)
keybindCaptureFrame:SetPropagateKeyboardInput(true)
keybindCaptureFrame:SetScript("OnKeyDown", function(self, key)
    if InCombatLockdown() then return end

    if state.bindingMode and state.pendingBindButton then
        self:SetPropagateKeyboardInput(false)
        HandleKeyBind(key)
        C_Timer.After(0.1, function()
            if not InCombatLockdown() then
                self:SetPropagateKeyboardInput(true)
            end
        end)
    else
        self:SetPropagateKeyboardInput(true)
    end
end)

-------------------------------
-- Minimap Button
-------------------------------

-- Built the way LibDBIcon builds them -- BugSack's, AtlasLoot's -- so it sits
-- in the same ring as everyone else's: a 31px button on the minimap's edge,
-- the gold tracking border round it, the round minimap background behind a
-- 17px icon. It is dragged around the edge rather than anywhere on screen,
-- and remembers where as an angle.

local function MinimapShapeIsSquare()
    local shape = type(GetMinimapShape) == "function" and GetMinimapShape() or "ROUND"
    return shape == "SQUARE"
end

local function PlaceOnMinimap(button)
    local angle = math.rad(addon:GetMinimapDB().minimapPos or 225)
    local x, y = math.cos(angle), math.sin(angle)
    local w = ((tonumber(Minimap:GetWidth()) or 140) / 2) + 5
    local h = ((tonumber(Minimap:GetHeight()) or 140) / 2) + 5
    if MinimapShapeIsSquare() then
        -- Out to the corner's distance, then back inside the square.
        local diagW, diagH = math.sqrt(2 * w * w) - 10, math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * diagW, w))
        y = math.max(-h, math.min(y * diagH, h))
    else
        x, y = x * w, y * h
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end
addon.PlaceMinimapButton = PlaceOnMinimap

local function FollowCursor(button)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not (mx and px and scale and scale > 0) then return end
    px, py = px / scale, py / scale
    addon:GetMinimapDB().minimapPos = math.deg(math.atan2(py - my, px - mx)) % 360
    PlaceOnMinimap(button)
end

function addon:CreateMinimapButton()
    local db = self:GetMinimapDB()

    local button = CreateFrame("Button", addonName .. "MinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\AddOns\\Chaircraft\\ChairSnack\\minimap")
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    -- The little press LibDBIcon gives its icons.
    button:SetScript("OnMouseDown", function() icon:SetTexCoord(0.05, 0.95, 0.05, 0.95) end)
    button:SetScript("OnMouseUp", function() icon:SetTexCoord(0, 1, 0, 1) end)

    PlaceOnMinimap(button)

    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
        self:SetScript("OnUpdate", FollowCursor)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
        icon:SetTexCoord(0, 1, 0, 1)
        PlaceOnMinimap(self)
    end)

    button:SetScript("OnClick", function(self, btn)
        if btn == "LeftButton" then
            -- The suite's main menu. This icon belongs to Chaircraft as a
            -- whole now, not to the part that happens to draw it, so it opens
            -- the front door and lets the menu reach everything else.
            -- Guarded: if the menu is missing for any reason, fall back to
            -- this part's own config rather than doing nothing at all.
            local plus = Chaircraft and Chaircraft.ChairPlus
            if plus and plus.TogglePanel then
                plus.TogglePanel("plus")
            else
                addon:OpenConfig()
            end
        elseif btn == "RightButton" then
            if state.bindingMode then
                addon:StopBindingMode()
            else
                addon:StartBindingMode()
            end
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ChairCraft", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: Open the ChairCraft menu", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: Toggle ChairSnack keybind mode",
            0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag to move it around the minimap", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    if db.hide then
        button:Hide()
    end

    minimapButton = button
    return button
end

-- The icon is a fixed size now, the same as every other minimap button, so
-- this is kept only so an older caller does not error.
function addon:SetMinimapButtonSize() end

function addon:SetMinimapButtonHidden(hide)
    if minimapButton then
        if hide then minimapButton:Hide() else minimapButton:Show() end
        self:GetMinimapDB().hide = hide
    end
end
