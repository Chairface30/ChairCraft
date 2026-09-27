-- SnapSnack Bootstrap.lua
-- Event wiring and slash commands. The game's options page for the whole
-- suite is Suite/Hub.lua's.
-- Loaded last; everything it calls is defined by the earlier files.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack

local GetItemInfo          = addon.GetItemInfo
local GetItemInfoInstant   = addon.GetItemInfoInstant
local GetItemSpell         = addon.GetItemSpell
local GetContainerNumSlots = addon.GetContainerNumSlots
local GetContainerItemID   = addon.GetContainerItemID

local state = addon.state

-------------------------------
-- Combat Recovery
-------------------------------

-- Binding mode cannot be torn down mid-combat (SetAttribute is protected), so
-- the teardown is finished the moment combat ends.
local function RestoreButtonActions()
    if state.bindingMode or InCombatLockdown() then return end
    for _, buttons in pairs(addon.itemButtons) do
        for _, button in ipairs(buttons) do
            button.bindOverlay:Hide()
            button.bindHighlight:Hide()
            if not button:GetAttribute("type") then
                addon.ApplyButtonAction(button)
            end
        end
    end
end

-------------------------------
-- Low Supply Notice
-------------------------------

-- Where the rest of it is: "+20 bank, +5 Alt". Empty when there is none, so a
-- line stays short when there is nothing to add to it.
local function ElsewhereText(entry)
    local parts = {}
    if entry.bank > 0 then
        table.insert(parts, "+" .. entry.bank .. " bank")
    end
    for charKey, count in pairs(entry.alts) do
        -- "Name-Realm" is more than a restock line needs.
        table.insert(parts, "+" .. count .. " " .. (charKey:match("^([^-]+)") or charKey))
    end
    if #parts == 0 then return "" end
    table.sort(parts)
    return "  |cff00ccff" .. table.concat(parts, ", ") .. "|r"
end

-- The count text already turns amber on a running-low stack, which is enough
-- almost everywhere. A chat line is reserved for the one moment it is worth
-- interrupting for: walking into an instance short on something.
local function WarnLowSupplyOnEntry()
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return end
    if instanceType ~= "party" and instanceType ~= "raid" then return end

    local report = addon:GetLowSupplyReport(true)

    local short = {}
    for _, bar in ipairs(report) do
        for _, entry in ipairs(bar.items) do
            local elsewhere = ""
            if entry.bank > 0 then
                -- The one fact worth the extra words on the way in: you are not
                -- short, you just left it in the bank.
                elsewhere = " |cff00ccff(" .. entry.bank .. " in the bank)|r"
            end
            table.insert(short, entry.name .. " |cff808080x" .. entry.count ..
                         "|r" .. elsewhere)
        end
    end

    if #short > 0 then
        addon:Print("|cffffa500Running low:|r " .. table.concat(short, ", "))
    end
end

-------------------------------
-- Profile Load Report
-------------------------------
-- Settings that came back empty and settings that were never saved look
-- identical once the bars are on screen, and both read as "the addon forgot".
-- Saying which one happened, at the moment it happens, is the difference
-- between a puzzle and a one-click fix in the Profiles tab.

local function ReportProfileLoad()
    if addon.adoptedProfileFrom then
        addon:Print("picked up your existing settings, which were stored " ..
                    "under |cffffd100" .. addon.adoptedProfileFrom ..
                    "|r. They are filed against the character itself now, " ..
                    "so a rename or a realm change cannot lose them again.")
        return
    end

    if not addon.profileWasNew then return end

    if addon.dbWasEmpty then
        addon:Print("no saved settings yet -- starting fresh. Expected the " ..
                    "first time only.")
    elseif (addon.otherProfileCount or 0) > 0 then
        addon:Print("|cffffa500nothing stored for " .. addon:CharLabel() ..
                    ", so these bars are the default layout.|r " ..
                    (addon.otherProfileCount == 1 and "1 other profile is"
                        or (addon.otherProfileCount .. " other profiles are")) ..
                    " saved -- |cff00ffff/chair snack profiles|r lists them, and the " ..
                    "Profiles tab can copy one across.")
    end
end

-------------------------------
-- Events
-------------------------------

local eventFrame = CreateFrame("Frame")
local events = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE",
    "BAG_UPDATE_COOLDOWN",
    "PLAYER_LEVEL_UP",
    "GET_ITEM_INFO_RECEIVED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "UNIT_AURA",
    "UNIT_PET",
    "SPELLS_CHANGED",
    "UI_ERROR_MESSAGE",
    "PLAYER_EQUIPMENT_CHANGED",
    "UNIT_INVENTORY_CHANGED",
    "GROUP_ROSTER_UPDATE",
    "ZONE_CHANGED",
    "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED_INDOORS",
    "PLAYER_UPDATE_RESTING",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    -- Press-and-hold casting decides whether a secure action fires on the
    -- press or the release, and the buttons have to be re-registered when it
    -- is toggled or they go silently inert.
    "CVAR_UPDATE",
    -- Last chance to shrink the profile before the client serialises it.
    "PLAYER_LOGOUT",
}
-- RegisterEvent raises on an unknown event name, and this loop runs at file
-- scope: an unrecognised event would abort the rest of this file, taking the
-- OnEvent handler and the slash commands with it and leaving the addon inert.
-- Skip anything this client flavour does not know instead.
for _, event in ipairs(events) do
    local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
    if not ok then
        addon:Print("skipping event unsupported by this client: " .. event)
    end
end

local ready = false

-- The saved global does not arrive on schedule on this client. ADDON_LOADED is
-- the documented moment and it was nil there on every login, which is why
-- Bootstrap moved to PLAYER_LOGIN. That holds for a /reload and it does not
-- hold for a cold start, where the settings still come back as defaults the
-- next day -- and the old shape guaranteed that could never recover.
-- Bootstrap created SnapSnackDB itself the moment it found nil, set ready, and
-- the PLAYER_ENTERING_WORLD "second chance" then returned at the ready check
-- without ever looking again. A global that arrived late was replaced by the
-- empty one this addon had already put in its place, and the defaults were
-- written back over the real settings on the way out.
--
-- So nothing is invented until the data has had a fair chance to show up. The
-- gate bootstraps the moment SnapSnackDB exists and only falls back to an empty
-- one after the grace period, which is what a genuine first run looks like.
local DB_GRACE_SECONDS = 15
local waitStarted = nil

-- Everything is built here, and this is called from PLAYER_LOGIN rather than
-- from ADDON_LOADED.
--
-- ADDON_LOADED is the documented moment a saved variable becomes readable,
-- and on this client it is not. Reading SnapSnackDB there returned nil on
-- every login while the file on disk plainly held the settings -- both copies
-- of them, under two different names -- and the defaults were then written
-- back over the top on the way out. The bar positions "not saving" were
-- always this: they saved, and were read a moment too early.
--
-- The addons on this client that keep their settings are the ones that wait
-- for PLAYER_LOGIN, so that is where this waits. It costs nothing: the event
-- fires before the player is in the world, and before anything below needs
-- the profile.
local function Bootstrap()
    if ready then return end

    addon:InitDatabase()

    for gridID in pairs(addon:GetGrids()) do
        addon.itemButtons[gridID] = {}
        addon:CreateGridFrame(gridID)
    end

    addon:ScanBags()
    addon:UpdateAutoBars()
    -- Second half of the keybind conversion: the automatic bars now know
    -- which slot holds which item.
    addon:ResolveKeybindMigration()

    -- The bars are the addon; the window configures it. A window that cannot
    -- be built is a bad afternoon, not a reason to have no bars -- so each of
    -- these is allowed to fail on its own and say so.
    for _, part in ipairs({
        { "the options window", function() addon:SetupConfig() end },
        { "the minimap button", function() addon:CreateMinimapButton() end },
    }) do
        local ok, err = pcall(part[2])
        if not ok then
            addon:Print("|cffff5555" .. part[1] .. " could not be built:|r "
                        .. tostring(err))
        end
    end

    ready = true
    addon:Print("loaded. Type |cff00ffff/chair snack|r to configure.")
    ReportProfileLoad()

    -- And draw them.
    --
    -- Building a bar, filling it and drawing it are three steps, and this used
    -- to do only the first two: the draw happened in the PLAYER_LOGIN branch
    -- below instead. That branch sits behind the ready gate, so on a client
    -- where the saved data does not arrive in time -- this one -- bootstrap
    -- was still waiting when login fired, the branch returned early, and by
    -- the time bootstrap finally ran there was no event left to redraw
    -- anything. The bars were built, filled, and invisible until some setting
    -- was changed and redrew them.
    --
    -- Doing it here means bootstrap is complete on its own terms, whenever it
    -- happens to run.
    addon:UpdateAllGrids()

    -- Item data is routinely not cached this early, and an item the client
    -- cannot name yet is skipped rather than guessed at. One more pass a
    -- moment later picks up what was missing.
    C_Timer.After(1, function()
        addon:ScanBags()
        addon:UpdateAutoBars()
        addon:UpdateAllGrids()
    end)
end

-- Bootstrap only when there is something to bootstrap from, or when waiting any
-- longer would be its own bug. addon.dbArrival records which it was, and the
-- logout write keeps it, so a cold start that comes up on defaults tomorrow can
-- still say whether the data ever turned up and how late.
local function TryBootstrap(reason)
    if ready then return end

    waitStarted = waitStarted or GetTime()
    local waited = GetTime() - waitStarted

    if SnapSnackDB ~= nil then
        addon.dbArrival = string.format("%s +%.1fs", reason, waited)
        Bootstrap()
    elseif waited >= DB_GRACE_SECONDS then
        addon.dbArrival = string.format("never (defaults after %.0fs)", waited)
        Bootstrap()
    else
        C_Timer.After(0.5, function() TryBootstrap("waited") end)
    end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 ~= suiteName then return end
        -- Recorded, not acted on. Whether the saved data had arrived by now
        -- is the whole question above, and /chair snack profiles reports it.
        addon.dbAtAddonLoaded = (SnapSnackDB ~= nil)
        return
    end

    if event == "PLAYER_LOGOUT" then
        addon:CompactProfile()
        return
    end

    -- Set up on the first PLAYER_LOGIN, before the gate below.
    -- PLAYER_ENTERING_WORLD is a second chance rather than a second setup:
    -- Bootstrap only runs once, and betting the whole addon on one event
    -- firing is what this change is trying to stop doing.
    if event == "PLAYER_LOGIN" then
        addon.dbAtPlayerLogin = (SnapSnackDB ~= nil)
        TryBootstrap("PLAYER_LOGIN")
    elseif event == "PLAYER_ENTERING_WORLD" then
        addon.dbAtEnteringWorld = (SnapSnackDB ~= nil)
        TryBootstrap("PLAYER_ENTERING_WORLD")
    end

    -- Nothing below is safe before the profile exists. SPELLS_CHANGED in
    -- particular can arrive before this addon has loaded.
    if not ready then return end

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- Entering an instance changes which zone consumables work.
        addon.ClearUsableCache()
        -- Supplies are worth checking on the way in, and only on the way in.
        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(2, WarnLowSupplyOnEntry)
        end
        -- Item data is often not cached yet at this point.
        C_Timer.After(1, function()
            addon:ScanBags()
            addon:UpdateAutoBars()
            addon:UpdateAllGrids()
        end)

    elseif event == "BAG_UPDATE" then
        -- One loot or one sale fires this once per bag it touched, several
        -- in the same frame, and each used to rescan every bag and rebuild
        -- every auto bar. They are gathered into one pass on the next frame.
        if addon.bagScanPending then return end
        addon.bagScanPending = true
        C_Timer.After(0, function()
            addon.bagScanPending = false
            addon:ScanBags()
            addon:UpdateAutoBars()
            -- Counts and cooldowns are not protected, so they are refreshed
            -- straight away. RequestUpdate defers the parts that are, which
            -- is why using a potion in combat used to leave a stale number.
            addon:RefreshLiveState()
            addon:RequestUpdate()

            -- A just-looted item often has no item data yet, so it is skipped
            -- and only reappears on the next pass -- which is why something
            -- picked up would show up only after a reload.
            -- GET_ITEM_INFO_RECEIVED usually covers it; this is the backstop
            -- for when it does not fire.
            if addon:AutoBarNeedsRetry() then
                C_Timer.After(0.5, function()
                    addon:UpdateAutoBars()
                    addon:RequestUpdate()
                end)
            end
        end)

    elseif event == "BAG_UPDATE_COOLDOWN" then
        addon:RefreshLiveState()

    elseif event == "PLAYER_LEVEL_UP" then
        addon:UpdateAutoBars()
        addon:RequestUpdate()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Only worth acting on while the auto bar is still waiting for data.
        if addon:AutoBarNeedsRetry() then
            addon:UpdateAutoBars()
            addon:RequestUpdate()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        if state.bindingMode then
            addon:StopBindingMode()
        end

    elseif event == "CVAR_UPDATE" then
        -- arg1 is the CVar name on some builds and its display name on others,
        -- so this re-reads the setting rather than trying to match the name.
        -- A refresh refused in combat is picked up on PLAYER_REGEN_ENABLED.
        addon.RefreshClickRegistration()

    elseif event == "PLAYER_REGEN_ENABLED" then
        RestoreButtonActions()
        addon.RefreshClickRegistration()
        addon:UpdateAllGrids()

    elseif event == "UNIT_AURA" then
        if arg1 == "player" then
            -- First, because everything below reads the snapshot it writes.
            --
            -- It used to be refreshed only inside UpdateAllGrids, which is the
            -- call BuffFoodStateChanged decides whether to make -- so the check
            -- for the food buff read the buffs as they were BEFORE the aura
            -- that woke it. Becoming Well Fed therefore looked like no change
            -- at all, and the bar stayed up until something unrelated happened
            -- to relayout the grids. The buff timers on the buttons were a
            -- frame behind for the same reason.
            addon:CheckPlayerBuffs()

            addon:RefreshLiveState()
            addon:RequestUpdate()
            -- Whether the buff food bar shows is a Lua rule, and Lua rules are
            -- only re-read during layout. Relayout when the buff actually
            -- flips and not one firing sooner: UNIT_AURA arrives constantly,
            -- and a full relayout per arrival would be the most expensive
            -- thing this addon does.
            if addon:BuffFoodStateChanged() then
                addon:UpdateAllGrids()
            end
        end

    elseif event == "UNIT_PET" then
        if arg1 == "player" then
            -- A different pet family means a different food list and diet, and
            -- summoning or dismissing adds or removes the pet bandage slot.
            addon:UpdateAutoBar()
            addon:UpdatePotionBar()
            addon:RequestUpdate()
            addon:RefreshConfig()
        end

    elseif event == "UI_ERROR_MESSAGE" then
        -- arg1 is the message on some builds and an error id on others, so
        -- check both and compare against the localised global.
        local message = arg1
        if type(arg1) == "number" then message = select(1, ...) end
        if type(message) == "string" and SPELL_FAILED_WRONG_PET_FOOD
            and message == SPELL_FAILED_WRONG_PET_FOOD then
            addon.NotePetFeedRejected()
        end

    elseif event == "SPELLS_CHANGED" then
        -- A newly trained portal belongs in the mage flyout. This is the only
        -- thing that invalidates the cached spellbook walk.
        addon.InvalidateMagePortals()
        -- Training Create Healthstone or a conjure changes what an empty slot
        -- can offer, and this is the only event that says so.
        addon.InvalidateCreateSpells()
        addon.InvalidateRecallSpell()
        addon:UpdateAutoBars()
        addon:RequestUpdate()

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- The Parachute Cloak is used from the back slot, never from a bag.
        addon:UpdateTeleportBar()
        -- Swapping an off-hand adds or removes that enchant slot, and ammo
        -- lives in an inventory slot rather than a bag.
        addon:UpdateEnchantBar()
        addon:UpdateAmmoBar()
        addon:UpdatePotionBar()
        addon:RequestUpdate()

    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then
            addon:UpdateEnchantBar()
            addon:UpdateAmmoBar()
            addon:UpdatePotionBar()
            -- Ammo count and weapon enchant timers, both of which move in
            -- combat.
            addon:RefreshLiveState()
            addon:RequestUpdate()
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- "Only in a group" is evaluated during layout, so a relayout is the
        -- whole of the work here.
        addon:UpdateAllGrids()

    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA"
        or event == "ZONE_CHANGED_INDOORS" or event == "PLAYER_UPDATE_RESTING" then
        addon:CheckIfInCity()
        -- Zone consumables such as Bottled Nethergon Energy become usable or
        -- unusable purely by moving, so drop the usability cache and re-pick.
        addon.ClearUsableCache()
        addon:UpdatePotionBar()
        addon:RequestUpdate()

    elseif event == "BANKFRAME_OPENED" then
        C_Timer.After(0.5, function() addon:ScanBank() end)

    elseif event == "BANKFRAME_CLOSED" then
        addon:ScanBank()
    end
end)

-------------------------------
-- Slash Commands
-------------------------------

SLASH_SNAPSNACK1 = "/ss"
SLASH_SNAPSNACK2 = "/snack"
SLASH_SNAPSNACK3 = "/snapsnack"

SlashCmdList["SNAPSNACK"] = function(msg)
    msg = msg:lower():trim()

    if msg == "reset" then
        addon:ResetProfile()
        ReloadUI()

    elseif msg == "scan" then
        -- A rescan is the answer to "the bar is not seeing my items", so it
        -- re-reads every tooltip rather than trusting what was cached.
        addon.ClearClassifyCache()
        addon.ClearUsableCache()
        addon.ClearRestrictionCache()
        addon:ScanBags()
        addon:UpdateAutoBars()
        addon:RequestUpdate()
        local count = 0
        for _ in pairs(addon.knownConsumables) do count = count + 1 end
        addon:Print("Found " .. count .. " consumables.")

    elseif msg == "bind" then
        if state.bindingMode then
            addon:StopBindingMode()
        else
            addon:StartBindingMode()
        end

    elseif msg == "lock" or msg == "unlock" then
        -- Both retired in v2.43: bars move while the config window is open and
        -- are pinned when it is closed, so there is nothing to lock. Answered
        -- rather than ignored, since these were the documented way to do it.
        addon:Print("Bars are movable while the config window is open -- " ..
                    "right-drag any bar to move it. Closing the window pins " ..
                    "them again, so there is no lock to set.")
        addon:OpenConfig()

    elseif msg == "auto" then
        local function Report(label, selection, order, describe)
            print("|cffFFD100" .. label .. "|r")
            for _, slot in ipairs(order) do
                local pick = selection[slot]
                if pick then
                    print("  " .. slot .. ": " .. (pick.name or "?") .. describe(pick))
                else
                    print("  " .. slot .. ": |cff808080none|r")
                end
            end
        end

        addon:Print("Automatic bar selection:")

        Report("Food & Drink", addon.autoSelection or {}, addon.FOOD_SLOT_ORDER,
            function(pick)
                if pick.spellName then
                    if pick.needsSetup then return " (no food chosen)" end
                    if pick.state and pick.state ~= "ready" then
                        return " (" .. (pick.hint or pick.state) .. ")"
                    end
                    return " (" .. (pick.total or 0) .. " total)"
                end
                if pick.isCreateSpell then return " (nothing on hand -- offers the spell)" end
                return " (req level " .. (pick.minLevel or 0) ..
                       (pick.isTableFood and ", table food" or "") .. ")"
            end)

        -- The feed slot stands for a whole list, so name every food in it.
        local feedPet = (addon.autoSelection or {}).feedPet
        if feedPet and feedPet.members and #feedPet.members > 0 then
            print("  |cffFFD100feedPet order|r")
            for index, member in ipairs(feedPet.members) do
                local marker = (member.itemID == feedPet.itemID)
                    and " |cff33ff33<- next|r" or ""
                print("    " .. index .. ". " .. (member.name or "?") ..
                      " |cff808080x" .. (member.count or 0) .. "|r" .. marker)
            end
        end

        Report("Potions", addon.potionSelection or {}, addon.POTION_SLOT_ORDER,
            function(pick)
                if pick.isCreateSpell then return " (nothing on hand -- offers the spell)" end
                local text = " (restores " .. math.floor((pick.amount or 0) + 0.5)
                if pick.total then
                    text = text .. ", " .. pick.total .. " on hand"
                end
                if pick.isZoneItem then
                    text = text .. ", |cff00ccffzone item|r"
                end
                return text .. ")"
            end)

        -- Teleport slots hold a list rather than a single pick.
        print("|cffFFD100Teleports|r")
        local teleports = addon.teleportSelection or {}
        for _, slot in ipairs(addon.TELEPORT_SLOT_ORDER) do
            local picked = teleports[slot]
            if not picked or #picked == 0 then
                print("  " .. slot .. ": |cff808080none|r")
            elseif slot == "magePortals" or slot == "mageTeleports" then
                local names = {}
                for _, spell in ipairs(picked) do table.insert(names, spell.name) end
                print("  " .. slot .. ": " .. table.concat(names, ", "))
            else
                local names = {}
                for _, entry in ipairs(picked) do table.insert(names, entry.name) end
                print("  " .. slot .. ": " .. table.concat(names, ", "))
            end
        end

        -- Which "make one" spells were recognised. Listed because these come
        -- from reference spell ids: a wrong one costs the button silently, and
        -- this is where that shows up.
        local created = addon.GetCreateSpells() or {}
        if next(created) then
            print("|cffFFD100Make your own|r")
            for slotKey, spell in pairs(created) do
                print("  " .. slotKey .. ": " .. spell.name)
            end
        else
            local _, class = UnitClass("player")
            if class == "WARLOCK" or class == "MAGE" then
                print("|cffFFD100Make your own|r |cffff5555none recognized|r")
            end
        end

        local alternatives = addon.potionAlternatives or {}
        if next(alternatives) then
            print("|cffFFD100Potion alternatives (right-click)|r")
            for slot, pool in pairs(alternatives) do
                local names = {}
                for _, candidate in ipairs(pool) do
                    table.insert(names, candidate.name .. " |cff808080x" ..
                                 (candidate.count or 0) .. "|r")
                end
                print("  " .. slot .. ": " .. table.concat(names, ", "))
            end
        end

        if addon:IsHunter() then
            print("|cffFFD100Ammo|r")
            local ammo = (addon.ammoSelection or {}).ammo
            if ammo then
                print("  ammo: " .. (ammo.name or "?") ..
                      " |cff808080x" .. (ammo.count or 0) .. "|r")
            else
                print("  ammo: |cff808080nothing in the ammo slot|r")
            end
        end

        print("|cffFFD100Weapon Enchants|r")
        if addon:IsRogue() then
            local grid = addon:GetGrid(addon.ENCHANT_GRID_ID)
            local chosen = (grid and grid.poisonSlots) or {}
            for _, slot in ipairs(addon.ENCHANT_SLOT_ORDER) do
                local line = chosen[slot] or addon.DEFAULT_POISON_SLOT[slot]
                print("  |cff808080" .. slot .. " prefers " ..
                      (addon.POISON_LINE_NAMES[line] or "?") ..
                      (chosen[slot] and "" or " (default)") .. "|r")
            end
        end
        local enchants = addon.enchantSelection or {}
        for _, slot in ipairs(addon.ENCHANT_SLOT_ORDER) do
            local pick = enchants[slot]
            if not pick then
                print("  " .. slot .. ": |cff808080none|r")
            elseif pick.remaining then
                print("  " .. slot .. ": " .. pick.name .. " |cff808080(" ..
                      addon.FormatDuration(pick.remaining) .. " left)|r")
            else
                print("  " .. slot .. ": " .. pick.name .. " |cffff5555(no enchant)|r")
            end
        end

    elseif msg:match("^bufffood") then
        addon:BuffFoodCommand(msg:match("^bufffood%s*(.-)$") or "")

    elseif msg == "petfood" then
        local family = addon:GetPetFamily()
        if not family then
            addon:Print("No pet out.")
        else
            local diet = addon:GetDietForFamily(family)
            addon:Print(family .. (diet and (" -- diet: " .. table.concat(diet, ", ")) or ""))
            for index, pick in ipairs(addon:GetAutoPetFood(family)) do
                print("  " .. index .. ". " .. pick.name ..
                      " |cff808080[" .. pick.rating .. "]|r")
            end
            local known = addon:GetPetFoodKnowledge(family)
            if known then
                for itemID, accepted in pairs(known) do
                    if accepted == false then
                        print("  |cff808080refused: " ..
                              (GetItemInfo(itemID) or itemID) .. "|r")
                    end
                end
            end
        end

    elseif msg == "why" then
        -- Ground truth for the bars: where each item's classification came
        -- from, the verdict it produced, and the tooltip behind the usability
        -- check -- line by line with the colour of each, since that is what
        -- the zone and requirement checks actually read.
        addon.ClearClassifyCache()
        addon.ClearUsableCache()
        addon.ClearRestrictionCache()

        addon:Print("Zone: " .. (GetRealZoneText() or "?") ..
                    " / " .. (GetSubZoneText() or ""))

        local seen = {}
        local shown = 0
        for bag = 0, 4 do
            local numSlots = addon.GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local itemID = addon.GetContainerItemID(bag, slot)
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    local info = addon.ClassifyItem(itemID, bag, slot)
                    -- Anything with a use effect, not just what already passed
                    -- classification: an item rejected by the classifier has to
                    -- be visible here or it vanishes without explanation.
                    local hasUse = GetItemSpell(itemID) ~= nil
                    if info and (info.isPotion or info.isBandage or hasUse) then
                        shown = shown + 1
                        local usable = addon.IsUsableNow(itemID, bag, slot)
                        local slots = {}
                        if info.food or info.drink then
                            -- Food class never reaches the potion bar.
                            if addon:BuffFoodBarClaims(itemID) then
                                -- On the buff bar, so the plain slots pass it
                                -- over: this is the line that says why a food
                                -- you are carrying is not on the food bar.
                                table.insert(slots, "buff food bar")
                            else
                                if info.food then table.insert(slots, "food bar") end
                                if info.drink then table.insert(slots, "drink bar") end
                            end
                        elseif info.isEnhancement then
                            -- Which hand it can go on is the useful half here:
                            -- a sharpening stone on a mace is a button that
                            -- refuses, and the bar leaves it off for that.
                            for _, hand in ipairs(addon.ENCHANT_SLOT_ORDER) do
                                local equipped = GetInventoryItemID("player",
                                    addon.WEAPON_SLOT[hand])
                                -- Same three answers the bar itself reads: no
                                -- weapon in the hand, a weapon of a known type,
                                -- or a weapon the client cannot type yet.
                                local isWeapon, subclassID = equipped ~= nil, nil
                                if equipped and GetItemInfoInstant then
                                    local _, _, _, _, _, classID, sub =
                                        GetItemInfoInstant(equipped)
                                    if classID ~= nil then
                                        isWeapon = classID == addon.WEAPON_CLASS_ID
                                        if isWeapon then subclassID = sub end
                                    end
                                end
                                if isWeapon and addon.EnhancementFitsWeapon(itemID, subclassID) then
                                    table.insert(slots, hand)
                                end
                            end
                        elseif info.isZoneItem then
                            table.insert(slots, "zoneItem")
                        elseif not info.isPotion and not info.isBandage then
                            -- Classified as neither; nothing will place it.
                        elseif info.isBandage then
                            table.insert(slots, "bandage")
                        else
                            local zone = addon.IsZoneConsumable(itemID, bag, slot)
                            if info.healAmount > 0 then
                                table.insert(slots, info.conjured and "healthstone"
                                    or (zone and "zoneHealth" or "health"))
                            end
                            if info.manaAmount > 0 then
                                table.insert(slots, info.conjured and "manaGem"
                                    or (zone and "zoneMana" or "mana"))
                            end
                        end

                        local classID, subclassID = "?", "?"
                        if GetItemInfoInstant then
                            local _, _, _, _, _, c, sc = GetItemInfoInstant(itemID)
                            classID, subclassID = c or "?", sc or "?"
                        end

                        -- Which of the three sources answered for this item.
                        -- When a bar shows the wrong thing, this is the line
                        -- that says whether to fix an ID or an assumption.
                        local spellName, spellID = GetItemSpell(itemID)
                        local source
                        if addon.CONSUMABLE_DATA[itemID] then
                            source = "|cff33ff33id table|r"
                        elseif addon.HEALTHSTONE_ITEMS[itemID] then
                            source = "|cff33ff33healthstone table|r"
                        elseif addon.WEAPON_ENHANCEMENTS[itemID] then
                            source = "|cff33ff33enhancement table|r"
                        elseif spellName then
                            source = "|cff00ccffspell|r |cff808080" ..
                                     spellName .. " (" .. tostring(spellID) .. ")|r"
                        else
                            source = "|cff808080nothing|r"
                        end

                        print("|cffFFD100[" .. itemID .. "] " ..
                              (GetItemInfo(itemID) or "?") .. "|r " ..
                              "|cff808080cls=" .. tostring(classID) ..
                              "/" .. tostring(subclassID) .. "|r " ..
                              (usable and "|cff33ff33USABLE|r" or "|cffff5555BLOCKED|r") ..
                              " |cff808080-> " ..
                              (#slots > 0 and table.concat(slots, "+") or "no slot") ..
                              "  heal=" .. math.floor(info.healAmount) ..
                              " mana=" .. math.floor(info.manaAmount) ..
                              (info.estimated and "(est)" or "") ..
                              (info.conjured and " conjured" or "") ..
                              (info.zone and " zone" or "") .. "|r")
                        print("    |cff808080via " .. source .. "|r")

                        local dump = addon.DumpTooltip(itemID, bag, slot)
                        if not dump then
                            print("    |cffff5555tooltip scan FAILED|r")
                        else
                            for _, line in ipairs(dump) do
                                -- Raw values: colour has proved unreliable
                                -- here, so show it rather than interpret it.
                                print(string.format("    [%.2f %.2f %.2f] %s",
                                    line.r, line.g, line.b, line.text))
                            end
                            local restrictions = addon.RestrictionLines(itemID, bag, slot) or {}
                            for _, line in ipairs(restrictions) do
                                print("    |cff00ccffRESTRICTION:|r " .. line)
                            end
                        end
                    end
                end
            end
        end

        if shown == 0 then
            addon:Print("No potions or bandages found in bags.")
        end

    elseif msg == "vis" then
        -- Why a bar is or is not on screen, in the same terms layout decides
        -- it: enabled, the instance and group rules, how many buttons ended up
        -- visible, and where the frame actually sits.
        local inInstance, instanceType = IsInInstance()
        addon:Print("Visibility report")
        print("  |cff808080instance=" .. tostring(inInstance) ..
              "/" .. tostring(instanceType) ..
              "  group=" .. tostring(addon.IsInGroupNow()) ..
              "  combat=" .. tostring(InCombatLockdown()) ..
              "  dead=" .. tostring(UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) .. "|r")

        for _, info in ipairs(addon:GetGridList()) do
            local gridID = info.id
            local db = addon:GetGrid(gridID)
            local frame = addon.frames[gridID]
            local buttons = addon.itemButtons[gridID] or {}

            local shown = 0
            for _, button in ipairs(buttons) do
                if button:IsShown() then shown = shown + 1 end
            end

            local passes = addon.PassesVisibilityRules(db)
            local verdict
            if not db.enabled then
                verdict = "|cffff5555bar disabled|r"
            elseif not passes then
                verdict = "|cffff5555blocked by rules|r"
            elseif shown == 0 then
                verdict = "|cffff5555nothing to show|r"
            elseif frame and frame:IsShown() then
                verdict = "|cff33ff33on screen|r"
            else
                verdict = "|cffff5555frame hidden|r"
            end

            print("|cffFFD100" .. gridID .. "|r " .. verdict)
            print("  |cff808080items=" .. #db.items ..
                  " buttons=" .. #buttons ..
                  " shown=" .. shown ..
                  " onlyInInstance=" .. tostring(db.onlyInInstance) ..
                  " onlyInGroup=" .. tostring(db.onlyInGroup) ..
                  " hideWhenDead=" .. tostring(db.hideWhenDead) ..
                  " showInCombat=" .. tostring(db.showInCombat) .. "|r")

            if frame then
                local point, _, _, x, y = frame:GetPoint()
                print(string.format("  |cff808080frame shown=%s alpha=%.2f size=%dx%d at %s %d,%d|r",
                    tostring(frame:IsShown()), frame:GetAlpha(),
                    math.floor(frame:GetWidth()), math.floor(frame:GetHeight()),
                    tostring(point), math.floor(x or 0), math.floor(y or 0)))
            else
                print("  |cffff5555no frame created|r")
            end
        end

    elseif msg == "click" then
        -- Why a button does or does not do anything when clicked.
        --
        -- A button that draws correctly and then ignores the click has failed
        -- somewhere between the layout pass and the secure template, and only
        -- three things can be wrong: the action attributes were never set, the
        -- mouse is not reaching the button, or the template's own handler is
        -- gone. This prints all three side by side rather than one at a time.
        addon:Print("Click report")
        print("  |cff808080ready=" .. tostring(ready) ..
              "  combat=" .. tostring(InCombatLockdown()) ..
              "  bindingMode=" .. tostring(state.bindingMode) ..
              "  clicks fire on " .. addon.ClickRegistration() .. "|r")

        for _, info in ipairs(addon:GetGridList()) do
            local gridID = info.id
            local frame = addon.frames[gridID]
            local buttons = addon.itemButtons[gridID] or {}

            local any = false
            for index, button in ipairs(buttons) do
                if button:IsShown() then
                    if not any then
                        any = true
                        print("|cffFFD100" .. gridID .. "|r |cff808080frame level=" ..
                              (frame and frame:GetFrameLevel() or -1) ..
                              " strata=" .. (frame and frame:GetFrameStrata() or "?") ..
                              "|r")
                    end

                    -- type1/type2 are consulted ahead of type, so all three
                    -- have to be visible to know which one a click will find.
                    local kind = button:GetAttribute("type1")
                        or button:GetAttribute("type") or "|cffff5555none|r"
                    local payload = button:GetAttribute("item")
                        or button:GetAttribute("spell")
                        or button:GetAttribute("macrotext")
                        or button:GetAttribute("macrotext1")
                        or "|cffff5555none|r"

                    local data = type(button.itemData) == "table" and button.itemData or nil
                    local label = (data and data.slotKey)
                        or (button.itemName or tostring(button.itemID))

                    print("  " .. index .. ". " .. tostring(label) ..
                          " |cff808080type=" .. tostring(kind) ..
                          " -> " .. tostring(payload) ..
                          "  right=" .. tostring(button:GetAttribute("type2") or "-") ..
                          "|r")
                    print("     |cff808080mouse=" .. tostring(button:IsMouseEnabled()) ..
                          " level=" .. button:GetFrameLevel() ..
                          " strata=" .. button:GetFrameStrata() ..
                          " onclick=" .. tostring(button:GetScript("OnClick") ~= nil) ..
                          " protected=" .. tostring(button:IsProtected()) ..
                          " clicks=" .. (button.clickCount or 0) .. "|r")
                end
            end
        end

        -- What else is sitting on that spot.
        --
        -- Every attribute can be right, the button can be at the top of its own
        -- frame, and the click can still never arrive because some other
        -- addon's frame covers it. Walking every shown, mouse-enabled frame
        -- whose rect contains the button answers that outright, instead of
        -- asking the user to hover and guess -- and it names the culprit.
        local STRATA_RANK = {
            BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
            DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
        }

        local function CoveringFrames(button)
            local left, right = button:GetLeft(), button:GetRight()
            local bottom, top = button:GetBottom(), button:GetTop()
            if not (left and right and bottom and top) then return {} end
            local x, y = (left + right) / 2, (bottom + top) / 2

            local mine = STRATA_RANK[button:GetFrameStrata()] or 0
            local myLevel = button:GetFrameLevel()

            local found = {}
            local frame = EnumerateFrames()
            while frame do
                local ok = frame ~= button
                    and not (frame.IsForbidden and frame:IsForbidden())
                    and frame.IsVisible and frame:IsVisible()
                    and frame.IsMouseEnabled and frame:IsMouseEnabled()

                if ok then
                    local l, r = frame:GetLeft(), frame:GetRight()
                    local b, t = frame:GetBottom(), frame:GetTop()
                    if l and r and b and t
                        and x >= l and x <= r and y >= b and y <= t then
                        local rank = STRATA_RANK[frame:GetFrameStrata()] or 0
                        local level = frame:GetFrameLevel()
                        -- Only what would actually win the click. A frame
                        -- underneath is not a suspect.
                        if rank > mine or (rank == mine and level > myLevel) then
                            table.insert(found, {
                                frame = frame, rank = rank, level = level,
                            })
                        end
                    end
                end
                frame = EnumerateFrames(frame)
            end

            table.sort(found, function(a, b)
                if a.rank ~= b.rank then return a.rank > b.rank end
                return a.level > b.level
            end)
            return found
        end

        local probe = nil
        for _, info in ipairs(addon:GetGridList()) do
            for _, button in ipairs(addon.itemButtons[info.id] or {}) do
                if button:IsShown() then probe = probe or button end
            end
        end

        if not probe then
            addon:Print("No visible buttons to test.")
        else
            local covering = CoveringFrames(probe)
            if #covering == 0 then
                addon:Print("|cff33ff33Nothing is covering the bars.|r " ..
                            "The click is reaching the button, so a clicks= " ..
                            "above that stays at 0 means it is not being " ..
                            "delivered, and a rising one means the action ran " ..
                            "and was refused.")
            else
                addon:Print("|cffff5555" .. #covering ..
                            " frame(s) sit on top of the bar and will take the " ..
                            "click first:|r")
                for index, entry in ipairs(covering) do
                    if index > 6 then break end
                    local name = entry.frame.GetName and entry.frame:GetName()
                    print("  " .. (name or "|cff808080unnamed|r") ..
                          " |cff808080strata=" .. entry.frame:GetFrameStrata() ..
                          " level=" .. entry.level .. "|r")
                end
            end
        end

    elseif msg == "api" then
        -- Which client API each compatibility shim landed on. Anything marked
        -- MISSING is a call that will error the moment it is reached.
        print("|cffFFFF00=== ChairSnack API ===|r")
        local names = {}
        for name in pairs(addon.apiSource) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local source = addon.apiSource[name]
            local colour = (source == "MISSING" and "|cffff5555")
                or (source == "global" and "|cff808080") or "|cff33ff33"
            print("  " .. name .. " |cff808080->|r " .. colour .. source .. "|r")
        end

    elseif msg == "zone" then
        -- Every name the client has for where you are standing, and the
        -- verdict for each item that names the zones it works in. When a zone
        -- consumable is missing from the bar, this says whether its zone list
        -- is wrong or the zone text here simply reads differently than the
        -- list expects -- which is the only way to write that list correctly.
        print("|cffFFFF00=== ChairSnack zone ===|r")
        for _, name in ipairs(addon.CurrentZoneNames()) do
            print("  |cff808080here:|r " .. name)
        end

        local listed = {}
        for itemID, data in pairs(addon.CONSUMABLE_DATA) do
            if data.zones then listed[#listed + 1] = itemID end
        end
        table.sort(listed)

        if #listed == 0 then
            print("  |cff808080no item names its own zones|r")
        end
        for _, itemID in ipairs(listed) do
            local data = addon.CONSUMABLE_DATA[itemID]
            local name = GetItemInfo(itemID) or data.name or ("item:" .. itemID)
            local usable = addon.IsUsableNow(itemID)
            print("  " .. name .. " |cff808080(" .. itemID .. ")|r -> " ..
                  (usable and "|cff33ff33usable here|r" or "|cffff5555not here|r") ..
                  " |cff808080[" .. table.concat(data.zones, ", ") .. "]|r")
        end

    elseif msg == "pos" then
        -- Where each bar is saved, against where it actually is. If the two
        -- disagree the bar was moved after layout ran, and the frame it is
        -- anchored to says by what.
        print("|cffFFFF00=== ChairSnack Positions ===|r")
        local cx, cy = UIParent:GetCenter()
        print(string.format("UIParent %.0f x %.0f, center %.1f, %.1f, scale %.3f",
            UIParent:GetWidth(), UIParent:GetHeight(), cx or 0, cy or 0,
            UIParent:GetEffectiveScale()))

        if addon.lastLayoutError then
            print("|cffff5555last layout error:|r " .. addon.lastLayoutError)
        end

        for _, entry in ipairs(addon:GetGridList()) do
            local db = addon:GetGrid(entry.id)
            local frame = addon.frames[entry.id]
            if db then
                print("  |cffFFD100" .. (db.name or tostring(entry.id)) .. "|r" ..
                      (db.enabled and "" or " |cff808080(disabled)|r"))
                print("    saved: " .. (db.pos
                        and string.format("%.1f, %.1f pivot %s", db.pos.x, db.pos.y,
                                          tostring(db.posPivot))
                        or "|cffff5555nothing saved|r"))

                local point, relativeTo, relPoint, x, y
                if frame then point, relativeTo, relPoint, x, y = frame:GetPoint() end
                if point then
                    local relName = (relativeTo and relativeTo.GetName
                                     and relativeTo:GetName()) or "UIParent?"
                    print(string.format("    live:  %s of frame to %s of %s, " ..
                                        "%.1f, %.1f  (%s)",
                        point, tostring(relPoint), relName, x or 0, y or 0,
                        frame:IsShown() and "shown" or "hidden"))
                else
                    print("    live:  |cffff5555no anchor set|r")
                end
            end
        end

    elseif msg == "profiles" then
        -- Enough to tell "it was never saved" from "it was saved and then
        -- not found again", which is the only question worth asking when a
        -- layout comes back as the default one.
        print("|cffFFFF00=== ChairSnack Profiles ===|r")
        print("Character: " .. addon:CharLabel())
        print("Profile key: |cff808080" .. addon:CharKey() .. "|r")
        if SnapSnackDB and SnapSnackDB.sentinel then
            print("|cff33ff33SENTINEL SEEN: " .. tostring(SnapSnackDB.sentinel) ..
                  "|r -- the file on disk was read.")
        end
        print("Saved data present at load: " ..
              (addon.dbWasEmpty and "|cffff5555no|r" or "|cff33ff33yes|r"))
        print("  ...at ADDON_LOADED:       " ..
              (addon.dbAtAddonLoaded and "|cff33ff33yes|r" or "|cffff5555no|r"))
        print("  ...at PLAYER_LOGIN:       " ..
              (addon.dbAtPlayerLogin and "|cff33ff33yes|r" or "|cffff5555no|r"))
        print("Profile created this session: " ..
              (addon.profileWasNew and "|cffff5555yes|r" or "|cff33ff33no|r"))

        local current = addon:CharKey()
        local any = false
        for key, profile in pairs(SnapSnackDB.profiles or {}) do
            any = true
            local grids = 0
            for _ in pairs(profile.grids or {}) do grids = grids + 1 end
            print((key == current and "|cff33ff33-> |r" or "   ") ..
                  addon:ProfileLabel(key) .. " |cff808080(" .. grids ..
                  " bars, key " .. tostring(key) .. ")|r")
        end
        if not any then
            print("  |cff808080nothing stored|r")
        end

    elseif msg == "debug" then
        print("|cffFFFF00=== ChairSnack Debug ===|r")
        print("Profile: " .. addon:CharLabel() ..
              " |cff808080(" .. addon:CharKey() .. ")|r")
        print("InCombatLockdown: " .. tostring(InCombatLockdown()))
        print("bindingMode: " .. tostring(state.bindingMode))
        print("timer ticker: " .. tostring(addon:HasTimerTicker()))
        print("in group: " .. tostring(addon.IsInGroupNow()))
        for gridID, buttons in pairs(addon.itemButtons) do
            print("Grid " .. tostring(gridID) .. ": " .. #buttons .. " buttons")
        end

    elseif msg == "restock" then
        -- What to buy before going anywhere, and what is only in the bank.
        --
        -- Every enabled bar with a threshold, not just the ones set to warn on
        -- the way into an instance: asking for the list is the opt-in.
        local report, anyThreshold = addon:GetLowSupplyReport(false)

        if not anyThreshold then
            addon:Print("No bar has a low supply threshold set, so there is " ..
                        "nothing to be short of. Set one per bar in the config.")
        elseif #report == 0 then
            addon:Print("|cff33ff33Nothing is running low.|r")
        else
            local total = 0
            addon:Print("Restock check")
            for _, bar in ipairs(report) do
                print("  |cffFFD100" .. bar.name .. "|r")
                for _, entry in ipairs(bar.items) do
                    total = total + 1
                    local colour = entry.count == 0 and "|cffff5555" or "|cffffa500"
                    print("    " .. entry.name .. "  " .. colour .. "x" ..
                          entry.count .. "|r |cff808080(low at " ..
                          entry.threshold .. ")|r" .. ElsewhereText(entry))
                end
            end
            addon:Print(total .. (total == 1 and " item is" or " items are") ..
                        " running low.")
        end

    elseif msg == "data" then
        -- Check every hand-entered item ID against the client.
        --
        -- An ID list is only as good as its IDs, and a typo in one is
        -- completely silent: the item it was meant to describe just never gets
        -- placed, and an unrelated item may quietly gain a classification it
        -- should not have. Each row records the name it expects, so this is the
        -- client disagreeing with the table rather than something to eyeball.
        addon:Print("Checking item data against the client...")

        local checked, wrong, unknown = 0, 0, 0
        local function Check(itemID, expected, label)
            checked = checked + 1

            local actual = GetItemInfo(itemID)
            if not actual then
                -- The client only knows items it has seen. Not evidence of
                -- anything, so it is counted rather than reported as a fault.
                unknown = unknown + 1
                return
            end

            if actual ~= expected then
                wrong = wrong + 1
                print("  |cffff5555[" .. itemID .. "] is " .. actual ..
                      "|r |cff808080-- the table says " .. expected ..
                      " (" .. label .. ")|r")
            end
        end

        for itemID, entry in pairs(addon.CONSUMABLE_DATA) do
            Check(itemID, entry.name, entry.kind ..
                  (entry.amount and (" " .. entry.amount) or ""))
        end
        for itemID, entry in pairs(addon.HEALTHSTONE_ITEMS) do
            Check(itemID, entry.name, "healthstone " .. entry.amount)
        end
        for itemID, entry in pairs(addon.WEAPON_ENHANCEMENTS) do
            Check(itemID, entry.name, "weapon enhancement")
        end

        if wrong == 0 then
            addon:Print("|cff33ff33" .. (checked - unknown) ..
                        " of " .. checked .. " entries match.|r " ..
                        (unknown > 0
                            and ("|cff808080" .. unknown ..
                                 " not cached by the client this session; " ..
                                 "run this again after seeing them.|r")
                            or ""))
        else
            addon:Print("|cffff5555" .. wrong .. " of " .. checked ..
                        " entries are wrong|r -- the IDs above describe a " ..
                        "different item than ItemData.lua claims.")
        end

    else
        addon:OpenConfig()
    end
end
