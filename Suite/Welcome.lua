-- Chaircraft Suite/Welcome.lua
-- The first time Chaircraft ever loads on an account: one page of the most
-- used switches, so a new player can see what is here without hunting
-- through the menu. Everything ships off, and a suite that does nothing out
-- of the box otherwise looks broken.
--
-- Shown once per account, and only to someone new: an account that already
-- has settings saved on any character is an update, not a first run, and
-- gets What's new (Suite/WhatsNew.lua) instead. Reopened from the menu's
-- Home page, or /chair setup.
--
-- The labels and tips are the menu's own rows (ChairPlus's ROWS), so a
-- switch here always reads the same as in the menu.

local suiteName, Chaircraft = ...

-- The switches on the page, in order. `key` is a ChairPlus setting; `part`
-- is another part's master switch, with its own label.
local QUICK = {
    { key = "osd" },
    { key = "quests" },
    { key = "autoGossip" },
    { key = "sellJunk" },
    { key = "repairGear" },
    { key = "fasterLoot" },
    { key = "flight" },
    { key = "arrow" },
    { key = "maxCameraZoom" },
    { key = "declineDuels" },
    { key = "lfgFilters" },
    { key = "tooltipExtras" },
    { part = "ChairIgnore", label = "ChairIgnore: one ignore list for every character",
      tip = "Anyone you ignore is kept on every character, past the game's 50, and their chat is hidden. "
         .. "Chat filters are on its page." },
}
Chaircraft.QUICK_SETUP = QUICK

local function Plus() return Chaircraft.ChairPlus end

-- A window opened from the menu takes the menu's place while it is up, so
-- the two never sit on top of each other: the menu hides, and comes back on
-- the page it was on when the window closes. Opened with the menu closed
-- (at login, or by command), it leaves the menu alone.
function Chaircraft.StandInForMenu(frame)
    local plus = Plus()
    local menu = _G.ChairPlusPanel
    frame.menuPage = nil
    if menu and menu:IsShown() then
        frame.menuPage = (plus and plus.CurrentPage and plus.CurrentPage()) or "plus"
        menu:Hide()
    end
    if not frame.standInHooked then
        frame.standInHooked = true
        frame:HookScript("OnHide", function(self)
            local page = self.menuPage
            self.menuPage = nil
            local p = Plus()
            if page and p and p.OpenPanel then pcall(p.OpenPanel, page) end
        end)
    end
end

local function RowFor(key)
    local plus = Plus()
    for _, row in ipairs(plus and plus.ROWS or {}) do
        if row.key == key then return row end
    end
    return nil
end

-- A switch's label, tip, and how to read and write it.
local function Describe(entry)
    if entry.part == "ChairIgnore" then
        local ci = Chaircraft.ChairIgnore
        if not (ci and ci.Get) then return nil end
        return {
            label = entry.label, tip = entry.tip,
            get = function() return ci.Get("enabled") == true end,
            set = function(value) ci.Set("enabled", value) end,
        }
    end
    local plus, row = Plus(), RowFor(entry.key)
    if not (plus and plus.Get and row) then return nil end
    return {
        label = row.label,
        tip = plus.RowTip and plus.RowTip(row) or row.tip,
        get = function() return plus.Get(entry.key) == true end,
        set = function(value) plus.Set(entry.key, value) end,
    }
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local window

local function Build()
    if window then return window end
    local plus = Plus()
    if not (plus and plus.MakeButton and plus.MakeCheckButton) then return nil end

    window = CreateFrame("Frame", "ChaircraftWelcome", UIParent, "BackdropTemplate")
    window:SetSize(420, 150 + #QUICK * 24)
    window:SetPoint("CENTER", 0, 40)
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
    if UISpecialFrames then tinsert(UISpecialFrames, "ChaircraftWelcome") end

    local title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Welcome to ChairCraft")

    local intro = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    intro:SetPoint("TOPLEFT", 18, -42)
    intro:SetPoint("TOPRIGHT", -18, -42)
    intro:SetJustifyH("LEFT")
    intro:SetText("Everything starts switched off. Tick what you want now; the rest is in "
        .. "|cffffd100/chair|r. You can change any of these later.")

    window.checks = {}
    local y = -84
    for _, entry in ipairs(QUICK) do
        local info = Describe(entry)
        if info then
            local check = plus.MakeCheckButton(window)
            check:SetSize(22, 22)
            check:SetPoint("TOPLEFT", 18, y)
            local label = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            label:SetPoint("LEFT", check, "RIGHT", 4, 0)
            label:SetText(info.label)
            check:SetScript("OnClick", function(self)
                pcall(info.set, self:GetChecked() and true or false)
            end)
            if info.tip then
                check:HookScript("OnEnter", function(self)
                    local tip = _G.GameTooltip
                    if not tip then return end
                    tip:SetOwner(self, "ANCHOR_RIGHT")
                    tip:AddLine(info.label, 1, 0.82, 0)
                    tip:AddLine(info.tip, 1, 1, 1, true)
                    tip:Show()
                end)
                check:HookScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
            end
            window.checks[#window.checks + 1] = { check = check, info = info }
            y = y - 24
        end
    end

    local done = plus.MakeButton(window, 110, "Done")
    done:SetPoint("BOTTOMRIGHT", -18, 14)
    done:SetScript("OnClick", function() window:Hide() end)
    window.done = done

    local menu = plus.MakeButton(window, 150, "Open the full menu")
    menu:SetPoint("RIGHT", done, "LEFT", -8, 0)
    menu:SetScript("OnClick", function()
        -- Back to the menu, on its first page, whether or not it was open.
        window.menuPage = "plus"
        window:Hide()
    end)
    window.menu = menu

    window:SetScript("OnShow", function()
        for _, c in ipairs(window.checks) do
            local ok, on = pcall(c.info.get)
            c.check:SetChecked(ok and on and true or false)
        end
    end)
    return window
end

function Chaircraft.ShowWelcome()
    local frame = Build()
    if not frame then return false end
    if frame:IsShown() then return true end
    Chaircraft.StandInForMenu(frame)
    frame:Show()
    return true
end

-------------------------------------------------------------------------------
-- Whether this is a first run
-------------------------------------------------------------------------------

-- True when no character on this account has any ChairPlus setting saved:
-- nothing has ever been changed, so this is someone new.
local function NothingSavedAnywhere()
    local db = _G.ChairPlusDB
    if type(db) ~= "table" or type(db.profiles) ~= "table" then return true end
    for _, profile in pairs(db.profiles) do
        if type(profile) == "table" and type(profile.settings) == "table" and next(profile.settings) then
            return false
        end
    end
    return true
end

-- Decides once per account. Returns true when it opened the window, so
-- What's new knows to stay quiet on a first run.
function Chaircraft.MaybeWelcome()
    local db = _G.ChairPlusDB
    if type(db) ~= "table" or db.welcomed then return false end
    db.welcomed = true
    if not NothingSavedAnywhere() then return false end
    return Chaircraft.ShowWelcome() and true or false
end
