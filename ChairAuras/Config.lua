local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------
-- Built only from templates the probe instantiated on this client and watched
-- come back with real dimensions: BackdropTemplate, InsetFrameTemplate3,
-- UIPanelScrollFrameTemplate, UIPanelButtonTemplate, UICheckButtonTemplate,
-- InputBoxTemplate and OptionsSliderTemplate.
--
-- There is deliberately no dropdown anywhere in here. UIDropDownMenu is the one
-- widget family the probe never covered, and it is also the one the retail
-- engine rewrote -- so every choice is a row of buttons that lock their own
-- highlight instead. Buttons cost a few more lines and cannot be missing.
--
-- The right-hand side is three tabs -- Trigger, Display, Load -- the same split
-- WeakAuras uses, and for the same reason: what makes an aura fire, what it
-- looks like when it does, and whether it exists at all are three separate
-- questions, and a single flat list of forty controls hides that.
--
-- Every pane is built from a table of field descriptions rather than by hand.
-- Adding an option is a row in a table, and the Load tab is generated straight
-- from the condition list in Load.lua, so the window cannot drift out of step
-- with what the engine actually tests.
--
-- Nothing in this file is required for the addon to work. If the window fails to
-- build, the slash commands still configure everything it does.

local Config = {}
ns.Config = Config

local WINDOW_W, WINDOW_H = 760, 520
local LIST_W, LIST_H = 250, 360
local PANE_W = 440
local ROW_HEIGHT = 24
local FIELD_GAP = 6

local window, listChild, editor
local rows = {}
local selectedID = nil
local currentTab = "trigger"
-- Which of the selected aura's triggers the Trigger tab is editing.
local currentTrigger = 1

-------------------------------------------------------------------------------
-- Small widget helpers
-------------------------------------------------------------------------------

local function Tooltip(frame, title, body)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        if body then GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Text(parent, text, font, colour)
    local region = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    region:SetText(text)
    if colour then region:SetTextColor(unpack(colour)) end
    return region
end

local function Button(parent, label, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(label)
    button:SetScript("OnClick", onClick)
    return button
end

local function CheckBox(parent, label, onClick)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    -- The template's own label is reached by a global name on some builds and by
    -- a key on others, so this carries its own and depends on neither.
    check.label = Text(parent, label, "GameFontHighlightSmall")
    check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    return check
end

-- A choice of two or more. Each button locks its highlight while it is the
-- answer, which is what a dropdown would have shown as its selected line.
local function ButtonGroup(parent, labels, width, onPick, perRow)
    local group = { buttons = {} }

    for index, entry in ipairs(labels) do
        local button = Button(parent, entry.text, width, function()
            onPick(entry.value)
        end)
        button.value = entry.value
        if index == 1 then
            button:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        elseif perRow and (index - 1) % perRow == 0 then
            -- A new row, under the first button of the last one.
            button:SetPoint("TOPLEFT", group.buttons[index - perRow], "BOTTOMLEFT", 0, -4)
        else
            button:SetPoint("LEFT", group.buttons[index - 1], "RIGHT", 4, 0)
        end
        group.buttons[index] = button
    end
    group.rows = perRow and math.ceil(#labels / perRow) or 1

    function group:SetValue(value)
        for _, button in ipairs(self.buttons) do
            if button.value == value then
                button:LockHighlight()
            else
                button:UnlockHighlight()
            end
        end
    end

    function group:SetEnabled(enabled)
        for _, button in ipairs(self.buttons) do
            button:SetEnabled(enabled)
        end
    end

    return group
end

-- A dropdown: a button naming the current choice, and a list that opens
-- under it. Built here rather than on Blizzard's UIDropDownMenu, which taints
-- whatever it touches -- the kind of thing that ends in a blocked action in
-- combat. `values` may carry { header = "Spells" } entries, drawn as titles.
-- A long list scrolls with the mouse wheel.
local openDropdown
local MENU_ROW, MENU_ROWS = 18, 16

local function Dropdown(parent, width, values, onPick)
    local dropdown = {}
    local button = Button(parent, "", width, function()
        if openDropdown and openDropdown ~= dropdown then openDropdown.menu:Hide() end
        if dropdown.menu:IsShown() then dropdown.menu:Hide() return end
        dropdown:Open()
    end)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    dropdown.button = button
    local arrow = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    arrow:SetText("v")

    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:SetWidth(math.max(width, 160))
    pcall(menu.SetBackdrop, menu, {
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    pcall(menu.SetBackdropColor, menu, 0.06, 0.06, 0.08, 0.97)
    menu:EnableMouse(true)
    menu:EnableMouseWheel(true)
    menu:Hide()
    dropdown.menu = menu
    -- Closing the window closes the list with it.
    parent:HookScript("OnHide", function() menu:Hide() end)

    dropdown.rows = {}
    dropdown.offset = 0
    local function Row(i)
        local row = dropdown.rows[i]
        if row then return row end
        row = CreateFrame("Button", nil, menu)
        row:SetHeight(MENU_ROW)
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - (i - 1) * MENU_ROW)
        row:SetPoint("RIGHT", menu, "RIGHT", -6, 0)
        local glow = row:CreateTexture(nil, "HIGHLIGHT")
        glow:SetAllPoints()
        glow:SetColorTexture(1, 1, 1, 0.12)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.text:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(self)
            if self.value == nil then return end
            menu:Hide()
            onPick(self.value)
        end)
        dropdown.rows[i] = row
        return row
    end

    function dropdown:Draw()
        local shown = math.min(#values, MENU_ROWS)
        self.offset = math.max(0, math.min(self.offset, #values - shown))
        for i = 1, shown do
            local entry = values[i + self.offset]
            local row = Row(i)
            if entry.header then
                row.value = nil
                row.text:SetText("|cff9d7cff" .. entry.header .. "|r")
                row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
            else
                row.value = entry.value
                local mark = (entry.value == self.value) and "|cffffd100> |r" or "   "
                row.text:SetText(mark .. entry.text)
                row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            end
            row:Show()
        end
        for i = shown + 1, #self.rows do self.rows[i]:Hide() end
        menu:SetHeight(shown * MENU_ROW + 12)
    end

    menu:SetScript("OnMouseWheel", function(_, delta)
        dropdown.offset = dropdown.offset - (delta or 0) * 3
        dropdown:Draw()
    end)

    function dropdown:Open()
        -- Scrolled so the current choice is in view.
        for i, entry in ipairs(values) do
            if entry.value == self.value and i > MENU_ROWS then self.offset = i - MENU_ROWS end
        end
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
        self:Draw()
        menu:Show()
        openDropdown = self
    end

    function dropdown:SetValue(value)
        self.value = value
        local label = tostring(value or "")
        for _, entry in ipairs(values) do
            if not entry.header and entry.value == value then label = entry.text end
        end
        self.button:SetText(label)
        if menu:IsShown() then self:Draw() end
    end

    function dropdown:SetEnabled(enabled)
        self.button:SetEnabled(enabled)
        if not enabled then menu:Hide() end
    end

    -- For the tests, which pick as a player would.
    function dropdown:Pick(value)
        onPick(value)
    end

    return dropdown
end

-- Fonts to pick from: the game's own, and any LibSharedMedia carries when
-- another addon has loaded it. Filled in place, so a dropdown built from
-- this table sees fonts registered after it was made.
local FONT_VALUES = {}
local function RefreshFonts()
    wipe(FONT_VALUES)
    FONT_VALUES[1] = { text = "Game default", value = "" }
    local builtin = {
        { "Friz Quadrata", "Fonts\\FRIZQT__.TTF" }, { "Arial Narrow", "Fonts\\ARIALN.TTF" },
        { "Morpheus", "Fonts\\MORPHEUS.TTF" }, { "Skurri", "Fonts\\SKURRI.TTF" },
    }
    local seen = {}
    for _, font in ipairs(builtin) do
        FONT_VALUES[#FONT_VALUES + 1] = { text = font[1], value = font[2] }
        seen[font[2]] = true
    end
    local stub = _G.LibStub
    local ok, media = pcall(function() return stub and stub("LibSharedMedia-3.0", true) end)
    if ok and media and type(media.List) == "function" then
        local okL, names = pcall(media.List, media, "font")
        for _, name in ipairs(okL and names or {}) do
            local okF, path = pcall(media.Fetch, media, "font", name)
            if okF and path and not seen[path] then
                FONT_VALUES[#FONT_VALUES + 1] = { text = name, value = path }
                seen[path] = true
            end
        end
    end
end
RefreshFonts()
ns.RefreshFonts = RefreshFonts

-- The game's color picker, opened on a hex color; `done` hears each change.
local function PickColour(hex, done)
    local picker = _G.ColorPickerFrame
    if not picker then ns.Print("this client has no color picker.") return end
    hex = (hex and hex ~= "") and hex or "ffffff"
    local r = (tonumber(hex:sub(1, 2), 16) or 255) / 255
    local g = (tonumber(hex:sub(3, 4), 16) or 255) / 255
    local b = (tonumber(hex:sub(5, 6), 16) or 255) / 255
    local function ToHex(cr, cg, cb)
        return string.format("%02x%02x%02x", math.floor(cr * 255 + 0.5),
            math.floor(cg * 255 + 0.5), math.floor(cb * 255 + 0.5))
    end
    local function Current()
        local ok, cr, cg, cb = pcall(picker.GetColorRGB, picker)
        if ok and cr then done(ToHex(cr, cg, cb)) end
    end
    local function Cancel() done(hex) end
    if type(picker.SetupColorPickerAndShow) == "function" then
        pcall(picker.SetupColorPickerAndShow, picker,
            { r = r, g = g, b = b, hasOpacity = false, swatchFunc = Current, cancelFunc = Cancel })
        return
    end
    picker.hasOpacity = false
    picker.func, picker.swatchFunc, picker.cancelFunc = Current, Current, Cancel
    picker.previousValues = { r, g, b }
    pcall(picker.SetColorRGB, picker, r, g, b)
    if type(_G.ShowUIPanel) == "function" then pcall(_G.ShowUIPanel, picker) else picker:Show() end
end
ns.PickColour = PickColour

local sliderSerial = 0
local function Slider(parent, label, low, high, step, onChange)
    sliderSerial = sliderSerial + 1
    local name = "ChairAurasSlider" .. sliderSerial
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetWidth(180)
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(step)
    -- Not on every build, and a missing setter must not cost us the slider.
    pcall(slider.SetObeyStepOnDrag, slider, true)

    slider.labelText = slider.Text or _G[name .. "Text"]
    local lowText  = slider.Low  or _G[name .. "Low"]
    local highText = slider.High or _G[name .. "High"]
    if lowText then lowText:SetText(low) end
    if highText then highText:SetText(high) end

    slider.prefix = label
    slider.step = step
    slider:SetScript("OnValueChanged", function(self, value)
        -- To the step: whole numbers, or tenths for a custom option that
        -- steps by 0.1.
        local by = tonumber(self.step) or 1
        if by >= 1 then
            value = math.floor(value + 0.5)
        else
            value = math.floor(value / by + 0.5) * by
        end
        if self.labelText then
            self.labelText:SetText(self.prefix .. ": " .. tostring(value))
        end
        if not self.settingProgrammatically then onChange(value) end
    end)

    function slider:SetDisplayValue(value)
        self.settingProgrammatically = true
        self:SetValue(value)
        if self.labelText then
            self.labelText:SetText(self.prefix .. ": " .. math.floor(value + 0.5))
        end
        self.settingProgrammatically = nil
    end

    return slider
end

local function EditBox(parent, width, onEnter, commitOnFocusLost)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function(self)
        onEnter(self:GetText())
        self:ClearFocus()
    end)
    box:SetScript("OnEscapePressed", function(self)
        -- Escape means "forget it", and clearing focus is what fires the
        -- commit below, so the two have to agree about what just happened.
        self.abandoning = true
        self:ClearFocus()
        Config:Refresh()
    end)
    if commitOnFocusLost then
        -- Typing a name and clicking away is the same intention as typing a
        -- name and pressing Enter. Losing it to the click is the kind of thing
        -- that teaches people to distrust a text field.
        box:SetScript("OnEditFocusLost", function(self)
            if self.abandoning then
                self.abandoning = nil
                return
            end
            onEnter(self:GetText())
        end)
    end
    return box
end

-- Anything that can be dropped on. The cursor payload is read through the same
-- shared reader /chair auras cursor uses, so the two cannot disagree about what this
-- client puts there.
local function AcceptsSpellDrop(frame, callback)
    local function take()
        local spellID, what = ns.SpellFromCursor()
        if what ~= "spell" then return end
        ClearCursor()
        if spellID then
            callback(spellID)
        else
            ns.Print("could not read a spell ID off the cursor.")
        end
    end
    frame:SetScript("OnReceiveDrag", take)
    frame:HookScript("OnMouseDown", take)
end

-------------------------------------------------------------------------------
-- Selection
-------------------------------------------------------------------------------

local function Current()
    return ns.FindAura(selectedID)
end

-- Every edit lands here: store it, rebuild what depends on it, then redraw both
-- the tree and the editor so nothing can show a stale answer.
local function Commit(rebuild)
    if rebuild then
        ns.Engine:Rebuild()
    else
        ns.Display:Layout()
    end
    ns.RequestUpdate()
    Config:Refresh()
end

-------------------------------------------------------------------------------
-- The tree
-------------------------------------------------------------------------------
-- Groups, then their children indented under them, then everything with no
-- parent. One flat list of rows drawn from the tree, because a real tree widget
-- would need the scroll templates to nest and these do not.

local TYPE_TAG = {
    icon    = "",
    group   = "|cff40c4ff[group]|r ",
    dynamic = "|cff40c4ff[dynamic]|r ",
}

-- Several auras at once: ctrl-click adds one to the selection. The one open
-- in the editor is always part of it.
local multi = {}
function Config.__multi() return multi end

local function TreeOrder()
    local order = {}

    -- The search box: what matches, and the groups it sits in.
    local keep
    local query = (Config.search or ""):lower()
    if query ~= "" then
        keep = {}
        for _, aura in ipairs(ns.GetAuras()) do
            local label = ns.Engine:Describe(aura)
            local text = (tostring(label or "") .. " " .. tostring(aura.name or "")):lower()
            if text:find(query, 1, true) then
                local cursor, seen = aura, {}
                while cursor and not seen[cursor.id] do
                    seen[cursor.id] = true
                    keep[cursor.id] = true
                    cursor = cursor.parent and ns.FindAura(cursor.parent)
                end
            end
        end
    end

    local function Walk(parentID, depth)
        for _, aura in ipairs(ns.Children(parentID)) do
            if not keep or keep[aura.id] then
                order[#order + 1] = { aura = aura, depth = depth }
                if ns.IsGroup(aura) then Walk(aura.id, depth + 1) end
            end
        end
    end

    Walk(nil, 0)
    return order
end

-- Defined further down, with the drop logic they belong to.
local ShowDropMark, AutoScroll

local function CreateRow(index)
    local row = CreateFrame("Button", nil, listChild)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", listChild, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetColorTexture(0.25, 0.77, 1, 0.22)
    row.selection:Hide()

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.10)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.text = Text(row, "", "GameFontHighlightSmall")
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT")

    -- Dragging a row moves the aura: onto a group to put it inside, onto
    -- anything else to sit beside it. The row under the cursor is found by
    -- position rather than by a drop target on each row, because a row being
    -- dragged is not a row that can be hovered.
    row:RegisterForDrag("LeftButton")

    row:SetScript("OnDragStart", function(self)
        Config.dragging = self.auraID
        self.selection:Show()
        self:SetScript("OnUpdate", function()
            AutoScroll()
            ShowDropMark()
        end)
    end)

    row:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if Config.dropLine then Config.dropLine:Hide() end
        if Config.dropGlow then Config.dropGlow:Hide() end
        local dragged = Config.dragging
        Config.dragging = nil
        if not dragged then return end

        local target, where = Config:RowUnderCursor()
        local aura = ns.FindAura(dragged)
        if aura and where == "end" then
            if ns.MoveAuraToEnd(aura) then
                selectedID = dragged
                Commit(true)
                return
            end
        elseif target and target ~= dragged then
            local onto = ns.FindAura(target)
            local moving = Config:SelectedList()
            if multi[dragged] and #moving > 1 and onto and not multi[target] then
                -- In list order; "after" goes last first so they keep it.
                local moved = false
                local from, to, step = 1, #moving, 1
                if where == "after" then from, to, step = #moving, 1, -1 end
                for i = from, to, step do
                    if ns.MoveAura(moving[i], onto, where) then moved = true end
                end
                if moved then Commit(true) return end
            elseif aura and onto and ns.MoveAura(aura, onto, where) then
                selectedID = dragged
                Commit(true)
                return
            end
        end

        Config:Refresh()
    end)

    row:SetScript("OnClick", function(self)
        local ctrl = type(IsControlKeyDown) == "function" and IsControlKeyDown()
        if ctrl and selectedID and self.auraID ~= selectedID then
            multi[selectedID] = true
            multi[self.auraID] = (not multi[self.auraID]) or nil
            Config:Refresh()
            return
        end
        wipe(multi)
        Config:Select(self.auraID)
    end)

    rows[index] = row
    return row
end

local function RefreshTree()
    local order = TreeOrder()

    for index, entry in ipairs(order) do
        local row = rows[index] or CreateRow(index)
        local aura = entry.aura
        local indent = 4 + entry.depth * 14

        row.auraID = aura.id
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", indent, 0)
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)

        local label, icon = ns.Engine:Describe(aura)
        local chosen = (aura.display or {}).icon or (aura.display or {}).iconSpell

        -- A group with an icon of its own wears it; one without stays a faint
        -- placeholder, because a bright question mark next to five real icons
        -- reads as something broken rather than as something unset.
        row.icon:SetTexture(icon)
        row.icon:SetAlpha((ns.IsGroup(aura) and not chosen) and 0.35 or 1)

        local state = ns.Engine.states and ns.Engine.states[aura.id]
        local suffix = ""
        if state and not state.loaded then
            suffix = "  |cff888888not loaded|r"
        elseif state and state.unknown then
            -- Worth saying out loud: what is on screen is the last thing the
            -- client would admit to, not what is true this second.
            suffix = "  |cffddaa44can't read|r"
        elseif state and state.shown then
            suffix = "  |cff66dd66on|r"
        end

        row.text:SetText((TYPE_TAG[aura.type or "icon"] or "") .. label .. suffix)
        row.selection:SetShown(aura.id == selectedID or multi[aura.id] == true)
        row:Show()
    end

    for index = #order + 1, #rows do
        rows[index]:Hide()
    end

    listChild:SetHeight(math.max(#order * ROW_HEIGHT, 1))
end

-------------------------------------------------------------------------------
-- Reading and writing an aura
-------------------------------------------------------------------------------
-- Declared above everything that calls them, which is not a matter of taste:
-- a local is in scope only after its own line, so a widget callback written
-- further up that names SetDisplay would be reading a nil global instead.

local function TriggerOf(aura) return ns.TriggerTable(aura, currentTrigger) end
local function DisplayOf(aura) return ns.SubTable(aura, "display") end
local function LoadOf(aura) return ns.SubTable(aura, "load") end
local function ActionsOf(aura) return ns.SubTable(aura, "actions") end

-- How an aura looks is a question a group can answer for everything inside it.
--
-- Set on an icon this is just a field; set on a group it is set on every
-- descendant as well, so "make them all 30 pixels" is one edit rather than six.
-- The group keeps the value too, which is what a child added later inherits --
-- otherwise the seventh icon would arrive at the default and look wrong next to
-- the six that were changed.
--
-- Layout is deliberately not part of this. Growth, spacing, wrapping and sort
-- describe how a group arranges what it holds, and a group inside a group
-- running the other way is a thing people want rather than a mistake.
-- Some settings are tables -- a set of classes, a level range -- and handing
-- the same table to six children would make them one setting wearing six
-- names: editing any of them would edit all of them, including the group's own
-- copy. Each gets its own.
local function CopyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = CopyValue(inner) end
    return out
end

-- What a group hands down, and what it keeps.
--
-- Size, dimming, swipes and the rest describe a house style and are worth
-- setting once for everything inside. An icon is not: it is how you tell one
-- thing from another. A group's icon is what names it in the list -- a group
-- draws nothing on screen, so this is the only place it has a face at all --
-- and stamping that face onto all six children would undo the only thing they
-- had going for them, which is looking like what they watch.
local PERSONAL = {
    icon = true,
    iconSpell = true,
}

local function SetDisplay(aura, key, value)
    DisplayOf(aura)[key] = value

    if ns.IsGroup(aura) and not PERSONAL[key] then
        for _, child in ipairs(ns.Descendants(aura.id)) do
            DisplayOf(child)[key] = CopyValue(value)
        end
    end
end

-- When an aura loads is the same kind of question as how it looks, and a group
-- answers it for everything inside the same way: the setting lands on every
-- descendant, and the group keeps a copy so anything added later starts with
-- it. A child can still be changed afterwards -- the group sets them, it does
-- not own them.
--
-- The group's own copy is never evaluated: only icons are, so a group with a
-- load condition and no children is simply a template nobody has used yet.
local function SetLoad(aura, key, value)
    LoadOf(aura)[key] = value

    if ns.IsGroup(aura) then
        for _, child in ipairs(ns.Descendants(aura.id)) do
            LoadOf(child)[key] = CopyValue(value)
        end
    end
end

-- What to show for a group: its own answer, which is also what its children
-- were last told.
local function GetDisplay(aura, key)
    return ns.DisplayField(aura, key)
end

-------------------------------------------------------------------------------
-- Field rendering
-------------------------------------------------------------------------------
-- A pane is a list of field descriptions. Each one knows how to read and write
-- its own value and, where it matters, whether it applies to the aura in hand --
-- a control that does not apply is greyed rather than hidden, because a widget
-- that vanishes reads as a bug.

local function BuildField(pane, field)
    local widget = { field = field }
    local host = CreateFrame("Frame", nil, pane)
    host:SetSize(PANE_W, 24)
    widget.host = host

    if field.kind == "check" then
        widget.check = CheckBox(host, field.label, function(checked)
            local aura = Current()
            if aura then field.set(aura, checked) end
        end)
        widget.check:SetPoint("LEFT", host, "LEFT", 0, 0)
        if field.tip then Tooltip(widget.check, field.label, field.tip) end

        function widget:Read(aura)
            self.check:SetChecked(field.get(aura) and true or false)
        end
        function widget:SetEnabled(enabled)
            self.check:SetEnabled(enabled)
            self.check.label:SetTextColor(enabled and 1 or 0.4,
                                          enabled and 1 or 0.4,
                                          enabled and 1 or 0.4)
        end

    elseif field.kind == "sound" then
        host:SetHeight(44)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label

        local current = Text(host, "none", "GameFontHighlightSmall")
        current:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -6)
        current:SetWidth(150)
        current:SetJustifyH("LEFT")
        widget.current = current

        local choose = Button(host, "Choose...", 90, function()
            local aura = Current()
            if not aura then return end
            local value = field.get and field.get(aura) or ns.ActionField(aura, field.key)
            ns.Sounds:Open(value, ns.ActionField(aura, "channel"),
                           function(picked) field.set(aura, picked) end)
        end)
        choose:SetPoint("LEFT", current, "RIGHT", 6, 0)
        widget.choose = choose

        local test = Button(host, "Play", 56, function()
            local aura = Current()
            if not aura then return end
            local value = field.get and field.get(aura) or ns.ActionField(aura, field.key)
            if not ns.Sounds:Preview(value, ns.ActionField(aura, "channel")) then
                ns.Print("nothing played -- pick one from the list, or check the path.")
            end
        end)
        test:SetPoint("LEFT", choose, "RIGHT", 4, 0)
        widget.test = test

        local clear = Button(host, "Clear", 56, function()
            local aura = Current()
            if aura then field.set(aura, "") end
        end)
        clear:SetPoint("LEFT", test, "RIGHT", 4, 0)
        widget.clear = clear
        if field.tip then Tooltip(label, field.label, field.tip) end

        function widget:Read(aura)
            local value = field.get and field.get(aura) or ns.ActionField(aura, field.key)
            self.current:SetText(ns.Sounds:Label(value))
        end
        function widget:SetEnabled(enabled)
            self.choose:SetEnabled(enabled)
            self.test:SetEnabled(enabled)
            self.clear:SetEnabled(enabled)
        end

    elseif field.kind == "strip" then
        -- A numbered row: one button per item (condition, check, change), +
        -- to add one, Remove, and optionally up and down to reorder. What the
        -- numbers stand for, and what + and Remove do, come from the field.
        host:SetHeight(44)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label
        if field.tip then Tooltip(label, field.label, field.tip) end
        local MAX = field.max or 10
        widget.numbers = {}
        for i = 1, MAX do
            local button = Button(host, tostring(i), 26, function()
                field.select(i)
                Config:Refresh()
            end)
            if i == 1 then
                button:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
            else
                button:SetPoint("LEFT", widget.numbers[i - 1], "RIGHT", 2, 0)
            end
            widget.numbers[i] = button
        end
        widget.add = Button(host, "+", 26, function()
            local aura = Current()
            if not aura or field.count(aura) >= MAX then return end
            field.add(aura)
            Commit(false)
        end)
        widget.remove = Button(host, "Remove", 64, function()
            local aura = Current()
            if aura and field.count(aura) > 0 then
                field.remove(aura)
                Commit(false)
            end
        end)
        if field.move then
            widget.up = Button(host, "^", 22, function()
                local aura = Current()
                if aura then field.move(aura, -1) Commit(false) end
            end)
            widget.down = Button(host, "v", 22, function()
                local aura = Current()
                if aura then field.move(aura, 1) Commit(false) end
            end)
            Tooltip(widget.up, "Move up", "Earlier conditions are overridden by later ones.")
        end
        widget.empty = Text(host, field.empty or "", "GameFontDisableSmall")

        function widget:Read(aura)
            local count = field.count(aura)
            local current = field.current()
            if current > count then current = math.max(count, 1) field.select(current) end
            for i, button in ipairs(self.numbers) do
                button:SetShown(i <= count)
                if i == current then button:LockHighlight() else button:UnlockHighlight() end
            end
            local anchor = count > 0 and self.numbers[math.min(count, #self.numbers)] or nil
            self.add:ClearAllPoints()
            if anchor then
                self.add:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
            else
                self.add:SetPoint("TOPLEFT", self.label, "BOTTOMLEFT", 0, -4)
            end
            self.remove:ClearAllPoints()
            self.remove:SetPoint("LEFT", self.add, "RIGHT", 4, 0)
            self.remove:SetShown(count > 0)
            local last = self.remove
            if self.up then
                self.up:ClearAllPoints()
                self.up:SetPoint("LEFT", self.remove, "RIGHT", 4, 0)
                self.down:ClearAllPoints()
                self.down:SetPoint("LEFT", self.up, "RIGHT", 2, 0)
                self.up:SetShown(count > 1)
                self.down:SetShown(count > 1)
                if count > 1 then last = self.down end
            end
            self.empty:ClearAllPoints()
            self.empty:SetPoint("LEFT", count > 0 and last or self.add, "RIGHT", 8, 0)
            self.empty:SetShown(count == 0)
        end
        function widget:SetEnabled(enabled)
            self.add:SetEnabled(enabled)
            self.remove:SetEnabled(enabled)
        end

    elseif field.kind == "triggers" then
        -- The strip above the Trigger tab: one button per trigger, + to add
        -- one (a copy of the one open), Remove, and -- once there is more than
        -- one -- how they combine and which one the aura's timer comes from.
        host:SetHeight(76)
        local label = Text(host, "Triggers", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label

        widget.numbers = {}
        local MAX_SHOWN = 8
        for i = 1, MAX_SHOWN do
            local button = Button(host, tostring(i), 26, function()
                currentTrigger = i
                Config:Refresh()
            end)
            if i == 1 then
                button:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
            else
                button:SetPoint("LEFT", widget.numbers[i - 1], "RIGHT", 2, 0)
            end
            widget.numbers[i] = button
        end
        widget.add = Button(host, "+", 26, function()
            local aura = Current()
            if not aura or ns.TriggerCount(aura) >= MAX_SHOWN then return end
            currentTrigger = ns.AddTrigger(aura, ns.Trigger(aura, currentTrigger))
            Commit(true)
        end)
        Tooltip(widget.add, "Add a trigger", "A copy of the one open, to change from there.")
        widget.remove = Button(host, "Remove", 64, function()
            local aura = Current()
            if aura and ns.RemoveTrigger(aura, currentTrigger) then
                currentTrigger = math.max(1, currentTrigger - 1)
                Commit(true)
            end
        end)

        local showLabel = Text(host, "Show when", "GameFontNormalSmall")
        showLabel:SetPoint("TOPLEFT", widget.numbers[1], "BOTTOMLEFT", 0, -8)
        widget.showLabel = showLabel
        local modeHost = CreateFrame("Frame", nil, host)
        modeHost:SetSize(220, 22)
        modeHost:SetPoint("LEFT", showLabel, "RIGHT", 6, 0)
        widget.mode = ButtonGroup(modeHost, {
            { text = "All", value = "all" }, { text = "Any", value = "any" },
            { text = "Custom", value = "custom" } }, 60, function(value)
            local aura = Current()
            if not aura then return end
            ns.NormalizeTriggers(aura)
            aura.triggers = aura.triggers or { {} }
            aura.triggers.disjunctive = value
            Commit(false)
        end)
        Tooltip(showLabel, "Show when",
            "All: every trigger is met. Any: at least one is. Custom: a Lua function"
            .. " decides, given the triggers' answers as a list -- trigger[1] and so on.")

        widget.info = Button(host, "Info: first active", 130, function()
            local aura = Current()
            if not aura then return end
            local count = ns.TriggerCount(aura)
            local mode = ns.ActiveTriggerMode(aura)
            local nextMode = (mode == -10) and 1 or (mode + 1)
            if nextMode > count then nextMode = -10 end
            ns.NormalizeTriggers(aura)
            aura.triggers = aura.triggers or { {} }
            aura.triggers.activeTriggerMode = nextMode
            Commit(false)
        end)
        widget.info:SetPoint("LEFT", modeHost, "RIGHT", 4, 0)
        Tooltip(widget.info, "Which trigger the aura shows",
            "The timer, stacks, name and icon come from one trigger: the first one"
            .. " that is met, or the one picked here.")

        function widget:Read(aura)
            local count = ns.TriggerCount(aura)
            if currentTrigger > count then currentTrigger = count end
            for i, button in ipairs(self.numbers) do
                button:SetShown(i <= count)
                if i == currentTrigger then button:LockHighlight() else button:UnlockHighlight() end
            end
            self.add:ClearAllPoints()
            self.add:SetPoint("LEFT", self.numbers[math.min(count, #self.numbers)], "RIGHT", 6, 0)
            self.add:SetShown(count < #self.numbers)
            self.remove:ClearAllPoints()
            self.remove:SetPoint("LEFT", self.add, "RIGHT", 4, 0)
            self.remove:SetEnabled(count > 1)
            self.mode:SetValue(ns.TriggerMode(aura))
            local mode = ns.ActiveTriggerMode(aura)
            self.info:SetText(mode == -10 and "Info: first active" or ("Info: trigger " .. mode))
            local several = count > 1
            self.mode:SetEnabled(several)
            self.info:SetEnabled(several)
        end
        function widget:SetEnabled(enabled)
            for _, button in ipairs(self.numbers) do button:SetEnabled(enabled) end
            self.add:SetEnabled(enabled)
            self.label:SetTextColor(enabled and 1 or 0.4, enabled and 0.82 or 0.4, enabled and 0 or 0.4)
        end

    elseif field.kind == "code" then
        -- Lua, several lines of it. Saved when the box loses focus or Save is
        -- pressed; what the compiler or the last run said sits underneath.
        host:SetHeight(field.height or 150)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label
        if field.tip then Tooltip(label, field.label, field.tip) end

        local back = CreateFrame("Frame", nil, host)
        back:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
        back:SetSize(PANE_W - 24, (field.height or 150) - 44)
        local fill = back:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetColorTexture(0, 0, 0, 0.5)

        local scroll = CreateFrame("ScrollFrame", nil, back)
        scroll:SetPoint("TOPLEFT", 4, -4)
        scroll:SetPoint("BOTTOMRIGHT", -4, 4)
        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject("ChatFontNormal")
        box:SetWidth(PANE_W - 36)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnTabPressed", function(self) self:Insert("    ") end)
        box:SetScript("OnTextChanged", function(_, byUser) if byUser then widget.ran = nil end end)
        scroll:SetScrollChild(box)
        back:EnableMouse(true)
        back:SetScript("OnMouseDown", function() box:SetFocus() end)
        widget.box = box

        local function Save()
            local aura = Current()
            if aura then field.set(aura, box:GetText()) end
        end
        box:SetScript("OnEditFocusLost", Save)
        local save = Button(host, "Save", 50, function() box:ClearFocus() Save() end)
        save:SetPoint("TOPLEFT", back, "BOTTOMLEFT", 0, -4)
        widget.save = save
        -- Run: compile it and call it once, in the sandbox, with no arguments,
        -- and say what came back -- the quickest way to see a typo.
        local run = Button(host, "Run", 50, function()
            local aura = Current()
            if not aura then return end
            box:ClearFocus()
            local source = box:GetText()
            if aura.untrusted then
                widget.ran = "|cffff5555imported code: approve it first|r"
            else
                local fn, err = ns.Env:Compile(source, field.label or "code")
                if not fn then
                    widget.ran = "|cffff5555" .. tostring(err) .. "|r"
                else
                    local ok, a, b, c = ns.Env:Call(aura, fn)
                    if ok then
                        local parts = {}
                        for _, value in ipairs({ a, b, c }) do parts[#parts + 1] = ns.SafeText(tostring(value)) or "?" end
                        widget.ran = "|cff66dd66ran|r" .. (#parts > 0 and (": returned " .. table.concat(parts, ", ")) or "")
                    else
                        widget.ran = "|cffff5555" .. tostring(a) .. "|r"
                    end
                end
            end
            widget.status:SetText(widget.ran)
        end)
        run:SetPoint("LEFT", save, "RIGHT", 4, 0)
        widget.run = run
        Tooltip(run, "Run", "Runs it once now, with no arguments, and says what it returned or where it failed.")
        local status = Text(host, "", "GameFontDisableSmall")
        status:SetPoint("LEFT", run, "RIGHT", 8, 0)
        status:SetWidth(PANE_W - 140)
        status:SetJustifyH("LEFT")
        widget.status = status

        function widget:Read(aura)
            if not self.box:HasFocus() then
                self.box:SetText(field.get(aura) or "")
                self.box:SetCursorPosition(0)
            end
            local err = field.error and field.error(aura)
            if err then
                self.status:SetText("|cffff5555" .. tostring(err) .. "|r")
            elseif self.ran then
                self.status:SetText(self.ran)
            else
                self.status:SetText(field.hint or "")
            end
        end
        function widget:SetEnabled(enabled)
            self.box:SetEnabled(enabled)
            self.save:SetEnabled(enabled)
            self.run:SetEnabled(enabled)
            self.box:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5)
            self.label:SetTextColor(enabled and 1 or 0.4, enabled and 0.82 or 0.4, enabled and 0 or 0.4)
        end

    elseif field.kind == "button" then
        widget.button = Button(host, field.text or field.label, 110, function()
            local aura = Current()
            if aura then field.click(aura) end
        end)
        widget.button:SetPoint("LEFT", host, "LEFT", 0, 0)
        if field.tip then Tooltip(widget.button, field.label, field.tip) end

        function widget:Read() end
        function widget:SetEnabled(enabled) self.button:SetEnabled(enabled) end

    elseif field.kind == "icon" then
        host:SetHeight(44)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label

        local preview = CreateFrame("Frame", nil, host)
        preview:SetSize(32, 32)
        preview:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -2)
        preview.texture = preview:CreateTexture(nil, "ARTWORK")
        preview.texture:SetAllPoints()
        preview.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        widget.preview = preview

        local choose = Button(host, "Choose...", 90, function()
            local aura = Current()
            if not aura then return end
            ns.Icons:Open(function(texture)
                SetDisplay(aura, "icon", texture)
                Commit(true)
            end)
        end)
        choose:SetPoint("LEFT", preview, "RIGHT", 8, 0)
        widget.choose = choose

        local clear = Button(host, "Clear", 60, function()
            local aura = Current()
            if not aura then return end
            SetDisplay(aura, "icon", nil)
            Commit(true)
        end)
        clear:SetPoint("LEFT", choose, "RIGHT", 4, 0)
        widget.clear = clear
        if field.tip then Tooltip(label, field.label, field.tip) end

        function widget:Read(aura)
            local _, icon = ns.Engine:Describe(aura)
            self.preview.texture:SetTexture(icon)
            self.clear:SetEnabled((aura.display or {}).icon ~= nil)
        end
        function widget:SetEnabled(enabled)
            self.choose:SetEnabled(enabled)
        end

    elseif field.kind == "tristate" then
        -- One box, three answers, because the question has three: must be so,
        -- must not be, and do not care. Clicking walks round them in that
        -- order, which is the order people try them in.
        --
        -- The tick and the cross are both drawn from the client's own art, but
        -- the words carry the state as well. Art can be missing on a client
        -- like this one, and a box that looks empty for two different answers
        -- is worse than no box at all.
        widget.check = CheckBox(host, field.label, function() end)
        widget.check:SetPoint("LEFT", host, "LEFT", 0, 0)
        widget.check:SetScript("OnClick", function()
            local aura = Current()
            if not aura then return end
            field.cycle(aura)
        end)
        if field.tip then Tooltip(widget.check, field.label, field.tip) end

        local YES = "Interface\\Buttons\\UI-CheckBox-Check"
        local NO  = "Interface\\RaidFrame\\ReadyCheck-NotReady"

        function widget:Read(aura)
            local value = field.get(aura)
            local check = self.check

            check:SetChecked(value ~= nil)
            -- SetCheckedTexture is given a path rather than a texture object,
            -- and a path this client does not have simply draws nothing, so
            -- the colour and the label are what actually carry the answer.
            if value == true then
                pcall(check.SetCheckedTexture, check, YES)
                local texture = check.GetCheckedTexture and check:GetCheckedTexture()
                if texture then texture:SetVertexColor(0.4, 1, 0.4) end
                check.label:SetText(field.label .. "  |cff66dd66yes|r")
            elseif value == false then
                pcall(check.SetCheckedTexture, check, NO)
                local texture = check.GetCheckedTexture and check:GetCheckedTexture()
                if texture then texture:SetVertexColor(1, 0.4, 0.4) end
                check.label:SetText(field.label .. "  |cffdd6666no|r")
            else
                pcall(check.SetCheckedTexture, check, YES)
                local texture = check.GetCheckedTexture and check:GetCheckedTexture()
                if texture then texture:SetVertexColor(1, 1, 1) end
                check.label:SetText("|cff808080" .. field.label .. "|r")
            end
        end

        function widget:SetEnabled(enabled)
            self.check:SetEnabled(enabled)
        end

    elseif field.kind == "choice" then
        host:SetHeight(44)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label

        local groupHost = CreateFrame("Frame", nil, host)
        groupHost:SetSize(PANE_W, 22)
        groupHost:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 2, -4)
        local function pick(value)
            local aura = Current()
            if aura then field.set(aura, value) end
        end
        if field.dropdown then
            -- Too many to lay out as buttons: a list that opens instead.
            widget.group = Dropdown(groupHost, field.width or 200, field.values, pick)
            widget.dropdown = widget.group
        else
            local width = field.width or 84
            local perRow
            if field.wrap or #field.values * (width + 4) > PANE_W then
                perRow = math.max(1, math.floor((PANE_W - 8) / (width + 4)))
            end
            widget.group = ButtonGroup(groupHost, field.values, width, pick, perRow)
            host:SetHeight(18 + widget.group.rows * 26)
        end
        if field.tip then Tooltip(label, field.label, field.tip) end

        function widget:Read(aura) self.group:SetValue(field.get(aura)) end
        function widget:SetEnabled(enabled)
            self.group:SetEnabled(enabled)
            self.label:SetTextColor(enabled and 1 or 0.4,
                                    enabled and 0.82 or 0.4,
                                    enabled and 0 or 0.4)
        end

    elseif field.kind == "position" then
        -- A slider with a box beside it: drag for rough, type for exact. The
        -- range is half the screen either way of the centre, so the slider
        -- covers everywhere the aura can go; a typed number can go past it.
        host:SetHeight(42)
        local half = 1000
        local okW, width = pcall(UIParent.GetWidth, UIParent)
        local okH, height = pcall(UIParent.GetHeight, UIParent)
        width, height = okW and ns.SafeNumber(width), okH and ns.SafeNumber(height)
        if field.axis == "x" and width and width > 0 then half = math.floor(width / 2) end
        if field.axis == "y" and height and height > 0 then half = math.floor(height / 2) end
        widget.slider = Slider(host, field.label, -half, half, 1, function(value)
            local aura = Current()
            if aura then field.set(aura, value) end
        end)
        widget.slider:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -12)
        widget.box = EditBox(host, 56, function(text)
            local aura = Current()
            local value = tonumber(text)
            if aura and value then field.set(aura, math.floor(value + 0.5)) end
            Config:Refresh()
        end, true)
        widget.box:SetPoint("LEFT", widget.slider, "RIGHT", 16, 0)
        if field.tip then Tooltip(widget.box, field.label, field.tip) end

        -- One pixel a click, for the last nudge into place.
        local function Nudge(step)
            local aura = Current()
            if aura then field.set(aura, (field.get(aura) or 0) + step) end
        end
        widget.minus = Button(host, "-", 22, function() Nudge(-1) end)
        widget.minus:SetPoint("LEFT", widget.box, "RIGHT", 6, 0)
        widget.plus = Button(host, "+", 22, function() Nudge(1) end)
        widget.plus:SetPoint("LEFT", widget.minus, "RIGHT", 2, 0)

        function widget:Read(aura)
            local value = field.get(aura) or 0
            self.slider:SetDisplayValue(math.max(-half, math.min(half, value)))
            if self.slider.labelText then
                self.slider.labelText:SetText(field.label .. ": " .. value)
            end
            if not self.box:HasFocus() then self.box:SetText(tostring(value)) end
        end
        function widget:SetEnabled(enabled)
            self.slider:SetEnabled(enabled)
            self.box:SetEnabled(enabled)
            self.minus:SetEnabled(enabled)
            self.plus:SetEnabled(enabled)
        end

    elseif field.kind == "slider" then
        host:SetHeight(42)
        widget.slider = Slider(host, field.label, field.min, field.max,
            field.step or 1, function(value)
                local aura = Current()
                if aura then field.set(aura, value) end
            end)
        widget.slider:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -12)

        function widget:Read(aura) self.slider:SetDisplayValue(field.get(aura) or field.min) end
        function widget:SetEnabled(enabled) self.slider:SetEnabled(enabled) end

    elseif field.kind == "text" or field.kind == "spell" or field.kind == "item" then
        host:SetHeight(44)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label

        local box = EditBox(host, field.width or 240, function(text)
            local aura = Current()
            if aura then field.set(aura, text) end
        end)
        box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -4)
        widget.box = box
        if field.tip then Tooltip(label, field.label, field.tip) end

        if field.kind == "item" then
            local function takeItem()
                local what, itemID = GetCursorInfo()
                if what ~= "item" then return end
                ClearCursor()
                local aura = Current()
                if aura and itemID then field.set(aura, tostring(itemID)) end
            end
            box:SetScript("OnReceiveDrag", takeItem)
            box:HookScript("OnMouseDown", takeItem)
            local set = Button(host, "Set", 44, function()
                local aura = Current()
                if aura then field.set(aura, box:GetText()) end
            end)
            set:SetPoint("LEFT", box, "RIGHT", 6, 0)
            widget.setButton = set
            local hint = Text(host, "or drag an item here", "GameFontDisableSmall")
            hint:SetPoint("LEFT", set, "RIGHT", 8, 0)
        end
        if field.kind == "spell" then
            AcceptsSpellDrop(box, function(spellID)
                local aura = Current()
                if aura then field.set(aura, tostring(spellID)) end
            end)
            local set = Button(host, "Set", 44, function()
                local aura = Current()
                if aura then field.set(aura, box:GetText()) end
            end)
            set:SetPoint("LEFT", box, "RIGHT", 6, 0)
            widget.setButton = set

            local hint = Text(host, "or drag a spell here", "GameFontDisableSmall")
            hint:SetPoint("LEFT", set, "RIGHT", 8, 0)
        end

        function widget:Read(aura)
            if not self.box:HasFocus() then
                self.box:SetText(field.get(aura) or "")
                self.box:SetCursorPosition(0)
            end
        end
        function widget:SetEnabled(enabled)
            self.box:SetEnabled(enabled)
            if self.setButton then self.setButton:SetEnabled(enabled) end
            self.label:SetTextColor(enabled and 1 or 0.4,
                                    enabled and 0.82 or 0.4,
                                    enabled and 0 or 0.4)
        end

    elseif field.kind == "range" then
        host:SetHeight(44)
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label

        local minBox = EditBox(host, 60, function(text)
            local aura = Current()
            if aura then field.set(aura, "min", text) end
        end)
        minBox:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -4)

        local dash = Text(host, "to", "GameFontDisableSmall")
        dash:SetPoint("LEFT", minBox, "RIGHT", 6, 0)

        local maxBox = EditBox(host, 60, function(text)
            local aura = Current()
            if aura then field.set(aura, "max", text) end
        end)
        maxBox:SetPoint("LEFT", dash, "RIGHT", 8, 0)

        widget.minBox, widget.maxBox = minBox, maxBox
        if field.tip then Tooltip(label, field.label, field.tip) end

        function widget:Read(aura)
            local value = field.get(aura) or {}
            if not self.minBox:HasFocus() then
                self.minBox:SetText(value.min and tostring(value.min) or "")
            end
            if not self.maxBox:HasFocus() then
                self.maxBox:SetText(value.max and tostring(value.max) or "")
            end
        end
        function widget:SetEnabled(enabled)
            self.minBox:SetEnabled(enabled)
            self.maxBox:SetEnabled(enabled)
            self.label:SetTextColor(enabled and 1 or 0.4,
                                    enabled and 0.82 or 0.4,
                                    enabled and 0 or 0.4)
        end

    elseif field.kind == "set" then
        local values = field.values()
        local perRow = field.perRow or 3
        local lines = math.max(math.ceil(#values / perRow), 1)
        host:SetHeight(20 + lines * 24)

        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        widget.label = label
        widget.checks = {}
        if field.tip then Tooltip(label, field.label, field.tip) end

        for index, entry in ipairs(values) do
            local column = (index - 1) % perRow
            local line = math.floor((index - 1) / perRow)
            local check = CheckBox(host, entry.text, function(checked)
                local aura = Current()
                if aura then field.set(aura, entry.value, checked) end
            end)
            check:SetPoint("TOPLEFT", host, "TOPLEFT",
                           6 + column * 140, -18 - line * 24)
            check.value = entry.value
            widget.checks[#widget.checks + 1] = check
        end

        function widget:Read(aura)
            local value = field.get(aura) or {}
            for _, check in ipairs(self.checks) do
                check:SetChecked(value[check.value] and true or false)
            end
        end
        function widget:SetEnabled(enabled)
            for _, check in ipairs(self.checks) do
                check:SetEnabled(enabled)
                check.label:SetTextColor(enabled and 1 or 0.4,
                                         enabled and 1 or 0.4,
                                         enabled and 1 or 0.4)
            end
            self.label:SetTextColor(enabled and 1 or 0.4,
                                    enabled and 0.82 or 0.4,
                                    enabled and 0 or 0.4)
        end

    elseif field.kind == "colour" then
        local label = Text(host, field.label, "GameFontNormalSmall")
        label:SetPoint("LEFT", host, "LEFT", 0, 0)
        widget.label = label
        local swatch = CreateFrame("Button", nil, host)
        swatch:SetSize(20, 20)
        swatch:SetPoint("LEFT", label, "RIGHT", 8, 0)
        local edge = swatch:CreateTexture(nil, "BACKGROUND")
        edge:SetAllPoints()
        edge:SetColorTexture(0.8, 0.8, 0.8, 1)
        local fill = swatch:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 2, -2)
        fill:SetPoint("BOTTOMRIGHT", -2, 2)
        widget.swatch, widget.fill = swatch, fill
        swatch:SetScript("OnClick", function()
            local aura = Current()
            if not aura then return end
            PickColour(field.get(aura), function(hex) field.set(aura, hex) end)
        end)
        local reset = Button(host, "Default", 60, function()
            local aura = Current()
            if aura then field.set(aura, nil) end
        end)
        reset:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
        widget.reset = reset
        if field.tip then Tooltip(label, field.label, field.tip) end
        function widget:Read(aura)
            local hex = field.get(aura) or "ffffff"
            local r = (tonumber(hex:sub(1, 2), 16) or 255) / 255
            local g = (tonumber(hex:sub(3, 4), 16) or 255) / 255
            local b = (tonumber(hex:sub(5, 6), 16) or 255) / 255
            self.fill:SetColorTexture(r, g, b, 1)
        end
        function widget:SetEnabled(enabled)
            self.swatch:SetEnabled(enabled)
            self.reset:SetEnabled(enabled)
            self.label:SetTextColor(enabled and 1 or 0.4, enabled and 0.82 or 0.4, enabled and 0 or 0.4)
        end

    elseif field.kind == "authoroptions" then
        -- An aura's custom options (WeakAuras' author options), as the user
        -- sets them: one control each, drawn afresh for whichever aura is
        -- open, since every aura has its own list.
        host:SetHeight(24)
        widget.rows = {}
        widget.empty = Text(host, field.empty or "", "GameFontDisableSmall")
        widget.empty:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -4)
        widget.empty:SetWidth(PANE_W - 20)
        widget.empty:SetJustifyH("LEFT")

        local function Row(i, kind)
            local row = widget.rows[i]
            if row and row.kind == kind then return row end
            if row then row.frame:Hide() end
            row = { kind = kind, height = 24 }
            local frame = CreateFrame("Frame", nil, host)
            frame:SetSize(PANE_W, 24)
            row.frame = frame
            local function Set(value)
                local aura = Current()
                if aura and row.path then field.set(aura, row.path, value) end
            end
            if kind == "toggle" then
                row.check = CheckBox(frame, "", function(checked) Set(checked) end)
                row.check:SetPoint("LEFT", frame, "LEFT", 0, 0)
                row.label = row.check.label
            elseif kind == "range" then
                row.height = 42
                row.slider = Slider(frame, "", 0, 100, 1, function(value) Set(value) end)
                row.slider:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -12)
            elseif kind == "select" then
                row.height = 44
                row.label = Text(frame, "", "GameFontNormalSmall")
                row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                local holder = CreateFrame("Frame", nil, frame)
                holder:SetSize(PANE_W, 22)
                holder:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 2, -4)
                row.values = {}
                row.dropdown = Dropdown(holder, 200, row.values, function(value) Set(value) end)
            elseif kind == "multiselect" then
                row.label = Text(frame, "", "GameFontNormalSmall")
                row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                row.checks = {}
            elseif kind == "color" then
                row.label = Text(frame, "", "GameFontNormalSmall")
                row.label:SetPoint("LEFT", frame, "LEFT", 0, 0)
                local swatch = CreateFrame("Button", nil, frame)
                swatch:SetSize(20, 20)
                swatch:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
                local edge = swatch:CreateTexture(nil, "BACKGROUND")
                edge:SetAllPoints()
                edge:SetColorTexture(0.8, 0.8, 0.8, 1)
                row.fill = swatch:CreateTexture(nil, "ARTWORK")
                row.fill:SetPoint("TOPLEFT", 2, -2)
                row.fill:SetPoint("BOTTOMRIGHT", -2, 2)
                row.swatch = swatch
                swatch:SetScript("OnClick", function()
                    local c = type(row.value) == "table" and row.value or { 1, 1, 1, 1 }
                    local function Byte(v) return math.floor((tonumber(v) or 1) * 255 + 0.5) end
                    PickColour(string.format("%02x%02x%02x", Byte(c[1]), Byte(c[2]), Byte(c[3])), function(hex)
                        Set({ (tonumber(hex:sub(1, 2), 16) or 255) / 255, (tonumber(hex:sub(3, 4), 16) or 255) / 255,
                              (tonumber(hex:sub(5, 6), 16) or 255) / 255, tonumber(c[4]) or 1 })
                    end)
                end)
            elseif kind == "header" or kind == "description" or kind == "space" then
                row.label = Text(frame, "", kind == "header" and "GameFontNormal" or "GameFontHighlightSmall")
                row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, kind == "header" and -6 or 0)
                row.label:SetWidth(PANE_W - 20)
                row.label:SetJustifyH("LEFT")
            else
                -- input, number, media, and anything unknown: a text box.
                row.height = 44
                row.label = Text(frame, "", "GameFontNormalSmall")
                row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                row.box = EditBox(frame, 240, function(text)
                    if row.kind == "number" then Set(tonumber(text)) else Set(text) end
                end, true)
                row.box:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 4, -4)
            end
            widget.rows[i] = row
            return row
        end

        local function Fill(row, option, value)
            row.option, row.value = option, value
            local name = tostring(option.name or option.key or "")
            local kind = row.kind
            if kind == "toggle" then
                row.check:SetChecked(value and true or false)
                row.label:SetText(name)
            elseif kind == "range" then
                local low, high = tonumber(option.min) or 0, tonumber(option.max) or 100
                row.slider:SetMinMaxValues(low, high)
                row.slider.step = tonumber(option.step) or 1
                row.slider:SetValueStep(row.slider.step)
                row.slider.prefix = name
                row.slider:SetDisplayValue(tonumber(value) or low)
            elseif kind == "select" then
                wipe(row.values)
                for index, text in ipairs(type(option.values) == "table" and option.values or {}) do
                    row.values[index] = { text = tostring(text), value = index }
                end
                row.label:SetText(name)
                row.dropdown:SetValue(value)
            elseif kind == "multiselect" then
                row.label:SetText(name)
                local list = type(option.values) == "table" and option.values or {}
                for index, text in ipairs(list) do
                    local check = row.checks[index]
                    if not check then
                        check = CheckBox(row.frame, "", function(checked)
                            local current = {}
                            for k, v in pairs(type(row.value) == "table" and row.value or {}) do current[k] = v end
                            current[index] = checked and true or false
                            local aura = Current()
                            if aura and row.path then field.set(aura, row.path, current) end
                        end)
                        row.checks[index] = check
                    end
                    check:ClearAllPoints()
                    check:SetPoint("TOPLEFT", row.frame, "TOPLEFT", ((index - 1) % 3) * 140,
                                   -16 - math.floor((index - 1) / 3) * 24)
                    check.label:SetText(tostring(text))
                    check:SetChecked(type(value) == "table" and value[index] and true or false)
                    check:Show()
                    check.label:Show()
                end
                for index = #list + 1, #row.checks do
                    row.checks[index]:Hide()
                    row.checks[index].label:Hide()
                end
                row.height = 20 + math.ceil(#list / 3) * 24
            elseif kind == "color" then
                row.label:SetText(name)
                local c = type(value) == "table" and value or { 1, 1, 1, 1 }
                row.fill:SetColorTexture(tonumber(c[1]) or 1, tonumber(c[2]) or 1, tonumber(c[3]) or 1, 1)
            elseif kind == "header" then
                row.label:SetText(tostring(option.text or option.name or ""))
            elseif kind == "description" then
                row.label:SetText(tostring(option.text or ""))
                local ok, h = pcall(row.label.GetStringHeight, row.label)
                row.height = math.max(16, ((ok and type(h) == "number") and h or 12) + 4)
            elseif kind == "space" then
                row.label:SetText("")
                row.height = 12
            else
                row.label:SetText(name)
                if not row.box:HasFocus() then row.box:SetText(value ~= nil and tostring(value) or "") end
            end
            row.frame:SetHeight(row.height)
        end

        function widget:Read(aura)
            local list = {}
            local function Walk(options, path, config)
                for _, option in ipairs(type(options) == "table" and options or {}) do
                    local here = {}
                    for i, key in ipairs(path) do here[i] = key end
                    if option.type == "group" then
                        list[#list + 1] = { option = { type = "header", text = option.name or option.key } }
                        if option.groupType == "array" then
                            list[#list + 1] = { option = { type = "description",
                                text = "A list of entries: its values are kept, but edited in code for now." } }
                        else
                            here[#here + 1] = option.key
                            Walk(option.subOptions, here, type(config) == "table" and config[option.key] or nil)
                        end
                    elseif option.type == "header" or option.type == "description" or option.type == "space" then
                        list[#list + 1] = { option = option }
                    else
                        here[#here + 1] = option.key
                        local value = type(config) == "table" and config[option.key] or nil
                        if value == nil then value = option.default end
                        list[#list + 1] = { option = option, path = here, value = value }
                    end
                end
            end
            Walk(aura.authorOptions, {}, aura.config)
            local y = 0
            for i, entry in ipairs(list) do
                local row = Row(i, entry.option.type or "input")
                row.path = entry.path
                Fill(row, entry.option, entry.value)
                row.frame:ClearAllPoints()
                row.frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
                row.frame:Show()
                y = y + row.height + 4
            end
            for i = #list + 1, #self.rows do self.rows[i].frame:Hide() end
            self.empty:SetShown(#list == 0)
            host:SetHeight(math.max(y, 24))
        end
        function widget:SetEnabled() end

    elseif field.kind == "note" then
        local text = Text(host, field.text or "", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        text:SetWidth(PANE_W - 20)
        text:SetJustifyH("LEFT")
        local okH, height = pcall(text.GetStringHeight, text)
        height = (okH and type(height) == "number") and height or 24
        host:SetHeight(math.max(height + 4, 16))
        widget.text = text
        function widget:Read() end
        function widget:SetEnabled() end

    else -- "header"
        host:SetHeight(26)
        local label = Text(host, field.label, "GameFontNormal")
        label:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 2)
        function widget:Read() end
        function widget:SetEnabled() end
    end

    return widget
end

local function BuildPane(parent, fields)
    local pane = CreateFrame("Frame", nil, parent)
    pane:SetSize(PANE_W, LIST_H)
    pane.widgets = {}

    local offset = 0
    for _, field in ipairs(fields) do
        local widget = BuildField(pane, field)
        widget.host:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -offset)
        offset = offset + widget.host:GetHeight() + FIELD_GAP
        pane.widgets[#pane.widgets + 1] = widget
    end

    pane.contentHeight = offset

    function pane:Read(aura)
        -- Fields that apply only sometimes (a trigger type's settings) are
        -- left out rather than greyed, and the rest close up.
        local y = 0
        for _, widget in ipairs(self.widgets) do
            local field = widget.field
            local shown = true
            if field.visible then shown = field.visible(aura) and true or false end
            widget.host:SetShown(shown)
            if shown then
                local enabled = true
                if field.enabled then enabled = field.enabled(aura) and true or false end
                widget:SetEnabled(enabled)
                widget:Read(aura)
                widget.host:ClearAllPoints()
                widget.host:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
                y = y + (widget.host:GetHeight() or 24) + FIELD_GAP
            end
        end
        self.contentHeight = y
        pcall(self.SetHeight, self, math.max(y, 1))
    end

    pane:Hide()
    return pane
end

-------------------------------------------------------------------------------
-- Field descriptions
-------------------------------------------------------------------------------

local function IsAura(aura)
    return not ns.IsGroup(aura)
        and ns.TriggerField(aura, "type", currentTrigger) == "aura"
end

local function ByID(aura)
    return IsAura(aura) and ns.TriggerField(aura, "match", currentTrigger) == "id"
end

local function ByName(aura)
    return IsAura(aura) and ns.TriggerField(aura, "match", currentTrigger) == "name"
end

local function IsCustom(aura)
    return not ns.IsGroup(aura) and ns.TriggerField(aura, "type", currentTrigger) == "custom"
end

local function CustomKind(aura)
    return ns.Custom.Kind(ns.Trigger(aura, currentTrigger))
end

local TRIGGER_TEMPLATE = "function(event, ...)\n    return true\nend"
local UNTRIGGER_TEMPLATE = "function(event, ...)\n    return true\nend"
local TSU_TEMPLATE = "function(allstates, event, ...)\n    allstates[\"\"] = { show = true,"
    .. " changed = true, name = \"Custom\" }\n    return true\nend"

-- A code box for one of a custom trigger's functions. `template` fills an
-- empty one (a string, or a function of the aura); `extraEnabled` narrows
-- when it applies.
local function CodeField(key, label, template, tip, extraEnabled)
    return {
        kind = "code", label = label, key = key, height = 120, tip = tip,
        hint = "saved when you click away",
        enabled = function(aura)
            if not IsCustom(aura) then return false end
            return not extraEnabled or extraEnabled(aura)
        end,
        get = function(aura)
            local source = ns.Trigger(aura, currentTrigger)[key]
            if source and source ~= "" then return source end
            if type(template) == "function" then return template(aura) end
            return template or ""
        end,
        set = function(aura, text)
            local fill = type(template) == "function" and template(aura) or template
            if text == "" or text == fill and not ns.Trigger(aura, currentTrigger)[key] and key ~= "custom" then
                TriggerOf(aura)[key] = nil
            else
                TriggerOf(aura)[key] = text
            end
            Commit(true)
        end,
        error = function(aura)
            if aura.untrusted then return "imported code: approve it above before it runs" end
            local source = ns.Trigger(aura, currentTrigger)[key]
            if source and source ~= "" then
                local fn, err = ns.Env:Compile(source, key)
                if not fn then return err end
            end
            local state = ns.Engine.states[aura.id]
            local ts = state and state.triggers and state.triggers[currentTrigger]
            return ts and ts.error or nil
        end,
    }
end

local DEFAULT_ACTIVATION = "function(trigger)\n    return trigger[1] and trigger[2]\nend"

local TRIGGER_FIELDS = {
    {
        kind = "triggers", key = "triggers",
        enabled = function(aura) return not ns.IsGroup(aura) end,
    },
    {
        kind = "code", label = "Custom activation", key = "customTriggerLogic", height = 140,
        tip = "Lua that decides whether the aura shows. It is handed the triggers'"
           .. " answers as a list: trigger[1] is true when the first is met, and so"
           .. " on. It runs in a sandbox, the way WeakAuras' does.",
        hint = "function(trigger) ... end -- saved when you click away",
        enabled = function(aura)
            return not ns.IsGroup(aura) and ns.TriggerMode(aura) == "custom"
        end,
        get = function(aura)
            local list = aura.triggers
            return (type(list) == "table" and list.customTriggerLogic) or DEFAULT_ACTIVATION
        end,
        set = function(aura, text)
            ns.NormalizeTriggers(aura)
            aura.triggers = aura.triggers or { {} }
            aura.triggers.customTriggerLogic = text
            Commit(false)
        end,
        error = function(aura)
            local list = aura.triggers
            local source = type(list) == "table" and list.customTriggerLogic
            if source then
                local fn, err = ns.Env:Compile(source, "activation")
                if not fn then return err end
            end
            local state = ns.Engine.states[aura.id]
            return state and state.error or nil
        end,
    },
    {
        kind = "choice", label = "Trigger", key = "type", width = 110,
        values = { { text = "Aura", value = "aura" },
                   { text = "Cooldown", value = "cooldown" },
                   { text = "Custom", value = "custom" } },
        enabled = function(aura) return not ns.IsGroup(aura) end,
        get = function(aura) return ns.TriggerField(aura, "type", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).type = value
            Commit(true)
        end,
    },
    {
        kind = "choice", label = "Match by", key = "match", width = 110,
        tip = "By spell is exact and is what a dragged spell gives you. By name "
           .. "matches the text on the aura itself, which is the only way to "
           .. "catch things like Well Fed -- a different spell ID for every "
           .. "meal, all wearing the same name.",
        values = { { text = "Spell", value = "id" },
                   { text = "Name", value = "name" } },
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "match", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).match = value
            Commit(true)
        end,
    },
    {
        kind = "spell", label = "Spell", key = "spellID",
        tip = "A spell name or numeric ID.",
        enabled = function(aura)
            return not ns.IsGroup(aura)
               and (ByID(aura) or ns.TriggerField(aura, "type", currentTrigger) == "cooldown")
        end,
        get = function(aura)
            local spellID = ns.Trigger(aura, currentTrigger).spellID
            if not spellID then return "" end
            return ns.Engine:SpellName(spellID) .. " (" .. spellID .. ")"
        end,
        set = function(aura, text)
            local spellID = ns.ResolveSpell(text)
            if not spellID then
                ns.Print("this client does not know that spell -- try its numeric ID.")
                Config:Refresh()
                return
            end
            TriggerOf(aura).spellID = spellID
            Commit(true)
        end,
    },
    {
        kind = "text", label = "Aura name", key = "text",
        tip = "The text as it appears on the aura: Well Fed, Drink, a proc you "
           .. "only know by sight. Case does not matter.",
        enabled = ByName,
        get = function(aura) return ns.Trigger(aura, currentTrigger).text or "" end,
        set = function(aura, text)
            TriggerOf(aura).text = (text ~= "" and text) or nil
            Commit(true)
        end,
    },
    {
        kind = "check", label = "Name only has to be contained", key = "partial",
        tip = "Matches any aura whose name contains the text, rather than one "
           .. "that equals it. One aura for a whole family of them.",
        enabled = ByName,
        get = function(aura) return ns.TriggerField(aura, "partial", currentTrigger) end,
        set = function(aura, checked)
            TriggerOf(aura).partial = checked or nil
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "Aura kind", key = "harmful", width = 84,
        values = { { text = "Buff", value = false },
                   { text = "Debuff", value = true } },
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "harmful", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).harmful = value or nil
            -- A debuff nobody said where to look for means the target, the same
            -- way the slash command reads it.
            if value and not ns.Trigger(aura, currentTrigger).unit then
                TriggerOf(aura).unit = "target"
            end
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "On", key = "unit", width = 78,
        tip = "Party, Raid and Boss look at everyone in them (Party includes you); "
           .. "Group is whichever of party or raid you are in.",
        values = { { text = "You", value = "player" },
                   { text = "Target", value = "target" },
                   { text = "Focus", value = "focus" },
                   { text = "Pet", value = "pet" },
                   { text = "Party", value = "party" },
                   { text = "Raid", value = "raid" },
                   { text = "Group", value = "group" },
                   { text = "Boss", value = "boss" } },
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "unit", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).unit = value
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Only what I applied", key = "mine",
        tip = "Ignores the same aura coming from anyone else. Useful for a "
           .. "debuff several people can put on one target.",
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "mine", currentTrigger) end,
        set = function(aura, checked)
            TriggerOf(aura).mine = checked or nil
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "Stacks", key = "stacksOp", width = 60,
        tip = "Left at zero below, stacks are not considered at all.",
        values = { { text = "at least", value = ">=" },
                   { text = "at most", value = "<=" },
                   { text = "exactly", value = "==" } },
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "stacksOp", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).stacksOp = value
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Stack count", key = "stacks", min = 0, max = 40,
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "stacks", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).stacks = (value > 0) and value or nil
            Commit(false)
        end,
    },
    {
        kind = "text", label = "Also match", key = "also", width = 280,
        tip = "More auras that count as this one: names or spell IDs, split by commas. "
           .. "Handy for a buff with several ranks or several foods.",
        enabled = IsAura,
        get = function(aura) return ns.Trigger(aura, currentTrigger).also or "" end,
        set = function(aura, text)
            TriggerOf(aura).also = text ~= "" and text or nil
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "How many matches", key = "matchOp", width = 60,
        tip = "Left at zero below, one match is enough. Otherwise: how many matching "
           .. "auras there must be, across every unit it watches. %{matchCount} shows the number.",
        values = { { text = "at least", value = ">=" },
                   { text = "at most", value = "<=" },
                   { text = "exactly", value = "==" } },
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "matchOp", currentTrigger) end,
        set = function(aura, value)
            TriggerOf(aura).matchOp = value
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Match count", key = "matchCount", min = 0, max = 40,
        enabled = IsAura,
        get = function(aura) return tonumber(ns.Trigger(aura, currentTrigger).matchCount) or 0 end,
        set = function(aura, value)
            TriggerOf(aura).matchCount = (value > 0) and value or nil
            Commit(false)
        end,
    },
    {
        kind = "check", label = "One region per match (inside a group)", key = "cloneMatches",
        tip = "Each matching aura -- on each unit -- gets a region of its own, laid out by "
           .. "the group. %{unitName} names whose it is.",
        enabled = IsAura,
        get = function(aura) return ns.Trigger(aura, currentTrigger).cloneMatches and true or false end,
        set = function(aura, checked)
            TriggerOf(aura).cloneMatches = checked or nil
            Commit(false)
        end,
    },
    { kind = "header", label = "Custom Lua" },
    {
        kind = "button", label = "Approve its code", key = "approve", text = "Approve its code",
        tip = "This aura came from an import and carries custom Lua. Read it in the"
           .. " boxes below first -- it runs as you once approved. Until then it does"
           .. " nothing.",
        enabled = function(aura) return aura.untrusted and true or false end,
        click = function(aura)
            aura.untrusted = nil
            ns.Print("custom code approved for " .. tostring(aura.name or aura.id) .. ".")
            Commit(true)
        end,
    },
    {
        kind = "choice", label = "Kind", key = "custom_type", width = 110,
        tip = "Status: your function says whether it is on, whenever one of the events"
           .. " fires (or every update). Event: your function fires it on an event, and"
           .. " it hides after a while or when your untrigger says so. State updater:"
           .. " WeakAuras' TSU -- your function fills in allstates itself.",
        values = { { text = "Status", value = "status" }, { text = "Event", value = "event" },
                   { text = "State updater", value = "stateupdate" } },
        enabled = IsCustom,
        get = function(aura) return ns.Custom.Kind(ns.Trigger(aura, currentTrigger)) end,
        set = function(aura, value)
            TriggerOf(aura).custom_type = value
            Commit(true)
        end,
    },
    {
        kind = "text", label = "Events", key = "events", width = 380,
        tip = "Space-separated, as WeakAuras writes them: PLAYER_TARGET_CHANGED"
           .. " UNIT_POWER_UPDATE:player. A unit after a colon filters on the event's"
           .. " first argument. TRIGGER:1 fires when trigger 1 changes; any other name"
           .. " is a custom event, sent with WeakAuras.ScanEvents. The combat log does"
           .. " not exist on this client.",
        enabled = IsCustom,
        get = function(aura) return ns.Trigger(aura, currentTrigger).events or "" end,
        set = function(aura, text)
            TriggerOf(aura).events = text ~= "" and text or nil
            Commit(true)
        end,
    },
    {
        kind = "choice", label = "Check", key = "check", width = 110,
        tip = "On events: the function runs when one of the events fires. Every update:"
           .. " ten times a second, whatever happens.",
        values = { { text = "On events", value = "event" }, { text = "Every update", value = "update" } },
        enabled = function(aura) return IsCustom(aura) and CustomKind(aura) == "status" end,
        get = function(aura) return ns.Trigger(aura, currentTrigger).check or "event" end,
        set = function(aura, value)
            TriggerOf(aura).check = value ~= "event" and value or nil
            Commit(true)
        end,
    },
    {
        kind = "choice", label = "Hide", key = "customHide", width = 110,
        tip = "Timed: it shows for the duration below, then hides. Custom: it hides"
           .. " when your untrigger function returns true.",
        values = { { text = "Timed", value = "timed" }, { text = "Custom", value = "custom" } },
        enabled = function(aura) return IsCustom(aura) and CustomKind(aura) == "event" end,
        get = function(aura) return ns.Trigger(aura, currentTrigger).customHide or "timed" end,
        set = function(aura, value)
            TriggerOf(aura).customHide = value ~= "timed" and value or nil
            Commit(true)
        end,
    },
    {
        kind = "text", label = "Duration (seconds)", key = "duration", width = 60,
        enabled = function(aura)
            return IsCustom(aura) and CustomKind(aura) == "event"
                and (ns.Trigger(aura, currentTrigger).customHide or "timed") == "timed"
        end,
        get = function(aura) return tostring(ns.Trigger(aura, currentTrigger).duration or 1) end,
        set = function(aura, text)
            local seconds = tonumber(text)
            TriggerOf(aura).duration = (seconds and seconds > 0) and seconds or nil
            Commit(true)
        end,
    },
    CodeField("custom", "Trigger", function(aura)
        local kind = CustomKind(aura)
        if kind == "stateupdate" then return TSU_TEMPLATE end
        return TRIGGER_TEMPLATE
    end, "Status: return true while it should show. Event: return true to fire it."
       .. " State updater: fill in allstates and return true when you changed it."),
    CodeField("customUntrigger", "Untrigger", UNTRIGGER_TEMPLATE,
        "Status: once on, it stays on until this returns true. Event (hide: custom):"
        .. " it hides when this returns true.", function(aura)
            local kind = CustomKind(aura)
            return kind == "status" or (kind == "event"
                and ns.Trigger(aura, currentTrigger).customHide == "custom")
        end),
    CodeField("customDuration", "Duration", nil,
        "Optional. return duration, expirationTime -- drawn as the aura's timer."),
    CodeField("customName", "Name", nil, "Optional. return the name %n shows."),
    CodeField("customIcon", "Icon", nil, "Optional. return a texture path or file ID."),
    CodeField("customStacks", "Stacks", nil, "Optional. return the stack count."),
}

local function IsKind(wanted)
    return function(aura) return ns.RegionKind(aura) == wanted end
end

local OUTLINES = {
    { text = "Game", value = "" }, { text = "None", value = "NONE" },
    { text = "Outline", value = "OUTLINE" }, { text = "Thick", value = "THICKOUTLINE" },
}

-- Font, outline and color for one piece of text.
local function TextStyleFields(prefix, fontKey, outlineKey, colourKey, enabled)
    return {
        {
            kind = "choice", label = prefix .. " font", key = fontKey, width = 200,
            values = FONT_VALUES, dropdown = true, enabled = enabled,
            get = function(aura) return ns.DisplayField(aura, fontKey) end,
            set = function(aura, value)
                SetDisplay(aura, fontKey, value ~= "" and value or nil)
                Commit(false)
            end,
        },
        {
            kind = "choice", label = prefix .. " outline", key = outlineKey, width = 64,
            values = OUTLINES, enabled = enabled,
            get = function(aura) return ns.DisplayField(aura, outlineKey) end,
            set = function(aura, value)
                SetDisplay(aura, outlineKey, value)
                Commit(false)
            end,
        },
        {
            kind = "colour", label = prefix .. " color", key = colourKey, enabled = enabled,
            get = function(aura)
                local hex = ns.DisplayField(aura, colourKey)
                if not hex or hex == "" then hex = ns.DisplayField(aura, "colour") end
                return hex
            end,
            set = function(aura, hex)
                SetDisplay(aura, colourKey, hex)
                Commit(false)
            end,
        },
    }
end

local function Append(list, extra)
    for _, field in ipairs(extra) do list[#list + 1] = field end
    return list
end

local COLOURS = {
    { text = "White",  value = "ffffff" },
    { text = "Red",    value = "ff5555" },
    { text = "Green",  value = "55dd55" },
    { text = "Blue",   value = "40c4ff" },
    { text = "Yellow", value = "ffd100" },
    { text = "Purple", value = "cc66ff" },
}

-- Only an aura that is not inside a group has a place of its own on screen;
-- the group decides where its children go.
-- A free group's children each have one too, from the group's center.
local function OwnPosition(aura)
    if aura.parent == nil then return true end
    local parent = ns.FindAura(aura.parent)
    return parent ~= nil and ns.GroupField(parent, "growth") == "FREE"
end

local POSITION_TIP = "Where its center sits, in pixels from the center of the "
    .. "screen: 0, 0 is dead center, X grows to the right and Y upward. Drag "
    .. "the slider, or type a number and press Enter. Inside a group the group "
    .. "decides, so set the group's instead."

-- Display settings, built alike: one key on the Display tab each.
local function DisplayCheck(key, label, visible, tip, enabled)
    return {
        kind = "check", label = label, key = key, tip = tip, visible = visible, enabled = enabled,
        get = function(aura) return ns.DisplayField(aura, key) end,
        set = function(aura, checked)
            SetDisplay(aura, key, checked and true or false)
            Commit(false)
        end,
    }
end
local function DisplaySlider(key, label, low, high, visible, tip, step)
    return {
        kind = "slider", label = label, key = key, min = low, max = high, step = step,
        tip = tip, visible = visible,
        get = function(aura) return ns.DisplayField(aura, key) end,
        set = function(aura, value)
            SetDisplay(aura, key, value)
            Commit(false)
        end,
    }
end
local function DisplayChoice(key, label, values, visible, width, dropdown, tip)
    return {
        kind = "choice", label = label, key = key, values = values, width = width,
        dropdown = dropdown, visible = visible, tip = tip,
        get = function(aura) return ns.DisplayField(aura, key) end,
        set = function(aura, value)
            SetDisplay(aura, key, value)
            Commit(false)
        end,
    }
end
local function DisplayText(key, label, visible, width, tip)
    return {
        kind = "text", label = label, key = key, width = width or 240, tip = tip, visible = visible,
        get = function(aura) return tostring(ns.DisplayField(aura, key) or "") end,
        set = function(aura, text)
            SetDisplay(aura, key, text ~= "" and text or nil)
            Commit(false)
        end,
    }
end
local function DisplayColour(key, label, visible, fallback, tip)
    return {
        kind = "colour", label = label, key = key, visible = visible, tip = tip,
        get = function(aura)
            local hex = ns.DisplayField(aura, key)
            if not hex or hex == "" then hex = fallback and ns.DisplayField(aura, fallback) or "ffffff" end
            return hex
        end,
        set = function(aura, hex)
            SetDisplay(aura, key, hex)
            Commit(false)
        end,
    }
end

-- Visible for some shapes only.
local function KindIn(...)
    local wanted = {}
    for i = 1, select("#", ...) do wanted[select(i, ...)] = true end
    return function(aura) return wanted[ns.RegionKind(aura)] and true or false end
end
local function NotGroup(aura) return not ns.IsGroup(aura) end
local function Both(a, b) return function(aura) return a(aura) and b(aura) end end
local function DisplayIs(key, value)
    return function(aura) return ns.DisplayField(aura, key) == value end
end

local POINTS = {
    { text = "TL", value = "TOPLEFT" }, { text = "Top", value = "TOP" },
    { text = "TR", value = "TOPRIGHT" }, { text = "Left", value = "LEFT" },
    { text = "Mid", value = "CENTER" }, { text = "Right", value = "RIGHT" },
    { text = "BL", value = "BOTTOMLEFT" }, { text = "Bot", value = "BOTTOM" },
    { text = "BR", value = "BOTTOMRIGHT" },
}

local DIRECTIONS = {
    { text = "Right", value = "RIGHT" }, { text = "Left", value = "LEFT" },
    { text = "Up", value = "UP" }, { text = "Down", value = "DOWN" },
}

-- Pictures from the game's own files, and the aura's own icon. Any other
-- file path or file ID can be typed in.
local TEXTURES = {
    { text = "The aura's icon", value = "icon" },
    { text = "Solid", value = "Interface\\Buttons\\WHITE8X8" },
    { text = "Circle", value = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask" },
    { text = "Ring", value = "Interface\\Cooldown\\ping4" },
    { text = "Star", value = "Interface\\Cooldown\\star4" },
    { text = "Starburst", value = "Interface\\Cooldown\\starburst" },
    { text = "Glow", value = "Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64" },
    { text = "Spark", value = "Interface\\CastingBar\\UI-CastingBar-Spark" },
    { text = "Skull", value = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull" },
    { text = "Raid star", value = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1" },
    { text = "Raid skull", value = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { text = "Arrow", value = "Interface\\Minimap\\MinimapArrow" },
    { text = "Status bar", value = "Interface\\TargetingFrame\\UI-StatusBar" },
}

-- Bar fills: flat, the game's, and any LibSharedMedia carries.
local BAR_TEXTURES = {}
local function RefreshBarTextures()
    wipe(BAR_TEXTURES)
    local builtin = {
        { "Flat", "" }, { "Blizzard", "Interface\\TargetingFrame\\UI-StatusBar" },
        { "Raid", "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
        { "Skills", "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
    }
    local seen = {}
    for _, entry in ipairs(builtin) do
        BAR_TEXTURES[#BAR_TEXTURES + 1] = { text = entry[1], value = entry[2] }
        seen[entry[2]] = true
    end
    local stub = _G.LibStub
    local ok, media = pcall(function() return stub and stub("LibSharedMedia-3.0", true) end)
    if ok and media and type(media.List) == "function" then
        local okL, names = pcall(media.List, media, "statusbar")
        for _, name in ipairs(okL and names or {}) do
            local okF, path = pcall(media.Fetch, media, "statusbar", name)
            if okF and path and not seen[path] then
                BAR_TEXTURES[#BAR_TEXTURES + 1] = { text = name, value = path }
                seen[path] = true
            end
        end
    end
end
RefreshBarTextures()

-- Templates for a group's own layout code.
local GROW_TEMPLATE = "function(newPositions, activeRegions)\n"
    .. "    for i, regionData in ipairs(activeRegions) do\n"
    .. "        newPositions[i] = { (i - 1) * (regionData.regionWidth + 4), 0 }\n"
    .. "    end\nend"
local SORT_TEMPLATE = "function(a, b)\n    return a.id < b.id\nend"

-- Which of the aura's extra texts the Display tab is editing.
local currentText = 1
local function TextsOf(aura)
    local list = type(aura.display) == "table" and aura.display.texts
    return type(list) == "table" and list or nil
end
local function CurText(aura)
    local list = TextsOf(aura)
    return list and list[currentText]
end
local function HasText(aura) return not ns.IsGroup(aura) and CurText(aura) ~= nil end
local function TextValue(aura, key) return ns.SubRegions.TextField(CurText(aura), key) end
local function SetText(aura, key, value)
    local entry = CurText(aura)
    if not entry then return end
    entry[key] = value
    Commit(false)
end
function Config.__textCursor(i)
    if i then currentText = i end
    return currentText
end

local DISPLAY_FIELDS = {
    {
        kind = "position", label = "X", key = "posX", axis = "x", tip = POSITION_TIP,
        enabled = OwnPosition,
        get = function(aura) return (ns.Display:CenterOffset(aura)) end,
        set = function(aura, value)
            local _, y = ns.Display:CenterOffset(aura)
            ns.Display:SetCenterOffset(aura, value, y)
            Commit(false)
        end,
    },
    {
        kind = "position", label = "Y", key = "posY", axis = "y", tip = POSITION_TIP,
        enabled = OwnPosition,
        get = function(aura) return select(2, ns.Display:CenterOffset(aura)) end,
        set = function(aura, value)
            local x = ns.Display:CenterOffset(aura)
            ns.Display:SetCenterOffset(aura, x, value)
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "Draw it as", key = "type", width = 160, dropdown = true,
        tip = "The same trigger, drawn differently. Everything else about the "
           .. "aura survives the change.",
        values = { { text = "Icon", value = "icon" },
                   { text = "Text", value = "text" },
                   { text = "Bar", value = "bar" },
                   { text = "Texture", value = "texture" },
                   { text = "Progress texture", value = "progress" },
                   { text = "Model", value = "model" } },
        enabled = function(aura) return not ns.IsGroup(aura) end,
        get = function(aura) return ns.RegionKind(aura) end,
        set = function(aura, value)
            aura.type = value
            Commit(true)
        end,
    },
    {
        kind = "icon", label = "Icon", key = "icon",
        enabled = function(aura)
            local kind = ns.RegionKind(aura)
            return kind == "icon" or kind == "bar" or ns.IsGroup(aura)
        end,
        tip = "Pick one out of the game's own list, or name a spell to borrow "
           .. "its icon. Either way it beats what the aura would have shown, "
           .. "which is what an aura matched by name needs -- it has no spell "
           .. "of its own to take one from.\n\n"
           .. "On a group this is the only setting that is not handed down: it "
           .. "is how the group is known in the list, and the children keep "
           .. "looking like what they watch.",
    },
    {
        kind = "text", label = "Icon from spell", key = "iconSpell", width = 200,
        group = true,
        tip = "An aura matched by name has no spell to take an icon from, so "
           .. "until it is actually on you it has nothing to show. Name a "
           .. "spell or ID here to borrow its icon. Once the aura has been "
           .. "seen, the icon it is really wearing is used instead.",
        get = function(aura)
            local spellID = (aura.display or {}).iconSpell
            if not spellID then return "" end
            return ns.Engine:SpellName(spellID) .. " (" .. spellID .. ")"
        end,
        set = function(aura, text)
            if text == "" then
                SetDisplay(aura, "iconSpell", nil)
                Commit(true)
                return
            end
            local spellID = ns.ResolveSpell(text)
            if not spellID then
                ns.Print("this client does not know that spell -- try its numeric ID.")
                Config:Refresh()
                return
            end
            SetDisplay(aura, "iconSpell", spellID)
            Commit(true)
        end,
    },
    {
        kind = "slider", label = "Icon size", key = "size", min = 12, max = 128,
        tip = "On a group this sets every icon inside it, now and for anything "
           .. "added to it later.",
        enabled = function(aura)
            return ns.IsGroup(aura) or ns.RegionKind(aura) == "icon"
        end,
        get = function(aura) return ns.DisplayField(aura, "size") end,
        set = function(aura, value)
            SetDisplay(aura, "size", value)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Show when missing", key = "invert",
        tip = "Turns the aura inside out: bright while the thing is absent. "
           .. "This is how you watch for a buff falling off.",
        get = function(aura) return ns.DisplayField(aura, "invert") end,
        set = function(aura, checked)
            SetDisplay(aura, "invert", checked or nil)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Hide when inactive", key = "hide",
        tip = "Disappear entirely instead of dimming. Inside a dynamic group "
           .. "this is what makes the row close up around it.",
        get = function(aura) return ns.DisplayField(aura, "hide") end,
        set = function(aura, checked)
            SetDisplay(aura, "hide", checked or nil)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Gray out when inactive", key = "desaturate",
        get = function(aura) return ns.DisplayField(aura, "desaturate") end,
        set = function(aura, checked)
            SetDisplay(aura, "desaturate", checked)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Cooldown swipe", key = "swipe",
        get = function(aura) return ns.DisplayField(aura, "swipe") end,
        set = function(aura, checked)
            SetDisplay(aura, "swipe", checked)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Stack count", key = "stacks",
        tip = "Draw the number of stacks in the corner of the icon.\n\n"
           .. "Only an icon has a corner to draw it in. A bar or a text aura "
           .. "shows its stacks through %s in the text instead, so this is "
           .. "grayed out for those rather than quietly doing nothing.\n\n"
           .. "An aura that does not stack reports zero, and zero is not "
           .. "drawn -- otherwise every ordinary buff would wear a 0.",
        enabled = function(aura)
            return ns.IsGroup(aura) or ns.RegionKind(aura) == "icon"
        end,
        get = function(aura) return ns.DisplayField(aura, "stacks") end,
        set = function(aura, checked)
            SetDisplay(aura, "stacks", checked)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Flash when it comes up", key = "flash",
        get = function(aura) return ns.DisplayField(aura, "flash") end,
        set = function(aura, checked)
            SetDisplay(aura, "flash", checked)
            Commit(false)
        end,
    },
    DisplaySlider("iconZoom", "Zoom (%)", 0, 60, IsKind("icon"),
        "Crops the icon's art in from its edge."),
    DisplayCheck("cooldownReverse", "Reverse the swipe", IsKind("icon"),
        "The swipe fills in rather than empties out."),
    DisplayCheck("cooldownEdge", "Swipe edge", IsKind("icon"), "A bright line along the swipe's edge."),
    DisplayCheck("cooldownText", "Countdown numbers", IsKind("icon"),
        "The client's own numbers on the swipe."),

    DisplaySlider("width", "Width", 4, 512, KindIn("texture", "progress", "model")),
    DisplaySlider("height", "Height", 4, 512, KindIn("texture", "progress", "model")),

    { kind = "header", label = "Texture", visible = IsKind("texture") },
    DisplayChoice("texture", "Picture", TEXTURES, IsKind("texture"), 200, true,
        "One of the game's own, or the aura's icon. Type any other file path or file ID below."),
    DisplayText("texture", "Or a file", IsKind("texture"), 280,
        "A texture path, like Interface\\Icons\\Spell_Nature_Rejuvenation, or a file ID."),
    DisplayColour("textureColour", "Color", IsKind("texture")),
    DisplaySlider("textureRotation", "Rotation", 0, 360, IsKind("texture")),
    DisplayCheck("textureMirror", "Mirror", IsKind("texture")),
    DisplayChoice("textureBlend", "Blend", { { text = "Normal", value = "BLEND" },
        { text = "Add (glowing)", value = "ADD" } }, IsKind("texture"), 100),

    { kind = "header", label = "Progress texture", visible = IsKind("progress") },
    DisplayChoice("progressStyle", "Shape", { { text = "Bar", value = "linear" },
        { text = "Round", value = "circular" } }, IsKind("progress"), 80, false,
        "A bar fills one way; round sweeps like a cooldown. Round follows a timer only."),
    DisplayChoice("progressTexture", "Picture", TEXTURES, IsKind("progress"), 200, true),
    DisplayText("progressTexture", "Or a file", IsKind("progress"), 280),
    DisplayColour("progressColour", "Fill color", IsKind("progress"), "colour"),
    DisplayColour("progressBackColour", "Background color", IsKind("progress")),
    DisplaySlider("progressBackAlpha", "Background opacity (%)", 0, 100, IsKind("progress")),
    DisplayChoice("progressDirection", "Fills toward", DIRECTIONS,
        Both(IsKind("progress"), DisplayIs("progressStyle", "linear")), 62),
    DisplayCheck("progressInverse", "Inverse", IsKind("progress"),
        "Fill with the time gone rather than the time left."),

    { kind = "header", label = "Model", visible = IsKind("model") },
    DisplayChoice("modelSource", "Show", { { text = "A unit", value = "unit" },
        { text = "Display ID", value = "display" }, { text = "File ID", value = "file" } },
        IsKind("model"), 90),
    DisplayChoice("modelUnit", "Unit", { { text = "Player", value = "player" },
        { text = "Target", value = "target" }, { text = "Focus", value = "focus" },
        { text = "Pet", value = "pet" } }, Both(IsKind("model"), DisplayIs("modelSource", "unit")), 62),
    {
        kind = "text", label = "ID", key = "modelID", width = 120,
        visible = function(aura) return ns.RegionKind(aura) == "model" and ns.DisplayField(aura, "modelSource") ~= "unit" end,
        get = function(aura) return tostring(ns.DisplayField(aura, "modelID") or 0) end,
        set = function(aura, text)
            SetDisplay(aura, "modelID", tonumber(text) or nil)
            Commit(false)
        end,
    },
    DisplaySlider("modelFacing", "Facing", 0, 360, IsKind("model")),
    DisplaySlider("modelZoom", "Zoom (%)", 0, 100, IsKind("model")),
    { kind = "header", label = "Text on the icon" },
    {
        kind = "text", label = "What it says", key = "iconText", width = 240,
        tip = "Drawn on top of the icon. %t time left, %s stacks, %n the name, "
           .. "%p per cent left, %d the full duration. Leave it empty for none.",
        enabled = IsKind("icon"),
        get = function(aura) return ns.DisplayField(aura, "iconText") end,
        set = function(aura, text)
            SetDisplay(aura, "iconText", text ~= "" and text or nil)
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "Where", key = "iconTextPoint", width = 44,
        values = {
            { text = "TL", value = "TOPLEFT" }, { text = "Top", value = "TOP" },
            { text = "TR", value = "TOPRIGHT" }, { text = "Left", value = "LEFT" },
            { text = "Mid", value = "CENTER" }, { text = "Right", value = "RIGHT" },
            { text = "BL", value = "BOTTOMLEFT" }, { text = "Bot", value = "BOTTOM" },
            { text = "BR", value = "BOTTOMRIGHT" },
        },
        enabled = IsKind("icon"),
        get = function(aura) return ns.DisplayField(aura, "iconTextPoint") end,
        set = function(aura, value)
            SetDisplay(aura, "iconTextPoint", value)
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Size", key = "iconTextSize", min = 6, max = 32,
        enabled = IsKind("icon"),
        get = function(aura) return ns.DisplayField(aura, "iconTextSize") end,
        set = function(aura, value)
            SetDisplay(aura, "iconTextSize", value)
            Commit(false)
        end,
    },
    { kind = "header", label = "Text" },
    {
        kind = "text", label = "What it says", key = "textFormat", width = 240,
        tip = "%n the name, %s stacks, %t time left, %p per cent left, "
           .. "%d the full duration. Anything else is written out as typed.",
        enabled = IsKind("text"),
        get = function(aura) return ns.DisplayField(aura, "textFormat") end,
        set = function(aura, text)
            SetDisplay(aura, "textFormat", text ~= "" and text or nil)
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Font size", key = "fontSize", min = 8, max = 48,
        enabled = IsKind("text"),
        get = function(aura) return ns.DisplayField(aura, "fontSize") end,
        set = function(aura, value)
            SetDisplay(aura, "fontSize", value)
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Text width", key = "textWidth", min = 40, max = 400,
        tip = "How much room it takes in a group. The words themselves are not "
           .. "cut off by it.",
        enabled = IsKind("text"),
        get = function(aura) return ns.DisplayField(aura, "textWidth") end,
        set = function(aura, value)
            SetDisplay(aura, "textWidth", value)
            Commit(false)
        end,
    },

    { kind = "header", label = "Bar" },
    {
        kind = "text", label = "What it says", key = "barFormat", width = 240,
        tip = "The same tokens as the text: %n name, %s stacks, %t time left, "
           .. "%p per cent, %d duration.",
        enabled = IsKind("bar"),
        get = function(aura) return ns.DisplayField(aura, "barFormat") end,
        set = function(aura, text)
            SetDisplay(aura, "barFormat", text ~= "" and text or nil)
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Bar width", key = "barWidth", min = 40, max = 500,
        enabled = IsKind("bar"),
        get = function(aura) return ns.DisplayField(aura, "barWidth") end,
        set = function(aura, value)
            SetDisplay(aura, "barWidth", value)
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Bar height", key = "barHeight", min = 6, max = 60,
        enabled = IsKind("bar"),
        get = function(aura) return ns.DisplayField(aura, "barHeight") end,
        set = function(aura, value)
            SetDisplay(aura, "barHeight", value)
            Commit(false)
        end,
    },
    {
        kind = "check", label = "Icon beside the bar", key = "barIcon",
        enabled = IsKind("bar"),
        get = function(aura) return ns.DisplayField(aura, "barIcon") end,
        set = function(aura, checked)
            SetDisplay(aura, "barIcon", checked)
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "Color", key = "colour", width = 62,
        tip = "Colors the bar, or the words -- including the text on an icon.",
        values = COLOURS,
        enabled = function(aura)
            local kind = ns.RegionKind(aura)
            return ns.IsGroup(aura) or kind == "text" or kind == "bar" or kind == "icon"
        end,
        get = function(aura) return ns.DisplayField(aura, "colour") end,
        set = function(aura, value)
            SetDisplay(aura, "colour", value)
            Commit(false)
        end,
    },

    DisplayChoice("barTexture", "Bar texture", BAR_TEXTURES, IsKind("bar"), 200, true),
    DisplayColour("barBackColour", "Background color", IsKind("bar")),
    DisplaySlider("barBackAlpha", "Background opacity (%)", 0, 100, IsKind("bar")),
    DisplayChoice("barDirection", "Fills toward", DIRECTIONS, IsKind("bar"), 62),
    DisplayCheck("barSpark", "Spark", IsKind("bar"), "A spark at the moving edge while it has a timer."),
    DisplayCheck("barInverse", "Inverse", IsKind("bar"), "Fill with the time gone rather than the time left."),

    { kind = "header", label = "Border and background", visible = NotGroup },
    DisplayCheck("border", "Border", NotGroup),
    DisplayColour("borderColour", "Border color", Both(NotGroup, DisplayIs("border", true))),
    DisplaySlider("borderSize", "Border size", 1, 10, Both(NotGroup, DisplayIs("border", true))),
    DisplaySlider("borderOffset", "Border and background offset", -10, 10, NotGroup,
        "Out from the edge, or in from it."),
    DisplayCheck("backdrop", "Background", NotGroup),
    DisplayColour("backdropColour", "Background color", Both(NotGroup, DisplayIs("backdrop", true))),
    DisplaySlider("backdropAlpha", "Background opacity (%)", 0, 100, Both(NotGroup, DisplayIs("backdrop", true))),

    { kind = "header", label = "Glow", visible = NotGroup },
    DisplayCheck("glow", "Glow while it shows", NotGroup,
        "A glow round it for as long as it shows. A condition can glow it too; it uses the style set here."),
    DisplayChoice("glowType", "Style", { { text = "Pulse", value = "pulse" },
        { text = "Pixel", value = "pixel" }, { text = "Shine", value = "shine" } }, NotGroup, 62, false,
        "Pulse breathes a border in and out; pixel runs lines round the edge; shine runs dots round it. "
        .. "The game's own action-button glow is not on this client."),
    DisplayColour("glowColour", "Glow color", NotGroup),
    DisplaySlider("glowLines", "Lines or dots", 1, 30, Both(NotGroup, function(aura)
        return ns.DisplayField(aura, "glowType") ~= "pulse" end)),
    DisplaySlider("glowThickness", "Thickness", 1, 8, NotGroup),
    DisplaySlider("glowSpeed", "Speed", 5, 200, Both(NotGroup, function(aura)
        return ns.DisplayField(aura, "glowType") ~= "pulse" end),
        "How far round it goes in a second, per cent."),

    { kind = "header", label = "Ticks", visible = KindIn("bar", "progress") },
    DisplayText("ticks", "Marks at", KindIn("bar", "progress"), 160,
        "Numbers, split by commas: seconds left, or per cent along. \"3, 10\" marks 3 and 10 seconds left."),
    DisplayChoice("tickMode", "Measured in", { { text = "Seconds left", value = "seconds" },
        { text = "Per cent", value = "percent" } }, KindIn("bar", "progress"), 100),
    DisplayColour("tickColour", "Tick color", KindIn("bar", "progress")),
    DisplaySlider("tickThickness", "Tick thickness", 1, 8, KindIn("bar", "progress")),

    { kind = "header", label = "More text", visible = NotGroup },
    {
        kind = "strip", label = "Texts", key = "texts", max = 8, visible = NotGroup,
        empty = "none yet -- + adds one",
        tip = "Any number of texts, each placed and styled on its own, with the text codes.",
        count = function(aura) local list = TextsOf(aura) return list and #list or 0 end,
        current = function() return currentText end,
        select = function(i) currentText = i end,
        add = function(aura)
            local display = DisplayOf(aura)
            display.texts = display.texts or {}
            display.texts[#display.texts + 1] = { text = "%n" }
            currentText = #display.texts
        end,
        remove = function(aura)
            local list = TextsOf(aura)
            if not list then return end
            table.remove(list, currentText)
            currentText = math.max(1, currentText - 1)
        end,
    },
    {
        kind = "text", label = "What it says", key = "subText", width = 240, visible = HasText,
        tip = "The same codes as everywhere: %n, %s, %t, %p, %c, %field...",
        get = function(aura) return TextValue(aura, "text") end,
        set = function(aura, text) SetText(aura, "text", text) end,
    },
    {
        kind = "choice", label = "Where", key = "subTextPoint", width = 44, values = POINTS, visible = HasText,
        get = function(aura) return TextValue(aura, "point") end,
        set = function(aura, value) SetText(aura, "point", value) end,
    },
    {
        kind = "slider", label = "Across", key = "subTextX", min = -200, max = 200, visible = HasText,
        get = function(aura) return TextValue(aura, "x") end,
        set = function(aura, value) SetText(aura, "x", value) end,
    },
    {
        kind = "slider", label = "Up", key = "subTextY", min = -200, max = 200, visible = HasText,
        get = function(aura) return TextValue(aura, "y") end,
        set = function(aura, value) SetText(aura, "y", value) end,
    },
    {
        kind = "slider", label = "Size", key = "subTextSize", min = 6, max = 48, visible = HasText,
        get = function(aura) return TextValue(aura, "size") end,
        set = function(aura, value) SetText(aura, "size", value) end,
    },
    {
        kind = "choice", label = "Font", key = "subTextFont", width = 200, values = FONT_VALUES,
        dropdown = true, visible = HasText,
        get = function(aura) return TextValue(aura, "font") end,
        set = function(aura, value) SetText(aura, "font", value) end,
    },
    {
        kind = "choice", label = "Outline", key = "subTextOutline", width = 64, values = OUTLINES,
        visible = HasText,
        get = function(aura) return TextValue(aura, "outline") end,
        set = function(aura, value) SetText(aura, "outline", value) end,
    },
    {
        kind = "colour", label = "Color", key = "subTextColour", visible = HasText,
        get = function(aura) return TextValue(aura, "colour") end,
        set = function(aura, hex) SetText(aura, "colour", hex) end,
    },

    { kind = "header", label = "Group layout" },
    {
        kind = "choice", label = "Grow", key = "growth", width = 62,
        tip = "Which way the group grows, and which part of it holds still "
           .. "while it does. Center keeps the middle fixed, so a dynamic "
           .. "group opens out and closes back in around its own center "
           .. "instead of pushing off one end.",
        enabled = ns.IsGroup,
        values = { { text = "Right", value = "RIGHT" },
                   { text = "Left", value = "LEFT" },
                   { text = "Down", value = "DOWN" },
                   { text = "Up", value = "UP" },
                   { text = "Center H", value = "HCENTER" },
                   { text = "Center V", value = "VCENTER" },
                   { text = "Circle", value = "CIRCLE" },
                   { text = "Custom", value = "CUSTOM" },
                   { text = "Free", value = "FREE" } },
        get = function(aura) return ns.GroupField(aura, "growth") end,
        set = function(aura, value)
            aura.growth = value
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Spacing", key = "spacing", min = 0, max = 40,
        enabled = ns.IsGroup,
        get = function(aura) return ns.GroupField(aura, "spacing") end,
        set = function(aura, value)
            aura.spacing = value
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Wrap after", key = "columns", min = 0, max = 12,
        tip = "Zero keeps everything on one line.",
        enabled = ns.IsGroup,
        get = function(aura) return ns.GroupField(aura, "columns") end,
        set = function(aura, value)
            aura.columns = value
            Commit(false)
        end,
    },
    {
        kind = "check", label = "New lines go up (or left)", key = "wrapReverse",
        tip = "When it wraps: a row's next line goes above it rather than below, a "
           .. "column's to its left rather than its right.",
        visible = function(aura)
            local growth = ns.GroupField(aura, "growth")
            return ns.IsGroup(aura) and (ns.GroupField(aura, "columns") or 0) > 0
                and growth ~= "CIRCLE" and growth ~= "CUSTOM" and growth ~= "FREE"
        end,
        get = function(aura) return ns.GroupField(aura, "wrapReverse") end,
        set = function(aura, checked)
            aura.wrapReverse = checked or nil
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Radius (0 fits them)", key = "radius", min = 0, max = 400,
        visible = function(aura) return ns.IsGroup(aura) and ns.GroupField(aura, "growth") == "CIRCLE" end,
        get = function(aura) return ns.GroupField(aura, "radius") end,
        set = function(aura, value) aura.radius = value Commit(false) end,
    },
    {
        kind = "slider", label = "Start (degrees from the top)", key = "arcStart", min = 0, max = 360,
        visible = function(aura) return ns.IsGroup(aura) and ns.GroupField(aura, "growth") == "CIRCLE" end,
        get = function(aura) return ns.GroupField(aura, "arcStart") end,
        set = function(aura, value) aura.arcStart = value Commit(false) end,
    },
    {
        kind = "slider", label = "Arc (360 is the whole ring)", key = "arcRange", min = 10, max = 360,
        visible = function(aura) return ns.IsGroup(aura) and ns.GroupField(aura, "growth") == "CIRCLE" end,
        get = function(aura) return ns.GroupField(aura, "arcRange") end,
        set = function(aura, value) aura.arcRange = value Commit(false) end,
    },
    {
        kind = "code", label = "Custom growth", key = "growCustom", height = 150,
        tip = "WeakAuras' custom grow: fill newPositions[i] = { x, y } from the group's center for "
           .. "each of activeRegions (region, regionWidth, regionHeight, data, state).",
        hint = "saved when you click away",
        visible = function(aura) return ns.IsGroup(aura) and ns.GroupField(aura, "growth") == "CUSTOM" end,
        get = function(aura)
            local source = aura.growCustom
            if source and source ~= "" then return source end
            return GROW_TEMPLATE
        end,
        set = function(aura, text)
            aura.growCustom = (text ~= "" and text ~= GROW_TEMPLATE) and text or nil
            Commit(false)
        end,
        error = function(aura)
            if not aura.growCustom then return nil end
            if aura.untrusted then return "imported code: approve it first" end
            local fn, err = ns.Env:Compile(aura.growCustom, "growth")
            return (not fn) and err or nil
        end,
    },
    {
        kind = "choice", label = "Sort (dynamic only)", key = "sort", width = 78,
        values = { { text = "List order", value = "none" },
                   { text = "Name", value = "name" },
                   { text = "Time left", value = "time" },
                   { text = "Custom", value = "custom" } },
        enabled = function(aura) return aura.type == "dynamic" end,
        get = function(aura) return ns.GroupField(aura, "sort") end,
        set = function(aura, value)
            aura.sort = value
            Commit(false)
        end,
    },
    {
        kind = "code", label = "Custom sort", key = "sortCustom", height = 130,
        tip = "WeakAuras' custom sort: return true when a goes before b. Each has region, data, "
           .. "id, cloneId and state.",
        hint = "saved when you click away",
        visible = function(aura) return aura.type == "dynamic" and ns.GroupField(aura, "sort") == "custom" end,
        get = function(aura)
            local source = aura.sortCustom
            if source and source ~= "" then return source end
            return SORT_TEMPLATE
        end,
        set = function(aura, text)
            aura.sortCustom = (text ~= "" and text ~= SORT_TEMPLATE) and text or nil
            Commit(false)
        end,
        error = function(aura)
            if not aura.sortCustom then return nil end
            if aura.untrusted then return "imported code: approve it first" end
            local fn, err = ns.Env:Compile(aura.sortCustom, "sort")
            return (not fn) and err or nil
        end,
    },
    {
        kind = "slider", label = "Show at most (dynamic only)", key = "limit",
        min = 0, max = 20,
        enabled = function(aura) return aura.type == "dynamic" end,
        get = function(aura) return ns.GroupField(aura, "limit") end,
        set = function(aura, value)
            aura.limit = (value > 0) and value or nil
            Commit(false)
        end,
    },
}

local function SoundField(key, label, tip)
    return {
        kind = "sound", label = label, key = key, tip = tip,
        get = function(aura) return ns.ActionField(aura, key) end,
        set = function(aura, text)
            local actions = ActionsOf(aura)
            actions[key] = (text ~= "" and text) or nil

            -- Like the rest of a group's settings, this is one edit for
            -- everything inside it.
            if ns.IsGroup(aura) then
                for _, child in ipairs(ns.Descendants(aura.id)) do
                    ns.SubTable(child, "actions")[key] = actions[key]
                end
            end
            Commit(false)
        end,
    }
end

local SOUND_TIP = "Choose one from the client's own list -- clicking a name "
    .. "plays it, so you hear it before you keep it -- or type a file path in "
    .. "the list window and press Use path. Empty is silence."

-------------------------------------------------------------------------------
-- The Conditions tab
-------------------------------------------------------------------------------
-- A strip of conditions; for the one open, a strip of its checks and one of
-- its changes; and for the check and change open, their settings. Every
-- setting shows only while it applies, as on the Trigger tab.

local currentCondition, currentCheck, currentChange = 1, 1, 1

local function Conds(aura)
    aura.conditions = aura.conditions or {}
    return aura.conditions
end
local function Cond(aura)
    return aura.conditions and aura.conditions[currentCondition]
end

-- A condition's checks as a list: several under an AND/OR, or its one.
local function CheckList(cond)
    if not cond or type(cond.check) ~= "table" then return {} end
    if tonumber(cond.check.trigger) == -2 then return cond.check.checks or {} end
    return { cond.check }
end
local function CurCheck(aura)
    local list = CheckList(Cond(aura))
    return list[currentCheck]
end
local function Change(aura)
    local cond = Cond(aura)
    return cond and cond.changes and cond.changes[currentChange]
end

local function HasCond(aura) return not ns.IsGroup(aura) and Cond(aura) ~= nil end
local function HasCheck(aura) return HasCond(aura) and CurCheck(aura) ~= nil end
local function HasChange(aura) return HasCond(aura) and Change(aura) ~= nil end
local function CheckOnTrigger(aura)
    local check = CurCheck(aura)
    return check and (tonumber(check.trigger) or 1) > 0
end
local function CheckKind(aura)
    local check = CurCheck(aura)
    return check and ns.Conditions.KindOf(check.variable) or nil
end
local function ChangeIs(...)
    local wanted = { ... }
    return function(aura)
        local change = HasChange(aura) and Change(aura)
        if not change then return false end
        for _, w in ipairs(wanted) do if change.property == w then return true end end
        return false
    end
end

local function Hex(colour)
    if type(colour) ~= "table" then return "ffffff" end
    return string.format("%02x%02x%02x", math.floor((tonumber(colour[1]) or 1) * 255 + 0.5),
        math.floor((tonumber(colour[2]) or 1) * 255 + 0.5), math.floor((tonumber(colour[3]) or 1) * 255 + 0.5))
end
local function FromHex(hex)
    hex = hex or "ffffff"
    return { (tonumber(hex:sub(1, 2), 16) or 255) / 255, (tonumber(hex:sub(3, 4), 16) or 255) / 255,
             (tonumber(hex:sub(5, 6), 16) or 255) / 255, 1 }
end

local DEFAULT_VALUE = {
    alpha = 50, color = { 1, 0.2, 0.2, 1 }, desaturate = true, glow = true, scale = 1.5,
    text = "%s", sound = { sound = "" }, chat = { message = "", channel = "PRINT" },
    customcode = { custom = "function()\n    \nend" },
}

local TRIGGER_CHOICES = {}
for i = 1, 8 do TRIGGER_CHOICES[#TRIGGER_CHOICES + 1] = { text = "Trigger " .. i, value = i } end
TRIGGER_CHOICES[#TRIGGER_CHOICES + 1] = { text = "Custom Lua", value = -1 }

local NUMBER_OPS = {
    { text = ">=", value = ">=" }, { text = "<=", value = "<=" }, { text = "=", value = "==" },
    { text = ">", value = ">" }, { text = "<", value = "<" }, { text = "not", value = "~=" },
}
local STRING_OPS = { { text = "is", value = "==" }, { text = "is not", value = "~=" },
                     { text = "contains", value = "find" } }

local function SetCheck(aura, key, value)
    local check = CurCheck(aura)
    if check then check[key] = value end
    Commit(false)
end
local function SetChangeValue(aura, value)
    local change = Change(aura)
    if change then change.value = value end
    Commit(false)
end

local CONDITION_FIELDS = {
    { kind = "note", key = "conditionsNote",
      text = "When a trigger's values meet a check, the aura changes: its color, glow,"
          .. " transparency, size or text while it holds, or a sound, chat message or"
          .. " custom code the moment it starts. Later conditions override earlier ones.",
      visible = function(aura) return not ns.IsGroup(aura) end },
    {
        kind = "strip", key = "conditionStrip", label = "Conditions", move = true,
        empty = "none yet -- + adds one",
        visible = function(aura) return not ns.IsGroup(aura) end,
        count = function(aura) return #(aura.conditions or {}) end,
        current = function() return currentCondition end,
        select = function(i) currentCondition, currentCheck, currentChange = i, 1, 1 end,
        add = function(aura)
            local list = Conds(aura)
            list[#list + 1] = {
                check = { trigger = 1, variable = "stacks", op = ">=", value = 1 },
                changes = { { property = "glow", value = true } },
            }
            currentCondition, currentCheck, currentChange = #list, 1, 1
        end,
        remove = function(aura)
            local list = Conds(aura)
            table.remove(list, currentCondition)
            currentCondition = math.max(1, currentCondition - 1)
            if #list == 0 then aura.conditions = nil end
        end,
        move = function(aura, step)
            local list = Conds(aura)
            local to = currentCondition + step
            if to < 1 or to > #list then return end
            list[currentCondition], list[to] = list[to], list[currentCondition]
            currentCondition = to
        end,
    },
    {
        kind = "check", label = "Else if (only when the one above did not hold)", key = "linked",
        visible = function(aura) return HasCond(aura) and currentCondition > 1 end,
        get = function(aura) return Cond(aura).linked end,
        set = function(aura, on) Cond(aura).linked = on or nil Commit(false) end,
    },

    { kind = "header", label = "When", visible = HasCond },
    {
        kind = "strip", key = "checkStrip", label = "Checks", max = 6,
        visible = HasCond,
        count = function(aura) return #CheckList(Cond(aura)) end,
        current = function() return currentCheck end,
        select = function(i) currentCheck = i end,
        add = function(aura)
            local cond = Cond(aura)
            local new = { trigger = 1, variable = "show", op = "==", value = true }
            local list = CheckList(cond)
            if #list == 0 then
                cond.check = new
            elseif tonumber(cond.check.trigger) == -2 then
                table.insert(cond.check.checks, new)
            else
                cond.check = { trigger = -2, variable = "AND", checks = { cond.check, new } }
            end
            currentCheck = #CheckList(cond)
        end,
        remove = function(aura)
            local cond = Cond(aura)
            if tonumber(cond.check and cond.check.trigger) == -2 then
                table.remove(cond.check.checks, currentCheck)
                if #cond.check.checks == 1 then cond.check = cond.check.checks[1] end
            else
                cond.check = nil
            end
            currentCheck = math.max(1, currentCheck - 1)
        end,
    },
    {
        kind = "choice", label = "Combine", key = "combine", width = 70,
        values = { { text = "All", value = "AND" }, { text = "Any", value = "OR" } },
        visible = function(aura) return HasCond(aura) and #CheckList(Cond(aura)) > 1 end,
        get = function(aura) return Cond(aura).check.variable end,
        set = function(aura, value) Cond(aura).check.variable = value Commit(false) end,
    },
    {
        kind = "choice", label = "Look at", key = "checkTrigger", width = 160, dropdown = true,
        values = TRIGGER_CHOICES, visible = HasCheck,
        get = function(aura) return tonumber(CurCheck(aura).trigger) or 1 end,
        set = function(aura, value)
            local check = CurCheck(aura)
            check.trigger = value
            if value == -1 then
                check.variable = "customcheck"
                check.value = "function(trigger)\n    return trigger[1] and trigger[1].met\nend"
                check.op = nil
            elseif check.variable == "customcheck" then
                check.variable, check.op, check.value = "show", "==", true
            end
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "Its", key = "checkVariable", width = 160, dropdown = true,
        values = ns.Conditions.VARIABLES, visible = CheckOnTrigger,
        get = function(aura) return CurCheck(aura).variable end,
        set = function(aura, value)
            local check = CurCheck(aura)
            local kind = ns.Conditions.KindOf(value)
            check.variable = value
            if kind == "bool" then check.op, check.value = "==", true
            elseif kind == "string" then check.op, check.value = "==", ""
            else check.op, check.value = ">=", 1 end
            Commit(false)
        end,
    },
    {
        kind = "text", label = "Value name", key = "checkField", width = 160,
        tip = "Any value of the trigger's state -- one a custom state updater sets, say.",
        visible = function(aura) return CheckOnTrigger(aura) and CurCheck(aura).variable == "custom" end,
        get = function(aura) return CurCheck(aura).field or "" end,
        set = function(aura, text) SetCheck(aura, "field", text ~= "" and text or nil) end,
    },
    {
        kind = "choice", label = "Is", key = "checkOpNumber", width = 44, values = NUMBER_OPS,
        visible = function(aura)
            local kind = CheckOnTrigger(aura) and CheckKind(aura)
            return kind == "number" or kind == "timer"
        end,
        get = function(aura) return CurCheck(aura).op or ">=" end,
        set = function(aura, value) SetCheck(aura, "op", value) end,
    },
    {
        kind = "choice", label = "Is", key = "checkOpString", width = 70, values = STRING_OPS,
        visible = function(aura) return CheckOnTrigger(aura) and CheckKind(aura) == "string" end,
        get = function(aura) return CurCheck(aura).op or "==" end,
        set = function(aura, value) SetCheck(aura, "op", value) end,
    },
    {
        kind = "choice", label = "Is", key = "checkBool", width = 60,
        values = { { text = "True", value = true }, { text = "False", value = false } },
        visible = function(aura) return CheckOnTrigger(aura) and CheckKind(aura) == "bool" end,
        get = function(aura) local v = CurCheck(aura).value return v == true or v == "true" end,
        set = function(aura, value) SetCheck(aura, "value", value) end,
    },
    {
        kind = "text", label = "Than", key = "checkValue", width = 120,
        tip = "Time left is in seconds. A value this client keeps secret never matches.",
        visible = function(aura)
            local kind = CheckOnTrigger(aura) and CheckKind(aura)
            return kind == "number" or kind == "timer" or kind == "string"
        end,
        get = function(aura) return tostring(CurCheck(aura).value or "") end,
        set = function(aura, text)
            local kind = CheckKind(aura)
            SetCheck(aura, "value", (kind == "string") and text or tonumber(text))
        end,
    },
    {
        kind = "code", label = "Custom check", key = "checkCode", height = 120,
        tip = "Given the triggers' states -- trigger[1].met, trigger[1].count, .name,"
           .. " .start, .duration -- return true when the condition holds.",
        visible = function(aura) return HasCheck(aura) and tonumber(CurCheck(aura).trigger) == -1 end,
        get = function(aura) return CurCheck(aura).value or "" end,
        set = function(aura, text) SetCheck(aura, "value", text) end,
        error = function(aura)
            if aura.untrusted then return "imported code: approve it on the Trigger tab" end
            local fn, err = ns.Env:Compile(CurCheck(aura).value, "condition")
            return (not fn) and err or nil
        end,
    },

    { kind = "header", label = "Then", visible = HasCond },
    {
        kind = "strip", key = "changeStrip", label = "Changes", max = 8,
        visible = HasCond,
        count = function(aura) return #((Cond(aura) or {}).changes or {}) end,
        current = function() return currentChange end,
        select = function(i) currentChange = i end,
        add = function(aura)
            local cond = Cond(aura)
            cond.changes = cond.changes or {}
            cond.changes[#cond.changes + 1] = { property = "glow", value = true }
            currentChange = #cond.changes
        end,
        remove = function(aura)
            local cond = Cond(aura)
            table.remove(cond.changes, currentChange)
            currentChange = math.max(1, currentChange - 1)
        end,
    },
    {
        kind = "choice", label = "Change", key = "changeProperty", width = 160, dropdown = true,
        values = ns.Conditions.PROPERTIES, visible = HasChange,
        get = function(aura) return Change(aura).property end,
        set = function(aura, value)
            local change = Change(aura)
            change.property = value
            local default = DEFAULT_VALUE[value]
            if type(default) == "table" then
                local copy = {}
                for k, v in pairs(default) do copy[k] = v end
                default = copy
            end
            change.value = default
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Opacity (per cent)", key = "changeAlpha", min = 0, max = 100,
        visible = ChangeIs("alpha"),
        get = function(aura) return tonumber(Change(aura).value) or 100 end,
        set = SetChangeValue,
    },
    {
        kind = "colour", label = "Color", key = "changeColour", visible = ChangeIs("color"),
        get = function(aura) return Hex(Change(aura).value) end,
        set = function(aura, hex) SetChangeValue(aura, FromHex(hex)) end,
    },
    {
        kind = "choice", label = "Set to", key = "changeBool", width = 60,
        values = { { text = "On", value = true }, { text = "Off", value = false } },
        visible = ChangeIs("desaturate", "glow"),
        get = function(aura) return Change(aura).value and true or false end,
        set = SetChangeValue,
    },
    {
        kind = "slider", label = "Size (times)", key = "changeScale", min = 0.5, max = 3, step = 0.1,
        visible = ChangeIs("scale"),
        get = function(aura) return tonumber(Change(aura).value) or 1 end,
        set = SetChangeValue,
    },
    {
        kind = "text", label = "Text", key = "changeText", width = 240,
        tip = "Replaces what the aura says while this holds. Text codes work: %s, %t, %n...",
        visible = ChangeIs("text"),
        get = function(aura) return tostring(Change(aura).value or "") end,
        set = SetChangeValue,
    },
    {
        kind = "sound", label = "Sound", key = "changeSound", visible = ChangeIs("sound"),
        get = function(aura)
            local v = Change(aura).value
            return type(v) == "table" and v.sound or v or ""
        end,
        set = function(aura, sound) SetChangeValue(aura, { sound = sound }) end,
    },
    {
        kind = "text", label = "Message", key = "changeMessage", width = 280,
        tip = "Text codes work. Said once, when the condition starts to hold.",
        visible = ChangeIs("chat"),
        get = function(aura)
            local v = Change(aura).value
            return type(v) == "table" and v.message or ""
        end,
        set = function(aura, text)
            local v = Change(aura).value
            v = type(v) == "table" and v or {}
            v.message = text
            SetChangeValue(aura, v)
        end,
    },
    {
        kind = "choice", label = "Where", key = "changeChannel", width = 64,
        values = { { text = "Me only", value = "PRINT" }, { text = "Say", value = "SAY" },
                   { text = "Party", value = "PARTY" }, { text = "Raid", value = "RAID" },
                   { text = "Guild", value = "GUILD" } },
        visible = ChangeIs("chat"),
        get = function(aura)
            local v = Change(aura).value
            return type(v) == "table" and v.channel or "PRINT"
        end,
        set = function(aura, channel)
            local v = Change(aura).value
            v = type(v) == "table" and v or {}
            v.channel = channel
            SetChangeValue(aura, v)
        end,
    },
    {
        kind = "code", label = "Custom code", key = "changeCode", height = 120,
        tip = "Runs once, when the condition starts to hold. aura_env is the aura's table.",
        visible = ChangeIs("customcode"),
        get = function(aura)
            local v = Change(aura).value
            return type(v) == "table" and v.custom or ""
        end,
        set = function(aura, text) SetChangeValue(aura, { custom = text }) end,
        error = function(aura)
            if aura.untrusted then return "imported code: approve it on the Trigger tab" end
            local v = Change(aura).value
            local fn, err = ns.Env:Compile(type(v) == "table" and v.custom or "", "condition code")
            return (not fn and err ~= "empty") and err or nil
        end,
    },
}
Config.__conditionFields = CONDITION_FIELDS
function Config.__conditionCursor(a, b, c)
    if a then currentCondition, currentCheck, currentChange = a, b or 1, c or 1 end
    return currentCondition, currentCheck, currentChange
end

local CHAT_WHERE = {
    { text = "Me only", value = "PRINT" }, { text = "Say", value = "SAY" },
    { text = "Party", value = "PARTY" }, { text = "Raid", value = "RAID" },
    { text = "Guild", value = "GUILD" }, { text = "Yell", value = "YELL" },
}

local function ActionText(key, label, tip)
    return {
        kind = "text", label = label, key = key, width = 280, tip = tip,
        get = function(aura) return ns.ActionField(aura, key) end,
        set = function(aura, text)
            ActionsOf(aura)[key] = text ~= "" and text or nil
            Commit(false)
        end,
    }
end
local function ActionWhere(key)
    return {
        kind = "choice", label = "Where", key = key, width = 60, values = CHAT_WHERE,
        get = function(aura) return ns.ActionField(aura, key) end,
        set = function(aura, value)
            ActionsOf(aura)[key] = value
            Commit(false)
        end,
    }
end
local function ActionCode(key, label, tip)
    return {
        kind = "code", label = label, key = key, height = 110, tip = tip,
        hint = "function() ... end -- saved when you click away",
        get = function(aura)
            local source = ns.ActionField(aura, key)
            if source and source ~= "" then return source end
            return "function()\n    \nend"
        end,
        set = function(aura, text)
            local blank = text == "" or text == "function()\n    \nend"
            ActionsOf(aura)[key] = (not blank) and text or nil
            Commit(false)
        end,
        error = function(aura)
            local source = ns.ActionField(aura, key)
            if not source or source == "" then return nil end
            if aura.untrusted then return "imported code: approve it on the Trigger tab" end
            local fn, err = ns.Env:Compile(source, key)
            return (not fn) and err or nil
        end,
    }
end

local ACTION_FIELDS = {
    { kind = "header", label = "When it comes up" },
    SoundField("onShow", "Sound", SOUND_TIP),
    ActionText("onShowMessage", "Chat message",
        "Said once as it comes up. Text codes work: %n, %s, %t..."),
    ActionWhere("onShowChannel"),
    ActionCode("onShowCode", "Custom code", "Runs once as it comes up. aura_env.state is its state."),

    { kind = "header", label = "When it goes away" },
    SoundField("onHide", "Sound", SOUND_TIP),
    ActionText("onHideMessage", "Chat message", "Said once as it goes."),
    ActionWhere("onHideChannel"),
    ActionCode("onHideCode", "Custom code", "Runs once as it goes."),

    { kind = "header", label = "Glow another frame while it shows" },
    {
        kind = "choice", label = "Glow", key = "glowFrame", width = 220, dropdown = true,
        tip = "A glowing border on another frame while this aura shows -- WeakAuras' external"
           .. " glow. 'The spell's action button' finds the trigger's spell on your bars.",
        values = {
            { text = "Nothing", value = "none" },
            { text = "The spell's action button", value = "button" },
            { text = "Player frame", value = "player" }, { text = "Target frame", value = "target" },
            { text = "Focus frame", value = "focus" }, { text = "Pet frame", value = "pet" },
            { text = "A frame by name...", value = "name" },
        },
        get = function(aura) return ns.ActionField(aura, "glowFrame") end,
        set = function(aura, value)
            ActionsOf(aura).glowFrame = value ~= "none" and value or nil
            Commit(false)
        end,
    },
    {
        kind = "text", label = "Frame name", key = "glowFrameName", width = 200,
        tip = "The frame's global name, as /fstack shows it.",
        visible = function(aura) return ns.ActionField(aura, "glowFrame") == "name" end,
        get = function(aura) return ns.ActionField(aura, "glowFrameName") end,
        set = function(aura, text)
            ActionsOf(aura).glowFrameName = text ~= "" and text or nil
            Commit(false)
        end,
    },

    { kind = "header", label = "Custom code as it loads" },
    ActionCode("initCode", "On init", "Once, the first time the aura is set up (again after an edit)."),
    ActionCode("loadCode", "On load", "Each time its load conditions start to hold."),
    ActionCode("unloadCode", "On unload", "Each time they stop."),

    { kind = "header", label = "Sound channel" },
    {
        kind = "choice", label = "Channel", key = "channel", width = 78,
        tip = "Master ignores the sound-effects volume, which is usually what "
           .. "you want for something you asked to be told about.",
        values = { { text = "Master", value = "Master" },
                   { text = "SFX", value = "SFX" },
                   { text = "Ambience", value = "Ambience" },
                   { text = "Dialog", value = "Dialog" } },
        get = function(aura) return ns.ActionField(aura, "channel") end,
        set = function(aura, value)
            ActionsOf(aura).channel = value
            Commit(false)
        end,
    },
}

-- The offline tests drive these the way the window does, rather than poking at
-- the stored tables behind them, so a field that stops doing what it says is a
-- failing check instead of a surprise in the game.
-- Each piece of text gets its own font, outline and color, next to the rest
-- of its settings; the text codes' own options close the tab.
do
    local function InsertAfter(list, key, extra)
        for i, field in ipairs(list) do
            if field.key == key then
                for j, e in ipairs(extra) do table.insert(list, i + j, e) end
                return
            end
        end
    end
    -- An aura that shows while something is missing has no stacks or timer to
    -- show at that moment; text asking for them would always be empty.
    local function EmptyByInversion(formatKey)
        return function(aura)
            if ns.IsGroup(aura) or not ns.DisplayField(aura, "invert") then return false end
            local text = ns.DisplayField(aura, formatKey) or ""
            return text:find("%%[stpd]") ~= nil
        end
    end
    local INVERT_NOTE = "|cffffd100'Show when missing' is on: this aura shows only while the buff is"
        .. " missing, so there are no stacks or time left to show -- %s, %t and %p will be empty."
        .. " Turn it off to show them while the buff is up.|r"
    for _, key in ipairs({ "iconText", "textFormat", "barFormat" }) do
        InsertAfter(DISPLAY_FIELDS, key, { {
            kind = "note", key = key .. "InvertNote", text = INVERT_NOTE,
            visible = EmptyByInversion(key),
        } })
    end

    InsertAfter(DISPLAY_FIELDS, "iconTextSize",
        TextStyleFields("Icon text", "iconTextFont", "iconTextOutline", "iconTextColour", IsKind("icon")))
    InsertAfter(DISPLAY_FIELDS, "fontSize",
        TextStyleFields("Text", "textFont", "textOutline", "textColour", IsKind("text")))
    InsertAfter(DISPLAY_FIELDS, "barFormat", Append({
        {
            kind = "slider", label = "Bar text size", key = "barFontSize", min = 6, max = 32,
            enabled = IsKind("bar"),
            get = function(aura) return ns.DisplayField(aura, "barFontSize") end,
            set = function(aura, value)
                SetDisplay(aura, "barFontSize", value)
                Commit(false)
            end,
        },
    }, TextStyleFields("Bar text", "barFont", "barOutline", "barTextColour", IsKind("bar"))))

    local function HasText(aura)
        return not ns.IsGroup(aura)
    end
    Append(DISPLAY_FIELDS, {
        { kind = "header", label = "Text codes" },
        {
            kind = "note", key = "textCodesNote",
            text = "%n name, %s stacks, %i the icon, %c your custom text (%c1, %c2... for"
                .. " several), %stacks or %{field} any value of the trigger, %2.p trigger 2's."
                .. " ChairAuras codes: %t time left, %p per cent left, %d the full duration."
                .. " WeakAuras codes: %p time left, %t the full duration.",
        },
        {
            kind = "choice", label = "Codes", key = "textStyle", width = 100,
            tip = "Which meaning %t and %p have. Auras made here use ChairAuras'; ones"
               .. " imported from WeakAuras use WeakAuras'.",
            values = { { text = "ChairAuras", value = "chairauras" }, { text = "WeakAuras", value = "weakauras" } },
            enabled = HasText,
            get = function(aura) return ns.DisplayField(aura, "textStyle") end,
            set = function(aura, value)
                SetDisplay(aura, "textStyle", value)
                Commit(false)
            end,
        },
        {
            kind = "choice", label = "Time as", key = "timeFormat", width = 80,
            tip = "Auto: 2h, 4:05, 12, 3.4. Clock: 0:03. Seconds: 3.",
            values = { { text = "Auto", value = "auto" }, { text = "Clock", value = "clock" },
                       { text = "Seconds", value = "seconds" } },
            enabled = HasText,
            get = function(aura) return ns.DisplayField(aura, "timeFormat") end,
            set = function(aura, value)
                SetDisplay(aura, "timeFormat", value)
                Commit(false)
            end,
        },
        {
            kind = "slider", label = "Decimals", key = "timePrecision", min = 0, max = 3,
            tip = "Auto shows them under ten seconds; seconds always. A clock has none.",
            enabled = HasText,
            get = function(aura) return ns.DisplayField(aura, "timePrecision") end,
            set = function(aura, value)
                SetDisplay(aura, "timePrecision", value)
                Commit(false)
            end,
        },
        {
            kind = "code", label = "Custom text (%c)", key = "customText", height = 120,
            tip = "A Lua function; what it returns is %c, and %c1, %c2 for several values."
               .. " aura_env.state is the aura's state. Runs each time the text is drawn.",
            hint = "function() return ... end -- saved when you click away",
            enabled = HasText,
            get = function(aura)
                local source = ns.DisplayField(aura, "customText")
                if source and source ~= "" then return source end
                return "function()\n    return \"\"\nend"
            end,
            set = function(aura, text)
                local blank = text == "" or text == "function()\n    return \"\"\nend"
                SetDisplay(aura, "customText", (not blank) and text or nil)
                Commit(false)
            end,
            error = function(aura)
                local source = ns.DisplayField(aura, "customText")
                if not source or source == "" then return nil end
                if aura.untrusted then return "imported code: approve it on the Trigger tab" end
                local fn, err = ns.Env:Compile(source, "custom text")
                return (not fn) and err or nil
            end,
        },
    })
end

Config.__displayFields = DISPLAY_FIELDS
-------------------------------------------------------------------------------
-- The built-in trigger types' settings, made from their own descriptions
-------------------------------------------------------------------------------
-- Triggers.lua says what each type needs; the fields here are made from that,
-- shown only while their type is the one picked. The type picker lists them
-- all, and every setting that belongs to one kind of trigger -- Aura's,
-- Cooldown's, Custom's -- hides for the others, so the tab shows what applies.

do
    local function TypeIs(key)
        return function(aura)
            return not ns.IsGroup(aura) and ns.TriggerField(aura, "type", currentTrigger) == key
        end
    end

    local function Default(spec)
        if spec.default ~= nil then return spec.default end
        if spec.kind == "choice" and spec.values and spec.values[1] then return spec.values[1].value end
        if spec.kind == "slider" then return spec.min or 0 end
        if spec.kind == "check" then return false end
        return nil
    end

    local function ResolveItem(text)
        local id = tonumber(text)
        if id then return id end
        local item = _G.C_Item
        local getInstant = (item and item.GetItemInfoInstant) or _G.GetItemInfoInstant
        if type(getInstant) == "function" then
            local ok, found = pcall(getInstant, text)
            if ok and tonumber(found) then return tonumber(found) end
        end
        return nil
    end

    local function MakeField(typeKey, spec)
        local field = {}
        for k, v in pairs(spec) do field[k] = v end
        local shown = TypeIs(typeKey)
        field.visible, field.enabled = shown, shown
        local key = spec.key
        field.get = function(aura)
            local value = ns.Trigger(aura, currentTrigger)[key]
            if value == nil then value = Default(spec) end
            if spec.kind == "spell" then
                if not value then return "" end
                return ns.Engine:SpellName(value) .. " (" .. value .. ")"
            elseif spec.kind == "item" then
                if not value then return "" end
                local name = ns.ItemInfo and ns.ItemInfo(value)
                return (name or "item") .. " (" .. value .. ")"
            end
            return value
        end
        field.set = function(aura, value)
            local trigger = TriggerOf(aura)
            if spec.kind == "spell" then
                if value == "" then trigger[key] = nil Commit(true) return end
                local spellID = ns.ResolveSpell(value)
                if not spellID then
                    ns.Print("this client does not know that spell -- try its numeric ID.")
                    Config:Refresh()
                    return
                end
                trigger[key] = spellID
            elseif spec.kind == "item" then
                local itemID = ResolveItem(value)
                if not itemID then
                    ns.Print("could not find that item -- try its numeric ID, or drag it here.")
                    Config:Refresh()
                    return
                end
                trigger[key] = itemID
            elseif spec.kind == "check" then
                trigger[key] = value and true or nil
            elseif spec.kind == "text" then
                trigger[key] = (value ~= "") and value or nil
            else
                trigger[key] = value
            end
            Commit(true)
        end
        return field
    end

    -- The picker lists every type.
    for _, field in ipairs(TRIGGER_FIELDS) do
        if field.key == "type" and field.kind == "choice" then
            local GROUPS = {
                { "Auras & cooldowns", { "aura", "cooldown" } },
                { "Spells", { "usable", "known", "range", "charges", "cast" } },
                { "Items", { "itemcooldown", "slotcooldown", "itemcount", "equipped", "enchant" } },
                { "You", { "form", "threat", "xp", "reputation", "money", "status", "zone" } },
                { "Events", { "chat", "readycheck" } },
                { "Bars (display only)", { "health", "power" } },
                { "Custom", { "custom" } },
            }
            local names = { aura = "Aura", cooldown = "Cooldown", custom = "Custom Lua" }
            for key, def in pairs(ns.TriggerTypes or {}) do names[key] = def.text end
            local values, placed = {}, {}
            for _, group in ipairs(GROUPS) do
                values[#values + 1] = { header = group[1] }
                for _, key in ipairs(group[2]) do
                    if names[key] then
                        values[#values + 1] = { text = names[key], value = key }
                        placed[key] = true
                    end
                end
            end
            -- Anything registered and not in a group still gets listed.
            for _, key in ipairs(ns.TriggerTypeOrder or {}) do
                if not placed[key] then values[#values + 1] = { text = names[key], value = key } end
            end
            field.values = values
            field.width = 200
            field.dropdown = true
            field.tip = "What the trigger watches. Aura and Cooldown are the classics;"
                .. " Custom is your own Lua; the rest are WeakAuras' built-in"
                .. " triggers that this client can answer."
        end
    end

    -- What belongs to one kind of trigger hides for the others.
    for _, field in ipairs(TRIGGER_FIELDS) do
        if field.key ~= "type" and field.kind ~= "triggers" and field.key ~= "customTriggerLogic" then
            if field.kind == "header" then
                field.visible = IsCustom
            elseif field.enabled and not field.visible then
                field.visible = field.enabled
            end
        end
    end
    -- The custom activation box shows only when it is in use.
    for _, field in ipairs(TRIGGER_FIELDS) do
        if field.key == "customTriggerLogic" then field.visible = field.enabled end
    end

    -- And each built-in type's own settings, after a short description.
    for _, key in ipairs(ns.TriggerTypeOrder or {}) do
        local def = ns.TriggerTypes[key]
        TRIGGER_FIELDS[#TRIGGER_FIELDS + 1] = {
            kind = "header", label = def.text, visible = TypeIs(key),
        }
        if def.tip then
            TRIGGER_FIELDS[#TRIGGER_FIELDS + 1] = {
                kind = "note", key = key .. "Note", text = def.tip, visible = TypeIs(key),
            }
        end
        for _, spec in ipairs(def.fields or {}) do
            TRIGGER_FIELDS[#TRIGGER_FIELDS + 1] = MakeField(key, spec)
        end
    end
end

Config.__triggerFields = TRIGGER_FIELDS
function Config.__currentTrigger(n) if n then currentTrigger = n end return currentTrigger end
Config.__actionFields = ACTION_FIELDS

-- The Load tab is generated from the condition list, so the window and the
-- engine cannot disagree about what a condition is or what it is called.
local function BuildLoadFields()
    local fields = {
        { kind = "header", label = "Load only while" },
    }

    for _, condition in ipairs(ns.Load.CONDITIONS) do
        if condition.section then
            fields[#fields + 1] = { kind = "header", label = condition.section }
        end
        local key = condition.key
        local available = ns.Load:Available(condition)
        local tip = condition.tip
        if not available then
            tip = (tip and (tip .. "\n\n") or "")
                .. "This client cannot answer this one, so it is ignored."
        end

        if condition.kind == "toggle" then
            local hint = (tip and (tip .. "\n\n") or "")
                .. "Click through it: yes, then no, then off. Off means the "
                .. "condition is not asked at all."
            fields[#fields + 1] = {
                kind = "tristate", label = condition.label, tip = hint,
                key = key,
                enabled = function() return available end,
                get = function(aura) return (aura.load or {})[key] end,
                cycle = function(aura)
                    local value = (aura.load or {})[key]
                    -- nil -> true -> false -> nil
                    local next
                    if value == nil then
                        next = true
                    elseif value == true then
                        next = false
                    else
                        next = nil
                    end
                    SetLoad(aura, key, next)
                    Commit(false)
                end,
            }

        elseif condition.kind == "set" then
            fields[#fields + 1] = {
                kind = "set", label = condition.label, tip = tip, key = key,
                values = condition.values,
                perRow = 3,
                enabled = function() return available end,
                get = function(aura) return (aura.load or {})[key] end,
                set = function(aura, value, checked)
                    local chosen = CopyValue((aura.load or {})[key]) or {}
                    chosen[value] = checked or nil
                    SetLoad(aura, key, next(chosen) and chosen or nil)
                    Commit(false)
                end,
            }

        elseif condition.kind == "range" then
            fields[#fields + 1] = {
                kind = "range", label = condition.label, tip = tip, key = key,
                enabled = function() return available end,
                get = function(aura) return (aura.load or {})[key] end,
                set = function(aura, side, text)
                    local range = CopyValue((aura.load or {})[key]) or {}
                    range[side] = tonumber(text)
                    SetLoad(aura, key, next(range) and range or nil)
                    Commit(false)
                end,
            }

        elseif condition.kind == "text" then
            fields[#fields + 1] = {
                kind = "text", label = condition.label, tip = tip, key = key,
                enabled = function() return available end,
                get = function(aura) return (aura.load or {})[key] or "" end,
                set = function(aura, text)
                    SetLoad(aura, key, (text ~= "" and text) or nil)
                    Commit(false)
                end,
            }
        end
    end

    Config.__loadFields = fields
    return fields
end

-------------------------------------------------------------------------------
-- Editor assembly
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Animations tab
-------------------------------------------------------------------------------
-- One slot at a time -- start, main, finish -- in WeakAuras' own fields, so
-- an imported aura's animations read back as they were written.

local currentAnim = "start"
function Config.__animCursor(which)
    if which then currentAnim = which end
    return currentAnim
end

local function AnimValue(aura, key, default)
    local list = aura.animation
    local anim = type(list) == "table" and list[currentAnim]
    local value = type(anim) == "table" and anim[key]
    if value == nil then return default end
    return value
end

-- Set on the aura; on a group, on everything inside it as well, like the rest
-- of a group's look. A running animation starts again with the change.
local function SetAnim(aura, key, value)
    local targets = { aura }
    if ns.IsGroup(aura) then
        for _, child in ipairs(ns.Descendants(aura.id)) do targets[#targets + 1] = child end
    end
    for _, target in ipairs(targets) do
        target.animation = type(target.animation) == "table" and target.animation or {}
        local anim = target.animation[currentAnim]
        if type(anim) ~= "table" then
            anim = { type = "none" }
            target.animation[currentAnim] = anim
        end
        anim[key] = CopyValue(value)
        if ns.Animations then
            for frame in pairs(ns.Animations.__running) do
                if frame.auraID == target.id then ns.Animations:Stop(frame) end
            end
        end
    end
    Commit(false)
end

local function AnimType(aura) return AnimValue(aura, "type", "none") end
local function AnimCustom(aura) return AnimType(aura) == "custom" end
local function AnimUses(part)
    return function(aura) return AnimCustom(aura) and AnimValue(aura, "use_" .. part, false) and true or false end
end
local function AnimPathIs(part, kind)
    return function(aura)
        return AnimUses(part)(aura) and AnimValue(aura, part .. "Type") == kind
    end
end

local ANIM_PATHS = {
    alpha = { { "Normal", "straight" }, { "Pulse", "alphaPulse" }, { "Hide", "hide" },
              { "Custom function", "custom" } },
    translate = { { "Normal", "straightTranslate" }, { "Circle", "circle" }, { "Spiral", "spiral" },
                  { "Spiral in and out", "spiralandpulse" }, { "Shake", "shake" }, { "Bounce", "bounce" },
                  { "Bounce with decay", "bounceDecay" }, { "Custom function", "custom" } },
    scale = { { "Normal", "straightScale" }, { "Pulse", "pulse" }, { "Spin", "fauxspin" },
              { "Flip", "fauxflip" }, { "Custom function", "custom" } },
    rotate = { { "Normal", "straight" }, { "Back and forth", "backandforth" }, { "Wobble", "wobble" },
               { "Custom function", "custom" } },
    color = { { "Gradient", "straightColor" }, { "Gradient pulse", "pulseColor" },
              { "Custom function", "custom" } },
}
local ANIM_DEFAULT_PATH = {
    alpha = "straight", translate = "straightTranslate", scale = "straightScale",
    rotate = "straight", color = "straightColor",
}
local ANIM_TEMPLATES = {
    alpha = "function(progress, start, delta)\n    return start + (progress * delta)\nend",
    translate = "function(progress, startX, startY, deltaX, deltaY)\n"
        .. "    return startX + (progress * deltaX), startY + (progress * deltaY)\nend",
    scale = "function(progress, startX, startY, scaleX, scaleY)\n"
        .. "    return startX + (progress * (scaleX - startX)), startY + (progress * (scaleY - startY))\nend",
    rotate = "function(progress, start, delta)\n    return start + (progress * delta)\nend",
    color = "function(progress, r1, g1, b1, a1, r2, g2, b2, a2)\n"
        .. "    return r1 + (progress * (r2 - r1)), g1 + (progress * (g2 - g1)),\n"
        .. "           b1 + (progress * (b2 - b1)), a1 + (progress * (a2 - a1))\nend",
}

local function AnimCheck(part, label, tip)
    return {
        kind = "check", label = label, key = "use_" .. part, tip = tip, visible = AnimCustom,
        get = function(aura) return AnimValue(aura, "use_" .. part, false) end,
        set = function(aura, checked) SetAnim(aura, "use_" .. part, checked and true or nil) end,
    }
end
local function AnimNumber(key, label, low, high, part, scale, default, step)
    scale = scale or 1
    return {
        kind = "slider", label = label, key = key, min = low, max = high, step = step,
        visible = AnimUses(part),
        get = function(aura) return (tonumber(AnimValue(aura, key, default)) or 0) * scale end,
        set = function(aura, value) SetAnim(aura, key, value / scale) end,
    }
end
local function AnimPath(part)
    local values = {}
    for i, entry in ipairs(ANIM_PATHS[part]) do values[i] = { text = entry[1], value = entry[2] } end
    return {
        kind = "choice", label = "Path", key = part .. "Type", width = 180, dropdown = true,
        values = values, visible = AnimUses(part),
        get = function(aura) return AnimValue(aura, part .. "Type", ANIM_DEFAULT_PATH[part]) end,
        set = function(aura, value) SetAnim(aura, part .. "Type", value) end,
    }
end
local function AnimCode(part)
    local key = part .. "Func"
    return {
        kind = "code", label = "Function", key = key, height = 120,
        visible = AnimPathIs(part, "custom"),
        hint = "WeakAuras' signature -- saved when you click away",
        get = function(aura)
            local source = AnimValue(aura, key)
            if source and source ~= "" then return source end
            return ANIM_TEMPLATES[part]
        end,
        set = function(aura, text)
            local blank = text == "" or text == ANIM_TEMPLATES[part]
            SetAnim(aura, key, (not blank) and text or nil)
        end,
        error = function(aura)
            local source = AnimValue(aura, key)
            if not source or source == "" then return nil end
            if aura.untrusted then return "imported code: approve it on the Trigger tab" end
            local fn, err = ns.Env:Compile(source, key)
            return (not fn) and err or nil
        end,
    }
end

local function PresetField(slot)
    local values = {}
    for i, entry in ipairs(ns.Animations.SLOT_PRESETS[slot]) do
        values[i] = { text = entry[2], value = entry[1] }
    end
    return {
        kind = "choice", label = "Preset", key = "preset_" .. slot, width = 180, dropdown = true,
        values = values,
        visible = function(aura) return currentAnim == slot and AnimType(aura) == "preset" end,
        get = function(aura) return AnimValue(aura, "preset") end,
        set = function(aura, value) SetAnim(aura, "preset", value) end,
    }
end

local ANIMATION_FIELDS = {
    {
        kind = "choice", label = "Animation", key = "animSlot", width = 70,
        tip = "Start plays as it comes up, main loops while it shows, finish plays as it goes.",
        values = { { text = "Start", value = "start" }, { text = "Main", value = "main" },
                   { text = "Finish", value = "finish" } },
        get = function() return currentAnim end,
        set = function(_, value)
            currentAnim = value
            Config:Refresh()
        end,
    },
    {
        kind = "choice", label = "Type", key = "animType", width = 70,
        values = { { text = "None", value = "none" }, { text = "Preset", value = "preset" },
                   { text = "Custom", value = "custom" } },
        get = function(aura) return AnimType(aura) end,
        set = function(aura, value)
            SetAnim(aura, "type", value)
            if value == "preset" and not AnimValue(aura, "preset") then
                SetAnim(aura, "preset", ns.Animations.SLOT_PRESETS[currentAnim][1][1])
            end
        end,
    },
    PresetField("start"), PresetField("main"), PresetField("finish"),
    {
        kind = "button", label = "Play it", text = "Play it", key = "animPreview",
        tip = "Plays this one on the aura now.",
        visible = function(aura) return AnimType(aura) ~= "none" and not ns.IsGroup(aura) end,
        click = function(aura)
            local frame = ns.Display.__regions[aura.id]
            if frame and ns.Animations then ns.Animations:Play(frame, aura, currentAnim) end
        end,
    },
    {
        kind = "slider", label = "Duration (tenths of a second)", key = "animDuration",
        min = 1, max = 100, visible = AnimCustom,
        get = function(aura) return math.floor((tonumber(AnimValue(aura, "duration", 0.25)) or 0.25) * 10 + 0.5) end,
        set = function(aura, value) SetAnim(aura, "duration", value / 10) end,
    },
    {
        kind = "choice", label = "Duration is", key = "duration_type", width = 130,
        values = { { text = "Seconds", value = "seconds" },
                   { text = "Of the timer", value = "relative" } },
        tip = "Of the timer: one pass takes that share of the aura's own duration, so it speeds up as it runs out.",
        visible = function(aura) return AnimCustom(aura) and currentAnim == "main" end,
        get = function(aura) return AnimValue(aura, "duration_type", "seconds") end,
        set = function(aura, value) SetAnim(aura, "duration_type", value) end,
    },
    {
        kind = "choice", label = "Easing", key = "easeType", width = 100,
        values = { { text = "None", value = "none" }, { text = "Ease in", value = "easeIn" },
                   { text = "Ease out", value = "easeOut" }, { text = "In and out", value = "easeOutIn" } },
        visible = AnimCustom,
        get = function(aura) return AnimValue(aura, "easeType", "none") end,
        set = function(aura, value) SetAnim(aura, "easeType", value) end,
    },
    {
        kind = "slider", label = "Ease strength", key = "easeStrength", min = 1, max = 5,
        visible = function(aura) return AnimCustom(aura) and AnimValue(aura, "easeType", "none") ~= "none" end,
        get = function(aura) return AnimValue(aura, "easeStrength", 3) end,
        set = function(aura, value) SetAnim(aura, "easeStrength", value) end,
    },

    { kind = "header", label = "Fade", visible = AnimCustom },
    AnimCheck("alpha", "Fade", "To this opacity; a start animation fades in from it."),
    AnimNumber("alpha", "Opacity (%)", 0, 100, "alpha", 100, 0),
    AnimPath("alpha"), AnimCode("alpha"),

    { kind = "header", label = "Move", visible = AnimCustom },
    AnimCheck("translate", "Move", "By this much from where it sits."),
    AnimNumber("x", "Across", -400, 400, "translate", 1, 0),
    AnimNumber("y", "Up", -400, 400, "translate", 1, 0),
    AnimPath("translate"), AnimCode("translate"),

    { kind = "header", label = "Zoom", visible = AnimCustom },
    AnimCheck("scale", "Zoom", "To this size, per cent of its own."),
    AnimNumber("scalex", "Width (%)", 0, 500, "scale", 100, 1),
    AnimNumber("scaley", "Height (%)", 0, 500, "scale", 100, 1),
    AnimPath("scale"), AnimCode("scale"),

    { kind = "header", label = "Rotate", visible = AnimCustom },
    AnimCheck("rotate", "Rotate", "Turns an icon's or a texture's picture."),
    AnimNumber("rotate", "Degrees", -360, 360, "rotate", 1, 0),
    AnimPath("rotate"), AnimCode("rotate"),

    { kind = "header", label = "Color", visible = AnimCustom },
    AnimCheck("color", "Color", "To this color."),
    {
        kind = "colour", label = "To", key = "animColour", visible = AnimUses("color"),
        get = function(aura)
            local r = tonumber(AnimValue(aura, "colorR", 1)) or 1
            local g = tonumber(AnimValue(aura, "colorG", 1)) or 1
            local b = tonumber(AnimValue(aura, "colorB", 1)) or 1
            return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
                                 math.floor(b * 255 + 0.5))
        end,
        set = function(aura, hex)
            hex = hex or "ffffff"
            SetAnim(aura, "colorR", (tonumber(hex:sub(1, 2), 16) or 255) / 255)
            SetAnim(aura, "colorG", (tonumber(hex:sub(3, 4), 16) or 255) / 255)
            SetAnim(aura, "colorB", (tonumber(hex:sub(5, 6), 16) or 255) / 255)
        end,
    },
    AnimPath("color"), AnimCode("color"),
}
Config.__animationFields = ANIMATION_FIELDS

-------------------------------------------------------------------------------
-- Options tab: custom options
-------------------------------------------------------------------------------
-- WeakAuras' Custom Options: settings an aura's author offers, which its code
-- reads as aura_env.config. The top is for using them; author mode, below,
-- makes them.

local authorMode = false
local currentOption = 1
function Config.__optionCursor(i, mode)
    if i then currentOption = i end
    if mode ~= nil then authorMode = mode end
    return currentOption, authorMode
end

local function OptionList(aura) return type(aura.authorOptions) == "table" and aura.authorOptions or nil end
local function CurOption(aura)
    local list = OptionList(aura)
    return list and list[currentOption]
end
local function Authoring(aura) return authorMode and CurOption(aura) ~= nil end
local function OptionIs(...)
    local wanted = {}
    for i = 1, select("#", ...) do wanted[select(i, ...)] = true end
    return function(aura)
        local option = CurOption(aura)
        return authorMode and option ~= nil and wanted[option.type or "input"] and true or false
    end
end

local function OptionsChanged(aura)
    ns.Env:RefreshConfig(aura)
    Commit(false)
end

local OPTION_TYPES = {
    { text = "Toggle", value = "toggle" }, { text = "Text", value = "input" },
    { text = "Number", value = "number" }, { text = "Slider", value = "range" },
    { text = "Color", value = "color" }, { text = "Choice", value = "select" },
    { text = "Several choices", value = "multiselect" }, { text = "Media (a path)", value = "media" },
    { text = "Heading", value = "header" }, { text = "Description", value = "description" },
    { text = "Space", value = "space" },
}
-- What a fresh option of each type starts with.
local OPTION_DEFAULTS = {
    toggle = false, input = "", number = 0, range = 0, color = { 1, 1, 1, 1 },
    select = 1, multiselect = {}, media = "",
}

local function OptionText(key, label, visible, tip)
    return {
        kind = "text", label = label, key = key, width = 240, visible = visible, tip = tip,
        get = function(aura)
            local option = CurOption(aura)
            local value = option and option[key:gsub("^opt", ""):lower()]
            return value ~= nil and tostring(value) or ""
        end,
        set = function(aura, text)
            local option = CurOption(aura)
            if not option then return end
            option[key:gsub("^opt", ""):lower()] = text ~= "" and text or nil
            OptionsChanged(aura)
        end,
    }
end
local function OptionNumber(field, label, visible)
    return {
        kind = "text", label = label, key = "opt_" .. field, width = 80, visible = visible,
        get = function(aura)
            local option = CurOption(aura)
            return option and option[field] ~= nil and tostring(option[field]) or ""
        end,
        set = function(aura, text)
            local option = CurOption(aura)
            if not option then return end
            option[field] = tonumber(text)
            OptionsChanged(aura)
        end,
    }
end

local OPTION_FIELDS = {
    { kind = "header", label = "Custom options" },
    {
        kind = "authoroptions", key = "authorOptions",
        empty = "This aura has no custom options. Author mode, below, adds settings "
             .. "for its code to read as aura_env.config; an aura shared with them brings them along.",
        set = function(aura, path, value)
            aura.config = type(aura.config) == "table" and aura.config or {}
            local t = aura.config
            for i = 1, #path - 1 do
                if type(t[path[i]]) ~= "table" then t[path[i]] = {} end
                t = t[path[i]]
            end
            t[path[#path]] = value
            OptionsChanged(aura)
        end,
    },
    {
        kind = "button", label = "Reset to defaults", text = "Reset to defaults", key = "optReset",
        visible = function(aura) return OptionList(aura) ~= nil end,
        click = function(aura)
            aura.config = nil
            OptionsChanged(aura)
        end,
    },
    {
        kind = "check", label = "Author mode", key = "authorMode",
        tip = "Make the options: add them, name them, set their defaults.",
        get = function() return authorMode end,
        set = function(_, checked)
            authorMode = checked and true or false
            Config:Refresh()
        end,
    },
    {
        kind = "strip", label = "Options", key = "optionStrip", max = 20,
        visible = function() return authorMode end,
        empty = "none yet -- + adds one",
        count = function(aura) local list = OptionList(aura) return list and #list or 0 end,
        current = function() return currentOption end,
        select = function(i) currentOption = i end,
        add = function(aura)
            aura.authorOptions = OptionList(aura) or {}
            local n = #aura.authorOptions + 1
            aura.authorOptions[n] = { type = "toggle", key = "option" .. n, name = "Option " .. n, default = false }
            currentOption = n
            ns.Env:RefreshConfig(aura)
        end,
        remove = function(aura)
            local list = OptionList(aura)
            if not list then return end
            table.remove(list, currentOption)
            if #list == 0 then aura.authorOptions = nil end
            currentOption = math.max(1, currentOption - 1)
            ns.Env:RefreshConfig(aura)
        end,
        move = function(aura, step)
            local list = OptionList(aura)
            local to = currentOption + step
            if not list or not list[to] then return end
            list[currentOption], list[to] = list[to], list[currentOption]
            currentOption = to
        end,
    },
    {
        kind = "choice", label = "Type", key = "optType", width = 200, dropdown = true,
        values = OPTION_TYPES, visible = Authoring,
        get = function(aura) local option = CurOption(aura) return option and (option.type or "input") end,
        set = function(aura, value)
            local option = CurOption(aura)
            if not option then return end
            option.type = value
            local default = OPTION_DEFAULTS[value]
            option.default = type(default) == "table" and CopyValue(default) or default
            if value == "range" then option.min, option.max, option.step = 0, 100, 1 end
            if (value == "select" or value == "multiselect") and type(option.values) ~= "table" then
                option.values = { "First", "Second" }
            end
            OptionsChanged(aura)
        end,
    },
    OptionText("optKey", "Key (aura_env.config.<key>)",
        OptionIs("toggle", "input", "number", "range", "color", "select", "multiselect", "media")),
    OptionText("optName", "Name", OptionIs("toggle", "input", "number", "range", "color", "select",
        "multiselect", "media", "header")),
    OptionText("optDesc", "Tooltip", OptionIs("toggle", "input", "number", "range", "color", "select",
        "multiselect", "media")),
    OptionText("optText", "Text", OptionIs("header", "description")),
    {
        kind = "text", label = "Default", key = "optDefault", width = 160,
        tip = "true or false for a toggle, a number for a number or slider, the choice's number for a choice.",
        visible = OptionIs("toggle", "input", "number", "range", "select", "media"),
        get = function(aura)
            local option = CurOption(aura)
            return option and option.default ~= nil and tostring(option.default) or ""
        end,
        set = function(aura, text)
            local option = CurOption(aura)
            if not option then return end
            local kind = option.type or "input"
            if kind == "toggle" then option.default = (text == "true")
            elseif kind == "number" or kind == "range" or kind == "select" then option.default = tonumber(text)
            else option.default = text end
            OptionsChanged(aura)
        end,
    },
    OptionNumber("min", "Lowest", OptionIs("range", "number")),
    OptionNumber("max", "Highest", OptionIs("range", "number")),
    OptionNumber("step", "Step", OptionIs("range", "number")),
    {
        kind = "text", label = "Choices, split by commas", key = "optValues", width = 300,
        visible = OptionIs("select", "multiselect"),
        get = function(aura)
            local option = CurOption(aura)
            return option and type(option.values) == "table" and table.concat(option.values, ", ") or ""
        end,
        set = function(aura, text)
            local option = CurOption(aura)
            if not option then return end
            local values = {}
            for part in text:gmatch("[^,]+") do
                part = part:match("^%s*(.-)%s*$")
                if part ~= "" then values[#values + 1] = part end
            end
            option.values = values
            OptionsChanged(aura)
        end,
    },
}
Config.__optionFields = OPTION_FIELDS

local TABS = {
    { key = "trigger",    text = "Trigger",    width = 60 },
    { key = "display",    text = "Display",    width = 60 },
    { key = "conditions", text = "Conditions", width = 74 },
    { key = "load",       text = "Load",       width = 46 },
    { key = "actions",    text = "Actions",    width = 60 },
    { key = "animations", text = "Animations", width = 78 },
    { key = "options",    text = "Options",    width = 60 },
}

local function BuildEditor(parent)
    editor = CreateFrame("Frame", nil, parent)
    editor:SetPoint("TOPLEFT", parent, "TOPLEFT", LIST_W + 32, -76)
    editor:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -16, 44)

    local hint = Text(editor, "Select something on the left,\nor add an aura below.",
                      "GameFontDisableLarge")
    hint:SetPoint("CENTER", editor, "CENTER", 0, 40)
    hint:SetJustifyH("CENTER")
    editor.hint = hint

    local body = CreateFrame("Frame", nil, editor)
    body:SetAllPoints()
    editor.body = body

    -- Name, above the tabs: it applies to an icon and a group alike, and it is
    -- the first thing anyone wants after making one.
    local nameLabel = Text(body, "Name", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -4)

    local nameBox = EditBox(body, 250, function(text)
        if selectedID then Config:Rename(selectedID, text) end
    end, true)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    editor.nameBox = nameBox
    Tooltip(nameLabel, "Name",
        "What this is called in the list and on its outline while unlocked. "
        .. "Leave it empty and it is called after whatever it watches.")

    local nameHint = Text(body, "optional", "GameFontDisableSmall")
    nameHint:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)

    -- Tabs
    editor.tabButtons = {}
    for index, tab in ipairs(TABS) do
        local button = Button(body, tab.text, tab.width or 70, function()
            Config:SetTab(tab.key)
        end)
        if index == 1 then
            button:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -32)
        else
            button:SetPoint("LEFT", editor.tabButtons[index - 1], "RIGHT", 4, 0)
        end
        button.key = tab.key
        editor.tabButtons[index] = button
    end

    -- Panes live inside one scroll frame each, because the Load tab is taller
    -- than the window and the others are not far off.
    editor.panes = {}
    local specs = {
        trigger = TRIGGER_FIELDS,
        display = DISPLAY_FIELDS,
        conditions = CONDITION_FIELDS,
        load    = BuildLoadFields(),
        actions = ACTION_FIELDS,
        animations = ANIMATION_FIELDS,
        options = OPTION_FIELDS,
    }

    for key, fields in pairs(specs) do
        local scroll = CreateFrame("ScrollFrame", "ChairAurasPane" .. key, body,
                                   "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -62)
        scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -24, 34)

        local pane = BuildPane(scroll, fields)
        scroll:SetScrollChild(pane)
        pane:SetHeight(math.max(pane.contentHeight, 1))
        pane:Show()
        scroll:Hide()

        editor.panes[key] = { scroll = scroll, pane = pane }
        Config.__panes = editor.panes
    end

    -- Parent
    local parentLabel = Text(body, "Inside group", "GameFontNormalSmall")
    parentLabel:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 10)
    editor.parentLabel = parentLabel

    local parentBox = EditBox(body, 150, function(text)
        local aura = Current()
        if not aura then return end
        Config:SetParentByName(aura, text)
    end)
    parentBox:SetPoint("LEFT", parentLabel, "RIGHT", 8, 0)
    editor.parentBox = parentBox
    Tooltip(parentLabel, "Inside group",
        "Type the name of a group to put this in it, or leave it empty to take "
        .. "it out. Groups are listed above with [group] or [dynamic] in front.")

    local remove = Button(body, "Delete", 80, function()
        Config:DeleteSelected()
    end)
    remove:SetPoint("LEFT", parentBox, "RIGHT", 12, 0)
    Tooltip(remove, "Delete", "Deleting a group leaves its children behind, "
        .. "outside any group -- nothing is ever removed twice over. With several "
        .. "selected (ctrl-click), deletes them all.")

    -- With several selected: this tab's settings onto all of them.
    local copyTab = Button(body, "Copy tab to selected", 150, function()
        local n = Config:CopyTabToSelected()
        ns.Print("copied to " .. n .. ".")
    end)
    copyTab:SetPoint("LEFT", remove, "RIGHT", 8, 0)
    Tooltip(copyTab, "Copy this tab to the selected",
        "Ctrl-click auras in the list to select several; this copies what is on the open tab "
        .. "from this one onto the rest.")
    editor.copyTab = copyTab
end

local function RefreshEditor()
    local aura = Current()

    if not aura then
        editor.hint:Show()
        editor.body:Hide()
        return
    end

    editor.hint:Hide()
    editor.body:Show()
    local selectedCount = #Config:SelectedList()
    editor.copyTab:SetShown(selectedCount > 1)
    editor.copyTab:SetText("Copy tab to " .. (selectedCount - 1) .. " more")

    for _, button in ipairs(editor.tabButtons) do
        if button.key == currentTab then
            button:LockHighlight()
        else
            button:UnlockHighlight()
        end
    end

    for key, entry in pairs(editor.panes) do
        if key == currentTab then
            entry.pane:Read(aura)
            entry.scroll:Show()
        else
            entry.scroll:Hide()
        end
    end

    if not editor.nameBox:HasFocus() then
        -- The name it has, not the name it shows: the spell it is called after
        -- would look like a name someone had typed, and editing it would turn
        -- a borrowed label into a real one by accident.
        editor.nameBox:SetText(aura.name or "")
        editor.nameBox:SetCursorPosition(0)
    end

    if not editor.parentBox:HasFocus() then
        local parent = aura.parent and ns.FindAura(aura.parent)
        editor.parentBox:SetText(parent and (parent.name or parent.id) or "")
        editor.parentBox:SetCursorPosition(0)
    end
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

-- Which row the cursor is over, and whether it is over the middle of a group
-- rather than its edge. The middle means "inside"; the top and bottom thirds
-- mean "beside", so a group can still be reordered among its siblings instead
-- of swallowing everything dropped near it.
function Config:RowUnderCursor()
    local scale = UIParent:GetEffectiveScale()
    local _, cursorY = GetCursorPosition()
    if not cursorY then return nil end
    cursorY = cursorY / scale

    for _, row in ipairs(rows) do
        if row:IsShown() and row.auraID then
            local top = row:GetTop()
            local bottom = row:GetBottom()
            if top and bottom and cursorY <= top and cursorY >= bottom then
                local aura = ns.FindAura(row.auraID)
                local height = top - bottom
                -- The top of a row is above it and the bottom below; the
                -- middle of a group is inside it.
                if ns.IsGroup(aura) and cursorY < top - height / 3 and cursorY > bottom + height / 3 then
                    return row.auraID, "inside"
                end
                return row.auraID, (cursorY >= bottom + height / 2) and "before" or "after"
            end
        end
    end

    -- Below the last row: the end of the list.
    local last
    for _, row in ipairs(rows) do
        if row:IsShown() and row.auraID then last = row end
    end
    local bottom = last and last:GetBottom()
    if bottom and cursorY < bottom then return "END", "end" end
    return nil
end

-- The mark that shows where a dragged row will land: a line between rows, or
-- the group it will go inside lit up. And the list scrolls when the cursor is
-- held near its top or bottom.
ShowDropMark = function()
    local marker, glow = Config.dropLine, Config.dropGlow
    if not (marker and glow) then return end
    marker:Hide()
    glow:Hide()
    local target, where = Config:RowUnderCursor()
    if not target or target == Config.dragging then return end
    local row
    if where == "end" then
        for _, one in ipairs(rows) do if one:IsShown() and one.auraID then row = one end end
        where = "after"
    else
        for _, one in ipairs(rows) do if one.auraID == target and one:IsShown() then row = one end end
    end
    if not row then return end
    if where == "inside" then
        glow:ClearAllPoints()
        glow:SetAllPoints(row)
        glow:Show()
    else
        marker:ClearAllPoints()
        local point = (where == "before") and "TOP" or "BOTTOM"
        marker:SetPoint("LEFT", row, point .. "LEFT", 0, 0)
        marker:SetPoint("RIGHT", row, point .. "RIGHT", 0, 0)
        marker:Show()
    end
end

AutoScroll = function()
    local scroll = Config.listScroll
    if not scroll then return end
    local scale = UIParent:GetEffectiveScale()
    local _, cursorY = GetCursorPosition()
    local top, bottom = scroll:GetTop(), scroll:GetBottom()
    if not (cursorY and top and bottom) then return end
    cursorY = cursorY / scale
    local at = scroll:GetVerticalScroll() or 0
    local most = scroll:GetVerticalScrollRange() or 0
    if cursorY > top - 20 then
        scroll:SetVerticalScroll(math.max(0, at - 6))
    elseif cursorY < bottom + 20 then
        scroll:SetVerticalScroll(math.min(most, at + 6))
    end
end

function Config:Select(id)
    if id ~= selectedID then
        currentTrigger = 1
        currentCondition, currentCheck, currentChange = 1, 1, 1
        currentText = 1
        currentOption = 1
    end
    selectedID = id
    self:Refresh()
end

-- Naming is a property of the thing itself, not of how it is drawn, so it is
-- reachable from anywhere rather than living inside one tab. The window and
-- /chair auras rename both come through here.
function Config:Rename(id, text)
    local aura = ns.FindAura(id)
    if not aura then return false end

    text = text and text:match("^%s*(.-)%s*$") or ""
    -- Cleared rather than set to the empty string: an aura with no name of its
    -- own is called after whatever it watches, and that is a real state worth
    -- being able to get back to.
    aura.name = (text ~= "") and text or nil

    ns.Display:ApplyLock()   -- the unlocked outline carries the name
    Commit(false)
    return true
end

-- What a group has been told is what anything put into it starts out with:
-- how it looks, and when it loads. Not the trigger -- that is the whole reason
-- the new aura exists and is nobody else's business.
--
-- Only fills gaps, so an aura that already says something for itself keeps it.
function Config:InheritDisplay(aura)
    local parent = aura.parent and ns.FindAura(aura.parent)
    if not parent then return end

    for _, which in ipairs({ "display", "load" }) do
        local inherited = parent[which]
        if inherited then
            local own = ns.SubTable(aura, which)
            for key, value in pairs(inherited) do
                -- PERSONAL only applies to display; a load condition is never
                -- one of those keys, so the one test covers both tables.
                if own[key] == nil and not PERSONAL[key] then
                    own[key] = CopyValue(value)
                end
            end
        end
    end
end

function Config:AddAura(spellID)
    local profile = ns.GetProfile()
    if not profile then return end

    local aura = {
        id = ns.NextID(profile),
        type = "icon",
        trigger = { spellID = spellID },
    }

    -- Added into whatever is selected, if that is a group: adding six things to
    -- a group one after another without having to re-home each one is most of
    -- what a group is for.
    local selected = Current()
    if selected then
        if ns.IsGroup(selected) then
            aura.parent = selected.id
        elseif selected.parent then
            aura.parent = selected.parent
        end
    end

    Config:InheritDisplay(aura)
    profile.auras[#profile.auras + 1] = aura
    selectedID = aura.id
    Commit(true)
end

-- Watching the words on an aura rather than a spell behind it. Well Fed is the
-- example everyone means: a different spell ID for every meal, all wearing the
-- same name, and no ID worth writing down. Nothing here consults the spellbook,
-- which is the point -- the text is the whole trigger.
function Config:AddNamed(text)
    local profile = ns.GetProfile()
    if not profile then return nil end

    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return nil end

    local aura = {
        id = ns.NextID(profile),
        type = "icon",
        name = text,
        trigger = { match = "name", text = text },
    }

    local selected = Current()
    if selected then
        if ns.IsGroup(selected) then
            aura.parent = selected.id
        elseif selected.parent then
            aura.parent = selected.parent
        end
    end

    Config:InheritDisplay(aura)
    profile.auras[#profile.auras + 1] = aura
    selectedID = aura.id
    currentTab = "trigger"
    Commit(true)
    return aura
end

-- New from template (Templates.lua): a spell, and what to watch about it.
function Config:AddFromTemplate(kind, spellID)
    local profile = ns.GetProfile()
    if not profile or not spellID then return nil end
    local aura = ns.Templates:Make(kind, spellID)
    if not aura then return nil end
    aura.id = ns.NextID(profile)
    local selected = Current()
    if selected then
        if ns.IsGroup(selected) then
            aura.parent = selected.id
        elseif selected.parent then
            aura.parent = selected.parent
        end
    end
    Config:InheritDisplay(aura)
    profile.auras[#profile.auras + 1] = aura
    selectedID = aura.id
    Commit(true)
    return aura
end

local templateFrame
function Config:OpenTemplates()
    if not window then return end
    if not templateFrame then
        local frame = CreateFrame("Frame", "ChairAurasTemplates", window, "BackdropTemplate")
        frame:SetSize(300, 176)
        frame:SetPoint("CENTER", window, "CENTER", 0, 40)
        pcall(frame.SetFrameStrata, frame, "DIALOG")
        pcall(frame.SetBackdrop, frame, { bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        pcall(frame.SetBackdropColor, frame, 0.05, 0.06, 0.08, 0.98)
        pcall(frame.SetBackdropBorderColor, frame, 0.25, 0.77, 1, 0.7)
        frame:EnableMouse(true)
        local title = Text(frame, "New from template", "GameFontNormal")
        title:SetPoint("TOP", frame, "TOP", 0, -10)

        local spellLabel = Text(frame, "Spell (from your spellbook)", "GameFontNormalSmall")
        spellLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -34)
        local spellHost = CreateFrame("Frame", nil, frame)
        spellHost:SetSize(260, 22)
        spellHost:SetPoint("TOPLEFT", spellLabel, "BOTTOMLEFT", 0, -4)
        frame.spells = {}
        frame.spellDrop = Dropdown(spellHost, 260, frame.spells, function(value)
            frame.spell = value
            frame.spellDrop:SetValue(value)
        end)

        local kindLabel = Text(frame, "Watch", "GameFontNormalSmall")
        kindLabel:SetPoint("TOPLEFT", spellHost, "BOTTOMLEFT", 0, -10)
        local kindHost = CreateFrame("Frame", nil, frame)
        kindHost:SetSize(260, 22)
        kindHost:SetPoint("TOPLEFT", kindLabel, "BOTTOMLEFT", 0, -4)
        frame.kind = "cooldown"
        frame.kindDrop = Dropdown(kindHost, 260, ns.Templates.KINDS, function(value)
            frame.kind = value
            frame.kindDrop:SetValue(value)
        end)

        local create = Button(frame, "Create", 90, function()
            if Config:AddFromTemplate(frame.kind, frame.spell) then frame:Hide() end
        end)
        create:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 12)
        local cancel = Button(frame, "Cancel", 90, function() frame:Hide() end)
        cancel:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 4, 12)
        templateFrame = frame
        Config.__templates = frame
    end
    wipe(templateFrame.spells)
    for _, entry in ipairs(ns.Templates:Spells()) do templateFrame.spells[#templateFrame.spells + 1] = entry end
    if not templateFrame.spell and templateFrame.spells[1] then templateFrame.spell = templateFrame.spells[1].value end
    templateFrame.spellDrop:SetValue(templateFrame.spell)
    templateFrame.kindDrop:SetValue(templateFrame.kind)
    templateFrame:Show()
end

function Config:AddGroup(dynamic)
    local profile = ns.GetProfile()
    if not profile then return end

    local aura = {
        id = ns.NextID(profile),
        type = dynamic and "dynamic" or "group",
        name = dynamic and "Dynamic group" or "Group",
    }
    profile.auras[#profile.auras + 1] = aura
    selectedID = aura.id
    Commit(true)
end

-- Everything selected, in list order.
function Config:SelectedList()
    local out = {}
    for _, entry in ipairs(TreeOrder()) do
        if entry.aura.id == selectedID or multi[entry.aura.id] then out[#out + 1] = entry.aura end
    end
    return out
end

function Config:DeleteSelected()
    local list = self:SelectedList()
    if #list <= 1 then return self:Delete(selectedID) end
    for _, aura in ipairs(list) do self:Delete(aura.id) end
    wipe(multi)
end

-- The open tab's settings, copied onto the rest of the selection.
local TAB_PARTS = {
    trigger = { "triggers" }, display = { "display" }, conditions = { "conditions" },
    load = { "load" }, actions = { "actions" }, animations = { "animation" },
    options = { "authorOptions", "config" },
}
local NOT_ON_GROUPS = { trigger = true, conditions = true, actions = true }
function Config:CopyTabToSelected()
    local source = Current()
    local parts = TAB_PARTS[currentTab]
    if not (source and parts) then return 0 end
    local copied = 0
    for _, aura in ipairs(self:SelectedList()) do
        if aura ~= source and not (NOT_ON_GROUPS[currentTab] and ns.IsGroup(aura)) then
            for _, key in ipairs(parts) do aura[key] = CopyValue(source[key]) end
            if source.untrusted then aura.untrusted = true end
            if currentTab == "options" then ns.Env:RefreshConfig(aura) end
            copied = copied + 1
        end
    end
    Commit(true)
    return copied
end

function Config:Delete(id)
    local aura, index = ns.FindAura(id)
    if not aura then return end

    -- A group's children are let out rather than deleted with it. Losing six
    -- auras to one click on the wrong row is not something to be clever about.
    for _, child in ipairs(ns.Children(id)) do
        child.parent = aura.parent
    end

    table.remove(ns.GetAuras(), index)
    selectedID = nil
    Commit(true)
end

function Config:SetParentByName(aura, text)
    if text == "" then
        aura.parent = nil
        Commit(true)
        return
    end

    local wanted = text:lower()
    for _, candidate in ipairs(ns.GetAuras()) do
        if ns.IsGroup(candidate) then
            local name = (candidate.name or candidate.id):lower()
            if name == wanted or candidate.id == text then
                if ns.WouldLoop(aura, candidate.id) then
                    ns.Print("a group cannot be put inside itself.")
                    return
                end
                aura.parent = candidate.id
                Config:InheritDisplay(aura)
                Commit(true)
                return
            end
        end
    end

    ns.Print("no group called", text, "-- make one with the buttons below the list.")
end

-------------------------------------------------------------------------------
-- Sharing
-------------------------------------------------------------------------------
-- One window for both directions. Exporting fills it and selects everything,
-- because the next thing anyone does is press ctrl-C; importing reads whatever
-- is in it and says what it found before anything is added.

local shareFrame

local function BuildShare()
    shareFrame = CreateFrame("Frame", "ChairAurasShare", UIParent, "BackdropTemplate")
    shareFrame:SetSize(520, 300)
    shareFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    shareFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    shareFrame:SetMovable(true)
    shareFrame:EnableMouse(true)
    shareFrame:RegisterForDrag("LeftButton")
    shareFrame:SetScript("OnDragStart", shareFrame.StartMoving)
    shareFrame:SetScript("OnDragStop", shareFrame.StopMovingOrSizing)
    shareFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    shareFrame:SetBackdropColor(0.05, 0.06, 0.08, 0.96)
    shareFrame:SetBackdropBorderColor(0.25, 0.77, 1, 0.7)
    tinsert(UISpecialFrames, "ChairAurasShare")

    shareFrame.title = Text(shareFrame, "Share", "GameFontNormal")
    shareFrame.title:SetPoint("TOP", shareFrame, "TOP", 0, -12)

    shareFrame.hint = Text(shareFrame, "", "GameFontDisableSmall")
    shareFrame.hint:SetPoint("TOPLEFT", shareFrame, "TOPLEFT", 20, -34)
    shareFrame.hint:SetPoint("TOPRIGHT", shareFrame, "TOPRIGHT", -20, -34)
    shareFrame.hint:SetJustifyH("LEFT")

    local inset = CreateFrame("Frame", nil, shareFrame, "InsetFrameTemplate3")
    inset:SetPoint("TOPLEFT", shareFrame, "TOPLEFT", 16, -56)
    inset:SetPoint("BOTTOMRIGHT", shareFrame, "BOTTOMRIGHT", -16, 44)

    local scroll = CreateFrame("ScrollFrame", "ChairAurasShareScroll", inset,
                               "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", inset, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -26, 6)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(440)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    shareFrame.box = box

    local importButton = Button(shareFrame, "Import", 100, function()
        local added, err = ns.Share:Import(shareFrame.box:GetText())
        if not added then
            shareFrame.hint:SetText("|cffdd6666" .. (err or "could not read that") .. "|r")
            return
        end
        ns.Print("imported", #added, "aura(s).")
        shareFrame:Hide()
        selectedID = added[1] and added[1].id or nil
        Config:Refresh()
    end)
    importButton:SetPoint("BOTTOMLEFT", shareFrame, "BOTTOMLEFT", 16, 12)
    shareFrame.importButton = importButton

    local selectAll = Button(shareFrame, "Select all", 100, function()
        shareFrame.box:SetFocus()
        shareFrame.box:HighlightText()
    end)
    selectAll:SetPoint("LEFT", importButton, "RIGHT", 6, 0)

    local close = Button(shareFrame, "Close", 80, function() shareFrame:Hide() end)
    close:SetPoint("BOTTOMRIGHT", shareFrame, "BOTTOMRIGHT", -16, 12)

    shareFrame:Hide()
end

local function ShowShare()
    if not shareFrame then
        local ok, err = pcall(BuildShare)
        if not ok then
            ns.Print("the share window failed to build:", err)
            return nil
        end
    end
    shareFrame:Show()
    return shareFrame
end

function Config:OpenExport(aura)
    aura = aura or Current()
    if not aura then
        ns.Print("select something to share first.")
        return
    end

    local text = ns.Share:Export(aura)
    if not text then
        ns.Print("that could not be turned into a string.")
        return
    end

    if not ShowShare() then
        ns.Print(text)
        return
    end

    shareFrame.title:SetText("Export")
    shareFrame.hint:SetText("Ctrl-C this and paste it to whoever wants it. They "
        .. "bring it in with Import.")
    shareFrame.box:SetText(text)
    shareFrame.box:SetFocus()
    shareFrame.box:HighlightText()
    shareFrame.importButton:SetEnabled(false)
end

function Config:OpenImport(text)
    if not ShowShare() then return end

    shareFrame.title:SetText("Import")
    shareFrame.box:SetText(text or "")
    shareFrame.importButton:SetEnabled(true)

    local bundle, err = ns.Share:Peek(shareFrame.box:GetText())
    if bundle then
        local first = bundle.auras[1]
        shareFrame.hint:SetText(string.format(
            "%d aura(s) from %s. The first is |cffffffff%s|r.",
            #bundle.auras, ns.SafeText(bundle.who) or "someone",
            ns.SafeText(first.name) or "unnamed"))
    else
        shareFrame.hint:SetText(text and text ~= ""
            and ("|cffdd6666" .. (err or "?") .. "|r")
            or "Paste a ChairAuras string here and press Import.")
    end

    shareFrame.box:SetFocus()
end

-------------------------------------------------------------------------------
-- Assembly
-------------------------------------------------------------------------------

local function BuildWindow()
    window = CreateFrame("Frame", "ChairAurasConfig", UIParent, "BackdropTemplate")
    -- As tall as fits comfortably on a 1920x1080 screen, and resizable from
    -- the corner; the size is remembered.
    local screenH = tonumber(UIParent:GetHeight()) or 768
    local saved = type(ChairAurasDB) == "table" and ChairAurasDB.window or nil
    local width = saved and tonumber(saved.w) or WINDOW_W
    local height = saved and tonumber(saved.h) or math.max(WINDOW_H, math.min(760, screenH - 80))
    window:SetSize(width, height)
    window:SetPoint("CENTER")
    pcall(window.SetResizable, window, true)
    if type(window.SetResizeBounds) == "function" then
        pcall(window.SetResizeBounds, window, WINDOW_W, WINDOW_H, 1600, 1400)
    elseif type(window.SetMinResize) == "function" then
        pcall(window.SetMinResize, window, WINDOW_W, WINDOW_H)
    end
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetClampedToScreen(true)
    window:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    window:SetBackdropColor(0.05, 0.06, 0.08, 0.94)
    window:SetBackdropBorderColor(0.25, 0.77, 1, 0.7)

    -- Escape closes it, the same as every other panel in the game.
    tinsert(UISpecialFrames, "ChairAurasConfig")

    local title = Text(window, ns.WINDOW_TITLE, "GameFontNormalLarge")
    title:SetPoint("TOP", window, "TOP", 0, -14)

    local version = Text(window, "v" .. ns.version, "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 6, -1)

    -- Add bar
    local addBox = CreateFrame("EditBox", nil, window, "InputBoxTemplate")
    addBox:SetSize(220, 22)
    addBox:SetPoint("TOPLEFT", window, "TOPLEFT", 22, -44)
    addBox:SetAutoFocus(false)
    window.addBox = addBox

    local function Clear()
        addBox:SetText("")
        addBox:ClearFocus()
    end

    local function AddFromBox()
        local text = addBox:GetText()
        local spellID = ns.ResolveSpell(text)
        if not spellID then
            -- Not a refusal any more: plenty of what people watch has no spell
            -- this client will admit to, and the answer to that is the button
            -- next door rather than a dead end.
            ns.Print("no spell called", text ..
                     ". If it is the words on an aura -- Well Fed and the like",
                     "-- use |cffffd100By name|r instead.")
            return
        end
        Config:AddAura(spellID)
        Clear()
    end

    local function AddNamedFromBox()
        local text = addBox:GetText()
        if not Config:AddNamed(text) then
            ns.Print("type the words as they appear on the aura, then press "
                     .. "|cffffd100By name|r.")
            return
        end
        Clear()
    end

    addBox:SetScript("OnEnterPressed", AddFromBox)
    addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    AcceptsSpellDrop(addBox, function(spellID) Config:AddAura(spellID) end)

    local addButton = Button(window, "Add spell", 90, AddFromBox)
    addButton:SetPoint("LEFT", addBox, "RIGHT", 8, 0)
    Tooltip(addButton, "Add by spell",
        "Type a spell name or ID, or drag a spell out of your spellbook and "
        .. "drop it on the box. Matched on the spell itself, so it is exact.")

    local namedButton = Button(window, "By name", 84, AddNamedFromBox)
    namedButton:SetPoint("LEFT", addButton, "RIGHT", 4, 0)
    Tooltip(namedButton, "Add by the words on it",
        "For everything with no spell worth naming: Well Fed, Drink, a server's "
        .. "own buff, a proc you only know by sight. Whatever you type is "
        .. "matched against the name the aura carries, and the Trigger tab can "
        .. "loosen that to 'contains' for a whole family of them.")


    local dropHint = Text(window, "or drag a spell here", "GameFontDisableSmall")
    dropHint:SetPoint("LEFT", namedButton, "RIGHT", 10, 0)

    local templateButton = Button(window, "From template", 110, function() Config:OpenTemplates() end)
    templateButton:SetPoint("LEFT", dropHint, "RIGHT", 10, 0)
    Tooltip(templateButton, "New from template",
        "Pick a spell from your spellbook and what to watch about it -- its cooldown, its buff, "
        .. "the buff missing, your debuff on the target -- and the aura is made for you.")

    -- List
    local inset = CreateFrame("Frame", nil, window, "InsetFrameTemplate3")
    inset:SetWidth(LIST_W)
    inset:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -76)
    inset:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 16, 76)

    local shiftHint = Text(window, "drag rows to reorder or regroup",
                           "GameFontDisableSmall")
    shiftHint:SetPoint("BOTTOMRIGHT", inset, "TOPRIGHT", 0, 1)

    -- Search: the list narrows to what matches, and the groups it is in.
    local search = CreateFrame("EditBox", nil, inset, "InputBoxTemplate")
    search:SetSize(LIST_W - 40, 20)
    search:SetPoint("TOPLEFT", inset, "TOPLEFT", 12, -5)
    search:SetAutoFocus(false)
    local searchHint = Text(search, "search", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", search, "LEFT", 2, 0)
    search:SetScript("OnTextChanged", function(self)
        Config.search = self:GetText() or ""
        searchHint:SetShown(Config.search == "")
        RefreshTree()
    end)
    search:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
    window.search = search

    local scroll = CreateFrame("ScrollFrame", "ChairAurasConfigScroll", inset,
                               "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", inset, "TOPLEFT", 4, -30)
    scroll:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -26, 4)

    listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(LIST_W - 32, 1)
    scroll:SetScrollChild(listChild)
    Config.listScroll = scroll

    -- Where a dragged row will land.
    local dropLine = listChild:CreateTexture(nil, "OVERLAY")
    dropLine:SetColorTexture(1, 0.82, 0, 0.95)
    dropLine:SetHeight(2)
    dropLine:Hide()
    Config.dropLine = dropLine
    local dropGlow = listChild:CreateTexture(nil, "OVERLAY")
    dropGlow:SetColorTexture(1, 0.82, 0, 0.25)
    dropGlow:Hide()
    Config.dropGlow = dropGlow

    -- The corner grip that resizes the window.
    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    -- Inside the Chaircraft menu the window is pinned to the menu, and sizing
    -- it directly would pull it loose -- the menu's background left behind as
    -- one window, the controls as another (2026-09-26). So there the grip
    -- sizes the menu, and the window, pinned to both its corners, follows.
    local function SizingTarget()
        if window.chairEmbedded then
            local host = window:GetParent()
            if host and host ~= UIParent then return host end
        end
        return window
    end
    grip:SetScript("OnMouseDown", function()
        local target = SizingTarget()
        pcall(target.SetResizable, target, true)
        if target ~= window then
            local extra = (tonumber(target:GetHeight()) or 0) - (tonumber(window:GetHeight()) or 0)
            if type(target.SetResizeBounds) == "function" then
                pcall(target.SetResizeBounds, target, WINDOW_W, WINDOW_H + extra, 1600, 1400)
            elseif type(target.SetMinResize) == "function" then
                pcall(target.SetMinResize, target, WINDOW_W, WINDOW_H + extra)
            end
        end
        target:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        local target = SizingTarget()
        target:StopMovingOrSizing()
        local w = math.floor((tonumber(window:GetWidth()) or WINDOW_W) + 0.5)
        local h = math.floor((tonumber(window:GetHeight()) or WINDOW_H) + 0.5)
        -- Kept as the window's own size too, for when it is shown on its own.
        pcall(window.SetSize, window, w, h)
        if type(ChairAurasDB) == "table" then ChairAurasDB.window = { w = w, h = h } end
    end)
    Tooltip(grip, "Resize", "Drag to make the window bigger or smaller. The size is remembered.")
    window.grip = grip

    local newGroup = Button(window, "New group", 110, function()
        Config:AddGroup(false)
    end)
    newGroup:SetPoint("TOPLEFT", inset, "BOTTOMLEFT", 0, -6)
    Tooltip(newGroup, "New group",
        "Children keep their slot whether or not they are showing, so the third "
        .. "icon is always the third icon.")

    local newDynamic = Button(window, "New dynamic group", 140, function()
        Config:AddGroup(true)
    end)
    newDynamic:SetPoint("LEFT", newGroup, "RIGHT", 6, 0)
    Tooltip(newDynamic, "New dynamic group",
        "Lays out only what is showing and closes the gaps, so a row of procs "
        .. "is however many are actually up.")

    BuildEditor(window)

    window.lock = CheckBox(window, "Unlocked (drag any icon to move its group)",
        function(checked)
            ns.profile.locked = not checked
            ns.Display:ApplyLock()
        end)
    window.lock:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 20, 14)

    local exportButton = Button(window, "Export", 80, function()
        Config:OpenExport()
    end)
    exportButton:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -180, 12)
    Tooltip(exportButton, "Export",
        "Turns what is selected into a string you can paste anywhere. A group "
        .. "brings its children with it.")

    local importButton = Button(window, "Import", 80, function()
        Config:OpenImport()
    end)
    importButton:SetPoint("LEFT", exportButton, "RIGHT", 4, 0)

    local close = Button(window, "Close", 80, function() window:Hide() end)
    close:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -16, 12)

    -- What the Chaircraft menu hides while it hosts this window: it supplies
    -- its own title and its own way out.
    window.chairChrome = { title, version, close }

    window:Hide()
end

-------------------------------------------------------------------------------
-- Entry points
-------------------------------------------------------------------------------

-- Which of the three questions is on screen. A function rather than a field so
-- the buttons and the offline tests take the same path into it.
-- Seams for the offline tests: the rows as built, and what is selected.
Config.__rows = rows
function Config.__rowList() return rows end
function Config.__selected() return selectedID end

function Config:SetTab(key)
    currentTab = key
    self:Refresh()
end

function Config:Refresh()
    if not window then return end
    RefreshTree()
    RefreshEditor()
    if window.lock then
        window.lock:SetChecked(not (ns.profile and ns.profile.locked))
    end
end

function Config:RefreshIfShown()
    if window and window:IsShown() then self:Refresh() end
end

function Config:Open()
    -- Opened from anywhere, it opens inside the Chaircraft menu. The menu calls
    -- back into here to fill the window, by which time it is hosted.
    if not (window and window.chairEmbedded) then
        local plus = _G.ChairPlusNS
        if plus and plus.OpenPartPage and plus.OpenPartPage("auras") then return end
    end
    if not window then
        local ok, err = pcall(BuildWindow)
        if not ok then
            ns.Print("the options window failed to build:", err)
            ns.Print("everything it does is also on |cffffd100/chair auras help|r.")
            return
        end
    end
    self:Refresh()
    window:Show()
end

-- The window, built if need be but not shown. The Chaircraft menu hosts it.
function Config:GetWindow()
    if not window then
        local ok, err = pcall(BuildWindow)
        if not ok then
            ns.Print("the options window failed to build:", err)
            return nil
        end
    end
    return window
end

function Config:Toggle()
    if window and window:IsShown() then
        window:Hide()
    else
        self:Open()
    end
end
