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
local function ButtonGroup(parent, labels, width, onPick)
    local group = { buttons = {} }

    for index, entry in ipairs(labels) do
        local button = Button(parent, entry.text, width, function()
            onPick(entry.value)
        end)
        button.value = entry.value
        if index == 1 then
            button:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        else
            button:SetPoint("LEFT", group.buttons[index - 1], "RIGHT", 4, 0)
        end
        group.buttons[index] = button
    end

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
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        if self.labelText then
            self.labelText:SetText(self.prefix .. ": " .. value)
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

local function TreeOrder()
    local order = {}

    local function Walk(parentID, depth)
        for _, aura in ipairs(ns.Children(parentID)) do
            order[#order + 1] = { aura = aura, depth = depth }
            if ns.IsGroup(aura) then Walk(aura.id, depth + 1) end
        end
    end

    Walk(nil, 0)
    return order
end

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
    end)

    row:SetScript("OnDragStop", function(self)
        local dragged = Config.dragging
        Config.dragging = nil
        if not dragged then return end

        local target, inside = Config:RowUnderCursor()
        if target and target ~= dragged then
            local aura = ns.FindAura(dragged)
            local onto = ns.FindAura(target)
            if aura and onto and ns.MoveAura(aura, onto, inside) then
                selectedID = dragged
                Commit(true)
                return
            end
        end

        Config:Refresh()
    end)

    row:SetScript("OnClick", function(self)
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
        row.selection:SetShown(aura.id == selectedID)
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

local function TriggerOf(aura) return ns.SubTable(aura, "trigger") end
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
            ns.Sounds:Open(ns.ActionField(aura, field.key),
                           ns.ActionField(aura, "channel"),
                           function(value) field.set(aura, value) end)
        end)
        choose:SetPoint("LEFT", current, "RIGHT", 6, 0)
        widget.choose = choose

        local test = Button(host, "Play", 56, function()
            local aura = Current()
            if not aura then return end
            if not ns.Sounds:Preview(ns.ActionField(aura, field.key),
                                     ns.ActionField(aura, "channel")) then
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
            self.current:SetText(ns.Sounds:Label(ns.ActionField(aura, field.key)))
        end
        function widget:SetEnabled(enabled)
            self.choose:SetEnabled(enabled)
            self.test:SetEnabled(enabled)
            self.clear:SetEnabled(enabled)
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
        widget.group = ButtonGroup(groupHost, field.values, field.width or 84,
            function(value)
                local aura = Current()
                if aura then field.set(aura, value) end
            end)
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

    elseif field.kind == "text" or field.kind == "spell" then
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
        for _, widget in ipairs(self.widgets) do
            local field = widget.field
            local enabled = true
            if field.enabled then enabled = field.enabled(aura) and true or false end
            widget:SetEnabled(enabled)
            widget:Read(aura)
        end
    end

    pane:Hide()
    return pane
end

-------------------------------------------------------------------------------
-- Field descriptions
-------------------------------------------------------------------------------

local function IsAura(aura)
    return not ns.IsGroup(aura)
        and ns.TriggerField(aura, "type") == "aura"
end

local function ByID(aura)
    return IsAura(aura) and ns.TriggerField(aura, "match") == "id"
end

local function ByName(aura)
    return IsAura(aura) and ns.TriggerField(aura, "match") == "name"
end

local TRIGGER_FIELDS = {
    {
        kind = "choice", label = "Trigger", key = "type", width = 110,
        values = { { text = "Aura", value = "aura" },
                   { text = "Cooldown", value = "cooldown" } },
        enabled = function(aura) return not ns.IsGroup(aura) end,
        get = function(aura) return ns.TriggerField(aura, "type") end,
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
        get = function(aura) return ns.TriggerField(aura, "match") end,
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
               and (ByID(aura) or ns.TriggerField(aura, "type") == "cooldown")
        end,
        get = function(aura)
            local spellID = ns.Trigger(aura).spellID
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
        get = function(aura) return ns.Trigger(aura).text or "" end,
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
        get = function(aura) return ns.TriggerField(aura, "partial") end,
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
        get = function(aura) return ns.TriggerField(aura, "harmful") end,
        set = function(aura, value)
            TriggerOf(aura).harmful = value or nil
            -- A debuff nobody said where to look for means the target, the same
            -- way the slash command reads it.
            if value and not ns.Trigger(aura).unit then
                TriggerOf(aura).unit = "target"
            end
            Commit(false)
        end,
    },
    {
        kind = "choice", label = "On", key = "unit", width = 78,
        values = { { text = "You", value = "player" },
                   { text = "Target", value = "target" },
                   { text = "Focus", value = "focus" },
                   { text = "Pet", value = "pet" } },
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "unit") end,
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
        get = function(aura) return ns.TriggerField(aura, "mine") end,
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
        get = function(aura) return ns.TriggerField(aura, "stacksOp") end,
        set = function(aura, value)
            TriggerOf(aura).stacksOp = value
            Commit(false)
        end,
    },
    {
        kind = "slider", label = "Stack count", key = "stacks", min = 0, max = 40,
        enabled = IsAura,
        get = function(aura) return ns.TriggerField(aura, "stacks") end,
        set = function(aura, value)
            TriggerOf(aura).stacks = (value > 0) and value or nil
            Commit(false)
        end,
    },
}

local function IsKind(wanted)
    return function(aura) return ns.RegionKind(aura) == wanted end
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
local function OwnPosition(aura) return aura.parent == nil end

local POSITION_TIP = "Where its center sits, in pixels from the center of the "
    .. "screen: 0, 0 is dead center, X grows to the right and Y upward. Drag "
    .. "the slider, or type a number and press Enter. Inside a group the group "
    .. "decides, so set the group's instead."

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
        kind = "choice", label = "Draw it as", key = "type", width = 70,
        tip = "The same trigger, drawn differently. Everything else about the "
           .. "aura survives the change.",
        values = { { text = "Icon", value = "icon" },
                   { text = "Text", value = "text" },
                   { text = "Bar", value = "bar" } },
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
        tip = "Colors the bar, or the words.",
        values = COLOURS,
        enabled = function(aura)
            local kind = ns.RegionKind(aura)
            return ns.IsGroup(aura) or kind == "text" or kind == "bar"
        end,
        get = function(aura) return ns.DisplayField(aura, "colour") end,
        set = function(aura, value)
            SetDisplay(aura, "colour", value)
            Commit(false)
        end,
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
                   { text = "Center V", value = "VCENTER" } },
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
        kind = "choice", label = "Sort (dynamic only)", key = "sort", width = 78,
        values = { { text = "List order", value = "none" },
                   { text = "Name", value = "name" },
                   { text = "Time left", value = "time" } },
        enabled = function(aura) return aura.type == "dynamic" end,
        get = function(aura) return ns.GroupField(aura, "sort") end,
        set = function(aura, value)
            aura.sort = value
            Commit(false)
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

local ACTION_FIELDS = {
    { kind = "header", label = "Sound" },
    SoundField("onShow", "When it comes up", SOUND_TIP),
    SoundField("onHide", "When it goes away", SOUND_TIP),
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
Config.__displayFields = DISPLAY_FIELDS
Config.__triggerFields = TRIGGER_FIELDS
Config.__actionFields = ACTION_FIELDS

-- The Load tab is generated from the condition list, so the window and the
-- engine cannot disagree about what a condition is or what it is called.
local function BuildLoadFields()
    local fields = {
        { kind = "header", label = "Load only while" },
    }

    for _, condition in ipairs(ns.Load.CONDITIONS) do
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

local TABS = {
    { key = "trigger",    text = "Trigger" },
    { key = "display",    text = "Display" },
    { key = "load",       text = "Load" },
    { key = "actions",    text = "Actions" },
}

local function BuildEditor(parent)
    editor = CreateFrame("Frame", nil, parent)
    editor:SetSize(PANE_W + 20, LIST_H + 40)
    editor:SetPoint("TOPLEFT", parent, "TOPLEFT", LIST_W + 32, -76)

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
        local button = Button(body, tab.text, 90, function()
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
        load    = BuildLoadFields(),
        actions = ACTION_FIELDS,
    }

    for key, fields in pairs(specs) do
        local scroll = CreateFrame("ScrollFrame", "ChairAurasPane" .. key, body,
                                   "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -62)
        scroll:SetSize(PANE_W, LIST_H - 62)

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
    parentLabel:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(LIST_H + 4))
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
        Config:Delete(selectedID)
    end)
    remove:SetPoint("LEFT", parentBox, "RIGHT", 12, 0)
    Tooltip(remove, "Delete", "Deleting a group leaves its children behind, "
        .. "outside any group -- nothing is ever removed twice over.")
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
                local inside = ns.IsGroup(aura)
                    and cursorY < top - height / 3
                    and cursorY > bottom + height / 3
                return row.auraID, inside
            end
        end
    end

    return nil
end

function Config:Select(id)
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
    window:SetSize(WINDOW_W, WINDOW_H)
    window:SetPoint("CENTER")
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

    local title = Text(window, "ChairAuras", "GameFontNormalLarge")
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

    local shiftHint = Text(window, "drag rows to reorder",
                           "GameFontDisableSmall")
    shiftHint:SetPoint("TOPLEFT", window, "TOPLEFT", 18, -444)

    local dropHint = Text(window, "or drag a spell here", "GameFontDisableSmall")
    dropHint:SetPoint("LEFT", namedButton, "RIGHT", 10, 0)

    -- List
    local inset = CreateFrame("Frame", nil, window, "InsetFrameTemplate3")
    inset:SetSize(LIST_W, LIST_H)
    inset:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -76)

    local scroll = CreateFrame("ScrollFrame", "ChairAurasConfigScroll", inset,
                               "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", inset, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -26, 4)

    listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(LIST_W - 32, 1)
    scroll:SetScrollChild(listChild)

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
