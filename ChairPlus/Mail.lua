-- ChairPlus Mail.lua
-- Small automations, each its own switch, all off out of the box:
--
--   open all mail      a button on the inbox that takes every letter's gold
--                      and items, skipping cash-on-delivery and GM mail, and
--                      stopping when the bags are full
--   battleground release   release your spirit on dying in a battleground,
--                      unless you could come back where you fell
--   skip cinematics    the in-game cutscenes (not pre-rendered movies)
--   dismount and stand     on the "You are mounted" and "You must be
--                      standing" errors, out of combat, and on opening the
--                      flight map
--
-- Holding shift leaves each of them to you. Every call is a client function
-- (TakeInboxMoney, RepopMe, StopCinematic, Dismount...), looked up when used:
-- nothing of Blizzard's own interface is made to run from here.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local function Shift()
    local ok, down = pcall(_G.IsShiftKeyDown)
    return ok and ns.Bool(down) == true
end

local function Locked()
    local ok, locked = pcall(_G.InCombatLockdown)
    return ok and ns.Bool(locked) == true
end

local function Call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

-------------------------------------------------------------------------------
-- Open all mail
-------------------------------------------------------------------------------

local opening = false
local taken = { money = 0, items = 0 }
local STEP = 0.35
-- A take is only a request: the server can refuse it (a unique item you
-- already carry, gold over the cap) and say nothing to us. So the last one
-- asked for waits in `pending` and is counted only once it has left the
-- inbox; one that has not left after a few looks goes into `refused` and is
-- not asked for again.
local pending
local refused = {}
local SETTLE_LOOKS = 3
local steps = 0
local MAX_STEPS = 200

local function BagsFull()
    if not ns.FreeBagSlots then return false end
    local ok, free, _, _, total = pcall(ns.FreeBagSlots)
    return ok and free ~= nil and (total or 0) > 0 and free <= 0
end

local function Finish(reason)
    opening = false
    pending = nil
    wipe(refused)
    local parts = {}
    if taken.money > 0 then
        local text = tostring(taken.money) .. "c"
        if type(ns.GetCoinText) == "function" then
            local ok, coin = pcall(ns.GetCoinText, taken.money)
            if ok and ns.Text(coin) then text = ns.Text(coin) end
        end
        parts[#parts + 1] = text
    end
    if taken.items > 0 then parts[#parts + 1] = taken.items .. " item" .. (taken.items == 1 and "" or "s") end
    if #parts > 0 then
        ns.Print("Took " .. table.concat(parts, " and ") .. " from the mail" .. (reason and (" -- " .. reason) or "") .. ".")
    elseif reason then
        ns.Print("Mail: " .. reason .. ".")
    end
end

local function InboxCount()
    local ok, count = pcall(_G.GetInboxNumItems)
    return ok and ns.Num(count) or 0
end

-- A letter by what it says rather than where it sits: the list closes up as
-- emptied letters go, so an index from one step is not the same letter the
-- next.
local function Header(index)
    local ok, _, _, sender, subject, money, cod, daysLeft, itemCount, _, _, _, _, isGM = pcall(_G.GetInboxHeaderInfo, index)
    if not ok then return nil end
    return {
        key = tostring(ns.Text(sender) or "") .. "\0" .. tostring(ns.Text(subject) or "")
            .. "\0" .. tostring(ns.Num(daysLeft) or ""),
        money = ns.Num(money) or 0,
        cod = ns.Num(cod) or 0,
        itemCount = ns.Num(itemCount) or 0,
        isGM = ns.Bool(isGM),
    }
end

local function ItemName(index, attachment)
    local ok, name = pcall(_G.GetInboxItem, index, attachment)
    return ok and ns.Text(name) or nil
end

-- Whether the last take is still sitting in the inbox.
local function StillThere(p)
    for index = 1, InboxCount() do
        local header = Header(index)
        if header and header.key == p.key then
            if p.attachment then
                if ItemName(index, p.attachment) == p.name then return true end
            elseif header.money > 0 then
                return true
            end
        end
    end
    return false
end

-- Counts the last take if it went. Returns true while it is still worth
-- waiting for.
local function Settle()
    local p = pending
    if not p then return false end
    if StillThere(p) then
        p.looks = p.looks + 1
        if p.looks < SETTLE_LOOKS then return true end
        refused[p.key .. "\0" .. (p.attachment or "money")] = true
    elseif p.attachment then
        taken.items = taken.items + 1
    else
        taken.money = taken.money + p.money
    end
    pending = nil
    return false
end

-- One letter's worth: its gold, or one attachment. Returns whether it asked.
local function TakeOne()
    for index = InboxCount(), 1, -1 do
        local header = Header(index)
        if header and header.cod == 0 and not header.isGM then
            local key = header.key
            if header.money > 0 and not refused[key .. "\0money"] then
                if Call("TakeInboxMoney", index) then
                    pending = { key = key, money = header.money, looks = 0 }
                    return true
                end
            elseif header.itemCount > 0 then
                for attachment = 1, 16 do
                    local name = ItemName(index, attachment)
                    if name and not refused[key .. "\0" .. attachment] then
                        if BagsFull() then return false, "your bags are full" end
                        if Call("TakeInboxItem", index, attachment) then
                            pending = { key = key, attachment = attachment, name = name, looks = 0 }
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function Step()
    if not opening then return end
    steps = steps + 1
    if steps > MAX_STEPS then
        Settle()
        return Finish("stopped")
    end
    if Settle() then return ns.After(STEP, Step) end
    local acted, why = TakeOne()
    if acted then
        ns.After(STEP, Step)
    else
        Finish(why)
    end
end

function ns.OpenAllMail()
    if opening then return end
    opening = true
    taken.money, taken.items = 0, 0
    pending, steps = nil, 0
    wipe(refused)
    Step()
end

local mailButton
local function MailButton()
    local inbox = _G.InboxFrame
    if mailButton or type(inbox) ~= "table" then return mailButton end
    mailButton = CreateFrame("Button", "ChairPlusOpenAllMail", inbox, "UIPanelButtonTemplate")
    mailButton:SetSize(90, 22)
    mailButton:SetText("Open all")
    mailButton:SetPoint("TOPRIGHT", inbox, "TOPRIGHT", -60, -40)
    mailButton:SetScript("OnClick", function() ns.OpenAllMail() end)
    mailButton:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:AddLine("Open all", 1, 0.82, 0)
        tip:AddLine("Takes every letter's gold and items. Cash-on-delivery and GM mail are left; "
            .. "it stops when your bags are full.", 1, 1, 1, true)
        tip:Show()
    end)
    mailButton:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    return mailButton
end

-------------------------------------------------------------------------------
-- The rest
-------------------------------------------------------------------------------

-- Error strings, the client's own so any language matches.
local MOUNTED = { "ERR_ATTACK_MOUNTED", "ERR_NOT_WHILE_MOUNTED", "SPELL_FAILED_NOT_MOUNTED",
                  "ERR_TAXIPLAYERALREADYMOUNTED", "ERR_MOUNT_SHAPESHIFTED" }
local STANDING = { "ERR_CANTATTACK_NOTSTANDING", "SPELL_FAILED_NOT_STANDING", "ERR_LOOT_NOTSTANDING" }
local function Matches(message, list)
    local text = ns.Text(message)
    if not text then return false end
    for _, key in ipairs(list) do
        if ns.Text(_G[key]) == text then return true end
    end
    return false
end
ns.MailMatchesError = Matches

local driver

local function OnEvent(_, event, a, b)
    if event == "MAIL_SHOW" then
        local button = MailButton()
        if button then button:SetShown(ns.IsEnabled("mailOpenAll")) end
    elseif event == "MAIL_CLOSED" then
        if opening then Finish() end
    elseif event == "PLAYER_DEAD" then
        if not ns.IsEnabled("autoReleaseBG") or Shift() then return end
        local ok, inside, kind = pcall(_G.IsInInstance)
        if not (ok and inside and kind == "pvp") then return end
        -- A soulstone or reincarnation brings you back where you fell:
        -- worth more than a run from the graveyard.
        local okS, self = pcall(_G.HasSoulstone)
        if okS and ns.Text(self) then return end
        Call("RepopMe")
    elseif event == "CINEMATIC_START" then
        if not ns.IsEnabled("skipCinematics") or Shift() then return end
        Call("StopCinematic")
    elseif event == "UI_ERROR_MESSAGE" then
        if not ns.IsEnabled("autoDismount") or Locked() then return end
        local message = (type(b) == "string" and b) or a
        if Matches(message, MOUNTED) then
            Call("Dismount")
        elseif Matches(message, STANDING) then
            Call("DoEmote", "STAND")
        end
    elseif event == "TAXIMAP_OPENED" then
        if not ns.IsEnabled("autoDismount") or Locked() then return end
        local ok, mounted = pcall(_G.IsMounted)
        if ok and ns.Bool(mounted) then Call("Dismount") end
    end
end

local EVENTS = {
    mailOpenAll = { "MAIL_SHOW", "MAIL_CLOSED" },
    autoReleaseBG = { "PLAYER_DEAD" },
    skipCinematics = { "CINEMATIC_START" },
    autoDismount = { "UI_ERROR_MESSAGE", "TAXIMAP_OPENED" },
}

local function ApplyAll()
    if not driver then
        driver = CreateFrame("Frame")
        driver:SetScript("OnEvent", OnEvent)
    end
    pcall(driver.UnregisterAllEvents, driver)
    for key, events in pairs(EVENTS) do
        if ns.IsEnabled(key) then
            for _, event in ipairs(events) do pcall(driver.RegisterEvent, driver, event) end
        end
    end
    if mailButton then mailButton:SetShown(ns.IsEnabled("mailOpenAll")) end
end

ns.RegisterModule("mailOpenAll", {
    title = "Open all mail",
    desc = "A button on the inbox that takes every letter's gold and items, skipping cash-on-delivery and GM mail.",
    Apply = ApplyAll,
})
ns.RegisterModule("autoReleaseBG", {
    title = "Release in battlegrounds",
    desc = "Release your spirit on dying in a battleground, unless you can come back where you fell. Hold shift to stay.",
    Apply = ApplyAll,
})
ns.RegisterModule("skipCinematics", {
    title = "Skip cinematics",
    desc = "Skip the in-game cutscenes. Hold shift when one starts to watch it.",
    Apply = ApplyAll,
})
ns.RegisterModule("autoDismount", {
    title = "Dismount and stand when needed",
    desc = "On \"You are mounted\" or \"You must be standing\", dismount or stand up, out of combat. Also dismounts when you open the flight map.",
    Apply = ApplyAll,
})
