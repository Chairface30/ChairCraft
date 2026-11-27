-- ChairPlus Role.lua
-- Set your group role when you join a group.
--
-- Each character keeps its own role (a priest heals, a warrior tanks), picked
-- on the Groups & people page. Joining a group sets it, and holds it for the
-- first few seconds: the game hands out a role of its own (from your spec)
-- a moment after you join, and setting ours once, early, lost to that. After
-- those seconds it is yours: change it from the group's menu and ChairCraft
-- leaves it be until you leave and join another group.
--
-- Logging in or reloading while already in a group only sets a role when you
-- have none, so a role you changed in that group survives the reload. Groups
-- from the dungeon finder are left alone: the queue gave you that role.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local ROLES = {
    { value = "NONE",    text = "none" },
    { value = "TANK",    text = "Tank" },
    { value = "HEALER",  text = "Healer" },
    { value = "DAMAGER", text = "Damage" },
}
ns.AUTO_ROLES = ROLES

local NAMES = {}
for _, role in ipairs(ROLES) do NAMES[role.value] = role.text end

-- Looks after joining, in seconds: the first once the roster settles, the
-- rest to catch the game's own role landing on top of ours.
local CHECKS = { 1.5, 3, 5, 8, 12 }
local HOLD = 12     -- seconds the role is held after joining; then it's yours
local MAX_SETS = 4  -- sets in one hold before giving up and saying so

local driver, enabled
local grouped = false   -- in a group as of the last look
local hold              -- { kind = "join"|"login", untilT, sets, said }, or nil
local lastResult
local log = {}          -- recent role events, for /chair plus role

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

local function Now() return ns.Num(Try(_G.GetTime)) or 0 end

local function Note(line)
    lastResult = line
    log[#log + 1] = string.format("%.1f %s", Now(), line)
    while #log > 12 do table.remove(log, 1) end
end

-------------------------------------------------------------------------------
-- The role picked for this character
-------------------------------------------------------------------------------

local function CharKey()
    local key = ns.CharacterKey()
    if key then return key end
    local name = ns.Text(Try(_G.UnitName, "player"))
    return name and ("name:" .. name) or nil
end

local function Store()
    local profile = ns.Profile()
    if type(profile.autoRoleByChar) ~= "table" then profile.autoRoleByChar = {} end
    return profile.autoRoleByChar
end

function ns.AutoRoleGet()
    local key = CharKey()
    local role = key and Store()[key]
    return NAMES[role] and role or "NONE"
end

local Start

function ns.AutoRoleSet(role)
    local key = CharKey()
    if not key or not NAMES[role] then return end
    Store()[key] = (role ~= "NONE") and role or nil
    -- Picked while in a group: set it now, the way joining would.
    if enabled and grouped and role ~= "NONE" then Start("join") end
end

-------------------------------------------------------------------------------
-- Setting it
-------------------------------------------------------------------------------

local function InGroup()
    local n = ns.Num(Try(_G.GetNumGroupMembers)) or 0
    if n > 0 then return true end
    return Try(_G.IsInGroup) and true or false
end

local function CurrentRole()
    local role = ns.Text(Try(_G.UnitGroupRolesAssigned, "player"))
    return NAMES[role] and role or "NONE"
end

-- A dungeon finder group: the queue picked the role.
local function FinderGroup()
    return Try(_G.IsPartyLFG) and true or Try(_G.HasLFGRestrictions) and true or false
end

function ns.AutoRoleCheck()
    if not hold then return end
    if not (enabled and InGroup()) then hold = nil return end
    if Now() > hold.untilT then
        hold = nil
        return
    end
    local want = ns.AutoRoleGet()
    if want == "NONE" then
        hold = nil
        Note("no role picked for this character")
        return
    end
    if FinderGroup() then
        hold = nil
        Note("dungeon finder group: left as the queue set it")
        return
    end
    -- The role can't be changed in combat: the end of the fight catches up.
    if Try(_G.InCombatLockdown) then
        hold.combat = true
        Note("waiting for combat to end")
        return
    end

    local have = CurrentRole()
    if have == want then
        -- Right for now. Keep looking until the hold ends: the game's own
        -- role can still land on top of it.
        if not hold.said then
            hold.said = true
            Note("already " .. NAMES[want])
        end
        return
    end
    if hold.kind == "login" and have ~= "NONE" then
        hold = nil
        Note("kept " .. NAMES[have] .. ": a role was already set")
        return
    end
    if hold.sets >= MAX_SETS then
        hold = nil
        Note("gave up: set " .. NAMES[want] .. " " .. MAX_SETS .. " times and it is still " .. NAMES[have])
        ns.Print("|cffff5555Could not set your group role to " .. NAMES[want] .. ":|r the game keeps it at "
            .. NAMES[have] .. ". /chair plus role says what it saw.")
        return
    end

    local set = _G.UnitSetRole
    if type(set) ~= "function" then
        hold = nil
        Note("this client has no UnitSetRole")
        ns.Print("|cffff5555Could not set your group role:|r this client has no way for addons to set it.")
        return
    end
    hold.sets = hold.sets + 1
    -- Once ours is set, a later role from the game is put back, not kept.
    hold.kind = "join"
    local ok, err = pcall(set, "player", want)
    if not ok then
        hold = nil
        Note("UnitSetRole failed: " .. (ns.Text(err) or "unknown error"))
        ns.Print("|cffff5555Could not set your group role:|r", ns.Text(err) or "unknown error")
        return
    end
    Note("set " .. NAMES[want] .. " (was " .. NAMES[have] .. ")")
    if hold.sets == 1 then ns.Print("Group role set to " .. NAMES[want] .. ".") end
end

function Start(kind)
    hold = { kind = kind, untilT = Now() + HOLD, sets = 0 }
    if not ns.After then return end
    for _, delay in ipairs(CHECKS) do ns.After(delay, ns.AutoRoleCheck) end
end

local function Look(event)
    local now = InGroup()
    if now and not grouped then
        -- Joined. The first look after logging in finds a group you were
        -- already in, not one you just joined.
        Start(event == "join" and "join" or "login")
    elseif not now then
        hold = nil
    end
    grouped = now
end

local ROLE_EVENTS = { ROLE_CHANGED_INFORM = true, PLAYER_ROLES_ASSIGNED = true }

ns.RegisterModule("autoRole", {
    title = "Set my role on joining a group",
    desc = "Sets this character's group role when it joins a group. Change it yourself afterwards and it stays changed.",
    Apply = function(on)
        -- Every module is applied again whenever any setting changes, so
        -- only switching this on counts as "just turned on".
        local switchedOn = on and not enabled
        enabled = on and true or false
        if not driver then
            driver = CreateFrame("Frame")
            local seenWorld = false
            driver:SetScript("OnEvent", function(_, event, ...)
                if ROLE_EVENTS[event] then
                    -- Who changed whose role, kept for the probe; and a look,
                    -- in case it was the game putting its own role back.
                    if event == "ROLE_CHANGED_INFORM" then
                        local changed, from, old, new = ...
                        Note(string.format("game: %s's role %s -> %s, by %s", ns.Text(changed) or "?",
                            ns.Text(old) or "?", ns.Text(new) or "?", ns.Text(from) or "?"))
                    else
                        Note("game: roles assigned, yours " .. NAMES[CurrentRole()])
                    end
                    if hold and ns.After then ns.After(0.2, ns.AutoRoleCheck) end
                    return
                end
                if event == "PLAYER_REGEN_ENABLED" then
                    if hold and hold.combat then
                        hold.combat = nil
                        hold.untilT = Now() + HOLD
                        for _, delay in ipairs(CHECKS) do ns.After(delay, ns.AutoRoleCheck) end
                        ns.AutoRoleCheck()
                    end
                    return
                end
                if event == "PLAYER_ENTERING_WORLD" then
                    local first = not seenWorld
                    seenWorld = true
                    if first then Look("login") end
                    return
                end
                -- Before the first loading screen ends, a group is one you
                -- logged in to.
                Look(seenWorld and "join" or "login")
            end)
        end
        if enabled then
            for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
                                     "ROLE_CHANGED_INFORM", "PLAYER_ROLES_ASSIGNED" }) do
                pcall(driver.RegisterEvent, driver, event)
            end
            -- Turned on while in a group: as if just logged in.
            if switchedOn then
                grouped = false
                if InGroup() then Look("login") end
            end
        else
            driver:UnregisterAllEvents()
            hold = nil
        end
    end,
})

-- /chair plus role
function ns.ProbeAutoRole()
    ns.Print("Option:", ns.IsEnabled("autoRole") and "on" or "|cffff5555OFF|r (tick \"Set my role on joining a group\")",
        "- picked for this character:", NAMES[ns.AutoRoleGet()],
        "- in a group:", InGroup() and "yes" or "no",
        "- role now:", NAMES[CurrentRole()],
        "- UnitSetRole:", type(_G.UnitSetRole) == "function" and "found" or "MISSING")
    ns.Print("Last:", lastResult or "nothing yet")
    for _, line in ipairs(log) do ns.Print("  " .. line) end
end
