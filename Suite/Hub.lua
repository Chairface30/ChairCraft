-- Chaircraft Suite/Hub.lua
-- One command for the whole suite.
--
-- There is no launcher window any more. The menu is the ChairPlus options
-- panel, which grew a nav row reaching the other three parts; this file is what
-- makes "/chair" the only way in.
--
-- It must load last. Every part registers its own slash command as its files
-- load, and the whole design here is to capture those handlers and then take
-- the commands away -- which only works if they already exist.

local suiteName, Chaircraft = ...

local function Print(...)
    local parts = { "|cff9d7cffChairCraft|r:" }
    for i = 1, select("#", ...) do
        -- Pulled into a local first. A nested function cannot see the enclosing
        -- one's "...", and reaching for it there is a compile error, not a
        -- runtime one -- it would take this whole file down at load.
        local value = (select(i, ...))
        local ok, text = pcall(function() return "" .. tostring(value) end)
        parts[#parts + 1] = ok and text or "<unreadable>"
    end
    local ok, line = pcall(table.concat, parts, " ")
    print(ok and line or "|cff9d7cffChairCraft|r: <unprintable message>")
end

Chaircraft.Print = Print

-------------------------------------------------------------------------------
-- Take over the slash commands
-------------------------------------------------------------------------------
-- Capture first, then clear. The captured reference is the only one left, so
-- the router can still reach every part's command handling without any of the
-- four addons being edited to give it up.
--
-- Clearing means nil-ing both halves: the SlashCmdList entry the client looks
-- the handler up in, and the SLASH_<KEY><n> globals that map typed text to that
-- key. SnapSnack registers three of those, the rest two, so the loop runs until
-- it finds a gap rather than assuming a count.

local function CaptureAndRemove(part)
    part.Handler = SlashCmdList and SlashCmdList[part.cmdKey] or nil

    if SlashCmdList then SlashCmdList[part.cmdKey] = nil end
    local i = 1
    while true do
        local global = "SLASH_" .. part.cmdKey .. i
        if _G[global] == nil then break end
        _G[global] = nil
        i = i + 1
        if i > 12 then break end
    end
end

for _, part in ipairs(Chaircraft.parts) do
    CaptureAndRemove(part)
end

-- Same fallback reasoning as elsewhere in this suite: which option templates
-- exist has changed across the clients in the TOC, and asking for a missing
-- one is a hard error at load rather than a nil to check.
local function MakeButton(parent, width, height)
    local button
    local ok = pcall(function()
        button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    end)
    if not (ok and button) then
        button = CreateFrame("Button", nil, parent)
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.18, 0.15, 0.26, 1)
    end
    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.10)
    button:SetSize(width, height)

    -- The template supplies its own font string, but not under a name that has
    -- been stable across these clients, so the label is always ours.
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    button.labelText = label

    return button
end

-------------------------------------------------------------------------------
-- The text box
-------------------------------------------------------------------------------
-- Text to copy out, or paste in. The flight-times panel uses it.

local textBox

local function BuildTextBox()
    if textBox then return textBox end

    textBox = CreateFrame("Frame", "ChaircraftTextBox", UIParent)
    textBox:SetFrameStrata("FULLSCREEN_DIALOG")
    textBox:SetPoint("CENTER")
    textBox:SetSize(520, 300)
    textBox:SetMovable(true)
    textBox:EnableMouse(true)
    textBox:RegisterForDrag("LeftButton")
    textBox:SetScript("OnDragStart", textBox.StartMoving)
    textBox:SetScript("OnDragStop", textBox.StopMovingOrSizing)

    local bg = textBox:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.96)

    local title = textBox:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    textBox.title = title

    local hint = textBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -38)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    textBox.hint = hint

    local scroll = CreateFrame("ScrollFrame", "ChaircraftTextBoxScroll", textBox)
    scroll:SetPoint("TOPLEFT", 16, -60)
    scroll:SetPoint("BOTTOMRIGHT", -16, 46)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetWidth(480)
    edit:SetScript("OnEscapePressed", function() textBox:Hide() end)
    scroll:SetScrollChild(edit)
    textBox.edit = edit

    local close = MakeButton(textBox, 100, 22)
    close:SetPoint("BOTTOMRIGHT", -16, 14)
    close.labelText:SetText("Close")
    close:SetScript("OnClick", function() textBox:Hide() end)

    local accept = MakeButton(textBox, 100, 22)
    accept:SetPoint("BOTTOMRIGHT", close, "BOTTOMLEFT", -8, 0)
    accept.labelText:SetText("Import")
    textBox.accept = accept

    textBox:Hide()
    return textBox
end

-- onAccept nil means "here is some text to copy"; a function means "paste
-- something in and press the button".
function Chaircraft.ShowTextBox(title, text, onAccept, hint, acceptLabel)
    BuildTextBox()
    textBox.title:SetText("ChairCraft " .. tostring(title))
    textBox.edit:SetText(text or "")

    if onAccept then
        textBox.hint:SetText(hint
            or "Paste the text here, then press Import.")
        textBox.accept.labelText:SetText(acceptLabel or "Import")
        textBox.accept:Show()
        textBox.accept:SetScript("OnClick", function()
            local typed = textBox.edit:GetText()
            textBox:Hide()
            onAccept(typed)
        end)
    else
        textBox.hint:SetText(hint
            or "Press ctrl-A then ctrl-C to copy this.")
        textBox.accept:Hide()
        textBox.edit:HighlightText()
        textBox.edit:SetFocus()
    end

    textBox:Show()
end

-------------------------------------------------------------------------------
-- Reporting
-------------------------------------------------------------------------------

-- Each part already records when its saved data turned up. Surfacing those
-- answers "did this come up at login, or only when I opened something?" --
-- which is otherwise invisible, because a part that quietly waited looks
-- exactly like a part that is switched off.
local function Witness(part)
    if part.key == "chairauras" then
        local ns = Chaircraft.ChairAuras
        local w = ns and ns.loadWitness
        if not w then return nil end
        return string.format("arrival=%s atLogin=%s seeded=%s newProfile=%s",
            tostring(w.arrival), tostring(w.atPlayerLogin),
            tostring(w.seeded), tostring(w.profileWasNew))
    elseif part.key == "chairsnack" then
        local addon = Chaircraft.ChairSnack
        if not addon then return nil end
        local saved = _G.SnapSnackDB
        return string.format("atAddonLoaded=%s bootstrapped=%s profiles=%s",
            tostring(addon.dbAtAddonLoaded),
            tostring(addon.ready ~= nil and addon.ready or "?"),
            tostring(saved and saved.profiles ~= nil))
    elseif part.key == "chairplus" then
        local ns = Chaircraft.ChairPlus
        if not ns then return nil end
        local line = string.format("settings=%s",
            tostring(ns.settings ~= nil))
        -- The flight timer depends on calls this client may not have, and it
        -- has already gone quiet once because of that.
        if ns.FlightStatus then
            local okF, f = pcall(ns.FlightStatus)
            if okF and f then
                line = line .. string.char(10) .. string.format(
                    "      flight: taxi=%s nodes=%s tooltip=%s routes=%s hardcoded=%s speed=%.2fx"
                        .. " frequentFlyer=%s (%.2fx time)",
                    tostring(f.taxiProbe or "NONE"), tostring(f.nodes),
                    tostring(f.tooltip), tostring(f.routes), tostring(f.hardcoded),
                    f.speed or 1, f.frequentFlyer == nil and "unknown" or tostring(f.frequentFlyer),
                    f.perkTime or 0.8)
            end
        end
        return line
    end
    return nil
end

function Chaircraft.Report()
    Print("ChairCraft v" .. (Chaircraft.version or "?") .. " -- parts:")
    for _, part in ipairs(Chaircraft.parts) do
        local ok, present = pcall(part.Present)
        local loaded = (ok and present)
        print("  " .. part.title
            .. ": " .. (loaded and "|cff55ff55loaded|r" or "|cffff5555missing|r")
            .. "   " .. part.route
            .. (part.Handler and "" or "  |cff808080(no commands)|r"))
        local okW, note = pcall(Witness, part)
        if okW and note then print("      |cff808080" .. note .. "|r") end
    end
end

local function Help()
    Print("everything lives under |cffffd100/chair|r:")
    print("  |cffffd100/chair|r - the menu")
    print("  |cffffd100/chair osd|r - the on-screen display page")
    for _, part in ipairs(Chaircraft.parts) do
        local aliases = table.concat(part.tokens, ", ")
        print("  |cffffd100" .. part.route .. "|r - " .. part.title
            .. "  |cff808080(" .. aliases .. ")|r")
    end
    print("  |cffffd100/chair <part> <command>|r - passed straight through, e.g. "
        .. "|cffffd100/chair snack scan|r")
    print("  |cffffd100/chair arrow|r - the waypoint arrow's options (|cffffd100on|r, "
        .. "|cffffd100off|r, |cffffd100lock|r, |cffffd100unlock|r, |cffffd100reset|r, "
        .. "|cffffd100probe|r)")
    print("  |cffffd100/chair threat|r - the threat meter's options (|cffffd100on|r, "
        .. "|cffffd100off|r, |cffffd100lock|r, |cffffd100unlock|r, |cffffd100reset|r, "
        .. "|cffffd100preview|r)")
    print("  |cffffd100/chair cooldowns|r - profession cooldowns on every character (|cffffd100probe|r to check spell IDs)")
    print("  |cffffd100/chair setup|r - the welcome page's quick setup")
    print("  |cffffd100/chair whatsnew|r - what changed in this version")
    print("  |cffffd100/chair status|r - which parts loaded")
end

-------------------------------------------------------------------------------
-- The router
-------------------------------------------------------------------------------

local function Forward(part, args)
    if not part.Handler then
        Print("|cffff5555" .. part.title .. " has no commands loaded.|r")
        return
    end
    local ok, err = pcall(part.Handler, args)
    if not ok then
        Print("|cffff5555" .. part.title .. " errored:|r", err)
    end
end

-- Opening a part's settings goes through part.Open rather than forwarding an
-- empty string. Three of the four already open settings on empty input, but
-- ChairTracker's bare command toggles its bar window instead -- so forwarding
-- would make the menu's own nav buttons and the slash command disagree about
-- what "/chair tracker" means.
local function OpenPart(part)
    local ok, opened = pcall(part.Open)
    if not ok or not opened then
        Print("|cffff5555" .. part.title .. " did not answer.|r "
            .. "It may have failed to load -- try |cffffd100/chair status|r.")
    end
end

local function Handler(input)
    input = tostring(input or "")
    local token, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    token = (token or ""):lower()
    rest = rest or ""

    if token == "" then
        local ns = Chaircraft.ChairPlus
        if ns and ns.TogglePanel then
            ns.TogglePanel("plus")
        else
            Print("|cffff5555The menu did not load.|r Try |cffffd100/chair status|r.")
        end
        return
    end

    if token == "help" or token == "?" then return Help() end
    if token == "status" or token == "report" then return Chaircraft.Report() end

    -- The display is a page of the menu rather than a part of its own, but it
    -- still forwards: "/chair osd unlock" has to reach the same handling that
    -- used to sit behind the old command's "osd" subcommand.
    if token == "osd" then
        local ns = Chaircraft.ChairPlus
        if rest ~= "" then
            local plus = Chaircraft.FindPart("plus")
            if plus then Forward(plus, "osd " .. rest) end
        elseif ns and ns.TogglePanel then
            ns.TogglePanel("osd")
        else
            Print("|cffff5555The menu did not load.|r")
        end
        return
    end

    -- The welcome page and What's new, reopened by hand.
    if token == "setup" or token == "welcome" then
        if not (Chaircraft.ShowWelcome and Chaircraft.ShowWelcome()) then
            Print("|cffff5555The welcome page could not open.|r Try |cffffd100/chair status|r.")
        end
        return
    end
    if token == "whatsnew" or token == "news" then
        if not (Chaircraft.ShowWhatsNew and Chaircraft.ShowWhatsNew()) then
            Print("Nothing listed for ChairCraft v" .. tostring(Chaircraft.version) .. ".")
        end
        return
    end

    -- The arrow and the threat meter belong to ChairPlus but are reached from
    -- the top level, the same as the display.
    if token == "arrow" or token == "threat" or token == "cooldowns" then
        local plus = Chaircraft.FindPart("plus")
        if plus then Forward(plus, token .. (rest ~= "" and (" " .. rest) or "")) end
        return
    end

    local part = Chaircraft.FindPart(token)
    if not part then
        Print("|cffff5555No part called|r |cffffd100" .. token .. "|r.")
        Help()
        return
    end

    if rest == "" then
        OpenPart(part)
    else
        Forward(part, rest)
    end
end

SLASH_CHAIRCRAFT1 = "/chair"
SLASH_CHAIRCRAFT2 = "/chaircraft"
SlashCmdList["CHAIRCRAFT"] = Handler

-------------------------------------------------------------------------------
-- The game's options page
-------------------------------------------------------------------------------
-- One entry under Options > AddOns for the whole suite, opening the /chair
-- menu. ChairSnack and ChairTracker each used to register a page of their own;
-- both are gone, so the four parts are reached the same way from everywhere.
-- The icon is the minimap button's.

local ICON = "Interface\\AddOns\\Chaircraft\\ChairSnack\\minimap"

-- Settings.ClosePanel is the public way out of the options window. Its frames
-- are not hidden directly: making a Blizzard frame run its own code from ours
-- taints it (see ChairTracker's skills window, 2026-09-26).
local function OpenMenu()
    if _G.Settings and type(_G.Settings.ClosePanel) == "function" then
        pcall(_G.Settings.ClosePanel)
    end
    local ns = Chaircraft.ChairPlus
    if ns and ns.TogglePanel then
        ns.TogglePanel("plus")
    else
        Print("|cffff5555The menu did not load.|r Try |cffffd100/chair status|r.")
    end
end

local function BuildOptionsPage()
    local panel = CreateFrame("Frame", "ChaircraftOptionsPage")
    panel.name = "|T" .. ICON .. ":16:16|t ChairCraft"

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", 16, -16)
    icon:SetTexture(ICON)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("ChairCraft v" .. tostring(Chaircraft.version or "?"))

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -12)
    desc:SetWidth(500)
    desc:SetJustifyH("LEFT")
    desc:SetText("ChairPlus, ChairAuras, ChairSnack and ChairTracker live in one menu."
        .. " Open it here or type |cffffd100/chair|r.")

    local open = MakeButton(panel, 180, 28)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    open.labelText:SetText("Open ChairCraft menu")
    open:SetScript("OnClick", OpenMenu)

    local settings = _G.Settings
    if settings and type(settings.RegisterCanvasLayoutCategory) == "function" then
        local category = settings.RegisterCanvasLayoutCategory(panel, panel.name)
        settings.RegisterAddOnCategory(category)
        Chaircraft.settingsCategory = category
    elseif type(_G.InterfaceOptions_AddCategory) == "function" then
        _G.InterfaceOptions_AddCategory(panel)
    end
end

do
    local ok, err = pcall(BuildOptionsPage)
    if not ok then Print("|cffff5555The options page could not be built:|r", err) end
end

-- The menu as a LibDataBroker launcher, for any bar addon that shows them.
-- The OSD leaves this one out of its own list: it is already the way in.
do
    local stub = _G.LibStub
    local ok, ldb = pcall(function() return stub and stub:GetLibrary("LibDataBroker-1.1", true) end)
    if ok and ldb and not ldb:GetDataObjectByName("Chaircraft") then
        pcall(ldb.NewDataObject, ldb, "Chaircraft", {
            type = "launcher",
            label = "ChairCraft",
            icon = ICON,
            OnClick = function() OpenMenu() end,
            OnTooltipShow = function(tip)
                tip:AddLine("ChairCraft v" .. tostring(Chaircraft.version or "?"))
                tip:AddLine("Click to open the menu.", 1, 1, 1)
            end,
        })
    end
end

-------------------------------------------------------------------------------
-- Duplicate load warning
-------------------------------------------------------------------------------
-- Running a standalone alongside the suite loads everything twice: two event
-- frames, two handlers, two of every automatic action. That has already cost
-- one debugging session -- auto-repair billing and reporting twice looked for
-- all the world like an addon bug.

local warn = CreateFrame("Frame")
warn:RegisterEvent("PLAYER_LOGIN")
warn:SetScript("OnEvent", function()
    local isLoaded = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(isLoaded) ~= "function" then return end
    local clashes = {}
    for _, name in ipairs({ "ChairPlus", "ChairAuras", "SnapSnack", "WOWFTracker" }) do
        local ok, loaded = pcall(isLoaded, name)
        if ok and loaded then clashes[#clashes + 1] = name end
    end
    if #clashes > 0 then
        Print("|cffff5555" .. table.concat(clashes, ", ")
            .. " is also enabled.|r Everything in it is now running twice. "
            .. "Untick it in the addon list.")
    end
end)
