local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Icons
-------------------------------------------------------------------------------
-- Where a list of every icon in the game comes from, and a window to pick one
-- out of it.
--
-- There are three ways a client can answer this and no guarantee of any of
-- them, so all three are tried in turn and whichever answers is used:
--
-- 1. GetNumMacroIcons / GetMacroIconInfo -- the list the macro window draws,
--    which is the raw icon set. Cheap, complete, and has no names attached.
--
-- 2. The macro icon lists -- GetLooseMacroIcons, GetMacroIcons and their item
--    twins, the four the modern client's IconDataProvider is built from, asked
--    for directly. The provider itself is never created here: it keeps its
--    list and a count of its users in variables shared by every caller, so
--    creating one from addon code taints them, and the next Blizzard panel
--    that uses one runs tainted -- the nameplate preview in Options >
--    Advanced then errors on secret values (2026-09-28). Releasing one from
--    here can also clear the list under a panel still using it.
--
-- 3. Spell icons -- every spell the client admits exists, walked in the
--    background and indexed by name. This is what WeakAuras searches: its
--    picker is a search over spell names, not over icon files, which is why
--    typing "shield" there finds shield icons. C_Spell.GetSpellName and
--    GetSpellTexture both work here, so this one cannot fail.
--
-- The first two are for browsing and the third is what makes the search box
-- work. Nothing is written to the saved file: the index is rebuilt each session
-- because this client cannot be trusted to hand a saved one back, and it is
-- cheap enough to earn its place at a few thousand ids a frame.

local Icons = {}
ns.Icons = Icons

local QUESTION_MARK = 134400

-------------------------------------------------------------------------------
-- The browse list
-------------------------------------------------------------------------------

local browseList, browseSource

local function FromMacroAPI()
    if not (_G.GetNumMacroIcons and _G.GetMacroIconInfo) then return nil end

    local ok, count = pcall(GetNumMacroIcons)
    count = ok and ns.SafeNumber(count) or nil
    if not count or count < 1 then return nil end

    local list = {}
    for index = 1, count do
        local got, texture = pcall(GetMacroIconInfo, index)
        if got and texture then list[#list + 1] = texture end
    end

    if #list == 0 then return nil end
    return list
end

local function FromMacroLists()
    local spells, items = {}, {}
    for _, fill in ipairs({ { _G.GetLooseMacroIcons, spells }, { _G.GetMacroIcons, spells },
                            { _G.GetLooseMacroItemIcons, items }, { _G.GetMacroItemIcons, items } }) do
        if type(fill[1]) == "function" then pcall(fill[1], fill[2]) end
    end

    -- Each entry is a file ID, as a number or a string of digits, or a file
    -- name under Interface\Icons.
    local list = {}
    for _, source in ipairs({ spells, items }) do
        for _, texture in ipairs(source) do
            local id = tonumber(texture)
            if id then
                list[#list + 1] = id
            elseif type(texture) == "string" and texture ~= "" then
                list[#list + 1] = "Interface\\Icons\\" .. texture
            end
        end
    end

    if #list == 0 then return nil end
    return list
end

-- Last resort: the icons of everything the spell index found. Not the full set
-- of files, but it is never empty and it is always searchable.
local function FromSpellIndex()
    local list, seen = {}, {}
    for _, entry in ipairs(Icons:SpellIndex()) do
        if not seen[entry.icon] then
            seen[entry.icon] = true
            list[#list + 1] = entry.icon
        end
    end
    if #list == 0 then return nil end
    return list
end

function Icons:Browse()
    if browseList then return browseList, browseSource end

    browseList, browseSource = FromMacroAPI(), "macro icons"
    if not browseList then browseList, browseSource = FromMacroLists(), "macro icon lists" end
    if not browseList then browseList, browseSource = FromSpellIndex(), "spell icons" end
    if not browseList then browseList, browseSource = { QUESTION_MARK }, "nothing" end

    return browseList, browseSource
end

function Icons:Source()
    local _, source = self:Browse()
    return source, #self:Browse()
end

-------------------------------------------------------------------------------
-- The spell index
-------------------------------------------------------------------------------
-- Walked a slice at a time so the game does not stutter, and readable while it
-- is still being built: the picker shows what has been found so far and grows
-- under you rather than making you wait for a progress bar.

local spellIndex = {}
local scanCursor = 0
local scanning = false

-- Where to stop looking. Spell ids on this client run far past the vanilla
-- range -- its own items are numbered in the quarter million -- so this is a
-- ceiling on effort rather than a claim about what exists.
local SCAN_CEILING = 250000
local SCAN_SLICE = 4000

function Icons:SpellIndex()
    return spellIndex
end

function Icons:ScanProgress()
    return scanCursor, SCAN_CEILING, scanning
end

local function ScanSlice()
    local stop = math.min(scanCursor + SCAN_SLICE, SCAN_CEILING)

    for id = scanCursor + 1, stop do
        local name = ns.SafeText(C_Spell.GetSpellName(id))
        if name then
            local icon = ns.SafeNumber(C_Spell.GetSpellTexture(id))
            if icon then
                spellIndex[#spellIndex + 1] = { name = name, icon = icon, id = id }
            end
        end
    end

    scanCursor = stop
    if scanCursor >= SCAN_CEILING then
        scanning = false
        return false
    end
    return true
end

function Icons:StartScan(onProgress)
    if scanning or scanCursor >= SCAN_CEILING then return end
    scanning = true

    local function Step()
        if not scanning then return end
        local more = ScanSlice()
        if onProgress then onProgress(scanCursor, SCAN_CEILING) end
        if more then
            C_Timer.After(0, Step)
        elseif onProgress then
            onProgress(SCAN_CEILING, SCAN_CEILING)
        end
    end

    Step()
end

function Icons:StopScan()
    scanning = false
end

-- Every icon whose spell name contains the text, most obvious first: an exact
-- name beats one that merely contains it, because someone typing "renew" wants
-- Renew before Renewing Mist.
function Icons:Search(text, limit)
    limit = limit or 300
    text = (text or ""):lower()
    if text == "" then return {} end

    local exact, partial, seen = {}, {}, {}

    for _, entry in ipairs(spellIndex) do
        local name = entry.name:lower()
        if not seen[entry.icon] then
            if name == text then
                seen[entry.icon] = true
                exact[#exact + 1] = entry
            elseif name:find(text, 1, true) then
                seen[entry.icon] = true
                partial[#partial + 1] = entry
            end
        end
        if #exact + #partial >= limit then break end
    end

    for _, entry in ipairs(partial) do exact[#exact + 1] = entry end
    return exact
end

-------------------------------------------------------------------------------
-- The picker
-------------------------------------------------------------------------------
-- A page of icons at a time rather than all of them: the full list on this
-- client is thousands long, and a scroll frame holding thousands of buttons is
-- how an options window takes a second to open. Buttons are made once and
-- refilled, so paging costs nothing after the first page.

local COLUMNS, ROWS = 10, 8
local CELL = 36
local PAGE = COLUMNS * ROWS

local picker
local topRow, filtered, onPicked = 0, nil, nil

local function CurrentList()
    if filtered then return filtered end
    return (Icons:Browse())
end

-- How far down the list can go before the last row is on screen. The grid is a
-- fixed pool of buttons showing a window onto the list rather than a button per
-- icon: the full set on this client is thousands long, and thousands of frames
-- is how an options window takes a second to open and a second to close.
local function MaxTopRow()
    local rows = math.ceil(#CurrentList() / COLUMNS)
    return math.max(rows - ROWS, 0)
end

local function RefreshPicker()
    if not picker then return end

    local list = CurrentList()
    topRow = math.max(0, math.min(topRow, MaxTopRow()))

    -- The scrollbar is told where it is rather than asked, and told not to
    -- answer back: setting its value fires its own handler, which would call
    -- straight back into here.
    if picker.scrollbar then
        picker.scrollbar.settingProgrammatically = true
        picker.scrollbar:SetMinMaxValues(0, MaxTopRow())
        picker.scrollbar:SetValue(topRow)
        picker.scrollbar:SetShown(MaxTopRow() > 0)
        picker.scrollbar.settingProgrammatically = nil
    end

    local first = topRow * COLUMNS
    for index, button in ipairs(picker.buttons) do
        local entry = list[first + index]
        local texture = type(entry) == "table" and entry.icon or entry
        if texture then
            button.texture:SetTexture(texture)
            button.value = texture
            button.label = type(entry) == "table" and entry.name or nil
            button:Show()
        else
            button:Hide()
        end
    end

    local source = Icons:Source()
    local scanned, ceiling, running = Icons:ScanProgress()
    local rows = math.ceil(#list / COLUMNS)

    picker.status:SetText(string.format(
        "%d icons  |cff808080(%s)|r    row %d of %d%s",
        #list, filtered and "search" or source,
        math.min(topRow + 1, math.max(rows, 1)), math.max(rows, 1),
        running and string.format("   |cff808080indexing spells %d%%|r",
                                  math.floor(scanned / ceiling * 100)) or ""))
end

local function ScrollTo(row)
    topRow = row
    RefreshPicker()
end

local function BuildPicker()
    picker = CreateFrame("Frame", "ChairAurasIconPicker", UIParent, "BackdropTemplate")
    picker:SetSize(COLUMNS * CELL + 52, ROWS * CELL + 116)
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
    tinsert(UISpecialFrames, "ChairAurasIconPicker")

    local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetText("Choose an icon")
    title:SetPoint("TOP", picker, "TOP", 0, -12)

    -- Search
    local box = CreateFrame("EditBox", nil, picker, "InputBoxTemplate")
    box:SetSize(COLUMNS * CELL - 96, 22)
    box:SetPoint("TOPLEFT", picker, "TOPLEFT", 24, -36)
    box:SetAutoFocus(false)
    picker.box = box

    local function Search()
        local text = box:GetText()
        if text == "" then
            filtered = nil
        else
            filtered = Icons:Search(text)
        end
        topRow = 0
        RefreshPicker()
    end

    box:SetScript("OnEnterPressed", function(self) Search(); self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Searching as you type, because the answer is already in memory and making
    -- someone press Enter to find out there are no results is a wasted step.
    box:SetScript("OnTextChanged", Search)

    local clear = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
    clear:SetSize(60, 22)
    clear:SetPoint("LEFT", box, "RIGHT", 6, 0)
    clear:SetText("All")
    clear:SetScript("OnClick", function()
        box:SetText("")
        filtered = nil
        topRow = 0
        RefreshPicker()
    end)

    -- The grid
    picker.buttons = {}
    for index = 1, PAGE do
        local button = CreateFrame("Button", nil, picker)
        button:SetSize(CELL - 4, CELL - 4)

        local column = (index - 1) % COLUMNS
        local row = math.floor((index - 1) / COLUMNS)
        button:SetPoint("TOPLEFT", picker, "TOPLEFT",
                        22 + column * CELL, -68 - row * CELL)

        button.texture = button:CreateTexture(nil, "ARTWORK")
        button.texture:SetAllPoints()
        button.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.25)

        button:SetScript("OnEnter", function(self)
            if not self.label then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.label, 1, 1, 1)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)

        button:SetScript("OnClick", function(self)
            if onPicked and self.value then onPicked(self.value) end
            picker:Hide()
        end)

        picker.buttons[index] = button
    end

    -- Scrolling. The wheel is the part people will actually use; the bar is
    -- there so the window says how far down the list you are.
    --
    -- Built from a bare Slider with a plain colour for its thumb rather than
    -- from a scrollbar template. The templates this client has were checked one
    -- by one before anything here was allowed to depend on them, and a missing
    -- scrollbar art file would leave a working control nobody can see.
    picker:EnableMouseWheel(true)
    picker:SetScript("OnMouseWheel", function(_, delta)
        ScrollTo(topRow - (delta or 0) * 3)
    end)

    local scrollbar = CreateFrame("Slider", nil, picker)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetSize(10, ROWS * CELL - 8)
    scrollbar:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -8, -68)
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

    local close = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
    close:SetSize(70, 22)
    close:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -22, 12)
    close:SetText("Cancel")
    close:SetScript("OnClick", function() picker:Hide() end)

    picker.status = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    picker.status:SetPoint("BOTTOM", picker, "BOTTOM", 0, 40)

    picker:Hide()
end

function Icons:Open(callback)
    if not picker then
        local ok, err = pcall(BuildPicker)
        if not ok then
            ns.Print("the icon picker failed to build:", err)
            return
        end
    end

    onPicked = callback
    filtered = nil
    topRow = 0
    picker.box:SetText("")

    -- The spell index is what the search box searches, and it is only worth
    -- building once someone has actually asked to look at icons.
    self:StartScan(function() RefreshPicker() end)

    RefreshPicker()
    picker:Show()
end

function Icons:Toggle(callback)
    if picker and picker:IsShown() then
        picker:Hide()
    else
        self:Open(callback)
    end
end
