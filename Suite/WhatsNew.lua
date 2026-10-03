-- Chaircraft Suite/WhatsNew.lua
-- After an update, a short in-game list of what changed. Shown once per
-- account per version; never on a first run, where the welcome page
-- (Suite/Welcome.lua) comes first. Reopened from the Home page, or
-- /chair whatsnew.
--
-- The client cannot read CHANGELOG.md, so each release adds its entry here:
-- a few short lines, the headline changes only. .tests/chaircraft_test.py
-- fails when the TOC's version has no entry.

local suiteName, Chaircraft = ...

Chaircraft.WHATS_NEW = {
    ["1.8.1"] = {
        title = "ChairIgnore keeps your reasons",
        lines = {
            "ChairIgnore no longer asks why you ignored someone already on the list. The game could send its ignore list a name short, and that name lost its reason and was asked about again.",
        },
    },
    ["1.8.0"] = {
        title = "Settings shared by the account",
        lines = {
            "Settings are now the same on every character on the account, except ChairTracker's bars and factions. Each part starts from your fullest character's setup.",
            "ChairIgnore keeps one list of people for the whole account, and no longer loses names when the game is slow to send its ignore list at login.",
            "The Map & Quest Log window can be dragged by its title bar.",
            "Threat % now shows on nameplates of mobs you have not targeted.",
            "Fewer errors in combat, when the game hides values from addons. Among them, a ChairAuras error when a mob yelled as a fight began.",
        },
    },
    ["1.7.0"] = {
        title = "Threat on the nameplates",
        lines = {
            "Threat % on enemy nameplates (Threat meter, Nameplates page): DPS and healers see their own threat on every mob in the fight; tanks see the highest threat behind them.",
            "Full, colored numbers on mobs someone in your group has targeted; your own % on the rest.",
            "Combo points as pips on your target's nameplate, for rogues and druids in Cat Form.",
            "The spellbook can be dragged by its title bar again.",
            "A /reload in the air no longer resets the flight timer.",
        },
    },
    ["1.6.0"] = {
        title = "A clearer menu",
        lines = {
            "The menu has a list of pages down the left, one topic each: Quests & NPCs, Buying & selling, Groups & people, Chat, Looting & comfort, Travel, Info bar and Threat meter.",
            "Auras, Snack, Tracker and Ignore are under Tools in the same list, and open beside it.",
            "New on the Chat page: put the chat scroll bar and its arrows on the left.",
            "ChairTracker starts switched off on a new install. If you already use it, it stays as it is.",
            "Fixed errors in the game's Options > Advanced list, from the nameplate preview.",
        },
    },
    ["1.5.0"] = {
        title = "Restock and profession cooldowns",
        lines = {
            "Restock: at any merchant, buy back up to a count you set of ammo, reagents, food and water (Plus page, Merchants, Items...).",
            "Profession cooldowns on every character: an OSD item, a ready notice, and /chair cooldowns.",
            "ChairIgnore filters take a * wildcard (<*> is any guild tag), and each can be kept to channels you tick: Say, Yell, Trade and the rest.",
            "Long filter lines wrap and their box grows; the filter editor scrolls to fit.",
            "A Politics starter filter, off until you tick it on the Chat filters tab.",
            "An Ignored chat tab: everything ChairIgnore hides, in its own tab (ChairIgnore Options).",
            "ChairIgnore is now set up once for the whole account: its switches are the same on every character.",
            "This window has a Don't show after updates box, and Quick setup and What's new now take the menu's place while they are up.",
        },
    },
    ["1.4.0"] = {
        title = "Finding things, and ChairIgnore round two",
        lines = {
            "Search box in the menu's title bar: type part of any option's name or tooltip.",
            "Quick setup: the most-used switches on one page (General page, or /chair setup).",
            "This window after each update (General page, or /chair whatsnew).",
            "ChairIgnore filters: {link} for any link, and \"quoted\" words that count only on their own, even spaced out or with look-alike letters.",
            "ChairIgnore's new Hidden tab: what it hid and why, with Show in chat and Unignore.",
            "Share a ChairIgnore filter as a line of text: Export and Import on the Chat filters tab.",
        },
    },
}

local window

local function Build()
    if window then return window end
    local plus = Chaircraft.ChairPlus
    if not (plus and plus.MakeButton) then return nil end

    window = CreateFrame("Frame", "ChaircraftWhatsNew", UIParent, "BackdropTemplate")
    window:SetSize(440, 160)
    window:SetPoint("CENTER", 0, 60)
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
    if UISpecialFrames then tinsert(UISpecialFrames, "ChaircraftWhatsNew") end

    window.title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    window.title:SetPoint("TOP", 0, -14)
    window.subtitle = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    window.subtitle:SetPoint("TOP", window.title, "BOTTOM", 0, -4)

    window.body = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    window.body:SetPoint("TOPLEFT", 20, -62)
    window.body:SetPoint("TOPRIGHT", -20, -62)
    window.body:SetJustifyH("LEFT")
    window.body:SetSpacing(4)

    local close = plus.MakeButton(window, 90, "Close")
    close:SetPoint("BOTTOMRIGHT", -18, 14)
    close:SetScript("OnClick", function() window:Hide() end)
    window.close = close
    local menu = plus.MakeButton(window, 130, "Open the menu")
    menu:SetPoint("RIGHT", close, "LEFT", -8, 0)
    menu:SetScript("OnClick", function()
        window.menuPage = "plus"
        window:Hide()
    end)

    -- For those who would rather not see it: it stays on the Home page
    -- and /chair whatsnew either way.
    local never = plus.MakeCheckButton(window)
    never:SetSize(22, 22)
    never:SetPoint("BOTTOMLEFT", 14, 14)
    local neverLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    neverLabel:SetPoint("LEFT", never, "RIGHT", 2, 0)
    neverLabel:SetText("Don't show after updates")
    never:SetScript("OnClick", function(self) Chaircraft.SetWhatsNewOff(self:GetChecked() and true or false) end)
    window.never = never
    return window
end

-- Opens the list for a version (this one by default). False when there is
-- no entry for it.
function Chaircraft.ShowWhatsNew(version)
    version = version or Chaircraft.version
    local entry = Chaircraft.WHATS_NEW[version]
    if not entry then return false end
    local frame = Build()
    if not frame then return false end
    frame.title:SetText("What's new in ChairCraft v" .. version)
    frame.subtitle:SetText(entry.title or "")
    local lines = {}
    for _, line in ipairs(entry.lines or {}) do lines[#lines + 1] = "- " .. line end
    frame.body:SetText(table.concat(lines, "\n"))
    local ok, height = pcall(frame.body.GetStringHeight, frame.body)
    height = (ok and tonumber(height)) or (#lines * 18)
    frame:SetHeight(math.max(160, 62 + height + 56))
    frame.never:SetChecked(Chaircraft.WhatsNewOff())
    if not frame:IsShown() then
        Chaircraft.StandInForMenu(frame)
        frame:Show()
    end
    return true
end

-- Whether What's new stays shut after updates. Account-wide, like the
-- version it remembers.
function Chaircraft.WhatsNewOff()
    local db = _G.ChairPlusDB
    return type(db) == "table" and db.whatsNewOff == true
end

function Chaircraft.SetWhatsNewOff(off)
    local db = _G.ChairPlusDB
    if type(db) == "table" then db.whatsNewOff = off and true or nil end
end

-- Once per account per version. A first run (the welcome page just opened)
-- only records the version.
function Chaircraft.MaybeWhatsNew(firstRun)
    local db = _G.ChairPlusDB
    local version = Chaircraft.version
    if type(db) ~= "table" or not version or db.lastSeenVersion == version then return false end
    db.lastSeenVersion = version
    if firstRun or db.whatsNewOff then return false end
    return Chaircraft.ShowWhatsNew(version)
end

-- At login, once everything has loaded and settled: the welcome page for
-- someone new, What's new for someone updated, nothing otherwise.
local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", function()
    local function Decide()
        local okW, welcomed = pcall(Chaircraft.MaybeWelcome)
        pcall(Chaircraft.MaybeWhatsNew, okW and welcomed or false)
    end
    if C_Timer and C_Timer.After then C_Timer.After(4, Decide) else Decide() end
end)
