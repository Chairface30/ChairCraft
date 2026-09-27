----------------------------------------------------------------------
-- Options.lua
-- GUI configuration: appearance, sort modes, custom order, auto-hide
----------------------------------------------------------------------

WOWFTrackerNS = WOWFTrackerNS or {}

-- Reputation panel access, wrapped in WOWFTracker.lua so the classic and
-- the C_Reputation clients both read the same way. See the notes there.
local GetNumFactions      = WOWFTrackerNS.GetNumFactions
local GetFactionInfo      = WOWFTrackerNS.GetFactionInfo
local GetFactionInfoByID  = WOWFTrackerNS.GetFactionInfoByID
local ExpandFactionHeader = WOWFTrackerNS.ExpandFactionHeader

local PANEL_WIDTH  = 600
-- Tall enough for the Hover Linger slider's value underneath it, which was
-- clipped off the bottom at 680.
local PANEL_HEIGHT = 720

----------------------------------------------------------------------
-- Main options frame
----------------------------------------------------------------------
local opt = CreateFrame("Frame", "WOWFTrackerOptions", UIParent, "BackdropTemplate")
opt:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
opt:SetPoint("CENTER")
opt:SetMovable(true)
opt:EnableMouse(true)
opt:RegisterForDrag("LeftButton")

-- Where the panel was left.
--
-- Measured centre-to-centre against UIParent rather than saved as a corner
-- offset, so a change of resolution or UI scale moves it with the screen
-- instead of parking it off the edge.
local function SaveOptionsPosition(frame)
    if not (WOWFTrackerDB and WOWFTrackerDB.settings) then return end
    local centerX, centerY = UIParent:GetCenter()
    local x, y = frame:GetCenter()
    if not (centerX and x) then return end
    WOWFTrackerDB.optionsPosition = { x = x - centerX, y = y - centerY }
end

local function RestoreOptionsPosition(frame)
    local pos = WOWFTrackerDB and WOWFTrackerDB.optionsPosition
    if not (pos and pos.x and pos.y) then return end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
end

opt:SetScript("OnDragStart", opt.StartMoving)
opt:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveOptionsPosition(self)
end)
-- Restored on show, not at file scope: the saved variables are not loaded
-- yet when this file runs.
opt:SetScript("OnShow", function(self)
    -- Hosted inside the Chaircraft menu, the menu decides where it sits.
    if self.chairEmbedded then return end
    RestoreOptionsPosition(self)
end)
opt:SetClampedToScreen(true)
opt:SetFrameStrata("DIALOG")
opt:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
opt:SetBackdropColor(0.06, 0.06, 0.10, 0.95)
opt:SetBackdropBorderColor(0.45, 0.45, 0.55, 1)
opt:Hide()

tinsert(UISpecialFrames, "WOWFTrackerOptions")

----------------------------------------------------------------------
-- Header
----------------------------------------------------------------------
local header = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
header:SetPoint("TOP", 0, -12)
header:SetText("|cff88aaddChairTracker|r Options")

local credit = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
credit:SetPoint("TOP", header, "BOTTOM", 0, -2)
credit:SetText("by |cff00ccffChairface|r — Enjoy the addon? Mail me a tip in-game!")

local closeBtn = CreateFrame("Button", nil, opt, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -4, -4)

-- What the Chaircraft menu hides while it hosts this window.
opt.chairChrome = { header, credit, closeBtn }
WOWFTrackerNS.optionsFrame = opt

----------------------------------------------------------------------
-- Widget helpers (slider styled after ZPerl / X-Perl)
----------------------------------------------------------------------
local ZPERL_SLIDER_BLUE = { r = 0.4, g = 0.4, b = 0.80 }

local function MakeSlider(parent, label, minVal, maxVal, step, xOff, yOff, width)
    local sliderWidth = width or 180

    -- Inherit BackdropTemplate so SetBackdrop works on 11.x
    local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate, BackdropTemplate")
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, yOff)
    s:SetSize(sliderWidth, 20)
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)

    -- Explicit thumb texture (the draggable knob)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = s:GetThumbTexture()
    if thumb then
        thumb:SetSize(32, 32)
    end

    -- ZPerl-style track bar backdrop
    s:SetBackdrop({
        bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetBackdropColor(0, 0, 0, 1)
    s:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    -- Label text (above)
    s.Text:SetText(label)
    s.Text:SetVertexColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)

    -- Low / High range labels
    s.Low:SetText(minVal)
    s.Low:SetVertexColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
    s.High:SetText(maxVal)
    s.High:SetVertexColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)

    -- Current value text (ZPerl blue, centered below)
    s.valText = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s.valText:SetPoint("TOP", s, "BOTTOM", 0, -2)
    s.valText:SetVertexColor(ZPERL_SLIDER_BLUE.r, ZPERL_SLIDER_BLUE.g, ZPERL_SLIDER_BLUE.b)

    -- Mouse wheel support (ZPerl feature)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        local val = self:GetValue()
        local lo, hi = self:GetMinMaxValues()
        local newVal = val + (delta * step)
        newVal = math.max(lo, math.min(hi, newVal))
        self:SetValue(newVal)
    end)

    return s
end

-- A hover explanation for a setting whose label cannot say it all.
local function Tip(frame, title, text)
    if not (frame and text) then return end
    pcall(frame.HookScript, frame, "OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pcall(frame.HookScript, frame, "OnLeave", function() GameTooltip:Hide() end)
end

local function MakeCheckbox(parent, label, xOff, yOff, onClick, tip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, yOff)
    cb.text:SetText(label)
    cb.text:SetFontObject("GameFontHighlightSmall")
    if onClick then cb:SetScript("OnClick", onClick) end
    Tip(cb, label, tip)
    return cb
end

----------------------------------------------------------------------
-- LEFT COLUMN: Bar Appearance
----------------------------------------------------------------------
local colLeft = 16
local appearLabel = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
appearLabel:SetPoint("TOPLEFT", colLeft, -42)
appearLabel:SetText("Bar Appearance")

local widthSlider = MakeSlider(opt, "Bar Width", 120, 400, 5, colLeft + 4, -72, 200)
widthSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.barWidth = val
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local heightSlider = MakeSlider(opt, "Bar Height", 8, 32, 1, colLeft + 4, -120, 200)
heightSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.barHeight = val
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local spacingSlider = MakeSlider(opt, "Row Spacing", 0, 10, 1, colLeft + 4, -168, 200)
spacingSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.rowSpacing = val
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local fontSlider = MakeSlider(opt, "Font Size", 7, 16, 1, colLeft + 4, -216, 200)
fontSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.fontSize = val
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local alphaSlider = MakeSlider(opt, "BG Opacity", 0, 100, 5, colLeft + 4, -264, 200)
alphaSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val .. "%")
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.bgAlpha = val / 100
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local frameAlphaSlider = MakeSlider(opt, "Frame Opacity", 10, 100, 5, colLeft + 4, -312, 200)
frameAlphaSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val .. "%")
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.frameAlpha = val / 100
        WOWFTrackerNS.RebuildAppearance()
    end
end)

----------------------------------------------------------------------
-- Bar Texture selector
----------------------------------------------------------------------
local texLabel = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
texLabel:SetPoint("TOPLEFT", colLeft, -358)
texLabel:SetText("Bar Texture")

local texButtons = {}
for i, info in ipairs(WOWFTracker_BarTextures) do
    local btn = CreateFrame("Button", nil, opt)
    btn:SetSize(200, 18)
    btn:SetPoint("TOPLEFT", colLeft + 4, -376 - ((i - 1) * 20))

    local preview = btn:CreateTexture(nil, "ARTWORK")
    preview:SetSize(60, 14)
    preview:SetPoint("LEFT")
    preview:SetTexture(info.path)
    preview:SetVertexColor(0.3, 0.5, 0.9)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", preview, "RIGHT", 6, 0)
    lbl:SetText(info.name)

    btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.highlight:SetAllPoints()
    btn.highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    btn.highlight:SetVertexColor(1, 1, 1, 0.1)

    btn.selected = btn:CreateTexture(nil, "BACKGROUND")
    btn.selected:SetAllPoints()
    btn.selected:SetTexture("Interface\\Buttons\\WHITE8X8")
    btn.selected:SetVertexColor(0.3, 0.5, 0.8, 0.2)
    btn.selected:Hide()

    btn:SetScript("OnClick", function()
        if WOWFTrackerDB and WOWFTrackerDB.settings then
            WOWFTrackerDB.settings.barTexture = info.path
            for _, b in ipairs(texButtons) do b.selected:Hide() end
            btn.selected:Show()
            WOWFTrackerNS.RebuildAppearance()
        end
    end)
    texButtons[i] = btn
    btn.texturePath = info.path
end

----------------------------------------------------------------------
-- Checkboxes
----------------------------------------------------------------------
local cbY = -470
local showWindowCB = MakeCheckbox(opt, "Show tracker window", colLeft, cbY, function(self)
    if WOWFTrackerNS.SetWindowVisible then
        WOWFTrackerNS.SetWindowVisible(self:GetChecked() and true or false)
    end
end)

local lockCB = MakeCheckbox(opt, "Lock frame position", colLeft, cbY - 24, function(self)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.locked = self:GetChecked() and true or false
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local headerCB = MakeCheckbox(opt, "Show title bar", colLeft, cbY - 48, function(self)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.showHeader = self:GetChecked() and true or false
        WOWFTrackerNS.RebuildAppearance()
    end
end)

local fadeSlider, showTimeSlider
-- The fade and linger sliders only mean something with auto-hide on.
local function ShowAutoHideSliders(on)
    for _, slider in ipairs({ fadeSlider, showTimeSlider }) do
        if slider then
            pcall(slider.SetEnabled, slider, on and true or false)
            pcall(slider.SetAlpha, slider, on and 1 or 0.4)
        end
    end
end

local autoHideCB = MakeCheckbox(opt, "Auto-hide (show on hover)", colLeft, cbY - 72, function(self)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.autoHide = self:GetChecked() and true or false
        WOWFTrackerNS.RebuildAppearance()
    end
    ShowAutoHideSliders(self:GetChecked())
end, "The window hides itself and comes back while the mouse is over where it sits.")

local exaltedCB = MakeCheckbox(opt, "Show total progress to Exalted", colLeft, cbY - 96, function(self)
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.showTotalToExalted = self:GetChecked() and true or false
        WOWFTrackerNS.UpdateReputation()
    end
end, "Each reputation bar measures the whole way from Neutral to Exalted, rather than the standing it is in.")

-- A time, not a speed: higher is a slower fade.
fadeSlider = MakeSlider(opt, "Fade Time", 10, 100, 5, colLeft + 30, cbY - 134, 160)
Tip(fadeSlider, "Fade Time", "How long the window takes to fade out once the mouse leaves it.")
fadeSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(string.format("%.1fs", val / 100))
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.fadeTime = val / 100
    end
end)

showTimeSlider = MakeSlider(opt, "Hover Linger", 1, 15, 1, colLeft + 30, cbY - 182, 160)
Tip(showTimeSlider, "Hover Linger", "How long the window stays after the mouse leaves, before it starts to fade.")
showTimeSlider:SetScript("OnValueChanged", function(self, val)
    val = math.floor(val + 0.5)
    self.valText:SetText(val .. "s")
    if WOWFTrackerDB and WOWFTrackerDB.settings then
        WOWFTrackerDB.settings.showTime = val
    end
end)

----------------------------------------------------------------------
-- RIGHT COLUMN: Faction Picker + Sort + Custom Order
----------------------------------------------------------------------
local colRight = 260

-- Sort mode
local sortLabel = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sortLabel:SetPoint("TOPLEFT", colRight, -42)
sortLabel:SetText("Sort Mode")

local sortButtons = {}
local sortY = -60
for i, info in ipairs(WOWFTracker_SortModes) do
    local btn = CreateFrame("Button", nil, opt)
    btn:SetSize(160, 16)
    btn:SetPoint("TOPLEFT", colRight + 4, sortY - ((i - 1) * 18))

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", 4, 0)
    lbl:SetText(info.label)
    btn.label = lbl

    btn.selected = btn:CreateTexture(nil, "BACKGROUND")
    btn.selected:SetAllPoints()
    btn.selected:SetTexture("Interface\\Buttons\\WHITE8X8")
    btn.selected:SetVertexColor(0.3, 0.5, 0.8, 0.25)
    btn.selected:Hide()

    btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    btn.highlight:SetAllPoints()
    btn.highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    btn.highlight:SetVertexColor(1, 1, 1, 0.08)

    btn.sortKey = info.key
    btn:SetScript("OnClick", function()
        if WOWFTrackerDB and WOWFTrackerDB.settings then
            WOWFTrackerDB.settings.sortMode = info.key
            for _, b in ipairs(sortButtons) do b.selected:Hide() end
            btn.selected:Show()
            WOWFTrackerNS.SyncCustomOrder()
            WOWFTrackerNS.UpdateReputation()
            RefreshCustomOrder()
        end
    end)
    sortButtons[i] = btn
end

----------------------------------------------------------------------
-- Faction picker header
----------------------------------------------------------------------
local factionLabel = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
factionLabel:SetPoint("TOPLEFT", colRight, sortY - (#WOWFTracker_SortModes * 18) - 10)
factionLabel:SetText("Tracked Factions and Skills")

local factionDescY = sortY - (#WOWFTracker_SortModes * 18) - 24
local factionDesc = opt:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
factionDesc:SetPoint("TOPLEFT", colRight, factionDescY)
factionDesc:SetText("Check the factions and skills to display. Use Custom Order sort to reorder.")

local btnRowY = factionDescY - 16
local selAllBtn = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
selAllBtn:SetSize(50, 20)
selAllBtn:SetPoint("TOPLEFT", colRight, btnRowY)
selAllBtn:SetText("All")

local selNoneBtn = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
selNoneBtn:SetSize(50, 20)
selNoneBtn:SetPoint("LEFT", selAllBtn, "RIGHT", 4, 0)
selNoneBtn:SetText("None")

----------------------------------------------------------------------
-- Tab buttons: "Factions" / "Skills" / "Ordering"
----------------------------------------------------------------------
local tabY = btnRowY - 24
local currentTab = "factions"

local tabFactions = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
tabFactions:SetSize(75, 20)
tabFactions:SetPoint("TOPLEFT", colRight, tabY)
tabFactions:SetText("Factions")

local tabSkills = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
tabSkills:SetSize(60, 20)
tabSkills:SetPoint("LEFT", tabFactions, "RIGHT", 3, 0)
tabSkills:SetText("Skills")

local tabOrder = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
tabOrder:SetSize(75, 20)
tabOrder:SetPoint("LEFT", tabSkills, "RIGHT", 3, 0)
tabOrder:SetText("Ordering")

----------------------------------------------------------------------
-- Scroll frame (shared by both tabs)
----------------------------------------------------------------------
local scrollY = tabY - 24
local scrollParent = CreateFrame("Frame", nil, opt, "BackdropTemplate")
scrollParent:SetPoint("TOPLEFT", colRight - 2, scrollY)
scrollParent:SetPoint("BOTTOMRIGHT", opt, "BOTTOMRIGHT", -14, 14)
scrollParent:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
scrollParent:SetBackdropColor(0.04, 0.04, 0.06, 0.6)
scrollParent:SetBackdropBorderColor(0.35, 0.35, 0.45, 0.7)

local scroll = CreateFrame("ScrollFrame", "WOWFTrackerOptionsScroll", scrollParent, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 6, -6)
scroll:SetPoint("BOTTOMRIGHT", -28, 6)

local scrollChild = CreateFrame("Frame", nil, scroll)
scrollChild:SetSize(1, 1)
scroll:SetScrollChild(scrollChild)

----------------------------------------------------------------------
-- Row pools and hide helpers (forward-declared for cross-tab use)
----------------------------------------------------------------------
local factionRows = {}
local orderRows = {}
local skillRows = {}

local function HideAllRows()
    for _, row in ipairs(factionRows) do row:Hide() end
end

local function HideAllOrderRows()
    for _, row in ipairs(orderRows) do row:Hide() end
end

local function HideAllSkillRows()
    for _, row in ipairs(skillRows) do row:Hide() end
end

local function HideAllTabs()
    HideAllRows()
    HideAllOrderRows()
    HideAllSkillRows()
end

----------------------------------------------------------------------
-- Faction list (All Factions tab)
----------------------------------------------------------------------
local function BuildFactionList()
    HideAllTabs()
    if not WOWFTrackerDB then return end

    local factions = WOWFTrackerDB.factions
    local yOffset  = 0
    local rowIndex = 0

    local i = 1
    while i <= GetNumFactions() do
        local name, _, standingID, barMin, barMax, barValue,
              atWarWith, canToggleAtWar, isHeader, isCollapsed,
              hasRep, isWatched, isChild, factionID = GetFactionInfo(i)

        if name then
            rowIndex = rowIndex + 1
            local row = factionRows[rowIndex]
            if not row then
                row = CreateFrame("Frame", nil, scrollChild)
                row:SetSize(260, 20)
                factionRows[rowIndex] = row
            end
            row:SetPoint("TOPLEFT", 0, -yOffset)
            row:Show()

            -- Hide order widgets if they exist
            if row.upBtn then row.upBtn:Hide() end
            if row.downBtn then row.downBtn:Hide() end
            if row.orderLabel then row.orderLabel:Hide() end

            if isHeader then
                if not row.headerText then
                    row.headerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    row.headerText:SetPoint("LEFT", 4, 0)
                end
                row.headerText:SetText("|cffffcc00" .. name .. "|r")
                row.headerText:Show()
                if row.cb then row.cb:Hide() end
                if isCollapsed then ExpandFactionHeader(i) end
                yOffset = yOffset + 22
            else
                if row.headerText then row.headerText:Hide() end
                if not row.cb then
                    row.cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                    row.cb:SetSize(22, 22)
                end
                row.cb:SetPoint("LEFT", isChild and 20 or 8, 0)
                row.cb:Show()

                local c = WOWFTracker_StandingColors[standingID] or { r = 0.5, g = 0.5, b = 0.5 }
                local standingName = WOWFTracker_StandingLabels[standingID] or ""

                if not row.cb.label then
                    row.cb.label = row.cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    row.cb.label:SetPoint("LEFT", row.cb, "RIGHT", 2, 0)
                end
                row.cb.label:SetText(name)

                if not row.cb.standingText then
                    row.cb.standingText = row.cb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    row.cb.standingText:SetPoint("LEFT", row.cb.label, "RIGHT", 6, 0)
                end
                row.cb.standingText:SetText(string.format("|cff%02x%02x%02x%s|r",
                    c.r * 255, c.g * 255, c.b * 255, standingName))

                row.cb:SetChecked(factions[factionID] and true or false)
                row.cb.factionID = factionID
                row.cb:SetScript("OnClick", function(self)
                    factions[self.factionID] = self:GetChecked() and true or false
                    WOWFTrackerNS.SyncCustomOrder()
                    WOWFTrackerNS.UpdateReputation()
                end)
                yOffset = yOffset + 20
            end
        end
        i = i + 1
    end
    scrollChild:SetHeight(math.max(yOffset, 1))
end

----------------------------------------------------------------------
-- Custom order list (Ordering tab)
----------------------------------------------------------------------
function RefreshCustomOrder()
    HideAllTabs()
    if not WOWFTrackerDB then return end

    WOWFTrackerNS.SyncCustomOrder()
    local order = WOWFTrackerDB.customOrder
    local yOffset = 0

    if #order == 0 then
        if not orderRows[1] then
            orderRows[1] = CreateFrame("Frame", nil, scrollChild)
            orderRows[1]:SetSize(260, 20)
        end
        orderRows[1]:SetPoint("TOPLEFT", 0, 0)
        orderRows[1]:Show()
        if not orderRows[1].emptyText then
            orderRows[1].emptyText = orderRows[1]:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            orderRows[1].emptyText:SetPoint("LEFT", 8, 0)
        end
        orderRows[1].emptyText:SetText("Nothing tracked to reorder.")
        orderRows[1].emptyText:Show()
        scrollChild:SetHeight(20)
        return
    end

    for i, entryID in ipairs(order) do
        local row = orderRows[i]
        if not row then
            row = CreateFrame("Frame", nil, scrollChild)
            row:SetSize(260, 22)
            orderRows[i] = row
        end
        row:SetPoint("TOPLEFT", 0, -yOffset)
        row:Show()

        -- Hide faction-picker widgets
        if row.headerText then row.headerText:Hide() end
        if row.cb then row.cb:Hide() end
        if row.emptyText then row.emptyText:Hide() end

        -- Order number
        if not row.orderLabel then
            row.orderLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.orderLabel:SetPoint("LEFT", 4, 0)
        end
        row.orderLabel:SetText("|cff888888" .. i .. ".|r")
        row.orderLabel:Show()

        -- Resolve name for factions (number) or skills (string "skill:Name")
        if not row.nameLabel then
            row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.nameLabel:SetPoint("LEFT", 24, 0)
            row.nameLabel:SetPoint("RIGHT", row, "RIGHT", -42, 0)
            row.nameLabel:SetJustifyH("LEFT")
            row.nameLabel:SetWordWrap(false)
        end
        -- Tracked entries this character doesn't have yet stay in the order
        -- (they get a bar once learned/discovered) but are flagged here
        local name
        if type(entryID) == "string" and entryID:match("^skill:") then
            local skillName = entryID:match("^skill:(.+)$")
            name = (skillName or entryID) .. "  |cffccaa44[Skill]|r"
            if skillName and not WOWFTrackerNS.HasSkill(skillName) then
                name = name .. " |cff888888(unlearned)|r"
            end
        else
            name = GetFactionInfoByID(entryID) or ("ID " .. tostring(entryID))
            if not WOWFTrackerNS.IsFactionKnown(entryID) then
                name = name .. " |cff888888(undiscovered)|r"
            end
        end
        row.nameLabel:SetText(name)
        row.nameLabel:Show()

        -- Up button
        if not row.upBtn then
            row.upBtn = CreateFrame("Button", nil, row)
            row.upBtn:SetSize(16, 16)
            row.upBtn:SetPoint("RIGHT", row, "RIGHT", -22, 0)
            row.upBtn:SetNormalTexture("Interface\\Buttons\\UI-MicroStream-Green")
            row.upBtn:GetNormalTexture():SetRotation(math.rad(180))
            row.upBtn.highlight = row.upBtn:CreateTexture(nil, "HIGHLIGHT")
            row.upBtn.highlight:SetAllPoints()
            row.upBtn.highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
            row.upBtn.highlight:SetVertexColor(1, 1, 1, 0.15)
        end
        row.upBtn:Show()
        row.upBtn.index = i
        row.upBtn:SetScript("OnClick", function(self)
            local idx = self.index
            if idx <= 1 then return end
            local ord = WOWFTrackerDB.customOrder
            ord[idx], ord[idx - 1] = ord[idx - 1], ord[idx]
            WOWFTrackerNS.UpdateReputation()
            RefreshCustomOrder()
        end)
        if i == 1 then row.upBtn:SetAlpha(0.3) else row.upBtn:SetAlpha(1) end

        -- Down button
        if not row.downBtn then
            row.downBtn = CreateFrame("Button", nil, row)
            row.downBtn:SetSize(16, 16)
            row.downBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.downBtn:SetNormalTexture("Interface\\Buttons\\UI-MicroStream-Green")
            row.downBtn.highlight = row.downBtn:CreateTexture(nil, "HIGHLIGHT")
            row.downBtn.highlight:SetAllPoints()
            row.downBtn.highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
            row.downBtn.highlight:SetVertexColor(1, 1, 1, 0.15)
        end
        row.downBtn:Show()
        row.downBtn.index = i
        row.downBtn:SetScript("OnClick", function(self)
            local idx = self.index
            local ord = WOWFTrackerDB.customOrder
            if idx >= #ord then return end
            ord[idx], ord[idx + 1] = ord[idx + 1], ord[idx]
            WOWFTrackerNS.UpdateReputation()
            RefreshCustomOrder()
        end)
        if i == #order then row.downBtn:SetAlpha(0.3) else row.downBtn:SetAlpha(1) end

        yOffset = yOffset + 22
    end

    -- Hide extras
    for j = #order + 1, #orderRows do orderRows[j]:Hide() end

    scrollChild:SetHeight(math.max(yOffset, 1))
end

----------------------------------------------------------------------
-- Skill list (Skills tab)
----------------------------------------------------------------------
local function BuildSkillList()
    HideAllTabs()
    if not WOWFTrackerDB or not WOWFTrackerNS.GetAllSkills then return end

    local skills = WOWFTrackerDB.skills or {}
    local allSkills = WOWFTrackerNS.GetAllSkills()
    local yOffset = 0
    local rowIndex = 0
    local lastHeader = ""
    local skillColors = WOWFTracker_SkillColors

    for _, info in ipairs(allSkills) do
        -- Show category header when it changes
        if info.header ~= lastHeader then
            lastHeader = info.header
            rowIndex = rowIndex + 1
            local row = skillRows[rowIndex]
            if not row then
                row = CreateFrame("Frame", nil, scrollChild)
                row:SetSize(260, 20)
                skillRows[rowIndex] = row
            end
            row:SetPoint("TOPLEFT", 0, -yOffset)
            row:Show()

            if not row.headerText then
                row.headerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.headerText:SetPoint("LEFT", 4, 0)
            end
            row.headerText:SetText("|cffffcc00" .. info.header .. "|r")
            row.headerText:Show()
            if row.cb then row.cb:Hide() end
            if row.orderLabel then row.orderLabel:Hide() end
            if row.nameLabel then row.nameLabel:Hide() end
            if row.upBtn then row.upBtn:Hide() end
            if row.downBtn then row.downBtn:Hide() end
            yOffset = yOffset + 22
        end

        -- Skill checkbox row
        rowIndex = rowIndex + 1
        local row = skillRows[rowIndex]
        if not row then
            row = CreateFrame("Frame", nil, scrollChild)
            row:SetSize(260, 20)
            skillRows[rowIndex] = row
        end
        row:SetPoint("TOPLEFT", 0, -yOffset)
        row:Show()

        if row.headerText then row.headerText:Hide() end
        if row.orderLabel then row.orderLabel:Hide() end
        if row.nameLabel then row.nameLabel:Hide() end
        if row.upBtn then row.upBtn:Hide() end
        if row.downBtn then row.downBtn:Hide() end

        if not row.cb then
            row.cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.cb:SetSize(22, 22)
        end
        row.cb:SetPoint("LEFT", 16, 0)
        row.cb:Show()

        -- Skill name label
        if not row.cb.label then
            row.cb.label = row.cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.cb.label:SetPoint("LEFT", row.cb, "RIGHT", 2, 0)
        end
        row.cb.label:SetText(info.name)

        -- Rank/category text
        if not row.cb.standingText then
            row.cb.standingText = row.cb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.cb.standingText:SetPoint("LEFT", row.cb.label, "RIGHT", 6, 0)
        end
        local cat = info.category or "weapon"
        local c = skillColors[cat] or skillColors.default
        row.cb.standingText:SetText(string.format("|cff%02x%02x%02x%d/%d|r",
            c.r * 255, c.g * 255, c.b * 255, info.rank, info.maxRank))

        -- Check state
        local skillKey = "skill:" .. info.name
        row.cb:SetChecked(skills[skillKey] and true or false)

        row.cb.skillKey = skillKey
        row.cb:SetScript("OnClick", function(self)
            if not WOWFTrackerDB.skills then WOWFTrackerDB.skills = {} end
            WOWFTrackerDB.skills[self.skillKey] = self:GetChecked() and true or false
            WOWFTrackerNS.SyncCustomOrder()
            WOWFTrackerNS.UpdateReputation()
        end)

        yOffset = yOffset + 20
    end

    -- Hide extras
    for j = rowIndex + 1, #skillRows do skillRows[j]:Hide() end

    scrollChild:SetHeight(math.max(yOffset, 1))
end

----------------------------------------------------------------------
-- Tab switching
----------------------------------------------------------------------
local function SetTab(tab)
    currentTab = tab
    HideAllTabs()

    -- Reset all tab button states
    tabFactions:SetButtonState("NORMAL", false)
    tabSkills:SetButtonState("NORMAL", false)
    tabOrder:SetButtonState("NORMAL", false)

    if tab == "factions" then
        tabFactions:SetButtonState("PUSHED", true)
        selAllBtn:Show()
        selNoneBtn:Show()
        BuildFactionList()
    elseif tab == "skills" then
        tabSkills:SetButtonState("PUSHED", true)
        selAllBtn:Hide()
        selNoneBtn:Hide()
        BuildSkillList()
    else
        tabOrder:SetButtonState("PUSHED", true)
        selAllBtn:Hide()
        selNoneBtn:Hide()
        RefreshCustomOrder()
    end
end

tabFactions:SetScript("OnClick", function() SetTab("factions") end)
tabSkills:SetScript("OnClick", function() SetTab("skills") end)
tabOrder:SetScript("OnClick", function() SetTab("order") end)

----------------------------------------------------------------------
-- Select All / None
----------------------------------------------------------------------
selAllBtn:SetScript("OnClick", function()
    if not WOWFTrackerDB then return end
    local i = 1
    while i <= GetNumFactions() do
        local name, _, _, _, _, _, _, _, isHeader, isCollapsed, _, _, _, factionID = GetFactionInfo(i)
        if name and not isHeader and factionID then
            WOWFTrackerDB.factions[factionID] = true
        end
        if isHeader and isCollapsed then ExpandFactionHeader(i) end
        i = i + 1
    end
    WOWFTrackerNS.SyncCustomOrder()
    BuildFactionList()
    WOWFTrackerNS.UpdateReputation()
end)

selNoneBtn:SetScript("OnClick", function()
    if not WOWFTrackerDB then return end
    WOWFTrackerDB.factions = {}
    WOWFTrackerDB.customOrder = {}
    BuildFactionList()
    WOWFTrackerNS.UpdateReputation()
end)

----------------------------------------------------------------------
-- Refresh all controls when panel opens
----------------------------------------------------------------------
local function RefreshPanel()
    if not WOWFTrackerDB or not WOWFTrackerDB.settings then return end
    local s = WOWFTrackerDB.settings

    widthSlider:SetValue(s.barWidth)
    heightSlider:SetValue(s.barHeight)
    spacingSlider:SetValue(s.rowSpacing)
    fontSlider:SetValue(s.fontSize)
    alphaSlider:SetValue((s.bgAlpha or 0.8) * 100)
    frameAlphaSlider:SetValue((s.frameAlpha or 1.0) * 100)
    lockCB:SetChecked(s.locked)
    headerCB:SetChecked(s.showHeader)
    showWindowCB:SetChecked(s.windowVisible ~= false)
    autoHideCB:SetChecked(s.autoHide)
    exaltedCB:SetChecked(s.showTotalToExalted)
    fadeSlider:SetValue((s.fadeTime or 0.3) * 100)
    showTimeSlider:SetValue(s.showTime or 5)
    ShowAutoHideSliders(s.autoHide)

    for _, b in ipairs(texButtons) do
        if b.texturePath == s.barTexture then b.selected:Show() else b.selected:Hide() end
    end

    for _, b in ipairs(sortButtons) do
        if b.sortKey == s.sortMode then b.selected:Show() else b.selected:Hide() end
    end

    SetTab("factions")
end

----------------------------------------------------------------------
-- Toggle
----------------------------------------------------------------------
-- Fill and show, never hide. The Chaircraft menu uses this to host the panel.
function WOWFTrackerNS.ShowOptions()
    RefreshPanel()
    opt:Show()
end

function WOWFTrackerNS.ToggleOptions()
    if opt:IsShown() then
        opt:Hide()
        return
    end
    -- Opens inside the Chaircraft menu when it can, on its own when it cannot.
    local plus = _G.ChairPlusNS
    if plus and plus.OpenPartPage and plus.OpenPartPage("tracker") then return end
    RefreshPanel()
    opt:Show()
end

----------------------------------------------------------------------
-- Refresh on rep/skill change while open
----------------------------------------------------------------------
opt:RegisterEvent("UPDATE_FACTION")
opt:RegisterEvent("SKILL_LINES_CHANGED")
-- A weapon skill rebuilt from the character sheet changes with the gear, so
-- the picker has to hear about that too.
opt:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
opt:SetScript("OnEvent", function(self, event)
    if event == "SKILL_LINES_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        WOWFTrackerNS.InvalidateSkillRows()
    end
    if self:IsShown() then
        if currentTab == "factions" then
            BuildFactionList()
        elseif currentTab == "skills" then
            BuildSkillList()
        else
            RefreshCustomOrder()
        end
    end
end)

