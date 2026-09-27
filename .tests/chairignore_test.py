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
function UnitName(unit) if unit == "player" then return "Me Test" end return UNIT_NAMES and UNIT_NAMES[unit] end
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

FILES = ["ChairIgnore/Core.lua", "ChairIgnore/Filters.lua", "ChairIgnore/Window.lua"]

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
      ev("#NS.Filters()") == 4 and all(ev(f"NS.Filters()[{i}].enabled") is False for i in range(1, 5)))
check("off, a listed player's chat is left alone",
      ev("(NS.Add('Spammer Test'))") is not None and ev("CHAT('CHAT_MSG_SAY', 'hi', 'Spammer Test-HomeRealm')") is False)
check("off, nothing is put on the game's list", ev("#GAME") == 0)

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
check("one you delete stays deleted", ev("#NS.Filters()") == 3)

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

print("")
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("All checks passed.")
