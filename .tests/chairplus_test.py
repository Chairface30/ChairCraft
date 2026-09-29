# Relocated into Chaircraft on 2026-09-22, when the standalone addon folders
# were deleted. Until then this ran as a runtime-patched copy of that addon's
# own suite; there is no upstream to re-run against any more, so it lives here.
# Offline checks for ChairPlus (needs: pip install lupa).
#   python .tests/chairplus_test.py
# 1. Every .lua file parses as Lua 5.1 (the dialect WoW uses).
# 2. Loads the addon against a mocked client and checks the things that are
#    easy to get wrong and impossible to see until you are standing in the
#    game: the settings layering that stands in for this client's broken
#    SavedVariables, the OSD line, the junk-selling loop and its refusals, and
#    the quest turn-in safety gates.
import glob, math, os, re, sys
from lupa import lua51

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

HARNESS = r'''
-- Frames: any CamelCase key is a method; lowercase keys are plain fields.
FRAMES, EVENT_FRAMES = {}, {}

local Mock
local function Method(k)
    return setmetatable({}, {
        __index = function(_, key)
            if type(key) == "string" and key:match("^%u") then return Method(key) end
        end,
        __call = function(_, self, ...)
            if type(self) ~= "table" then return Mock() end
            if k == "SetText" then rawset(self, "_text", (...))
            elseif k == "GetText" then return rawget(self, "_text")
            elseif k == "Show" then rawset(self, "_shown", true)
            elseif k == "Hide" then
                -- As the client does: OnHide and anything hooked on it run,
                -- but only when the frame was showing.
                local was = rawget(self, "_shown")
                rawset(self, "_shown", false)
                if was then
                    local hooks = rawget(self, "_hideHooks")
                    for _, fn in ipairs(hooks or {}) do fn(self) end
                end
            elseif k == "HookScript" then
                local name, fn = ...
                if name == "OnHide" then
                    local hooks = rawget(self, "_hideHooks") or {}
                    hooks[#hooks + 1] = fn
                    rawset(self, "_hideHooks", hooks)
                end
            elseif k == "SetShown" then rawset(self, "_shown", (...) and true or false)
            elseif k == "IsShown" then return rawget(self, "_shown") == true
            elseif k == "SetChecked" then rawset(self, "_checked", (...) and true or false)
            elseif k == "GetChecked" then return rawget(self, "_checked") == true
            elseif k == "GetFont" then return "Fonts\\FRIZQT__.TTF", 12, ""
            elseif k == "GetStringWidth" then
                -- A test that cares how wide text is sets STRING_WIDTH.
                if STRING_WIDTH then return STRING_WIDTH(rawget(self, "_text")) end
                return 120
            elseif k == "GetStringHeight" then return 14
            elseif k == "SetScale" then rawset(self, "_scale", (...))
            elseif k == "SetJustifyH" then rawset(self, "_justify", (...))
            elseif k == "SetAlpha" then rawset(self, "_alpha", (...))
            elseif k == "GetAlpha" then return rawget(self, "_alpha") or 1
            elseif k == "GetScale" then return rawget(self, "_scale") or 1
            elseif k == "EnableMouse" then rawset(self, "_mouse", (...) and true or false)
            elseif k == "SetMovable" then rawset(self, "_movable", (...) and true or false)
            elseif k == "IsMovable" then return rawget(self, "_movable") == true
            elseif k == "SetParent" then rawset(self, "_parent", (...))
            elseif k == "GetParent" then return rawget(self, "_parent")
            elseif k == "GetName" then return rawget(self, "_name")
            elseif k == "SetSize" then
                local w, h = ...
                rawset(self, "_w", w); rawset(self, "_h", h)
            elseif k == "SetPoint" then
                local point, a, b, c, d = ...
                if type(a) == "number" then
                    rawset(self, "_point", { point = point, rel = point, x = a, y = b })
                else
                    rawset(self, "_point", { point = point, rel = b, x = c, y = d })
                end
            elseif k == "GetPoint" then
                local p = rawget(self, "_point")
                if not p then return nil end
                return p.point, UIParent, p.rel, p.x, p.y
            elseif k == "ClearAllPoints" then rawset(self, "_point", nil)
            elseif k == "SetScript" then
                local name, fn = ...
                local s = rawget(self, "_scripts") or {}
                s[name] = fn
                rawset(self, "_scripts", s)
            elseif k == "RegisterEvent" then
                if UNKNOWN_EVENTS and UNKNOWN_EVENTS[(...)] then
                    error('Attempt to register unknown event "' .. tostring((...)) .. '"')
                end
                local e = rawget(self, "_events")
                if not e then
                    e = {}
                    rawset(self, "_events", e)
                    table.insert(EVENT_FRAMES, self)
                end
                e[(...)] = true
            elseif k == "UnregisterAllEvents" then
                -- Still a frame that listens: registering again must reach it.
                if not rawget(self, "_events") then table.insert(EVENT_FRAMES, self) end
                rawset(self, "_events", {})
            elseif k == "UnregisterEvent" then
                local e = rawget(self, "_events")
                if e then e[(...)] = nil end
            elseif k == "IsEventRegistered" then
                local e = rawget(self, "_events")
                return (e and e[(...)]) and true or false
            end
            return Mock()
        end,
    })
end
Mock = function()
    local f = setmetatable({}, { __index = function(_, key)
        if type(key) == "string" and key:match("^%u") then return Method(key) end
    end })
    -- Shown from birth, the way the real client makes them. A mock that
    -- creates frames hidden is more forgiving than the game, and it let a
    -- panel that hid itself on first use pass every test.
    rawset(f, "_shown", true)
    table.insert(FRAMES, f)
    return f
end
MakeMock = Mock

function CreateFrame(ftype, name, parent, template)
    -- The panel asks for option templates that may not exist. The real client
    -- raises on a missing one, which is the whole reason that code pcalls.
    if template and template ~= "BackdropTemplate" then
        error("Unknown template: " .. tostring(template))
    end
    local f = Mock()
    rawset(f, "_parent", parent)
    if name then _G[name] = f; rawset(f, "_name", name) end
    return f
end

function FireEvent(ev, arg1, arg2, arg3)
    for _, f in ipairs(EVENT_FRAMES) do
        local e = rawget(f, "_events")
        local s = rawget(f, "_scripts")
        if e and e[ev] and s and s.OnEvent then
            s.OnEvent(f, ev, arg1, arg2, arg3)
        end
    end
end

-- Did anything register this event at all? Used to prove the module never
-- reaches for the protected combat log again.
function ANY_REGISTERED(ev)
    for _, f in ipairs(EVENT_FRAMES) do
        local e = rawget(f, "_events")
        if e and e[ev] then return true end
    end
    return false
end

-- Find a widget by the text it was given, so a test can ask whether a
-- particular option row is on the page currently showing.
function SHOWN(text)
    for _, f in ipairs(FRAMES) do
        if rawget(f, "_text") == text then return rawget(f, "_shown") end
    end
    return nil
end

-- Buttons carry their caption on a child font string, but it is the button
-- that gets shown and hidden, so it needs its own probe.
function SHOWN_BUTTON(text)
    for _, f in ipairs(FRAMES) do
        local label = rawget(f, "labelText")
        if label and rawget(label, "_text") == text then return rawget(f, "_shown") end
    end
    return nil
end

function PAGE_BUTTON(text)
    for _, f in ipairs(FRAMES) do
        local label = rawget(f, "labelText")
        if label and rawget(label, "_text") == text then return f end
    end
end

function DRIVER_TICK()
    for _, f in ipairs(FRAMES) do
        local s = rawget(f, "_scripts")
        if s and s.OnUpdate and rawget(f, "_shown") then s.OnUpdate(f, 0.1) end
    end
end

UIParent = Mock()
SlashCmdList = {}

function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strsplit(sep, str)
    -- Empty fields are preserved, the way the real one does it. Anything that
    -- indexes a GUID by position depends on that.
    local out, current = {}, ""
    for i = 1, #str do
        local c = str:sub(i, i)
        if c == sep then out[#out + 1] = current; current = ""
        else current = current .. c end
    end
    out[#out + 1] = current
    return unpack(out)
end
strupper = string.upper
tinsert = table.insert
function GetTime() return NOW end
NOW = 1000

-- Modifier keys.
SHIFT = false
function IsShiftKeyDown() return SHIFT end

-- Timers, held so the test can decide when the sell loop takes its next pass.
PENDING = {}
C_Timer = { After = function(delay, fn) table.insert(PENDING, fn) end }
function RUN_TIMERS(n)
    for _ = 1, (n or 1) do
        local queue = PENDING
        PENDING = {}
        for _, fn in ipairs(queue) do fn() end
    end
end

-- Money. SECRET_MONEY makes GetMoney hand back a value that behaves exactly
-- like this client's secrets: it passes type() and dies on a format.
MONEY = 0
SECRET_MONEY = false
local secret = setmetatable({}, { __tostring = function() error("secret value") end })
function GetMoney()
    if SECRET_MONEY then return secret end
    return MONEY
end
-- type() must still say "number" for the test to mean anything, so the secret
-- path is exercised through ns.Num being handed something that throws on
-- format. A table is the closest a plain Lua harness can get; ns.Num rejects
-- it at the type check, which is the same nil the real secret produces.

-- Bags.
BAGS = {}
SOLD = {}
C_Container = {
    GetContainerNumSlots = function(bag)
        return BAGS[bag] and BAGS[bag].size or 0
    end,
    GetContainerNumFreeSlots = function(bag)
        local b = BAGS[bag]
        if not b then return 0, 0 end
        local used = 0
        for _ in pairs(b.items or {}) do used = used + 1 end
        return (b.size or 0) - used, b.slotFamily or b.family or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        local b = BAGS[bag]
        return b and b.items and b.items[slot] or nil
    end,
    -- What the SLOT claims. Deliberately allowed to disagree with the bag
    -- actually equipped, because on the real client it does: an empty typed
    -- slot answers with a family and zero free slots.
    ContainerIDToInventoryID = function(bag) return 19 + bag end,
    UseContainerItem = function(bag, slot)
        local b = BAGS[bag]
        if b and b.items and b.items[slot] then
            table.insert(SOLD, b.items[slot].itemID)
            b.items[slot] = nil
        end
    end,
}

-- The bags actually equipped, keyed by inventory slot, and what each bag item
-- is. BAGS[n].slotFamily is the slot's claim; this is the truth.
BAG_ITEMS = {}
EQUIPPED_BAGS = {}
function GetInventoryItemID(unit, slot) return EQUIPPED_BAGS[slot] end

-- Items: [id] = { price = , classID = , bound = }
ITEMS = {}
ItemLocation = { CreateFromBagAndSlot = function(bag, slot) return { bag, slot } end }
C_Item = {
    GetItemInfo = function(key)
        local bagItem = BAG_ITEMS[key]
        if bagItem then
            return "Bag", nil, 1, nil, nil, nil, nil, nil, nil, nil, 0,
                   bagItem.classID or 1, bagItem.subclassID or 0
        end
        local item = ITEMS[key]
        if not item then return nil end
        return item.name or "Item", nil, item.quality or 0, nil, nil, nil, nil, nil,
               nil, nil, item.price or 0, item.classID or 0, nil, nil, nil, nil,
               item.craftingReagent or false
    end,
    GetItemFamily = function(itemID)
        local bag = BAG_ITEMS[itemID]
        return bag and bag.family or 0
    end,
    -- Bag items answer GetItemInfo like any other item: class 1 = Container
    -- (subclass 0 plain, anything else a profession bag), class 11 = quiver.
    GetItemInfoForBag = true,
    IsBound = function(loc)
        local b = BAGS[loc[1]]
        local item = b and b.items and b.items[loc[2]]
        return item and item.bound or false
    end,
}
Enum = {
    ItemClass = { Weapon = 2, Armor = 4 },
    QuestFrequency = { Default = 1, Daily = 2, Weekly = 3 },
    BagIndex = { ReagentBag = 5 },
}
NUM_BAG_SLOTS = 4

C_CurrencyInfo = { GetCoinText = function(amount) return amount .. " copper" end }

-- Merchant.
MerchantFrame = Mock()
MERCHANT_CAN_REPAIR = true
REPAIR_COST = 500
REPAIRED = {}
function CanMerchantRepair() return MERCHANT_CAN_REPAIR end
-- CAN_AFFORD and GUILD_PAYS say whether each purse covers the bill; a repair
-- that goes through leaves nothing more to pay.
CAN_AFFORD, GUILD_PAYS = true, true
function GetRepairAllCost() return REPAIR_COST, CAN_AFFORD and REPAIR_COST > 0 end
function RepairAllItems(useGuild)
    table.insert(REPAIRED, useGuild and "guild" or "self")
    if (useGuild and GUILD_PAYS) or (not useGuild and CAN_AFFORD) then REPAIR_COST = 0 end
end
function IsInGuild() return IN_GUILD end
function CanGuildBankRepair() return GUILD_CAN_REPAIR end
IN_GUILD, GUILD_CAN_REPAIR = false, false

-- Loot.
LOOT_SLOTS = 0
LOOTED = {}
AUTOLOOT_CVAR = true
AUTOLOOT_MODIFIED = false
function GetNumLootItems() return LOOT_SLOTS end
function LootSlot(i) table.insert(LOOTED, i) end
function GetCVarBool(name) return AUTOLOOT_CVAR end
function IsModifiedClick(name) return AUTOLOOT_MODIFIED end

CVARS = {}
function SetCVar(name, value) CVARS[name] = value end

-- Quests.
NPC_GUID = "Creature-0-1-2-3-99999-0000"
function UnitGUID(unit) return NPC_GUID end
function UnitExists(unit) return true end
QUEST_GOLD_REQUIRED = 0
function GetQuestMoneyToGet() return QUEST_GOLD_REQUIRED end
QUEST_COMPLETABLE = true
function IsQuestCompletable() return QUEST_COMPLETABLE end
QUEST_ACTIONS = {}
function CompleteQuest() table.insert(QUEST_ACTIONS, "CompleteQuest") end
function AcceptQuest() table.insert(QUEST_ACTIONS, "AcceptQuest") end
function CloseQuest() table.insert(QUEST_ACTIONS, "CloseQuest") end
function GetQuestReward(i) table.insert(QUEST_ACTIONS, "GetQuestReward:" .. tostring(i)) end
function QuestGetAutoAccept() return false end
function QuestIsDaily() return QUEST_IS_DAILY end
function QuestIsWeekly() return false end
QUEST_IS_DAILY = false
NUM_QUEST_CHOICES = 1
function GetNumQuestChoices() return NUM_QUEST_CHOICES end
C_GossipInfo = {
    GetOptions = function() return {} end,
    GetActiveQuests = function() return {} end,
    GetAvailableQuests = function() return {} end,
    SelectActiveQuest = function(id) table.insert(QUEST_ACTIONS, "SelectActive:" .. id) end,
    SelectAvailableQuest = function(id) table.insert(QUEST_ACTIONS, "SelectAvailable:" .. id) end,
}

PRINTED = {}
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(PRINTED, table.concat(parts, " "))
end
'''

LOAD = r'''
NS = {}
SUITE_TABLE = { ChairPlus = NS }
SUITE_TABLE.UnitFullName = function(unit) local ok, a, b = pcall(UnitName, unit) if not ok or a == nil then return nil end a = tostring(a) if b ~= nil and tostring(b) ~= "" then return a .. " " .. tostring(b) end return a end
local files = {
    "Core.lua", "Config.lua", "OSD.lua", "StatusBars.lua", "Quests.lua", "Gossip.lua",
    "Vendor.lua", "Restock.lua", "Cooldowns.lua", "Loot.lua", "FlightData.lua", "Flight.lua", "Camera.lua", "Arrow.lua",
    "Threat.lua", "Nameplates.lua", "Tooltips.lua", "Mail.lua", "Social.lua", "Invite.lua", "LFG.lua", "Movers.lua", "Backup.lua", "Commands.lua",
}
for _, file in ipairs(files) do
    local chunk, err = loadfile("ChairPlus/" .. file)
    if not chunk then error("load " .. file .. ": " .. tostring(err)) end
    chunk("Chaircraft", SUITE_TABLE)
end

function BOOT()
    FireEvent("ADDON_LOADED", "Chaircraft")
    FireEvent("PLAYER_LOGIN")
end
'''

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        failures.append(name)


print("Parsing every Lua file as 5.1")
lua = lua51.LuaRuntime(unpack_returned_tuples=True)
for path in sorted(glob.glob("ChairPlus/*.lua")):
    ok, err = lua.eval(
        "function(p) local c, e = loadfile(p) return c ~= nil, tostring(e) end")(path)
    check(f"{path} parses", ok is True, str(err))

if failures:
    print("\nSyntax errors -- stopping here.")
    sys.exit(1)


# Every feature ships off, and nearly every test here is about a feature doing
# its job. So the harness switches the master toggles on through the baked
# layer -- below saved settings, so a test that saves a value still wins --
# and the tests about the shipped defaults ask for stock=True.
MASTER_TOGGLES = ("osd", "quests", "autoGossip", "sellJunk", "repairGear",
                  "fasterLoot", "flight", "maxCameraZoom")


def fresh(stock=False):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    rt.execute(LOAD)
    if not stock:
        for key in MASTER_TOGGLES:
            rt.execute(f'NS.baked["{key}"] = true')
    return rt, rt.globals()


print("\nSettings layering")
rt, g = fresh(stock=True)
g.ChairPlusDB = None
rt.execute("BOOT()")
ns = g.NS
check("every feature defaults off",
      all(ns.IsEnabled(key) is False for key in MASTER_TOGGLES))
check("but the options under them keep their values",
      ns.IsEnabled("osdMoney") is True and ns.IsEnabled("questsTurnIn") is True)
check("guild repair defaults off", ns.IsEnabled("repairGuildFunds") is False)
check("cold start is reported", g.NS.savedWasEmpty is True)

rt, g = fresh()
rt.execute('NS.baked["repairGuildFunds"] = true')
rt.execute('NS.baked["osdFontSize"] = 18')
rt.execute("BOOT()")
check("baked value wins over default", g.NS.IsEnabled("repairGuildFunds") is True)
check("baked number applies", g.NS.Get("osdFontSize") == 18)

rt, g = fresh()
rt.execute('ChairPlusDB = { settings = { sellJunk = false, osdFontSize = 20 } }')
rt.execute('NS.baked["osdFontSize"] = 18')
rt.execute("BOOT()")
check("saved value wins over baked", g.NS.Get("osdFontSize") == 20)
check("saved off survives", g.NS.IsEnabled("sellJunk") is False)
check("not flagged as cold start", g.NS.savedWasEmpty is False)

rt, g = fresh()
rt.execute('ChairPlusDB = { settings = { sellJunk = "yes", bogusKey = true } }')
rt.execute("BOOT()")
check("wrong-typed saved value ignored", g.NS.IsEnabled("sellJunk") is True)
check("unknown saved key ignored", g.NS.Get("bogusKey") is None)

print("\nNumber laundering")
rt, g = fresh()
rt.execute("BOOT()")
check("fraction survives (0.3 stays 0.3)", abs(g.NS.Num(0.3) - 0.3) < 1e-9,
      f"got {g.NS.Num(0.3)}")
check("loot delay default intact", abs(g.NS.Get("fasterLootDelay") - 0.3) < 1e-9)
check("integer survives", g.NS.Num(123456789) == 123456789)
check("non-number rejected", g.NS.Num("12") is None)

print("\nOSD line")
rt, g = fresh()
g.MONEY = 23 * 10000 + 15 * 100 + 19
rt.execute("""
BAGS[0] = { size = 16, family = 0, items = { [1] = { itemID = 1 } } }
BAGS[1] = { size = 10, family = 0, items = {} }
-- A herb bag: it counts as one because the BAG is a herb bag, not because
-- the slot says so. ContainerIDToInventoryID(2) is 21 in this harness.
BAG_ITEMS[900] = { classID = 1, subclassID = 2 }
EQUIPPED_BAGS[21] = 900
BAGS[2] = { size = 20, family = 4, items = {} }
BOOT()
DRIVER_TICK()
""")
text = rt.eval("ChairPlusOSD and _G.ChairPlusOSD") and rt.eval("NS.OSDLine()")
print(f"    line: {text}")
check("gold amount shown", text is not None and re.search(r"UI-GoldIcon[^|]*\|t 23", text) is not None)
check("silver amount shown", text is not None and re.search(r"UI-SilverIcon[^|]*\|t 15", text) is not None)
check("copper amount shown", text is not None and re.search(r"UI-CopperIcon[^|]*\|t 19", text) is not None)
check("icon precedes its number", text is not None and text.strip().startswith("|T"))
# 15 free in bag 0, 10 in bag 1, herb bag excluded.
check("free slots exclude profession bags",
      text is not None and re.search(r"INV_Misc_Bag_08[^|]*\|t 25", text) is not None)

check("profession bags counted separately",
      text is not None and re.search(r"INV_Misc_Bag_09[^|]*\|t 20", text) is not None,
      f"line: {text}")
check("the two bag counts are never added together",
      text is not None and "45" not in text and "36" not in text, f"line: {text}")

# No profession bag equipped: the second count is absent, not a standing zero.
rt, g = fresh()
g.MONEY = 0
rt.execute("""
BAGS[0] = { size = 16, family = 0, items = {} }
BAGS[1] = { size = 10, family = 0, items = {} }
BOOT()
DRIVER_TICK()
""")
text = rt.eval("NS.OSDLine()")
check("no profession bag means no second count",
      text is not None and "INV_Misc_Bag_09" not in text, f"line: {text}")
check("general count still right", 
      text is not None and re.search(r"INV_Misc_Bag_08[^|]*\|t 26", text) is not None,
      f"line: {text}")

# A full profession bag still reports, because zero free is real information.
rt, g = fresh()
g.MONEY = 0
rt.execute("""
BAGS[0] = { size = 16, family = 0, items = {} }
BAG_ITEMS[900] = { classID = 1, subclassID = 2 }
EQUIPPED_BAGS[21] = 900
BAGS[2] = { size = 2, family = 4, items = { [1] = { itemID = 1 }, [2] = { itemID = 2 } } }
BOOT()
DRIVER_TICK()
""")
text = rt.eval("NS.OSDLine()")
check("a full profession bag shows zero",
      text is not None and re.search(r"INV_Misc_Bag_09[^|]*\|t 0", text) is not None,
      f"line: {text}")

print("")
print("Default position")
rt, g = fresh()
rt.execute("BOOT()")
check("defaults to the centre of the screen",
      g.NS.Get("osdAnchor") == "CENTER" and g.NS.Get("osdRelAnchor") == "CENTER",
      f'{g.NS.Get("osdAnchor")} / {g.NS.Get("osdRelAnchor")}')
check("with no offset", g.NS.Get("osdX") == 0 and g.NS.Get("osdY") == 0)
check("display is locked by default", g.NS.IsEnabled("osdLocked") is True)
rt.execute('SlashCmdList["CHAIRPLUS"]("osd unlock")')
check("unlock enables the mouse", g.NS.IsEnabled("osdLocked") is False)
rt.execute('NS.SetMany({ osdAnchor = "TOPLEFT", osdRelAnchor = "TOPLEFT", osdX = 5, osdY = 5 })')
rt.execute('SlashCmdList["CHAIRPLUS"]("osd reset")')
check("reset returns to the shipped position",
      g.NS.Get("osdAnchor") == "CENTER" and g.NS.Get("osdX") == 0 and g.NS.Get("osdY") == 0)

print("\nUnreadable money degrades instead of crashing")
rt, g = fresh()
rt.execute("""
GetMoney = function() return setmetatable({}, {}) end
BAGS[0] = { size = 16, family = 0, items = {} }
BOOT()
DRIVER_TICK()
""")
text = rt.eval("NS.OSDLine()")
check("money shows placeholder, bags still read",
      text is not None and "|t --" in text and re.search(r"INV_Misc_Bag_08[^|]*\|t 16", text) is not None,
      f"line: {text}")

print("\nSelling junk")
rt, g = fresh()
rt.execute("""
ITEMS[101] = { quality = 0, price = 50, classID = 9 }
ITEMS[102] = { quality = 2, price = 900, classID = 2 }
ITEMS[103] = { quality = 0, price = 0, classID = 9 }
BAGS[0] = { size = 4, family = 0, items = {
    [1] = { itemID = 101, quality = 0, stackCount = 2, hasNoValue = false },
    [2] = { itemID = 102, quality = 2, stackCount = 1, hasNoValue = false },
    [3] = { itemID = 103, quality = 0, stackCount = 1, hasNoValue = true },
} }
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(3)
""")
sold = list(rt.eval("SOLD").values())
check("grey item sold", 101 in sold)
check("green item kept", 102 not in sold)
check("valueless grey kept", 103 not in sold)
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("summary counts stack (50 x 2)", "100 copper" in printed, printed)

# Buyback holds twelve: a visit sells no more, so all of it can come back.
rt, g = fresh()
rt.execute("""
BAGS[0] = { size = 16, family = 0, items = {} }
for i = 1, 14 do
    ITEMS[600 + i] = { quality = 0, price = 1, classID = 9 }
    BAGS[0].items[i] = { itemID = 600 + i, quality = 0, stackCount = 1, hasNoValue = false }
end
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(3)
""")
sold = list(rt.eval("SOLD").values())
check("no more than twelve sold in one visit", len(set(sold)) == 12, len(set(sold)))
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("and it says the rest waits", "bought back" in printed, printed[-200:])

rt, g = fresh()
rt.execute("""
ITEMS[201] = { quality = 0, price = 10, classID = 9 }
NS.blockedItems[201] = "keep me"
BAGS[0] = { size = 2, family = 0, items = {
    [1] = { itemID = 201, quality = 0, stackCount = 1, hasNoValue = false },
} }
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(3)
""")
check("blocked item never sold", len(list(rt.eval("SOLD").values())) == 0)

rt, g = fresh()
rt.execute("""
ITEMS[301] = { quality = 0, price = 10, classID = 2 }  -- a grey weapon
ITEMS[302] = { quality = 0, price = 10, classID = 2 }
BAGS[0] = { size = 4, family = 0, items = {
    [1] = { itemID = 301, quality = 0, stackCount = 1, hasNoValue = false, bound = false },
    [2] = { itemID = 302, quality = 0, stackCount = 1, hasNoValue = false, bound = true },
} }
NS.baked["sellJunkKeepGear"] = true
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(3)
""")
sold = list(rt.eval("SOLD").values())
check("unbound grey gear held back", 301 not in sold)
check("soulbound grey gear still sold", 302 in sold)

rt, g = fresh()
rt.execute("""
ITEMS[401] = { quality = 0, price = 10, classID = 9 }
BAGS[0] = { size = 2, family = 0, items = {
    [1] = { itemID = 401, quality = 0, stackCount = 1, hasNoValue = false },
} }
BOOT()
SHIFT = true
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(3)
""")
check("shift suppresses selling", len(list(rt.eval("SOLD").values())) == 0)
check("shift suppresses repair", len(list(rt.eval("REPAIRED").values())) == 0)

print("\nRepair")
rt, g = fresh()
rt.execute("BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW')")
repaired = list(rt.eval("REPAIRED").values())
check("repairs with own gold by default", repaired == ["self"], str(repaired))

rt, g = fresh()
rt.execute("""
IN_GUILD, GUILD_CAN_REPAIR = true, true
NS.baked["repairGuildFunds"] = true
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
""")
repaired = list(rt.eval("REPAIRED").values())
check("guild funds tried first, then own", repaired == ["guild", "self"], str(repaired))

rt, g = fresh()
rt.execute("IN_GUILD, GUILD_CAN_REPAIR = true, true BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW')")
repaired = list(rt.eval("REPAIRED").values())
check("guild funds untouched when option off", repaired == ["self"], str(repaired))

rt, g = fresh()
rt.execute("REPAIR_COST = 0 BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW')")
check("no repair when nothing to pay", len(list(rt.eval("REPAIRED").values())) == 0)

# Short of gold, the guild still pays: the gold check used to come first.
rt, g = fresh()
rt.execute("""
IN_GUILD, GUILD_CAN_REPAIR, CAN_AFFORD = true, true, false
NS.baked["repairGuildFunds"] = true
BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW')
""")
repaired = list(rt.eval("REPAIRED").values())
check("short of gold, guild funds still repair", repaired == ["guild"], str(repaired))
rt.execute("RUN_TIMERS(6)")
check("and the repair is reported", "Repaired for" in "\n".join(str(v) for v in rt.eval("PRINTED").values()))

rt, g = fresh()
rt.execute("CAN_AFFORD = false BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW') RUN_TIMERS(8)")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("a repair that cannot be paid for is not reported as done",
      "Repaired for" not in printed, printed[-200:])
check("but as not done, once the checks run out", "Could not repair" in printed, printed[-200:])

# The server answers a repair a moment later: the cost read straight after
# RepairAllItems is still the old one.
rt, g = fresh()
rt.execute("""
function RepairAllItems(useGuild)
    table.insert(REPAIRED, useGuild and "guild" or "self")
    C_Timer.After(0.5, function() REPAIR_COST = 0 end)
end
NS.Set("repairSummary", true)
BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW')
""")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("nothing is said before the server answers", "repair" not in printed.lower(), printed[-200:])
rt.execute("RUN_TIMERS(8)")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("a repair the server confirms late is reported as done",
      "Repaired for" in printed and "Could not repair" not in printed, printed[-200:])

rt, g = fresh()
rt.execute("CAN_AFFORD = false BOOT() MerchantFrame:Show() FireEvent('MERCHANT_SHOW') FireEvent('MERCHANT_CLOSED') RUN_TIMERS(8)")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("leaving the merchant before the answer says nothing", "repair" not in printed.lower(), printed[-200:])

print("\nQuest safety gates")
rt, g = fresh()
rt.execute("BOOT() FireEvent('QUEST_PROGRESS')")
check("completable quest is turned in",
      "CompleteQuest" in list(rt.eval("QUEST_ACTIONS").values()))

rt, g = fresh()
rt.execute("QUEST_GOLD_REQUIRED = 5000 BOOT() FireEvent('QUEST_PROGRESS')")
check("quest wanting gold is left alone",
      "CompleteQuest" not in list(rt.eval("QUEST_ACTIONS").values()))

rt, g = fresh()
rt.execute("NUM_QUEST_CHOICES = 3 BOOT() FireEvent('QUEST_COMPLETE')")
actions = list(rt.eval("QUEST_ACTIONS").values())
check("multiple rewards left for the player",
      not any(str(a).startswith("GetQuestReward") for a in actions), str(actions))

rt, g = fresh()
rt.execute("NUM_QUEST_CHOICES = 1 BOOT() FireEvent('QUEST_COMPLETE')")
actions = list(rt.eval("QUEST_ACTIONS").values())
check("single reward taken", any(str(a).startswith("GetQuestReward") for a in actions), str(actions))

rt, g = fresh()
rt.execute('NPC_GUID = "Creature-0-1-2-3-15192-0000" BOOT() FireEvent("QUEST_PROGRESS")')
check("blocked NPC is never turned in for",
      "CompleteQuest" not in list(rt.eval("QUEST_ACTIONS").values()))

rt, g = fresh()
rt.execute("SHIFT = true BOOT() FireEvent('QUEST_DETAIL')")
check("shift suppresses quest automation",
      "AcceptQuest" not in list(rt.eval("QUEST_ACTIONS").values()))

rt, g = fresh()
rt.execute("BOOT() FireEvent('QUEST_DETAIL')")
check("quest accepted normally",
      "AcceptQuest" in list(rt.eval("QUEST_ACTIONS").values()))

rt, g = fresh()
rt.execute('QUEST_IS_DAILY = true NS.baked["questsDaily"] = false BOOT() FireEvent("QUEST_DETAIL")')
check("daily declined when dailies are off",
      "AcceptQuest" not in list(rt.eval("QUEST_ACTIONS").values()))

print("\nFaster loot")
rt, g = fresh()
rt.execute("LOOT_SLOTS = 3 BOOT() FireEvent('LOOT_READY')")
looted = list(rt.eval("LOOTED").values())
check("loots every slot backwards", looted == [3, 2, 1], str(looted))

rt, g = fresh()
rt.execute("LOOT_SLOTS = 3 AUTOLOOT_MODIFIED = true BOOT() FireEvent('LOOT_READY')")
check("modifier key leaves the loot window alone",
      len(list(rt.eval("LOOTED").values())) == 0)

rt, g = fresh()
rt.execute("LOOT_SLOTS = 2 BOOT() FireEvent('LOOT_READY') FireEvent('LOOT_READY')")
check("second LOOT_READY in the same instant is throttled",
      len(list(rt.eval("LOOTED").values())) == 2)

# Full bags: coin and currency still come, items wait in the window.
rt, g = fresh()
rt.execute("""
LOOT_TYPES = { [1] = 1, [2] = 2, [3] = 3 }   -- item, money, currency
function GetLootSlotType(i) return LOOT_TYPES[i] end
BOOT()
NS.FreeBagSlots = function() return 0, 0, false, 16, 0 end
LOOT_SLOTS = 3 FireEvent('LOOT_READY')
""")
looted = sorted(rt.eval("LOOTED").values())
check("with bags full, coin and currency are still taken", looted == [2, 3], str(looted))

print("\nCamera")
rt, g = fresh()
rt.execute("BOOT()")
check("zoom factor raised", rt.eval('CVARS["cameraDistanceMaxZoomFactor"]') == 2.6)
rt.execute('NS.Set("maxCameraZoom", false)')
check("zoom factor restored when switched off",
      rt.eval('CVARS["cameraDistanceMaxZoomFactor"]') == 1.9)
rt, g = fresh(stock=True)
rt.execute('BOOT() CVARS["cameraDistanceMaxZoomFactor"] = 2.2 NS.Set("osdFontSize", 14)')
check("left off, the player's own zoom is never touched",
      rt.eval('CVARS["cameraDistanceMaxZoomFactor"]') == 2.2)

print("\nToggling off unhooks")
rt, g = fresh()
rt.execute("BOOT()")
rt.execute('NS.Set("fasterLoot", false)')
rt.execute("LOOT_SLOTS = 3 FireEvent('LOOT_READY')")
check("loot module stops listening", len(list(rt.eval("LOOTED").values())) == 0)
rt.execute('NS.Set("fasterLoot", true)')
rt.execute("NOW = 2000 FireEvent('LOOT_READY')")
check("and starts again when switched back on", len(list(rt.eval("LOOTED").values())) == 3)

rt, g = fresh()
rt.execute("BOOT()")
rt.execute('NS.Set("sellJunk", false) NS.Set("repairGear", false)')
rt.execute("MerchantFrame:Show() FireEvent('MERCHANT_SHOW')")
check("merchant frame unhooks when both are off",
      len(list(rt.eval("REPAIRED").values())) == 0)

print("\nCommands")
rt, g = fresh()
rt.execute("BOOT()")
rt.execute('SlashCmdList["CHAIRPLUS"]("off sellJunk")')
check("slash toggles an option off", g.NS.IsEnabled("sellJunk") is False)
rt.execute('SlashCmdList["CHAIRPLUS"]("on selljunk")')
check("option name is case insensitive", g.NS.IsEnabled("sellJunk") is True)
rt.execute('SlashCmdList["CHAIRPLUS"]("delay 0.1")')
check("delay accepts a fraction", abs(g.NS.Get("fasterLootDelay") - 0.1) < 1e-9,
      str(g.NS.Get("fasterLootDelay")))
rt.execute('SlashCmdList["CHAIRPLUS"]("delay 9")')
check("out-of-range delay refused", abs(g.NS.Get("fasterLootDelay") - 0.1) < 1e-9)

rt, g = fresh()
rt.execute("BOOT()")
rt.execute('NS.Set("repairGuildFunds", true)')
rt.execute('SlashCmdList["CHAIRPLUS"]("bake")')
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("bake prints a pasteable line", '["repairGuildFunds"] = true,' in printed, printed)
check("bake is parked in SavedVariables", rt.eval("ChairPlusDB.bakeHint") is not None)
baked_blob = rt.eval("ChairPlusDB.bakeHint")
ok, err = lua.eval(
    "function(s) local c, e = loadstring('local ns = {} ' .. s) return c ~= nil, tostring(e) end"
)(baked_blob)
check("baked output is valid Lua", ok is True, str(err))

rt, g = fresh()
rt.execute("BOOT()")
rt.execute('SlashCmdList["CHAIRPLUS"]("")')
# Reported 2026-09-22: the menu did nothing until the command was typed a
# second time. A frame is shown the moment it is created, so BuildPanel left it
# "shown", the toggle saw that and hid it, and the first press was swallowed.
check("panel builds without option templates",
      rt.eval("ChairPlusPanel ~= nil and ChairPlusPanel:IsShown()") is True,
      "the first invocation did not open the menu")
rt.execute('SlashCmdList["CHAIRPLUS"]("")')
check("and a second invocation closes it again",
      rt.eval("ChairPlusPanel:IsShown()") is False)
rt.execute('SlashCmdList["CHAIRPLUS"]("")')
check("and a third opens it once more",
      rt.eval("ChairPlusPanel:IsShown()") is True)

# The sidebar lists every page, then every other part under TOOLS; the
# window is the sidebar plus two columns of settings, and tall enough for
# the whole list.
rt, g = fresh()
rt.execute('''
SUITE_TABLE.parts = {}
for _, key in ipairs({ "chairplus", "chairauras", "chairsnack", "chairtracker", "chairignore" }) do
    table.insert(SUITE_TABLE.parts, { key = key, title = "Chair" .. key, route = "/chair", Open = function() end })
end
BOOT() SlashCmdList["CHAIRPLUS"]("")
''')
width = rt.eval("rawget(ChairPlusPanel, '_w')")
check("the menu is the sidebar plus two columns wide", width == 160 + 540, width)
check("every other part has a line in the sidebar",
      all(rt.eval("SHOWN_BUTTON(%r)" % t) is True for t in ("chairauras", "chairsnack", "chairtracker", "chairignore")))
rt.execute('SlashCmdList["CHAIRPLUS"]("status")')
check("status prints without error",
      any("sellJunk" in str(v) for v in rt.eval("PRINTED").values()))

print("")
print("Profession bag counting")

# The bug reported in game on 2026-09-22: the profession count showed 0 while
# the profession bag had 5 free. The slot's own claim about its family is not
# the bag's -- an empty typed slot answers with a family and no free slots,
# which both made the count appear AND pushed the real bag into the general
# total.
rt, g = fresh()
rt.execute("""
BAG_ITEMS[5000] = { classID = 1, subclassID = 2 }   -- a herb bag
EQUIPPED_BAGS[20] = 5000                            -- equipped in bag 1
BAGS[0] = { size = 16, family = 0, items = {} }
BAGS[1] = { size = 5,  slotFamily = 0, items = {} } -- slot lies: says generic
BOOT()
DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()")
check("a profession bag is counted by what it IS, not what the slot says",
      line is not None and re.search(r"INV_Misc_Bag_09[^|]*\|t 5", line) is not None,
      f"line: {line}")
check("and its slots are kept out of the general count",
      line is not None and re.search(r"INV_Misc_Bag_08[^|]*\|t 16", line) is not None,
      f"line: {line}")

# The other half: a typed but EMPTY slot must not make the count appear at all.
rt, g = fresh()
rt.execute("""
BAGS[0] = { size = 16, family = 0, items = {} }
BAGS[5] = { size = 0, slotFamily = 2048, items = {} }  -- empty reagent slot
BOOT()
DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()")
check("an empty typed slot does not produce a phantom 0",
      line is not None and "INV_Misc_Bag_09" not in line, f"line: {line}")


# The exact shape of the live report on 2026-09-22: 29 general, 5 profession,
# shown as 34 and 0. The detection must not depend on GetItemFamily, because
# this client does not have it -- requiring it is what made the previous fix a
# no-op, leaving the old slot-family behaviour in place.
rt, g = fresh()
rt.execute("""
C_Item.GetItemFamily = nil                          -- as on the live client
BAG_ITEMS[5000] = { classID = 1, subclassID = 2 }   -- herb bag, 5 free
EQUIPPED_BAGS[22] = 5000
BAGS[0] = { size = 16, family = 0, items = {} }
BAGS[1] = { size = 8,  slotFamily = 0, items = {} }
BAGS[2] = { size = 5,  slotFamily = 0, items = {} }
BAGS[3] = { size = 5,  slotFamily = 0, items = {} } -- the herb bag
BAGS[5] = { size = 0,  slotFamily = 2048, items = {} }  -- empty reagent slot
BOOT()
DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()")
check("29 free general slots are reported as 29, not 34",
      line is not None and re.search(r"INV_Misc_Bag_08[^|]*\|t 29", line) is not None,
      f"line: {line}")
check("and the 5 profession slots are reported as 5, not 0",
      line is not None and re.search(r"INV_Misc_Bag_09[^|]*\|t 5", line) is not None,
      f"line: {line}")

# Without GetItemFamily AND without GetItemInfo, an unidentifiable bag must
# fall back to generic rather than inventing a profession count.
rt, g = fresh()
rt.execute("""
C_Item.GetItemFamily = nil
C_Item.GetItemInfo = nil
BAGS[0] = { size = 16, family = 0, items = {} }
BAGS[5] = { size = 0, slotFamily = 2048, items = {} }
BOOT()
DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()")
check("with no item APIs at all, no phantom profession count appears",
      line is not None and "INV_Misc_Bag_09" not in line, f"line: {line}")

print("")
print("Flight path timer")

FLIGHT_HARNESS = """
-- The flight driver throttles itself to four ticks a second, so the shared
-- harness tick of 0.1s would never reach it. Only this suite's runtime is
-- affected; each test gets a fresh one.
function DRIVER_TICK()
    for _, f in ipairs(FRAMES) do
        local s = rawget(f, "_scripts")
        if s and s.OnUpdate and rawget(f, "_shown") then s.OnUpdate(f, 0.3) end
    end
end

ON_TAXI = false
-- UnitOnTaxi is the call that exists here; IsOnTaxi is the one the first
-- version assumed and this client does not provide.
function UnitOnTaxi(unit) return ON_TAXI end

-- The classic flight map API. TaxiNodeGetType says which node we are standing
-- at; the rest are destinations.
NODES = {
    { name = "Stormwind, Elwynn", kind = "CURRENT" },
    { name = "Ironforge, Dun Morogh", kind = "REACHABLE" },
    { name = "Menethil, Wetlands", kind = "REACHABLE" },
}
function NumTaxiNodes() return #NODES end
function TaxiNodeName(i) return NODES[i] and NODES[i].name end
function TaxiNodeGetType(i) return NODES[i] and NODES[i].kind end
function TakeTaxiNode(i) end

HOOKS = {}
function hooksecurefunc(name, fn) HOOKS[name] = fn end
function TaxiNodeOnButtonEnter(button) end

TOOLTIP_LINES = {}
GameTooltip = {
    AddLine = function(self, text) table.insert(TOOLTIP_LINES, text) end,
    Show = function() end,
}

-- Fly from the current node to node `slot`, taking `seconds`.
function FLY(slot, seconds)
    HOOKS.TakeTaxiNode(slot)
    ON_TAXI = true
    DRIVER_TICK()
    NOW = NOW + seconds
    DRIVER_TICK()
    ON_TAXI = false
    DRIVER_TICK()
end

function TIMER_TEXT()
    local f = _G.ChairPlusFlightTimer
    if not f or not f:IsShown() then return nil end
    for _, frame in ipairs(FRAMES) do
        local t = rawget(frame, "_text")
        -- Anchored: the OSD's inline textures contain "14:14:0:0", which an
        -- unanchored clock pattern happily matches.
        if t and (t:match("^%d+:%d%d") or t:match("^|cffffd100%+")) then
            return t
        end
    end
    return nil
end
"""


def flight(setup="", hardcoded=False):
    rt, g = fresh()
    rt.execute(FLIGHT_HARNESS)
    # The real FlightData.lua knows Stormwind to Ironforge, and most of the
    # tests here are about a route nobody has a time for yet.
    if not hardcoded:
        rt.execute("NS.flightData = {}")
    rt.execute(setup)
    rt.execute("BOOT()")
    return rt


rt = flight()
check("the taxi hooks are installed", rt.eval("HOOKS.TakeTaxiNode ~= nil") is True)
check("it found the call this client actually has",
      str(rt.eval("NS.FlightStatus().taxiProbe")) == "UnitOnTaxi",
      str(rt.eval("NS.FlightStatus().taxiProbe")))

# The bug: the first version hardcoded IsOnTaxi(), which is absent here, so
# every flight silently did nothing at all.
rt2 = flight("UnitOnTaxi = nil IsOnTaxi = function() return ON_TAXI end")
check("it falls back to IsOnTaxi where that is what exists",
      str(rt2.eval("NS.FlightStatus().taxiProbe")) == "IsOnTaxi",
      str(rt2.eval("NS.FlightStatus().taxiProbe")))
rt2.execute("FLY(2, 150)")
check("and still records through the fallback",
      rt2.eval("next(ChairPlusDB.flights) ~= nil") is True)

# With no way to tell at all it must say so, not sit quiet.
rt3 = flight("UnitOnTaxi = nil IsOnTaxi = nil UnitInVehicle = nil")
printed = chr(10).join(str(v) for v in rt3.eval("PRINTED").values())
check("with no taxi call at all it refuses out loud",
      "Flight timer off" in printed, printed[:160])
check("and reports no probe", rt3.eval("NS.FlightStatus().taxiProbe") is None,
      str(rt3.eval("NS.FlightStatus().taxiProbe")))

rt.execute("FLY(2, 150)")
check("a flight is recorded under source and destination",
      rt.eval('ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"] ~= nil')
      is True,
      str(rt.eval("ChairPlusDB.flights")))
entry = 'ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"]'
check("with the measured time", rt.eval(entry + ".base") == 150)
check("and one sample", rt.eval(entry + ".n") == 1)

# A route takes what it takes. Flying it again must not move the stored time.
rt.execute("FLY(2, 150)")
check("a second identical flight leaves the base alone",
      rt.eval(entry + ".base") == 150, str(rt.eval(entry + ".base")))
check("but the flight is counted", rt.eval(entry + ".n") == 2)

# Small jitter is the clock starting and stopping, not a speed change.
rt.execute("FLY(2, 151)")
check("a second of jitter is ignored", rt.eval(entry + ".base") == 150)
check("and does not move the speed factor",
      rt.eval("ChairPlusDB.flightSpeed == nil or ChairPlusDB.flightSpeed == 1")
      is True, str(rt.eval("ChairPlusDB.flightSpeed")))

print("")
print("A /reload in the air")
CLOCK = "SERVER = 1000 function GetServerTime() return SERVER end "
rt = flight(CLOCK)
rt.execute("HOOKS.TakeTaxiNode(2) ON_TAXI = true DRIVER_TICK()")
check("taking off on a known route writes it down",
      rt.eval("ChairPlusDB.flightInFlight and ChairPlusDB.flightInFlight.dest") == "Ironforge, Dun Morogh")
who = rt.eval("ChairPlusDB.flightInFlight.who")
src = rt.eval("ChairPlusDB.flightInFlight.source")
note = f'{{ who = "{who}", at = 1000, source = "{src}", dest = "Ironforge, Dun Morogh" }}'
rt.execute("NOW = NOW + 150 SERVER = SERVER + 150 ON_TAXI = false DRIVER_TICK()")
check("landing clears it", rt.eval("ChairPlusDB.flightInFlight") is None)
check("and an ordinary flight is still recorded",
      rt.eval('ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"] ~= nil') is True)

# The reload: a fresh session, 60 seconds after takeoff, already on the taxi.
rt = flight(CLOCK + f"SERVER = 1060 ON_TAXI = true ChairPlusDB = {{ flightInFlight = {note} }}")
rt.execute("DRIVER_TICK()")
text = rt.eval("TIMER_TEXT()")
check("after the reload the clock carries on from the real takeoff", text is not None and text.startswith("01:0"), text)
check("for the same flight", "Ironforge" in str(text), text)
rt.execute("NOW = NOW + 90 SERVER = SERVER + 90 ON_TAXI = false DRIVER_TICK()")
check("landing does not record a flight timed across a reload",
      rt.eval('ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"]') is None)
check("and clears the note", rt.eval("ChairPlusDB.flightInFlight") is None)

rt = flight(CLOCK + "ON_TAXI = true ChairPlusDB = { flightInFlight = { who = \"someone else\", at = 1000, "
            "source = \"Stormwind, Elwynn\", dest = \"Ironforge, Dun Morogh\" } }")
rt.execute("DRIVER_TICK()")
check("another character's note is not picked up", "Ironforge" not in str(rt.eval("TIMER_TEXT()")))
rt = flight(CLOCK + f"SERVER = 1000 + 3600 ON_TAXI = true ChairPlusDB = {{ flightInFlight = {note} }}")
rt.execute("DRIVER_TICK()")
check("nor one too old to be this flight", "Ironforge" not in str(rt.eval("TIMER_TEXT()")))
rt = flight(CLOCK + f"ON_TAXI = false ChairPlusDB = {{ flightInFlight = {note} }}")
check("logging in on the ground clears a leftover note", rt.eval("ChairPlusDB.flightInFlight") is None)

print("")
print("Flight speed changes")
# A permanent speed increase scales every route by the same factor, so one
# flight over a known route measures it.
rt = flight()
rt.execute("FLY(2, 150)")
rt.execute("PRINTED = {} FLY(2, 120)")
check("a materially faster flight is read as a speed change",
      abs(rt.eval("ChairPlusDB.flightSpeed") - 0.8) < 0.001,
      str(rt.eval("ChairPlusDB.flightSpeed")))
check("and the base time is still untouched",
      rt.eval(entry + ".base") == 150, str(rt.eval(entry + ".base")))
printed = chr(10).join(str(v) for v in rt.eval("PRINTED").values())
check("the rescale is announced even with summaries off",
      "0.80x" in printed, printed)

# That factor then applies to routes never flown at the new speed.
rt.execute('NODES[1].kind = "REACHABLE" NODES[3].kind = "CURRENT"')
check("every estimate is rescaled by it",
      abs(rt.eval('(NS.FlightTime("Stormwind, Elwynn", "Ironforge, Dun Morogh"))')
          - 120) < 0.001,
      str(rt.eval('(NS.FlightTime("Stormwind, Elwynn", "Ironforge, Dun Morogh"))')))

# A new route learned while boosted is stored at base speed, so it is
# comparable with everything else.
rt = flight()
rt.execute("FLY(2, 150)")
rt.execute("FLY(2, 120)")          # speed factor becomes 0.8
rt.execute('NODES[2].kind = "REACHABLE" NODES[3].kind = "REACHABLE"')
rt.execute("FLY(3, 80)")           # a new route, flown while boosted
check("a route learned while boosted stores its unboosted base",
      abs(rt.eval('ChairPlusDB.flights["Stormwind, Elwynn > Menethil, Wetlands"].base')
          - 100) < 0.001,
      str(rt.eval('ChairPlusDB.flights["Stormwind, Elwynn > Menethil, Wetlands"].base')))

# A flight that went wrong is not a speed change.
rt = flight()
rt.execute("FLY(2, 150)")
rt.execute("FLY(2, 900)")
check("an absurd flight is not treated as a speed change",
      rt.eval("ChairPlusDB.flightSpeed == nil or ChairPlusDB.flightSpeed == 1")
      is True, str(rt.eval("ChairPlusDB.flightSpeed")))

# Routes are directional: the way back is its own entry.
rt = flight()
rt.execute("FLY(2, 150)")
rt.execute('NODES[1].kind = "REACHABLE" NODES[2].kind = "CURRENT"')
rt.execute("FLY(1, 140)")
check("the return trip is a separate route",
      rt.eval('ChairPlusDB.flights["Ironforge, Dun Morogh > Stormwind, Elwynn"].base')
      == 140,
      str(rt.eval('ChairPlusDB.flights["Ironforge, Dun Morogh > Stormwind, Elwynn"]')))

# A flight that never really happened must not poison the average.
rt = flight()
rt.execute("FLY(2, 2)")
check("a flight shorter than five seconds is not recorded",
      rt.eval("next(ChairPlusDB.flights) == nil") is True,
      str(rt.eval("ChairPlusDB.flights")))

print("")
print("Routes that change when a flight point is learned")
# The client reports the stops a flight will pass through. ROUTES[slot] lists
# the end of each hop in order. TaxiGetNodeSlot(slot, hop, true) is the hop's
# start and false its end, the way Blizzard's own flight map reads it -- the
# first version had that backwards, and so did this harness, so both passed.
ROUTE_HARNESS = """
table.insert(NODES, { name = "Thelsamar, Loch Modan", kind = "REACHABLE" })
ROUTES = { [2] = { 3, 2 }, [3] = { 3 }, [4] = { 4 } }
function GetNumRoutes(slot) return ROUTES[slot] and #ROUTES[slot] or 0 end
function TaxiGetNodeSlot(slot, hop, isSource)
    local hops = ROUTES[slot]
    if isSource then return hop == 1 and 1 or hops[hop - 1] end
    return hops[hop]
end
"""
VIA_MENETHIL = "Stormwind, Elwynn > Menethil, Wetlands > Ironforge, Dun Morogh"
VIA_THELSAMAR = "Stormwind, Elwynn > Thelsamar, Loch Modan > Ironforge, Dun Morogh"
ENDS = "Stormwind, Elwynn > Ironforge, Dun Morogh"

def flights(rt):
    return str(dict(rt.eval("ChairPlusDB.flights") or {}))

def tooltip(rt, slot):
    rt.execute("TOOLTIP_LINES = {} HOOKS.TaxiNodeOnButtonEnter({ slot = %d })" % slot)
    return chr(10).join(str(v) for v in rt.eval("TOOLTIP_LINES").values())

def speed_untouched(rt):
    return rt.eval("ChairPlusDB.flightSpeed == nil or ChairPlusDB.flightSpeed == 1") is True

rt = flight(ROUTE_HARNESS)
rt.execute("FLY(2, 200)")
check("a multi-hop flight is recorded under its whole path",
      rt.eval('ChairPlusDB.flights["%s"].base' % VIA_MENETHIL) == 200, flights(rt))
check("and not under its two ends",
      rt.eval('ChairPlusDB.flights["%s"] == nil' % ENDS) is True, flights(rt))
check("the tooltip reads the path time", "03:20" in tooltip(rt, 2), tooltip(rt, 2))

# The bug this fixes: a new flight point reroutes the same trip, it comes in
# faster, and the old code took that for a speed increase.
rt.execute("ROUTES[2] = { 4, 2 }")
check("a rerouted trip is not yet known", "not yet known" in tooltip(rt, 2), tooltip(rt, 2))
rt.execute("PRINTED = {} FLY(2, 150)")
check("it is learned as a new path",
      rt.eval('ChairPlusDB.flights["%s"].base' % VIA_THELSAMAR) == 150, flights(rt))
check("without touching the flight speed", speed_untouched(rt),
      str(rt.eval("ChairPlusDB.flightSpeed")))
printed = chr(10).join(str(v) for v in rt.eval("PRINTED").values())
check("or announcing a rescale", "rescaled" not in printed, printed)
check("and the old path keeps its own time",
      rt.eval('ChairPlusDB.flights["%s"].base' % VIA_MENETHIL) == 200, flights(rt))

# A real speed change still shows up on a path that is flown again.
rt.execute("FLY(2, 120)")
check("a faster flight over the same path is still a speed change",
      abs((rt.eval("ChairPlusDB.flightSpeed") or 0) - 0.8) < 0.001,
      str(rt.eval("ChairPlusDB.flightSpeed")))

# Times saved before paths were known are keyed by their two ends. They still
# give a countdown, but a trip measured against one is never a speed change.
rt = flight(ROUTE_HARNESS)
rt.execute('ChairPlusDB.flights["%s"] = { base = 180, n = 3 }' % ENDS)
check("an old two-ended time still shows for a multi-hop path",
      "03:00" in tooltip(rt, 2), tooltip(rt, 2))
rt.execute("FLY(2, 120)")
check("flying it is not read as a speed change", speed_untouched(rt),
      str(rt.eval("ChairPlusDB.flightSpeed")))
check("the path is recorded at what it took",
      rt.eval('ChairPlusDB.flights["%s"].base' % VIA_MENETHIL) == 120, flights(rt))
check("and the old time is left where it was",
      rt.eval('ChairPlusDB.flights["%s"].base' % ENDS) == 180, flights(rt))

# A direct flight's path key is its two-ended key, so nothing already recorded
# for one-hop routes is lost.
rt = flight(ROUTE_HARNESS)
rt.execute('ChairPlusDB.flights["Stormwind, Elwynn > Menethil, Wetlands"] = { base = 90, n = 2 }')
rt.execute("FLY(3, 90)")
check("a direct flight keeps using its existing time",
      rt.eval('ChairPlusDB.flights["Stormwind, Elwynn > Menethil, Wetlands"].n') == 3,
      flights(rt))

# Which way round the flag reads is not something to stake the path on.
rt = flight(ROUTE_HARNESS + """
local real = TaxiGetNodeSlot
function TaxiGetNodeSlot(slot, hop, flag) return real(slot, hop, not flag) end
""")
rt.execute("FLY(2, 200)")
check("the path reads the same with the flag the other way round",
      rt.eval('ChairPlusDB.flights["%s"].base' % VIA_MENETHIL) == 200, flights(rt))

# A hop that does not join on to the one before is not a path.
rt = flight(ROUTE_HARNESS + """
function TaxiGetNodeSlot(slot, hop, isSource) return isSource and 4 or 2 end
""")
rt.execute("FLY(2, 200)")
check("a chain that does not start here is not trusted",
      rt.eval('ChairPlusDB.flights["%s"].base' % ENDS) == 200, flights(rt))

# A path the client will not describe falls back to the two ends.
rt = flight(ROUTE_HARNESS + 'function TaxiGetNodeSlot() error("no") end')
rt.execute("FLY(2, 200)")
check("with no readable path the flight is keyed by its ends",
      rt.eval('ChairPlusDB.flights["%s"].base' % ENDS) == 200, flights(rt))

print("")
print("Hardcoded flight times")
# FlightData.lua keys a route by its stops' names, each cut at the first comma.
LISTED = """
FACTION = "Alliance"
function UnitFactionGroup() return FACTION end
"""
def said(rt):
    return " ".join(str(v) for v in rt.eval("PRINTED").values())


TEST_DATA = """
NS.flightData = {
    Alliance = {
        ["Stormwind > Ironforge"] = 150,
        ["Stormwind > Menethil > Ironforge"] = 210,
    },
    Horde = { ["Stormwind > Ironforge"] = 99 },
}
"""

rt = flight(LISTED, hardcoded=True)
check("the real table is loaded, both factions",
      rt.eval("NS.FlightHardcodedCount()") > 2000, str(rt.eval("NS.FlightHardcodedCount()")))
check("and holds Stormwind to Ironforge",
      rt.eval('NS.flightData.Alliance["Stormwind > Ironforge"]') == 216)
check("a never-flown route shows its hardcoded time on the map",
      "03:36" in tooltip(rt, 2), tooltip(rt, 2))

rt = flight(LISTED + TEST_DATA)
rt.execute("HOOKS.TakeTaxiNode(2) ON_TAXI = true DRIVER_TICK()")
check("taking it counts down from the hardcoded time instead of timing",
      (rt.eval("TIMER_TEXT()") or "").startswith("02:30"), str(rt.eval("TIMER_TEXT()")))
rt.execute("NOW = NOW + 151 DRIVER_TICK() ON_TAXI = false DRIVER_TICK()")
check("landing on time keeps the route, measured, without a fuss",
      rt.eval('ChairPlusDB.flights["%s"].base' % ENDS) == 151
      and "not the" not in said(rt), said(rt)[-200:])
check("and a hardcoded time is never taken for a speed change", speed_untouched(rt))
check("a flight that matches the list is not reported as new",
      rt.eval("(NS.FlightCorrections())") is None)

rt = flight(LISTED + TEST_DATA)
rt.execute("PRINTED = {} FLY(2, 170)")
check("a flight that disagrees with the table says so once",
      "not the 02:30 on file" in said(rt), said(rt)[-200:])
check("and its own time wins from then on", "02:50" in tooltip(rt, 2), tooltip(rt, 2))
check("without touching the flight speed", speed_untouched(rt))
check("and it is listed as a correction, in the datasheet's shape",
      "170, -- Stormwind, Ironforge (list had 150)" in str(rt.eval("(NS.FlightCorrections())")),
      str(rt.eval("(NS.FlightCorrections())")))
check("under its faction's heading",
      str(rt.eval("(NS.FlightCorrections())")).startswith("ALLIANCE"))

rt = flight(ROUTE_HARNESS + LISTED + TEST_DATA)
check("a multi-hop path is looked up by every stop on it",
      "03:30" in tooltip(rt, 2), tooltip(rt, 2))
rt.execute("ROUTES[2] = { 4, 2 }")
check("a path the table does not have is not guessed at",
      "not yet known" in tooltip(rt, 2), tooltip(rt, 2))
rt.execute("FLY(2, 300)")
check("and once flown it is listed as new",
      "300, -- Stormwind, Thelsamar, Ironforge (new)" in str(rt.eval("(NS.FlightCorrections())")),
      str(rt.eval("(NS.FlightCorrections())")))

rt = flight(LISTED + TEST_DATA + 'FACTION = "Horde"')
check("a Horde character reads the Horde table", "01:39" in tooltip(rt, 2), tooltip(rt, 2))
rt = flight(LISTED + TEST_DATA + 'FACTION = "Horde" NS.flightData.Horde = {}')
check("and falls back to the other side's for a route only it lists",
      "02:30" in tooltip(rt, 2), tooltip(rt, 2))

rt = flight(LISTED + """
FACTION = "Horde"
NODES = {
    { name = "The Sepulcher, Silverpine Forest", kind = "CURRENT" },
    { name = "Undercity, Tirisfal", kind = "REACHABLE" },
    { name = "Tarren Mill, Hillsbrad", kind = "REACHABLE" },
}
""", hardcoded=True)
check("the Sepulcher to Undercity finds the list's 112s",
      "01:52" in tooltip(rt, 2), tooltip(rt, 2))
check("and to Tarren Mill its 95s", "01:35" in tooltip(rt, 3), tooltip(rt, 3))
check("positions are never needed",
      rt.eval("TaxiNodePosition") is None)

rt = flight(LISTED + TEST_DATA)
rt.execute('PRINTED = {} SlashCmdList["CHAIRPLUS"]("flight probe")')
probe = said(rt)
check("the probe reports the lookup chain", "faction = Alliance" in probe, probe[:300])
check("and each destination's key and result",
      "Stormwind > Ironforge -> 150s" in probe, probe[-400:])
check("with a total", "found," in probe, probe[-200:])

# This client will not say which stops a flight passes through (2026-09-26:
# every time flown was saved under its two ends). A multi-hop route in the
# table is then found by its ends, over flight points you know.
MULTI_ONLY = """
NS.flightData = { Alliance = {
    ["Stormwind > Menethil > Ironforge"] = 210,
    ["Stormwind > Thelsamar > Ironforge"] = 260,
} }
function GetNumRoutes() error("no") end
"""
rt = flight(ROUTE_HARNESS + LISTED + MULTI_ONLY)
check("with no path from the client, a multi-hop route is found by its ends",
      "03:30" in tooltip(rt, 2), tooltip(rt, 2))
rt.execute("HOOKS.TakeTaxiNode(2) ON_TAXI = true DRIVER_TICK()")
check("and counted down from, rather than timed from zero",
      (rt.eval("TIMER_TEXT()") or "").startswith("03:30"), str(rt.eval("TIMER_TEXT()")))
rt = flight(ROUTE_HARNESS + LISTED + MULTI_ONLY + 'NODES[3].kind = "NONE"')
check("a route through a flight point you have not found is not the one",
      "04:20" in tooltip(rt, 2), tooltip(rt, 2))
rt.execute('PRINTED = {} SlashCmdList["CHAIRPLUS"]("flight probe")')
check("and the probe says the route was worked out", "worked out" in said(rt), said(rt)[-400:])

print("")
print("Flight countdown")
rt = flight()
rt.execute("HOOKS.TakeTaxiNode(2) ON_TAXI = true DRIVER_TICK()")
check("an unknown route counts up from zero",
      rt.eval("TIMER_TEXT()") is not None
      and "00:00" in str(rt.eval("TIMER_TEXT()")), str(rt.eval("TIMER_TEXT()")))
rt.execute("NOW = NOW + 65 DRIVER_TICK()")
check("and keeps counting up", "01:05" in str(rt.eval("TIMER_TEXT()")),
      str(rt.eval("TIMER_TEXT()")))
check("and says it is timing, not counting down",
      "(timing)" in str(rt.eval("TIMER_TEXT()")), str(rt.eval("TIMER_TEXT()")))
rt.execute("NOW = NOW + 10 ON_TAXI = false DRIVER_TICK()")
check("the timer is hidden on landing", rt.eval("TIMER_TEXT()") is None)

# Now the route is known, so the next one counts down.
rt.execute("HOOKS.TakeTaxiNode(2) ON_TAXI = true DRIVER_TICK()")
check("a known route counts down from the learned time",
      "01:15" in str(rt.eval("TIMER_TEXT()")), str(rt.eval("TIMER_TEXT()")))
check("and does not claim to be timing",
      "(timing)" not in str(rt.eval("TIMER_TEXT()")), str(rt.eval("TIMER_TEXT()")))
rt.execute("NOW = NOW + 60 DRIVER_TICK()")
check("and ticks down", "00:15" in str(rt.eval("TIMER_TEXT()")),
      str(rt.eval("TIMER_TEXT()")))
# A route takes what it takes, so the clock must never tick past the arrival
# it promised. It clamps at zero instead.
rt.execute("NOW = NOW + 30 DRIVER_TICK()")
check("it clamps at zero rather than running over",
      "00:00" in str(rt.eval("TIMER_TEXT()")), str(rt.eval("TIMER_TEXT()")))
check("and never shows an overrun",
      "+" not in str(rt.eval("TIMER_TEXT()")), str(rt.eval("TIMER_TEXT()")))

rt = flight('NS.baked["flightCountdown"] = false')
rt.execute("HOOKS.TakeTaxiNode(2) ON_TAXI = true DRIVER_TICK()")
check("the countdown can be switched off", rt.eval("TIMER_TEXT()") is None)
rt.execute("NOW = NOW + 100 ON_TAXI = false DRIVER_TICK()")
check("but the flight is still recorded",
      rt.eval("next(ChairPlusDB.flights) ~= nil") is True)

print("")
print("Flight times as code")
rt = flight()
rt.execute("FLY(2, 150)")
rt.execute('NODES[2].kind = "REACHABLE" NODES[3].kind = "REACHABLE"')
rt.execute("FLY(3, 90)")
rt.execute("EXPORTED, COUNT = NS.FlightExport()")
exported = str(rt.eval("EXPORTED"))
check("every learned route is exported", rt.eval("COUNT") == 2, exported)
check("as a pasteable flightDefaults block",
      exported.startswith("ns.flightDefaults = {") and exported.rstrip().endswith("}"),
      exported)
check("with the base time, not the boosted one", "150.0" in exported, exported)

# It has to be Lua that actually loads, or "paste this into the file" is a lie.
ok, err = lua.eval(
    "function(s) local c, e = loadstring('local ns = {} ' .. s) "
    "return c ~= nil, tostring(e) end")(exported)
check("and it is valid Lua", ok is True, str(err))

# Round trip: feed the export back in as the hardcoded list on a fresh profile.
rt2 = flight("ChairPlusDB = nil")
rt2.execute("NS.flightDefaults = { [\"A > B\"] = 123.0 }")
rt2.execute("NS.ApplyAll()")
check("hardcoded times seed a profile that has never flown",
      rt2.eval('ChairPlusDB.flights["A > B"].base') == 123.0,
      str(rt2.eval("ChairPlusDB.flights")))
check("and are marked as never actually flown",
      rt2.eval('ChairPlusDB.flights["A > B"].n') == 0)

# A measured time outranks the list.
rt3 = flight()
rt3.execute("FLY(2, 150)")
rt3.execute('NS.flightDefaults = { ["Stormwind, Elwynn > Ironforge, Dun Morogh"] = 999 }')
rt3.execute("NS.ApplyAll()")
check("seeding never overwrites a route already measured",
      rt3.eval('ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"].base')
      == 150, str(rt3.eval('ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"].base')))

print("")
print("Building the catalogue by paste")
# The exported list pastes straight back in.
rt4 = flight()
rt4.execute("""
ADDED, SKIPPED = NS.ImportFlightTimes([[
ns.flightDefaults = {
    ["Orgrimmar, Durotar > Thunder Bluff, Mulgore"] = 225.4,
    ["Thunder Bluff, Mulgore > Crossroads, The Barrens"] = 158.5,
}
]])
""")
check("the exported shape imports", rt4.eval("ADDED") == 2, str(rt4.eval("ADDED")))
check("with the right time",
      rt4.eval('ChairPlusDB.flights["Orgrimmar, Durotar > Thunder Bluff, Mulgore"].base')
      == 225.4)

# So does a fragment lifted straight out of SavedVariables, braces and all.
rt5 = flight()
rt5.execute("""
ADDED, SKIPPED = NS.ImportFlightTimes([[
["flights"] = {
["Thunder Bluff, Mulgore > Orgrimmar, Durotar"] = {
["base"] = 207.12199999997,
["n"] = 1,
},
]])
""")
check("a raw SavedVariables fragment imports", rt5.eval("ADDED") == 1,
      str(rt5.eval("ADDED")))
check("reading base out of the nested table",
      abs(rt5.eval('ChairPlusDB.flights["Thunder Bluff, Mulgore > Orgrimmar, Durotar"].base')
          - 207.122) < 0.001)

# A measured time outranks a pasted one.
rt6 = flight()
rt6.execute("FLY(2, 150)")
rt6.execute("""
ADDED, SKIPPED = NS.ImportFlightTimes([[
["Stormwind, Elwynn > Ironforge, Dun Morogh"] = 999,
["Somewhere > Else"] = 60,
]])
""")
check("a route already known is left alone", rt6.eval("SKIPPED") == 1,
      str(rt6.eval("SKIPPED")))
check("and keeps its measured time",
      rt6.eval('ChairPlusDB.flights["Stormwind, Elwynn > Ironforge, Dun Morogh"].base')
      == 150)
check("while the new one is added", rt6.eval("ADDED") == 1)

rt7 = flight()
rt7.execute('BAD, WHY = NS.ImportFlightTimes("nothing useful in here at all")')
check("text with no times in it is refused",
      rt7.eval("BAD") is None and rt7.eval("WHY") is not None,
      str(rt7.eval("WHY")))

rt.execute('SlashCmdList["CHAIRPLUS"]("flights")')
check("the command parks a copy in SavedVariables for reading off disk",
      rt.eval("ChairPlusDB.flightsHint ~= nil") is True)

print("")
print("Flight timer placement")
rt = flight()
check("it sits near the top edge, clear of the zone text",
      rt.eval('NS.Get("flightY")') == -30 and rt.eval('NS.Get("flightAnchor")') == "TOP",
      str(rt.eval('NS.Get("flightY")')))
check("locked by default", rt.eval('NS.IsEnabled("flightLocked")') is True)
check("and hidden while not flying",
      rt.eval("ChairPlusFlightTimer:IsShown()") is False)

# Unlocked it has to be visible to be dragged -- it is otherwise only ever on
# screen mid-flight, which is a poor moment to arrange the UI.
rt.execute('SlashCmdList["CHAIRPLUS"]("flight unlock")')
check("unlocking parks it on screen to drag",
      rt.eval("ChairPlusFlightTimer:IsShown()") is True)
check("showing a sample", "drag me" in str(rt.eval("TIMER_TEXT()") or ""),
      str(rt.eval("TIMER_TEXT()")))
check("and it takes the mouse", rt.eval('rawget(ChairPlusFlightTimer, "_mouse")')
      is True)

rt.execute('SlashCmdList["CHAIRPLUS"]("flight lock")')
check("locking hides it again",
      rt.eval("ChairPlusFlightTimer:IsShown()") is False)
check("and stops it eating clicks",
      rt.eval('rawget(ChairPlusFlightTimer, "_mouse")') is False)

rt.execute('NS.SetMany({ flightAnchor = "CENTER", flightX = 40, flightY = 40 })')
rt.execute('SlashCmdList["CHAIRPLUS"]("flight reset")')
check("reset returns it to the top",
      rt.eval('NS.Get("flightAnchor")') == "TOP" and rt.eval('NS.Get("flightY")') == -30,
      str(rt.eval('NS.Get("flightAnchor")')))

print("")
print("Flight map tooltip")
rt = flight()
rt.execute("FLY(2, 150)")
rt.execute("TOOLTIP_LINES = {} HOOKS.TaxiNodeOnButtonEnter({ slot = 2 })")
lines = chr(10).join(str(v) for v in rt.eval("TOOLTIP_LINES").values())
check("a known route shows its time on hover", "02:30" in lines, lines)

rt.execute("TOOLTIP_LINES = {} HOOKS.TaxiNodeOnButtonEnter({ slot = 3 })")
lines = chr(10).join(str(v) for v in rt.eval("TOOLTIP_LINES").values())
check("an unknown route says so rather than nothing", "not yet known" in lines, lines)

# Node 1 is the one we are standing on. There is no flight to it.
rt.execute("TOOLTIP_LINES = {} HOOKS.TaxiNodeOnButtonEnter({ slot = 1 })")
check("the origin node says nothing at all",
      len(list(rt.eval("TOOLTIP_LINES").values())) == 0,
      chr(10).join(str(v) for v in rt.eval("TOOLTIP_LINES").values()))

rt = flight('NS.baked["flightTooltip"] = false')
rt.execute("FLY(2, 150)")
rt.execute("TOOLTIP_LINES = {} HOOKS.TaxiNodeOnButtonEnter({ slot = 2 })")
check("the tooltip line can be switched off",
      len(list(rt.eval("TOOLTIP_LINES").values())) == 0)

print("")
print("Auto gossip")

def gossip(setup=""):
    rt, g = fresh()
    rt.execute("""
    GOSSIP_OPTIONS = {}
    GOSSIP_AVAILABLE = {}
    GOSSIP_ACTIVE = {}
    SELECTED = {}
    C_GossipInfo.GetOptions = function() return GOSSIP_OPTIONS end
    C_GossipInfo.GetAvailableQuests = function() return GOSSIP_AVAILABLE end
    C_GossipInfo.GetActiveQuests = function() return GOSSIP_ACTIVE end
    C_GossipInfo.SelectOption = function(id) table.insert(SELECTED, id) end
    function GetNumAvailableQuests() return 0 end
    function GetNumActiveQuests() return 0 end
    """)
    rt.execute(setup)
    rt.execute('BOOT() FireEvent("GOSSIP_SHOW")')
    return rt, [str(v) for v in rt.eval("SELECTED").values()]

rt, sel = gossip('GOSSIP_OPTIONS = { { name = "Continue", gossipOptionID = 7 } }')
check("a lone plain option is taken", sel == ["7"], str(sel))

rt, sel = gossip('GOSSIP_OPTIONS = { { name = "One", gossipOptionID = 1 },'
                 ' { name = "Two", gossipOptionID = 2 } }')
check("two options are a choice, and are left alone", sel == [], str(sel))

rt, sel = gossip('GOSSIP_OPTIONS = {}')
check("no options, nothing happens", sel == [], str(sel))

# Quests.lua owns quest gossip; this must not close the window underneath it.
rt, sel = gossip('GOSSIP_OPTIONS = { { name = "Continue", gossipOptionID = 7 } }'
                 ' GOSSIP_AVAILABLE = { { questID = 11, title = "A quest" } }')
check("a window with a quest on it is left to the quest module", sel == [], str(sel))
rt, sel = gossip('GOSSIP_OPTIONS = { { name = "Continue", gossipOptionID = 7 } }'
                 ' GOSSIP_ACTIVE = { { questID = 11, title = "A quest" } }')
check("an active quest also blocks it", sel == [], str(sel))

# The costly kinds, which is the whole reason this rule is narrow.
for label, option in (
    ("a flight master", '{ name = "Fly me", gossipOptionID = 3, type = "Taxi" }'),
    ("an innkeeper", '{ name = "Make this my home", gossipOptionID = 3, type = "Binder" }'),
    ("a trainer", '{ name = "Train me", gossipOptionID = 3, type = "Trainer" }'),
    ("a vendor", '{ name = "Browse", gossipOptionID = 3, type = "Vendor" }'),
):
    rt, sel = gossip(f"GOSSIP_OPTIONS = {{ {option} }}")
    check(f"{label} is never auto-selected", sel == [], str(sel))
for label, option in (
    ("a Classic flight master known only by its icon", '{ name = "Fly me", gossipOptionID = 3, icon = 132057 }'),
    ("a Classic innkeeper known only by its icon", '{ name = "Make this my home", gossipOptionID = 3, icon = 132052 }'),
):
    rt, sel = gossip(f"GOSSIP_OPTIONS = {{ {option} }}")
    check(f"{label} is never auto-selected", sel == [], str(sel))
rt, sel = gossip('GOSSIP_OPTIONS = { { name = "Tell me more", gossipOptionID = 7, icon = 132053 } }')
check("an ordinary talk option still is", sel == ["7"], str(sel))

rt, sel = gossip('GOSSIP_OPTIONS = { { name = "|cffff0000Skip ahead|r",'
                 ' gossipOptionID = 3 } }')
check("a coloured option is left alone", sel == [], str(sel))

rt, sel = gossip('GOSSIP_OPTIONS = { { name = "Continue", gossipOptionID = 7 } }'
                 ' SHIFT = true')
check("shift suppresses it", sel == [], str(sel))

rt, sel = gossip('GOSSIP_OPTIONS = { { name = "Continue", gossipOptionID = 7 } }'
                 ' NS.baked["autoGossip"] = false')
check("and the option switches it off", sel == [], str(sel))

print("")
print("Settings per character")
# Only the auras are account-wide. ChairPlus settings and window positions are
# kept per character, keyed by GUID; learned flight times stay shared.
CHARS = """
PLAYER_GUID = "Player-1-A"
function UnitGUID(u) if u == "player" then return PLAYER_GUID end return NPC_GUID end
function UnitName(u) return "Chairface" end
function GetRealmName() return "Forever" end
function AS(guid) PLAYER_GUID = guid NS.LoadSettings() end
"""
rt, g = fresh(stock=True)
rt.execute(CHARS)
rt.execute('BOOT() NS.Set("osd", true) NS.Set("osdFontSize", 22)')
rt.execute('AS("Player-1-B")')
check("a second character starts on the defaults, not the first's settings",
      g.NS.IsEnabled("osd") is False and g.NS.Get("osdFontSize") == 14,
      str(g.NS.Get("osdFontSize")))
rt.execute('NS.Set("osdFontSize", 30)')
rt.execute('AS("Player-1-A")')
check("and changing it leaves the first character's alone",
      g.NS.IsEnabled("osd") is True and g.NS.Get("osdFontSize") == 22,
      str(g.NS.Get("osdFontSize")))
check("each is kept under its own GUID",
      rt.eval('ChairPlusDB.profiles["guid:Player-1-A"].settings.osdFontSize') == 22
      and rt.eval('ChairPlusDB.profiles["guid:Player-1-B"].settings.osdFontSize') == 30)

rt.execute('AS("Player-1-B") NS.Profile().movers.CharacterFrame = { x = 5, y = 6 } AS("Player-1-A")')
check("window positions are per character too",
      rt.eval("NS.Profile().movers.CharacterFrame") is None)

rt.execute('ChairPlusDB.flights = { ["A > B"] = { base = 60 } } AS("Player-1-B")')
check("learned flight times stay shared by every character",
      rt.eval('ChairPlusDB.flights["A > B"].base') == 60)

# The day this changed: the shared settings every character was using become
# each character's starting point, so nobody logs in to a reset setup.
rt, g = fresh(stock=True)
rt.execute(CHARS)
rt.execute('ChairPlusDB = { settings = { osd = true, osdFontSize = 20 }, '
           'movers = { BankFrame = { x = 1, y = 2 } } }')
rt.execute("BOOT()")
check("an existing setup is carried into the character's profile",
      g.NS.IsEnabled("osd") is True and g.NS.Get("osdFontSize") == 20
      and rt.eval("NS.Profile().movers.BankFrame.x") == 1)
rt.execute('NS.Set("osdFontSize", 25) AS("Player-1-B")')
check("and every other character starts from that same setup, not the change",
      g.NS.Get("osdFontSize") == 20, str(g.NS.Get("osdFontSize")))
rt.execute('NS.Set("osdFontSize", 9)')
check("the old shared settings themselves are never written again",
      rt.eval("ChairPlusDB.settings.osdFontSize") == 20)

# A GUID the client cannot read yet at ADDON_LOADED: the profile made under the
# name moves to the GUID at login instead of being left behind.
rt, g = fresh(stock=True)
rt.execute(CHARS)
rt.execute('PLAYER_GUID = nil FireEvent("ADDON_LOADED", "Chaircraft") NS.Set("osdFontSize", 18)')
check("before the GUID is readable, the name is the key",
      rt.eval('ChairPlusDB.profiles["Chairface-Forever"] ~= nil') is True)
rt.execute('PLAYER_GUID = "Player-1-A" FireEvent("PLAYER_LOGIN")')
check("at login the profile moves to the GUID",
      rt.eval('ChairPlusDB.profiles["guid:Player-1-A"].settings.osdFontSize') == 18
      and rt.eval('ChairPlusDB.profiles["Chairface-Forever"] == nil') is True)
check("with the setting still in force", g.NS.Get("osdFontSize") == 18)

print("")
print("Menu tabs")
rt, g = fresh()
rt.execute("BOOT()")
rt.execute('NS.OpenPanel("quests")')
check("Plus page shows the automation options",
      rt.eval('SHOWN("Automate quests")') is True)
check("and hides the display options",
      rt.eval('SHOWN("Money")') is False)
check("section headers follow their page",
      rt.eval('SHOWN("|cff9d7cffQuests|r")') is True
      and rt.eval('SHOWN("|cff9d7cffDisplay|r")') is False
      and rt.eval('SHOWN("|cff9d7cffJunk and repairs|r")') is False)
check("each page opens with its name", rt.eval('SHOWN("Quests & NPCs")') is True
      and rt.eval('SHOWN("Buying & selling")') is True)

rt.execute('NS.OpenPanel("osd")')
check("OSD page shows the display options",
      rt.eval('SHOWN("Money")') is True
      and rt.eval('SHOWN("Profession bags, separately")') is True)
check("and hides the automation options",
      rt.eval('SHOWN("Automate quests")') is False)
check("the move/reset buttons live on the OSD page",
      rt.eval('SHOWN_BUTTON("Move display")') is True
      and rt.eval('SHOWN_BUTTON("Reset position")') is True)
rt.execute('NS.OpenPanel("quests")')
check("and are gone from the Plus page",
      rt.eval('SHOWN_BUTTON("Move display")') is False)

# Plus-page controls: the minimap icon size. The flight times button is gone
# (2026-09-25) -- the times are hardcoded now; /chair plus flights still shows them.
check("there is no flight times button any more",
      rt.eval('SHOWN_BUTTON("Flight times")') is None)
rt.execute('NS.OpenPanel("quests")')
check("the minimap size slider is gone: the icon sits in the minimap ring now",
      rt.eval('SHOWN("Minimap icon size: 24")') is None)

# Toggling is per page: asking for the page you are on closes the window,
# asking for another switches to it rather than shutting it in your face.
rt.execute('NS.OpenPanel("quests")')
rt.execute('NS.TogglePanel("osd")')
check("toggling to a different page switches instead of closing",
      rt.eval("ChairPlusPanel:IsShown()") is True
      and rt.eval('SHOWN("Money")') is True)
rt.execute('NS.TogglePanel("osd")')
check("toggling the page you are on closes the window",
      rt.eval("ChairPlusPanel:IsShown()") is False)

print("")
print("Vendor regressions (the bugs found in game on 2026-09-22)")

# The original bug. Every earlier selling test called MerchantFrame:Show()
# before firing the event, which the real client does not guarantee -- and
# that forgiveness is exactly why the suite passed while nothing ever sold.
rt, g = fresh()
rt.execute("""
ITEMS[501] = { quality = 0, price = 10, classID = 9 }
BAGS[0] = { size = 2, family = 0, items = {
    [1] = { itemID = 501, quality = 0, stackCount = 1, hasNoValue = false },
} }
BOOT()
FireEvent("MERCHANT_SHOW")   -- frame deliberately never shown
RUN_TIMERS(4)
""")
check("sells even though the merchant frame was never shown",
      501 in list(rt.eval("SOLD").values()),
      "MerchantOpen() is reading the frame again")

# The first pass must be deferred, not run inside the event. The frame IS
# shown here on purpose: without that, the old frame-reading code also sold
# nothing and this check would pass for entirely the wrong reason.
rt, g = fresh()
rt.execute("""
ITEMS[502] = { quality = 0, price = 10, classID = 9 }
BAGS[0] = { size = 2, family = 0, items = {
    [1] = { itemID = 502, quality = 0, stackCount = 1, hasNoValue = false },
} }
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
""")
check("nothing is sold synchronously inside MERCHANT_SHOW",
      len(list(rt.eval("SOLD").values())) == 0,
      "the first pass still runs inside the event")
rt.execute("RUN_TIMERS(4)")
check("but the deferred pass does sell", 502 in list(rt.eval("SOLD").values()))

# A throwing sweep must not leave `selling` true forever. Before the fix this
# wedged junk selling for the rest of the session, silently.
rt, g = fresh()
rt.execute("""
ITEMS[503] = { quality = 0, price = 10, classID = 9 }
BAGS[0] = { size = 2, family = 0, items = {
    [1] = { itemID = 503, quality = 0, stackCount = 1, hasNoValue = false },
} }
BOOT()
NS.blockedItems = nil          -- indexing nil throws inside the sweep
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(4)
FireEvent("MERCHANT_CLOSED")
""")
check("a throwing sweep sells nothing", len(list(rt.eval("SOLD").values())) == 0)
rt.execute("""
NS.blockedItems = {}           -- whatever it was, it is better now
FireEvent("MERCHANT_SHOW")
RUN_TIMERS(4)
""")
check("and the next merchant still works (selling is not wedged)",
      503 in list(rt.eval("SOLD").values()),
      "the `selling` flag stayed true after the error")

# Repair is charged and reported once per visit, however many times the event
# arrives.
rt, g = fresh()
rt.execute("""
BOOT()
MerchantFrame:Show()
FireEvent("MERCHANT_SHOW")
FireEvent("MERCHANT_SHOW")
""")
repaired = list(rt.eval("REPAIRED").values())
check("a repeated MERCHANT_SHOW repairs once", repaired == ["self"], str(repaired))
rt.execute('REPAIR_COST = 500 FireEvent("MERCHANT_CLOSED") FireEvent("MERCHANT_SHOW")')
repaired = list(rt.eval("REPAIRED").values())
check("but a genuinely new visit repairs again", repaired == ["self", "self"],
      str(repaired))

print("\nWaypoint arrow")
# One 1000-yard-square map, the player in the middle facing north. The world
# layout is deliberately the client's awkward one -- X runs north, Y runs west
# -- to prove the cross-map conversion does not assume axes.
ARROW_SETUP = """
MAPS = { [1] = { north = 0, west = 0 }, [2] = { north = 100, west = 0 } }
PLAYER = { map = 1, x = 0.5, y = 0.5 }
FACING = 0
PIN = nil
SUPER, WATCHED, QUEST_WP, QUESTS_ON_MAP = nil, nil, {}, {}
function GetPlayerFacing() return FACING end
C_Map = {
    GetBestMapForUnit = function() return PLAYER.map end,
    GetPlayerMapPosition = function(map)
        return { GetXY = function() return PLAYER.x, PLAYER.y end }
    end,
    GetMapWorldSize = function() return 1000, 1000 end,
    GetWorldPosFromMapPos = function(map, vec)
        local x, y = vec:GetXY()
        local m = MAPS[map]
        return 0, { x = m.north - y * 1000, y = m.west - x * 1000 }
    end,
    HasUserWaypoint = function() return PIN ~= nil end,
    GetUserWaypoint = function()
        if not PIN then return nil end
        return { uiMapID = PIN.map, position = { x = PIN.x, y = PIN.y } }
    end,
}
C_SuperTrack = { GetSuperTrackedQuestID = function() return SUPER or 0 end }
C_QuestLog = {
    GetQuestIDForQuestWatchIndex = function(i) return WATCHED end,
    GetNextWaypoint = function(id)
        local wp = QUEST_WP[id]
        if wp then return wp.map, wp.x, wp.y end
    end,
    GetQuestsOnMap = function(map) return QUESTS_ON_MAP end,
    GetTitleForQuestID = function(id) return "Quest title " .. id end,
}
"""


def arrow_rt(extra=""):
    rt, g = fresh()
    rt.execute(ARROW_SETUP)
    rt.execute(extra)
    rt.execute('BOOT() NS.Set("arrow", true)')
    return rt, g


def printed_text(rt):
    return " ".join(str(v) for v in rt.eval("PRINTED").values())


def any_text(rt, text):
    return rt.eval("(function(t) for _, f in ipairs(FRAMES) do"
                   " if rawget(f, '_text') == t then return true end end"
                   " return false end)")(text)


rt, g = fresh(stock=True)
rt.execute("BOOT()")
check("the arrow and the threat meter ship off",
      g.NS.IsEnabled("arrow") is False and g.NS.IsEnabled("threat") is False)
check("the arrow sits top centre by default",
      g.NS.Get("arrowAnchor") == "TOP" and g.NS.Get("arrowX") == 0)

rt, g = arrow_rt('PIN = { map = 1, x = 0.5, y = 0.4 }')
rt.execute("DRIVER_TICK()")
state = g.NS.arrowState
check("a pin 100 yards north is found", state is not None and state.target is not None
      and state.target.kind == "pin")
check("and is 100 yards away", state is not None and state.yards is not None
      and abs(state.yards - 100) < 0.01, str(state and state.yards))
check("facing it, the arrow shows cell 0", g.NS.ArrowCell(state.bearing - 0) == 0)
check("facing west, it points right (three quarters of a turn)",
      g.NS.ArrowCell(state.bearing - math.pi / 2) == 48,
      str(g.NS.ArrowCell(state.bearing - math.pi / 2)))
rt.execute("PIN = { map = 1, x = 0.4, y = 0.5 }")
rt.execute("DRIVER_TICK()")
check("a pin to the west points left (a quarter turn)",
      g.NS.ArrowCell(g.NS.arrowState.bearing) == 16,
      str(g.NS.ArrowCell(g.NS.arrowState.bearing)))
rt.execute("PIN = { map = 2, x = 0.5, y = 0.5 }")
rt.execute("DRIVER_TICK()")
st = g.NS.arrowState
check("a pin on another map is placed through world coordinates",
      st.yards is not None and abs(st.yards - 100) < 0.01
      and g.NS.ArrowCell(st.bearing) == 0, f"{st.yards} {st.bearing}")

rt, g = arrow_rt("""
PIN = { map = 1, x = 0.4, y = 0.5 }
SUPER = 77
QUEST_WP[77] = { map = 1, x = 0.6, y = 0.5 }
""")
rt.execute("DRIVER_TICK()")
st = g.NS.arrowState
check("the tracked quest wins over the pin", st.target.kind == "quest"
      and st.target.name == "Quest title 77", str(st.target.name))
check("and points east", g.NS.ArrowCell(st.bearing) == 48, str(g.NS.ArrowCell(st.bearing)))

rt, g = arrow_rt("""
PIN = { map = 1, x = 0.4, y = 0.5 }
SUPER = 12
QUESTS_ON_MAP = { { questID = 12, x = 0.5, y = 0.6 } }
""")
rt.execute("DRIVER_TICK()")
st = g.NS.arrowState
check("a selected quest with no waypoint is found by its marker on the map",
      st.target.kind == "quest" and g.NS.ArrowCell(st.bearing) == 32,
      f"{st.target.kind} {st.bearing}")

# A selected quest in another zone (found in game on 2026-09-25: the arrow went
# away as soon as the quest was not on the map you were standing on). Zones 1
# and 2 are on continent 10, zone 3 on continent 20, both under world 5.
ZONES = """
MAPS[3] = { north = 0, west = 0 }
CONT = { [1] = 10, [2] = 10, [3] = 20 }
INFO = {
    [1] = { name = "Elwynn", mapType = 3, parentMapID = 10 },
    [2] = { name = "Westfall", mapType = 3, parentMapID = 10 },
    [3] = { name = "Durotar", mapType = 3, parentMapID = 20 },
    [10] = { name = "Eastern Kingdoms", mapType = 2, parentMapID = 5 },
    [20] = { name = "Kalimdor", mapType = 2, parentMapID = 5 },
    [5] = { name = "Azeroth", mapType = 1, parentMapID = 0 },
}
KIDS = { [10] = { 1, 2 }, [20] = { 3 }, [5] = { 10, 20 } }
C_Map.GetMapInfo = function(id) return INFO[id] end
C_Map.GetMapChildrenInfo = function(id, mapType)
    local out = {}
    for _, kid in ipairs(KIDS[id] or {}) do
        if INFO[kid].mapType == mapType then out[#out + 1] = { mapID = kid } end
    end
    return out
end
C_Map.GetWorldPosFromMapPos = function(map, vec)
    local x, y = vec:GetXY()
    local m = MAPS[map]
    return CONT[map], { x = m.north - y * 1000, y = m.west - x * 1000 }
end
ON_MAP, LOOKUPS = {}, 0
C_QuestLog.GetQuestsOnMap = function(map)
    LOOKUPS = LOOKUPS + 1
    return ON_MAP[map] or {}
end
SUPER = 40
"""

rt, g = arrow_rt(ZONES + "ON_MAP[2] = { { questID = 40, x = 0.5, y = 0.5 } }")
rt.execute("DRIVER_TICK()")
st = g.NS.arrowState
check("a selected quest in the next zone is found",
      st.target is not None and st.target.map == 2, str(st.target and st.target.map))
check("and pointed at through world coordinates",
      st.yards is not None and abs(st.yards - 100) < 0.01 and g.NS.ArrowCell(st.bearing) == 0,
      f"{st.yards} {st.bearing}")
check("with the arrow showing", any_text(rt, "100 yd"))

rt.execute("LOOKUPS = 0 DRIVER_TICK() DRIVER_TICK()")
check("once found, only its own map is asked again", rt.eval("LOOKUPS") <= 4,
      str(rt.eval("LOOKUPS")))

rt, g = arrow_rt(ZONES)
rt.execute("DRIVER_TICK() LOOKUPS = 0 DRIVER_TICK() DRIVER_TICK()")
check("a quest found nowhere is not searched for every tick",
      rt.eval("LOOKUPS") <= 2, str(rt.eval("LOOKUPS")))
rt.execute("ON_MAP[2] = { { questID = 40, x = 0.5, y = 0.5 } } NOW = NOW + 3 DRIVER_TICK()")
check("but is looked for again a moment later",
      g.NS.arrowState.target is not None and g.NS.arrowState.target.map == 2)

rt, g = arrow_rt(ZONES + """
ON_MAP[2] = { { questID = 40, x = 0.5, y = 0.5 } }
function GetQuestUiMapID(id) return id == 40 and 2 or 0 end
""")
rt.execute("DRIVER_TICK()")
check("the client's own hint for the quest's zone is used",
      g.NS.arrowState.target is not None and g.NS.arrowState.target.map == 2)

rt, g = arrow_rt(ZONES + "ON_MAP[3] = { { questID = 40, x = 0.5, y = 0.5 } }")
rt.execute("DRIVER_TICK()")
st = g.NS.arrowState
check("a quest on another continent is still found",
      st.target is not None and st.target.map == 3)
check("but is not given a direction that would be wrong", st.bearing is None)
check("the arrow says which continent to go to instead", any_text(rt, "Go to Kalimdor"))
check("and names the quest and its zone", any_text(rt, "Quest title 40 (Durotar)"))
check("the frame stays visible for it", rt.eval("rawget(ChairPlusArrow, '_alpha')") == 1)

rt, g = arrow_rt(ZONES + "PLAYER.map = 3 ON_MAP[2] = { { questID = 40, x = 0.5, y = 0.5 } }")
rt.execute("DRIVER_TICK()")
check("and the other way round, from Kalimdor",
      any_text(rt, "Go to Eastern Kingdoms") and any_text(rt, "Quest title 40 (Westfall)"))

# The watch list fills itself as quests are accepted, so a watched quest is not
# a chosen one. Nothing selected and no pin means no arrow.
rt, g = arrow_rt("""
WATCHED = 12
QUESTS_ON_MAP = { { questID = 12, x = 0.5, y = 0.6 } }
""")
rt.execute("DRIVER_TICK()")
check("a quest that is only on the watch list does not bring the arrow up",
      g.NS.arrowState.target is None)
check("and the arrow is invisible",
      rt.eval("ChairPlusArrow:GetAlpha()") == 0
      or rt.eval("rawget(ChairPlusArrow, '_alpha')") == 0,
      str(rt.eval("rawget(ChairPlusArrow, '_alpha')")))
check("and cannot be clicked", rt.eval("rawget(ChairPlusArrow, '_mouse')") is False)
rt.execute("PIN = { map = 1, x = 0.5, y = 0.4 } DRIVER_TICK()")
check("placing a pin brings it back",
      rt.eval("rawget(ChairPlusArrow, '_alpha')") == 1 and g.NS.arrowState.bearing is not None)
rt.execute("PIN = nil DRIVER_TICK()")
check("and removing the pin makes it disappear again",
      rt.eval("rawget(ChairPlusArrow, '_alpha')") == 0)
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow unlock") DRIVER_TICK()')
check("unlocked but with the menu closed, nothing selected still shows nothing",
      rt.eval("rawget(ChairPlusArrow, '_alpha')") == 0)
rt.execute('NS.OpenPanel("quests") DRIVER_TICK()')
check("unlocked with the menu open, it shows to be dragged",
      rt.eval("rawget(ChairPlusArrow, '_alpha')") == 1)
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow lock") NS.OpenPanel("arrow") DRIVER_TICK()')
check("on the Arrow page it shows, locked or not",
      rt.eval("rawget(ChairPlusArrow, '_alpha')") == 1)
rt.execute('ChairPlusPanel:Hide() DRIVER_TICK()')
check("and closing the menu with nothing to track hides it",
      rt.eval("rawget(ChairPlusArrow, '_alpha')") == 0)

rt, g = arrow_rt("""
PIN = { map = 1, x = 0.4, y = 0.5 }
SUPER = 77
C_QuestLog = nil
""")
rt.execute("DRIVER_TICK()")
check("without the quest APIs it falls back to the pin",
      g.NS.arrowState.target.kind == "pin")

rt, g = arrow_rt("")
rt.execute("DRIVER_TICK()")
check("with no quest and no pin there is nothing to point at",
      g.NS.arrowState.target is None)

rt, g = arrow_rt('PIN = { map = 1, x = 0.5, y = 0.4 } '
                 'C_Map.GetPlayerMapPosition = function() return nil end')
rt.execute("DRIVER_TICK()")
check("in an instance, where the player cannot be placed, it does not point",
      g.NS.arrowState.bearing is None)

rt, g = arrow_rt('PIN = { map = 1, x = 0.5, y = 0.498 }')
rt.execute("DRIVER_TICK()")
check("within five yards it says it has arrived", any_text(rt, "Arrived") is True)

rt, g = arrow_rt("")
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow unlock")')
check("/chair arrow unlock makes it draggable",
      g.NS.IsEnabled("arrowLocked") is False
      and rt.eval("rawget(ChairPlusArrow, '_movable')") is True)
rt.execute('NS.SetMany({ arrowAnchor = "CENTER", arrowX = 40 })')
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow reset")')
check("/chair arrow reset puts it back top centre",
      g.NS.Get("arrowAnchor") == "TOP" and g.NS.Get("arrowX") == 0)
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow probe")')
check("/chair arrow probe reports the APIs", "GetUserWaypoint" in printed_text(rt))
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow")')
check("/chair arrow opens its page", rt.eval("ChairPlusPanel:IsShown()") is True
      and rt.eval('SHOWN("Show the waypoint arrow")') is True)
rt.execute('SlashCmdList["CHAIRPLUS"]("arrow toggle")')
check("/chair arrow toggle turns it off", g.NS.IsEnabled("arrow") is False)

check("the colour is green straight ahead", tuple(g.NS.ArrowColour(0)) == (0.2, 1, 0.25))
r, gg, b = g.NS.ArrowColour(math.pi)
check("and red behind", r == 1 and gg < 0.3, f"{r} {gg} {b}")

print("\nThreat meter")
THREAT_SETUP = """
IN_GROUP, IN_RAID, IN_COMBAT, HAS_TARGET = true, false, true, true
function IsInGroup() return IN_GROUP end
function IsInRaid() return IN_RAID end
function UnitAffectingCombat() return IN_COMBAT end
function UnitCanAttack() return true end
PRESENT = { player = true, party1 = true, party2 = true }
function UnitExists(u) if u == "target" then return HAS_TARGET end return PRESENT[u] or false end
NAMES = { player = "Chairface", party1 = "Tank", party2 = "Healer" }
function UnitName(u) return NAMES[u] end
CLASSES = { player = "HUNTER", party1 = "WARRIOR", party2 = "PRIEST" }
function UnitClass(u) return "x", CLASSES[u] end
THREAT = { player = 70, party1 = 100, party2 = 12 }
-- Like the client: a mob nobody is fighting has no threat list, so out of
-- combat every unit answers nil. The fake used to answer regardless, and the
-- out-of-combat option passed here while never showing in game.
function UnitDetailedThreatSituation(u, t)
    if not IN_COMBAT then return nil end
    local pct = THREAT[u]
    if not pct then return nil end
    return u == "party1", u == "party1" and 3 or 1, pct, pct, pct * 10
end
RAID_CLASS_COLORS = { HUNTER = { r = 0.6, g = 0.8, b = 0.4 } }
"""
rt, g = fresh()
rt.execute(THREAT_SETUP)
rt.execute('BOOT() NS.Set("threat", true)')
rows = g.NS.ThreatRows()
names = [rows[i].name for i in range(1, len(rows) + 1)]
check("every group member with threat is listed, highest first",
      names == ["Tank", "Chairface", "Healer"], str(names))
check("the tank is marked", rows[1].tanking is True and rows[2].tanking is False)
check("the meter is shown in a group fight", rt.eval("ChairPlusThreat:IsShown()") is True)
rt.execute("IN_COMBAT = false NS.RefreshThreat()")
check("and hidden out of combat", rt.eval("ChairPlusThreat:IsShown()") is False)
rt.execute("IN_COMBAT = true IN_GROUP = false NS.RefreshThreat()")
check("and hidden when solo", rt.eval("ChairPlusThreat:IsShown()") is False)
rt.execute("IN_GROUP = true HAS_TARGET = false NS.RefreshThreat()")
check("and hidden with no target", rt.eval("ChairPlusThreat:IsShown()") is False)
rt.execute('HAS_TARGET = true SlashCmdList["CHAIRPLUS"]("threat unlock")')
rt.execute("IN_GROUP = false NS.RefreshThreat()")
check("unlocked, it stays up so it can be dragged",
      rt.eval("ChairPlusThreat:IsShown()") is True)

rt, g = fresh()
rt.execute(THREAT_SETUP)
rt.execute('UnitDetailedThreatSituation = nil BOOT() NS.Set("threat", true)')
check("a client without the threat API says so instead of erroring",
      "UnitDetailedThreatSituation" in printed_text(rt), printed_text(rt)[-200:])

print("\nThreat meter options")
THREAT_MORE = """
function UnitCanAttack(_, u) if u == "target" then return TARGET_HOSTILE end return true end
TARGET_HOSTILE = true
PRESENT.targettarget = true
LOCKDOWN = false
function InCombatLockdown() return LOCKDOWN end
INSTANCE = nil
function IsInInstance() if INSTANCE then return true, INSTANCE end return false, "none" end
ERRORS, SOUNDS = {}, {}
UIErrorsFrame = { AddMessage = function(self, text) table.insert(ERRORS, text) end }
function PlaySound(id) table.insert(SOUNDS, id) end
SOUNDKIT = { RAID_WARNING = 8959 }
function UP() return ChairPlusThreat:IsShown() end
function SLIDER(prefix)
    for _, f in ipairs(FRAMES) do
        local l = rawget(f, "labelText")
        local t = l and rawget(l, "_text")
        if type(t) == "string" and t:sub(1, #prefix) == prefix and rawget(f, "_scripts") then
            return f
        end
    end
end
"""


def threat_rt(before=""):
    rt, g = fresh()
    rt.execute(THREAT_SETUP)
    rt.execute(THREAT_MORE)
    rt.execute(before + ' BOOT() NS.Set("threat", true)')
    return rt, g


rt, g = threat_rt()
rt.execute('NS.OpenPanel("threat")')
check("the Threat tab shows the meter's options",
      rt.eval('SHOWN("Show the threat meter")') is True
      and rt.eval('SHOWN("Click-through in combat")') is True)
check("and not the Plus page's", rt.eval('SHOWN("Automate quests")') is False)
check("its sliders are labelled with their values",
      rt.eval('SHOWN("Width: 220")') is True and rt.eval('SHOWN("Most bars: 10")') is True)
check("the move and preview buttons live on the Threat tab",
      rt.eval('SHOWN_BUTTON("Move / resize")') is True
      and rt.eval('SHOWN_BUTTON("Preview")') is True)
rt.execute('NS.OpenPanel("quests")')
check("and are gone from the Plus page", rt.eval('SHOWN_BUTTON("Move / resize")') is False)
check("the threat options are not on the Plus page any more",
      rt.eval('SHOWN("Show the threat meter")') is False)

rt.execute('NS.OpenPanel("threat") SLIDER("Width: ")._scripts.OnValueChanged(SLIDER("Width: "), 303)')
check("a slider writes its setting, snapped to its step",
      g.NS.Get("threatWidth") == 300, str(g.NS.Get("threatWidth")))
check("and its label follows", rt.eval('SHOWN("Width: 300")') is True)
rt.execute('SLIDER("Scale: ")._scripts.OnValueChanged(SLIDER("Scale: "), 1.2600001)')
check("fractional steps come out clean",
      g.NS.Get("threatScale") == 1.25, str(g.NS.Get("threatScale")))

rt.execute('ChairPlusPanel:Hide() SlashCmdList["CHAIRPLUS"]("threat")')
check("a bare /chair threat opens the Threat tab",
      rt.eval("ChairPlusPanel:IsShown()") is True
      and rt.eval('SHOWN("Show the threat meter")') is True)
check("rather than switching the meter off", g.NS.IsEnabled("threat") is True)

# Visibility.
rt, g = threat_rt()
rt.execute("IN_GROUP = false NS.RefreshThreat()")
check("solo is hidden by default", rt.eval("UP()") is False)
rt.execute('NS.Set("threatSolo", true) NS.RefreshThreat()')
check("and shown with 'When solo' on", rt.eval("UP()") is True)
rt.execute("IN_GROUP = true IN_COMBAT = false NS.RefreshThreat()")
check("out of combat is hidden by default", rt.eval("UP()") is False)
rt.execute('NS.Set("threatOutOfCombat", true) NS.RefreshThreat()')
check("and shown with 'Out of combat too' on, though the mob has no threat list",
      rt.eval("UP()") is True)
rt.execute('HAS_TARGET = false NS.RefreshThreat()')
check("with nothing targeted too", rt.eval("UP()") is True)
check("titled plainly", rt.eval('SHOWN("Threat")') is True)
rt.execute('NS.Set("threatShowAbove", 80) NS.RefreshThreat()')
check("the in-combat 'only once my threat is over' line does not hide it",
      rt.eval("UP()") is True)
rt.execute('NS.Set("threatShowAbove", 0) IN_COMBAT = true NS.RefreshThreat()')
check("in combat with no target it still hides", rt.eval("UP()") is False)
rt.execute('HAS_TARGET = true')
rt.execute('IN_COMBAT = true NS.Set("threatParty", false) NS.RefreshThreat()')
check("'In a party' off hides it in a party", rt.eval("UP()") is False)
rt.execute('NS.Set("threatParty", true) INSTANCE = "party" NS.Set("threatDungeon", false) NS.RefreshThreat()')
check("'Dungeons' off hides it in a dungeon", rt.eval("UP()") is False)
rt.execute('INSTANCE = "raid" NS.RefreshThreat()')
check("but not in a raid instance", rt.eval("UP()") is True)
rt.execute('INSTANCE = "pvp" NS.RefreshThreat()')
check("battlegrounds are off by default", rt.eval("UP()") is False)
rt.execute('INSTANCE = nil NS.Set("threatWorld", false) NS.RefreshThreat()')
check("'Open world' off hides it outdoors", rt.eval("UP()") is False)

rt, g = threat_rt()
rt.execute('NS.Set("threatShowAbove", 80) NS.RefreshThreat()')
check("'only once my threat is over 80%' hides it at 70%", rt.eval("UP()") is False)
rt.execute('THREAT.player = 85 NS.RefreshThreat()')
check("and shows it at 85%", rt.eval("UP()") is True)

rt, g = threat_rt()
rt.execute('THREAT = {} NS.RefreshThreat()')
check("nobody with threat yet hides it by default", rt.eval("UP()") is False)
rt.execute('NS.Set("threatShowEmpty", true) NS.RefreshThreat()')
check("unless asked to show it anyway", rt.eval("UP()") is True)

rt, g = threat_rt()
rt.execute('TARGET_HOSTILE = false NS.RefreshThreat()')
check("a friendly target hides it by default", rt.eval("UP()") is False)
rt.execute('NS.Set("threatTargetTarget", true) NS.RefreshThreat()')
check("with 'their target' on it follows the friend's target", rt.eval("UP()") is True)

rt, g = threat_rt()
rt.execute('NS.Set("threatLinger", 5) NOW = 1000 NS.RefreshThreat() '
           'IN_COMBAT = false NOW = 1003 NS.RefreshThreat()')
check("it lingers after the fight", rt.eval("UP()") is True)
rt.execute('NOW = 1006 NS.RefreshThreat()')
check("and goes once the linger is over", rt.eval("UP()") is False)

rt, g = threat_rt()
rt.execute('IN_GROUP = false IN_COMBAT = false NS.SetThreatPreview(true)')
check("preview shows it with no fight at all", rt.eval("UP()") is True)
check("with sample bars", rt.eval('SHOWN("Rogue")') is not None)
rt.execute('NS.OpenPanel("threat") ChairPlusPanel:Hide() ChairPlusPanel._scripts.OnHide(ChairPlusPanel)')
check("closing the options ends the preview",
      rt.eval("UP()") is False and g.NS.threatPreview is False)

# The bug found in game on 2026-09-25: an unlocked meter drew sample bars no
# matter what the Preview button said, so End preview did nothing.
rt, g = threat_rt()
rt.execute('IN_GROUP = false IN_COMBAT = false NS.OpenPanel("threat")')
rt.execute("""
function CLICK(caption)
    for _, f in ipairs(FRAMES) do
        local l = rawget(f, "labelText")
        if l and rawget(l, "_text") == caption and rawget(f, "_shown") then
            rawget(f, "_scripts").OnClick(f)
            return true
        end
    end
    return false
end
function THREAT_H() return rawget(ChairPlusThreat, "_h") end
""")
rt.execute('CLICK("Move / resize")')
check("unlocking starts the preview", g.NS.threatPreview is True)
check("so the meter is up with sample bars",
      rt.eval("UP()") is True and rt.eval("THREAT_H()") == 20 + 10 * 16 + 4,
      str(rt.eval("THREAT_H()")))
check("and the button offers to end it", rt.eval('SHOWN_BUTTON("End preview")') is True)
rt.execute('CLICK("End preview")')
check("End preview on an unlocked meter ends it", g.NS.threatPreview is False)
check("leaving an empty meter to drag, not the sample bars",
      rt.eval("UP()") is True and rt.eval("THREAT_H()") == 20 + 16 + 4,
      str(rt.eval("THREAT_H()")))
check("and the button says Preview again", rt.eval('SHOWN_BUTTON("Preview")') is True)
rt.execute('CLICK("Preview")')
check("Preview turns it back on while unlocked",
      g.NS.threatPreview is True and rt.eval("THREAT_H()") == 20 + 10 * 16 + 4)
rt.execute('CLICK("Lock meter")')
check("locking ends the preview and puts the meter away",
      g.NS.threatPreview is False and rt.eval("UP()") is False)
rt.execute('CLICK("Preview")')
check("Preview on a locked meter shows it", rt.eval("UP()") is True)
rt.execute('CLICK("End preview")')
check("and End preview hides it again", rt.eval("UP()") is False and g.NS.threatPreview is False)

rt, g = threat_rt()
rt.execute('rawset(ChairPlusThreat, "EnableMouse", function() error("kaboom") end) FireEvent("PLAYER_TARGET_CHANGED") '
           'FireEvent("PLAYER_TARGET_CHANGED")')
check("an error inside the meter is reported rather than swallowed",
      printed_text(rt).count("kaboom") == 1, printed_text(rt)[-200:])

# Secret names (found in game on 2026-09-25: "attempt to compare local 'text'
# (a secret string value)" from ns.Text). Plain Lua cannot make a string that
# throws on compare, so these pin down the two things around it that can be
# tested: ns.Text never raises, and nothing sorts by a name.
rt, g = threat_rt()
check("ns.Text answers nil for a value it cannot read, instead of raising",
      rt.eval("NS.Text(setmetatable({}, { __tostring = function() error('secret') end }))") is None)
rt.execute('THREAT = { player = 50, party1 = 50, party2 = 50 } NS.RefreshThreat()')
rows = g.NS.ThreatRows()
check("equal threat keeps group order rather than comparing names",
      [rows[i].name for i in range(1, 4)] == ["Chairface", "Tank", "Healer"],
      str([rows[i].name for i in range(1, 4)]))

# Mouse.
rt, g = threat_rt()
check("locked and click-through by default",
      rt.eval("rawget(ChairPlusThreat, '_mouse')") is False)
rt.execute('NS.Set("threatClickThrough", false)')
check("click-through off takes the mouse out of combat",
      rt.eval("rawget(ChairPlusThreat, '_mouse')") is True)
rt.execute('LOCKDOWN = true FireEvent("PLAYER_REGEN_DISABLED")')
check("and lets it through again in combat",
      rt.eval("rawget(ChairPlusThreat, '_mouse')") is False)
rt.execute('NS.Set("threatClickThroughCombat", false)')
check("unless that is off too", rt.eval("rawget(ChairPlusThreat, '_mouse')") is True)
rt.execute('NS.Set("threatClickThrough", true) NS.Set("threatLocked", false)')
check("unlocked always takes the mouse, to be dragged",
      rt.eval("rawget(ChairPlusThreat, '_mouse')") is True)

# Rows.
rt, g = threat_rt()
rt.execute('THREAT.player = 5 NS.Set("threatAlwaysMe", false) NS.Set("threatMaxRows", 2)')
check("'Most bars' cuts the list", rt.eval("rawget(ChairPlusThreat, '_h')") == 20 + 2 * 16 + 4,
      str(rt.eval("rawget(ChairPlusThreat, '_h')")))
check("leaving the lower bars off", rt.eval('SHOWN("Healer")') is not None)
rt, g = threat_rt("THREAT.player = 5")
rt.execute('NS.Set("threatMaxRows", 2)')
check("but your own bar stays on it, in place of the last",
      rt.eval('SHOWN("Healer")') is None)

# Warning.
rt, g = threat_rt()
rt.execute('NS.Set("threatWarn", true) NS.Set("threatWarnAt", 60) NS.RefreshThreat() NS.RefreshThreat()')
check("passing the warning line warns once", rt.eval("#ERRORS") == 1, str(rt.eval("#ERRORS")))
check("with a sound", rt.eval("SOUNDS[1]") == 8959)
rt.execute('THREAT.player = 40 NS.RefreshThreat() THREAT.player = 70 NS.RefreshThreat()')
check("and again after dropping back and climbing", rt.eval("#ERRORS") == 2)
rt, g = threat_rt()
rt.execute('THREAT.party1 = 50 THREAT.player = 100 '
           'UnitDetailedThreatSituation = function(u) local p = THREAT[u] if not p then return nil end '
           'return u == "player", 3, p end '
           'NS.Set("threatWarn", true) NS.Set("threatWarnAt", 60) NS.RefreshThreat()')
check("the tank is never warned", rt.eval("#ERRORS") == 0)
# A tank who is not on top this moment -- the pull, a taunt swap -- is still
# the tank, and is not told to ease off. The role chosen decides, not class.
for setup, who, warned in (
    ('function UnitGroupRolesAssigned() return "TANK" end', "given the tank role in the group", 0),
    ('function UnitGroupRolesAssigned() return "NONE" end C_LFGList = { GetRoles = function() return { tank = true } end }',
     "with tank chosen in the group finder", 0),
    ('function UnitGroupRolesAssigned() return "DAMAGER" end C_LFGList = { GetRoles = function() return { tank = true } end }',
     "assigned damage in the group, whatever the finder says", 1),
    ('function UnitClass() return "Warrior", "WARRIOR" end function GetShapeshiftForm() return 2 end',
     "a warrior in Defensive Stance with no tank role chosen", 1),
):
    rt, g = threat_rt(setup)
    rt.execute('NS.Set("threatWarn", true) NS.Set("threatWarnAt", 60) NS.RefreshThreat() NS.RefreshThreat()')
    check(("not warned" if warned == 0 else "warned") + " when " + who, rt.eval("#ERRORS") == warned,
          str(rt.eval("#ERRORS")))

# Resizing.
rt, g = threat_rt()
rt.execute('NS.Set("threatLocked", false)')
rt.execute("""
for _, f in ipairs(FRAMES) do
    local s = rawget(f, "_scripts")
    if s and s.OnMouseDown and rawget(f, "_parent") == ChairPlusThreat then GRIP = f end
end
rawset(ChairPlusThreat, "StartSizing", function() SIZING = true end)
rawset(ChairPlusThreat, "GetWidth", function() return 312 end)
rawset(ChairPlusThreat, "GetHeight", function() return 20 + 5 * 16 + 4 end)
""")
check("unlocked, there is a resize grip", rt.eval("GRIP ~= nil") is True)
rt.execute("GRIP._scripts.OnMouseDown(GRIP) GRIP._scripts.OnMouseUp(GRIP)")
check("dragging the grip sets the width",
      rt.eval("SIZING") is True and g.NS.Get("threatWidth") == 312, str(g.NS.Get("threatWidth")))
check("and how many bars fit", g.NS.Get("threatMaxRows") == 5, str(g.NS.Get("threatMaxRows")))

print("\nMovable character panel and bags")
MOVERS_SETUP = """
LAYOUTS = 0
function UpdateUIPanelPositions(frame)
    LAYOUTS = LAYOUTS + 1
    CharacterFrame:ClearAllPoints()
    CharacterFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
end
function hooksecurefunc(name, fn)
    local original = _G[name]
    _G[name] = function(...)
        local a, b, c = original(...)
        fn(...)
        return a, b, c
    end
end
function InCombatLockdown() return IN_LOCKDOWN end
IN_LOCKDOWN = false
function MakeWindow(name)
    local f = MakeMock()
    _G[name] = f
    rawset(f, "GetCenter", function(self) return rawget(self, "_cx"), rawget(self, "_cy") end)
    rawset(f, "GetEffectiveScale", function() return 1 end)
    rawset(f, "IsProtected", function() return PROTECTED end)
    rawset(f, "GetFrameLevel", function() return 5 end)
    rawset(f, "StartMoving", function(self) rawset(self, "_moving", true) end)
    rawset(f, "StopMovingOrSizing", function(self) rawset(self, "_moving", false) end)
    rawset(f, "HookScript", function(self, script, fn)
        local s = rawget(self, "_hooks") or {}
        s[script] = fn
        rawset(self, "_hooks", s)
    end)
    return f
end
PROTECTED = false
rawset(UIParent, "GetCenter", function() return 960, 540 end)
rawset(UIParent, "GetEffectiveScale", function() return 1 end)
MakeWindow("CharacterFrame")
"""

rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT()")
handle = rt.eval("CharacterFrame.chairMoverHandle")
check("the character panel gets a header drag handle", handle is not None)
check("the window is made movable", rt.eval("rawget(CharacterFrame, '_movable')") is True)
scripts = rt.eval("rawget(CharacterFrame.chairMoverHandle, '_scripts')")
scripts.OnDragStart(handle)
check("dragging the header moves the window", rt.eval("rawget(CharacterFrame, '_moving')") is True)
rt.execute("rawset(CharacterFrame, '_cx', 1060) rawset(CharacterFrame, '_cy', 490)")
scripts.OnDragStop(handle)
spot = rt.eval("NS.Profile().movers.CharacterFrame")
check("dropping it saves an offset from the screen centre",
      spot is not None and spot.x == 100 and spot.y == -50, str(spot and (spot.x, spot.y)))
rt.execute("UpdateUIPanelPositions(CharacterFrame)")
point = rt.eval("rawget(CharacterFrame, '_point')")
check("Blizzard's re-layout is undone straight away",
      point.point == "CENTER" and point.x == 100 and point.y == -50,
      f"{point.point} {point.x} {point.y}")

rt.execute("IN_LOCKDOWN = true PROTECTED = true UpdateUIPanelPositions(CharacterFrame)")
point = rt.eval("rawget(CharacterFrame, '_point')")
check("in combat a protected window is left where Blizzard put it",
      point.point == "TOPLEFT", point.point)
rt.execute('IN_LOCKDOWN = false FireEvent("PLAYER_REGEN_ENABLED")')
point = rt.eval("rawget(CharacterFrame, '_point')")
check("and moved back once combat ends", point.point == "CENTER", point.point)

rt.execute('PROTECTED = false SlashCmdList["CHAIRPLUS"]("movers reset")')
rt.execute("UpdateUIPanelPositions(CharacterFrame)")
point = rt.eval("rawget(CharacterFrame, '_point')")
check("/chair plus movers reset hands it back to Blizzard", point.point == "TOPLEFT",
      point.point)

# The bank is laid out by the same panel manager as the character panel, and
# each keeps its own spot.
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("MakeWindow('BankFrame') BOOT()")
check("the bank gets a header drag handle",
      rt.eval("BankFrame.chairMoverHandle") is not None)
bank = rt.eval("rawget(BankFrame.chairMoverHandle, '_scripts')")
bank.OnDragStart(rt.eval("BankFrame.chairMoverHandle"))
rt.execute("rawset(BankFrame, '_cx', 760) rawset(BankFrame, '_cy', 600)")
bank.OnDragStop(rt.eval("BankFrame.chairMoverHandle"))
spot = rt.eval("NS.Profile().movers.BankFrame")
check("dropping the bank saves its own spot",
      spot is not None and spot.x == -200 and spot.y == 60, str(spot and (spot.x, spot.y)))
rt.execute("BankFrame:ClearAllPoints() BankFrame:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 0, -104) "
           "UpdateUIPanelPositions(BankFrame)")
point = rt.eval("rawget(BankFrame, '_point')")
check("and the bank stays there when Blizzard lays the screen out",
      point.point == "CENTER" and point.x == -200 and point.y == 60,
      f"{point.point} {point.x} {point.y}")
check("without moving the character panel, which has no spot saved",
      rt.eval("NS.Profile().movers.CharacterFrame") is None
      and rt.eval("rawget(CharacterFrame, '_point').point") == "TOPLEFT")

# The auction house UI is load-on-demand: its frame appears only when the
# auction house is first visited.
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT()")
check("no auction frame before the first visit is not an error",
      rt.eval("AuctionHouseFrame") is None)
rt.execute("MakeWindow('AuctionHouseFrame') FireEvent('ADDON_LOADED', 'Blizzard_AuctionHouseUI')")
check("the auction house gets its handle once its UI loads",
      rt.eval("AuctionHouseFrame.chairMoverHandle") is not None)
ah = rt.eval("rawget(AuctionHouseFrame.chairMoverHandle, '_scripts')")
ah.OnDragStart(rt.eval("AuctionHouseFrame.chairMoverHandle"))
rt.execute("rawset(AuctionHouseFrame, '_cx', 960) rawset(AuctionHouseFrame, '_cy', 640)")
ah.OnDragStop(rt.eval("AuctionHouseFrame.chairMoverHandle"))
rt.execute("AuctionHouseFrame:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 0, -104) "
           "UpdateUIPanelPositions(AuctionHouseFrame)")
point = rt.eval("rawget(AuctionHouseFrame, '_point')")
check("and stays where it was dropped when Blizzard lays the screen out",
      point.point == "CENTER" and point.x == 0 and point.y == 100,
      f"{point.point} {point.x} {point.y}")
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT() MakeWindow('AuctionFrame') FireEvent('AUCTION_HOUSE_SHOW')")
check("an older client's AuctionFrame is handled the same way",
      rt.eval("AuctionFrame.chairMoverHandle") is not None)

# The guild window: the guild and communities window on this engine, loaded
# on demand; an older GuildFrame on others.
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT() MakeWindow('CommunitiesFrame') FireEvent('ADDON_LOADED', 'Blizzard_Communities')")
check("the guild window gets its handle once it loads",
      rt.eval("CommunitiesFrame.chairMoverHandle") is not None)
cf = rt.eval("rawget(CommunitiesFrame.chairMoverHandle, '_scripts')")
cf.OnDragStart(rt.eval("CommunitiesFrame.chairMoverHandle"))
rt.execute("rawset(CommunitiesFrame, '_cx', 760) rawset(CommunitiesFrame, '_cy', 540)")
cf.OnDragStop(rt.eval("CommunitiesFrame.chairMoverHandle"))
rt.execute("CommunitiesFrame:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 0, -104) "
           "UpdateUIPanelPositions(CommunitiesFrame)")
point = rt.eval("rawget(CommunitiesFrame, '_point')")
check("and stays where it was dropped",
      point.point == "CENTER" and point.x == -200 and point.y == 0,
      f"{point.point} {point.x} {point.y}")
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT() MakeWindow('GuildFrame') FireEvent('PLAYER_LOGIN')")
check("an older client's GuildFrame is handled the same way",
      rt.eval("GuildFrame.chairMoverHandle") is not None)

# The profession window is load-on-demand as well.
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT()")
check("no profession window before one is opened is not an error",
      rt.eval("TradeSkillFrame") is None)
rt.execute("MakeWindow('TradeSkillFrame') FireEvent('TRADE_SKILL_SHOW')")
check("the profession window gets its handle once it exists",
      rt.eval("TradeSkillFrame.chairMoverHandle") is not None)
ts = rt.eval("rawget(TradeSkillFrame.chairMoverHandle, '_scripts')")
ts.OnDragStart(rt.eval("TradeSkillFrame.chairMoverHandle"))
rt.execute("rawset(TradeSkillFrame, '_cx', 860) rawset(TradeSkillFrame, '_cy', 540)")
ts.OnDragStop(rt.eval("TradeSkillFrame.chairMoverHandle"))
rt.execute("TradeSkillFrame:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 0, -104) "
           "UpdateUIPanelPositions(TradeSkillFrame)")
point = rt.eval("rawget(TradeSkillFrame, '_point')")
check("and stays where it was dropped when Blizzard lays the screen out",
      point.point == "CENTER" and point.x == -100 and point.y == 0,
      f"{point.point} {point.x} {point.y}")
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT() MakeWindow('CraftFrame') FireEvent('CRAFT_SHOW')")
check("the enchanting window (CraftFrame) is handled the same way",
      rt.eval("CraftFrame.chairMoverHandle") is not None)

# The classic beta has no CRAFT_SHOW; registering it throws in the real client.
rt = lua51.LuaRuntime(unpack_returned_tuples=True)
rt.execute(HARNESS)
rt.execute("UNKNOWN_EVENTS = { CRAFT_SHOW = true }")
try:
    rt.execute(LOAD)
    loaded = True
except Exception as err:
    loaded = False
    print(f"       {err}")
check("a client without CRAFT_SHOW loads every file without an error", loaded)
rt.execute(MOVERS_SETUP)
rt.execute("BOOT()")
check("a client without CRAFT_SHOW still gets the movers loaded",
      rt.eval("CharacterFrame.chairMoverHandle") is not None)
rt.execute("MakeWindow('TradeSkillFrame') FireEvent('TRADE_SKILL_SHOW')")
check("and the profession window still gets its handle",
      rt.eval("TradeSkillFrame.chairMoverHandle") is not None)

# The bag frame does not exist until the bags are first opened.
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT()")
check("no bag frame yet is not an error", rt.eval("ContainerFrameCombinedBags") is None)
rt.execute("MakeWindow('ContainerFrameCombinedBags') FireEvent('ADDON_LOADED', 'Blizzard_Whatever')")
check("the bags get their handle once the frame exists",
      rt.eval("ContainerFrameCombinedBags.chairMoverHandle") is not None)


print("\nThreat % on the nameplates")
rt, g = fresh()
rt.execute('''
BOOT()
NP_COMBAT = true
function UnitAffectingCombat() return NP_COMBAT end
TANK = true
NS.PlayerIsTank = function() return TANK end
ROWS = {}
NS.ThreatRows = function() return ROWS end
function NPTEXT(unit)
    local t, r, g, b = NS.NameplateThreatText(unit or "nameplate1")
    return t, r
end
''')
rt.execute('ROWS = { { name = "Chairface Chippendale", pct = 100, tanking = true, isMe = true },'
           ' { name = "Brakk Stonefist", pct = 72.4, tanking = false } }')
check("tank holding it: the highest threat behind them", rt.eval("NPTEXT()") == ("72%", 1))
rt.execute('ROWS = { { name = "Chairface Chippendale", pct = 100, tanking = true, isMe = true },'
           ' { name = "Brakk Stonefist", pct = 34, tanking = false } }')
check("well clear of it, the number is green", rt.eval("NPTEXT()") == ("34%", 0.4))
rt.execute('ROWS = { { name = "Chairface Chippendale", pct = 100, tanking = true, isMe = true },'
           ' { name = "Brakk Stonefist", pct = 93, tanking = false } }')
check("about to lose it, red", rt.eval("NPTEXT()") == ("93%", 1) and
      rt.eval("(function() local _, r, g = NS.NameplateThreatText('nameplate1') return g end)()") < 0.5)
rt.execute('ROWS = { { name = "Chairface Chippendale", pct = 100, tanking = true, isMe = true } }')
check("alone on it: nothing to show", rt.eval("(NPTEXT())") is None)
rt.execute('ROWS = { { name = "Brakk Stonefist", pct = 100, tanking = true },'
           ' { name = "Chairface Chippendale", pct = 76.2, tanking = false, isMe = true } }')
check("someone else has it: their first name and the tank's own %",
      rt.eval("NPTEXT()") == ("Brakk 76%", 1))
rt.execute("TANK = false")
rt.execute('ROWS = { { name = "Brakk Stonefist", pct = 100, tanking = true },'
           ' { name = "Chairface Chippendale", pct = 58, tanking = false, isMe = true } }')
check("not the tank: their own threat", rt.eval("NPTEXT()") == ("58%", 0.4))
rt.execute('ROWS = { { name = "Brakk Stonefist", pct = 100, tanking = true } }')
check("not the tank, a mob in the fight they have not hit: 0%", rt.eval("NPTEXT()") == ("0%", 0.4))
rt.execute('ROWS = {}')
check("and with nobody from the group on it yet, still 0%", rt.eval("NPTEXT()") == ("0%", 0.4))
rt.execute('ROWS = { { name = "Chairface Chippendale", pct = 0, tanking = true, isMe = true } }')
check("solo DPS holding the mob: 100%, whatever the number says", rt.eval("NPTEXT()") == ("100%", 1))
rt.execute('''ROWS = {}
function UnitIsUnit(a, b) return a == "nameplate1target" and b == "player" end''')
check("solo DPS left off the list, the mob on them: 100%", rt.eval("NPTEXT()") == ("100%", 1))
rt.execute('''function UnitIsUnit() return false end
function UnitThreatSituation() return 3 end''')
check("and by threat status alone: 100%", rt.eval("NPTEXT()") == ("100%", 1))
rt.execute('''function UnitThreatSituation() return 1 end''')
check("past the tank with no number: high, in red", rt.eval("NPTEXT()") == ("high", 1))
# Forever keeps the % secret in combat, so the row never makes the list. The
# secret itself is handed on for the plate to draw; it can't be rounded or
# colored, so it comes in white.
rt.execute('''SECRET_PCT = setmetatable({}, { __tostring = function() error("secret") end })
REAL_ISSECRET = NS.IsSecret
NS.IsSecret = function(v) return v == SECRET_PCT end
function UnitDetailedThreatSituation(u, mob) if u == "player" then return false, 0, SECRET_PCT, 40, 1000 end end''')
check("a secret % of their own: handed on as it is, in white",
      rt.eval("(function() local t, r, g, b, s = NS.NameplateThreatText('nameplate1') return t == nil and r == 1 and g == 1 and b == 1 and s == SECRET_PCT end)()") is True)
rt.execute('''function UnitThreatSituation() return 3 end''')
check("the mob on them still reads 100%, secret or not", rt.eval("NPTEXT()") == ("100%", 1))
rt.execute('''function UnitThreatSituation() return 1 end
function UnitDetailedThreatSituation() return nil end''')
check("no number at all, past the tank: still high", rt.eval("NPTEXT()") == ("high", 1))
rt.execute("UnitDetailedThreatSituation = nil NS.IsSecret = REAL_ISSECRET")
rt.execute('''function UnitThreatSituation() return nil end''')
rt.execute("TANK = true")
check("the tank on an empty list: nothing, as before", rt.eval("(NPTEXT())") is None)
rt.execute("TANK = false")
rt.execute('ROWS = { { name = "Brakk Stonefist", pct = 100, tanking = true },'
           ' { name = "Chairface Chippendale", pct = 58, tanking = false, isMe = true } }')
rt.execute("NP_COMBAT = false")
check("out of combat: nothing", rt.eval("(NPTEXT())") is None)

# On a plate: our own frame over the health bar, aligned as chosen.
rt.execute('''
NP_COMBAT = true
PLATE = CreateFrame("Frame")
PLATE.UnitFrame = CreateFrame("Frame")
PLATE.UnitFrame.healthBar = CreateFrame("StatusBar")
PLATE.UnitFrame.healthBar.SetStatusBarColor = function() end
C_NamePlate = { GetNamePlateForUnit = function() return PLATE end }
NS.Set("npThreatText", true)
NS.ShowNameplateThreatText("nameplate1")
''')
label_text = rt.eval("(function() for _, f in ipairs(FRAMES) do local t = rawget(f, '_text') if t == '58%' then return t end end end)()")
check("switched on, the % is drawn on the plate", label_text == "58%", label_text)
check("the plate's own health bar is left alone",
      rt.eval("rawget(PLATE.UnitFrame.healthBar, '_text')") is None)
rt.execute('NS.Set("npThreatText", false) NS.ShowNameplateThreatText("nameplate1")')
rt.execute('NS.Set("npThreatText", true) NS.ShowNameplateThreatText("nameplate1")')
shown_on = rt.eval("NS.npThreatLabels[PLATE].frame:IsShown()")
rt.execute('NS.Set("npThreatText", false) NS.ShowNameplateThreatText("nameplate1")')
check("switched off, it hides", shown_on is True and rt.eval("NS.npThreatLabels[PLATE].frame:IsShown()") is False)
rt.execute('NS.Set("npThreatText", true) NS.Set("npThreatTextAlign", "RIGHT") NS.ShowNameplateThreatText("nameplate1")')
check("the Position setting moves it to the right",
      rt.eval("NS.npThreatLabels[PLATE].text._point.point") == "RIGHT")
rt.execute('NS.Set("npThreatTextAlign", "LEFT") NS.ShowNameplateThreatText("nameplate1")')
check("and to the left", rt.eval("NS.npThreatLabels[PLATE].text._point.point") == "LEFT")
rt.execute('''NS.Set("npThreatTextAlign", "CENTER")
SECRET_PCT = setmetatable({}, { __tostring = function() error("secret") end })
REAL_ISSECRET = NS.IsSecret
NS.IsSecret = function(v) return v == SECRET_PCT end
ROWS = {}
function UnitThreatSituation() return 0 end
function UnitDetailedThreatSituation(u) if u == "player" then return false, 0, SECRET_PCT end end
local text = NS.npThreatLabels[PLATE].text
text.SetFormattedText = function(self, fmt, v) DREW_FMT, DREW_VALUE = fmt, v end
NS.ShowNameplateThreatText("nameplate1")''')
check("a secret % is drawn on the plate straight from the value",
      rt.eval("DREW_FMT") == "%d%%" and rt.eval("DREW_VALUE == SECRET_PCT") is True
      and rt.eval("NS.npThreatLabels[PLATE].frame:IsShown()") is True)
rt.execute('''NS.npThreatLabels[PLATE].text.SetFormattedText = function() error("secret") end
NS.ShowNameplateThreatText("nameplate1")''')
check("and a client that won't draw it hides the label rather than erroring",
      rt.eval("NS.npThreatLabels[PLATE].frame:IsShown()") is False)
rt.execute("UnitDetailedThreatSituation = nil UnitThreatSituation = nil NS.IsSecret = REAL_ISSECRET")
check("the option is on the threat meter's Nameplates page",
      any(rt.eval(f"NS.ROWS[{i}].key") == "npThreatText" and rt.eval(f"NS.ROWS[{i}].tab") == "threatnp"
          for i in range(1, rt.eval("#NS.ROWS") + 1)))
check("it ships off, centered", g.NS.defaults.npThreatText is False and g.NS.defaults.npThreatTextAlign == "CENTER")
check("the font path is a real path, backslash and all",
      "Fonts\\\\FRIZQT__.TTF" in open("ChairPlus/Nameplates.lua", encoding="utf-8").read())

# Lua 5.1 drops the backslash of an escape it does not know, so
# "Interface\TargetingFrame" quietly becomes a path to nothing: a texture
# or font that never draws, and no error anywhere. The harness runs 5.1 too,
# so it has to be looked for.
def bad_escapes():
    known = set('abfnrtv\\"\'\n0123456789')
    string_re = re.compile(r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'')
    found = []
    for path in glob.glob("**/*.lua", recursive=True):
        for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            for m in string_re.finditer(line):
                s = m.group(1) if m.group(1) is not None else m.group(2)
                i = 0
                while i < len(s):
                    if s[i] == "\\":
                        if i + 1 < len(s) and s[i + 1] not in known:
                            found.append(f"{path}:{n}")
                            break
                        i += 2
                    else:
                        i += 1
    return found
bad = bad_escapes()
check("no string in any Lua file loses a backslash", not bad, bad)

print("\nCombo points on the target's nameplate")
rt.execute('''
MY_CLASS = "ROGUE"
function UnitClass() return "Rogue", MY_CLASS end
function UnitExists() return true end
function UnitCanAttack() return true end
POINTS = 3
function GetComboPoints() return POINTS end
function UnitPowerMax() return 5 end
PIP_VALUES = {}
NS.Set("npComboPoints", true)
NS.ApplyModule("npComboPoints")
local combo = NS.npComboPips[PLATE]
for i, pip in ipairs(combo and combo.pips or {}) do
    rawset(pip, "SetValue", function(self, v) PIP_VALUES[i] = v end)
    rawset(pip, "GetMinMaxValues", nil)
end
NS.ShowNameplateCombo()
''')
check("a rogue gets five pips on the target's plate", rt.eval("#NS.npComboPips[PLATE].pips") == 5)
check("each pip is handed the count as it is, to clamp itself",
      all(rt.eval(f"PIP_VALUES[{i}]") == 3 for i in range(1, 6)))
check("and it shows", rt.eval("NS.npComboPips[PLATE].frame:IsShown()") is True)
rt.execute('function GetComboPoints() return nil end function UnitPower() return 4 end')
check("without the classic call, the player's combo power answers",
      rt.eval("(function() local n, from = NS.ComboPointCount() return from end)()") == "UnitPower")
rt.execute('function GetComboPoints() return 0 end')
check("a plain 0 from the classic call gives way to the combo power",
      rt.eval("(function() local n, from = NS.ComboPointCount() return n, from end)()") == (4, "UnitPower"))
rt.execute('function UnitPower() return 0 end')
check("both 0: 0", rt.eval("(NS.ComboPointCount())") == 0)
rt.execute('UnitCanAttack = function() return nil end NS.ShowNameplateCombo()')
check("a target the client will not say it can attack still gets them",
      rt.eval("NS.npComboPips[PLATE].frame:IsShown()") is True)
rt.execute('PRINTED = {} NS.Print = function(...) PRINTED[#PRINTED + 1] = table.concat({...}, " ") end NS.ProbeCombo()')
check("/chair threat combo says why",
      any("pips: shown" in (rt.eval(f"PRINTED[{i}]") or "") for i in range(1, rt.eval("#PRINTED") + 1)))
rt.execute('NS.Set("npComboPoints", false) NS.ShowNameplateCombo()')
check("switched off, it hides", rt.eval("NS.npComboPips[PLATE].frame:IsShown()") is False)
rt.execute('NS.Set("npComboPoints", true) MY_CLASS = "WARRIOR" NS.ShowNameplateCombo()')
check("not a rogue: nothing", rt.eval("NS.npComboPips[PLATE].frame:IsShown()") is False)
check("the option is only offered to rogues",
      rt.eval('(function() for _, r in ipairs(NS.ROWS) do if r.key == "npComboPoints" then return NS.RowFits(r) end end end)()') is False)
rt.execute('MY_CLASS = "ROGUE"')
check("and a rogue sees it",
      rt.eval('(function() for _, r in ipairs(NS.ROWS) do if r.key == "npComboPoints" then return NS.RowFits(r) end end end)()') is True)
check("it ships off", g.NS.defaults.npComboPoints is False)

print("\nOther parts' settings inside the menu")
EMBED_SETUP = """
UISpecialFrames = { "FakeWin" }
FAKE = CreateFrame("Frame", "FakeWin", UIParent)
FAKE:SetMovable(true)
FAKE:Hide()
rawset(FAKE, "GetWidth", function() return 760 end)
rawset(FAKE, "GetHeight", function() return 520 end)
FAKE_TITLE = CreateFrame("Frame", nil, FAKE)
FAKE_CLOSE = CreateFrame("Button", nil, FAKE)
FAKE.chairChrome = { FAKE_TITLE, FAKE_CLOSE }
-- Every anchor it holds, not just the last one set.
FAKE_POINTS = {}
do
    local setPoint, clear = FAKE.SetPoint, FAKE.ClearAllPoints
    rawset(FAKE, "SetPoint", function(self, point, ...)
        FAKE_POINTS[point] = { ... }
        return setPoint(self, point, ...)
    end)
    rawset(FAKE, "ClearAllPoints", function(self)
        FAKE_POINTS = {}
        return clear(self)
    end)
end
SHOWS = 0
PART = {
    key = "fake", title = "ChairFake",
    Window = function() return FAKE end,
    Show = function() SHOWS = SHOWS + 1 FAKE:SetPoint("CENTER") FAKE:Show() end,
}
function SPECIAL_COUNT(name)
    local n = 0
    for _, v in pairs(UISpecialFrames) do if v == name then n = n + 1 end end
    return n
end
-- The client's Escape: hide every shown frame in the list, walking it live.
function ESCAPE()
    for _, name in pairs(UISpecialFrames) do
        local f = _G[name]
        if f and f:IsShown() then
            f:Hide()
            local s = rawget(f, "_scripts")
            if s and s.OnHide then s.OnHide(f) end
        end
    end
end
"""
rt, g = fresh()
rt.execute(EMBED_SETUP)
rt.execute("BOOT() NS.OpenPanel('quests')")
base = (rt.eval("rawget(ChairPlusPanel, '_w')"), rt.eval("rawget(ChairPlusPanel, '_h')"))
check("the menu's Escape entry is there", rt.eval("SPECIAL_COUNT('ChairPlusPanel')") == 1)

opened = rt.eval("NS.OpenPage(PART)")
check("a part's page opens", opened is True)
check("its window is parented inside the menu",
      rt.eval("rawget(FAKE, '_parent') == ChairPlusPanel") is True)
check("below the menu's header, beside the sidebar",
      rt.eval("FAKE_POINTS.TOPLEFT ~= nil and FAKE_POINTS.TOPLEFT[1] == ChairPlusPanel"
              " and FAKE_POINTS.TOPLEFT[3] == 160 and FAKE_POINTS.TOPLEFT[4] == -44") is True)
# Pinned by its bottom corner too: when the ChairAuras grip resizes the menu,
# the window goes with it rather than coming loose from the menu's background.
check("and pinned to the menu's bottom corner, so it follows a resize",
      rt.eval("FAKE_POINTS.BOTTOMRIGHT ~= nil and FAKE_POINTS.BOTTOMRIGHT[1] == ChairPlusPanel") is True)
check("the part's own CENTER anchor is gone", rt.eval("FAKE_POINTS.CENTER") is None)
check("the part filled and showed it the way it always has",
      rt.eval("SHOWS") == 1 and rt.eval("FAKE:IsShown()") is True)
check("its own title and close button are hidden",
      rt.eval("FAKE_TITLE:IsShown()") is False and rt.eval("FAKE_CLOSE:IsShown()") is False)
check("it cannot be dragged out of the menu", rt.eval("rawget(FAKE, '_movable')") is False)
check("the menu grows to fit it beside the sidebar",
      rt.eval("rawget(ChairPlusPanel, '_w')") == 160 + 760
      and rt.eval("rawget(ChairPlusPanel, '_h')") == 520 + 44)
check("the sidebar stays up, so any page is one click away",
      rt.eval("SHOWN_BUTTON('Home')") is True and rt.eval("SHOWN_BUTTON('Info bar')") is True)
check("the part's own Escape entry is taken out while hosted",
      rt.eval("SPECIAL_COUNT('FakeWin')") == 0)

rt.execute("ESCAPE()")
check("Escape goes back to the menu", rt.eval("NS.HostedPart()") is None)
check("rather than closing it", rt.eval("ChairPlusPanel:IsShown()") is True)
rt.execute("RUN_TIMERS()")
check("and the menu's own Escape entry comes back once the key is done",
      rt.eval("SPECIAL_COUNT('ChairPlusPanel')") == 1)
rt.execute("ESCAPE()")
check("a second Escape closes the menu", rt.eval("ChairPlusPanel:IsShown()") is False)

rt.execute("NS.OpenPanel('quests') NS.OpenPage(PART)")
rt.execute("NS.ClosePage()")
check("Back hands the window back to the part",
      rt.eval("rawget(FAKE, '_parent') == UIParent") is True
      and rt.eval("FAKE:IsShown()") is False)
check("with its title and close button restored",
      rt.eval("FAKE_TITLE:IsShown()") is True and rt.eval("FAKE_CLOSE:IsShown()") is True)
check("draggable again", rt.eval("rawget(FAKE, '_movable')") is True)
check("and back in the Escape list", rt.eval("SPECIAL_COUNT('FakeWin')") == 1)
check("the menu is its old size again",
      (rt.eval("rawget(ChairPlusPanel, '_w')"), rt.eval("rawget(ChairPlusPanel, '_h')")) == base)
check("the sidebar is still there", rt.eval("SHOWN_BUTTON('Quests & NPCs')") is True)

rt.execute("NS.OpenPage(PART) PAGE_BUTTON('Travel')._scripts.OnClick(PAGE_BUTTON('Travel'))")
check("a page in the sidebar hands a hosted window back and shows itself",
      rt.eval("NS.HostedPart()") is None and rt.eval("NS.CurrentPage()") == "travel"
      and rt.eval('SHOWN("Show the waypoint arrow")') is True)

rt.execute("NS.OpenPage(PART)")
rt.execute("ChairPlusPanel:Hide() rawget(ChairPlusPanel, '_scripts').OnHide(ChairPlusPanel)")
check("closing the menu from a page hands the page back too",
      rt.eval("NS.HostedPart()") is None and rt.eval("rawget(FAKE, '_parent') == UIParent") is True)

rt.execute("PART.Show = function() error('boom') end")
ok = rt.eval("NS.OpenPage(PART)")
check("a page that fails to open is reported and the menu recovers",
      ok is False and rt.eval("NS.HostedPart()") is None
      and "failed to open" in printed_text(rt), printed_text(rt)[-160:])

print("\nMore movable windows")
rt, g = fresh()
rt.execute(MOVERS_SETUP)
rt.execute("BOOT() MakeWindow('LFGParentFrame') MakeWindow('QuestLogFrame') "
           "FireEvent('ADDON_LOADED', 'Blizzard_LookingForGroupUI')")
check("the group finder (LFG) gets a drag handle",
      rt.eval("LFGParentFrame.chairMoverHandle") is not None)
check("and so does the quest log", rt.eval("QuestLogFrame.chairMoverHandle") is not None)
rt.execute("MakeWindow('PVEFrame') FireEvent('ADDON_LOADED', 'Blizzard_PVE')")
check("the retail engine's group finder too", rt.eval("PVEFrame.chairMoverHandle") is not None)

print("\nCopying another character's settings")
COPY = """
PLAYER_GUID = "Player-1-A"
function UnitGUID(u) if u == "player" then return PLAYER_GUID end return NPC_GUID end
function UnitName(u) return PLAYER_GUID == "Player-1-A" and "Alpha" or "Beta" end
function GetRealmName() return "Forever" end
function AS(guid) PLAYER_GUID = guid NS.LoadSettings() end
"""
rt, g = fresh(stock=True)
rt.execute(COPY)
rt.execute('BOOT() NS.Set("osd", true) NS.Set("osdFontSize", 21) '
           'NS.Profile().movers.BankFrame = { x = 3, y = 4 }')
rt.execute('AS("Player-1-B")')
others = rt.eval("NS.OtherCharacters()")
check("the other character is offered by name and realm",
      len(others) == 1 and others[1].label == "Alpha-Forever",
      str([others[i].label for i in range(1, len(others) + 1)]))
rt.execute('WOWFTrackerAccountDB = { profiles = { ["guid:Player-1-A"] = { label = "Alpha-Forever", '
           'settings = { barWidth = 300 } }, ["guid:Player-1-B"] = { label = "Beta-Forever" } } }')
rt.execute('PARTS = NS.CopyCharacter("guid:Player-1-A")')
check("copying takes ChairPlus's settings", g.NS.IsEnabled("osd") is True
      and g.NS.Get("osdFontSize") == 21)
check("and its window positions", rt.eval("NS.Profile().movers.BankFrame.x") == 3)
check("and ChairTracker's",
      rt.eval('WOWFTrackerAccountDB.profiles["guid:Player-1-B"].settings.barWidth') == 300)
check("keeping this character's own label",
      rt.eval('WOWFTrackerAccountDB.profiles["guid:Player-1-B"].label') == "Beta-Forever")
rt.execute('NS.Set("osdFontSize", 9)')
rt.execute('AS("Player-1-A")')
check("and the source is left alone", g.NS.Get("osdFontSize") == 21)
rt.execute('AS("Player-1-B") NS.OpenPanel("general")')
check("the General page offers the copy", rt.eval('SHOWN_BUTTON("Import")') is True
      and any_text(rt, "|cffffffffAlpha-Forever|r"))
check("and the settings backup beside it",
      rt.eval('SHOWN_BUTTON("Export settings")') is True and rt.eval('SHOWN_BUTTON("Import settings")') is True)
rt.execute('NS.OpenPanel("quests")')
check("which the Plus page no longer carries", rt.eval('SHOWN_BUTTON("Export settings")') is False)

print("\nInvites, duels, resurrection")
SOCIAL = """
ACTIONS = {}
function AcceptGroup() table.insert(ACTIONS, "accept") end
function CancelDuel() table.insert(ACTIONS, "cancelduel") end
function DeclineGuild() table.insert(ACTIONS, "declineguild") end
function AcceptResurrect() table.insert(ACTIONS, "rez") end
C_SummonInfo = { ConfirmSummon = function() table.insert(ACTIONS, "summon") end }
HIDDEN = {}
function StaticPopup_Hide(which) HIDDEN[which] = true end
FRIENDS = { "Pal" }
C_FriendList = {
    GetNumFriends = function() return #FRIENDS end,
    GetFriendInfoByIndex = function(i) return { name = FRIENDS[i] } end,
}
GUILD = { "Mate-Forever" }
function IsInGuild() return true end
function GetNumGuildMembers() return #GUILD end
function GetGuildRosterInfo(i) return GUILD[i] end
function DID(what) for _, a in ipairs(ACTIONS) do if a == what then return true end end return false end
"""
rt, g = fresh(stock=True)
rt.execute(SOCIAL)
rt.execute("BOOT()")
rt.execute('FireEvent("PARTY_INVITE_REQUEST", "Pal")')
check("nothing is answered while it is all off", rt.eval("#ACTIONS") == 0)
rt.execute('NS.Set("autoInvite", true) FireEvent("PARTY_INVITE_REQUEST", "Pal")')
check("a friend's invite is accepted", rt.eval('DID("accept")') is True
      and rt.eval("HIDDEN.PARTY_INVITE") is True)
rt.execute('ACTIONS = {} FireEvent("PARTY_INVITE_REQUEST", "Mate")')
check("so is a guildmate's", rt.eval('DID("accept")') is True)
rt.execute('ACTIONS = {} FireEvent("PARTY_INVITE_REQUEST", "Stranger")')
check("but not a stranger's", rt.eval("#ACTIONS") == 0)
rt.execute('NS.Set("autoInviteGuild", false) ACTIONS = {} FireEvent("PARTY_INVITE_REQUEST", "Mate")')
check("guildmates can be left out", rt.eval("#ACTIONS") == 0)
rt.execute('SHIFT = true ACTIONS = {} FireEvent("PARTY_INVITE_REQUEST", "Pal") SHIFT = false')
check("holding shift leaves it to you", rt.eval("#ACTIONS") == 0)
rt.execute('NS.SetMany({ declineDuels = true, declineGuildInvites = true, '
           'autoResurrect = true, autoSummon = true })')
rt.execute('FireEvent("DUEL_REQUESTED", "Rogue") FireEvent("GUILD_INVITE_REQUEST", "Spam", "Spammers") '
           'FireEvent("RESURRECT_REQUEST", "Priest") FireEvent("CONFIRM_SUMMON")')
check("duels are declined", rt.eval('DID("cancelduel")') is True)
check("guild invites are declined", rt.eval('DID("declineguild")') is True)
check("resurrection is accepted", rt.eval('DID("rez")') is True)
check("summons are accepted", rt.eval('DID("summon")') is True)
check("and none of it is said in chat", "Declined a duel" not in printed_text(rt)
      and "Accepted" not in printed_text(rt), printed_text(rt)[-300:])

print("\nQuest turn-in safety")
QUESTS_SETUP = """
QUEST_ITEMS, QUEST_CURRENCIES, ITEMS_LOADED, COMPLETED, ACCEPTED = {}, 0, {}, 0, 0
function GetNumQuestCurrencies() return QUEST_CURRENCIES end
function GetNumQuestItems() return #QUEST_ITEMS end
function GetQuestItemInfo(kind, i)
    local item = QUEST_ITEMS[i]
    if kind ~= "required" or not item then return nil end
    return item.name, 0, 1, 1, true, item.id
end
function IsQuestCompletable() return true end
function CompleteQuest() COMPLETED = COMPLETED + 1 end
function AcceptQuest() ACCEPTED = ACCEPTED + 1 end
function GetQuestMoneyToGet() return 0 end
function GetQuestID() return QUEST_ID end
function QuestIsDaily() return false end
function QuestIsWeekly() return false end
"""
rt, g = fresh(stock=True)
rt.execute(QUESTS_SETUP)
rt.execute('BOOT() NS.Set("quests", true) NS.Set("questsTurnIn", true) NS.Set("questsAccept", true)')
rt.execute("""NS.GetItemInfo = function(id)
    local item = ITEMS_LOADED[id]
    if not item then return nil end
    local info = { item.name }
    info[17] = item.reagent
    return unpack(info, 1, 17)
end""")
rt.execute('QUEST_ITEMS = { { name = "Wolf Pelt", id = 1 } } ITEMS_LOADED[1] = { name = "Wolf Pelt" } FireEvent("QUEST_PROGRESS")')
check("a turn-in asking for a plain item goes ahead", rt.eval("COMPLETED") == 1)
rt.execute('QUEST_ITEMS = { { name = "Linen Cloth", id = 2 } } ITEMS_LOADED[2] = { name = "Linen Cloth", reagent = true } FireEvent("QUEST_PROGRESS")')
check("one asking for a crafting reagent is left to you", rt.eval("COMPLETED") == 1)
rt.execute('QUEST_ITEMS = { { name = "Something", id = 3 } } FireEvent("QUEST_PROGRESS")')
check("and so is one whose item the client has not loaded yet", rt.eval("COMPLETED") == 1)
rt.execute('QUEST_ITEMS = {} QUEST_CURRENCIES = 1 FireEvent("QUEST_PROGRESS")')
check("and one asking for a currency", rt.eval("COMPLETED") == 1)
rt.execute('NS.blockedQuests[4242] = true QUEST_ID = 4242 FireEvent("QUEST_DETAIL")')
check("a blocked quest offered straight to the detail window is not accepted", rt.eval("ACCEPTED") == 0)
rt.execute('QUEST_ID = 17 FireEvent("QUEST_DETAIL")')
check("an ordinary one is", rt.eval("ACCEPTED") == 1)

print("\nError spam filter")
ERRORS_SETUP = """
ERR_OUT_OF_RAGE = "Not enough rage"
ERR_SPELL_COOLDOWN = "Spell is not ready yet"
SHOWN_ERRORS = {}
UIErrorsFrame = MakeMock()
rawset(UIErrorsFrame, "_events", { UI_ERROR_MESSAGE = true })
table.insert(EVENT_FRAMES, UIErrorsFrame)
HANDLER_RAN_BY_US = 0
rawset(UIErrorsFrame, "_scripts", { OnEvent = function(self, event, kind, message)
    if FILTER_ACTIVE then HANDLER_RAN_BY_US = HANDLER_RAN_BY_US + 1 end
    table.insert(SHOWN_ERRORS, message)
end })
rawset(UIErrorsFrame, "AddMessage", function(self, text) table.insert(SHOWN_ERRORS, text) end)
rawset(UIErrorsFrame, "GetScript", function(self, name) return rawget(self, "_scripts")[name] end)
"""
rt, g = fresh(stock=True)
rt.execute(ERRORS_SETUP)
rt.execute('BOOT() NS.Set("filterErrors", true) FILTER_ACTIVE = true')
rt.execute('FireEvent("UI_ERROR_MESSAGE", 1, "Not enough rage") '
           'FireEvent("UI_ERROR_MESSAGE", 2, "Spell is not ready yet") '
           'FireEvent("UI_ERROR_MESSAGE", 3, "Inventory is full.")')
shown = [str(v) for v in rt.eval("SHOWN_ERRORS").values()]
check("the spam is dropped", "Not enough rage" not in shown and "Spell is not ready yet" not in shown,
      str(shown))
check("a real error still shows, once", shown.count("Inventory is full.") == 1, str(shown))
check("through the frame's AddMessage, never by running its own handler from ours",
      rt.eval("HANDLER_RAN_BY_US") == 0)
rt.execute('NS.Set("filterErrors", false) FILTER_ACTIVE = false SHOWN_ERRORS = {} FireEvent("UI_ERROR_MESSAGE", 1, "Not enough rage")')
check("switching it off hands the errors back",
      [str(v) for v in rt.eval("SHOWN_ERRORS").values()] == ["Not enough rage"])

print("\nOSD items and order")
OSD_MORE = """
function GetInventoryItemDurability(slot)
    if slot == 1 then return 20, 100 end
    if slot == 5 then return 90, 100 end
end
function GetInventoryItemTexture(unit, slot) if slot == 0 then return "Interface\\\\ICONS\\\\Ammo" end end
function GetInventoryItemCount(unit, slot) if slot == 0 then return 950 end end
NS.GetItemCount = function(id) if id == 6265 then return 12 end return 0 end
function UnitClass() return "Warlock", "WARLOCK" end
C_Map = {
    GetBestMapForUnit = function() return 1 end,
    GetPlayerMapPosition = function() return { x = 0.4523, y = 0.678 } end,
}
function OSD_LINE() return NS.OSDLine() end
"""
rt, g = fresh()
rt.execute(OSD_MORE)
rt.execute("BOOT() MONEY = 12345 NS.SetMany({ osdDurability = true, osdAmmo = true, "
           "osdShards = true, osdCoords = true }) NS.RefreshOSD() DRIVER_TICK()")
line = rt.eval("OSD_LINE()") or ""
check("durability shows the worst item, in red", "|cffff3333" in line and "20%" in line, line)
check("ammo shows the count in the ammo slot", "950" in line, line)
check("soul shards show for a warlock", "INV_Misc_Gem_Amethyst_02" in line and " 12" in line, line)
check("coordinates show to one decimal", "45.2, 67.8" in line, line)
check("in the default order: money first, coordinates after the bags",
      line.find("UI-GoldIcon") < line.find("INV_Misc_Bag_08") < line.find("45.2"), line)
rt.execute('NS.MoveOSDItem("coords", -1) NS.MoveOSDItem("coords", -1) NS.MoveOSDItem("coords", -1) '
           'NS.MoveOSDItem("coords", -1) NS.MoveOSDItem("coords", -1) NS.MoveOSDItem("coords", -1) '
           'NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("OSD_LINE()") or ""
check("moving an item up the list moves it left on the line",
      0 <= line.find("45.2") < line.find("UI-GoldIcon"), line)
check("and the order is saved", g.NS.Get("osdOrder").startswith("coords,"), g.NS.Get("osdOrder"))
rt.execute('NS.Set("osdOrder", "bogus,bags")')
order = [rt.eval("NS.OSDOrder()")[i].key for i in range(1, 11)]
check("a saved order missing items keeps them, and drops what it does not know",
      order[0] == "bags" and len(order) == 10 and "bogus" not in order, str(order))
rt.execute('NS.OpenPanel("osd")')
check("the OSD page lists the items", rt.eval('SHOWN("Durability")') is True
      and rt.eval('SHOWN("Coordinates")') is True and rt.eval('SHOWN("Money")') is True)
check("with buttons to reorder them", rt.eval('SHOWN_BUTTON("^")') is True)

print("\nArrow page and styles")
rt, g = arrow_rt('PIN = { map = 1, x = 0.5, y = 0.4 }')
rt.execute("NS.OpenPanel('arrow')")
check("the Arrow tab shows the arrow's options",
      rt.eval('SHOWN("Show the waypoint arrow")') is True
      and rt.eval('SHOWN("Style: |cffffffff3D arrow|r")') is True)
check("and its move button", rt.eval('SHOWN_BUTTON("Move arrow")') is True)
rt.execute("""
for _, f in ipairs(FRAMES) do
    local l = rawget(f, "labelText")
    if l and rawget(l, "_text") == ">" and rawget(f, "_shown") then NEXT_STYLE = f end
end
NEXT_STYLE._scripts.OnClick(NEXT_STYLE)
""")
check("> steps to the next style", g.NS.Get("arrowStyle") == "needle3d", str(g.NS.Get("arrowStyle")))
check("and the label follows", rt.eval('SHOWN("Style: |cffffffff3D compass needle|r")') is True)
rt.execute('NS.Set("arrowStyle", "flat")')
rt.execute("""
for _, f in ipairs(FRAMES) do
    if rawget(f, "_w") == 120 and rawget(f, "_h") == 120 then ARROW_TEX = f end
end
ROTATED = nil
rawset(ARROW_TEX, "SetRotation", function(self, a) ROTATED = a end)
TEXTURED = nil
rawset(ARROW_TEX, "SetTexture", function(self, t) TEXTURED = t end)
FACING = 1 DRIVER_TICK()
""")
check("a flat style uses its own texture", "arrow_flat" in str(rt.eval("TEXTURED")),
      str(rt.eval("TEXTURED")))
check("and is turned by rotation", rt.eval("ROTATED") is not None
      and abs(rt.eval("ROTATED") + 1) < 0.001, str(rt.eval("ROTATED")))
check("every style has its texture on disk", all(
    os.path.exists(os.path.join("ChairPlus", "arrow_%s.tga" % v))
    for v in ("flat", "chevron", "needle", "dart", "triangle", "ring")) and all(
    os.path.getsize(os.path.join("ChairPlus", "arrow3d_%s.tga" % v)) == 4194322
    for v in ("needle", "dart", "chevron", "triangle")))
rt.execute("""
TEXCOORD = nil
rawset(ARROW_TEX, "SetTexCoord", function(self, ...) TEXCOORD = { ... } end)
NS.Set("arrowStyle", "needle3d") DRIVER_TICK()
""")
check("a 3D style draws from its own sheet, a cell at a time",
      "arrow3d_needle" in str(rt.eval("TEXTURED")) and rt.eval("#TEXCOORD") == 4,
      str(rt.eval("TEXTURED")))
rt.execute('NS.Set("arrowShowDistance", false) DRIVER_TICK()')
check("the distance can be turned off", any_text(rt, "100 yd") is False)

# Another zone on the same continent: the zone is named on its own line under
# the quest's name, in the same font.
rt, g = arrow_rt(ZONES + "ON_MAP[2] = { { questID = 40, x = 0.5, y = 0.5 } }")
rt.execute("DRIVER_TICK()")
check("a quest in the next zone names that zone under the quest",
      any_text(rt, "Westfall") and any_text(rt, "Quest title 40"))
rt, g = arrow_rt(ZONES + "ON_MAP[1] = { { questID = 40, x = 0.5, y = 0.6 } }")
rt.execute("DRIVER_TICK()")
check("but not when it is in the zone you are in", any_text(rt, "Elwynn") is False)

print("\nOSD width holds still")
# Found in game on 2026-09-25: the frame rate changing width re-centred the
# whole line and resized the bar several times a second -- a flicker. Every
# item now has its own slot that only grows.
rt, g = fresh()
rt.execute("""
STRING_WIDTH = function(t) return t and #t * 6 or 0 end
FPS = 60
function GetFramerate() return FPS end
function GetNetStats() return 0, 0, 40, 40 end
BOOT() MONEY = 12345 NS.SetMany({ osdLatency = true }) NS.RefreshOSD() DRIVER_TICK()
""")
w1 = rt.eval("rawget(ChairPlusOSD, '_w')")
rt.execute("FPS = 7 NS.RefreshOSD() DRIVER_TICK()")
w2 = rt.eval("rawget(ChairPlusOSD, '_w')")
rt.execute("FPS = 144 NS.RefreshOSD() DRIVER_TICK()")
w3 = rt.eval("rawget(ChairPlusOSD, '_w')")
check("the bar keeps its width as the frame rate changes", w1 == w2 == w3, f"{w1} {w2} {w3}")
check("the frame rate is still what it shows", "144 fps" in (rt.eval("NS.OSDLine()") or ""),
      rt.eval("NS.OSDLine()"))

print("\nClock and alarm")
CLOCK = """
function GetGameTime() return 21, 5 end
date = function(fmt) if fmt == "*t" then return { hour = 9, min = 30 } end return "" end
CVARS_T = { timeMgrAlarmTime = "450", timeMgrAlarmEnabled = "1" }
C_CVar = { GetCVar = function(name) return CVARS_T[name] end }
TOGGLED = 0
function TimeManager_Toggle() TOGGLED = TOGGLED + 1 end
function GetFramerate() return 60 end
"""
rt, g = fresh()
rt.execute(CLOCK)
rt.execute("BOOT() NS.SetMany({ osdClock = true, osdAlarm = true }) NS.RefreshOSD() DRIVER_TICK()")
line = rt.eval("NS.OSDLine()") or ""
check("the clock shows this computer's time, 24-hour, by default", "09:30" in line, line)
check("the alarm shows the in-game alarm's time", "Horn_01" in line and "07:30" in line, line)
rt.execute('NS.Set("osdClockServer", true) NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("server time reads the realm's clock", "21:05" in line, line)
rt.execute('NS.Set("osdClock24", false) NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("12-hour shows AM and PM", "9:05 PM" in line and "7:30 AM" in line, line)
rt.execute('CVARS_T.timeMgrAlarmEnabled = "0" NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("an alarm that is switched off says so, dimmed", "7:30 AM off" in line, line)
check("12:00 is noon, not zero", rt.eval("NS.FormatClock(12, 0)") == "12:00 PM"
      and rt.eval("NS.FormatClock(0, 5)") == "12:05 AM")

# Clicking the alarm opens Blizzard's clock, even with the display locked.
rt.execute("""
for _, f in ipairs(FRAMES) do
    local s = rawget(f, "_scripts")
    if s and s.OnClick and rawget(f, "_parent") == ChairPlusOSD then ALARM_BUTTON = f end
end
""")
check("the alarm has a clickable spot", rt.eval("ALARM_BUTTON ~= nil") is True)
check("which takes the mouse though the display is locked",
      g.NS.IsEnabled("osdLocked") is True and rt.eval("rawget(ALARM_BUTTON, '_mouse')") is True)
rt.execute("ALARM_BUTTON._scripts.OnClick(ALARM_BUTTON)")
check("clicking it opens the in-game clock", rt.eval("TOGGLED") == 1)
rt.execute('NS.Set("osdAlarm", false) NS.RefreshOSD() DRIVER_TICK()')
check("and it goes when the alarm item is off", rt.eval("ALARM_BUTTON:IsShown()") is False)

# The frame rate sits right-aligned in its box, so its digits do not wiggle.
rt.execute('NS.Set("osdLatency", true) NS.RefreshOSD() DRIVER_TICK()')
rt.execute("""
for _, f in ipairs(FRAMES) do
    local t = rawget(f, "_text")
    if type(t) == "string" and t:find(" fps", 1, true) then LAT = f end
end
""")
check("the frame rate is right-aligned in its box",
      rt.eval("LAT and rawget(LAT, '_justify')") == "RIGHT", str(rt.eval("LAT and rawget(LAT, '_justify')")))
rt.execute('NS.OpenPanel("osd")')
check("the OSD page has the clock settings",
      rt.eval('SHOWN("24-hour")') is True
      and rt.eval('SHOWN("Alarm (click it to set)")') is True)

print("\nOSD dividers and the alarm's message")
rt, g = fresh()
rt.execute(CLOCK)
rt.execute('CVARS_T.timeMgrAlarmMessage = "Raid time"')
rt.execute("BOOT() NS.SetMany({ osdClock = true, osdAlarm = true }) NS.RefreshOSD() DRIVER_TICK()")
line = rt.eval("NS.OSDLine()") or ""
check("the alarm shows its message after its time", "07:30  Raid time" in line, line)
rt.execute('NS.AddOSDDivider() NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("a divider added at the end is not drawn with nothing after it", "   |   " not in line, line)
for _ in range(15):
    rt.execute('NS.MoveOSDItem("|1", -1)')
rt.execute("NS.RefreshOSD() DRIVER_TICK()")
line = rt.eval("NS.OSDLine()") or ""
check("moved between two items, it is drawn between them",
      line.find("INV_Misc_Bag_08") < line.find("   |   ") < line.find("PocketWatch"), line)
check("drawn as a line almost the height of the background",
      rt.eval("(function() for _, f in ipairs(FRAMES) do if rawget(f, '_w') == 1 and rawget(f, '_shown') then return rawget(f, '_h') end end end)()")
      == rt.eval("rawget(ChairPlusOSD, '_h')") - 4)
check("and saved in the order as a |", "|" in g.NS.Get("osdOrder").split(","), g.NS.Get("osdOrder"))
rt.execute('NS.AddOSDDivider() NS.MoveOSDItem("|2", -1) NS.RefreshOSD() DRIVER_TICK()')
order = [rt.eval("NS.OSDOrder()")[i].key for i in range(1, len(rt.eval("NS.OSDOrder()")) + 1)]
check("there can be more than one", order.count("|1") == 1 and order.count("|2") == 1, str(order))
rt.execute('NS.RemoveOSDDivider("|2") NS.RemoveOSDDivider("|1") NS.RefreshOSD() DRIVER_TICK()')
check("and they can be taken away", "|" not in g.NS.Get("osdOrder").split(","), g.NS.Get("osdOrder"))
rt.execute("for i = 1, 40 do NS.AddOSDDivider() end")
check("up to thirty", g.NS.Get("osdOrder").split(",").count("|") == 30)
rt.execute('NS.OpenPanel("osd")')
check("the OSD page has an Add divider button", rt.eval('SHOWN_BUTTON("Add divider")') is True)

print("\nThreat warning sound")
rt, g = threat_rt()
rt.execute("""
PLAYED = {}
SUITE_TABLE.ChairAuras = { Sounds = {
    Play = function(self, value) table.insert(PLAYED, value) return true end,
    Label = function(self, value) return "Sound " .. value end,
    Open = function(self, current, channel, callback) PICKED_WITH = callback end,
} }
""")
rt.execute('NS.PlayThreatWarning()')
check("with nothing chosen it is the raid warning", rt.eval("SOUNDS[1]") == 8959)
rt.execute('NS.OpenPanel("threat")')
check("the Threat tab offers the auras' sound list",
      rt.eval('SHOWN_BUTTON("Choose...")') is True
      and rt.eval('SHOWN("Sound: |cffffffffRaid warning|r")') is True)
rt.execute("""
for _, f in ipairs(FRAMES) do
    local l = rawget(f, "labelText")
    if l and rawget(l, "_text") == "Choose..." then rawget(f, "_scripts").OnClick(f) end
end
PICKED_WITH("12345")
""")
check("picking one saves it", g.NS.Get("threatWarnSoundID") == "12345")
check("and shows its name", rt.eval('SHOWN("Sound: |cffffffffSound 12345|r")') is True)
rt.execute('NS.PlayThreatWarning()')
check("the warning then plays it", rt.eval("PLAYED[1]") == "12345")
rt.execute("""
SUITE_TABLE.ChairAuras.Sounds.Play = function(self, value) table.insert(PLAYED, value) return true, 77 end
STOPPED = nil
function StopSound(handle) STOPPED = handle end
NS.PlayThreatWarning()
for _, f in ipairs(FRAMES) do
    local l = rawget(f, "labelText")
    if l and rawget(l, "_text") == "Stop" and rawget(f, "_shown") then rawget(f, "_scripts").OnClick(f) end
end
""")
check("Stop cuts a long one off", rt.eval("STOPPED") == 77, str(rt.eval("STOPPED")))

print("\nNothing of the menu shows under a hosted page")
rt, g = fresh()
rt.execute("BOOT()")
rt.execute("""
FAKE = MakeMock()
rawset(FAKE, "IsMovable", function() return true end)
rawset(FAKE, "GetWidth", function() return 400 end)
rawset(FAKE, "GetHeight", function() return 300 end)
PART = { key = "chairfake", title = "ChairFake", Window = function() return FAKE end,
         Show = function() FAKE:Show() end }
NS.OpenPanel("quests") NS.OpenPage(PART)
""")
check("the Plus page's options are hidden while another part's page is up",
      rt.eval('SHOWN("Automate quests")') is False and rt.eval('SHOWN_BUTTON("Import")') is False)
rt.execute("NS.ClosePage()")
check("and come back with Back", rt.eval('SHOWN("Automate quests")') is True)

print("\nOSD items dragged into order")
rt, g = fresh()
rt.execute("""
BOOT() NS.OpenPanel("osd")
rawset(NS.osdItemRows.host, "GetTop", function() return 800 end)
rawset(NS.osdItemRows.host, "GetEffectiveScale", function() return 1 end)
function DRAG(key, index)
    local rows = NS.osdItemRows
    local handle = rows[key].handle
    CURSOR_Y = 800 + rows.top - (index - 1) * 24
    GetCursorPosition = function() return 100, CURSOR_Y end
    handle._scripts.OnDragStart(handle)
    handle._scripts.OnUpdate(handle)
    handle._scripts.OnDragStop(handle)
end
""")
rt.execute('DRAG("coords", 1)')
check("dragging a row to the top puts it first", g.NS.Get("osdOrder").startswith("coords,"),
      g.NS.Get("osdOrder"))
rt.execute('DRAG("coords", 4)')
order = g.NS.Get("osdOrder").split(",")
check("and dragging it down puts it where it was dropped", order.index("coords") == 2, str(order))
check("the drop marker hides again afterwards",
      rt.eval("NS.osdItemRows.marker:IsShown()") is False)
before = rt.eval("NS.osdItemRows.maxScroll")
check("more rows than fit scroll, with the bar showing",
      before > 0 and rt.eval("NS.osdItemRows.bar:IsShown()") is True, str(before))
rt.execute("for _ = 1, 6 do NS.AddOSDDivider() end NS.OpenPanel('osd')")
check("dividers lengthen the scroll instead of growing the window",
      rt.eval("NS.osdItemRows.maxScroll") == before + 6 * 24,
      str(rt.eval("NS.osdItemRows.maxScroll")))
rt.execute("for _ = 1, 24 do NS.AddOSDDivider() end NS.OpenPanel('osd')")
check("thirty dividers are allowed", rt.eval("(NS.AddOSDDivider())") is False
      and sum(1 for k in g.NS.Get("osdOrder").split(",") if k == "|") == 30, g.NS.Get("osdOrder"))
check("and with thirty the add button grays out",
      rt.eval("NS.osdItemRows.addButton:IsEnabled()") is not True)
rt.execute("NS.osdItemRows.ScrollTo(10000)")
check("and scrolling stops at the end",
      rt.eval("NS.osdItemRows.offset == NS.osdItemRows.maxScroll") is True)
rt.execute("NS.osdItemRows.ScrollTo(-50)")
check("and at the top", rt.eval("NS.osdItemRows.offset") == 0)

print("\nOSD zone, threat, bag totals and XP")
rt, g = fresh()
rt.execute("""
function GetZoneText() return "Elwynn Forest" end
function GetSubZoneText() return "Goldshire" end
function UnitXP() return 1047 end
function UnitXPMax() return 10000 end
function GetXPExhaustion() return 2500 end
THREAT_PCT, TANKING, HAS_TARGET = 85, false, true
function UnitExists(u) if u == "target" then return HAS_TARGET end return true end
function UnitDetailedThreatSituation() return TANKING, 1, THREAT_PCT end
BAGS[0] = { size = 16, family = 0, items = { [1] = { itemID = 1 } } }
BAGS[1] = { size = 10, family = 0, items = {} }
BOOT() NS.SetMany({ osdZone = true, osdThreat = true, osdXP = true }) NS.RefreshOSD() DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()") or ""
check("the zone shows with its subzone", "Elwynn Forest: Goldshire" in line, line)
check("XP shows to the hundredth", "10.47%" in line and "+25.00%" in line, line)
rt.execute('NS.Set("osdXPMode", "num") NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("or as XP out of the level's total", "1047/10000" in line and "+2500" in line
      and "10.47%" not in line, line)
rt.execute('NS.Set("osdXPMode", "both") NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("or both", "1047/10000 (10.47%)" in line and "+2500 (+25.00%)" in line, line)
rt.execute('NS.OpenPanel("osd")')
check("chosen on the OSD page", rt.eval('SHOWN("XP as: |cffffffffboth|r")') is True)
rt.execute('NS.Set("osdXPMode", "pct") NS.RefreshOSD() DRIVER_TICK()')
check("threat past 80% is orange", "|cffff8c00Threat 85%|r" in line, line)
rt.execute("THREAT_PCT = 40 NS.RefreshOSD() DRIVER_TICK()")
check("and uncolored while comfortable", "Threat 40%" in (rt.eval("NS.OSDLine()") or "")
      and "|cff" not in (rt.eval("NS.OSDLine()") or "").split("Threat 40%")[0][-12:])
rt.execute("TANKING = true NS.RefreshOSD() DRIVER_TICK()")
check("and red once you are tanking", "|cffff2626Threat 40%|r" in (rt.eval("NS.OSDLine()") or ""),
      rt.eval("NS.OSDLine()"))
rt.execute("HAS_TARGET = false NS.RefreshOSD() DRIVER_TICK()")
check("with no target it is left out", "Threat" not in (rt.eval("NS.OSDLine()") or ""))
line = rt.eval("NS.OSDLine()") or ""
check("bag space is free slots by default", re.search(r"INV_Misc_Bag_08[^|]*\|t 25(\s|$)", line) is not None, line)
rt.execute('NS.Set("osdBagsTotal", true) NS.RefreshOSD() DRIVER_TICK()')
line = rt.eval("NS.OSDLine()") or ""
check("or free/total with the toggle on", "|t 25/26" in line, line)

print("\nOSD polish: level cap, zone changes, widths, help text")
rt, g = fresh()
rt.execute("""
ZONE_NOW = "Elwynn Forest"
function GetZoneText() return ZONE_NOW end
function GetSubZoneText() return "" end
function UnitXP() return 0 end
function UnitXPMax() return 12345 end
function GetMaxPlayerLevel() return 60 end
LEVEL = 60
function UnitLevel() return LEVEL end
BOOT() NS.SetMany({ osdZone = true, osdXP = true }) NS.RefreshOSD() DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()") or ""
check("at the level cap the XP item is left out, not shown at 0.00%", "0.00%" not in line, line)
rt.execute('ZONE_NOW = "Westfall" FireEvent("ZONE_CHANGED_NEW_AREA") DRIVER_TICK()')
check("the zone name follows a zone change on its own",
      "Westfall" in (rt.eval("NS.OSDLine()") or ""), rt.eval("NS.OSDLine()"))

# A long name reserves room; once it is gone for a while the room is given back.
rt.execute('STRING_WIDTH = function(text) return #tostring(text or "") * 6 end')
rt.execute('ZONE_NOW = "The Very Long Name Of A Subzone Somewhere" FireEvent("ZONE_CHANGED") DRIVER_TICK()')
wide = rt.eval("NS.OSDReserved and NS.OSDReserved('zone')")
rt.execute('ZONE_NOW = "Goldshire" FireEvent("ZONE_CHANGED") DRIVER_TICK()')
still = rt.eval("NS.OSDReserved and NS.OSDReserved('zone')")
rt.execute('NOW = NOW + 11 FireEvent("ZONE_CHANGED") DRIVER_TICK()')
after = rt.eval("NS.OSDReserved and NS.OSDReserved('zone')")
check("a wide name keeps its room for a moment, then gives it back",
      wide and still == wide and after < wide, (wide, still, after))

rt.execute('PRINTED = {} SlashCmdList["CHAIRPLUS"]("help")')
helptext = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("help text escapes its separators, so no color code eats a letter",
      "|reset" not in helptext.replace("||", "") and "on||off||toggle" in helptext, helptext[:300])

print("\nOSD: watched reputation and repair cost")
rt, g = fresh()
rt.execute("""
WATCHED = { "Stormwind", 5, 3000, 9000, 6000 }
function GetWatchedFactionInfo() if WATCHED then return unpack(WATCHED) end end
FACTION_BAR_COLORS = { [5] = { r = 0, g = 0.6, b = 0.1 } }
BOOT() NS.SetMany({ osdRep = true }) NS.RefreshOSD() DRIVER_TICK()
""")
line = rt.eval("NS.OSDLine()") or ""
check("the watched faction shows, how far through its standing", "Stormwind" in line and "50%" in line, line)
rt.execute("WATCHED = nil NS.RefreshOSD() DRIVER_TICK()")
check("and nothing when no faction is watched", "Stormwind" not in (rt.eval("NS.OSDLine()") or ""))

rt.execute("""
function GetRepairAllCost() return 2500, true end
FireEvent("MERCHANT_SHOW")
""")
check("a merchant's repair quote is remembered", rt.eval("(NS.RepairCost())") == 2500)
check("and marked as a quote", rt.eval("select(2, NS.RepairCost())") is True)
rt.execute("""
C_TooltipInfo = { GetInventoryItem = function(unit, slot)
    if slot == 1 then return { repairCost = 120 } end
    if slot == 5 then return { repairCost = 80 } end
    return {}
end }
""")
check("an exact cost from the items wins over the quote",
      rt.eval("(NS.RepairCost())") == 200 and rt.eval("select(2, NS.RepairCost())") is False)

print("\nOSD layout: wrapping, opacity, right-click")
rt, g = fresh()
rt.execute("""
STRING_WIDTH = function(text) return 100 end
function GetZoneText() return "Elwynn Forest" end
function GetSubZoneText() return "" end
BOOT() NS.SetMany({ osdMoney = true, osdZone = true, osdClock = true, osdBackground = true })
NS.RefreshOSD() DRIVER_TICK()
""")
check("with no wrap width, one line", rt.eval("NS.osdRows") == 1)
rt.execute('NS.Set("osdMaxWidth", 250) NS.RefreshOSD() DRIVER_TICK()')
check("past the wrap width, items start another line", rt.eval("NS.osdRows") >= 2, rt.eval("NS.osdRows"))
check("and the display is no wider than the wrap width",
      rt.eval("rawget(ChairPlusOSD, '_w')") <= 250, rt.eval("rawget(ChairPlusOSD, '_w')"))

rt.execute("""
ChairPlusDB.sessions = ChairPlusDB.sessions or {}
ChairPlusDB.sessions["Player-1-alt"] = { name = "Alt-Testrealm", lastMoney = 50000 }
PRINTED = {}
local b = NS.OSDHotspot("money") b._scripts.OnClick(b, "RightButton")
""")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("right-clicking money lists every character's gold", "Alt-Testrealm" in said and "Total" in said, said[-300:])
rt.execute("""
ChairPlusDB.sessions["Player-1-main"] = { name = "Main-Testrealm", lastMoney = 120000 }
MONEY_TIP = {}
local tip = {
    AddLine = function(self, text) table.insert(MONEY_TIP, tostring(text)) end,
    AddDoubleLine = function(self, a, b) table.insert(MONEY_TIP, tostring(a) .. "=" .. tostring(b)) end,
}
for _, it in ipairs(NS.OSD_ITEMS) do if it.key == "money" then it.tooltip(tip) end end
""")
tip = [str(v) for v in rt.eval("MONEY_TIP").values()]
names = [l.split("=")[0] for l in tip if "=" in l]
check("hovering money lists each character, richest first",
      "Main-Testrealm" in names and "Alt-Testrealm" in names
      and names.index("Main-Testrealm") < names.index("Alt-Testrealm"), tip)
check("and the account total", any(l.startswith("Account total=") for l in tip), tip)
before = rt.eval('NS.Get("osdClock24")')
rt.execute('for _, it in ipairs(NS.OSD_ITEMS) do if it.key == "clock" then it.rightClick() end end')
check("right-clicking the clock switches 12 and 24 hour", rt.eval('NS.Get("osdClock24")') != before)
rt.execute('OPENED_ALARM = false NS.OpenAlarm = function() OPENED_ALARM = true end '
           'for _, it in ipairs(NS.OSD_ITEMS) do if it.key == "clock" then it.click() end end')
check("while a left-click still opens the clock", rt.eval("OPENED_ALARM") is True)

print("\nTooltip extras, mail and small automations, nameplate colors")
rt, g = fresh(stock=True)
rt.execute("""
POST = {}
Enum.TooltipDataType = { Item = 0, Spell = 1, UnitAura = 7 }
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) POST[kind] = fn end }
TIP_LINES = {}
GameTooltip = GameTooltip or MakeMock()
rawset(GameTooltip, "AddDoubleLine", function(self, a, b) table.insert(TIP_LINES, tostring(a) .. "=" .. tostring(b)) end)
rawset(GameTooltip, "AddLine", function(self, a) table.insert(TIP_LINES, tostring(a)) end)
function GetItemInfo(id)
    if id == 2589 then return "Linen Cloth", nil, 1, nil, nil, nil, nil, 20, nil, nil, 13 end
end
C_Item.GetItemInfo = GetItemInfo
BOOT() NS.SetMany({ tooltipExtras = true, tooltipIDs = true })
POST[0](GameTooltip, { id = 2589 })
POST[1](GameTooltip, { id = 774 })
""")
lines = [str(v) for v in rt.eval("TIP_LINES").values()]
check("an item's tooltip gets what it sells for", any(l.startswith("Sells for=") for l in lines), lines)
check("and its ID, and a spell's", "Item ID=2589" in lines and "Spell ID=774" in lines, lines)
rt.execute('TIP_LINES = {} NS.Set("tooltipExtras", false) POST[0](GameTooltip, { id = 2589 })')
check("switched off, nothing is added", len(list(rt.eval("TIP_LINES").values())) == 0)

rt.execute("""
RELEASED, STOPPED, DISMOUNTED, STOOD = 0, 0, 0, 0
function IsInInstance() return true, "pvp" end
function HasSoulstone() return nil end
function RepopMe() RELEASED = RELEASED + 1 end
function StopCinematic() STOPPED = STOPPED + 1 end
function Dismount() DISMOUNTED = DISMOUNTED + 1 end
function DoEmote(e) if e == "STAND" then STOOD = STOOD + 1 end end
function InCombatLockdown() return false end
ERR_ATTACK_MOUNTED = "You are mounted."
SPELL_FAILED_NOT_STANDING = "You must be standing to do that"
NS.SetMany({ autoReleaseBG = true, skipCinematics = true, autoDismount = true })
FireEvent("PLAYER_DEAD") FireEvent("CINEMATIC_START")
FireEvent("UI_ERROR_MESSAGE", 1, "You are mounted.")
FireEvent("UI_ERROR_MESSAGE", 1, "You must be standing to do that")
""")
check("dying in a battleground releases", rt.eval("RELEASED") == 1)
check("a cinematic is skipped", rt.eval("STOPPED") == 1)
check("'You are mounted' dismounts, 'must be standing' stands",
      rt.eval("DISMOUNTED") == 1 and rt.eval("STOOD") == 1)
rt.execute('function HasSoulstone() return "Use Soulstone" end FireEvent("PLAYER_DEAD")')
check("but not with a soulstone to come back where you fell", rt.eval("RELEASED") == 1)

rt.execute("""
BAR = MakeMock()
BAR_COLOR = { 0.8, 0, 0 }
rawset(BAR, "SetStatusBarColor", function(self, r, g, b) BAR_COLOR = { r, g, b } end)
rawset(BAR, "GetStatusBarColor", function() return BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3] end)
C_NamePlate = { GetNamePlateForUnit = function(unit) return { UnitFrame = { healthBar = BAR } } end }
STATUS, ON_ME, TARGET_ROLE, GROUPED = 3, false, "DAMAGER", true
function UnitAffectingCombat(u) return true end
function UnitThreatSituation(me, u) return STATUS end
function UnitIsFriend() return false end
function UnitExists(u) return true end
function UnitIsUnit(a, b) return ON_ME end
function UnitInParty(u) return GROUPED end
MY_ROLE = "TANK"
function UnitGroupRolesAssigned(u) if u == "player" then return MY_ROLE end return TARGET_ROLE end
NS.Set("nameplateThreat", true)
FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
""")
def colour():
    return tuple(round(rt.eval("BAR_COLOR[%d]" % i), 2) for i in (1, 2, 3))
check("I have aggro: my color", colour() == (0.2, 0.8, 0.2), colour())
rt.execute('STATUS = 2 FireEvent("UNIT_THREAT_LIST_UPDATE", "nameplate1")')
check("aggro changing: its color", colour() == (1.0, 0.6, 0.0), colour())
rt.execute('STATUS = 0 FireEvent("UNIT_THREAT_LIST_UPDATE", "nameplate1")')
check("a non-tank has aggro: its color", colour() == (1.0, 0.1, 0.1), colour())
rt.execute('TARGET_ROLE = "TANK" FireEvent("UNIT_THREAT_LIST_UPDATE", "nameplate1")')
check("another tank has it: its color", colour() == (0.25, 0.5, 1.0), colour())
rt.execute('GROUPED = false FireEvent("UNIT_THREAT_LIST_UPDATE", "nameplate1")')
check("on someone outside the group, the plate's own color comes back", colour() == (0.8, 0.0, 0.0), colour())
rt.execute('GROUPED = true STATUS = 3 NS.Set("npMine", false) FireEvent("UNIT_THREAT_LIST_UPDATE", "nameplate1")')
check("a state switched off is left alone", colour() == (0.8, 0.0, 0.0), colour())
rt.execute('NS.Set("npMine", true) MY_ROLE = "DAMAGER" FireEvent("UNIT_THREAT_LIST_UPDATE", "nameplate1")')
check("not the tank: the plate keeps its normal color", colour() == (0.8, 0.0, 0.0), colour())
rt.execute('MY_ROLE = "TANK" FireEvent("PLAYER_ROLES_ASSIGNED")')
check("made the tank, the colors come on", colour() == (0.2, 0.8, 0.2), colour())
rt.execute('MY_ROLE = "HEALER" FireEvent("PLAYER_ROLES_ASSIGNED")')
check("and go again, back to normal, when the role changes", colour() == (0.8, 0.0, 0.0), colour())
rt.execute('MY_ROLE = "NONE" C_LFGList = { GetRoles = function() return { tank = true } end } FireEvent("LFG_ROLE_UPDATE")')
check("solo, the tank role ticked in the group finder counts", colour() == (0.2, 0.8, 0.2), colour())

print("\nSettings backup")
rt, g = fresh()
for lib in ("Libs/LibStub/LibStub.lua", "Libs/LibDeflate/LibDeflate.lua", "Libs/LibSerialize/LibSerialize.lua"):
    source = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", lib), encoding="utf-8").read()
    rt.execute("local f = assert(loadstring(...)) f()", source)
rt.execute('BOOT() NS.Set("osdFontSize", 19) NS.Set("sellJunk", true)')
exported = rt.eval("(NS.ExportSettings(false))")
check("export gives one Chaircraft string", isinstance(exported, str) and exported.startswith("!CC:1!"),
      str(exported)[:40])
rt.execute('NS.Set("osdFontSize", 12) NS.Set("sellJunk", false)')
rt.globals().BACKUP = exported
rt.execute("COPIED, DATA = NS.ImportSettings(BACKUP, false)")
check("and importing it puts the settings back",
      g.NS.Get("osdFontSize") == 19 and g.NS.IsEnabled("sellJunk") is True,
      (g.NS.Get("osdFontSize"), g.NS.IsEnabled("sellJunk")))
check("leaving no temporary profile behind",
      rt.eval('ChairPlusDB.profiles["import:backup"]') is None)
check("a string that is not one is refused, not an error",
      rt.eval("select(2, NS.PeekSettings('hello'))") == "that is not a ChairCraft settings string")

# Auras from a backup string are someone else's as far as we know: their code
# waits for approval, whatever the string says, and they land in the table
# ChairAuras already holds.
rt.execute("""
HELD = { auras = {} }
ChairAurasDB = { profiles = { account = HELD } }
SUITE_TABLE.ChairAuras = {
    NormalizeTriggers = function(aura) end,
    Custom = { CodeOf = function(self, aura)
        return (aura.code and { { "trigger", aura.code } }) or {}
    end },
}
""")
rt.execute("""
local serialize = LibStub("LibSerialize")
local deflate = LibStub("LibDeflate")
local data = { v = 1, who = "Other", plus = { settings = {}, movers = {} },
               auras = { auras = { { id = 1, code = "return true" }, { id = 2 } } } }
AURA_BACKUP = "!CC:1!" .. deflate:EncodeForPrint(deflate:CompressDeflate(serialize:Serialize(data)))
NS.ImportSettings(AURA_BACKUP, true)
""")
check("a backup's aura with code comes in waiting for approval",
      rt.eval("ChairAurasDB.profiles.account.auras[1].untrusted") is True)
check("one without code comes in as it is", rt.eval("ChairAurasDB.profiles.account.auras[2].untrusted") is None)
check("into the table ChairAuras already holds", rt.eval("ChairAurasDB.profiles.account == HELD") is True)
rt.execute("SUITE_TABLE.ChairAuras = nil NS.ImportSettings(AURA_BACKUP, true)")
check("with ChairAuras missing, every aura waits",
      rt.eval("ChairAurasDB.profiles.account.auras[1].untrusted") is True
      and rt.eval("ChairAurasDB.profiles.account.auras[2].untrusted") is True)

print("\nArrow custom color")
rt, g = arrow_rt('PIN = { map = 1, x = 0.5, y = 0.4 }')
rt.execute("""
for _, f in ipairs(FRAMES) do
    if rawget(f, "_w") == 120 and rawget(f, "_h") == 120 then ARROW_TEX = f end
end
TINT = nil
rawset(ARROW_TEX, "SetVertexColor", function(self, r, g, b) TINT = { r, g, b } end)
FACING = math.pi DRIVER_TICK()
""")
check("by default it is colored by direction (red behind you)", rt.eval("TINT[1]") == 1 and rt.eval("TINT[2]") < 0.5)
rt.execute('NS.SetMany({ arrowCustomColor = true, arrowColorR = 0.1, arrowColorG = 0.2, arrowColorB = 0.9 }) DRIVER_TICK()')
check("a custom color replaces it", abs(rt.eval("TINT[3]") - 0.9) < 0.001 and abs(rt.eval("TINT[1]") - 0.1) < 0.001)
rt.execute('NS.OpenPanel("arrow")')
check("the Arrow page offers it", rt.eval('SHOWN("Custom color")') is True)
check("and grays out color by direction while it is on",
      rt.eval("(function() for _, f in ipairs(FRAMES) do if rawget(f, '_text') == 'Color by direction' then return f end end end)()") is not None)
rt.execute("""
PICKER = MakeMock()
ColorPickerFrame = PICKER
rawset(PICKER, "SetupColorPickerAndShow", function(self, info) PICKER_INFO = info end)
rawset(PICKER, "GetColorRGB", function() return 0.5, 0.25, 0.75 end)
for _, f in ipairs(FRAMES) do
    if rawget(f, "fill") and rawget(f, "_scripts") and rawget(f, "settingKey") == "arrowCustomColor" then
        rawget(f, "_scripts").OnClick(f)
    end
end
PICKER_INFO.swatchFunc()
""")
check("the swatch opens the color picker and takes its color",
      abs(g.NS.Get("arrowColorG") - 0.25) < 0.001 and g.NS.IsEnabled("arrowCustomColor") is True)
rt.execute("PICKER_INFO.cancelFunc()")
check("and Cancel puts the old one back", abs(g.NS.Get("arrowColorG") - 0.2) < 0.001)

rt, g = fresh()
rt.execute('BOOT() LFGBrowseFrame = MakeMock() C_LFGList = { Search = function() end, GetSearchResults = function() return { 1, 2, 3 } end }')
rt.execute('PRINTED = {} SlashCmdList["CHAIRPLUS"]("lfg")')
probe = printed_text(rt)
check("/chair plus lfg reports the group finder it finds",
      "LFGBrowseFrame" in probe and "current search results: 3" in probe and "Search" in probe, probe[-400:])

print("\nChairTracker in the OSD")
rt, g = fresh()
rt.execute("""
DOCKED, SHOWN_DROP = "never", 0
WOWFTrackerNS = {
    Dock = function(frame) DOCKED = frame end,
    DockShow = function() SHOWN_DROP = SHOWN_DROP + 1 end,
}
BOOT() NS.Set("osdTracker", true) NS.RefreshOSD() DRIVER_TICK()
""")
check("the tracker item shows on the line", "Tracker" in (rt.eval("NS.OSDLine()") or ""))
check("and docks the tracker to it, which shuts the standalone window",
      rt.eval("type(DOCKED) == 'table'") is True)
rt.execute("DOCKED._scripts.OnEnter(DOCKED)")
check("hovering the item drops the tracker down", rt.eval("SHOWN_DROP") == 1)

# Putting the tracker on the display turns its auto-hide on, at two seconds,
# unless it is on already -- once, so turning it off afterwards sticks.
rt, g = fresh()
rt.execute("""
WOWFTrackerDB = { settings = { autoHide = false, showTime = 5 } }
WOWFTrackerNS = { Dock = function() end, DockShow = function() end }
BOOT() NS.Set("osd", true) NS.Set("osdTracker", true)
""")
check("on the display, the tracker's auto-hide comes on at two seconds",
      rt.eval("WOWFTrackerDB.settings.autoHide") is True and rt.eval("WOWFTrackerDB.settings.showTime") == 2)
rt.execute('WOWFTrackerDB.settings.autoHide = false NS.Set("osdFontSize", 15)')
check("turning auto-hide off afterwards is left alone", rt.eval("WOWFTrackerDB.settings.autoHide") is False)
rt.execute('NS.Set("osdTracker", false) NS.Set("osdTracker", true)')
check("taking it off the display and back turns it on again", rt.eval("WOWFTrackerDB.settings.autoHide") is True)
rt, g = fresh()
rt.execute("""
WOWFTrackerDB = { settings = { autoHide = true, showTime = 7 } }
WOWFTrackerNS = { Dock = function() end, DockShow = function() end }
BOOT() NS.Set("osd", true) NS.Set("osdTracker", true)
""")
check("already on, its own delay stands", rt.eval("WOWFTrackerDB.settings.showTime") == 7)
rt.execute('NS.Set("osdTracker", false) NS.RefreshOSD() DRIVER_TICK()')
check("switching the item off gives the tracker its window back", rt.eval("DOCKED") is None)
rt.execute('DOCKED = "untouched" NS.RefreshOSD() DRIVER_TICK()')
check("and a tracker it did not dock is left alone", rt.eval("DOCKED") == "untouched")

print("\nGroup finder player filters")
# The Browse frame the way this client's is built (from "/chair plus lfg" in
# game): UpdateResultList fetches a fresh results table, then UpdateResults
# draws the list from it.
LFG_SETUP = """
function hooksecurefunc(obj, name, fn)
    if type(obj) == "string" then obj, name, fn = _G, obj, name end
    local original = obj[name]
    obj[name] = function(...)
        local a, b, c = original(...)
        fn(...)
        return a, b, c
    end
end
LISTINGS = {
    [1] = { numMembers = 1, player = { classFilename = "PRIEST", level = 30, isHealer = true } },
    [2] = { numMembers = 1, player = { classFilename = "WARRIOR", level = 42, isTank = true, isDamage = true } },
    [3] = { numMembers = 1, player = { classFilename = "MAGE", level = 18, isDamage = true } },
    [4] = { numMembers = 4, player = { classFilename = "ROGUE", level = 40, isDamage = true } },
}
SEARCH = { 1, 2, 3, 4 }
C_LFGList = {
    GetSearchResults = function() return { unpack(SEARCH) } end,
    GetSearchResultInfo = function(id) local l = LISTINGS[id] return l and { numMembers = l.numMembers } end,
    GetSearchResultPlayerInfo = function(id) local l = LISTINGS[id] return l and l.player end,
}
LFGParentFrame = MakeMock()
LFGBrowseFrame = MakeMock()
LFGBrowseFrame.RefreshButton = MakeMock()
rawset(LFGBrowseFrame.RefreshButton, "GetSize", function() return 32, 32 end)
DRAWN = {}
function LFGBrowseFrame:UpdateResultList()
    self.results = { unpack(SEARCH) }
    self:UpdateResults()
end
function LFGBrowseFrame:UpdateResults()
    DRAWN = {}
    for _, id in ipairs(self.results) do DRAWN[#DRAWN + 1] = id end
end
function SHOWN_IDS() return table.concat(DRAWN, ",") end
"""
rt, g = fresh()
rt.execute(LFG_SETUP)
rt.execute("BOOT() NS.Set('lfgFilters', true) LFGBrowseFrame:UpdateResultList()")
check("with the filters on, the groups are hidden and the players stay",
      rt.eval("SHOWN_IDS()") == "1,2,3", rt.eval("SHOWN_IDS()"))
rt.execute("NS.LFGToggle('lfgClasses', 'PRIEST', true) NS.LFGRefilter()")
check("by class", rt.eval("SHOWN_IDS()") == "1", rt.eval("SHOWN_IDS()"))
rt.execute("NS.LFGToggle('lfgClasses', 'MAGE', true) NS.LFGRefilter()")
check("several classes at once", rt.eval("SHOWN_IDS()") == "1,3", rt.eval("SHOWN_IDS()"))
rt.execute("NS.SetMany({ lfgClasses = '', lfgRoles = 'TANK' }) NS.LFGRefilter()")
check("by role, reading every role a player listed", rt.eval("SHOWN_IDS()") == "2", rt.eval("SHOWN_IDS()"))
rt.execute("NS.SetMany({ lfgRoles = 'DAMAGER' }) NS.LFGRefilter()")
check("a player listed as tank and damage counts as damage too",
      rt.eval("SHOWN_IDS()") == "2,3", rt.eval("SHOWN_IDS()"))
rt.execute("NS.SetMany({ lfgRoles = 'HEALER,TANK' }) NS.LFGRefilter()")
check("several roles at once", rt.eval("SHOWN_IDS()") == "1,2", rt.eval("SHOWN_IDS()"))
rt.execute("""
for _, f in ipairs(FRAMES) do
    local l = rawget(f, "labelText")
    if l and rawget(l, "_text") == "Mage" and rawget(f, "_scripts") then
        rawset(f, "GetChecked", function() return true end)
        rawget(f, "_scripts").OnClick(f)
    end
end
""")
check("ticking a class checkbox adds it", "MAGE" in g.NS.Get("lfgClasses").split(","),
      g.NS.Get("lfgClasses"))
rt.execute("NS.SetMany({ lfgClasses = '', lfgRoles = '', lfgMinLevel = 20, lfgMaxLevel = 40 }) NS.LFGRefilter()")
check("by level range", rt.eval("SHOWN_IDS()") == "1", rt.eval("SHOWN_IDS()"))
rt.execute("NS.SetMany({ lfgMinLevel = 0, lfgMaxLevel = 0, lfgPlayersOnly = false }) NS.LFGRefilter()")
check("with players-only off and nothing ticked, the whole search shows",
      rt.eval("SHOWN_IDS()") == "1,2,3,4", rt.eval("SHOWN_IDS()"))
check("and the count says how many of how many", tuple(rt.eval("{ NS.LFGCounts() }").values()) == (4, 4))
rt.execute("NS.Set('lfgPlayersOnly', true) SEARCH = { 4, 3 } LFGBrowseFrame:UpdateResultList()")
check("a new search is filtered too", rt.eval("SHOWN_IDS()") == "3", rt.eval("SHOWN_IDS()"))
check("the filter panel is attached to the group finder",
      rt.eval("ChairPlusLFGFilters ~= nil and rawget(ChairPlusLFGFilters, '_parent') == LFGBrowseFrame") is True)
check("it starts tucked away", rt.eval("ChairPlusLFGFilters:IsShown()") is False)
check("with a toggle button showing", rt.eval("ChairPlusLFGToggle ~= nil and ChairPlusLFGToggle:IsShown()") is True)
rt.execute("ChairPlusLFGToggle._scripts.OnClick(ChairPlusLFGToggle)")
check("the toggle flies the panel out", rt.eval("ChairPlusLFGFilters:IsShown()") is True)
rt.execute("ChairPlusLFGToggle._scripts.OnClick(ChairPlusLFGToggle)")
check("and tucks it away again", rt.eval("ChairPlusLFGFilters:IsShown()") is False)
check("the filters keep working while it is away", rt.eval("SHOWN_IDS()") == "3", rt.eval("SHOWN_IDS()"))
rt.execute("NS.Set('lfgFilters', false)")
check("switching the filters off gives the whole search back", rt.eval("SHOWN_IDS()") == "4,3",
      rt.eval("SHOWN_IDS()"))
rt.execute("SEARCH = { 1, 4 } LFGBrowseFrame:UpdateResultList()")
check("and later searches are left alone", rt.eval("SHOWN_IDS()") == "1,4", rt.eval("SHOWN_IDS()"))

# Found in game on 2026-09-26: the list showed for a few frames and vanished.
# Nothing ticked must leave every player on screen -- and the list is only
# ever redrawn by Blizzard's own UpdateResults.
rt, g = fresh()
rt.execute(LFG_SETUP)
rt.execute("BOOT() NS.Set('lfgFilters', true) LFGBrowseFrame:UpdateResultList()")
check("nothing ticked: every player stays on screen", rt.eval("SHOWN_IDS()") == "1,2,3",
      rt.eval("SHOWN_IDS()"))

check("there is no auto refresh: a search is protected on this client",
      rt.eval("ChairPlusLFGAutoRefresh == nil and NS.LFGSetAutoRefresh == nil") is True)

rt.execute('PRINTED = {} SlashCmdList["CHAIRPLUS"]("lfg")')
check("/chair plus lfg shows what a player's listing holds",
      "read as: class=PRIEST level=30 grayed=nil roles=HEALER" in printed_text(rt), printed_text(rt)[-300:])
check("and how the last filter pass went",
      "hooked=true, results field=table, last pass read 4, kept 3" in printed_text(rt), printed_text(rt)[-600:])

# The Classic Era finder's own shape: lfgRoles with lower-case keys, "dps"
# rather than "DAMAGER", and assignedRole "NONE" for someone not in a group.
rt, g = fresh()
rt.execute(LFG_SETUP)
rt.execute("""
LISTINGS = {
    [1] = { numMembers = 1, player = { classFilename = "PRIEST", level = 30, assignedRole = "NONE",
            lfgRoles = { tank = false, healer = true, dps = false } } },
    [2] = { numMembers = 1, player = { classFilename = "WARRIOR", level = 42, assignedRole = "NONE",
            lfgRoles = { tank = true, healer = false, dps = true } } },
    [3] = { numMembers = 1, player = { classFilename = "MAGE", level = 18, assignedRole = "NONE",
            lfgRoles = { tank = false, healer = false, dps = true } } },
}
SEARCH = { 1, 2, 3 }
BOOT() NS.Set('lfgFilters', true)
""")
rt.execute("NS.SetMany({ lfgRoles = 'TANK' }) LFGBrowseFrame:UpdateResultList()")
check("lfgRoles is read: tank", rt.eval("SHOWN_IDS()") == "2", rt.eval("SHOWN_IDS()"))
rt.execute("NS.SetMany({ lfgRoles = 'DAMAGER' }) NS.LFGRefilter()")
check("and dps counts as damage", rt.eval("SHOWN_IDS()") == "2,3", rt.eval("SHOWN_IDS()"))
rt.execute("NS.SetMany({ lfgRoles = 'HEALER' }) NS.LFGRefilter()")
check("and an assigned role of NONE is not a role that hides everyone",
      rt.eval("SHOWN_IDS()") == "1", rt.eval("SHOWN_IDS()"))

# Grayed out: delisted, or an application that went nowhere.
rt, g = fresh()
rt.execute(LFG_SETUP)
rt.execute("""
LISTINGS[5] = { numMembers = 3, player = { classFilename = "MAGE", level = 50, isDamage = true } }
LISTINGS[1].delisted = true
APPS = { [3] = "declined", [2] = "applied" }
SEARCH = { 1, 2, 3, 4, 5 }
C_LFGList.GetSearchResultInfo = function(id)
    local l = LISTINGS[id] return l and { numMembers = l.numMembers, isDelisted = l.delisted } end
C_LFGList.GetApplicationInfo = function(id) return id, APPS[id] or "none", false end
LISTINGS[5].delisted = true
BOOT() NS.SetMany({ lfgFilters = true, lfgPlayersOnly = false })
LFGBrowseFrame:UpdateResultList()
""")
check("delisted players and groups and declined applications are always hidden; a pending one stays",
      rt.eval("SHOWN_IDS()") == "2,4", rt.eval("SHOWN_IDS()"))

print()
print("\nOSD session, speed, pet, mail and social")
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
CLOCK_NOW = 100000
time = function() return CLOCK_NOW end
MONEY = 50000
function GetMoney() return MONEY end
function GetUnitSpeed() return SPEED or 0, 7 end
function UnitClass() return "Hunter", "HUNTER" end
function UnitExists(u) return true end
function UnitName(u) if u == "pet" then return "Fang" end return "Me" end
function UnitHealth(u) return 30 end
function UnitHealthMax(u) return 100 end
function GetPetHappiness() return 1, 75, -2 end
MAIL = false
function HasNewMail() return MAIL end
C_FriendList = {
    GetNumFriends = function() return 3 end,
    GetFriendInfoByIndex = function(i) return { name = "F" .. i, connected = i ~= 2, level = 60 } end,
}
function BNGetNumFriends() return 5, 1 end
function IsInGuild() return true end
function GetNumGuildMembers() return 4 end
function GetGuildRosterInfo(i) return "G" .. i .. "-Realm", "", 0, 60, "", "Orgrimmar", "", "", i <= 2 end
BOOT()
SessionEvents = function() for _, f in ipairs(FRAMES) do local s = rawget(f, "_scripts") if s and s.OnEvent then pcall(s.OnEvent, f, "PLAYER_ENTERING_WORLD", true, false) end end end
SessionEvents()
NS.SetMany({ osd = true, osdMoney = false, osdBags = false, osdSession = true, osdSessionGold = true,
             osdSpeed = true, osdPet = true, osdMail = true, osdSocial = true, osdGuild = true })
""")
def line(rt):
    rt.execute("NS.RefreshOSD() DRIVER_TICK()")
    return rt.eval("NS.OSDLine()") or ""
rt.execute("CLOCK_NOW = CLOCK_NOW + 3725 MONEY = 62345")
text = line(rt)
check("session time counts from login", "1:02:05" in text, text)
check("gold this session shows what was made, in green",
      "|cff4cff4c+|r" in text and "UI-GoldIcon:14:14:0:0|t 1" in text and "UI-CopperIcon:14:14:0:0|t 45" in text, text)
rt.execute("MONEY = 40000")
check("and a loss in red", "|cffff3333-|r" in line(rt), line(rt))
rt.execute("NS.Set('osdGPH', true)")
text = line(rt)
check("gold per hour: 7,000 copper lost over a bit more than an hour",
      "|cffff3333-|r" in text and "/hr" in text, text)
rt.execute("NS.ResetGoldPerHour()")
check("clicking it restarts the count, and the first minute shows no rate",
      "-- /hr" in line(rt), line(rt))
rt.execute("CLOCK_NOW = CLOCK_NOW + 1800 MONEY = MONEY + 5000")
check("half an hour and 50 silver later, it reads 1 gold an hour",
      "|cff4cff4c+|r" in line(rt) and "UI-GoldIcon:14:14:0:0|t 1 " in line(rt), line(rt))
check("and restarting it left the session's own total alone",
      "|cffff3333-|r" in line(rt).split("/hr")[1]
      and "UI-SilverIcon:14:14:0:0|t 50" in line(rt).split("/hr")[1], line(rt))
rt.execute("NS.Set('osdGPH', false)")
rt.execute("NS.ResetSessionGold()")
check("clicking it starts the count again", "UI-CopperIcon:14:14:0:0|t 0" in line(rt), line(rt))
check("standing still, the run speed shows dimmed", "|cff999999 100%|r" in line(rt), line(rt))
rt.execute("SPEED = 14")
check("moving, the speed right now", " 200%" in line(rt), line(rt))

# ChairIgnore's item: its portrait icon and nothing else.
rt.execute("""
SUITE_TABLE.ChairIgnore = { ICON = "Interface\\\\FriendsFrame\\\\Battlenet-Portrait",
    Count = function() return 7 end, On = function() return IGNORE_ON end,
    session = { listed = 0, filtered = 0 } }
IGNORE_ON = true
NS.Set('osdIgnore', true)
""")
text = line(rt)
check("the ChairIgnore item is its portrait icon alone, no text",
      "Battlenet-Portrait" in text and "Ignore" not in text and " 7" not in text, text)
text = line(rt)
check("an unhappy hunter pet shows its name and the unhappy face",
      "UI-PetHappiness:14:14:0:0:128:64:48:72:0:23|t Fang" in text, text)
check("and low health in red", "|cffff3333 30%|r" in text, text)
check("no mail, no mail icon", "INV_Letter_15" not in text, text)
rt.execute("MAIL = true")
check("new mail shows the icon", "INV_Letter_15" in line(rt), line(rt))
text = line(rt)
check("friends online count Battle.net ones too", " Friends 3" in text, text)
check("and the guild is an item of its own", " Guild 2" in text and "Friends 3  Guild" not in text, text)
rt.execute("""
OPENED = {}
function ToggleFriendsFrame(tab) OPENED[#OPENED + 1] = "friends " .. tostring(tab) end
function ToggleGuildFrame() OPENED[#OPENED + 1] = "guild" end
local f = NS.OSDHotspot("social") f._scripts.OnClick(f, "LeftButton")
local g = NS.OSDHotspot("guild") g._scripts.OnClick(g, "LeftButton")
ToggleGuildFrame = nil
g._scripts.OnClick(g, "LeftButton")
""")
opened = list(rt.eval("OPENED").values())
check("friends opens the friends list, guild the guild window",
      opened[:2] == ["friends 1", "guild"], str(opened))
check("and on a client without a guild window, the friends window's guild tab",
      opened[2:] == ["friends 3"], str(opened))
rt.execute("function IsInGuild() return false end")
check("outside a guild, no guild item", " Guild " not in line(rt), line(rt))
rt.execute("function IsInGuild() return true end")
rt.execute("function UnitClass() return 'Mage', 'MAGE' end")
check("not a hunter, no pet item", "Fang" not in line(rt), line(rt))
rt.execute("CLOCK_NOW = CLOCK_NOW + 60 SessionEvents()")
check("a login starts a new session", "0:00" in line(rt), line(rt))

print("\nOther addons' feeds on the OSD")
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
securecallfunction = function(f, ...) return f(...) end
for _, file in ipairs({ "Libs/LibStub/LibStub.lua", "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
                        "Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua" }) do
    assert(loadfile(file))()
end
LDB = LibStub("LibDataBroker-1.1")
CLICKED = nil
EARLY = LDB:NewDataObject("Early Bird", { type = "data source", text = "12 errors", icon = "Interface\\Icons\\Bug",
    OnClick = function(_, button) CLICKED = button end,
    OnTooltipShow = function(tip) tip:AddLine("early tip") end })
NS.HookBrokers()
BOOT()
NS.SetMany({ osd = true, osdMoney = false, osdBags = false })
""")
check("a feed published before Chaircraft looked is found",
      rt.eval("#NS.OSDBrokers()") == 1 and rt.eval("NS.OSDBrokers()[1].broker") == "Early Bird")
check("and is off until ticked", "12 errors" not in (rt.eval("NS.OSDLine()") or ""))
rt.execute("NS.SetOSDItemOn(NS.OSDBrokers()[1], true)")
check("ticked, its icon and text are on the line", "Bug:14:14:0:0|t 12 errors" in line(rt), line(rt))
check("its key escapes the space, so the saved order stays whole",
      g.NS.Get("osdBrokers") == "ldb:Early%20Bird", g.NS.Get("osdBrokers"))
rt.execute('EARLY.text = "13 errors"')
check("a change to its text redraws the line", "13 errors" in line(rt), line(rt))
rt.execute("""
LATE = LDB:NewDataObject("LateAddon", { type = "launcher", icon = "Interface\\Icons\\Late",
    OnClick = function(_, button) CLICKED = "late " .. button end })
""")
check("a feed created later is picked up too", rt.eval("#NS.OSDBrokers()") == 2)
rt.execute("NS.SetOSDItemOn(NS.OSDBrokers()[2], true)")
check("a launcher shows its icon alone", "Late:14:14:0:0|t" in line(rt) and "LateAddon" not in line(rt), line(rt))
check("both are remembered", g.NS.Get("osdBrokers") == "ldb:Early%20Bird,ldb:LateAddon", g.NS.Get("osdBrokers"))
rt.execute("""
local b = NS.OSDBrokers()[1]
for _, f in ipairs(FRAMES) do
    local s = rawget(f, "_scripts")
    if s and s.OnClick and s.OnEnter and rawget(f, "_shown") then
        s.OnClick(f, "RightButton")
        if CLICKED == "RightButton" then break end
    end
end
""")
check("a click reaches the addon with the mouse button", rt.eval("CLICKED") == "RightButton")
check("Chaircraft's own launcher is not offered back to itself",
      all(rt.eval("NS.OSDBrokers()[%d].broker" % i) != "Chaircraft" for i in (1, 2)))
rt.execute("NS.OpenPanel('osd')")
check("the OSD page has a row for each feed",
      rt.eval('NS.osdItemRows["ldb:Early%20Bird"] ~= nil') is True
      and rt.eval('NS.osdItemRows["ldb:LateAddon"] ~= nil') is True)
check("ticked on the page as they are on the line",
      rt.eval('NS.osdItemRows["ldb:Early%20Bird"].check:GetChecked()') is True)
rt.execute("""
DBI = LibStub:NewLibrary("LibDBIcon-1.0", 1)
DBI.objects = {}
BUTTON_EARLY = CreateFrame("Button", "LibDBIcon10_EarlyBird", UIParent) BUTTON_EARLY:Show()
BUTTON_EARLY.dataObject = EARLY
DBI.objects["EarlyBirdIcon"] = BUTTON_EARLY
BUTTON_LATE = CreateFrame("Button", "LibDBIcon10_LateAddon", UIParent) BUTTON_LATE:Show()
BUTTON_LATE.dataObject = LATE
DBI.objects["LateAddon"] = BUTTON_LATE
ChairfacesCasinoMinimapButton = CreateFrame("Button", "ChairfacesCasinoMinimapButton", UIParent)
ChairfacesCasinoMinimapButton:Show()
NS.ApplyMinimapHiding()
""")
check("off by default, minimap buttons are left alone",
      rt.eval("BUTTON_EARLY:IsShown() and BUTTON_LATE:IsShown()") is True)
rt.execute("NS.Set('osdHideMinimap', true)")
check("on, an addon on the display loses its minimap button, matched by its data object",
      rt.eval("BUTTON_EARLY:IsShown()") is False and rt.eval("BUTTON_LATE:IsShown()") is False)
rt.execute("NS.Set('osdCasino', true)")
check("the casino's is never hidden, even with its item on the display",
      rt.eval("ChairfacesCasinoMinimapButton:IsShown()") is True)
rt.execute("NS.SetOSDItemOn(NS.OSDBrokers()[2], false)")
check("taking an addon off the display brings its button back",
      rt.eval("BUTTON_LATE:IsShown()") is True and rt.eval("BUTTON_EARLY:IsShown()") is False)
rt.execute("NS.Set('osdHideMinimap', false)")
check("and unticking the setting brings them all back",
      rt.eval("BUTTON_EARLY:IsShown()") is True)
rt.execute("BUTTON_LATE:Hide() NS.Set('osdHideMinimap', true) NS.Set('osdHideMinimap', false)")
check("a button its addon had hidden stays hidden", rt.eval("BUTTON_LATE:IsShown()") is False)
rt.execute("NS.SetOSDItemOn(NS.OSDBrokers()[1], false)")
check("and unticking one drops it", "errors" not in line(rt) and g.NS.Get("osdBrokers") == "", line(rt))


print("\nInvite on keyword")
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
INVITED, CONVERTED, GROUP, LEADER, RAID = {}, false, 0, true, false
C_PartyInfo = {
    InviteUnit = function(name) INVITED[#INVITED + 1] = name end,
    ConvertToRaid = function() CONVERTED = true RAID = true end,
}
function GetNumGroupMembers() return GROUP end
function UnitIsGroupLeader() return LEADER end
function UnitIsGroupAssistant() return false end
function IsInRaid() return RAID end
function UnitInParty() return false end
function UnitInRaid() return false end
function UnitName() return "Me" end
C_BattleNet = { GetAccountInfoByID = function(id)
    return { gameAccountInfo = { isOnline = true, characterName = "Pal", realmName = "Faerlina" } } end }
BOOT()
NS.Set("keywordInvite", true)
function CHAT(event, message, sender, ...)
    for _, f in ipairs(FRAMES) do
        local s = rawget(f, "_scripts")
        local events = rawget(f, "_events")
        if s and s.OnEvent and events and events[event] then s.OnEvent(f, event, message, sender, ...) end
    end
end
""")
def invited(rt):
    return list((rt.eval("INVITED") or {}).values())
check("the shipped keywords are inv and invite",
      list(rt.eval("NS.InviteKeywords()").values()) == ["inv", "invite"])
rt.execute('CHAT("CHAT_MSG_WHISPER", "inv", "Alice-Realm")')
check("a whispered keyword invites the sender", invited(rt) == ["Alice-Realm"], str(invited(rt)))
rt.execute('CHAT("CHAT_MSG_WHISPER", "inv", "Alice-Realm")')
check("asking again straight away is not a second invite", invited(rt) == ["Alice-Realm"], str(invited(rt)))
rt.execute('CHAT("CHAT_MSG_WHISPER", "INV!", "Bob")')
check("case and a trailing ! do not matter", invited(rt)[-1] == "Bob", str(invited(rt)))
rt.execute('CHAT("CHAT_MSG_WHISPER", "can I get an inv", "Cat")')
check("with whole-message matching, a keyword inside a sentence is not enough",
      "Cat" not in invited(rt), str(invited(rt)))
rt.execute('NS.Set("keywordInviteExact", false) CHAT("CHAT_MSG_WHISPER", "can I get an inv please", "Cat")')
check("without it, a keyword anywhere as its own word is", invited(rt)[-1] == "Cat", str(invited(rt)))
rt.execute('CHAT("CHAT_MSG_WHISPER", "investigate this", "Dan")')
check("but not a keyword that is only part of a word", "Dan" not in invited(rt), str(invited(rt)))
rt.execute('CHAT("CHAT_MSG_GUILD", "inv", "Eve")')
check("guild chat is off until switched on", "Eve" not in invited(rt), str(invited(rt)))
rt.execute('NS.Set("keywordInviteGuild", true) CHAT("CHAT_MSG_GUILD", "inv", "Eve")')
check("and counts once it is", invited(rt)[-1] == "Eve", str(invited(rt)))
rt.execute('CHAT("CHAT_MSG_BN_WHISPER", "inv", "|Kq1|k", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 77)')
check("a Battle.net whisper invites the character they are playing",
      invited(rt)[-1] == "Pal-Faerlina", str(invited(rt)))
rt.execute('NS.AddInviteKeyword("  Raid Me ") CHAT("CHAT_MSG_WHISPER", "raid me", "Fay")')
check("an added keyword works, trimmed and in lower case", invited(rt)[-1] == "Fay", str(invited(rt)))
check("and cannot be added twice", rt.eval('(NS.AddInviteKeyword("raid me"))') is False)
rt.execute('NS.RemoveInviteKeyword("raid me") CHAT("CHAT_MSG_WHISPER", "raid me", "Gus")')
check("a removed one no longer invites", "Gus" not in invited(rt), str(invited(rt)))
rt.execute('GROUP, LEADER = 3, false CHAT("CHAT_MSG_WHISPER", "inv", "Hal")')
check("not the leader, nobody is invited", "Hal" not in invited(rt), str(invited(rt)))
rt.execute('LEADER, GROUP = true, 5 NS.Set("keywordInviteRaid", false) CHAT("CHAT_MSG_WHISPER", "inv", "Ida")')
check("a full party is not turned into a raid when told not to",
      "Ida" not in invited(rt) and rt.eval("CONVERTED") is False, str(invited(rt)))
rt.execute('NS.Set("keywordInviteRaid", true) CHAT("CHAT_MSG_WHISPER", "inv", "Ida")')
check("and is when allowed, but the invite waits for the raid to land",
      rt.eval("CONVERTED") is True and "Ida" not in invited(rt), str(invited(rt)))
rt.execute("RUN_TIMERS(1)")
check("then the invite goes out", invited(rt)[-1] == "Ida", str(invited(rt)))
rt.execute('NS.Set("keywordInvite", false) CHAT("CHAT_MSG_WHISPER", "inv", "Jo")')
check("switched off, nothing happens", "Jo" not in invited(rt), str(invited(rt)))
rt.execute("NS.ToggleKeywordPanel()")
check("the keyword window opens", rt.eval("ChairPlusKeywordPanel:IsShown()") is True)
check("with the menu, if it was closed", rt.eval("ChairPlusPanel:IsShown()") is True)
check("hanging off the menu's right edge",
      rt.eval("(function() local p = rawget(ChairPlusKeywordPanel, '_point') return p and p.point == 'TOPLEFT' and p.rel == 'TOPRIGHT' end)()") is True)
check("as the menu's child, so it closes with it",
      rt.eval("rawget(ChairPlusKeywordPanel, '_parent') == ChairPlusPanel") is True)
rt.execute("NS.ToggleKeywordPanel()")
check("and the button closes it again", rt.eval("ChairPlusKeywordPanel:IsShown()") is False)
rt.execute("NS.OpenPanel('groups')")
check("the Groups & people page has a Keywords... button", rt.eval('SHOWN_BUTTON("Keywords...")') is True)

print("\nCasino table on the OSD")
rt, g = fresh()
rt.execute("""
ACTIVE, GAME = false, "holdem"
ChairfacesCasino = {
    UI = { Lobby = {
        IsAnyGameActive = function(self) return ACTIVE, ACTIVE and GAME or nil end,
        GetGameName = function(self, key) return key == "holdem" and "Texas Hold'em" or key end,
        Show = function(self) LOBBY_SHOWN = true end,
    } },
    HoldemMultiplayer = { currentHost = "Chairface-Realm" },
}
BOOT()
NS.SetMany({ osd = true, osdMoney = false, osdBags = false, osdCasino = true })
""")
check("no table up, nothing shows", "Hold'em" not in line(rt), line(rt))
rt.execute("ACTIVE = true")
text = line(rt)
check("a table up in the group shows the game and its host",
      "Texas Hold'em" in text and "(Chairface)" in text, text)
check("with the casino's own icon", "Chairfaces Casino\\Textures\\icon" in text, text)
rt.execute("ChairfacesCasino = nil")
check("without the casino loaded it is simply absent", "Hold'em" not in line(rt), line(rt))


print("\nOSD items are clickable and explain themselves")
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
CALLS = {}
function ToggleAllBags() CALLS[#CALLS + 1] = "bags" end
function ToggleWorldMap() CALLS[#CALLS + 1] = "map" end
function ToggleCharacter(tab) CALLS[#CALLS + 1] = tab end
function GetZoneText() return "Elwynn Forest" end
function GetSubZoneText() return "Goldshire" end
function GetZonePVPInfo() return "friendly" end
function GetUnitSpeed() return 0, 7, 7, 4.72 end
function GetFramerate() return 60 end
function GetNetStats() return 0, 0, 40, 55 end
MOUNTED = false
function IsMounted() return MOUNTED end
function GetInventoryItemDurability(slot) if slot == 1 then return 10, 100 end if slot == 5 then return 80, 100 end end
TIP = {}
GameTooltip = {
    SetOwner = function() end, Show = function() end, Hide = function() end,
    AddLine = function(self, text) TIP[#TIP + 1] = tostring(text) end,
    AddDoubleLine = function(self, a, b) TIP[#TIP + 1] = tostring(a) .. " = " .. tostring(b) end,
}
BOOT()
NS.SetMany({ osd = true, osdMoney = true, osdBags = true, osdZone = true, osdSpeed = true,
             osdDurability = true, osdLatency = true })
NS.RefreshOSD() DRIVER_TICK()
function CLICK(key) local b = NS.OSDHotspot(key) b._scripts.OnClick(b, "LeftButton") end
function HOVER(key) TIP = {} local b = NS.OSDHotspot(key) b._scripts.OnEnter(b) return table.concat(TIP, " | ") end
""")
def calls(rt):
    return list((rt.eval("CALLS") or {}).values())
rt.execute('CLICK("bags")')
check("clicking the bags opens the bags", calls(rt)[-1:] == ["bags"], str(calls(rt)))
rt.execute('CLICK("money")')
check("so does clicking the money", calls(rt)[-1:] == ["bags"], str(calls(rt)))
rt.execute('CLICK("zone")')
check("clicking the zone opens the map", calls(rt)[-1:] == ["map"], str(calls(rt)))
rt.execute('CLICK("durability")')
check("clicking durability opens the character", calls(rt)[-1:] == ["PaperDollFrame"], str(calls(rt)))
tip = rt.eval('HOVER("zone")')
check("the zone's tooltip has the subzone and the territory",
      "Goldshire" in tip and "Friendly territory" in tip, tip)
tip = rt.eval('HOVER("durability")')
check("durability lists each piece, worst first",
      tip.index("Head = 10%") < tip.index("Chest = 80%"), tip)
tip = rt.eval('HOVER("speed")')
check("speed's tooltip gives run and swim speed", "Running = 100%" in tip and "Swimming = 67%" in tip, tip)
check("and no longer tries to name what is changing it, or the speed right now",
      "Nothing is changing" not in tip and "Now =" not in tip, tip)
tip = rt.eval('HOVER("latency")')
check("latency's tooltip offers to free memory", "free unused addon memory" in tip, tip)
check("an item can still drag an unlocked display",
      rt.eval('NS.OSDHotspot("bags")._scripts.OnDragStart ~= nil') is True)


print("\nArranging items on the display itself")
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
function GetZoneText() return "Elwynn Forest" end
function GetSubZoneText() return "" end
BOOT()
NS.SetMany({ osd = true, osdMoney = true, osdBags = true, osdZone = true,
             osdOrder = "money,bags,zone" })
NS.RefreshOSD() DRIVER_TICK()
rawset(ChairPlusOSD, "GetLeft", function() return 100 end)
rawset(ChairPlusOSD, "GetEffectiveScale", function() return 1 end)
function ONLINE() local keys = {} for _, spot in ipairs(NS.OSDOrder()) do if spot.key == "money" or spot.key == "bags" or spot.key == "zone" or spot.divider then keys[#keys + 1] = spot.key end end return table.concat(keys, ",") end
function DRAG_TO(key, cursorX)
    GetCursorPosition = function() return 100 + cursorX, 0 end
    local b = NS.OSDHotspot(key)
    b._scripts.OnDragStart(b)
    if b._scripts.OnUpdate then b._scripts.OnUpdate(b) end
    b._scripts.OnDragStop(b)
    NS.RefreshOSD() DRIVER_TICK()
end
""")
check("with the menu shut, the display is not being arranged", rt.eval("NS.OSDArranging()") is False)
rt.execute("NS.OpenPanel('osd') NS.RefreshOSD() DRIVER_TICK()")
check("open on the OSD page, it is", rt.eval("NS.OSDArranging()") is True)
rt.execute("DRAG_TO('zone', 0)")
check("dragging the zone to the far left puts it first", rt.eval("ONLINE()").startswith("zone,"), rt.eval("ONLINE()"))
rt.execute("DRAG_TO('zone', 5000)")
check("and to the far right puts it last", rt.eval("ONLINE()").endswith(",zone"), rt.eval("ONLINE()"))
rt.execute("NS.AddOSDDivider() NS.OpenPanel('osd') NS.RefreshOSD() DRIVER_TICK()")
check("a divider takes the mouse while arranging", rt.eval('NS.OSDHotspot("|1") ~= nil') is True)
rt.execute("DRAG_TO('|1', 0)")
check("and can be dragged too; alone at the front it is not drawn",
      rt.eval("NS.Get('osdOrder')").startswith("|,"), rt.eval("NS.Get('osdOrder')"))
rt.execute("NS.OpenPanel('quests')")
check("another page of the menu ends arranging", rt.eval("NS.OSDArranging()") is False)
rt.execute("NS.OpenPanel('osd') ChairPlusPanel:Hide() ChairPlusPanel._scripts.OnHide(ChairPlusPanel)")
check("and so does closing the menu", rt.eval("NS.OSDArranging()") is False)
rt.execute("NS.RefreshOSD() DRIVER_TICK()")
check("a divider's drag target goes away with it", rt.eval('NS.OSDHotspot("|1"):IsShown()') is False)


print("")
print("Hiding the XP bar and status bar 2")
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
MainStatusTrackingBarContainer = CreateFrame("Frame", "MainStatusTrackingBarContainer", UIParent)
SecondaryStatusTrackingBarContainer = CreateFrame("Frame", "SecondaryStatusTrackingBarContainer", UIParent)
MainStatusTrackingBarContainer:Show() SecondaryStatusTrackingBarContainer:Show()
BOOT()
""")
check("off by default, both bars are left alone",
      rt.eval("MainStatusTrackingBarContainer:IsShown() and SecondaryStatusTrackingBarContainer:IsShown()") is True)
rt.execute("""
BAR_CHILD = CreateFrame("StatusBar", nil, MainStatusTrackingBarContainer)
rawset(MainStatusTrackingBarContainer, "GetChildren", function() return BAR_CHILD end)
rawset(BAR_CHILD, "IsMouseEnabled", function(self) return rawget(self, "_mouse") ~= false end)
HIDE_CALLS = 0
for _, bar in ipairs({ MainStatusTrackingBarContainer, SecondaryStatusTrackingBarContainer }) do
    rawset(bar, "Hide", function() HIDE_CALLS = HIDE_CALLS + 1 end)
end
""")
rt.execute('NS.Set("hideStatusBars", true)')
check("one toggle makes both see-through",
      rt.eval("MainStatusTrackingBarContainer:GetAlpha() == 0 and SecondaryStatusTrackingBarContainer:GetAlpha() == 0") is True)
check("and click-through, so no tooltip from an invisible bar",
      rt.eval("rawget(BAR_CHILD, '_mouse')") is False)
check("without ever calling Hide on Blizzard's bars", rt.eval("HIDE_CALLS") == 0)
check("and a bar missing on this client is not an error", rt.eval("NS.modules.hideStatusBars.broken") is None)
rt.execute('NS.Set("hideStatusBars", false)')
check("turning it off brings both back, mouse and all",
      rt.eval("MainStatusTrackingBarContainer:GetAlpha() == 1 and SecondaryStatusTrackingBarContainer:GetAlpha() == 1") is True
      and rt.eval("rawget(BAR_CHILD, '_mouse')") is True)
# The reload case (2026-09-26): on, from the saved file, then the client's
# own bar layout puts the alpha back after login without showing the bar.
rt, g = fresh()
rt.execute("""
function InCombatLockdown() return false end
function hooksecurefunc(obj, name, fn)
    if type(obj) == "string" then obj, name, fn = _G, obj, name end
    local original = obj[name]
    rawset(obj, name, function(...)
        local a, b, c = original(...)
        fn(...)
        return a, b, c
    end)
end
MainStatusTrackingBarContainer = CreateFrame("Frame", "MainStatusTrackingBarContainer", UIParent)
MainStatusTrackingBarContainer:Show()
ChairPlusDB = { settings = { hideStatusBars = true } }
BOOT()
MainStatusTrackingBarContainer:SetAlpha(1)
""")
check("after a reload, the client putting the XP bar back does not bring it back",
      rt.eval("MainStatusTrackingBarContainer:GetAlpha()") == 0, rt.eval("MainStatusTrackingBarContainer:GetAlpha()"))
rt.execute('NS.Set("hideStatusBars", false) MainStatusTrackingBarContainer:SetAlpha(1)')
check("and switched off, the client's alpha stands",
      rt.eval("MainStatusTrackingBarContainer:GetAlpha()") == 1)
check("the toggle is on the OSD page, not under the display's own switch",
      rt.eval("""(function() for _, r in ipairs(NS.ROWS or {}) do
          if r.key == "hideStatusBars" then return r.tab == "osd" and r.sub == nil end end
          return "no ROWS" end)()""") in (True, "no ROWS"))

print("\nRestock")
RESTOCK_SETUP = """
-- A merchant: arrows by the 200, water by the 5, and a token-cost item.
GOODS = {
    { id = 2512, name = "Rough Arrow", price = 10, lot = 200 },
    { id = 159, name = "Refreshing Spring Water", price = 25, lot = 5 },
    { id = 999, name = "Badge Item", price = 0, lot = 1, token = true },
}
HAVE = { [2512] = 50, [159] = 0, [999] = 0 }
BUYS = {}
BAGS_FULL = false
MONEY = 100000
function GetMoney() return MONEY end
function GetMerchantNumItems() return #GOODS end
function GetMerchantItemID(i) return GOODS[i] and GOODS[i].id end
function GetMerchantItemInfo(i)
    local g = GOODS[i]
    return g.name, 1, g.price, g.lot, -1, true, true, g.token or false
end
function BuyMerchantItem(i)
    local g = GOODS[i]
    table.insert(BUYS, g.id)
    MONEY = MONEY - g.price
    if not BAGS_FULL then HAVE[g.id] = HAVE[g.id] + g.lot end
end
C_Item = C_Item or {}
C_Item.GetItemNameByID = function(id) for _, g in ipairs(GOODS) do if g.id == id then return g.name end end end
"""
def restock_rt(setup=""):
    rt, g = fresh()
    rt.execute(RESTOCK_SETUP + setup)
    rt.execute("BOOT() NS.GetItemCount = function(id) return HAVE[id] or 0 end")
    return rt, g
def visit(rt, passes=12):
    rt.execute("PRINTED = {} BUYS = {} MerchantFrame:Show() FireEvent('MERCHANT_SHOW')")
    rt.execute("RUN_TIMERS(%d)" % passes)
    return "\n".join(str(v) for v in rt.eval("PRINTED").values())

rt, g = restock_rt()
check("restock ships off", g.NS.Get("restock") is False)
rt.execute("NS.SetRestock(2512, 1000) NS.SetRestock(159, 20) NS.SetRestock(2512, 800)")
check("the list keeps one count per item, changed in place",
      rt.eval("NS.Get('restockList')") == "2512:800,159:20")
check("a bad count is refused", rt.eval("select(2, NS.SetRestock(159, 0))") == "the count must be 1 to 5000")
rt.execute("NS.RemoveRestock(159) NS.SetRestock(159, 20)")
check("remove, then add again", rt.eval("NS.Get('restockList')") == "2512:800,159:20")

rt, g = restock_rt()
rt.execute("NS.Set('restock', true) NS.SetRestock(2512, 1000) NS.SetRestock(159, 20) NS.SetRestock(999, 5)")
said = visit(rt)
check("it buys whole lots until you hold the count", rt.eval("HAVE[2512]") == 1050 and rt.eval("HAVE[159]") == 20,
      (rt.eval("HAVE[2512]"), rt.eval("HAVE[159]")))
check("never an item that costs more than gold", rt.eval("HAVE[999]") == 0)
check("and says what it bought and what it cost",
      "Restocked: 1000 Rough Arrow, 20 Refreshing Spring Water" in said and "150 copper" in said, said[-200:])
said = visit(rt)
check("a second visit with everything held buys nothing", len(list(rt.eval("BUYS").values())) == 0)

rt, g = restock_rt()
rt.execute("NS.Set('restock', true) NS.Set('restockCap', 1) NS.SetRestock(2512, 5000) GOODS[1].price = 4000")
said = visit(rt)
check("the per-visit limit stops it", rt.eval("HAVE[2512]") == 450 and "spending limit" in said, said[-200:])

rt, g = restock_rt()
rt.execute("NS.Set('restock', true) NS.Set('restockCap', 0) NS.Set('restockFloor', 5) NS.SetRestock(2512, 5000)"
           " MONEY = 70000 GOODS[1].price = 15000")
said = visit(rt)
check("and so does the gold floor", rt.eval("MONEY") == 55000 and "gold floor" in said, said[-200:])

rt, g = restock_rt()
rt.execute("NS.Set('restock', true) NS.SetRestock(2512, 1000) BAGS_FULL = true")
said = visit(rt, passes=20)
buys = len(list(rt.eval("BUYS").values()))
check("with full bags it gives up after one pass of orders, not buying forever",
      0 < buys <= 4 and "bags are full" in said, (buys, said[-200:]))

# A slow server: bought lots show up a pass later. It must not order again
# for what is already on its way.
rt, g = restock_rt('''
LATE = {}
function BuyMerchantItem(i)
    local g = GOODS[i]
    table.insert(BUYS, g.id)
    MONEY = MONEY - g.price
    table.insert(LATE, g)
end
function DELIVER() for _, g in ipairs(LATE) do HAVE[g.id] = HAVE[g.id] + g.lot end LATE = {} end
''')
rt.execute("NS.Set('restock', true) NS.SetRestock(2512, 450)")
rt.execute("PRINTED = {} BUYS = {} MerchantFrame:Show() FireEvent('MERCHANT_SHOW')")
for _ in range(8):
    rt.execute("RUN_TIMERS(1) DELIVER()")
check("with a slow server it never orders twice for the same count",
      rt.eval("HAVE[2512]") == 450 and len(list(rt.eval("BUYS").values())) == 2,
      (rt.eval("HAVE[2512]"), len(list(rt.eval("BUYS").values()))))

rt, g = restock_rt()
rt.execute("NS.Set('restock', true) NS.SetRestock(2512, 5000)")
rt.execute("MerchantFrame:Show() FireEvent('MERCHANT_SHOW') RUN_TIMERS(2) FireEvent('MERCHANT_CLOSED')")
before = rt.eval("HAVE[2512]")
rt.execute("RUN_TIMERS(10)")
check("closing the merchant stops it", rt.eval("HAVE[2512]") == before and before < 5000)

rt, g = restock_rt()
rt.execute("NS.Set('restock', true) NS.SetRestock(2512, 1000) SHIFT = true")
visit(rt)
check("holding shift leaves it to you", rt.eval("HAVE[2512]") == 50)

rt, g = restock_rt("""
function GetInventoryItemID(unit, slot) if slot == 0 then return 2512 end end
""")
rt.execute("""
NS.GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end
NS.GetContainerItemInfo = function(bag, slot) return ({ { itemID = 159 }, { itemID = 4242 } })[slot] end
MerchantFrame:Show() FireEvent('MERCHANT_SHOW')
""")
s_ = rt.eval("NS.RestockSuggestions()")
ids = [s_[i].id for i in range(1, len(s_) + 1)]
check("suggestions: your ammo, and what in your bags this merchant sells", ids == [2512, 159], ids)
rt.execute("NS.SetRestock(159, 20)")
s_ = rt.eval("NS.RestockSuggestions()")
check("and not what is already on the list", [s_[i].id for i in range(1, len(s_) + 1)] == [2512])
rt.execute("NS.ToggleRestockPanel()")
check("the Items window opens beside the menu", rt.eval("ChairPlusRestockPanel:IsShown()") is True)
check("it has the tooltip item ID switch, off like the menu's",
      rt.eval("ChairPlusRestockPanel.showIDs:GetChecked()") is False)
rt.execute("""
local c = ChairPlusRestockPanel.showIDs
c:SetChecked(true) rawget(c, "_scripts").OnClick(c)
""")
check("ticking it there shows IDs in tooltips, Tooltip extras and all",
      g.NS.Get("tooltipIDs") is True and g.NS.Get("tooltipExtras") is True)
rt.execute("""
local c = ChairPlusRestockPanel.showIDs
c:SetChecked(false) rawget(c, "_scripts").OnClick(c)
""")
check("unticking takes only the IDs off",
      g.NS.Get("tooltipIDs") is False and g.NS.Get("tooltipExtras") is True)
rt.execute("NS.Set('tooltipIDs', true) NS.RefreshRestockPanel()")
check("and it follows the menu's switch", rt.eval("ChairPlusRestockPanel.showIDs:GetChecked()") is True)

print("\nProfession cooldowns")
rt, g = fresh()
rt.execute("""
CLOCK = 1700000000
time = function() return CLOCK end
C_Spell = nil
GetSpellCooldown = function() error("secret") end
BOOT()
""")
rt.execute("FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'player', 'Cast-1', 18560) RUN_TIMERS(2)")
mine = "(function() for _, r in pairs(ChairPlusDB.cooldowns) do return r end end)()"
check("a tracked cast is recorded, with the table's duration when the game keeps it secret",
      rt.eval(mine + ".spells[18560]") == 1700000000 + 4 * 86400)
rt.execute("FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'player', 'Cast-2', 133)")
check("an untracked spell is not", rt.eval(mine + ".spells[133]") is None)
rt.execute("FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'party1', 'Cast-3', 17187)")
check("nor someone else's cast", rt.eval(mine + ".spells[17187]") is None)
rt.execute("""
GetSpellCooldown = function(id) return NOW - 1, 36 * 3600 end
FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'player', 'Cast-4', 17187) RUN_TIMERS(2)
""")
check("the game's own cooldown is used when it can be read",
      abs(rt.eval(mine + ".spells[17187]") - (1700000000 + 36 * 3600 - 1)) <= 1, rt.eval(mine + ".spells[17187]"))
rt.execute("""
ChairPlusDB.cooldowns["guid:alt"] = { name = "Sewer Urchin", spells = { [19566] = CLOCK - 5 } }
""")
check("counts span every character: one ready of three", tuple(rt.eval("{ NS.CooldownCounts() }").values()) == (1, 3))
rt.execute("NS.Set('osd', true) NS.SetMany({ osdMoney = false, osdBags = false, osdCooldowns = true })")
text = line(rt)
check("the OSD item shows the icon and how many are ready", "Trade_Alchemy" in text and " 1 ready" in text, text)
rt.execute("PRINTED = {} NS.AnnounceReadyCooldowns()")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("the ready notice is off out of the box", "Salt Shaker" not in said)
rt.execute("NS.Set('cooldownNotify', true) PRINTED = {} NS.AnnounceReadyCooldowns() NS.AnnounceReadyCooldowns()")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("switched on, it says so once", said.count("Salt Shaker is ready on Sewer Urchin") == 1, said)
rt.execute("CLOCK = CLOCK + 5 * 86400 PRINTED = {} SlashCmdList['CHAIRPLUS']('cooldowns')")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("/chair cooldowns lists every character's", "Sewer Urchin" in said and "Mooncloth: ready" in said, said)
rt.execute("PRINTED = {} SlashCmdList['CHAIRPLUS']('cooldowns probe') FireEvent('UNIT_SPELLCAST_SUCCEEDED', 'player', 'Cast-5', 12345) RUN_TIMERS(2)")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("the probe prints the next cast's spell ID and what the game said", "cast 12345" in said, said)

print("\nWelcome page and What's new")
# Suite/Welcome.lua and Suite/WhatsNew.lua ride on ChairPlus's widgets and
# settings; loaded here before BOOT so What's new hears PLAYER_LOGIN.
SUITE_FILES = """
SUITE_TABLE.version = "1.4.0"
for _, f in ipairs({ "Suite/Welcome.lua", "Suite/WhatsNew.lua" }) do
    assert(loadfile(f))("Chaircraft", SUITE_TABLE)
end
"""
rt, g = fresh(stock=True)
rt.execute("ChairPlusDB = nil")
rt.execute(SUITE_FILES)
rt.execute("BOOT() RUN_TIMERS(1)")
check("a brand-new account gets the welcome page", rt.eval("ChaircraftWelcome and ChaircraftWelcome:IsShown()") is True)
check("and not What's new on top of it",
      rt.eval("ChaircraftWhatsNew == nil or not ChaircraftWhatsNew:IsShown()") is True)
check("both remembered for next time",
      rt.eval("ChairPlusDB.welcomed") is True and rt.eval("ChairPlusDB.lastSeenVersion") == "1.4.0")
check("its first switch is the menu's own row, label and all",
      rt.eval("ChaircraftWelcome.checks[1].info.label") == "Show the display")
rt.execute("""
local c = ChaircraftWelcome.checks[1].check
c:SetChecked(true)
rawget(c, "_scripts").OnClick(c)
""")
check("ticking it switches the setting on", g.NS.Get("osd") is True)
rt.execute("ChaircraftWelcome:Hide() SUITE_TABLE.MaybeWelcome()")
check("it does not come back on the next login", rt.eval("ChaircraftWelcome:IsShown()") is False)

rt, g = fresh(stock=True)
rt.execute("""ChairPlusDB = { profiles = { ["guid:alt"] = { settings = { sellJunk = true } } },
                              lastSeenVersion = "1.3.0" }""")
rt.execute(SUITE_FILES)
rt.execute("BOOT() RUN_TIMERS(1)")
check("an account updated from 1.3.0 gets no welcome page",
      rt.eval("ChaircraftWelcome == nil or not ChaircraftWelcome:IsShown()") is True)
check("but What's new, once", rt.eval("ChaircraftWhatsNew and ChaircraftWhatsNew:IsShown()") is True
      and rt.eval("ChairPlusDB.lastSeenVersion") == "1.4.0")
rt.execute("ChaircraftWhatsNew:Hide()")
check("and not again for the same version", rt.eval("SUITE_TABLE.MaybeWhatsNew(false)") is False)
print("\nPopups stand in for the menu")
rt, g = fresh(stock=True)
rt.execute("""ChairPlusDB = { profiles = { ["guid:alt"] = { settings = { sellJunk = true } } },
                              lastSeenVersion = "1.4.0" }""")
rt.execute(SUITE_FILES)
rt.execute("BOOT() RUN_TIMERS(1) NS.OpenPanel('general')")
rt.execute("SUITE_TABLE.ShowWelcome()")
check("Quick setup from the menu hides the menu while it is up",
      rt.eval("ChaircraftWelcome:IsShown()") is True and rt.eval("ChairPlusPanel:IsShown()") is False)
rt.execute("ChaircraftWelcome:Hide()")
check("and closing it brings the menu back, on the page it was on",
      rt.eval("ChairPlusPanel:IsShown()") is True and rt.eval("NS.CurrentPage()") == "general")
rt.execute("ChairPlusPanel:Hide() SUITE_TABLE.ShowWelcome() ChaircraftWelcome:Hide()")
check("opened with the menu closed, closing it leaves the menu closed",
      rt.eval("ChairPlusPanel:IsShown()") is False)
rt.execute("SUITE_TABLE.ShowWelcome() rawget(ChaircraftWelcome.menu, '_scripts').OnClick()")
check("its Open the full menu button opens the menu",
      rt.eval("ChaircraftWelcome:IsShown()") is False and rt.eval("ChairPlusPanel:IsShown()") is True)
rt.execute("NS.OpenPanel('general') SUITE_TABLE.ShowWhatsNew()")
check("What's new stands in for the menu the same way",
      rt.eval("ChaircraftWhatsNew:IsShown()") is True and rt.eval("ChairPlusPanel:IsShown()") is False)
rt.execute("ChaircraftWhatsNew:Hide()")
check("and hands it back", rt.eval("ChairPlusPanel:IsShown()") is True)

print("\nWhat's new can be switched off")
rt, g = fresh(stock=True)
rt.execute("""ChairPlusDB = { profiles = { ["guid:alt"] = { settings = { sellJunk = true } } },
                              lastSeenVersion = "1.3.0", whatsNewOff = true }""")
rt.execute(SUITE_FILES)
rt.execute("BOOT() RUN_TIMERS(1)")
check("switched off, an update does not open it",
      rt.eval("ChaircraftWhatsNew == nil or not ChaircraftWhatsNew:IsShown()") is True
      and rt.eval("ChairPlusDB.lastSeenVersion") == "1.4.0")
check("but it still opens by hand", rt.eval("SUITE_TABLE.ShowWhatsNew()") is True)
check("with its box ticked", rt.eval("ChaircraftWhatsNew.never:GetChecked()") is True)
rt.execute("""
local c = ChaircraftWhatsNew.never
c:SetChecked(false) rawget(c, "_scripts").OnClick(c)
""")
check("unticking it there switches it back on", rt.eval("ChairPlusDB.whatsNewOff") is None)
check("and the General page has the same switch",
      rt.eval("""(function() for _, r in ipairs(NS.ROWS) do
          if r.key == "whatsNewOff" then return r.tab end end end)()""") == "general")

print("\nSearching the menu")
rt, g = fresh()
rt.execute('''
SUITE_TABLE.parts = { { key = "chairplus", title = "ChairPlus" },
    { key = "chairignore", title = "ChairIgnore", blurb = "One ignore list for every character.",
      Open = function() OPENED_PART = "ignore" return true end,
      Search = function() return { { label = "Hide chat from everyone on the list",
                                     open = function() OPENED_TAB = "options" end } } end } }
BOOT()
''')
def search(q):
    return rt.eval("NS.SearchSettings(%r)" % q)
hits = search("repair")
labels = [hits[i].label for i in range(1, len(hits) + 1)]
check("search finds an option by its label", "Repair automatically" in labels, labels)
check("and says which page it is on",
      any(hits[i].label == "Repair automatically" and hits[i].where == "Buying & selling" for i in range(1, len(hits) + 1)))
check("case does not matter", len(search("REPAIR")) == len(hits))
check("one letter shows nothing", len(search("r")) == 0)
tip_only = search("bought back")
check("a word only in an option's tooltip still finds it",
      any(tip_only[i].label == "Sell junk automatically" for i in range(1, len(tip_only) + 1)))
rt.execute("NS.GoToSetting(NS.SearchSettings('dark background')[1])")
check("choosing a result opens its page", rt.eval("NS.CurrentPage()") == "osd"
      and rt.eval("ChairPlusPanel:IsShown()") is True)
rt.execute("NS.GoToSetting(NS.SearchSettings('hide chat from')[1])")
check("another part's option opens that part, on the right tab",
      rt.eval("OPENED_PART") == "ignore" and rt.eval("OPENED_TAB") == "options")
check("a part is found by name", any(search("chairignore")[i].where == "Page"
                                     for i in range(1, len(search("chairignore")) + 1)))
rt.execute('''
local box = ChairPlusPanel.search
box:SetText("zzzz") rawget(box, "_scripts").OnTextChanged(box)
''')
check("no match says so", rt.eval("ChairPlusPanel.searchList.none:IsShown()") is True)

check("the General page offers both again",
      rt.eval("""(function() local found = 0
          for _, r in ipairs(NS.ROWS) do
              if r.tab == "general" and (r.action == "Quick setup..." or r.action == "What's new...") then found = found + 1 end
          end return found end)()""") == 2)


if failures:
    print(f"{len(failures)} check(s) failed:")
    for name in failures:
        print(f"  - {name}")
    sys.exit(1)
print("All checks passed.")
