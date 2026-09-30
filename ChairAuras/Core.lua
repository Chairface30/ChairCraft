local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-- The window's title while ChairAuras grows toward WeakAuras' feature set.
ns.WINDOW_TITLE = "ChairAuras |cffff9900*Beta*|r"

_G.ChairAurasNS = ns

ns.version = "0.3"

-------------------------------------------------------------------------------
-- Secret values
-------------------------------------------------------------------------------
-- This client returns "secret" values from some APIs. A secret reports its
-- underlying type through type(), survives tostring() still secret, and throws
-- only when something actually reads it -- a concat, string.format, SetText. So
-- the error lands on the innocent-looking line that formats the value, never on
-- the call that produced it, and it kills the whole enclosing function on the
-- way past.
--
-- UnitHealth and UnitPower are confirmed secret on this build. Everything
-- C_UnitAuras and C_Spell.GetSpellCooldown return is not, which is the only
-- reason this addon can exist at all.
--
-- type() cannot detect a secret. Attempting the concat inside a pcall can.

-- The client's own detectors come first. The concat trick is the fallback:
-- under a tainted stack a secret can survive a concat and throw on the next
-- thing that touches it, so a native answer is the one to trust.
local issecretvalue = _G.issecretvalue
local canaccessvalue = _G.canaccessvalue

function ns.IsSecret(value)
    if issecretvalue then
        local ok, res = pcall(issecretvalue, value)
        if ok then return res and true or false end
    end
    if canaccessvalue then
        local ok, res = pcall(canaccessvalue, value)
        if ok then return not res end
    end
    return not pcall(function() return "" .. tostring(value) end)
end

-- Every value that reaches a concat, a string.format or a SetText goes through
-- here first. nil comes back as nil so callers can tell "absent" from "unreadable".
function ns.SafeText(value)
    if ns.IsSecret(value) then return nil end
    if value == nil then return nil end
    -- The comparison sits inside the pcall: a secret string joins happily and
    -- throws on the first comparison after.
    local ok, text = pcall(function()
        local s = "" .. tostring(value)
        if s == "" then return nil end
        return s
    end)
    if ok then return text end
    return nil
end

-- A number that is safe to compare and arithmetic on. A secret number passes
-- type() == "number" and then poisons whatever it is formatted into later, so
-- anything read out of an API and kept is screened here on the way in.
function ns.SafeNumber(value)
    if type(value) ~= "number" then return nil end
    if ns.IsSecret(value) then return nil end
    return value
end

-------------------------------------------------------------------------------
-- Stack counts
-------------------------------------------------------------------------------
-- `applications` is the field, confirmed by dumping real aura data on this
-- client. An earlier version of this hunted for the name through a fuzzy scan
-- of every key, on the theory that the field was missing. It was not: a buff
-- that does not stack simply reports **applications = 0**, which is a real
-- answer and not an absent one. The scan was removed rather than left in --
-- speculative matching that can pick the wrong key is worse than no fallback
-- at all once the right key is known.
--
-- The remaining names cost nothing and cover genuine variation across the
-- clients in the TOC.
--
-- Returns nil only when there is no number to be had. Never invents a zero:
-- "I could not read it" and "there are none" are different answers, and
-- conflating them made a grey-out-at-zero-stacks rule fire permanently.

-- Every value read off an aura goes the same way the stack count does -- the
-- method that found it: a list of the names each client has used for it,
-- tried in order, the first READABLE one taken (a real 0 included), and a
-- secret or missing value is unknown -- nil -- never a made-up zero or blank.
-- The second return names the field that answered, for the diagnostics.
--
-- One reader for all of them means a client that renames a field is fixed in
-- one line here, and no feature reads it differently from another.
local AURA_FIELDS = {
    stacks   = { kind = "number", "applications", "stackCount", "count", "charges", "stacks" },
    name     = { kind = "text",   "name", "spellName" },
    spellId  = { kind = "number", "spellId", "spellID", "id" },
    icon     = { kind = "number", "icon", "iconFileID", "texture" },
    duration = { kind = "number", "duration" },
    expires  = { kind = "number", "expirationTime", "expires", "expirationtime" },
    source   = { kind = "text",   "sourceUnit", "unitCaster", "caster" },
    dispel   = { kind = "text",   "dispelName", "debuffType", "dispelType" },
    instance = { kind = "number", "auraInstanceID", "instanceID" },
}
ns.AURA_FIELDS = AURA_FIELDS

-- The same for any table a client call hands back: `names` in order, the
-- first readable one taken.
function ns.ReadField(data, names, kind)
    if type(data) ~= "table" or type(names) ~= "table" then return nil end
    local read = (kind == "text") and ns.SafeText or ns.SafeNumber
    for _, field in ipairs(names) do
        local value = read(data[field])
        if value ~= nil then return value, field end
    end
    return nil
end

function ns.AuraField(data, what)
    local names = AURA_FIELDS[what]
    if not names then return nil end
    return ns.ReadField(data, names, names.kind)
end

function ns.StackCount(data)
    return ns.AuraField(data, "stacks")
end

-- A font string built from a font object this client does not have draws
-- nothing, while answering GetText, SetText and every other call perfectly
-- happily -- so the failure looks like "the feature is off" rather than like a
-- missing font. Returns true when it had to step in, so a caller can say so.
function ns.EnsureFont(fontString, size, flags)
    if type(fontString) ~= "table" and type(fontString) ~= "userdata" then
        return false
    end
    local ok, font = pcall(function() return (fontString:GetFont()) end)
    if ok and font then return false end
    pcall(fontString.SetFont, fontString,
        "Fonts" .. string.char(92) .. "FRIZQT__.TTF", size or 12, flags or "OUTLINE")
    return true
end

function ns.Print(...)
    local parts = { "|cff40c4ffChairAuras|r:" }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = ns.SafeText((select(i, ...))) or "<unreadable>"
    end
    local ok, line = pcall(table.concat, parts, " ")
    print(ok and line or "|cff40c4ffChairAuras|r: <unprintable message>")
end

-------------------------------------------------------------------------------
-- Update driver
-------------------------------------------------------------------------------
-- Both halves, and the timer is the half that is load-bearing. Events make the
-- common case immediate -- UNIT_AURA and SPELL_UPDATE_COOLDOWN both fire
-- reliably here, so a buff appears the frame it lands. The timer is what makes
-- the addon correct: an event list is a list of the changes somebody thought of,
-- and everything else is an aura that sits there wrong until something unrelated
-- happens to sweep it up. Expiry is only the obvious one of those -- nothing
-- fires when a duration runs out -- and this client has plenty more.
--
-- Events are coalesced rather than acted on directly. UNIT_AURA can arrive
-- several times for one cast, and a full rescan per arrival is wasted work.

local dirty = false
local driver = CreateFrame("Frame")

-- The guaranteed tick. Every aura is re-evaluated this often whether or not
-- anything asked for it, because the list of events above is not the list of
-- things that change an aura -- an aura on a unit that was swapped out from
-- under a group, a load condition the client has no event for, a buff applied
-- by something that fires nothing. Each of those is its own investigation and
-- each one ends in an aura that is simply wrong until the next unrelated event
-- sweeps it up. A tick costs a scan of a handful of auras and closes all of
-- them at once.
local TICK = 0.1

-- Layout is reconciled more slowly than state. Refresh moves icons when a
-- dynamic group's children change what they are showing, which is the common
-- case and is immediate -- but it cannot see a group whose own load condition
-- changed, or a size edited from somewhere that forgot to relayout. This is
-- the backstop for those: rare enough to be worth a quarter-second of
-- staleness, cheap enough not to care.
local LAYOUT_TICK = 0.25

local sinceTick = 0
local sinceLayout = 0

function ns.RequestUpdate()
    dirty = true
end

driver:SetScript("OnUpdate", function(_, elapsed)
    -- Before bootstrap there is nothing to evaluate and no states table to
    -- draw from. The dirty flag is deliberately left standing rather than
    -- cleared, so an event that arrived during the wait is still honoured on
    -- the first tick after it.
    if not (ns.Engine and ns.ready) then return end

    sinceTick = sinceTick + elapsed
    sinceLayout = sinceLayout + elapsed

    local due = sinceTick >= TICK
    if not (dirty or due) then return end

    -- Only the tick resets the tick clock. Counting a coalesced event as one
    -- would let steady event traffic -- UNIT_AURA in a raid -- push the
    -- guaranteed sweep out indefinitely, which is exactly the situation the
    -- guarantee exists for.
    dirty = false
    if due then sinceTick = 0 end

    ns.Engine:UpdateAll()

    if sinceLayout >= LAYOUT_TICK then
        sinceLayout = 0
        if ns.Display then ns.Display:Layout() end
    end
end)

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
-- RegisterEvent raises on an event name this flavour does not know, and this
-- runs at file scope: one unknown name would abort the rest of the file and
-- take the handler with it. UNIT_COMBO_POINTS is exactly that on this client --
-- present in every guide, unknown here -- so each name is registered on its own
-- and a refusal is reported rather than fatal.

local EVENTS = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LOGOUT",
    "UNIT_AURA",
    "SPELL_UPDATE_COOLDOWN",
    "SPELL_UPDATE_USABLE",
    "SPELL_UPDATE_CHARGES",
    "ACTIONBAR_UPDATE_COOLDOWN",
    "PLAYER_TARGET_CHANGED",
    "PLAYER_FOCUS_CHANGED",
    "UNIT_PET",
    "SPELLS_CHANGED",
    -- Everything below is a load condition changing under an aura. Without
    -- these an aura that loads only in combat would sit there until some
    -- unrelated aura event happened to sweep it up.
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
    "GROUP_ROSTER_UPDATE",
    "PLAYER_LEVEL_UP",
    "UPDATE_SHAPESHIFT_FORM",
    "ZONE_CHANGED",
    "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED_INDOORS",
    "PLAYER_UPDATE_RESTING",
    "UPDATE_STEALTH",
    "PLAYER_DEAD",
    "PLAYER_ALIVE",
    "PLAYER_UNGHOST",
    "PLAYER_EQUIPMENT_CHANGED",
    "PARTY_LEADER_CHANGED",
    "PLAYER_GUILD_UPDATE",
    "PLAYER_FLAGS_CHANGED",
    "PLAYER_ROLES_ASSIGNED",
}

local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

for _, event in ipairs(EVENTS) do
    local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
    if not ok then
        ns.Print("this client does not know the event", event, "-- skipped.")
    end
end

-- The handler is set here even though it calls into files that have not loaded
-- yet: the body runs at event time, by which point the whole .toc is in. Every
-- file in an addon is loaded before its own ADDON_LOADED fires.
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= suiteName then return end
        -- Recorded, not acted on. Whether the saved data had arrived by now is
        -- the question the witness exists to answer, and acting on the answer
        -- here is what previously made a late arrival permanent.
        ns.loadWitness.atAddonLoaded = (ChairAurasDB ~= nil)
        return

    elseif event == "PLAYER_LOGIN" then
        ns.loadWitness.atPlayerLogin = (ChairAurasDB ~= nil)
        ns.TryBootstrap("PLAYER_LOGIN")
        return

    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.loadWitness.atEnteringWorld = (ChairAurasDB ~= nil)
        ns.TryBootstrap("PLAYER_ENTERING_WORLD")
        return

    elseif event == "PLAYER_LOGOUT" then
        ns.SaveOnLogout()
        return
    end

    if not ns.ready then return end

    -- UNIT_AURA fires for every unit in the group. Only the four a trigger can
    -- name are worth a rescan; the other thirty-six are pure waste.
    -- A trigger watching a party, raid or the bosses (ns.watchesGroupUnits)
    -- wants theirs too.
    if event == "UNIT_AURA" and arg1 ~= "player" and arg1 ~= "target"
       and arg1 ~= "focus" and arg1 ~= "pet" then
        local groupUnit = type(arg1) == "string" and (arg1:match("^party%d") or arg1:match("^raid%d")
                                                      or arg1:match("^boss%d"))
        if not (groupUnit and ns.watchesGroupUnits) then return end
    end

    if event == "SPELLS_CHANGED" then
        ns.Engine:ClearSpellCache()
    end

    ns.RequestUpdate()
end)
