local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Sounds
-------------------------------------------------------------------------------
-- The list of things an aura can play, and a window to pick one out of it.
--
-- Where the list comes from, in order:
--
-- 1. SOUNDKIT -- the client's own table of named sounds. Every entry in it is
--    something this client definitely has, which is the only list worth
--    offering: a menu of sounds that turn out not to exist is worse than no
--    menu, because the silence looks like a bug in the aura.
--
-- 2. Anything the player has typed in by hand, kept beside the list so a file
--    path someone pasted does not vanish out of the picker next time they open
--    it.
--
-- Nothing is hardcoded. A list of sound ids written down here would be a guess
-- about a client that has already removed more than it kept.

local Sounds = {}
ns.Sounds = Sounds

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

local list, custom = nil, {}

-- IG_MAINMENU_OPEN reads as "Ig Mainmenu Open", which is not English but is
-- several steps closer to it than the constant.
local function Prettify(name)
    local text = name:gsub("_", " "):lower()
    text = text:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)
    return text
end

function Sounds:List()
    if list then return list end

    list = {}

    local kit = _G.SOUNDKIT
    if type(kit) == "table" then
        for name, id in pairs(kit) do
            local value = ns.SafeNumber(id)
            if type(name) == "string" and value then
                list[#list + 1] = {
                    name = Prettify(name),
                    raw = name,
                    value = tostring(value),
                }
            end
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- A path someone typed is added to the list rather than argued with: this addon
-- has no way to know which files a client of this vintage actually ships.
function Sounds:Remember(value)
    if not value or value == "" or tonumber(value) then return end
    for _, entry in ipairs(custom) do
        if entry.value == value then return end
    end
    custom[#custom + 1] = { name = value, raw = value, value = value }
    list = nil   -- rebuilt with the new one in it
end

function Sounds:Entries()
    local out = { { name = "|cff808080No sound|r", value = "" } }
    for _, entry in ipairs(custom) do out[#out + 1] = entry end
    for _, entry in ipairs(self:List()) do out[#out + 1] = entry end
    return out
end

-- What to call whatever is stored on an aura, for the field to show.
function Sounds:Label(value)
    if not value or value == "" then return "none" end

    for _, entry in ipairs(self:Entries()) do
        if entry.value == value then return entry.name end
    end
    return value
end

-- One place that knows how to make a noise, used by the picker and by the
-- action that fires in play. A number is a sound this client already has;
-- anything else is a file.
--
-- Both calls answer with a handle as well as whether they played, and the
-- handle is what StopSound wants later. It is passed back rather than kept
-- here: an aura firing its own sound must never be able to cut off the one
-- someone is auditioning in the picker, and the two only stay separate if
-- neither of them owns a global "currently playing".
function Sounds:Play(value, channel)
    if not value or value == "" then return false end
    channel = channel or "Master"

    local id = tonumber(value)
    local ok, willPlay, handle

    if id then
        if type(_G.PlaySound) ~= "function" then return false end
        ok, willPlay, handle = pcall(PlaySound, id, channel)
    else
        if type(_G.PlaySoundFile) ~= "function" then return false end
        ok, willPlay, handle = pcall(PlaySoundFile, value, channel)
    end

    if not ok then return false end
    -- A client that answers nothing at all still played it as far as anyone
    -- can tell; only an explicit false means it did not.
    if willPlay == false then return false end
    return true, handle
end

function Sounds:Stop(handle)
    if handle == nil then return false end
    if type(_G.StopSound) ~= "function" then return false end
    return (pcall(StopSound, handle))
end

-- Auditioning: the one the picker and the Play button use. Starting a new one
-- stops the one before it, because two sounds over each other tell you nothing
-- about either -- and the point of the list is hearing them one at a time.
local previewHandle

function Sounds:Preview(value, channel)
    self:StopPreview()

    local ok, handle = self:Play(value, channel)
    if ok then previewHandle = handle end
    return ok
end

function Sounds:StopPreview()
    if previewHandle ~= nil then
        self:Stop(previewHandle)
        previewHandle = nil
    end
end

function Sounds:Available()
    return type(_G.PlaySound) == "function"
        or type(_G.PlaySoundFile) == "function"
end

-------------------------------------------------------------------------------
-- The picker
-------------------------------------------------------------------------------
-- A scrolling list of names, and picking one plays it. That is the whole point
-- of the window: nobody knows what MONSTER_SOUND_12 is until they hear it, and
-- choosing a sound you have not heard is choosing at random.

local ROWS, ROW_HEIGHT = 14, 20

local picker
local topRow, filtered, onPicked, channel = 0, nil, nil, "Master"

local function Entries()
    return filtered or Sounds:Entries()
end

local function MaxTopRow()
    return math.max(#Entries() - ROWS, 0)
end

local function RefreshPicker()
    if not picker then return end

    topRow = math.max(0, math.min(topRow, MaxTopRow()))

    if picker.scrollbar then
        picker.scrollbar.settingProgrammatically = true
        picker.scrollbar:SetMinMaxValues(0, MaxTopRow())
        picker.scrollbar:SetValue(topRow)
        picker.scrollbar:SetShown(MaxTopRow() > 0)
        picker.scrollbar.settingProgrammatically = nil
    end

    local entries = Entries()
    for index, row in ipairs(picker.rows) do
        local entry = entries[topRow + index]
        if entry then
            row.text:SetText(entry.name)
            row.value = entry.value
            row:Show()
        else
            row:Hide()
        end
    end

    picker.status:SetText(string.format("%d sounds  |cff808080(click one to hear it)|r",
                                        #entries))
end

local function ScrollTo(row)
    topRow = row
    RefreshPicker()
end

local function BuildPicker()
    picker = CreateFrame("Frame", "ChairAurasSoundPicker", UIParent, "BackdropTemplate")
    picker:SetSize(320, ROWS * ROW_HEIGHT + 110)
    picker:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    picker:SetFrameStrata("FULLSCREEN_DIALOG")
    picker:SetMovable(true)
    picker:EnableMouse(true)
    picker:RegisterForDrag("LeftButton")
    picker:SetScript("OnDragStart", picker.StartMoving)
    picker:SetScript("OnDragStop", picker.StopMovingOrSizing)
    picker:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    picker:SetBackdropColor(0.05, 0.06, 0.08, 0.96)
    picker:SetBackdropBorderColor(0.25, 0.77, 1, 0.7)
    tinsert(UISpecialFrames, "ChairAurasSoundPicker")

    local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetText("Choose a sound")
    title:SetPoint("TOP", picker, "TOP", 0, -12)

    local box = CreateFrame("EditBox", nil, picker, "InputBoxTemplate")
    box:SetSize(180, 22)
    box:SetPoint("TOPLEFT", picker, "TOPLEFT", 24, -36)
    box:SetAutoFocus(false)
    picker.box = box

    local function Search()
        local text = box:GetText():lower()
        if text == "" then
            filtered = nil
        else
            filtered = {}
            for _, entry in ipairs(Sounds:Entries()) do
                if entry.name:lower():find(text, 1, true)
                   or (entry.raw or ""):lower():find(text, 1, true) then
                    filtered[#filtered + 1] = entry
                end
            end
        end
        topRow = 0
        RefreshPicker()
    end

    box:SetScript("OnTextChanged", Search)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- A file of your own, for anything the client's own list does not carry.
    local add = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
    add:SetSize(80, 22)
    add:SetPoint("LEFT", box, "RIGHT", 6, 0)
    add:SetText("Use path")
    add:SetScript("OnClick", function()
        local text = box:GetText()
        if text == "" then return end
        Sounds:Remember(text)
        Sounds:Preview(text, channel)
        if onPicked then onPicked(text) end
        picker:Hide()
    end)

    picker.rows = {}
    for index = 1, ROWS do
        local row = CreateFrame("Button", nil, picker)
        row:SetSize(250, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", picker, "TOPLEFT", 22, -66 - (index - 1) * ROW_HEIGHT)

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.12)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetJustifyH("LEFT")

        -- Selecting is hearing. The window stays open so the next one can be
        -- tried against it, and Use it closes on the one you settled on.
        row:SetScript("OnClick", function(self)
            picker.chosen = self.value
            picker.chosenText:SetText("chosen: " .. Sounds:Label(self.value))
            Sounds:Preview(self.value, channel)
            if onPicked then onPicked(self.value) end
        end)

        picker.rows[index] = row
    end

    picker:EnableMouseWheel(true)
    picker:SetScript("OnMouseWheel", function(_, delta)
        ScrollTo(topRow - (delta or 0) * 3)
    end)

    local scrollbar = CreateFrame("Slider", nil, picker)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetSize(10, ROWS * ROW_HEIGHT - 4)
    scrollbar:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -10, -66)
    scrollbar:SetValueStep(1)
    pcall(scrollbar.SetObeyStepOnDrag, scrollbar, true)

    local track = scrollbar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.07)

    local thumb = scrollbar:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(0.25, 0.77, 1, 0.55)
    thumb:SetSize(10, 28)
    scrollbar:SetThumbTexture(thumb)

    scrollbar:SetScript("OnValueChanged", function(self, value)
        if self.settingProgrammatically then return end
        ScrollTo(math.floor(value + 0.5))
    end)
    picker.scrollbar = scrollbar

    picker.chosenText = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    picker.chosenText:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 22, 34)

    picker.status = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    picker.status:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 22, 48)

    local done = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
    done:SetSize(70, 22)
    done:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -20, 10)
    done:SetText("Done")
    done:SetScript("OnClick", function() picker:Hide() end)

    -- Closing takes the sound with it, however it was closed: the Done
    -- button, escape, or something else stealing the screen. OnHide catches
    -- all three, which a handler on the button would not.
    picker:SetScript("OnHide", function()
        Sounds:StopPreview()
    end)

    picker:Hide()
end

function Sounds:Open(current, soundChannel, callback)
    if not picker then
        local ok, err = pcall(BuildPicker)
        if not ok then
            ns.Print("the sound list failed to build:", err)
            return
        end
    end

    onPicked = callback
    channel = soundChannel or "Master"
    filtered = nil
    topRow = 0
    picker.box:SetText("")
    picker.chosen = current
    picker.chosenText:SetText("chosen: " .. self:Label(current))

    -- Whatever is already set stays in the list even if it came from a file.
    self:Remember(current)

    RefreshPicker()
    picker:Show()

    if not self:Available() then
        ns.Print("|cffdd6666note:|r this client has no way to play a sound, so "
                 .. "nothing here will be heard.")
    end
end
