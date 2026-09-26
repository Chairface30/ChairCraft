----------------------------------------------------------------------
-- WOWFTracker.lua  v1.0
-- Compact, draggable reputation tracker with sorting & auto-hide
----------------------------------------------------------------------

WOWFTrackerNS = WOWFTrackerNS or {}

----------------------------------------------------------------------
-- WoW API compatibility
-- Patch 11.0 removed the global reputation-panel functions and replaced
-- them with C_Reputation equivalents that hand back a FactionData table
-- instead of a return list. Older clients (and the offline test harness)
-- only have the globals. These wrappers present the classic return list
-- the rest of the addon is written against, whichever the client has.
----------------------------------------------------------------------
local C_Rep = _G.C_Reputation

-- FactionData table -> the return list GetFactionInfo used to give
local function FactionList(d)
    if not d then return nil end
    return d.name, d.description, d.reaction,
           d.currentReactionThreshold, d.nextReactionThreshold, d.currentStanding,
           d.atWarWith, d.canToggleAtWar, d.isHeader, d.isCollapsed,
           d.isHeaderWithRep, d.isWatched, d.isChild, d.factionID,
           d.hasBonusRepGain, d.canSetInactive
end

local GetNumFactions, GetFactionInfo, GetFactionInfoByID
local ExpandFactionHeader, CollapseFactionHeader

if C_Rep and C_Rep.GetFactionDataByIndex then
    GetNumFactions        = C_Rep.GetNumFactions
    GetFactionInfo        = function(i)  return FactionList(C_Rep.GetFactionDataByIndex(i)) end
    GetFactionInfoByID    = function(id) return FactionList(C_Rep.GetFactionDataByID(id)) end
    ExpandFactionHeader   = C_Rep.ExpandFactionHeader
    CollapseFactionHeader = C_Rep.CollapseFactionHeader
else
    GetNumFactions        = _G.GetNumFactions
    GetFactionInfo        = _G.GetFactionInfo
    GetFactionInfoByID    = _G.GetFactionInfoByID
    ExpandFactionHeader   = _G.ExpandFactionHeader
    CollapseFactionHeader = _G.CollapseFactionHeader
end

-- Nothing to read if the client has neither set (shouldn't happen, but a
-- missing faction API must not take the whole addon down).
if not GetNumFactions then
    GetNumFactions        = function() return 0 end
    GetFactionInfo        = function() return nil end
    GetFactionInfoByID    = function() return nil end
    ExpandFactionHeader   = function() end
    CollapseFactionHeader = function() end
end

-- Options.lua walks the same panel
WOWFTrackerNS.GetNumFactions       = GetNumFactions
WOWFTrackerNS.GetFactionInfo       = GetFactionInfo
WOWFTrackerNS.GetFactionInfoByID   = GetFactionInfoByID
WOWFTrackerNS.ExpandFactionHeader  = ExpandFactionHeader
WOWFTrackerNS.CollapseFactionHeader = CollapseFactionHeader

----------------------------------------------------------------------
-- Skill lines
-- Three things can be true of a client, and this addon has met all three.
--
-- 1. The panel is there under its old global names. GetSkillLineInfo, like
--    the reputation panel, only sees rows under open headers: a collapsed
--    "Weapon Skills" hides every weapon skill under it. So the list is read
--    with the headers opened and closed again after, and the result cached
--    -- opening one fires SKILL_LINES_CHANGED, which lands back here, and
--    the cache plus the scanning flag stop that recursing. The cache is
--    dropped on any SKILL_LINES_CHANGED we didn't cause.
--
-- 2. The panel is there but the client has folded the functions into one of
--    the C_ tables. Which table is not something an addon can guess, so the
--    globals are tried first and the C_ tables searched by shape after. The
--    GetSkillLineInfo found that way may answer with a table rather than
--    the old return list; both are normalised below.
--
-- 3. There is no panel at all. Professions are still readable through
--    GetProfessions/GetProfessionInfo, which has no slot for a weapon
--    skill, so weapon skills are rebuilt from the character sheet instead.
----------------------------------------------------------------------
local GetNumSkillLines, GetSkillLineInfo
local skillRows, scanningSkills
local panelAPI                    -- the four panel functions, wherever they live
local skillSource, weaponSource   -- what answered, for /chair tracker api

local function InvalidateSkillRows()
    if not scanningSkills then skillRows = nil end
end
WOWFTrackerNS.InvalidateSkillRows = InvalidateSkillRows

-- This client hands some character-sheet numbers back as secret values:
-- they pass a type() check and then throw the moment they are used.
--
-- Printing is not the whole test. Under a tainted call stack -- which is what
-- an event arriving mid-click through a secure action button leaves behind --
-- a secret formats perfectly happily and then throws on the very next compare,
-- and every one of these numbers is compared before it reaches a row. So the
-- value is formatted and read back, which is what turns a secret into an
-- ordinary number, and the comparison afterwards is what proves it took.
local function Printable(v)
    if type(v) ~= "number" then return nil end
    local ok, plain = pcall(function()
        local n = tonumber(string.format("%d", v))
        if type(n) ~= "number" then return nil end
        -- True of any real number, and the point is that it answers at all.
        if not (n >= 0 or n < 0) then return nil end
        return n
    end)
    return (ok and type(plain) == "number") and plain or nil
end

----------------------------------------------------------------------
-- The panel, wherever it is
----------------------------------------------------------------------
local function FindPanelAPI()
    local function shape(tbl, label)
        if type(tbl) ~= "table" then return nil end
        local ok, num, info, expand, collapse = pcall(function()
            return tbl.GetNumSkillLines, tbl.GetSkillLineInfo,
                   tbl.ExpandSkillHeader, tbl.CollapseSkillHeader
        end)
        if not ok or type(num) ~= "function" or type(info) ~= "function" then
            return nil
        end
        return {
            num      = num,
            info     = info,
            expand   = type(expand) == "function" and expand or nil,
            collapse = type(collapse) == "function" and collapse or nil,
            source   = label,
        }
    end

    local found = shape(_G, "globals")
    if found then return found end

    for name, value in pairs(_G) do
        if type(name) == "string" and name:sub(1, 2) == "C_" then
            found = shape(value, name)
            if found then return found end
        end
    end
end

-- Either the old return list or a table comes back from GetSkillLineInfo;
-- both leave here as name, isHeader, isExpanded, rank, maxRank.
local function SkillLineFields(first, ...)
    if type(first) == "table" then
        return first.skillName or first.name,
               first.isHeader and true or false,
               first.isExpanded ~= false,
               Printable(first.skillRank or first.rank) or 0,
               Printable(first.skillMaxRank or first.maxRank) or 0
    end
    local isHeader, isExpanded, rank, _, _, maxRank = ...
    return first,
           isHeader and true or false,
           isExpanded and true or false,
           Printable(rank) or 0,
           Printable(maxRank) or 0
end

local function PanelCount()
    local ok, n = pcall(panelAPI.num)
    return (ok and Printable(n)) or 0
end

local function PanelLine(i)
    local ok, a, b, c, d, e, f, g = pcall(panelAPI.info, i)
    if not ok then return nil end
    return SkillLineFields(a, b, c, d, e, f, g)
end

-- One row per skill, whatever answered.
--
-- Every source here can name the same skill as another one, and two of them
-- reading the same client is the normal case rather than the odd one: the panel
-- and the character sheet overlap on whatever is equipped, and a client whose
-- own list repeats an entry -- a profession filed under both the primary and the
-- secondary header, which is what one of them does -- repeats it into ours.
-- Each of those was handled where it arose, which meant the next source to do
-- it arrived as a fresh bug. This is the invariant stated once instead.
--
-- The first row wins its place in the order, because that is what the client
-- called the order. A later duplicate is not thrown away blind, though: a row
-- that can measure the skill replaces the numbers on one that could only name
-- it, since between two rows for the same skill the one with a real reading is
-- the answer.
local droppedDuplicates = {}

function WOWFTrackerNS.DroppedDuplicates()
    return droppedDuplicates
end

local function Deduplicate(rows)
    wipe(droppedDuplicates)

    local kept, out = {}, {}

    for _, row in ipairs(rows) do
        if row.isHeader then
            out[#out + 1] = row
        else
            local first = kept[row.name]
            if not first then
                kept[row.name] = row
                out[#out + 1] = row
            else
                droppedDuplicates[row.name] = (droppedDuplicates[row.name] or 1) + 1

                -- A measurement beats a name. Anything else about the later row
                -- is the same skill said twice and is not worth keeping.
                local rank = Printable(row.rank)
                local max = Printable(row.maxRank) or 0
                if first.flat and rank and max > 1 then
                    first.rank, first.maxRank, first.flat = rank, max, nil
                end
            end
        end
    end

    return out
end

-- Dropping rows can leave a header standing over nothing
local function PruneEmptyHeaders(rows)
    local kept = {}
    for i, row in ipairs(rows) do
        local nextRow = rows[i + 1]
        if not row.isHeader or (nextRow and not nextRow.isHeader) then
            kept[#kept + 1] = row
        end
    end
    return kept
end

-- Headers this client showed us shut and gave us no way to open. Everything
-- under one of those is invisible to an addon, however well the rest works --
-- and a weapon skill that is simply out of sight looks exactly like a weapon
-- skill the client does not have.
local unopened = {}

function WOWFTrackerNS.UnopenedHeaders()
    return unopened
end

local function ScanSkillPanel()
    scanningSkills = true
    wipe(unopened)
    local rows, reopened = {}, {}

    local i = 1
    while i <= PanelCount() do
        local name, isHeader, isExpanded, rank, maxRank = PanelLine(i)
        if name then
            -- A row that tops out at one point is a skill this client will
            -- name but not measure: a druid's Feral Combat comes back 1/1
            -- while the client's own panel shows it at 63/65.
            --
            -- That used to mean the row was thrown away, which was too blunt
            -- by half. It cost the skill entirely rather than costing its
            -- numbers, and on a client that reports every weapon skill that
            -- way it emptied the list -- which is exactly what happened. The
            -- row stays; it is marked instead, so its numbers can be replaced
            -- from the character sheet and, failing that, it can be drawn as
            -- a skill that is known rather than a bar that is a lie.
            rows[#rows + 1] = {
                name     = name,
                isHeader = isHeader,
                rank     = rank,
                maxRank  = maxRank,
                flat     = (not isHeader) and maxRank <= 1 or nil,
            }
            -- Opening it inserts its skills directly below, so the walk
            -- carries straight on into them.
            if isHeader and not isExpanded then
                if panelAPI.expand then
                    reopened[name] = true
                    panelAPI.expand(i)
                else
                    unopened[name] = true
                end
            end
        end
        i = i + 1
    end

    -- Bottom up, so closing a header doesn't shift the rows still to visit
    if panelAPI.collapse then
        for j = PanelCount(), 1, -1 do
            local name, isHeader, isExpanded = PanelLine(j)
            if isHeader and isExpanded and reopened[name] then
                panelAPI.collapse(j)
            end
        end
    end

    scanningSkills = false
    return PruneEmptyHeaders(rows)
end

----------------------------------------------------------------------
-- Professions, for a client with no panel
----------------------------------------------------------------------
local function ProfessionRows()
    local rows = {}
    if not (_G.GetProfessions and _G.GetProfessionInfo) then return rows end

    local ok, prof1, prof2, arch, fishing, cooking = pcall(GetProfessions)
    if not ok then return rows end

    -- Varargs, not a table: an unlearned slot comes back nil and would
    -- cut an ipairs walk short at the hole.
    local function add(header, ...)
        local any = false
        for i = 1, select("#", ...) do
            local index = select(i, ...)
            local name, rank, maxRank
            if index then
                local got, n, _, r, m = pcall(GetProfessionInfo, index)
                if got then name, rank, maxRank = n, r, m end
            end
            if name then
                if not any then
                    rows[#rows + 1] = { name = header, isHeader = true }
                    any = true
                end
                rows[#rows + 1] = {
                    name     = name,
                    isHeader = false,
                    rank     = Printable(rank) or 0,
                    maxRank  = Printable(maxRank) or 0,
                }
            end
        end
    end

    add("Professions", prof1, prof2)
    add("Secondary Skills", arch, fishing, cooking)
    return rows
end

----------------------------------------------------------------------
-- Weapon skills with no panel to read them from
-- The character sheet still knows the skill behind what is equipped:
-- UnitAttackBothHands gives the two melee hands, UnitRangedAttack the
-- ranged slot and UnitDefense defence, all against a cap of five per level.
-- What names the skill is the equipped item's subclass, and an empty hand
-- is Unarmed.
--
-- That only ever covers what is held right now, so every rank read is
-- remembered per character: a weapon put away keeps its bar at the last
-- rank seen instead of dropping out of the list. Nothing is invented -- a
-- skill appears once it has been equipped at least once.
----------------------------------------------------------------------
local WEAPON_HEADER = "Weapon Skills"

local function RememberedWeaponSkills()
    local db = WOWFTrackerDB
    if type(db) ~= "table" then return {} end
    db.weaponSkills = db.weaponSkills or {}
    return db.weaponSkills
end

local function EquippedSkillName(slot)
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok or type(link) ~= "string" then return nil end

    local itemInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    local got, _, _, _, _, _, _, subType = pcall(itemInfo, link)
    if not got or type(subType) ~= "string" then return nil end

    return (WOWFTracker_WeaponSkills or {})[subType]
end

-- A druid in cat or bear form swings with Feral Combat rather than with
-- whatever is in their hands, so while they are shifted the melee numbers
-- on the sheet are that skill's. It is the one weapon skill no item names.
--
-- The form is matched against the client's own constants, not against
-- numbers of our own: the IDs have moved between versions, the names have
-- not, and a client without them simply reports no feral form.
local FERAL_FORMS = { "CAT_FORM", "BEAR_FORM", "DIRE_BEAR_FORM" }

local function FeralFormActive()
    local okClass, _, class = pcall(UnitClass, "player")
    if not okClass or class ~= "DRUID" then return false end

    local okForm, formID = pcall(GetShapeshiftFormID)
    formID = okForm and Printable(formID) or nil
    if not formID then return false end

    for _, name in ipairs(FERAL_FORMS) do
        if Printable(_G[name]) == formID then return true end
    end
    return false
end

-- What the character sheet says right now, written into the remembered table.
-- Returns how many ranks moved: the row builder does not care, and the poll
-- below is entirely about that number.
local function RecordSheetSkills()
    local remembered = RememberedWeaponSkills()
    local changed = 0

    local function record(name, value)
        local rank = Printable(value)
        if name and rank and rank > 0 and remembered[name] ~= rank then
            remembered[name] = rank
            changed = changed + 1
        end
    end

    -- UnitDefense is gone here; UnitDefenseSkill is what this client kept, and
    -- the probe found it by name. Both are tried, newest first, because which
    -- one a client has is not something to assume.
    -- Written out rather than walked with ipairs: a client missing the first
    -- of them leaves a hole at index one, and ipairs stops at a hole -- so the
    -- second would never be tried, which is how Defense went missing on a
    -- client that had a perfectly good way to answer.
    local function ReadDefense(fn)
        if type(fn) ~= "function" then return nil end
        local ok, base = pcall(fn, "player")
        if not ok then return nil end
        return Printable(base)
    end

    record("Defense", ReadDefense(_G.UnitDefenseSkill) or ReadDefense(_G.UnitDefense))

    local okMelee, mainBase, _, offBase = pcall(UnitAttackBothHands, "player")
    if okMelee then
        if FeralFormActive() then
            record("Feral Combat", mainBase)
        else
            record(EquippedSkillName(16) or "Unarmed", mainBase)
            record(EquippedSkillName(17), offBase)
        end
    end

    local okRanged, rangedBase = pcall(UnitRangedAttack, "player")
    if okRanged then record(EquippedSkillName(18), rangedBase) end

    return changed
end

local function DerivedWeaponRows()
    local okLevel, level = pcall(UnitLevel, "player")
    local maxRank = ((okLevel and Printable(level)) or 0) * 5
    if maxRank <= 0 then return {} end

    RecordSheetSkills()
    local remembered = RememberedWeaponSkills()

    local rows = {}
    for name, stored in pairs(remembered) do
        -- Anything an older build left in here is checked too, since the
        -- table outlives the session that filled it.
        local rank = Printable(stored)
        if rank then
            rows[#rows + 1] = {
                name     = name,
                isHeader = false,
                rank     = math.min(rank, maxRank),
                maxRank  = maxRank,
            }
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

----------------------------------------------------------------------
-- The client's own Skills window
----------------------------------------------------------------------
-- Last resort, and on this client the only thing that knows.
--
-- The probe found SkillsFrame, SkillsEntryMixin, SkillsBarMixin and friends:
-- there is a Skills panel here, it lists weapon skills, and it shows real
-- numbers -- while the API an addon is supposed to ask hands back five trade
-- skills and nothing else. So the numbers are asked of the window that has
-- them.
--
-- Reading another addon's frames is a last resort and this is Blizzard's, but
-- the alternative is telling someone their weapon skills do not exist while
-- they are looking at them. Every step is guarded: a window built differently
-- than expected costs this source and nothing else.
--
-- Three shapes are tried, because a modern list frame can hold its data in any
-- of them and there is no documentation to consult for this client.

local function EntryFields(entry)
    if type(entry) ~= "table" then return nil end

    local label = entry.skillName or entry.name or entry.label
    local rank = entry.skillRank or entry.rank or entry.value or entry.current
    local max = entry.skillMaxRank or entry.maxRank or entry.max
        or entry.maxValue or entry.skillMax

    if type(label) ~= "string" or label == "" then return nil end

    rank = Printable(rank)
    max = Printable(max)
    if not (rank and max) or max <= 0 then return nil end

    return { name = label, rank = rank, maxRank = max, isHeader = false }
end

-- Reading the window by what it says, rather than by what it stores.
--
-- Three guesses at the field names inside SkillsFrame all missed, and there is
-- no documentation for this client to check them against. What is not in doubt
-- is what is on screen: every row shows its name and "48 / 80". That text is
-- the data, and a FontString will hand it over whatever the fields behind it
-- are called.
--
-- Rows are found by looking for the smallest frame that contains exactly one
-- "number / number" -- which is a row, because a container holding six of them
-- contains six. The name is then the other text in that same frame.
local VALUE_PATTERN = "^%s*(%d+)%s*/%s*(%d+)%s*$"

local function TextsUnder(frame, depth, out)
    if depth > 6 or type(frame) ~= "table" then return out end

    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if ok then
        for _, region in ipairs(regions) do
            local got, text = pcall(function()
                return region.GetText and region:GetText()
            end)
            if got and type(text) == "string" and text ~= "" then
                out[#out + 1] = text
            end
        end
    end

    local fine, children = pcall(function() return { frame:GetChildren() } end)
    if fine then
        for _, child in ipairs(children) do TextsUnder(child, depth + 1, out) end
    end

    return out
end

local function ScrapeSkillsFrame()
    local frame = _G.SkillsFrame
    if type(frame) ~= "table" then return nil end

    local rows = {}

    local function Visit(node, depth)
        if depth > 6 or type(node) ~= "table" then return end

        local texts = TextsUnder(node, 0, {})
        local values, names = {}, {}

        for _, text in ipairs(texts) do
            local rank, max = text:match(VALUE_PATTERN)
            if rank then
                values[#values + 1] = { rank = tonumber(rank), max = tonumber(max) }
            else
                -- Colour codes and the like are how a client dresses a label;
                -- the words underneath are the name.
                local clean = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                clean = clean:match("^%s*(.-)%s*$")
                if clean ~= "" then names[#names + 1] = clean end
            end
        end

        -- Exactly one number pair means this is a row rather than the box the
        -- rows are sitting in.
        if #values == 1 and #names > 0 then
            local value = values[1]
            if value.max > 0 then
                rows[#rows + 1] = {
                    name = names[1],
                    rank = value.rank,
                    maxRank = value.max,
                    isHeader = false,
                }
            end
            return
        end

        local ok, children = pcall(function() return { node:GetChildren() } end)
        if ok then
            for _, child in ipairs(children) do Visit(child, depth + 1) end
        end
    end

    Visit(frame, 0)
    if #rows == 0 then return nil end
    return rows
end

local function FromSkillsFrame()
    local frame = _G.SkillsFrame
    if type(frame) ~= "table" then return nil end

    local found = {}

    local function Take(entry)
        local row = EntryFields(entry)
        if row and not found[row.name] then found[row.name] = row end
    end

    -- A modern scroll list keeps its rows in a data provider.
    local box = frame.ScrollBox or frame.scrollBox or frame.SkillsScrollBox
    if box then
        local ok, provider = pcall(function()
            return box.GetDataProvider and box:GetDataProvider()
        end)
        if ok and type(provider) == "table" then
            pcall(function()
                for _, entry in provider:Enumerate() do
                    Take(entry)
                    Take(entry and entry.data)
                end
            end)
        end

        -- Failing that, the frames it has made are on screen and carry the
        -- same values.
        pcall(function()
            if box.GetFrames then
                for _, child in ipairs(box:GetFrames()) do
                    Take(child)
                    Take(child and child.elementData)
                    Take(child and child.data)
                end
            end
        end)
    end

    -- And the oldest shape of all: a plain list hanging off the frame.
    for _, key in ipairs({ "skills", "entries", "lines", "data" }) do
        local list = frame[key]
        if type(list) == "table" then
            pcall(function()
                for _, entry in pairs(list) do Take(entry) end
            end)
        end
    end

    local rows = {}
    for _, row in pairs(found) do rows[#rows + 1] = row end

    -- Nothing came out of the fields, so read what the window is showing.
    if #rows == 0 then
        rows = ScrapeSkillsFrame() or {}
    end

    if #rows == 0 then return nil end

    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end
WOWFTrackerNS.ReadSkillsFrame = FromSkillsFrame
WOWFTrackerNS.ScrapeSkillsFrame = ScrapeSkillsFrame

-- The window only holds rows once it has been opened, and opening it is not an
-- event this addon hears about. Without this the list is whatever was readable
-- at login -- which is nothing, because nobody has opened their skills panel
-- by then -- and it stays that way for the session however many times the
-- panel is looked at afterwards.
--
-- The panel itself may arrive late too: a client loads that kind of window on
-- demand, so the hook is attempted again until it takes.
local skillsWindowHooked = false

local function HookSkillsWindow()
    if skillsWindowHooked then return true end

    local frame = _G.SkillsFrame
    if type(frame) ~= "table" or not frame.HookScript then return false end

    local ok = pcall(frame.HookScript, frame, "OnShow", function()
        InvalidateSkillRows()

        -- Shown and filled are not the same moment: the rows are built after
        -- the frame appears, so the list is thrown away again once they exist.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.3, function()
                InvalidateSkillRows()
                if WOWFTrackerNS.UpdateReputation then
                    WOWFTrackerNS.UpdateReputation()
                end
            end)
        end
    end)

    skillsWindowHooked = ok and true or false
    return skillsWindowHooked
end
WOWFTrackerNS.HookSkillsWindow = HookSkillsWindow

----------------------------------------------------------------------
-- Getting the numbers without the window
----------------------------------------------------------------------
-- The state of things this is here to fix: every weapon skill except the ones
-- currently in hand is invisible until the player opens their skills panel.
-- The character sheet answers for what is equipped and nothing else, the skill
-- API on this client answers with spell tabs at 1/1, and the only thing that
-- knows the rest is Blizzard's own Skills window -- which holds no rows until
-- it has been shown once. So the list is short at login, fills in when the
-- panel is opened, and is short again next login, because the saved file this
-- client writes is not read back either.
--
-- The window does not have to be looked at, though. It only has to have run.
-- Five things are tried, cheapest and least invasive first, and the walk stops
-- the moment rows come out:
--
--   1. load it, if it is the kind of window a client only loads when wanted
--   2. ask it -- it may have been filled already, by the player or by us
--   3. call its own update, which is what filling it consists of
--   4. run its OnShow without showing it, which is the same thing one step up
--   5. show it parented to something hidden, which is the only way to get rows
--      that are read off what is drawn rather than out of a data provider
--
-- Steps 3 to 5 are reaching into Blizzard's frame, and 5 reaches furthest: it
-- moves the frame. So 5 happens once a session, never while the panel is open,
-- never in combat -- the one state where a taint of our making could cost
-- something -- and everything is put back afterwards, anchors included.
--
-- What comes out is written into the same per-character table the character
-- sheet writes into. That is the part that matters: after one warm the ranks
-- are answers this addon holds, not answers the window holds, so they keep
-- being drawn whether or not anything ever opens it again.

local warmParent
local warmSteps = {}        -- what each attempt did, for /chair tracker weapons
local warmedHidden = false  -- step 5, once a session
local filledOnce = false    -- whether any step has ever produced rows
local warming = false
local lastWarm = 0
local WARM_GAP = 5          -- seconds between unforced warms

local function Note(step, outcome, rows)
    warmSteps[#warmSteps + 1] = {
        step = step, outcome = outcome or "?", rows = rows or 0,
    }
end

function WOWFTrackerNS.WarmReport()
    return warmSteps, warmedHidden
end

-- Rows the panel gave us, kept as this addon's own answer. A row the panel
-- named but could not measure is not an answer, so a flat 1/1 is not stored.
local function RememberWeaponRows(rows)
    local weapons = WOWFTracker_WeaponSkillNames or {}
    local remembered = RememberedWeaponSkills()
    local fresh = 0

    for _, row in ipairs(rows or {}) do
        if not row.isHeader and weapons[row.name] then
            local rank = Printable(row.rank)
            local max = Printable(row.maxRank) or 0
            if rank and rank > 0 and max > 1 then
                if remembered[row.name] == nil then fresh = fresh + 1 end
                remembered[row.name] = rank
            end
        end
    end

    return fresh
end
WOWFTrackerNS.RememberWeaponRows = RememberWeaponRows

local function PanelRows()
    local rows = FromSkillsFrame()
    return rows, rows and #rows or 0
end

-- 1. The window itself, if the client has not loaded it yet. Which addon holds
--    it has been renamed more than once, so the usual names are all tried and a
--    client with none of them costs this step and nothing else.
-- Only names that are the skills window itself. Blizzard_CharacterUI was in
-- this list and came straight back out: loading a broad panel addon to get at
-- one window re-initialises whatever else it owns, and the profession list
-- coming back doubled is exactly the kind of bill that arrives for it.
local SKILLS_ADDONS = {
    "Blizzard_Skills", "Blizzard_SkillsUI", "Blizzard_SkillsFrame",
}

local function LoadSkillsAddOn()
    if type(_G.SkillsFrame) == "table" then return "already loaded" end

    local load = (_G.C_AddOns and _G.C_AddOns.LoadAddOn)
        or _G.LoadAddOn or _G.UIParentLoadAddOn
    if type(load) ~= "function" then return "nothing to load it with" end

    for _, name in ipairs(SKILLS_ADDONS) do
        pcall(load, name)
        if type(_G.SkillsFrame) == "table" then return name end
    end

    return "none of the usual names"
end

-- 3. Filling the window is what its own update does, so the update is called
--    directly. Nothing here is documented for this client; the names are the
--    ones a window of this kind has had, and a miss costs a pcall.
local REFRESH_METHODS = {
    "Update", "UpdateSkills", "Refresh", "RefreshSkills", "FullUpdate",
    "Initialize", "Init", "InitSkills", "Populate", "UpdateLayout",
}

local REFRESH_GLOBALS = {
    "SkillsFrame_Update", "SkillsFrame_OnShow", "SkillsFrame_LoadUI",
    "SkillFrame_Update", "SkillFrame_OnShow",
}

local function CallUpdates(frame)
    local called = {}

    for _, name in ipairs(REFRESH_METHODS) do
        local method = frame[name]
        if type(method) == "function" then
            if pcall(method, frame) then called[#called + 1] = ":" .. name end
        end
    end

    for _, name in ipairs(REFRESH_GLOBALS) do
        local fn = _G[name]
        if type(fn) == "function" then
            if pcall(fn, frame) then called[#called + 1] = name end
        end
    end

    if #called == 0 then return "nothing by any of the usual names" end
    local ok, line = pcall(table.concat, called, " ")
    return ok and line or "some of them"
end

-- 4. The same work one step further up: whatever the window does when it
--    appears, done without it appearing. Our own hook is in there too, which is
--    harmless -- it drops the cached list, which is what we want anyway.
local function RunOnShow(frame)
    local ok, script = pcall(frame.GetScript, frame, "OnShow")
    if not ok or type(script) ~= "function" then return "it has no OnShow" end
    if not pcall(script, frame) then return "its OnShow threw" end
    return "ran"
end

-- 5. Shown, but parented to a frame that is hidden, so nothing reaches the
--    screen. The last resort, and the only one that can produce rows read off
--    what is drawn -- a scrolling list makes no row frames until it is asked to
--    lay itself out.
local function ShowHidden(frame, harvest)
    local okShown, shown = pcall(frame.IsShown, frame)
    if okShown and shown then return "the panel is open -- left alone" end

    local okCombat, inCombat = pcall(_G.UnitAffectingCombat, "player")
    if okCombat and inCombat then return "in combat -- not now" end

    local okParent, previous = pcall(frame.GetParent, frame)
    if not okParent then return "its parent could not be read" end

    -- Every anchor it had, so moving it can be undone. A frame that comes back
    -- from this unanchored is a window that opens in the wrong place for the
    -- rest of the session, which is worse than the thing being fixed.
    local points = {}
    pcall(function()
        for i = 1, (frame:GetNumPoints() or 0) do
            points[#points + 1] = { frame:GetPoint(i) }
        end
    end)

    warmParent = warmParent or CreateFrame("Frame", nil, UIParent)
    warmParent:Hide()

    if not pcall(frame.SetParent, frame, warmParent) then
        return "it would not be reparented"
    end

    pcall(frame.Show, frame)

    -- Read while it is up, not after. A scrolling list makes its row frames
    -- when it is shown and is entitled to unmake them when it is hidden, and
    -- for that client this is the only moment the numbers exist at all.
    local count = harvest and harvest() or 0

    pcall(frame.Hide, frame)

    pcall(frame.SetParent, frame, previous or UIParent)
    if #points > 0 then
        pcall(function()
            frame:ClearAllPoints()
            for _, point in ipairs(points) do frame:SetPoint(unpack(point)) end
        end)
    end

    warmedHidden = true
    return "shown out of sight", count
end

-- force skips the throttle and lets step 5 run again, which is what
-- /chair tracker weapons warm is for.
function WOWFTrackerNS.WarmSkills(force)
    if warming then return 0 end

    local okTime, now = pcall(GetTime)
    now = (okTime and Printable(now)) or 0
    if not force and lastWarm > 0 and now > 0 and now - lastWarm < WARM_GAP then
        return 0
    end

    warming = true
    wipe(warmSteps)
    if now > 0 then lastWarm = now end

    local learned = 0

    local function Harvest(label, outcome)
        local rows, count = PanelRows()
        Note(label, outcome, count)
        if count > 0 then
            filledOnce = true
            learned = learned + RememberWeaponRows(rows)
            return true
        end
        return false
    end

    Note("load the window", LoadSkillsAddOn())

    local frame = _G.SkillsFrame
    if type(frame) ~= "table" then
        Note("ask it", "there is no SkillsFrame on this client", 0)
    else
        -- Asking first is right the first time and wrong afterwards: once the
        -- window holds rows, reading them again hands back the snapshot it was
        -- filled with, however old. A later warm wants it to recompute, so the
        -- update goes first and the ask comes after it.
        local done = false
        if not filledOnce then
            done = Harvest("ask it", "asked as it stands")
        end
        if not done then done = Harvest("call its update", CallUpdates(frame)) end
        if not done then done = Harvest("run its OnShow", RunOnShow(frame)) end

        if not done and (force or not warmedHidden) then
            local outcome, count = ShowHidden(frame, function()
                local rows, found = PanelRows()
                if found > 0 then learned = learned + RememberWeaponRows(rows) end
                return found
            end)
            Note("show it out of sight", outcome, count or 0)

            -- Only if nothing was readable while it was up: a window that keeps
            -- its rows afterwards is worth one more ask, and a window that does
            -- not has already been read.
            if (count or 0) == 0 then
                Harvest("ask it again", "after being shown")
            end
        end
    end

    warming = false

    -- Only if something was learned: an invalidation that changes nothing is a
    -- full rebuild of every row on screen for no reason, and this runs on a
    -- skill-up.
    if learned > 0 then InvalidateSkillRows() end
    return learned
end

----------------------------------------------------------------------
-- Weapon skills, as they happen
----------------------------------------------------------------------
-- A weapon skill goes up mid-swing and nothing here hears about it. The events
-- that ought to say so are CHAT_MSG_SKILL and SKILL_LINES_CHANGED, and on this
-- client both of them hang off the same skill-line machinery that answers with
-- spell tabs at one point out of one -- so a sword going from 150 to 151 arrives
-- as nothing at all, and the bar sits at 150 until something unrelated happens
-- to rebuild the list.
--
-- Rather than guess at which other event this client might fire, the three
-- numbers the character sheet answers for are simply read on a timer. That is
-- the whole cost: UnitAttackBothHands, UnitRangedAttack and UnitDefenseSkill,
-- once every couple of seconds, and a redraw only when one of them moved. It
-- covers the case that matters -- you skill up the weapon you are holding, and
-- the sheet knows about that one without any window being open.
--
-- It does not cover a skill for something not in hand. Nothing can: the sheet
-- has no answer for it and the panel is a snapshot. That is what the warm is
-- for, and why the warm reruns on a skill-up too.

local SKILL_POLL = 2
local sincePoll = 0
local skillPoll = CreateFrame("Frame")

-- Returns true if the list was rebuilt, which is what the tests ask and what
-- makes the timer below cheap to reason about: no change, no work.
function WOWFTrackerNS.PollWeaponSkills()
    if not RecordSheetSkills then return false end
    if RecordSheetSkills() == 0 then return false end

    InvalidateSkillRows()
    if WOWFTrackerNS.UpdateReputation then WOWFTrackerNS.UpdateReputation() end
    return true
end

skillPoll:SetScript("OnUpdate", function(_, elapsed)
    sincePoll = sincePoll + (elapsed or 0)
    if sincePoll < SKILL_POLL then return end
    sincePoll = 0

    -- Before the database is in, the remembered table is a throwaway and
    -- writing to it would be work with nowhere to land.
    if not (WOWFTrackerDB and type(WOWFTrackerDB) == "table") then return end
    WOWFTrackerNS.PollWeaponSkills()
end)

----------------------------------------------------------------------
-- The list the rest of the addon reads
----------------------------------------------------------------------
-- Has the panel given us a weapon skill it can actually measure? A row it
-- names but reports as 1/1 does not count: the character sheet may still be
-- able to say what that skill really is, and the whole point of asking is to
-- get a number.
local function HasWeaponRow(rows)
    local weapons = WOWFTracker_WeaponSkillNames or {}
    for _, row in ipairs(rows) do
        if not row.isHeader and weapons[row.name] and not row.flat then
            return true
        end
    end
    return false
end

local function BuildRows()
    -- Cheap, and the only place it can be done before the answer is used.
    HookSkillsWindow()

    local rows = panelAPI and ScanSkillPanel() or ProfessionRows()

    -- Whatever answered, if there is no weapon skill in it then this client
    -- isn't offering them that way, and they come off the character sheet.
    if HasWeaponRow(rows) then
        weaponSource = "panel"

        -- Even then, a row the panel named but did not measure is worth a
        -- second opinion: Feral Combat arrives flat next to a Daggers the
        -- panel measured perfectly well.
        local derived = {}
        for _, row in ipairs(DerivedWeaponRows()) do derived[row.name] = row end

        for _, row in ipairs(rows) do
            if row.flat and derived[row.name] then
                row.rank = derived[row.name].rank
                row.maxRank = derived[row.name].maxRank
                row.flat = nil
            end
        end
    else
        -- The weapon names above are the English ones, so on a localised
        -- client a panel row could go unrecognised and be rebuilt a second
        -- time. A name already in the list is left alone whatever it is.
        -- A flat row is a name the panel gave us with no number behind it, so
        -- the derived one replaces it rather than sitting beside it.
        local already, flatRows = {}, {}
        for _, row in ipairs(rows) do
            if not row.isHeader then
                if row.flat then
                    flatRows[row.name] = row
                else
                    already[row.name] = true
                end
            end
        end

        -- The character sheet first, since it needs nothing on screen, then
        -- the client's own Skills window for whatever the sheet could not say.
        local derived = DerivedWeaponRows()

        local weapons = WOWFTracker_WeaponSkillNames or {}
        local byName = {}
        for _, row in ipairs(derived) do byName[row.name] = true end

        for _, row in ipairs(FromSkillsFrame() or {}) do
            if weapons[row.name] and not byName[row.name] then
                derived[#derived + 1] = row
                byName[row.name] = true
            end
        end

        local added = 0
        for _, row in ipairs(derived) do
            local flat = flatRows[row.name]
            if flat then
                flat.rank, flat.maxRank, flat.flat = row.rank, row.maxRank, nil
                already[row.name] = true
            end

            if not already[row.name] then
                if added == 0 then
                    rows[#rows + 1] = { name = WEAPON_HEADER, isHeader = true }
                end
                rows[#rows + 1] = row
                added = added + 1
            end
        end
        weaponSource = added > 0 and "derived" or "none"
    end

    -- Last, so it covers every source above and anything added after them, and
    -- the prune afterwards because dropping a duplicate can leave the header it
    -- was under standing over nothing.
    return PruneEmptyHeaders(Deduplicate(rows))
end

-- Mid-scan the panel is half open, so callers reaching here from the event
-- that fires get the previous list. The scan that provoked them redraws
-- with the full one as soon as it returns.
local function SkillRowList()
    if skillRows then return skillRows end
    if scanningSkills then return {} end
    skillRows = BuildRows()
    return skillRows
end

GetNumSkillLines = function() return #SkillRowList() end
GetSkillLineInfo = function(i)
    local row = SkillRowList()[i]
    if not row then return nil end
    -- name, isHeader, isExpanded, rank, numTempPoints, modifier, maxRank
    return row.name, row.isHeader, true, row.rank or 0, 0, 0, row.maxRank or 0
end

-- Whether this client would only name that skill, not measure it.
function WOWFTrackerNS.SkillIsFlat(name)
    for _, row in ipairs(SkillRowList()) do
        if not row.isHeader and row.name == name then return row.flat == true end
    end
    return false
end

panelAPI = FindPanelAPI()
skillSource = panelAPI and panelAPI.source
    or ((_G.GetProfessions and _G.GetProfessionInfo) and "professions" or "none")

-- For /chair tracker api: which of the three clients above this one turned out to be
function WOWFTrackerNS.SkillSource()
    return skillSource, weaponSource or "unread"
end

local ADDON_NAME   = "WOWFTracker"
local HEADER_HEIGHT = 22

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function DB()       return WOWFTrackerDB end
local function Settings() return WOWFTrackerDB.settings end
local function Factions() return WOWFTrackerDB.factions end

----------------------------------------------------------------------
-- Main anchor frame
----------------------------------------------------------------------
local anchor = CreateFrame("Frame", "WOWFTrackerFrame", UIParent, "BackdropTemplate")
anchor:SetClampedToScreen(true)
anchor:SetFrameStrata("MEDIUM")
anchor:SetPoint("CENTER")
WOWFTrackerNS.anchor = anchor

----------------------------------------------------------------------
-- Title bar
----------------------------------------------------------------------
local titleBar = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titleBar:SetPoint("LEFT", anchor, "LEFT", 8, 0)
titleBar:SetText("|cff88aaddChairTracker|r")

----------------------------------------------------------------------
-- Collapse / expand button
----------------------------------------------------------------------
local collapseBtn = CreateFrame("Button", nil, anchor)
collapseBtn:SetSize(14, 14)
collapseBtn:SetPoint("RIGHT", anchor, "RIGHT", -22, 0)
collapseBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Up")
collapseBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
collapseBtn:SetScript("OnClick", function()
    anchor.collapsed = not anchor.collapsed
    if anchor.collapsed then
        anchor.barContainer:SetAlpha(0)
        anchor.barContainer:Hide()
    else
        anchor.barContainer:Show()
        anchor.barContainer:SetAlpha(1)
        WOWFTrackerNS.UpdateReputation()
    end
end)

----------------------------------------------------------------------
-- Settings / gear button
----------------------------------------------------------------------
local gearBtn = CreateFrame("Button", nil, anchor)
gearBtn:SetSize(14, 14)
gearBtn:SetPoint("RIGHT", anchor, "RIGHT", -5, 0)
gearBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
gearBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
gearBtn:SetScript("OnClick", function()
    if WOWFTrackerNS.ToggleOptions then WOWFTrackerNS.ToggleOptions() end
end)

----------------------------------------------------------------------
-- Container for bars
----------------------------------------------------------------------
local container = CreateFrame("Frame", nil, anchor, "BackdropTemplate")
container:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -1)
container:SetSize(200, 10)
anchor.barContainer = container

----------------------------------------------------------------------
-- Fade engine (no dependency on UIFrameFade)
----------------------------------------------------------------------
local fadeFrame = CreateFrame("Frame")
local activeFades = {}

local function StartFade(frame, fromAlpha, toAlpha, duration, onFinish)
    activeFades[frame] = {
        from     = fromAlpha,
        to       = toAlpha,
        duration = duration,
        elapsed  = 0,
        onFinish = onFinish,
    }
    frame:SetAlpha(fromAlpha)
    if not frame:IsShown() then frame:Show() end
    fadeFrame:SetScript("OnUpdate", function(self, dt)
        local any = false
        for f, info in pairs(activeFades) do
            info.elapsed = info.elapsed + dt
            local pct = math.min(info.elapsed / info.duration, 1)
            local alpha = info.from + (info.to - info.from) * pct
            f:SetAlpha(alpha)
            if pct >= 1 then
                activeFades[f] = nil
                if info.onFinish then info.onFinish() end
            else
                any = true
            end
        end
        if not any then self:SetScript("OnUpdate", nil) end
    end)
end

----------------------------------------------------------------------
-- Auto-hide state
----------------------------------------------------------------------
local autoHideTimer   = nil
local isContainerShown = true

local function FadeContainerIn()
    if anchor.collapsed then return end
    local s = Settings()
    if not s then return end
    if autoHideTimer then autoHideTimer:Cancel(); autoHideTimer = nil end
    if isContainerShown then return end
    isContainerShown = true
    StartFade(container, container:GetAlpha(), 1, s.fadeTime)
end

local function FadeContainerOut()
    if anchor.collapsed then return end
    local s = Settings()
    if not s then return end
    isContainerShown = false
    StartFade(container, container:GetAlpha(), 0, s.fadeTime, function()
        -- don't hide so mouse can still detect entry
    end)
end

local function ScheduleAutoHide()
    local s = Settings()
    if not s or not s.autoHide then return end
    if autoHideTimer then autoHideTimer:Cancel() end
    autoHideTimer = C_Timer.NewTimer(s.showTime, function()
        autoHideTimer = nil
        FadeContainerOut()
    end)
end

----------------------------------------------------------------------
-- Hover detection zone (covers anchor + container area)
----------------------------------------------------------------------
local hoverZone = CreateFrame("Frame", nil, anchor)
hoverZone:SetPoint("TOPLEFT", anchor, "TOPLEFT")
hoverZone:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT")
hoverZone:EnableMouse(false) -- don't eat clicks, we just poll

local hoverPoll = CreateFrame("Frame")
local wasHovering = false

local function IsMouseOverTracker()
    return anchor:IsMouseOver() or container:IsMouseOver()
end

hoverPoll:SetScript("OnUpdate", function(self, dt)
    if not WOWFTrackerDB or not WOWFTrackerDB.settings then return end
    if WOWFTrackerNS.docked then
        if WOWFTrackerNS.DockPoll then WOWFTrackerNS.DockPoll() end
        return
    end
    if not WOWFTrackerDB.settings.autoHide then return end
    if anchor.collapsed then return end

    local hovering = IsMouseOverTracker()
    if hovering and not wasHovering then
        -- mouse entered
        FadeContainerIn()
    elseif not hovering and wasHovering then
        -- mouse left
        ScheduleAutoHide()
    end
    wasHovering = hovering
end)

----------------------------------------------------------------------
-- Bar pool
----------------------------------------------------------------------
local bars = {}

local function CreateBar(index)
    local s = Settings()
    local bar = CreateFrame("StatusBar", nil, container)
    bar:SetSize(s.barWidth, s.barHeight)
    bar:SetStatusBarTexture(s.barTexture)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.1, 0.1, 0.12, 0.9)
    bar.bg = bg

    bar.nameText = bar:CreateFontString(nil, "OVERLAY")
    bar.nameText:SetFont(s.fontFace, s.fontSize, "OUTLINE")
    bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
    bar.nameText:SetJustifyH("LEFT")

    bar.valueText = bar:CreateFontString(nil, "OVERLAY")
    bar.valueText:SetFont(s.fontFace, s.fontSize, "OUTLINE")
    bar.valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    bar.valueText:SetJustifyH("RIGHT")

    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

        -- Header line
        if self.tipTitle then
            GameTooltip:AddLine(self.tipTitle, 1, 0.82, 0)
        end
        -- Progress line
        if self.tipProgress then
            GameTooltip:AddLine(self.tipProgress, 1, 1, 1)
        end

        -- Dungeon guide (reputations only)
        if self.tipDungeons then
            for _, line in ipairs(self.tipDungeons) do
                GameTooltip:AddLine(line.text, line.r, line.g, line.b, true)
            end
        end

        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", GameTooltip_Hide)

    -- Standing tick marks (shown in total-to-Exalted mode)
    -- 3 ticks: Neutral/Friendly, Friendly/Honored, Honored/Revered
    bar.ticks = {}
    for t = 1, 3 do
        local tick = bar:CreateTexture(nil, "OVERLAY")
        tick:SetTexture("Interface\\Buttons\\WHITE8X8")
        tick:SetVertexColor(1, 1, 1, 0.35)
        tick:SetSize(1, 1)
        tick:Hide()
        bar.ticks[t] = tick
    end

    bars[index] = bar
    return bar
end

----------------------------------------------------------------------
-- Rebuild appearance from settings
----------------------------------------------------------------------
function WOWFTrackerNS.RebuildAppearance()
    local s = Settings()

    anchor:SetSize(s.barWidth + 10, HEADER_HEIGHT)
    anchor:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    anchor:SetBackdropColor(0.05, 0.05, 0.08, s.bgAlpha)
    anchor:SetBackdropBorderColor(0.4, 0.4, 0.5, s.borderAlpha)

    if s.showHeader then
        anchor:SetAlpha(s.frameAlpha or 1.0)
    else
        anchor:SetAlpha((s.frameAlpha or 1.0) * 0.3)
    end

    if s.locked then
        anchor:SetMovable(false)
        anchor:EnableMouse(false)
    else
        anchor:SetMovable(true)
        anchor:EnableMouse(true)
        anchor:RegisterForDrag("LeftButton")
        anchor:SetScript("OnDragStart", anchor.StartMoving)
        anchor:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, _, relPoint, x, y = self:GetPoint()
            DB().position = { point = point, relPoint = relPoint, x = x, y = y }
        end)
    end

    container:SetSize(s.barWidth + 10, 10)
    container:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    container:SetBackdropColor(0.05, 0.05, 0.08, s.bgAlpha * 0.9)
    container:SetBackdropBorderColor(0.4, 0.4, 0.5, s.borderAlpha * 0.85)

    for _, bar in ipairs(bars) do
        bar:SetSize(s.barWidth, s.barHeight)
        bar:SetStatusBarTexture(s.barTexture)
        bar.nameText:SetFont(s.fontFace, s.fontSize, "OUTLINE")
        bar.valueText:SetFont(s.fontFace, s.fontSize, "OUTLINE")
        bar.nameText:SetWidth(s.barWidth * 0.55)
    end

    -- Apply auto-hide initial state
    if s.autoHide and not anchor.collapsed then
        isContainerShown = false
        container:SetAlpha(0)
    else
        isContainerShown = true
        container:SetAlpha(1)
    end

    WOWFTrackerNS.UpdateReputation()
end

----------------------------------------------------------------------
-- Window visibility toggle (persists across sessions)
----------------------------------------------------------------------
function WOWFTrackerNS.SetWindowVisible(visible)
    local s = Settings()
    if not s then return end
    s.windowVisible = visible
    -- Living in the OSD, the window only ever opens from there. The choice is
    -- remembered for when it comes out again.
    if WOWFTrackerNS.docked then return end
    if visible then
        anchor:Show()
        container:Show()
        if s.autoHide then
            isContainerShown = false
            container:SetAlpha(0)
        else
            isContainerShown = true
            container:SetAlpha(1)
        end
        anchor.collapsed = false
        WOWFTrackerNS.UpdateReputation()
    else
        anchor:Hide()
    end
end

function WOWFTrackerNS.ToggleWindow()
    local s = Settings()
    if not s then return end
    WOWFTrackerNS.SetWindowVisible(not s.windowVisible)
end

----------------------------------------------------------------------
-- Sorting
----------------------------------------------------------------------
local function SortEntries(entries)
    local s = Settings()
    local mode = s.sortMode or "name_asc"

    if mode == "name_asc" then
        table.sort(entries, function(a, b) return a.name < b.name end)

    elseif mode == "name_desc" then
        table.sort(entries, function(a, b) return a.name > b.name end)

    elseif mode == "standing_desc" then
        table.sort(entries, function(a, b)
            if a.standing == b.standing then
                return a.progressPct > b.progressPct
            end
            return a.standing > b.standing
        end)

    elseif mode == "standing_asc" then
        table.sort(entries, function(a, b)
            if a.standing == b.standing then
                return a.progressPct < b.progressPct
            end
            return a.standing < b.standing
        end)

    elseif mode == "progress" then
        table.sort(entries, function(a, b) return a.progressPct > b.progressPct end)

    elseif mode == "category" then
        local rank = {}
        for i, cat in ipairs(WOWFTracker_CategoryOrder) do rank[cat] = i end
        local function Rank(e)
            return rank[e.isSkill and e.skillCategory or "faction"]
                or #WOWFTracker_CategoryOrder + 1
        end
        table.sort(entries, function(a, b)
            local ra, rb = Rank(a), Rank(b)
            if ra == rb then return a.name < b.name end
            return ra < rb
        end)

    elseif mode == "custom" then
        local order = WOWFTrackerDB.customOrder or {}
        local orderMap = {}
        for i, id in ipairs(order) do orderMap[id] = i end
        table.sort(entries, function(a, b)
            local oa = orderMap[a.id] or 9999
            local ob = orderMap[b.id] or 9999
            if oa == ob then return a.name < b.name end
            return oa < ob
        end)
    end
end

----------------------------------------------------------------------
-- Skill data helper
----------------------------------------------------------------------
local function GetSkillCategory(skillName)
    return WOWFTracker_Professions[skillName] or "weapon"
end

local function GetSkillColor(skillName)
    local cat = GetSkillCategory(skillName)
    return WOWFTracker_SkillColors[cat] or WOWFTracker_SkillColors.default
end

-- Iterate all skill lines and return data for a given skill name
local function GetSkillData(targetName)
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, isExpanded, skillRank, numTempPoints,
              skillModifier, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and skillName == targetName then
            return skillName, skillRank, skillMaxRank
        end
    end
    return nil
end

-- Collect all non-header skills the player has (filtered)
function WOWFTrackerNS.GetAllSkills()
    local skills = {}
    local currentHeader = ""
    local filters = WOWFTracker_SkillFilters or {}
    local headerFilter = filters.headers or {}
    local nameFilter   = filters.names or {}
    local skipHeader = false

    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, isExpanded, skillRank, numTempPoints,
              skillModifier, skillMaxRank = GetSkillLineInfo(i)
        if isHeader then
            currentHeader = skillName
            skipHeader = headerFilter[skillName] and true or false
        elseif not skipHeader and skillName and skillMaxRank and skillMaxRank > 0
               and not nameFilter[skillName] then
            table.insert(skills, {
                name     = skillName,
                rank     = skillRank,
                maxRank  = skillMaxRank,
                header   = currentHeader,
                category = GetSkillCategory(skillName),
                -- One point of everything is not a measurement; the picker
                -- and the bar both say "known" rather than "1 / 1".
                flat     = skillMaxRank <= 1 or nil,
            })
        end
    end
    return skills
end

function WOWFTrackerNS.HasSkill(skillName)
    return GetSkillData(skillName) ~= nil
end

----------------------------------------------------------------------
-- Known factions
-- GetFactionInfoByID answers for every faction in the game, met or not,
-- so tracked IDs alone (e.g. a SavedVariables file copied from another
-- character) would draw bars for factions this character has never met.
-- A faction belongs to the character only if it is in their reputation
-- panel. The set lives in memory only, so a copied profile can't carry it.
--
-- GetFactionInfo can't see under collapsed headers, so when a tracked
-- faction is missing and headers are collapsed, a full scan opens them
-- and closes them again. That fires UPDATE_FACTION, which lands back
-- here, so full scans are rate-limited.
----------------------------------------------------------------------
local knownFactions = {}
local lastFullScan
local FULL_SCAN_INTERVAL = 30

-- Records every faction in the panel. With expand, opens collapsed headers
-- on the way and closes them again after. Returns false if collapsed
-- headers were left unread.
local function ScanFactionPanel(expand)
    local reopened = {}
    local complete = true
    local i = 1
    while i <= GetNumFactions() do
        local name, _, _, _, _, _, _, _, isHeader, isCollapsed,
              _, _, _, factionID = GetFactionInfo(i)
        if factionID then knownFactions[factionID] = true end
        if isHeader and isCollapsed then
            if expand and name then
                reopened[name] = true
                ExpandFactionHeader(i)
            else
                complete = false
            end
        end
        i = i + 1
    end
    -- Bottom up, so closing a header doesn't shift the rows still to visit
    for j = GetNumFactions(), 1, -1 do
        local name, _, _, _, _, _, _, _, isHeader, isCollapsed = GetFactionInfo(j)
        if isHeader and not isCollapsed and reopened[name] then
            CollapseFactionHeader(j)
        end
    end
    return complete
end

local function RefreshKnownFactions(tracked)
    if ScanFactionPanel(false) then return end
    for id, enabled in pairs(tracked) do
        if enabled and not knownFactions[id] then
            local now = GetTime()
            if not lastFullScan or now - lastFullScan >= FULL_SCAN_INTERVAL then
                lastFullScan = now
                ScanFactionPanel(true)
            end
            return
        end
    end
end

function WOWFTrackerNS.IsFactionKnown(factionID)
    return knownFactions[factionID] == true
end

----------------------------------------------------------------------
-- Cumulative rep-to-Exalted calculation
-- Rep thresholds: amount of rep within each standing level
----------------------------------------------------------------------
local REP_THRESHOLDS = {
    [1] = 36000,  -- Hated
    [2] = 3000,   -- Hostile
    [3] = 3000,   -- Unfriendly
    [4] = 3000,   -- Neutral
    [5] = 6000,   -- Friendly
    [6] = 12000,  -- Honored
    [7] = 21000,  -- Revered
    [8] = 0,      -- Exalted (done)
}

-- Total from Neutral (standing 4) to Exalted = 42,000
local REP_TOTAL_TO_EXALTED = 0
for i = 4, 7 do REP_TOTAL_TO_EXALTED = REP_TOTAL_TO_EXALTED + REP_THRESHOLDS[i] end

-- Returns: earned (from bottom of Neutral), total (42,000)
local function GetExaltedProgress(standingID, barMin, barMax, barValue)
    local total = REP_TOTAL_TO_EXALTED

    if standingID >= 8 then
        return total, total
    end

    -- Below Neutral: shouldn't be called, but return 0 just in case
    if standingID < 4 then
        return 0, total
    end

    -- Sum completed standings from Neutral onward
    local earned = 0
    for i = 4, standingID - 1 do
        earned = earned + REP_THRESHOLDS[i]
    end

    -- Add progress within current standing
    local rankSize = barMax - barMin
    if rankSize > 0 then
        earned = earned + (barValue - barMin)
    end

    return math.max(0, math.min(earned, total)), total
end

----------------------------------------------------------------------
-- Dungeon tooltip builder for TBC factions
----------------------------------------------------------------------
local function BuildDungeonTooltip(factionID, currentStanding)
    local dungeonData = WOWFTracker_DungeonData
    if not dungeonData then return nil end
    local data = dungeonData[factionID]
    if not data then return nil end

    local lines = {}
    local labels = WOWFTracker_StandingLabels or {}

    -- Already exalted — nothing to run
    if currentStanding >= 8 then
        table.insert(lines, { text = " ", r = 1, g = 1, b = 1 })
        table.insert(lines, { text = "Exalted — no further rep needed!", r = 0.6, g = 0.4, b = 0.9 })
        return lines
    end

    local nextStanding = currentStanding + 1
    local nextName = labels[nextStanding] or "next tier"

    table.insert(lines, { text = " ", r = 1, g = 1, b = 1 })
    table.insert(lines, { text = "Dungeons for " .. nextName .. ":", r = 1, g = 0.82, b = 0 })

    local foundAny = false
    local heroicLocked = currentStanding < 7  -- Need Revered for Heroics

    for _, entry in ipairs(data) do
        if type(entry) == "table" and entry.name then
            if entry.maxStanding >= nextStanding then
                -- Check if player meets the minimum standing requirement
                local minReq = entry.minStanding or 0
                local locked = currentStanding < minReq

                local modeColor
                if entry.mode == "Heroic" then
                    modeColor = { r = 1.0, g = 0.5, b = 0.2 }
                elseif entry.mode == "Raid" then
                    modeColor = { r = 1.0, g = 0.3, b = 0.3 }
                else
                    modeColor = { r = 0.7, g = 0.9, b = 0.7 }
                end

                -- Show "caps at" info if the source won't reach exalted
                local capNote = ""
                if entry.maxStanding < 8 then
                    local capName = labels[entry.maxStanding] or "?"
                    capNote = "  |cff888888(caps at " .. capName .. ")|r"
                end

                local icon = entry.mode == "Heroic" and "|cffff8833[H]|r "
                    or entry.mode == "Raid" and "|cffff4444[R]|r "
                    or "|cff88cc88[N]|r "

                if locked then
                    -- Show as locked/grayed out with requirement
                    local reqName = labels[minReq] or "?"
                    table.insert(lines, {
                        text = "  " .. icon .. entry.name .. "  |cff666666(requires " .. reqName .. ")|r",
                        r = 0.45, g = 0.45, b = 0.45
                    })
                else
                    table.insert(lines, {
                        text = "  " .. icon .. entry.name .. capNote,
                        r = modeColor.r, g = modeColor.g, b = modeColor.b
                    })
                end
                foundAny = true
            end
        end
    end

    if not foundAny then
        table.insert(lines, { text = "  No dungeon sources at this tier.", r = 0.6, g = 0.6, b = 0.6 })
    end

    -- Faction-specific note (turn-ins, dailies, etc.)
    if data.note then
        table.insert(lines, { text = " ", r = 1, g = 1, b = 1 })
        table.insert(lines, { text = data.note, r = 0.7, g = 0.7, b = 0.85 })
    end

    return lines
end

----------------------------------------------------------------------
-- Standing tick mark positions (from Neutral baseline)
-- Boundaries: end of Neutral(3k), end of Friendly(9k), end of Honored(21k)
----------------------------------------------------------------------
local TICK_POSITIONS = { 3000, 9000, 21000 }  -- out of 42000 total

local function UpdateBarTicks(bar, show, barWidth, barHeight)
    if not bar.ticks then return end
    if not show then
        for _, tick in ipairs(bar.ticks) do tick:Hide() end
        return
    end
    for i, tick in ipairs(bar.ticks) do
        if TICK_POSITIONS[i] then
            local frac = TICK_POSITIONS[i] / REP_TOTAL_TO_EXALTED
            local xPos = frac * barWidth
            tick:ClearAllPoints()
            tick:SetSize(1, barHeight)
            tick:SetPoint("LEFT", bar, "LEFT", xPos, 0)
            tick:Show()
        else
            tick:Hide()
        end
    end
end

----------------------------------------------------------------------
-- Core display update (reputations + skills)
----------------------------------------------------------------------
-- How many weapon skills the window is showing, against how many the list
-- knows about. They differ exactly once -- the first sweep after the panel has
-- been opened -- and that is the moment to read it again.
local function WindowHasMore()
    local window = WOWFTrackerNS.ScrapeSkillsFrame and WOWFTrackerNS.ScrapeSkillsFrame()
    if not window then return false end

    local weapons = WOWFTracker_WeaponSkillNames or {}
    local onScreen, known = 0, 0

    for _, row in ipairs(window) do
        if weapons[row.name] then onScreen = onScreen + 1 end
    end

    for index = 1, GetNumSkillLines() do
        local name, isHeader = GetSkillLineInfo(index)
        if not isHeader and weapons[name] then known = known + 1 end
    end

    return onScreen > known
end

function WOWFTrackerNS.UpdateReputation()
    if anchor.collapsed then return end
    -- The client can report skill changes before PLAYER_LOGIN, and until InitDB
    -- runs there is no profile to draw from -- on a cold start not even the
    -- global. The login pass draws everything anyway.
    if type(WOWFTrackerDB) ~= "table" or not WOWFTrackerDB.settings then return end

    -- Belt and braces for the hook above: if the window turns out to hold more
    -- than the list does, the list is out of date whatever did or did not fire.
    if WindowHasMore() then
        InvalidateSkillRows()
    end

    local s        = Settings()
    local factions = Factions()
    local skills   = WOWFTrackerDB.skills or {}
    local colors   = WOWFTracker_StandingColors
    local labels   = WOWFTracker_StandingLabels

    local entries = {}
    local undiscovered = 0

    -- Collect reputation entries (only factions this character has met)
    RefreshKnownFactions(factions)
    for factionID, enabled in pairs(factions) do
        if enabled and not knownFactions[factionID] then
            undiscovered = undiscovered + 1
        elseif enabled then
            local name, _, standingID, barMin, barMax, barValue = GetFactionInfoByID(factionID)
            if name then
                -- Safety: if API returns zeroed min/max but valid standing,
                -- reconstruct from known thresholds
                if barMin == barMax and standingID and REP_THRESHOLDS[standingID] then
                    local threshold = REP_THRESHOLDS[standingID]
                    if threshold > 0 then
                        barMin = 0
                        barMax = threshold
                        -- barValue is typically the raw rep offset; map it into the range
                        -- For below-Neutral, barValue can be negative (e.g. -1975 in Unfriendly)
                        -- Treat barValue as progress from the bottom of the standing
                        if barValue < 0 then
                            barValue = threshold + barValue  -- e.g. 3000 + (-1975) = 1025
                        end
                        barValue = math.max(0, math.min(barValue, barMax))
                    end
                end

                local total = barMax - barMin
                local prog  = barValue - barMin
                local pct   = (total > 0) and (prog / total) or (standingID == 8 and 1 or 0)
                table.insert(entries, {
                    id          = factionID,
                    name        = name,
                    standing    = standingID,
                    barMin      = barMin,
                    barMax      = barMax,
                    barValue    = barValue,
                    progressPct = pct,
                    isSkill     = false,
                })
            end
        end
    end

    -- Collect skill entries
    for skillKey, enabled in pairs(skills) do
        if enabled then
            local skillName = skillKey:match("^skill:(.+)$")
            if skillName then
                local name, rank, maxRank = GetSkillData(skillName)
                if name and maxRank and maxRank > 0 then
                    local pct = rank / maxRank
                    table.insert(entries, {
                        id          = skillKey,
                        name        = name,
                        standing    = 0,  -- 0 = skill (not a rep standing)
                        barMin      = 0,
                        barMax      = maxRank,
                        barValue    = rank,
                        progressPct = pct,
                        isSkill     = true,
                        flat        = WOWFTrackerNS.SkillIsFlat(name) or nil,
                        skillCategory = GetSkillCategory(name),
                    })
                end
            end
        end
    end

    SortEntries(entries)

    for i, entry in ipairs(entries) do
        local bar = bars[i] or CreateBar(i)

        if entry.isSkill then
            -- Skill bar
            local maxRank = entry.barMax
            local rank    = entry.barValue

            bar:SetSize(s.barWidth, s.barHeight)
            bar:SetStatusBarTexture(s.barTexture)
            bar:SetMinMaxValues(0, maxRank > 0 and maxRank or 1)
            bar:SetValue(rank)

            local c = GetSkillColor(entry.name)
            bar:SetStatusBarColor(c.r, c.g, c.b, 0.85)

            bar.nameText:SetText(entry.name)
            bar.nameText:SetWidth(s.barWidth * 0.55)

            if entry.flat then
                -- The client names this one and will not measure it. A full
                -- bar reading "known" is the honest version of that; "1 / 1"
                -- looked like a skill stuck at its first point.
                bar:SetMinMaxValues(0, 1)
                bar:SetValue(1)
                bar.valueText:SetText("known")
                bar.tipProgress = "this client does not report a level for it"
            else
                bar.valueText:SetText(string.format("%d / %d", rank, maxRank))
                bar.tipProgress = string.format("%d / %d  [%.0f%%]",
                    rank, maxRank, entry.progressPct * 100)
            end

            bar.tipTitle = entry.name
            bar.tipDungeons = nil
            UpdateBarTicks(bar, false, s.barWidth, s.barHeight)
        else
            -- Reputation bar
            local standing    = entry.standing or 4
            local totalInRank = entry.barMax - entry.barMin
            local progress    = entry.barValue - entry.barMin

            if standing == 8 then
                totalInRank = 1
                progress    = 1
            end

            bar:SetSize(s.barWidth, s.barHeight)
            bar:SetStatusBarTexture(s.barTexture)

            local c = colors[standing] or { r = 0.5, g = 0.5, b = 0.5 }
            bar:SetStatusBarColor(c.r, c.g, c.b, 0.85)

            local standingName = labels[standing] or "Unknown"
            bar.nameText:SetText(entry.name)
            bar.nameText:SetWidth(s.barWidth * 0.55)

            if s.showTotalToExalted and standing >= 4 then
                -- Cumulative progress: 0 to Exalted (42,000)
                local earned, total = GetExaltedProgress(standing, entry.barMin, entry.barMax, entry.barValue)
                bar:SetMinMaxValues(0, total > 0 and total or 1)
                bar:SetValue(earned)
                bar.valueText:SetText(standing == 8 and "Exalted"
                    or string.format("%d / %d", earned, total))
                bar.tipTitle = entry.name .. " — " .. standingName
                bar.tipProgress = string.format("%d / %d to Exalted  [%.0f%%]",
                    earned, total, (total > 0 and (earned / total) * 100 or 100))
                UpdateBarTicks(bar, standing < 8, s.barWidth, s.barHeight)
            else
                -- Standard per-standing progress (also used for negative reps)
                bar:SetMinMaxValues(0, totalInRank > 0 and totalInRank or 1)
                bar:SetValue(progress)
                bar.valueText:SetText(standing == 8 and "Exalted"
                    or string.format("%d / %d", progress, totalInRank))
                bar.tipTitle = entry.name .. " — " .. standingName
                bar.tipProgress = string.format("%d / %d  [%.0f%%]",
                    progress, totalInRank, entry.progressPct * 100)
                UpdateBarTicks(bar, false, s.barWidth, s.barHeight)
            end

            bar.tipDungeons = BuildDungeonTooltip(entry.id, standing)
        end

        bar:SetPoint("TOPLEFT", container, "TOPLEFT", 5,
            -5 - ((i - 1) * (s.barHeight + s.rowSpacing)))
        bar:Show()
    end

    for i = #entries + 1, #bars do
        bars[i]:Hide()
        UpdateBarTicks(bars[i], false, 0, 0)
    end

    local count = #entries
    local totalHeight = (count * (s.barHeight + s.rowSpacing)) + 8
    container:SetHeight(math.max(totalHeight, 10))

    if count == 0 and not anchor.collapsed then
        if not anchor.emptyText then
            anchor.emptyText = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            anchor.emptyText:SetPoint("CENTER", container, "CENTER", 0, 0)
        end
        if undiscovered > 0 then
            anchor.emptyText:SetText(undiscovered .. " tracked faction(s) not discovered yet")
        else
            anchor.emptyText:SetText("No items tracked — click the gear icon")
        end
        anchor.emptyText:Show()
        container:SetHeight(30)
    elseif anchor.emptyText then
        anchor.emptyText:Hide()
    end
end

----------------------------------------------------------------------
-- Ensure custom order stays in sync with faction + skill toggles
----------------------------------------------------------------------
function WOWFTrackerNS.SyncCustomOrder()
    if not WOWFTrackerDB then return end
    local factions = WOWFTrackerDB.factions
    local skills   = WOWFTrackerDB.skills or {}
    local order    = WOWFTrackerDB.customOrder or {}

    -- Build a set of all enabled IDs (numbers for factions, strings for skills)
    local enabledSet = {}
    for id, enabled in pairs(factions) do
        if enabled then enabledSet[id] = true end
    end
    for key, enabled in pairs(skills) do
        if enabled then enabledSet[key] = true end
    end

    -- Remove entries from order that are no longer tracked
    local cleaned = {}
    for _, id in ipairs(order) do
        if enabledSet[id] then table.insert(cleaned, id) end
    end

    -- Add newly tracked items to the end
    local inOrder = {}
    for _, id in ipairs(cleaned) do inOrder[id] = true end
    for id in pairs(enabledSet) do
        if not inOrder[id] then
            table.insert(cleaned, id)
        end
    end

    WOWFTrackerDB.customOrder = cleaned
end

----------------------------------------------------------------------
-- Restore position
----------------------------------------------------------------------
local function RestorePosition()
    local db = DB()
    if db and db.position then
        local p = db.position
        anchor:ClearAllPoints()
        anchor:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    end
end

----------------------------------------------------------------------
-- Docked in ChairPlus's OSD
----------------------------------------------------------------------
-- With "ChairTracker" switched on as an OSD item, the tracker lives there:
-- the standalone window is shut, and hovering the item drops the window down
-- underneath it. It stays while the mouse is over the item or the window, then
-- lingers for the Hover Linger time and fades out over the Fade time -- the
-- same two settings the window's own auto-hide uses.
local dockTimer
local dockShowing = false

local function CancelDockTimer()
    if dockTimer then dockTimer:Cancel(); dockTimer = nil end
end

-- Hang from `frame` (the OSD item), or nil to come back out as a window.
function WOWFTrackerNS.Dock(frame)
    if frame == WOWFTrackerNS.docked then return end
    WOWFTrackerNS.docked = frame
    CancelDockTimer()
    activeFades[anchor] = nil
    dockShowing = false
    local s = Settings()
    if frame then
        anchor:Hide()
        return
    end
    -- Out of the OSD: back where it was put, as it was.
    anchor:SetAlpha(s and ((s.showHeader and 1 or 0.3) * (s.frameAlpha or 1)) or 1)
    RestorePosition()
    if s and s.windowVisible then
        WOWFTrackerNS.SetWindowVisible(true)
    else
        anchor:Hide()
    end
end

function WOWFTrackerNS.DockShow()
    local dock = WOWFTrackerNS.docked
    if not dock then return end
    CancelDockTimer()
    activeFades[anchor] = nil
    local s = Settings()
    anchor:ClearAllPoints()
    anchor:SetPoint("TOP", dock, "BOTTOM", 0, -4)
    anchor:SetAlpha(s and ((s.showHeader and 1 or 0.3) * (s.frameAlpha or 1)) or 1)
    anchor.collapsed = false
    container:Show()
    container:SetAlpha(1)
    isContainerShown = true
    anchor:Show()
    dockShowing = true
    WOWFTrackerNS.UpdateReputation()
end

local function DockFadeOut()
    local s = Settings()
    CancelDockTimer()
    dockTimer = C_Timer.NewTimer((s and s.showTime) or 3, function()
        dockTimer = nil
        StartFade(anchor, anchor:GetAlpha(), 0, (s and s.fadeTime) or 0.5, function()
            if WOWFTrackerNS.docked then anchor:Hide() end
            dockShowing = false
        end)
    end)
end

-- Called by the hover poll every frame while docked.
function WOWFTrackerNS.DockPoll()
    if not dockShowing then return end
    local dock = WOWFTrackerNS.docked
    local over = anchor:IsMouseOver() or container:IsMouseOver()
        or (dock and dock.IsMouseOver and dock:IsMouseOver())
    if over then
        if dockTimer or activeFades[anchor] then
            CancelDockTimer()
            activeFades[anchor] = nil
            local s = Settings()
            anchor:SetAlpha(s and ((s.showHeader and 1 or 0.3) * (s.frameAlpha or 1)) or 1)
        end
    elseif not dockTimer and not activeFades[anchor] then
        DockFadeOut()
    end
end

----------------------------------------------------------------------
-- Initialise saved variables
----------------------------------------------------------------------
-- Settings live in an account-wide file, split into one profile per
-- character, instead of in a per-character saved variable.
--
-- Per-character is the obvious way to do this and it is what this addon did.
-- On this client it came back empty: the file was written on the way out and
-- was not there on the way in, so every session started from the defaults and
-- then saved a fresh set over the top. An account-wide file has a single path
-- with no character name in it to be spelled two ways, so it cannot fail that
-- way. The profile inside it is keyed by player GUID for the same reason --
-- a name and a realm are strings the client can render differently from one
-- login to the next, and a key that comes back different is a key that is not
-- there.
--
-- WOWFTrackerDB stays the name the rest of the addon reads. It is now a
-- pointer at this character's profile inside the account store.

-- This client hands back "secret" values from some APIs. A secret survives
-- tostring() and throws only when something actually reads it, so the concat --
-- not the call above it -- is where the error lands. An unguarded concat here
-- would kill InitDB before the profile was ever looked up, and the addon would
-- come up on defaults: indistinguishable from "it never saved my settings".
-- Every value that reaches a concat in this file goes through SafeText first.
local function SafeText(value)
    if value == nil then return nil end
    local ok, text = pcall(function() return "" .. tostring(value) end)
    if ok and text ~= "" then return text end
    return nil
end

local function CharLabel()
    return (SafeText(UnitName("player")) or "Unknown")
        .. "-" .. (SafeText(GetRealmName()) or "Unknown")
end

local function ProfileKey()
    local guid = SafeText(UnitGUID and UnitGUID("player"))
    if guid then return "guid:" .. guid end
    return CharLabel()
end

-- What the load actually found, reported by /chair tracker db. Settings that were
-- never saved and settings that were saved and then not found again look
-- identical from the outside, and only one of them is worth chasing.
local loadReport = {}
WOWFTrackerNS.loadReport = loadReport

local function InitDB()
    loadReport.accountStore = (WOWFTrackerAccountDB ~= nil)
    loadReport.perCharTable = (type(WOWFTrackerDB) == "table"
                               and next(WOWFTrackerDB) ~= nil)

    if not WOWFTrackerAccountDB then WOWFTrackerAccountDB = {} end
    local store = WOWFTrackerAccountDB
    store.profiles = store.profiles or {}

    local key = ProfileKey()
    loadReport.key = key
    loadReport.guidReadable = (SafeText(UnitGUID and UnitGUID("player")) ~= nil)
    loadReport.when = date("%Y-%m-%d %H:%M:%S")

    local profile = store.profiles[key]
    loadReport.profileFound = (profile ~= nil)
    loadReport.imported = false

    if not profile then
        -- One-time import. If the client did hand back the old per-character
        -- table, that is the user's real setup and it is kept; only a genuine
        -- first run falls through to the defaults.
        if loadReport.perCharTable then
            profile = WOWFTrackerDB
            loadReport.imported = true
        else
            profile = {}
        end
        store.profiles[key] = profile
    end

    profile.label = CharLabel()

    -- From here on the global is the profile.
    WOWFTrackerDB = profile

    local db = WOWFTrackerDB
    local defaults = WOWFTracker_Defaults or {}

    if not db.settings then db.settings = {} end
    for k, v in pairs(defaults) do
        if k ~= "factions" and k ~= "skills" and db.settings[k] == nil then
            db.settings[k] = v
        end
    end

    if not db.factions then
        db.factions = {}
        for id, v in pairs(defaults.factions or {}) do
            db.factions[id] = v
        end
    end

    if not db.skills then
        db.skills = {}
        for k, v in pairs(defaults.skills or {}) do
            db.skills[k] = v
        end
    end

    if not db.customOrder then
        db.customOrder = {}
        for id, v in pairs(WOWFTracker_DefaultOrder or {}) do
            db.customOrder[id] = v
        end
    end

    -- The baked-in position from Config.lua, and nothing else: a profile the
    -- client failed to hand back still comes up empty on purpose. Only fills
    -- what is missing, so a saved position wins.
    if not db.position and WOWFTracker_DefaultPosition then
        db.position = {}
        for field, value in pairs(WOWFTracker_DefaultPosition) do
            db.position[field] = value
        end
    end

    WOWFTrackerNS.SyncCustomOrder()
end

----------------------------------------------------------------------
-- Compaction
----------------------------------------------------------------------
-- Drop everything the next load rebuilds by itself, just before the client
-- writes the file.
--
-- This client writes a saved file larger than about four kilobytes and then
-- never reads it back, silently, which is indistinguishable from an addon
-- that does not save. One profile of untouched settings is already a
-- kilobyte of values identical to the ones in Config.lua, and the account
-- file holds a profile for every character -- so a few alts each tracking a
-- few factions would reach that size without anyone doing anything odd.
--
-- Nothing here is a judgement about what matters: InitDB fills in every key
-- removed, from the same defaults consulted here.

local function CompactProfile(profile)
    local defaults = WOWFTracker_Defaults or {}
    local settings = profile.settings

    if settings then
        for key, value in pairs(defaults) do
            if type(value) ~= "table" and settings[key] == value then
                settings[key] = nil
            end
        end
        if not next(settings) then profile.settings = nil end
    end

    -- Screen coordinates to a tenth of a pixel are a dozen characters
    -- describing a position nobody can see.
    local pos = profile.position
    if pos and pos.x and pos.y then
        pos.x = math.floor(pos.x + 0.5)
        pos.y = math.floor(pos.y + 0.5)
    end
    local opts = profile.optionsPosition
    if opts and opts.x and opts.y then
        opts.x = math.floor(opts.x + 0.5)
        opts.y = math.floor(opts.y + 0.5)
    end

    -- Recreated empty by InitDB, so an empty one on disk says nothing.
    for _, key in ipairs({ "skills", "factions", "customOrder", "weaponSkills" }) do
        local list = profile[key]
        if type(list) == "table" and not next(list) then
            profile[key] = nil
        end
    end
end

-- A witness for the next cold start. Whatever this session's login actually found
-- is written back into the file, so if the addon comes up on defaults tomorrow the
-- file still says which step failed: whether the store was read back at all,
-- whether the profile key matched, and whether the GUID was readable at the moment
-- it was needed. Settings that were never saved and settings that were saved and
-- then not found again look identical from the outside without this.
local function RecordLoad(store)
    local r = WOWFTrackerNS.loadReport or {}
    store.lastLoad = {
        when = r.when,
        storeRead = r.accountStore and true or false,
        profileFound = r.profileFound and true or false,
        guidReadable = r.guidReadable and true or false,
        key = r.key,
    }
end

local function CompactDB()
    local store = WOWFTrackerAccountDB
    if not (store and store.profiles) then return end
    RecordLoad(store)
    for _, profile in pairs(store.profiles) do
        CompactProfile(profile)
    end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

-- Never on the event itself. Every one of these events can arrive in a burst,
-- and two of them can arrive while the client is still building the very window
-- the warm wants to read.
local function WarmSoon(delay)
    if not (C_Timer and C_Timer.After and WOWFTrackerNS.WarmSkills) then return end
    C_Timer.After(delay or 1, function()
        local learned = WOWFTrackerNS.WarmSkills(false)
        if learned and learned > 0 and WOWFTrackerNS.UpdateReputation then
            WOWFTrackerNS.UpdateReputation()
        end
    end)
end

anchor.dbReady = false
anchor:RegisterEvent("UPDATE_FACTION")
anchor:RegisterEvent("SKILL_LINES_CHANGED")
anchor:RegisterEvent("PLAYER_LOGIN")
anchor:RegisterEvent("PLAYER_LOGOUT")
-- A weapon skill read off the character sheet changes with what is held and
-- with the level that caps it, and a client that never fires
-- SKILL_LINES_CHANGED still fires these.
anchor:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
anchor:RegisterEvent("UNIT_INVENTORY_CHANGED")
anchor:RegisterEvent("PLAYER_LEVEL_UP")
anchor:RegisterEvent("CHAT_MSG_SKILL")
-- Shifting is what puts a druid's Feral Combat on the sheet, and takes it off
anchor:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
-- The skills panel is the kind of window a client loads when it is first
-- wanted, so its arrival is worth hearing about.
anchor:RegisterEvent("ADDON_LOADED")
anchor:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGOUT" then
        CompactDB()
        return
    end
    if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
    if event == "SKILL_LINES_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED"
       or event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_LEVEL_UP"
       or event == "CHAT_MSG_SKILL" or event == "UPDATE_SHAPESHIFT_FORM" then
        InvalidateSkillRows()
    end
    if event == "ADDON_LOADED" then
        -- Whatever just loaded may have brought the skills window with it.
        if WOWFTrackerNS.HookSkillsWindow and WOWFTrackerNS.HookSkillsWindow() then
            InvalidateSkillRows()
            -- And a window that has only just arrived has never been filled, so
            -- this is the first moment it is worth asking.
            WarmSoon(0.5)
        end
        return
    end

    -- A skill went up, or the cap did. If this client does fire one of these,
    -- the sheet is read on the spot rather than up to two seconds later -- the
    -- poll is the floor, not the plan. The warm then covers what the sheet
    -- cannot answer for, throttled, so a run of skill-ups is not a run of warms.
    if event == "CHAT_MSG_SKILL" or event == "PLAYER_LEVEL_UP"
       or event == "SKILL_LINES_CHANGED" then
        if WOWFTrackerNS.PollWeaponSkills then WOWFTrackerNS.PollWeaponSkills() end
    end
    if event == "CHAT_MSG_SKILL" or event == "PLAYER_LEVEL_UP" then
        WarmSoon(1)
    end

    if event == "PLAYER_LOGIN" then
        InitDB()
        RestorePosition()
        WOWFTrackerNS.RebuildAppearance()
        -- Apply saved visibility
        local s = Settings()
        if (s and not s.windowVisible) or WOWFTrackerNS.docked then
            anchor:Hide()
        end
        self.dbReady = true

        -- Twice, because neither moment is reliable on its own: the window may
        -- not be loaded yet at login, and waiting only for the late one leaves
        -- the list short for the first eight seconds of every session.
        WarmSoon(2)
        WarmSoon(8)

        print("|cff88aaddChairTracker|r v1.4.0 loaded — by |cff00ccffChairface|r. Type /chair tracker for options.")
    end
    if self.dbReady then
        WOWFTrackerNS.UpdateReputation()
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_WOWFTRACKER1 = "/wowft"
SLASH_WOWFTRACKER2 = "/wowftracker"
SlashCmdList["WOWFTRACKER"] = function(msg)
    local cmd = msg:match("^(%S+)") or ""
    cmd = cmd:lower()

    if cmd == "options" or cmd == "config" or cmd == "opt" then
        if WOWFTrackerNS.ToggleOptions then WOWFTrackerNS.ToggleOptions() end

    elseif cmd == "" or cmd == "toggle" then
        WOWFTrackerNS.ToggleWindow()

    elseif cmd == "show" then
        WOWFTrackerNS.SetWindowVisible(true)

    elseif cmd == "hide" then
        WOWFTrackerNS.SetWindowVisible(false)

    elseif cmd == "lock" then
        Settings().locked = not Settings().locked
        local state = Settings().locked and "|cff00ff00LOCKED|r" or "|cffff4444UNLOCKED|r"
        print("|cff88aadd[WOWFT]|r Frame " .. state)
        WOWFTrackerNS.RebuildAppearance()

    elseif cmd == "reset" then
        if WOWFTrackerAccountDB and WOWFTrackerAccountDB.profiles then
            WOWFTrackerAccountDB.profiles[ProfileKey()] = nil
        end
        WOWFTrackerDB = nil
        InitDB()
        anchor:ClearAllPoints()
        anchor:SetPoint("CENTER")
        WOWFTrackerNS.RebuildAppearance()
        print("|cff88aadd[WOWFT]|r Settings and factions reset to defaults.")

    elseif cmd == "api" then
        -- Which panel API this client actually has, and what the skill list
        -- looks like through it. For working out why something is missing.
        print("|cff88aadd[WOWFT]|r === API probe ===")

        local function report(name, value)
            print(string.format("  %-28s %s", name,
                value and "|cff00ff00yes|r" or "|cffff4444no|r"))
        end
        report("C_Reputation", _G.C_Reputation ~= nil)
        report("GetFactionInfo", _G.GetFactionInfo ~= nil)
        report("GetNumSkillLines", _G.GetNumSkillLines ~= nil)
        report("GetSkillLineInfo", _G.GetSkillLineInfo ~= nil)
        report("GetProfessions", _G.GetProfessions ~= nil)
        report("C_SkillInfo", _G.C_SkillInfo ~= nil)
        report("C_TradeSkillUI", _G.C_TradeSkillUI ~= nil)

        -- Wrapped so one missing field can't take the probe down with it
        local function dump(label, tbl)
            if type(tbl) ~= "table" then
                print("  |cffffcc00" .. label .. ":|r |cffff4444absent|r")
                return
            end
            local names = {}
            for k in pairs(tbl) do
                if type(k) == "string" then names[#names + 1] = k end
            end
            table.sort(names)
            print("  |cffffcc00" .. label .. " (" .. #names .. "):|r")
            local line = "   "
            for _, n in ipairs(names) do
                if #line + #n > 72 then print(line); line = "   " end
                line = line .. " " .. n
            end
            if line ~= "   " then print(line) end
        end
        dump("C_SkillInfo", _G.C_SkillInfo)
        dump("C_TradeSkillUI", _G.C_TradeSkillUI)

        -- 0 rows with GetProfessions present means the professions themselves
        -- came back empty, so show exactly what they answer.
        if _G.GetProfessions and _G.GetProfessionInfo then
            local p1, p2, arch, fish, cook = GetProfessions()
            print(string.format("  |cffffcc00GetProfessions():|r %s, %s, %s, %s, %s",
                tostring(p1), tostring(p2), tostring(arch), tostring(fish), tostring(cook)))
            local function slot(label, index)
                if not index then
                    print("    " .. label .. ": |cff888888empty|r")
                    return
                end
                local ok, name, _, rank, maxRank, _, _, skillLine =
                    pcall(GetProfessionInfo, index)
                if not ok then
                    print("    " .. label .. ": |cffff4444error|r " .. tostring(name))
                else
                    print(string.format("    %s: idx=%s name=%s rank=%s/%s line=%s",
                        label, tostring(index), tostring(name), tostring(rank),
                        tostring(maxRank), tostring(skillLine)))
                end
            end
            slot("prof1", p1)
            slot("prof2", p2)
            slot("archaeology", arch)
            slot("fishing", fish)
            slot("cooking", cook)
        end

        -- Which of the three clients this turned out to be, and where the
        -- weapon skills on the bars came from.
        local source, weapons = WOWFTrackerNS.SkillSource()
        print("  |cffffcc00skill source:|r " .. tostring(source) ..
              "   |cffffcc00weapon skills:|r " .. tostring(weapons))

        -- Everything on this client with "skill" in its name. The point of a
        -- probe is the function nobody thought to ask for.
        local hits = {}
        for name, value in pairs(_G) do
            if type(name) == "string" then
                if name:lower():find("skill") then
                    hits[#hits + 1] = name
                elseif name:sub(1, 2) == "C_" and type(value) == "table" then
                    for key in pairs(value) do
                        if type(key) == "string" and key:lower():find("skill") then
                            hits[#hits + 1] = name .. "." .. key
                        end
                    end
                end
            end
        end
        table.sort(hits)
        print("  |cffffcc00named *skill* (" .. #hits .. "):|r")
        local line = "   "
        for _, h in ipairs(hits) do
            if #line + #h > 72 then print(line); line = "   " end
            line = line .. " " .. h
        end
        if line ~= "   " then print(line) end

        -- The character-sheet numbers the weapon bars fall back on. A value
        -- this client keeps secret can be read but never formatted, so each
        -- one is printed through a pcall rather than trusted.
        local function show(v)
            local ok, text = pcall(string.format, "%s", v)
            return ok and text or "|cffff4444secret|r"
        end
        local function sheet(label, fn, ...)
            if type(fn) ~= "function" then
                print("    " .. label .. ": |cff888888absent|r")
                return
            end
            local ok, a, b = pcall(fn, ...)
            print("    " .. label .. ": " ..
                  (ok and (show(a) .. " / " .. show(b)) or "|cffff4444error|r"))
        end
        print("  |cffffcc00character sheet:|r")
        sheet("UnitLevel", _G.UnitLevel, "player")
        sheet("UnitDefense", _G.UnitDefense, "player")
        sheet("UnitAttackBothHands", _G.UnitAttackBothHands, "player")
        sheet("UnitRangedAttack", _G.UnitRangedAttack, "player")
        sheet("GetShapeshiftFormID", _G.GetShapeshiftFormID)
        print("    feral form constants: " ..
              show(_G.CAT_FORM) .. " / " .. show(_G.BEAR_FORM) ..
              " / " .. show(_G.DIRE_BEAR_FORM))

        -- A shut header is the quiet way to have no weapon skills, and it
        -- looks identical to a client that has none.
        local shut = {}
        for name in pairs(WOWFTrackerNS.UnopenedHeaders()) do
            shut[#shut + 1] = name
        end
        table.sort(shut)

        if #shut > 0 then
            local ok, line = pcall(table.concat, shut, ", ")
            print("  |cffdd6666closed and cannot be opened from here:|r "
                  .. (ok and line or "?"))
            print("  |cff808080everything under those is invisible to an addon. "
                  .. "Open them in the character panel, then /reload.|r")
        end

        local scraped = WOWFTrackerNS.ScrapeSkillsFrame and
            WOWFTrackerNS.ScrapeSkillsFrame()
        print("  |cffffcc00read off the window's own text:|r "
              .. (scraped and #scraped or 0) .. " row(s)")

        local fromWindow = WOWFTrackerNS.ReadSkillsFrame()
        print("  |cffffcc00the client's own Skills window:|r "
              .. (_G.SkillsFrame and "|cff00ff00present|r" or "|cffff4444absent|r")
              .. ", readable rows: "
              .. (fromWindow and #fromWindow or 0))
        if fromWindow then
            for _, row in ipairs(fromWindow) do
                print(string.format("    %s  %s/%s", row.name,
                    tostring(row.rank), tostring(row.maxRank)))
            end
        elseif _G.SkillsFrame then
            print("  |cff808080it is there but nothing in it could be read -- "
                  .. "open the Skills panel once and try again.|r")
        end

        print("  |cffffcc00can open a closed header:|r "
              .. (_G.ExpandSkillHeader and "|cff00ff00yes|r" or "|cffff4444no|r"))
        print("  |cffffcc00skill rows the tracker reads:|r " .. GetNumSkillLines())
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            print(string.format("    %2d %s%s|r  %s/%s", i,
                isHeader and "|cffffcc00" or "|cffffffff", tostring(name),
                tostring(rank), tostring(maxRank)))
        end
        print("|cff88aadd[WOWFT]|r === End probe ===")

    elseif cmd == "skills" then
        -- The api sweep prints every name with "skill" in it, and on this
        -- client that is four hundred string constants with the handful that
        -- matter buried in them -- the paste that came back had been cut off
        -- before the C section, which is exactly where an API would sort.
        -- This one prints only things that can be called or looked inside.
        print("|cff88aadd[WOWFT]|r === skills probe ===")

        local hits = {}
        for name, value in pairs(_G) do
            if type(name) == "string" and name:lower():find("skill") then
                local kind = type(value)
                if kind == "function" or kind == "table" then
                    hits[#hits + 1] = name .. " |cff808080(" .. kind .. ")|r"
                end
            elseif type(name) == "string" and name:sub(1, 2) == "C_"
                   and type(value) == "table" then
                for key, inner in pairs(value) do
                    if type(key) == "string" and key:lower():find("skill") then
                        hits[#hits + 1] = name .. "." .. key
                            .. " |cff808080(" .. type(inner) .. ")|r"
                    end
                end
            end
        end
        table.sort(hits)

        print("  |cffffcc00callable or lookable, named *skill* (" .. #hits .. "):|r")
        for _, hit in ipairs(hits) do print("    " .. hit) end

        -- And the shape of the window that is showing the numbers, one level
        -- down, so the reader can be written against what is there rather than
        -- against what a client of this age usually has.
        local frame = _G.SkillsFrame
        if type(frame) ~= "table" then
            print("  |cffff4444SkillsFrame is not there.|r")
        else
            local function Describe(label, tbl, depth)
                local names = {}
                local ok = pcall(function()
                    for key, value in pairs(tbl) do
                        if type(key) == "string" then
                            names[#names + 1] = key .. ":" .. type(value)
                        end
                    end
                end)
                if not ok then
                    print("    " .. label .. " |cffff4444could not be read|r")
                    return
                end

                table.sort(names)
                print("  |cffffcc00" .. label .. " (" .. #names .. "):|r")
                local line = "   "
                for _, entry in ipairs(names) do
                    if #line + #entry > 72 then print(line); line = "   " end
                    line = line .. " " .. entry
                end
                if line ~= "   " then print(line) end
            end

            Describe("SkillsFrame", frame)

            for _, key in ipairs({ "ScrollBox", "scrollBox", "SkillsScrollBox",
                                   "ScrollFrame", "Container", "List" }) do
                local child = frame[key]
                if type(child) == "table" then
                    Describe("SkillsFrame." .. key, child)

                    local got, provider = pcall(function()
                        return child.GetDataProvider and child:GetDataProvider()
                    end)
                    if got and type(provider) == "table" then
                        Describe("its data provider", provider)

                        -- The first row it holds, which is the thing worth
                        -- reading: whatever names the fields here is what the
                        -- tracker has to ask for.
                        local fine = pcall(function()
                            for _, element in provider:Enumerate() do
                                Describe("first row", element)
                                if type(element) == "table" and type(element.data) == "table" then
                                    Describe("first row .data", element.data)
                                end
                                break
                            end
                        end)
                        if not fine then
                            print("    |cff808080its rows could not be walked|r")
                        end
                    end
                end
            end
        end

        print("|cff88aadd[WOWFT]|r === End skills probe ===")

    elseif cmd == "weapons" then
        -- Everything that can answer "what is my sword skill", and what each one
        -- actually said, because on this client the answer is different for every
        -- source and the useful question is which of them is worth trusting.
        local force = (msg:match("^%S+%s+(%S+)") or ""):lower() == "warm"

        print("|cff88aadd[WOWFT]|r === weapon skills ===")

        local okLevel, level = pcall(UnitLevel, "player")
        local cap = ((okLevel and tonumber(level)) or 0) * 5
        print("  Level cap on a weapon skill: |cffffcc00" .. cap .. "|r")

        -- 1. The character sheet. Needs nothing on screen and answers only for
        --    what is held, which is the whole problem in one line.
        print("  |cffffcc00from the character sheet (equipped only):|r")
        local function Say(label, ok, value)
            local shown = "|cffff4444could not be read|r"
            if ok then
                local n = tonumber(tostring(value))
                shown = n and ("|cff00ff00" .. n .. "|r") or "|cff808080nil|r"
            end
            print("    " .. label .. ": " .. shown)
        end

        local okMelee, mainBase, _, offBase = pcall(UnitAttackBothHands, "player")
        Say("main hand", okMelee, mainBase)
        Say("off hand", okMelee, offBase)
        Say("ranged", pcall(UnitRangedAttack, "player"))
        local defFn = _G.UnitDefenseSkill or _G.UnitDefense
        if type(defFn) == "function" then
            Say("defense", pcall(defFn, "player"))
        else
            print("    defense: |cffff4444no UnitDefenseSkill or UnitDefense|r")
        end

        -- 2. The warm: the window, filled without being opened. Forced when
        --    asked, so the step that moves the frame can be retried on demand.
        if force then print("  |cffffcc00forcing a full warm|r") end
        local learned = WOWFTrackerNS.WarmSkills and WOWFTrackerNS.WarmSkills(force) or 0
        local steps, usedHidden = WOWFTrackerNS.WarmReport()

        print("  |cffffcc00warming the skills window (learned " .. learned .. " new):|r")
        for _, step in ipairs(steps or {}) do
            local rows = step.rows > 0
                and ("|cff00ff00" .. step.rows .. " rows|r")
                or "|cff808080no rows|r"
            print("    " .. step.step .. ": " .. step.outcome .. " — " .. rows)
        end
        if usedHidden then
            print("    |cff808080(the out-of-sight show has been used this session)|r")
        end

        -- 3. What the addon now holds, which is what gets drawn whether or not
        --    anything ever opens the panel again.
        local held = (type(WOWFTrackerDB) == "table" and WOWFTrackerDB.weaponSkills) or {}
        local names = {}
        for name in pairs(held) do names[#names + 1] = name end
        table.sort(names)

        print("  |cffffcc00held for this character (" .. #names .. "):|r")
        if #names == 0 then
            print("    |cffff4444nothing yet|r — |cff00ccff/chair tracker weapons warm|r forces a"
                  .. " full attempt, and opening the skills panel once will always work.")
        else
            local line = "   "
            for _, name in ipairs(names) do
                local entry = name .. " " .. tostring(held[name]) .. "/" .. cap
                if #line + #entry > 70 then print(line); line = "   " end
                line = line .. " |cff00ff00" .. entry .. "|r"
            end
            if line ~= "   " then print(line) end
        end

        -- Named rather than silently swallowed: a skill this client lists twice
        -- is now harmless, but it is also the only sign that one of the sources
        -- above is answering for something it should not be.
        local dupes = WOWFTrackerNS.DroppedDuplicates and WOWFTrackerNS.DroppedDuplicates()
        local dupeNames = {}
        for name, count in pairs(dupes or {}) do
            dupeNames[#dupeNames + 1] = name .. " |cff808080x" .. count .. "|r"
        end
        table.sort(dupeNames)
        if #dupeNames > 0 then
            local ok, line = pcall(table.concat, dupeNames, ", ")
            print("  |cffffcc00listed more than once, kept once:|r " .. (ok and line or "?"))
        end

        print("|cff88aadd[WOWFT]|r === End weapon skills ===")

    elseif cmd == "db" then
        -- The one question worth asking when everything is back at its
        -- default: was anything there to load?
        print("|cff88aadd[WOWFT]|r === Saved data ===")
        local function yesno(v)
            return v and "|cff00ff00yes|r" or "|cffff4444no|r"
        end
        print("  Character:            " .. CharLabel())
        print("  Profile key:          |cff888888" .. tostring(loadReport.key) .. "|r")
        print("  Account file at load: " .. yesno(loadReport.accountStore))
        print("  Profile found:        " .. yesno(loadReport.profileFound))
        print("  Per-character table:  " .. yesno(loadReport.perCharTable))
        print("  Imported from it:     " .. yesno(loadReport.imported))

        local store = WOWFTrackerAccountDB
        if store and store.profiles then
            for key, profile in pairs(store.profiles) do
                local skills, tracked = 0, 0
                for _ in pairs(profile.skills or {}) do skills = skills + 1 end
                for _ in pairs(profile.factions or {}) do tracked = tracked + 1 end
                print("  " .. (key == loadReport.key and "|cff00ff00->|r " or "   ") ..
                      (profile.label or key) .. " |cff888888(" .. skills ..
                      " skills, " .. tracked .. " factions, position " ..
                      (profile.position and "saved" or "unset") .. ")|r")
            end
        end

    elseif cmd == "debug" then
        local arg = msg:match("^%S+%s+(.+)$")
        print("|cff88aadd[WOWFT]|r === Debug Dump ===")

        -- If they passed a number, try GetFactionInfoByID directly
        local testID = tonumber(arg)
        if testID then
            local name, desc, standingID, barMin, barMax, barValue,
                  atWarWith, canToggle, isHeader, isCollapsed,
                  hasRep, isWatched, isChild, factionID = GetFactionInfoByID(testID)
            print(string.format("  GetFactionInfoByID(%d):", testID))
            print(string.format("    name=%s  standing=%s  min=%s  max=%s  val=%s  retID=%s",
                tostring(name), tostring(standingID), tostring(barMin),
                tostring(barMax), tostring(barValue), tostring(factionID)))
        end

        -- Scan the full rep panel for matching name or ID
        print("  --- Full panel scan ---")
        local searchName = arg and arg:lower() or ""
        local i = 1
        while i <= GetNumFactions() do
            local name, _, standingID, barMin, barMax, barValue,
                  atWarWith, canToggle, isHeader, isCollapsed,
                  hasRep, isWatched, isChild, factionID = GetFactionInfo(i)
            if isHeader and isCollapsed then
                ExpandFactionHeader(i)
            end
            if name and (name:lower():find(searchName, 1, true)
                    or (testID and factionID == testID)) then
                print(string.format("    [%d] %s  id=%s  standing=%d  min=%d  max=%d  val=%d  header=%s  hasRep=%s",
                    i, name, tostring(factionID), standingID or 0,
                    barMin or 0, barMax or 0, barValue or 0,
                    tostring(isHeader), tostring(hasRep)))
            end
            i = i + 1
        end

        -- Also dump what our DB has stored
        if WOWFTrackerDB and WOWFTrackerDB.factions then
            print("  --- Tracked factions in DB ---")
            for id, enabled in pairs(WOWFTrackerDB.factions) do
                if enabled then
                    local n = GetFactionInfoByID(id)
                    print(string.format("    id=%s  name=%s  discovered=%s", tostring(id),
                        tostring(n), tostring(knownFactions[id] == true)))
                end
            end
        end
        print("|cff88aadd[WOWFT]|r === End Debug ===")

    else
        print("|cff88aadd[WOWFT]|r Commands:")
        print("  /chair tracker          — Toggle tracker on/off")
        print("  /chair tracker options  — Open options panel")
        print("  /chair tracker lock     — Toggle frame lock")
        print("  /chair tracker show     — Show the tracker")
        print("  /chair tracker hide     — Hide the tracker")
        print("  /chair tracker reset    — Reset everything to defaults")
        print("  /chair tracker db       — Report what saved data was found at load")
        print("  /chair tracker debug <name or id> — Dump faction data")
        print("  /chair tracker api      — Show which client API the tracker is using")
        print("  /chair tracker skills   — Where this client keeps its skill numbers")
        print("  /chair tracker weapons  — Every source for a weapon skill, and what it said")
        print("                    (add |cff00ccffwarm|r to force a full attempt)")
    end
end
