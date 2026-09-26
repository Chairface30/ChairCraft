local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Animations
-------------------------------------------------------------------------------
-- WeakAuras' three slots, in its data shape (aura.animation.start/main/finish):
--
--   start    plays as the aura comes up, running from its settings back to
--            how the aura normally looks (a fade in from alpha 0)
--   main     loops for as long as it shows
--   finish   plays as it goes, from how it looks to its settings; the region
--            stays on screen, and keeps its place in a dynamic group, until
--            it ends
--
-- Each is none, one of WeakAuras' presets, or custom: alpha, translate,
-- scale, rotate and color, each along one of WeakAuras' paths (straight,
-- pulse, circle, bounce...) or a Lua function of its own, with WeakAuras'
-- easing. Translation moves the region from where layout pinned it; scale
-- resizes it; rotation turns an icon's or texture's art.
--
-- Driven from one OnUpdate rather than AnimationGroups, so the same code
-- can put everything back exactly, and the tests can step it.

local Anim = {}
ns.Animations = Anim

local Display = ns.Display

-- WeakAuras' presets (Prototypes.lua anim_presets), as they are.
Anim.PRESETS = {
    slidetop    = { duration = 0.25, use_translate = true, x = 0, y = 50, use_alpha = true, alpha = 0 },
    slideleft   = { duration = 0.25, use_translate = true, x = -50, y = 0, use_alpha = true, alpha = 0 },
    slideright  = { duration = 0.25, use_translate = true, x = 50, y = 0, use_alpha = true, alpha = 0 },
    slidebottom = { duration = 0.25, use_translate = true, x = 0, y = -50, use_alpha = true, alpha = 0 },
    fade        = { duration = 0.25, use_alpha = true, alpha = 0 },
    grow        = { duration = 0.25, use_scale = true, scalex = 2, scaley = 2, use_alpha = true, alpha = 0 },
    shrink      = { duration = 0.25, use_scale = true, scalex = 0, scaley = 0, use_alpha = true, alpha = 0 },
    spiral      = { duration = 0.5, use_translate = true, x = 100, y = 100, translateType = "spiral",
                    use_alpha = true, alpha = 0 },
    bounceDecay = { duration = 1.5, use_translate = true, x = 50, y = 50, translateType = "bounceDecay",
                    use_alpha = true, alpha = 0 },
    starShakeDecay = { duration = 1, use_translate = true, x = 50, y = 50, translateType = "starShakeDecay",
                       use_alpha = true, alpha = 0 },
    shake       = { duration = 0.5, use_translate = true, x = 10, y = 0, translateType = "circle2" },
    spin        = { duration = 1, use_scale = true, scalex = 1, scaley = 1, scaleType = "fauxspin" },
    flip        = { duration = 1, use_scale = true, scalex = 1, scaley = 1, scaleType = "fauxflip" },
    wobble      = { duration = 0.5, use_rotate = true, rotate = 3, rotateType = "wobble" },
    pulse       = { duration = 0.75, use_scale = true, scalex = 1.05, scaley = 1.05, scaleType = "pulse" },
    alphaPulse  = { duration = 0.5, use_alpha = true, alpha = 0.5, alphaType = "alphaPulse" },
    rotateClockwise        = { duration = 4, use_rotate = true, rotate = -360 },
    rotateCounterClockwise = { duration = 4, use_rotate = true, rotate = 360 },
    spiralandpulse = { duration = 6, use_translate = true, x = 100, y = 100, translateType = "spiralandpulse" },
    circle      = { duration = 4, use_translate = true, x = 100, y = 100, translateType = "circle" },
    orbit       = { duration = 4, use_translate = true, x = 100, y = 100, translateType = "circle",
                    use_rotate = true, rotate = 360 },
    bounce      = { duration = 0.6, use_translate = true, x = 0, y = 25, translateType = "bounce" },
}

-- Which presets each slot offers, in WeakAuras' words.
Anim.SLOT_PRESETS = {
    start = {
        { "slidetop", "Slide from Top" }, { "slideleft", "Slide from Left" },
        { "slideright", "Slide from Right" }, { "slidebottom", "Slide from Bottom" },
        { "fade", "Fade In" }, { "shrink", "Grow" }, { "grow", "Shrink" },
        { "spiral", "Spiral" }, { "bounceDecay", "Bounce" }, { "starShakeDecay", "Star Shake" },
    },
    main = {
        { "shake", "Shake" }, { "spin", "Spin" }, { "flip", "Flip" }, { "wobble", "Wobble" },
        { "pulse", "Pulse" }, { "alphaPulse", "Flash" }, { "rotateClockwise", "Rotate Right" },
        { "rotateCounterClockwise", "Rotate Left" }, { "spiralandpulse", "Spiral" },
        { "orbit", "Orbit" }, { "bounce", "Bounce" },
    },
    finish = {
        { "slidetop", "Slide to Top" }, { "slideleft", "Slide to Left" },
        { "slideright", "Slide to Right" }, { "slidebottom", "Slide to Bottom" },
        { "fade", "Fade Out" }, { "shrink", "Shrink" }, { "grow", "Grow" },
        { "spiral", "Spiral" }, { "bounceDecay", "Bounce" }, { "starShakeDecay", "Star Shake" },
    },
}

local pi, sin, cos, abs, floor = math.pi, math.sin, math.cos, math.abs, math.floor

-- WeakAuras' paths (Prototypes.lua anim_function_strings), as functions.
local F = {}
Anim.FUNCTIONS = F
F.straight = function(p, start, delta) return start + p * delta end
F.straightTranslate = function(p, sx, sy, dx, dy) return sx + p * dx, sy + p * dy end
F.straightScale = function(p, sx, sy, tx, ty) return sx + p * (tx - sx), sy + p * (ty - sy) end
F.straightColor = function(p, r1, g1, b1, a1, r2, g2, b2, a2)
    return r1 + p * (r2 - r1), g1 + p * (g2 - g1), b1 + p * (b2 - b1), a1 + p * (a2 - a1)
end
F.straightHSV = F.straightColor
F.circle = function(p, sx, sy, dx, dy)
    local angle = p * 2 * pi
    return sx + dx * cos(angle), sy + dy * sin(angle)
end
F.circle2 = function(p, sx, sy, dx, dy)
    local angle = p * 2 * pi
    return sx + dx * sin(angle), sy + dy * cos(angle)
end
F.spiral = function(p, sx, sy, dx, dy)
    local angle = p * 2 * pi
    return sx + p * dx * cos(angle), sy + p * dy * sin(angle)
end
F.spiralandpulse = function(p, sx, sy, dx, dy)
    local angle = (p + 0.25) * 2 * pi
    return sx + cos(angle) * dx * cos(angle * 2), sy + abs(cos(angle)) * dy * sin(angle * 2)
end
local function BackAndForth(p)
    if p < 0.25 then return p * 4 elseif p < 0.75 then return 2 - p * 4 end
    return (p - 1) * 4
end
F.shake = function(p, sx, sy, dx, dy)
    local prog = BackAndForth(p)
    return sx + prog * dx, sy + prog * dy
end
F.starShakeDecay = function(p, sx, sy, dx, dy)
    local spokes, circles = 10, 4
    local r = math.min(abs(dx), abs(dy))
    if r == 0 then return sx, sy end
    local xs, ys = dx / r, dy / r
    local step = circles * 2 / spokes * pi
    local q = p * spokes
    local i1 = floor(q)
    q = q - i1
    local a1, a2 = i1 * step, (i1 + 1) * step
    local x = q * r * cos(a2) + (1 - q) * r * cos(a1)
    local y = q * r * sin(a2) + (1 - q) * r * sin(a1)
    local ease = sin(p * pi / 2)
    return ease * x * xs, ease * y * ys
end
F.bounceDecay = function(p, sx, sy, dx, dy)
    local prog = (p * 3.5) % 1
    local bounce = math.ceil(p * 3.5)
    local distance = sin(prog * pi) * (bounce / 4)
    return sx + distance * dx, sy + distance * dy
end
F.bounce = function(p, sx, sy, dx, dy)
    local distance = sin(p * pi)
    return sx + distance * dx, sy + distance * dy
end
F.flash = function(p, start, delta)
    local prog = (p < 0.5) and p * 2 or (p - 1) * 2
    return start + prog * delta
end
local function Wave(p) return (sin(p * 2 * pi - pi / 2) + 1) / 2 end
F.pulse = function(p, sx, sy, tx, ty) local w = Wave(p) return sx + w * (tx - 1), sy + w * (ty - 1) end
F.alphaPulse = function(p, start, delta) return start + Wave(p) * delta end
F.pulseColor = function(p, r1, g1, b1, a1, r2, g2, b2, a2)
    return F.straightColor(Wave(p), r1, g1, b1, a1, r2, g2, b2, a2)
end
F.pulseHSV = F.pulseColor
F.fauxspin = function(p, sx, sy, tx, ty) return cos(p * 2 * pi) * tx, sy + p * (ty - sy) end
F.fauxflip = function(p, sx, sy, tx, ty) return sx + p * (tx - sx), cos(p * 2 * pi) * ty end
F.backandforth = function(p, start, delta) return start + BackAndForth(p) * delta end
F.wobble = function(p, start, delta) return start + sin(p * 2 * pi) * delta end
F.hide = function() return 0 end

local DEFAULT_PATH = {
    alpha = "straight", translate = "straightTranslate", scale = "straightScale",
    rotate = "straight", color = "straightColor",
}

Anim.EASE = {
    none = function(p) return p end,
    easeIn = function(p, power) return p ^ power end,
    easeOut = function(p, power) return 1 - (1 - p) ^ power end,
    easeOutIn = function(p, power)
        if p < 0.5 then return (p * 2) ^ power * 0.5 end
        return 1 - ((1 - p) * 2) ^ power * 0.5
    end,
}

-- The settings a slot plays: a preset's, or its own.
function Anim:Resolve(aura, which)
    local anim = ns.Animation(aura, which)
    if not anim then return nil end
    if anim.type == "preset" then
        local preset = Anim.PRESETS[anim.preset or ""]
        if not preset then return nil end
        return preset
    end
    if not (anim.use_alpha or anim.use_translate or anim.use_scale or anim.use_rotate or anim.use_color) then
        return nil
    end
    return anim
end

-- One part's path: WeakAuras' named ones, or the aura's own function.
local function PathFor(aura, def, part)
    local kind = def[part .. "Type"] or DEFAULT_PATH[part]
    if kind == "custom" then
        local source = def[part .. "Func"]
        if aura.untrusted or type(source) ~= "string" or source == "" then return nil end
        local fn, err = ns.Env:Compile(source, tostring(aura.name or aura.id) .. " " .. part .. " animation")
        if not fn then
            ns.Env:Report(aura, part .. " animation", err)
            return nil
        end
        return function(...)
            local ok, a, b, c, d = ns.Env:Call(aura, fn, ...)
            if not ok then
                ns.Env:Report(aura, part .. " animation", a)
                return nil
            end
            return a, b, c, d
        end
    end
    return F[kind] or F[DEFAULT_PATH[part]]
end

-- Frames with an animation running, and the frame that steps them.
local running = {}
Anim.__running = running
local driver

local function Clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- Puts back what an animation changed.
local function Reset(frame)
    local run = frame.anim
    frame.anim = nil
    running[frame] = nil
    local moved = (frame.animX or 0) ~= 0 or (frame.animY or 0) ~= 0
    frame.animX, frame.animY = nil, nil
    if moved then Display.RePin(frame) end
    if frame.animScaleX or frame.animScaleY then
        frame.animScaleX, frame.animScaleY = nil, nil
        Display.Rescale(frame)
    end
    if run and run.rotating and frame.texture then
        pcall(frame.texture.SetRotation, frame.texture, math.rad(frame.baseRotation or 0))
    end
    if run and run.colouring then
        Display.ColourRegion(frame, frame.kind, 1, 1, 1, 1)
        ns.RequestUpdate()
    end
    if frame.baseAlpha then pcall(frame.SetAlpha, frame, frame.baseAlpha) end
end

-- Where a running animation has got to, drawn.
function Anim:Apply(frame)
    local run = frame.anim
    if not run then return end
    local def = run.def
    local p = run.progress
    if run.inverse then p = 1 - p end
    p = (Anim.EASE[def.easeType or "none"] or Anim.EASE.none)(p, tonumber(def.easeStrength) or 3)

    if def.use_alpha and run.alphaPath then
        local base = (run.which == "finish") and (frame.shownAlpha or 1) or (frame.baseAlpha or 1)
        local alpha = run.alphaPath(p, base, (tonumber(def.alpha) or 0) - base)
        if type(alpha) == "number" then pcall(frame.SetAlpha, frame, Clamp(alpha, 0, 1)) end
    end
    if def.use_translate and run.translatePath then
        local x, y = run.translatePath(p, 0, 0, tonumber(def.x) or 0, tonumber(def.y) or 0)
        frame.animX, frame.animY = tonumber(x) or 0, tonumber(y) or 0
        Display.RePin(frame)
    end
    if def.use_scale and run.scalePath then
        local sx, sy = run.scalePath(p, 1, 1, tonumber(def.scalex) or 1, tonumber(def.scaley) or 1)
        frame.animScaleX, frame.animScaleY = tonumber(sx) or 1, tonumber(sy) or 1
        Display.Rescale(frame)
    end
    if def.use_rotate and run.rotatePath and frame.texture then
        local degrees = run.rotatePath(p, 0, tonumber(def.rotate) or 0)
        if type(degrees) == "number" then
            run.rotating = true
            pcall(frame.texture.SetRotation, frame.texture, math.rad((frame.baseRotation or 0) + degrees))
        end
    end
    if def.use_color and run.colorPath then
        local r, g, b, a = run.colorPath(p, 1, 1, 1, 1, tonumber(def.colorR) or 1, tonumber(def.colorG) or 1,
                                         tonumber(def.colorB) or 1, tonumber(def.colorA) or 1)
        if type(r) == "number" then
            run.colouring = true
            Display.ColourRegion(frame, frame.kind, r, g or 1, b or 1, a or 1)
        end
    end
end

local function EnsureDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, elapsed) Anim:Step(tonumber(elapsed) or 0) end)
end

function Anim:Play(frame, aura, which, onDone)
    local def = self:Resolve(aura, which)
    if not def then return false end
    Reset(frame)
    local run = {
        which = which, def = def, progress = 0, aura = aura, onDone = onDone,
        duration = math.max(tonumber(def.duration) or 0.25, 0.01),
        inverse = (which == "start"), loop = (which == "main"),
        relative = def.duration_type == "relative",
    }
    for _, part in ipairs({ "alpha", "translate", "scale", "rotate", "color" }) do
        if def["use_" .. part] then run[part .. "Path"] = PathFor(aura, def, part) end
    end
    frame.anim = run
    running[frame] = true
    EnsureDriver()
    self:Apply(frame)
    return true
end

function Anim:Stop(frame) Reset(frame) end

function Anim:Step(elapsed)
    local done
    for frame in pairs(running) do
        local run = frame.anim
        if not run then
            running[frame] = nil
        else
            if run.relative and run.loop then
                -- Tied to the aura's own timer: one pass every `duration` of it.
                local state = frame.animState
                local fraction = state and ns.Engine:Progress(state)
                if fraction then
                    run.progress = ((1 - fraction) / run.duration) % 1
                else
                    run.progress = (run.progress + elapsed / run.duration) % 1
                end
            else
                run.progress = run.progress + elapsed / run.duration
            end
            if run.progress >= 1 then
                if run.loop then
                    run.progress = run.progress % 1
                else
                    run.progress = 1
                    done = done or {}
                    done[#done + 1] = frame
                end
            end
            self:Apply(frame)
        end
    end
    for _, frame in ipairs(done or {}) do
        local run = frame.anim
        Reset(frame)
        if run and run.onDone then run.onDone(frame) end
    end
end

-- Called by the display after every draw: starts and stops the slots on the
-- aura's edges, and puts a running animation back over what was just drawn.
function Anim:Sync(aura, frame, state, live)
    local was = frame.animLive
    frame.animLive = live
    local run = frame.anim

    if live then
        frame.shownAlpha = frame.baseAlpha
        if was == false then
            -- Coming up: start, then main. Not at login or a reload (nil),
            -- when everything would slide in at once.
            local function Main(f) Anim:Play(f, aura, "main") end
            if not self:Play(frame, aura, "start", Main) then Main(frame) end
        elseif (not run or run.which == "finish") and self:Resolve(aura, "main") then
            if run then Reset(frame) end
            self:Play(frame, aura, "main")
        elseif run and run.which == "main" and not self:Resolve(aura, "main") then
            Reset(frame)
        end
    else
        if run and run.which ~= "finish" then Reset(frame) end
        if was == true then
            -- Going: finish, and a dynamic group closes up when it ends.
            self:Play(frame, aura, "finish", function()
                if ns.Display then ns.Display:Layout() end
            end)
        end
    end
    self:Apply(frame)
end
