-- ChairPlus Backup.lua
-- Every Chaircraft setting of this character as one line of text, and back.
--
--   export   this character's ChairPlus settings and window spots, ChairSnack
--            bars and ChairTracker bars and factions -- and, if asked, the
--            account's auras -- serialized and compressed the way ChairAuras
--            shares an aura (LibSerialize, LibDeflate), as "!CC:1!..."
--   import   read one back onto this character. It goes in through the same
--            path as "copy settings from another character", so it lands the
--            same way; auras, if the string carries them, replace the
--            account's only when the box for it is ticked. A /reload finishes
--            the job for the parts that read their settings at login.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local PREFIX = "!CC:1!"
local IMPORT_KEY = "import:backup"

local function Lib(name)
    local stub = _G.LibStub
    if not stub then return nil end
    local ok, lib = pcall(stub.GetLibrary, stub, name, true)
    return ok and lib or nil
end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = DeepCopy(v) end
    return out
end

-- What this character has, part by part.
local function Collect(withAuras)
    local out = { v = 1 }
    local profile = ns.Profile()
    out.who = profile.label
    out.plus = { settings = DeepCopy(profile.settings), movers = DeepCopy(profile.movers) }

    local snack = Chaircraft.ChairSnack
    local snackDB = _G.SnapSnackDB
    if snack and type(snack.CharKey) == "function" and type(snackDB) == "table" and type(snackDB.profiles) == "table" then
        local ok, key = pcall(snack.CharKey, snack)
        if ok and snackDB.profiles[key] then out.snack = DeepCopy(snackDB.profiles[key]) end
    end

    local tracker = _G.WOWFTrackerAccountDB
    if type(tracker) == "table" and type(tracker.profiles) == "table" and ns.profileKey then
        out.tracker = DeepCopy(tracker.profiles[ns.profileKey])
    end

    local auras = _G.ChairAurasDB
    if withAuras and type(auras) == "table" and type(auras.profiles) == "table" then
        out.auras = DeepCopy(auras.profiles.account)
    end
    return out
end

function ns.ExportSettings(withAuras)
    local serialize, deflate = Lib("LibSerialize"), Lib("LibDeflate")
    if not (serialize and deflate) then return nil, "this copy is missing LibSerialize or LibDeflate" end
    local ok, text = pcall(function()
        local packed = serialize:SerializeEx({ errorOnUnserializableType = false }, Collect(withAuras))
        return PREFIX .. deflate:EncodeForPrint(deflate:CompressDeflate(packed, { level = 9 }))
    end)
    if not ok then return nil, "could not be written: " .. tostring(text) end
    return text
end

-- What a string holds, without applying any of it.
function ns.PeekSettings(text)
    text = tostring(text or ""):gsub("%s", "")
    if text:sub(1, #PREFIX) ~= PREFIX then return nil, "that is not a Chaircraft settings string" end
    local serialize, deflate = Lib("LibSerialize"), Lib("LibDeflate")
    if not (serialize and deflate) then return nil, "this copy is missing LibSerialize or LibDeflate" end
    local decoded = deflate:DecodeForPrint(text:sub(#PREFIX + 1))
    local raw = decoded and deflate:DecompressDeflate(decoded)
    if not raw then return nil, "the string is damaged" end
    local ok, data = serialize:Deserialize(raw)
    if not ok or type(data) ~= "table" or type(data.plus) ~= "table" then return nil, "the string is damaged" end
    local parts = { "Plus" }
    if type(data.snack) == "table" then parts[#parts + 1] = "Snack" end
    if type(data.tracker) == "table" then parts[#parts + 1] = "Tracker" end
    if type(data.auras) == "table" then parts[#parts + 1] = "Auras" end
    data.parts = parts
    return data
end

-- Applies a string to this character. Returns the parts written.
function ns.ImportSettings(text, withAuras)
    local data, err = ns.PeekSettings(text)
    if not data then return nil, err end

    -- In through the copy path: a temporary profile in each store, copied
    -- from, then removed.
    local plusDB = _G.ChairPlusDB
    local snackDB = _G.SnapSnackDB
    local tracker = _G.WOWFTrackerAccountDB
    if type(plusDB) == "table" and type(plusDB.profiles) == "table" then
        plusDB.profiles[IMPORT_KEY] = { label = data.who, settings = data.plus.settings or {}, movers = data.plus.movers or {} }
    end
    if data.snack and type(snackDB) == "table" and type(snackDB.profiles) == "table" then
        snackDB.profiles[IMPORT_KEY] = data.snack
    end
    if data.tracker and type(tracker) == "table" and type(tracker.profiles) == "table" then
        tracker.profiles[IMPORT_KEY] = data.tracker
    end
    local ok, copied = pcall(ns.CopyCharacter, IMPORT_KEY)
    if type(plusDB) == "table" and type(plusDB.profiles) == "table" then plusDB.profiles[IMPORT_KEY] = nil end
    if type(snackDB) == "table" and type(snackDB.profiles) == "table" then snackDB.profiles[IMPORT_KEY] = nil end
    if type(tracker) == "table" and type(tracker.profiles) == "table" then tracker.profiles[IMPORT_KEY] = nil end
    if not ok then return nil, "could not be applied: " .. tostring(copied) end
    copied = copied or {}

    local auras = _G.ChairAurasDB
    if withAuras and type(data.auras) == "table" and type(auras) == "table" and type(auras.profiles) == "table" then
        auras.profiles.account = DeepCopy(data.auras)
        copied[#copied + 1] = "Auras"
    end
    return copied, data
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local window

local function Build()
    if window then return window end
    window = CreateFrame("Frame", "ChairPlusBackup", UIParent, "BackdropTemplate")
    window:SetSize(460, 300)
    window:SetPoint("CENTER")
    window:SetFrameStrata("FULLSCREEN_DIALOG")
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
    tinsert(UISpecialFrames, "ChairPlusBackup")

    window.title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    window.title:SetPoint("TOP", 0, -12)
    window.hint = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    window.hint:SetPoint("TOPLEFT", 16, -36)
    window.hint:SetPoint("TOPRIGHT", -16, -36)
    window.hint:SetJustifyH("LEFT")

    local back = CreateFrame("Frame", nil, window)
    back:SetPoint("TOPLEFT", 16, -64)
    back:SetPoint("BOTTOMRIGHT", -16, 76)
    local fill = back:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetColorTexture(0, 0, 0, 0.5)
    local scroll = CreateFrame("ScrollFrame", nil, back)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(410)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnTextChanged", function(_, byUser) if byUser and window.Peek then window.Peek() end end)
    scroll:SetScrollChild(box)
    window.box = box

    window.aurasCheck = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
    window.aurasCheck:SetSize(22, 22)
    window.aurasCheck:SetPoint("BOTTOMLEFT", 14, 44)
    window.aurasLabel = window:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    window.aurasLabel:SetPoint("LEFT", window.aurasCheck, "RIGHT", 2, 0)
    window.aurasLabel:SetText("Auras too (they are account-wide: every character's change)")
    window.aurasCheck:SetScript("OnClick", function()
        if window.mode == "export" then window.ShowExport() end
    end)

    local function Button(label, width, onClick)
        local b = ns.MakeButton and ns.MakeButton(window, width, label)
            or CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        if not ns.MakeButton then b:SetSize(width, 22) b:SetText(label) end
        b:SetScript("OnClick", onClick)
        return b
    end
    window.importButton = Button("Import", 90, function()
        local copied, err = ns.ImportSettings(window.box:GetText(), window.aurasCheck:GetChecked())
        if not copied then
            window.hint:SetText("|cffff5555" .. tostring(err) .. "|r")
            return
        end
        ns.Print("Imported " .. table.concat(copied, ", ") .. ". Type |cffffd100/reload|r to finish.")
        window:Hide()
    end)
    window.importButton:SetPoint("BOTTOMRIGHT", -112, 14)
    local close = Button("Close", 90, function() window:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -16, 14)

    function window.ShowExport()
        local text, err = ns.ExportSettings(window.aurasCheck:GetChecked())
        window.box:SetText(text or "")
        window.hint:SetText(text and "Copy this (Ctrl-C) and keep it, or paste it into Import on another character."
            or ("|cffff5555" .. tostring(err) .. "|r"))
        window.box:SetFocus()
        window.box:HighlightText()
    end

    function window.Peek()
        local data, err = ns.PeekSettings(window.box:GetText())
        if data then
            window.hint:SetText(string.format("From |cffffffff%s|r: %s. Import replaces this character's settings.",
                tostring(data.who or "someone"), table.concat(data.parts, ", ")))
        else
            window.hint:SetText(window.box:GetText() ~= "" and ("|cffff5555" .. tostring(err) .. "|r")
                or "Paste a Chaircraft settings string here.")
        end
    end
    return window
end

function ns.OpenBackup(mode)
    local w = Build()
    w.mode = mode
    w.title:SetText(mode == "export" and "Export settings" or "Import settings")
    w.importButton:SetShown(mode ~= "export")
    w:Show()
    if mode == "export" then
        w.aurasCheck:SetChecked(false)
        w.ShowExport()
    else
        w.aurasCheck:SetChecked(false)
        w.box:SetText("")
        w.Peek()
        w.box:SetFocus()
    end
end
