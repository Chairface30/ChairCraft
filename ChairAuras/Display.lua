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

-- Every shape a region can take beyond the four built in here -- texture,
-- progress texture, model -- registers how it is made, drawn, measured and
-- colored (Regions.lua).
local KINDS = {}
Display.KINDS = KINDS
function Display.RegisterKind(kind, def) KINDS[kind] = def end

-- Where layout put a frame, kept, so an animation can move it from there and
-- put it back: layout pins, an animation adds an offset on top.
local function Pin(frame, point, relative, relativePoint, x, y)
    x, y = x or 0, y or 0
    frame.pin = { point, relative, relativePoint, x, y }
    frame:ClearAllPoints()
    frame:SetPoint(point, relative, relativePoint, x + (frame.animX or 0), y + (frame.animY or 0))
end
Display.Pin = Pin
function Display.RePin(frame)
    local pin = frame.pin
    -- Not while the player is dragging it: that is the cursor's to place.
    if not pin or (Display.movingID and Display.movingID == frame.auraID) then return end
    Pin(frame, pin[1], pin[2], pin[3], pin[4], pin[5])
end

-- A region going out of use: hidden, and nothing left animating it.
local function Retire(frame)
    frame:Hide()
    if ns.Animations then ns.Animations:Stop(frame) end
end

-- And the size layout gave it, which an animation scales.
local function Size(frame, width, height)
    width, height = tonumber(width) or 0, tonumber(height) or 0
    frame.baseW, frame.baseH = width, height
    local sx, sy = frame.animScaleX, frame.animScaleY
    if sx or sy then
        width = width * math.max(math.abs(sx or 1), 0.001)
        height = height * math.max(math.abs(sy or 1), 0.001)
    end
    frame:SetSize(width, height)
end
Display.Size = Size
function Display.Rescale(frame)
    if frame.baseW then Size(frame, frame.baseW, frame.baseH) end
end

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

    -- The text drawn on the icon, on the same high frame so the swipe and the
    -- flash cannot cover it.
    icon.overlay = icon.countFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    icon.overlay:SetPoint("CENTER", icon, "CENTER", 0, 0)
    ns.EnsureFont(icon.overlay)
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

local function Hex(hex, fallback)
    hex = (hex and hex ~= "") and hex or fallback or "ffffff"
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255
end

-- One piece of text styled by its own settings: font, size, outline, color.
-- The game's font is remembered the first time, so "default" can go back.
local function StyleText(fontString, aura, fontKey, sizeKey, outlineKey, colourKey)
    if not fontString then return end
    local current, currentSize, currentFlags = fontString:GetFont()
    if not fontString.baseFont then
        fontString.baseFont, fontString.baseFlags = current, currentFlags
    end
    local font = ns.DisplayField(aura, fontKey)
    local size = ns.DisplayField(aura, sizeKey) or currentSize
    local outline = ns.DisplayField(aura, outlineKey)
    local flags
    if outline == "NONE" then flags = ""
    elseif outline and outline ~= "" then flags = outline
    else flags = fontString.baseFlags or "" end
    local path = (font and font ~= "") and font or fontString.baseFont
    if path then
        if not pcall(fontString.SetFont, fontString, path, size, flags) then
            pcall(fontString.SetFont, fontString, fontString.baseFont, size, flags)
        end
    end
    fontString:SetTextColor(Hex(ns.DisplayField(aura, colourKey), ns.DisplayField(aura, "colour")))
end
Display.StyleText = StyleText
Display.Hex = Hex

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

    -- The spark at the moving edge, on while the bar has a timer.
    region.spark = region.bar:CreateTexture(nil, "OVERLAY")
    region.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    pcall(region.spark.SetBlendMode, region.spark, "ADD")
    region.spark:Hide()

    -- A bar with a duration on it has to move between sweeps or it is a
    -- staircase: the engine looks every 0.15s and an eye reads a timer faster
    -- than that. The frame keeps the last state it was given and redraws
    -- itself from the clock.
    region:SetScript("OnUpdate", function(self)
        local aura = ns.FindAura(self.auraID)
        local state = self.lastState
        if not (aura and state) then return end

        -- Health and power are secret: handed to the bar to draw, never read.
        if state.live and ns.DrawLive and ns.DrawLive(self.bar, state.live) then
            -- drawn
        else
            local fraction = ns.Engine:Progress(state)
            if fraction then
                if ns.DisplayField(aura, "barInverse") then fraction = 1 - fraction end
                self.bar:SetMinMaxValues(0, 1)
                self.bar:SetValue(fraction)
            end
            Display.PlaceSpark(aura, self, fraction)
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
    CIRCLE  = "CENTER",
    CUSTOM  = "CENTER",
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
        Retire(frame)
        frame = nil
    end

    if not frame then
        local def = KINDS[wanted]
        frame = ((def and def.create) or BUILDERS[wanted] or CreateIconRegion)(aura.id)
        frame.kind = wanted
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
            Retire(frame)
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
    local def = KINDS[kind]
    if def and def.extent then return def.extent(aura) end

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

-- A ring: every child's center on a circle round the group's center,
-- clockwise from `arcStart` degrees off the top, over `arcRange` degrees.
local function CirclePositions(group, children)
    local n = #children
    local widest, spacing = 0, ns.GroupField(group, "spacing")
    local sizes = {}
    for i, child in ipairs(children) do
        local w, h = RegionExtent(child)
        sizes[i] = { w, h }
        widest = math.max(widest, w, h)
    end
    local radius = tonumber(ns.GroupField(group, "radius")) or 0
    if radius <= 0 then
        -- Round enough that they do not overlap.
        radius = math.max(widest, n * (widest + spacing) / (2 * math.pi))
    end
    local start = tonumber(ns.GroupField(group, "arcStart")) or 0
    local range = tonumber(ns.GroupField(group, "arcRange")) or 360
    local step
    if range >= 360 then step = range / math.max(n, 1)
    else step = n > 1 and range / (n - 1) or 0 end
    local out = {}
    for i = 1, n do
        local angle = math.rad(start + (i - 1) * step)
        out[i] = { x = radius * math.sin(angle), y = radius * math.cos(angle),
                   w = sizes[i][1], h = sizes[i][2] }
    end
    return out, 2 * radius + widest, 2 * radius + widest
end
Display.CirclePositions = CirclePositions

-- What a custom growth function said last time, for measuring the group.
local customExtent = {}

function Display:GroupExtent(group, children)
    children = children or ns.Children(group.id)
    if #children == 0 then
        local size = ns.DISPLAY_DEFAULTS.size
        return size, size
    end
    local growth = ns.GroupField(group, "growth")
    if growth == "CIRCLE" then
        local _, w, h = CirclePositions(group, children)
        return w, h
    end
    if growth == "CUSTOM" and customExtent[group.id] then
        return customExtent[group.id][1], customExtent[group.id][2]
    end

    local _, along, across, vertical = Measure(group, children)
    if vertical then return across, along end
    return along, across
end

-- Where a child's state lives: its own, or one clone's of its aura.
local function EntryState(entry, states)
    if not states then return nil end
    if entry.cloneOf then
        local state = states[entry.cloneOf.id]
        for _, clone in ipairs(state and state.clones or {}) do
            if clone.cloneKey == entry.cloneKey then return clone end
        end
        return nil
    end
    return states[entry.id]
end
Display.EntryState = EntryState

-- WeakAuras' custom growth: function(newPositions, activeRegions), filling
-- newPositions[i] = { x, y } from the group's center. Nil if it cannot run.
local function CustomPositions(group, children, states)
    local fn = (not group.untrusted) and ns.Env:Compile(ns.GroupField(group, "growCustom"),
                                                        tostring(group.name or group.id) .. " growth")
    if not fn then return nil end
    local active = {}
    for i, child in ipairs(children) do
        local w, h = RegionExtent(child)
        local state = EntryState(child, states)
        active[i] = { region = regions[child.id], regionWidth = w, regionHeight = h,
                      data = child.cloneOf or child, id = (child.cloneOf or child).id,
                      cloneId = child.cloneKey or "", dataIndex = i, state = state }
        if active[i].region then active[i].region.state = state end
    end
    local positions = {}
    local ok, err = ns.Env:Call(group, fn, positions, active)
    if not ok then
        ns.Env:Report(group, "custom growth", err)
        return nil
    end
    local out, maxX, maxY = {}, 0, 0
    for i = 1, #children do
        local pos = positions[i]
        local x = type(pos) == "table" and tonumber(pos[1] or pos.x) or 0
        local y = type(pos) == "table" and tonumber(pos[2] or pos.y) or 0
        local hidden = type(pos) == "table" and pos[3] == false
        out[i] = { x = x, y = y, w = active[i].regionWidth, h = active[i].regionHeight, hide = hidden }
        maxX = math.max(maxX, math.abs(x) + out[i].w / 2)
        maxY = math.max(maxY, math.abs(y) + out[i].h / 2)
    end
    return out, 2 * maxX, 2 * maxY
end

-- Puts every child where Measure said it goes.
local function Arrange(group, children, states)
    local groupFrame = regions[group.id]
    local growth = ns.GroupField(group, "growth")

    -- Round a ring, or wherever the group's own code says.
    local positions, width, height
    if growth == "CIRCLE" then
        positions, width, height = CirclePositions(group, children)
    elseif growth == "CUSTOM" then
        positions, width, height = CustomPositions(group, children, states)
        if positions then customExtent[group.id] = { width, height } end
    end
    if positions then
        for i, child in ipairs(children) do
            local frame, pos = regions[child.id], positions[i]
            if frame and pos then
                Size(frame, pos.w, pos.h)
                Pin(frame, "CENTER", groupFrame, "CENTER", pos.x, pos.y)
                if pos.hide then frame:Hide() else frame:Show() end
            end
        end
        return width, height
    end

    local lines, along, across, vertical
    lines, along, across, vertical, growth = Measure(group, children)
    local centred = CENTRED[growth]

    for _, line in ipairs(lines) do
        for _, item in ipairs(line.items) do
            local frame = regions[item.child.id]
            if frame then
                Size(frame, item.width, item.height)

                if centred then
                    -- Measured out from the middle, so the whole thing opens
                    -- and closes around its own centre.
                    local alongPos = item.offset + item.along / 2 - line.total / 2
                    local acrossPos = line.crossOffset + item.across / 2 - across / 2

                    if vertical then
                        Pin(frame, "CENTER", groupFrame, "CENTER", acrossPos, -alongPos)
                    else
                        Pin(frame, "CENTER", groupFrame, "CENTER", alongPos, -acrossPos)
                    end

                elseif growth == "LEFT" then
                    Pin(frame, "TOPRIGHT", groupFrame, "TOPRIGHT", -item.offset, -line.crossOffset)
                elseif growth == "UP" then
                    Pin(frame, "BOTTOMLEFT", groupFrame, "BOTTOMLEFT", line.crossOffset, item.offset)
                elseif growth == "DOWN" then
                    Pin(frame, "TOPLEFT", groupFrame, "TOPLEFT", line.crossOffset, -item.offset)
                else
                    Pin(frame, "TOPLEFT", groupFrame, "TOPLEFT", item.offset, -line.crossOffset)
                end

                frame:Show()
            end
        end
    end

    if vertical then return across, along end
    return along, across
end

-- Clones: a state updater's extra states each take a place in the group, as
-- an entry that is the aura in every way but its id.
local cloneEntries = {}
local function CloneEntry(child, clone)
    local byKey = cloneEntries[child.id]
    if not byKey then
        byKey = {}
        cloneEntries[child.id] = byKey
    end
    local entry = byKey[clone.cloneKey]
    if not entry then
        entry = setmetatable({ id = child.id .. "::" .. tostring(clone.cloneKey),
                               cloneOf = child, cloneKey = clone.cloneKey }, { __index = child })
        byKey[clone.cloneKey] = entry
    end
    return entry
end

local function ExpandClones(children, states)
    if not states then return children end
    local out
    for i, child in ipairs(children) do
        local state = (not ns.IsGroup(child)) and states[child.id]
        local clones = state and state.clones
        if clones then
            if not out then
                out = {}
                for j = 1, i - 1 do out[j] = children[j] end
            end
            out[#out + 1] = child
            for c = 2, #clones do out[#out + 1] = CloneEntry(child, clones[c]) end
        elseif out then
            out[#out + 1] = child
        end
    end
    return out or children
end

-- A group's children, in the order the group wants them drawn. Only a dynamic
-- group sorts or filters: a static group's order is its list order, because its
-- whole promise is that a slot does not move.
local function OrderedChildren(group, states)
    local children = ns.Children(group.id)
    local dynamic = (group.type == "dynamic")

    if not dynamic then return ExpandClones(children, states) end

    local showing = {}
    for _, child in ipairs(children) do
        if ns.IsGroup(child) then
            showing[#showing + 1] = child
        else
            local state = states and states[child.id]
            -- Before the first sweep there are no states at all. Treating that
            -- as "nothing is showing" would make a dynamic group flicker empty
            -- on every reload, so an unevaluated child counts as showing.
            -- One playing its finish animation keeps its place until it ends.
            if not states or (state and state.shown) or Display.Finishing(regions[child.id]) then
                showing[#showing + 1] = child
            end
        end
    end
    showing = ExpandClones(showing, states)

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
            local sa = EntryState(a, states)
            local sb = EntryState(b, states)
            local ea = (sa and sa.start and sa.duration) and (sa.start + sa.duration) or math.huge
            local eb = (sb and sb.start and sb.duration) and (sb.start + sb.duration) or math.huge
            if ea == eb then return (a.id or "") < (b.id or "") end
            return ea < eb
        end)
    elseif sort == "custom" then
        -- WeakAuras' custom sort: function(a, b), each { region, data, state }.
        local fn = (not group.untrusted) and ns.Env:Compile(ns.GroupField(group, "sortCustom"),
                                                            tostring(group.name or group.id) .. " sort")
        if fn then
            local failed = false
            local function Wrap(entry)
                return { region = regions[entry.id], data = entry.cloneOf or entry,
                         id = (entry.cloneOf or entry).id, cloneId = entry.cloneKey or "",
                         state = EntryState(entry, states) }
            end
            local before = {}
            for i, entry in ipairs(showing) do before[i] = entry end
            pcall(table.sort, showing, function(a, b)
                if failed then return false end
                local ok, result = ns.Env:Call(group, fn, Wrap(a), Wrap(b))
                if not ok then
                    failed = true
                    ns.Env:Report(group, "custom sort", result)
                    return false
                end
                return result and true or false
            end)
            if failed then
                for i, entry in ipairs(before) do showing[i] = entry end
            end
        end
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
            for _, clone in pairs(Display.ClonesOf(child.id)) do
                if not placed[clone.regionID] then clone:Hide() end
            end
        end
    end

    -- Groups inside this one size themselves first, because this one's layout
    -- is measured from how big they turned out to be.
    for _, child in ipairs(children) do
        if ns.IsGroup(child) then LayoutGroup(child, states) end
    end

    local width, height = Arrange(group, children, states)
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
    Pin(frame, pivot, UIParent, "CENTER",
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
                Size(frame, RegionExtent(aura))
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
        for _, clone in pairs(Display.ClonesOf(aura.id)) do clone:EnableMouse(not locked) end
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
Display.AlphaFor = AlphaFor

-- A StatusBar filling one of four ways.
local DIRECTIONS = {
    RIGHT = { "HORIZONTAL", false }, LEFT = { "HORIZONTAL", true },
    UP    = { "VERTICAL", false },   DOWN = { "VERTICAL", true },
}
function Display.SetDirection(bar, direction)
    local d = DIRECTIONS[direction] or DIRECTIONS.RIGHT
    pcall(bar.SetOrientation, bar, d[1])
    pcall(bar.SetReverseFill, bar, d[2])
    return d[1] == "VERTICAL", d[2]
end

-- The bar's length along its fill, for the spark and the ticks.
function Display.BarLength(aura, kind)
    if kind == "progress" then
        local vertical = DIRECTIONS[ns.DisplayField(aura, "progressDirection")]
        vertical = vertical and vertical[1] == "VERTICAL"
        return vertical and ns.DisplayField(aura, "height") or ns.DisplayField(aura, "width"), vertical
    end
    local d = DIRECTIONS[ns.DisplayField(aura, "barDirection")] or DIRECTIONS.RIGHT
    local height = ns.DisplayField(aura, "barHeight")
    if d[1] == "VERTICAL" then return height, true end
    local width = ns.DisplayField(aura, "barWidth")
    if ns.DisplayField(aura, "barIcon") then width = width - height - 2 end
    return math.max(width, 1), false
end

-- Where along the bar a fraction of it sits, as an offset from the start of
-- the fill -- LEFT and DOWN fill from the far end.
function Display.AlongBar(bar, fraction, length, vertical, reverse, texture, thickness, across)
    local at = fraction * length
    texture:ClearAllPoints()
    if vertical then
        if reverse then texture:SetPoint("CENTER", bar, "TOP", 0, -at)
        else texture:SetPoint("CENTER", bar, "BOTTOM", 0, at) end
        texture:SetSize(across, thickness)
    else
        if reverse then texture:SetPoint("CENTER", bar, "RIGHT", -at, 0)
        else texture:SetPoint("CENTER", bar, "LEFT", at, 0) end
        texture:SetSize(thickness, across)
    end
end

function Display.PlaceSpark(aura, frame, fraction)
    local spark = frame.spark
    if not spark then return end
    if not (fraction and ns.DisplayField(aura, "barSpark")) then
        spark:Hide()
        return
    end
    local length, vertical = Display.BarLength(aura, "bar")
    local d = DIRECTIONS[ns.DisplayField(aura, "barDirection")] or DIRECTIONS.RIGHT
    local height = ns.DisplayField(aura, "barHeight")
    Display.AlongBar(frame.bar, fraction, length, vertical, d[2], spark, 12, height * 2)
    spark:Show()
end

local function RefreshText(aura, frame, state)
    frame:SetAlpha(AlphaFor(aura, state))

    StyleText(frame.text, aura, "textFont", "fontSize", "textOutline", "textColour")
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
    local texture = ns.DisplayField(aura, "barTexture")
    frame.bar:SetStatusBarTexture((texture and texture ~= "") and texture or "Interface\\Buttons\\WHITE8X8")
    frame.bar:SetStatusBarColor(Colour(aura))
    Display.SetDirection(frame.bar, ns.DisplayField(aura, "barDirection"))

    frame.background:ClearAllPoints()
    frame.background:SetAllPoints(frame.bar)
    local br, bg, bb = Hex(ns.DisplayField(aura, "barBackColour"), "000000")
    frame.background:SetColorTexture(br, bg, bb, (ns.DisplayField(aura, "barBackAlpha") or 55) / 100)

    -- A trigger with no duration is not half way through anything, so the bar
    -- reads full rather than empty: it is on, and that is all it knows.
    if not (state.live and ns.DrawLive and ns.DrawLive(frame.bar, state.live)) then
        local fraction = ns.Engine:Progress(state)
        if fraction and ns.DisplayField(aura, "barInverse") then fraction = 1 - fraction end
        frame.bar:SetMinMaxValues(0, 1)
        if not fraction and state.durationObject and type(frame.bar.SetTimerDuration) == "function"
           and pcall(frame.bar.SetTimerDuration, frame.bar, state.durationObject) then
            -- In combat a cooldown's times are secret; the client's duration
            -- object still runs the bar.
        else
            frame.bar:SetValue(fraction or 1)
        end
        Display.PlaceSpark(aura, frame, fraction)
    end

    StyleText(frame.text, aura, "barFont", "barFontSize", "barOutline", "barTextColour")
    frame.text:SetText(ns.Engine:FormatText(
        ns.DisplayField(aura, "barFormat"), aura, state))

    -- Kept for the OnUpdate, which is what makes the timer run smoothly
    -- between sweeps.
    frame.lastState = state
end

local function RefreshIcon(aura, frame, state)
    frame.texture:SetTexture(state.icon)
    -- Zoom crops the art in from the trim every icon gets.
    local zoom = (tonumber(ns.DisplayField(aura, "iconZoom")) or 0) / 100
    local inset = math.min(0.07 + zoom * 0.5, 0.45)
    frame.texture:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
    pcall(frame.cooldown.SetReverse, frame.cooldown, ns.DisplayField(aura, "cooldownReverse") and true or false)
    pcall(frame.cooldown.SetDrawEdge, frame.cooldown, ns.DisplayField(aura, "cooldownEdge") and true or false)
    pcall(frame.cooldown.SetHideCountdownNumbers, frame.cooldown, not ns.DisplayField(aura, "cooldownText"))

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

    local swipe = ns.DisplayField(aura, "swipe")
    if state.start and state.duration and swipe then
        frame.cooldown:SetCooldown(state.start, state.duration)
    elseif state.durationObject and swipe
        and type(frame.cooldown.SetCooldownFromDurationObject) == "function" then
        -- In combat a cooldown's times are secret; the client's duration
        -- object is the one thing that still draws it correctly.
        if not pcall(frame.cooldown.SetCooldownFromDurationObject, frame.cooldown,
                     state.durationObject) then
            frame.cooldown:Clear()
        end
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

    -- The text on the icon. Placed a little inside the edge it is pinned to,
    -- so a corner does not hang off the icon.
    local overlayFormat = ns.DisplayField(aura, "iconText")
    if frame.overlay then
        if overlayFormat and overlayFormat ~= "" then
            local point = ns.DisplayField(aura, "iconTextPoint")
            local dx = point:find("LEFT") and 2 or (point:find("RIGHT") and -2 or 0)
            local dy = point:find("TOP") and -2 or (point:find("BOTTOM") and 2 or 0)
            frame.overlay:ClearAllPoints()
            frame.overlay:SetPoint(point, frame, point, dx, dy)
            StyleText(frame.overlay, aura, "iconTextFont", "iconTextSize",
                      "iconTextOutline", "iconTextColour")
            frame.overlay:SetText(ns.Engine:FormatText(overlayFormat, aura, state))
            frame.overlay:Show()
        else
            frame.overlay:SetText("")
            frame.overlay:Hide()
        end
    end


end

-------------------------------------------------------------------------------
-- What a condition changes
-------------------------------------------------------------------------------
-- A condition's properties go on after the region has drawn itself, so they
-- override it while they hold and are gone the sweep after they stop.

-- A glow: a pulsing border. This client has no action-button glow, so it is
-- made here out of four edges and one animation.
-- `owner` keeps the glow; `target`, when it is another frame (a unit frame,
-- an action button), is what it goes round. That one is not made the glow's
-- parent: a child of a protected frame would make trouble in combat, so the
-- glow hangs off UIParent and is only anchored there.
--
-- Three styles, after LibCustomGlow's: pulse (a border breathing in and out),
-- pixel (lines running round the edge) and shine (dots running round it).
local DEFAULT_GLOW = { type = "pulse", r = 1, g = 0.85, b = 0.2, lines = 8, thickness = 2, speed = 0.25 }

function Display.GlowStyle(aura)
    local r, g, b = Hex(ns.DisplayField(aura, "glowColour"), "ffd933")
    local lines = math.max(1, math.min(30, tonumber(ns.DisplayField(aura, "glowLines")) or 8))
    return { type = ns.DisplayField(aura, "glowType") or "pulse", r = r, g = g, b = b,
             lines = lines, thickness = tonumber(ns.DisplayField(aura, "glowThickness")) or 2,
             speed = (tonumber(ns.DisplayField(aura, "glowSpeed")) or 25) / 100 }
end

-- Lines or dots spaced round the glow's edge, `phase` of the way on.
local function PlaceRunners(glow)
    local ok, w, h = pcall(glow.GetSize, glow)
    w, h = ok and ns.SafeNumber(w) or 0, ok and ns.SafeNumber(h) or 0
    if w <= 0 or h <= 0 then return end
    local perimeter = 2 * (w + h)
    local n, th = #glow.runners, glow.thickness
    local length = glow.dots and th * 2 or perimeter / n * 0.4
    for i, tex in ipairs(glow.runners) do
        local d = (((i - 1) / n + glow.phase) % 1) * perimeter
        local x, y, sw, sh
        if d < w then
            x, y, sw, sh = d, 0, math.min(length, w - d), th
        elseif d < w + h then
            x, y, sw, sh = w - th, d - w, th, math.min(length, w + h - d)
        elseif d < 2 * w + h then
            local run = math.min(length, 2 * w + h - d)
            x, y, sw, sh = w - (d - w - h) - run, h - th, run, th
        else
            local run = math.min(length, perimeter - d)
            x, y, sw, sh = 0, h - (d - 2 * w - h) - run, th, run
        end
        if glow.dots then sw, sh = th * 2, th * 2 end
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", glow, "TOPLEFT", x, -y)
        tex:SetSize(math.max(sw, 1), math.max(sh, 1))
    end
end

local function BuildGlow(owner, target, style)
    local external = target ~= owner
    local glow = CreateFrame("Frame", nil, external and UIParent or owner)
    local pad = (style.type == "pulse") and 3 or 1
    glow:SetPoint("TOPLEFT", target, "TOPLEFT", -pad, pad)
    glow:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", pad, -pad)
    if external then
        local okS, strata = pcall(target.GetFrameStrata, target)
        if okS and type(strata) == "string" then pcall(glow.SetFrameStrata, glow, strata) end
    end
    local okL, level = pcall(target.GetFrameLevel, target)
    pcall(glow.SetFrameLevel, glow, ((okL and type(level) == "number") and level or 0) + 12)
    glow.textures = {}
    glow.style = style.type

    if style.type == "pixel" or style.type == "shine" then
        glow.runners, glow.phase, glow.dots = {}, 0, style.type == "shine"
        glow.thickness = math.max(1, style.thickness)
        for i = 1, style.lines do
            local t = glow:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1, 1, 1, 1)
            glow.runners[i] = t
            glow.textures[#glow.textures + 1] = t
        end
        glow:SetScript("OnUpdate", function(self, elapsed)
            self.phase = (self.phase + (tonumber(elapsed) or 0) * (self.speed or 0.25)) % 1
            PlaceRunners(self)
        end)
        return glow
    end

    local thick = math.max(1, style.thickness + 1)
    local function Edge(a, b, horizontal)
        local t = glow:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 1)
        t:SetPoint(a, glow, a)
        t:SetPoint(b, glow, b)
        if horizontal then t:SetHeight(thick) else t:SetWidth(thick) end
        glow.textures[#glow.textures + 1] = t
    end
    Edge("TOPLEFT", "TOPRIGHT", true)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    Edge("TOPLEFT", "BOTTOMLEFT", false)
    Edge("TOPRIGHT", "BOTTOMRIGHT", false)
    local okA, pulse = pcall(glow.CreateAnimationGroup, glow)
    if okA and pulse then
        pcall(pulse.SetLooping, pulse, "BOUNCE")
        local fade = pulse:CreateAnimation("Alpha")
        fade:SetFromAlpha(1)
        fade:SetToAlpha(0.25)
        fade:SetDuration(0.5)
        glow.pulse = pulse
    end
    return glow
end

local function Glow(owner, on, target, style)
    if not on then
        if owner.glow then owner.glow:Hide() end
        return
    end
    target = target or owner
    style = style or DEFAULT_GLOW
    local key = style.type .. ":" .. style.lines .. ":" .. style.thickness
    owner.glows = owner.glows or {}
    local glow = owner.glows[key]
    if not glow then
        glow = BuildGlow(owner, target, style)
        owner.glows[key] = glow
    end
    if owner.glow and owner.glow ~= glow then owner.glow:Hide() end
    owner.glow = glow
    -- Color and speed change without a rebuild.
    for _, t in ipairs(glow.textures) do t:SetVertexColor(style.r, style.g, style.b, 1) end
    glow.speed = style.speed
    if not glow:IsShown() then
        glow:Show()
        if glow.pulse then pcall(glow.pulse.Play, glow.pulse) end
    end
end
Display.Glow = Glow

-- A region's main color: an icon's or texture's art, a bar's fill, a text's
-- words. What a condition's color and a color animation set.
function Display.ColourRegion(frame, kind, r, g, b, a)
    local def = KINDS[kind]
    if def and def.colour then return def.colour(frame, r, g, b, a) end
    if (kind == "icon" or kind == "texture") and frame.texture then
        frame.texture:SetVertexColor(r, g, b, a or 1)
    elseif kind == "bar" and frame.bar then
        frame.bar:SetStatusBarColor(r, g, b, a or 1)
    elseif kind == "text" and frame.text then
        frame.text:SetTextColor(r, g, b, a or 1)
    end
end

-- Playing its finish animation: still on screen, though no longer shown.
function Display.Finishing(frame)
    return frame ~= nil and frame.anim ~= nil and frame.anim.which == "finish"
end

local function ApplyProps(aura, frame, state, kind)
    local props = state.props or {}
    -- Put back what a condition may have changed last time.
    if frame.propScaled then
        pcall(frame.SetScale, frame, 1)
        frame.propScaled = nil
    end
    if kind == "icon" and frame.texture then frame.texture:SetVertexColor(1, 1, 1) end

    if not next(props) then return false end

    local visible = (tonumber(frame:GetAlpha()) or 0) > 0
    if props.alpha ~= nil and visible then
        pcall(frame.SetAlpha, frame, math.max(0, math.min(1, (tonumber(props.alpha) or 100) / 100)))
    end
    local colour = props.color
    if type(colour) == "table" then
        local r, g, b = tonumber(colour[1]) or 1, tonumber(colour[2]) or 1, tonumber(colour[3]) or 1
        Display.ColourRegion(frame, kind, r, g, b, 1)
    end
    if props.desaturate ~= nil and kind == "icon" and frame.texture then
        frame.texture:SetDesaturated(props.desaturate and true or false)
    end
    if props.scale ~= nil then
        local scale = tonumber(props.scale)
        if scale and scale > 0 then
            pcall(frame.SetScale, frame, scale)
            frame.propScaled = true
        end
    end
    if type(props.text) == "string" then
        local text = ns.Engine:FormatText(props.text, aura, state)
        local target = (kind == "icon") and frame.overlay or frame.text
        if target then
            target:SetText(text)
            target:Show()
        end
    end
    return props.glow and true or false
end
Display.ApplyProps = ApplyProps

-- Draws one region from one state: its shape, what hangs off it, what a
-- condition changes, its glow and its animation. An aura's own region and
-- each of its clones go through here.
local function DrawRegion(aura, frame, state, kind)
    local def = KINDS[kind]
    if def and def.refresh then
        def.refresh(aura, frame, state)
    elseif kind == "text" then
        RefreshText(aura, frame, state)
    elseif kind == "bar" then
        RefreshBar(aura, frame, state)
    else
        RefreshIcon(aura, frame, state)
    end

    local live = (state.shown and state.loaded) and true or false
    if ns.SubRegions then ns.SubRegions:Apply(aura, frame, state, kind, live) end
    local propGlow = ApplyProps(aura, frame, state, kind)
    local visible = (tonumber(frame:GetAlpha()) or 0) > 0
    local glowOn = visible and (propGlow or (live and ns.DisplayField(aura, "glow")))
    Glow(frame, glowOn and true or false, nil, Display.GlowStyle(aura))

    frame.baseAlpha = tonumber(frame:GetAlpha()) or 1
    frame.animState = state
    if ns.Animations then ns.Animations:Sync(aura, frame, state, live) end
end
Display.DrawRegion = DrawRegion

-- Clone regions, kept per aura so they are reused rather than made again.
local clonePool = {}
function Display.ClonesOf(id) return clonePool[id] or {} end

local function CloneFrame(aura, key)
    local pool = clonePool[aura.id]
    if not pool then
        pool = {}
        clonePool[aura.id] = pool
    end
    local wanted = ns.RegionKind(aura)
    local frame = pool[key]
    if frame and frame.kind ~= wanted then
        Retire(frame)
        frame = nil
    end
    if not frame then
        local def = KINDS[wanted]
        frame = ((def and def.create) or BUILDERS[wanted] or CreateIconRegion)(aura.id)
        frame.kind = wanted
        frame.auraID, frame.cloneKey = aura.id, key
        frame.regionID = aura.id .. "::" .. tostring(key)
        MakeDraggable(frame)
        pool[key] = frame
    end
    -- New to the layout (made, or back after a rebuild): it needs placing.
    local fresh = regions[frame.regionID] ~= frame
    regions[frame.regionID] = frame
    frame:SetParent((aura.parent and regions[aura.parent]) or UIParent)
    frame:EnableMouse(not (ns.profile and ns.profile.locked))
    return frame, fresh
end

local function DropClones(aura, keep)
    for key, frame in pairs(clonePool[aura.id] or {}) do
        if not (keep and keep[key]) then
            if regions[frame.regionID] == frame then regions[frame.regionID] = nil end
            Retire(frame)
        end
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

                -- Loading and unloading are moments of their own, for the
                -- on-load and on-unload actions.
                if ns.Actions then
                    if loaded and not frame.wasLoaded then
                        ns.Actions:Fire(aura, state, "load")
                    elseif frame.wasLoaded and not loaded then
                        ns.Actions:Fire(aura, state, "unload")
                    end
                end

                if loaded then
                    if frame.wasLoaded then
                        if state.shown and not frame.wasShown then
                            if frame.fade and ns.DisplayField(aura, "flash") then
                                frame.fade:Stop()
                                frame.fade:Play()
                            end
                            Display:PlayAction(aura, "onShow")
                            if ns.Actions then ns.Actions:Fire(aura, state, "show") end
                        elseif frame.wasShown and not state.shown then
                            Display:PlayAction(aura, "onHide")
                            if ns.Actions then ns.Actions:Fire(aura, state, "hide") end
                        end
                    end
                    frame.wasShown = state.shown
                end
                frame.wasLoaded = loaded
                if ns.Actions then ns.Actions:UpdateGlow(aura, state) end

                local kind = ns.RegionKind(aura)
                DrawRegion(aura, frame, state, kind)

                -- Inside a group, a state updater's other states get a region
                -- each; a new set of them needs a new layout.
                local clones = aura.parent and state.clones
                local keep, signature = nil, ""
                if clones then
                    keep = {}
                    for c = 2, #clones do
                        local clone = clones[c]
                        clone.props = state.props
                        keep[clone.cloneKey] = true
                        signature = signature .. "|" .. tostring(clone.cloneKey)
                        local cloneFrame, fresh = CloneFrame(aura, clone.cloneKey)
                        if fresh then relayout = true end
                        DrawRegion(aura, cloneFrame, clone, kind)
                    end
                end
                DropClones(aura, keep)
                if (frame.cloneSignature or "") ~= signature then relayout = true end
                frame.cloneSignature = signature

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
