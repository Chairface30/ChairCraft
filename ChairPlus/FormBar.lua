-- ChairPlus FormBar.lua
-- A druid's alternate resource bar only in Bear and Cat Form.
--
-- Edit Mode's Personal Resource Display has a checkbox for the alternate
-- resource bar (a druid's mana while shifted), on or off for good. With this
-- option the checkbox stays on and the bar is see-through outside Bear and
-- Cat Form. Edit Mode's settings are not changed from here: that is
-- Blizzard's code run from ours, and forms change in combat, when it would be
-- refused.
--
-- See-through rather than hidden, for the reason StatusBars.lua gives: alpha
-- is the widget's own switch, and nothing of Blizzard's runs. Blizzard puts
-- the alpha back when it shows or fades the bar, so that is undone after its
-- own call while the bar should be hidden.
--
-- The form is told by power type: rage is Bear Form, energy Cat Form. Form
-- numbers differ between clients; the power types do not.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local RAGE, ENERGY = 1, 3   -- Enum.PowerType, where the enum is missing

-- Where the bar may hang off the resource display, first match wins. The
-- display's other fields are searched after these for anything named like an
-- alternate power or mana bar (/chair plus formbar says what was found).
local DISPLAY = "PersonalResourceDisplayFrame"
local KEYS = { "AlternatePowerBar", "AlternateManaBar", "AlternatePowerBarContainer", "AltPowerBar" }

local enabled = false
local hiding = false       -- the bar is see-through right now
local concealing = false   -- our own SetAlpha(0), not to be taken for the client's
local hooked = {}
local driver
local found, foundAs       -- the bar, and the name it was found by

local function IsBar(value)
    if type(value) ~= "table" then return false end
    local ok, setAlpha = pcall(function() return value.SetAlpha end)
    return ok and setAlpha ~= nil
end

local function Find()
    if found then return found, foundAs end
    local display = _G[DISPLAY]
    if type(display) ~= "table" then return nil end
    for _, key in ipairs(KEYS) do
        -- Child frames are plain fields on the frame; methods are not
        local ok, value = pcall(rawget, display, key)
        if ok and IsBar(value) then
            found, foundAs = value, DISPLAY .. "." .. key
            return found, foundAs
        end
    end
    -- Any field named like "Alt...Power" or "Alt...Mana", on the display or
    -- one level down (a container holding the bars).
    local function Scan(frame, path, depth)
        for key, value in pairs(frame) do
            if type(key) == "string" and IsBar(value) then
                local lower = key:lower()
                if lower:find("^alt") and (lower:find("power") or lower:find("mana")) then
                    return value, path .. "." .. key
                end
            end
        end
        if depth > 0 then
            for key, value in pairs(frame) do
                if type(key) == "string" and IsBar(value) and value ~= frame then
                    local bar, name = Scan(value, path .. "." .. key, depth - 1)
                    if bar then return bar, name end
                end
            end
        end
    end
    local ok, bar, name = pcall(Scan, display, DISPLAY, 1)
    if ok and bar then found, foundAs = bar, name end
    return found, foundAs
end

-- True in Bear or Cat Form, false out of them, nil when the client won't say.
local function InForm()
    local enum = _G.Enum and _G.Enum.PowerType
    local rage = (enum and ns.Num(enum.Rage)) or RAGE
    local energy = (enum and ns.Num(enum.Energy)) or ENERGY
    local ok, powerType = pcall(_G.UnitPowerType, "player")
    powerType = ok and ns.Num(powerType) or nil
    if powerType == nil then return nil end
    return powerType == rage or powerType == energy
end
ns.FormBarInForm = InForm

local function IsDruid()
    local ok, _, class = pcall(_G.UnitClass, "player")
    return ok and ns.Text(class) == "DRUID"
end

local function Conceal(bar)
    concealing = true
    pcall(bar.SetAlpha, bar, 0)
    concealing = false
end

local function Watch(bar)
    if hooked[bar] then return end
    hooked[bar] = true
    if bar.HookScript then
        pcall(bar.HookScript, bar, "OnShow", function(self)
            if hiding then Conceal(self) end
        end)
    end
    if type(hooksecurefunc) == "function" then
        pcall(hooksecurefunc, bar, "SetAlpha", function(self, alpha)
            if hiding and not concealing and (ns.Num(alpha) or 1) > 0 then Conceal(self) end
        end)
    end
end

-- Hide or show the bar for the form the player is in now.
local function Update()
    if not enabled and not hiding then return end
    local bar = Find()
    if not bar then return end
    local want = enabled and IsDruid()
    if want then
        local inForm = InForm()
        if inForm == nil then return end   -- unknown: leave it as it is
        want = not inForm
    end
    if want then
        Watch(bar)
        hiding = true
        Conceal(bar)
    elseif hiding then
        hiding = false
        pcall(bar.SetAlpha, bar, 1)
    end
end
ns.FormBarUpdate = Update

local function Apply(on)
    enabled = on and true or false
    if enabled and not driver then
        driver = CreateFrame("Frame")
        for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "UPDATE_SHAPESHIFT_FORM",
                                 "EDIT_MODE_LAYOUTS_UPDATED" }) do
            pcall(driver.RegisterEvent, driver, event)
        end
        pcall(driver.RegisterUnitEvent, driver, "UNIT_DISPLAYPOWER", "player")
        driver:SetScript("OnEvent", Update)
    end
    Update()
    -- The display may be built after login; look again once it has settled.
    if enabled and not found then
        ns.After(2, Update)
    end
end

-- /chair plus formbar: what was found and what the form reads as.
function ns.ProbeFormBar()
    local bar, name = Find()
    ns.Print("Alternate resource bar: " .. (name or ("not found on " .. DISPLAY)))
    if not bar and type(_G[DISPLAY]) == "table" then
        local keys = {}
        pcall(function()
            for key, value in pairs(_G[DISPLAY]) do
                if type(key) == "string" and IsBar(value) then keys[#keys + 1] = key end
            end
        end)
        table.sort(keys)
        ns.Print("  frames on the display: " .. (#keys > 0 and table.concat(keys, ", ") or "none"))
    end
    local inForm = InForm()
    ns.Print("  form: " .. (inForm == nil and "the client won't say"
        or inForm and "Bear or Cat Form" or "not Bear or Cat Form")
        .. ", option " .. (enabled and "on" or "off")
        .. (not IsDruid() and " (not a druid: nothing is hidden)" or "")
        .. ", bar " .. (hiding and "hidden" or "shown"))
end

ns.RegisterModule("formAltBar", {
    title = "Alternate resource bar only in forms",
    desc = "A druid's alternate resource bar on the Personal Resource Display shows only in Bear and Cat Form.",
    Apply = Apply,
})
