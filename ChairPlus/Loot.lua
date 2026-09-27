-- ChairPlus Loot.lua
-- Faster auto loot.
--
-- The client's own auto loot walks the loot table on a timer of its own. This
-- takes the slots itself the moment LOOT_READY arrives, which is the whole
-- speed-up -- there is no setting that makes the built-in one faster.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

local lootFrame
local lastLoot = 0

-- Whether auto loot should be happening at all right now. This is the client's
-- own rule, and it has to be asked rather than assumed: the autoLootDefault
-- CVar sets the baseline and the auto-loot modifier key inverts it, so someone
-- holding that key is explicitly asking for the loot window and must get it.
local function ShouldAutoLoot()
    local getBool = _G.GetCVarBool
    local isModified = _G.IsModifiedClick
    if type(getBool) ~= "function" or type(isModified) ~= "function" then
        return false
    end
    local okDefault, autoLoot = pcall(getBool, "autoLootDefault")
    local okMod, modified = pcall(isModified, "AUTOLOOTTOGGLE")
    if not okDefault or not okMod then return false end
    return (autoLoot and true or false) ~= (modified and true or false)
end

local function FastLoot()
    local delay = ns.Num(ns.Get("fasterLootDelay")) or 0.3
    local now = ns.Num(GetTime()) or 0

    -- A throttle, not a timer. LOOT_READY can fire more than once for a single
    -- corpse, and taking the same slots twice in a frame is how items end up
    -- half-looted.
    if now - lastLoot < delay then return end
    lastLoot = now

    if not ShouldAutoLoot() then return end

    local getNum = _G.GetNumLootItems
    local lootSlot = _G.LootSlot
    if type(getNum) ~= "function" or type(lootSlot) ~= "function" then return end

    local okNum, count = pcall(getNum)
    count = okNum and (ns.Num(count) or 0) or 0

    -- Bags full: coin and currency still go (they take no slot), items are
    -- left in the window rather than tried one by one, each answered with
    -- "Inventory is full". Whatever might stack or fit a profession bag is
    -- the player's to pick.
    local full = false
    if ns.FreeBagSlots then
        -- Full means slots exist and none is free; no slots at all is a bag
        -- count this client did not give, not a full bag.
        local okFree, free, _, _, total = pcall(ns.FreeBagSlots)
        full = okFree and free ~= nil and (total or 0) > 0 and free <= 0
    end
    local slotType = _G.GetLootSlotType
    local lootTypes = _G.Enum and _G.Enum.LootSlotType
    local MONEY = lootTypes and lootTypes.Money or 2
    local CURRENCY = lootTypes and lootTypes.Currency or 3

    -- Backwards, because taking a slot renumbers the ones after it.
    for i = count, 1, -1 do
        local take = true
        if full then
            local okType, kind = pcall(slotType or function() return nil end, i)
            kind = okType and ns.Num(kind) or nil
            take = kind == MONEY or kind == CURRENCY
        end
        if take then pcall(lootSlot, i) end
    end

    lastLoot = ns.Num(GetTime()) or lastLoot
end

ns.RegisterModule("fasterLoot", {
    title = "Faster auto loot",
    desc = "Take the whole corpse as soon as the loot is ready.",
    Apply = function(enabled)
        if not lootFrame then
            lootFrame = CreateFrame("Frame")
            lootFrame:SetScript("OnEvent", FastLoot)
        end
        if enabled then
            lootFrame:RegisterEvent("LOOT_READY")
        else
            lootFrame:UnregisterAllEvents()
        end
    end,
})
