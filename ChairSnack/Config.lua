-- SnapSnack Config.lua
-- The configuration window: navigation rail plus four panels (user grid, auto
-- bar, general, profiles).
--
-- Panels are built once and rebound when the selection changes, rather than
-- torn down and recreated. Item rows come from a pool and live inside a
-- ScrollFrame so a long list stays inside the window.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

local GetItemInfo  = addon.GetItemInfo
local GetItemCount = addon.GetItemCount

local configFrame = nil
local navButtons = {}
local currentGridID = nil

local ROW_HEIGHT = 32
local LIST_ROW_HEIGHT = 18

-- Fixed rather than measured from the scroll frame: GetWidth() is unreliable
-- before the first layout pass, and the content area is a known size.
local ROW_WIDTH = 410

-- Every option dropdown, so their popup lists can be closed together.
local optionDropdowns = {}

-- Nav entries that are panels rather than bars.
local NON_GRID_PANELS = {
    general = true,
    profiles = true,
    petfood = true,
}

local function CurrentGrid()
    if not currentGridID then return nil end
    if NON_GRID_PANELS[currentGridID] then return nil end
    return addon:GetGrid(currentGridID)
end

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
}

-------------------------------
-- Shared Search Popup
-------------------------------
-- One popup parented to UIParent, borrowed by whichever dropdown is open. A
-- popup parented to its row would be clipped by the item ScrollFrame, since a
-- scroll viewport clips its descendants whatever their frame strata.

local searchPopup = nil

local function GetSearchPopup()
    if searchPopup then return searchPopup end

    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(220, 200)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    frame:Hide()

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", -25, 5)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local value = self:GetVerticalScroll() - delta * LIST_ROW_HEIGHT * 2
        local maxScroll = self:GetVerticalScrollRange()
        if value < 0 then value = 0 elseif value > maxScroll then value = maxScroll end
        self:SetVerticalScroll(value)
    end)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(190, 1)
    scroll:SetScrollChild(child)

    frame.scroll = scroll
    frame.child = child
    frame.buttons = {}

    -- Grow the button pool on demand; the old fixed 15 silently dropped every
    -- match past the fifteenth.
    function frame:GetButton(index)
        local button = self.buttons[index]
        if button then return button end

        button = CreateFrame("Button", nil, self.child)
        button:SetSize(185, LIST_ROW_HEIGHT)
        button:SetPoint("TOPLEFT", 0, -(index - 1) * LIST_ROW_HEIGHT)

        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("LEFT", 5, 0)
        button.text:SetPoint("RIGHT", -5, 0)
        button.text:SetJustifyH("LEFT")

        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints()
        button.highlight:SetColorTexture(1, 1, 1, 0.2)

        button:SetScript("OnClick", function(self)
            if searchPopup.onSelect and self.itemID then
                searchPopup.onSelect(self.itemID, self.itemName)
            end
            searchPopup:Hide()
        end)

        self.buttons[index] = button
        return button
    end

    function frame:Populate(filter)
        filter = filter and filter:lower() or ""
        local items = (self.getItems and self.getItems()) or addon:GetSortedConsumableList()

        local shown = 0
        for _, item in ipairs(items) do
            if filter == "" or item.name:lower():find(filter, 1, true) then
                shown = shown + 1
                local button = self:GetButton(shown)
                button.itemID = item.id
                button.itemName = item.name
                button.text:SetText(item.name)

                -- Rows can be colour-coded by the list that supplied them.
                if self.getColor then
                    local r, g, b = self.getColor(item.id)
                    button.text:SetTextColor(r or 1, g or 1, b or 1)
                else
                    button.text:SetTextColor(1, 1, 1)
                end

                button:Show()
            end
        end

        for i = shown + 1, #self.buttons do
            self.buttons[i]:Hide()
        end

        self.child:SetHeight(math.max(shown * LIST_ROW_HEIGHT, 1))
        self.scroll:SetVerticalScroll(0)
        return shown
    end

    function frame:Open(owner, filter, onSelect, getItems, getColor)
        self.owner = owner
        self.onSelect = onSelect
        self.getItems = getItems
        self.getColor = getColor
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
        self:Populate(filter)
        self:Show()
    end

    searchPopup = frame
    return frame
end

local function CloseSearchPopup(owner)
    if searchPopup and searchPopup:IsShown() then
        if not owner or searchPopup.owner == owner then
            searchPopup:Hide()
        end
    end
end

-------------------------------
-- Searchable Item Dropdown
-------------------------------
-- The row it belongs to supplies the target index at click time, so a pooled
-- row can be rebound to a different slot without rebuilding the dropdown.

local function CreateSearchableDropdown(parent, onSelect, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(220, 24)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local editBox = CreateFrame("EditBox", nil, frame)
    editBox:SetPoint("TOPLEFT", 5, -4)
    editBox:SetPoint("BOTTOMRIGHT", -24, 4)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(100)

    local dropButton = CreateFrame("Button", nil, frame)
    dropButton:SetSize(20, 20)
    dropButton:SetPoint("RIGHT", -2, 0)
    dropButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    dropButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    dropButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    local function Select(itemID, itemName)
        editBox:SetText(itemName or "")
        frame.selectedID = itemID
        editBox:ClearFocus()
        if onSelect then onSelect(frame, itemID) end
    end

    local function Open()
        GetSearchPopup():Open(frame, editBox:GetText(), Select,
                              opts.getItems, opts.getColor)
    end

    editBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then Open() end
    end)
    editBox:SetScript("OnEditFocusGained", Open)
    editBox:SetScript("OnEditFocusLost", function()
        -- Delay so a click on a popup row still registers.
        C_Timer.After(0.15, function() CloseSearchPopup(frame) end)
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        CloseSearchPopup(frame)
    end)
    editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        CloseSearchPopup(frame)
    end)

    dropButton:SetScript("OnClick", function()
        if searchPopup and searchPopup:IsShown() and searchPopup.owner == frame then
            searchPopup:Hide()
        else
            Open()
            editBox:SetFocus()
        end
    end)

    function frame:SetValue(itemID)
        self.selectedID = itemID
        if not itemID then
            editBox:SetText("")
            return
        end
        local name = GetItemInfo(itemID)
        if name then
            editBox:SetText(name)
        else
            editBox:SetText("Loading...")
            local item = Item:CreateFromItemID(itemID)
            item:ContinueOnItemLoad(function()
                local loaded = GetItemInfo(itemID)
                if loaded and self.selectedID == itemID then
                    editBox:SetText(loaded)
                end
            end)
        end
    end

    function frame:GetValue()
        return self.selectedID
    end

    return frame
end

-------------------------------
-- Basic Widgets
-------------------------------

local function CreateSlider(parent, min, max, step, getValue, setValue, label, noGridUpdate)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(180, 50)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(label)

    local numSteps = math.floor((max - min) / step)

    local slider = CreateFrame("Slider", nil, frame, "MinimalSliderWithSteppersTemplate")
    slider:SetPoint("TOPLEFT", 0, -16)
    slider:SetHeight(26)
    slider:SetWidth(160)

    local right = MinimalSliderWithSteppersMixin.Label.Right
    local formatters = {}
    formatters[right] = CreateMinimalSliderFormatter(right, function(value)
        return tostring(math.floor(value + 0.5))
    end)

    slider:Init(getValue() or min, min, max, numSteps, formatters)

    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if frame.suppress then return end
        value = math.floor(value / step + 0.5) * step
        setValue(value)
        if not noGridUpdate then
            addon:RequestUpdate()
        end
    end)

    frame.slider = slider
    function frame:Refresh()
        self.suppress = true
        slider:Init(getValue() or min, min, max, numSteps, formatters)
        self.suppress = false
    end

    return frame
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
addon.ConfigTip = Tip

local function CreateCheckbox(parent, label, getValue, setValue, noGridUpdate)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check.text:SetText(label)
    check.text:SetFontObject(GameFontNormal)

    check:SetScript("OnClick", function(self)
        setValue(self:GetChecked())
        if not noGridUpdate then
            addon:RequestUpdate()
        end
    end)

    function check:Refresh()
        self:SetChecked(getValue())
    end

    return check
end

-- Generic option dropdown. The option set can be replaced after creation, so
-- the profiles list can be rebuilt without leaking a frame each refresh.
local function CreateOptionDropdown(parent, width, options, labels, getValue, setValue)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width, 24)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 5, 0)
    text:SetPoint("RIGHT", -22, 0)
    text:SetJustifyH("LEFT")
    frame.text = text

    local dropButton = CreateFrame("Button", nil, frame)
    dropButton:SetSize(20, 20)
    dropButton:SetPoint("RIGHT", -2, 0)
    dropButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    dropButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
    dropButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    -- Parented to UIParent so it is never clipped by a scroll viewport.
    local listFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    listFrame:SetFrameStrata("TOOLTIP")
    listFrame:SetBackdrop(BACKDROP)
    listFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
    listFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    listFrame:Hide()

    frame.listFrame = listFrame
    frame.listButtons = {}
    frame.options = options
    frame.labels = labels

    function frame:SetOptions(newOptions, newLabels)
        self.options = newOptions
        self.labels = newLabels or {}

        for i, option in ipairs(newOptions) do
            local btn = self.listButtons[i]
            if not btn then
                btn = CreateFrame("Button", nil, listFrame)
                btn:SetSize(width - 10, LIST_ROW_HEIGHT)
                btn:SetPoint("TOPLEFT", 5, -(i - 1) * LIST_ROW_HEIGHT - 4)

                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                btn.text:SetPoint("LEFT", 5, 0)
                btn.text:SetPoint("RIGHT", -5, 0)
                btn.text:SetJustifyH("LEFT")

                btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
                btn.highlight:SetAllPoints()
                btn.highlight:SetColorTexture(1, 1, 1, 0.2)

                btn:SetScript("OnClick", function(self)
                    setValue(self.option)
                    text:SetText(self.text:GetText())
                    listFrame:Hide()
                end)

                self.listButtons[i] = btn
            end
            btn.option = option
            btn.text:SetText(self.labels[option] or option)
            btn:Show()
        end

        for i = #newOptions + 1, #self.listButtons do
            self.listButtons[i]:Hide()
        end

        listFrame:SetSize(width, math.max(#newOptions, 1) * LIST_ROW_HEIGHT + 8)
    end

    dropButton:SetScript("OnClick", function()
        if listFrame:IsShown() then
            listFrame:Hide()
        else
            listFrame:ClearAllPoints()
            listFrame:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
            listFrame:Show()
        end
    end)

    function frame:Refresh()
        local value = getValue()
        text:SetText(self.labels[value] or value or "")
    end

    frame:SetOptions(options, labels)
    table.insert(optionDropdowns, frame)
    return frame
end

local function CloseAllDropdowns()
    for _, dropdown in ipairs(optionDropdowns) do
        dropdown.listFrame:Hide()
    end
end

-------------------------------
-- Item List Section
-------------------------------
-- A pooled list of item rows bound to whatever table its owner hands it, so the
-- same rows serve both a user grid item list and the hunter pet food list.
--
-- scrollable = true when the section owns the space it sits in. The auto panel
-- scrolls as a whole, so its pet food list uses scrollable = false and just
-- reports the height it needs.

local function CreateItemRow(parent, section)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(ROW_WIDTH, 28)

    local function List() return section:GetList() end

    local function Changed()
        addon:RequestUpdate()
        section:Refresh()
        if section.onChanged then section.onChanged() end
    end

    local moveUpBtn = CreateFrame("Button", nil, row)
    moveUpBtn:SetSize(16, 16)
    moveUpBtn:SetPoint("LEFT", 0, 0)
    moveUpBtn:SetNormalTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Up")
    moveUpBtn:SetHighlightTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Highlight")
    moveUpBtn:SetPushedTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Down")
    moveUpBtn:SetDisabledTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Disabled")
    moveUpBtn:SetScript("OnClick", function()
        local list, index = List(), row.itemIndex
        if not list or index <= 1 or not list[index] then return end
        list[index], list[index - 1] = list[index - 1], list[index]
        Changed()
    end)
    row.moveUpBtn = moveUpBtn

    local moveDownBtn = CreateFrame("Button", nil, row)
    moveDownBtn:SetSize(16, 16)
    moveDownBtn:SetPoint("LEFT", moveUpBtn, "RIGHT", 2, 0)
    moveDownBtn:SetNormalTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Up")
    moveDownBtn:SetHighlightTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Highlight")
    moveDownBtn:SetPushedTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Down")
    moveDownBtn:SetDisabledTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Disabled")
    moveDownBtn:SetScript("OnClick", function()
        local list, index = List(), row.itemIndex
        if not list or not list[index] or not list[index + 1] then return end
        list[index], list[index + 1] = list[index + 1], list[index]
        Changed()
    end)
    row.moveDownBtn = moveDownBtn

    local dropdown = CreateSearchableDropdown(row, function(_, itemID)
        local list, index = List(), row.itemIndex
        if not list or not itemID then return end
        list[index] = {
            itemID = itemID,
            hideOnZero = addon.IsConjuredItem(itemID),
            showInCombat = false,
        }
        Changed()
    end, section.dropdownOpts)
    dropdown:SetPoint("LEFT", moveDownBtn, "RIGHT", 5, 0)
    row.dropdown = dropdown

    local deleteBtn = CreateFrame("Button", nil, row)
    deleteBtn:SetSize(20, 20)
    deleteBtn:SetPoint("LEFT", dropdown, "RIGHT", 5, 0)
    deleteBtn:SetNormalTexture("Interface\\BUTTONS\\UI-GroupLoot-Pass-Up")
    deleteBtn:SetHighlightTexture("Interface\\BUTTONS\\UI-GroupLoot-Pass-Highlight")
    deleteBtn:SetPushedTexture("Interface\\BUTTONS\\UI-GroupLoot-Pass-Down")
    deleteBtn:SetScript("OnClick", function()
        local list, index = List(), row.itemIndex
        if not list then return end
        table.remove(list, index)
        Changed()
    end)
    deleteBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(section.removeText or "Remove")
        GameTooltip:Show()
    end)
    deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.deleteBtn = deleteBtn

    local hideZeroCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    hideZeroCheck:SetSize(20, 20)
    hideZeroCheck:SetPoint("LEFT", deleteBtn, "RIGHT", 5, 0)
    hideZeroCheck.text:SetText("Hide 0")
    hideZeroCheck.text:SetFontObject(GameFontNormalSmall)
    hideZeroCheck:SetScript("OnClick", function(self)
        local list, index = List(), row.itemIndex
        if not list or not list[index] then return end
        local itemData = list[index]
        if type(itemData) == "table" then
            itemData.hideOnZero = self:GetChecked()
        else
            list[index] = { itemID = itemData, hideOnZero = self:GetChecked(), showInCombat = false }
        end
        addon:RequestUpdate()
    end)
    hideZeroCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Hide when count is 0")
        GameTooltip:Show()
    end)
    hideZeroCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.hideZeroCheck = hideZeroCheck

    local combatCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    combatCheck:SetSize(20, 20)
    combatCheck:SetPoint("LEFT", hideZeroCheck, "RIGHT", 50, 0)
    combatCheck.text:SetText("Combat")
    combatCheck.text:SetFontObject(GameFontNormalSmall)
    combatCheck:SetScript("OnClick", function(self)
        local list, index = List(), row.itemIndex
        if not list or not list[index] then return end
        local itemData = list[index]
        if type(itemData) == "table" then
            itemData.showInCombat = self:GetChecked()
        else
            list[index] = { itemID = itemData, hideOnZero = false, showInCombat = self:GetChecked() }
        end
        addon:RequestUpdate()
    end)
    combatCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Show this item in combat\n(even if the grid is hidden)")
        GameTooltip:Show()
    end)
    combatCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.combatCheck = combatCheck

    return row
end

local function CreateItemListSection(parent, opts)
    local section = CreateFrame("Frame", nil, parent)
    section.rowPool = {}
    section.getList = opts.getList
    section.showPerItemOptions = opts.showPerItemOptions ~= false
    section.removeText = opts.removeText
    section.onChanged = opts.onChanged
    section.dropdownOpts = opts.dropdownOpts

    function section:GetList()
        return self.getList and self.getList() or nil
    end

    local host
    if opts.scrollable then
        local scroll = CreateFrame("ScrollFrame", nil, section, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", -22, 0)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local value = self:GetVerticalScroll() - delta * ROW_HEIGHT
            local maxScroll = self:GetVerticalScrollRange()
            if value < 0 then value = 0 elseif value > maxScroll then value = maxScroll end
            self:SetVerticalScroll(value)
        end)
        scroll:SetScript("OnVerticalScroll", function()
            CloseSearchPopup()
            CloseAllDropdowns()
        end)

        local child = CreateFrame("Frame", nil, scroll)
        child:SetSize(ROW_WIDTH, 1)
        scroll:SetScrollChild(child)

        section.scroll = scroll
        host = child
    else
        host = section
    end
    section.host = host

    function section:AcquireRow(index)
        local row = self.rowPool[index]
        if not row then
            row = CreateItemRow(self.host, self)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
            self.rowPool[index] = row
        end
        row.itemIndex = index
        row:Show()
        return row
    end

    -- Renders the list plus one spare "add item" row, and returns the height
    -- the rows occupy.
    function section:Refresh()
        local list = self:GetList()
        if not list then return 0 end

        local count = #list
        for i = 1, count + 1 do
            local row = self:AcquireRow(i)

            if i <= count then
                row.dropdown:SetValue(addon.GetItemIDFromData(list[i]))
                row.deleteBtn:Show()
                row.moveUpBtn:Show()
                row.moveDownBtn:Show()
                if i == 1 then row.moveUpBtn:Disable() else row.moveUpBtn:Enable() end
                if i >= count then row.moveDownBtn:Disable() else row.moveDownBtn:Enable() end

                if self.showPerItemOptions then
                    row.hideZeroCheck:SetChecked(addon.GetHideOnZeroFromData(list[i]))
                    row.combatCheck:SetChecked(addon.GetShowInCombatFromData(list[i]))
                    row.hideZeroCheck:Show()
                    row.combatCheck:Show()
                else
                    row.hideZeroCheck:Hide()
                    row.combatCheck:Hide()
                end
            else
                row.dropdown:SetValue(nil)
                row.deleteBtn:Hide()
                row.moveUpBtn:Hide()
                row.moveDownBtn:Hide()
                row.hideZeroCheck:Hide()
                row.combatCheck:Hide()
            end
        end

        for i = count + 2, #self.rowPool do
            self.rowPool[i]:Hide()
        end

        local height = math.max((count + 1) * ROW_HEIGHT, ROW_HEIGHT)
        if self.scroll then
            self.host:SetSize(ROW_WIDTH, height)
        else
            self:SetSize(ROW_WIDTH, height)
        end
        return height
    end

    return section
end

-------------------------------
-- Shared Appearance Controls
-------------------------------
-- Identical on every panel that owns a bar, so it is built once and pointed at
-- whichever grid the panel is showing.

local APPEARANCE_HEIGHT = 250

-- lowRange: { max, step } for the low-supply warning. Most bars count single
-- items; ammo counts in hundreds, and a 0-20 slider could not even hold its
-- own default of 200.
local function CreateAppearanceControls(parent, getGrid, lowRange)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(ROW_WIDTH + 20, APPEARANCE_HEIGHT)

    local function Grid() return getGrid() end

    frame.enableCheck = CreateCheckbox(frame, "Enable Bar",
        function() local g = Grid() return g and g.enabled end,
        function(v) local g = Grid() if g then g.enabled = v end end)
    frame.enableCheck:SetPoint("TOPLEFT", 0, 0)

    frame.combatCheck = CreateCheckbox(frame, "Show in Combat",
        function() local g = Grid() return g and g.showInCombat end,
        function(v) local g = Grid() if g then g.showInCombat = v end end)
    frame.combatCheck:SetPoint("TOPLEFT", 150, 0)

    frame.tooltipCheck = CreateCheckbox(frame, "Show Tooltips",
        function() local g = Grid() return g and g.showTooltips ~= false end,
        function(v) local g = Grid() if g then g.showTooltips = v end end)
    frame.tooltipCheck:SetPoint("TOPLEFT", 280, 0)

    frame.deadCheck = CreateCheckbox(frame, "Hide When Dead",
        function() local g = Grid() return g and g.hideWhenDead end,
        function(v) local g = Grid() if g then g.hideWhenDead = v end end)
    frame.deadCheck:SetPoint("TOPLEFT", 0, -25)

    frame.instanceCheck = CreateCheckbox(frame, "Only In Instances",
        function() local g = Grid() return g and g.onlyInInstance end,
        function(v) local g = Grid() if g then g.onlyInInstance = v end end)
    frame.instanceCheck:SetPoint("TOPLEFT", 150, -25)

    frame.groupCheck = CreateCheckbox(frame, "Only In A Group",
        function() local g = Grid() return g and g.onlyInGroup end,
        function(v) local g = Grid() if g then g.onlyInGroup = v end end)
    frame.groupCheck:SetPoint("TOPLEFT", 280, -25)

    frame.warnCheck = CreateCheckbox(frame, "Warn On Entering",
        function() local g = Grid() return g and g.warnOnInstanceEntry end,
        function(v) local g = Grid() if g then g.warnOnInstanceEntry = v end end)
    frame.warnCheck:SetPoint("TOPLEFT", 0, -50)

    Tip(frame.enableCheck, "Enable Bar", "Show this bar.")
    Tip(frame.combatCheck, "Show in Combat",
        "Keep the bar on screen during combat. Its buttons cannot change in combat, so it "
        .. "shows what it had when the fight began; counts and cooldowns still update.")
    Tip(frame.tooltipCheck, "Show Tooltips", "The item's tooltip when you hover a button.")
    Tip(frame.deadCheck, "Hide When Dead", "Hide the bar while you are dead or a ghost.")
    Tip(frame.instanceCheck, "Only In Instances", "Only inside dungeons, raids and battlegrounds.")
    Tip(frame.groupCheck, "Only In A Group", "Only while you are in a party or raid.")
    Tip(frame.warnCheck, "Warn On Entering",
        "When you enter a dungeon or raid, say in chat what on this bar is at or below its "
        .. "low-supply count, and how many more are in your bank.")

    frame.colSlider = CreateSlider(frame, 1, 12, 1,
        function() local g = Grid() return g and g.columns end,
        function(v) local g = Grid() if g then g.columns = v end end, "Columns")
    frame.colSlider:SetPoint("TOPLEFT", 0, -80)

    frame.sizeSlider = CreateSlider(frame, 16, 64, 2,
        function() local g = Grid() return g and g.iconSize end,
        function(v) local g = Grid() if g then g.iconSize = v end end, "Icon Size")
    frame.sizeSlider:SetPoint("TOPLEFT", 200, -80)

    frame.padSlider = CreateSlider(frame, 0, 30, 1,
        function() local g = Grid() return g and g.padding end,
        function(v) local g = Grid() if g then g.padding = v end end, "Padding")
    frame.padSlider:SetPoint("TOPLEFT", 0, -130)

    frame.lowSlider = CreateSlider(frame, 0, lowRange and lowRange[1] or 20, lowRange and lowRange[2] or 1,
        function() local g = Grid() return g and g.lowSupply end,
        function(v) local g = Grid() if g then g.lowSupply = v end end,
        "Low Supply Warning")
    frame.lowSlider:SetPoint("TOPLEFT", 200, -130)
    Tip(frame.lowSlider, "Low Supply Warning",
        "A count at or below this turns amber on the button. 0 turns the warning off.")

    local moveHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    moveHint:SetPoint("TOPLEFT", 0, -180)
    moveHint:SetWidth(140)
    moveHint:SetJustifyH("LEFT")
    moveHint:SetText("|cffFFD100Right-drag any bar to move it|r while this " ..
                     "window is open. Closing it locks them again.")

    local colGrowthLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colGrowthLabel:SetPoint("TOPLEFT", 150, -180)
    colGrowthLabel:SetText("Column Growth")

    frame.colGrowth = CreateOptionDropdown(frame, 90,
        { "LEFT", "CENTER", "RIGHT" }, { LEFT = "Left", CENTER = "Center", RIGHT = "Right" },
        function() local g = Grid() return g and g.columnGrowth or "RIGHT" end,
        function(v) local g = Grid() if g then g.columnGrowth = v addon:RequestUpdate() end end)
    frame.colGrowth:SetPoint("TOPLEFT", 150, -198)

    local rowGrowthLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rowGrowthLabel:SetPoint("TOPLEFT", 260, -180)
    rowGrowthLabel:SetText("Row Growth")

    frame.rowGrowth = CreateOptionDropdown(frame, 90,
        { "UP", "CENTER", "DOWN" }, { UP = "Up", CENTER = "Center", DOWN = "Down" },
        function() local g = Grid() return g and g.rowGrowth or "DOWN" end,
        function(v) local g = Grid() if g then g.rowGrowth = v addon:RequestUpdate() end end)
    frame.rowGrowth:SetPoint("TOPLEFT", 260, -198)

    function frame:SetEnableLabel(text)
        self.enableCheck.text:SetText(text)
    end

    function frame:Refresh()
        self.enableCheck:Refresh()
        self.combatCheck:Refresh()
        self.tooltipCheck:Refresh()
        self.deadCheck:Refresh()
        self.instanceCheck:Refresh()
        self.groupCheck:Refresh()
        self.warnCheck:Refresh()
        self.lowSlider:Refresh()
        self.colSlider:Refresh()
        self.sizeSlider:Refresh()
        self.padSlider:Refresh()
        self.colGrowth:Refresh()
        self.rowGrowth:Refresh()
    end

    return frame
end

-- A panel whose whole contents scroll. The automatic bars carry more controls
-- than fit in the content area once slot toggles and a readout are added.
local function CreateScrollingPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -22, 0)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local value = self:GetVerticalScroll() - delta * ROW_HEIGHT
        local maxScroll = self:GetVerticalScrollRange()
        if value < 0 then value = 0 elseif value > maxScroll then value = maxScroll end
        self:SetVerticalScroll(value)
    end)
    scroll:SetScript("OnVerticalScroll", function()
        CloseSearchPopup()
        CloseAllDropdowns()
    end)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_WIDTH + 20, 500)
    scroll:SetScrollChild(content)

    panel.scroll = scroll
    panel.content = content
    return panel
end

-------------------------------
-- User Grid Panel
-------------------------------

local function BuildGridPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", 10, -10)
    nameLabel:SetText("Grid Name:")

    local nameBox = CreateFrame("EditBox", nil, panel, "BackdropTemplate")
    nameBox:SetPoint("TOPLEFT", 90, -7)
    nameBox:SetSize(180, 22)
    nameBox:SetFontObject(ChatFontNormal)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(50)
    nameBox:SetBackdrop(BACKDROP)
    nameBox:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    nameBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    nameBox:SetTextInsets(5, 5, 0, 0)
    nameBox:SetScript("OnEnterPressed", function(self)
        local db = CurrentGrid()
        if db then
            db.name = self:GetText()
            addon:RefreshNavigation()
        end
        self:ClearFocus()
    end)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.nameBox = nameBox

    local keybindBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    keybindBtn:SetSize(130, 24)
    keybindBtn:SetPoint("TOPLEFT", 285, -8)
    keybindBtn:SetText("Keybind Mode")
    keybindBtn:SetScript("OnClick", function() addon:StartBindingMode() end)

    panel.appearance = CreateAppearanceControls(panel,
        function() return CurrentGrid() end)
    panel.appearance:SetPoint("TOPLEFT", 10, -40)
    panel.appearance:SetEnableLabel("Enable Grid")

    local itemsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    itemsTitle:SetPoint("TOPLEFT", 10, -297)
    itemsTitle:SetText("Consumable Items")

    local itemsSubtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemsSubtitle:SetPoint("TOPLEFT", 10, -314)
    itemsSubtitle:SetText("Type to search and add consumables from your bags")

    -- The overflow fix: item rows live in a scroll viewport bounded by the
    -- panel instead of marching off the bottom of the window.
    panel.list = CreateItemListSection(panel, {
        scrollable = true,
        removeText = "Remove from grid",
        getList = function()
            local db = CurrentGrid()
            return db and db.items
        end,
    })
    panel.list:SetPoint("TOPLEFT", 10, -333)
    panel.list:SetPoint("BOTTOMRIGHT", -6, 34)

    local deleteBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteBtn:SetSize(100, 22)
    deleteBtn:SetPoint("BOTTOMRIGHT", -10, 6)
    deleteBtn:SetText("Delete Grid")
    deleteBtn:SetScript("OnClick", function()
        local db = CurrentGrid()
        if not db then return end
        local gridID = currentGridID
        StaticPopupDialogs["SNAPSNACK_DELETE_GRID"] = {
            text = "Are you sure you want to delete '" .. (db.name or "") .. "'?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                addon:DeleteGrid(gridID)
                addon:RefreshNavigation()
                addon:SelectGrid(addon.AUTO_GRID_ID)
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("SNAPSNACK_DELETE_GRID")
    end)
    panel.deleteBtn = deleteBtn

    function panel:Refresh()
        local db = CurrentGrid()
        if not db then return end

        self.nameBox:SetText(db.name or "")
        self.appearance:Refresh()
        self.list:Refresh()

        -- Only offer deletion when another user grid would remain.
        local userGrids = 0
        for id in pairs(addon:GetGrids()) do
            if not addon.RESERVED_GRIDS[id] then userGrids = userGrids + 1 end
        end
        if userGrids > 1 then self.deleteBtn:Show() else self.deleteBtn:Hide() end
    end

    return panel
end

-------------------------------
-- Automatic Bar Panels
-------------------------------

-- Lay out slot toggles two to a row and return the height used.
local function BuildSlotToggles(parent, panel, slots, getGrid, onToggle)
    panel.slotChecks = {}
    for i, slot in ipairs(slots) do
        local key = slot.key
        local check = CreateCheckbox(parent, slot.label,
            function()
                local g = getGrid()
                return g and g.autoSlots[key] ~= false
            end,
            function(v)
                local g = getGrid()
                if not g then return end
                g.autoSlots[key] = v and true or false
                onToggle()
            end)
        check:SetPoint("TOPLEFT", 10 + ((i - 1) % 2) * 210,
                       -(math.floor((i - 1) / 2)) * 25)
        panel.slotChecks[key] = check
    end
    return math.ceil(#slots / 2) * 25
end

local FOOD_SLOT_LABELS = {
    { key = "food", label = "Food" },
    { key = "drink", label = "Water" },
    { key = "conjuredFood", label = "Conjured food" },
    { key = "conjuredDrink", label = "Conjured water" },
    { key = "feedPet", label = "Feed Pet (hunter)" },
}

local POTION_SLOT_LABELS = {
    { key = "health", label = "Health potion" },
    { key = "zoneHealth", label = "Zone health (e.g. Nethergon Vapor)" },
    { key = "mana", label = "Mana potion" },
    { key = "zoneMana", label = "Zone mana (e.g. Nethergon Energy)" },
    { key = "zoneItem", label = "Zone item (e.g. Windstone)" },
    { key = "healthstone", label = "Healthstone" },
    { key = "manaGem", label = "Mana Gem" },
    { key = "bandage", label = "Bandage" },
}

local function BuildAutoPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function AutoGrid()
        return addon:GetGrid(addon.AUTO_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Food & Drink (Auto)")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -32)
    desc:SetWidth(410)
    desc:SetJustifyH("LEFT")
    desc:SetText("Always shows the highest-level food and water you can use, chosen from " ..
                 "your bags. Ties are broken alphabetically, and conjured items get their " ..
                 "own buttons. Feed Pet rides on this bar; its foods live on the Pet Food tab.")

    local slotsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    slotsTitle:SetPoint("TOPLEFT", 10, -90)
    slotsTitle:SetText("|cffFFD100Slots|r")

    local slotHolder = CreateFrame("Frame", nil, content)
    slotHolder:SetPoint("TOPLEFT", 0, -110)
    slotHolder:SetSize(ROW_WIDTH, 80)
    BuildSlotToggles(slotHolder, panel, FOOD_SLOT_LABELS, AutoGrid, function()
        addon:UpdateAutoBar()
        addon:RequestUpdate()
        panel:Refresh()
    end)

    panel.appearance = CreateAppearanceControls(content, AutoGrid)
    panel.appearance:SetPoint("TOPLEFT", 10, -200)

    local pickTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOPLEFT", 10, -460)
    pickTitle:SetText("|cffFFD100Currently showing|r")

    panel.pickText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.pickText:SetPoint("TOPLEFT", 10, -480)
    panel.pickText:SetWidth(410)
    panel.pickText:SetJustifyH("LEFT")

    function panel:Refresh()
        self.appearance:Refresh()
        for _, check in pairs(self.slotChecks) do check:Refresh() end

        local grid = AutoGrid()
        local selection = addon.autoSelection or {}

        local lines = {}
        for _, slot in ipairs(FOOD_SLOT_LABELS) do
            if slot.key == "feedPet" and not addon:IsHunter() then
                -- Not applicable; leave it out of the readout entirely.
            elseif grid.autoSlots[slot.key] == false then
                table.insert(lines, slot.label .. ": |cff808080disabled|r")
            else
                local pick = selection[slot.key]
                if not pick and slot.key == "feedPet" and not UnitExists("pet") then
                    table.insert(lines, slot.label .. ": |cff808080no pet summoned|r")
                elseif not pick then
                    table.insert(lines, slot.label .. ": |cff808080none|r")
                elseif pick.isCreateSpell then
                    table.insert(lines, slot.label .. ": |cff00ccff" .. pick.name ..
                                 " (make one)|r")
                elseif slot.key == "feedPet" then
                    if pick.needsSetup then
                        table.insert(lines, slot.label .. ": |cffff5555no food chosen|r")
                    elseif pick.state and pick.state ~= "ready" then
                        table.insert(lines, slot.label .. ": |cffff5555" ..
                                     (pick.hint or pick.state) .. "|r")
                    else
                        table.insert(lines, slot.label .. ": " .. pick.name ..
                                     " |cff808080(" .. pick.total .. " total)|r")
                    end
                else
                    local note = pick.isTableFood and " |cff00ccff(table food)|r" or ""
                    table.insert(lines, slot.label .. ": " .. pick.name ..
                                 " |cff808080(req " .. pick.minLevel .. ")|r" .. note)
                end
            end
        end
        self.pickText:SetText(table.concat(lines, "\n"))
        self.content:SetHeight(495 + math.max(self.pickText:GetStringHeight(), 14) + 30)
    end

    return panel
end

-------------------------------
-- Pet Food Panel
-------------------------------
-- Its own tab so the feature is findable rather than buried at the bottom of
-- the Food & Drink panel.

-- Everything that will be fed, in order, each with a button to rule it out.
-- Excluding by hand writes to the same store the pet teaches by refusing, so
-- the two are one fact.
local PET_ROW_HEIGHT = 20

local function CreatePetAutoList(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(ROW_WIDTH, PET_ROW_HEIGHT)
    frame.rows = {}

    function frame:AcquireRow(index)
        local row = self.rows[index]
        if not row then
            row = CreateFrame("Frame", nil, self)
            row:SetSize(ROW_WIDTH, PET_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * PET_ROW_HEIGHT)

            row.up = CreateFrame("Button", nil, row)
            row.up:SetSize(16, 16)
            row.up:SetPoint("LEFT", 2, 0)
            row.up:SetNormalTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Up")
            row.up:SetHighlightTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Highlight")
            row.up:SetPushedTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Down")
            row.up:SetDisabledTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollUp-Disabled")
            row.up:SetScript("OnClick", function(button)
                local owner = button:GetParent()
                if addon:MovePetFood(frame.family, owner.itemID, -1) then
                    if frame.onChanged then frame.onChanged() end
                end
            end)
            row.up:SetScript("OnEnter", function(button)
                GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
                GameTooltip:SetText("Feed this sooner")
                GameTooltip:Show()
            end)
            row.up:SetScript("OnLeave", function() GameTooltip:Hide() end)

            row.down = CreateFrame("Button", nil, row)
            row.down:SetSize(16, 16)
            row.down:SetPoint("LEFT", 20, 0)
            row.down:SetNormalTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Up")
            row.down:SetHighlightTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Highlight")
            row.down:SetPushedTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Down")
            row.down:SetDisabledTexture("Interface\\CHATFRAME\\UI-ChatIcon-ScrollDown-Disabled")
            row.down:SetScript("OnClick", function(button)
                local owner = button:GetParent()
                if addon:MovePetFood(frame.family, owner.itemID, 1) then
                    if frame.onChanged then frame.onChanged() end
                end
            end)
            row.down:SetScript("OnEnter", function(button)
                GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
                GameTooltip:SetText("Feed this later")
                GameTooltip:Show()
            end)
            row.down:SetScript("OnLeave", function() GameTooltip:Hide() end)

            row.toggle = CreateFrame("Button", nil, row)
            row.toggle:SetSize(16, 16)
            row.toggle:SetPoint("LEFT", 40, 0)
            row.toggle:SetScript("OnClick", function(button)
                local owner = button:GetParent()
                if not owner.itemID or not frame.family then return end
                addon:SetPetFoodExcluded(frame.family, owner.itemID, not owner.excluded)
                if frame.onChanged then frame.onChanged() end
            end)
            row.toggle:SetScript("OnEnter", function(button)
                local owner = button:GetParent()
                GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
                if owner.excluded then
                    GameTooltip:SetText("Allow this food again")
                else
                    GameTooltip:SetText("Never feed this to this pet")
                end
                GameTooltip:Show()
            end)
            row.toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", row.toggle, "RIGHT", 6, 0)
            row.text:SetPoint("RIGHT", -6, 0)
            row.text:SetJustifyH("LEFT")

            self.rows[index] = row
        end
        row:Show()
        return row
    end

    function frame:Refresh(family)
        self.family = family

        local shown = 0
        if family then
            local included, excluded = addon:GetPetFoodOverview(family)

            for order, pick in ipairs(included) do
                shown = shown + 1
                local row = self:AcquireRow(shown)
                row.itemID = pick.itemID
                row.excluded = false
                row.toggle:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
                row.toggle:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")

                -- Only included rows have a position to move.
                row.up:Show()
                row.down:Show()
                if order == 1 then row.up:Disable() else row.up:Enable() end
                if order >= #included then row.down:Disable() else row.down:Enable() end

                local color = addon.PET_FOOD_COLORS[pick.rating]
                    or addon.PET_FOOD_COLORS.good
                row.text:SetText(order .. ". " .. pick.name ..
                    " |cff808080x" .. GetItemCount(pick.itemID) .. "|r")
                row.text:SetTextColor(color[1], color[2], color[3])
            end

            for _, pick in ipairs(excluded) do
                shown = shown + 1
                local row = self:AcquireRow(shown)
                row.itemID = pick.itemID
                row.excluded = true
                row.up:Hide()
                row.down:Hide()
                row.toggle:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
                row.toggle:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
                row.text:SetText(pick.name .. " |cff808080(excluded)|r")
                row.text:SetTextColor(0.5, 0.5, 0.5)
            end
        end

        for index = shown + 1, #self.rows do
            self.rows[index]:Hide()
        end

        local height = math.max(shown * PET_ROW_HEIGHT, PET_ROW_HEIGHT)
        self:SetSize(ROW_WIDTH, height)
        self.shownCount = shown
        return height
    end

    return frame
end

local function BuildPetFoodPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function AutoGrid()
        return addon:GetGrid(addon.AUTO_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Pet Food")

    panel.notHunter = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.notHunter:SetPoint("TOPLEFT", 10, -40)
    panel.notHunter:SetWidth(410)
    panel.notHunter:SetJustifyH("LEFT")
    panel.notHunter:SetText("Only hunters have a pet to feed.")

    panel.petAutoCheck = CreateCheckbox(content, "Pick pet food automatically",
        function()
            local g = AutoGrid()
            return (g.petFoodMode or "auto") == "auto"
        end,
        function(v)
            AutoGrid().petFoodMode = v and "auto" or "manual"
            addon:UpdateAutoBar()
            addon:RequestUpdate()
            panel:Refresh()
        end, true)

    panel.subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.subtitle:SetWidth(410)
    panel.subtitle:SetJustifyH("LEFT")

    panel.autoList = CreatePetAutoList(content)
    panel.autoList.onChanged = function() panel:Refresh() end

    panel.emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.emptyText:SetWidth(410)
    panel.emptyText:SetJustifyH("LEFT")

    -- Only offered once an order has actually been set by hand, so reshuffling
    -- the list is never a one-way door.
    panel.resetOrderBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    panel.resetOrderBtn:SetSize(110, 20)
    panel.resetOrderBtn:SetText("Reset order")
    panel.resetOrderBtn:SetScript("OnClick", function()
        addon:ResetPetFoodOrder(panel.orderFamily)
        panel:Refresh()
    end)

    panel.familyLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.familyLabel:SetText("Editing list for")

    -- Every tameable family, not just the one out, so lists can be preset.
    panel.familyDropdown = CreateOptionDropdown(content, 150, {}, {},
        function() return panel.editingFamily end,
        function(v)
            panel.editingFamily = v
            panel:Refresh()
        end)

    -- Escape hatch: the edible filter leans on item class IDs, so if it ever
    -- excludes something valid the full list is one click away.
    panel.showAll = CreateCheckbox(content, "Show all items",
        function() return panel.showAllPetFood == true end,
        function(v) panel.showAllPetFood = v end, true)

    panel.manualList = CreateItemListSection(content, {
        scrollable = false,
        showPerItemOptions = false,
        removeText = "Remove from pet food",
        getList = function()
            return addon:GetPetFoodList(panel.editingFamily)
        end,
        onChanged = function()
            addon:UpdateAutoBar()
            addon:RequestUpdate()
        end,
        dropdownOpts = {
            getItems = function()
                return addon:GetPetFoodChoices(panel.showAllPetFood)
            end,
            getColor = function(itemID)
                local rating = addon:RatePetFood(itemID, panel.editingFamily)
                local color = addon.PET_FOOD_COLORS[rating] or addon.PET_FOOD_COLORS.good
                return color[1], color[2], color[3]
            end,
        },
    })

    local function HideAll(self)
        self.petAutoCheck:Hide()
        self.subtitle:Hide()
        self.autoList:Hide()
        self.emptyText:Hide()
        self.resetOrderBtn:Hide()
        self.familyLabel:Hide()
        self.familyDropdown:Hide()
        self.familyDropdown.listFrame:Hide()
        self.showAll:Hide()
        self.manualList:Hide()
    end

    function panel:Refresh()
        if not addon:IsHunter() then
            HideAll(self)
            self.notHunter:Show()
            self.content:SetHeight(120)
            return
        end
        self.notHunter:Hide()

        local grid = AutoGrid()
        local activeFamily = addon:GetPetFamily()
        local auto = (grid.petFoodMode or "auto") == "auto"

        if not self.editingFamily then
            self.editingFamily = activeFamily or addon.FAMILY_ORDER[1]
        end
        -- Auto always concerns the pet that is actually out.
        local family = auto and activeFamily or self.editingFamily

        -- Laid out with a running cursor: the subtitle wraps to a different
        -- number of lines depending on mode and diet, so fixed offsets here is
        -- what made the checkbox overlap it.
        local cursor = 44

        self.petAutoCheck:ClearAllPoints()
        self.petAutoCheck:SetPoint("TOPLEFT", 10, -cursor)
        self.petAutoCheck:Show()
        self.petAutoCheck:Refresh()
        cursor = cursor + 28

        local diet = addon:GetDietForFamily(family)
        local lineBreak = "\n"
        local subtitle
        if auto then
            subtitle = "Nothing to set up: food comes from your bags, highest level " ..
                       "first, and anything your pet refuses is remembered and dropped. " ..
                       "Use the arrows to change the feed order, or the X to rule a food " ..
                       "out yourself."
        else
            subtitle = "Feed Pet uses the first of these you actually have; order is " ..
                       "priority. Each pet family keeps its own list, so you can set " ..
                       "one up before taming."
        end
        if family then
            subtitle = subtitle .. lineBreak .. "|cffFFD100" .. family .. "|r"
            if diet then
                subtitle = subtitle .. " |cffFFD100diet:|r " .. table.concat(diet, ", ")
            end
        end
        subtitle = subtitle .. lineBreak ..
            "Level fit: |cffFFD100good|r  |cff33ff33low|r  |cff808080too low|r"

        self.subtitle:ClearAllPoints()
        self.subtitle:SetPoint("TOPLEFT", 10, -cursor)
        self.subtitle:SetText(subtitle)
        self.subtitle:Show()
        cursor = cursor + math.max(self.subtitle:GetStringHeight(), 14) + 14

        if auto then
            self.familyLabel:Hide()
            self.familyDropdown:Hide()
            self.familyDropdown.listFrame:Hide()
            self.showAll:Hide()
            self.manualList:Hide()

            self.orderFamily = family
            local height = self.autoList:Refresh(family)
            if family and self.autoList.shownCount > 0 then
                self.autoList:ClearAllPoints()
                self.autoList:SetPoint("TOPLEFT", 10, -cursor)
                self.autoList:Show()
                self.emptyText:Hide()
                cursor = cursor + height

                if addon:HasPetFoodOrder(family) then
                    self.resetOrderBtn:ClearAllPoints()
                    self.resetOrderBtn:SetPoint("TOPLEFT", 10, -(cursor + 6))
                    self.resetOrderBtn:Show()
                    cursor = cursor + 30
                else
                    self.resetOrderBtn:Hide()
                end
            else
                self.autoList:Hide()
                self.emptyText:ClearAllPoints()
                self.emptyText:SetPoint("TOPLEFT", 10, -cursor)
                self.emptyText:SetText(family
                    and "Nothing in your bags this pet can eat."
                    or "Summon a pet and the list fills itself in.")
                self.emptyText:Show()
                self.resetOrderBtn:Hide()
                cursor = cursor + 20
            end
        else
            self.autoList:Hide()
            self.emptyText:Hide()
            self.resetOrderBtn:Hide()

            local labels = {}
            for _, entry in ipairs(addon.FAMILY_ORDER) do
                local count = addon:CountPetFoodFor(entry)
                local label = entry
                if entry == activeFamily then
                    label = label .. " |cff33ff33(active)|r"
                end
                if count > 0 then
                    label = label .. " |cff808080[" .. count .. "]|r"
                end
                labels[entry] = label
            end
            self.familyDropdown:SetOptions(addon.FAMILY_ORDER, labels)
            self.familyDropdown:Refresh()

            self.familyLabel:ClearAllPoints()
            self.familyLabel:SetPoint("TOPLEFT", 10, -(cursor + 4))
            self.familyLabel:Show()

            self.familyDropdown:ClearAllPoints()
            self.familyDropdown:SetPoint("TOPLEFT", 120, -cursor)
            self.familyDropdown:Show()

            self.showAll:ClearAllPoints()
            self.showAll:SetPoint("TOPLEFT", 285, -cursor)
            self.showAll:Show()
            self.showAll:Refresh()
            cursor = cursor + 32

            self.manualList:ClearAllPoints()
            self.manualList:SetPoint("TOPLEFT", 10, -cursor)
            self.manualList:Show()
            cursor = cursor + self.manualList:Refresh()
        end

        self.content:SetHeight(cursor + 24)
    end

    return panel
end
local function BuildPotionPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function PotionGrid()
        return addon:GetGrid(addon.POTION_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Potions (Auto)")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -32)
    desc:SetWidth(410)
    desc:SetJustifyH("LEFT")
    desc:SetText("Shows the biggest health and mana restore you are carrying and can " ..
                 "actually use. Zone consumables take the slot while you are somewhere " ..
                 "they work. Healthstones and Mana Gems get their own buttons, counting " ..
                 "every rank together and using the strongest.")

    local slotsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    slotsTitle:SetPoint("TOPLEFT", 10, -95)
    slotsTitle:SetText("|cffFFD100Slots|r")

    local slotHolder = CreateFrame("Frame", nil, content)
    slotHolder:SetPoint("TOPLEFT", 0, -115)
    slotHolder:SetSize(ROW_WIDTH, 105)
    BuildSlotToggles(slotHolder, panel, POTION_SLOT_LABELS, PotionGrid, function()
        addon:UpdatePotionBar()
        addon:RequestUpdate()
        panel:Refresh()
    end)

    panel.appearance = CreateAppearanceControls(content, PotionGrid)
    panel.appearance:SetPoint("TOPLEFT", 10, -230)

    local pickTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOPLEFT", 10, -490)
    pickTitle:SetText("|cffFFD100Currently showing|r")

    panel.pickText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.pickText:SetPoint("TOPLEFT", 10, -510)
    panel.pickText:SetWidth(410)
    panel.pickText:SetJustifyH("LEFT")

    function panel:Refresh()
        self.appearance:Refresh()
        for _, check in pairs(self.slotChecks) do check:Refresh() end

        local selection = addon.potionSelection or {}
        local grid = PotionGrid()
        local lines = {}
        for _, slot in ipairs(POTION_SLOT_LABELS) do
            if grid.autoSlots[slot.key] == false then
                table.insert(lines, slot.label .. ": |cff808080disabled|r")
            else
                local pick = selection[slot.key]
                if pick and pick.isCreateSpell then
                    table.insert(lines, slot.label .. ": |cff00ccff" .. pick.name ..
                                 " (make one)|r")
                elseif not pick then
                    table.insert(lines, slot.label .. ": |cff808080none on hand|r")
                else
                    local note = ""
                    if pick.total then
                        note = note .. " |cff808080x" .. pick.total .. "|r"
                    end
                    if pick.estimated then
                        note = note .. " |cff808080(estimated)|r"
                    end
                    if pick.isZoneItem then
                        note = note .. " |cff00ccff(zone item)|r"
                    end
                    local others = (addon.potionAlternatives or {})[slot.key]
                    if others and #others > 1 then
                        note = note .. " |cff808080+" .. (#others - 1) ..
                               " on right-click|r"
                    end
                    table.insert(lines, slot.label .. ": " .. pick.name ..
                                 " |cff808080(" .. math.floor((pick.amount or 0) + 0.5) ..
                                 ")|r" .. note)
                end
            end
        end
        self.pickText:SetText(table.concat(lines, "\n"))
        self.content:SetHeight(655)
    end

    return panel
end

local TELEPORT_SLOT_LABELS = {
    { key = "hearthstone", label = "Hearthstone" },
    { key = "engineering", label = "Engineering teleporters" },
    { key = "parachute", label = "Parachute Cloak" },
    -- shown only alongside a transporter; see UpdateTeleportBar
    { key = "mageTeleports", label = "Mage teleports (flyout)" },
    { key = "magePortals", label = "Mage portals (flyout)" },
    { key = "extras", label = "Extra teleports (below)" },
}

local function BuildTeleportPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function TeleportGrid()
        return addon:GetGrid(addon.TELEPORT_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Teleports (Auto)")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT",10, -32)
    desc:SetWidth(410)
    desc:SetJustifyH("LEFT")
    desc:SetText("Shows every teleport you are carrying or wearing. Mage teleports and " ..
                 "portals each collapse into a button of their own that fans out when " ..
                 "clicked. Anything not recognized can be added to the list at the bottom.")

    local slotsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    slotsTitle:SetPoint("TOPLEFT", 10, -95)
    slotsTitle:SetText("|cffFFD100Include|r")

    local slotHolder = CreateFrame("Frame", nil, content)
    slotHolder:SetPoint("TOPLEFT", 0, -115)
    slotHolder:SetSize(ROW_WIDTH, 80)
    BuildSlotToggles(slotHolder, panel, TELEPORT_SLOT_LABELS, TeleportGrid, function()
        addon:UpdateTeleportBar()
        addon:RequestUpdate()
        panel:Refresh()
    end)

    panel.appearance = CreateAppearanceControls(content, TeleportGrid)
    panel.appearance:SetPoint("TOPLEFT", 10, -205)

    local pickTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOPLEFT", 10, -465)
    pickTitle:SetText("|cffFFD100Currently showing|r")

    panel.pickText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.pickText:SetPoint("TOPLEFT", 10, -485)
    panel.pickText:SetWidth(410)
    panel.pickText:SetJustifyH("LEFT")

    panel.extraTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.extraTitle:SetPoint("TOPLEFT", 10, -590)
    panel.extraTitle:SetText("Extra Teleports")

    panel.extraSubtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.extraSubtitle:SetPoint("TOPLEFT", 10, -610)
    panel.extraSubtitle:SetWidth(410)
    panel.extraSubtitle:SetJustifyH("LEFT")
    panel.extraSubtitle:SetText("Teleport items the built-in list does not know about. " ..
                                "They appear on the bar whenever you are carrying them.")

    panel.extraList = CreateItemListSection(content, {
        scrollable = false,
        showPerItemOptions = false,
        removeText = "Remove from teleports",
        getList = function()
            local g = TeleportGrid()
            return g and g.extras
        end,
        onChanged = function()
            addon:UpdateTeleportBar()
            addon:RequestUpdate()
        end,
    })
    panel.extraList:SetPoint("TOPLEFT", 10, -642)

    function panel:Refresh()
        self.appearance:Refresh()
        for _, check in pairs(self.slotChecks) do check:Refresh() end

        local selection = addon.teleportSelection or {}
        local grid = TeleportGrid()
        local lines = {}

        for _, slot in ipairs(TELEPORT_SLOT_LABELS) do
            if grid.autoSlots[slot.key] == false then
                table.insert(lines, slot.label .. ": |cff808080off|r")
            else
                local picked = selection[slot.key]
                if not picked or #picked == 0 then
                    table.insert(lines, slot.label .. ": |cff808080none|r")
                elseif slot.key == "magePortals" or slot.key == "mageTeleports" then
                    table.insert(lines, slot.label .. ": |cff00ccff" .. #picked ..
                                 " known|r")
                else
                    local names = {}
                    for _, entry in ipairs(picked) do
                        local name = entry.name
                        if slot.key == "parachute" and entry.worn == false then
                            name = name .. " |cff808080(equip first)|r"
                        end
                        table.insert(names, name)
                    end
                    table.insert(lines, slot.label .. ": " .. table.concat(names, ", "))
                end
            end
        end

        self.pickText:SetText(table.concat(lines, "\n"))
        self.content:SetHeight(642 + self.extraList:Refresh() + 20)
    end

    return panel
end

local AMMO_SLOT_LABELS = {
    { key = "ammo", label = "Hunter ammo" },
}

local function BuildAmmoPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function AmmoGrid()
        return addon:GetGrid(addon.AMMO_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Ammo (Auto)")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -32)
    desc:SetWidth(410)
    desc:SetJustifyH("LEFT")
    desc:SetText("Reads whatever is loaded in your ammo slot and counts what is left. " ..
                 "It has a bar of its own so you can put the count where you want it - " ..
                 "drag it like any other bar, or lock it once it is placed. This is a " ..
                 "readout rather than a button: clicking ammo does nothing in game, so " ..
                 "the icon is deliberately not clickable. Low supply below colors the " ..
                 "count red, and is set in arrows rather than stacks.")

    local slotsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    slotsTitle:SetPoint("TOPLEFT", 10, -110)
    slotsTitle:SetText("|cffFFD100Slots|r")

    local slotHolder = CreateFrame("Frame", nil, content)
    slotHolder:SetPoint("TOPLEFT", 0, -130)
    slotHolder:SetSize(ROW_WIDTH, 30)
    BuildSlotToggles(slotHolder, panel, AMMO_SLOT_LABELS, AmmoGrid, function()
        addon:UpdateAmmoBar()
        addon:RequestUpdate()
        panel:Refresh()
    end)

    panel.appearance = CreateAppearanceControls(content, AmmoGrid, { 1000, 50 })
    panel.appearance:SetPoint("TOPLEFT", 10, -170)

    local pickTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOPLEFT", 10, -430)
    pickTitle:SetText("|cffFFD100Currently showing|r")

    panel.pickText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.pickText:SetPoint("TOPLEFT", 10, -450)
    panel.pickText:SetWidth(410)
    panel.pickText:SetJustifyH("LEFT")

    function panel:Refresh()
        self.appearance:Refresh()
        for _, check in pairs(self.slotChecks) do check:Refresh() end

        local grid = AmmoGrid()
        local selection = addon.ammoSelection or {}
        local lines = {}
        for _, slot in ipairs(AMMO_SLOT_LABELS) do
            if grid.autoSlots[slot.key] == false then
                table.insert(lines, slot.label .. ": |cff808080disabled|r")
            else
                local pick = selection[slot.key]
                if not pick then
                    table.insert(lines, slot.label ..
                                 ": |cff808080nothing in the ammo slot|r")
                else
                    table.insert(lines, slot.label .. ": " .. (pick.name or "?") ..
                                 " |cff808080(" .. (pick.count or 0) .. " left)|r")
                end
            end
        end
        self.pickText:SetText(table.concat(lines, "\n"))
        self.content:SetHeight(490)
    end

    return panel
end

local ENCHANT_SLOT_LABELS = {
    { key = "mainHand", label = "Main hand" },
    { key = "offHand", label = "Off hand" },
}

local function BuildEnchantPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function EnchantGrid()
        return addon:GetGrid(addon.ENCHANT_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Weapon Enchants (Auto)")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -32)
    desc:SetWidth(410)
    desc:SetJustifyH("LEFT")
    desc:SetText("Sharpening stones, weightstones and oils from your bags, best " ..
                 "first - and rogue poisons, which take priority. |cffFFD100Left-click " ..
                 "applies to your main hand, right-click to your off hand.|r Each " ..
                 "button counts down the enchant on its own weapon and turns red once " ..
                 "it has lapsed. A hand is only offered what its weapon can take, so " ..
                 "a slot holding a mace, a shield or nothing shows no stone.")

    local slotsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    slotsTitle:SetPoint("TOPLEFT", 10, -110)
    slotsTitle:SetText("|cffFFD100Slots|r")

    local slotHolder = CreateFrame("Frame", nil, content)
    slotHolder:SetPoint("TOPLEFT", 0, -130)
    slotHolder:SetSize(ROW_WIDTH, 30)
    BuildSlotToggles(slotHolder, panel, ENCHANT_SLOT_LABELS, EnchantGrid, function()
        addon:UpdateEnchantBar()
        addon:RequestUpdate()
        panel:Refresh()
    end)

    -- Rogues pair different poisons across the two hands, which is the one
    -- thing "best in bags" cannot work out on its own.
    local poisonRow = CreateFrame("Frame", nil, content)
    poisonRow:SetPoint("TOPLEFT", 0, -165)
    poisonRow:SetSize(ROW_WIDTH, 50)
    panel.poisonRow = poisonRow

    local poisonTitle = poisonRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    poisonTitle:SetPoint("TOPLEFT", 10, 0)
    poisonTitle:SetText("|cffFFD100Poison for each hand|r")

    local poisonOptions = { "auto" }
    local poisonLabels = { auto = "Automatic" }
    for _, line in ipairs(addon.POISON_LINE_ORDER) do
        table.insert(poisonOptions, line)
        poisonLabels[line] = addon.POISON_LINE_NAMES[line]
    end

    panel.poisonDrops = {}
    for i, slot in ipairs(ENCHANT_SLOT_LABELS) do
        local label = poisonRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", 10 + (i - 1) * 205, -20)
        label:SetText(slot.label)

        local key = slot.key
        local drop = CreateOptionDropdown(poisonRow, 170, poisonOptions, poisonLabels,
            function()
                local g = EnchantGrid()
                return (g and g.poisonSlots and g.poisonSlots[key]) or "auto"
            end,
            function(v)
                local g = EnchantGrid()
                if not g then return end
                g.poisonSlots = g.poisonSlots or {}
                g.poisonSlots[key] = (v ~= "auto") and v or nil
                addon:UpdateEnchantBar()
                addon:RequestUpdate()
                panel:Refresh()
            end)
        drop:SetPoint("TOPLEFT", 10 + (i - 1) * 205, -34)
        panel.poisonDrops[key] = drop
    end

    panel.appearance = CreateAppearanceControls(content, EnchantGrid)
    panel.appearance:SetPoint("TOPLEFT", 10, -225)

    local pickTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOPLEFT", 10, -490)
    pickTitle:SetText("|cffFFD100Currently showing|r")

    panel.pickText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.pickText:SetPoint("TOPLEFT", 10, -510)
    panel.pickText:SetWidth(410)
    panel.pickText:SetJustifyH("LEFT")

    function panel:Refresh()
        self.appearance:Refresh()
        for _, check in pairs(self.slotChecks) do check:Refresh() end

        -- The poison chooser is meaningless to everyone else.
        if addon:IsRogue() then
            self.poisonRow:Show()
            for _, drop in pairs(self.poisonDrops) do drop:Refresh() end
        else
            self.poisonRow:Hide()
        end

        local selection = addon.enchantSelection or {}
        local grid = EnchantGrid()
        local lines = {}

        for _, slot in ipairs(ENCHANT_SLOT_LABELS) do
            if grid.autoSlots[slot.key] == false then
                table.insert(lines, slot.label .. ": |cff808080disabled|r")
            else
                local pick = selection[slot.key]
                if not pick then
                    table.insert(lines, slot.label ..
                                 ": |cff808080nothing to apply|r")
                elseif pick.remaining then
                    table.insert(lines, slot.label .. ": " .. pick.name ..
                                 " |cff808080(" ..
                                 addon.FormatDuration(pick.remaining) .. " left)|r")
                else
                    table.insert(lines, slot.label .. ": " .. pick.name ..
                                 " |cffff5555(no enchant)|r")
                end
            end
        end

        self.pickText:SetText(table.concat(lines, "\n"))
        self.content:SetHeight(540 + math.max(self.pickText:GetStringHeight(), 14) + 30)
    end

    return panel
end

-------------------------------
-- General Panel
-------------------------------

local function BuildGeneralPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("General Settings")

    local minimapTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minimapTitle:SetPoint("TOPLEFT", 10, -50)
    minimapTitle:SetText("|cffFFD100Minimap Icon|r")

    panel.hideMinimapCheck = CreateCheckbox(panel, "Hide Minimap Icon",
        function() return addon:GetMinimapDB().hide end,
        function(v) addon:SetMinimapButtonHidden(v) end, true)
    panel.hideMinimapCheck:SetPoint("TOPLEFT", 10, -75)


    local iconsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    iconsTitle:SetPoint("TOPLEFT", 10, -175)
    iconsTitle:SetText("|cffFFD100Icons|r")

    local cdLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cdLabel:SetPoint("TOPLEFT", 10, -197)
    cdLabel:SetText("Cooldown numbers")

    panel.cooldownDrop = CreateOptionDropdown(panel, 190,
        { "auto", "always", "never" },
        { auto = "Automatic (off with OmniCC)",
          always = "Always show", never = "Never show" },
        function() return (addon:GetGlobal() or {}).cooldownNumbers or "auto" end,
        function(v)
            local g = addon:GetGlobal()
            if g then g.cooldownNumbers = v end
            addon:RequestUpdate()
        end)
    panel.cooldownDrop:SetPoint("TOPLEFT", 10, -213)

    local commandsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    commandsTitle:SetPoint("TOPLEFT", 10, -250)
    commandsTitle:SetText("|cffFFD100Commands|r")

    local commandsText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    commandsText:SetPoint("TOPLEFT", 10, -270)
    commandsText:SetJustifyH("LEFT")
    commandsText:SetText(
        "/chair snack - Open this configuration\n" ..
        "/chair snack bind - Toggle keybind mode\n" ..
        "/chair snack scan - Rescan bags for consumables\n" ..
        "/chair snack auto - Report the auto bar selection\n" ..
        "/chair snack why - Why a potion is or is not on the bar\n" ..
        "/chair snack vis - Why a bar is or is not on screen\n" ..
        "/chair snack petfood - Pet food order and what was learned\n" ..
        "/chair snack lock - Lock all grids\n" ..
        "/chair snack unlock - Unlock all grids\n" ..
        "/chair snack reset - Reset this character settings"
    )

    local tipsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tipsTitle:SetPoint("TOPLEFT", 10, -425)
    tipsTitle:SetText("|cffFFD100Tips|r")

    local tipsText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tipsText:SetPoint("TOPLEFT", 10, -445)
    tipsText:SetJustifyH("LEFT")
    tipsText:SetWidth(400)
    tipsText:SetText(
        "- Drag the lock icon to move grids\n" ..
        "- Right-click the lock to toggle lock/unlock\n" ..
        "- Items with active buffs hide outside cities\n" ..
        "- Bank and alt counts show in item tooltips"
    )

    function panel:Refresh()
        self.hideMinimapCheck:Refresh()
        self.cooldownDrop:Refresh()
    end

    return panel
end

-------------------------------
-- Profiles Panel
-------------------------------

local function BuildProfilesPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()
    panel:Hide()

    panel.selectedProfile = nil

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Profiles")

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -34)
    desc:SetWidth(420)
    desc:SetJustifyH("LEFT")
    desc:SetText("Each character has its own grids, positions, and keybinds. " ..
                 "Copying takes a snapshot -- the two profiles stay independent afterwards.")

    local currentLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    currentLabel:SetPoint("TOPLEFT", 10, -75)
    currentLabel:SetText("Current profile:")

    panel.currentText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.currentText:SetPoint("TOPLEFT", 130, -75)

    local copyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    copyLabel:SetPoint("TOPLEFT", 10, -115)
    copyLabel:SetText("|cffFFD100Copy from another character|r")

    -- Rebuilt whenever the panel refreshes, since the profile list changes.
    panel.dropdownHolder = CreateFrame("Frame", nil, panel)
    panel.dropdownHolder:SetPoint("TOPLEFT", 10, -138)
    panel.dropdownHolder:SetSize(240, 24)

    local copyBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    copyBtn:SetSize(110, 22)
    copyBtn:SetPoint("TOPLEFT", 260, -138)
    copyBtn:SetText("Copy From")
    copyBtn:SetScript("OnClick", function()
        local source = panel.selectedProfile
        if not source then
            addon:Print("Pick a character to copy from first.")
            return
        end
        local sourceName = addon:ProfileLabel(source)
        StaticPopupDialogs["SNAPSNACK_COPY_PROFILE"] = {
            text = "Replace this character settings with those from '" .. sourceName .. "'?",
            button1 = "Copy",
            button2 = "Cancel",
            OnAccept = function()
                if addon:CopyProfileFrom(source) then
                    addon:Print("Copied profile from " .. sourceName .. ". Reloading.")
                    ReloadUI()
                end
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("SNAPSNACK_COPY_PROFILE")
    end)

    local deleteBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteBtn:SetSize(110, 22)
    deleteBtn:SetPoint("TOPLEFT", 260, -168)
    deleteBtn:SetText("Delete")
    deleteBtn:SetScript("OnClick", function()
        local target = panel.selectedProfile
        if not target then
            addon:Print("Pick a character to delete first.")
            return
        end
        StaticPopupDialogs["SNAPSNACK_DELETE_PROFILE"] = {
            text = "Delete the stored profile for '" .. addon:ProfileLabel(target) .. "'?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function()
                addon:DeleteProfile(target)
                panel.selectedProfile = nil
                panel:Refresh()
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("SNAPSNACK_DELETE_PROFILE")
    end)

    local resetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resetLabel:SetPoint("TOPLEFT", 10, -215)
    resetLabel:SetText("|cffFFD100Reset|r")

    local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(150, 22)
    resetBtn:SetPoint("TOPLEFT", 10, -238)
    resetBtn:SetText("Reset This Character")
    resetBtn:SetScript("OnClick", function()
        StaticPopupDialogs["SNAPSNACK_RESET_PROFILE"] = {
            text = "Reset all ChairSnack settings for this character?",
            button1 = "Reset",
            button2 = "Cancel",
            OnAccept = function()
                addon:ResetProfile()
                ReloadUI()
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("SNAPSNACK_RESET_PROFILE")
    end)

    -- Built once; the option list is swapped in on each refresh.
    panel.dropdown = CreateOptionDropdown(panel.dropdownHolder, 240, {}, {},
        function() return panel.selectedProfile end,
        function(v) panel.selectedProfile = v end)
    panel.dropdown:SetPoint("TOPLEFT", 0, 0)

    panel.emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.emptyText:SetPoint("TOPLEFT", panel.dropdownHolder, "TOPLEFT", 2, -4)
    panel.emptyText:SetText("No other characters stored yet.")
    panel.emptyText:Hide()

    function panel:Refresh()
        self.currentText:SetText(addon:CharLabel())

        local profiles = addon:ListOtherProfiles()
        local labels = {}
        for _, key in ipairs(profiles) do labels[key] = addon:ProfileLabel(key) end

        -- A profile that was deleted should not stay selected.
        if self.selectedProfile and not labels[self.selectedProfile] then
            self.selectedProfile = nil
        end

        if #profiles == 0 then
            self.dropdown:Hide()
            self.dropdown.listFrame:Hide()
            self.emptyText:Show()
            return
        end

        self.emptyText:Hide()
        self.dropdown:Show()
        self.dropdown:SetOptions(profiles, labels)
        self.dropdown:Refresh()
        if not self.selectedProfile then
            self.dropdown.text:SetText("Select a character...")
        end
    end

    return panel
end

-------------------------------
-- Navigation
-------------------------------

local function StyleNavButton(btn, selected)
    if selected then
        btn:SetBackdropColor(0.2, 0.4, 0.6, 1)
    else
        btn:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
    end
end

local function AcquireNavButton(index)
    local btn = navButtons[index]
    if not btn then
        btn = CreateFrame("Button", nil, configFrame.navPanel, "BackdropTemplate")
        btn:SetSize(130, 28)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn.text:SetPoint("LEFT", 8, 0)
        btn.text:SetPoint("RIGHT", -8, 0)
        btn.text:SetJustifyH("LEFT")

        btn:SetScript("OnClick", function(self) addon:SelectGrid(self.gridID) end)
        btn:SetScript("OnEnter", function(self)
            if currentGridID ~= self.gridID then
                self:SetBackdropColor(0.25, 0.25, 0.25, 1)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            StyleNavButton(self, currentGridID == self.gridID)
        end)

        navButtons[index] = btn
    end
    btn:Show()
    return btn
end

local function RefreshNavigation()
    if not configFrame then return end

    local index = 0
    local function AddEntry(id, label)
        index = index + 1
        local btn = AcquireNavButton(index)
        btn:SetPoint("TOPLEFT", 5, -5 - (index - 1) * 32)
        btn.gridID = id
        btn.text:SetText(label)
        StyleNavButton(btn, currentGridID == id)
    end

    AddEntry("general", "|cffFFD100General|r")
    AddEntry("profiles", "|cffFFD100Profiles|r")
    if addon:IsHunter() then
        AddEntry("petfood", "|cffFFD100Pet Food|r")
    end

    for _, gridInfo in ipairs(addon:GetGridList()) do
        AddEntry(gridInfo.id, gridInfo.name)
    end

    for i = index + 1, #navButtons do
        navButtons[i]:Hide()
    end

    local addBtn = configFrame.addGridBtn
    addBtn:SetPoint("TOPLEFT", 5, -10 - index * 32)
end

addon.RefreshNavigation = RefreshNavigation

-------------------------------
-- Panel Switching
-------------------------------

-- Whether the bars are in move mode. Replaces the per-bar lock: a bar is
-- movable exactly while this window is open, and pinned the moment it closes,
-- so there is no state to get stuck in and nothing to remember to re-lock.
function addon:IsConfigOpen()
    return (configFrame and configFrame:IsShown()) and true or false
end

function addon:SelectGrid(gridID)
    if not configFrame then return end

    -- Fall back to a valid selection if the target vanished.
    if not NON_GRID_PANELS[gridID] and not self:GetGrid(gridID) then
        gridID = self.AUTO_GRID_ID
    end

    currentGridID = gridID

    for _, btn in ipairs(navButtons) do
        if btn:IsShown() then
            StyleNavButton(btn, btn.gridID == gridID)
        end
    end

    -- Any of these can be absent now, either because its builder failed or
    -- because the window is being driven before it finished being built.
    local function HidePanel(key)
        local panel = configFrame[key]
        if panel then panel:Hide() end
    end

    HidePanel("gridPanel")
    HidePanel("autoPanel")
    HidePanel("potionPanel")
    HidePanel("teleportPanel")
    HidePanel("enchantPanel")
    HidePanel("ammoPanel")
    HidePanel("buffFoodPanel")
    HidePanel("petFoodPanel")
    HidePanel("generalPanel")
    HidePanel("profilesPanel")
    CloseSearchPopup()
    CloseAllDropdowns()

    -- Any of these may be nil if its builder failed; showing nothing is the
    -- honest outcome, and the failure was already reported at build time.
    local panel
    if gridID == "general" then
        panel = configFrame.generalPanel
    elseif gridID == "profiles" then
        panel = configFrame.profilesPanel
    elseif gridID == "petfood" then
        panel = configFrame.petFoodPanel
    elseif gridID == self.AUTO_GRID_ID then
        panel = configFrame.autoPanel
    elseif gridID == self.POTION_GRID_ID then
        panel = configFrame.potionPanel
    elseif gridID == self.TELEPORT_GRID_ID then
        panel = configFrame.teleportPanel
    elseif gridID == self.ENCHANT_GRID_ID then
        panel = configFrame.enchantPanel
    elseif gridID == self.AMMO_GRID_ID then
        panel = configFrame.ammoPanel
    elseif gridID == self.BUFF_FOOD_GRID_ID then
        panel = configFrame.buffFoodPanel
    else
        panel = configFrame.gridPanel
    end

    -- A panel whose builder failed leaves nothing to show. Saying so beats a
    -- second error on top of the first, which is what turned one broken panel
    -- into a window that could not be clicked at all.
    if not panel then
        addon:Print("that tab could not be built this session -- "
                    .. "|cff00ffff/reload|r usually clears it.")
        return
    end

    panel:Show()
    if panel.Refresh then panel:Refresh() end
end


-------------------------------
-- Buff Food Panel
-------------------------------

-- The classifier gets ordinary crafted food right and cannot be right about
-- everything, so the bar is balanced by hand from here. One tick box per food,
-- meaning exactly what it looks like: ticked is on the bar, unticked is off it.
-- What that writes underneath depends on what the classifier already thought,
-- which is the picker's problem rather than the reader's.

local BUFF_FOOD_MODES = { "both", "auto", "manual" }
local BUFF_FOOD_MODE_LABELS = {
    both   = "Detected, plus what I tick",
    auto   = "Detected only",
    manual = "Only what I tick",
}

local BUFF_FOOD_ROW = 26
local BUFF_FOOD_LIST_TOP = 446

local function BuildBuffFoodPanel(parent)
    local panel = CreateScrollingPanel(parent)
    local content = panel.content

    local function Grid()
        return addon:GetGrid(addon.BUFF_FOOD_GRID_ID)
    end

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Buff Food (Auto)")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 10, -32)
    desc:SetWidth(ROW_WIDTH)
    desc:SetJustifyH("LEFT")
    desc:SetText("Food that grants a buff rather than only restoring health. " ..
                 "Everything you are carrying goes on the bar, biggest stack " ..
                 "first - which one you want depends on what you are about to do, " ..
                 "and the bar cannot know that. Tick anything the detection missed.")

    -- The same block every other automatic bar gets: enable, combat, tooltips,
    -- dead, instance, group, low supply, and the layout sliders. It was left
    -- out of the first version of this panel, which meant a bar that had been
    -- switched off could not be switched back on from anywhere.
    panel.appearance = CreateAppearanceControls(content, Grid)
    panel.appearance:SetPoint("TOPLEFT", 10, -96)

    local hideCheck = CreateCheckbox(content, "Hide the bar while the buff is up",
        function()
            local grid = Grid()
            return grid and grid.hideWhileBuffed
        end,
        function(value)
            local grid = Grid()
            if grid then grid.hideWhileBuffed = value and true or false end
            addon:UpdateAllGrids()
        end)
    hideCheck:SetPoint("TOPLEFT", 10, -356)

    local modeLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeLabel:SetPoint("TOPLEFT", 10, -386)
    modeLabel:SetText("|cffFFD100What goes on the bar|r")

    local modeDrop = CreateOptionDropdown(content, 220, BUFF_FOOD_MODES,
        BUFF_FOOD_MODE_LABELS,
        function() return addon:BuffFoodMode() end,
        function(value)
            addon:SetBuffFoodMode(value)
            panel:Refresh()
        end)
    modeDrop:SetPoint("TOPLEFT", 10, -406)

    local listTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listTitle:SetPoint("TOPLEFT", 10, -436)
    listTitle:SetText("|cffFFD100Food you are carrying|r")

    local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("TOPLEFT", 14, -BUFF_FOOD_LIST_TOP - 4)
    empty:SetText("No food in your bags.")
    panel.empty = empty

    panel.rows = {}

    local function AcquireRow(index)
        local row = panel.rows[index]
        if row then return row end

        row = CreateFrame("Frame", nil, content)
        row:SetSize(ROW_WIDTH, BUFF_FOOD_ROW)

        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(22, 22)
        row.check:SetPoint("LEFT", 8, 0)
        row.check:SetScript("OnClick", function(self)
            if not row.itemID then return end
            addon:SetBuffFoodPicked(row.itemID, self:GetChecked() and true or false)
            -- The whole list is redrawn rather than the one row: a tick can move
            -- an item between the on-bar group and the rest, and can change the
            -- mode underneath the dropdown.
            panel:Refresh()
        end)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetWidth(210)
        row.name:SetJustifyH("LEFT")

        row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.tag:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
        row.tag:SetJustifyH("LEFT")

        panel.rows[index] = row
        return row
    end

    function panel:Refresh()
        self.appearance:Refresh()
        hideCheck:Refresh()
        modeDrop:Refresh()

        local candidates = addon:BuffFoodCandidates()

        for index, entry in ipairs(candidates) do
            local row = AcquireRow(index)
            row:SetPoint("TOPLEFT", 0,
                         -(BUFF_FOOD_LIST_TOP + (index - 1) * BUFF_FOOD_ROW))
            row.itemID = entry.itemID
            row.icon:SetTexture(entry.icon)

            local count = (entry.count > 0)
                and (" |cff808080x" .. entry.count .. "|r") or ""
            row.name:SetText(entry.name .. count)
            -- Three states, not two. "Unrecognised" is a different failure
            -- from "plain": it means the classifier does not think the item is
            -- food at all, which on a build this new usually means the use
            -- spell has a name it has never seen. Ticking still works.
            local tag
            if entry.detected then
                tag = "|cff66dd66detected|r"
            elseif entry.known then
                tag = "|cff888888plain food|r"
            else
                tag = "|cffdd9944unrecognized|r"
            end
            row.tag:SetText(tag)
            row.check:SetChecked(entry.onBar)
            row:Show()
        end

        for index = #candidates + 1, #self.rows do
            self.rows[index]:Hide()
        end

        if #candidates == 0 then self.empty:Show() else self.empty:Hide() end

        content:SetHeight(math.max(
            BUFF_FOOD_LIST_TOP + #candidates * BUFF_FOOD_ROW + 20, 500))
    end

    return panel
end

-------------------------------
-- Main Config Frame
-------------------------------

-- Where the window was left.
--
-- Account-wide rather than per-character: this is where you like the window
-- on your screen, not something about the character, and having it jump back
-- to the middle on every alt would be its own small annoyance.
--
-- Measured from the centre of UIParent to the centre of the window, so it
-- survives a resolution or UI-scale change as a proportion of the screen
-- rather than as a corner offset that can land off the edge.
local function SaveConfigPosition(frame)
    local centerX, centerY = UIParent:GetCenter()
    local x, y = frame:GetCenter()
    if not (centerX and x) then return end

    local global = addon:GetGlobal()
    if not global then return end
    global.configPos = { x = x - centerX, y = y - centerY }
end

local function RestoreConfigPosition(frame)
    local pos = (addon:GetGlobal() or {}).configPos
    frame:ClearAllPoints()
    if pos and pos.x and pos.y then
        frame:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
    else
        frame:SetPoint("CENTER")
    end
end

function addon:SetupConfig()
    if configFrame then return end

    configFrame = CreateFrame("Frame", addonName .. "ConfigFrame", UIParent, "BackdropTemplate")
    configFrame:SetSize(620, 570)
    RestoreConfigPosition(configFrame)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:SetClampedToScreen(true)
    configFrame:Hide()

    configFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    configFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    configFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    configFrame:SetScript("OnHide", function()
        CloseSearchPopup()
        CloseAllDropdowns()
        -- Leaving move mode: drop the move borders now, and let an empty bar
        -- that was only being shown so it could be dragged go away on the
        -- relayout.
        addon:RefreshMoveChrome()
        addon:RequestUpdate()
    end)

    configFrame:SetScript("OnShow", function()
        addon:RefreshMoveChrome()
        addon:RequestUpdate()
    end)


    local titleBar = CreateFrame("Frame", nil, configFrame)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", -70, 0)
    titleBar:SetHeight(30)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() configFrame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        configFrame:StopMovingOrSizing()
        SaveConfigPosition(configFrame)
    end)

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("CENTER", configFrame, "TOP", 0, -15)
    titleText:SetText("ChairSnack")

    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(60, 22)
    closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -8, -5)
    closeBtn:SetText("Close")
    closeBtn:GetFontString():SetTextColor(1, 0.3, 0.3)
    closeBtn:SetFrameLevel(configFrame:GetFrameLevel() + 10)
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)

    -- What the Chaircraft menu hides while it hosts this window: its title bar
    -- (and with it the drag) and its close button.
    configFrame.chairChrome = { titleBar, closeBtn }

    local navPanel = CreateFrame("Frame", nil, configFrame, "BackdropTemplate")
    navPanel:SetPoint("TOPLEFT", 8, -35)
    navPanel:SetSize(140, 490)
    navPanel:SetBackdrop(BACKDROP)
    navPanel:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
    navPanel:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    configFrame.navPanel = navPanel

    local addBtn = CreateFrame("Button", nil, navPanel, "UIPanelButtonTemplate")
    addBtn:SetSize(130, 24)
    addBtn:SetText("+ New Grid")
    addBtn:SetScript("OnClick", function()
        local newID = addon:CreateNewGrid()
        RefreshNavigation()
        addon:SelectGrid(newID)
    end)
    configFrame.addGridBtn = addBtn

    local content = CreateFrame("Frame", nil, configFrame)
    content:SetPoint("TOPLEFT", navPanel, "TOPRIGHT", 8, 0)
    content:SetPoint("BOTTOMRIGHT", configFrame, "BOTTOMRIGHT", -8, 40)
    configFrame.content = content

    -- One at a time, and a failure costs one panel.
    --
    -- These were ten calls in a row, so the first one to throw took the other
    -- nine with it -- and SetupConfig with them, and Bootstrap with that. The
    -- addon then had no bars at all, because building the bars and building
    -- the window that configures them were the same errand. What that looks
    -- like from the game is "SnapSnack is not loading", with a stack trace
    -- pointing at whichever panel happened to be unlucky.
    --
    -- Grid.lua already lays bars out one at a time for exactly this reason;
    -- this is the same lesson applied to the window.
    local function Build(key, builder)
        local ok, panel = pcall(builder, content)
        if ok then
            configFrame[key] = panel
        else
            addon:Print("|cffff5555the " .. key .. " could not be built:|r "
                        .. tostring(panel))
        end
    end

    Build("gridPanel", BuildGridPanel)
    Build("autoPanel", BuildAutoPanel)
    Build("potionPanel", BuildPotionPanel)
    Build("teleportPanel", BuildTeleportPanel)
    Build("enchantPanel", BuildEnchantPanel)
    Build("ammoPanel", BuildAmmoPanel)
    Build("buffFoodPanel", BuildBuffFoodPanel)
    Build("petFoodPanel", BuildPetFoodPanel)
    Build("generalPanel", BuildGeneralPanel)
    Build("profilesPanel", BuildProfilesPanel)

    local scanBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    scanBtn:SetSize(100, 24)
    scanBtn:SetPoint("BOTTOMLEFT", 160, 10)
    scanBtn:SetText("Scan Bags")
    scanBtn:SetScript("OnClick", function()
        addon.ClearClassifyCache()
        addon.ClearUsableCache()
        addon.ClearRestrictionCache()
        addon:ScanBags()
        addon:UpdateAutoBars()
        addon:RequestUpdate()
        local count = 0
        for _ in pairs(addon.knownConsumables) do count = count + 1 end
        addon:Print("Found " .. count .. " consumables.")
        addon:RefreshConfig()
    end)

    -- The suite's version: this has been part of Chaircraft since the merge,
    -- and asking for "SnapSnack" found no addon at all.
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(suiteName, "Version"))
        or (GetAddOnMetadata and GetAddOnMetadata(suiteName, "Version"))
        or "?"
    local versionText = configFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    versionText:SetPoint("BOTTOMRIGHT", configFrame, "BOTTOMRIGHT", -10, 10)
    versionText:SetText("v" .. version)

    tinsert(UISpecialFrames, configFrame:GetName())
end

function addon:OpenConfig(gridID)
    -- Opened from anywhere, it opens inside the Chaircraft menu. The menu calls
    -- back into here to fill the window, by which time it is hosted; the grid
    -- asked for is carried across that round trip.
    if not (configFrame and configFrame.chairEmbedded) then
        local plus = _G.ChairPlusNS
        if plus and plus.OpenPartPage then
            self.pendingConfigGrid = gridID
            if plus.OpenPartPage("snack") then return end
            self.pendingConfigGrid = nil
        end
    end

    if not configFrame then
        self:SetupConfig()
    end

    gridID = gridID or self.pendingConfigGrid
    self.pendingConfigGrid = nil
    if not gridID then
        gridID = currentGridID or self.AUTO_GRID_ID
    end

    configFrame:Show()
    RefreshNavigation()
    self:SelectGrid(gridID)
end

-- The window, built if need be but not shown. The Chaircraft menu hosts it.
function addon:GetConfigWindow()
    if not configFrame then self:SetupConfig() end
    return configFrame
end

function addon:RefreshConfig()
    if configFrame and configFrame:IsShown() and currentGridID then
        RefreshNavigation()
        self:SelectGrid(currentGridID)
    end
end

-- Opens the Food & Drink panel scrolled to its Pet Food section. Reached from
-- the unconfigured Feed Pet button, so a first click leads somewhere useful.
function addon:OpenConfigAtPetFood()
    self:OpenConfig("petfood")
end

function addon:CloseConfig()
    if configFrame then
        configFrame:Hide()
    end
end
