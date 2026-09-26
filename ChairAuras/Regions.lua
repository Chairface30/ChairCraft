local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Regions: the shapes beyond icon, text and bar
-------------------------------------------------------------------------------
-- WeakAuras' texture, progress texture and model, each registered with the
-- display: how it is made, drawn, measured and colored.
--
--   texture    a picture -- a game file, a file ID, or the aura's own icon --
--              colored, turned, mirrored, added or blended
--   progress   a texture that fills with the timer, as a bar (four ways) or
--              round like a cooldown swipe
--   model      a unit's model, or one by display or file ID; PlayerModel is
--              on this client (probe, 2026-09-26)
--
-- Secret values are handled the way the bar handles them: health and power
-- are handed to the StatusBar to draw, and a cooldown's secret times go
-- through the client's duration object.

local Display = ns.Display
local Hex = Display.Hex

local WHITE = "Interface\\Buttons\\WHITE8X8"

local function FreeSize(aura)
    return ns.DisplayField(aura, "width"), ns.DisplayField(aura, "height")
end

-- A texture setting: a path, a file ID, or "icon" for the aura's own.
local function Picture(value, state)
    if value == "icon" then return state and state.icon end
    if value == nil or value == "" then return WHITE end
    return tonumber(value) or value
end
ns.Picture = Picture

-------------------------------------------------------------------------------
-- Texture
-------------------------------------------------------------------------------

local function CreateTextureRegion()
    local region = CreateFrame("Frame", nil, UIParent)
    region.texture = region:CreateTexture(nil, "ARTWORK")
    region.texture:SetAllPoints()
    return region
end

local function RefreshTexture(aura, frame, state)
    frame:SetAlpha(Display.AlphaFor(aura, state))
    local tex = frame.texture
    tex:SetTexture(Picture(ns.DisplayField(aura, "texture"), state))
    pcall(tex.SetBlendMode, tex, ns.DisplayField(aura, "textureBlend") == "ADD" and "ADD" or "BLEND")
    if ns.DisplayField(aura, "textureMirror") then
        tex:SetTexCoord(1, 0, 0, 1)
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
    frame.baseRotation = tonumber(ns.DisplayField(aura, "textureRotation")) or 0
    if not (frame.anim and frame.anim.rotating) then
        pcall(tex.SetRotation, tex, math.rad(frame.baseRotation))
    end
    local r, g, b = Hex(ns.DisplayField(aura, "textureColour"), "ffffff")
    tex:SetVertexColor(r, g, b, 1)
    tex:SetDesaturated((not state.shown) and ns.DisplayField(aura, "desaturate") and true or false)
end

Display.RegisterKind("texture", {
    create = CreateTextureRegion, refresh = RefreshTexture, extent = FreeSize,
})

-------------------------------------------------------------------------------
-- Progress texture
-------------------------------------------------------------------------------

local function Fraction(aura, state)
    local fraction = ns.Engine:Progress(state)
    if fraction and ns.DisplayField(aura, "progressInverse") then fraction = 1 - fraction end
    return fraction
end

local function CreateProgressRegion()
    local region = CreateFrame("Frame", nil, UIParent)
    region.background = region:CreateTexture(nil, "BACKGROUND")
    region.background:SetAllPoints()

    region.bar = CreateFrame("StatusBar", nil, region)
    region.bar:SetAllPoints()
    region.bar:SetMinMaxValues(0, 1)
    region.bar:SetValue(1)

    region.circle = CreateFrame("Cooldown", nil, region, "CooldownFrameTemplate")
    region.circle:SetAllPoints()
    pcall(region.circle.SetDrawEdge, region.circle, false)
    pcall(region.circle.SetHideCountdownNumbers, region.circle, true)

    -- Round with no timer to run: drawn whole.
    region.full = region:CreateTexture(nil, "ARTWORK")
    region.full:SetAllPoints()
    region.full:Hide()

    -- Smooth between sweeps, as the bar is.
    region:SetScript("OnUpdate", function(self)
        local aura = ns.FindAura(self.auraID)
        local state = self.lastState
        if not (aura and state) or self.round then return end
        if state.live and ns.DrawLive and ns.DrawLive(self.bar, state.live) then return end
        local fraction = Fraction(aura, state)
        if fraction then self.bar:SetValue(fraction) end
    end)
    return region
end

local function ProgressColour(aura)
    local hex = ns.DisplayField(aura, "progressColour")
    if not hex or hex == "" then hex = ns.DisplayField(aura, "colour") end
    return Hex(hex, "ffffff")
end

local function RefreshProgress(aura, frame, state)
    frame:SetAlpha(Display.AlphaFor(aura, state))
    local path = Picture(ns.DisplayField(aura, "progressTexture"), state)
    local r, g, b = ProgressColour(aura)

    frame.background:SetTexture(path)
    local br, bg, bb = Hex(ns.DisplayField(aura, "progressBackColour"), "000000")
    frame.background:SetVertexColor(br, bg, bb, (ns.DisplayField(aura, "progressBackAlpha") or 50) / 100)

    frame.lastState = state
    if ns.DisplayField(aura, "progressStyle") == "circular" then
        frame.round = true
        frame.bar:Hide()
        local circle = frame.circle
        circle:Show()
        pcall(circle.SetSwipeTexture, circle, path)
        pcall(circle.SetSwipeColor, circle, r, g, b, 1)
        pcall(circle.SetReverse, circle, ns.DisplayField(aura, "progressInverse") and true or false)
        local drawn = false
        if state.start and state.duration and state.duration > 0 then
            drawn = pcall(circle.SetCooldown, circle, state.start, state.duration)
        elseif state.durationObject and type(circle.SetCooldownFromDurationObject) == "function" then
            drawn = pcall(circle.SetCooldownFromDurationObject, circle, state.durationObject)
        end
        if drawn then
            frame.full:Hide()
        else
            pcall(circle.Clear, circle)
            frame.full:SetTexture(path)
            frame.full:SetVertexColor(r, g, b, 1)
            frame.full:Show()
        end
        return
    end

    frame.round = false
    frame.circle:Hide()
    frame.full:Hide()
    local bar = frame.bar
    bar:Show()
    bar:SetStatusBarTexture(path)
    bar:SetStatusBarColor(r, g, b, 1)
    Display.SetDirection(bar, ns.DisplayField(aura, "progressDirection"))
    if state.live and ns.DrawLive and ns.DrawLive(bar, state.live) then return end
    local fraction = Fraction(aura, state)
    bar:SetMinMaxValues(0, 1)
    if not fraction and state.durationObject and type(bar.SetTimerDuration) == "function"
       and pcall(bar.SetTimerDuration, bar, state.durationObject) then
        return
    end
    bar:SetValue(fraction or 1)
end

Display.RegisterKind("progress", {
    create = CreateProgressRegion, refresh = RefreshProgress, extent = FreeSize,
    colour = function(frame, r, g, b, a)
        if frame.round then
            pcall(frame.circle.SetSwipeColor, frame.circle, r, g, b, a or 1)
            frame.full:SetVertexColor(r, g, b, a or 1)
        else
            frame.bar:SetStatusBarColor(r, g, b, a or 1)
        end
    end,
})

-------------------------------------------------------------------------------
-- Model
-------------------------------------------------------------------------------

local function CreateModelRegion()
    local region = CreateFrame("Frame", nil, UIParent)
    local ok, model = pcall(CreateFrame, "PlayerModel", nil, region)
    if ok and model then
        model:SetAllPoints()
        region.model = model
    end
    return region
end

local function RefreshModel(aura, frame, state)
    frame:SetAlpha(Display.AlphaFor(aura, state))
    local model = frame.model
    if not model then return end

    -- Loading a model is not free, so it is loaded again only when what it
    -- should show has changed: another unit in that slot, or another ID.
    local source = ns.DisplayField(aura, "modelSource")
    local key
    local unit = ns.DisplayField(aura, "modelUnit")
    if source == "unit" then
        local okG, guid = pcall(UnitGUID, unit)
        key = "unit:" .. unit .. ":" .. tostring((okG and ns.SafeText(guid)) or "none")
    else
        key = source .. ":" .. tostring(ns.DisplayField(aura, "modelID"))
    end
    if key ~= frame.modelKey then
        frame.modelKey = key
        pcall(model.ClearModel, model)
        local id = tonumber(ns.DisplayField(aura, "modelID")) or 0
        if source == "unit" then
            local okE, exists = pcall(UnitExists, unit)
            if okE and exists then pcall(model.SetUnit, model, unit) end
        elseif source == "display" then
            if id > 0 then pcall(model.SetDisplayInfo, model, id) end
        elseif id > 0 then
            pcall(model.SetModel, model, id)
        end
    end
    pcall(model.SetFacing, model, math.rad(tonumber(ns.DisplayField(aura, "modelFacing")) or 0))
    pcall(model.SetPortraitZoom, model, (tonumber(ns.DisplayField(aura, "modelZoom")) or 0) / 100)
end

Display.RegisterKind("model", {
    create = CreateModelRegion, refresh = RefreshModel, extent = FreeSize,
    colour = function() end,
})
