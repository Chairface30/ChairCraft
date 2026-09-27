-- ChairPlus Restock.lua
-- At a merchant, buy back up to a count you set of the things you run
-- through: ammo, reagents, food and water. Per character, off out of the box.
--
--   the list      "itemID:count" pairs in one setting (restockList), so it is
--                 per character and travels with backups and "copy settings"
--                 like every other setting
--   buying        for each item on the list the merchant sells for gold, one
--                 lot at a time (the merchant's own lot size: arrows by the
--                 200, water by the 5), a few lots per pass, until you hold
--                 the count. Never past the per-visit spending cap, never
--                 below the gold floor, and it stops the moment the merchant
--                 closes or a purchase stops arriving (full bags)
--   report        one line in chat of what was bought and what it cost
--
-- Holding shift when the merchant opens leaves it to you, as with junk and
-- repair. Items that cost anything but gold (tokens, honor) are never bought.
-- Every call is a client function looked up when used, inside a pcall; the
-- merchant's own frame is never touched.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local PASS = 0.3          -- seconds between passes
local LOTS_PER_PASS = 4
local STALL_PASSES = 3    -- passes with nothing arriving before an item is given up

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

-- { { id = 2512, count = 200 }, ... } in the order they were added.
function ns.RestockList()
    local out = {}
    for id, count in tostring(ns.Get("restockList") or ""):gmatch("(%d+):(%d+)") do
        id, count = tonumber(id), tonumber(count)
        if id and count and count > 0 then out[#out + 1] = { id = id, count = count } end
    end
    return out
end

local function Save(list)
    local parts = {}
    for _, entry in ipairs(list) do
        parts[#parts + 1] = entry.id .. ":" .. math.floor(entry.count)
    end
    ns.Set("restockList", table.concat(parts, ","))
    if ns.RefreshRestockPanel then ns.RefreshRestockPanel() end
end

-- Adds an item or changes its count. Returns false and why for a bad one.
function ns.SetRestock(id, count)
    id, count = tonumber(id), tonumber(count)
    if not id or id <= 0 then return false, "that is not an item" end
    count = math.floor(count or 0)
    if count < 1 or count > 5000 then return false, "the count must be 1 to 5000" end
    local list = ns.RestockList()
    for _, entry in ipairs(list) do
        if entry.id == id then
            entry.count = count
            Save(list)
            return true
        end
    end
    list[#list + 1] = { id = id, count = count }
    Save(list)
    return true
end

function ns.RemoveRestock(id)
    id = tonumber(id)
    local list = ns.RestockList()
    for i, entry in ipairs(list) do
        if entry.id == id then
            table.remove(list, i)
            Save(list)
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Reading the client
-------------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return select(2, unpack(results))
end

function ns.ItemName(id)
    local C = _G.C_Item
    local name = ns.Text(Call(C and C.GetItemNameByID, id))
        or ns.Text(Call(ns.GetItemInfo, id))
    return name or ("item " .. tostring(id))
end

local function Owned(id)
    return ns.Num(Call(ns.GetItemCount, id)) or 0
end

local function Money()
    return ns.Num(Call(_G.GetMoney)) or 0
end

-- What the merchant's slot sells: its item, the price of one lot, the lot
-- size, how many lots are left (-1: no limit), and whether it takes gold only.
local function MerchantSlot(index)
    local id = ns.Num(Call(_G.GetMerchantItemID, index))
    if not id then
        local link = ns.Text(Call(_G.GetMerchantItemLink, index))
        id = link and tonumber(link:match("item:(%d+)"))
    end
    local mf = _G.C_MerchantFrame
    local info = mf and Call(mf.GetItemInfo, index)
    local price, stack, available, purchasable, extended
    if type(info) == "table" then
        price, stack, available = ns.Num(info.price), ns.Num(info.stackCount), ns.Num(info.numAvailable)
        purchasable, extended = info.isPurchasable, info.hasExtendedCost
    else
        local _, _, p, q, n, buyable, _, ext = Call(_G.GetMerchantItemInfo, index)
        price, stack, available, purchasable, extended = ns.Num(p), ns.Num(q), ns.Num(n), buyable, ext
    end
    if not (id and price) then return nil end
    return {
        index = index, id = id, price = price, stack = math.max(1, stack or 1),
        available = available or -1,
        goldOnly = not ns.Bool(extended) and ns.Bool(purchasable) ~= false,
    }
end

-- The merchant's goods, by item ID.
function ns.MerchantGoods()
    local out = {}
    local count = ns.Num(Call(_G.GetMerchantNumItems)) or 0
    for index = 1, count do
        local slot = MerchantSlot(index)
        if slot and not out[slot.id] then out[slot.id] = slot end
    end
    return out
end

-------------------------------------------------------------------------------
-- Buying
-------------------------------------------------------------------------------

local run  -- the visit in progress, or nil

local function Coins(copper)
    if type(ns.GetCoinText) == "function" then
        local ok, text = pcall(ns.GetCoinText, copper)
        if ok and ns.Text(text) then return ns.Text(text) end
    end
    return tostring(copper) .. "c"
end

local function Finish(why)
    local r = run
    run = nil
    if not r then return end
    local parts = {}
    for _, item in ipairs(r.items) do
        local got = Owned(item.id) - item.startOwned
        if got > 0 then parts[#parts + 1] = got .. " " .. ns.ItemName(item.id) end
    end
    if #parts > 0 and ns.Get("restockSummary") then
        ns.Print("Restocked: " .. table.concat(parts, ", ") .. " (" .. Coins(r.spent) .. ")"
            .. (why and (" -- " .. why) or "") .. ".")
    elseif why and ns.Get("restockSummary") then
        ns.Print("Restock: " .. why .. ".")
    end
end

local function Pass()
    local r = run
    if not r then return end
    if not ns.MerchantIsOpen() then return Finish() end

    local capCopper = (ns.Num(ns.Get("restockCap")) or 0) * 10000
    local floorCopper = (ns.Num(ns.Get("restockFloor")) or 0) * 10000
    local boughtAny, stoppedBy = false, nil
    local lots = LOTS_PER_PASS

    for _, item in ipairs(r.items) do
        if not item.done then
            -- What has been bought but not yet seen in the bags counts
            -- toward the count, so a slow server never gets a second order
            -- for the same arrows. While lots are still on their way nothing
            -- more is bought; if they never arrive (bags full), it gives up.
            local owned = Owned(item.id)
            local arrived = owned - item.lastOwned
            if arrived > 0 then
                item.inFlight = math.max(0, item.inFlight - arrived)
                item.lastOwned, item.stalled = owned, 0
            elseif item.inFlight > 0 then
                item.stalled = item.stalled + 1
                if item.stalled >= STALL_PASSES then item.done, stoppedBy = true, "your bags are full" end
            end
            local need = item.count - owned - item.inFlight
            if need <= 0 and item.inFlight == 0 then item.done = true end
            local waiting = item.inFlight > 0 and arrived <= 0
            while not item.done and not waiting and lots > 0 and need > 0 do
                local slot = item.slot
                if slot.available == 0 then item.done = true break end
                if capCopper > 0 and r.spent + slot.price > capCopper then
                    item.done, stoppedBy = true, "the spending limit for one visit is reached"
                    break
                end
                if Money() - slot.price < floorCopper then
                    item.done, stoppedBy = true, "buying more would take you under your gold floor"
                    break
                end
                local ok = pcall(_G.BuyMerchantItem, slot.index)
                if not ok then item.done = true break end
                r.spent = r.spent + slot.price
                item.inFlight = item.inFlight + slot.stack
                if slot.available > 0 then slot.available = slot.available - 1 end
                need = need - slot.stack
                lots = lots - 1
                boughtAny = true
            end
        end
    end
    r.stoppedBy = r.stoppedBy or stoppedBy

    local open = false
    for _, item in ipairs(r.items) do
        if not item.done then open = true end
    end
    -- One more pass after the last purchase, so what it brought is counted.
    if open or boughtAny then
        ns.After(PASS, Pass)
    else
        Finish(r.stoppedBy)
    end
end

-- Called by Vendor.lua when a merchant opens. Returns whether it started.
function ns.StartRestock()
    if run or not ns.Get("restock") then return false end
    local goods = ns.MerchantGoods()
    local items = {}
    for _, entry in ipairs(ns.RestockList()) do
        local slot = goods[entry.id]
        local owned = Owned(entry.id)
        if slot and slot.goldOnly and owned < entry.count then
            items[#items + 1] = { id = entry.id, count = entry.count, slot = slot,
                                  startOwned = owned, lastOwned = owned, stalled = 0, inFlight = 0 }
        end
    end
    if #items == 0 then return false end
    run = { items = items, spent = 0 }
    ns.After(PASS, Pass)
    return true
end

function ns.StopRestock()
    if run then Finish() end
end

-------------------------------------------------------------------------------
-- Suggestions for the list
-------------------------------------------------------------------------------
-- At a merchant: what is in your bags that this merchant sells (ammo,
-- reagents, food, water, whatever you carry). Anywhere: the ammo you have
-- equipped. Things already on the list are left out.

function ns.RestockSuggestions()
    local listed, out, seen = {}, {}, {}
    for _, entry in ipairs(ns.RestockList()) do listed[entry.id] = true end
    local function Offer(id, why)
        if id and not listed[id] and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, why = why, have = Owned(id) }
        end
    end
    local ammo = ns.Num(Call(_G.GetInventoryItemID, "player", 0))
    if ammo then Offer(ammo, "your ammo") end
    if ns.MerchantIsOpen() then
        local goods = ns.MerchantGoods()
        for bag = 0, ns.LAST_BAG do
            local slots = ns.Num(Call(ns.GetContainerNumSlots, bag)) or 0
            for slot = 1, slots do
                local info = Call(ns.GetContainerItemInfo, bag, slot)
                local id = type(info) == "table" and ns.Num(info.itemID) or nil
                if id and goods[id] and goods[id].goldOnly then Offer(id, "sold here") end
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------
-- Hangs off the menu's right edge like the keyword window: the list with
-- a count box and a remove button each, suggestions to add with one click,
-- and a box for an item ID.

local window
local LIST_ROWS, SUGGEST_ROWS = 8, 5

local function Box(parent, width, numeric)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlight")
    box:SetTextInsets(6, 6, 0, 0)
    if numeric then box:SetNumeric(true) box:SetMaxLetters(5) end
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.08)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

function ns.RefreshRestockPanel()
    if not (window and window:IsShown()) then return end
    local list = ns.RestockList()
    for i, row in ipairs(window.rows) do
        local entry = list[i]
        row.entry = entry
        row.name:SetShown(entry ~= nil)
        row.count:SetShown(entry ~= nil)
        row.remove:SetShown(entry ~= nil)
        if entry then
            row.name:SetText(ns.ItemName(entry.id) .. " |cff808080(" .. Owned(entry.id) .. ")|r")
            if not row.count:HasFocus() then row.count:SetText(tostring(entry.count)) end
        end
    end
    window.empty:SetShown(#list == 0)
    window.more:SetText(#list > LIST_ROWS and ("and " .. (#list - LIST_ROWS) .. " more") or "")

    local suggestions = ns.RestockSuggestions()
    for i, row in ipairs(window.suggest) do
        local s = suggestions[i]
        row.suggestion = s
        row.add:SetShown(s ~= nil)
        row.name:SetShown(s ~= nil)
        if s then
            row.name:SetText(ns.ItemName(s.id) .. " |cff808080(" .. s.why .. ", you have " .. s.have .. ")|r")
        end
    end
    window.noSuggest:SetShown(#suggestions == 0)
    window.showIDs:SetChecked(ns.Get("tooltipExtras") == true and ns.Get("tooltipIDs") == true)
end

local function Build(menu)
    if window then return window end
    local MakeButton = ns.MakeButton
    window = CreateFrame("Frame", "ChairPlusRestockPanel", menu or UIParent)
    window:SetSize(320, 510)
    window:EnableMouse(true)
    window:SetScript("OnShow", function() ns.RefreshRestockPanel() end)
    if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "ChairPlusRestockPanel") end
    local bg = window:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.96)

    local title = window:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("|cff9d7cffRestock|r")
    local close = MakeButton(window, 22, "x")
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetScript("OnClick", function() window:Hide() end)

    local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -40)
    hint:SetWidth(290)
    hint:SetJustifyH("LEFT")
    hint:SetText("Bought up to the count at any merchant that sells it. (You have) is in your bags now.")

    window.rows = {}
    local y = -70
    for i = 1, LIST_ROWS do
        local row = {}
        row.remove = MakeButton(window, 22, "x")
        row.remove:SetPoint("TOPLEFT", 14, y)
        row.name = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.remove, "RIGHT", 6, 0)
        row.name:SetWidth(200)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.count = Box(window, 56, true)
        row.count:SetPoint("TOPRIGHT", -14, y - 1)
        row.remove:SetScript("OnClick", function()
            if row.entry then ns.RemoveRestock(row.entry.id) end
        end)
        local function SaveCount(self)
            if row.entry then
                local ok, why = ns.SetRestock(row.entry.id, tonumber(self:GetText()))
                if not ok then ns.Print("Restock: " .. why .. ".") end
            end
            self:ClearFocus()
        end
        row.count:SetScript("OnEnterPressed", SaveCount)
        window.rows[i] = row
        y = y - 24
    end
    window.empty = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    window.empty:SetPoint("TOPLEFT", 16, -74)
    window.empty:SetText("Nothing yet: add something below.")
    window.more = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    window.more:SetPoint("TOPLEFT", 16, y - 2)

    local suggestHead = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    suggestHead:SetPoint("TOPLEFT", 16, y - 22)
    suggestHead:SetText("Add")
    y = y - 44
    window.suggest = {}
    for i = 1, SUGGEST_ROWS do
        local row = {}
        row.add = MakeButton(window, 40, "Add")
        row.add:SetPoint("TOPLEFT", 14, y)
        row.name = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.add, "RIGHT", 6, 0)
        row.name:SetWidth(240)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.add:SetScript("OnClick", function()
            local s = row.suggestion
            if s then
                -- A lot's worth over what you carry now, as a starting count.
                ns.SetRestock(s.id, math.max(s.have, 20))
            end
        end)
        window.suggest[i] = row
        y = y - 24
    end
    window.noSuggest = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    window.noSuggest:SetPoint("TOPLEFT", 16, y + SUGGEST_ROWS * 24 - 2)
    window.noSuggest:SetWidth(290)
    window.noSuggest:SetJustifyH("LEFT")
    window.noSuggest:SetText("Open a merchant to see what in your bags they sell, or add an item ID below.")

    local idLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    idLabel:SetPoint("TOPLEFT", 16, y - 8)
    idLabel:SetText("Item ID")
    window.idBox = Box(window, 80, true)
    window.idBox:SetMaxLetters(7)
    window.idBox:SetPoint("LEFT", idLabel, "RIGHT", 8, 0)
    local countLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    countLabel:SetPoint("LEFT", window.idBox, "RIGHT", 10, 0)
    countLabel:SetText("count")
    window.countBox = Box(window, 56, true)
    window.countBox:SetPoint("LEFT", countLabel, "RIGHT", 8, 0)
    local function AddTyped()
        local ok, why = ns.SetRestock(tonumber(window.idBox:GetText()), tonumber(window.countBox:GetText()))
        if ok then
            window.idBox:SetText("")
            window.countBox:SetText("")
        else
            ns.Print("Restock: " .. why .. ".")
        end
    end
    window.idBox:SetScript("OnEnterPressed", AddTyped)
    window.countBox:SetScript("OnEnterPressed", AddTyped)
    local add = MakeButton(window, 50, "Add")
    add:SetPoint("LEFT", window.countBox, "RIGHT", 8, 0)
    add:SetScript("OnClick", AddTyped)
    window.addTyped = add

    -- The same switch as the menu's "Item and spell IDs", here because an
    -- item's ID is what the box above wants. It sits under Tooltip extras in
    -- the menu, so ticking it here turns that on too; unticking takes only
    -- the IDs off.
    local ids = ns.MakeCheckButton(window)
    ids:SetSize(22, 22)
    ids:SetPoint("TOPLEFT", idLabel, "BOTTOMLEFT", -4, -14)
    local idsLabel = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    idsLabel:SetPoint("LEFT", ids, "RIGHT", 2, 0)
    idsLabel:SetText("Show item IDs in tooltips")
    ids:SetScript("OnClick", function(self)
        if self:GetChecked() then
            ns.SetMany({ tooltipExtras = true, tooltipIDs = true })
        else
            ns.Set("tooltipIDs", false)
        end
        if ns.RefreshPanel then pcall(ns.RefreshPanel) end
        ns.RefreshRestockPanel()
    end)
    window.showIDs = ids

    window:Hide()
    return window
end

function ns.ToggleRestockPanel()
    local menu = _G.ChairPlusPanel
    if not (menu and menu:IsShown()) and ns.OpenPanel then
        pcall(ns.OpenPanel, "plus")
        menu = _G.ChairPlusPanel
    end
    Build(menu)
    if window:IsShown() then window:Hide() return end
    if menu then
        window:SetParent(menu)
        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", menu, "TOPRIGHT", 2, 0)
        pcall(window.SetFrameStrata, window, menu:GetFrameStrata())
        pcall(window.SetFrameLevel, window, (ns.Num(menu:GetFrameLevel()) or 1) + 5)
    end
    window:Show()
    ns.RefreshRestockPanel()
end

-- The window's list changes with what the merchant sells and what you carry.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MERCHANT_SHOW")
watcher:RegisterEvent("MERCHANT_CLOSED")
watcher:RegisterEvent("BAG_UPDATE_DELAYED")
watcher:SetScript("OnEvent", function()
    if ns.RefreshRestockPanel then pcall(ns.RefreshRestockPanel) end
end)
