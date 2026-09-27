-- ChairIgnore Window.lua
-- The ChairIgnore page of the /chair menu: Players, Filters, Options.
--
-- Built on first use out of ChairPlus's own buttons and checkboxes, so it
-- looks like the rest of the menu, with plain stand-ins if ChairPlus is not
-- there. The menu hosts it (Suite/Namespace.lua); on its own it is a movable
-- window.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairIgnore

-- Wide enough for the Players tab's top row (boxes, Add and New) with the
-- same 16px margin on the right as on the left.
local WIDTH, HEIGHT = 660, 520
local ROW_H = 20
local PLAYER_ROWS = 12
local FILTER_ROWS = 12

local window
local currentTab = "players"

-------------------------------------------------------------------------------
-- Widgets
-------------------------------------------------------------------------------

local function Plus() return Chaircraft.ChairPlus or {} end

local function Button(parent, width, text, onClick)
    local b
    if Plus().MakeButton then
        b = Plus().MakeButton(parent, width, text)
    else
        b = CreateFrame("Button", nil, parent)
        b:SetSize(width, 22)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.22, 0.18, 0.32, 1)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.12)
        b.labelText = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.labelText:SetPoint("CENTER")
        b.labelText:SetText(text)
    end
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function Check(parent, text, onClick)
    local cb
    if Plus().MakeCheckButton then
        cb = Plus().MakeCheckButton(parent)
    else
        cb = CreateFrame("CheckButton", nil, parent)
        cb:SetSize(24, 24)
        cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
        cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    end
    cb:SetSize(24, 24)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(text)
    cb.label = label
    if onClick then
        cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    end
    return cb
end

local function Box(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlight")
    box:SetMaxLetters(maxLetters or 200)
    box:SetTextInsets(6, 6, 0, 0)
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.08)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

-- A box that wraps its text and grows a line at a time as it gets longer,
-- for the filter's lines of words. It is still one line of words: Enter
-- saves (the caller's OnEnterPressed), and a line break is turned back into
-- a space. `onGrow` runs whenever its height changes.
local function GrowingBox(parent, width, maxLetters, onGrow)
    local box = Box(parent, width, maxLetters)
    box:SetMultiLine(true)
    box:SetTextInsets(6, 6, 4, 4)
    -- Measured on a copy of the text, the same width and font. Kept shown
    -- (see-through): a hidden font string may not report its height.
    local measure = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    measure:SetWidth(width - 12)
    measure:SetWordWrap(true)
    measure:SetAlpha(0)
    measure:SetPoint("TOPLEFT", box, "TOPLEFT", 6, -4)
    box.measure = measure
    box.grownTo = 22
    function box:Grow()
        measure:SetText((self:GetText() or ""):gsub("[\r\n]", " ") .. " ")
        local measured = measure:GetStringHeight()
        local h = tonumber(measured) or 0
        local height = math.max(22, math.ceil(h) + 8)
        if height ~= self.grownTo then
            self.grownTo = height
            self:SetHeight(height)
            if onGrow then onGrow() end
        end
    end
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text:find("[\r\n]") then
            self:SetText((text:gsub("[\r\n]+", " ")))
            return
        end
        self:Grow()
    end)
    return box
end

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormalSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

-- A clickable list row with a highlight, a selected look, and columns.
local function Row(parent, width, columns)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, ROW_H)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(0.45, 0.35, 0.7, 0.35)
    row.selected:Hide()
    row.cols = {}
    local x = 0
    for i, col in ipairs(columns) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", x + 6, 0)
        fs:SetWidth(col.width - 10)
        fs:SetJustifyH(col.align or "LEFT")
        fs:SetWordWrap(false)
        row.cols[i] = fs
        x = x + col.width
    end
    return row
end

local function Header(parent, columns)
    local x = 0
    for _, col in ipairs(columns) do
        local fs = Label(parent, col.title, "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 6, 0)
        fs:SetWidth(col.width - 10)
        fs:SetJustifyH(col.align or "LEFT")
        x = x + col.width
    end
end

local function Scroller(frame, getOffset, setOffset, getMax)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local offset = math.max(0, math.min(getMax(), getOffset() - delta * 3))
        setOffset(offset)
        ns.RefreshWindow()
    end)
end

local function DateText(t)
    if not t or type(date) ~= "function" then return "" end
    return date("%Y-%m-%d", t)
end

local function ExpiresText(t)
    if not t then return "never" end
    local days = math.ceil((t - ns.Now()) / 86400)
    if days <= 0 then return "today" end
    return days == 1 and "in 1 day" or ("in " .. days .. " days")
end

-------------------------------------------------------------------------------
-- Players
-------------------------------------------------------------------------------

local players = { offset = 0 }

local PLAYER_COLUMNS = {
    { title = "Player", width = 190 },
    { title = "Reason", width = 230 },
    { title = "Added", width = 90 },
    { title = "Expires", width = 90 },
}

local function SelectPlayer(entry)
    players.selected = entry and entry.name or nil
    local page = window.pages.players
    page.name:SetText(entry and entry.name or "")
    page.note:SetText(entry and entry.note or "")
    local days = ""
    if entry and entry.expires then days = tostring(math.max(1, math.ceil((entry.expires - ns.Now()) / 86400))) end
    page.days:SetText(days)
    ns.RefreshWindow()
end

local function SavePlayer()
    local page = window.pages.players
    local name, note = page.name:GetText(), page.note:GetText()
    -- Blank: for someone new, the default from Options; for someone already
    -- listed, never.
    local days = tonumber(page.days:GetText())
    local entry, why
    if players.selected and ns.Find(players.selected)
        and ns.Key(ns.FullName(name)) == ns.Key(players.selected) then
        ns.SetNote(players.selected, note)
        ns.SetExpiry(players.selected, days or 0)
        entry = ns.Find(players.selected)
    else
        entry, why = ns.Add(name, note, days)
    end
    if not entry then
        ns.Print("Not added:", why .. ".")
        return
    end
    page.name:ClearFocus()
    page.note:ClearFocus()
    page.days:ClearFocus()
    SelectPlayer(nil)
end

local function BuildPlayers(page)
    local nameLabel = Label(page, "Player")
    nameLabel:SetPoint("TOPLEFT", 0, 0)
    page.name = Box(page, 170, 60)
    page.name:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)

    local noteLabel = Label(page, "Reason")
    noteLabel:SetPoint("LEFT", nameLabel, "LEFT", 180, 0)
    page.note = Box(page, 230, 120)
    page.note:SetPoint("LEFT", page.name, "RIGHT", 10, 0)

    local daysLabel = Label(page, "Remove after (days)")
    daysLabel:SetPoint("LEFT", noteLabel, "LEFT", 240, 0)
    page.days = Box(page, 60, 4)
    page.days:SetNumeric(true)
    page.days:SetPoint("LEFT", page.note, "RIGHT", 10, 0)

    page.save = Button(page, 70, "Add", SavePlayer)
    page.save:SetPoint("LEFT", page.days, "RIGHT", 10, 0)
    page.clear = Button(page, 60, "New", function() SelectPlayer(nil) end)
    page.clear:SetPoint("LEFT", page.save, "RIGHT", 6, 0)
    for _, box in ipairs({ page.name, page.note, page.days }) do
        box:SetScript("OnEnterPressed", SavePlayer)
    end

    local head = CreateFrame("Frame", nil, page)
    head:SetSize(600, 16)
    head:SetPoint("TOPLEFT", page.name, "BOTTOMLEFT", 0, -14)
    Header(head, PLAYER_COLUMNS)

    local list = CreateFrame("Frame", nil, page)
    list:SetSize(600, PLAYER_ROWS * ROW_H)
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
    local bg = list:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.3)
    page.rows = {}
    for i = 1, PLAYER_ROWS do
        local row = Row(list, 600, PLAYER_COLUMNS)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetScript("OnClick", function(self)
            if self.entry then SelectPlayer(self.entry) end
        end)
        page.rows[i] = row
    end
    Scroller(list, function() return players.offset end, function(v) players.offset = v end,
        function() return math.max(0, ns.Count() - PLAYER_ROWS) end)

    page.remove = Button(page, 90, "Remove", function()
        if players.selected then
            local name = players.selected
            ns.Remove(name)
            ns.Print(name, "is off the list.")
            SelectPlayer(nil)
        end
    end)
    page.remove:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
    page.count = Label(page, "", "GameFontDisableSmall")
    page.count:SetPoint("LEFT", page.remove, "RIGHT", 12, 0)
end

local function RefreshPlayers(page)
    local list = ns.SortedPlayers()
    players.offset = math.max(0, math.min(players.offset, #list - PLAYER_ROWS))
    for i, row in ipairs(page.rows) do
        local entry = list[players.offset + i]
        row.entry = entry
        if entry then
            row.cols[1]:SetText(ns.ShortName(entry.name))
            row.cols[2]:SetText(entry.note or "")
            row.cols[3]:SetText(DateText(entry.added))
            row.cols[4]:SetText(ExpiresText(entry.expires))
            row.selected:SetShown(players.selected ~= nil and ns.Key(players.selected) == ns.Key(entry.name))
            row:Show()
        else
            row:Hide()
        end
    end
    local editing = players.selected and ns.Find(players.selected)
    page.save.labelText:SetText(editing and "Save" or "Add")
    page.remove:SetEnabled(editing and true or false)
    local shown = math.min(#list, ns.GAME_LIST_MAX)
    page.count:SetText(string.format("%d on the list.  The game's own list on this character holds %d of them.",
        #list, shown))
end

-------------------------------------------------------------------------------
-- Filters
-------------------------------------------------------------------------------



local filters = { offset = 0 }
local LINES = 3

local FILTER_COLUMNS = {
    { title = "On", width = 30 },
    { title = "Filter", width = 150 },
    { title = "Hidden", width = 60, align = "RIGHT" },
}

local function SelectFilter(filter)
    filters.selected = filter
    local page = window.pages.filters
    page.nameBox:SetText(filter and filter.name or "")
    for i = 1, LINES do
        page.lineBoxes[i]:SetText(filter and filter.lines and filter.lines[i] or "")
    end
    page.squeeze:SetChecked(filter and filter.squeeze and true or false)
    for _, box in ipairs(page.lineBoxes) do box:Grow() end
    page.FillChannels()
    page.scrollBar:SetValue(0)
    page.UpdateScroll()
    page.result:SetText("")
    ns.RefreshWindow()
end

local function SaveFilter()
    local filter = filters.selected
    if not filter then return end
    local page = window.pages.filters
    local name = page.nameBox:GetText()
    filter.name = (name ~= "" and name) or "Unnamed filter"
    filter.lines = {}
    for i = 1, LINES do
        local text = page.lineBoxes[i]:GetText():gsub("[\r\n]+", " ")
        if text:match("%S") then filter.lines[#filter.lines + 1] = text end
    end
    filter.squeeze = page.squeeze:GetChecked() and true or nil
    ns.CompileFilters()
    for _, box in ipairs(page.lineBoxes) do box:ClearFocus() end
    page.nameBox:ClearFocus()
    ns.RefreshWindow()
end

local function BuildFilters(page)
    local head = CreateFrame("Frame", nil, page)
    head:SetSize(240, 16)
    head:SetPoint("TOPLEFT", 0, 0)
    Header(head, FILTER_COLUMNS)

    local list = CreateFrame("Frame", nil, page)
    list:SetSize(240, FILTER_ROWS * ROW_H)
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
    local bg = list:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.3)
    page.rows = {}
    for i = 1, FILTER_ROWS do
        local row = Row(list, 240, FILTER_COLUMNS)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetScript("OnClick", function(self)
            if self.filter then SelectFilter(self.filter) end
        end)
        local toggle = Check(row, "")
        toggle:SetSize(18, 18)
        toggle:SetPoint("LEFT", 6, 0)
        toggle:SetScript("OnClick", function(self)
            if row.filter then
                row.filter.enabled = self:GetChecked() and true or false
                ns.CompileFilters()
                ns.RefreshWindow()
            end
        end)
        row.toggle = toggle
        page.rows[i] = row
    end
    Scroller(list, function() return filters.offset end, function(v) filters.offset = v end,
        function() return math.max(0, #ns.Filters() - FILTER_ROWS) end)

    local new = Button(page, 70, "New", function()
        SelectFilter(ns.NewFilter())
    end)
    new:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
    page.delete = Button(page, 70, "Delete", function()
        if filters.selected then
            ns.DeleteFilter(filters.selected)
            SelectFilter(nil)
        end
    end)
    page.delete:SetPoint("LEFT", new, "RIGHT", 6, 0)
    page.reset = Button(page, 90, "Reset count", function()
        if filters.selected then
            filters.selected.blocked = 0
            ns.RefreshWindow()
        end
    end)
    page.reset:SetPoint("LEFT", page.delete, "RIGHT", 6, 0)

    -- Sharing: one filter as a line of text, and back.
    page.export = Button(page, 70, "Export", function()
        local text, why = ns.ExportFilter(filters.selected)
        if not text then ns.Print("Not exported:", why .. ".") return end
        if Chaircraft.ShowTextBox then
            Chaircraft.ShowTextBox("filter: " .. tostring(filters.selected.name), text, nil,
                "Press ctrl-A then ctrl-C, and paste it to whoever wants the filter.")
        end
    end)
    page.export:SetPoint("TOPLEFT", new, "BOTTOMLEFT", 0, -6)
    page.import = Button(page, 70, "Import", function()
        if not Chaircraft.ShowTextBox then return end
        Chaircraft.ShowTextBox("filter import", "", function(typed)
            local filter, why = ns.ImportFilter(typed)
            if not filter then ns.Print("Not imported:", why .. ".") return end
            ns.Print("Imported \"" .. filter.name .. "\", switched off. Tick it on the Chat filters tab to use it.")
            SelectFilter(filter)
        end, "Paste a ChairIgnore filter here, then press Import. It arrives switched off.")
    end)
    page.import:SetPoint("LEFT", page.export, "RIGHT", 6, 0)

    -- The editor, to the right of the list. It scrolls: the boxes for the
    -- lines of words grow as a filter gets long, and push the rest down.
    local EDITOR_H = 390
    local scroll = CreateFrame("ScrollFrame", nil, page)
    scroll:SetPoint("TOPLEFT", head, "TOPRIGHT", 20, 0)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -14, 0)
    local edit = CreateFrame("Frame", nil, scroll)
    edit:SetSize(340, EDITOR_H)
    scroll:SetScrollChild(edit)
    page.editor = scroll
    page.editorContent = edit

    local bar = CreateFrame("Slider", nil, page)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(8)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.06)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.45, 0.35, 0.7, 0.9)
    thumb:SetSize(8, 36)
    bar:SetThumbTexture(thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    page.scrollBar = bar
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local low, high = bar:GetMinMaxValues()
        local value = math.max(low or 0, math.min(high or 0, (bar:GetValue() or 0) - delta * 30))
        bar:SetValue(value)
    end)

    -- The editor's full height: its fixed parts, plus whatever the growing
    -- boxes have grown. The bar shows only when that is more than fits.
    local growing = {}
    local function UpdateScroll()
        local extra = 0
        for _, box in ipairs(growing) do extra = extra + (box.grownTo - 22) end
        extra = extra + math.max(0, (page.channelCount or 1) - 2) * 22
        local total = EDITOR_H + extra
        edit:SetHeight(total)
        local shownHeight = scroll:GetHeight()
        local visible = tonumber(shownHeight) or (HEIGHT - 96)
        local max = math.max(0, total - visible)
        bar:SetMinMaxValues(0, max)
        if (bar:GetValue() or 0) > max then bar:SetValue(max) end
        bar:SetShown(max > 0 and scroll:IsShown())
        page.scrollMax = max
    end
    page.UpdateScroll = UpdateScroll

    local nameLabel = Label(edit, "Name")
    nameLabel:SetPoint("TOPLEFT", 0, 0)
    page.nameBox = Box(edit, 330, 60)
    page.nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)

    local help = Label(edit, "Hide a message that has a word from every line below. "
        .. "Separate words with commas. |cffffd100*|r is anything (|cffffd100<*>|r: a guild tag). "
        .. "|cffffd100{link}|r is any link. A word in "
        .. "|cffffd100\"quotes\"|r counts only on its own, even spaced out or with "
        .. "look-alike letters (4 for a, 0 for o).", "GameFontDisableSmall")
    help:SetPoint("TOPLEFT", page.nameBox, "BOTTOMLEFT", 0, -10)
    help:SetWidth(330)

    page.lineBoxes = {}
    local anchor = help
    for i = 1, LINES do
        local label = Label(edit, i == 1 and "Has any of" or "and any of")
        label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
        local box = GrowingBox(edit, 330, 400, function() UpdateScroll() end)
        box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
        box:SetScript("OnEnterPressed", SaveFilter)
        page.lineBoxes[i] = box
        growing[#growing + 1] = box
        anchor = box
    end

    page.squeeze = Check(edit, "Ignore spaces and symbols (\"g.o l d\" counts as \"gold\")")
    page.squeeze:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -4, -8)

    -- Where it works: a checkbox for each channel you are in, read from the
    -- game each time (numbers change with the order channels are joined, so
    -- only names are kept). None ticked: everywhere the Options tab allows.
    -- Ticked ones override the Options tab. A channel the filter has that
    -- this character is not in is still listed, ticked, so it can be taken
    -- off. Each tick applies at once.
    local channelsLabel = Label(edit, "Only in these (none ticked: everywhere)")
    channelsLabel:SetPoint("TOPLEFT", page.squeeze, "BOTTOMLEFT", 4, -8)
    local list = CreateFrame("Frame", nil, edit)
    list:SetSize(330, 22)
    list:SetPoint("TOPLEFT", channelsLabel, "BOTTOMLEFT", -4, -2)
    page.channelList = list
    page.channelRows = {}
    page.noChannels = Label(list, "(and no numbered channels right now)", "GameFontDisableSmall")
    page.noChannels:SetPoint("TOPLEFT", 6, -26)

    local function Ticked(filter)
        local set = {}
        for name in tostring(filter and filter.channels or ""):gmatch("[^,]+") do
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" and not name:match("^%d+$") then set[name:lower()] = name end
        end
        return set
    end

    local function SetTicked(filter, set)
        local names = {}
        for _, name in pairs(set) do names[#names + 1] = name end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        filter.channels = (#names > 0) and table.concat(names, ", ") or nil
        ns.CompileFilters()
        ns.RefreshWindow()
    end

    function page.FillChannels()
        local filter = filters.selected
        local ticked = Ticked(filter)
        -- Say and Yell first, always there; then the channels you are in.
        local shown, seen = {}, { say = true, yell = true }
        shown[1] = { name = "Say", label = "Say" }
        shown[2] = { name = "Yell", label = "Yell" }
        for _, channel in ipairs(ns.JoinedChannels()) do
            local key = channel.name:lower()
            if not seen[key] then
                seen[key] = true
                shown[#shown + 1] = { name = channel.name, label = channel.name .. " |cff808080(" .. channel.number .. ")|r" }
            end
        end
        for key, name in pairs(ticked) do
            if not seen[key] then
                seen[key] = true
                shown[#shown + 1] = { name = name, label = name .. " |cff808080(not joined here)|r" }
            end
        end
        for i, entry in ipairs(shown) do
            local row = page.channelRows[i]
            if not row then
                row = Check(list, "", function(checked)
                    local f = filters.selected
                    if not (f and row.channel) then return end
                    local set = Ticked(f)
                    if checked then set[row.channel:lower()] = row.channel else set[row.channel:lower()] = nil end
                    SetTicked(f, set)
                end)
                -- Two columns, so Say, Yell and the usual channels fit
                -- without the editor having to scroll.
                row:SetPoint("TOPLEFT", ((i - 1) % 2) * 165, -math.floor((i - 1) / 2) * 22)
                page.channelRows[i] = row
            end
            row.channel = entry.name
            row.label:SetText(entry.label)
            row:SetChecked(ticked[entry.name:lower()] ~= nil)
            row:Show()
            row.label:Show()
        end
        for i = #shown + 1, #page.channelRows do
            page.channelRows[i]:Hide()
            page.channelRows[i].label:Hide()
            page.channelRows[i].channel = nil
        end
        page.noChannels:SetShown(#shown <= 2)
        -- Rows of two, plus the line saying there are no numbered channels.
        page.channelCount = math.ceil(#shown / 2) + ((#shown <= 2) and 1 or 0)
        list:SetHeight(page.channelCount * 22)
        UpdateScroll()
    end

    page.save = Button(edit, 70, "Save", SaveFilter)
    page.save:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -8)

    local tryLabel = Label(edit, "Try a message")
    tryLabel:SetPoint("TOPLEFT", page.save, "BOTTOMLEFT", 0, -12)
    page.try = Box(edit, 330, 255)
    page.try:SetPoint("TOPLEFT", tryLabel, "BOTTOMLEFT", 0, -4)
    page.result = Label(edit, "", "GameFontHighlightSmall")
    page.result:SetPoint("TOPLEFT", page.try, "BOTTOMLEFT", 0, -4)
    page.try:SetScript("OnTextChanged", function(self)
        local filter = filters.selected
        local text = self:GetText()
        if not filter or text == "" then page.result:SetText("") return end
        -- What is typed in the boxes now, saved or not.
        local draft = { lines = {}, squeeze = page.squeeze:GetChecked() and true or nil }
        for i = 1, LINES do draft.lines[i] = page.lineBoxes[i]:GetText() end
        local missing = ns.MissingLine(text, draft)
        if not missing then
            page.result:SetText("|cffff5555Hidden|r by this filter"
                .. (filter.enabled and "." or ", once it is switched on."))
        else
            page.result:SetText(string.format("|cff55ff55Shown|r: it has none of the words on line %d.", missing))
        end
    end)

    page.none = Label(page, "Pick a filter on the left, or make a new one.", "GameFontDisable")
    page.none:SetPoint("TOPLEFT", edit, "TOPLEFT", 0, -40)
end

local function RefreshFilters(page)
    local list = ns.Filters()
    filters.offset = math.max(0, math.min(filters.offset, #list - FILTER_ROWS))
    for i, row in ipairs(page.rows) do
        local filter = list[filters.offset + i]
        row.filter = filter
        if filter then
            row.toggle:SetChecked(filter.enabled and true or false)
            row.cols[1]:SetText("")
            row.cols[2]:SetText((filter.name or "")
                .. (filter.channels and ("|cff808080 (" .. filter.channels .. ")|r") or ""))
            row.cols[3]:SetText(tostring(filter.blocked or 0))
            row.selected:SetShown(filter == filters.selected)
            row:Show()
        else
            row:Hide()
        end
    end
    local has = filters.selected ~= nil
    page.editor:SetShown(has)
    page.none:SetShown(not has)
    page.UpdateScroll()
    page.delete:SetEnabled(has)
    page.reset:SetEnabled(has)
    page.export:SetEnabled(has)
end

-------------------------------------------------------------------------------
-- Hidden
-------------------------------------------------------------------------------
-- What ChairIgnore hid, newest first: to check a filter is not catching
-- more than it should, and to bring back something worth reading.

local hidden = { offset = 0 }
local HIDDEN_ROWS = 13

local HIDDEN_COLUMNS = {
    { title = "When", width = 60 },
    { title = "From", width = 150 },
    { title = "Message", width = 290 },
    { title = "Why", width = 100 },
}

local function TimeText(t)
    if not t or type(date) ~= "function" then return "" end
    return date("%H:%M", t)
end

-- The log newest first.
local function Newest()
    local log, out = ns.HiddenLog(), {}
    for i = #log, 1, -1 do out[#out + 1] = log[i] end
    return out
end

local function BuildHidden(page)
    local head = CreateFrame("Frame", nil, page)
    head:SetSize(600, 16)
    head:SetPoint("TOPLEFT", 0, 0)
    Header(head, HIDDEN_COLUMNS)

    local list = CreateFrame("Frame", nil, page)
    list:SetSize(600, HIDDEN_ROWS * ROW_H)
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
    local bg = list:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.3)
    page.rows = {}
    for i = 1, HIDDEN_ROWS do
        local row = Row(list, 600, HIDDEN_COLUMNS)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetScript("OnClick", function(self)
            hidden.selected = self.entry
            ns.RefreshWindow()
        end)
        page.rows[i] = row
    end
    Scroller(list, function() return hidden.offset end, function(v) hidden.offset = v end,
        function() return math.max(0, #ns.HiddenLog() - HIDDEN_ROWS) end)

    page.show = Button(page, 110, "Show in chat", function()
        local e = hidden.selected
        if not e then return end
        print("|cff808080[hidden by ChairIgnore, " .. (e.why == "listed" and "listed player" or e.why) .. "]|r "
            .. "[" .. e.kind .. "] " .. tostring(e.sender or "?") .. ": " .. (e.text or "<unreadable>"))
    end)
    page.show:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
    page.unignore = Button(page, 90, "Unignore", function()
        local e = hidden.selected
        if e and e.why == "listed" and e.sender and ns.Remove(e.sender) then
            ns.Print(e.sender, "is off the list.")
        end
        ns.RefreshWindow()
    end)
    page.unignore:SetPoint("LEFT", page.show, "RIGHT", 6, 0)
    page.clear = Button(page, 70, "Clear", function()
        ns.ClearHiddenLog()
        hidden.selected, hidden.offset = nil, 0
        ns.RefreshWindow()
    end)
    page.clear:SetPoint("LEFT", page.unignore, "RIGHT", 6, 0)
    page.note = Label(page, "", "GameFontDisableSmall")
    page.note:SetPoint("LEFT", page.clear, "RIGHT", 12, 0)
end

local function RefreshHidden(page)
    local list = Newest()
    hidden.offset = math.max(0, math.min(hidden.offset, #list - HIDDEN_ROWS))
    for i, row in ipairs(page.rows) do
        local e = list[hidden.offset + i]
        row.entry = e
        if e then
            row.cols[1]:SetText(TimeText(e.at))
            row.cols[2]:SetText(ns.ShortName(e.sender or "?"))
            row.cols[3]:SetText(e.text or "|cff808080(unreadable)|r")
            row.cols[4]:SetText(e.why == "listed" and "listed" or e.why)
            row.selected:SetShown(e == hidden.selected)
            row:Show()
        else
            row:Hide()
        end
    end
    local e = hidden.selected
    page.show:SetEnabled(e ~= nil)
    page.unignore:SetEnabled(e ~= nil and e.why == "listed" and ns.IsListed(e.sender or ""))
    page.note:SetText(#list .. " kept (at most " .. ns.LOG_MAX .. ")"
        .. (ns.Get("keepLog") and ", saved between sessions." or ", this session only."))
end

-------------------------------------------------------------------------------
-- Options
-------------------------------------------------------------------------------

local OPTIONS = {
    { key = "syncGameList", text = "Keep this character's game ignore list in step (it holds 50)" },
    { key = "hideListed", text = "Hide chat from everyone on the list, past the 50 too" },
    -- No switch for the filters as a whole: each one on the Chat filters
    -- tab has its own, and ships off. These say where they apply.
    { header = "Chat filters apply here, unless one names its own channels:" },
    { key = "filterPublic", text = "in trade, general and other channels", sub = true },
    { key = "filterSayYell", text = "in say, yell and emotes", sub = true },
    { key = "filterWhisper", text = "in whispers", sub = true },
    { key = "filterGroup", text = "in party, raid, instance and guild chat", sub = true },
    { key = "spareFriends", text = "never on a friend or guildmate", sub = true },
    { key = "keepLog", text = "Keep the Hidden tab's messages between sessions" },
}

local function BuildOptions(page)
    page.checks = {}
    local y = 0
    for _, option in ipairs(OPTIONS) do
        if option.header then
            local head = Label(page, option.header, "GameFontNormal")
            head:SetPoint("TOPLEFT", 4, y - 8)
            y = y - 26
        else
            local cb = Check(page, option.text, function(checked) ns.Set(option.key, checked) end)
            cb:SetPoint("TOPLEFT", option.sub and 24 or 0, y)
            cb.option = option
            page.checks[#page.checks + 1] = cb
            y = y - 26
        end
    end

    local daysLabel = Label(page, "New players come off the list after", "GameFontHighlight")
    daysLabel:SetPoint("TOPLEFT", 4, y - 10)
    page.days = Box(page, 50, 4)
    page.days:SetNumeric(true)
    page.days:SetPoint("LEFT", daysLabel, "RIGHT", 8, 0)
    local daysAfter = Label(page, "days (0: never)", "GameFontHighlight")
    daysAfter:SetPoint("LEFT", page.days, "RIGHT", 8, 0)
    local function SaveDays(self)
        ns.Set("expireDays", tonumber(self:GetText()) or 0)
        self:ClearFocus()
    end
    page.days:SetScript("OnEnterPressed", SaveDays)
    page.days:SetScript("OnEditFocusLost", SaveDays)

    local sync = Button(page, 110, "Sync now", function()
        ns.SyncGameList()
        ns.Print("Synced with this character's ignore list.")
    end)
    sync:SetPoint("TOPLEFT", 4, y - 44)
end

local function RefreshOptions(page)
    local on = ns.Get("enabled") == true
    for _, cb in ipairs(page.checks) do
        cb:SetChecked(ns.Get(cb.option.key) == true)
        local usable = on
        cb:SetEnabled(usable)
        cb.label:SetTextColor(usable and 1 or 0.5, usable and 1 or 0.5, usable and 1 or 0.5)
    end
    if not page.days:HasFocus() then page.days:SetText(tostring(ns.Get("expireDays") or 0)) end
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local TABS = {
    { key = "players", title = "Players", build = BuildPlayers, refresh = RefreshPlayers },
    { key = "filters", title = "Chat filters", build = BuildFilters, refresh = RefreshFilters },
    { key = "hidden", title = "Hidden", build = BuildHidden, refresh = RefreshHidden },
    { key = "options", title = "Options", build = BuildOptions, refresh = RefreshOptions },
}

local function Build()
    if window then return window end
    window = CreateFrame("Frame", "ChairIgnoreWindow", UIParent, "BackdropTemplate")
    window:SetSize(WIDTH, HEIGHT)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    pcall(window.SetBackdrop, window, { bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    pcall(window.SetBackdropColor, window, 0.05, 0.05, 0.07, 0.97)
    pcall(window.SetBackdropBorderColor, window, 0.45, 0.35, 0.7, 0.9)
    window:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "ChairIgnoreWindow") end

    local icon = window:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("TOPLEFT", 14, -10)
    icon:SetTexture(ns.ICON)

    window.master = Check(window, "Turn on ChairIgnore", function(checked) ns.Set("enabled", checked) end)
    window.master:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    window.status = Label(window, "", "GameFontDisableSmall")
    window.status:SetPoint("TOPRIGHT", -16, -18)
    window.status:SetJustifyH("RIGHT")
    -- While the master switch is off nothing on these pages runs: no
    -- picking up normal ignores, no sync, no chat hiding, no filters. Said where it cannot be
    -- missed, beside the tabs.
    window.offNote = Label(window, "|cffff7f7fChairIgnore is off.|r Nothing here runs, and ignoring "
        .. "someone only reaches the game's list, until you tick Turn on ChairIgnore.", "GameFontHighlightSmall")
    local noteX = 16 + #TABS * 104 + 4
    window.offNote:SetPoint("TOPLEFT", noteX, -46)
    window.offNote:SetWidth(WIDTH - noteX - 16)

    window.tabs, window.pages = {}, {}
    local x = 16
    for _, tab in ipairs(TABS) do
        local b = Button(window, 100, tab.title, function()
            currentTab = tab.key
            ns.RefreshWindow()
        end)
        b:SetPoint("TOPLEFT", x, -48)
        window.tabs[tab.key] = b
        x = x + 104

        local page = CreateFrame("Frame", nil, window)
        page:SetPoint("TOPLEFT", 16, -84)
        page:SetPoint("BOTTOMRIGHT", -16, 12)
        tab.build(page)
        window.pages[tab.key] = page
    end

    window:SetScript("OnShow", function()
        if ns.On() then ns.PruneExpired() end
        ns.RefreshWindow()
    end)
    return window
end

function ns.RefreshWindow()
    if not (window and window:IsShown()) then return end
    window.master:SetChecked(ns.Get("enabled") == true)
    window.offNote:SetShown(ns.Get("enabled") ~= true)
    local s = ns.session
    window.status:SetText(string.format("%d on the list  |  hidden this session: %d from players, %d by filters",
        ns.Count(), s.listed, s.filtered))
    for _, tab in ipairs(TABS) do
        local chosen = tab.key == currentTab
        window.pages[tab.key]:SetShown(chosen)
        local label = window.tabs[tab.key].labelText
        if label then label:SetTextColor(chosen and 1 or 0.7, chosen and 0.82 or 0.7, chosen and 0 or 0.7) end
        if chosen then tab.refresh(window.pages[tab.key]) end
    end
end

-------------------------------------------------------------------------------
-- Asking for the reason
-------------------------------------------------------------------------------
-- Opens when you ignore someone the normal way (the game's right-click
-- Ignore, or /ignore): they are already on ChairIgnore's list by then, and
-- this asks why. Save keeps the reason, Skip (or Escape) leaves them listed
-- without one. Several at once are asked about one after another.

local ask
local queue = {}

local ShowNext

local function BuildAsk()
    if ask then return ask end
    ask = CreateFrame("Frame", "ChairIgnoreReason", UIParent, "BackdropTemplate")
    ask:SetSize(340, 132)
    ask:SetPoint("CENTER", 0, 120)
    ask:SetFrameStrata("DIALOG")
    ask:SetClampedToScreen(true)
    ask:EnableMouse(true)
    ask:SetMovable(true)
    ask:RegisterForDrag("LeftButton")
    ask:SetScript("OnDragStart", ask.StartMoving)
    ask:SetScript("OnDragStop", ask.StopMovingOrSizing)
    pcall(ask.SetBackdrop, ask, { bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    pcall(ask.SetBackdropColor, ask, 0.05, 0.05, 0.07, 0.97)
    pcall(ask.SetBackdropBorderColor, ask, 0.45, 0.35, 0.7, 0.9)
    ask:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "ChairIgnoreReason") end
    -- Closing it any way (Skip, Escape, Save) moves on to the next.
    ask:SetScript("OnHide", function() ShowNext() end)

    local icon = ask:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", 12, -10)
    icon:SetTexture(ns.ICON)
    ask.title = Label(ask, "", "GameFontNormal")
    ask.title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    ask.title:SetPoint("RIGHT", ask, "RIGHT", -12, 0)

    local label = Label(ask, "Reason (optional)")
    label:SetPoint("TOPLEFT", 14, -44)
    ask.box = Box(ask, 312, 120)
    ask.box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)

    local function Save()
        local reason = ask.box:GetText()
        if ask.player and reason:match("%S") and ns.SetNote(ask.player, reason) then
            ns.Print(ask.player, "ignored: " .. reason)
        end
        ask:Hide()
    end
    ask.box:SetScript("OnEnterPressed", Save)
    ask.box:SetScript("OnEscapePressed", function() ask:Hide() end)

    ask.save = Button(ask, 90, "Save", Save)
    ask.save:SetPoint("BOTTOMRIGHT", ask, "BOTTOM", -4, 12)
    ask.skip = Button(ask, 90, "Skip", function() ask:Hide() end)
    ask.skip:SetPoint("BOTTOMLEFT", ask, "BOTTOM", 4, 12)
    return ask
end

ShowNext = function()
    local frame = BuildAsk()
    if frame:IsShown() then return end
    while #queue > 0 do
        local full = table.remove(queue, 1)
        -- Unignored again before being asked about: nothing to ask.
        if ns.IsListed(full) then
            frame.player = full
            frame.title:SetText("Ignored " .. ns.ShortName(full) .. ". Why?")
            frame.box:SetText("")
            frame:Show()
            frame.box:SetFocus()
            return
        end
    end
end

-- Core.lua calls this for each player ignored the normal way.
function ns.OnIgnoredNormally(full)
    queue[#queue + 1] = full
    ShowNext()
end

-- The channel checkboxes follow the channels you are in.
local channelWatch = CreateFrame("Frame")
channelWatch:RegisterEvent("CHANNEL_UI_UPDATE")
channelWatch:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
channelWatch:SetScript("OnEvent", function()
    if window and window:IsShown() and filters.selected and window.pages.filters.FillChannels then
        pcall(window.pages.filters.FillChannels)
    end
end)

function ns.GetWindow()
    return Build()
end

-- Opens the page on one tab ("players", "filters", "options").
function ns.ShowTab(key)
    currentTab = key
    ns.RefreshWindow()
end

-- What the menu's search box can find here: each tab by name, and each
-- option by its label. Opening one goes to its tab (the part's page is
-- opened first, by the menu).
function ns.SearchEntries()
    local out = {}
    for _, tab in ipairs(TABS) do
        out[#out + 1] = { label = "ChairIgnore: " .. tab.title, open = function() ns.ShowTab(tab.key) end }
    end
    for _, option in ipairs(OPTIONS) do
        if option.text then
            out[#out + 1] = { label = option.text, open = function() ns.ShowTab("options") end }
        end
    end
    out[#out + 1] = { label = "Turn on ChairIgnore", open = function() ns.ShowTab("options") end }
    return out
end

function ns.ShowWindow()
    Build():Show()
    ns.RefreshWindow()
end
