local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Display
-------------------------------------------------------------------------------
-- Every template this needs was confirmed present on this client --
-- CooldownFrameTemplate and BackdropTemplate among them -- so none of it is
-- guesswork.
--
-- Three things get drawn, and the difference between them is the whole feature:
--
--   icon     one thing on screen. A top-level icon carries its own position and
--            can be dragged; an icon inside a group is placed by the group.
--   group    a container whose children each keep their slot. A child that is
--            not showing leaves a gap, and nothing else moves. This is what you
--            want for a row you read by position -- the third icon is always the
--            third icon, so you learn where to look.
--   dynamic  a container that lays out only what is showing and closes the gaps,
--            so a row of six procs is however many are actually up, packed
--            together. This is what you want for a list you read by content.
--
-- WeakAuras draws the same distinction and the reason is the same: reading by
-- position and reading by content are different jobs and one layout cannot do
-- both.

local Display = {}
ns.Display = Display

local regions = {}     -- id -> frame

-- The offline tests read the positions the layout actually wrote, because the
-- only other way to know whether a dynamic group closed its gap is to stand in
-- the game and look at it.
Display.__regions = regions

local DEFAULT_X, DEFAULT_Y = 0, -150

-------------------------------------------------------------------------------
-- Region creation
-------------------------------------------------------------------------------

local function CreateIconRegion(id)
    local icon = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    icon.kind = "icon"

    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetAllPoints()
    -- The default art has a border baked in that reads as a grey frame at small
    -- sizes. Trimming the edge is what every icon in the game does.
    icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    icon.cooldown:SetAllPoints()
    pcall(icon.cooldown.SetDrawEdge, icon.cooldown, false)

    -- The stack count gets a frame of its own, and a high one.
    --
    -- A FontString on the icon's OVERLAY layer is still drawn *below* any
    -- child frame of that icon, and there are two of them here -- the
    -- cooldown and the flash. So the number was being rendered, correctly,
    -- underneath them. +10 clears both, which take the default parent+1.
    icon.countFrame = CreateFrame("Frame", nil, icon)
    icon.countFrame:SetAllPoints()
    -- The arithmetic goes inside the guard, not in the argument list: a client
    -- that answers GetFrameLevel with something other than a number would
    -- throw before pcall ever saw it.
    local okLevel, level = pcall(icon.GetFrameLevel, icon)
    level = (okLevel and type(level) == "number") and level or 0
    pcall(icon.countFrame.SetFrameLevel, icon.countFrame, level + 10)

    icon.count = icon.countFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    icon.count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, 0)
    -- NumberFontNormal is not on every build, and a font string with no font
    -- draws nothing at all while answering every call you make to it. This
    -- client has already lost ActionButton_ShowOverlayGlow and friends, so a
    -- missing font object is not a hypothetical.
    ns.EnsureFont(icon.count)

    -- Both ActionButton_ShowOverlayGlow and ActionButton_HideOverlayGlow are
    -- gone on this client, and ActionButtonSpellAlertManager is undocumented
    -- enough that driving it blind would be its own project. A flat white flash
    -- needs no art file and no API that might not be here.
    -- The flash lives on a frame of its own rather than on a bare texture:
    -- CreateAnimationGroup is a Frame method, and calling it on a texture is a
    -- nil-value error that would take every icon down with it.
    icon.flashFrame = CreateFrame("Frame", nil, icon)
    icon.flashFrame:SetAllPoints()
    icon.flashFrame:SetAlpha(0)

    icon.flash = icon.flashFrame:CreateTexture(nil, "OVERLAY")
    icon.flash:SetAllPoints()
    icon.flash:SetColorTexture(1, 1, 1, 1)
    icon.flash:SetBlendMode("ADD")

    local fade = icon.flashFrame:CreateAnimationGroup()
    local alpha = fade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.7)
    alpha:SetToAlpha(0)
    alpha:SetDuration(0.45)
    icon.fade = fade

    return icon
end

-- A group draws nothing at all, ever: no border, no name, no background. It is
-- a place to put things, and the things are what you came to look at. The
-- frame still exists because the children hang off it and it is what carries
-- the position, but it has no art of its own and never takes the mouse.
-- A colour stored as six hex characters, which is how the options window
-- offers them and how they survive being exported as text.
local function Colour(aura)
    local hex = ns.DisplayField(aura, "colour") or "ffffff"
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255
end

local function CreateTextRegion(id)
    local region = CreateFrame("Frame", nil, UIParent)
    region.kind = "text"

    region.text = region:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    region.text:SetAllPoints()
    region.text:SetJustifyH("LEFT")

    return region
end

local function CreateBarRegion(id)
    local region = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    region.kind = "bar"

    region.background = region:CreateTexture(nil, "BACKGROUND")
    region.background:SetAllPoints()
    region.background:SetColorTexture(0, 0, 0, 0.55)

    region.icon = region:CreateTexture(nil, "ARTWORK")
    region.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    region.bar = CreateFrame("StatusBar", nil, region)
    region.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    region.bar:SetMinMaxValues(0, 1)
    region.bar:SetValue(1)

    region.text = region.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    region.text:SetPoint("LEFT", region.bar, "LEFT", 4, 0)
    region.text:SetPoint("RIGHT", region.bar, "RIGHT", -4, 0)
    region.text:SetJustifyH("LEFT")

    -- A bar with a duration on it has to move between sweeps or it is a
    -- staircase: the engine looks every 0.15s and an eye reads a timer faster
    -- than that. The frame keeps the last state it was given and redraws
    -- itself from the clock.
    region:SetScript("OnUpdate", function(self)
        local aura = ns.FindAura(self.auraID)
        local state = self.lastState
        if not (aura and state) then return end

        local fraction = ns.Engine:Progress(state)
        if fraction then
            self.bar:SetValue(fraction)
        end

        local template = ns.DisplayField(aura, "barFormat")
        if template and template ~= "" then
            self.text:SetText(ns.Engine:FormatText(template, aura, state))
        end
    end)

    return region
end

local function CreateGroupRegion(id)
    local group = CreateFrame("Frame", nil, UIParent)
    group.kind = "group"
    return group
end

-------------------------------------------------------------------------------
-- Anchor points
-------------------------------------------------------------------------------
-- The point on the group that stays put while it resizes. A row growing right
-- should keep its left edge, a row growing left its right edge, and a centred
-- one its middle -- otherwise adding an icon shoves the ones already there
-- sideways, which is the whole complaint centred growth exists to answer.
local PIVOT = {
    RIGHT   = "TOPLEFT",
    LEFT    = "TOPRIGHT",
    DOWN    = "TOPLEFT",
    UP      = "BOTTOMLEFT",
    HCENTER = "CENTER",
    VCENTER = "CENTER",
}

function Display:PivotFor(aura)
    if not ns.IsGroup(aura) then return "CENTER" end
    return PIVOT[ns.GroupField(aura, "growth")] or "TOPLEFT"
end

-- Where a named point of a frame sits relative to that frame's own centre.
local function PivotDelta(pivot, width, height)
    local halfW, halfH = width / 2, height / 2
    if pivot == "TOPLEFT" then return -halfW, halfH end
    if pivot == "TOPRIGHT" then return halfW, halfH end
    if pivot == "BOTTOMLEFT" then return -halfW, -halfH end
    if pivot == "BOTTOMRIGHT" then return halfW, -halfH end
    return 0, 0
end

-------------------------------------------------------------------------------
-- Dragging
-------------------------------------------------------------------------------
-- What a drag actually moves.
--
-- Only a top-level region has a position of its own: a child sits where its
-- group's layout puts it, and letting one be dragged would write a position
-- that the next layout immediately overwrites -- a control that silently
-- undoes itself. So dragging a child moves the group it belongs to.
--
-- That also answers the question groups stopped being able to answer once they
-- drew nothing: an invisible frame cannot be grabbed, so the icons inside it
-- are the handle. Grab any icon and the whole group comes with it.
local function TopLevelOf(aura)
    local seen = {}
    while aura and aura.parent and not seen[aura.id] do
        seen[aura.id] = true
        aura = ns.FindAura(aura.parent)
    end
    return aura
end

local function MakeDraggable(frame)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    frame:SetScript("OnDragStart", function(self)
        if ns.profile and ns.profile.locked then return end

        local aura = ns.FindAura(self.auraID)
        local top = TopLevelOf(aura)
        if not top then return end

        local mover = regions[top.id]
        if not mover then return end

        -- Remembered on the frame that was grabbed, because OnDragStop fires
        -- on that one and it has to know what it set in motion.
        self.movingID = top.id
        -- And remembered on the module, because layout has to know too: a
        -- frame under StartMoving follows the mouse, and anything that pins it
        -- with SetPoint in the meantime takes it straight back off the cursor.
        Display.movingID = top.id
        mover:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        local id = self.movingID or self.auraID
        self.movingID = nil
        Display.movingID = nil

        local mover = regions[id]
        if mover then mover:StopMovingOrSizing() end
        Display:SavePosition(id)
    end)
end

-- Where an aura's centre sits, as an offset from the centre of the screen --
-- what the X and Y fields on the Display tab show and set. The stored
-- position is the pivot point (a corner, for a group), so it is converted
-- through the frame's size either way; a frame not drawn yet counts as a
-- point, which puts its pivot and centre in the same place.
local function FrameSize(id)
    local frame = regions[id]
    if not frame then return 0, 0 end
    local ok, w, h = pcall(frame.GetSize, frame)
    return (ok and ns.SafeNumber(w)) or 0, (ok and ns.SafeNumber(h)) or 0
end

function Display:CenterOffset(aura)
    local pos = aura.pos
    local x = pos and pos.x or DEFAULT_X
    local y = pos and pos.y or DEFAULT_Y
    local w, h = FrameSize(aura.id)
    local dx, dy = PivotDelta((pos and pos.pivot) or self:PivotFor(aura), w, h)
    return math.floor(x - dx + 0.5), math.floor(y - dy + 0.5)
end

function Display:SetCenterOffset(aura, x, y)
    local cx, cy = self:CenterOffset(aura)
    x, y = ns.SafeNumber(x) or cx, ns.SafeNumber(y) or cy
    local pivot = self:PivotFor(aura)
    local w, h = FrameSize(aura.id)
    local dx, dy = PivotDelta(pivot, w, h)
    aura.pos = { x = x + dx, y = y + dy, pivot = pivot }
end

function Display:SavePosition(id)
    local frame = regions[id]
    local aura = ns.FindAura(id)
    if not (frame and aura) then return end

    local x, y = frame:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not (x and y and ux and uy) then return end

    -- Stored as the pivot point rather than the centre, because the pivot is
    -- what the next layout pins: saving a centre and pinning a corner is how a
    -- frame jumps half its own width the moment it is redrawn.
    local pivot = self:PivotFor(aura)
    local width = ns.SafeNumber(frame:GetSize()) or 0
    local height = ns.SafeNumber(select(2, frame:GetSize())) or 0
    local dx, dy = PivotDelta(pivot, width, height)
    aura.pos = { x = x - ux + dx, y = y - uy + dy, pivot = pivot }
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

function Display:Build()
    self:Rebuild()
end

local BUILDERS = {
    icon  = CreateIconRegion,
    text  = CreateTextRegion,
    bar   = CreateBarRegion,
    group = CreateGroupRegion,
}

local function RegionFor(aura)
    local frame = regions[aura.id]
    local wanted = ns.RegionKind(aura)

    -- A type change makes the old frame the wrong shape. Frames cannot be
    -- destroyed, so the old one is hidden and forgotten rather than reused into
    -- something it was not built for.
    if frame and frame.kind ~= wanted then
        frame:Hide()
        frame = nil
    end

    if not frame then
        frame = (BUILDERS[wanted] or CreateIconRegion)(aura.id)
        frame.auraID = aura.id
        MakeDraggable(frame)
        regions[aura.id] = frame
    end

    frame.auraParent = aura.parent
    return frame
end

-- Rebuilt from the list every time the list changes: which region belongs to
-- which aura, who its parent is, and where the top-level ones sit.
function Display:Rebuild()
    local auras = ns.GetAuras()
    local live = {}

    for _, aura in ipairs(auras) do
        local frame = RegionFor(aura)
        live[aura.id] = true

        local parentFrame = aura.parent and regions[aura.parent] or UIParent
        -- A child of a group that does not exist would otherwise be parented to
        -- nothing and never drawn. It falls back to the screen, where it is at
        -- least visible and fixable.
        frame:SetParent(parentFrame or UIParent)
    end

    for id, frame in pairs(regions) do
        if not live[id] then
            frame:Hide()
            regions[id] = nil
        end
    end

    self:Layout()
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

-- How much room a thing takes. An icon is square, a bar is as wide as it was
-- set to be, and text is as tall as its font -- so a group can no longer step
-- by one number the way it could when everything was an icon.
local function RegionExtent(aura)
    local kind = ns.RegionKind(aura)

    if kind == "text" then
        return ns.DisplayField(aura, "textWidth"),
               ns.DisplayField(aura, "fontSize") + 8
    end

    if kind == "bar" then
        return ns.DisplayField(aura, "barWidth"),
               ns.DisplayField(aura, "barHeight")
    end

    if kind == "group" then
        local width, height = Display:GroupExtent(aura)
        return width, height
    end

    local size = ns.DisplayField(aura, "size")
    return size, size
end
Display.__extent = RegionExtent

local VERTICAL = { UP = true, DOWN = true, VCENTER = true }
local CENTRED  = { HCENTER = true, VCENTER = true }

-- Children split into lines, each line measured along the direction it runs
-- and across it. Everything the layout needs comes out of here, so placing and
-- sizing cannot disagree about where things went.
local function Measure(group, children)
    local growth  = ns.GroupField(group, "growth")
    local spacing = ns.GroupField(group, "spacing")
    local columns = ns.GroupField(group, "columns")
    local vertical = VERTICAL[growth] and true or false

    local perLine = (columns and columns > 0) and columns or math.max(#children, 1)
    local lines = {}

    for index, child in ipairs(children) do
        local width, height = RegionExtent(child)
        local along, across = width, height
        if vertical then along, across = height, width end

        local number = math.floor((index - 1) / perLine) + 1
        local line = lines[number]
        if not line then
            line = { total = 0, across = 0, items = {} }
            lines[number] = line
        end

        if #line.items > 0 then line.total = line.total + spacing end
        line.items[#line.items + 1] = {
            child = child, along = along, across = across,
            offset = line.total, width = width, height = height,
        }
        line.total = line.total + along
        line.across = math.max(line.across, across)
    end

    local widest, stacked = 0, 0
    for number, line in ipairs(lines) do
        widest = math.max(widest, line.total)
        if number > 1 then stacked = stacked + spacing end
        line.crossOffset = stacked
        stacked = stacked + line.across
    end

    return lines, widest, stacked, vertical, growth, spacing
end

function Display:GroupExtent(group, children)
    children = children or ns.Children(group.id)
    if #children == 0 then
        local size = ns.DISPLAY_DEFAULTS.size
        return size, size
    end

    local _, along, across, vertical = Measure(group, children)
    if vertical then return across, along end
    return along, across
end

-- Puts every child where Measure said it goes.
local function Arrange(group, children)
    local lines, along, across, vertical, growth = Measure(group, children)
    local centred = CENTRED[growth]

    for _, line in ipairs(lines) do
        for _, item in ipairs(line.items) do
            local frame = regions[item.child.id]
            if frame then
                frame:SetSize(item.width, item.height)
                frame:ClearAllPoints()

                if centred then
                    -- Measured out from the middle, so the whole thing opens
                    -- and closes around its own centre.
                    local alongPos = item.offset + item.along / 2 - line.total / 2
                    local acrossPos = line.crossOffset + item.across / 2 - across / 2

                    if vertical then
                        frame:SetPoint("CENTER", acrossPos, -alongPos)
                    else
                        frame:SetPoint("CENTER", alongPos, -acrossPos)
                    end

                elseif growth == "LEFT" then
                    frame:SetPoint("TOPRIGHT", -item.offset, -line.crossOffset)
                elseif growth == "UP" then
                    frame:SetPoint("BOTTOMLEFT", line.crossOffset, item.offset)
                elseif growth == "DOWN" then
                    frame:SetPoint("TOPLEFT", line.crossOffset, -item.offset)
                else
                    frame:SetPoint("TOPLEFT", item.offset, -line.crossOffset)
                end

                frame:Show()
            end
        end
    end

    if vertical then return across, along end
    return along, across
end

-- A group's children, in the order the group wants them drawn. Only a dynamic
-- group sorts or filters: a static group's order is its list order, because its
-- whole promise is that a slot does not move.
local function OrderedChildren(group, states)
    local children = ns.Children(group.id)
    local dynamic = (group.type == "dynamic")

    if not dynamic then return children end

    local showing = {}
    for _, child in ipairs(children) do
        if ns.IsGroup(child) then
            showing[#showing + 1] = child
        else
            local state = states and states[child.id]
            -- Before the first sweep there are no states at all. Treating that
            -- as "nothing is showing" would make a dynamic group flicker empty
            -- on every reload, so an unevaluated child counts as showing.
            if not states or (state and state.shown) then
                showing[#showing + 1] = child
            end
        end
    end

    local sort = ns.GroupField(group, "sort")
    if sort == "name" then
        table.sort(showing, function(a, b)
            local an = ns.Engine:Describe(a)
            local bn = ns.Engine:Describe(b)
            return (an or "") < (bn or "")
        end)
    elseif sort == "time" then
        -- Soonest to run out first, and anything with no timer after the ones
        -- that have one: a permanent aura has no place in a race.
        table.sort(showing, function(a, b)
            local sa = states and states[a.id]
            local sb = states and states[b.id]
            local ea = (sa and sa.start and sa.duration) and (sa.start + sa.duration) or math.huge
            local eb = (sb and sb.start and sb.duration) and (sb.start + sb.duration) or math.huge
            if ea == eb then return (a.id or "") < (b.id or "") end
            return ea < eb
        end)
    end

    local limit = ns.GroupField(group, "limit")
    if limit and limit > 0 then
        for index = #showing, limit + 1, -1 do
            showing[index] = nil
        end
    end

    return showing
end

local function LayoutGroup(group, states)
    local frame = regions[group.id]
    if not frame then return end

    local children = OrderedChildren(group, states)

    -- Anything in the group that is not in the running is hidden rather than
    -- left where it was: a region still sitting in an old slot is the bug the
    -- whole layout exists to avoid.
    if group.type == "dynamic" then
        local placed = {}
        for _, child in ipairs(children) do placed[child.id] = true end
        for _, child in ipairs(ns.Children(group.id)) do
            if not placed[child.id] and regions[child.id] then
                regions[child.id]:Hide()
            end
        end
    end

    -- Groups inside this one size themselves first, because this one's layout
    -- is measured from how big they turned out to be.
    for _, child in ipairs(children) do
        if ns.IsGroup(child) then LayoutGroup(child, states) end
    end

    local width, height = Arrange(group, children)
    frame:SetSize(math.max(width, 1), math.max(height, 1))
end

-- A stored position is where the pivot point sits, so changing the growth
-- direction changes what the number means. Converting it here keeps the group
-- exactly where it is on screen through that change -- and positions saved
-- before pivots existed are centre-based, which is what the default covers.
local function ConvertPivot(aura, frame, pivot)
    local pos = aura.pos
    if not pos or pos.pivot == pivot then return end

    -- Screened rather than trusted: this client hands some numbers back as
    -- secrets, and a frame that has not been laid out yet answers with nothing
    -- useful. Either way the conversion waits for a size it can do sums on,
    -- and the next layout comes back for it.
    local width = ns.SafeNumber(frame:GetSize())
    local height = ns.SafeNumber(select(2, frame:GetSize()))
    if not (width and height) or width <= 0 then return end

    local oldX, oldY = PivotDelta(pos.pivot or "CENTER", width, height)
    local newX, newY = PivotDelta(pivot, width, height)
    pos.x = pos.x - oldX + newX
    pos.y = pos.y - oldY + newY
    pos.pivot = pivot
end

local function PlaceTopLevel(aura)
    local frame = regions[aura.id]
    if not frame then return end

    -- Being dragged right now: it is where the player is putting it, and the
    -- position it is heading for is saved on release. Laying it out again in
    -- the middle of that is how a drag turns into a fight with the addon.
    if Display.movingID == aura.id then return end

    local pivot = Display:PivotFor(aura)
    ConvertPivot(aura, frame, pivot)

    local pos = aura.pos
    frame:ClearAllPoints()
    frame:SetPoint(pivot, UIParent, "CENTER",
                   pos and pos.x or DEFAULT_X,
                   pos and pos.y or DEFAULT_Y)
    frame:Show()
end

function Display:Layout(states)
    states = states or ns.Engine.states

    for _, aura in ipairs(ns.TopLevel()) do
        local frame = regions[aura.id]
        if frame then
            if ns.IsGroup(aura) then
                LayoutGroup(aura, states)
            else
                frame:SetSize(RegionExtent(aura))
            end
            PlaceTopLevel(aura)
        end
    end

    self:ApplyLock()
end

-------------------------------------------------------------------------------
-- Lock
-------------------------------------------------------------------------------
-- Unlocked, the icons take the mouse and dragging one moves whatever it belongs
-- to. Nothing else changes on screen: there is no outline and no label, because
-- the only things worth looking at are the auras themselves.
--
-- An icon that is not currently up is still shown faintly while unlocked, and
-- that is the one visible difference between locked and not. It has to be:
-- without it, a group whose auras are all quiet has nothing to take hold of,
-- and "hide when inactive" would leave its own aura impossible to reposition.
-- An aura that is not loaded stays invisible, because it does not exist right
-- now and moving something that is not there is not a thing to offer.

function Display:ApplyLock()
    local locked = ns.profile and ns.profile.locked

    for _, aura in ipairs(ns.GetAuras()) do
        local frame = regions[aura.id]
        if frame then
            frame:EnableMouse(not locked and not ns.IsGroup(aura))
        end
    end
end

function Display:Unlocked()
    return not (ns.profile and ns.profile.locked)
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------
-- Sound on the edge: the moment it comes up, the moment it goes. Anything that
-- fired on the state instead would play every sweep for as long as the aura was
-- up, which is a noise nobody would keep the addon installed through.
--
-- What the player typed decides how it is played. A number is a sound this
-- client already has and goes through PlaySound; anything else is a file and
-- goes through PlaySoundFile. Both are wrapped, because a client missing either
-- one must cost the sound and nothing else -- and a path that does not exist is
-- silence rather than an error, which is the client's own behaviour.

function Display:PlayAction(aura, which)
    local sound = ns.ActionField(aura, which)
    if not sound or sound == "" then return false end

    -- Playing it is Sounds' job, and only its job: the picker plays the same
    -- way this does, so what you heard when you chose it is what you get.
    return ns.Sounds:Play(sound, ns.ActionField(aura, "channel"))
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

-- How visible a thing is right now, which is the same question whatever shape
-- it is drawn in.
local function AlphaFor(aura, state)
    if not state.loaded then return 0 end
    if state.shown then return ns.DisplayField(aura, "alpha") / 100 end
    if ns.DisplayField(aura, "hide") then
        return Display:Unlocked() and 0.25 or 0
    end
    return ns.DisplayField(aura, "dimAlpha") / 100
end

local function RefreshText(aura, frame, state)
    frame:SetAlpha(AlphaFor(aura, state))

    local size = ns.DisplayField(aura, "fontSize")
    local font, _, flags = frame.text:GetFont()
    if font then pcall(frame.text.SetFont, frame.text, font, size, flags) end

    frame.text:SetTextColor(Colour(aura))
    frame.text:SetText(ns.Engine:FormatText(
        ns.DisplayField(aura, "textFormat"), aura, state))
end

local function RefreshBar(aura, frame, state)
    frame:SetAlpha(AlphaFor(aura, state))

    local height = ns.DisplayField(aura, "barHeight")
    local showIcon = ns.DisplayField(aura, "barIcon")

    if showIcon then
        frame.icon:SetSize(height, height)
        frame.icon:ClearAllPoints()
        frame.icon:SetPoint("LEFT", frame, "LEFT", 0, 0)
        frame.icon:SetTexture(state.icon)
        frame.icon:SetDesaturated(false)
        frame.icon:Show()
    else
        frame.icon:Hide()
    end

    frame.bar:ClearAllPoints()
    frame.bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    frame.bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", showIcon and height + 2 or 0, 0)
    frame.bar:SetStatusBarColor(Colour(aura))

    -- A trigger with no duration is not half way through anything, so the bar
    -- reads full rather than empty: it is on, and that is all it knows.
    local fraction = ns.Engine:Progress(state)
    frame.bar:SetValue(fraction or 1)

    frame.text:SetText(ns.Engine:FormatText(
        ns.DisplayField(aura, "barFormat"), aura, state))

    -- Kept for the OnUpdate, which is what makes the timer run smoothly
    -- between sweeps.
    frame.lastState = state
end

local function RefreshIcon(aura, frame, state)
    frame.texture:SetTexture(state.icon)

    local alpha    = ns.DisplayField(aura, "alpha") / 100
    local dimAlpha = ns.DisplayField(aura, "dimAlpha") / 100

    if not state.loaded then
        -- Not loaded is not the same as not met: the aura does not exist right
        -- now, so it shows nothing at all rather than a dimmed placeholder.
        frame:SetAlpha(0)
    else
        local wantAlpha, wantDesaturated
        if state.shown then
            wantAlpha, wantDesaturated = alpha, false
        elseif ns.DisplayField(aura, "hide") then
            -- Hidden, unless the bars are unlocked and it needs to be grabbable.
            wantAlpha = Display:Unlocked() and 0.25 or 0
            wantDesaturated = ns.DisplayField(aura, "desaturate")
        else
            wantAlpha = dimAlpha
            wantDesaturated = ns.DisplayField(aura, "desaturate")
        end


        frame:SetAlpha(wantAlpha)
        frame.texture:SetDesaturated(wantDesaturated)
    end

    if state.start and state.duration and ns.DisplayField(aura, "swipe") then
        frame.cooldown:SetCooldown(state.start, state.duration)
    else
        frame.cooldown:Clear()
    end

    -- Shown from one, not from two. Stacks are opt-in per aura, so an aura
    -- that asked for them and sits at a single stack should say "1" rather
    -- than nothing -- "> 1" made the option look broken on everything that
    -- does not stack high.
    if state.count and state.count > 0 and ns.DisplayField(aura, "stacks") then
        frame.count:SetText(ns.SafeText(state.count) or "")
    else
        frame.count:SetText("")
    end


end

function Display:Refresh(states)
    local relayout = false

    for _, aura in ipairs(ns.GetAuras()) do
        if not ns.IsGroup(aura) then
            local frame = regions[aura.id]
            local state = states[aura.id]
            if frame and state then
                -- Flash and sound happen on the edge, not on the state: an
                -- aura that is simply on would otherwise fire on every sweep.
                -- Shared by all three shapes, so a bar is as audible as an icon.
                --
                -- The edge is the trigger changing, and loading is not that.
                -- An aura that loads out of combat loads again at the end of
                -- every fight, and counting that as coming up plays the sound
                -- every time a fight ends for a buff that was missing right
                -- through it -- which is noise about nothing having happened.
                -- Unloading is the same thing in the other direction: it would
                -- announce the aura going away every time one starts.
                --
                -- So the state is carried across the gap rather than reset, and
                -- the frame it comes back on adopts whatever is true then
                -- without firing. What changed while the aura did not exist is
                -- not something that happened to the player.
                local loaded = state.loaded
                local live = state.shown and loaded

                if loaded then
                    if frame.wasLoaded then
                        if state.shown and not frame.wasShown then
                            if frame.fade and ns.DisplayField(aura, "flash") then
                                frame.fade:Stop()
                                frame.fade:Play()
                            end
                            Display:PlayAction(aura, "onShow")
                        elseif frame.wasShown and not state.shown then
                            Display:PlayAction(aura, "onHide")
                        end
                    end
                    frame.wasShown = state.shown
                end
                frame.wasLoaded = loaded

                local kind = ns.RegionKind(aura)
                if kind == "text" then
                    RefreshText(aura, frame, state)
                elseif kind == "bar" then
                    RefreshBar(aura, frame, state)
                else
                    RefreshIcon(aura, frame, state)
                end

                -- A dynamic group's layout is a function of what is showing, so
                -- a change there is the one thing that has to move icons.
                local parent = aura.parent and ns.FindAura(aura.parent)
                if parent and parent.type == "dynamic"
                   and frame.lastShown ~= (state.shown and state.loaded) then
                    relayout = true
                end
                frame.lastShown = (state.shown and state.loaded)
            end
        end
    end

    if relayout then self:Layout(states) end
end

function Display:Redraw()
    self:Rebuild()
    ns.RequestUpdate()
end
