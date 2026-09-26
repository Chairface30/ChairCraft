local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Sub-regions: what hangs off a region
-------------------------------------------------------------------------------
-- WeakAuras' sub-regions, on every shape but a group:
--
--   background   a colored panel behind it
--   border       a colored edge round it
--   texts        any number of texts, each placed, styled and written with
--                the text codes (display.texts, a list)
--   ticks        marks along a bar or linear progress texture, at seconds
--                left or at a per cent
--
-- The glow is the display's own (Display.Glow), because conditions and the
-- external glow use it as well.

local SubRegions = {}
ns.SubRegions = SubRegions

local Display = ns.Display
local Hex = Display.Hex

local function Above(frame, child, plus)
    local ok, level = pcall(frame.GetFrameLevel, frame)
    pcall(child.SetFrameLevel, child, ((ok and type(level) == "number") and level or 0) + plus)
end

local function Background(aura, frame)
    if not ns.DisplayField(aura, "backdrop") then
        if frame.subBackdrop then frame.subBackdrop:Hide() end
        return
    end
    local tex = frame.subBackdrop
    if not tex then
        tex = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        frame.subBackdrop = tex
    end
    local pad = tonumber(ns.DisplayField(aura, "borderOffset")) or 0
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", frame, "TOPLEFT", -pad, pad)
    tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", pad, -pad)
    local r, g, b = Hex(ns.DisplayField(aura, "backdropColour"), "000000")
    tex:SetColorTexture(r, g, b, (tonumber(ns.DisplayField(aura, "backdropAlpha")) or 50) / 100)
    tex:Show()
end

local function Border(aura, frame)
    if not ns.DisplayField(aura, "border") then
        if frame.subBorder then frame.subBorder:Hide() end
        return
    end
    local holder = frame.subBorder
    if not holder then
        holder = CreateFrame("Frame", nil, frame)
        Above(frame, holder, 11)
        holder.edges = {}
        for i = 1, 4 do holder.edges[i] = holder:CreateTexture(nil, "OVERLAY") end
        frame.subBorder = holder
    end
    local size = math.max(1, tonumber(ns.DisplayField(aura, "borderSize")) or 1)
    local pad = tonumber(ns.DisplayField(aura, "borderOffset")) or 0
    holder:ClearAllPoints()
    holder:SetPoint("TOPLEFT", frame, "TOPLEFT", -pad, pad)
    holder:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", pad, -pad)
    local r, g, b = Hex(ns.DisplayField(aura, "borderColour"), "000000")
    local sides = {
        { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i, side in ipairs(sides) do
        local edge = holder.edges[i]
        edge:ClearAllPoints()
        edge:SetPoint(side[1], holder, side[1])
        edge:SetPoint(side[2], holder, side[2])
        if side[3] then edge:SetHeight(size) else edge:SetWidth(size) end
        edge:SetColorTexture(r, g, b, 1)
    end
    holder:Show()
    frame.subBorder.size = size
end

-------------------------------------------------------------------------------
-- More text
-------------------------------------------------------------------------------

-- A new text's settings, and what an empty field means.
SubRegions.TEXT_DEFAULTS = {
    text = "%n", point = "CENTER", x = 0, y = 0, size = 12,
    font = "", outline = "OUTLINE", colour = "ffffff",
}
local TEXT_DEFAULTS = SubRegions.TEXT_DEFAULTS

function SubRegions.TextField(entry, key)
    local value = type(entry) == "table" and entry[key]
    if value == nil then return TEXT_DEFAULTS[key] end
    return value
end
local TextField = SubRegions.TextField

local function StyleOne(fontString, entry)
    local current, _, currentFlags = fontString:GetFont()
    if not fontString.baseFont then
        fontString.baseFont, fontString.baseFlags = current, currentFlags
    end
    local font = TextField(entry, "font")
    local outline = TextField(entry, "outline")
    local flags = (outline == "NONE") and "" or ((outline and outline ~= "") and outline or fontString.baseFlags or "")
    local path = (font and font ~= "") and font or fontString.baseFont
    local size = tonumber(TextField(entry, "size")) or 12
    if path and not pcall(fontString.SetFont, fontString, path, size, flags) then
        pcall(fontString.SetFont, fontString, fontString.baseFont, size, flags)
    end
    fontString:SetTextColor(Hex(TextField(entry, "colour"), "ffffff"))
end

local function Texts(aura, frame, state)
    local list = type(aura.display) == "table" and aura.display.texts
    local count = type(list) == "table" and #list or 0
    frame.subTexts = frame.subTexts or {}
    if count > 0 and not frame.subTextFrame then
        -- Above the cooldown swipe and the flash, like the icon's own text.
        local holder = CreateFrame("Frame", nil, frame)
        holder:SetAllPoints()
        Above(frame, holder, 10)
        frame.subTextFrame = holder
    end
    for i = 1, count do
        local entry = list[i]
        local fontString = frame.subTexts[i]
        if not fontString then
            fontString = frame.subTextFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            if ns.EnsureFont then ns.EnsureFont(fontString) end
            frame.subTexts[i] = fontString
        end
        local point = TextField(entry, "point")
        fontString:ClearAllPoints()
        fontString:SetPoint(point, frame, point, tonumber(TextField(entry, "x")) or 0,
                            tonumber(TextField(entry, "y")) or 0)
        StyleOne(fontString, entry)
        fontString:SetText(ns.Engine:FormatText(TextField(entry, "text") or "", aura, state))
        fontString:Show()
    end
    for i = count + 1, #frame.subTexts do
        frame.subTexts[i]:SetText("")
        frame.subTexts[i]:Hide()
    end
end

-------------------------------------------------------------------------------
-- Ticks
-------------------------------------------------------------------------------

local function TickValues(text)
    local out = {}
    for number in tostring(text or ""):gmatch("[%d%.]+") do
        local value = tonumber(number)
        if value then out[#out + 1] = value end
    end
    return out
end
SubRegions.TickValues = TickValues

local REVERSED = { LEFT = true, DOWN = true }

local function Ticks(aura, frame, state, kind)
    local bar = frame.bar
    local linear = kind == "bar" or (kind == "progress" and ns.DisplayField(aura, "progressStyle") ~= "circular")
    local values = linear and bar and TickValues(ns.DisplayField(aura, "ticks")) or {}
    frame.subTicks = frame.subTicks or {}

    local mode = ns.DisplayField(aura, "tickMode")
    local inverse = (kind == "bar") and ns.DisplayField(aura, "barInverse")
                    or (kind == "progress" and ns.DisplayField(aura, "progressInverse"))
    local direction = (kind == "bar") and ns.DisplayField(aura, "barDirection")
                      or ns.DisplayField(aura, "progressDirection")
    local length, vertical = Display.BarLength(aura, kind)
    local across
    if kind == "bar" then
        across = vertical and ns.DisplayField(aura, "barWidth") or ns.DisplayField(aura, "barHeight")
    else
        across = vertical and ns.DisplayField(aura, "width") or ns.DisplayField(aura, "height")
    end
    local thickness = math.max(1, tonumber(ns.DisplayField(aura, "tickThickness")) or 2)
    local r, g, b = Hex(ns.DisplayField(aura, "tickColour"), "ffffff")
    local duration = state and state.duration

    local shown = 0
    for _, value in ipairs(values) do
        local fraction
        if mode == "percent" then
            fraction = value / 100
        elseif duration and duration > 0 then
            -- The bar shows time left, so a mark at 3 seconds sits where
            -- 3 seconds is left.
            fraction = value / duration
        end
        if fraction and fraction >= 0 and fraction <= 1 then
            if inverse and mode ~= "percent" then fraction = 1 - fraction end
            shown = shown + 1
            local tex = frame.subTicks[shown]
            if not tex then
                tex = bar:CreateTexture(nil, "OVERLAY")
                frame.subTicks[shown] = tex
            end
            tex:SetColorTexture(r, g, b, 1)
            Display.AlongBar(bar, fraction, length, vertical, REVERSED[direction], tex, thickness, across)
            tex:Show()
        end
    end
    for i = shown + 1, #frame.subTicks do frame.subTicks[i]:Hide() end
    frame.ticksShown = shown
end

function SubRegions:Apply(aura, frame, state, kind, live)
    if kind == "group" then return end
    Background(aura, frame)
    Border(aura, frame)
    Texts(aura, frame, state)
    Ticks(aura, frame, state, kind)
end
