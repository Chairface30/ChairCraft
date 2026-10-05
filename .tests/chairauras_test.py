# Relocated into Chaircraft on 2026-09-22, when the standalone addon folders
# were deleted. Until then this ran as a runtime-patched copy of that addon's
# own suite; there is no upstream to re-run against any more, so it lives here.
# Offline checks for ChairAuras (needs: pip install lupa).
#   python .tests/chairauras_test.py
# 1. Every .lua file parses as Lua 5.1 (the dialect WoW uses).
# 2. Loads the addon against a mocked client and checks the things that are easy
#    to get wrong and impossible to see until you are standing in the game:
#    the v1 -> v2 migration, matching an aura by name, load conditions, dynamic
#    group compaction, and the spell-off-the-cursor payload.
import glob, io, math, os, sys
from lupa import lua51

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

HARNESS = r'''
-- Frames: any CamelCase key is a method; lowercase keys are plain fields.
FRAMES, EVENT_FRAMES, PRINTED = {}, {}, {}

local Mock
local function Method(k)
    return setmetatable({}, {
        __index = function(_, key)
            if type(key) == "string" and key:match("^%u") then return Method(key) end
        end,
        __call = function(_, self, ...)
            if type(self) ~= "table" then return Mock() end
            if k == "Insert" then
                CHAT_INSERTED = (...)
            elseif k == "SetText" then rawset(self, "_text", (...))
            elseif k == "GetText" then return rawget(self, "_text")
            elseif k == "SetDesaturated" then rawset(self, "_desaturated", (...) and true or false)
            elseif k == "IsDesaturated" then return rawget(self, "_desaturated") == true
            elseif k == "Show" then
                local was = rawget(self, "_shown")
                rawset(self, "_shown", true)
                -- A real frame runs its OnShow/OnHide when it is shown or
                -- hidden, and code hangs behaviour off those, so the mock has
                -- to as well. Only on an actual change, the way the game does.
                local scripts = rawget(self, "_scripts")
                if was ~= true and scripts and scripts.OnShow then
                    scripts.OnShow(self)
                end
            elseif k == "Hide" then
                local was = rawget(self, "_shown")
                rawset(self, "_shown", false)
                local scripts = rawget(self, "_scripts")
                if was == true and scripts and scripts.OnHide then
                    scripts.OnHide(self)
                end
            elseif k == "IsShown" then return rawget(self, "_shown") == true
            elseif k == "SetSize" then
                local w, h = ...
                rawset(self, "_w", w); rawset(self, "_h", h)
            elseif k == "GetHeight" then return rawget(self, "_h") or 0
            elseif k == "GetTop" then return rawget(self, "_top")
            elseif k == "GetBottom" then return rawget(self, "_bottom")
            elseif k == "GetEffectiveScale" then return 1
            elseif k == "GetWidth" then return rawget(self, "_w") or 0
            elseif k == "GetSize" then
                return rawget(self, "_w") or 0, rawget(self, "_h") or 0
            elseif k == "GetCenter" then
                -- Enough for the position maths: a frame sits where its point
                -- put it, measured from the middle of a 1024x768 screen.
                local point = rawget(self, "_point") or { x = 0, y = 0 }
                return 512 + (point.x or 0), 384 + (point.y or 0)
            elseif k == "SetAlpha" then rawset(self, "_alpha", (...))
            elseif k == "SetValue" then rawset(self, "_value", (...))
            elseif k == "GetFont" then
                local f = rawget(self, "_font")
                if f then return f[1], f[2], f[3] end
                return "Fonts\\FRIZQT__.TTF", 12, ""
            elseif k == "SetFont" then rawset(self, "_font", { ... })
            elseif k == "SetTextColor" then rawset(self, "_colour", { ... })
            elseif k == "SetStatusBarColor" then rawset(self, "_colour", (...))
            elseif k == "GetValue" then return rawget(self, "_value") or 0
            elseif k == "SetShown" then rawset(self, "_shown", (...) and true or false)
            elseif k == "EnableMouse" then rawset(self, "_mouse", (...) and true or false)
            elseif k == "SetBackdrop" then rawset(self, "_backdrop", (...))
            elseif k == "GetAlpha" then return rawget(self, "_alpha") or 1
            elseif k == "SetPoint" then
                local point, a, b, c = ...
                -- Two shapes: SetPoint(point, x, y) inside a parent, and
                -- SetPoint(point, frame, point, x, y). Only the offsets matter.
                if type(a) == "number" then
                    rawset(self, "_point", { point = point, x = a, y = b })
                else
                    rawset(self, "_point", { point = point, x = c, y = (select(5, ...)) })
                end
            elseif k == "ClearAllPoints" then rawset(self, "_point", nil)
            elseif k == "SetParent" then rawset(self, "_parent", (...))
            elseif k == "GetParent" then return rawget(self, "_parent")
            elseif k == "SetScript" then
                local name, fn = ...
                local s = rawget(self, "_scripts") or {}
                s[name] = fn
                rawset(self, "_scripts", s)
            elseif k == "RegisterEvent" or k == "RegisterUnitEvent" then
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
    local f = setmetatable({}, { __index = function(_, key)
        if type(key) == "string" and key:match("^%u") then return Method(key) end
    end })
    table.insert(FRAMES, f)
    return f
end

function CreateFrame(ftype, name, parent, template)
    local f = Mock()
    rawset(f, "_parent", parent)
    if name then _G[name] = f end
    return f
end

-- The sweep is not an event: it hangs off OnUpdate, so the harness has to be
-- able to hand out frames the way the game hands out elapsed time.
function DRIVER_TICK(elapsed)
    for _, f in ipairs(FRAMES) do
        local s = rawget(f, "_scripts")
        if s and s.OnUpdate then s.OnUpdate(f, elapsed) end
    end
end

function FireEvent(ev, ...)
    for _, f in ipairs(EVENT_FRAMES) do
        if f._events[ev] and f._scripts and f._scripts.OnEvent then
            f._scripts.OnEvent(f, ev, ...)
        end
    end
end

UIParent, GameTooltip = Mock(), Mock()

-- Chat: the filters an addon installs, and the box a link is typed into.
CHAT_FILTERS = {}
function ChatFrame_AddMessageEventFilter(event, fn)
    CHAT_FILTERS[event] = CHAT_FILTERS[event] or {}
    table.insert(CHAT_FILTERS[event], fn)
    return true
end

-- What a line looks like by the time it reaches the frame.
function DeliverChat(event, message, sender)
    for _, fn in ipairs(CHAT_FILTERS[event] or {}) do
        local blocked, rewritten = fn(nil, event, message, sender)
        if blocked then return nil end
        if rewritten then message = rewritten end
    end
    return message
end

-- A tooltip a clicked link can write into, and the keyboard focus a
-- shift-click forwards through.
ItemRefTooltip = Mock()
function ShowUIPanel() end
KEYBOARD_FOCUS = nil
function GetCurrentKeyBoardFocus() return KEYBOARD_FOCUS end

-- Modifier keys, which several gestures hang off.
SHIFT = false
function IsShiftKeyDown() return SHIFT end

-- Who counts as someone you know, for whispers.
IN_PARTY, IN_GUILD = false, false
function UnitInParty() return IN_PARTY end
function UnitInRaid() return false end
function IsGuildMember() return IN_GUILD end
function Ambiguate(name) return (name:gsub("%-.*$", "")) end

WHISPERED = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, message, channel, target)
        table.insert(WHISPERED, { prefix = prefix, message = message,
                                  channel = channel, target = target })
        return true
    end,
}

HOOKED = {}
function hooksecurefunc(name, fn)
    HOOKED[name] = HOOKED[name] or {}
    table.insert(HOOKED[name], fn)
end
function SetItemRef() end

-- Chat windows, which is what the frame-level rewrite hooks. Each records
-- what it was finally asked to draw.
NUM_CHAT_WINDOWS = 3
DRAWN = {}
for index = 1, NUM_CHAT_WINDOWS do
    local frame = Mock()
    frame.AddMessage = function(self, text) table.insert(DRAWN, text) end
    _G["ChatFrame" .. index] = frame
end

-- The chat box a link gets inserted into.
CHAT_INSERTED = nil
ChatFrame1EditBox = Mock()
function ChatEdit_GetActiveWindow() return ChatFrame1EditBox end
function ChatEdit_ActivateChat() end
UIParent:SetSize(1024, 768)
rawset(UIParent, "_point", { x = 0, y = 0 })
function GameTooltip_Hide() end
IMMEDIATE_TIMERS = false
C_Timer = { After = function(_, fn)
    if IMMEDIATE_TIMERS then fn() end
end }
SlashCmdList, UISpecialFrames, tinsert = {}, {}, table.insert
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(PRINTED, table.concat(parts, " "))
end
-- Writes a table out as Lua source, which is what the client does to the
-- saved file: a session ends, the table becomes text, and the next session
-- reads that text back. Testing persistence without this only ever tests that
-- a table still has what was just put in it.
function DUMP(value)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "nil" end

    local parts = {}
    for key, inner in pairs(value) do
        local written
        if type(key) == "string" then
            written = "[" .. string.format("%q", key) .. "]"
        else
            written = "[" .. tostring(key) .. "]"
        end
        parts[#parts + 1] = written .. " = " .. DUMP(inner)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

function wipe(t) for k in pairs(t) do t[k] = nil end return t end
NOW = 1000
function GetTime() return NOW end
CURSOR_Y = 0
function GetCursorPosition() return 0, CURSOR_Y end
function ClearCursor() end

-- Sounds, recorded rather than played.
SOUNDS, STOPPED, NEXT_HANDLE = {}, {}, 0
SOUNDKIT = { IG_MAINMENU_OPEN = 850, IG_QUEST_LIST_COMPLETE = 878,
             RAID_WARNING = 8959, ALARM_CLOCK_WARNING_3 = 12867 }
function PlaySound(id, channel)
    NEXT_HANDLE = NEXT_HANDLE + 1
    table.insert(SOUNDS, { kind = "id", value = id, channel = channel,
                           handle = NEXT_HANDLE })
    return true, NEXT_HANDLE
end
function PlaySoundFile(path, channel)
    NEXT_HANDLE = NEXT_HANDLE + 1
    table.insert(SOUNDS, { kind = "file", value = path, channel = channel,
                           handle = NEXT_HANDLE })
    return true, NEXT_HANDLE
end
function StopSound(handle)
    table.insert(STOPPED, handle)
    return true
end

-- Player identity and state
UnitNameValue, REALM = "Tester", "Testrealm"
LEVEL, CLASS_TOKEN, FORM = 60, "DRUID", nil
IN_COMBAT, IN_GROUP, ZONE = false, false, "Elwynn Forest"
function UnitName() return UnitNameValue end
function GetRealmName() return REALM end
function UnitGUID() return "Player-1-00000001" end
function UnitLevel() return LEVEL end
function UnitClass() return "Druid", CLASS_TOKEN end
function UnitExists(unit) return unit == "player" or unit == "target" end
function UnitCanAttack() return true end
function UnitAffectingCombat() return IN_COMBAT end
function IsInGroup() return IN_GROUP end
function IsInRaid() return false end
function IsInInstance() return false end
function IsResting() return false end
function IsMounted() return false end
function IsStealthed() return false end
DEAD = false
function UnitIsDeadOrGhost() return DEAD end
function GetShapeshiftFormID() return FORM end
function GetRealZoneText() return ZONE end
function GetSubZoneText() return "" end
function GetZoneText() return ZONE end
function GetMinimapZoneText() return ZONE end
CAT_FORM, BEAR_FORM, DIRE_BEAR_FORM, MOONKIN_FORM = 1, 5, 8, 31
LOCALIZED_CLASS_NAMES_MALE = { DRUID = "Druid", HUNTER = "Hunter", MAGE = "Mage",
    PALADIN = "Paladin", PRIEST = "Priest", ROGUE = "Rogue", SHAMAN = "Shaman",
    WARLOCK = "Warlock", WARRIOR = "Warrior" }

-- Spells
SPELLS = {
    [774]  = { name = "Rejuvenation", icon = 100 },
    [8936] = { name = "Regrowth", icon = 101 },
    [5487] = { name = "Bear Form", icon = 102 },
    [1126] = { name = "Mark of the Wild", icon = 103 },
}
C_Spell = {
    GetSpellName = function(id) return SPELLS[id] and SPELLS[id].name end,
    GetSpellTexture = function(id) return SPELLS[id] and SPELLS[id].icon end,
    DoesSpellExist = function(id) return SPELLS[id] ~= nil end,
    GetSpellInfo = function(text)
        for id, spell in pairs(SPELLS) do
            if spell.name == text then return { spellID = id, name = spell.name } end
        end
        return nil
    end,
    GetSpellCooldown = function(id)
        local cd = COOLDOWNS and COOLDOWNS[id]
        if not cd then return { duration = 0, startTime = 0 } end
        return { duration = cd.duration, startTime = cd.start }
    end,
}
COOLDOWNS = {}

-- Auras. AURAS[unit] = { { name=, spellId=, applications=, duration=, expirationTime=, isHarmful= } }
AURAS = { player = {}, target = {} }

-- This client refuses aura reads from addon code once it has decided the aura
-- is secret, which it does in combat: the call throws rather than answering.
-- AURAS_REFUSED makes it do that here.
AURAS_REFUSED = false

-- And sometimes it answers with a table whose fields cannot be read. A value
-- that errors when anything tries to make text of it is what that looks like
-- from in here.
local function Secret()
    return setmetatable({}, { __tostring = function() error("secret") end,
                              __concat = function() error("secret") end })
end
SECRET_VALUE = Secret

C_UnitAuras = {
    GetAuraDataByIndex = function(unit, index, filter)
        if AURAS_REFUSED then error("Auras cannot be accessed when secret") end
        local wantHarmful = filter and filter:find("HARMFUL") ~= nil
        local mineOnly = filter and filter:find("PLAYER") ~= nil
        local matching = {}
        for _, aura in ipairs(AURAS[unit] or {}) do
            local harmful = aura.isHarmful and true or false
            if harmful == wantHarmful and (not mineOnly or aura.mine) then
                matching[#matching + 1] = aura
            end
        end
        return matching[index]
    end,
}

-- The cursor: this client answers with four values for a spell, the ID last.
CURSOR = nil
function GetCursorInfo()
    if not CURSOR then return nil end
    return "spell", CURSOR.index, CURSOR.book, CURSOR.spellID
end
'''

# A saved file that arrived and has nothing in it. The real cold start on this
# client is worse than this -- the global is not there at all and the grace
# period runs out -- but both end in the same place, a profile with no auras,
# which is what the seeding decision is made on.
EMPTY_SAVED = """
ChairAurasDB = { version = 2, profiles = {} }
"""

SAVED_ONE_AURA = """
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = {
    auras = { { id = "a1", name = "mine", trigger = { spellID = 774 } } },
} } }
"""

# Which frames swept, as a string of ones and noughts -- the sweep is counted
# by standing in front of UpdateAll rather than inferred from what ended up on
# screen. dirty names the frames an event arrives on: "" never, "all" every one,
# or a comma-separated list. Each run settles the tick clock first, so one run
# cannot answer for the next.
SWEEP_PATTERN = """
(function()
    local swept = false
    local real = ns.Engine.UpdateAll
    ns.Engine.UpdateAll = function(self, ...) swept = true return real(self, ...) end
    return function(elapsed, frames, dirty)
        local on = {}
        if dirty == "all" then
            on.all = true
        else
            for n in string.gmatch(dirty or "", "%d+") do on[tonumber(n)] = true end
        end

        DRIVER_TICK(999)      -- the clock starts from a known place
        local out = {}
        for frame = 1, frames do
            swept = false
            if on.all or on[frame] then ns.RequestUpdate() end
            DRIVER_TICK(elapsed)
            out[#out + 1] = swept and "1" or "0"
        end
        return table.concat(out)
    end
end)()
"""

failures = []
def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)

# --- 1. syntax ------------------------------------------------------------
L = lua51.LuaRuntime(unpack_returned_tuples=True)
loadstring = L.eval("function(s,n) return loadstring(s,n) end")
FILES = ["Core.lua", "Presets.lua", "Database.lua", "Load.lua", "AuraEnvironment.lua", "Engine.lua", "CustomTrigger.lua", "Triggers.lua", "Text.lua", "Conditions.lua", "Actions.lua",
         "Display.lua", "Regions.lua", "SubRegions.lua", "Animations.lua", "Icons.lua", "Share.lua", "Templates.lua", "Sounds.lua", "Config.lua",
         "Probe.lua", "Commands.lua"]
FILES = ["ChairAuras/" + _f for _f in FILES]
LIBS = ["Libs/LibStub/LibStub.lua", "Libs/LibDeflate/LibDeflate.lua", "Libs/LibSerialize/LibSerialize.lua"]
for f in FILES:
    res = loadstring(io.open(f, encoding="utf-8").read(), "@" + f)
    fn, err = (res if isinstance(res, tuple) else (res, None))
    check("parses " + f, fn is not None, err)
if failures:
    sys.exit(1)


# preset=False for everything that is not about the preset: an empty profile
# would otherwise come up holding the four auras written into Presets.lua, and a
# test that means "nothing is configured yet" has to be able to say so.
def boot(setup="", preset=False):
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(HARNESS)
    L.execute(setup)
    run = L.eval("function(s, n) local f = assert(loadstring(s, n)); f('Chaircraft', suite) end")
    L.execute("ns = {}; suite = { ChairAuras = ns }; suite.UnitFullName = function(unit) local ok, a, b = pcall(UnitName, unit) if not ok or a == nil then return nil end a = tostring(a) if b ~= nil and tostring(b) ~= \"\" then return a .. \" \" .. tostring(b) end return a end")
    L.execute('suite.IsSecret = function(v) return not pcall(function() return "" .. tostring(v) end) end')
    # The libraries the TOC loads ahead of ChairAuras: LibStub, and the ones
    # the WeakAuras-style strings are made with.
    for f in LIBS:
        run(io.open(f, encoding="utf-8").read(), "@" + f)
    for f in FILES:
        run(io.open(f, encoding="utf-8").read(), "@" + f)
    # Seeding ships off; preset=True switches it on, as "/ca preset on" would,
    # for the tests about what seeding does. preset=None leaves it as shipped.
    if preset is not None:
        L.execute("ns.presetEnabled = " + ("true" if preset else "false"))
    L.execute('FireEvent("PLAYER_LOGIN")')
    return L

# The addon takes (addonName, ns) as its vararg; the loader above hands both in,
# so every file shares one namespace table the way the real client gives them one.

# --- 2. migration ---------------------------------------------------------
print("-- migration from the flat watcher list")
L = boot('''
ChairAurasDB = { version = 1, profiles = { ["guid:Player-1-00000001"] = {
    size = 32, spacing = 4, growth = "LEFT", pos = { x = 10, y = -20 },
    watchers = {
        { spellID = 774, kind = "buff", unit = "player" },
        { spellID = 8936, kind = "debuff", unit = "target", mine = true },
        { spellID = 5487, kind = "cooldown", invert = true },
    },
} } }
''')
ev = L.eval
check("watchers became auras", ev("#ns.GetAuras()") == 4, ev("#ns.GetAuras()"))
check("a dynamic group was made to hold them",
      ev("ns.GetAuras()[1].type") == "dynamic", ev("ns.GetAuras()[1].type"))
check("the row keeps its growth", ev("ns.GetAuras()[1].growth") == "LEFT")
# A stored position is now where the pivot sits, and a left-growing row is held
# by its top-right corner. The old number was a centre, so the one that matters
# is whether the centre it described survived the conversion.
width = ev("(ns.Display.__regions.a1:GetSize())")
height = ev("(select(2, ns.Display.__regions.a1:GetSize()))")
check("and its position converts to the corner that now holds it",
      ev("ns.GetAuras()[1].pos.pivot") == "TOPRIGHT"
      and ev("ns.GetAuras()[1].pos.x") - width / 2 == 10
      and ev("ns.GetAuras()[1].pos.y") - height / 2 == -20,
      (ev("ns.GetAuras()[1].pos.pivot"), ev("ns.GetAuras()[1].pos.x"), width))
check("every watcher is inside it",
      ev("ns.GetAuras()[2].parent") == "a1" and ev("ns.GetAuras()[4].parent") == "a1")
check("a debuff stayed a debuff on the target",
      ev("ns.TriggerField(ns.GetAuras()[3], 'harmful')") is True
      and ev("ns.TriggerField(ns.GetAuras()[3], 'unit')") == "target")
check("mine-only survived", ev("ns.TriggerField(ns.GetAuras()[3], 'mine')") is True)
check("a cooldown stayed a cooldown",
      ev("ns.TriggerField(ns.GetAuras()[4], 'type')") == "cooldown")
check("inversion survived", ev("ns.DisplayField(ns.GetAuras()[4], 'invert')") is True)
check("icon size survived", ev("ns.DisplayField(ns.GetAuras()[2], 'size')") == 32)
check("the old list is gone", ev("ns.GetProfile().watchers") is None)
check("a second load does not migrate twice",
      ev("ChairAurasDB.version") == 3)

# --- 3. matching by name --------------------------------------------------
print("-- triggers that match the text on the aura")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "Well Fed" } },
    { id = "a2", trigger = { match = "name", text = "fed", partial = true } },
    { id = "a3", trigger = { spellID = 774 } },
} } } }
AURAS.player = {
    { name = "Well Fed", spellId = 999111, applications = 0, duration = 0 },
    { name = "Rejuvenation", spellId = 774, applications = 3,
      duration = 12, expirationTime = 1012 },
}
''')
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("an aura with no spell anyone knows is matched by its name",
      ev("ns.Engine.states.a1.shown") is True)
check("a partial name matches a family of them",
      ev("ns.Engine.states.a2.shown") is True)
check("matching by ID still works alongside it",
      ev("ns.Engine.states.a3.shown") is True)
check("stacks come through", ev("ns.Engine.states.a3.count") == 3)
check("a timed aura reports its window",
      ev("ns.Engine.states.a3.duration") == 12 and ev("ns.Engine.states.a3.start") == 1000)
check("a permanent aura draws no swipe", ev("ns.Engine.states.a1.duration") is None)

L.execute('AURAS.player = {}; ns.Engine:UpdateAll()')
check("and it goes out when the aura does", ev("ns.Engine.states.a1.shown") is False)

# A buff that is not on you is a buff you have no stacks of.
check("an aura that is not up reports zero stacks",
      ev("ns.Engine.states.a1.count") == 0,
      "absent aura reported %s" % ev("ns.Engine.states.a1.count"))

# Exact match must not fire on a longer name that contains it.
L.execute('''
AURAS.player = { { name = "Well Fed and Watered", spellId = 999112 } }
ns.Engine:UpdateAll()
''')
check("an exact match stays exact", ev("ns.Engine.states.a1.shown") is False)
check("while the contains match still catches it", ev("ns.Engine.states.a2.shown") is True)

# --- 4. stack thresholds --------------------------------------------------
print("-- stack counts")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { spellID = 774, stacks = 3, stacksOp = ">=" } },
    { id = "a2", trigger = { spellID = 774, stacks = 3, stacksOp = "==" } },
} } } }
AURAS.player = { { name = "Rejuvenation", spellId = 774, applications = 2 } }
''')
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("under the threshold, nothing", ev("ns.Engine.states.a1.shown") is False)
L.execute('AURAS.player[1].applications = 4; ns.Engine:UpdateAll()')
check("at least three, with four", ev("ns.Engine.states.a1.shown") is True)
check("exactly three, with four", ev("ns.Engine.states.a2.shown") is False)

# --- 5. load conditions ---------------------------------------------------
print("-- load conditions")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" }, load = { combat = true } },
    { id = "a2", trigger = { match = "name", text = "x" }, load = { class = { WARRIOR = true } } },
    { id = "a3", trigger = { match = "name", text = "x" }, load = { level = { min = 70 } } },
    { id = "a4", trigger = { match = "name", text = "x" }, load = { form = { CAT_FORM = true } } },
    { id = "a5", trigger = { match = "name", text = "x" }, load = { zone = "elwynn" } },
    { id = "a6", trigger = { match = "name", text = "x" }, load = { never = true } },
    { id = "a7", trigger = { match = "name", text = "x" } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
''')
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("out of combat, a combat aura is not loaded", ev("ns.Engine.states.a1.loaded") is False)
check("wrong class, not loaded", ev("ns.Engine.states.a2.loaded") is False)
check("under the level, not loaded", ev("ns.Engine.states.a3.loaded") is False)
check("wrong form, not loaded", ev("ns.Engine.states.a4.loaded") is False)
check("right zone, loaded", ev("ns.Engine.states.a5.loaded") is True)
check("never means never", ev("ns.Engine.states.a6.loaded") is False)
check("no conditions at all means always", ev("ns.Engine.states.a7.loaded") is True)
check("an unloaded aura never shows", ev("ns.Engine.states.a1.shown") is False)

L.execute('IN_COMBAT = true; LEVEL = 70; FORM = CAT_FORM; ns.Engine:UpdateAll()')
check("in combat, it loads", ev("ns.Engine.states.a1.loaded") is True)
check("at the level, it loads", ev("ns.Engine.states.a3.loaded") is True)
check("in cat form, it loads", ev("ns.Engine.states.a4.loaded") is True)
check("and then it can show", ev("ns.Engine.states.a1.shown") is True)

L.execute('ZONE = "Orgrimmar"; ns.Engine:UpdateAll()')
check("leaving the zone unloads it", ev("ns.Engine.states.a5.loaded") is False)

# A condition this client cannot answer must never be the reason something is
# missing from the screen.
L2 = boot('''
IsInInstance = nil
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" }, load = { instance = true } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
''')
L2.execute("ns.Engine:UpdateAll()")
check("a condition the client cannot answer does not block loading",
      L2.eval("ns.Engine.states.a1.loaded") is True)

# --- 5b. one box, three answers -------------------------------------------
# A load condition has three states -- must be so, must not be, do not care --
# and the box walks round them in that order.
print("-- load toggles cycle")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('a1'); ns.Config:SetTab('load')")


def combat_field(L):
    return L.eval("""
        (function()
            for _, field in ipairs(ns.Config.__loadFields or {}) do
                if field.key == "combat" then return field end
            end
        end)()
    """)


field = combat_field(L)
check("the combat condition is drawn as one three-state box",
      field is not None and field["kind"] == "tristate",
      field and field["kind"])

# Parenthesised: FindAura answers with the aura and its index, and lupa
# hands back both as a tuple otherwise.
aura = L.eval("(ns.FindAura('a1'))")
check("it starts asking nothing at all", L.eval("(ns.FindAura('a1').load or {}).combat") is None)

field["cycle"](aura)
check("first click means it must be so", ev("ns.FindAura('a1').load.combat") is True)
L.execute("ns.Engine:UpdateAll()")
check("and out of combat that keeps it unloaded", ev("ns.Engine.states.a1.loaded") is False)

field["cycle"](aura)
check("second click means it must not be", ev("ns.FindAura('a1').load.combat") is False)
L.execute("ns.Engine:UpdateAll()")
check("which out of combat loads it", ev("ns.Engine.states.a1.loaded") is True)

L.execute("IN_COMBAT = true; ns.Engine:UpdateAll()")
check("and in combat does not", ev("ns.Engine.states.a1.loaded") is False)

field["cycle"](aura)
check("third click stops asking", ev("(ns.FindAura('a1').load or {}).combat") is None)
L.execute("ns.Engine:UpdateAll()")
check("so it loads either way", ev("ns.Engine.states.a1.loaded") is True)
L.execute("IN_COMBAT = false; ns.Engine:UpdateAll()")
check("both ways", ev("ns.Engine.states.a1.loaded") is True)

field["cycle"](aura)
check("and round it goes again", ev("ns.FindAura('a1').load.combat") is True)

# The three states have to be told apart on screen, which on a client with
# missing art means the words have to carry it, not only the tick.
labels = {}
for wanted in (True, False, None):
    L.execute("ns.FindAura('a1').load.combat = %s"
              % ("true" if wanted is True else "false" if wanted is False else "nil"))
    L.execute("ns.Config:SetTab('load')")
    labels[wanted] = L.eval("""
        (function()
            for _, entry in pairs(ns.Config.__panes or {}) do
                for _, widget in ipairs(entry.pane.widgets or {}) do
                    if widget.field and widget.field.key == "combat" and widget.check then
                        return widget.check.label:GetText()
                    end
                end
            end
        end)()
    """)
check("yes, no and off each read differently",
      len({v for v in labels.values() if v}) == 3, labels)
check("and say which is which in words",
      "yes" in (labels[True] or "") and "no" in (labels[False] or ""), labels)

# --- 5c. alive or not ------------------------------------------------------
print("-- the alive condition")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" }, load = { alive = true } },
    { id = "a2", trigger = { match = "name", text = "x" }, load = { alive = false } },
    { id = "a3", trigger = { match = "name", text = "x" } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("alive, the alive-only one loads", ev("ns.Engine.states.a1.loaded") is True)
check("and the dead-only one does not", ev("ns.Engine.states.a2.loaded") is False)

L.execute("DEAD = true; ns.Engine:UpdateAll()")
check("dead, that swaps over",
      ev("ns.Engine.states.a1.loaded") is False
      and ev("ns.Engine.states.a2.loaded") is True)
check("and one that never asked carries on regardless",
      ev("ns.Engine.states.a3.loaded") is True)

# A client that cannot answer must not be the reason an aura vanishes.
L2 = boot("""
UnitIsDeadOrGhost, UnitIsDead, UnitIsGhost = nil, nil, nil
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" }, load = { alive = true } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
""")
L2.execute("ns.Engine:UpdateAll()")
check("a client that cannot say loads it anyway",
      L2.eval("ns.Engine.states.a1.loaded") is True)
check("and the window greys the setting rather than offering it",
      L2.eval("(function() for _, c in ipairs(ns.Load.CONDITIONS) do "
              "if c.key == 'alive' then return ns.Load:Available(c) end end end)()") is False)

# The older pair still answers where the combined one is gone.
L3 = boot("""
UnitIsDeadOrGhost = nil
GHOST = false
function UnitIsDead() return DEAD end
function UnitIsGhost() return GHOST end
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" }, load = { alive = true } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
""")
L3.execute("GHOST = true; ns.Engine:UpdateAll()")
check("a ghost counts as not alive even without the combined call",
      L3.eval("ns.Engine.states.a1.loaded") is False)

# --- 6. groups ------------------------------------------------------------
print("-- groups and dynamic groups")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "group", name = "Static", spacing = 10 },
    { id = "g2", type = "dynamic", name = "Dyn", spacing = 10 },
    { id = "a1", parent = "g1", trigger = { match = "name", text = "one" } },
    { id = "a2", parent = "g1", trigger = { match = "name", text = "two" } },
    { id = "b1", parent = "g2", trigger = { match = "name", text = "one" } },
    { id = "b2", parent = "g2", trigger = { match = "name", text = "two" } },
    { id = "b3", parent = "g2", trigger = { match = "name", text = "three" } },
} } } }
AURAS.player = { { name = "one", spellId = 1 }, { name = "three", spellId = 3 } }
''')
ev = L.eval
check("the tree knows its children", ev("#ns.Children('g1')") == 2)
check("top level is the two groups", ev("#ns.TopLevel()") == 2)
check("a group cannot be put inside itself",
      ev("ns.WouldLoop(ns.FindAura('g1'), 'g1')") is True)

L.execute("ns.Engine:UpdateAll()")

# The positions the layout actually wrote, read back off the mock frames.
slots = L.eval('''
(function()
    local out = {}
    for _, id in ipairs({ "a1", "a2", "b1", "b2", "b3" }) do
        local frame = ns.Display.__regions[id]
        local point = frame and rawget(frame, "_point")
        out[id] = point and point.x or false
    end
    return out
end)()
''')
check("static child one at the start", slots["a1"] == 0, dict(slots))
check("static child two one step along (40 + 10 spacing)", slots["a2"] == 50, dict(slots))
check("dynamic child one at the start", slots["b1"] == 0, dict(slots))
check("the dynamic group skips what is not showing: three takes slot two",
      slots["b3"] == 50, dict(slots))
check("and what is not showing is hidden outright",
      L.eval("ns.Display.__regions.b2:IsShown()") is False)

L.execute('AURAS.player = { { name = "one", spellId = 1 },'
          '{ name = "two", spellId = 2 }, { name = "three", spellId = 3 } };'
          'ns.Engine:UpdateAll()')
slots = L.eval('''
(function()
    local out = {}
    for _, id in ipairs({ "b1", "b2", "b3" }) do
        local frame = ns.Display.__regions[id]
        local point = frame and rawget(frame, "_point")
        out[id] = point and point.x or false
    end
    return out
end)()
''')
check("when the middle one comes back the row opens up again",
      slots["b2"] == 50 and slots["b3"] == 100, dict(slots))

# --- 6b. growing out of the middle ----------------------------------------
# The point of centred growth: the row opens out and closes back in around its
# own anchor instead of shoving everything off one end.
print("-- centred growth")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "h1", type = "dynamic", name = "Across", growth = "HCENTER", spacing = 10 },
    { id = "c1", parent = "h1", trigger = { match = "name", text = "one" } },
    { id = "c2", parent = "h1", trigger = { match = "name", text = "two" } },
    { id = "c3", parent = "h1", trigger = { match = "name", text = "three" } },
    { id = "v1", type = "dynamic", name = "Down", growth = "VCENTER", spacing = 10 },
    { id = "d1", parent = "v1", trigger = { match = "name", text = "one" } },
    { id = "d2", parent = "v1", trigger = { match = "name", text = "two" } },
} } } }
AURAS.player = { { name = "one", spellId = 1 }, { name = "two", spellId = 2 },
                 { name = "three", spellId = 3 } }
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")


def offsets(ids, axis="x"):
    out = {}
    for one in ids:
        point = L.eval("rawget(ns.Display.__regions.%s, '_point')" % one)
        out[one] = (point[axis], point["point"]) if point else None
    return out

across = offsets(["c1", "c2", "c3"])
check("three across sit at -step, 0, +step around the centre",
      [across[i][0] for i in ("c1", "c2", "c3")] == [-50, 0, 50], across)
check("and they are anchored to the group's centre, not a corner",
      all(across[i][1] == "CENTER" for i in ("c1", "c2", "c3")), across)

down = offsets(["d1", "d2"], axis="y")
check("two down straddle the centre at +step/2 and -step/2",
      [down[i][0] for i in ("d1", "d2")] == [25, -25], down)

# One drops out: what is left must re-centre rather than leave a hole at one end.
L.execute("""
AURAS.player = { { name = "one", spellId = 1 }, { name = "three", spellId = 3 } }
ns.Engine:UpdateAll()
""")
across = offsets(["c1", "c3"])
check("losing the middle one re-centres the two that are left",
      [across[i][0] for i in ("c1", "c3")] == [-25, 25], across)

L.execute("""
AURAS.player = { { name = "two", spellId = 2 } }
ns.Engine:UpdateAll()
""")
check("and the last one alone sits exactly on the centre",
      offsets(["c2"])["c2"][0] == 0, offsets(["c2"]))

# The group's anchor is the thing that must not move through all of that.
check("a centred group is pinned by its centre",
      ev("ns.Display:PivotFor(ns.FindAura('h1'))") == "CENTER")
check("while a right-growing one is pinned by its left edge",
      ev("""
        (function()
            ns.FindAura('h1').growth = "RIGHT"
            return ns.Display:PivotFor(ns.FindAura('h1'))
        end)()
      """) == "TOPLEFT")

# --- 6c. groups are not things you look at --------------------------------
# A group is a place to put icons. It has no border, no name and no background,
# and the only things on screen are the auras themselves.
print("-- groups draw nothing")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs", pos = { x = 100, y = 50 } },
    { id = "a1", parent = "g1", trigger = { match = "name", text = "one" },
      display = { hide = true } },
    { id = "a2", parent = "g1", trigger = { match = "name", text = "two" } },
} } } }
AURAS.player = { { name = "two", spellId = 2 } }
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")

check("a group region has no label to show",
      ev("ns.Display.__regions.g1.label") is None)
check("and nothing ever asked it for a backdrop",
      ev("rawget(ns.Display.__regions.g1, '_backdrop')") is None)

# The mouse is the other half of being invisible: an outline you cannot see is
# still in the way if it takes clicks.
L.execute("ns.profile.locked = false; ns.Display:ApplyLock()")
check("unlocked, a group still refuses the mouse",
      ev("rawget(ns.Display.__regions.g1, '_mouse')") is False,
      ev("rawget(ns.Display.__regions.g1, '_mouse')"))
check("and its icons take it instead",
      ev("rawget(ns.Display.__regions.a2, '_mouse')") is True)

L.execute("ns.profile.locked = true; ns.Display:ApplyLock()")
check("locked, nothing takes the mouse at all",
      ev("rawget(ns.Display.__regions.a2, '_mouse')") is False)

# Dragging: the icon is the handle, the group is what moves.
L.execute("""
ns.profile.locked = false
ns.Display:ApplyLock()
local icon = ns.Display.__regions.a2
icon._scripts.OnDragStart(icon)
""")
check("grabbing an icon sets its group moving",
      ev("rawget(ns.Display.__regions.a2, 'movingID')") == "g1",
      ev("rawget(ns.Display.__regions.a2, 'movingID')"))

L.execute("""
local icon = ns.Display.__regions.a2
icon._scripts.OnDragStop(icon)
""")
check("and letting go writes the group's position, not the icon's",
      ev("ns.FindAura('g1').pos ~= nil") is True and ev("ns.FindAura('a1').pos") is None)
check("stored against the point that holds the group still",
      ev("ns.FindAura('g1').pos.pivot") == "TOPLEFT",
      ev("ns.FindAura('g1').pos.pivot"))

# The same drag on a centred group records its centre instead, which is the
# whole difference between the two.
L.execute("""
ns.FindAura('g1').growth = "HCENTER"
ns.Display:Layout()
local icon = ns.Display.__regions.a2
icon._scripts.OnDragStart(icon)
icon._scripts.OnDragStop(icon)
""")
check("a centred group records its centre",
      ev("ns.FindAura('g1').pos.pivot") == "CENTER",
      ev("ns.FindAura('g1').pos.pivot"))

# "Hide when inactive" would otherwise leave nothing to grab -- but only
# while arranging. Unlocked is the default, so unlocked alone left every
# hidden aura faintly up in play.
L.execute("ns.profile.locked = false; ns.Engine:UpdateAll()")
check("an inactive hidden icon is gone in play, even unlocked",
      ev("ns.Display.__regions.a1:GetAlpha()") == 0,
      ev("ns.Display.__regions.a1:GetAlpha()"))
L.execute("ns.Config:Open(); ns.Engine:UpdateAll()")
check("and faintly there to grab while the window is open",
      0 < ev("ns.Display.__regions.a1:GetAlpha()") < 0.5,
      ev("ns.Display.__regions.a1:GetAlpha()"))
L.execute("ns.profile.locked = true; ns.Engine:UpdateAll()")
check("and gone once locked", ev("ns.Display.__regions.a1:GetAlpha()") == 0)
L.execute("ns.Config:Toggle(); ns.profile.locked = false; ns.Engine:UpdateAll()")

# --- 6d. adding something with no spell behind it -------------------------
# The window could only ever create from a spell, so "Well Fed" was refused at
# the only door into it. Adding by the words on the aura is its own way in.
print("-- adding by the words on an aura")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
AURAS.player = { { name = "Well Fed", spellId = 999111, applications = 0, icon = 456 } }
""")
ev = L.eval

check("a name this client knows no spell for is refused as a spell",
      ev("ns.ResolveSpell('Well Fed')") is None)
check("but it can still be added by name",
      ev("ns.Config:AddNamed('Well Fed') ~= nil") is True)
check("stored as a name match, not a spell",
      ev("ns.Trigger(ns.GetAuras()[1]).match") == "name"
      and ev("ns.Trigger(ns.GetAuras()[1]).text") == "Well Fed")
check("and named after the text so the list reads properly",
      ev("(ns.Engine:Describe(ns.GetAuras()[1]))") == "Well Fed")

L.execute("ns.Engine:UpdateAll()")
check("it fires on the aura that is actually up",
      ev("ns.Engine.states.a1.shown") is True)
check("wearing the icon the aura itself carries, not a question mark",
      ev("ns.Engine.states.a1.icon") == 456, ev("ns.Engine.states.a1.icon"))

# Once seen, the meal's icon sticks rather than reverting when it drops.
L.execute("AURAS.player = {}; ns.Engine:UpdateAll()")
check("and keeps that icon after it falls off",
      ev("ns.Engine.states.a1.icon") == 456,
      ev("ns.Engine.states.a1.icon"))

check("an empty name is refused rather than making a dud aura",
      ev("ns.Config:AddNamed('   ')") is None and ev("#ns.GetAuras()") == 1)

# --- 6e. a group's look applies to everything in it -----------------------
print("-- group settings reach the children")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs" },
    { id = "n1", type = "group", name = "Nested", parent = "g1" },
    { id = "a1", parent = "g1", trigger = { spellID = 774 } },
    { id = "a2", parent = "g1", trigger = { spellID = 8936 } },
    { id = "a3", parent = "n1", trigger = { spellID = 5487 } },
    { id = "loose", trigger = { spellID = 1126 } },
} } } }
""")
ev = L.eval

check("a group knows everything under it, however deep",
      ev("#ns.Descendants('g1')") == 4, ev("#ns.Descendants('g1')"))

L.execute("ns.Config:Select('g1')")
L.execute("""
for _, field in ipairs(ns.Config.__displayFields) do
    if field.key == "size" then field.set(ns.FindAura('g1'), 30) end
end
""")
check("setting a size on the group sets it on its children",
      ev("ns.DisplayField(ns.FindAura('a1'), 'size')") == 30
      and ev("ns.DisplayField(ns.FindAura('a2'), 'size')") == 30)
check("and on children of children",
      ev("ns.DisplayField(ns.FindAura('a3'), 'size')") == 30)
check("the nested group keeps it too, for what it gets later",
      ev("ns.FindAura('n1').display.size") == 30)
check("the group remembers what it told them",
      ev("ns.DisplayField(ns.FindAura('g1'), 'size')") == 30)
check("and nothing outside it was touched",
      ev("ns.DisplayField(ns.FindAura('loose'), 'size')") == 40,
      ev("ns.DisplayField(ns.FindAura('loose'), 'size')"))

# Anything added afterwards should look like the rest rather than arrive at the
# default and stand out.
L.execute("ns.Config:Select('g1'); ns.Config:AddAura(1126)")
check("something added to the group later inherits the same look",
      ev("ns.DisplayField(ns.GetAuras()[#ns.GetAuras()], 'size')") == 30,
      ev("ns.DisplayField(ns.GetAuras()[#ns.GetAuras()], 'size')"))

L.execute("ns.Config:Select('g1'); ns.Config:AddNamed('Well Fed')")
check("including one added by name",
      ev("ns.DisplayField(ns.GetAuras()[#ns.GetAuras()], 'size')") == 30)

# Moving one in picks the look up; layout stays the group's own business.
L.execute("ns.Config:SetParentByName(ns.FindAura('loose'), 'Procs')")
check("moving something into a group takes on its look",
      ev("ns.DisplayField(ns.FindAura('loose'), 'size')") == 30)
check("layout is not inherited -- a nested group grows its own way",
      ev("""
        (function()
            ns.FindAura('g1').growth = "HCENTER"
            return ns.GroupField(ns.FindAura('n1'), 'growth')
        end)()
      """) == "RIGHT")

# --- 6f. a group answers "when does this load" too ------------------------
print("-- load settings reach the children")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs" },
    { id = "n1", type = "group", name = "Nested", parent = "g1" },
    { id = "a1", parent = "g1", trigger = { match = "name", text = "x" } },
    { id = "a2", parent = "n1", trigger = { match = "name", text = "x" } },
    { id = "loose", trigger = { match = "name", text = "x" } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('g1'); ns.Config:SetTab('load')")


def load_field(L, key):
    L.execute("__key = '%s'" % key)
    return L.eval("""
        (function()
            for _, field in ipairs(ns.Config.__loadFields or {}) do
                if field.key == __key then return field end
            end
        end)()
    """)


group = L.eval("(ns.FindAura('g1'))")
combat = load_field(L, "combat")
combat["cycle"](group)

check("a load condition set on a group lands on its children",
      ev("ns.FindAura('a1').load.combat") is True)
check("and on children of children",
      ev("ns.FindAura('a2').load.combat") is True)
check("the nested group keeps it for what it gets later",
      ev("ns.FindAura('n1').load.combat") is True)
check("nothing outside the group hears about it",
      ev("(ns.FindAura('loose').load or {}).combat") is None)

L.execute("ns.Engine:UpdateAll()")
check("so out of combat the whole group is unloaded",
      ev("ns.Engine.states.a1.loaded") is False
      and ev("ns.Engine.states.a2.loaded") is False)
check("while the loose one carries on", ev("ns.Engine.states.loose.loaded") is True)

# Cycling on round has to reach them as well, or "no" would strand the children
# on "yes".
combat["cycle"](group)
check("cycling to must-not reaches them too",
      ev("ns.FindAura('a1').load.combat") is False)
combat["cycle"](group)
check("and switching it off clears theirs",
      ev("(ns.FindAura('a1').load or {}).combat") is None)

# A table-valued condition has to arrive as a copy each, or editing one child
# would edit the lot.
klass = load_field(L, "class")
klass["set"](group, "DRUID", True)
check("a class list reaches the children",
      ev("ns.FindAura('a1').load.class.DRUID") is True
      and ev("ns.FindAura('a2').load.class.DRUID") is True)

child = L.eval("(ns.FindAura('a1'))")
klass["set"](child, "MAGE", True)
check("and each holds its own copy of it",
      ev("ns.FindAura('a1').load.class.MAGE") is True
      and ev("(ns.FindAura('a2').load.class or {}).MAGE") is None
      and ev("(ns.FindAura('g1').load.class or {}).MAGE") is None,
      (ev("(ns.FindAura('a2').load.class or {}).MAGE"),
       ev("(ns.FindAura('g1').load.class or {}).MAGE")))

level = load_field(L, "level")
level["set"](group, "min", "40")
check("a level range reaches them", ev("ns.FindAura('a2').load.level.min") == 40)
level["set"](child, "max", "60")
check("and is a copy there too",
      ev("ns.FindAura('a1').load.level.max") == 60
      and ev("(ns.FindAura('a2').load.level or {}).max") is None)

# New and moved children pick it up.
L.execute("ns.Config:Select('g1'); ns.Config:AddNamed('Well Fed')")
check("something added later inherits the group's load settings",
      ev("ns.GetAuras()[#ns.GetAuras()].load.class.DRUID") is True)
L.execute("ns.Config:SetParentByName(ns.FindAura('loose'), 'Procs')")
check("and so does one moved into it",
      ev("ns.FindAura('loose').load.class.DRUID") is True)

# --- 6g. the icon list ----------------------------------------------------
# Three possible sources and no guarantee of any, so what matters is that it
# falls through to one that works and says which it used.
print("-- the icon list")

L = boot("""
GetNumMacroIcons, GetMacroIconInfo = nil, nil
IconDataProviderMixin, CreateAndInitFromMixin = nil, nil
SPELLS[1127] = { name = "Regrowth Twin", icon = 101 }
IMMEDIATE_TIMERS = true
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
ev = L.eval
L.execute("ns.Icons:StartScan()")

check("with no icon API at all it falls back to spell icons",
      ev("(ns.Icons:Source())") == "spell icons", ev("(ns.Icons:Source())"))
check("and the spell index found every spell this client has",
      ev("#ns.Icons:SpellIndex()") == 5, ev("#ns.Icons:SpellIndex()"))
check("including ones well past where the first slice stops",
      ev("(function() for _, e in ipairs(ns.Icons:SpellIndex()) do if e.id == 8936 then return true end end return false end)()") is True)
check("and it knows it has finished",
      ev("(select(3, ns.Icons:ScanProgress()))") is False)

found = ev("(function() local list = ns.Icons:Search('regrowth') return #list end)()")
check("searching by name finds it", found >= 1, found)
check("and two spells wearing one icon are offered once",
      ev("(function() local list = ns.Icons:Search('regrowth') return #list end)()") == 1,
      ev("(function() local list = ns.Icons:Search('regrowth') return #list end)()"))
check("an exact name comes before one that merely contains it",
      ev("""
        (function()
            local list = ns.Icons:Search('rejuvenation')
            return list[1] and list[1].name
        end)()
      """) == "Rejuvenation")
check("searching nothing offers nothing rather than everything",
      ev("(function() return #ns.Icons:Search('') end)()") == 0)

# The macro list, where a client has it, is the real full set and wins.
L2 = boot("""
MACRO_ICONS = { 900, 901, 902, 903 }
function GetNumMacroIcons() return #MACRO_ICONS end
function GetMacroIconInfo(index) return MACRO_ICONS[index] end
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
check("the macro list is preferred when the client has one",
      L2.eval("(ns.Icons:Source())") == "macro icons", L2.eval("(ns.Icons:Source())"))
check("and carries every icon in it",
      L2.eval("(select(2, ns.Icons:Source()))") == 4,
      L2.eval("(select(2, ns.Icons:Source()))"))

# The lists the modern client's icon provider is built from, asked for
# directly. The provider must never be created: its shared state, written
# from addon code, taints the nameplate preview in Options > Advanced.
L3 = boot("""
GetNumMacroIcons, GetMacroIconInfo = nil, nil
PROVIDER_MADE = false
IconDataProviderMixin = {}
function CreateAndInitFromMixin() PROVIDER_MADE = true error("must not be called") end
function GetLooseMacroIcons(t) t[#t + 1] = 136243 end
function GetMacroIcons(t) t[#t + 1] = "Spell_Nature_Regeneration" t[#t + 1] = "135000" end
function GetMacroItemIcons(t) t[#t + 1] = 133784 end
IMMEDIATE_TIMERS = true
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
L3.execute("ns.Icons:StartScan() ns.Icons:Browse()")
check("without the old macro API, the macro icon lists are read directly",
      L3.eval("(ns.Icons:Source())") == "macro icon lists", L3.eval("(ns.Icons:Source())"))
check("spells first, then items, file IDs as numbers, file names under the Icons folder",
      L3.eval("table.concat((ns.Icons:Browse()), ',')")
      == r"136243,Interface\Icons\Spell_Nature_Regeneration,135000,133784",
      L3.eval("table.concat((ns.Icons:Browse()), ',')"))
check("and Blizzard's icon provider is never created", L3.eval("PROVIDER_MADE") is False)

# One of those functions throwing takes nothing else down.
L4 = boot("""
GetNumMacroIcons, GetMacroIconInfo = nil, nil
function GetLooseMacroIcons(t) error("broken") end
function GetMacroIcons(t) t[#t + 1] = 136243 end
IMMEDIATE_TIMERS = true
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
L4.execute("ns.Icons:StartScan()")
check("a list that throws is skipped, not fatal",
      L4.eval("(ns.Icons:Source())") == "macro icon lists"
      and L4.eval("(select(2, ns.Icons:Source()))") == 1, L4.eval("(ns.Icons:Source())"))

# --- 6h. a chosen icon outranks everything --------------------------------
print("-- a chosen icon wins")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { spellID = 774 } },
    { id = "a2", trigger = { match = "name", text = "Well Fed" } },
} } } }
AURAS.player = { { name = "Well Fed", spellId = 999111, icon = 456 } }
""")
ev = L.eval
check("a spell aura starts on its spell's icon",
      ev("(select(2, ns.Engine:Describe(ns.FindAura('a1'))))") == 100)

L.execute("ns.SubTable(ns.FindAura('a1'), 'display').icon = 777")
check("a chosen icon replaces it",
      ev("(select(2, ns.Engine:Describe(ns.FindAura('a1'))))") == 777)

L.execute("ns.SubTable(ns.FindAura('a2'), 'display').icon = 888; ns.Engine:UpdateAll()")
check("and it is not overwritten by the one the aura is wearing",
      ev("ns.Engine.states.a2.icon") == 888, ev("ns.Engine.states.a2.icon"))

L.execute("ns.FindAura('a2').display.icon = nil; ns.Engine:UpdateAll()")
check("cleared, the aura's own icon comes back",
      ev("ns.Engine.states.a2.icon") == 456, ev("ns.Engine.states.a2.icon"))

# The window itself, since a picker that will not build is a picker nobody has.
L.execute("PRINTED = {}; ns.Icons:Open(function() end)")
printed = chr(10).join(L.eval("PRINTED").values())
check("the picker builds", "failed to build" not in printed, printed)
check("and is on screen", L.eval("ChairAurasIconPicker:IsShown()") is True)

# --- 6i. picking one out of the list --------------------------------------
# The path that failed in the game: the Choose button opens the picker and the
# callback it hands over writes the icon. That callback names SetDisplay, which
# was declared further down the file than the widget that calls it -- so inside
# the closure it was a nil global, and clicking an icon threw instead of
# choosing one. Nothing below is about the widget looking right; it is about
# the click actually landing.
print("-- picking an icon")
L = boot("""
MACRO_ICONS = {}
for i = 1, 500 do MACRO_ICONS[i] = 134000 + i end
function GetNumMacroIcons() return #MACRO_ICONS end
function GetMacroIconInfo(index) return MACRO_ICONS[index] end
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", name = "Well Fed", trigger = { match = "name", text = "Well Fed" } },
} } } }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('a1'); ns.Config:SetTab('display')")

# Finding the icon control the way a click finds it: through the panes the
# window actually built, not through the table of field descriptions.
FIND_ICON_WIDGET = (
    "(function() for _, entry in pairs(ns.Config.__panes or {}) do "
    "for _, widget in ipairs(entry.pane.widgets or {}) do "
    "if widget.field and widget.field.kind == 'icon' then return widget end "
    "end end end)()")

CLICK_CHOOSE = (
    "(function() local w = " + FIND_ICON_WIDGET + " local ok, err = pcall(function() "
    "w.choose._scripts.OnClick(w.choose) end) return ok, tostring(err) end)()")

CLICK_FIRST_ICON = (
    "(function() local b = ChairAurasIconPicker.buttons[1] "
    "b._scripts.OnClick(b) return b.value end)()")

CLICK_CLEAR = (
    "(function() local w = " + FIND_ICON_WIDGET + " "
    "w.clear._scripts.OnClick(w.clear) end)()")

WHEEL = ("(function() ChairAurasIconPicker._scripts.OnMouseWheel("
         "ChairAurasIconPicker, %s) return ChairAurasIconPicker.buttons[1].value end)()")


widget = ev(FIND_ICON_WIDGET)
check("the display tab has an icon control", widget is not None)

ok, err = ev(CLICK_CHOOSE)
check("clicking Choose opens the picker without erroring", ok is True, err)
check("and the picker is up", ev("ChairAurasIconPicker:IsShown()") is True)

picked = ev(CLICK_FIRST_ICON)
check("clicking an icon stores it on the aura",
      ev("ns.FindAura('a1').display.icon") == picked,
      (picked, ev("(ns.FindAura('a1').display or {}).icon")))
check("the picker closes behind it",
      ev("ChairAurasIconPicker:IsShown()") is False)
check("and the aura wears it",
      ev("(select(2, ns.Engine:Describe(ns.FindAura('a1'))))") == picked)

L.execute("ns.Config:SetTab('display')")
L.execute(CLICK_CLEAR)
check("Clear puts it back to having none",
      ev("(ns.FindAura('a1').display or {}).icon") is None)

# --- 6j. the grid scrolls --------------------------------------------------
print("-- the icon grid scrolls")
L.execute("ns.Icons:Open(function() end)")
first = ev("ChairAurasIconPicker.buttons[1].value")
check("it starts at the top", first == 134001, first)

after = ev(WHEEL % "-1")
check("a wheel down moves three rows on",
      after == 134001 + 30, (first, after))

back = ev(WHEEL % "1")
check("and a wheel up comes back", back == 134001, back)

top = ev(WHEEL % "1")
check("it will not scroll off the top", top == 134001, top)

L.execute("for i = 1, 200 do ChairAurasIconPicker._scripts.OnMouseWheel(ChairAurasIconPicker, -1) end")
bottom = ev("ChairAurasIconPicker.buttons[1].value")
check("nor past the last row",
      bottom == 134000 + (math.ceil(500 / 10) - 8) * 10 + 1, bottom)
check("the last row is full of icons, not blanks",
      ev("ChairAurasIconPicker.buttons[1]:IsShown()") is True)

check("the scrollbar follows the grid",
      ev("(ChairAurasIconPicker.scrollbar:GetValue())") == math.ceil(500 / 10) - 8,
      ev("(ChairAurasIconPicker.scrollbar:GetValue())"))

# --- 6k. a group's icon is its own ----------------------------------------
# Everything else a group is told is handed down. Its icon is not: that is how
# the group is known in the list, and children keep looking like what they
# watch.
print("-- a group's icon stays with the group")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs" },
    { id = "a1", parent = "g1", trigger = { spellID = 774 } },
    { id = "a2", parent = "g1", trigger = { match = "name", text = "Well Fed" } },
} } } }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('g1'); ns.Config:SetTab('display')")

GROUP_ICON_WIDGET = (
    "(function() for _, entry in pairs(ns.Config.__panes or {}) do "
    "for _, widget in ipairs(entry.pane.widgets or {}) do "
    "if widget.field and widget.field.kind == 'icon' then return widget end "
    "end end end)()")

# Setting it the way the window does: open the picker off the group's Choose
# button and click an icon.
L.execute("MACRO_ICONS = { 500001, 500002 }")
L.execute("function GetNumMacroIcons() return #MACRO_ICONS end")
L.execute("function GetMacroIconInfo(i) return MACRO_ICONS[i] end")
L.execute("(function() local w = " + GROUP_ICON_WIDGET + " w.choose._scripts.OnClick(w.choose) end)()")
picked = ev("(function() local b = ChairAurasIconPicker.buttons[1] b._scripts.OnClick(b) return b.value end)()")

check("the group takes the icon", ev("ns.FindAura('g1').display.icon") == picked, picked)
check("and does not push it onto its children",
      ev("(ns.FindAura('a1').display or {}).icon") is None
      and ev("(ns.FindAura('a2').display or {}).icon") is None,
      (ev("(ns.FindAura('a1').display or {}).icon"),
       ev("(ns.FindAura('a2').display or {}).icon")))
check("so a child still wears its own spell's icon",
      ev("(select(2, ns.Engine:Describe(ns.FindAura('a1'))))") == 100,
      ev("(select(2, ns.Engine:Describe(ns.FindAura('a1'))))"))
check("while the group wears the one it was given",
      ev("(select(2, ns.Engine:Describe(ns.FindAura('g1'))))") == picked)

# Borrowing one from a spell is the same kind of setting, so it stays put too.
L.execute("ns.SubTable(ns.FindAura('g1'), 'display').iconSpell = nil")
L.execute("(function() for _, f in ipairs(ns.Config.__displayFields) do if f.key == 'iconSpell' then f.set(ns.FindAura('g1'), 'Regrowth') end end end)()")
check("a borrowed icon is the group's alone",
      ev("ns.FindAura('g1').display.iconSpell") == 8936
      and ev("(ns.FindAura('a1').display or {}).iconSpell") is None)

# Anything else it is told still reaches them, so this is one exception rather
# than inheritance quietly coming undone.
L.execute("(function() for _, f in ipairs(ns.Config.__displayFields) do if f.key == 'size' then f.set(ns.FindAura('g1'), 28) end end end)()")
check("the rest of the group's look still cascades",
      ev("ns.DisplayField(ns.FindAura('a1'), 'size')") == 28)

# And something added afterwards takes the look but not the face.
L.execute("ns.Config:Select('g1'); ns.Config:AddNamed('Drink')")
check("a new child inherits the size",
      ev("ns.DisplayField(ns.GetAuras()[#ns.GetAuras()], 'size')") == 28)
check("but not the icon",
      ev("(ns.GetAuras()[#ns.GetAuras()].display or {}).icon") is None
      and ev("(ns.GetAuras()[#ns.GetAuras()].display or {}).iconSpell") is None)

# --- 6l. export and import -------------------------------------------------
# A string that leaves one game and arrives in another has to survive being
# serialised, encoded, pasted, and read back by an addon that shares nothing
# with the sender except this file.
print("-- export and import")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs", growth = "HCENTER",
      pos = { x = 10, y = -20 } },
    { id = "a1", parent = "g1", name = "Rejuv", trigger = { spellID = 774, mine = true },
      display = { size = 30 }, load = { combat = true, class = { DRUID = true } } },
    { id = "a2", parent = "g1", trigger = { match = "name", text = "Well Fed",
      partial = true }, display = { icon = 456 } },
    { id = "loose", trigger = { spellID = 8936 } },
} } } }
""")
ev = L.eval

# Serialising on its own, since everything else rests on it.
round_trip = ev("""
    (function()
        local before = { a = 1, b = "two", c = true, d = false,
                         e = { f = "g", [3] = "h" }, i = -2.5 }
        local after = ns.Share.Deserialise(ns.Share.Serialise(before))
        return after.a == 1 and after.b == "two" and after.c == true
           and after.d == false and after.e.f == "g" and after.e[3] == "h"
           and after.i == -2.5
    end)()
""")
check("a table survives being written out and read back", round_trip is True)

check("so do the characters the format itself uses",
      ev("""
        (function()
            local before = { name = "a,b{c}d=e|f~g" }
            local after = ns.Share.Deserialise(ns.Share.Serialise(before))
            return after.name == before.name
        end)()
      """) is True)

text = ev("(ns.Share:Export((ns.FindAura('g1'))))")
check("a group exports to a string, made the way WeakAuras makes its own",
      isinstance(text, str) and text.startswith("!CA:3!"), text and text[:40])
# Strings from before 1.2 still read: the same group in the old CA1: form.
old = ev("(function() local b = { v = 1, auras = { ns.FindAura('g1') } } return 'CA1:' .. ns.Share.__Encode(ns.Share.Serialise(b)) end)()")
check("and a CA1: string from before still imports",
      ev("(function() local b = ns.Share:Peek(%s) return b and b.auras[1].id end)()" % ("'" + old + "'")) == "g1")

bundle = ev("(ns.Share:Peek(%s))" % ("'" + text + "'"))
check("which says what is in it before anything is added",
      bundle is not None and bundle["auras"] is not None)
check("the group brought its children", ev("#(ns.Share:Peek('%s')).auras" % text) == 3,
      ev("#(ns.Share:Peek('%s')).auras" % text))
check("and it knows who sent it",
      ev("(ns.Share:Peek('%s')).who" % text) == "Tester")

# Importing into a profile that already has these ids is where a naive
# implementation quietly overwrites something.
before = ev("#ns.GetAuras()")
added = ev("ns.Share:Import('%s')" % text)
check("importing adds them rather than replacing anything",
      ev("#ns.GetAuras()") == before + 3, ev("#ns.GetAuras()"))
check("with new ids, so nothing collided",
      ev("ns.FindAura('g1').name") == "Procs"
      and ev("(function() local n = 0 for _, a in ipairs(ns.GetAuras()) do "
             "if a.name == 'Procs' then n = n + 1 end end return n end)()") == 2)

imported_group = ev("""
    (function()
        for index = #ns.GetAuras(), 1, -1 do
            local aura = ns.GetAuras()[index]
            if aura.name == "Procs" and aura.id ~= "g1" then return aura end
        end
    end)()
""")
check("the copy is still a dynamic group that grows from the centre",
      imported_group["type"] == "dynamic" and imported_group["growth"] == "HCENTER")

check("its children point at the copy, not at the original",
      ev("""
        (function()
            local copy
            for index = #ns.GetAuras(), 1, -1 do
                local aura = ns.GetAuras()[index]
                if aura.name == "Procs" and aura.id ~= "g1" then copy = aura break end
            end
            local n = 0
            for _, aura in ipairs(ns.GetAuras()) do
                if aura.parent == copy.id then n = n + 1 end
            end
            return n
        end)()
      """) == 2)

check("triggers came across whole",
      ev("""
        (function()
            for _, aura in ipairs(ns.GetAuras()) do
                if aura.id ~= "a2" and ns.Trigger(aura).text == "Well Fed" then
                    return ns.Trigger(aura).partial == true and (aura.display or {}).icon == 456
                end
            end
            return false
        end)()
      """) is True)
check("so did load conditions",
      ev("""
        (function()
            for _, aura in ipairs(ns.GetAuras()) do
                if aura.id ~= "a1" and aura.name == "Rejuv" then
                    return (aura.load or {}).combat == true
                       and ((aura.load or {}).class or {}).DRUID == true
                end
            end
            return false
        end)()
      """) is True)

# Rubbish in has to come back as a sentence, not an error.
for junk, why in (("", "nothing pasted"), ("hello", "not a ChairAuras string"),
                  ("CA1:!!!!", "damaged")):
    ok = ev("(function() local b, e = ns.Share:Peek('%s') return b == nil end)()" % junk)
    check("junk is refused: " + (junk or "an empty box"), ok is True)

check("and refusing says why in words",
      isinstance(ev("(function() local _, e = ns.Share:Peek('hello') return e end)()"), str))

# A child shared on its own must not arrive pointing at a group that is not here.
alone = ev("(ns.Share:Export((ns.FindAura('a1'))))")
L.execute("ns.Share:Import('%s')" % alone)
check("an aura shared out of its group comes in loose",
      ev("""
        (function()
            local last = ns.GetAuras()[#ns.GetAuras()]
            return last.name == "Rejuv" and last.parent == nil
        end)()
      """) is True)

# --- 6m. sound on the edge -------------------------------------------------
print("-- sound actions")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" },
      actions = { onShow = "1234", onHide = "Interface\\\\Sound\\\\gone.ogg" } },
} } } }
AURAS.player = {}
""")
ev = L.eval

L.execute("SOUNDS = {}; ns.Engine:UpdateAll()")
check("nothing plays while it is simply off", ev("#SOUNDS") == 0)

L.execute('AURAS.player = { { name = "x", spellId = 1 } }; ns.Engine:UpdateAll()')
check("it plays when the aura comes up", ev("#SOUNDS") == 1, ev("#SOUNDS"))
check("a number goes through PlaySound",
      ev("SOUNDS[1].kind") == "id" and ev("SOUNDS[1].value") == 1234,
      (ev("SOUNDS[1].kind"), ev("SOUNDS[1].value")))
check("on the master channel by default", ev("SOUNDS[1].channel") == "Master")

L.execute("ns.Engine:UpdateAll(); ns.Engine:UpdateAll()")
check("and not again on every sweep while it stays up", ev("#SOUNDS") == 1,
      ev("#SOUNDS"))

L.execute("AURAS.player = {}; ns.Engine:UpdateAll()")
check("the going-away sound plays when it drops", ev("#SOUNDS") == 2)
check("and a path goes through PlaySoundFile",
      ev("SOUNDS[2].kind") == "file", ev("SOUNDS[2].kind"))

# Loading and unloading are not edges, in either direction. An aura that only
# loads out of combat loads again at the end of every fight, and counting that
# as coming up plays the sound every time a fight ends for a buff that was
# missing right through it. Unloading is the same thing the other way round: it
# would announce the aura leaving every time one starts.
L.execute("""
SOUNDS = {}
AURAS.player = { { name = "x", spellId = 1 } }
ns.Engine:UpdateAll()
ns.FindAura('a1').load = { never = true }
ns.Engine:UpdateAll()
""")
check("coming up is heard, and unloading after it is not",
      ev("#SOUNDS") == 1, ev("#SOUNDS"))

L.execute("ns.FindAura('a1').load = nil; ns.Engine:UpdateAll()")
check("and loading again announces nothing, because nothing changed",
      ev("#SOUNDS") == 1, ev("#SOUNDS"))

# What changed while it was away is not news either: the state is adopted on
# the way back in, so the next thing heard is the next thing that happens.
L.execute("""
ns.FindAura('a1').load = { never = true }
ns.Engine:UpdateAll()
AURAS.player = {}
ns.FindAura('a1').load = nil
ns.Engine:UpdateAll()
""")
check("a trigger that changed while it was unloaded is adopted quietly",
      ev("#SOUNDS") == 1, ev("#SOUNDS"))

L.execute('AURAS.player = { { name = "x", spellId = 1 } }; ns.Engine:UpdateAll()')
check("and the next real change is heard", ev("#SOUNDS") == 2, ev("#SOUNDS"))

# The whole reason the rule changed, in the shape it actually arrived in: a
# buff watcher that loads only out of combat, inverted so it shows while the
# buff is missing. Every fight unloads it and every fight ending loads it back,
# and it used to announce itself each time.
LCOMBAT = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", name = "Well Fed", trigger = { match = "name", text = "Well Fed" },
      display = { invert = true, hide = true },
      load = { combat = false },
      actions = { onShow = "12867" } },
} } } }
AURAS.player = {}
IN_COMBAT = false
""")

LCOMBAT.execute("SOUNDS = {}; ns.Engine:UpdateAll()")
check("the buff is missing out of combat, and the first sweep is quiet",
      LCOMBAT.eval("#SOUNDS") == 0
      and LCOMBAT.eval("ns.Engine.states.a1.shown") is True,
      (LCOMBAT.eval("#SOUNDS"), LCOMBAT.eval("ns.Engine.states.a1.shown")))

for fight in range(3):
    LCOMBAT.execute("IN_COMBAT = true; ns.Engine:UpdateAll()")
    LCOMBAT.execute("IN_COMBAT = false; ns.Engine:UpdateAll()")
check("and three fights later it still has not made a sound",
      LCOMBAT.eval("#SOUNDS") == 0, LCOMBAT.eval("#SOUNDS"))

# It still has to work as a reminder, though: the buff running out while the
# player is standing there is the thing it exists to say.
LCOMBAT.execute("""
AURAS.player = { { name = "Well Fed", spellId = 1 } }
ns.Engine:UpdateAll()
AURAS.player = {}
ns.Engine:UpdateAll()
""")
check("the buff running out while it is loaded is still heard",
      LCOMBAT.eval("#SOUNDS") == 1, LCOMBAT.eval("#SOUNDS"))

# A client with no sound API at all must cost the sound and nothing else.
L2 = boot("""
PlaySound, PlaySoundFile = nil, nil
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" }, actions = { onShow = "1234" } },
} } } }
AURAS.player = { { name = "x", spellId = 1 } }
""")
ok = L2.eval("(function() return pcall(function() ns.Engine:UpdateAll() end) end)()")
check("no sound API is silence, not an error", ok is True)
check("and the aura still shows", L2.eval("ns.Engine.states.a1.shown") is True)

# Set on a group, heard from everything in it.
L3 = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs" },
    { id = "a1", parent = "g1", trigger = { match = "name", text = "x" } },
    { id = "a2", parent = "g1", trigger = { match = "name", text = "y" } },
} } } }
AURAS.player = {}
""")
L3.execute("(function() for _, f in ipairs(ns.Config.__actionFields) do "
           "if f.key == 'onShow' then f.set(ns.FindAura('g1'), '99') end end end)()")
check("a group's sound reaches its children",
      L3.eval("ns.ActionField(ns.FindAura('a1'), 'onShow')") == "99"
      and L3.eval("ns.ActionField(ns.FindAura('a2'), 'onShow')") == "99")

# The first sweep is the one the auras come into existence on, and that is not
# a change; the buffs land on the sweep after it.
L3.execute("""
SOUNDS = {}
ns.Engine:UpdateAll()
AURAS.player = { { name = "x", spellId = 1 }, { name = "y", spellId = 2 } }
ns.Engine:UpdateAll()
""")
check("so both of them are heard", L3.eval("#SOUNDS") == 2, L3.eval("#SOUNDS"))

# --- 6n. a read that was refused is not an aura that is missing -----------
# The bug this was written for: two watchers set to show when a buff falls off
# came on the instant combat started and went off again when it ended. Nothing
# about the buffs changed -- the client stopped answering, the addon read that
# as "the buff is gone", and gone was exactly what they were watching for.
print("-- refused reads in combat")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "missing", trigger = { spellID = 774 }, display = { invert = true } },
    { id = "present", trigger = { spellID = 774 } },
} } } }
AURAS.player = { { name = "Rejuvenation", spellId = 774, icon = 100 } }
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("out of combat the buff is there, so the missing-watcher is quiet",
      ev("ns.Engine.states.missing.shown") is False)
check("and the plain one is on", ev("ns.Engine.states.present.shown") is True)

L.execute("AURAS_REFUSED = true; ns.Engine:UpdateAll()")
check("a refused read does not light up the missing-watcher",
      ev("ns.Engine.states.missing.shown") is False,
      ev("ns.Engine.states.missing.shown"))
check("nor turn off the plain one",
      ev("ns.Engine.states.present.shown") is True)
check("it says it could not read instead",
      ev("ns.Engine.states.present.unknown") is True)

L.execute("SOUNDS = {}; ns.Engine:UpdateAll(); ns.Engine:UpdateAll()")
check("and nothing fires on an edge nobody can see", ev("#SOUNDS") == 0)

L.execute("AURAS_REFUSED = false; ns.Engine:UpdateAll()")
check("when the reads come back, so does the truth",
      ev("ns.Engine.states.missing.shown") is False
      and ev("ns.Engine.states.present.shown") is True
      and ev("ns.Engine.states.present.unknown") is False)

# The buff really going away while reads work still has to register.
L.execute("AURAS.player = {}; ns.Engine:UpdateAll()")
check("a buff that really drops still turns the missing-watcher on",
      ev("ns.Engine.states.missing.shown") is True)

# The other shape of the same refusal: a table arrives, but its fields are
# secret. That is not a failure to match, it is a failure to read.
L2 = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "missing", trigger = { spellID = 774 }, display = { invert = true } },
} } } }
AURAS.player = { { name = "Rejuvenation", spellId = 774, icon = 100 } }
""")
L2.execute("ns.Engine:UpdateAll()")
check("with readable auras the watcher is quiet",
      L2.eval("ns.Engine.states.missing.shown") is False)

L2.execute("AURAS.player = { { name = SECRET_VALUE(), spellId = SECRET_VALUE() } }")
L2.execute("ns.Engine:UpdateAll()")
check("an aura whose fields cannot be read counts as unknown, not absent",
      L2.eval("ns.Engine.states.missing.shown") is False
      and L2.eval("ns.Engine.states.missing.unknown") is True,
      (L2.eval("ns.Engine.states.missing.shown"),
       L2.eval("ns.Engine.states.missing.unknown")))

# And a name-matched watcher has the same exposure.
L3 = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "fed", trigger = { match = "name", text = "Well Fed" },
      display = { invert = true } },
} } } }
AURAS.player = { { name = "Well Fed", spellId = 999111 } }
""")
L3.execute("ns.Engine:UpdateAll()")
check("a name watcher is quiet while the aura is there",
      L3.eval("ns.Engine.states.fed.shown") is False)
L3.execute("AURAS_REFUSED = true; ns.Engine:UpdateAll()")
check("and stays quiet when the client stops answering",
      L3.eval("ns.Engine.states.fed.shown") is False)

# --- 6o. choosing a sound off a list --------------------------------------
# Nobody knows what IG_MAINMENU_OPEN is until they hear it, so the list plays
# each one as you click it and only keeps the one you settled on.
print("-- the sound list")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" } },
} } } }
""")
ev = L.eval

check("the list is built from the client's own sound table",
      ev("#ns.Sounds:List()") == 4, ev("#ns.Sounds:List()"))
check("with names a person can read",
      ev("(function() for _, e in ipairs(ns.Sounds:List()) do "
         "if e.raw == 'IG_MAINMENU_OPEN' then return e.name end end end)()")
      == "Ig Mainmenu Open",
      ev("(function() for _, e in ipairs(ns.Sounds:List()) do "
         "if e.raw == 'IG_MAINMENU_OPEN' then return e.name end end end)()"))
check("and No sound at the top of what is offered",
      ev("ns.Sounds:Entries()[1].value") == "")

L.execute("SOUNDS = {}")
L.execute("ns.Sounds:Open('', 'Master', function(value) CHOSEN = value end)")
check("the window opens", ev("ChairAurasSoundPicker:IsShown()") is True)
check("opening it plays nothing on its own", ev("#SOUNDS") == 0)

# Clicking a row is both choosing and hearing.
L.execute("(function() local row = ChairAurasSoundPicker.rows[2] "
          "row._scripts.OnClick(row) end)()")
check("clicking a name plays it once", ev("#SOUNDS") == 1, ev("#SOUNDS"))
check("and hands it back to whoever opened the list",
      ev("CHOSEN") == ev("ChairAurasSoundPicker.rows[2].value"))
check("the window stays open so the next one can be tried against it",
      ev("ChairAurasSoundPicker:IsShown()") is True)

L.execute("(function() local row = ChairAurasSoundPicker.rows[3] "
          "row._scripts.OnClick(row) end)()")
check("trying another plays that one too", ev("#SOUNDS") == 2)

# A path the client's list does not carry is still allowed, and remembered.
L.execute("ChairAurasSoundPicker.box:SetText('Interface/Sound/mine.ogg')")
check("a typed path is kept in the list once used",
      ev("(function() ns.Sounds:Remember('Interface/Sound/mine.ogg') "
         "for _, e in ipairs(ns.Sounds:Entries()) do "
         "if e.value == 'Interface/Sound/mine.ogg' then return true end end "
         "return false end)()") is True)

check("a stored sound reads back under its own name",
      ev("ns.Sounds:Label('850')") == "Ig Mainmenu Open", ev("ns.Sounds:Label('850')"))
check("and nothing reads as none", ev("ns.Sounds:Label('')") == "none")

# The action and the picker have to make the same noise, or what you heard
# while choosing is not what plays.
L.execute("SOUNDS = {}")
L.execute("ns.SubTable(ns.FindAura('a1'), 'actions').onShow = '8959'")
L.execute("ns.Display:PlayAction(ns.FindAura('a1'), 'onShow')")
check("the action plays through the same door as the list",
      ev("#SOUNDS") == 1 and ev("SOUNDS[1].value") == 8959,
      (ev("#SOUNDS"), ev("SOUNDS[1] and SOUNDS[1].value")))

# --- 6o2. one sound at a time ---------------------------------------------
# Auditioning is listening, and two sounds over each other tell you nothing
# about either.
print("-- the list plays one at a time")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { match = "name", text = "x" },
      actions = { onShow = "850" } },
} } } }
""")
ev = L.eval

L.execute("SOUNDS = {}; STOPPED = {}")
L.execute("ns.Sounds:Open('', 'Master', function() end)")
L.execute("(function() local row = ChairAurasSoundPicker.rows[2] "
          "row._scripts.OnClick(row) end)()")
check("the first one plays", ev("#SOUNDS") == 1)
check("and nothing has been stopped yet", ev("#STOPPED") == 0)

first = ev("SOUNDS[1].handle")
L.execute("(function() local row = ChairAurasSoundPicker.rows[3] "
          "row._scripts.OnClick(row) end)()")
check("the second one plays", ev("#SOUNDS") == 2)
check("and the first is stopped as it starts",
      ev("#STOPPED") == 1 and ev("STOPPED[1]") == first,
      (ev("#STOPPED"), ev("STOPPED[1]"), first))

second = ev("SOUNDS[2].handle")
L.execute("ChairAurasSoundPicker:Hide()")
check("closing the window stops what was still playing",
      ev("#STOPPED") == 2 and ev("STOPPED[2]") == second,
      (ev("#STOPPED"), ev("STOPPED[2]"), second))

L.execute("ChairAurasSoundPicker:Hide()")
check("and closing it again stops nothing twice over", ev("#STOPPED") == 2)

# Escape and anything else that hides the frame count as closing it, which is
# why this hangs off OnHide rather than the Done button.
L.execute("SOUNDS = {}; STOPPED = {}")
L.execute("ns.Sounds:Open('', 'Master', function() end)")
L.execute("(function() local row = ChairAurasSoundPicker.rows[2] "
          "row._scripts.OnClick(row) end)()")
L.execute("ChairAurasSoundPicker:Hide()")
check("however the window goes away, the sound goes with it",
      ev("#STOPPED") == 1, ev("#STOPPED"))

# An aura firing its own sound is not an audition and must not be cut off by
# one, nor cut one off.
L.execute("SOUNDS = {}; STOPPED = {}")
L.execute("ns.Sounds:Preview('850', 'Master')")
L.execute("ns.Display:PlayAction((ns.FindAura('a1')), 'onShow')")
check("an aura's own sound stops nothing", ev("#STOPPED") == 0, ev("#STOPPED"))
check("and both were heard", ev("#SOUNDS") == 2)

L.execute("ns.Sounds:Preview('878', 'Master')")
check("while the next audition still stops the audition before it",
      ev("#STOPPED") == 1)

# A client with no way to stop a sound must not error over it.
L2 = boot("""
StopSound = nil
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
ok = L2.eval("(function() return pcall(function() "
             "ns.Sounds:Preview('850', 'Master') ns.Sounds:Preview('878', 'Master') "
             "ns.Sounds:StopPreview() end) end)()")
check("no StopSound is a shrug, not an error", ok is True)

# --- 6q. text and bars -----------------------------------------------------
# The same trigger drawn three ways. What matters is that the shape is a
# display setting -- so changing it keeps the trigger -- and that a group can
# measure children that are no longer all the same size.
print("-- text and bar displays")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "t1", type = "text", trigger = { spellID = 774 },
      display = { textFormat = "%n %t", fontSize = 12, textWidth = 100 } },
    { id = "b1", type = "bar", trigger = { spellID = 774 },
      display = { barWidth = 200, barHeight = 20 } },
    { id = "i1", trigger = { spellID = 774 }, display = { size = 40 } },
} } } }
AURAS.player = { { name = "Rejuvenation", spellId = 774, icon = 100,
                   applications = 3, duration = 12, expirationTime = 1009 } }
""")
ev = L.eval

check("an aura says which shape it is",
      ev("ns.RegionKind(ns.FindAura('t1'))") == "text"
      and ev("ns.RegionKind(ns.FindAura('b1'))") == "bar"
      and ev("ns.RegionKind(ns.FindAura('i1'))") == "icon")

# The formatter, which both shapes share.
L.execute("ns.Engine:UpdateAll()")
state = "ns.Engine.states.t1"
check("%n is the name",
      ev("ns.Engine:FormatText('%n', ns.FindAura('t1'), " + state + ")") == "Rejuvenation")
check("%s is the stacks",
      ev("ns.Engine:FormatText('%s', ns.FindAura('t1'), " + state + ")") == "3")
check("%t is what is left of it",
      ev("ns.Engine:FormatText('%t', ns.FindAura('t1'), " + state + ")") == "9.0",
      ev("ns.Engine:FormatText('%t', ns.FindAura('t1'), " + state + ")"))
check("%d is how long it runs for",
      ev("ns.Engine:FormatText('%d', ns.FindAura('t1'), " + state + ")") == "12")
check("%p is how much of it is left",
      ev("ns.Engine:FormatText('%p', ns.FindAura('t1'), " + state + ")") == "75",
      ev("ns.Engine:FormatText('%p', ns.FindAura('t1'), " + state + ")"))
check("%% is a per-cent sign",
      ev("ns.Engine:FormatText('%p%%', ns.FindAura('t1'), " + state + ")") == "75%")
check("a token nobody defined is left alone",
      ev("ns.Engine:FormatText('%q', ns.FindAura('t1'), " + state + ")") == "%q")
check("minutes read as minutes",
      ev("ns.FormatTime(95)") == "1:35", ev("ns.FormatTime(95)"))
check("and an aura with no timer says nothing about time",
      ev("ns.Engine:FormatText('%t', ns.FindAura('t1'), { name = 'x' })") == "")

# What each one draws.
check("the text region says what it was told to say",
      ev("ns.Display.__regions.t1.text:GetText()") == "Rejuvenation 9.0",
      ev("ns.Display.__regions.t1.text:GetText()"))
check("the bar is three quarters full",
      abs(ev("ns.Display.__regions.b1.bar:GetValue()") - 0.75) < 0.001,
      ev("ns.Display.__regions.b1.bar:GetValue()"))
check("and a bar with no duration reads full rather than empty",
      ev("""
        (function()
            AURAS.player = { { name = "Rejuvenation", spellId = 774, icon = 100 } }
            ns.Engine:UpdateAll()
            return ns.Display.__regions.b1.bar:GetValue()
        end)()
      """) == 1)

# Sizes, which is what a group has to work from.
sizes = ev("""
    (function()
        local out = {}
        for _, id in ipairs({ "t1", "b1", "i1" }) do
            local w, h = ns.Display.__extent(ns.FindAura(id))
            out[id] = w .. "x" .. h
        end
        return out
    end)()
""")
check("text is as wide as it was set and as tall as its font",
      sizes["t1"] == "100x20", dict(sizes))
check("a bar is the size it was given", sizes["b1"] == "200x20", dict(sizes))
check("an icon is square", sizes["i1"] == "40x40", dict(sizes))

# A group of mixed shapes has to place them by measurement, not by one step.
L2 = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "group", name = "Mixed", spacing = 10 },
    { id = "i1", parent = "g1", trigger = { spellID = 774 }, display = { size = 40 } },
    { id = "b1", parent = "g1", type = "bar", trigger = { spellID = 774 },
      display = { barWidth = 200, barHeight = 20 } },
    { id = "t1", parent = "g1", type = "text", trigger = { spellID = 774 },
      display = { textWidth = 100, fontSize = 12 } },
} } } }
AURAS.player = { { name = "Rejuvenation", spellId = 774, icon = 100 } }
""")
L2.execute("ns.Engine:UpdateAll()")

places = L2.eval("""
    (function()
        local out = {}
        for _, id in ipairs({ "i1", "b1", "t1" }) do
            local point = rawget(ns.Display.__regions[id], "_point")
            out[id] = point and point.x or false
        end
        return out
    end)()
""")
check("the icon starts the row", places["i1"] == 0, dict(places))
check("the bar begins where the icon ended, plus the gap",
      places["b1"] == 50, dict(places))
check("and the text after the bar, by the bar's own width",
      places["t1"] == 260, dict(places))

size = L2.eval("(function() local w, h = ns.Display:GroupExtent((ns.FindAura('g1'))) "
               "return w .. 'x' .. h end)()")
check("the group is as wide as its contents and as tall as the tallest",
      size == "360x40", size)

# Changing shape is a display setting: everything else about the aura stays.
L2.execute("""
(function()
    for _, field in ipairs(ns.Config.__displayFields) do
        if field.key == "type" then field.set(ns.FindAura('i1'), "bar") end
    end
end)()
""")
check("an icon can become a bar", L2.eval("ns.RegionKind(ns.FindAura('i1'))") == "bar")
check("and keeps its trigger", L2.eval("ns.Trigger((ns.FindAura('i1'))).spellID") == 774)
check("the region was rebuilt as the right shape",
      L2.eval("ns.Display.__regions.i1.kind") == "bar",
      L2.eval("ns.Display.__regions.i1.kind"))

# --- 6r. moving things about ----------------------------------------------
# Order inside a group is the order of the list, so reordering and re-homing
# are the same move. Both go through MoveAura, which the drag and the command
# share.
print("-- reordering and re-homing")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Procs" },
    { id = "a1", parent = "g1", name = "One", trigger = { spellID = 774 } },
    { id = "a2", parent = "g1", name = "Two", trigger = { spellID = 8936 } },
    { id = "a3", name = "Loose", trigger = { spellID = 5487 } },
    { id = "g2", type = "group", name = "Other" },
} } } }
""")
ev = L.eval


def order(L):
    return list(L.eval("(function() local out = {} "
                       "for i, a in ipairs(ns.GetAuras()) do out[i] = a.id end "
                       "return out end)()").values())


check("the list starts in the order it was written",
      order(L) == ["g1", "a1", "a2", "a3", "g2"], order(L))

# Beside: dropping one aura on another puts it where that one is.
L.execute("ns.MoveAura((ns.FindAura('a2')), (ns.FindAura('a1')), false)")
check("dropping Two onto One puts it before One",
      order(L) == ["g1", "a2", "a1", "a3", "g2"], order(L))
check("and it stays in the same group",
      ev("ns.FindAura('a2').parent") == "g1")

# Inside: dropping on a group re-homes it, at the end of that group.
L.execute("ns.MoveAura((ns.FindAura('a3')), (ns.FindAura('g1')), true)")
check("dropping a loose aura onto a group puts it in",
      ev("ns.FindAura('a3').parent") == "g1")
check("at the end of what is already there",
      order(L) == ["g1", "a2", "a1", "a3", "g2"], order(L))
check("so the group now holds three", ev("#ns.Children('g1')") == 3)

# Out again: dropping onto something at the top level takes it back out.
L.execute("ns.MoveAura((ns.FindAura('a3')), (ns.FindAura('g2')), false)")
check("dropping it beside a top-level group takes it out of the group",
      ev("ns.FindAura('a3').parent") is None,
      ev("ns.FindAura('a3').parent"))
check("and it sits where that one was",
      order(L) == ["g1", "a2", "a1", "a3", "g2"], order(L))

# A group into a group, and the thing that must never happen.
L.execute("ns.MoveAura((ns.FindAura('g2')), (ns.FindAura('g1')), true)")
check("a group can be dropped inside another",
      ev("ns.FindAura('g2').parent") == "g1")
check("but not into itself",
      ev("ns.MoveAura((ns.FindAura('g1')), (ns.FindAura('g2')), true)") is False)
check("and the attempt changed nothing",
      ev("ns.FindAura('g1').parent") is None
      and ev("ns.FindAura('g2').parent") == "g1")

# Children follow their group.
L.execute("ns.MoveAura((ns.FindAura('a1')), (ns.FindAura('g2')), true)")
check("something moved into the nested group is under it",
      ev("ns.FindAura('a1').parent") == "g2")
check("and is still a descendant of the outer one",
      ev("#ns.Descendants('g1')") == 3, ev("#ns.Descendants('g1')"))

# The typed form of the same move.
L2 = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "group", name = "Box" },
    { id = "a1", name = "One", trigger = { spellID = 774 } },
    { id = "a2", name = "Two", trigger = { spellID = 8936 } },
} } } }
""")
L2.execute("SlashCmdList.CHAIRAURAS('move 3 2')")
check("/ca move reorders by list position",
      order(L2) == ["g1", "a2", "a1"], order(L2))
L2.execute("SlashCmdList.CHAIRAURAS('move 3 1 in')")
check("/ca move ... in drops it inside the group",
      L2.eval("ns.FindAura('a1').parent") == "g1",
      L2.eval("ns.FindAura('a1').parent"))

# And the drag, through the row scripts the window builds.
L3 = boot("""
CURSOR_Y = 0
function GetCursorPosition() return 0, CURSOR_Y end
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "group", name = "Box" },
    { id = "a1", name = "One", trigger = { spellID = 774 } },
} } } }
""")
L3.execute("ns.Config:Open()")
check("a row can be dragged",
      L3.eval("(function() for _, r in ipairs(ns.Config.__rows) do "
              "if r.auraID == 'a1' and r._scripts.OnDragStart then return true end "
              "end return false end)()") is True)

# Dropping it over the middle of the group row: the mock rows report where they
# are, so the cursor can be put over one.
L3.execute("""
(function()
    local group, aura
    for _, r in ipairs(ns.Config.__rows) do
        if r.auraID == "g1" then group = r end
        if r.auraID == "a1" then aura = r end
    end
    rawset(group, "_top", 100) rawset(group, "_bottom", 76)
    CURSOR_Y = 88
    aura._scripts.OnDragStart(aura)
    aura._scripts.OnDragStop(aura)
end)()
""")
check("dropping a row over the middle of a group puts it inside",
      L3.eval("ns.FindAura('a1').parent") == "g1",
      L3.eval("ns.FindAura('a1').parent"))

# --- 6t. everything, there and back ---------------------------------------
# Not a sample of settings: every field the addon can store, set to something
# that is not its default, compared key by key after a full export and import.
# A setting that is quietly dropped in the middle of that is the kind of thing
# nobody notices until the aura they shared behaves differently.
print("-- the whole aura survives a round trip")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
ev = L.eval

L.execute("""
EVERYTHING = {
    id = "src", type = "bar", name = "Everything",
    pos = { x = 11, y = -22, pivot = "TOPRIGHT" },
    triggers = {
        { trigger = {
            type = "aura", unit = "focus", harmful = true, match = "name",
            text = "Well Fed", partial = true, mine = true,
            stacks = 3, stacksOp = "<=", spellID = 774,
        } },
        { trigger = { type = "cooldown", spellID = 8936 } },
        disjunctive = "custom",
        customTriggerLogic = "function(t) return t[1] and not t[2] end",
        activeTriggerMode = 2,
    },
    display = {
        size = 33, invert = true, hide = true, desaturate = false,
        swipe = false, stacks = false, flash = false, alpha = 80, dimAlpha = 15,
        icon = 12345, iconSpell = 8936,
        textFormat = "%n %t", fontSize = 18, textWidth = 111,
        barFormat = "%p%% left", barWidth = 222, barHeight = 19, barIcon = false,
        colour = "ff5555",
    },
    load = {
        never = false, combat = true, alive = false, group = true, raid = false,
        instance = true, resting = false, mounted = true, stealthed = false,
        hasTarget = true, hostileTarget = false,
        class = { DRUID = true, MAGE = true },
        level = { min = 12, max = 60 },
        form = { CAT_FORM = true },
        zone = "Elwynn",
        spellKnown = "Regrowth",
    },
    actions = { onShow = "850", onHide = "Interface/Sound/x.ogg", channel = "SFX" },
}

-- A group carries layout of its own, so one of those goes through too.
GROUPY = {
    id = "grp", type = "dynamic", name = "Groupy",
    growth = "VCENTER", spacing = 13, sort = "time", limit = 4, columns = 3,
    pos = { x = -5, y = 6, pivot = "CENTER" },
    display = { size = 27, colour = "cc66ff" },
    load = { combat = false },
}

-- Deep compare, reporting the first path that differs rather than just false.
function DIFF(a, b, path)
    path = path or ""
    if type(a) ~= type(b) then
        return path .. " (" .. type(a) .. " vs " .. type(b) .. ")"
    end
    if type(a) ~= "table" then
        if a ~= b then
            return path .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")"
        end
        return nil
    end
    for key, value in pairs(a) do
        local found = DIFF(value, b[key], path .. "." .. tostring(key))
        if found then return found end
    end
    for key in pairs(b) do
        if a[key] == nil then return path .. "." .. tostring(key) .. " (extra)" end
    end
    return nil
end
""")

# Round trip the lot: put them in, export, import, compare.
L.execute("""
local profile = ns.GetProfile()
profile.auras = { EVERYTHING, GROUPY }
GROUPY_CHILD = { id = "kid", parent = "grp", name = "Kid",
                 triggers = { { trigger = { spellID = 774 } } }, load = { alive = true },
                 display = { size = 21 } }
profile.auras[#profile.auras + 1] = GROUPY_CHILD
""")

L.execute("EXPORTED = ns.Share:Export((ns.FindAura('src')))")
check("the aura exports", isinstance(ev("EXPORTED"), str))

L.execute("IMPORTED = ns.Share:Import(EXPORTED)")
check("and imports", ev("IMPORTED ~= nil") is True)

# Everything except the two fields the importer is meant to change.
difference = ev("""
    (function()
        local copy = IMPORTED[1]
        local original = {}
        for key, value in pairs(EVERYTHING) do original[key] = value end
        original.id = copy.id
        original.untrusted = true
        return DIFF(original, copy, "aura")
    end)()
""")
check("every field of it came back identical", difference is None, difference)
check("and its custom code came in waiting for approval", ev("IMPORTED[1].untrusted") is True)

# The same for a group and its child, where parent links are rewritten.
L.execute("GROUP_EXPORT = ns.Share:Export((ns.FindAura('grp')))")
L.execute("GROUP_IN = ns.Share:Import(GROUP_EXPORT)")

difference = ev("""
    (function()
        local copy = GROUP_IN[1]
        local original = {}
        for key, value in pairs(GROUPY) do original[key] = value end
        original.id = copy.id
        return DIFF(original, copy, "group")
    end)()
""")
check("a group keeps its layout, position and load", difference is None, difference)

difference = ev("""
    (function()
        local copy = GROUP_IN[2]
        local original = {}
        for key, value in pairs(GROUPY_CHILD) do original[key] = value end
        original.id = copy.id
        original.parent = copy.parent
        -- The child's position is deliberately not carried: only the thing
        -- being shared has one, and a child has no position of its own.
        original.pos = copy.pos
        return DIFF(original, copy, "child")
    end)()
""")
check("and its child keeps everything too", difference is None, difference)

# The three-state load values specifically, since false is the one a careless
# serialiser turns into nothing.
for key, wanted in (("combat", True), ("alive", False), ("never", False)):
    got = ev("IMPORTED[1].load.%s" % key)
    check("load." + key + " came back as " + str(wanted).lower(), got is wanted, got)

check("a load condition set to a list came back whole",
      ev("IMPORTED[1].load.class.DRUID") is True
      and ev("IMPORTED[1].load.class.MAGE") is True)
check("and a range kept both ends",
      ev("IMPORTED[1].load.level.min") == 12 and ev("IMPORTED[1].load.level.max") == 60)
check("and the text ones came back as text",
      ev("IMPORTED[1].load.zone") == "Elwynn"
      and ev("IMPORTED[1].load.spellKnown") == "Regrowth")

# Awkward strings, which is where a hand-written format usually comes apart.
check("a string full of the format's own punctuation survives",
      ev("""
        (function()
            local before = { s = "a,b{c}=d|e~f\\g092h" }
            local after = ns.Share.Deserialise(ns.Share.Serialise(before))
            return after.s == before.s
        end)()
      """) is True,
      ev("""
        (function()
            local before = { s = "a,b{c}=d|e~f\\g092h" }
            local after = ns.Share.Deserialise(ns.Share.Serialise(before))
            return tostring(after.s)
        end)()
      """))

# --- 6u. what survives a logout -------------------------------------------
# Settings are written to a file as text and read back next session. Anything
# the compactor strips has to be something the loader puts back, and the two
# are written from the same defaults -- but only a real round trip proves it.
print("-- settings survive being saved and loaded")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", name = "Watched", trigger = { spellID = 774 } },
} } } }
""")
ev = L.eval

# Set them the way the window does, through the real field setters.
L.execute("ns.Config:Open(); ns.Config:Select('a1')")
L.execute("""
(function()
    local aura = ns.FindAura('a1')
    for _, field in ipairs(ns.Config.__loadFields or {}) do
        if field.key == "combat" then field.cycle(aura) end
        if field.key == "alive" then field.cycle(aura) field.cycle(aura) end
        if field.key == "class" then field.set(aura, "DRUID", true) end
        if field.key == "level" then field.set(aura, "min", "30") end
        if field.key == "zone" then field.set(aura, "Elwynn") end
    end
    for _, field in ipairs(ns.Config.__actionFields or {}) do
        if field.key == "onShow" then field.set(aura, "850") end
        if field.key == "onHide" then field.set(aura, "878") end
        if field.key == "channel" then field.set(aura, "SFX") end
    end
end)()
""")

check("the load settings are on the aura before saving",
      ev("ns.FindAura('a1').load.combat") is True
      and ev("ns.FindAura('a1').load.alive") is False
      and ev("ns.FindAura('a1').load.class.DRUID") is True
      and ev("ns.FindAura('a1').load.level.min") == 30
      and ev("ns.FindAura('a1').load.zone") == "Elwynn")
check("and so are the actions",
      ev("ns.ActionField((ns.FindAura('a1')), 'onShow')") == "850"
      and ev("ns.ActionField((ns.FindAura('a1')), 'onHide')") == "878"
      and ev("ns.ActionField((ns.FindAura('a1')), 'channel')") == "SFX")

# Log out: the compactor runs, and whatever is left becomes the file.
L.execute("ns.SaveOnLogout()")
saved = ev("DUMP(ChairAurasDB)")
check("the file still mentions the load settings",
      "combat" in saved and "Elwynn" in saved, saved[:400])
check("and the actions", "onShow" in saved and "SFX" in saved, saved[:400])

# Next session: that text is the whole of what the addon is given.
L2 = boot("ChairAurasDB = " + saved)
ev2 = L2.eval

check("combat came back", ev2("ns.FindAura('a1').load.combat") is True)
check("a condition set to no came back as no",
      ev2("ns.FindAura('a1').load.alive") is False,
      ev2("tostring(ns.FindAura('a1').load.alive)"))
check("the class list came back", ev2("ns.FindAura('a1').load.class.DRUID") is True)
check("the level came back", ev2("ns.FindAura('a1').load.level.min") == 30)
check("the zone came back", ev2("ns.FindAura('a1').load.zone") == "Elwynn")
check("the sound to play came back",
      ev2("ns.ActionField((ns.FindAura('a1')), 'onShow')") == "850")
check("the sound for going away came back",
      ev2("ns.ActionField((ns.FindAura('a1')), 'onHide')") == "878")
check("and the channel came back",
      ev2("ns.ActionField((ns.FindAura('a1')), 'channel')") == "SFX",
      ev2("ns.ActionField((ns.FindAura('a1')), 'channel')"))

# A channel left on its default is stripped from the file on purpose, and has
# to read back as the default rather than as nothing.
L3 = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", trigger = { spellID = 774 }, actions = { onShow = "850",
      channel = "Master" } },
} } } }
""")
L3.execute("ns.SaveOnLogout()")
stripped = L3.eval("DUMP(ChairAurasDB)")
check("a default channel is not written to the file",
      "Master" not in stripped, stripped[:300])
L4 = boot("ChairAurasDB = " + stripped)
check("and still reads back as Master",
      L4.eval("ns.ActionField((ns.FindAura('a1')), 'channel')") == "Master")
check("with the sound it was given",
      L4.eval("ns.ActionField((ns.FindAura('a1')), 'onShow')") == "850")

# --- 6v. the controls themselves ------------------------------------------
# Every earlier test drove the field descriptions. This one clicks the widgets
# the window actually builds, which is the only path a player ever takes --
# and the only one that can be wired up wrong without any of the others
# noticing.
print("-- clicking the real controls")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", name = "Watched", trigger = { spellID = 774 } },
} } } }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('a1')")

FIND_WIDGET = """
(function(key, kind, paneKey)
    for name, entry in pairs(ns.Config.__panes or {}) do
        if not paneKey or name == paneKey then
        for _, widget in ipairs(entry.pane.widgets or {}) do
            if widget.field and widget.field.key == key
               and widget.field.kind == kind then
                return widget
            end
        end
        end
    end
end)
"""

L.execute("FIND_WIDGET = " + FIND_WIDGET)

# Load: the three-state box, clicked rather than cycled by hand.
L.execute("ns.Config:SetTab('load')")
check("the load tab built a three-state box for combat",
      ev("FIND_WIDGET('combat', 'tristate') ~= nil") is True)

L.execute("(function() local w = FIND_WIDGET('combat', 'tristate') "
          "w.check._scripts.OnClick(w.check) end)()")
check("clicking it writes to the aura",
      ev("(ns.FindAura('a1').load or {}).combat") is True,
      ev("tostring((ns.FindAura('a1').load or {}).combat)"))

L.execute("(function() local w = FIND_WIDGET('combat', 'tristate') "
          "w.check._scripts.OnClick(w.check) end)()")
check("clicking again writes the other answer",
      ev("ns.FindAura('a1').load.combat") is False)

# Load: a set, and a range, through their own widgets.
L.execute("(function() local w = FIND_WIDGET('class', 'set') "
          "local box = w.checks[1] box:SetChecked(true) box._scripts.OnClick(box) end)()")
check("ticking a class writes it",
      ev("(function() local c = ns.FindAura('a1').load.class "
         "return c ~= nil and next(c) ~= nil end)()") is True,
      ev("tostring(ns.FindAura('a1').load.class)"))

L.execute("(function() local w = FIND_WIDGET('level', 'range') "
          "w.minBox:SetText('25') w.minBox._scripts.OnEnterPressed(w.minBox) end)()")
check("typing a level writes it",
      ev("(ns.FindAura('a1').load.level or {}).min") == 25,
      ev("tostring((ns.FindAura('a1').load.level or {}).min)"))

L.execute("(function() local w = FIND_WIDGET('zone', 'text') "
          "w.box:SetText('Elwynn') w.box._scripts.OnEnterPressed(w.box) end)()")
check("typing a zone writes it",
      ev("ns.FindAura('a1').load.zone") == "Elwynn",
      ev("tostring(ns.FindAura('a1').load.zone)"))

# Actions: the sound row and the channel.
L.execute("ns.Config:SetTab('actions')")
check("the actions tab built a sound control",
      ev("FIND_WIDGET('onShow', 'sound') ~= nil") is True)

L.execute("(function() local w = FIND_WIDGET('onShow', 'sound') "
          "w.choose._scripts.OnClick(w.choose) end)()")
L.execute("(function() local row = ChairAurasSoundPicker.rows[2] "
          "row._scripts.OnClick(row) end)()")
check("choosing a sound writes it to the aura",
      ev("(ns.FindAura('a1').actions or {}).onShow") is not None,
      ev("tostring((ns.FindAura('a1').actions or {}).onShow)"))

L.execute("(function() local w = FIND_WIDGET('channel', 'choice') "
          "w.group.buttons[2]._scripts.OnClick(w.group.buttons[2]) end)()")
check("choosing a channel writes it",
      ev("ns.FindAura('a1').actions.channel") == "SFX",
      ev("tostring((ns.FindAura('a1').actions or {}).channel)"))

# And all of that has to still be there after a logout and a fresh session.
L.execute("ns.SaveOnLogout()")
saved = ev("DUMP(ChairAurasDB)")
check("the file carries what the controls wrote",
      "combat" in saved and "Elwynn" in saved and "onShow" in saved, saved[:500])

L2 = boot("ChairAurasDB = " + saved)
check("and it is all there next session",
      L2.eval("ns.FindAura('a1').load.combat") is False
      and L2.eval("ns.FindAura('a1').load.zone") == "Elwynn"
      and L2.eval("ns.FindAura('a1').load.level.min") == 25
      and L2.eval("(ns.FindAura('a1').actions or {}).onShow") is not None
      and L2.eval("ns.ActionField((ns.FindAura('a1')), 'channel')") == "SFX")

# Exported from there, it has to carry the same.
L2.execute("SHARED = ns.Share:Export((ns.FindAura('a1')))")
L2.execute("BACK = ns.Share:Peek(SHARED)")
check("an export of it carries the load settings",
      L2.eval("BACK.auras[1].load.zone") == "Elwynn"
      and L2.eval("BACK.auras[1].load.combat") is False,
      L2.eval("tostring(BACK.auras[1].load)"))
check("and the actions",
      L2.eval("BACK.auras[1].actions.channel") == "SFX",
      L2.eval("tostring(BACK.auras[1].actions)"))

# --- 6w. chat is left alone ------------------------------------------------
# Chat links were removed on 2026-09-24. Wrapping the chat windows to make them
# met secret chat text on this client and dropped lines, so nothing in this
# addon touches chat any more; the export string is how an aura travels.
print("-- chat is left alone")
L = boot(SAVED_ONE_AURA)
check("no chat window is wrapped",
      L.eval("ChatFrame1.chairaurasHooked") is None)
check("no chat filter is installed", L.eval("next(CHAT_FILTERS)") is None)
L.execute("DRAWN = {} ChatFrame1:AddMessage('[ChairAuras: Tester - Rejuv]')")
check("a line that looks like an old link is drawn as it came",
      L.eval("DRAWN[1]") == "[ChairAuras: Tester - Rejuv]", L.eval("DRAWN[1]"))
L.execute('PRINTED = {} SlashCmdList["CHAIRAURAS"]("link 1")')
check("the old link command points at export instead",
      "export" in chr(10).join(L.eval("PRINTED").values()))

# --- 7. the cursor --------------------------------------------------------
print("-- reading a spell off the cursor")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
-- What this client puts on the cursor: the spellbook index is second, the real
-- spell ID is fourth. 774 is also a valid spell, which is exactly how the old
-- reader got away with looking plausible while being wrong.
CURSOR = { index = 774, book = "spell", spellID = 8936 }
''')
# Parenthesised, so the "spell" that comes back beside it does not turn the
# comparison into one against a pair.
check("the ID comes off the end of the payload, not the middle",
      L.eval("(ns.SpellFromCursor())") == 8936, L.eval("(ns.SpellFromCursor())"))
L.execute("CURSOR = nil")
check("and a cursor holding no spell is refused",
      L.eval("(ns.SpellFromCursor())") is None)

# --- 8. deleting a group leaves its children -----------------------------
print("-- deleting")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "group", name = "Group" },
    { id = "a1", parent = "g1", trigger = { spellID = 774 } },
} } } }
''')
L.execute("ns.Config:Delete('g1')")
check("the group is gone", L.eval("ns.FindAura('g1')") is None)
check("its child is not", L.eval("ns.FindAura('a1') ~= nil") is True)
check("and it is no longer parented to a ghost",
      L.eval("ns.FindAura('a1').parent") is None)

# --- 9. compaction --------------------------------------------------------
print("-- what reaches the saved file")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "a1", type = "icon", trigger = { type = "aura", unit = "player",
      spellID = 774, mine = false }, display = { size = 40, invert = false },
      load = {} },
} } } }
''')
L.execute("ns.SaveOnLogout()")
check("defaults are stripped on the way out",
      L.eval("ns.Trigger(ns.GetAuras()[1]).unit") is None
      and L.eval("ns.Trigger(ns.GetAuras()[1]).type") is None)
check("the spell itself is kept", L.eval("ns.Trigger(ns.GetAuras()[1]).spellID") == 774)
check("an empty display table is dropped", L.eval("ns.GetAuras()[1].display") is None)
check("an empty load table is dropped", L.eval("ns.GetAuras()[1].load") is None)

# --- 9b. naming things after they exist -----------------------------------
print("-- renaming")
L = boot("""
ChairAurasDB = { version = 2, profiles = { ["guid:Player-4613-000001"] = { auras = {} } } }
ChairAurasDB.profiles["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Dynamic group" },
    { id = "a1", parent = "g1", trigger = { spellID = 774 } },
    { id = "a2", trigger = { match = "name", text = "Well Fed" }, name = "Well Fed" },
} }
""")
ev = L.eval

check("an aura starts out called after what it watches",
      ev("(ns.Engine:Describe(ns.FindAura('a1')))") == "Rejuvenation",
      ev("(ns.Engine:Describe(ns.FindAura('a1')))"))

check("renaming one answers true", ev("ns.Config:Rename('a1', 'Rejuv on me')") is True)
check("and it is called that now",
      ev("(ns.Engine:Describe(ns.FindAura('a1')))") == "Rejuv on me",
      ev("(ns.Engine:Describe(ns.FindAura('a1')))"))
check("the trigger is untouched by a rename",
      ev("ns.Trigger((ns.FindAura('a1'))).spellID") == 774)

check("a group can be renamed too", ev("ns.Config:Rename('g1', 'Procs')") is True)
check("and keeps its children, which name it by id not by label",
      ev("#ns.Children('g1')") == 1 and ev("ns.FindAura('a1').parent") == "g1")

# Clearing it has to be possible: an aura with no name of its own is a real
# state, not an empty string.
check("clearing the name gives back the borrowed one",
      ev("ns.Config:Rename('a1', '')") is True
      and ev("(ns.Engine:Describe(ns.FindAura('a1')))") == "Rejuvenation",
      ev("(ns.Engine:Describe(ns.FindAura('a1')))"))
check("and stores nothing rather than an empty string",
      ev("ns.FindAura('a1').name") is None)
check("a name of nothing but spaces counts as clearing it",
      ev("ns.Config:Rename('a2', '   ')") is True and ev("ns.FindAura('a2').name") is None)
check("surrounding spaces are trimmed off a real one",
      ev("ns.Config:Rename('a2', '  Fed  ')") is True
      and ev("ns.FindAura('a2').name") == "Fed", ev("ns.FindAura('a2').name"))
check("renaming something that is not there is refused, not an error",
      ev("ns.Config:Rename('nope', 'x')") is False)

# The slash command is the other way in, and it addresses things by the number
# /ca list prints rather than by id.
L.execute("SlashCmdList.CHAIRAURAS('rename 2 Big Heal')")
check("/ca rename reaches the same place",
      ev("ns.FindAura('a1').name") == "Big Heal", ev("ns.FindAura('a1').name"))
L.execute("SlashCmdList.CHAIRAURAS('rename 2')")
check("/ca rename with no name clears it", ev("ns.FindAura('a1').name") is None)

# --- 10. the window ------------------------------------------------------
# Config:Open catches its own errors and says so rather than throwing, which
# means a broken window is silent unless something looks for the complaint.
print("-- building the options window")
L = boot('''
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {
    { id = "g1", type = "dynamic", name = "Row" },
    { id = "a1", parent = "g1", trigger = { spellID = 774 } },
    { id = "a2", trigger = { match = "name", text = "Well Fed" },
      load = { combat = true, class = { DRUID = true }, level = { min = 10 } } },
} } } }
''')
L.execute("ns.Config:Open()")
printed = chr(10).join(L.eval("PRINTED").values())
check("the window builds", "failed to build" not in printed, printed)
check("and it is on screen", L.eval("ChairAurasConfig:IsShown()") is True)

L.execute("ns.Config:Select('a2'); ns.Config:Refresh()")
check("selecting a name-matched aura redraws without error", True)

for tab in ("trigger", "display", "load"):
    ok = L.eval("(function() return pcall(function() ns.Config:SetTab('%s') end) end)()" % tab)
    check("the " + tab + " tab draws", ok is True)

# A condition this client cannot answer is offered as greyed rather than as a
# setting that quietly does nothing.
L3 = boot("IsMounted = nil")
check("an unanswerable condition reports itself unavailable",
      L3.eval('''
        (function()
            for _, condition in ipairs(ns.Load.CONDITIONS) do
                if condition.key == "mounted" then
                    return ns.Load:Available(condition)
                end
            end
        end)()
      ''') is False)
check("one it can answer reports available",
      L3.eval('''
        (function()
            for _, condition in ipairs(ns.Load.CONDITIONS) do
                if condition.key == "combat" then
                    return ns.Load:Available(condition)
                end
            end
        end)()
      ''') is True)

# --- 20. the auras written into the addon ---------------------------------
# Seeding ships off: a fresh install starts with no auras. When it is switched
# on, the rules worth pinning: it fills an empty profile, it never touches one
# that has anything in it, and what it puts in is a copy.
print("-- auras written into the addon")

L = boot(EMPTY_SAVED, preset=None)
check("as shipped, an empty profile stays empty",
      L.eval("#ns.GetAuras()") == 0, L.eval("#ns.GetAuras()"))
check("and nothing is reported as seeded",
      L.eval("ns.loadWitness.seeded") == 0, L.eval("ns.loadWitness.seeded"))

L = boot(EMPTY_SAVED, preset=True)
check("an empty profile comes up holding the built-in auras",
      L.eval("#ns.GetAuras()") == 5, L.eval("#ns.GetAuras()"))
check("the group is the dynamic one they sit in",
      L.eval("ns.GetAuras()[1].type") == "dynamic"
      and L.eval("ns.GetAuras()[1].name") == "Buffs")
check("its children name it as their parent",
      L.eval("#ns.Children('a1')") == 4, L.eval("#ns.Children('a1')"))
check("they are matched by the words on the aura, having no spell id",
      L.eval("ns.TriggerField((ns.FindAura('a4')), 'match')") == "name"
      and L.eval("ns.Trigger((ns.FindAura('a4'))).text") == "Well Fed")
check("the load conditions came with them",
      L.eval("ns.FindAura('a5').load.class.DRUID") is True
      and L.eval("ns.FindAura('a5').load.combat") is False)
check("and the witness says these were seeded, not loaded",
      L.eval("ns.loadWitness.seeded") == 5, L.eval("ns.loadWitness.seeded"))

# The copy rule: the profile is edited in place and compacted on the way out,
# and both of those would otherwise reach into the file itself.
L.execute("ns.FindAura('a5').name = 'edited'")
PRESET_BY_ID = ("(function(id) for _, p in ipairs(ns.PRESET_AURAS) do"
                " if p.id == id then return p.name end end end)('%s')")
check("editing a seeded aura does not edit the list it came from",
      L.eval(PRESET_BY_ID % "a5") == "Mark of the Wild",
      L.eval(PRESET_BY_ID % "a5"))

L = boot(SAVED_ONE_AURA, preset=True)
check("saved auras that did arrive are left alone",
      L.eval("#ns.GetAuras()") == 1 and L.eval("ns.GetAuras()[1].name") == "mine",
      L.eval("#ns.GetAuras()"))
check("and nothing is reported as seeded",
      L.eval("ns.loadWitness.seeded") == 0, L.eval("ns.loadWitness.seeded"))

# /ca preset load is the deliberate way back, and it replaces rather than adds:
# the point of the command is "give me back that setup", not "give me two of it".
L.eval('SlashCmdList["CHAIRAURAS"]("preset load")')
check("/ca preset load replaces what was there",
      L.eval("#ns.GetAuras()") == 5, L.eval("#ns.GetAuras()"))
check("and the aura that was in the way is gone rather than duplicated",
      L.eval("ns.FindAura('a1').name") == "Buffs", L.eval("ns.FindAura('a1').name"))

L = boot(EMPTY_SAVED, preset=True)
L.eval('SlashCmdList["CHAIRAURAS"]("preset off")')
check("/ca preset off stops an emptied list filling itself again",
      L.eval("ns.presetEnabled") is False
      and L.eval("ns.ApplyPreset(ns.GetProfile(), false)") == 0)

# --- 21. the refresh tick -------------------------------------------------
# Events are not the whole story -- there are states this client raises nothing
# for -- so a tick re-evaluates everything whether or not anything asked. What
# matters is that it happens without an event, and that steady event traffic
# cannot starve it.
print("-- the refresh tick")

L = boot(SAVED_ONE_AURA)
pattern = L.eval(SWEEP_PATTERN)

check("nothing sweeps before the tick is due",
      pattern(0.02, 4, "") == "0000", pattern(0.02, 4, ""))
check("and then it sweeps every tenth of a second, with no event at all",
      pattern(0.1, 3, "") == "111", pattern(0.1, 3, ""))
check("an event still sweeps on the frame it arrives, without waiting",
      pattern(0.02, 3, "all") == "111", pattern(0.02, 3, "all"))
# The one that matters. A coalesced event must not put the tick clock back, or
# steady UNIT_AURA traffic -- forty units in a raid -- pushes the guarantee out
# indefinitely, which is the situation the guarantee exists for.
check("and an event does not put the guaranteed tick back",
      pattern(0.06, 3, "1") == "110", pattern(0.06, 3, "1"))

print("-- stacks and races")

L = boot(EMPTY_SAVED, preset=True)

# The stack count is read from whichever field this client fills in.
for field in ("applications", "stackCount", "count", "charges"):
    L.execute("DATA = { %s = 7 }" % field)
    L.execute("CNT = ns.SafeNumber(DATA.applications) or ns.SafeNumber(DATA.stackCount)"
              " or ns.SafeNumber(DATA.count) or ns.SafeNumber(DATA.charges) or 0")
    check("a stack count in " + field + " is read", L.eval("CNT") == 7,
          str(L.eval("CNT")))

# Races joined the load list.
keys = L.eval("(function() local t = {} for _, c in ipairs(ns.Load.CONDITIONS) do"
              " t[c.key] = true end return t end)()")
check("race is a load condition", keys["race"] is True)
check("and class is still there", keys["class"] is True)
check("the race list is populated", (L.eval("#ns.Load:RaceList()") or 0) > 0,
      str(L.eval("#ns.Load:RaceList()")))
L.execute("""
RACE_INFO = {}
for id = 1, 100 do RACE_INFO[id] = { clientFileString = "Race" .. id, raceName = "Race " .. id } end
RACE_INFO[5] = { clientFileString = "Scourge", raceName = "Undead" }
RACE_INFO[95] = { clientFileString = "HighOrderSkyborne", raceName = "High Order Skyborne" }
RACE_INFO[96] = { clientFileString = "WindshaperSkyborne", raceName = "Windshaper Skyborne" }
C_CreatureInfo = { GetRaceInfo = function(id) return RACE_INFO[id] end }
""")
races = [L.eval("ns.Load:RaceList()[%d].text" % i) for i in range(1, (L.eval("#ns.Load:RaceList()") or 0) + 1)]
check("only the playable races are offered, Skyborne included, from a client that knows a hundred",
      len(races) == 10 and "Undead" in races and "High Order Skyborne" in races
      and "Windshaper Skyborne" in races and "Race 50" not in races, str(races))


# The stack number was drawn correctly and invisibly: a font string on the
# icon OVERLAY layer sits under the icon's child frames, and the font object
# it asked for may not exist on this client.
L.execute("HASFONT = { GetFont = function() return 'F', 12, '' end,"
          " SetFont = function(self) self.set = true end }")
check("a font string that already has a font is left alone",
      L.eval("ns.EnsureFont(HASFONT)") is False)
L.execute("NOFONT = { GetFont = function() return nil end,"
          " SetFont = function(self) self.set = true end }")
check("one with no font is given one", L.eval("ns.EnsureFont(NOFONT)") is True)
check("and the font actually gets set", L.eval("NOFONT.set") is True)
L.execute("THROWS = { GetFont = function() error('no') end,"
          " SetFont = function(self) self.set = true end }")
check("a font string that throws is repaired rather than crashing",
      L.eval("ns.EnsureFont(THROWS)") is True)

# Conditions came back in WeakAuras' shape (phase 5). Rules saved in the shape
# removed on 2026-09-25 cannot be read as it, and are still dropped on load.
print("-- conditions")
LC = boot('''
ChairAurasDB = { version = 2, profiles = { ["account"] = { auras = {
    { id = "a1", type = "icon",
      trigger = { match = "name", text = "Plainsrunning" },
      conditions = { { property = "stacks", op = "<=", value = 5, effect = "hide" } } },
    { id = "c1", type = "icon",
      trigger = { match = "name", text = "Plainsrunning" },
      display = { iconText = "%s" },
      conditions = {
        { check = { trigger = 1, variable = "stacks", op = ">=", value = 3 },
          changes = { { property = "color", value = { 1, 0, 0, 1 } },
                      { property = "glow", value = true },
                      { property = "sound", value = { sound = "12867" } } } },
        { check = { trigger = 1, variable = "stacks", op = ">=", value = 5 },
          changes = { { property = "color", value = { 0, 0, 1, 1 } },
                      { property = "text", value = "MAX" } } },
      } },
    { id = "c2", type = "icon",
      trigger = { match = "name", text = "Plainsrunning" },
      conditions = {
        { check = { trigger = 1, variable = "expirationTime", op = "<=", value = 5 },
          changes = { { property = "alpha", value = 40 } } },
        { check = { trigger = 1, variable = "show", op = "==", value = true },
          changes = { { property = "scale", value = 2 } }, linked = true },
        { check = { trigger = -2, variable = "AND", checks = {
              { trigger = 1, variable = "name", op = "find", value = "plains" },
              { trigger = -1, variable = "customcheck", value = "function(t) return t[1].count == 2 end" } } },
          changes = { { property = "desaturate", value = true },
                      { property = "chat", value = { message = "two of %n", channel = "PRINT" } } } },
      } },
} } } }
AURAS.player = {
    { name = "Plainsrunning", spellId = 1299038, applications = 2, duration = 20, expirationTime = NOW + 10 },
}
''')
ev = LC.eval
check("rules in the old shape are dropped on load",
      LC.eval("ns.FindAura('a1').conditions") is None)
check("and conditions in WeakAuras' shape are kept",
      LC.eval("#ns.FindAura('c1').conditions") == 2)
LC.execute("SOUNDS = {} ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("an old hide rule no longer hides the aura",
      (LC.eval("ns.Display.__regions.a1._alpha") or 0) > 0,
      str(LC.eval("ns.Display.__regions.a1._alpha")))
check("two stacks is not three: no change", LC.eval("ns.Engine.states.c1.props") is None)
LC.execute("AURAS.player[1].applications = 3 ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("three stacks: the first condition holds, and colors the icon",
      LC.eval("ns.Engine.states.c1.props.color[1]") == 1 and LC.eval("ns.Engine.states.c1.props.glow") is True)
check("its sound plays once, as it starts", len(LC.eval("SOUNDS") or {}) == 1, str(LC.eval("DUMP(SOUNDS)")))
LC.execute("ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("and not again while it holds", len(LC.eval("SOUNDS") or {}) == 1)
check("the glow is drawn", LC.eval("ns.Display.__regions.c1.glow and ns.Display.__regions.c1.glow:IsShown()") is True)
LC.execute("AURAS.player[1].applications = 6 ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("six: the later condition overrides the color", LC.eval("ns.Engine.states.c1.props.color[3]") == 1)
check("and the text", LC.eval("ns.Display.__regions.c1.overlay._text") == "MAX",
      str(LC.eval("ns.Display.__regions.c1.overlay._text")))
check("while the earlier one's glow still holds", LC.eval("ns.Engine.states.c1.props.glow") is True)
LC.execute("AURAS.player[1].applications = 1 ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("and all of it goes when they stop holding",
      LC.eval("ns.Engine.states.c1.props") is None
      and LC.eval("ns.Display.__regions.c1.glow:IsShown()") is False)

LC.execute("AURAS.player[1].applications = 2 PRINTED = {} ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("time left over 5: no fade; else-if: the one below it holds instead",
      LC.eval("ns.Engine.states.c2.props.alpha") is None and LC.eval("ns.Engine.states.c2.props.scale") == 2)
LC.execute("NOW = NOW + 6 ns.Engine:UpdateAll()")
check("under 5 seconds: the fade holds, and the else-if below it does not",
      LC.eval("ns.Engine.states.c2.props.alpha") == 40 and LC.eval("ns.Engine.states.c2.props.scale") is None)
check("all-of checks, a name and a custom check together",
      LC.eval("ns.Engine.states.c2.props.desaturate") is True)
check("and a chat message said once", "two of Plainsrunning" in " ".join(str(v) for v in (LC.eval("PRINTED") or {}).values()),
      str(LC.eval("DUMP(PRINTED)")))

print("-- conditions in the window")
LC.execute("ns.Config:Open(); ns.Config:Select('c1'); ns.Config:SetTab('conditions')")
LC.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the window has a Conditions tab", LC.eval("ns.Config.__panes.conditions ~= nil") is True)
check("with the aura's conditions on its strip",
      LC.eval("FIND_WIDGET('conditionStrip', 'strip').numbers[2]:IsShown()") is True)
LC.execute("local w = FIND_WIDGET('conditionStrip', 'strip') w.add._scripts.OnClick(w.add)")
check("+ adds a condition, and opens it", LC.eval("#ns.FindAura('c1').conditions") == 3
      and LC.eval("(ns.Config.__conditionCursor())") == 3)
LC.execute("FIND_WIDGET('checkVariable', 'choice').dropdown:Pick('name')")
check("its check can look at another value", LC.eval("ns.FindAura('c1').conditions[3].check.variable") == "name")
check("and the operators follow what it is: a name has is / contains",
      LC.eval("FIND_WIDGET('checkOpString', 'choice').host:IsShown()") is True
      and LC.eval("FIND_WIDGET('checkOpNumber', 'choice').host:IsShown()") is False)
LC.execute("local w = FIND_WIDGET('checkStrip', 'strip') w.add._scripts.OnClick(w.add)")
check("a second check makes it all-of", LC.eval("ns.FindAura('c1').conditions[3].check.variable") == "AND"
      and LC.eval("#ns.FindAura('c1').conditions[3].check.checks") == 2)
LC.execute("FIND_WIDGET('changeProperty', 'choice').dropdown:Pick('alpha')")
check("a change can be made a fade", LC.eval("ns.FindAura('c1').conditions[3].changes[1].property") == "alpha"
      and LC.eval("FIND_WIDGET('changeAlpha', 'slider').host:IsShown()") is True)
LC.execute("local w = FIND_WIDGET('conditionStrip', 'strip') w.up._scripts.OnClick(w.up)")
check("and a condition can be moved up", LC.eval("ns.FindAura('c1').conditions[2].check.variable") == "AND")
LC.execute("local w = FIND_WIDGET('conditionStrip', 'strip') w.remove._scripts.OnClick(w.remove)")
check("or removed", LC.eval("#ns.FindAura('c1').conditions") == 2)


# The field name was never the problem -- a dump off the live client showed
# applications sitting right there. These pin the names down so a later
# "helpful" rewrite of the reader has to keep reading them.
for field in ("applications", "stackCount", "count", "charges", "stacks"):
    L.execute("D = { %s = 7 }" % field)
    check("a known field named " + field + " is read",
          L.eval("(ns.StackCount(D))") == 7, str(L.eval("(ns.StackCount(D))")))

# A buff that does not stack reports applications = 0. That is a real answer.
L.execute("D = { applications = 0, name = 'Some buff' }")
check("a non-stacking aura reports zero, not nothing",
      L.eval("(ns.StackCount(D))") == 0, str(L.eval("(ns.StackCount(D))")))

# Real data off this client, pasted from /dump.
L.execute("D = { spellId = 1299038, name = 'Plainsrunning', applications = 2,"
          " duration = 0, icon = 236717, auraInstanceID = 1613 }")
check("a real two-stack aura reads as two",
      L.eval("(ns.StackCount(D))") == 2, str(L.eval("(ns.StackCount(D))")))

L.execute("D = { name = 'Bob', duration = 12 }")
check("nothing countable means unknown, not zero",
      L.eval("(ns.StackCount(D))") is None, str(L.eval("(ns.StackCount(D))")))
check("and a non-table is refused", L.eval("(ns.StackCount(nil))") is None)

# --- account-wide profile -------------------------------------------------
# Auras are shared across the account. The first login after the change makes
# the account profile from the fullest character profile and leaves the
# character profiles alone.
print("-- account-wide auras")

L = boot("""
ChairAurasDB = { version = 2, profiles = {
    ["guid:Player-1-00000001"] = { auras = { { id = "a1", name = "mine" } } },
    ["guid:Player-1-00000002"] = { auras = {
        { id = "a1", name = "alt one" }, { id = "a2", name = "alt two" } } },
} }
""")
check("the profile key is the account, not the character",
      L.eval("ns.ProfileKey()") == "account")
check("the account profile starts from the fullest character profile",
      L.eval("#ns.GetAuras()") == 2 and L.eval("ns.GetAuras()[1].name") == "alt one",
      str(L.eval("#ns.GetAuras()")))
check("the character profiles are left in the file",
      L.eval("#ChairAurasDB.profiles['guid:Player-1-00000001'].auras") == 1
      and L.eval("#ChairAurasDB.profiles['guid:Player-1-00000002'].auras") == 2)
check("and the account profile is a copy, not the same table",
      L.eval("ChairAurasDB.profiles.account ~= ChairAurasDB.profiles['guid:Player-1-00000002']") is True)

L = boot("""
ChairAurasDB = { version = 2, profiles = {
    account = { auras = { { id = "a1", name = "shared" } } },
    ["guid:Player-1-00000001"] = { auras = {
        { id = "a1", name = "old" }, { id = "a2", name = "older" } } },
} }
""")
check("an existing account profile is never replaced",
      L.eval("#ns.GetAuras()") == 1 and L.eval("ns.GetAuras()[1].name") == "shared")

L = boot("""
UnitGUID = function() return "Player-1-00000099" end
ChairAurasDB = { version = 2, profiles = {
    account = { auras = { { id = "a1", name = "shared" } } },
} }
""")
check("another character sees the same auras",
      L.eval("#ns.GetAuras()") == 1 and L.eval("ns.GetAuras()[1].name") == "shared")

L = boot(EMPTY_SAVED)
check("a brand-new install gets an empty account profile",
      L.eval("#ns.GetAuras()") == 0 and L.eval("ChairAurasDB.profiles.account ~= nil") is True)


# --- opened from anywhere, it opens inside the Chaircraft menu ------------
# The menu is stood in for here: it builds the window, marks it hosted and calls
# back into Config:Open, which is exactly what ChairPlus's OpenPage does.
print("-- inside the Chaircraft menu")
L = boot(SAVED_ONE_AURA)
L.execute("""
HOSTED = 0
ChairPlusNS = { OpenPartPage = function(token)
    HOSTED = HOSTED + 1
    HOSTED_TOKEN = token
    local w = ns.Config:GetWindow()
    w.chairEmbedded = true
    ns.Config:Open()
    return true
end }
""")
L.execute("ns.Config:Open()")
check("opening the auras window goes through the menu",
      L.eval("HOSTED") == 1 and L.eval("HOSTED_TOKEN") == "auras", str(L.eval("HOSTED")))
check("and the menu's call back fills and shows it, without going round again",
      L.eval("ChairAurasConfig:IsShown()") is True and L.eval("HOSTED") == 1)
check("the window lists what the menu hides",
      L.eval("#ChairAurasConfig.chairChrome") == 3)
L.execute("ChairAurasConfig:Hide() ChairAurasConfig.chairEmbedded = nil "
          "ChairPlusNS.OpenPartPage = function() return false end ns.Config:Open()")
check("when the menu cannot host it, it opens on its own",
      L.eval("ChairAurasConfig:IsShown()") is True)

# X and Y on the Display tab: the aura's centre, from the centre of the screen.
print("-- positioning by number")
LP = boot('''
ChairAurasDB = { version = 2, profiles = { ["account"] = { auras = {
    { id = "a1", type = "icon", trigger = { match = "name", text = "Plainsrunning" } },
    { id = "g1", type = "group", name = "Buffs" },
    { id = "a2", type = "icon", parent = "g1", trigger = { match = "name", text = "Other" } },
} } } }
''')
LP.execute("ns.Config:Open(); ns.Config:Select('a1')")
LP.execute("""
function POSFIELD(key)
    for _, w in ipairs(ns.Config.__panes['display'].pane.widgets) do
        if w.field.key == key then return w end
    end
end
POSFIELD('posX').field.set(ns.FindAura('a1'), 120)
POSFIELD('posY').field.set(ns.FindAura('a1'), -45)
CX, CY = ns.Display:CenterOffset(ns.FindAura('a1'))
""")
check("X and Y fields exist on the Display tab",
      LP.eval("POSFIELD('posX') ~= nil and POSFIELD('posY') ~= nil") is True)
check("setting them puts the aura's centre there",
      LP.eval("CX") == 120 and LP.eval("CY") == -45, "%s %s" % (LP.eval("CX"), LP.eval("CY")))
check("and it is saved as its position",
      LP.eval("ns.FindAura('a1').pos.x") == 120 and LP.eval("ns.FindAura('a1').pos.y") == -45)
LP.execute("BOXW = POSFIELD('posX').box")
LP.execute("rawset(BOXW, '_text', '0') local s = rawget(BOXW, '_scripts') if s and s.OnEnterPressed then s.OnEnterPressed(BOXW) end")
check("typing a number sets it too", LP.eval("(ns.Display:CenterOffset(ns.FindAura('a1')))") == 0,
      str(LP.eval("(ns.Display:CenterOffset(ns.FindAura('a1')))")))
LP.execute("""
local w = POSFIELD('posX')
local click = rawget(w.plus, '_scripts').OnClick
click(w.plus) click(w.plus)
rawget(w.minus, '_scripts').OnClick(w.minus)
""")
check("+ and - nudge it a pixel at a time",
      LP.eval("(ns.Display:CenterOffset(ns.FindAura('a1')))") == 1,
      str(LP.eval("(ns.Display:CenterOffset(ns.FindAura('a1')))")))
check("an aura inside a group has no position of its own to set",
      LP.eval("POSFIELD('posX').field.enabled(ns.FindAura('a2'))") is False
      and LP.eval("POSFIELD('posX').field.enabled(ns.FindAura('g1'))") is True)


# --- several triggers on one aura --------------------------------------------
print("-- several triggers, one aura")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "m1", triggers = {
        { trigger = { spellID = 774 } },
        { trigger = { spellID = 8936 } },
    } },
} } } }
SPELLS[774] = { name = "Rejuvenation", icon = 100 }
SPELLS[8936] = { name = "Regrowth", icon = 200 }
""")
ev = L.eval
L.execute("AURAS.player = { { name = 'Rejuvenation', spellId = 774, icon = 100 } } ns.Engine:UpdateAll()")
check("all (the default): one of two met is not enough",
      ev("ns.Engine.states.m1.shown") is False)
check("each trigger keeps its own answer",
      ev("ns.Engine.states.m1.triggers[1].met") is True
      and ev("ns.Engine.states.m1.triggers[2].met") is False)
L.execute("""AURAS.player = { { name = 'Rejuvenation', spellId = 774, icon = 100, duration = 12, expirationTime = NOW + 10 },
                              { name = 'Regrowth', spellId = 8936, icon = 200, duration = 21, expirationTime = NOW + 20 } }
ns.Engine:UpdateAll()""")
check("both met, it shows", ev("ns.Engine.states.m1.shown") is True)
check("and the first active trigger supplies the timer",
      ev("ns.Engine.states.m1.duration") == 12)
L.execute("ns.FindAura('m1').triggers.activeTriggerMode = 2 ns.Engine:UpdateAll()")
check("or a chosen one does", ev("ns.Engine.states.m1.duration") == 21)
check("and its icon", ev("ns.Engine.states.m1.icon") == 200)

L.execute("AURAS.player = { { name = 'Regrowth', spellId = 8936, icon = 200 } } ns.FindAura('m1').triggers.activeTriggerMode = nil")
L.execute("ns.FindAura('m1').triggers.disjunctive = 'any' ns.Engine:UpdateAll()")
check("any: one met is enough", ev("ns.Engine.states.m1.shown") is True)
check("and the one that is met speaks for it", ev("ns.Engine.states.m1.icon") == 200)

L.execute("""
local t = ns.FindAura('m1').triggers
t.disjunctive = 'custom'
t.customTriggerLogic = 'function(trigger) return trigger[2] and not trigger[1] end'
ns.Engine:UpdateAll()""")
check("custom: a Lua function decides from the triggers' answers",
      ev("ns.Engine.states.m1.shown") is True)
L.execute("AURAS.player = { { name = 'Rejuvenation', spellId = 774 }, { name = 'Regrowth', spellId = 8936 } } ns.Engine:UpdateAll()")
check("and changes its mind with them", ev("ns.Engine.states.m1.shown") is False)

L.execute("ns.FindAura('m1').triggers.customTriggerLogic = 'function(t) return RunScript(\"x\") end' ns.Engine:UpdateAll()")
check("custom code cannot reach RunScript", ev("ns.Engine.states.m1.shown") is False
      and "not available" in str(ev("ns.Engine.states.m1.error")), str(ev("ns.Engine.states.m1.error")))
L.execute("ns.FindAura('m1').triggers.customTriggerLogic = 'function(t) return getfenv ~= nil and getfenv(1) end' ns.Engine:UpdateAll()")
check("nor getfenv", "not available" in str(ev("ns.Engine.states.m1.error")), str(ev("ns.Engine.states.m1.error")))
L.execute("ns.FindAura('m1').triggers.customTriggerLogic = 'function(t) return ChairAurasDB end' ns.Engine:UpdateAll()")
check("nor the saved variables", "not available" in str(ev("ns.Engine.states.m1.error")), str(ev("ns.Engine.states.m1.error")))
L.execute("ns.FindAura('m1').triggers.customTriggerLogic = 'function(t) aura_env.seen = (aura_env.seen or 0) + 1 return true end' ns.Engine:UpdateAll()")
check("aura_env is the aura's own table", ev("ns.Env:For(ns.FindAura('m1')).seen") == 1
      and ev("ns.Engine.states.m1.shown") is True)
L.execute("ns.FindAura('m1').triggers.customTriggerLogic = 'function(t) return ( end' ns.Engine:UpdateAll()")
check("code that does not compile shows nothing and says why",
      ev("ns.Engine.states.m1.shown") is False and ev("ns.Engine.states.m1.error") is not None)

check("a trigger can be added", ev("ns.AddTrigger(ns.FindAura('m1'), { spellID = 1 })") == 3)
check("and removed", ev("ns.RemoveTrigger(ns.FindAura('m1'), 3)") is True
      and ev("ns.TriggerCount(ns.FindAura('m1'))") == 2)
L.execute("ns.RemoveTrigger(ns.FindAura('m1'), 2)")
check("but never the last one", ev("ns.RemoveTrigger(ns.FindAura('m1'), 1)") is False)

# --- a v2 aura becomes a v3 aura, unchanged in behaviour ---------------------
print("-- migration to several triggers")
L = boot("""
ChairAurasDB = { version = 2, profiles = { account = { auras = {
    { id = "old", trigger = { spellID = 774, unit = "target", harmful = true } },
} } } }
""")
ev = L.eval
check("the one trigger became the first of a list",
      ev("ns.FindAura('old').trigger") is None
      and ev("ns.FindAura('old').triggers[1].trigger.spellID") == 774
      and ev("ns.TriggerField((ns.FindAura('old')), 'unit')") == "target")
L.execute("AURAS.target = { { name = 'x', spellId = 774, isHarmful = true } } ns.Engine:UpdateAll()")
check("and it still fires", ev("ns.Engine.states.old.shown") is True)
L.execute("ns.SaveOnLogout()")
check("saved compactly: one plain trigger keeps only what it says",
      ev("DUMP(ns.FindAura('old').triggers)") is not None
      and ev("ns.FindAura('old').triggers.disjunctive") is None)

# --- what combat hides -------------------------------------------------------
print("-- in combat, with the reads refused")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "buff", triggers = { { trigger = { spellID = 774 } } } },
    { id = "cd", triggers = { { trigger = { type = "cooldown", spellID = 5487 } } } },
} } } }
""")
ev = L.eval
L.execute("""AURAS.player = { { name = 'Rejuvenation', spellId = 774, duration = 12, expirationTime = NOW + 12 } }
ns.Engine:UpdateAll()""")
check("out of combat the buff is read", ev("ns.Engine.states.buff.shown") is True
      and ev("ns.Engine.states.buff.assumed") is False)
L.execute("AURAS_REFUSED = true NOW = NOW + 5 ns.Engine:UpdateAll()")
check("in combat it is carried on its known expiry, marked assumed",
      ev("ns.Engine.states.buff.shown") is True and ev("ns.Engine.states.buff.assumed") is True)
L.execute("NOW = NOW + 8 ns.Engine:UpdateAll()")
check("and goes when that expiry passes", ev("ns.Engine.states.buff.shown") is False)
L.execute("ns.Engine.lastCast[774] = NOW ns.Engine:UpdateAll()")
check("recasting the spell brings it back, for the duration learned out of combat",
      ev("ns.Engine.states.buff.shown") is True and ev("ns.Engine.states.buff.duration") == 12)

L.execute("AURAS_REFUSED = false COOLDOWNS[5487] = { duration = 60, start = NOW } ns.Engine:UpdateAll()")
check("a cooldown read out of combat teaches its length",
      ev("ns.Engine.learnedCooldown[5487]") == 60)
L.execute("""
DURATION_OBJECT = { kind = "duration" }
C_Spell.GetSpellCooldownDuration = function(id) return DURATION_OBJECT end
COOLDOWNS[5487] = { duration = SECRET_VALUE(), start = SECRET_VALUE() }
NOW = NOW + 70
ns.Engine:UpdateAll()""")
check("in combat a secret cooldown is not read as ready by mistake",
      ev("ns.Engine.states.cd.assumed") is True)
check("its duration object is handed on for the swipe to draw",
      ev("ns.Engine.states.cd.durationObject == DURATION_OBJECT") is True)
L.execute("ns.Engine.lastCast[5487] = NOW ns.Engine:UpdateAll()")
check("casting it puts it on its learned cooldown",
      ev("ns.Engine.states.cd.met") is False and ev("ns.Engine.states.cd.duration") == 60)
L.execute("NOW = NOW + 61 ns.Engine:UpdateAll()")
check("and it is ready again once that has run out", ev("ns.Engine.states.cd.met") is True)

print("-- in combat, an aura that cannot be read says so")
L = boot("""
ChairAurasDB = { version = 3, probe = { runs = {}, auraEvents = { "old" } },
    profiles = { account = { auras = {
    { id = "plains", display = { stacks = true },
      triggers = { { trigger = { spellID = 1299038, stacks = 3 } } } },
} } } }
""")
ev = L.eval
check("the old in-combat event log is cleared from the saved file",
      ev("ChairAurasDB.probe.auraEvents") is None)
L.execute("""
AURAS.player = { { name = 'Plainsrunning', spellId = 1299038, icon = 236717, applications = 4,
                   auraInstanceID = 47, duration = 0, expirationTime = 0 } }
ns.Engine:UpdateAll()""")
st = "ns.Engine.states.plains"
check("out of combat four stacks meet three and are counted",
      ev(st + ".shown") is True and ev(st + ".count") == 4 and ev(st + ".stale") is False)
check("drawn at full strength, with the count",
      ev("ns.Display.__regions.plains:GetAlpha()") == 1
      and ev("ns.Display.__regions.plains.count:GetText()") == "4")
L.execute("AURAS_REFUSED = true NOW = NOW + 1 ns.Engine:UpdateAll()")
check("in combat it stays shown, as the last thing known",
      ev(st + ".shown") is True and ev(st + ".stale") is True)
check("but its count is unknown, not stale", ev(st + ".count") is None)
check("and it is drawn as unknown: half as opaque, gray, '?' for stacks",
      ev("ns.Display.__regions.plains:GetAlpha()") == 0.5
      and ev("ns.Display.__regions.plains.texture:IsDesaturated()") is True
      and ev("ns.Display.__regions.plains.count:GetText()") == "?")
check("the %s text code says '?' too",
      ev('ns.Engine:FormatText("%s", ns.GetAuras()[1], ns.Engine.states.plains)') == "?")
L.execute("AURAS_REFUSED = false AURAS.player[1].applications = 2 NOW = NOW + 1 ns.Engine:UpdateAll()")
check("after combat the real state comes straight back",
      ev(st + ".shown") is False and ev(st + ".stale") is False
      and ev("ns.Display.__regions.plains.count:GetText()") != "?")


# --- the trigger strip in the window -----------------------------------------
print("-- the trigger strip")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "s1", triggers = { { trigger = { spellID = 774 } } } },
} } } }
SPELLS[774] = { name = "Rejuvenation", icon = 100 }
SPELLS[8936] = { name = "Regrowth", icon = 200 }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('s1'); ns.Config:SetTab('trigger')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the Trigger tab has a strip of triggers", ev("FIND_WIDGET('triggers', 'triggers') ~= nil") is True)
L.execute("local w = FIND_WIDGET('triggers', 'triggers') w.add._scripts.OnClick(w.add)")
check("+ adds a trigger, a copy of the open one",
      ev("ns.TriggerCount(ns.FindAura('s1'))") == 2
      and ev("ns.Trigger((ns.FindAura('s1')), 2).spellID") == 774)
check("and opens it", ev("ns.Config.__currentTrigger()") == 2)
L.execute("""
for _, field in ipairs(ns.Config.__triggerFields) do
    if field.kind == "spell" then field.set(ns.FindAura('s1'), "8936") end
end""")
check("an edit goes to the open trigger, not the first",
      ev("ns.Trigger((ns.FindAura('s1')), 2).spellID") == 8936
      and ev("ns.Trigger((ns.FindAura('s1')), 1).spellID") == 774)
L.execute("local w = FIND_WIDGET('triggers', 'triggers') w.numbers[1]._scripts.OnClick(w.numbers[1])")
check("clicking 1 goes back to the first", ev("ns.Config.__currentTrigger()") == 1)
L.execute("local w = FIND_WIDGET('triggers', 'triggers') w.mode.buttons[3]._scripts.OnClick(w.mode.buttons[3])")
check("Show when: Custom", ev("ns.TriggerMode(ns.FindAura('s1'))") == "custom")
check("opens the code box for editing",
      ev("FIND_WIDGET('customTriggerLogic', 'code').box._enabled ~= false") is True)
L.execute("""local w = FIND_WIDGET('customTriggerLogic', 'code')
w.field.set(ns.FindAura('s1'), 'function(trigger) return trigger[2] end')""")
check("the code is saved on the aura",
      ev("ns.FindAura('s1').triggers.customTriggerLogic") == "function(trigger) return trigger[2] end")
L.execute("""local w = FIND_WIDGET('customTriggerLogic', 'code')
w.field.set(ns.FindAura('s1'), 'function(trigger) return ( end') ns.Config:Refresh()""")
check("and a compile error is shown under it",
      "|cffff5555" in str(ev("FIND_WIDGET('customTriggerLogic', 'code').status._text")),
      str(ev("FIND_WIDGET('customTriggerLogic', 'code').status._text")))
L.execute("local w = FIND_WIDGET('triggers', 'triggers') w.info._scripts.OnClick(w.info)")
check("Info cycles from first active to trigger 1", ev("ns.ActiveTriggerMode(ns.FindAura('s1'))") == 1)
L.execute("local w = FIND_WIDGET('triggers', 'triggers') w.numbers[2]._scripts.OnClick(w.numbers[2]) w.remove._scripts.OnClick(w.remove)")
check("Remove takes the open trigger away",
      ev("ns.TriggerCount(ns.FindAura('s1'))") == 1
      and ev("ns.Trigger((ns.FindAura('s1')), 1).spellID") == 774)
L.execute("ns.Config:Select('s1')")


# --- text on an icon --------------------------------------------------------
print("-- text drawn on an icon")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "ov", triggers = { { trigger = { spellID = 774 } } },
      display = { iconText = "%t", iconTextPoint = "BOTTOM", iconTextSize = 16 } },
    { id = "plain", triggers = { { trigger = { spellID = 774 } } } },
} } } }
""")
ev = L.eval
L.execute("AURAS.player = { { name = 'Rejuvenation', spellId = 774, duration = 12, expirationTime = NOW + 9 } } ns.Engine:UpdateAll()")
check("an icon can carry text on top of it",
      ev("ns.Display.__regions.ov.overlay._text") == "9.0", str(ev("ns.Display.__regions.ov.overlay._text")))
check("where it was put", ev("ns.Display.__regions.ov.overlay._point.point") == "BOTTOM")
check("and an icon without any draws none", ev("ns.Display.__regions.plain.overlay._text") in ("", None))


# --- custom Lua triggers -----------------------------------------------------
print("-- custom triggers")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "st", triggers = { { trigger = { type = "custom", custom_type = "status",
        events = "PLAYER_TARGET_CHANGED UNIT_POWER_UPDATE:player",
        custom = "function(event, unit) aura_env.calls = (aura_env.calls or 0) + 1 return WANT_ON end",
        customName = "function() return 'Named by code' end",
        customStacks = "function() return 3 end",
        customDuration = "function() return 10, GetTime() + 4 end" } } } },
    { id = "up", triggers = { { trigger = { type = "custom", check = "update",
        custom = "function() return TICK_ON end" } } } },
    { id = "ev", triggers = { { trigger = { type = "custom", custom_type = "event",
        events = "MY_EVENT", duration = 5,
        custom = "function(event, what) return what == 'go' end" } } } },
    { id = "evc", triggers = { { trigger = { type = "custom", custom_type = "event",
        events = "MY_EVENT", customHide = "custom",
        custom = "function(event, what) return what == 'go' end",
        customUntrigger = "function(event, what) return what == 'stop' end" } } } },
    { id = "tsu", triggers = { { trigger = { type = "custom", custom_type = "stateupdate",
        events = "MY_EVENT",
        custom = "function(allstates, event, what) if what == 'add' then allstates.a = { show = true, changed = true, name = 'Clone A', stacks = 2, duration = 3, expirationTime = GetTime() + 3, autoHide = true } end return true end" } } } },
    { id = "watch", triggers = {
        { trigger = { spellID = 774 } },
        { trigger = { type = "custom", events = "TRIGGER:1",
          custom = "function(event, n, other) HEARD = event .. ' ' .. tostring(n) .. ' ' .. tostring(other.met) return other.met end" } },
        disjunctive = "any", activeTriggerMode = 2 } },
    { id = "cleu", triggers = { { trigger = { type = "custom", events = "CLEU:SPELL_DAMAGE",
        custom = "function() return true end" } } } },
} } } }
WANT_ON, TICK_ON = false, false
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("a status trigger gets an answer straight away", ev("ns.Engine.states.st.shown") is False)
L.execute("WANT_ON = true FireEvent('PLAYER_TARGET_CHANGED') ns.Engine:UpdateAll()")
check("and runs again on its events", ev("ns.Engine.states.st.shown") is True)
check("its name, stacks and timer come from its own functions",
      ev("ns.Engine.states.st.name") == "Named by code" and ev("ns.Engine.states.st.count") == 3
      and ev("ns.Engine.states.st.duration") == 10)
L.execute("WANT_ON = false FireEvent('UNIT_POWER_UPDATE', 'target') ns.Engine:UpdateAll()")
check("a unit filter lets another unit's event pass it by", ev("ns.Engine.states.st.shown") is True)
L.execute("FireEvent('UNIT_POWER_UPDATE', 'player') ns.Engine:UpdateAll()")
check("and its own unit's through", ev("ns.Engine.states.st.shown") is False)
check("aura_env carries between calls", (ev("ns.Env:For(ns.FindAura('st')).calls") or 0) >= 3)

L.execute("TICK_ON = true ns.Engine:UpdateAll()")
check("every update: runs each sweep, no event needed", ev("ns.Engine.states.up.shown") is True)

L.execute("WeakAuras.ScanEvents('MY_EVENT', 'go') ns.Engine:UpdateAll()")
check("an event trigger fires on a custom event from WeakAuras.ScanEvents",
      ev("ns.Engine.states.ev.shown") is True and ev("ns.Engine.states.ev.duration") == 5)
L.execute("NOW = NOW + 6 ns.Engine:UpdateAll()")
check("and hides when its duration runs out", ev("ns.Engine.states.ev.shown") is False)
check("one with a custom hide stays until its untrigger says so",
      ev("ns.Engine.states.evc.shown") is True)
L.execute("WeakAuras.ScanEvents('MY_EVENT', 'stop') ns.Engine:UpdateAll()")
check("and goes when it does", ev("ns.Engine.states.evc.shown") is False)

L.execute("WeakAuras.ScanEvents('MY_EVENT', 'add') ns.Engine:UpdateAll()")
check("a state updater shows the states it fills in",
      ev("ns.Engine.states.tsu.shown") is True and ev("ns.Engine.states.tsu.name") == "Clone A"
      and ev("ns.Engine.states.tsu.count") == 2)
L.execute("NOW = NOW + 4 ns.Engine:UpdateAll()")
check("and one set to autoHide goes when it expires", ev("ns.Engine.states.tsu.shown") is False)

L.execute("AURAS.player = { { name = 'Rejuvenation', spellId = 774 } } ns.Engine:UpdateAll() ns.Engine:UpdateAll()")
check("TRIGGER:1 hears when trigger 1 changes", ev("HEARD") == "TRIGGER 1 true", str(ev("HEARD")))
check("and can decide from it", ev("ns.Engine.states.watch.shown") is True)

check("a combat log trigger says the combat log does not exist here",
      "combat log" in str(ev("ns.Engine.states.cleu.triggers[1].error")))
check("the WeakAuras global is there for code that expects it",
      ev("WeakAuras.IsChairAuras") is True and ev("WeakAuras.GetData('st').id") == "st")

# --- imported code waits for approval ----------------------------------------
print("-- imported custom code")
L.execute("""
local source = { id = "x", name = "Imported",
    triggers = { { trigger = { type = "custom", check = "update", custom = "function() RAN = true return true end" } } } }
table.insert(ns.GetProfile().auras, source)
EXPORTED = ns.Share:Export(source)
table.remove(ns.GetProfile().auras)
IMPORTED = ns.Share:Import(EXPORTED)
RAN = false
ns.Engine:UpdateAll()
""")
check("an imported aura with custom Lua comes in unapproved", ev("IMPORTED[1].untrusted") is True)
check("and its code does not run", ev("RAN") is False)
L.execute("PRINTED = {} SlashCmdList['CHAIRAURAS']('trust ' .. #ns.GetAuras())")
check("trust <n> shows the code first", ev("IMPORTED[1].untrusted") is True)
L.execute("SlashCmdList['CHAIRAURAS']('trust ' .. #ns.GetAuras() .. ' yes') ns.Engine:UpdateAll()")
check("trust <n> yes lets it run", ev("IMPORTED[1].untrusted") is None and ev("RAN") is True)

# --- the custom trigger in the window ----------------------------------------
print("-- custom triggers in the window")
L.execute("ns.Config:Open(); ns.Config:Select('st'); ns.Config:SetTab('trigger')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the kind, events and code boxes are there for a custom trigger",
      ev("FIND_WIDGET('custom_type', 'choice') ~= nil and FIND_WIDGET('events', 'text') ~= nil"
         " and FIND_WIDGET('custom', 'code') ~= nil") is True)
L.execute("FIND_WIDGET('custom', 'code').field.set(ns.FindAura('st'), 'function() return ( end') ns.Config:Refresh()")
check("a compile error shows under the trigger box",
      "|cffff5555" in str(ev("FIND_WIDGET('custom', 'code').status._text")))


# --- the built-in trigger types ----------------------------------------------
print("-- built-in trigger types")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "use", triggers = { { trigger = { type = "usable", spellID = 1 } } } },
    { id = "kno", triggers = { { trigger = { type = "known", spellID = 2 } } } },
    { id = "rng", triggers = { { trigger = { type = "range", spellID = 1 } } } },
    { id = "ur", triggers = { { trigger = { type = "usable", spellID = 1, inRange = true } } } },
    { id = "tgt", triggers = { { trigger = { type = "target", attackable = true, alive = true, spellID = 1 } } } },
    { id = "dst", triggers = { { trigger = { type = "target", minYards = 8, maxYards = 25 } } } },
    { id = "ovp", triggers = { { trigger = { type = "dodged", duration = 5, spellID = 7384 } } } },
    { id = "par", triggers = { { trigger = { type = "parried" } } } },
    { id = "old", triggers = { { trigger = { type = "avoided", avoid = "BLOCK" } } } },
    { id = "rev", triggers = { { trigger = { type = "selfblocked" } } } },
    { id = "glw", triggers = { { trigger = { type = "glow", spellID = 7384 } } } },
    { id = "chg", triggers = { { trigger = { type = "charges", spellID = 1, charges = 2 } } } },
    { id = "cst", triggers = { { trigger = { type = "cast", spellID = 5, duration = 4 } } } },
    { id = "icd", triggers = { { trigger = { type = "itemcooldown", itemID = 6948 } } } },
    { id = "scd", triggers = { { trigger = { type = "slotcooldown", slot = 13 } } } },
    { id = "cnt", triggers = { { trigger = { type = "itemcount", itemID = 6265, count = 3 } } } },
    { id = "eqp", triggers = { { trigger = { type = "equipped", itemID = 777 } } } },
    { id = "enc", triggers = { { trigger = { type = "enchant" } } } },
    { id = "frm", triggers = { { trigger = { type = "form", spellID = 5487 } } } },
    { id = "nof", triggers = { { trigger = { type = "form" } } } },
    { id = "thr", triggers = { { trigger = { type = "threat", threat = 80 } } } },
    { id = "xpt", triggers = { { trigger = { type = "xp", xp = 50 } } } },
    { id = "gld", triggers = { { trigger = { type = "money", gold = 10 } } } },
    { id = "sts", triggers = { { trigger = { type = "status", status = "mounted" } } } },
    { id = "zon", triggers = { { trigger = { type = "zone", zoneName = "goldshire" } } } },
    { id = "cht", triggers = { { trigger = { type = "chat", chatChannel = "party", message = "pull" } } } },
    { id = "rdy", triggers = { { trigger = { type = "readycheck" } } } },
    { id = "hp", type = "bar", triggers = { { trigger = { type = "health", unit = "player" } } } },
} } } }
USABLE, INRANGE, KNOWN, CHARGES = true, true, false, 1
C_Spell.IsSpellUsable = function(id) return USABLE, false end
-- A warrior's spellbook, for the distance band: Charge 8-25, Shoot 8-30,
-- a melee strike 0-5. DIST is how far the target really is.
DIST = 15
RANGES = { [100] = { 8, 25 }, [101] = { 8, 30 }, [102] = { 0, 5 } }
SPELLS[100] = { name = "Charge", icon = 200 }
SPELLS[101] = { name = "Shoot", icon = 201 }
SPELLS[102] = { name = "Heroic Strike", icon = 202 }
SPELLS[7384] = { name = "Overpower", icon = 203 }
SPELLS[7887] = { name = "Overpower", icon = 203 }   -- rank 2
function GetNumSpellTabs() return 1 end
function GetSpellTabInfo() return "General", nil, 0, 3 end
function GetSpellBookItemInfo(i) return "SPELL", 99 + i end
local byName = C_Spell.GetSpellInfo
C_Spell.GetSpellInfo = function(id)
    local r = RANGES[id]
    if r then return { spellID = id, name = SPELLS[id].name, minRange = r[1], maxRange = r[2] } end
    return byName(id)
end
C_Spell.IsSpellInRange = function(id, unit)
    if not HAS_TARGET then return nil end
    local r = RANGES[id]
    if r then return DIST >= r[1] and DIST <= r[2] end
    return INRANGE
end
INTERACT_YARDS = { [3] = 9.9, [2] = 11.11, [4] = 28 }
function CheckInteractDistance(unit, i) return HAS_TARGET and DIST <= INTERACT_YARDS[i] end
COMBAT = false
function InCombatLockdown() return COMBAT end
HAS_TARGET, ENEMY, TARGET_DEAD = true, true, false
function UnitExists(unit) if unit == "target" then return HAS_TARGET end return true end
function UnitCanAttack() return HAS_TARGET and ENEMY end
function UnitIsDeadOrGhost(unit) if unit == "target" then return TARGET_DEAD end return false end
C_Spell.GetSpellCharges = function(id) return { currentCharges = CHARGES, maxCharges = 2, cooldownStartTime = NOW, cooldownDuration = 10 } end
function IsPlayerSpell(id) return KNOWN end
ITEMCD = { 0, 0 }
C_Item = {
    GetItemCooldown = function(id) return ITEMCD[1], ITEMCD[2], true end,
    GetItemCount = function(id) return ITEMS_HELD or 0 end,
    IsEquippedItem = function(id) return EQUIPPED end,
    GetItemNameByID = function(id) return "Item " .. id end,
    GetItemIconByID = function(id) return 1000 + id end,
}
function GetInventoryItemID(unit, slot) if slot == 13 then return 999 end if slot == 16 then return 555 end end
function GetInventoryItemCooldown(unit, slot) return TRINKET[1], TRINKET[2], 1 end
TRINKET = { 0, 0 }
function GetWeaponEnchantInfo() return ENCHANTED, 1800000, 0, 25, false end
FORM = 0
function GetShapeshiftForm() return FORM end
function GetShapeshiftFormInfo(i) return 132276, true, true, 5487 end
function UnitDetailedThreatSituation() return false, 2, THREAT end
THREAT = 50
function UnitXP() return 600 end function UnitXPMax() return 1000 end function UnitLevel() return 20 end
function GetMoney() return MONEY end MONEY = 50000
function IsMounted() return MOUNTED end
function GetRealZoneText() return "Elwynn Forest" end function GetSubZoneText() return "Goldshire" end
function UnitHealth() return SECRET_VALUE() end function UnitHealthMax() return 1000 end
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
def shown(i): return ev("ns.Engine.states.%s.shown" % i)
check("usable: usable and off cooldown", shown("use") is True)
check("usable and in range, with a target in range", shown("ur") is True)
check("target: attackable, alive and in range", shown("tgt") is True)
L.execute("TARGET_DEAD = true ns.Engine:UpdateAll()")
check("not once it is dead", shown("tgt") is False)
L.execute("TARGET_DEAD = false ENEMY = false ns.Engine:UpdateAll()")
check("nor a target you cannot attack", shown("tgt") is False)
L.execute("ENEMY = true INRANGE = false ns.Engine:UpdateAll()")
check("nor one out of range", shown("tgt") is False)
L.execute("INRANGE = true HAS_TARGET = false ns.Engine:UpdateAll()")
check("no target is not in range, for usable's range box too",
      shown("tgt") is False and shown("ur") is False)
L.execute("HAS_TARGET = true ns.Engine:UpdateAll()")
check("distance: 15 yards is between 8 and 25", shown("dst") is True)
L.execute("DIST = 5 NOW = NOW + 1 ns.Engine:UpdateAll()")
check("5 yards is too close", shown("dst") is False)
L.execute("DIST = 27 NOW = NOW + 1 ns.Engine:UpdateAll()")
check("27 yards is too far", shown("dst") is False)
L.execute("DIST = 15 COMBAT = true NOW = NOW + 1 ns.Engine:UpdateAll()")
check("in combat it goes by the spells alone, without the interact distances",
      shown("dst") is True)
L.execute("COMBAT = false NOW = NOW + 1 ns.Engine:UpdateAll()")

check("overpower: nothing dodged yet", shown("ovp") is False)
L.execute("FireEvent('UNIT_COMBAT', 'target', 'WOUND', '', 50, 1) ns.Engine:UpdateAll()")
check("a hit is not a dodge", shown("ovp") is False)
check("an aura saved with the old combined trigger becomes the matching new one",
      ev("ns.GetAuras()[" + str(0) + "+1]") is not None
      and ev("(function() for _, a in ipairs(ns.GetAuras()) do if a.id == 'old' then"
             " return a.triggers[1].trigger.type end end end)()") == "blocked")
L.execute("FireEvent('UNIT_COMBAT', 'target', 'PARRY', '', 0, 1) ns.Engine:UpdateAll()")
check("a parry brings up the parry trigger, not the dodge one",
      shown("par") is True and shown("ovp") is False)
L.execute("FireEvent('UNIT_COMBAT', 'target', 'DODGE', '', 0, 1) ns.Engine:UpdateAll()")
check("the target dodging you brings it up, wearing Overpower, on a 5 second timer",
      shown("ovp") is True and ev("ns.Engine.states.ovp.duration") == 5
      and ev("ns.Engine.states.ovp.name") == "Overpower")
L.execute("NOW = NOW + 6 ns.Engine:UpdateAll()")
check("and it goes when the window runs out", shown("ovp") is False)
L.execute("FireEvent('CHAT_MSG_COMBAT_SELF_MISSES', 'You attack. Kobold Miner dodges.') ns.Engine:UpdateAll()")
check("the old chat line for a dodge brings it up too", shown("ovp") is True)
L.execute("NOW = NOW + 1 ns.Engine.lastCast[7887] = NOW ns.Engine:UpdateAll()")
check("casting Overpower, any rank, drops it", shown("ovp") is False)
L.execute("NOW = NOW + 1 FireEvent('CHAT_MSG_SPELL_SELF_DAMAGE', 'Your Heroic Strike was dodged by Kobold Miner.')"
          " ns.Engine:UpdateAll()")
check("a dodged special counts, and an older cast does not end the new window",
      shown("ovp") is True)
check("a partly blocked hit is not a block",
      ev("ns.AvoidFromChat('you hit kobold for 30. (12 blocked)')") is None
      and ev("ns.AvoidFromChat('kobold blocks your attack.')") == "BLOCK")
L.execute("FireEvent('UNIT_COMBAT', 'target', SECRET_VALUE(), '', 0, 1)")
check("the target blocking is not you blocking", shown("rev") is False)
L.execute("FireEvent('UNIT_COMBAT', 'player', 'WOUND', 'BLOCK', 40, 1) ns.Engine:UpdateAll()")
check("a partial block on you counts as you blocking", shown("rev") is True)
check("spell glows: not lit", shown("glw") is False)
L.execute("FireEvent('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW', 7887) ns.Engine:UpdateAll()")
check("the game lighting up any rank of it brings it up", shown("glw") is True)
L.execute("FireEvent('SPELL_ACTIVATION_OVERLAY_GLOW_HIDE', 7887) ns.Engine:UpdateAll()")
check("and the glow going takes it down", shown("glw") is False)
log = " | ".join(str(v) for v in ev("ChairAurasDB.probe.procs").values())
check("each one heard is logged, a secret one as secret",
      "target DODGE, heard from UNIT_COMBAT" in log
      and "target DODGE, heard from CHAT_MSG_COMBAT_SELF_MISSES" in log
      and "you BLOCK, heard from UNIT_COMBAT (partial)" in log
      and "button glow on: overpower" in log and "action SECRET" in log, log)
L.execute("USABLE = false ns.Engine:UpdateAll()")
check("and not when it is not", shown("use") is False)
check("spell known: not known", shown("kno") is False)
L.execute("KNOWN = true ns.Engine:UpdateAll()")
check("and known", shown("kno") is True)
check("in range", shown("rng") is True)
L.execute("INRANGE = false ns.Engine:UpdateAll()")
check("and out of it", shown("rng") is False)
check("charges: one is not the two asked for", shown("chg") is False and ev("ns.Engine.states.chg.count") == 1)
L.execute("CHARGES = 2 ns.Engine:UpdateAll()")
check("two is", shown("chg") is True)
check("your cast: nothing cast yet", shown("cst") is False)
L.execute("ns.Engine.lastCast[5] = NOW ns.Engine:UpdateAll()")
check("shows for a while after you cast it", shown("cst") is True and ev("ns.Engine.states.cst.duration") == 4)
L.execute("NOW = NOW + 5 ns.Engine:UpdateAll()")
check("then goes", shown("cst") is False)
check("item cooldown: ready", shown("icd") is True)
L.execute("ITEMCD = { NOW - 10, 3600 } ns.Engine:UpdateAll()")
check("and not while cooling down, with its timer",
      shown("icd") is False and ev("ns.Engine.states.icd.duration") == 3600)
check("and wears the item's name", ev("ns.Engine.states.icd.name") == "Item 6948")
check("slot cooldown: the trinket is ready", shown("scd") is True)
L.execute("TRINKET = { NOW, 120 } ns.Engine:UpdateAll()")
check("and on cooldown", shown("scd") is False)
check("item count: none carried", shown("cnt") is False)
L.execute("ITEMS_HELD = 5 ns.Engine:UpdateAll()")
check("five of three wanted", shown("cnt") is True and ev("ns.Engine.states.cnt.count") == 5)
L.execute("EQUIPPED = true ns.Engine:UpdateAll()")
check("item equipped", shown("eqp") is True)
L.execute("ENCHANTED = true ns.Engine:UpdateAll()")
check("weapon enchant: on, with its time left", shown("enc") is True
      and ev("ns.Engine.states.enc.duration") == 1800)
check("form: not in bear form", shown("frm") is False and shown("nof") is True)
L.execute("FORM = 1 ns.Engine:UpdateAll()")
check("in bear form", shown("frm") is True and shown("nof") is False)
check("threat: 50 is under 80", shown("thr") is False)
L.execute("THREAT = 95 ns.Engine:UpdateAll()")
check("95 is over", shown("thr") is True)
check("experience: 60% is over 50", shown("xpt") is True)
check("money: 5 gold is under 10", shown("gld") is False)
L.execute("MONEY = 200000 ns.Engine:UpdateAll()")
check("20 is over", shown("gld") is True)
L.execute("MOUNTED = true ns.Engine:UpdateAll()")
check("status: mounted", shown("sts") is True)
check("zone: the subzone matches", shown("zon") is True)
L.execute("for _, f in ipairs(EVENT_FRAMES) do if f._events.CHAT_MSG_PARTY then f._scripts.OnEvent(f, 'CHAT_MSG_PARTY', 'ok PULL now', 'Tank') end end ns.Engine:UpdateAll()")
check("chat: a party message containing the words", shown("cht") is True and ev("ns.Engine.states.cht.name") == "Tank")
L.execute("FireEvent('READY_CHECK') ns.Engine:UpdateAll()")
check("ready check", shown("rdy") is True)
check("health: met while the unit exists, carrying a live value for the bar",
      shown("hp") is True and ev("ns.Engine.states.hp.live.kind") == "health")
check("and the bar is handed the secret value to draw",
      ev("ns.DrawLive(ns.Display.__regions.hp.bar, ns.Engine.states.hp.live)") is True)

print("-- built-in trigger types in the window")
L.execute("ns.Config:Open(); ns.Config:Select('icd'); ns.Config:SetTab('trigger')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the picker lists the built-in types",
      ev("""(function() for _, f in ipairs(ns.Config.__triggerFields) do
          if f.key == 'type' then return #f.values end end end)()""") >= 20)
check("an item trigger shows its item box",
      ev("FIND_WIDGET('itemID', 'item').host:IsShown()") is True)
check("and not the aura trigger's settings",
      ev("FIND_WIDGET('match', 'choice').host:IsShown()") is False)
L.execute("FIND_WIDGET('itemID', 'item').field.set(ns.FindAura('icd'), '6265')")
check("an item is set by ID", ev("ns.Trigger((ns.FindAura('icd'))).itemID") == 6265)
L.execute("ns.Config:Select('thr')")
check("switching to a threat trigger shows its settings instead",
      ev("FIND_WIDGET('threat', 'slider').host:IsShown()") is True
      and ev("FIND_WIDGET('itemID', 'item').host:IsShown()") is False)


print("-- the trigger type dropdown")
L.execute("ns.Config:Select('icd')")
check("the type picker is a dropdown", ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown ~= nil") is True)
check("naming the type in use", ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.button:GetText()") == "Item cooldown",
      str(ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.button:GetText()")))
L.execute("local d = FIND_WIDGET('type', 'choice', 'trigger').dropdown d.button._scripts.OnClick(d.button)")
check("clicking it opens the list", ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.menu:IsShown()") is True)
L.execute("local d = FIND_WIDGET('type', 'choice', 'trigger').dropdown"
          " for _ = 1, 10 do d.menu._scripts.OnMouseWheel(d.menu, 1) end")
check("grouped under headings",
      "Auras" in str(ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.rows[1].text._text")),
      str(ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.rows[1].text._text")))
L.execute("local d = FIND_WIDGET('type', 'choice', 'trigger').dropdown d.rows[1]._scripts.OnClick(d.rows[1])")
check("a heading cannot be picked", ev("ns.TriggerField((ns.FindAura('icd')), 'type')") == "itemcooldown")
L.execute("""local d = FIND_WIDGET('type', 'choice', 'trigger').dropdown
for _ = 1, 10 do
    local hit
    for _, row in ipairs(d.rows) do if row.value == 'threat' then hit = row break end end
    if hit then hit._scripts.OnClick(hit) break end
    d.menu._scripts.OnMouseWheel(d.menu, -1)
end""")
check("picking a type from the list sets it, and closes the list",
      ev("ns.TriggerField((ns.FindAura('icd')), 'type')") == "threat"
      and ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.menu:IsShown()") is False)
check("the button then names it", ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.button:GetText()") == "Threat")
L.execute("local d = FIND_WIDGET('type', 'choice', 'trigger').dropdown for i = 1, 5 do d.menu._scripts.OnMouseWheel(d.menu, -1) end")
check("a long list scrolls", ev("FIND_WIDGET('type', 'choice', 'trigger').dropdown.offset") > 0)


# --- text codes ----------------------------------------------------------------
print("-- text codes")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "tx", type = "text", triggers = {
        { trigger = { spellID = 774 } },
        { trigger = { spellID = 8936 } },
        disjunctive = "any" },
      display = { customText = "function() return 'first', 'second' end" } },
} } } }
SPELLS[774] = { name = "Rejuvenation", icon = 100 }
SPELLS[8936] = { name = "Regrowth", icon = 200 }
""")
ev = L.eval
L.execute("""AURAS.player = {
    { name = 'Rejuvenation', spellId = 774, icon = 100, applications = 3, duration = 12, expirationTime = NOW + 9 },
    { name = 'Regrowth', spellId = 8936, icon = 200, duration = 20, expirationTime = NOW + 5 } }
ns.Engine:UpdateAll()""")
def say(fmt):
    return ev("ns.Engine:FormatText(%r, ns.FindAura('tx'), ns.Engine.states.tx)" % fmt)
check("ChairAuras codes as before: %n %s %t %d %p",
      say("%n %s %t %d %p%%") == "Rejuvenation 3 9.0 12 75%", say("%n %s %t %d %p%%"))
check("%i draws the icon", say("%i") == "|T100:0|t", say("%i"))
check("%c is the custom text, %c2 its second value", say("%c/%c2") == "first/second", say("%c/%c2"))
check("%stacks and %{name} read the trigger's state", say("%stacks %{name}") == "3 Rejuvenation",
      say("%stacks %{name}"))
check("%2.n and %2.t read trigger 2", say("%2.n %2.t") == "Regrowth 5.0", say("%2.n %2.t"))
check("%{2.p} with braces", say("%{2.p}") == "25", say("%{2.p}"))
check("an unknown letter is left as typed", say("100%x") == "100%x", say("100%x"))
L.execute("ns.FindAura('tx').display.textStyle = 'weakauras'")
check("WeakAuras codes: %p is time left, %t the full duration", say("%p / %t") == "9.0 / 12", say("%p / %t"))
L.execute("ns.FindAura('tx').display.textStyle = nil ns.FindAura('tx').display.timeFormat = 'clock'")
check("time as a clock", say("%t") == "0:09", say("%t"))
L.execute("ns.FindAura('tx').display.timeFormat = 'seconds' ns.FindAura('tx').display.timePrecision = 2")
check("or seconds, to two places", say("%t") == "9.00", say("%t"))

# --- each text styled on its own ---------------------------------------------
print("-- text styling")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "ic", triggers = { { trigger = { spellID = 774 } } },
      display = { iconText = "%t", iconTextFont = "Fonts\\\\MORPHEUS.TTF", iconTextSize = 20,
                  iconTextOutline = "THICKOUTLINE", iconTextColour = "ff0000" } },
    { id = "tt", type = "text", triggers = { { trigger = { spellID = 774 } } },
      display = { textFont = "Fonts\\\\ARIALN.TTF", fontSize = 18, textColour = "00ff00", textOutline = "NONE" } },
    { id = "bb", type = "bar", triggers = { { trigger = { spellID = 774 } } },
      display = { barFont = "Fonts\\\\SKURRI.TTF", barFontSize = 14, barTextColour = "0000ff" } },
} } } }
""")
ev = L.eval
L.execute("""
FONTS_SET = {}
local originalCreate = CreateFrame
AURAS.player = { { name = 'Rejuvenation', spellId = 774, duration = 12, expirationTime = NOW + 9 } }
ns.Engine:UpdateAll()""")
def font(fs):
    return ev("DUMP({ %s:GetFont() })" % fs)
check("icon text: its own font, size and outline",
      "MORPHEUS" in str(font("ns.Display.__regions.ic.overlay")) and "20" in str(font("ns.Display.__regions.ic.overlay"))
      and "THICKOUTLINE" in str(font("ns.Display.__regions.ic.overlay")), str(font("ns.Display.__regions.ic.overlay")))
check("and its own color", ev("ns.Display.__regions.ic.overlay._colour and ns.Display.__regions.ic.overlay._colour[1]") == 1)
check("text aura: its own font and size", "ARIALN" in str(font("ns.Display.__regions.tt.text"))
      and "18" in str(font("ns.Display.__regions.tt.text")), str(font("ns.Display.__regions.tt.text")))
check("bar text: its own font and size", "SKURRI" in str(font("ns.Display.__regions.bb.text"))
      and "14" in str(font("ns.Display.__regions.bb.text")), str(font("ns.Display.__regions.bb.text")))


# --- reordering and regrouping by dragging --------------------------------------
print("-- dragging auras in the list")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "g1", type = "dynamic", name = "Group" },
    { id = "a1", parent = "g1", name = "One" },
    { id = "a2", parent = "g1", name = "Two" },
    { id = "a3", name = "Three" },
    { id = "a4", name = "Four" },
} } } }
""")
ev = L.eval
def order():
    return ev("""(function() local out = {} for _, a in ipairs(ns.GetAuras()) do
        out[#out + 1] = a.id .. ':' .. tostring(a.parent) end return table.concat(out, ' ') end)()""")
L.execute("ns.MoveAura((ns.FindAura('a3')), (ns.FindAura('a4')), 'after')")
check("after: it lands just below the target", order().index("a4:nil") < order().index("a3:nil"), order())
L.execute("ns.MoveAura((ns.FindAura('a1')), (ns.FindAura('a4')), 'before')")
check("before a row outside the group takes it out of the group",
      "a1:nil" in order() and order().index("a1:nil") < order().index("a4:nil"), order())
L.execute("ns.MoveAura((ns.FindAura('a3')), (ns.FindAura('a2')), 'after')")
check("after a row inside a group puts it in that group", "a3:g1" in order(), order())
L.execute("ns.MoveAura((ns.FindAura('a4')), (ns.FindAura('g1')), 'inside')")
check("inside a group, at its end", "a4:g1" in order(), order())
L.execute("ns.MoveAuraToEnd((ns.FindAura('a2')))")
check("dropped below the list: the end, outside every group", order().endswith("a2:nil"), order())

L.execute("ns.Config:Open()")
L.execute("""
local rows = {}
for _, row in pairs(ns.Config.__rows or {}) do rows[#rows + 1] = row end
""")
check("the list has a drop marker and a corner grip",
      ev("ns.Config.dropLine ~= nil and ChairAurasConfig.grip ~= nil") is True)
L.execute("""
function AT(y) GetCursorPosition = function() return 10, y end end
UIParent.GetEffectiveScale = function() return 1 end
for i, row in ipairs(ns.Config.__rowList()) do
    local top = 500 - (i - 1) * 24
    rawset(row, "GetTop", function() return top end)
    rawset(row, "GetBottom", function() return top - 24 end)
end
""")
def under(y):
    L.execute("AT(%d)" % y)
    return ev("(function() local id, where = ns.Config:RowUnderCursor() return tostring(id) .. ' ' .. tostring(where) end)()")
first = ev("ns.Config.__rowList()[1].auraID")
check("the top of a row drops above it", under(498) == first + " before", under(498))
check("the bottom of a row drops below it", under(478) == first + " after", under(478))
check("the middle of a group drops inside it", under(488) == first + " inside", under(488))
check("below the last row drops at the end", under(100) == "END end", under(100))

L.execute("""local grip = ChairAurasConfig.grip
rawset(ChairAurasConfig, "GetWidth", function() return 900 end)
rawset(ChairAurasConfig, "GetHeight", function() return 820 end)
grip._scripts.OnMouseDown(grip) grip._scripts.OnMouseUp(grip)""")
check("resizing from the corner is remembered",
      ev("ChairAurasDB.window.w") == 900 and ev("ChairAurasDB.window.h") == 820)

# Inside the Chaircraft menu the grip sizes the menu, not the window, which
# would otherwise pull loose from the menu's background (2026-09-26).
L.execute("""
SIZED = {}
HOST = CreateFrame("Frame", "FakeMenu", UIParent)
rawset(HOST, "StartSizing", function(self) SIZED[#SIZED + 1] = "host" end)
rawset(ChairAurasConfig, "StartSizing", function(self) SIZED[#SIZED + 1] = "window" end)
ChairAurasConfig:SetParent(HOST)
ChairAurasConfig.chairEmbedded = true
rawset(ChairAurasConfig, "GetWidth", function() return 1000 end)
rawset(ChairAurasConfig, "GetHeight", function() return 760 end)
local grip = ChairAurasConfig.grip
grip._scripts.OnMouseDown(grip) grip._scripts.OnMouseUp(grip)
""")
check("inside the menu, the grip sizes the menu", ev("SIZED[1]") == "host" and ev("#SIZED") == 1)
check("and the window's new size is still remembered",
      ev("ChairAurasDB.window.w") == 1000 and ev("ChairAurasDB.window.h") == 760)
L.execute("SIZED = {} ChairAurasConfig.chairEmbedded = nil ChairAurasConfig:SetParent(UIParent)"
          " local grip = ChairAurasConfig.grip grip._scripts.OnMouseDown(grip) grip._scripts.OnMouseUp(grip)")
check("on its own, it sizes the window", ev("SIZED[1]") == "window")


# --- the spell you cast, the buff it gives ------------------------------------
print("-- a spell and the buff it gives")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "pr", triggers = { { trigger = { spellID = 1259918, stacks = 2 } } },
      display = { iconText = "%s" } },
    { id = "inv", triggers = { { trigger = { spellID = 1259918 } } },
      display = { iconText = "%s", invert = true } },
} } } }
SPELLS[1259918] = { name = "Plainsrunning", icon = 1 }
""")
ev = L.eval
L.execute("AURAS.player = { { name = 'Plainsrunning', spellId = 1299038, applications = 2 } } ns.Engine:UpdateAll()")
check("a buff with a different ID but the chosen spell's name is found",
      ev("ns.Engine.states.pr.shown") is True)
check("its stacks read into %s", ev("ns.Display.__regions.pr.overlay._text") == "2",
      str(ev("ns.Display.__regions.pr.overlay._text")))
L.execute("AURAS.player = { { name = 'Plainsrunning', spellId = 1299038, applications = 1 } } ns.Engine:UpdateAll()")
check("and the stack setting is used: one is not the two asked for", ev("ns.Engine.states.pr.shown") is False)
L.execute("AURAS.player = { { name = 'Something Else', spellId = 1299038, applications = 5 } } ns.Engine:UpdateAll()")
check("a different buff is still a different buff", ev("ns.Engine.states.pr.shown") is False)

L.execute("ns.Config:Open(); ns.Config:Select('inv'); ns.Config:SetTab('display')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("an aura set to show when missing warns that %s will be empty",
      ev("FIND_WIDGET('iconTextInvertNote', 'note').host:IsShown()") is True)
L.execute("ns.Config:Select('pr')")
check("and one that is not, does not",
      ev("FIND_WIDGET('iconTextInvertNote', 'note').host:IsShown()") is False)


# --- one reader for every aura value -------------------------------------------
print("-- every aura value read the same way")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "alt", triggers = { { trigger = { spellID = 42 } } }, display = { iconText = "%s %n" } },
} } } }
""")
ev = L.eval
L.execute("""AURAS.player = { { spellName = 'Renamed Field', spellID = 42, stackCount = 4,
    iconFileID = 777, duration = 10, expires = NOW + 6 } }
ns.Engine:UpdateAll()""")
check("a client that names its fields differently is still read, every field alike",
      ev("ns.Engine.states.alt.shown") is True and ev("ns.Engine.states.alt.count") == 4
      and ev("ns.Engine.states.alt.icon") == 777 and ev("ns.Engine.states.alt.duration") == 10,
      str(ev("DUMP(ns.Engine.states.alt.triggers[1])")))
check("and says which field answered", ev("select(2, ns.AuraField(AURAS.player[1], 'stacks'))") == "stackCount")
L.execute("AURAS.player = { { name = 'X', spellId = 42, applications = SECRET_VALUE() } } ns.Engine:UpdateAll()")
check("a hidden value is unknown, not zero", ev("ns.Engine.states.alt.count") is None)


# --- actions ---------------------------------------------------------------------
print("-- actions")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "ac", triggers = { { trigger = { spellID = 774 } } },
      actions = {
        onShowMessage = "%n is up", onShowCode = "function() SHOWN = (SHOWN or 0) + 1 end",
        onHideMessage = "%n is gone", onHideCode = "function() HIDDEN = (HIDDEN or 0) + 1 end",
        initCode = "function() INITS = (INITS or 0) + 1 end",
        loadCode = "function() LOADS = (LOADS or 0) + 1 end",
        unloadCode = "function() UNLOADS = (UNLOADS or 0) + 1 end",
        glowFrame = "target" } },
    { id = "btn", triggers = { { trigger = { spellID = 774 } } },
      actions = { glowFrame = "button" } },
} } } }
SPELLS[774] = { name = "Rejuvenation", icon = 100 }
TargetFrame = CreateFrame("Frame", "TargetFrame", UIParent)
ActionButton3 = CreateFrame("Button", "ActionButton3", UIParent)
ActionButton3.action = 3
ActionButton4 = CreateFrame("Button", "ActionButton4", UIParent)
ActionButton4.action = 4
function GetActionInfo(slot) if slot == 3 then return "spell", 774 end if slot == 4 then return "spell", 1 end end
""")
ev = L.eval
L.execute("PRINTED = {} ns.Engine:UpdateAll() ns.Display:Refresh(ns.Engine.states)")
check("on init and on load run as it first loads", ev("INITS") == 1 and ev("LOADS") == 1)
L.execute("AURAS.player = { { name = 'Rejuvenation', spellId = 774 } } ns.Engine:UpdateAll() ns.Display:Refresh(ns.Engine.states)")
said = " ".join(str(v) for v in (ev("PRINTED") or {}).values())
check("on show: its chat message, with text codes", "Rejuvenation is up" in said, said)
check("and its custom code", ev("SHOWN") == 1)
check("a frame glows while it shows", ev("#ns.Actions:GlowingFor(ns.FindAura('ac'))") == 1
      and ev("ns.Actions:GlowingFor(ns.FindAura('ac'))[1] == TargetFrame") is True)
check("the action button carrying the spell glows, and only that one",
      ev("#ns.Actions:GlowingFor(ns.FindAura('btn'))") == 1
      and ev("ns.Actions:GlowingFor(ns.FindAura('btn'))[1] == ActionButton3") is True)
L.execute("AURAS.player = {} ns.Engine:UpdateAll() ns.Display:Refresh(ns.Engine.states)")
said = " ".join(str(v) for v in (ev("PRINTED") or {}).values())
check("on hide: its message and code", "Rejuvenation is gone" in said and ev("HIDDEN") == 1, said)
check("and the glow goes", ev("#ns.Actions:GlowingFor(ns.FindAura('ac'))") == 0)
L.execute("ns.FindAura('ac').load = { never = true } ns.Engine:UpdateAll() ns.Display:Refresh(ns.Engine.states)")
check("on unload runs as its load conditions stop holding", ev("UNLOADS") == 1)
L.execute("ns.FindAura('ac').load = nil ns.Engine:UpdateAll() ns.Display:Refresh(ns.Engine.states)")
check("on load again as they hold again, but init only the once", ev("LOADS") == 2 and ev("INITS") == 1)

print("-- actions in the window")
L.execute("ns.Config:Open(); ns.Config:Select('ac'); ns.Config:SetTab('actions')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the Actions tab has a message, code and a glow for each moment",
      ev("FIND_WIDGET('onShowMessage', 'text', 'actions') ~= nil and FIND_WIDGET('onHideCode', 'code', 'actions') ~= nil"
         " and FIND_WIDGET('glowFrame', 'choice', 'actions') ~= nil and FIND_WIDGET('initCode', 'code', 'actions') ~= nil") is True)
L.execute("FIND_WIDGET('glowFrame', 'choice', 'actions').dropdown:Pick('name')")
check("a frame can be glowed by name", ev("FIND_WIDGET('glowFrameName', 'text', 'actions').host:IsShown()") is True)

# --- the client probe --------------------------------------------------------
print("-- /chair auras probe")
L = boot("ChairAurasDB = { version = 2, profiles = {} }")
ev = L.eval
L.execute('SlashCmdList["CHAIRAURAS"]("probe")')
L.execute('FireEvent("UNIT_AURA", "player")')
L.execute('SlashCmdList["CHAIRAURAS"]("probe")')
check("the probe keeps its answers in the saved file",
      ev("type(ChairAurasDB.probe) == 'table' and type(ChairAurasDB.probe.runs.calm.results) == 'table'") is True)
check("it can tell custom Lua would work where loadstring and setfenv do",
      ev("ChairAurasDB.probe.runs.calm.results['lua: loadstring']") == "yes"
      and ev("ChairAurasDB.probe.runs.calm.results['lua: setfenv']") == "yes",
      str(ev("ChairAurasDB.probe.runs.calm.results['lua: setfenv']")))
check("a missing call is reported as missing, not as an error",
      ev("ChairAurasDB.probe.runs.calm.results['world: CombatLogGetCurrentEventInfo']") == "missing",
      str(ev("ChairAurasDB.probe.runs.calm.results['world: CombatLogGetCurrentEventInfo']")))
check("and a secret value is named as secret",
      (lambda r: r is not None and "secret" in r)(
          L.execute("UnitHealth = function() return SECRET_VALUE() end") or
          ev("ns.Probe:Run().results['units: UnitHealth / UnitHealthMax (player)']")),
      str(ev("ChairAurasDB.probe.runs.calm.results['units: UnitHealth / UnitHealthMax (player)']")))
check("events seen since the first probe are counted",
      (ev("ChairAurasDB.probe.runs.calm.events.UNIT_AURA") or "").startswith("1"),
      str(ev("ChairAurasDB.probe.runs.calm.events.UNIT_AURA")))


# --- phase 7: displays ------------------------------------------------------------
print("-- phase 7: texture, progress texture, model, sub-regions")
# Methods the harness frames would otherwise swallow, recorded on the frame.
RECORDER = """
function RECORD(obj, ...)
    for i = 1, select('#', ...) do
        local name = select(i, ...)
        rawset(obj, name, function(self, ...) rawset(self, '_' .. name, { ... }) return true end)
    end
end
"""
L = boot(RECORDER + """
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "tx", type = "texture", triggers = { { trigger = { spellID = 774 } } },
      display = { texture = "icon", textureColour = "ff0000", textureRotation = 90,
                  textureMirror = true, width = 80, height = 30 } },
    { id = "pg", type = "progress", triggers = { { trigger = { spellID = 774 } } },
      display = { progressDirection = "UP", ticks = "3, 5", width = 20, height = 100 } },
    { id = "pc", type = "progress", triggers = { { trigger = { spellID = 774 } } },
      display = { progressStyle = "circular" } },
    { id = "md", type = "model", triggers = { { trigger = { spellID = 774 } } },
      display = { modelSource = "display", modelID = 1234 } },
    { id = "ic", triggers = { { trigger = { spellID = 774 } } },
      display = { iconZoom = 20, border = true, borderColour = "00ff00", borderSize = 2,
                  backdrop = true, glow = true, glowType = "pixel",
                  texts = { { text = "%n!", point = "TOP", y = 5 }, { text = "%s", point = "BOTTOM" } } } },
    { id = "br", type = "bar", triggers = { { trigger = { spellID = 774 } } },
      display = { barDirection = "LEFT", barSpark = true, barInverse = true, ticks = "5" } },
} } } }
""")
ev = L.eval
L.execute("""
local R = ns.Display.__regions
RECORD(R.tx.texture, 'SetTexture', 'SetVertexColor', 'SetRotation', 'SetTexCoord')
RECORD(R.pg.bar, 'SetOrientation', 'SetReverseFill')
RECORD(R.pc.circle, 'SetCooldown', 'SetSwipeTexture')
RECORD(R.md.model, 'SetDisplayInfo')
RECORD(R.ic.texture, 'SetTexCoord')
RECORD(R.br.bar, 'SetReverseFill')
ns.Engine:UpdateAll()
""")
check("a texture aura is drawn as a texture",
      ev("ns.Display.__regions.tx.kind") == "texture")
check("its picture can be the aura's own icon", ev("ns.Display.__regions.tx.texture._SetTexture[1]") == 100)
check("colored, mirrored and turned",
      ev("ns.Display.__regions.tx.texture._SetVertexColor[1]") == 1
      and ev("ns.Display.__regions.tx.texture._SetVertexColor[2]") == 0
      and ev("ns.Display.__regions.tx.texture._SetTexCoord[1]") == 1
      and abs(ev("ns.Display.__regions.tx.texture._SetRotation[1]") - 1.5708) < 0.001)
check("with a free width and height",
      ev("(ns.Display.__regions.tx:GetSize())") == 80 and ev("select(2, ns.Display.__regions.tx:GetSize())") == 30)
check("a model loads the display ID it is given",
      ev("ns.Display.__regions.md.model._SetDisplayInfo[1]") == 1234)
check("a round progress texture with no timer is drawn whole",
      ev("ns.Display.__regions.pc.full:IsShown()") is True)

L.execute("AURAS.player = { { name = 'Rejuvenation', spellId = 774, applications = 3, duration = 10,"
          " expirationTime = NOW + 8 } } ns.Engine:UpdateAll()")
check("a progress texture fills with the time left, the way it is set to",
      abs(ev("ns.Display.__regions.pg.bar:GetValue()") - 0.8) < 0.001
      and ev("ns.Display.__regions.pg.bar._SetOrientation[1]") == "VERTICAL"
      and ev("ns.Display.__regions.pg.bar._SetReverseFill[1]") is False)
check("with a tick at each mark",
      ev("ns.Display.__regions.pg.ticksShown") == 2
      and ev("rawget(ns.Display.__regions.pg.subTicks[1], '_point').y") == 30,
      str(ev("rawget(ns.Display.__regions.pg.subTicks[1], '_point').y")))
check("round, it sweeps like a cooldown",
      ev("ns.Display.__regions.pc.circle._SetCooldown[2]") == 10
      and ev("ns.Display.__regions.pc.full:IsShown()") is False)
check("an icon can be zoomed in",
      abs(ev("ns.Display.__regions.ic.texture._SetTexCoord[1]") - 0.17) < 0.001)
check("and carries a border and a background",
      ev("ns.Display.__regions.ic.subBorder:IsShown()") is True
      and ev("ns.Display.__regions.ic.subBorder.size") == 2
      and ev("ns.Display.__regions.ic.subBackdrop:IsShown()") is True)
check("any number of texts, each with the text codes",
      ev("ns.Display.__regions.ic.subTexts[1]:GetText()") == "Rejuvenation!"
      and ev("ns.Display.__regions.ic.subTexts[2]:GetText()") == "3",
      str(ev("ns.Display.__regions.ic.subTexts[1]:GetText()")))
check("and glows while it shows, in the style picked",
      ev("ns.Display.__regions.ic.glow:IsShown()") is True
      and ev("ns.Display.__regions.ic.glow.style") == "pixel"
      and ev("#ns.Display.__regions.ic.glow.runners") == 8)
check("a bar fills either way, inverse, with a spark",
      ev("ns.Display.__regions.br.bar._SetReverseFill[1]") is True
      and abs(ev("ns.Display.__regions.br.bar:GetValue()") - 0.2) < 0.001
      and ev("ns.Display.__regions.br.spark:IsShown()") is True)
check("and its ticks follow the inverse", ev("ns.Display.__regions.br.ticksShown") == 1)
L.execute("AURAS.player = {} ns.Engine:UpdateAll()")
check("the glow goes when it stops showing", ev("ns.Display.__regions.ic.glow:IsShown()") is False)
L.execute("ns.FindAura('ic').display.texts = nil ns.Engine:UpdateAll()")
check("and removed texts go", ev("ns.Display.__regions.ic.subTexts[1]:IsShown()") is False)

print("-- phase 7: clones, rings and custom layout")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "dg", type = "dynamic", growth = "RIGHT", spacing = 0 },
    { id = "cl", parent = "dg", display = { iconText = "%s" },
      triggers = { { trigger = { type = "custom", custom_type = "stateupdate", events = "MY_EVENT",
        custom = "function(allstates, event, n) for _, st in pairs(allstates) do st.show = false end"
              .. " for i = 1, n or 0 do allstates['k' .. i] = { show = true, changed = true,"
              .. " name = 'C' .. i, stacks = i } end return true end" } } } },
    { id = "ring", type = "dynamic", growth = "CIRCLE", radius = 50 },
    { id = "r1", parent = "ring", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "r2", parent = "ring", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "r3", parent = "ring", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "r4", parent = "ring", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "cg", type = "dynamic", growth = "CUSTOM",
      growCustom = "function(p, a) for i, r in ipairs(a) do p[i] = { 0, i * 10 } end end" },
    { id = "c1", parent = "cg", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "c2", parent = "cg", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "sg", type = "dynamic", growth = "RIGHT", spacing = 0, sort = "custom",
      sortCustom = "function(a, b) return a.id > b.id end" },
    { id = "s1", parent = "sg", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
    { id = "s2", parent = "sg", triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
} } } }
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll() WeakAuras.ScanEvents('MY_EVENT', 3) ns.Engine:UpdateAll()")
check("a state updater with three states has three clones", ev("#ns.Engine.states.cl.clones") == 3)
check("each drawn in a region of its own, laid out in the group",
      ev("ns.Display.__regions['cl::k2']:IsShown()") is True
      and ev("rawget(ns.Display.__regions['cl::k2'], '_point').x") == 40
      and ev("rawget(ns.Display.__regions['cl::k3'], '_point').x") == 80,
      str(ev("rawget(ns.Display.__regions['cl::k3'], '_point') and rawget(ns.Display.__regions['cl::k3'], '_point').x")))
check("each with its own values", ev("ns.Display.__regions['cl::k3'].overlay:GetText()") == "3")
L.execute("ns.Engine:Rebuild() ns.Engine:UpdateAll() WeakAuras.ScanEvents('MY_EVENT', 3) ns.Engine:UpdateAll()")
check("they come back placed after the list is rebuilt",
      ev("ns.Display.__regions['cl::k3'] ~= nil and ns.Display.__regions['cl::k3']:IsShown()") is True
      and ev("rawget(ns.Display.__regions['cl::k3'], '_point').x") == 80)
L.execute("ns.Animations:Play(ns.Display.__regions['cl::k3'], ns.FindAura('cl'), 'main')")
L.execute("WeakAuras.ScanEvents('MY_EVENT', 1) ns.Engine:UpdateAll()")
check("and the clones go when their states do",
      ev("ns.Engine.states.cl.clones") is None
      and ev("ns.Display.ClonesOf('cl').k2:IsShown()") is False)
L.execute("ns.FindAura('cl').animation = { main = { type = 'preset', preset = 'pulse' } }"
          " WeakAuras.ScanEvents('MY_EVENT', 3) ns.Engine:UpdateAll() ns.Engine:UpdateAll()")
check("a clone animates like its aura", ev("ns.Display.__regions['cl::k3'].anim.which") == "main")
L.execute("WeakAuras.ScanEvents('MY_EVENT', 1) ns.Engine:UpdateAll()")
check("and a clone that goes stops animating", ev("ns.Animations.__running[ns.Display.ClonesOf('cl').k3]") is None)

pts = [(ev("rawget(ns.Display.__regions.r%d, '_point').x" % i),
        ev("rawget(ns.Display.__regions.r%d, '_point').y" % i)) for i in range(1, 5)]
expect = [(0, 50), (50, 0), (0, -50), (-50, 0)]
check("a ring puts them round a circle, clockwise from the top",
      all(abs(a[0] - b[0]) < 0.01 and abs(a[1] - b[1]) < 0.01 for a, b in zip(pts, expect)), str(pts))
check("custom growth places them where its function says",
      ev("rawget(ns.Display.__regions.c1, '_point').y") == 10
      and ev("rawget(ns.Display.__regions.c2, '_point').y") == 20)
check("custom sort orders them by its function",
      ev("rawget(ns.Display.__regions.s2, '_point').x") == 0
      and ev("rawget(ns.Display.__regions.s1, '_point').x") == 40)

# --- phase 8: animations ------------------------------------------------------------
print("-- phase 8: animations")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "an", triggers = { { trigger = { spellID = 8936 } } },
      animation = { start = { type = "preset", preset = "slideleft" },
                    main = { type = "custom", duration = 1, use_alpha = true, alpha = 0.5,
                             alphaType = "custom", alphaFunc = "function(p, s, d) return 0.42 end" },
                    finish = { type = "preset", preset = "fade" } } },
    { id = "dz", type = "dynamic", growth = "RIGHT", spacing = 0 },
    { id = "z1", parent = "dz", display = { hide = true },
      animation = { finish = { type = "preset", preset = "fade" } },
      triggers = { { trigger = { type = "custom", check = "update", custom = "function() return Z1_ON end" } } } },
    { id = "z2", parent = "dz", display = { hide = true },
      triggers = { { trigger = { type = "custom", check = "update", custom = "function() return true end" } } } },
} } } }
Z1_ON = true
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("nothing animates at login", ev("ns.Display.__regions.an.anim") is None)
L.execute("AURAS.player = { { name = 'Regrowth', spellId = 8936 } } ns.Engine:UpdateAll()")
check("coming up plays the start animation from its settings",
      ev("ns.Display.__regions.an.anim.which") == "start"
      and ev("ns.Display.__regions.an.animX") == -50
      and ev("rawget(ns.Display.__regions.an, '_point').x") == -50
      and ev("ns.Display.__regions.an:GetAlpha()") == 0)
L.execute("DRIVER_TICK(0.125)")
check("and runs back to where it belongs", abs(ev("ns.Display.__regions.an.animX") + 25) < 0.001,
      str(ev("ns.Display.__regions.an.animX")))
L.execute("DRIVER_TICK(0.2)")
check("then the main animation loops", ev("ns.Display.__regions.an.anim.which") == "main"
      and ev("rawget(ns.Display.__regions.an, '_point').x") == 0)
check("a custom path runs its own function", abs(ev("ns.Display.__regions.an:GetAlpha()") - 0.42) < 0.001,
      str(ev("ns.Display.__regions.an:GetAlpha()")))
L.execute("DRIVER_TICK(3)")
check("and keeps looping", ev("ns.Display.__regions.an.anim.which") == "main")
L.execute("AURAS.player = {} ns.Engine:UpdateAll()")
check("going plays the finish animation from how it looked",
      ev("ns.Display.__regions.an.anim.which") == "finish"
      and abs(ev("ns.Display.__regions.an:GetAlpha()") - 1) < 0.001)
L.execute("DRIVER_TICK(0.125)")
check("fading as it goes", abs(ev("ns.Display.__regions.an:GetAlpha()") - 0.5) < 0.001)
L.execute("DRIVER_TICK(0.2)")
check("and ends where the aura is drawn when it is not up",
      ev("ns.Display.__regions.an.anim") is None
      and abs(ev("ns.Display.__regions.an:GetAlpha()") - 0.3) < 0.001,
      str(ev("ns.Display.__regions.an:GetAlpha()")))

L.execute("Z1_ON = false ns.Engine:UpdateAll()")
check("a dynamic group keeps a place for one playing its finish",
      ev("ns.Display.__regions.z1.anim.which") == "finish"
      and ev("rawget(ns.Display.__regions.z2, '_point').x") == 40)
L.execute("DRIVER_TICK(0.5)")
check("and closes up when it ends",
      ev("rawget(ns.Display.__regions.z2, '_point').x") == 0
      and ev("ns.Display.__regions.z1:IsShown()") is False)

L.execute("ns.FindAura('an').animation.main = { type = 'none' } ns.SaveOnLogout()")
check("an animation set to none is not saved",
      ev("(function() for _, a in ipairs(ChairAurasDB.profiles.account.auras) do"
         " if a.id == 'an' then return a.animation.main == nil and a.animation.start ~= nil end end end)()") is True)

print("-- phases 7 and 8 in the window")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "w1", triggers = { { trigger = { spellID = 774 } } } },
    { id = "wg", type = "dynamic" },
} } } }
""")
ev = L.eval
L.execute("ns.Config:Open(); ns.Config:Select('w1'); ns.Config:SetTab('display')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the size of a texture is hidden on an icon",
      ev("FIND_WIDGET('width', 'slider', 'display').host:IsShown()") is False)
L.execute("FIND_WIDGET('type', 'choice', 'display').dropdown:Pick('texture')")
check("any aura can be drawn as a texture", ev("ns.FindAura('w1').type") == "texture"
      and ev("ns.Display.__regions.w1.kind") == "texture")
check("and then its size and picture are offered",
      ev("FIND_WIDGET('width', 'slider', 'display').host:IsShown()") is True
      and ev("FIND_WIDGET('texture', 'choice', 'display').host:IsShown()") is True)
L.execute("FIND_WIDGET('texts', 'strip', 'display').field.add(ns.FindAura('w1')) ns.Config:Refresh()")
check("texts are added from a strip", ev("#ns.FindAura('w1').display.texts") == 1
      and ev("FIND_WIDGET('subText', 'text', 'display').host:IsShown()") is True)
L.execute("ns.Config:SetTab('animations')")
L.execute("FIND_WIDGET('animType', 'choice', 'animations').field.set(ns.FindAura('w1'), 'preset')")
check("an Animations tab: a slot is set to a preset, the first offered",
      ev("ns.FindAura('w1').animation.start.type") == "preset"
      and ev("ns.FindAura('w1').animation.start.preset") == "slidetop")
L.execute("ns.Config.__animCursor('main')"
          " FIND_WIDGET('animType', 'choice', 'animations').field.set(ns.FindAura('w1'), 'preset')")
check("each slot has its own presets",
      ev("FIND_WIDGET('preset_main', 'choice', 'animations').host:IsShown()") is True
      and ev("FIND_WIDGET('preset_start', 'choice', 'animations').host:IsShown()") is False)
L.execute("FIND_WIDGET('animType', 'choice', 'animations').field.set(ns.FindAura('w1'), 'custom')"
          " FIND_WIDGET('use_translate', 'check', 'animations').field.set(ns.FindAura('w1'), true) ns.Config:Refresh()")
check("custom shows WeakAuras' parts",
      ev("FIND_WIDGET('x', 'slider', 'animations').host:IsShown()") is True
      and ev("FIND_WIDGET('alpha', 'slider', 'animations').host:IsShown()") is False)
L.execute("ns.Config:Select('wg') ns.Config:SetTab('display')")
L.execute("FIND_WIDGET('growth', 'choice', 'display').field.set(ns.FindAura('wg'), 'CIRCLE') ns.Config:Refresh()")
check("a ring's radius is offered once a group grows in a circle",
      ev("FIND_WIDGET('radius', 'slider', 'display').host:IsShown()") is True
      and ev("FIND_WIDGET('growCustom', 'code', 'display').host:IsShown()") is False)


# --- phase 9: load conditions ---------------------------------------------------------
print("-- phase 9: load conditions")
L = boot("""
function GetGuildInfo() return GUILD end
function UnitFactionGroup() return "Horde", "Horde" end
function UnitEffectiveLevel() return 55 end
function GetNumGroupMembers() return MEMBERS end
function UnitIsGroupLeader() return LEADER end
function UnitGroupRolesAssigned() return ROLE end
function UnitIsPVP() return false end
function IsInInstance() return INSTANCE_KIND ~= "none", INSTANCE_KIND end
function GetInstanceInfo() return "Molten Core", INSTANCE_KIND, 9, "40 Player", 40, 0, false, 409 end
C_Map = { GetBestMapForUnit = function() return 1429 end }
EQUIPPED = { [19019] = true, ["Thunderfury"] = true }
function IsEquippedItem(item) return EQUIPPED[item] == true end
function IsEquippedItemType(kind) return kind == "Shields" end
function IsSpellKnown(id) return id == 774 end
GUILD, MEMBERS, LEADER, ROLE, INSTANCE_KIND = "Chair Club", 0, false, "NONE", "none"
local function A(id, load) return { id = id, triggers = { { trigger = { spellID = 774 } } }, load = load } end
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    A("name", { playerName = "Someone, tester" }),
    A("nameRealm", { playerName = "Tester-Testrealm" }),
    A("otherName", { playerName = "Someone" }),
    A("guild", { guild = "chair club" }),
    A("faction", { faction = { Alliance = true } }),
    A("elevel", { effectiveLevel = { max = 50 } }),
    A("gsize", { groupSize = { min = 2 } }),
    A("leader", { groupLeader = true }),
    A("tank", { role = { TANK = true } }),
    A("raidinst", { instanceType = { raid = true } }),
    A("big", { instanceSize = { min = 40 } }),
    A("zone", { zoneID = "1429" }),
    A("mc", { zoneID = "409" }),
    A("tf", { equipped = "Thunderfury" }),
    A("notTf", { notEquipped = "19019" }),
    A("shield", { itemType = "Shields" }),
    A("noRejuv", { spellNotKnown = "774" }),
    A("boss", { encounter = true }),
    A("rag", { encounterID = "672" }),
} } } }
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
loaded = lambda i: ev("ns.Engine.states['%s'].loaded" % i)
check("by character name, in a list", loaded("name") is True and loaded("otherName") is False)
check("or as Name-Realm", loaded("nameRealm") is True)
check("by guild, whatever the case", loaded("guild") is True)
check("by faction", loaded("faction") is False)
check("by effective level", loaded("elevel") is False)
check("solo is a group of one", loaded("gsize") is False)
check("group leader and role", loaded("leader") is False and loaded("tank") is False)
check("by instance type and size, outside one", loaded("raidinst") is False and loaded("big") is True)
check("by map ID or instance ID", loaded("zone") is True and loaded("mc") is True)
check("by what you wear, by name or ID",
      loaded("tf") is True and loaded("notTf") is False and loaded("shield") is True)
check("by a spell you do not know", loaded("noRejuv") is False)
check("not in a boss fight", loaded("boss") is False and loaded("rag") is False)
L.execute("MEMBERS, LEADER, ROLE, INSTANCE_KIND = 5, true, 'TANK', 'raid'"
          " FireEvent('ENCOUNTER_START', 672) ns.Engine:UpdateAll()")
check("the group ones follow the group",
      loaded("gsize") is True and loaded("leader") is True and loaded("tank") is True)
check("and the instance ones the instance", loaded("raidinst") is True)
check("a boss fight loads its auras, and only that boss's",
      loaded("boss") is True and loaded("rag") is True)
L.execute("FireEvent('ENCOUNTER_END', 672) ns.Engine:UpdateAll()")
check("until it ends", loaded("boss") is False)

L.execute("ns.Config:Open(); ns.Config:Select('name'); ns.Config:SetTab('load')")
check("the Load tab has a heading for each new section",
      ev("(function() local n = 0 for _, f in ipairs(ns.Config.__loadFields) do"
         " if f.kind == 'header' and (f.label == 'You' or f.label == 'Group' or f.label == 'Where'"
         " or f.label == 'Gear' or f.label == 'Spells' or f.label == 'Encounter') then n = n + 1 end end"
         " return n end)()") == 6)
L.execute("PRINTED = {} SlashCmdList['CHAIRAURAS']('where')")
check("/chair auras where says the IDs to use",
      "1429" in " ".join(str(v) for v in (ev("PRINTED") or {}).values())
      and "409" in " ".join(str(v) for v in (ev("PRINTED") or {}).values()))


# --- phase 10: WeakAuras import, custom options, templates ----------------------------
print("-- phase 10: WeakAuras strings are not read")
L = boot("ChairAurasDB = { version = 3, profiles = { account = { auras = {} } } }")
ev = L.eval
check("a !WA:2! string is refused as not a ChairAuras string",
      ev("select(2, ns.Share:Peek('!WA:2!abcdef'))") == "that is not a ChairAuras string")
check("and the converter is gone", ev("ns.WAImport") is None)

print("-- phase 10: free groups, templates, the Options tab")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "fg", type = "group", growth = "FREE" },
    { id = "f1", parent = "fg", pos = { x = 10, y = 20, pivot = "CENTER" }, triggers = { { trigger = { spellID = 774 } } } },
    { id = "f2", parent = "fg", pos = { x = -30, y = 0, pivot = "CENTER" }, triggers = { { trigger = { spellID = 8936 } } } },
    { id = "op", triggers = { { trigger = { spellID = 774 } } },
      authorOptions = { { type = "toggle", key = "loud", name = "Loud", default = true },
                        { type = "header", text = "More" },
                        { type = "select", key = "mode", name = "Mode", values = { "A", "B" }, default = 1 } } },
    { id = "cp", triggers = { { trigger = { spellID = 8936 } } } },
} } } }
function GetNumSpellTabs() return 1 end
function GetSpellTabInfo() return "General", nil, 0, 3 end
BOOK = { 774, 8936, 5487 }
function GetSpellBookItemInfo(i) return "SPELL", BOOK[i] end
function IsPassiveSpell(id) return id == 5487 end
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("a free group puts each child where its own position says",
      ev("rawget(ns.Display.__regions.f1, '_point').x") == 10
      and ev("rawget(ns.Display.__regions.f1, '_point').y") == 20
      and ev("rawget(ns.Display.__regions.f2, '_point').x") == -30)
check("templates list your spellbook's active spells",
      ev("#ns.Templates:Spells()") == 2 and ev("ns.Templates:Spells()[1].text") == "Regrowth")
L.execute("ns.Config:Open() ns.Config:Select('op') ns.Config:AddFromTemplate('cooldown', 8936)")
check("and make the aura for one",
      ev("ns.FindAura(ns.Config.__selected()).triggers[1].trigger.type") == "cooldown"
      and ev("ns.FindAura(ns.Config.__selected()).name") == "Regrowth cooldown")
L.execute("ns.Config:OpenTemplates()")
check("the template picker opens with your spells", ev("#ns.Config.__templates.spells") == 2)

L.execute("ns.Config:Select('op') ns.Config:SetTab('options')")
L.execute("FIND_WIDGET = " + FIND_WIDGET)
check("the Options tab draws a control for each option",
      ev("(function() local w = FIND_WIDGET('authorOptions', 'authoroptions', 'options') local n = 0"
         " for _, r in ipairs(w.rows) do if r.frame:IsShown() then n = n + 1 end end return n end)()") == 3)
L.execute("FIND_WIDGET('authorOptions', 'authoroptions', 'options').field.set(ns.FindAura('op'), { 'loud' }, false)")
check("setting one changes aura_env.config",
      ev("ns.FindAura('op').config.loud") is False and ev("ns.Env:For(ns.FindAura('op')).config.loud") is False
      and ev("ns.Env:For(ns.FindAura('op')).config.mode") == 1)
L.execute("ns.Config.__optionCursor(nil, true) ns.Config:Refresh()"
          " FIND_WIDGET('optionStrip', 'strip', 'options').field.add(ns.FindAura('op')) ns.Config:Refresh()"
          " FIND_WIDGET('optType', 'choice', 'options').field.set(ns.FindAura('op'), 'range')")
check("author mode adds options and sets their type",
      ev("#ns.FindAura('op').authorOptions") == 4 and ev("ns.FindAura('op').authorOptions[4].type") == "range"
      and ev("ns.FindAura('op').authorOptions[4].max") == 100
      and ev("ns.Env:For(ns.FindAura('op')).config.option4") == 0)
# A new range clamps the thumb, and the client says so through OnValueChanged.
# Drawing the tab must not save that as the player's choice.
L.execute("""
local op = ns.FindAura('op')
op.authorOptions[4].min, op.authorOptions[4].max = 10, 50
op.config.option4 = 30
ns.Config:Refresh()
for _, row in ipairs(FIND_WIDGET('authorOptions', 'authoroptions', 'options').rows) do
    if row.slider then
        row.slider:SetValue(0)
        rawset(row.slider, "SetMinMaxValues", function(self, low, high)
            local value = self:GetValue()
            if value < low or value > high then
                value = math.max(low, math.min(high, value))
                self:SetValue(value)
                rawget(self, "_scripts").OnValueChanged(self, value)
            end
        end)
    end
end
ns.Config:Refresh()
""")
check("drawing a slider option leaves its saved value alone",
      ev("ns.FindAura('op').config.option4") == 30, ev("ns.FindAura('op').config.option4"))

print("-- phase 11: search, several at once, Run")
L.execute("ns.Config.search = 'regrowth' ns.Config:Refresh()")
check("search narrows the list to what matches, with its group",
      ev("(function() local n = 0 for _, r in ipairs(ns.Config.__rowList()) do if r:IsShown() then n = n + 1 end end return n end)()") == 4,
      ev("(function() local n = 0 for _, r in ipairs(ns.Config.__rowList()) do if r:IsShown() then n = n + 1 end end return n end)()"))
L.execute("ns.Config.search = '' ns.Config:Select('op') ns.Config.__multi().cp = true ns.Config:SetTab('display')"
          " ns.FindAura('op').display = { size = 55 } ns.Config:Refresh()")
check("ctrl-clicked auras join the selection", ev("#ns.Config:SelectedList()") == 2)
L.execute("ns.Config:CopyTabToSelected()")
check("and the open tab copies onto them", ev("ns.FindAura('cp').display.size") == 55)
L.execute("ns.Config:SetTab('actions') local w = FIND_WIDGET('initCode', 'code', 'actions')"
          " w.box:SetText('function() return 42 end') rawget(w.run, '_scripts').OnClick()")
check("Run runs code once and says what it returned",
      "42" in str(ev("FIND_WIDGET('initCode', 'code', 'actions').ran")),
      str(ev("FIND_WIDGET('initCode', 'code', 'actions').ran")))

# A selection left over from before must not ride along into the next Delete.
L.execute("ns.Config:Select('op') ns.Config.__multi().cp = true"
          " ns.Config:AddFromTemplate('cooldown', 8936) NEW_ID = ns.Config.__selected()")
check("a new aura from a template is selected on its own", ev("#ns.Config:SelectedList()") == 1)
L.execute("ns.Config:DeleteSelected()")
check("so Delete takes only it",
      ev("ns.FindAura(NEW_ID)") is None and ev("ns.FindAura('op') ~= nil") is True
      and ev("ns.FindAura('cp') ~= nil") is True)
L.execute("ns.Config:Select('op') ns.Config.__multi().cp = true ns.Config:Delete('op')")
check("deleting the open aura drops the rest of the selection", ev("next(ns.Config.__multi())") is None)


# --- the gaps: aura lists, group units, match counts, formatters, grid order ----------
print("-- aura triggers: more names, group units, match counts")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "also", triggers = { { trigger = { spellID = 774, also = "Regrowth, 1126" } } } },
    { id = "party", triggers = { { trigger = { spellID = 1126, unit = "party" } } },
      display = { textFormat = "%{unitName}" }, type = "text" },
    { id = "count3", triggers = { { trigger = { spellID = 1126, unit = "party", matchCount = 3 } } },
      display = { textFormat = "%{matchCount}" }, type = "text" },
    { id = "few", triggers = { { trigger = { spellID = 1126, unit = "party", matchCount = 1, matchOp = "<=" } } } },
    { id = "dg", type = "dynamic", growth = "RIGHT", spacing = 0 },
    { id = "each", parent = "dg", display = { iconText = "%{unitName:upper}" },
      triggers = { { trigger = { spellID = 1126, unit = "party", cloneMatches = true } } } },
} } } }
PARTY = { player = true, party1 = true, party2 = true }
NAMES = { player = "Tester", party1 = "Ann-Otherrealm", party2 = "Bob" }
function UnitExists(unit) return PARTY[unit] == true or unit == "target" end
function UnitName(unit) return NAMES[unit] or "Tester" end
""")
ev = L.eval
L.execute("AURAS.player = { { name = 'Regrowth', spellId = 8936 } } ns.Engine:UpdateAll()")
check("also match: another name counts as the aura", ev("ns.Engine.states.also.shown") is True)
L.execute("AURAS.player = { { name = 'Something', spellId = 1126 } } ns.Engine:UpdateAll()")
check("and so does another ID", ev("ns.Engine.states.also.shown") is True)
L.execute("AURAS.player = {} AURAS.party2 = { { name = 'Mark of the Wild', spellId = 1126 } } ns.Engine:UpdateAll()")
check("a party trigger finds it on anyone in the party, and says whose",
      ev("ns.Engine.states.party.shown") is True
      and ev("ns.Display.__regions.party.text:GetText()") == "Bob")
check("a count of three is not met by one", ev("ns.Engine.states.count3.shown") is False)
check("at most one is", ev("ns.Engine.states.few.shown") is True)
L.execute("AURAS.player = { { name = 'Mark of the Wild', spellId = 1126 } }"
          " AURAS.party1 = { { name = 'Mark of the Wild', spellId = 1126 } } ns.Engine:UpdateAll()")
check("three matches meet it, and %{matchCount} says so",
      ev("ns.Engine.states.count3.shown") is True
      and ev("ns.Display.__regions.count3.text:GetText()") == "3")
check("at most one no longer holds", ev("ns.Engine.states.few.shown") is False)
check("one region per match inside a group",
      ev("#ns.Engine.states.each.clones") == 3
      and ev("ns.Display.__regions['each::party1:01'] ~= nil") is True)
check("each naming its own unit, formatted",
      ev("ns.Display.__regions['each::party1:01'].overlay:GetText()") == "ANN-OTHERREALM")
check("group units' aura events are listened to once a trigger watches them",
      ev("ns.watchesGroupUnits") is True)

print("-- text formatters")
L.execute("""
RAID_CLASS_COLORS = { DRUID = { r = 1, g = 0.49, b = 0.04, colorStr = "ffff7c0a" } }
FMT_STATE = { source = { chosenState = { unit = "party1" }, big = 12345, frac = 2.6, who = "Ann-Otherrealm" } }
""")
fmt = lambda t: ev("ns.Engine:FormatText(%r, nil, FMT_STATE)" % t)
check("abbr shortens big numbers", fmt("%{big:abbr}") == "12.3k", fmt("%{big:abbr}"))
check("round, floor and ceil", fmt("%{frac:round} %{frac:floor} %{frac:ceil}") == "3 2 3")
check("norealm drops the realm, and they chain", fmt("%{who:norealm:upper}") == "ANN")
check("max cuts it short", fmt("%{who:max3}") == "Ann")
check("class colors a name by its unit's class", fmt("%{who:norealm:class}") == "|cffff7c0aAnn|r",
      fmt("%{who:norealm:class}"))
check("an unknown formatter leaves the text alone", fmt("%{big:sparkle}") == "12345")

print("-- grid order and reputation")
L = boot("""
ChairAurasDB = { version = 3, profiles = { account = { auras = {
    { id = "grid", type = "group", growth = "RIGHT", spacing = 0, columns = 2, wrapReverse = true },
    { id = "g1", parent = "grid", triggers = { { trigger = { spellID = 774 } } } },
    { id = "g2", parent = "grid", triggers = { { trigger = { spellID = 774 } } } },
    { id = "g3", parent = "grid", triggers = { { trigger = { spellID = 774 } } } },
    { id = "rep", type = "bar", triggers = { { trigger = { type = "reputation", standing = 6 } } } },
    { id = "rep2", triggers = { { trigger = { type = "reputation", faction = "Darnassus", standing = 7, standingOp = "==" } } } },
} } } }
function GetWatchedFactionInfo() return "Thunder Bluff", 6, 9000, 21000, 15000 end
function GetNumFactions() return 2 end
FACTIONS = { { "Orgrimmar", nil, 5, 3000, 9000, 4000 }, { "Darnassus", nil, 7, 21000, 42000, 30000 } }
function GetFactionInfo(i) return unpack(FACTIONS[i]) end
""")
ev = L.eval
L.execute("ns.Engine:UpdateAll()")
check("wrapping upward: the third starts a line above the first",
      ev("rawget(ns.Display.__regions.g3, '_point').point") == "BOTTOMLEFT"
      and ev("rawget(ns.Display.__regions.g3, '_point').y") == 40
      and ev("ns.Display:PivotFor(ns.FindAura('grid'))") == "BOTTOMLEFT")
check("reputation: the watched faction, at honored or better",
      ev("ns.Engine.states.rep.shown") is True and ev("ns.Engine.states.rep.name") == "Thunder Bluff"
      and ev("ns.Engine.states.rep.count") == 6)
check("its bar fills through the standing",
      ev("ns.Display.__regions.rep.bar:GetValue()") == 6000)
check("or a faction by name", ev("ns.Engine.states.rep2.shown") is True)

print("ALL OK" if not failures else "%d FAILED" % len(failures))
sys.exit(1 if failures else 0)
