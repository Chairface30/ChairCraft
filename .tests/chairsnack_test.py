# Relocated into Chaircraft on 2026-09-22, when the standalone addon folders
# were deleted. Until then this ran as a runtime-patched copy of that addon's
# own suite; there is no upstream to re-run against any more, so it lives here.
# Offline checks for SnapSnack (needs: pip install lupa).
#   python .tests/snapsnack_test.py
# 1. Every .lua file parses as Lua 5.1 (the dialect WoW uses).
# 2. Loads the addon against a mocked client and takes it through a login, which
#    is the step that has broken twice without anything noticing until it was
#    noticed in the game.
import glob, io, os, sys
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
            if k == "Show" then rawset(self, "_shown", true)
            elseif k == "Hide" then rawset(self, "_shown", false)
            elseif k == "IsShown" then return rawget(self, "_shown") == true
            elseif k == "IsVisible" then return rawget(self, "_shown") == true
            elseif k == "SetText" then rawset(self, "_text", (...))
            elseif k == "GetText" then return rawget(self, "_text")
            elseif k == "SetSize" then
                local w, h = ...
                rawset(self, "_w", w); rawset(self, "_h", h)
            elseif k == "GetWidth" then return rawget(self, "_w") or 0
            elseif k == "GetHeight" then return rawget(self, "_h") or 0
            elseif k == "GetSize" then
                return rawget(self, "_w") or 0, rawget(self, "_h") or 0
            elseif k == "GetCenter" then return 512, 384
            elseif k == "GetEffectiveScale" then return 1
            elseif k == "GetFrameLevel" then return 1
            elseif k == "GetFontString" then return Mock()
            elseif k == "GetNumPoints" then return 0
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
MOCK = Mock

function CreateFrame(ftype, name, parent, template)
    local f = Mock()
    rawset(f, "_parent", parent)

    -- Templates bring fields as well as methods, and code written against a
    -- template reaches for them by name. A checkbox has its label; a slider
    -- has the three font strings around it.
    if template then
        if template:find("CheckButton") or template:find("Checkbox") then
            rawset(f, "text", Mock())
        end
        if template:find("Slider") then
            rawset(f, "Low", Mock())
            rawset(f, "High", Mock())
            rawset(f, "Text", Mock())
        end
        if template:find("InputBox") or template:find("EditBox") then
            rawset(f, "Instructions", Mock())
        end
    end

    if name then
        _G[name] = f
        -- Templates also make globals out of their children, which older code
        -- looks up by name.
        _G[name .. "Text"] = Mock()
        _G[name .. "Low"] = Mock()
        _G[name .. "High"] = Mock()
    end
    return f
end

function FireEvent(ev, arg1, ...)
    for _, f in ipairs(EVENT_FRAMES) do
        if f._events[ev] and f._scripts and f._scripts.OnEvent then
            f._scripts.OnEvent(f, ev, arg1, ...)
        end
    end
end

UIParent, GameTooltip, WorldFrame = Mock(), Mock(), Mock()
Minimap = Mock()
function GameTooltip_Hide() end
IMMEDIATE_TIMERS = false
C_Timer = {
    After = function(_, fn) if IMMEDIATE_TIMERS then fn() end end,
    NewTicker = function() return { Cancel = function() end } end,
}
SlashCmdList, UISpecialFrames, tinsert = {}, {}, table.insert
UIDROPDOWNMENU_MENU_VALUE = nil
NUM_BAG_SLOTS, NUM_CHAT_WINDOWS = 4, 3
BACKPACK_CONTAINER, BANK_CONTAINER = 0, -1
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(PRINTED, table.concat(parts, " "))
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
-- A clock that can be moved. Bootstrap waits fifteen seconds for the saved
-- data before giving up, and a frozen clock plus timers that fire at once is
-- an infinite retry rather than a test.
NOW = 1000
function GetTime() return NOW end
function InCombatLockdown() return false end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function IsAltKeyDown() return false end
function GetCursorInfo() return nil end
function ClearCursor() end
function PlaySound() return true end
function StopSound() return true end
function GetLocale() return "enUS" end
function GetRealmName() return "Testrealm" end
function UnitName() return "Tester" end
function UnitGUID() return "Player-4613-00000001" end
function UnitClass() return "Druid", "DRUID" end
function UnitLevel() return 60 end
function UnitExists(unit) return unit == "player" end
function UnitAffectingCombat() return false end
function IsResting() return true end
function IsMounted() return false end
function IsIndoors() return false end
function IsInInstance() return false, "none" end
function IsInGroup() return false end
function IsInRaid() return false end
function GetNumGroupMembers() return 0 end
function GetZonePVPInfo() return "sanctuary" end
function GetRealZoneText() return "Elwynn Forest" end
function GetSubZoneText() return "" end
function GetZoneText() return "Elwynn Forest" end
function GetMinimapZoneText() return "Elwynn Forest" end
function GetInventoryItemID() return nil end
function GetInventoryItemLink() return nil end
function GetPetFoodTypes() return nil end
function HasPetUI() return false end
function GetSpellInfo(id) return "Spell " .. tostring(id) end
function GetSpellTexture() return 100 end
function GetItemSpell() return nil end
function IsUsableItem() return true end
function GetItemCooldown() return 0, 0, 1 end
function GetItemCount() return 5 end
function date() return "2026-01-01" end

-- Mixins and helpers the modern widgets are built from. These are tables the
-- client provides, not methods on a frame, so the frame mock cannot invent
-- them.
MinimalSliderWithSteppersMixin = {
    Label = { Right = 1, Left = 2, Top = 3, Min = 4, Max = 5 },
    Event = { OnValueChanged = "OnValueChanged" },
}
function CreateMinimalSliderFormatter() return function(value) return tostring(value) end end
function Mixin(target, ...) return target end
function CreateFromMixins() return MOCK() end
function CreateAndInitFromMixin() return MOCK() end
ScrollUtil = setmetatable({}, { __index = function() return function() return MOCK() end end })

-- Items. Only the handful the bars care about need to exist.
ITEMS = {
    [4536] = { name = "Shiny Red Apple", class = "Consumable", sub = "Food & Drink",
               level = 5, icon = 100 },
    [1179] = { name = "Ice Cold Milk", class = "Consumable", sub = "Food & Drink",
               level = 5, icon = 101 },
    [118]  = { name = "Minor Healing Potion", class = "Consumable", sub = "Potion",
               level = 5, icon = 102 },
    [2455] = { name = "Minor Mana Potion", class = "Consumable", sub = "Potion",
               level = 5, icon = 103 },
    [1251] = { name = "Linen Bandage", class = "Consumable", sub = "Bandage",
               level = 5, icon = 104 },
}

function GetItemInfo(id)
    local item = ITEMS[tonumber(id)]
    if not item then return nil end
    return item.name, "|Hitem:" .. id .. "|h[" .. item.name .. "]|h", 1, 10,
           item.level, item.class, item.sub, 20, "", item.icon, 100
end
function GetItemInfoInstant(id)
    local item = ITEMS[tonumber(id)]
    if not item then return nil end
    return tonumber(id), "", "", "", item.icon, 0, 5
end
C_Item = {
    GetItemInfo = function(id) return GetItemInfo(id) end,
    GetItemInfoInstant = function(id) return GetItemInfoInstant(id) end,
    GetItemCount = function() return 5 end,
    GetItemSpell = function() return nil end,
    IsUsableItem = function() return true end,
    GetItemCooldown = function() return 0, 0, 1 end,
}

-- Bags: one of each item, in bag 0.
BAGS = { [0] = { 4536, 1179, 118, 2455, 1251 } }
function GetContainerNumSlots(bag) return #(BAGS[bag] or {}) end
function GetContainerItemID(bag, slot) return (BAGS[bag] or {})[slot] end
function GetContainerItemInfo(bag, slot)
    local id = GetContainerItemID(bag, slot)
    if not id then return nil end
    return { itemID = id, stackCount = 5, iconFileID = (ITEMS[id] or {}).icon }
end
function GetContainerItemLink(bag, slot)
    local id = GetContainerItemID(bag, slot)
    return id and ("|Hitem:" .. id .. "|h") or nil
end
C_Container = {
    GetContainerNumSlots = function(bag) return GetContainerNumSlots(bag) end,
    GetContainerItemID = function(bag, slot) return GetContainerItemID(bag, slot) end,
    GetContainerItemInfo = function(bag, slot) return GetContainerItemInfo(bag, slot) end,
    GetContainerItemLink = function(bag, slot) return GetContainerItemLink(bag, slot) end,
    GetContainerItemCooldown = function() return 0, 0, 1 end,
}

C_Spell = {
    GetSpellInfo = function(id) return { name = "Spell " .. tostring(id), spellID = id } end,
    GetSpellName = function(id) return "Spell " .. tostring(id) end,
    GetSpellTexture = function() return 100 end,
    GetSpellCooldown = function() return { duration = 0, startTime = 0 } end,
    DoesSpellExist = function() return true end,
}
C_AddOns = { GetAddOnMetadata = function() return "2.64" end }
C_UnitAuras = { GetBuffDataByIndex = function() return nil end }

-- Tooltips the item scanner reads through.
function CreateTooltipMock()
    local tip = Mock()
    tip.NumLines = function() return 0 end
    return tip
end
'''

failures = []
def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)

FILES = ["Core.lua", "Database.lua", "ItemData.lua", "Items.lua", "AutoBar.lua",
         "BuffFood.lua", "Grid.lua", "Config.lua", "Bootstrap.lua"]
FILES = ["ChairSnack/" + _f for _f in FILES]

# --- 1. syntax ------------------------------------------------------------
L = lua51.LuaRuntime(unpack_returned_tuples=True)
loadstring = L.eval("function(s,n) return loadstring(s,n) end")
for f in FILES:
    res = loadstring(io.open(f, encoding="utf-8").read(), "@" + f)
    fn, err = (res if isinstance(res, tuple) else (res, None))
    check("parses " + f, fn is not None, err)
if failures:
    sys.exit(1)


def boot(setup=""):
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    L.execute(HARNESS)
    L.execute(setup)
    run = L.eval("function(s, n) local f = assert(loadstring(s, n)); f('Chaircraft', suite) end")
    L.execute("addon = {}; suite = { ChairSnack = addon }")
    for f in FILES:
        run(io.open(f, encoding="utf-8").read(), "@" + f)
    return L


# --- 2. a login ------------------------------------------------------------
# The whole of the point: an addon that throws on the way up leaves no bars and
# no error anyone reads, because script errors are off by default on this
# client.
print("-- logging in")
L = boot('SnapSnackDB = nil')
L.execute('FireEvent("ADDON_LOADED", "Chaircraft")')

error = None
try:
    L.execute('SnapSnackDB = { version = 2 }')
    L.execute('FireEvent("PLAYER_LOGIN")')
except Exception as exc:
    error = str(exc)

check("the addon gets through a login without erroring", error is None, error)

printed = chr(10).join(L.eval("PRINTED").values()) if error is None else ""
check("and says it loaded", "loaded" in printed, printed[:300])

# --- 3. a panel that will not build ---------------------------------------
# What actually happened in the game: one options panel threw, and because the
# ten panels were built in a row inside SetupConfig -- which is inside
# Bootstrap -- the addon ended up with no bars at all. A tab is worth losing.
# The addon is not.
print("-- one broken panel")
L = boot("""
SnapSnackDB = { version = 2 }
-- Something the slider panels need, taken away. Any missing client API would
-- do; this is one the real client actually changed.
MinimalSliderWithSteppersMixin = nil
""")
L.execute('FireEvent("ADDON_LOADED", "Chaircraft")')

error = None
try:
    L.execute('FireEvent("PLAYER_LOGIN")')
except Exception as exc:
    error = str(exc)

check("a panel that cannot be built does not stop the login", error is None, error)

printed = chr(10).join(L.eval("PRINTED").values()) if error is None else ""
check("the addon still loads", "loaded" in printed, printed[:400])
check("and says which part failed",
      "could not be built" in printed, printed[:400])

# The bars are the thing that has to survive, so check one exists and holds
# what the bag scan found.
check("the bars were still built",
      L.eval("(function() local n = 0 for _ in pairs(addon.frames or {}) do "
             "n = n + 1 end return n end)()") > 0,
      L.eval("(function() local n = 0 for _ in pairs(addon.frames or {}) do "
             "n = n + 1 end return n end)()"))

# --- 4. bootstrap draws what it built -------------------------------------
# The other half of the same fault: bootstrap built and filled the bars but
# left the drawing to a login branch that had already been skipped.
print("-- bootstrap finishes the job")
L = boot("SnapSnackDB = { version = 2 }")
L.execute("""
DREW = 0
local original = addon.UpdateAllGrids
addon.UpdateAllGrids = function(self, ...)
    DREW = DREW + 1
    return original(self, ...)
end
""")
L.execute('FireEvent("ADDON_LOADED", "Chaircraft")')
L.execute('FireEvent("PLAYER_LOGIN")')
check("the bars are drawn during bootstrap itself",
      L.eval("DREW") >= 1, L.eval("DREW"))

# And when the saved data is late -- which is this client's normal -- the
# login branch is skipped entirely, so bootstrap is the only thing that can
# have drawn them.
L = boot("SnapSnackDB = nil")
L.execute("""
DREW = 0
local original = addon.UpdateAllGrids
addon.UpdateAllGrids = function(self, ...)
    DREW = DREW + 1
    return original(self, ...)
end
""")
L.execute('FireEvent("ADDON_LOADED", "Chaircraft")')
L.execute('FireEvent("PLAYER_LOGIN")')
check("with no saved data yet, login alone draws nothing",
      L.eval("DREW") == 0, L.eval("DREW"))

# The grace period expires and bootstrap runs on defaults.
L.execute("NOW = NOW + 20")
L.execute("IMMEDIATE_TIMERS = true")
L.execute('FireEvent("PLAYER_ENTERING_WORLD")')
check("and when bootstrap finally runs, it draws them",
      L.eval("DREW") >= 1, L.eval("DREW"))


# --- opened from anywhere, it opens inside the Chaircraft menu ------------
print("-- inside the Chaircraft menu")
L = boot('SnapSnackDB = nil')
L.execute('FireEvent("ADDON_LOADED", "Chaircraft")')
L.execute('SnapSnackDB = { version = 2 }')
L.execute('FireEvent("PLAYER_LOGIN")')
L.execute("""
HOSTED = 0
SELECTED = nil
local select = addon.SelectGrid
addon.SelectGrid = function(self, id, ...) SELECTED = id return select(self, id, ...) end
ChairPlusNS = { OpenPartPage = function(token)
    HOSTED = HOSTED + 1
    local w = addon:GetConfigWindow()
    w.chairEmbedded = true
    addon:OpenConfig()
    return true
end }
""")
L.execute('addon:OpenConfig("petfood")')
check("opening the config goes through the menu, once", L.eval("HOSTED") == 1,
      str(L.eval("HOSTED")))
check("and still lands on the section it was asked for",
      L.eval("SELECTED") == "petfood", str(L.eval("SELECTED")))
check("the window lists what the menu hides",
      L.eval("#addon:GetConfigWindow().chairChrome") == 2)

# The minimap icon sits in the minimap ring the way LibDBIcon puts BugSack's
# and AtlasLoot's there: a 31px button on the minimap, the gold border round
# it, dragged round the edge and remembered as an angle.
print("-- the minimap icon")
L = boot('SnapSnackDB = nil')
L.execute('rawset(Minimap, "_w", 140) rawset(Minimap, "_h", 140)')
L.execute('FireEvent("ADDON_LOADED", "Chaircraft") SnapSnackDB = { version = 2 } FireEvent("PLAYER_LOGIN")')
L.execute("""
B = SnapSnackMinimapButton
""")
check("the icon is a button on the minimap", L.eval("B ~= nil and rawget(B, '_parent') == Minimap") is True)
check("the standard 31px size", L.eval("rawget(B, '_w')") == 31 and L.eval("rawget(B, '_h')") == 31)
L.execute("""
POINTS = {}
rawset(B, "SetPoint", function(self, ...) POINTS = { ... } end)
rawset(B, "ClearAllPoints", function() end)
addon:GetMinimapDB().minimapPos = 0
addon.PlaceMinimapButton(B)
""")
check("at 0 degrees it sits on the right edge of the minimap",
      L.eval("POINTS[2] == Minimap and math.abs(POINTS[4] - 75) < 0.01 and math.abs(POINTS[5]) < 0.01") is True,
      str([L.eval("POINTS[%d]" % i) for i in (1, 3, 4, 5)]))
L.execute("addon:GetMinimapDB().minimapPos = 90 addon.PlaceMinimapButton(B)")
check("and at 90 on the top edge",
      L.eval("math.abs(POINTS[4]) < 0.01 and math.abs(POINTS[5] - 75) < 0.01") is True)
L.execute("""
function GetCursorPosition() return 512 - 50, 384 - 50 end
B._scripts.OnDragStart(B)
B._scripts.OnUpdate(B)
B._scripts.OnDragStop(B)
""")
check("dragging moves it round the edge, and remembers the angle",
      abs(L.eval("addon:GetMinimapDB().minimapPos") - 225) < 0.01,
      str(L.eval("addon:GetMinimapDB().minimapPos")))
check("the old free-floating size setting is gone",
      L.eval("addon.minimapDefaults.size") is None)

print("ALL OK" if not failures else "%d FAILED" % len(failures))
sys.exit(1 if failures else 0)
