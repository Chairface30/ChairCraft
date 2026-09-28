# Does Chaircraft come up on its own? (needs: pip install lupa)
#   python .tests/boot_test.py
#
# Reported 2026-09-22: "the addon does not load itself until the main menu has
# been triggered." Every other suite here boots one part in isolation, which is
# exactly the arrangement that cannot catch this -- the parts are fine alone.
# This one loads the Suite files and ChairPlus together, in the order the TOC
# lists them, fires the events the client fires, and never opens the menu.
import io, os, re, sys
from lupa import lua51

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        failures.append(name)


# Reuse ChairPlus's harness rather than keeping a second copy of the client
# mock in step with it by hand.
_src = io.open(".tests/chairplus_test.py", encoding="utf-8").read()
HARNESS = re.search(r"HARNESS = r'''(.*?)'''", _src, re.S).group(1)

EXTRA = r'''
-- The camera module writes a CVar.
CVARS = {}
C_CVar = {
    RegisterCVar = function(n, d) if CVARS[n] == nil then CVARS[n] = d or "" end end,
    SetCVar = function(n, v) CVARS[n] = v end,
    GetCVar = function(n) return CVARS[n] end,
}

-- The TOC order for the files under test.
FILES = {
    "Suite/Namespace.lua",
    "ChairPlus/Core.lua",
    "ChairPlus/Config.lua",
    "ChairPlus/OSD.lua",
    "ChairPlus/Quests.lua",
    "ChairPlus/Gossip.lua",
    "ChairPlus/Vendor.lua",
    "ChairPlus/Loot.lua",
    "ChairPlus/FlightData.lua",
    "ChairPlus/Flight.lua",
    "ChairPlus/Camera.lua",
    "ChairPlus/Arrow.lua",
    "ChairPlus/Threat.lua",
    "ChairPlus/Commands.lua",
    "Suite/Hub.lua",
}

function LOAD_SUITE()
    SUITE = {}
    for _, file in ipairs(FILES) do
        local chunk, err = loadfile(file)
        if not chunk then error("load " .. file .. ": " .. tostring(err)) end
        chunk("Chaircraft", SUITE)
    end
    return SUITE
end

-- Exactly what the client sends, in order, with nothing else touched.
function LOGIN()
    FireEvent("ADDON_LOADED", "Chaircraft")
    FireEvent("PLAYER_LOGIN")
    FireEvent("PLAYER_ENTERING_WORLD")
    DRIVER_TICK()
end
'''


def boot(setup=""):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(HARNESS)
    rt.execute(EXTRA)
    rt.execute(setup)
    rt.execute("LOAD_SUITE()")
    rt.execute("LOGIN()")
    return rt


# Every feature ships off, so a login that proves the modules were applied has
# to come with them switched on -- which is also the ordinary case of a player
# whose saved file the client handed back.
FEATURES_ON = ("ChairPlusDB = { settings = { osd = true, quests = true, autoGossip = true,"
               " sellJunk = true, repairGear = true, fasterLoot = true, flight = true,"
               " maxCameraZoom = true } }")

print("A fresh install does nothing until asked")
stock = boot("""
MONEY = 1234
BAGS[0] = { size = 16, family = 0, items = {} }
""")
check("no display is shown",
      stock.eval("not (ChairPlusOSD and ChairPlusOSD:IsShown())") is True)
# Not even written: the player's own zoom (Blizzard's slider) is left alone.
check("the camera setting is not touched",
      stock.eval('CVARS["cameraDistanceMaxZoomFactor"]') is None,
      str(stock.eval('CVARS["cameraDistanceMaxZoomFactor"]')))
# Frames come up shown in the client (and in this harness), so anything not
# hidden on purpose would be on screen.
check("no threat meter is shown",
      stock.eval("not (ChairPlusThreat and ChairPlusThreat:IsShown())") is True)
check("no waypoint arrow is shown",
      stock.eval("not (ChairPlusArrow and ChairPlusArrow:IsShown() and ChairPlusArrow:GetAlpha() > 0)") is True)
check("/chair is still registered", stock.eval("SlashCmdList.CHAIRCRAFT ~= nil") is True)

print("")
print("Coming up without the menu")
rt = boot("""
MONEY = 1234
BAGS[0] = { size = 16, family = 0, items = {} }
""" + FEATURES_ON)

check("the menu was never built", rt.eval("ChairPlusPanel == nil") is True,
      "something opened the panel during login")

# The OSD is the visible proof the modules were applied.
check("the display exists after login alone",
      rt.eval("ChairPlusOSD ~= nil") is True,
      "ns.ApplyAll never ran at PLAYER_LOGIN")
check("and it is shown", rt.eval("ChairPlusOSD and ChairPlusOSD:IsShown()") is True)
text = rt.eval("(function() for _, f in ipairs(FRAMES) do local t = rawget(f, '_text')"
               " if t and t:find('|T', 1, true) then return t end end end)()")
check("and it has drawn its numbers", text is not None and "|T" in str(text),
      f"line: {text}")

# The automation, which has no frame to look at: check the events are hooked.
def hooked(event):
    return rt.eval(
        "(function() for _, f in ipairs(FRAMES) do local e = rawget(f, '_events')"
        f" if e and e['{event}'] then return true end end return false end)()")

for event, label in (("MERCHANT_SHOW", "vendor"), ("LOOT_READY", "faster loot"),
                     ("QUEST_DETAIL", "quests"), ("GOSSIP_SHOW", "gossip")):
    check(f"{label} is listening after login", hooked(event) is True,
          f"{event} not registered")

check("the camera CVar was applied",
      rt.eval('CVARS["cameraDistanceMaxZoomFactor"]') == 2.6,
      str(rt.eval('CVARS["cameraDistanceMaxZoomFactor"]')))

check("/chair is registered", rt.eval("SlashCmdList.CHAIRCRAFT ~= nil") is True)

print("")
print("Saved settings are read the ordinary way")
# The client puts the saved file into the global before ADDON_LOADED; nothing
# in the suite stands between that and the part reading it.
saved = boot("""
MONEY = 0
BAGS[0] = { size = 16, family = 0, items = {} }
ChairPlusDB = { settings = { osd = true, osdFontSize = 22 } }
""")
check("the saved setting reached ChairPlus",
      saved.eval('SUITE.ChairPlus.Get("osdFontSize")') == 22,
      str(saved.eval('SUITE.ChairPlus.Get("osdFontSize")')))
check("and the display came up", saved.eval("ChairPlusOSD and ChairPlusOSD:IsShown()") is True)
check("no CVar copy of the settings is written",
      not any(str(k).startswith("chaircraft") for k in saved.eval("CVARS").keys()))

print("")
print("A part that throws does not take the login with it")
broken = boot("""
MONEY = 0
BAGS[0] = { size = 16, family = 0, items = {} }
GetCVarBool = function() error("client said no") end
""" + FEATURES_ON)
check("the display still came up", broken.eval("ChairPlusOSD ~= nil") is True)
check("and /chair still works", broken.eval("SlashCmdList.CHAIRCRAFT ~= nil") is True)

print("")
print("Preset auras: who sees what")
# The four presets were all locked to DRUID, including the group holding them,
# so a hunter saw nothing and read it as the auras being lost.
import re as _re
presets = io.open("ChairAuras/Presets.lua", encoding="utf-8").read()

def block(aura_id):
    # Sliced rather than matched: the terminator is a newline plus indentation,
    # and building that pattern through a shell has bitten this session twice.
    start = presets.find('id     = "%s"' % aura_id)
    if start < 0:
        return ""
    end = presets.find(chr(10) + "    },", start)
    return presets[start:end if end > 0 else len(presets)]

def locked_to(aura_id):
    m = _re.search(r"class\s*=\s*\{\s*(\w+)\s*=\s*true", block(aura_id))
    return m.group(1) if m else None

check("the Buffs group is not locked to a class", locked_to("a1") is None,
      f"group locked to {locked_to('a1')} would hide every aura in it")
check("Well Fed is open to every class", locked_to("a4") is None,
      f"locked to {locked_to('a4')}")
check("Mark of the Wild stays druid", locked_to("a5") == "DRUID", str(locked_to("a5")))
check("thorns stays druid", locked_to("a6") == "DRUID", str(locked_to("a6")))
check("Aspect of the Hawk is hunter only", locked_to("a7") == "HUNTER",
      str(locked_to("a7")))
check("Aspect of the Hawk takes its icon from the spell, not a guessed id",
      "iconSpell  = 13165" in block("a7"), block("a7")[:120])
check("Aspect of the Hawk triggers on the buff name",
      'text = "Aspect of the Hawk"' in block("a7"))
check("it sits in the Buffs group", 'parent = "a1"' in block("a7"))

print()
if failures:
    print(f"{len(failures)} check(s) failed:")
    for name in failures:
        print(f"  - {name}")
    sys.exit(1)
print("All checks passed.")
