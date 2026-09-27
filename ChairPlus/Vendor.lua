-- ChairPlus Vendor.lua
-- Sell grey items and repair gear on arriving at a merchant.
--
-- Holding shift as you open a merchant suppresses both, which is the escape
-- hatch for the trip where you meant to keep something.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

local vendorFrame
local selling = false
local sellPass = 0
local sellTotal = 0
local sellCounted = {}

-- Whether we are at a merchant, tracked from the events rather than read off
-- the frame. See MerchantOpen below -- this is the fix for the bug where
-- nothing was ever sold.
local merchantOpen = false
local repairedThisVisit = false
local lastSellError = nil

-- Passes, not a single sweep. Selling is a server round trip per item: the
-- request goes out, the slot locks, and the bag only reflects it a moment
-- later. One walk of the bags issues every sale it can see and then has to
-- come back to find out which of them actually took.
local SELL_INTERVAL = 0.3
local SELL_MAX_PASSES = 40

-- The merchant's buyback holds the last twelve things sold. Selling more in
-- one visit pushes the first ones out for good, so a visit stops at twelve:
-- whatever was sold by mistake can still be bought back. The rest waits for
-- the next visit.
local SELL_CAP = 12
local soldThisVisit = 0
local capped = false

-------------------------------------------------------------------------------
-- Bag reading
-------------------------------------------------------------------------------

-- The container API changed shape between the clients in the TOC: newer ones
-- return one table, older ones return a flat tuple. Normalise to the fields
-- this file actually reads.
local function ItemInfo(bag, slot)
    local fn = ns.GetContainerItemInfo
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i, j = pcall(fn, bag, slot)
    if not ok or a == nil then return nil end
    if type(a) == "table" then
        return {
            quality    = ns.Num(a.quality),
            stackCount = ns.Num(a.stackCount) or 1,
            isLocked   = a.isLocked and true or false,
            hasNoValue = a.hasNoValue and true or false,
            itemID     = ns.Num(a.itemID),
            hyperlink  = ns.Text(a.hyperlink),
        }
    end
    -- icon, count, locked, quality, readable, lootable, link, filtered, noValue, itemID
    return {
        quality    = ns.Num(d),
        stackCount = ns.Num(b) or 1,
        isLocked   = c and true or false,
        hasNoValue = i and true or false,
        itemID     = ns.Num(j),
        hyperlink  = ns.Text(g),
    }
end

local function SellPrice(itemID, hyperlink)
    local fn = ns.GetItemInfo
    if type(fn) ~= "function" then return nil end
    local ok, price = pcall(function()
        return select(11, fn(hyperlink or itemID))
    end)
    if not ok then return nil end
    return ns.Num(price)
end

-- Weapon and armour only; everything else grey is vendor trash by definition.
local function IsGear(itemID, hyperlink)
    local fn = ns.GetItemInfo
    if type(fn) ~= "function" then return false end
    local ok, classID = pcall(function()
        return select(12, fn(hyperlink or itemID))
    end)
    if not ok then return false end
    classID = ns.Num(classID)
    local itemClass = _G.Enum and _G.Enum.ItemClass
    local weapon = itemClass and itemClass.Weapon or 2
    local armor = itemClass and itemClass.Armor or 4
    return classID == weapon or classID == armor
end

local function IsSoulbound(bag, slot)
    local C_Item = _G.C_Item
    local ItemLocation = _G.ItemLocation
    if not C_Item or type(C_Item.IsBound) ~= "function" or not ItemLocation then
        return nil
    end
    local ok, loc = pcall(ItemLocation.CreateFromBagAndSlot, bag, slot)
    if not ok or not loc then return nil end
    local okBound, bound = pcall(C_Item.IsBound, loc)
    if not okBound then return nil end
    return bound and true or false
end

-------------------------------------------------------------------------------
-- Selling
-------------------------------------------------------------------------------

local function StopSelling(report)
    if not selling then return end
    selling = false
    sellPass = 0

    if report and sellTotal > 0 and ns.Get("sellJunkSummary") then
        local text = nil
        if type(ns.GetCoinText) == "function" then
            local ok, coin = pcall(ns.GetCoinText, sellTotal)
            if ok then text = ns.Text(coin) end
        end
        ns.Print("Sold junk for", text or (sellTotal .. "c"),
            capped and "|cff888888(twelve, so all of it can still be bought back; talk to the merchant again for the rest)|r" or "")
    end

    sellTotal = 0
    soldThisVisit, capped = 0, false
    wipe(sellCounted)
    if ns.RefreshOSD then ns.RefreshOSD() end
end

-- The events, not the frame.
--
-- This used to read MerchantFrame:IsShown(), and that is why this module never
-- sold anything. MERCHANT_SHOW and MERCHANT_CLOSED are what actually bracket a
-- merchant visit; the frame being shown is a *side effect* of the first of
-- them, sequenced by whichever handler registered first. At the instant
-- MERCHANT_SHOW arrives the frame is not reliably up yet, so the very first
-- pass concluded the merchant had already gone and ended the job before it
-- began -- silently, because giving up is not an error.
--
-- Repair never had the problem because it only ever asked the API.
local function MerchantOpen()
    return merchantOpen
end
-- The same answer for Restock.lua.
ns.MerchantIsOpen = MerchantOpen

-- One sweep of the bags. Split out from SellPass so the whole body can be run
-- inside a pcall without the control flow around it also being protected.
-- Returns the number of sales issued.
local function SellSweep()
    local numSlots = ns.GetContainerNumSlots
    local useItem = ns.UseContainerItem
    if type(numSlots) ~= "function" or type(useItem) ~= "function" then
        -- No container API at all. Report it rather than spinning: a caller
        -- that gets nil back stops the job.
        return nil, "no container API on this client"
    end

    local sold = 0
    local keepGear = ns.Get("sellJunkKeepGear")

    for bag = 0, (ns.LAST_BAG or 4) do
        local okSlots, slots = pcall(numSlots, bag)
        slots = okSlots and (ns.Num(slots) or 0) or 0
        for slot = 1, slots do
            local info = ItemInfo(bag, slot)
            if info and info.quality == 0 and not info.hasNoValue and not info.isLocked then
                local skip = false

                if ns.blockedItems[info.itemID or -1] then
                    skip = true
                end

                -- Grey weapons and armour that are not soulbound can still be
                -- listed on the auction house, so there is a reason to hold
                -- them back. Soulbound ones have nowhere else to go.
                if not skip and keepGear and IsGear(info.itemID, info.hyperlink) then
                    if IsSoulbound(bag, slot) == false then skip = true end
                end

                if not skip then
                    -- Price is banked when the sale is issued, and each slot is
                    -- only banked once. A slot that shows up again on a later
                    -- pass did not sell, and counting it twice would report a
                    -- total that never arrived.
                    local tag = bag .. ":" .. slot .. ":" .. (info.itemID or 0)
                    if not sellCounted[tag] and soldThisVisit >= SELL_CAP then
                        capped = true
                        skip = true
                    end
                end

                if not skip then
                    local tag = bag .. ":" .. slot .. ":" .. (info.itemID or 0)
                    if not sellCounted[tag] then
                        sellCounted[tag] = true
                        soldThisVisit = soldThisVisit + 1
                        local price = SellPrice(info.itemID, info.hyperlink)
                        if price then
                            sellTotal = sellTotal + (price * (info.stackCount or 1))
                        end
                    end
                    pcall(useItem, bag, slot)
                    sold = sold + 1
                end
            end
        end
    end

    -- Counting the pass is the caller's job. A sweep that throws must not have
    -- advanced anything.
    return sold
end

-- The control flow around one sweep, and the only place `selling` is allowed
-- to survive a return.
--
-- The sweep runs inside a pcall because an error used to be permanent: the
-- throw skipped the cleanup *and* skipped scheduling the next pass, leaving
-- `selling` true forever. Every later merchant visit then returned instantly
-- at the guard in StartSelling, and since script errors are off by default on
-- this client it looked exactly like the feature being switched off.
local function SellPass()
    if not selling then return end

    -- Walking away mid-sale is not an error, it just ends the job.
    if not MerchantOpen() then
        StopSelling(true)
        return
    end

    local ok, sold, why = pcall(SellSweep)

    if not ok then
        lastSellError = ns.Text(sold) or "unknown error"
        StopSelling(false)
        ns.Print("|cffff5555Selling stopped:|r", lastSellError)
        return
    end

    if sold == nil then
        StopSelling(false)
        lastSellError = ns.Text(why) or "sweep declined"
        return
    end

    sellPass = sellPass + 1

    if sold == 0 or sellPass >= SELL_MAX_PASSES then
        StopSelling(true)
        return
    end

    ns.After(SELL_INTERVAL, SellPass)
end

local function StartSelling()
    if selling then return end
    selling = true
    sellPass = 0
    sellTotal = 0
    soldThisVisit, capped = 0, false
    lastSellError = nil
    wipe(sellCounted)
    -- Deferred, never immediate. Called straight from the MERCHANT_SHOW
    -- handler the first pass runs before the merchant is really open, which is
    -- the other half of the bug documented on MerchantOpen.
    ns.After(SELL_INTERVAL, SellPass)
end

-------------------------------------------------------------------------------
-- Repair
-------------------------------------------------------------------------------

local REPAIR_CHECK_INTERVAL = 0.3
local REPAIR_CHECKS = 6

-- Said only if something was actually repaired. None of the repair calls
-- says whether it worked, and the cost read straight after them is still the
-- old one: the server has not answered yet. So it is read again a little
-- later, a few times, before anything is said.
local function ConfirmRepair(cost, usedGuild, tries)
    -- Once the merchant is gone the cost cannot be trusted either way.
    if not merchantOpen then return end
    local okAfter, left = pcall(_G.GetRepairAllCost)
    left = okAfter and ns.Num(left) or cost
    if left >= cost then
        if tries < REPAIR_CHECKS then
            ns.After(REPAIR_CHECK_INTERVAL, function() ConfirmRepair(cost, usedGuild, tries + 1) end)
        elseif ns.Get("repairSummary") then
            ns.Print("|cffff5555Could not repair:|r not enough gold" .. (usedGuild and " or guild funds." or "."))
        end
        return
    end
    cost = cost - left

    if ns.Get("repairSummary") then
        local text = nil
        if type(ns.GetCoinText) == "function" then
            local okCoin, coin = pcall(ns.GetCoinText, cost)
            if okCoin then text = ns.Text(coin) end
        end
        ns.Print("Repaired for", text or (cost .. "c"),
            usedGuild and "|cff888888(guild funds first)|r" or "")
    end

    if ns.RefreshOSD then ns.RefreshOSD() end
end

local function DoRepair()
    local canRepair = _G.CanMerchantRepair
    if type(canRepair) ~= "function" then return end
    local ok, merchantRepairs = pcall(canRepair)
    if not ok or not merchantRepairs then return end

    local getCost = _G.GetRepairAllCost
    if type(getCost) ~= "function" then return end
    local okCost, cost, canAfford = pcall(getCost)
    if not okCost then return end
    cost = ns.Num(cost) or 0
    if cost <= 0 then return end

    local repairAll = _G.RepairAllItems
    if type(repairAll) ~= "function" then return end

    local usedGuild = false
    if ns.Get("repairGuildFunds") and _G.IsInGuild and IsInGuild() then
        local okGuild, guildAllowed = pcall(function()
            return _G.CanGuildBankRepair and CanGuildBankRepair()
        end)
        if okGuild and guildAllowed then
            -- Try guild funds, then fall through to personal gold. The second
            -- call is not redundant: the first silently does nothing once the
            -- guild daily limit is reached, and there is no return value that
            -- says so.
            pcall(repairAll, 1)
            usedGuild = true
        end
    end
    -- Personal gold only if it covers the bill: guild funds were tried
    -- first, and short of gold the guild is the only way this repair happens
    -- (it used to stop before asking the guild at all).
    if canAfford then pcall(repairAll) end

    ns.After(REPAIR_CHECK_INTERVAL, function() ConfirmRepair(cost, usedGuild, 1) end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function OnEvent(_, event)
    if event == "MERCHANT_SHOW" then
        -- Set before anything else reads it. Everything downstream decides
        -- whether the merchant is open by asking this, not the frame.
        merchantOpen = true

        if _G.IsShiftKeyDown and IsShiftKeyDown() then return end

        -- Once per visit. MERCHANT_SHOW can arrive more than once for a single
        -- merchant, and a second repair is a second bill.
        if ns.Get("repairGear") and not repairedThisVisit then
            repairedThisVisit = true
            local ok, err = pcall(DoRepair)
            if not ok then ns.Print("|cffff5555Repair failed:|r", ns.Text(err)) end
        end

        if ns.Get("sellJunk") then StartSelling() end

        -- Restock last, a moment later: after the junk has started going
        -- and the repair is paid, so its gold floor sees the money you have.
        if ns.Get("restock") and ns.StartRestock then
            ns.After(1, function()
                if merchantOpen then pcall(ns.StartRestock) end
            end)
        end

    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        repairedThisVisit = false
        StopSelling(true)
        if ns.StopRestock then pcall(ns.StopRestock) end
    end
end


-------------------------------------------------------------------------------
-- Modules
-------------------------------------------------------------------------------

-- Both features hang off the same two events, so they share one frame and the
-- frame stays registered while either is on.
local function UpdateRegistration()
    if not vendorFrame then
        vendorFrame = CreateFrame("Frame")
        vendorFrame:SetScript("OnEvent", OnEvent)
    end
    if ns.Get("sellJunk") or ns.Get("repairGear") or ns.Get("restock") then
        vendorFrame:RegisterEvent("MERCHANT_SHOW")
        vendorFrame:RegisterEvent("MERCHANT_CLOSED")
    else
        vendorFrame:UnregisterAllEvents()
    end
end

ns.RegisterModule("sellJunk", {
    title = "Sell junk automatically",
    desc = "Sell every gray item when you open a merchant.",
    Apply = function(enabled)
        if not enabled then StopSelling(false) end
        UpdateRegistration()
    end,
})

ns.RegisterModule("repairGear", {
    title = "Repair automatically",
    desc = "Repair on opening a merchant that can.",
    Apply = UpdateRegistration,
})
