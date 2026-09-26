# Relocated into Chaircraft on 2026-09-22, when the standalone addon folders
# were deleted. Until then this ran as a runtime-patched copy of that addon's
# own suite; there is no upstream to re-run against any more, so it lives here.
# Offline checks for WOWFTracker (needs: pip install lupa).
#   python .tests/tracker_test.py
# 1. Every .lua file parses as Lua 5.1 (the dialect WoW uses).
# 2. Loads Config/WOWFTracker/Options against a mocked WoW API with a fake
#    reputation panel and skill list, then checks: tracked factions this
#    character hasn't met get no bar, factions under collapsed headers are
#    still found and the headers are put back, full scans are rate-limited,
#    and the Category sort groups entries.
import glob, io, os, sys
from lupa import lua51

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

HARNESS = r'''
SETTEXT_LOG, EVENT_FRAMES, STATUSBARS, ONUPDATE_FRAMES = {}, {}, {}, {}
NOW, EXPANDS, COLLAPSES = 1000, 0, 0

-- Frames: any CamelCase key is a method; lowercase keys are plain fields.
local Mock
local function Method(k)
    return setmetatable({}, {
        __index = function(_, key)
            if type(key) == "string" and key:match("^%u") then return Method(key) end
        end,
        __call = function(_, self, ...)
            if type(self) ~= "table" then return Mock() end
            if k == "SetText" then
                local t = ...
                rawset(self, "_text", t)
                table.insert(SETTEXT_LOG, tostring(t))
            elseif k == "Show" then rawset(self, "_shown", true)
            elseif k == "Hide" then rawset(self, "_shown", false)
            elseif k == "IsShown" then return rawget(self, "_shown") == true
            elseif k == "SetScript" then
                local name, fn = ...
                local s = rawget(self, "_scripts") or {}
                s[name] = fn
                rawset(self, "_scripts", s)
                if name == "OnUpdate" and fn and not rawget(self, "_ticking") then
                    rawset(self, "_ticking", true)
                    table.insert(ONUPDATE_FRAMES, self)
                end
            elseif k == "RegisterEvent" then
                local e = rawget(self, "_events")
                if not e then
                    e = {}
                    rawset(self, "_events", e)
                    table.insert(EVENT_FRAMES, self)
                end
                e[(...)] = true
            end
            return Mock()
        end,
    })
end
Mock = function()
    return setmetatable({}, { __index = function(_, key)
        if type(key) == "string" and key:match("^%u") then return Method(key) end
    end })
end

function CreateFrame(ftype, name, parent, template)
    local f = Mock()
    if template and template:find("CheckButton") then f.text = Mock() end
    if name then _G[name] = f end
    if ftype == "StatusBar" then table.insert(STATUSBARS, f) end
    return f
end

function SKILL_TICK(elapsed)
    for _, f in ipairs(ONUPDATE_FRAMES) do
        local s = rawget(f, "_scripts")
        if s and s.OnUpdate then s.OnUpdate(f, elapsed) end
    end
end

function FireEvent(ev)
    for _, f in ipairs(EVENT_FRAMES) do
        if f._events[ev] and f._scripts and f._scripts.OnEvent then
            f._scripts.OnEvent(f, ev)
        end
    end
end

UIParent, GameTooltip = Mock(), Mock()
function GameTooltip_Hide() end
C_Timer = { NewTimer = function() return { Cancel = function() end } end,
            After = function() end }
SlashCmdList, UISpecialFrames, tinsert = {}, {}, table.insert
NORMAL_FONT_COLOR    = { r = 1, g = 0.82, b = 0 }
HIGHLIGHT_FONT_COLOR = { r = 1, g = 1, b = 1 }
function GetTime() return NOW end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
PRINTED = {}
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(PRINTED, table.concat(parts, " "))
end

-- Reputation panel. GetFactionInfo only sees rows under open headers.
function ResetPanel(outlandCollapsed, shattCollapsed)
    SHATT = { name = "Shattrath City", id = 936, header = true, child = true,
              collapsed = shattCollapsed, children = {
                  { name = "Lower City", id = 1011, child = true },
                  { name = "The Sha'tar", id = 935, child = true } } }
    OUTLAND = { name = "Outland", id = 980, header = true,
                collapsed = outlandCollapsed, children = {
                  { name = "Honor Hold", id = 946 },
                  { name = "Cenarion Expedition", id = 942 },
                  SHATT } }
    PANEL = {
        { name = "Alliance", id = 469, header = true, collapsed = false, children = {
            { name = "Stormwind", id = 72 }, { name = "Darnassus", id = 69 } } },
        OUTLAND,
        { name = "Other", id = 169, header = true, collapsed = false, children = {
            { name = "Timbermaw Hold", id = 576 } } },
    }
end

local function VisibleRows()
    local out = {}
    local function walk(list)
        for _, n in ipairs(list) do
            table.insert(out, n)
            if n.header and not n.collapsed then walk(n.children) end
        end
    end
    walk(PANEL)
    return out
end

-- id -> name, standingID, barMin, barMax, barValue. Includes factions the
-- character hasn't met: GetFactionInfoByID answers for those too.
FACTION_DB = {
    [72]   = { "Stormwind", 8, 42000, 42999, 42999 },
    [69]   = { "Darnassus", 5, 3000, 9000, 4000 },
    [946]  = { "Honor Hold", 6, 9000, 21000, 15000 },
    [942]  = { "Cenarion Expedition", 5, 3000, 9000, 3500 },
    [1011] = { "Lower City", 5, 3000, 9000, 5000 },
    [935]  = { "The Sha'tar", 4, 0, 3000, 200 },
    [576]  = { "Timbermaw Hold", 4, 0, 3000, 100 },
    [1015] = { "Netherwing", 4, 0, 3000, 0 },
    [1038] = { "Ogri'la", 4, 0, 3000, 0 },
}

function GetNumFactions() return #VisibleRows() end
function GetFactionInfo(i)
    local n = VisibleRows()[i]
    if not n then return nil end
    local d = FACTION_DB[n.id] or { n.name, 4, 0, 3000, 0 }
    return n.name, "", d[2], d[3], d[4], d[5], false, false,
           n.header == true, n.collapsed == true, not n.header, false,
           n.child == true, n.id
end
function GetFactionInfoByID(id)
    local d = FACTION_DB[id]
    if not d then return nil end
    return d[1], "", d[2], d[3], d[4], d[5]
end
-- The client fires UPDATE_FACTION on expand/collapse; fire it synchronously
-- here (the worst case: the tracker re-enters mid-scan).
function ExpandFactionHeader(i)
    local n = assert(VisibleRows()[i]); assert(n.header and n.collapsed)
    n.collapsed = false
    EXPANDS = EXPANDS + 1
    FireEvent("UPDATE_FACTION")
end
function CollapseFactionHeader(i)
    local n = assert(VisibleRows()[i]); assert(n.header and not n.collapsed)
    n.collapsed = true
    COLLAPSES = COLLAPSES + 1
    FireEvent("UPDATE_FACTION")
end

-- Skills panel. Like the reputation panel, GetSkillLineInfo only sees rows
-- under open headers. ResetSkills(weaponCollapsed) sets the starting state.
SKILL_EXPANDS, SKILL_COLLAPSES = 0, 0
function ResetSkills(weaponCollapsed)
    SKILL_EXPANDS, SKILL_COLLAPSES = 0, 0
    SKILL_PANEL = {
        { name = "Professions", collapsed = false, children = {
            { name = "Mining", rank = 300, max = 375 },
            { name = "Alchemy", rank = 250, max = 375 } } },
        { name = "Secondary Skills", collapsed = false, children = {
            { name = "Cooking", rank = 150, max = 225 },
            { name = "Riding", rank = 150, max = 150 } } },
        { name = "Weapon Skills", collapsed = weaponCollapsed, children = {
            { name = "Swords", rank = 350, max = 350 },
            { name = "Daggers", rank = 1, max = 350 } } },
    }
end
ResetSkills(false)

local function VisibleSkillRows()
    local out = {}
    for _, h in ipairs(SKILL_PANEL) do
        table.insert(out, h)
        if not h.collapsed then
            for _, s in ipairs(h.children) do table.insert(out, s) end
        end
    end
    return out
end

function GetNumSkillLines() return #VisibleSkillRows() end
function GetSkillLineInfo(i)
    local s = VisibleSkillRows()[i]
    if not s then return nil end
    local isHeader = s.children ~= nil
    return s.name, isHeader, not (isHeader and s.collapsed), s.rank or 0, 0, 0, s.max or 0
end
-- The client fires SKILL_LINES_CHANGED on expand/collapse; fire it
-- synchronously here, the worst case the tracker has to survive.
function ExpandSkillHeader(i)
    local s = assert(VisibleSkillRows()[i]); assert(s.children and s.collapsed)
    s.collapsed = false
    SKILL_EXPANDS = SKILL_EXPANDS + 1
    FireEvent("SKILL_LINES_CHANGED")
end
function CollapseSkillHeader(i)
    local s = assert(VisibleSkillRows()[i]); assert(s.children and not s.collapsed)
    s.collapsed = true
    SKILL_COLLAPSES = SKILL_COLLAPSES + 1
    FireEvent("SKILL_LINES_CHANGED")
end

-- Identity, for the per-character profile the settings are keyed on
function UnitName() return "Tester" end
function GetRealmName() return "Testrealm" end
function UnitGUID() return "Player-4613-00000001" end
function date() return "2026-01-01 00:00:00" end

-- Shapeshift forms. A druid in cat or bear form swings with Feral Combat,
-- so while shifted that is the skill the melee numbers belong to.
CAT_FORM, TREE_OF_LIFE, TRAVEL_FORM, AQUATIC_FORM, BEAR_FORM, DIRE_BEAR_FORM =
    1, 2, 3, 4, 5, 8
FORM = 0
function UnitClass() return "Druid", "DRUID" end
function GetShapeshiftFormID() return FORM ~= 0 and FORM or nil end

-- Character sheet. With no skills panel this is all that knows a weapon
-- skill: the numbers give the rank, and what is equipped gives the name.
-- EQUIPPED maps an inventory slot to the item subclass held in it.
LEVEL = 13
EQUIPPED = { [16] = "Daggers" }
SHEET = { defense = 61, mainhand = 48, offhand = 0, ranged = 0 }
function UnitLevel() return LEVEL end
function UnitDefense() return SHEET.defense, 0 end
function UnitAttackBothHands() return SHEET.mainhand, 0, SHEET.offhand, 0 end
function UnitRangedAttack() return SHEET.ranged, 0 end
function GetInventoryItemLink(unit, slot)
    if not EQUIPPED[slot] then return nil end
    return "|Hitem:" .. slot .. "|h[Weapon]|h"
end
function GetItemInfo(link)
    local slot = tonumber(link:match("item:(%d+)"))
    return "Weapon", link, 2, 20, 1, "Weapon", EQUIPPED[slot], 1, "INVTYPE_WEAPONMAINHAND"
end

function ShownBars()
    local out = {}
    for _, b in ipairs(STATUSBARS) do
        if b._shown == true then table.insert(out, b.nameText._text) end
    end
    return table.concat(out, "|")
end

function LogHas(...)
    local needles = { ... }
    for _, line in ipairs(SETTEXT_LOG) do
        local all = true
        for _, s in ipairs(needles) do
            if not line:find(s, 1, true) then all = false; break end
        end
        if all then return true end
    end
    return false
end
'''

failures = []
def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)

# --- 1. syntax ------------------------------------------------------------
L = lua51.LuaRuntime(unpack_returned_tuples=True)
loadstring = L.eval("function(s,n) return loadstring(s,n) end")
for f in sorted(glob.glob("ChairTracker/*.lua")):
    res = loadstring(io.open(f, encoding="utf-8").read(), "@" + f)
    fn, err = (res if isinstance(res, tuple) else (res, None))
    check("parses " + f, fn is not None, err)
if failures:
    sys.exit(1)

# --- 2. behaviour -----------------------------------------------------------
# The same expectations twice: once against the classic global reputation
# functions, once against the C_Reputation tables that replaced them in 11.0.
# WOWFTracker.lua wraps both, so nothing below should care which is in play.
MODERN_REP = '''
local numFactions, info, byID = GetNumFactions, GetFactionInfo, GetFactionInfoByID
local expand, collapse = ExpandFactionHeader, CollapseFactionHeader

local function pack(name, description, reaction, currentReactionThreshold,
                    nextReactionThreshold, currentStanding, atWarWith,
                    canToggleAtWar, isHeader, isCollapsed, isHeaderWithRep,
                    isWatched, isChild, factionID)
    if not name then return nil end
    return { name = name, description = description, reaction = reaction,
             currentReactionThreshold = currentReactionThreshold,
             nextReactionThreshold = nextReactionThreshold,
             currentStanding = currentStanding, atWarWith = atWarWith,
             canToggleAtWar = canToggleAtWar, isHeader = isHeader,
             isCollapsed = isCollapsed, isHeaderWithRep = isHeaderWithRep,
             isWatched = isWatched, isChild = isChild, factionID = factionID }
end

C_Reputation = {
    GetNumFactions        = function() return numFactions() end,
    GetFactionDataByIndex = function(i) return pack(info(i)) end,
    GetFactionDataByID    = function(id) return pack(byID(id)) end,
    ExpandFactionHeader   = function(i) return expand(i) end,
    CollapseFactionHeader = function(i) return collapse(i) end,
}

-- Take the globals away, so a fallback to them can't pass unnoticed.
GetNumFactions, GetFactionInfo, GetFactionInfoByID = nil, nil, nil
ExpandFactionHeader, CollapseFactionHeader = nil, nil
'''

MODERN = False


def boot(setup, modern=MODERN, login=True):
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(HARNESS)
    L.execute(setup)
    if modern:
        L.execute(MODERN_REP)
    run = L.eval("function(s, n) local f = assert(loadstring(s, n)); f() end")
    for f in ("ChairTracker/Config.lua", "ChairTracker/WOWFTracker.lua", "ChairTracker/Options.lua"):
        run(io.open(f, encoding="utf-8").read(), "@" + f)
    if login:
        L.execute('FireEvent("PLAYER_LOGIN")')
    return L


def behaviour():

    # Profile copied from another character: tracks Netherwing and Ogri'la,
    # which this character has never met. Outland and Shattrath City collapsed.
    L = boot('''
    ResetPanel(true, true)
ResetSkills(false)
    WOWFTrackerDB = { settings = { sortMode = "category" },
        factions = { [72] = true, [946] = true, [1011] = true, [576] = true,
                     [1015] = true, [1038] = true, [69] = false },
        skills = { ["skill:Mining"] = true, ["skill:Swords"] = true, ["skill:Cooking"] = true,
                   ["skill:Alchemy"] = true, ["skill:Maces"] = true } }
    ''')
    ev = L.eval
    BASE = "Honor Hold|Lower City|Stormwind|Timbermaw Hold|Alchemy|Mining|Cooking|Swords"
    check("undiscovered factions get no bar; category order", ev("ShownBars()") == BASE, ev("ShownBars()"))
    check("faction under nested collapsed header is known", ev("WOWFTrackerNS.IsFactionKnown(935)"))
    check("Netherwing not known", not ev("WOWFTrackerNS.IsFactionKnown(1015)"))
    check("one full scan at login (2 headers opened)", ev("EXPANDS") == 2, ev("EXPANDS"))
    check("headers closed again", ev("OUTLAND.collapsed and SHATT.collapsed and COLLAPSES == 2"))

    L.execute('for _ = 1, 3 do FireEvent("UPDATE_FACTION") end')
    check("no rescan inside 30s", ev("EXPANDS") == 2, ev("EXPANDS"))

    L.execute('NOW = NOW + 31; FireEvent("UPDATE_FACTION")')
    check("rescan after 30s while a tracked faction is missing", ev("EXPANDS") == 4, ev("EXPANDS"))
    check("bars unchanged after rescan", ev("ShownBars()") == BASE, ev("ShownBars()"))
    check("headers still closed after rescan", ev("OUTLAND.collapsed and SHATT.collapsed"))

    # Character meets Netherwing while its header is collapsed
    L.execute('''
    table.insert(OUTLAND.children, { name = "Netherwing", id = 1015 })
    NOW = NOW + 31; FireEvent("UPDATE_FACTION")
    ''')
    check("newly discovered faction gets a bar",
          ev("ShownBars()") == "Honor Hold|Lower City|Netherwing|Stormwind|Timbermaw Hold|Alchemy|Mining|Cooking|Swords",
          ev("ShownBars()"))

    L.execute("SETTEXT_LOG = {}; RefreshCustomOrder()")
    check("Ordering tab flags undiscovered faction", ev('LogHas("Ogri\'la", "(undiscovered)")'))
    check("Ordering tab flags unlearned skill", ev('LogHas("Maces", "(unlearned)")'))
    check("Ordering tab doesn't flag known faction",
          ev('LogHas("Honor Hold")') and not ev('LogHas("Honor Hold", "(undiscovered)")'))

    L.execute('WOWFTrackerDB.factions[1038] = nil; E0 = EXPANDS; NOW = NOW + 31; FireEvent("UPDATE_FACTION")')
    check("no scans once every tracked faction is known", ev("EXPANDS == E0"))

    L.execute('WOWFTrackerDB.factions = { [1038] = true }; WOWFTrackerDB.skills = {}; WOWFTrackerNS.UpdateReputation()')
    check("no bars when only undiscovered tracked", ev("ShownBars()") == "", ev("ShownBars()"))
    check("empty text explains why",
          ev("WOWFTrackerNS.anchor.emptyText._text") == "1 tracked faction(s) not discovered yet",
          ev("WOWFTrackerNS.anchor.emptyText._text"))

    # Only Outland collapsed; Shattrath City was left open and must stay open
    L = boot('''
    ResetPanel(true, false)
ResetSkills(false)
    WOWFTrackerDB = { factions = { [1011] = true }, skills = {} }
    ''')
    check("open sub-header left open", L.eval("OUTLAND.collapsed and not SHATT.collapsed and EXPANDS == 1"),
          L.eval("tostring(OUTLAND.collapsed) .. ' ' .. tostring(SHATT.collapsed) .. ' ' .. EXPANDS"))
    check("faction under it shown", L.eval("ShownBars()") == "Lower City", L.eval("ShownBars()"))

    # Nothing collapsed: no header is touched at all
    L = boot('''
    ResetPanel(false, false)
ResetSkills(false)
    WOWFTrackerDB = { factions = { [1011] = true, [1015] = true }, skills = {} }
    ''')
    check("no headers touched when none are collapsed", L.eval("EXPANDS == 0 and COLLAPSES == 0"))
    check("undiscovered hidden with nothing collapsed", L.eval("ShownBars()") == "Lower City", L.eval("ShownBars()"))


for MODERN in (False, True):
    LABEL = "C_Reputation" if MODERN else "globals"
    print("-- reputation API: " + LABEL)
    behaviour()

# --- 3. skills hidden under a collapsed header ------------------------------
# A collapsed "Weapon Skills" makes GetSkillLineInfo skip every weapon skill.
print("-- skills API: collapsed header")
L = boot('''
ResetPanel(false, false)
ResetSkills(true)
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Swords"] = true, ["skill:Mining"] = true } }
''')
check("weapon skill under a collapsed header is found",
      L.eval("ShownBars()") == "Mining|Swords", L.eval("ShownBars()"))
check("the header is closed again",
      L.eval("SKILL_PANEL[3].collapsed and SKILL_EXPANDS == 1 and SKILL_COLLAPSES == 1"),
      L.eval("tostring(SKILL_PANEL[3].collapsed) .. ' ' .. SKILL_EXPANDS .. ' ' .. SKILL_COLLAPSES"))
check("options picker lists it too", L.eval("WOWFTrackerNS.HasSkill('Daggers')"))

L.execute("E0 = SKILL_EXPANDS; for _ = 1, 5 do WOWFTrackerNS.UpdateReputation() end")
check("cached, so redraws don't reopen the header", L.eval("SKILL_EXPANDS == E0"),
      L.eval("SKILL_EXPANDS .. ' vs ' .. E0"))

L.execute('''
SKILL_PANEL[1].children[1].rank = 375
FireEvent("SKILL_LINES_CHANGED")
''')
check("a real skill-up drops the cache", L.eval("SKILL_EXPANDS > E0"))
check("and the new rank is drawn", L.eval("STATUSBARS[1] ~= nil"))

# --- 3. skills on a client with no skills panel -----------------------------
# GetNumSkillLines/GetSkillLineInfo are gone; professions -- all that is left
# of the skill list -- come from GetProfessions/GetProfessionInfo instead.
print("-- skills API: professions only")
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
PROFS = { [1] = { "Mining", 300, 375 }, [2] = { "Alchemy", 250, 375 },
          [4] = { "Fishing", 100, 300 }, [5] = { "Cooking", 150, 300 } }
-- Slot 3 (Archaeology) unlearned: GetProfessions returns a nil in the middle.
function GetProfessions() return 1, 2, nil, 4, 5 end
function GetProfessionInfo(i)
    local p = PROFS[i]
    if not p then return nil end
    return p[1], "icon", p[2], p[3]
end
WOWFTrackerDB = { factions = {}, skills = { ["skill:Mining"] = true,
    ["skill:Cooking"] = true, ["skill:Swords"] = true,
    ["skill:Daggers"] = true, ["skill:Defense"] = true } }
''', modern=True)
check("professions tracked without a skills panel",
      {"Cooking", "Mining"} <= set(L.eval("ShownBars()").split("|")), L.eval("ShownBars()"))
check("secondary skill past the nil slot is still found", L.eval("WOWFTrackerNS.HasSkill('Cooking')"))
check("weapon skill the client can't name is not claimed",
      not L.eval("WOWFTrackerNS.HasSkill('Swords')"))

# The weapon group rebuilt from the character sheet: the dagger in hand and
# defence, both against a cap of five per level.
check("equipped weapon skill rebuilt from the character sheet",
      sorted(L.eval("ShownBars()").split("|")) == ["Cooking", "Daggers", "Defense", "Mining"],
      L.eval("ShownBars()"))
check("rebuilt from the sheet, not the panel",
      L.eval("select(2, WOWFTrackerNS.SkillSource())") == "derived",
      L.eval("select(2, WOWFTrackerNS.SkillSource())"))
check("rank and the five-per-level cap",
      L.eval('LogHas("48 / 65")') and L.eval('LogHas("61 / 65")'))
check("picker lists the weapon group", L.eval("WOWFTrackerNS.HasSkill('Defense')"))

# Daggers go away, a mace comes out: the mace is read off the sheet, and the
# daggers keep the bar they had rather than dropping out of the list.
L.execute('''
EQUIPPED[16] = "One-Handed Maces"
SHEET.mainhand = 1
WOWFTrackerDB.skills["skill:Maces"] = true
FireEvent("PLAYER_EQUIPMENT_CHANGED")
''')
check("skill of a newly equipped weapon appears",
      sorted(L.eval("ShownBars()").split("|")) == ["Cooking", "Daggers", "Defense", "Maces", "Mining"],
      L.eval("ShownBars()"))
check("the put-away weapon keeps its last known rank",
      L.eval('LogHas("48 / 65")') and L.eval('LogHas("1 / 65")'))
check("and it is remembered for the next session",
      L.eval("WOWFTrackerDB.weaponSkills.Daggers") == 48,
      L.eval("tostring(WOWFTrackerDB.weaponSkills.Daggers)"))

# --- 3b. real weapon skills beside the 1/1 lines ---------------------------
# A panel that reports both: the skills are its own, the tabs are dropped.
print("-- skills API: real skills beside the 1/1 lines")
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
table.insert(SKILL_PANEL, { name = "Class Skills", collapsed = false, children = {
    { name = "Feral Combat", rank = 1, max = 1 } } })
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Swords"] = true, ["skill:Feral Combat"] = true } }
''')
check("the panel's own weapon skill is used",
      L.eval('LogHas("350 / 350")'), L.eval("ShownBars()"))
# A skill the panel names but reports as 1/1 is kept rather than thrown away:
# losing the row loses the skill, and on a client that reports every weapon
# skill that way the list empties. It is drawn as known instead.
check("and one it will not measure is still there, marked as such",
      sorted(L.eval("ShownBars()").split("|")) == ["Feral Combat", "Swords"]
      and L.eval('LogHas("known")'),
      L.eval("ShownBars()"))
check("the panel is trusted for weapons, not the sheet",
      L.eval("select(2, WOWFTrackerNS.SkillSource())") == "panel",
      L.eval("select(2, WOWFTrackerNS.SkillSource())"))

# --- 3c. no panel and no character sheet either -----------------------------
# Nothing here can name a weapon skill, and the addon must not invent one.
print("-- skills API: no panel, no character sheet")
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
GetProfessions, GetProfessionInfo = nil, nil
UnitLevel, UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil, nil
WOWFTrackerDB = { factions = {}, skills = { ["skill:Daggers"] = true } }
''')
check("no weapon skills invented with nothing to read them from",
      L.eval("ShownBars()") == "" and not L.eval("WOWFTrackerNS.HasSkill('Daggers')"),
      L.eval("ShownBars()"))

# --- 3d. the panel moved into a C_ table ------------------------------------
# The same panel at a new address, answering with a table instead of a list.
print("-- skills API: panel behind a C_ table")
L = boot('''
ResetPanel(false, false)
ResetSkills(true)
local num, info = GetNumSkillLines, GetSkillLineInfo
local expand, collapse = ExpandSkillHeader, CollapseSkillHeader
C_SkillInfo = {
    GetNumSkillLines = function() return num() end,
    GetSkillLineInfo = function(i)
        local name, isHeader, isExpanded, rank, _, _, maxRank = info(i)
        if not name then return nil end
        return { skillName = name, isHeader = isHeader, isExpanded = isExpanded,
                 skillRank = rank, skillMaxRank = maxRank }
    end,
    ExpandSkillHeader = function(i) return expand(i) end,
    CollapseSkillHeader = function(i) return collapse(i) end,
}
GetNumSkillLines, GetSkillLineInfo = nil, nil
ExpandSkillHeader, CollapseSkillHeader = nil, nil
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Swords"] = true, ["skill:Daggers"] = true } }
''')
check("weapon skills found through a C_ table",
      L.eval("ShownBars()") == "Daggers|Swords", L.eval("ShownBars()"))
check("its collapsed header is opened and closed again",
      L.eval("SKILL_PANEL[3].collapsed and SKILL_EXPANDS == 1 and SKILL_COLLAPSES == 1"),
      L.eval("tostring(SKILL_PANEL[3].collapsed) .. ' ' .. SKILL_EXPANDS .. ' ' .. SKILL_COLLAPSES"))
check("the C_ table is what answered",
      L.eval("(WOWFTrackerNS.SkillSource())") == "C_SkillInfo",
      L.eval("(WOWFTrackerNS.SkillSource())"))
check("the panel's own ranks are used, not the character sheet",
      L.eval('LogHas("350 / 350")') and L.eval("select(2, WOWFTrackerNS.SkillSource())") == "panel",
      L.eval("select(2, WOWFTrackerNS.SkillSource())"))

# --- 3e. a panel that answers with the spellbook's own lines ---------------
# What this client actually does: the rows are spell tabs, each reading 1/1.
# A tab is not a skill with progress, and a druid's "Feral Combat" tab must
# not stand in for the weapon skill of the same name.
print("-- skills API: panel lists the spellbook's own lines")
L = boot('''
ResetPanel(false, false)
TABS = { { "Class Skills", true }, { "Feral Combat", false, 1, 1 },
         { "Balance", false, 1, 1 }, { "Restoration", false, 1, 1 } }
function GetNumSkillLines() return #TABS end
function GetSkillLineInfo(i)
    local t = TABS[i]
    if not t then return nil end
    return t[1], t[2], true, t[3] or 0, 0, 0, t[4] or 0
end
ExpandSkillHeader, CollapseSkillHeader = nil, nil
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Feral Combat"] = true, ["skill:Daggers"] = true,
               ["skill:Defense"] = true } }
''')
check("the weapon skills still come from the character sheet",
      {"Daggers", "Defense"} <= set(L.eval("ShownBars()").split("|")),
      L.eval("ShownBars()"))
check("a line with no level behind it reads as known, not as 1 / 1",
      L.eval('LogHas("known")') and not L.eval('LogHas("1 / 1")'),
      L.eval("ShownBars()"))
check("and a spellbook tab under a class header is not offered in the picker",
      L.eval("""
        (function()
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                if skill.name == "Balance" then return false end
            end
            return true
        end)()
      """) is True)
check("its header goes with it", not L.eval('LogHas("Class Skills")'))
check("so the weapon skills still come off the sheet",
      L.eval("select(2, WOWFTrackerNS.SkillSource())") == "derived",
      L.eval("select(2, WOWFTrackerNS.SkillSource())"))

# Shift into cat form: now the melee numbers are Feral Combat's.
L.execute('''
SETTEXT_LOG = {}
FORM = CAT_FORM
SHEET.mainhand = 63
FireEvent("UPDATE_SHAPESHIFT_FORM")
''')
check("a shifted druid's feral skill is read off the sheet",
      L.eval("ShownBars()") == "Daggers|Defense|Feral Combat", L.eval("ShownBars()"))
check("at the rank the sheet gives it", L.eval('LogHas("63 / 65")'))
check("and the weapon in hand keeps its own rank", L.eval('LogHas("48 / 65")'))

# --- 3f. a client that names weapon skills but will not measure them -------
# The regression this exists to stop happening a third time.
#
# The first fix made weapon skills appear. The second fix -- for a Feral Combat
# reading 1/1 while the client's own panel showed 63/65 -- threw away every row
# the panel reported that way. On a client that reports ALL its weapon skills
# like that, the second fix deleted what the first one added, and the list came
# back holding professions and nothing else.
print("-- weapon skills the panel names but will not measure")
L = boot('''
ResetPanel(false, false)
SKILL_PANEL = {
    { name = "Professions", collapsed = false, children = {
        { name = "Skinning", rank = 300, max = 375 } } },
    -- Every one of them flat, which is the shape that emptied the list.
    { name = "Weapon Skills", collapsed = false, children = {
        { name = "Daggers", rank = 1, max = 1 },
        { name = "Defense", rank = 1, max = 1 },
        { name = "Feral Combat", rank = 1, max = 1 },
        { name = "Maces", rank = 1, max = 1 } } },
}
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Daggers"] = true, ["skill:Maces"] = true,
               ["skill:Feral Combat"] = true, ["skill:Skinning"] = true } }
''')

check("the weapon skills are still offered in the picker",
      L.eval("""
        (function()
            local found = 0
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                if skill.name == "Daggers" or skill.name == "Maces"
                   or skill.name == "Feral Combat" then found = found + 1 end
            end
            return found
        end)()
      """) == 3,
      L.eval("""
        (function()
            local names = {}
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                names[#names + 1] = skill.name
            end
            return table.concat(names, "|")
        end)()
      """))

check("and the tracked ones are drawn",
      sorted(L.eval("ShownBars()").split("|"))
      == ["Daggers", "Feral Combat", "Maces", "Skinning"],
      L.eval("ShownBars()"))
check("the profession keeps its real numbers", L.eval('LogHas("300 / 375")'))
check("while the unmeasured ones say so",
      L.eval('LogHas("known")') and not L.eval('LogHas("1 / 1")'))

# With a character sheet to ask, the flat rows get real numbers instead.
L = boot('''
ResetPanel(false, false)
SKILL_PANEL = {
    { name = "Weapon Skills", collapsed = false, children = {
        { name = "Daggers", rank = 1, max = 1 },
        { name = "Defense", rank = 1, max = 1 } } },
}
LEVEL = 13
EQUIPPED = { [16] = "Daggers" }
SHEET = { defense = 61, mainhand = 48, offhand = 0, ranged = 0 }
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Daggers"] = true, ["skill:Defense"] = true } }
''')

check("a flat row is filled in from the character sheet where it can be",
      L.eval('LogHas("48 / 65")') and L.eval('LogHas("61 / 65")'),
      L.eval("ShownBars()"))
check("and is not listed twice for the trouble",
      L.eval("ShownBars()") == "Daggers|Defense", L.eval("ShownBars()"))

# --- 3g. a section the client will not let us open -------------------------
# The other way to have no weapon skills: they are there, behind a header this
# client shows shut and gives no way to open. Indistinguishable from not having
# them, unless the addon says so.
print("-- a header that cannot be opened")
L = boot('''
ResetPanel(false, false)
ResetSkills(true)
ExpandSkillHeader, CollapseSkillHeader = nil, nil
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Swords"] = true, ["skill:Mining"] = true } }
''')

check("what is under it cannot be read",
      L.eval("ShownBars()") == "Mining", L.eval("ShownBars()"))
check("but the addon knows which header hid it",
      L.eval("WOWFTrackerNS.UnopenedHeaders()['Weapon Skills']") is True,
      L.eval("tostring(WOWFTrackerNS.UnopenedHeaders()['Weapon Skills'])"))

L.execute("SETTEXT_LOG = {}")
L.execute("SlashCmdList.WOWFTRACKER('api')")
check("and /wowft api says so out loud",
      L.eval("""
        (function()
            for _, line in ipairs(PRINTED or {}) do
                if line:find("cannot be opened", 1, true) then return true end
            end
            return false
        end)()
      """) is True)

# --- 3h. this client, as the probe found it --------------------------------
# What /wowft api actually reported: no GetSkillLineInfo worth the name, five
# trade skills through the professions call, UnitDefense and
# UnitAttackBothHands both gone, UnitDefenseSkill present, and a SkillsFrame on
# screen holding the real weapon skill numbers.
print("-- the client the probe described")
L = boot('''
ResetPanel(false, false)
GetNumSkillLines, GetSkillLineInfo = nil, nil

-- The trade skills, which is all the professions call knows.
PROFS = { [1] = { "Leatherworking", 39, 75 }, [2] = { "Skinning", 130, 150 },
          [4] = { "Fishing", 107, 150 }, [5] = { "Cooking", 85, 150 } }
function GetProfessions() return 1, 2, nil, 4, 5 end
function GetProfessionInfo(i)
    local p = PROFS[i]
    if not p then return nil end
    return p[1], "icon", p[2], p[3]
end

-- The sheet, as this client has it: the old calls gone, the defence one kept.
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
function UnitDefenseSkill() return 61, 0 end
LEVEL = 16

-- And the window that knows the rest, in the shape a modern list frame uses.
SkillsFrame = {
    ScrollBox = {
        GetDataProvider = function()
            return {
                Enumerate = function()
                    local rows = {
                        { skillName = "Daggers", skillRank = 48, skillMaxRank = 80 },
                        { skillName = "Feral Combat", skillRank = 63, skillMaxRank = 80 },
                        { skillName = "Maces", skillRank = 1, skillMaxRank = 80 },
                        { skillName = "Unarmed", skillRank = 1, skillMaxRank = 80 },
                        -- A trade skill in the same window, which must not be
                        -- mistaken for a weapon one.
                        { skillName = "Cooking", skillRank = 85, skillMaxRank = 150 },
                    }
                    local index = 0
                    return function()
                        index = index + 1
                        if rows[index] then return index, rows[index] end
                    end
                end,
            }
        end,
    },
}

WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Daggers"] = true, ["skill:Feral Combat"] = true,
               ["skill:Defense"] = true, ["skill:Cooking"] = true } }
''')

check("the window is readable",
      L.eval("#WOWFTrackerNS.ReadSkillsFrame()") == 5,
      L.eval("#(WOWFTrackerNS.ReadSkillsFrame() or {})"))

check("weapon skills come back with the numbers the window shows",
      sorted(L.eval("ShownBars()").split("|"))
      == ["Cooking", "Daggers", "Defense", "Feral Combat"],
      L.eval("ShownBars()"))
check("at the levels it reported",
      L.eval('LogHas("48 / 80")') and L.eval('LogHas("63 / 80")'),
      L.eval("ShownBars()"))
check("defence comes from the one sheet call this client kept",
      L.eval('LogHas("61 / 80")'), L.eval("ShownBars()"))
check("and a trade skill keeps coming from the professions call",
      L.eval('LogHas("85 / 150")'))

check("the picker offers the weapon skills as well",
      L.eval("""
        (function()
            local found = 0
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                if skill.name == "Daggers" or skill.name == "Feral Combat"
                   or skill.name == "Maces" or skill.name == "Unarmed" then
                    found = found + 1
                end
            end
            return found
        end)()
      """) == 4,
      L.eval("""
        (function()
            local names = {}
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                names[#names + 1] = skill.name
            end
            return table.concat(names, "|")
        end)()
      """))

check("and nothing is listed twice",
      L.eval("""
        (function()
            local seen, twice = {}, 0
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                if seen[skill.name] then twice = twice + 1 end
                seen[skill.name] = true
            end
            return twice
        end)()
      """) == 0)

# A window that is there but shaped differently must cost this source alone.
L2 = boot('''
ResetPanel(false, false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
function GetProfessions() return nil, nil, nil, nil, nil end
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
SkillsFrame = { ScrollBox = { GetDataProvider = function() error("no") end } }
WOWFTrackerDB = { factions = {}, skills = { ["skill:Daggers"] = true } }
''')
check("a window that cannot be read costs nothing else",
      L2.eval("ShownBars()") == "", L2.eval("ShownBars()"))
check("and the addon still came up", L2.eval("WOWFTrackerNS.anchor ~= nil") is True)

# --- 3i. the window read by what it says -----------------------------------
# The panel in the screenshot: seven weapon skills with their numbers on screen
# and nothing readable behind them. Every field name guessed at missed, so the
# rows are found by the one thing that is not in doubt -- the text.
print("-- reading the Skills window off the screen")


def SkillsWindow():
    """A frame tree shaped like the client's: rows of name and \"48 / 80\"."""
    return """
    local function FontString(text)
        return { GetText = function() return text end }
    end

    local function Row(name, value)
        local regions = { FontString(name), FontString(value) }
        return {
            GetRegions = function() return unpack(regions) end,
            GetChildren = function() return end,
        }
    end

    local rows = {
        Row("Daggers", "48 / 80"),
        Row("Defense", "78 / 80"),
        Row("Feral Combat", "80 / 80"),
        Row("Maces", "19 / 80"),
        Row("Staves", "39 / 80"),
        Row("Two-Handed Maces", "30 / 80"),
        Row("Unarmed", "1 / 80"),
    }

    -- A header above them, with no numbers of its own.
    local header = {
        GetRegions = function() return FontString("Weapon Skills") end,
        GetChildren = function() return end,
    }

    local list = {
        GetRegions = function() return end,
        GetChildren = function() return header, unpack(rows) end,
    }

    SkillsFrame = {
        GetRegions = function() return end,
        GetChildren = function() return list end,
    }
    """


L = boot('''
ResetPanel(false, false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
function GetProfessions() return nil, nil, nil, nil, nil end
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
LEVEL = 16
''' + SkillsWindow() + '''
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Daggers"] = true, ["skill:Maces"] = true,
               ["skill:Unarmed"] = true, ["skill:Feral Combat"] = true } }
''')

rows = L.eval("#(WOWFTrackerNS.ScrapeSkillsFrame() or {})")
check("every row on screen is read", rows == 7, rows)

check("with the numbers it is showing",
      L.eval("""
        (function()
            for _, row in ipairs(WOWFTrackerNS.ScrapeSkillsFrame()) do
                if row.name == "Daggers" then
                    return row.rank .. "/" .. row.maxRank
                end
            end
        end)()
      """) == "48/80")

check("the header is not mistaken for a skill",
      L.eval("""
        (function()
            for _, row in ipairs(WOWFTrackerNS.ScrapeSkillsFrame()) do
                if row.name == "Weapon Skills" then return false end
            end
            return true
        end)()
      """) is True)

check("and the tracked ones are drawn",
      sorted(L.eval("ShownBars()").split("|"))
      == ["Daggers", "Feral Combat", "Maces", "Unarmed"],
      L.eval("ShownBars()"))
check("at the levels the window shows",
      L.eval('LogHas("48 / 80")') and L.eval('LogHas("19 / 80")')
      and L.eval('LogHas("1 / 80")'),
      L.eval("ShownBars()"))
check("the picker offers them too",
      L.eval("""
        (function()
            local found = 0
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                if skill.name == "Staves" or skill.name == "Two-Handed Maces" then
                    found = found + 1
                end
            end
            return found
        end)()
      """) == 2)

# A window that is built but empty -- the panel never opened -- must not be
# mistaken for a client without weapon skills.
L2 = boot('''
ResetPanel(false, false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
function GetProfessions() return nil, nil, nil, nil, nil end
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
SkillsFrame = {
    GetRegions = function() return end,
    GetChildren = function() return end,
}
WOWFTrackerDB = { factions = {}, skills = { ["skill:Daggers"] = true } }
''')
check("an empty window reads as nothing rather than as an error",
      L2.eval("WOWFTrackerNS.ScrapeSkillsFrame()") is None)
check("and the addon still comes up", L2.eval("ShownBars()") == "")

# --- 3j. the window fills up after login -----------------------------------
# What actually happened in the game: the window read perfectly well when asked
# directly, and the tracker showed nothing but professions and Defense. The
# list had been built at login -- before anyone had opened their skills panel,
# when the window held nothing -- and nothing threw that list away when the
# panel was finally opened and filled.
print("-- the skills panel, opened after login")
L = boot('''
ResetPanel(false, false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
PROFS = { [1] = { "Leatherworking", 39, 75 }, [2] = { "Skinning", 130, 150 } }
function GetProfessions() return 1, 2, nil, nil, nil end
function GetProfessionInfo(i)
    local p = PROFS[i]
    if not p then return nil end
    return p[1], "icon", p[2], p[3]
end
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
function UnitDefenseSkill() return 78, 0 end
LEVEL = 16

-- The window exists from the start and is empty, which is how it is until
-- someone opens the panel.
WINDOW_ROWS = {}
local function FontString(text)
    return { GetText = function() return text end }
end
local function Row(name, value)
    local regions = { FontString(name), FontString(value) }
    return {
        GetRegions = function() return unpack(regions) end,
        GetChildren = function() return end,
    }
end
ROW = Row

SHOW_HANDLERS = {}
SkillsFrame = {
    GetRegions = function() return end,
    GetChildren = function() return unpack(WINDOW_ROWS) end,
    HookScript = function(_, which, fn)
        if which == "OnShow" then table.insert(SHOW_HANDLERS, fn) end
    end,
}

WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Daggers"] = true, ["skill:Defense"] = true,
               ["skill:Skinning"] = true } }
''')

check("before the panel is opened, only what the client will say",
      sorted(L.eval("ShownBars()").split("|")) == ["Defense", "Skinning"],
      L.eval("ShownBars()"))
check("and the window was hooked while it was still empty",
      L.eval("#SHOW_HANDLERS") >= 1, L.eval("#SHOW_HANDLERS"))

# The panel is opened: the rows appear, and the hook fires.
L.execute('''
WINDOW_ROWS = { ROW("Daggers", "48 / 80"), ROW("Defense", "78 / 80"),
                ROW("Maces", "19 / 80") }
for _, fn in ipairs(SHOW_HANDLERS) do fn() end
WOWFTrackerNS.UpdateReputation()
''')

check("opening it brings the weapon skills through",
      sorted(L.eval("ShownBars()").split("|")) == ["Daggers", "Defense", "Skinning"],
      L.eval("ShownBars()"))
check("at the numbers the window shows", L.eval('LogHas("48 / 80")'))
check("and the picker now offers the rest of them",
      L.eval("""
        (function()
            for _, skill in ipairs(WOWFTrackerNS.GetAllSkills()) do
                if skill.name == "Maces" then return true end
            end
            return false
        end)()
      """) is True)

# Even with no hook at all -- a client that will not let one be attached -- the
# next sweep has to notice the window holds more than the list does.
L2 = boot('''
ResetPanel(false, false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
function GetProfessions() return nil, nil, nil, nil, nil end
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
LEVEL = 16
WINDOW_ROWS = {}
local function FontString(text)
    return { GetText = function() return text end }
end
local function Row(name, value)
    local regions = { FontString(name), FontString(value) }
    return {
        GetRegions = function() return unpack(regions) end,
        GetChildren = function() return end,
    }
end
ROW = Row
SkillsFrame = {
    GetRegions = function() return end,
    GetChildren = function() return unpack(WINDOW_ROWS) end,
}
WOWFTrackerDB = { factions = {}, skills = { ["skill:Staves"] = true } }
''')

check("nothing to show while the window is empty",
      L2.eval("ShownBars()") == "", L2.eval("ShownBars()"))

L2.execute('WINDOW_ROWS = { ROW("Staves", "39 / 80") }')
L2.execute("WOWFTrackerNS.UpdateReputation()")
check("and a sweep picks it up once the window has it",
      L2.eval("ShownBars()") == "Staves", L2.eval("ShownBars()"))
check("with the right numbers", L2.eval('LogHas("39 / 80")'))

# --- 4. neither API ---------------------------------------------------------
# Nothing to read, but the addon must still load and draw an empty window.
print("-- no faction or skill API at all")
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
GetNumFactions, GetFactionInfo, GetFactionInfoByID = nil, nil, nil
ExpandFactionHeader, CollapseFactionHeader = nil, nil
GetNumSkillLines, GetSkillLineInfo = nil, nil
WOWFTrackerDB = { factions = { [1011] = true }, skills = { ["skill:Mining"] = true } }
''', modern=False)
check("loads with no reputation API", L.eval("ShownBars()") == "", L.eval("ShownBars()"))

# --- 5. the numbers without the window --------------------------------------
# A weapon skill that is not in hand is only knowable from Blizzard's Skills
# window, and that window holds nothing until it has run. These cover the walk
# that makes it run without putting it on screen -- one section per client shape,
# because which step answers is the whole question.
print("-- getting the weapon skills without opening the panel")

# The window in every shape, built from one description. fills says which call
# is the one that puts rows in it, which is exactly what differs between
# clients: an update method, an OnShow, or nothing short of a real Show.
PANEL = '''
ResetPanel(false, false)
ResetSkills(false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
function GetProfessions() return nil, nil, nil, nil, nil end
UnitDefense, UnitAttackBothHands, UnitRangedAttack = nil, nil, nil
function UnitDefenseSkill() return 78, 0 end
LEVEL = 16

WINDOW_ROWS = {}
PARENT_NOW, SHOWN_NOW, POINTS_NOW = "UIParent", false, 1

local function FontString(text)
    return { GetText = function() return text end }
end
local function Row(name, value)
    local regions = { FontString(name), FontString(value) }
    return {
        GetRegions = function() return unpack(regions) end,
        GetChildren = function() return end,
    }
end
ROW = Row

function FillWindow()
    WINDOW_ROWS = { ROW("Daggers", "48 / 80"), ROW("Maces", "19 / 80"),
                    ROW("Weapon Skills", "") }
end

CALLED = {}
SkillsFrame = {
    GetRegions = function() return end,
    GetChildren = function() return unpack(WINDOW_ROWS) end,
    HookScript = function() return true end,
    IsShown = function() return SHOWN_NOW end,
    GetParent = function() return PARENT_NOW end,
    SetParent = function(_, p) PARENT_NOW = p end,
    Show = function()
        SHOWN_NOW = true
        table.insert(CALLED, "Show")
        if FILLS == "show" then FillWindow() end
    end,
    -- A scrolling list makes its row frames when it is shown and can unmake
    -- them when it is hidden, so the numbers exist only while it is up.
    Hide = function()
        SHOWN_NOW = false
        if FILLS == "show" then WINDOW_ROWS = {} end
    end,
    GetNumPoints = function() return POINTS_NOW end,
    GetPoint = function() return "TOPLEFT", UIParent, "TOPLEFT", 16, -116 end,
    ClearAllPoints = function() POINTS_NOW = 0 end,
    SetPoint = function() POINTS_NOW = POINTS_NOW + 1 end,
    GetScript = function(_, which)
        if which ~= "OnShow" then return nil end
        if FILLS ~= "onshow" then return nil end
        return function()
            table.insert(CALLED, "OnShow")
            FillWindow()
        end
    end,
}

WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Daggers"] = true, ["skill:Defense"] = true } }
'''

# The kindest client: the window has an update of its own, and calling it is all
# filling it consists of.
L = boot('''
FILLS = "update"
''' + PANEL + '''
SkillsFrame.Update = function()
    table.insert(CALLED, "Update")
    FillWindow()
end
''')
check("nothing but Defense before anything is warmed",
      L.eval("ShownBars()") == "Defense", L.eval("ShownBars()"))

learned = L.eval("WOWFTrackerNS.WarmSkills(true)")
check("the warm learns the skills the sheet could not answer for",
      learned == 2, learned)
check("its own update is what was called, and it was never shown",
      L.eval("table.concat(CALLED, ',')") == "Update",
      L.eval("table.concat(CALLED, ',')"))
check("the window was left as it was found",
      L.eval("SHOWN_NOW") is False and L.eval("PARENT_NOW") == "UIParent",
      (L.eval("SHOWN_NOW"), L.eval("PARENT_NOW")))

L.execute("WOWFTrackerNS.UpdateReputation()")
check("and the bar is drawn without the panel ever being opened",
      sorted(L.eval("ShownBars()").split("|")) == ["Daggers", "Defense"],
      L.eval("ShownBars()"))
check("at the number the window was holding", L.eval('LogHas("48 / 80")'))

# The header the window draws above its rows is not a skill, and would be a bar
# at 0 out of 80 if it were taken for one.
check("the header among the rows is not stored as a skill",
      L.eval("WOWFTrackerDB.weaponSkills['Weapon Skills']") is None)

# What the whole thing is for: the values are the addon's own now, so a window
# that goes back to empty -- which is what the next login looks like -- does not
# take the numbers with it.
L.execute("WINDOW_ROWS = {} WOWFTrackerNS.UpdateReputation()")
check("and they survive the window emptying again",
      sorted(L.eval("ShownBars()").split("|")) == ["Daggers", "Defense"],
      L.eval("ShownBars()"))

# A client whose window only fills when it is told it has appeared. Nothing is
# shown here either -- the script is run, not the frame.
L = boot('FILLS = "onshow"\n' + PANEL)
learned = L.eval("WOWFTrackerNS.WarmSkills(true)")
check("an OnShow-only window is filled by running its OnShow",
      learned == 2 and L.eval("table.concat(CALLED, ',')") == "OnShow",
      (learned, L.eval("table.concat(CALLED, ',')")))
check("and it still never went on screen", L.eval("SHOWN_NOW") is False)

# The hard case: nothing fills it but a real show. It gets one, parented to
# something hidden, and has to come back with its parent and its anchors.
L = boot('FILLS = "show"\n' + PANEL)
learned = L.eval("WOWFTrackerNS.WarmSkills(true)")
check("a window that only fills on a real show gets one",
      learned == 2 and L.eval("table.concat(CALLED, ',')") == "Show",
      (learned, L.eval("table.concat(CALLED, ',')")))
check("it is hidden again afterwards", L.eval("SHOWN_NOW") is False)
check("its parent is put back",
      L.eval("PARENT_NOW") == "UIParent", L.eval("PARENT_NOW"))
check("and so is its anchor, which is where the panel opens next time",
      L.eval("POINTS_NOW") == 1, L.eval("POINTS_NOW"))

# A panel the player is looking at is not something to move out from under them.
L = boot('FILLS = "show"\n' + PANEL + '\nSHOWN_NOW = true\n')
L.eval("WOWFTrackerNS.WarmSkills(true)")
check("a panel that is open is read rather than reparented",
      L.eval("PARENT_NOW") == "UIParent"
      and L.eval("table.concat(CALLED, ',')") == "",
      (L.eval("PARENT_NOW"), L.eval("table.concat(CALLED, ',')")))

# And a client with no such window at all costs the attempt and nothing else.
L = boot(PANEL + "\nSkillsFrame = nil\nFILLS = 'none'\n")
check("no window at all is not an error",
      L.eval("WOWFTrackerNS.WarmSkills(true)") == 0)
check("and the addon still draws what it does know",
      L.eval("ShownBars()") == "Defense", L.eval("ShownBars()"))

# The throttle: this runs on every skill-up, and a run of them must not turn
# into a run of full attempts.
L = boot('''
FILLS = "update"
''' + PANEL + '''
SkillsFrame.Update = function()
    table.insert(CALLED, "Update")
    FillWindow()
end
''')
L.eval("WOWFTrackerNS.WarmSkills(false)")
L.execute("CALLED = {}")
L.eval("WOWFTrackerNS.WarmSkills(false)")
check("an unforced warm straight after another one does nothing",
      L.eval("table.concat(CALLED, ',')") == "",
      L.eval("table.concat(CALLED, ',')"))
# Emptied first, or the walk stops at "ask it" -- the window is still full from
# the warm above, and answering from it is the right thing to do.
L.execute("WINDOW_ROWS = {} NOW = NOW + 30")
L.eval("WOWFTrackerNS.WarmSkills(false)")
check("and it is allowed again once the gap has passed",
      L.eval("table.concat(CALLED, ',')") == "Update",
      L.eval("table.concat(CALLED, ',')"))

# The report itself. It is the thing that will be read in game when a client
# turns out to fill its window some sixth way, so it has to survive every shape
# above -- including the one with no window at all.
ran = L.eval("""
(function()
    local ok, err = pcall(SlashCmdList["WOWFTRACKER"], "weapons warm")
    return ok and "ok" or tostring(err)
end)()
""")
check("/wowft weapons warm runs and says what each step did", ran == "ok", ran)
# The command prints; the frame log is for bars, so this looks where it went.
PRINTED_HAS = """
(function(needle)
    for _, line in ipairs(PRINTED) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end)
"""
printed = L.eval(PRINTED_HAS)
# "load the window" is the one step that is always walked, whatever the client
# turns out to be; which of the others appear depends on what answered.
check("and names the steps it walked", printed("load the window") is True)
check("and what it is holding afterwards",
      printed("held for this character") is True)
check("with the ranks in it", printed("Daggers 48/80") is True)

L = boot(PANEL + chr(10) + "SkillsFrame = nil" + chr(10) + "FILLS = 'none'" + chr(10))
ran = L.eval("""
(function()
    local ok, err = pcall(SlashCmdList["WOWFTRACKER"], "weapons")
    return ok and "ok" or tostring(err)
end)()
""")
check("and it runs on a client with no skills window either", ran == "ok", ran)

# --- 6. one row per skill ---------------------------------------------------
# A client that lists the same skill twice -- a profession filed under both the
# primary and the secondary header, which is what this one does -- used to put it
# in the list twice, and the picker offered it twice with two checkboxes for the
# one skill.
print("-- a skill the client lists twice")

L = boot('''
ResetPanel(false, false)
ResetSkills(false)
-- Mining under Professions and again under Secondary Skills, which is the shape
-- the duplicate arrived in.
table.insert(SKILL_PANEL[2].children, { name = "Mining", rank = 300, max = 375 })
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Mining"] = true, ["skill:Cooking"] = true } }
''')

names = [s["name"] for s in [
    dict(name=L.eval("WOWFTrackerNS.GetAllSkills()[%d].name" % i))
    for i in range(1, int(L.eval("#WOWFTrackerNS.GetAllSkills()")) + 1)
]]
check("the picker offers it once", names.count("Mining") == 1, names)
check("and still offers everything else", "Cooking" in names, names)
check("the bar is drawn once too",
      L.eval("ShownBars()").split("|").count("Mining") == 1, L.eval("ShownBars()"))
check("and the duplicate is named rather than swallowed",
      L.eval("WOWFTrackerNS.DroppedDuplicates()['Mining']") == 2,
      L.eval("WOWFTrackerNS.DroppedDuplicates()['Mining']"))

# Between two rows for one skill, the one that can measure it is the answer --
# whichever order they arrive in.
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
SKILL_PANEL[1].children = { { name = "Mining", rank = 1, max = 1 } }
table.insert(SKILL_PANEL[2].children, { name = "Mining", rank = 300, max = 375 })
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Mining"] = true } }
''')
check("a named-only row takes the numbers from the measured duplicate",
      L.eval('LogHas("300 / 375")') is True)
check("and is no longer drawn as known-without-a-number",
      L.eval("WOWFTrackerNS.SkillIsFlat('Mining')") is False)

# A header left standing over nothing once its only row turned out to be a
# duplicate is a heading with no list under it.
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
SKILL_PANEL[2].children = { { name = "Mining", rank = 300, max = 375 } }
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Mining"] = true } }
''')
# GetSkillLineInfo here is the client's, not the tracker's -- its own view is
# what the list is built from, so the header each skill ends up under is what
# says whether one was left standing over nothing.
headers = sorted(set(
    L.eval("WOWFTrackerNS.GetAllSkills()[%d].header" % i)
    for i in range(1, int(L.eval("#WOWFTrackerNS.GetAllSkills()")) + 1)
))
check("nothing is left filed under the header the duplicate was under",
      "Secondary Skills" not in headers, headers)
check("and the skill kept the header it was first listed under",
      "Professions" in headers, headers)

# --- 7. weapon skills as they happen ----------------------------------------
# A sword going from 150 to 151 arrives as no event at all on this client, so the
# character sheet is read on a timer. These drive the timer by hand: the point is
# that nothing but time is needed, because that is the client being covered.
print("-- weapon skill-ups with no event to announce them")

# No panel worth reading, no professions, no skills window: the weapon numbers
# come off the character sheet and nowhere else, which is this client.
WEAPON_SHEET = '''
ResetPanel(false, false)
ResetSkills(false)
GetNumSkillLines, GetSkillLineInfo = nil, nil
function GetProfessions() return nil, nil, nil, nil, nil end
SkillsFrame = nil
LEVEL = 40
EQUIPPED = { [16] = "One-Handed Swords" }
SHEET = { defense = 148, mainhand = 150, offhand = 0, ranged = 0 }
UnitDefense = nil
function UnitDefenseSkill() return SHEET.defense, 0 end
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {},
    skills = { ["skill:Swords"] = true } }
'''

L = boot(WEAPON_SHEET)
check("the sword skill is drawn from the character sheet",
      L.eval("ShownBars()") == "Swords", L.eval("ShownBars()"))
check("at the rank the sheet gave", L.eval('LogHas("150 / 200")') is True)

# The skill goes up. No event fires -- that is the premise -- so nothing has
# changed yet.
L.execute("SHEET.mainhand = 151")
check("nothing moves on its own before the poll comes round",
      L.eval('LogHas("151 / 200")') is False)

L.execute("SKILL_TICK(2)")
check("the poll picks the skill-up up with no event at all",
      L.eval('LogHas("151 / 200")') is True)

# This runs every couple of seconds for the whole session, so a tick with
# nothing new has to cost nothing.
L.execute("SETTEXT_LOG = {}")
check("a tick with nothing new does no work",
      L.eval("WOWFTrackerNS.PollWeaponSkills()") is False
      and L.eval("#SETTEXT_LOG") == 0,
      L.eval("#SETTEXT_LOG"))

L.execute("SHEET.mainhand = 152")
L.execute("SKILL_TICK(0.5)")
check("a fraction of the interval is not a tick",
      L.eval('LogHas("152 / 200")') is False)
L.execute("SKILL_TICK(1.6)")
check("and the rest of it is", L.eval('LogHas("152 / 200")') is True)

# If the client does fire something, the bar must not wait for the timer.
L = boot(WEAPON_SHEET)
L.execute('SHEET.mainhand = 175; FireEvent("CHAT_MSG_SKILL")')
check("an event the client does fire is acted on at once",
      L.eval('LogHas("175 / 200")') is True)

# Defence comes off its own reader and has to move the same way.
L.execute("WOWFTrackerDB.skills['skill:Defense'] = true")
L.execute("SHEET.defense = 149")
L.execute("SKILL_TICK(2)")
check("defence moves on the poll too",
      sorted(L.eval("ShownBars()").split("|")) == ["Defense", "Swords"],
      L.eval("ShownBars()"))
check("at its new rank", L.eval('LogHas("149 / 200")') is True)

# A reader that throws -- which is what this client does with some numbers -- is
# not an answer, and must not take the rank that was already known with it.
L.execute('function UnitAttackBothHands() error("secret") end')
L.execute("SKILL_TICK(2)")
check("a reader that throws leaves the last good rank standing",
      L.eval("WOWFTrackerDB.weaponSkills.Swords") == 175,
      L.eval("WOWFTrackerDB.weaponSkills.Swords"))
check("and the bar is still drawn", L.eval('LogHas("175 / 200")') is True)

# The client can report skill changes before PLAYER_LOGIN, and on a cold start
# WOWFTrackerDB is still nil then -- InitDB has not run and the client handed
# nothing back. Nothing may read the profile before it exists.
L = boot(WEAPON_SHEET, login=False)
L.execute("WOWFTrackerDB = nil")
for event in ("SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "PLAYER_LEVEL_UP"):
    ok = L.eval('(function() local ok, err = pcall(FireEvent, "%s") '
                'return ok or tostring(err) end)()' % event)
    check(event + " before login is not an error", ok is True, ok)
ok = L.eval('(function() local ok, err = pcall(SKILL_TICK, 2) return ok or tostring(err) end)()')
check("nor is the skill poll", ok is True, ok)
L.execute('FireEvent("PLAYER_LOGIN")')
check("login still builds the profile", L.eval("type(WOWFTrackerDB.settings)") == "table")
L.execute("WOWFTrackerDB.skills['skill:Swords'] = true")
L.execute('SHEET.mainhand = 175; FireEvent("CHAT_MSG_SKILL")')
check("and the list still fills in once logged in", L.eval('LogHas("175 / 200")') is True)


# --- opened from anywhere, it opens inside the Chaircraft menu ------------
print("-- inside the Chaircraft menu")
L = boot('''
ResetPanel(false, false)
ResetSkills(true)
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {}, skills = {} }
''')
L.execute("""
HOSTED = 0
ChairPlusNS = { OpenPartPage = function(token)
    HOSTED = HOSTED + 1
    WOWFTrackerNS.optionsFrame.chairEmbedded = true
    WOWFTrackerNS.ShowOptions()
    return true
end }
""")
L.execute("WOWFTrackerNS.ToggleOptions()")
check("the gear button opens the options through the menu",
      L.eval("HOSTED") == 1 and L.eval("WOWFTrackerOptions:IsShown()") is True,
      str(L.eval("HOSTED")))
check("the window lists what the menu hides",
      L.eval("#WOWFTrackerNS.optionsFrame.chairChrome") == 3)
L.execute("WOWFTrackerNS.ToggleOptions()")
check("pressing it again closes it", L.eval("WOWFTrackerOptions:IsShown()") is False
      and L.eval("HOSTED") == 1)

# Docked in ChairPlus's OSD: the window stays shut until the OSD item is
# hovered, then drops down under it; undocked, it is a window again.
print("-- docked in the OSD")
L = boot('''
ResetPanel(false, false)
ResetSkills(false)
WOWFTrackerDB = { settings = { sortMode = "name_asc" }, factions = {}, skills = {} }
''')
L.execute("""
DOCK = CreateFrame("Frame")
WOWFTrackerNS.SetWindowVisible(true)
WOWFTrackerNS.Dock(DOCK)
""")
check("docking shuts the standalone window", L.eval("WOWFTrackerFrame:IsShown()") is False)
L.execute("WOWFTrackerNS.SetWindowVisible(true)")
check("and asking for the window while docked does not open it",
      L.eval("WOWFTrackerFrame:IsShown()") is False)
L.execute("WOWFTrackerNS.DockShow()")
check("hovering the OSD item drops it down", L.eval("WOWFTrackerFrame:IsShown()") is True)
L.execute("WOWFTrackerNS.Dock(nil)")
check("undocked, the window comes back as it was left",
      L.eval("WOWFTrackerFrame:IsShown()") is True and L.eval("WOWFTrackerNS.docked") is None)

print("ALL OK" if not failures else "%d FAILED" % len(failures))
sys.exit(1 if failures else 0)
