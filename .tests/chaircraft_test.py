# Offline checks for Chaircraft (needs: pip install lupa).
#   python .tests/chaircraft_test.py
#
# The top-level run. It drives each part's own suite in .tests/ and then checks
# the things only the merge can get wrong: the TOC, the namespace isolation that
# stops the parts overwriting each other's shared table, the display renames,
# and the /chair router.
#
# Those four suites began as the standalone addons' own, re-run against the
# merged copies through a set of runtime patches -- that was the proof the merge
# changed no behaviour. The standalone folders were deleted on 2026-09-22, so
# there is no upstream left to compare against and the suites now live here.
import io, os, re, subprocess, sys, tempfile

SUITE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ADDONS = os.path.abspath(os.path.join(SUITE, ".."))
os.chdir(SUITE)

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        failures.append(name)


B = chr(92)

# --------------------------------------------------------------------------
# 1. The TOC
# --------------------------------------------------------------------------
print("TOC")
toc_lines = [l.strip() for l in io.open("Chaircraft.toc", encoding="utf-8")]
entries = [l for l in toc_lines if l and not l.startswith("#")]
paths = [e.replace(B, "/") for e in entries]

check("every listed file exists", all(os.path.exists(p) for p in paths),
      str([p for p in paths if not os.path.exists(p)]))

on_disk = set()
for root, _, files in os.walk("."):
    if ".tests" in root:
        continue
    for f in files:
        if f.endswith(".lua"):
            on_disk.add(os.path.relpath(os.path.join(root, f), ".").replace(B, "/"))
check("no Lua file is left out of the TOC", on_disk == set(paths),
      str(sorted(on_disk ^ set(paths))))

# Only the shared libraries come before it.
first = [x for x in paths if not x.startswith("Libs/")][0]
check("Namespace.lua loads first", first == "Suite/Namespace.lua", first)
check("the libraries are LibStub, then CallbackHandler, then LibDataBroker",
      paths[:3] == ["Libs/LibStub/LibStub.lua", "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
                    "Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua"], str(paths[:3]))
# Hub captures every part's slash handler, so it can only run once they have
# all registered.
check("Hub.lua loads last", paths[-1] == "Suite/Hub.lua", paths[-1])

def order(prefix):
    return [os.path.basename(p) for p in paths if p.startswith(prefix + "/")]

EXPECTED_ORDER = {
    "ChairPlus": ["Core.lua", "Config.lua", "OSD.lua", "StatusBars.lua", "Quests.lua", "Gossip.lua",
                  "Vendor.lua", "Restock.lua", "Cooldowns.lua", "Loot.lua", "FlightData.lua", "Flight.lua", "Camera.lua",
                  "Arrow.lua", "Threat.lua", "Nameplates.lua", "Tooltips.lua", "Mail.lua", "Social.lua", "Invite.lua", "LFG.lua", "Movers.lua", "Backup.lua", "Commands.lua"],
    "ChairAuras": ["Core.lua", "Presets.lua", "Database.lua", "Load.lua",
                   "AuraEnvironment.lua", "Engine.lua", "CustomTrigger.lua", "Triggers.lua", "Text.lua", "Conditions.lua", "Actions.lua", "Display.lua", "Regions.lua", "SubRegions.lua", "Animations.lua", "Icons.lua", "Share.lua", "Templates.lua",
                   "Sounds.lua", "Config.lua", "Probe.lua", "Commands.lua"],
    "ChairSnack": ["Core.lua", "Database.lua", "ItemData.lua", "Items.lua",
                   "AutoBar.lua", "BuffFood.lua", "Grid.lua", "Config.lua",
                   "Bootstrap.lua"],
    "ChairTracker": ["Config.lua", "WOWFTracker.lua", "Options.lua"],
    "ChairIgnore": ["Core.lua", "Filters.lua", "Tab.lua", "Window.lua"],
}
for part, expected in EXPECTED_ORDER.items():
    check(f"{part} load order preserved", order(part) == expected, str(order(part)))

sv = " ".join(l for l in toc_lines if l.startswith("## SavedVariables"))
# Deliberately NOT renamed with the display names: these are the keys the
# client saves under, and the tracker's is the project's canary.
for name in ("ChairPlusDB", "ChairAurasDB", "SnapSnackDB",
             "WOWFTrackerAccountDB", "WOWFTrackerDB", "ChairIgnoreDB", "ChairIgnoreCharDB"):
    check(f"{name} still declared", name in sv)

# Built for WoW Forever 1.60.1 and nothing else.
iface = [l for l in toc_lines if l.startswith("## Interface:")]
check("the TOC is for WoW Forever 1.60.1 (16001) only",
      iface == ["## Interface: 16001"], str(iface))

# --------------------------------------------------------------------------
# 2. Namespace isolation
# --------------------------------------------------------------------------
print("")
print("Namespace isolation")
REBOUND = {"ChairPlus": 24, "ChairAuras": 22, "ChairSnack": 9, "ChairIgnore": 4}
for part, expected in REBOUND.items():
    bound, raw = 0, []
    for f in sorted(os.listdir(part)):
        if not f.endswith(".lua"):
            continue
        s = io.open(os.path.join(part, f), encoding="utf-8").read()
        if f"local ns = Chaircraft.{part}" in s or f"local addon = Chaircraft.{part}" in s:
            bound += 1
        if re.search(r"^local addonName, (ns|addon) = \.\.\.", s, re.M):
            raw.append(f)
    check(f"every {part} file rebound to its own table", bound == expected,
          f"{bound}/{expected}")
    check(f"no {part} file takes the raw vararg table", not raw, str(raw))

# ChairTracker never used the vararg header at all -- it carries its own
# globals, which were already unique, so its files needed no rebinding.
tracker = "".join(io.open(os.path.join("ChairTracker", f), encoding="utf-8").read()
                  for f in os.listdir("ChairTracker") if f.endswith(".lua"))
check("ChairTracker still uses its own globals", "WOWFTrackerNS" in tracker)

grid = io.open("ChairSnack/Grid.lua", encoding="utf-8").read()
check("minimap texture points into the suite folder",
      "AddOns" + B + B + "Chaircraft" + B + B + "ChairSnack" + B + B + "minimap" in grid)

# --------------------------------------------------------------------------
# 3. Display renames
# --------------------------------------------------------------------------
print("")
print("Display names")
lua_files = [os.path.join(base, f)
             for base, _, files in os.walk(".") if ".tests" not in base
             for f in files if f.endswith(".lua")]

stale = []
for p in lua_files:
    for i, line in enumerate(io.open(p, encoding="utf-8"), 1):
        if "WOW Forever Tracker" in line:
            stale.append(f"{p}:{i}")
        # Visible strings only: frame names built from addonName are meant to
        # keep the old value, because keybindings are attached to them.
        for pat in ('SetText("SnapSnack")', 'panel.name = "SnapSnack"',
                    'AddLine("SnapSnack"'):
            if pat in line:
                stale.append(f"{p}:{i}")
check("no stale display names left", not stale, str(stale[:6]))

grid_src = io.open("ChairSnack/Grid.lua", encoding="utf-8").read()
check("the minimap icon is titled Chaircraft",
      'AddLine("Chaircraft"' in grid_src)
check("and opens the suite menu rather than one part's config",
      "plus.TogglePanel" in grid_src, "left click still goes to OpenConfig")

check("ChairSnack keeps its addonName for frame names",
      'local addonName = "SnapSnack"' in
      io.open("ChairSnack/Core.lua", encoding="utf-8").read())

# Old slash commands may survive only on the registration lines, which Hub.lua
# clears at load. Anywhere else is help text that would send people to a
# command that no longer exists.
leftover = []
for p in lua_files:
    for i, line in enumerate(io.open(p, encoding="utf-8"), 1):
        if line.lstrip().startswith("SLASH_"):
            continue
        if re.search(r'(?<!/)/(ss|ca|cp|wowft|snack)\b', line):
            leftover.append(f"{p}:{i} {line.strip()[:60]}")
check("no help text points at a removed command", not leftover, str(leftover[:6]))

# --------------------------------------------------------------------------
# 4. Each part's suite
# --------------------------------------------------------------------------
# These used to be re-run from the standalone addon folders with a set of
# runtime patches, which proved the merge had not changed their behaviour.
# Those folders were deleted on 2026-09-22, so there is no upstream left to
# compare against and the patched copies now live here permanently. Same
# coverage, one less moving part -- and no silent loss when a folder goes away.
SUITES = ["chairplus", "chairauras", "chairsnack", "chairtracker", "chairignore", "boot"]

for stem in SUITES:
    print("")
    print(f"{stem}")
    path = os.path.join(SUITE, ".tests", f"{stem}_test.py")
    if not os.path.exists(path):
        check(f"{stem} suite present", False, path)
        continue
    proc = subprocess.run([sys.executable, path], cwd=SUITE,
                          capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    bad = [l for l in out.splitlines() if "FAIL" in l or "Traceback" in l]
    check(f"{stem} suite passes",
          proc.returncode == 0 and not bad,
          ("\n      " + "\n      ".join((bad or out.splitlines())[-12:])))

# --------------------------------------------------------------------------
# 5. The router
# --------------------------------------------------------------------------
# New code that none of the four inherited suites covers. ChairPlus is stubbed
# rather than loaded: what is under test is the routing, and the panel itself
# is covered by the ChairPlus suite above.
from lupa import lua51

ROUTER_HARNESS = r'''
FRAMES = {}
local Mock
local function Method(k)
    return setmetatable({}, {
        __index = function(_, key)
            if type(key) == "string" and key:match("^%u") then return Method(key) end
        end,
        __call = function(_, self, ...)
            if type(self) ~= "table" then return Mock() end
            if k == "SetScript" then
                local name, fn = ...
                local s = rawget(self, "_scripts") or {}
                s[name] = fn
                rawset(self, "_scripts", s)
            elseif k == "RegisterEvent" then
                rawset(self, "_event", (...))
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
function CreateFrame() return Mock() end
UIParent = Mock()
PRINTED = {}
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(PRINTED, table.concat(parts, " "))
end

CALLS = {}
function LOAD(withTracker)
    CALLS = {}
    PRINTED = {}
    -- Each part as the client would have it just before Hub.lua loads: a
    -- handler in SlashCmdList and its SLASH_ globals.
    SlashCmdList = {
        CHAIRPLUS   = function(a) table.insert(CALLS, "plus:" .. tostring(a)) end,
        CHAIRAURAS  = function(a) table.insert(CALLS, "auras:" .. tostring(a)) end,
        SNAPSNACK   = function(a) table.insert(CALLS, "snack:" .. tostring(a)) end,
        WOWFTRACKER = function(a) table.insert(CALLS, "tracker:" .. tostring(a)) end,
        -- ChairIgnore registers a handler but no SLASH_ globals of its own.
        CHAIRIGNORE = function(a) table.insert(CALLS, "ignore:" .. tostring(a)) end,
    }
    SLASH_CHAIRPLUS1, SLASH_CHAIRPLUS2 = "/chairplus", "/cp"
    SLASH_CHAIRAURAS1, SLASH_CHAIRAURAS2 = "/ca", "/chairauras"
    SLASH_SNAPSNACK1, SLASH_SNAPSNACK2, SLASH_SNAPSNACK3 = "/ss", "/snack", "/snapsnack"
    SLASH_WOWFTRACKER1, SLASH_WOWFTRACKER2 = "/wowft", "/wowftracker"

    SUITE = {}
    local chunk = assert(loadfile("Suite/Namespace.lua"))
    chunk("Chaircraft", SUITE)

    SUITE.ChairPlus.OpenPanel = function(tab)
        table.insert(CALLS, "open:plus:" .. tostring(tab)); return true
    end
    SUITE.ChairPlus.TogglePanel = function(tab)
        table.insert(CALLS, "toggle:plus:" .. tostring(tab)); return true
    end
    SUITE.ChairAuras.Config = { Open = function() table.insert(CALLS, "open:auras") end }
    SUITE.ChairSnack.OpenConfig = function() table.insert(CALLS, "open:snack") end
    SUITE.ChairIgnore.ShowWindow = function() table.insert(CALLS, "open:ignore") end
    if withTracker then
        WOWFTrackerNS = {
            ToggleOptions = function() table.insert(CALLS, "toggle:tracker") end,
            ShowOptions = function() table.insert(CALLS, "open:tracker") end,
        }
    else
        WOWFTrackerNS = nil
    end

    chunk = assert(loadfile("Suite/Hub.lua"))
    chunk("Chaircraft", SUITE)
    return SUITE
end
function RUN(cmd) SlashCmdList.CHAIRCRAFT(cmd) end
'''

print("")
print("Router")
rt = lua51.LuaRuntime(unpack_returned_tuples=True)
rt.execute(ROUTER_HARNESS)
rt.execute("LOAD(true)")

check("five parts registered", rt.eval("#SUITE.parts") == 5)

# The version shown in the menu and /chair status is the TOC's, not a copy.
toc_version = [l.split(":", 1)[1].strip() for l in toc_lines if l.startswith("## Version:")][0]
vrt = lua51.LuaRuntime(unpack_returned_tuples=True)
vrt.globals().TOC_VERSION = toc_version
vrt.execute('''
C_AddOns = { GetAddOnMetadata = function(name, field)
    if name == "Chaircraft" and field == "Version" then return TOC_VERSION end
end }
SUITE = {}
assert(loadfile("Suite/Namespace.lua"))("Chaircraft", SUITE)
''')
check("the version is read from the TOC", vrt.eval("SUITE.version") == toc_version,
      (vrt.eval("SUITE.version"), toc_version))
src = io.open("Suite/Namespace.lua", encoding="utf-8").read() + io.open("ChairPlus/Core.lua", encoding="utf-8").read()
check("and no file keeps a copy of its own", not re.search(r'version\s*=\s*"[0-9]', src))
whats_new = io.open("Suite/WhatsNew.lua", encoding="utf-8").read()
check("What's new has an entry for the TOC's version (add one each release)",
      '["' + toc_version + '"] = {' in whats_new, toc_version)
check("namespace hands out separate tables",
      rt.eval("SUITE.ChairPlus ~= SUITE.ChairSnack "
              "and SUITE.ChairPlus ~= SUITE.ChairAuras") is True)
check("/chair is registered", rt.eval("SlashCmdList.CHAIRCRAFT ~= nil") is True)

# The old commands are gone, handlers captured first.
for key in ("CHAIRPLUS", "CHAIRAURAS", "SNAPSNACK", "WOWFTRACKER"):
    check(f"{key} command removed", rt.eval(f"SlashCmdList.{key} == nil") is True)
check("SnapSnack's three SLASH_ globals cleared",
      rt.eval("SLASH_SNAPSNACK1 == nil and SLASH_SNAPSNACK2 == nil "
              "and SLASH_SNAPSNACK3 == nil") is True)
check("handlers were captured before removal",
      rt.eval("SUITE.FindPart('snack').Handler ~= nil") is True)

def calls(*cmds):
    rt.execute("CALLS = {}")
    for c in cmds:
        rt.execute(f'RUN("{c}")')
    return [str(v) for v in rt.eval("CALLS").values()]

check("bare /chair opens the menu on Plus",
      calls("") == ["toggle:plus:plus"], str(calls("")))
check("/chair osd opens the OSD page",
      calls("osd") == ["toggle:plus:osd"], str(calls("osd")))
check("/chair osd unlock forwards as 'osd unlock'",
      calls("osd unlock") == ["plus:osd unlock"], str(calls("osd unlock")))

check("/chair auras opens auras settings",
      calls("auras") == ["open:auras"], str(calls("auras")))
check("/chair snack opens snack settings",
      calls("snack") == ["open:snack"], str(calls("snack")))
check("/chair tracker opens tracker SETTINGS, not its window",
      calls("tracker") == ["open:tracker"], str(calls("tracker")))

check("/chair snack scan forwards verbatim",
      calls("snack scan") == ["snack:scan"], str(calls("snack scan")))
check("/chair tracker toggle still reaches the window",
      calls("tracker toggle") == ["tracker:toggle"], str(calls("tracker toggle")))

for alias, expected in (("ss", "open:snack"), ("ca", "open:auras"),
                        ("cp", "open:plus:plus"), ("tr", "open:tracker"),
                        ("rep", "open:tracker"), ("plus", "open:plus:plus")):
    got = calls(alias)
    check(f"alias '{alias}' resolves", got == [expected], f"{got} != [{expected}]")

check("case does not matter", calls("AURAS") == ["open:auras"], str(calls("AURAS")))

# With the menu there, a part's settings open inside it rather than alone.
rt.execute("""
SUITE.ChairPlus.OpenPage = function(part)
    table.insert(CALLS, "page:" .. part.key)
    return true
end
""")
check("/chair auras opens inside the menu when it can",
      calls("auras") == ["page:chairauras"], str(calls("auras")))
check("/chair tracker too", calls("tracker") == ["page:chairtracker"], str(calls("tracker")))
check("/chair ignore too", calls("ignore") == ["page:chairignore"], str(calls("ignore")))
check("and /chair ignore add is forwarded to ChairIgnore",
      calls("ignore add Troll") == ["ignore:add Troll"], str(calls("ignore add Troll")))
rt.execute("SUITE.ChairPlus.OpenPage = function() return false end")
check("and falls back to the part's own window when the menu cannot",
      calls("snack") == ["open:snack"], str(calls("snack")))
rt.execute("SUITE.ChairPlus.OpenPage = nil")

check("/chair arrow reaches ChairPlus", calls("arrow unlock") == ["plus:arrow unlock"],
      str(calls("arrow unlock")))
check("/chair threat reaches ChairPlus", calls("threat") == ["plus:threat"],
      str(calls("threat")))

rt.execute("CALLS = {} PRINTED = {} RUN('nonsense')")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("an unknown part is reported, not thrown",
      "No part called" in printed and "/chair auras" in printed, printed[:160])

rt.execute("PRINTED = {} SUITE.Report()")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("status reports all five loaded",
      printed.count("|cff55ff55loaded|r") == 5, printed)

# A part that failed to load must be reported, not thrown.
rt.execute("LOAD(false)")
rt.execute("CALLS = {} PRINTED = {} RUN('tracker')")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("a missing part says so instead of erroring",
      "did not answer" in printed and "ChairTracker" in printed, printed[:160])
rt.execute("PRINTED = {} SUITE.Report()")
printed = "\n".join(str(v) for v in rt.eval("PRINTED").values())
check("status marks the missing one", "missing" in printed, printed)

print()
if failures:
    print(f"{len(failures)} check(s) failed:")
    for name in failures:
        print(f"  - {name}")
    sys.exit(1)
print("All checks passed.")
