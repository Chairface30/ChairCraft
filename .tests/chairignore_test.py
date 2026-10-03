# Offline checks for ChairIgnore (needs: pip install lupa).
#   python .tests/chairignore_test.py
#
# Loads ChairIgnore's files against a mocked client and checks the list, the
# two-way sync with the game's 50-name ignore list, the chat filters, the
# right-click entry and the window. As with the other suites, a pass here is
# not proof in game: the client is stricter than this mock.
import glob, os, sys
from lupa import lua51

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        failures.append(name)


HARNESS = r'''
PRINTED = {}
print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    table.insert(PRINTED, table.concat(t, " ")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
NOW = 1700000000
function time() return NOW end
function date(fmt, t) return "DATE" end

-- Frames: any method works; the few the code reads back remember their value.
local function Mock()
    local self = { _scripts = {} }
    return setmetatable(self, { __index = function(t, k)
        if type(k) ~= "string" or not k:match("^%u") then return nil end
        return function(obj, ...)
            local a = ...
            if k == "SetScript" then obj._scripts[a] = select(2, ...)
            elseif k == "GetScript" then return obj._scripts[a]
            elseif k == "HookScript" then obj._scripts[a] = select(2, ...)
            elseif k == "SetText" then obj._text = a
            elseif k == "GetText" then return obj._text or ""
            elseif k == "SetChecked" then obj._checked = a and true or false
            elseif k == "GetChecked" then return obj._checked
            elseif k == "Show" then obj._shown = true
            elseif k == "Hide" then
                -- As the client does: OnHide only when it was showing.
                local was = obj._shown
                obj._shown = false
                if was and obj._scripts.OnHide then obj._scripts.OnHide(obj) end
            elseif k == "SetShown" then obj._shown = a and true or false
            elseif k == "IsShown" then return obj._shown == true
            elseif k == "HasFocus" then return false
            elseif k == "SetEnabled" then obj._enabled = a and true or false
            elseif k == "SetMinMaxValues" then obj._min, obj._max = a, select(2, ...)
            elseif k == "GetMinMaxValues" then return obj._min or 0, obj._max or 0
            elseif k == "SetValue" then
                -- As a slider does: kept inside its range, then OnValueChanged.
                local v = math.max(obj._min or 0, math.min(obj._max or a, a))
                obj._value = v
                if obj._scripts.OnValueChanged then obj._scripts.OnValueChanged(obj, v) end
            elseif k == "GetValue" then return obj._value or 0
            elseif k:match("^Create") then return Mock()
            end
        end
    end })
end
MakeMock = Mock
FRAMES = {}
function CreateFrame(kind, name, parent, template)
    local f = Mock()
    f._kind, f._name = kind, name
    table.insert(FRAMES, f)
    if name then _G[name] = f end
    return f
end
UIParent = Mock()
UISpecialFrames = {}

-- The player.
-- As WoW Forever does: the first name and the surname as two values.
function UnitName(unit) if unit == "player" then return "Me", "Test" end return UNIT_NAMES and UNIT_NAMES[unit] end
function GetNormalizedRealmName() return "HomeRealm" end
function UnitIsPlayer(unit) return true end
function UnitIsUnit(a, b) return a == b end

-- The game's ignore list.
GAME = {}
REFUSE = {}
C_FriendList = {
    GetNumIgnores = function() return #GAME end,
    GetIgnoreName = function(i) return GAME[i] end,
    AddIgnore = function(name)
        if REFUSE[name] then return end
        if #GAME >= 50 then return end
        table.insert(GAME, name)
    end,
    DelIgnore = function(name)
        for i, n in ipairs(GAME) do if n == name then table.remove(GAME, i) return end end
    end,
    IsFriend = function(name) return FRIENDS and FRIENDS[name] or false end,
    IsIgnored = function(name)
        for _, n in ipairs(GAME) do if n == name then return true end end
        return false
    end,
    AddOrDelIgnore = function(name)
        for i, n in ipairs(GAME) do if n == name then table.remove(GAME, i) return end end
        table.insert(GAME, name)
    end,
}
-- As the client's: the hook runs after the original, with its arguments.
function hooksecurefunc(a, b, c)
    local owner, key, fn = a, b, c
    if type(a) == "string" then owner, key, fn = _G, a, b end
    local original = owner[key]
    owner[key] = function(...)
        local results = { original(...) }
        fn(...)
        return unpack(results)
    end
end
function GetTime() return NOW end
ERR_IGNORE_ADDED_S = "%s is now being ignored."
ERR_IGNORE_REMOVED_S = "%s is no longer being ignored."

-- Chat filters.
CHAT_FILTERS = {}
function ChatFrame_AddMessageEventFilter(event, fn)
    CHAT_FILTERS[event] = CHAT_FILTERS[event] or {}
    table.insert(CHAT_FILTERS[event], fn)
end
function CHAT(event, message, sender, lineID)
    for _, fn in ipairs(CHAT_FILTERS[event] or {}) do
        if fn(nil, event, message, sender, "", "", "", "", 0, 0, "", 0, lineID or math.random(1, 1e9)) then
            return true
        end
    end
    return false
end

-- Right-click menus.
MENU_HOOKS = {}
Menu = { ModifyMenu = function(tag, fn) MENU_HOOKS[tag] = fn end }
function MENU(tag, context)
    local root = { buttons = {} }
    function root:CreateDivider() end
    function root:CreateButton(text, fn) table.insert(self.buttons, { text = text, fn = fn }) end
    MENU_HOOKS[tag](nil, root, context)
    return root.buttons
end

SlashCmdList = {}
PENDING = {}
C_Timer = { After = function(delay, fn) table.insert(PENDING, fn) end }
function RUN_TIMERS()
    local queue = PENDING
    PENDING = {}
    for _, fn in ipairs(queue) do fn() end
end

SUITE = { ChairIgnore = {} }
SUITE.UnitFullName = function(unit) local ok, a, b = pcall(UnitName, unit) if not ok or a == nil then return nil end a = tostring(a) if b ~= nil and tostring(b) ~= "" then return a .. " " .. tostring(b) end return a end
SUITE.IsSecret = function(v) return not pcall(function() return "" .. tostring(v) end) end
SUITE.FindPart = function(token) if token == "ignore" then return { Open = function() OPENED = true return true end } end end
NS = SUITE.ChairIgnore
function LOAD(path)
    local chunk = assert(loadfile(path))
    chunk("Chaircraft", SUITE)
end
function EVENT(event, ...)
    for _, f in ipairs(FRAMES) do
        local fn = f._scripts.OnEvent
        if fn then fn(f, event, ...) end
    end
end
'''

FILES = ["ChairIgnore/Core.lua", "ChairIgnore/Filters.lua", "ChairIgnore/Tab.lua", "ChairIgnore/Window.lua"]

print("Parsing every Lua file as 5.1")
lua = lua51.LuaRuntime(unpack_returned_tuples=True)
for path in sorted(glob.glob("ChairIgnore/*.lua")):
    ok, err = lua.eval("function(p) local c, e = loadfile(p) return c ~= nil, tostring(e) end")(path)
    check(f"{path} parses", ok is True, str(err))
if failures:
    sys.exit(1)


def fresh(setup="", on=True):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    rt.execute(setup)
    for f in FILES:
        rt.execute(f'LOAD("{f}")')
    rt.execute('EVENT("ADDON_LOADED", "Chaircraft") EVENT("PLAYER_LOGIN")')
    if on:
        rt.execute('NS.Set("enabled", true)')
    return rt, rt.eval


print("\nShipped off")
rt, ev = fresh(on=False)
check("ChairIgnore is off out of the box", ev("NS.Get('enabled')") is False)
check("the starter filters are there, every one off",
      ev("#NS.Filters()") == 6 and all(ev(f"NS.Filters()[{i}].enabled") is False for i in range(1, 7)))
check("off, a listed player's chat is left alone",
      ev("(NS.Add('Spammer Test'))") is not None and ev("CHAT('CHAT_MSG_SAY', 'hi', 'Spammer Test-HomeRealm')") is False)
check("off, nothing is put on the game's list", ev("#GAME") == 0)

print("\nAccount-wide")
rt, ev = fresh(on=False)
rt.execute("NS.Set('enabled', true) NS.Set('keepLog', true)")
check("switches are kept for the account", ev("ChairIgnoreDB.settings.enabled") is True)
rt.execute("ChairIgnoreCharDB = {}")  # another character logs in
check("so another character finds them as they were", ev("NS.Get('enabled')") is True and ev("NS.Get('keepLog')") is True)

# Up to 1.5.0 they were per character: the first one in brings its own.
rt, ev = fresh("""
ChairIgnoreDB = { players = {} }
ChairIgnoreCharDB = { settings = { enabled = true, spareFriends = false }, gameListRead = true }
""", on=False)
check("a character's old switches come with it to the account",
      ev("NS.Get('enabled')") is True and ev("NS.Get('spareFriends')") is False)
check("and are retired from the character", ev("ChairIgnoreCharDB.settings") is None)
rt, ev = fresh("""
ChairIgnoreDB = { players = {}, settings = { enabled = true } }
ChairIgnoreCharDB = { settings = { enabled = false } }
""", on=False)
check("a second character's leftovers do not undo them",
      ev("NS.Get('enabled')") is True and ev("ChairIgnoreCharDB.settings") is None)

print("\nOne list of people")
# Up to 1.7.0 each character kept its own record of its game ignore list in a
# file of its own. The records live in the account table now, and everyone on
# any of them is on the one list.
rt, ev = fresh("""
ChairIgnoreDB = { players = {}, gameLists = { ["guid:Player-1-B"] = {
    gameList = { ["spammer two-homerealm"] = "Spammer Two-HomeRealm" }, gameListRead = true } } }
ChairIgnoreCharDB = { gameList = { ["spammer one-homerealm"] = "Spammer One-HomeRealm" }, gameListRead = true }
""", on=False)
check("this character's record moves into the account table",
      ev("ChairIgnoreCharDB.gameList") is None and ev("ChairIgnoreCharDB.gameListRead") is None
      and ev("NS.CharStore(true).gameListRead") is True
      and ev("NS.CharStore(true).gameList['spammer one-homerealm']") == "Spammer One-HomeRealm")
check("everyone on any character's game list joins the one list",
      ev("ChairIgnoreDB.players['spammer one-homerealm'].name") == "Spammer One-HomeRealm"
      and ev("ChairIgnoreDB.players['spammer two-homerealm'].name") == "Spammer Two-HomeRealm")
rt.execute("NS.Remove('Spammer Two')")
rt.execute('EVENT("PLAYER_LOGIN")')
check("and a name taken off the list is not brought back by an old record",
      ev("ChairIgnoreDB.players['spammer two-homerealm']") is None)

print("\nNames")
rt, ev = fresh()
for given, want in [("chairface chippendale", "Chairface Chippendale-HomeRealm"),
                    ("Chairface Chippendale", "Chairface Chippendale-HomeRealm"),
                    (" chairface  chippendale ", "Chairface Chippendale-HomeRealm"),
                    ("Chairface Chippendale-Classicbetapvp2", "Chairface Chippendale-Classicbetapvp2"),
                    ("Sewer Urchin - Other Realm", "Sewer Urchin-OtherRealm"),
                    ("McRae Stone", "McRae Stone-HomeRealm"),
                    ("Ab Cd", "Ab Cd-HomeRealm"),
                    ("Abcdefghijkl Mnopqrstuvwx", "Abcdefghijkl Mnopqrstuvwx-HomeRealm"),
                    ("Arthas", None), ("Unknown", None), ("A Bcd", None), ("Abc D", None),
                    ("Abcdefghijklm Stone", None), ("Three Word Name", None),
                    ("", None), ("x1 y2", None), ("a.b cd", None)]:
    got = ev(f"NS.FullName({given!r})")
    check(f"{given!r} is {want!r}", got == want, got)
check("your own realm is left off for showing", ev("NS.ShortName('Arthas Test-HomeRealm')") == "Arthas Test")
check("a two-word name keeps both words", ev("NS.ShortName('Chairface Chippendale-homerealm')") == "Chairface Chippendale")
check("another realm is kept", ev("NS.ShortName('Arthas Test-OtherRealm')") == "Arthas Test-OtherRealm")

print("\nThe list")
rt, ev = fresh()
rt.execute("NS.Add('spammer test', 'sells gold')")
check("added, with its note", ev("NS.Find('Spammer Test').note") == "sells gold")
check("found however it is typed", ev("NS.IsListed('SPAMMER TEST-HomeRealm')") is True)
check("you cannot list yourself", ev("select(2, NS.Add('Me Test'))") == "you cannot ignore yourself")
rt.execute("NS.SetExpiry('Spammer Test', 2)")
check("an expiry is days from now", ev("NS.Find('Spammer Test').expires") == 1700000000 + 2 * 86400)
rt.execute("NOW = NOW + 3 * 86400")
check("and once it has passed, pruning takes them off", ev("NS.PruneExpired()") == 1 and ev("NS.Find('Spammer Test')") is None)
rt.execute("NS.Set('expireDays', 5) NS.Add('Other Test')")
check("new entries take the default expiry", ev("NS.Find('Other Test').expires") == ev("NOW") + 5 * 86400)
rt.execute("NS.Add('Third Test', nil, 0)")
check("unless told 0", ev("NS.Find('Third Test').expires") is None)
check("remove takes them off", ev("NS.Remove('Other Test')") is True and ev("NS.Find('Other Test')") is None)

print("\nSync with the game's list")
rt, ev = fresh('GAME = { "Oldfoe Test" }', on=False)
rt.execute("NS.Set('enabled', true)")
check("names already on the game list come onto ours", ev("NS.IsListed('Oldfoe Test')") is True)
rt.execute("NS.Add('Newfoe Test')")
check("and ours go onto the game's", ev("GAME[2]") == "Newfoe Test")
rt.execute("NS.Add('Farfoe Test-OtherRealm')")
check("another realm's player goes on with the realm", ev("GAME[3]") == "Farfoe Test-OtherRealm")
rt.execute("C_FriendList.DelIgnore('Oldfoe Test') EVENT('IGNORELIST_UPDATE')")
check("unignoring the normal way takes them off ours", ev("NS.IsListed('Oldfoe Test')") is False)
rt.execute("table.insert(GAME, 'Typed Test') EVENT('IGNORELIST_UPDATE')")
check("ignoring the normal way puts them on ours", ev("NS.IsListed('Typed Test')") is True)
rt.execute("NS.Remove('Newfoe Test')")
check("removing from ours takes them off the game's",
      all(ev(f"GAME[{i}]") != "Newfoe Test" for i in range(1, 5)))

rt, ev = fresh('REFUSE = { Ghost = true }', on=False)
rt.execute("NS.Set('enabled', true) NS.Add('Ghost Test') EVENT('IGNORELIST_UPDATE') EVENT('IGNORELIST_UPDATE')")
check("a name the server refuses stays on ours", ev("NS.IsListed('Ghost Test')") is True)

# Only the game list read whole can say someone was unignored. One still
# loading reads as empty, and a name the client keeps secret reads as
# missing: taking either for an unignore is how a whole list went missing.
rt, ev = fresh('GAME = { "Oldfoe Test", "Second Test" }', on=False)
rt.execute("NS.Set('enabled', true)")
rt.execute("KEPT = GAME GAME = {} EVENT('IGNORELIST_UPDATE')")
check("a game list that reads as empty takes no one off ours",
      ev("NS.IsListed('Oldfoe Test')") is True and ev("NS.IsListed('Second Test')") is True)
rt.execute("""GAME = { "Oldfoe Test", setmetatable({}, { __tostring = function() error("secret") end }) }
EVENT('IGNORELIST_UPDATE')""")
check("nor does one with a name the client keeps secret",
      ev("NS.IsListed('Second Test')") is True)
rt.execute("GAME = { 'Oldfoe Test' } EVENT('IGNORELIST_UPDATE')")
check("one read whole still does", ev("NS.IsListed('Second Test')") is False)

# A list that reads whole can still be short a name for a moment while the
# server fills it in. When the name comes back it is the same ignore: the
# reason kept, and no prompt asking for it again.
rt, ev = fresh('GAME = { "Oldfoe Test", "Second Test" }', on=False)
rt.execute("NS.Set('enabled', true) NS.SetNote('Second Test', 'spams trade') NS.SetExpiry('Second Test', 9)")
expires = ev("NS.Find('Second Test').expires")
rt.execute("GAME = { 'Oldfoe Test' } EVENT('IGNORELIST_UPDATE')")
rt.execute("GAME = { 'Oldfoe Test', 'Second Test' } EVENT('IGNORELIST_UPDATE')")
check("a name back on the game list keeps its reason and expiry",
      ev("NS.Find('Second Test') and NS.Find('Second Test').note") == "spams trade"
      and ev("NS.Find('Second Test').expires") == expires)
check("and is not asked about again", ev("ChairIgnoreReason == nil or not ChairIgnoreReason:IsShown()") is True)
rt.execute("C_FriendList.DelIgnore('Second Test') NOW = NOW + 5 C_FriendList.AddIgnore('Second Test')")
check("unignored and ignored again by hand, the reason is kept too",
      ev("NS.Find('Second Test').note") == "spams trade"
      and ev("ChairIgnoreReason == nil or not ChairIgnoreReason:IsShown()") is True)
rt.execute("NS.Remove('Second Test') EVENT('IGNORELIST_UPDATE') NS.Add('Second Test')")
check("taken off in ChairIgnore itself, the reason goes with them", ev("NS.Find('Second Test').note") is None)

# Removing from ours is final: another character's game list that still
# holds the name is behind, and is brought up to date, not believed.
rt, ev = fresh('GAME = { "Oldfoe Test" }', on=False)
rt.execute("NS.Set('enabled', true) NS.Remove('Oldfoe Test')")
check("removing takes them off this character's game list", ev("#GAME") == 0)
rt.execute("""ChairIgnoreDB.gameLists["guid:Other"] = { gameList = { ["oldfoe test-homerealm"] = "Oldfoe Test-HomeRealm" }, gameListRead = true }
NS.charKey = "guid:Other" table.insert(GAME, "Oldfoe Test") EVENT('IGNORELIST_UPDATE')""")
check("on another character, the name still on its game list is not put back on ours",
      ev("NS.IsListed('Oldfoe Test')") is False)
check("and comes off that game list too", ev("#GAME") == 0)
rt.execute("EVENT('IGNORELIST_UPDATE')")  # the game reports the list without them
rt.execute("table.insert(GAME, 'Oldfoe Test') EVENT('IGNORELIST_UPDATE')")
check("ignoring them again the normal way is a fresh ignore", ev("NS.IsListed('Oldfoe Test')") is True)
rt.execute("NS.Remove('Oldfoe Test') NS.Add('Oldfoe Test')")
check("as is adding them again", ev("NS.IsListed('Oldfoe Test')") is True and ev("ChairIgnoreDB.removed['oldfoe test-homerealm']") is None)

rt, ev = fresh(on=False)
rt.execute("for i = 1, 60 do NS.Add('Foe Q' .. string.char(96 + (i % 26) + 1) .. string.rep('a', math.floor(i / 26))) NOW = NOW + 1 end")
rt.execute("NS.Set('enabled', true)")
check("sixty on ours, the game's list stops at fifty", ev("NS.Count()") == 60 and ev("#GAME") == 50)
rt.execute("EVENT('IGNORELIST_UPDATE')")
check("and the ten left over are not taken for unignored", ev("NS.Count()") == 60)

rt, ev = fresh(on=False)
rt.execute("NS.Set('enabled', true) NS.Add('Loud Test')")
check("the game's 'now being ignored' line from a sync is hidden",
      ev("CHAT('CHAT_MSG_SYSTEM', 'Loud Test is now being ignored.', '')") is True)
check("but only the ones the sync caused",
      ev("CHAT('CHAT_MSG_SYSTEM', 'Loud Test is now being ignored.', '')") is False)

print("\nChat")
rt, ev = fresh()
rt.execute("NS.Add('Pest Test-OtherRealm')")
check("a listed player's chat is hidden", ev("CHAT('CHAT_MSG_CHANNEL', 'hello', 'Pest Test-OtherRealm')") is True)
check("everyone else's is not", ev("CHAT('CHAT_MSG_CHANNEL', 'hello', 'Friendly Test-OtherRealm')") is False)
rt.execute("CHAT('CHAT_MSG_SAY', 'a', 'Pest Test-OtherRealm', 77) CHAT('CHAT_MSG_SAY', 'a', 'Pest Test-OtherRealm', 77)")
check("counted once per message, not once per chat window", ev("NS.session.listed") == 2)
rt.execute("NS.Add('Sewer Urchin')")
check("a listed two-word name is hidden too",
      ev("CHAT('CHAT_MSG_CHANNEL', 'hello', 'Sewer Urchin-HomeRealm')") is True)
check("a secret sender is let through, not an error",
      ev("CHAT('CHAT_MSG_SAY', 'x', setmetatable({}, { __tostring = function() error('secret') end }))") is False)

check("a filter left off hides nothing",
      ev("CHAT('CHAT_MSG_CHANNEL', 'cheapest gold here', 'Seller Test-X')") is False)
rt.execute("NS.Filters()[1].enabled = true NS.CompileFilters()")
check("switched on, with nothing else to tick, a message with a word from every line is hidden",
      ev("CHAT('CHAT_MSG_CHANNEL', 'Cheapest GOLD here', 'Seller Test-X')") is True)
check("from a two-word Forever name as well",
      ev("CHAT('CHAT_MSG_CHANNEL', 'Cheapest GOLD here', 'Gold Seller-Classicbetapvp2')") is True)
check("one line alone is not enough", ev("CHAT('CHAT_MSG_CHANNEL', 'anyone selling gold?', 'Buyer Test-X')") is False)
check("spaces and symbols squeezed out still match",
      ev("CHAT('CHAT_MSG_CHANNEL', 'g.o.l.d at w w w dot', 'Seller Test-X')") is True)
check("each filter counts what it hid", ev("NS.Filters()[1].blocked") == 3, ev("NS.Filters()[1].blocked"))
check("guild chat is spared by default", ev("CHAT('CHAT_MSG_GUILD', 'cheapest gold', 'Seller Test-X')") is False)
rt.execute("FRIENDS = { ['Pal Test-X'] = true }")
check("and so are friends", ev("CHAT('CHAT_MSG_CHANNEL', 'cheapest gold', 'Pal Test-X')") is False)
check("and your own messages", ev("CHAT('CHAT_MSG_CHANNEL', 'cheapest gold', 'Me Test-HomeRealm')") is False)
check("a filter with an empty line is not a match-everything",
      ev("NS.MatchFilter('anything', { lines = { '', ' , ' } })") is None)
check("a word that is all symbols is matched as it is",
      ev("NS.MatchFilter('<Pals> recruiting', { lines = { 'recruiting', 'guild, <' }, squeeze = true }) ~= nil") is True)

print("\nStarter filters are shipped once")
rt, ev = fresh()
rt.execute("NS.DeleteFilter(NS.Filters()[4]) NS.InitFilters(ChairIgnoreDB)")
check("one you delete stays deleted", ev("#NS.Filters()") == 5)

print("\nThe hidden messages log")
rt, ev = fresh()
rt.execute("NS.Add('Pest Person') NS.Filters()[1].enabled = true NS.CompileFilters()")
rt.execute("CHAT('CHAT_MSG_SAY', 'hello there', 'Pest Person-HomeRealm')")
rt.execute("CHAT('CHAT_MSG_CHANNEL', 'cheapest gold here', 'Gold Seller-Otherrealm')")
rt.execute("CHAT('CHAT_MSG_CHANNEL', 'an ordinary message', 'Nice Person-Otherrealm')")
check("each hidden message is logged, and only those", ev("#NS.HiddenLog()") == 2)
check("with why: a listed player",
      ev("NS.HiddenLog()[1].why") == "listed" and ev("NS.HiddenLog()[1].kind") == "say"
      and ev("NS.HiddenLog()[1].text") == "hello there")
check("or the filter's name", ev("NS.HiddenLog()[2].why") == "Gold selling"
      and ev("NS.HiddenLog()[2].sender") == "Gold Seller-Otherrealm")
rt.execute("NS.ShowWindow() ChairIgnoreWindow.tabs.hidden._scripts.OnClick()")
check("the Hidden tab lists them newest first",
      ev("ChairIgnoreWindow.pages.hidden.rows[1].cols[4]:GetText()") == "Gold selling"
      and ev("ChairIgnoreWindow.pages.hidden.rows[2].cols[2]:GetText()") == "Pest Person")
rt.execute("""
local page = ChairIgnoreWindow.pages.hidden
page.rows[2]._scripts.OnClick(page.rows[2])
PRINTED = {}
page.show._scripts.OnClick()
""")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("Show in chat brings a message back, marked", "hidden by ChairIgnore" in said and "hello there" in said, said)
rt.execute("ChairIgnoreWindow.pages.hidden.unignore._scripts.OnClick()")
check("Unignore takes a listed sender off the list", ev("NS.IsListed('Pest Person')") is False)
rt.execute("for i = 1, 250 do CHAT('CHAT_MSG_CHANNEL', 'cheapest gold ' .. i, 'Gold Seller-Otherrealm') end")
check("at most 200 are kept, the oldest dropped",
      ev("#NS.HiddenLog()") == 200 and ev("NS.HiddenLog()[200].text") == "cheapest gold 250")
rt.execute("ChairIgnoreWindow.pages.hidden.clear._scripts.OnClick()")
check("Clear empties it", ev("#NS.HiddenLog()") == 0)
check("kept for the session only by default", ev("ChairIgnoreDB.log") is None)
rt.execute("NS.Set('keepLog', true) CHAT('CHAT_MSG_CHANNEL', 'cheapest gold again', 'Gold Seller-Otherrealm')")
check("with Keep on, it lives in the saved data", ev("#ChairIgnoreDB.log") == 1)

print("\nWildcards")
rt, ev = fresh()
def matches(lines, text):
    rt.globals().MSG = text
    rt.execute("F = { lines = {} }")
    for i, l in enumerate(lines, 1):
        rt.globals().LINE = l
        rt.execute("F.lines[%d] = LINE" % i)
    return rt.eval("NS.MatchFilter(MSG, F) ~= nil")
check("<*> catches a guild tag", matches(["<*>"], "<The Unkindled> is recruiting all classes"))
check("any tag, however long", matches(["<*>"], "Join <Pals For Life And Beyond> today"))
check("in any case", matches(["<*>"], "<pals> RECRUITING"))
check("but not a message without one", not matches(["<*>"], "anyone for deadmines?"))
check("nor half a tag", not matches(["<*>"], "3 < 5 is true"))
check("with another line: a tag and recruiting", matches(["<*>", "recruit, recruiting"], "<Pals> recruiting healers"))
check("the tag alone is not enough then", not matches(["<*>", "recruit, recruiting"], "<Pals> says hi"))
check("* in the middle of a word", matches(["g*ld"], "cheap g.0.ld here"))
check("a lone * is ignored, never a match-everything", not matches(["*"], "anything at all"))
check("other symbols in a wildcard word stay literal",
      matches(["50%*off"], "get 50% and more off") and not matches(["a.*z"], "abz"))
check("the test box reports a wildcard miss by its line",
      (lambda: (rt.globals().__setitem__("MSG", "<Pals> says hi"),
                rt.execute("F = { lines = { '<*>', 'recruit' } }"),
                ev("NS.MissingLine(MSG, F)"))[2])() == 2)

print("\nA filter's own channels")
rt, ev = fresh()
rt.execute("""
function CHAT_IN(number, name, message, sender)
    for _, fn in ipairs(CHAT_FILTERS.CHAT_MSG_CHANNEL or {}) do
        if fn(nil, "CHAT_MSG_CHANNEL", message, sender, "", number .. ". " .. name, "", "", 0,
              number, name, 0, math.random(1, 1e9)) then return true end
    end
    return false
end
local f = NS.Filters()[1]
f.enabled = true f.channels = "Trade"
NS.CompileFilters()
""")
spam = "cheapest gold here"
rt.globals().SPAM = spam
check("a filter set to Trade hides it in Trade",
      ev("CHAT_IN(2, 'Trade - City', SPAM, 'Gold Seller-X')") is True)
check("but not in General", ev("CHAT_IN(1, 'General - Elwynn Forest', SPAM, 'Gold Seller-X')") is False)
check("nor in say", ev("CHAT('CHAT_MSG_SAY', SPAM, 'Gold Seller-X')") is False)
rt.execute("NS.Filters()[1].channels = '2' NS.CompileFilters()")
check("a bare number is never matched: numbers differ by character",
      ev("CHAT_IN(2, 'Trade - City', SPAM, 'Gold Seller-X')") is False)
rt.execute("NS.Filters()[1].channels = 'trade, lookingforgroup' NS.CompileFilters() NS.Set('filterPublic', false)")
check("naming a channel overrides the Options tab", ev("CHAT_IN(5, 'LookingForGroup', SPAM, 'Gold Seller-X')") is True)
rt.execute("NS.Filters()[1].channels = nil NS.CompileFilters()")
check("left blank, it follows the Options tab again",
      ev("CHAT_IN(2, 'Trade - City', SPAM, 'Gold Seller-X')") is False)
rt.execute("NS.Set('filterPublic', true)")
check("and works in every channel once the Options allow",
      ev("CHAT_IN(1, 'General - Elwynn Forest', SPAM, 'Gold Seller-X')") is True)

rt.execute("""
NS.Filters()[1].channels = nil NS.CompileFilters()
GetChannelList = function() return 1, "General", false, 2, "Trade", false end
NS.ShowWindow() ChairIgnoreWindow.tabs.filters._scripts.OnClick()
PAGE = ChairIgnoreWindow.pages.filters
PAGE.rows[1]._scripts.OnClick(PAGE.rows[1])
function TICK(i, on)
    local row = PAGE.channelRows[i]
    row:SetChecked(on)
    row._scripts.OnClick(row)
end
""")
check("Say and Yell come first, always",
      ev("PAGE.channelRows[1].channel") == "Say" and ev("PAGE.channelRows[2].channel") == "Yell")
rt.execute("TICK(2, true)")
check("ticking Yell keeps a filter to yell", ev("NS.Filters()[1].channels") == "Yell"
      and ev("CHAT('CHAT_MSG_YELL', SPAM, 'Gold Seller-X')") is True
      and ev("CHAT('CHAT_MSG_SAY', SPAM, 'Gold Seller-X')") is False
      and ev("CHAT_IN(2, 'Trade - City', SPAM, 'Gold Seller-X')") is False)
rt.execute("TICK(1, true)")
check("and Say with it", ev("NS.Filters()[1].channels") == "Say, Yell"
      and ev("CHAT('CHAT_MSG_SAY', SPAM, 'Gold Seller-X')") is True)
rt.execute("TICK(1, false) TICK(2, false)")
check("a checkbox for each channel you are in, with its number",
      ev("PAGE.channelRows[3].channel") == "General" and ev("PAGE.channelRows[4].channel") == "Trade"
      and "(2)" in str(ev("PAGE.channelRows[4].label:GetText()")))
check("none ticked: everywhere", ev("PAGE.channelRows[3]:GetChecked()") is False and ev("NS.Filters()[1].channels") is None)
rt.execute("TICK(4, true)")
check("ticking one applies at once, by name", ev("NS.Filters()[1].channels") == "Trade")
check("and the list names it after the filter",
      "(Trade)" in str(ev("PAGE.rows[1].cols[2]:GetText()")))
check("and the filter now works there only", ev("CHAT_IN(2, 'Trade - City', SPAM, 'Gold Seller-X')") is True
      and ev("CHAT_IN(1, 'General - Elwynn Forest', SPAM, 'Gold Seller-X')") is False)
rt.execute("TICK(3, true)")
check("a second tick adds it", ev("NS.Filters()[1].channels") == "General, Trade")
rt.execute("""
-- Another character, in other channels, with Trade now as channel 4.
GetChannelList = function() return 1, "General", false, 4, "Trade", false end
NS.Filters()[1].channels = "General, Trade, GuildRecruitment"
PAGE.FillChannels()
""")
check("it follows the name when the number changes",
      ev("PAGE.channelRows[4].channel") == "Trade" and ev("PAGE.channelRows[4]:GetChecked()") is True
      and "(4)" in str(ev("PAGE.channelRows[4].label:GetText()")))
check("a channel this character is not in stays listed, ticked",
      ev("PAGE.channelRows[5].channel") == "GuildRecruitment" and ev("PAGE.channelRows[5]:GetChecked()") is True
      and "not joined here" in str(ev("PAGE.channelRows[5].label:GetText()")))
rt.execute("TICK(5, false) TICK(3, false) TICK(4, false)")
check("unticking them all goes back to everywhere", ev("NS.Filters()[1].channels") is None)
rt.execute("""
GetChannelList = function() return 1, "General", false, 2, "Trade", false, 5, "LookingForGroup", false end
for _, f in ipairs(FRAMES) do
    if f._scripts.OnEvent then f._scripts.OnEvent(f, "CHANNEL_UI_UPDATE") end
end
""")
check("joining a channel adds its checkbox", ev("PAGE.channelRows[5].channel") == "LookingForGroup"
      and ev("PAGE.channelRows[5]:IsShown()") is True)
rt.execute("GetChannelList = function() return end PAGE.FillChannels()")
check("in no channels, it says so, with Say and Yell still there", ev("PAGE.noChannels:IsShown()") is True
      and ev("PAGE.channelRows[3]:IsShown()") is False and ev("PAGE.channelRows[1]:IsShown()") is True)

print("\nLong filters wrap and scroll")
rt, ev = fresh()
rt.execute("""
NS.ShowWindow() ChairIgnoreWindow.tabs.filters._scripts.OnClick()
PAGE = ChairIgnoreWindow.pages.filters
PAGE.rows[1]._scripts.OnClick(PAGE.rows[1])
BOX = PAGE.lineBoxes[2]
-- The client measures wrapped text; here a long line measures four lines tall.
rawset(BOX.measure, "GetStringHeight", function(self)
    return #(rawget(self, "_text") or "") > 60 and 56 or 14
end)
""")
check("the lines of words wrap", ev("PAGE.lineBoxes[1].measure ~= nil") is True)
rt.execute("""
GetChannelList = function() return 1, "General", false, 2, "Trade", false, 3, "LocalDefense", false end
PAGE.FillChannels()
""")
check("Say, Yell and three channels fit side by side without scrolling",
      ev("PAGE.channelCount") == 3 and ev("PAGE.scrollBar:IsShown()") is False)
check("a short line stays one line, with no scrollbar",
      ev("BOX.grownTo") == 22 and ev("PAGE.scrollBar:IsShown()") is False)
rt.execute("BOX:SetText(string.rep('cheapest, ', 12)) BOX._scripts.OnTextChanged(BOX)")
check("a long one grows its box a line at a time", ev("BOX.grownTo") == 64, ev("BOX.grownTo"))
check("and the editor scrolls to fit it", ev("PAGE.scrollMax") > 0 and ev("PAGE.scrollBar:IsShown()") is True)
rt.execute("BOX:SetText('cheap') BOX._scripts.OnTextChanged(BOX)")
check("shortened again, it shrinks and the scrollbar goes",
      ev("BOX.grownTo") == 22 and ev("PAGE.scrollBar:IsShown()") is False)
rt.execute("BOX:SetText('gold,\\nsilver') BOX._scripts.OnTextChanged(BOX)")
check("a line break typed in it becomes a space", ev("BOX:GetText()") == "gold, silver")
rt.execute("BOX:SetText(string.rep('cheapest, ', 12)) BOX._scripts.OnTextChanged(BOX) PAGE.save._scripts.OnClick()")
check("and a long line is saved whole", ev("#NS.Filters()[1].lines[2]") == 120)
rt.execute("PAGE.scrollBar:SetValue(20) PAGE.rows[2]._scripts.OnClick(PAGE.rows[2])")
check("choosing another filter starts back at the top", ev("PAGE.scrollBar:GetValue()") == 0)

print("\nThe Politics starter filter")
rt, ev = fresh()
rt.execute("for _, f in ipairs(NS.Filters()) do if f.name == 'Politics' then POLITICS = f end end")
check("it ships, switched off", ev("POLITICS ~= nil and POLITICS.enabled == false") is True)
def hides(text):
    rt.globals().MSG = text
    return rt.eval("NS.MatchFilter(MSG, POLITICS) ~= nil")
for text in ("Trump rally tonight", "vote for biden", "saw it on Fox News", "the GOP again",
             "Roe v Wade", "t r u m p", "gaza ceasefire", "Brexit ruined it"):
    check("hides: " + text, hides(text))
for text in ("anyone have a trumpet?", "we advance on the left side", "victory!", "history quest",
             "I woke up late", "back in the capital city", "party up for deadmines", "vote kick him",
             "the auction house tax is awful", "left or right at the fork?", "our guild president said"):
    check("lets through: " + text, not hides(text))

print("\nCase never matters")
rt, ev = fresh()
def matches(lines, text):
    rt.globals().MSG = text
    rt.execute("F = { lines = {} }")
    for i, l in enumerate(lines, 1):
        rt.globals().LINE = l
        rt.execute("F.lines[%d] = LINE" % i)
    return rt.eval("NS.MatchFilter(MSG, F) ~= nil")
check("a word typed in capitals matches it in lowercase", matches(["CHEAP GOLD"], "selling cheap gold"))
check("and a lowercase word matches it in capitals", matches(["cheap gold"], "SELLING CHEAP GOLD"))
check("in mixed case either side", matches(["ChEaP"], "cHeAp"))
check("a quoted word, any case", matches(['"TRUMP"'], "trump rally") and matches(['"trump"'], "TRUMP RALLY"))
check("a wildcard, any case", matches(["<*> RECRUITING"], "<Pals> recruiting"))
check("{LINK} in capitals still means any link", matches(["{LINK}"], "look |cff|Hitem:1|h[Sword]|h|r"))
check("accented capitals too", matches(["élection"], "ÉLECTION demain") and matches(["ÜBER"], "über alles"))
check("and Cyrillic", matches(["золото"], "ДЕШЁВОЕ ЗОЛОТО") and matches(["ДЕШЁВОЕ"], "дешёвое золото"))
check("the players list ignores case", ev("(NS.Add('Sewer Urchin')) ~= nil") is True
      and ev("NS.IsListed('SEWER URCHIN')") is True and ev("NS.IsListed('sewer urchin-homerealm')") is True)

print("\nThe Ignored chat tab")
CHAT_WINDOWS = """
-- The game's chat windows: 1 General, 2 Combat Log, and whatever is made.
CHAT_NAMES = { "General", "Combat Log" }
NUM_CHAT_WINDOWS = 10
MADE, IN_COMBAT = 0, false
local function Frame(i)
    local f = { lines = {} }
    function f:AddMessage(text) table.insert(self.lines, text) end
    _G["ChatFrame" .. i] = f
end
Frame(1) Frame(2)
function GetChatWindowInfo(i) return CHAT_NAMES[i] end
function InCombatLockdown() return IN_COMBAT end
function FCF_OpenNewWindow(name)
    MADE = MADE + 1
    table.insert(CHAT_NAMES, name)
    Frame(#CHAT_NAMES)
    return _G["ChatFrame" .. #CHAT_NAMES]
end
"""
rt, ev = fresh(CHAT_WINDOWS)
rt.execute("NS.Add('Pest Person') CHAT('CHAT_MSG_SAY', 'hello', 'Pest Person-HomeRealm')")
check("off out of the box: no tab is made", ev("MADE") == 0)
rt.execute("NS.Set('ignoredTab', true)")
check("turned on, an Ignored tab is made on the chat window", ev("MADE") == 1 and ev("CHAT_NAMES[3]") == "Ignored")
rt.execute("CHAT('CHAT_MSG_SAY', 'buy my gold', 'Pest Person-HomeRealm')")
line = str(ev("ChatFrame3.lines[1]"))
check("a hidden message is printed there, with who and why",
      "Pest Person" in line and "buy my gold" in line and "listed" in line, line)
check("and nowhere else", ev("#ChatFrame1.lines") == 0)
rt.execute("NS.Set('ignoredTab', false) NS.Set('ignoredTab', true)")
check("it is made once and reused after", ev("MADE") == 1)
rt.execute("PRINTED = {} SlashCmdList.CHAIRIGNORE('tab off') CHAT('CHAT_MSG_SAY', 'again', 'Pest Person-HomeRealm')")
check("tab off stops it", ev("NS.Get('ignoredTab')") is False and ev("#ChatFrame3.lines") == 1)

rt, ev = fresh(CHAT_WINDOWS + "IN_COMBAT = true")
rt.execute("NS.Set('ignoredTab', true)")
check("in combat it waits", ev("MADE") == 0)
rt.execute("IN_COMBAT = false EVENT('PLAYER_REGEN_ENABLED')")
check("and makes the tab when combat ends", ev("MADE") == 1)

rt, ev = fresh(CHAT_WINDOWS + """
CHAT_NAMES[3] = "Ignored" do local f = { lines = {} } function f:AddMessage(t) table.insert(self.lines, t) end ChatFrame3 = f end
""")
rt.execute("NS.Set('ignoredTab', true)")
check("a tab already named Ignored is used, not a second one", ev("MADE") == 0)

rt, ev = fresh(CHAT_WINDOWS + "FCF_OpenNewWindow = nil")
rt.execute("PRINTED = {} NS.Set('ignoredTab', true)")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("a client that cannot make one says to make a tab named Ignored", "make a chat tab named Ignored" in said, said)
rt.execute("""
CHAT_NAMES[3] = "Ignored" do local f = { lines = {} } function f:AddMessage(t) table.insert(self.lines, t) end ChatFrame3 = f end
NS.Add('Pest Person') CHAT('CHAT_MSG_SAY', 'hello', 'Pest Person-HomeRealm')
""")
check("and uses the one you make", ev("#ChatFrame3.lines") == 1)
rt.execute("PRINTED = {} SlashCmdList.CHAIRIGNORE('status')")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("status says it was found", "found (chat window 3)" in said, said)

print("\nSharing filters")
def with_libs(rt):
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/LibDeflate/LibDeflate.lua", "Libs/LibSerialize/LibSerialize.lua"):
        rt.execute("local f = assert(loadstring(...)) f()", open(lib, encoding="utf-8").read())
rt, ev = fresh()
with_libs(rt)
rt.execute("""
local f = NS.Filters()[1]
f.enabled = true f.blocked = 42 f.squeeze = true
SHARED = NS.ExportFilter(f)
""")
shared = ev("SHARED")
check("a filter exports as one line of text", isinstance(shared, str) and shared.startswith("!CI:1!")
      and "\n" not in shared, str(shared)[:40])
rt.execute("IMPORTED = NS.ImportFilter(SHARED)")
check("and imports back as a new filter", ev("#NS.Filters()") == 7 and ev("IMPORTED.name") == "Gold selling (2)")
check("with its words and squeeze setting",
      ev("IMPORTED.lines[1]") == ev("NS.Filters()[1].lines[1]") and ev("IMPORTED.squeeze") is True)
check("but switched off, with nothing counted", ev("IMPORTED.enabled") is False and ev("IMPORTED.blocked") == 0)
rt.execute("AGAIN = NS.ImportFilter(SHARED)")
check("a third copy is named (3)", ev("AGAIN.name") == "Gold selling (3)")
check("spaces and line breaks pasted around it do not matter",
      ev("NS.ImportFilter('  ' .. SHARED:sub(1, 20) .. '\\n' .. SHARED:sub(21) .. '  ') ~= nil") is True)
check("text that is not a filter is refused, not an error",
      ev("select(2, NS.ImportFilter('hello'))") == "that is not a ChairIgnore filter")
check("a damaged filter is refused",
      ev("select(2, NS.ImportFilter('!CI:1!notreallyafilter'))") == "the text is damaged")
check("nothing is exported without a filter picked", ev("select(2, NS.ExportFilter(nil))") == "pick a filter first")
rt.execute("NS.Filters()[2].channels = 'Trade' TRADE_ONLY = NS.ImportFilter(NS.ExportFilter(NS.Filters()[2]))")
check("a shared filter keeps its channels", ev("TRADE_ONLY.channels") == "Trade")
rt.execute("NS.Filters()[2].channels = 'Trade, 5' MIXED = NS.ImportFilter(NS.ExportFilter(NS.Filters()[2]))")
check("but not channel numbers, which were the sender's", ev("MIXED.channels") == "Trade")

print("\nSmarter filter words")
rt, ev = fresh()
LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
rt.globals().LINK = LINK
rt.execute("CRUDE = { lines = { '\"anal\"', '{link}' } }")
def hides(text):
    rt.globals().MSG = text
    return rt.eval("NS.MatchFilter(MSG, CRUDE) ~= nil")
check("{link} and a quoted word: 'anal [link]' is caught", hides("anal " + LINK))
check("spaced out", hides("a n a l " + LINK))
check("with dots", hides("a.n.a.l " + LINK))
check("with a look-alike letter", hides("4nal " + LINK))
check("in capitals", hides("ANAL " + LINK))
check("inside another word it is not: canal", not hides("the canal " + LINK))
check("nor analysis", not hides("analysis of " + LINK))
check("nor banal", not hides("so banal " + LINK))
check("without a link it is not", not hides("anal"))
check("and a plain [bracket] typed by hand is not a link", not hides("anal [Thunderfury]"))
check("the starter filter ships, switched off",
      ev("(function() for _, f in ipairs(NS.Filters()) do if f.name == 'Crude link jokes' then return f.enabled end end end)()") is False)
rt.execute("for _, f in ipairs(NS.Filters()) do if f.name == 'Crude link jokes' then f.enabled = true end end NS.CompileFilters()")
rt.globals().CHATLINE = "anal " + LINK
check("switched on, it hides the chat line",
      ev("CHAT('CHAT_MSG_CHANNEL', CHATLINE, 'Joke Teller-Otherrealm')") is True)
check("the test box says which line a miss lacks, with the new words too",
      (lambda: (rt.globals().__setitem__("MSG", "the canal " + LINK), ev("NS.MissingLine(MSG, CRUDE)"))[1])() == 1)

print("\nIgnoring the normal way")
rt, ev = fresh()
rt.execute("table.insert(GAME, 'Rude Test-OtherRealm') EVENT('IGNORELIST_UPDATE')")
check("the game's Ignore puts them on ChairIgnore's list", ev("NS.IsListed('Rude Test-OtherRealm')") is True)
check("and asks why", ev("ChairIgnoreReason:IsShown()") is True
      and "Rude Test-OtherRealm" in str(ev("ChairIgnoreReason.title:GetText()")), ev("ChairIgnoreReason.title:GetText()"))
rt.execute("ChairIgnoreReason.box:SetText('spams trade') ChairIgnoreReason.save._scripts.OnClick()")
check("Save keeps the reason", ev("NS.Find('Rude Test-OtherRealm').note") == "spams trade"
      and ev("ChairIgnoreReason:IsShown()") is False)
rt.execute("table.insert(GAME, 'One Test') table.insert(GAME, 'Two Test') EVENT('IGNORELIST_UPDATE')")
first = ev("ChairIgnoreReason.player")
rt.execute("ChairIgnoreReason.skip._scripts.OnClick()")
check("two at once are asked about one after the other",
      ev("ChairIgnoreReason:IsShown()") is True and ev("ChairIgnoreReason.player") != first)
rt.execute("ChairIgnoreReason:Hide()")
check("Skip leaves them listed without a reason",
      ev("NS.IsListed('One Test')") is True and ev("NS.Find('One Test').note") is None)
check("/ignore'd players are listed even with the game list sync switched off",
      (lambda: (rt.execute("NS.Set('syncGameList', false) table.insert(GAME, 'Three Test') EVENT('IGNORELIST_UPDATE')"),
                ev("NS.IsListed('Three Test')"))[1])() is True)
rt.execute("ChairIgnoreReason:Hide()")

# The game's right-click Ignore and /ignore both call C_FriendList. Seen as
# they happen, whether or not the list can be read back afterwards.
rt, ev = fresh()
rt.execute("C_FriendList.GetNumIgnores = function() return 0 end")  # unreadable list
rt.execute("C_FriendList.AddOrDelIgnore('Rude Person')")
check("the toggle waits for the server's answer", ev("NS.IsListed('Rude Person')") is False)
rt.execute("RUN_TIMERS()")
check("right-click Ignore on a two-word name lists them, list unreadable or not",
      ev("NS.IsListed('Rude Person')") is True and ev("ChairIgnoreReason.player") == "Rude Person-HomeRealm")
rt.execute("ChairIgnoreReason:Hide() NOW = NOW + 5 C_FriendList.AddOrDelIgnore('Rude Person') RUN_TIMERS()")
check("and doing it again (Unignore) takes them off", ev("NS.IsListed('Rude Person')") is False)
rt.execute("C_FriendList.AddIgnore('Other One')")
check("AddIgnore is seen too", ev("NS.IsListed('Other One')") is True)
rt.execute("ChairIgnoreReason:Hide() NS.Add('Mine Only')")
check("ChairIgnore's own sync calls are not asked about",
      ev("ChairIgnoreReason:IsShown()") is False)
rt.execute("PRINTED = {} SlashCmdList.CHAIRIGNORE('status')")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("status names the calls it watches", "C_FriendList.AddOrDelIgnore" in said, said)

rt, ev = fresh('GAME = { "Oldfoe Test" }', on=False)
rt.execute("NS.Set('enabled', true)")
check("names already on the game list at the first sync are not asked about",
      ev("NS.IsListed('Oldfoe Test')") is True and ev("ChairIgnoreReason == nil or not ChairIgnoreReason:IsShown()") is True)

rt, ev = fresh(on=False)
rt.execute("table.insert(GAME, 'Early Test') EVENT('IGNORELIST_UPDATE')")
check("off, the game's Ignore stays the game's", ev("NS.IsListed('Early Test')") is False)

print("\nCommands")
rt, ev = fresh()
rt.execute("SlashCmdList.CHAIRIGNORE('add Troll Test: being rude')")
check("/chair ignore add <name>: <reason>", ev("NS.Find('Troll Test').note") == "being rude")
rt.execute("SlashCmdList.CHAIRIGNORE('add Sewer Urchin: spams trade')")
check("with a two-word name", ev("NS.Find('Sewer Urchin').note") == "spams trade")
rt.execute("SlashCmdList.CHAIRIGNORE('add Notte Sure')")
check("and without a reason", ev("NS.IsListed('Notte Sure')") is True)
rt.execute("SlashCmdList.CHAIRIGNORE('remove troll test')")
check("/chair ignore remove <name>", ev("NS.Find('Troll Test')") is None)
rt.execute("SlashCmdList.CHAIRIGNORE('')")
check("/chair ignore on its own opens the page", ev("OPENED") is True)
rt.execute("PRINTED = {} SlashCmdList.CHAIRIGNORE('status')")
said = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("/chair ignore status says whether it is on", "turned on" in said and "on the list" in said, said)

print("\nOff")
rt, ev = fresh(on=False)
rt.execute("NS.ShowWindow()")
check("the page says ChairIgnore is off", ev("ChairIgnoreWindow.offNote:IsShown()") is True)
rt.execute("NS.Set('enabled', true)")
check("and stops saying so once it is on", ev("ChairIgnoreWindow.offNote:IsShown()") is False)

print("\nThe window")
rt, ev = fresh()
rt.execute("NS.Add('Listed Test', 'a note') NS.ShowWindow()")
check("builds and shows without an error", ev("ChairIgnoreWindow:IsShown()") is True)
rt.execute("for _, key in ipairs({ 'players', 'filters', 'options' }) do "
           "  for _, f in ipairs(FRAMES) do end end")
check("the Players tab lists them",
      ev("ChairIgnoreWindow.pages.players.rows[1].cols[1]:GetText()") == "Listed Test")
rt.execute("""
local page = ChairIgnoreWindow.pages.players
page.name:SetText('Typed Test') page.note:SetText('from the box') page.days:SetText('')
page.save._scripts.OnClick(page.save)
""")
check("Add from the boxes lists them", ev("NS.Find('Typed Test').note") == "from the box")
rt.execute("ChairIgnoreWindow.tabs.filters._scripts.OnClick() ChairIgnoreWindow.pages.filters.rows[1]._scripts.OnClick(ChairIgnoreWindow.pages.filters.rows[1])")
check("the Filters tab opens a filter in the editor",
      ev("ChairIgnoreWindow.pages.filters.nameBox:GetText()") == "Gold selling")
rt.execute("NS.Filters()[1].enabled = true NS.CompileFilters() NS.RefreshWindow()")
before = ev("ChairIgnoreWindow.pages.filters.rows[1].cols[3]:GetText()")
rt.execute("CHAT('CHAT_MSG_CHANNEL', 'cheapest gold here', 'Gold Seller-Otherrealm')")
check("a hit shows in the Hidden column straight away, window left open",
      before == "0" and ev("ChairIgnoreWindow.pages.filters.rows[1].cols[3]:GetText()") == "1",
      (before, ev("ChairIgnoreWindow.pages.filters.rows[1].cols[3]:GetText()")))
check("the same message in a second chat window is not counted again",
      (lambda: (rt.execute("CHAT('CHAT_MSG_CHANNEL', 'cheapest gold here', 'Gold Seller-Otherrealm', 555) "
                           "CHAT('CHAT_MSG_CHANNEL', 'cheapest gold here', 'Gold Seller-Otherrealm', 555)"),
                ev("ChairIgnoreWindow.pages.filters.rows[1].cols[3]:GetText()"))[1])() == "2")
rt.execute("""
local page = ChairIgnoreWindow.pages.filters
page.try:SetText('cheapest gold') page.try._scripts.OnTextChanged(page.try)
""")
check("and its test box says a match would be hidden",
      "Hidden" in str(ev("ChairIgnoreWindow.pages.filters.result:GetText()")))
rt.execute("""
local page = ChairIgnoreWindow.pages.filters
page.try:SetText('selling gold') page.try._scripts.OnTextChanged(page.try)
""")
check("and, for a miss, which line of words it lacks",
      "line 2" in str(ev("ChairIgnoreWindow.pages.filters.result:GetText()")),
      ev("ChairIgnoreWindow.pages.filters.result:GetText()"))
rt.execute("ChairIgnoreWindow.tabs.options._scripts.OnClick()")
check("the Options tab draws", ev("ChairIgnoreWindow.pages.options:IsShown()") is True)
entries = rt.eval("NS.SearchEntries()")
labels = [entries[i].label for i in range(1, len(entries) + 1)]
check("the menu's search can find ChairIgnore's tabs and options",
      "ChairIgnore: Chat filters" in labels and "Turn on ChairIgnore" in labels, labels)
rt.execute("for _, e in ipairs(NS.SearchEntries()) do if e.label == 'ChairIgnore: Chat filters' then e.open() end end")
check("and opening one goes to its tab", ev("ChairIgnoreWindow.pages.filters:IsShown()") is True)

print("")
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("All checks passed.")
