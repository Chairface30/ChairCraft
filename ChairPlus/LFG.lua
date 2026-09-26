-- ChairPlus LFG.lua
-- Player filters for the group finder's Browse tab.
--
-- The Browse list is a mix of groups looking for members and individual
-- players looking for a group. These filters are for picking through the
-- individuals: by class, by role (tank, healer, damage) and by level, with
-- the groups hidden while "Players only" is on.
--
-- The filters sit in a small panel against the right edge of the group
-- finder, shown with the Browse tab. They work through the Browse frame's
-- own two steps: UpdateResultList fetches the result IDs into its `results`
-- table, then UpdateResults builds the list on screen from that table. After
-- the first, the IDs that do not match are taken out of `results`, and the
-- second is run again so Blizzard redraws the list itself.
--
-- The first version edited the list on screen (the ScrollBox's data provider)
-- instead. This client's provider is an older kind that could not be read
-- back from outside, so the filter read nothing, wrote nothing back, and the
-- list showed for a few frames and then vanished.
--
-- The full set of IDs is kept, so changing a filter re-filters at once
-- without a new search.
--
-- Built against the Classic Era group finder this client runs (LFGParentFrame
-- with LFGBrowseFrame, results from C_LFGList). How a listing reports its
-- player's class, level and roles has moved between builds, so every field is
-- looked for in more than one place; "/chair plus lfg" dumps what one really
-- holds.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                  "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local ROLES = { { value = "TANK", text = "Tank" }, { value = "HEALER", text = "Healer" },
                { value = "DAMAGER", text = "Damage" } }

-------------------------------------------------------------------------------
-- Reading a listing
-------------------------------------------------------------------------------

local function List() return _G.C_LFGList end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

-- The entry in the ScrollBox's list, whatever shape it has: a result ID, or a
-- table carrying one.
local function ResultID(element)
    if type(element) == "number" then return element end
    if type(element) == "table" then
        return ns.Num(element.resultID) or ns.Num(element.id) or ns.Num(element[1])
    end
    return nil
end

local function Upper(text)
    text = ns.Text(text)
    return text and text:upper() or nil
end

-- One listing's player: { members, class, level, roles = { TANK = true, ... } }.
function ns.LFGPlayer(resultID)
    local list = List()
    if not list or not resultID then return nil end
    local info = Call(list.GetSearchResultInfo, resultID)
    local out = { roles = {} }
    if type(info) == "table" then
        out.members = ns.Num(info.numMembers)
        out.class = Upper(info.leaderClassFilename or info.classFilename)
        out.level = ns.Num(info.leaderLevel or info.level)
    end

    local player = Call(list.GetSearchResultPlayerInfo, resultID, 1)
    if type(player) ~= "table" then player = Call(list.GetSearchResultLeaderInfo, resultID) end
    if type(player) == "table" then
        out.class = Upper(player.classFilename or player.class or player.className) or out.class
        out.level = ns.Num(player.level) or out.level
        if player.isTank then out.roles.TANK = true end
        if player.isHealer then out.roles.HEALER = true end
        if player.isDamage or player.isDPS then out.roles.DAMAGER = true end
        local assigned = Upper(player.assignedRole or player.role)
        if assigned then out.roles[assigned] = true end
        if type(player.roles) == "table" then
            for key, value in pairs(player.roles) do
                if value == true then out.roles[Upper(key) or key] = true end
                if type(value) == "string" then out.roles[Upper(value)] = true end
            end
        end
    end

    -- A solo listing's member counts are its own roles.
    if not next(out.roles) then
        local counts = Call(list.GetSearchResultMemberCounts, resultID)
        if type(counts) == "table" then
            for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
                if (ns.Num(counts[role]) or 0) > 0 then out.roles[role] = true end
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- The filter
-------------------------------------------------------------------------------

-- A saved "MAGE,PRIEST" as a set. Empty means no filter: nothing ticked is
-- the same as everything ticked.
local function Set(key)
    local out, any = {}, false
    local saved = ns.Get(key)
    if type(saved) == "string" then
        for value in saved:gmatch("[^,%s]+") do
            out[value] = true
            any = true
        end
    end
    return any and out or nil
end

-- Tick or untick one value in a saved set.
function ns.LFGToggle(key, value, on)
    local set = Set(key) or {}
    set[value] = on and true or nil
    local list = {}
    for v in pairs(set) do list[#list + 1] = v end
    table.sort(list)
    ns.Set(key, table.concat(list, ","))
end

local function Filters()
    return {
        classes = Set("lfgClasses"),
        roles = Set("lfgRoles"),
        min = ns.Num(ns.Get("lfgMinLevel")) or 0,
        max = ns.Num(ns.Get("lfgMaxLevel")) or 0,
        playersOnly = ns.Get("lfgPlayersOnly") and true or false,
    }
end

-- Whether a listing stays in the list under the current filters.
function ns.LFGKeep(resultID)
    local f = Filters()
    local p = ns.LFGPlayer(resultID)
    if not p then return true end
    local solo = (p.members or 1) <= 1
    if not solo then
        -- Groups are not what these filters read; they stay unless hidden.
        return not f.playersOnly
    end
    if f.classes and p.class and not f.classes[p.class] then return false end
    if f.roles and next(p.roles) then
        -- Any of the roles they listed that is ticked will do.
        local match = false
        for role in pairs(p.roles) do if f.roles[role] then match = true end end
        if not match then return false end
    end
    if f.min > 0 and p.level and p.level < f.min then return false end
    if f.max > 0 and p.level and p.level > f.max then return false end
    return true
end

local full = {}              -- every result from the last search
local shownCount, fullCount = 0, 0
local panel, countText
ns.lfgDiag = {}

local function Keeps(element)
    local id = ResultID(element)
    if not id then return true end
    local ok, keep = pcall(ns.LFGKeep, id)
    return (not ok) or keep
end

local function ShowCount()
    if countText then
        countText:SetText(string.format("Showing %d of %d", shownCount, fullCount))
    end
end

local redrawing = false

-- Filter the Browse frame's results and have it redraw. `restore` puts the
-- whole last search back first -- for a changed filter, and for switching
-- the filters off.
local function FilterBrowse(browse, restore)
    if redrawing or not browse then return end
    local results = browse.results
    ns.lfgDiag = { field = type(results) }
    if type(results) ~= "table" then return end

    if restore then
        for i = #results, 1, -1 do results[i] = nil end
        for i, v in ipairs(full) do results[i] = v end
    else
        full = {}
        for i, v in ipairs(results) do full[i] = v end
    end

    local kept = {}
    if ns.IsEnabled("lfgFilters") then
        for _, v in ipairs(full) do
            if Keeps(v) then kept[#kept + 1] = v end
        end
    else
        for i, v in ipairs(full) do kept[i] = v end
    end
    shownCount, fullCount = #kept, #full
    ns.lfgDiag.full, ns.lfgDiag.kept = #full, #kept

    if restore or #kept ~= #full then
        for i = #results, 1, -1 do results[i] = nil end
        for i, v in ipairs(kept) do results[i] = v end
        if type(browse.UpdateResults) == "function" then
            redrawing = true
            local ok, err = pcall(browse.UpdateResults, browse)
            redrawing = false
            ns.lfgDiag.redraw = ok and "ok" or (ns.Text(err) or "failed")
        end
    end
    ShowCount()
end

function ns.LFGRefilter()
    FilterBrowse(_G.LFGBrowseFrame, true)
end

function ns.LFGCounts() return shownCount, fullCount end

-------------------------------------------------------------------------------
-- The panel
-------------------------------------------------------------------------------

local function Button(parent, width, text, onClick)
    local ok, button = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not button then button = CreateFrame("Button", nil, parent) end
    button:SetSize(width, 20)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    button.labelText = label
    button:SetScript("OnClick", onClick)
    return button
end

local function ClassName(class)
    local names = _G.LOCALIZED_CLASS_NAMES_MALE
    return (names and names[class]) or (class:sub(1, 1) .. class:sub(2):lower())
end

local function CheckBox(parent, x, y, text, r, g, b)
    local ok, check = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if not ok or not check then check = CreateFrame("CheckButton", nil, parent) end
    check:SetSize(20, 20)
    check:SetPoint("TOPLEFT", x, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", check, "RIGHT", 1, 0)
    label:SetText(text)
    if r then label:SetTextColor(r, g, b) end
    check.labelText = label
    return check
end

-- A block of checkboxes for one saved set, two to a row. Returns the height
-- it took and a function that shows the saved state.
local function Checks(parent, y, title, values, key)
    local heading = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    heading:SetPoint("TOPLEFT", 10, y)
    heading:SetText(title .. " |cff808080(none ticked: any)|r")
    local boxes = {}
    for i, option in ipairs(values) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local check = CheckBox(parent, 8 + col * 80, y - 14 - row * 20, option.text,
            option.r, option.g, option.b)
        check:SetScript("OnClick", function(self)
            ns.LFGToggle(key, option.value, self:GetChecked())
            ns.LFGRefilter()
        end)
        boxes[option.value] = check
    end
    local function Show()
        local set = Set(key) or {}
        for value, check in pairs(boxes) do check:SetChecked(set[value] == true) end
    end
    Show()
    return 14 + math.ceil(#values / 2) * 20, Show
end

local function LevelBox(parent, x, y, key)
    local ok, box = pcall(CreateFrame, "EditBox", nil, parent, "InputBoxTemplate")
    if not ok or not box then box = CreateFrame("EditBox", nil, parent) end
    box:SetSize(34, 20)
    box:SetPoint("TOPLEFT", x, y)
    box:SetAutoFocus(false)
    pcall(box.SetNumeric, box, true)
    pcall(box.SetMaxLetters, box, 2)
    local function Commit(self)
        ns.Set(key, tonumber(self:GetText()) or 0)
        ns.LFGRefilter()
    end
    box:SetScript("OnEnterPressed", function(self) Commit(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", Commit)
    local function Show()
        local n = ns.Num(ns.Get(key)) or 0
        if not box:HasFocus() then box:SetText(n > 0 and tostring(n) or "") end
    end
    Show()
    return Show
end

local shows = {}

-- There is no auto refresh. It was tried (2026-09-26): a group search is a
-- protected action on this client, started only by a real click, and the
-- game blocked the timed one (ADDON_ACTION_BLOCKED, 'Search()').

local function BuildPanel(browse)
    if panel then return end
    local parentFrame = _G.LFGParentFrame or browse
    panel = CreateFrame("Frame", "ChairPlusLFGFilters", browse)
    panel:SetSize(170, 310)
    -- Hung from the bottom of the finder's right edge, not the top: the side
    -- tabs (the Who List among them) sit at the top right, and the panel
    -- clipped through them there.
    panel:SetPoint("BOTTOMLEFT", parentFrame, "BOTTOMRIGHT", -2, 12)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.92)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("|cff9d7cffPlayer filters|r")

    -- Class names in their class colors, so the list reads at a glance.
    local classValues = {}
    local colors = _G.RAID_CLASS_COLORS or {}
    for _, class in ipairs(CLASSES) do
        local c = colors[class]
        classValues[#classValues + 1] = { value = class, text = ClassName(class),
            r = c and c.r, g = c and c.g, b = c and c.b }
    end
    local y = -28
    local used, show = Checks(panel, y, "Class", classValues, "lfgClasses")
    shows[#shows + 1] = show
    y = y - used - 6
    used, show = Checks(panel, y, "Role", ROLES, "lfgRoles")
    shows[#shows + 1] = show
    y = y - used - 6

    local levelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    levelTitle:SetPoint("TOPLEFT", 10, y)
    levelTitle:SetText("Level")
    shows[#shows + 1] = LevelBox(panel, 14, y - 14, "lfgMinLevel")
    local to = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    to:SetPoint("TOPLEFT", 54, y - 18)
    to:SetText("to")
    shows[#shows + 1] = LevelBox(panel, 74, y - 14, "lfgMaxLevel")
    y = y - 42

    local okC, check = pcall(CreateFrame, "CheckButton", nil, panel, "UICheckButtonTemplate")
    if not okC or not check then check = CreateFrame("CheckButton", nil, panel) end
    check:SetSize(22, 22)
    check:SetPoint("TOPLEFT", 8, y)
    check:SetScript("OnClick", function(self)
        ns.Set("lfgPlayersOnly", self:GetChecked() and true or false)
        ns.LFGRefilter()
    end)
    local checkLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    checkLabel:SetPoint("LEFT", check, "RIGHT", 2, 0)
    checkLabel:SetText("Players only (hide groups)")
    shows[#shows + 1] = function() check:SetChecked(ns.IsEnabled("lfgPlayersOnly")) end

    local clear = Button(panel, 60, "Clear", function()
        ns.SetMany({ lfgClasses = "", lfgRoles = "", lfgMinLevel = 0, lfgMaxLevel = 0 })
        for _, show in ipairs(shows) do show() end
        ns.LFGRefilter()
    end)
    clear:SetPoint("TOPLEFT", 10, y - 28)
    -- The count has its own line under Clear; beside it, "Showing 100 of
    -- 100" ran off the right edge of the panel.
    panel:SetHeight(-(y - 28) + 48)

    countText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("TOPLEFT", clear, "BOTTOMLEFT", 0, -6)
    countText:SetWidth(150)
    countText:SetJustifyH("LEFT")
    countText:SetText("")

    for _, show in ipairs(shows) do show() end
end

local hooked = false
local toggle

-- Open or close the filter panel. The filters keep working either way; this
-- only decides whether the panel is showing.
local function ShowPanel()
    if not panel then return end
    local open = ns.IsEnabled("lfgFilters") and ns.IsEnabled("lfgPanelOpen")
    panel:SetShown(open and true or false)
    if toggle then
        if toggle.SetIcon then
            toggle.SetIcon(open and "LEFT" or "RIGHT")
        elseif toggle.labelText then
            toggle.labelText:SetText(open and "<" or ">")
        end
        toggle:SetShown(ns.IsEnabled("lfgFilters") and true or false)
    end
end
ns.LFGShowPanel = ShowPanel

-- A square button to the right of the Browse tab's Refresh button, the same
-- size: > opens the filter panel out to the side, < tucks it away.
local function BuildToggle(browse)
    if toggle then return end
    local refresh = browse.RefreshButton
    local ok, button = pcall(CreateFrame, "Button", "ChairPlusLFGToggle", browse, "UIPanelSquareButton")
    if not ok or not button then
        ok, button = pcall(CreateFrame, "Button", "ChairPlusLFGToggle", browse, "UIPanelButtonTemplate")
    end
    if not ok or not button then button = CreateFrame("Button", "ChairPlusLFGToggle", browse) end
    local w, h = 32, 32
    if refresh and refresh.GetSize then
        local okS, rw, rh = pcall(refresh.GetSize, refresh)
        if okS and ns.Num(rw) and ns.Num(rw) > 0 then w, h = ns.Num(rw), ns.Num(rh) end
    end
    button:SetSize(w, h)
    if refresh then
        button:SetPoint("LEFT", refresh, "RIGHT", 2, 0)
    else
        button:SetPoint("TOPRIGHT", browse, "TOPRIGHT", -40, -30)
    end
    -- The square button template draws its own arrows; without it, a ">".
    if type(_G.SquareButton_SetIcon) == "function" and button.icon then
        button.SetIcon = function(direction) pcall(_G.SquareButton_SetIcon, button, direction) end
    else
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("CENTER")
        button.labelText = label
    end
    button:SetScript("OnClick", function()
        ns.Set("lfgPanelOpen", not ns.IsEnabled("lfgPanelOpen"))
        ShowPanel()
    end)
    button:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        pcall(function()
            tip:SetOwner(self, "ANCHOR_RIGHT")
            tip:AddLine("Player filters")
            tip:AddLine("Filter the players listed by class, role and level.", 1, 1, 1, true)
            tip:Show()
        end)
    end)
    button:SetScript("OnLeave", function()
        if _G.GameTooltip then pcall(_G.GameTooltip.Hide, _G.GameTooltip) end
    end)
    toggle = button
end

local function Hook()
    local browse = _G.LFGBrowseFrame
    if not browse then return false end
    if not hooked and type(browse.UpdateResultList) == "function" then
        hooksecurefunc(browse, "UpdateResultList", function(self) FilterBrowse(self) end)
        hooked = true
        -- A search already showing when this switched on is filtered too.
        if type(browse.results) == "table" and #browse.results > 0 then FilterBrowse(browse) end
    end
    BuildPanel(browse)
    BuildToggle(browse)
    ShowPanel()
    return hooked
end

local driver

ns.RegisterModule("lfgFilters", {
    title = "Group finder player filters",
    desc = "Filter the group finder's Browse list of players by class, role and level.",
    Apply = function(enabled)
        if not driver then
            driver = CreateFrame("Frame")
            driver:SetScript("OnEvent", function()
                if ns.IsEnabled("lfgFilters") then pcall(Hook) end
            end)
        end
        if enabled then
            for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN" }) do
                pcall(driver.RegisterEvent, driver, event)
            end
            pcall(Hook)
            ShowPanel()
        else
            driver:UnregisterAllEvents()
            if panel then panel:Hide() end
            if toggle then toggle:Hide() end
            -- Off: the whole last search goes back, and new ones are left alone.
            if #full > 0 then FilterBrowse(_G.LFGBrowseFrame, true) end
        end
    end,
})

-- What "/chair plus lfg" adds: the Browse frame's own functions, and what the
-- first individual in the results really holds, so the field names above can
-- be checked against this client.
function ns.LFGProbeListing()
    local d = ns.lfgDiag or {}
    print(string.format("  filter: hooked=%s, results field=%s, last pass read %s, kept %s, redraw %s",
        tostring(hooked), tostring(d.field), tostring(d.full), tostring(d.kept), tostring(d.redraw)))
    local browse = _G.LFGBrowseFrame
    if browse then
        local fns = {}
        for key, value in pairs(browse) do
            if type(value) == "function" and type(key) == "string" then fns[#fns + 1] = key end
        end
        table.sort(fns)
        print("  LFGBrowseFrame functions: " .. table.concat(fns, ", "))
    end
    local list = List()
    local results = list and Call(list.GetSearchResults)
    if type(results) ~= "table" then return end
    for _, id in ipairs(results) do
        local info = Call(list.GetSearchResultInfo, id)
        if type(info) == "table" and (ns.Num(info.numMembers) or 0) <= 1 then
            local function dump(label, t)
                if type(t) ~= "table" then
                    print("  " .. label .. ": " .. tostring(t))
                    return
                end
                local parts = {}
                for k, v in pairs(t) do
                    if type(v) ~= "table" and type(v) ~= "function" then
                        parts[#parts + 1] = tostring(k) .. "=" .. (ns.Text(v) or "?")
                    end
                end
                table.sort(parts)
                print("  " .. label .. ": " .. table.concat(parts, ", "))
            end
            dump("first player's listing", info)
            dump("its player info", Call(list.GetSearchResultPlayerInfo, id, 1))
            dump("its member counts", Call(list.GetSearchResultMemberCounts, id))
            local p = ns.LFGPlayer(id)
            print(string.format("  read as: class=%s level=%s roles=%s",
                tostring(p.class), tostring(p.level),
                (function() local r = {} for k in pairs(p.roles) do r[#r + 1] = k end return table.concat(r, "/") end)()))
            return
        end
    end
    print("  no individual players in the current results to show")
end
