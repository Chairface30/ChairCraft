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
            elseif k == "GetFont" then return "Fonts\\FRIZQT__.TTF", 12, ""
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

function FireEvent(ev, arg1)
    for _, f in ipairs(EVENT_FRAMES) do
        if f._events[ev] and f._scripts and f._scripts.OnEvent then
            f._scripts.OnEvent(f, ev, arg1)
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
FILES = ["Core.lua", "Presets.lua", "Database.lua", "Load.lua", "Engine.lua",
         "Display.lua", "Icons.lua", "Share.lua", "Sounds.lua", "Config.lua",
         "Commands.lua"]
FILES = ["ChairAuras/" + _f for _f in FILES]
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
    L.execute("ns = {}; suite = { ChairAuras = ns }")
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
      ev("ChairAurasDB.version") == 2)

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

# "Hide when inactive" would otherwise leave nothing to grab.
L.execute("ns.profile.locked = false; ns.Engine:UpdateAll()")
check("an inactive hidden icon is faintly there while unlocked",
      0 < ev("ns.Display.__regions.a1:GetAlpha()") < 0.5,
      ev("ns.Display.__regions.a1:GetAlpha()"))
L.execute("ns.profile.locked = true; ns.Engine:UpdateAll()")
check("and gone once locked", ev("ns.Display.__regions.a1:GetAlpha()") == 0)

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
      ev("ns.GetAuras()[1].trigger.match") == "name"
      and ev("ns.GetAuras()[1].trigger.text") == "Well Fed")
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

# A provider that throws -- which is what this client's actually does -- must
# not take the list down with it.
L3 = boot("""
GetNumMacroIcons, GetMacroIconInfo = nil, nil
IconDataProviderMixin = {}
function CreateAndInitFromMixin() error("BaseIconFilenames is nil") end
IMMEDIATE_TIMERS = true
ChairAurasDB = { version = 2, profiles = { ["guid:Player-1-00000001"] = { auras = {} } } }
""")
L3.execute("ns.Icons:StartScan()")
check("a broken icon provider falls through instead of erroring",
      L3.eval("(ns.Icons:Source())") == "spell icons", L3.eval("(ns.Icons:Source())"))

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
check("a group exports to a string", isinstance(text, str) and text.startswith("CA1:"),
      text and text[:40])

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
                if aura.id ~= "a2" and (aura.trigger or {}).text == "Well Fed" then
                    return aura.trigger.partial == true and (aura.display or {}).icon == 456
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
check("and keeps its trigger", L2.eval("ns.FindAura('i1').trigger.spellID") == 774)
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
    trigger = {
        type = "aura", unit = "focus", harmful = true, match = "name",
        text = "Well Fed", partial = true, mine = true,
        stacks = 3, stacksOp = "<=", spellID = 774,
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
                 trigger = { spellID = 774 }, load = { alive = true },
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
        return DIFF(original, copy, "aura")
    end)()
""")
check("every field of it came back identical", difference is None, difference)

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
(function(key, kind)
    for _, entry in pairs(ns.Config.__panes or {}) do
        for _, widget in ipairs(entry.pane.widgets or {}) do
            if widget.field and widget.field.key == key
               and widget.field.kind == kind then
                return widget
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
      L.eval("ns.GetAuras()[1].trigger.unit") is None
      and L.eval("ns.GetAuras()[1].trigger.type") is None)
check("the spell itself is kept", L.eval("ns.GetAuras()[1].trigger.spellID") == 774)
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
      ev("ns.FindAura('a1').trigger.spellID") == 774)

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
      L.eval("ns.TriggerField(ns.FindAura('a4'), 'match')") == "name"
      and L.eval("ns.Trigger(ns.FindAura('a4')).text") == "Well Fed")
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

# Conditions were removed on 2026-09-25: no tab, no engine for them, and
# any a profile still carries are dropped when it loads.
print("-- conditions are gone")
LC = boot('''
ChairAurasDB = { version = 2, profiles = { ["account"] = { auras = {
    { id = "a1", type = "icon",
      trigger = { match = "name", text = "Plainsrunning" },
      conditions = { { property = "stacks", op = "<=", value = 5, effect = "hide" } } },
} } } }
AURAS.player = {
    { name = "Plainsrunning", spellId = 1299038, applications = 2, duration = 0 },
}
''')
LC.execute("ns.Config:Open(); ns.Config:Select('a1')")
check("the options window has no Conditions tab",
      LC.eval("ns.Config.__panes.conditions") is None)
check("the engine no longer offers them", LC.eval("ns.ConditionEffects") is None)
check("rules saved before are dropped on load",
      LC.eval("ns.FindAura('a1').conditions") is None)
LC.execute("ns.Engine:UpdateAll(); ns.Display:Refresh(ns.Engine.states)")
check("and an old hide rule no longer hides the aura",
      (LC.eval("ns.Display.__regions.a1._alpha") or 0) > 0,
      str(LC.eval("ns.Display.__regions.a1._alpha")))

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

print("ALL OK" if not failures else "%d FAILED" % len(failures))
sys.exit(1 if failures else 0)
