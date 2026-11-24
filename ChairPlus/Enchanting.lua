-- ChairPlus Enchanting.lua
-- Two helps for enchanting from the professions window (was Enchant Butter).
--
-- Replace: the "Replace X with Y?" question is moved so its Yes sits under
-- the mouse (click Enchant, click again in the same spot). Only that
-- question (REPLACE_TRADESKILL_ENCHANT), not the one for armor kits and oils
-- used from the bags. Hold shift to leave it where it is.
--
-- The dialog's Yes is never clicked from Lua. That was tried: the game
-- blocked ReplaceTradeskillEnchant(), and worse, running Blizzard's popup
-- code from addon code left the shared popup system tainted, so later
-- dialogs (the logout countdown's Exit Now / Cancel, the bank tab purchase)
-- were blocked too. Only anchors are touched here.
--
-- Nothing here sends a cast from Lua: a cast sent by addon code may raise
-- the question tainted, and then even your own click on Yes is blocked.
--
-- Enchant several times: Blizzard's window only offers a count for an enchant
-- whose target stacks (vellum). For any other target a count box and a button
-- sit where Blizzard's Create All would be. The button is a secure one
-- (SecureActionButtonTemplate, type "click"): each click presses Blizzard's
-- own Enchant button, or, while the replace question is up, its Yes. Click
-- the one spot (or a key with /click ChairCraftEnchantButton) until it is
-- done; it counts the casts that land and says when the count is reached.
-- The game wants a click (or key press) for every cast and every Yes; this
-- can't be made automatic.
--
-- Nothing of Blizzard's is replaced. The window's methods are only hooked
-- (hooksecurefunc) and read.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local POPUP = "REPLACE_TRADESKILL_ENCHANT"
local BUTTON_NAME = "ChairCraftEnchantButton"
local MAX_COUNT = 999

local replaceOn, queueOn = false, false
local hookedPopup = false
local lastPopup          -- for the probe: what happened to the last question
local run                -- { recipeID, total, done } while counting, or nil
local built, box, button
local buildWaiting       -- built after combat, if the window loaded during it
local driver

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function Method(obj, name, ...)
    if type(obj) ~= "table" then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return nil end
    return Call(fn, obj, ...)
end

local function InCombat()
    return _G.InCombatLockdown and _G.InCombatLockdown() and true or false
end

-------------------------------------------------------------------------------
-- The replace question
-------------------------------------------------------------------------------

local function FindDialog(which)
    local d = Call(_G.StaticPopup_FindVisible, which)
    if d then return d end
    for i = 1, (tonumber(_G.STATICPOPUP_NUMDIALOGS) or 4) do
        local f = _G["StaticPopup" .. i]
        if type(f) == "table" and f.which == which and Method(f, "IsShown") then return f end
    end
end

local function YesButton(d)
    local b = Method(d, "GetButton1") or Method(d, "GetButton", 1)
    if b then return b end
    if type(d.button1) == "table" then return d.button1 end
    if type(d.ButtonContainer) == "table" and type(d.ButtonContainer.Button1) == "table" then
        return d.ButtonContainer.Button1
    end
    local name = Method(d, "GetName")
    if name and type(_G[name .. "Button1"]) == "table" then return _G[name .. "Button1"] end
end

-- Move the question so its Yes is under the mouse. Only anchors change.
local function YesUnderMouse()
    if not replaceOn then return end
    local d = FindDialog(POPUP)
    if not d then return end
    if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then
        lastPopup = "left where it was (shift held)"
        return
    end
    local yes = YesButton(d)
    local cx, cy = Call(_G.GetCursorPosition)
    local dx, dy = Method(d, "GetCenter")
    local bx, by = Method(yes, "GetCenter")
    local scale = Method(d, "GetEffectiveScale")
    if not (yes and cx and dx and bx and scale and scale > 0) then
        lastPopup = "seen, but couldn't place it"
        return
    end
    -- The cursor is in screen pixels; the dialog's points are in its scale.
    local x, y = cx / scale + (dx - bx), cy / scale + (dy - by)
    local ok = pcall(d.ClearAllPoints, d) and pcall(d.SetPoint, d, "CENTER", _G.UIParent, "BOTTOMLEFT", x, y)
    lastPopup = ok and "Yes put under the mouse" or "seen, but couldn't move it"
end

-------------------------------------------------------------------------------
-- Enchant several times
-------------------------------------------------------------------------------

local function Page()
    local frame = _G.ProfessionsFrame
    return type(frame) == "table" and frame.CraftingPage or nil
end

local function Transaction(page)
    local form = page and page.SchematicForm
    return Method(form, "GetTransaction"), form
end

local function IsEnchant(transaction)
    local types = _G.Enum and _G.Enum.TradeskillRecipeType
    local enchant = type(types) == "table" and types.Enchant
    if enchant == nil then return false end
    if Method(transaction, "IsRecipeType", enchant) then return true end
    local info = Method(transaction, "GetRecipeSchematic")
    return type(info) == "table" and info.recipeType == enchant or false
end

local function Target(transaction)
    return Method(transaction, "GetEnchantAllocation")
end

local function RecipeID(transaction, form)
    local id = Method(transaction, "GetRecipeID")
    if not id then
        local info = Method(form, "GetRecipeInfo")
        id = type(info) == "table" and info.recipeID or nil
    end
    return ns.Num(id)
end

local function Count()
    local ok, text = false, nil
    if box then ok, text = pcall(box.GetText, box) end
    local n = math.floor(ok and tonumber(text or "") or 1)
    if n < 1 then n = 1 elseif n > MAX_COUNT then n = MAX_COUNT end
    return n
end

local Refresh

local function EndRun(message)
    if not run then return end
    run = nil
    if message then ns.Print(message) end
    Refresh()
end

Refresh = function()
    if not built then return end
    local page = Page()
    local show, enabled = false, false
    local transaction, form = Transaction(page)
    if queueOn and page and Method(page, "IsShown") then
        local blizzardCount = page.CreateMultipleInputBox
        if IsEnchant(transaction) and not (blizzardCount and Method(blizzardCount, "IsShown")) then
            show = true
            enabled = Target(transaction) ~= nil
                and (not page.CreateButton or Method(page.CreateButton, "IsEnabled") ~= false)
        end
    end
    -- A different enchant picked: the count starts over.
    if run and show and RecipeID(transaction, form) ~= run.recipeID then run = nil end
    if FindDialog(POPUP) then enabled = show end
    box:SetShown(show)
    if run then
        local left = run.total - run.done
        button:SetText(string.format(FindDialog(POPUP) and "Yes, replace (%d left)" or "Enchant (%d left)", left))
    else
        button:SetText("Enchant x" .. Count())
    end
    -- The button is a secure one: it can't be shown, hidden or switched
    -- during combat. It catches up when the fight ends.
    if InCombat() then return end
    button:SetShown(show)
    Method(button, "SetEnabled", enabled)
end

local function PreClick(self)
    if InCombat() then return end
    local page = Page()
    local d = FindDialog(POPUP)
    -- What this click presses: the question's Yes while it is up, otherwise
    -- Blizzard's own Enchant button.
    local target = d and YesButton(d) or (page and page.CreateButton)
    pcall(self.SetAttribute, self, "clickbutton", target)
    if not d and not run then
        local transaction, form = Transaction(page)
        local id = RecipeID(transaction, form)
        if id and Target(transaction) then run = { recipeID = id, total = Count(), done = 0 } end
    end
end

local function MakeWidget(kind, name, parent, template)
    local ok, f = pcall(CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    return CreateFrame(kind, name, parent)
end

local function Build()
    if built then return true end
    local page = Page()
    if not page then return false end
    if InCombat() then buildWaiting = true return false end
    buildWaiting = false
    button = MakeWidget("Button", BUTTON_NAME, page, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    button:SetSize(130, 22)
    local anchor = page.CreateButton
    if anchor then button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    else button:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -120, 8) end
    pcall(button.RegisterForClicks, button, "AnyUp", "AnyDown")
    pcall(button.SetAttribute, button, "type", "click")
    pcall(button.SetAttribute, button, "clickbutton", anchor)
    button:SetScript("PreClick", PreClick)
    button:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_TOP")
        tip:SetText("Enchant the same item again and again")
        tip:AddLine("Each click presses Enchant, or Yes when it asks to replace the enchant. "
            .. "Keep clicking here until the count is done. A key works too: a macro with "
            .. "/click " .. BUTTON_NAME, 1, 1, 1, true)
        tip:Show()
    end)
    button:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)

    box = MakeWidget("EditBox", nil, page, "InputBoxTemplate")
    box:SetSize(34, 20)
    box:SetPoint("RIGHT", button, "LEFT", -8, 0)
    Method(box, "SetAutoFocus", false)
    Method(box, "SetNumeric", true)
    Method(box, "SetMaxLetters", 3)
    Method(box, "SetJustifyH", "CENTER")
    box:SetText("1")
    box:SetScript("OnTextChanged", function() if not run then Refresh() end end)
    box:SetScript("OnEnterPressed", function(self) Method(self, "ClearFocus") end)
    box:SetScript("OnEscapePressed", function(self) Method(self, "ClearFocus") end)

    built = true
    -- Blizzard re-checks its buttons on every change to the recipe, the
    -- target and the bags (ValidateControls): ours follow.
    if type(page.ValidateControls) == "function" then
        pcall(hooksecurefunc, page, "ValidateControls", function() Refresh() end)
    end
    pcall(page.HookScript, page, "OnShow", function() Refresh() end)
    pcall(page.HookScript, page, "OnHide", function() EndRun() end)
    Refresh()
    return true
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function OnPopup(which)
    if which ~= POPUP then return end
    if replaceOn then YesUnderMouse() end
    if built then Refresh() end
end

local EVENTS = {
    "UNIT_SPELLCAST_SUCCEEDED", "TRADE_SKILL_CLOSE", "PLAYER_REGEN_ENABLED", "ADDON_LOADED",
}

local function MakeDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:SetScript("OnEvent", function(_, event, a, b, c)
        if event == "ADDON_LOADED" then
            if a == "Blizzard_Professions" and queueOn then Build() end
        elseif event == POPUP then
            OnPopup(POPUP)
        elseif event == "TRADE_SKILL_CLOSE" then
            EndRun()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if buildWaiting and queueOn then Build() end
            Refresh()
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            if a ~= "player" or not run or ns.Num(c) ~= run.recipeID then return end
            run.done = run.done + 1
            if run.done >= run.total then
                local total = run.total
                EndRun("Enchanted " .. total .. (total == 1 and " time." or " times."))
            else
                Refresh()
            end
        end
    end)
    -- The label follows the question coming and going.
    local elapsed = 0
    driver:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed < 0.2 then return end
        elapsed = 0
        if run then Refresh() end
    end)
end

local function HookPopup()
    if hookedPopup then return end
    hookedPopup = true
    if type(_G.StaticPopup_Show) == "function" then
        pcall(hooksecurefunc, "StaticPopup_Show", function(which) OnPopup(which) end)
    else
        pcall(driver.RegisterEvent, driver, POPUP)
    end
end

ns.RegisterModule("enchantReplace", {
    title = "Replace enchant: Yes under the mouse",
    desc = "Open \"Replace this enchant?\" with its Yes under the mouse in the professions window.",
    Apply = function(on)
        replaceOn = on and true or false
        MakeDriver()
        if replaceOn then HookPopup() end
    end,
})

ns.RegisterModule("enchantQueue", {
    title = "Enchant the same item several times",
    desc = "A count and a button that presses Enchant, or Yes, for you on each click.",
    Apply = function(on)
        queueOn = on and true or false
        MakeDriver()
        if queueOn then
            HookPopup()
            for _, event in ipairs(EVENTS) do pcall(driver.RegisterEvent, driver, event) end
            Build()
        else
            run = nil
            for _, event in ipairs(EVENTS) do pcall(driver.UnregisterEvent, driver, event) end
        end
        Refresh()
    end,
})

-- For the tests.
ns.EnchantRun = function() return run end

-- /chair plus enchant
function ns.ProbeEnchanting()
    local page = Page()
    local transaction, form = Transaction(page)
    local item = Target(transaction)
    local d = FindDialog(POPUP)
    ns.Print("Professions window:", _G.ProfessionsFrame and "found" or "not loaded yet (open it once)",
        "- crafting page:", page and "found" or "missing",
        "- Enchant button:", (page and page.CreateButton) and "found" or "MISSING",
        "- ours:", built and "built" or (buildWaiting and "waiting for combat to end" or "not built"))
    ns.Print("Picked recipe:", tostring(RecipeID(transaction, form)),
        "- an enchant:", IsEnchant(transaction) and "yes" or "no",
        "- target:", item and ((Method(item, "GetItemName") or "an item")
            .. (Method(item, "IsStackable") and " (stacks: Blizzard's own count is used)" or "")) or "none")
    ns.Print("Replace question:", d and ("up, Yes " .. (YesButton(d) and "found" or "NOT found")) or "not up",
        "- last:", lastPopup or "not seen yet", ns.IsEnabled("enchantReplace") and "" or "(option is off)")
    if run then ns.Print(string.format("Counting: %d of %d done.", run.done, run.total)) end
end
