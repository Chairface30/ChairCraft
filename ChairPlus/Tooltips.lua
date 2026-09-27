-- ChairPlus Tooltips.lua
-- A little more on tooltips:
--
--   sell price   what an item sells to a merchant for, which the classic
--                tooltip leaves out (a stack's worth for a stack in a bag)
--   IDs          the item's or spell's ID, for anyone writing auras or macros
--
-- Added after the client has drawn the tooltip, through its own post-call
-- hooks (TooltipDataProcessor) where the engine has them, or the tooltip's
-- OnTooltipSetItem/OnTooltipSetSpell scripts on an older one. Nothing of the
-- tooltip's own is made to run from here.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local hooked = false
local TIPS = {}   -- the tooltips we add to

local function Coins(copper)
    if type(ns.GetCoinText) == "function" then
        local ok, text = pcall(ns.GetCoinText, copper)
        if ok and ns.Text(text) then return ns.Text(text) end
    end
    return tostring(copper) .. "c"
end

-- The price the client already shows, where it does: nothing is added twice.
local function AlreadyPriced(tip)
    local name = tip.GetName and tip:GetName()
    local label = ns.Text(_G.SELL_PRICE)
    if not (name and label) then return false end
    for i = 1, 30 do
        local line = _G[name .. "TextLeft" .. i]
        if not line then break end
        local ok, text = pcall(line.GetText, line)
        text = ok and ns.Text(text)
        if text and text:find(label, 1, true) then return true end
    end
    return false
end

-- How many of the item the tooltip's owner is holding: a bag button knows.
local function OwnerCount(tip)
    local ok, owner = pcall(tip.GetOwner, tip)
    if not ok or type(owner) ~= "table" then return 1 end
    local count = ns.Num(owner.count) or ns.Num(owner.Count and owner.Count.GetText and tonumber(owner.Count:GetText()))
    return (count and count > 1) and count or 1
end

local function ItemLines(tip, itemID)
    itemID = ns.Num(itemID)
    if not itemID then return end
    if ns.Get("tooltipSellPrice") and not AlreadyPriced(tip) then
        local info = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
        local ok, price = pcall(function() return select(11, info(itemID)) end)
        price = ok and ns.Num(price) or nil
        if price and price > 0 then
            local count = OwnerCount(tip)
            local text = Coins(price * count)
            if count > 1 then text = text .. "  |cff888888(" .. count .. " x " .. Coins(price) .. ")|r" end
            tip:AddDoubleLine("Sells for", text, 1, 0.82, 0, 1, 1, 1)
        elseif price == 0 then
            tip:AddLine("Cannot be sold", 0.6, 0.6, 0.6)
        end
    end
    if ns.Get("tooltipIDs") then
        tip:AddDoubleLine("Item ID", tostring(itemID), 0.6, 0.6, 0.6, 1, 1, 1)
    end
    pcall(tip.Show, tip)
end

local function SpellLines(tip, spellID)
    spellID = ns.Num(spellID)
    if not spellID or not ns.Get("tooltipIDs") then return end
    tip:AddDoubleLine("Spell ID", tostring(spellID), 0.6, 0.6, 0.6, 1, 1, 1)
    pcall(tip.Show, tip)
end

local function Wanted(tip)
    return TIPS[tip] and ns.IsEnabled("tooltipExtras")
end

local function Hook()
    if hooked then return end
    hooked = true
    TIPS[_G.GameTooltip or false] = true
    TIPS[_G.ItemRefTooltip or false] = true
    TIPS[false] = nil

    local processor = _G.TooltipDataProcessor
    local kinds = _G.Enum and _G.Enum.TooltipDataType
    if processor and type(processor.AddTooltipPostCall) == "function" and kinds then
        pcall(processor.AddTooltipPostCall, kinds.Item, function(tip, data)
            if Wanted(tip) and type(data) == "table" then pcall(ItemLines, tip, data.id) end
        end)
        for _, kind in ipairs({ kinds.Spell, kinds.UnitAura }) do
            if kind then
                pcall(processor.AddTooltipPostCall, kind, function(tip, data)
                    if Wanted(tip) and type(data) == "table" then pcall(SpellLines, tip, data.id) end
                end)
            end
        end
        return
    end

    -- An older engine: the tooltip's own scripts say what it is showing.
    for tip in pairs(TIPS) do
        pcall(tip.HookScript, tip, "OnTooltipSetItem", function(self)
            if not Wanted(self) then return end
            local ok, _, link = pcall(self.GetItem, self)
            local id = ok and type(link) == "string" and tonumber(link:match("item:(%d+)"))
            pcall(ItemLines, self, id)
        end)
        pcall(tip.HookScript, tip, "OnTooltipSetSpell", function(self)
            if not Wanted(self) then return end
            local ok, _, id = pcall(self.GetSpell, self)
            pcall(SpellLines, self, ok and id)
        end)
    end
end

ns.RegisterModule("tooltipExtras", {
    title = "Tooltip extras",
    desc = "Sell prices and item and spell IDs on tooltips.",
    -- Hooks cannot be taken off, so switching off leaves them in place and
    -- they add nothing (Wanted checks the switch every time).
    Apply = function(enabled)
        if enabled then Hook() end
    end,
})
ns.TooltipItemLines = ItemLines
