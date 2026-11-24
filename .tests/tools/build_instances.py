"""Build ChairPlus/InstanceData.lua: where each dungeon and raid is entered, on
the zone maps, for the world map icons (InstanceMap.lua).

    python .tests/tools/build_instances.py <cache dir>

Positions come from the client's own tables on wago.tools, for the build the
Forever client runs, except where DOOR gives the door by hand. The tables are downloaded into <cache dir> the first time
and read from there after. This client has no Encounter Journal tables, which
is why its world map draws no entrances of its own.

  - Map: each instance and its corpse spot -- where a ghost is sent to walk
    back in, which is the entrance. Naxxramas has none (it floats over
    Plaguewood); its door is the area trigger listed in EXTRA.
    A few corpse spots are the portal well inside the outer door, and
    Forever's own dungeons have none at all; DOOR places those by hand.
  - UiMap / UiMapAssignment: each zone map's rectangle in world yards, to put
    a world position on a zone map. An entrance is listed on every zone map
    whose rectangle holds it, so it shows from next door too.

Instances entered in one place (Blackrock Mountain, Ahn'Qiraj) are one icon
that names them all (GROUPS). Rerun this rather than editing the Lua.
"""
import csv
import math
import os
import sys
import urllib.request
from pathlib import Path

BUILD = "1.60.1.70938"
OUT = Path(__file__).resolve().parents[2] / "ChairPlus" / "InstanceData.lua"
TABLES = ["Map", "UiMap", "UiMapAssignment", "AreaTrigger"]

# Instances with no corpse spot: map ID -> area trigger at the door.
EXTRA = {533: 4055}          # Naxxramas
# Map rows that are not a place to go in.
SKIP = {35, 44, 269}         # unused Stormwind prison, unused monastery, Caverns of Time (no entrance in Era)
# The door you walk to, on its zone map: map ID -> (uiMapID, x, y). For the
# old dungeons whose corpse spot is the portal deep inside or reads as the
# zone next door's, and for Forever's
# own dungeons, which have no corpse spot in the client at all (their
# entrances are server-side). Positions as ForeverDungeonJournal's entrance
# guide (Data/DungeonEntrances.lua) gives them.
DOOR = {
    36: (1436, 0.426, 0.717),    # Deadmines: the house in Moonbrook
    47: (1413, 0.429, 0.902),    # Razorfen Kraul: southern Barrens (its corpse spot sits on Thousand Needles' map)
    48: (1440, 0.145, 0.142),    # Blackfathom Deeps: the Zoram Strand (likewise Felwood's)
    70: (1418, 0.443, 0.120),    # Uldaman: the excavation cave in northern Badlands
    90: (1426, 0.244, 0.398),    # Gnomeregan: the front door, not the portal down the tunnel
    109: (1435, 0.695, 0.535),   # Sunken Temple: the Pool of Tears
    129: (1413, 0.500, 0.920),   # Razorfen Downs: far southern Barrens
    # Forever's dungeons
    2959: (1416, 0.085, 0.593),  # City of Dalaran: the sewer way in
    2970: (1434, 0.214, 0.279),  # The Drowned City: underwater, west of the Vile Reef
    2974: (1447, 0.386, 0.332),  # Blackmaw Hold: the old furbolg gate, northern Azshara
    2994: (1445, 0.753, 0.141),  # Alcaz Prison: Alcaz Island
    2998: (1437, 0.477, 0.562),  # Excavation Site: Wetlands
    2999: (1420, 0.634, 0.674),  # Ruins of Lordaeron
    3001: (1449, 0.481, 0.061),  # The Shaper's Terrace: above Marshal's Refuge
    3039: (2548, 0.375, 0.373),  # Krol'dok Stronghold: northern Riverglades
    3065: (1455, 0.435, 0.520),  # The Hall of Thanes: beneath Ironforge
}
# Instances entered in one place, one icon: map ID -> the place's name.
GROUPS = {
    229: "Blackrock Mountain", 230: "Blackrock Mountain", 409: "Blackrock Mountain", 469: "Blackrock Mountain",
    509: "Ahn'Qiraj", 531: "Ahn'Qiraj",
}
CONTINENTS = {"0": 1415, "1": 1414}


def load(cache, name):
    path = os.path.join(cache, name + ".csv")
    if not os.path.exists(path):
        url = f"https://wago.tools/db2/{name}/csv?build={BUILD}"
        req = urllib.request.Request(url, headers={"User-Agent": "chaircraft-build"})
        with urllib.request.urlopen(req) as r, open(path, "wb") as f:
            f.write(r.read())
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    cache = sys.argv[1]
    os.makedirs(cache, exist_ok=True)
    maps = load(cache, "Map")
    triggers = {int(t["ID"]): t for t in load(cache, "AreaTrigger")}
    uimaps = {int(u["ID"]): u for u in load(cache, "UiMap")}

    # Each zone map's rectangle (the whole-map assignment), on the two continents.
    rects = {}
    for r in load(cache, "UiMapAssignment"):
        ui = int(r["UiMapID"])
        u = uimaps.get(ui)
        if not u or u["Type"] != "3" or r["OrderIndex"] != "0" or r["MapID"] not in CONTINENTS:
            continue
        if (r["UiMin_0"], r["UiMin_1"], r["UiMax_0"], r["UiMax_1"]) != ("0", "0", "1", "1"):
            continue
        rects[ui] = (r["MapID"], float(r["Region_0"]), float(r["Region_1"]), float(r["Region_3"]), float(r["Region_4"]))

    # Every instance's entrance, in world yards.
    spots = []
    for m in maps:
        mid = int(m["ID"])
        if m["InstanceType"] not in ("1", "2") or mid in SKIP or m["MapName_lang"].startswith("<"):
            continue
        cont, x, y = m["CorpseMapID"], float(m["Corpse_0"]), float(m["Corpse_1"])
        home = None
        if mid in EXTRA:
            t = triggers[EXTRA[mid]]
            cont, x, y = t["ContinentID"], float(t["Pos_0"]), float(t["Pos_1"])
        if mid in DOOR:
            ui, fx, fy = DOOR[mid]
            home = ui
            cont, minX, minY, maxX, maxY = rects[ui]
            x, y = maxX - fy * (maxX - minX), maxY - fx * (maxY - minY)
        if cont not in CONTINENTS or (x == 0 and y == 0):
            continue
        spots.append({"id": mid, "name": m["MapName_lang"], "raid": m["InstanceType"] == "2",
                      "cont": cont, "x": x, "y": y, "home": home})

    # One place, one icon.
    groups, by_place = [], {}
    for s in sorted(spots, key=lambda s: s["id"]):
        place = GROUPS.get(s["id"])
        if place in by_place:
            by_place[place].append(s)
            continue
        groups.append([s])
        if place:
            by_place[place] = groups[-1]

    out = []
    for g in groups:
        x = sum(s["x"] for s in g) / len(g)
        y = sum(s["y"] for s in g) / len(g)
        on = []
        for ui, (cont, minX, minY, maxX, maxY) in sorted(rects.items()):
            if cont != g[0]["cont"]:
                continue
            # world X runs north and Y west; the map's x runs east and y south
            fx = (maxY - y) / (maxY - minY)
            fy = (maxX - x) / (maxX - minX)
            if 0 <= fx <= 1 and 0 <= fy <= 1:
                on.append((math.hypot(fx - 0.5, fy - 0.5), ui, fx, fy))
        if not on:
            print("on no zone map:", [s["name"] for s in g])
            continue
        # its home: the zone it was placed on, else the one it is most central in
        on.sort()
        home = next((s["home"] for s in g if s["home"]), on[0][1])
        name = GROUPS.get(g[0]["id"], g[0]["name"])
        out.append((name, g, on, home))

    lines = [
        "-- ChairPlus InstanceData.lua",
        "-- Where each dungeon and raid is entered, for the world map icons (InstanceMap.lua).",
        "-- Written by .tests/tools/build_instances.py from the client's own tables --",
        "-- rerun that rather than editing here.",
        "--",
        "--   name       what the icon is called",
        "--   instances  { name, raid } for each instance entered there",
        "--   home       the zone map it belongs to (placed on the continent from there)",
        "--   maps       [uiMapID] = { x, y }: on every zone map that shows it, as fractions",
        "",
        "local suiteName, Chaircraft = ...",
        "local ns = Chaircraft.ChairPlus",
        "",
        "ns.instanceEntrances = {",
    ]
    for name, g, on, home in sorted(out, key=lambda o: o[0]):
        lines.append(f"    {{ name = {lua_str(name)}, home = {home},")
        inst = ", ".join(f"{{ {lua_str(s['name'])}, {'true' if s['raid'] else 'false'} }}" for s in g)
        lines.append(f"      instances = {{ {inst} }},")
        pos = ", ".join(f"[{ui}] = {{ {fx:.4f}, {fy:.4f} }}" for _, ui, fx, fy in sorted(on, key=lambda o: o[1]))
        lines.append(f"      maps = {{ {pos} }} }},")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(out)} entrances -> {OUT}")


if __name__ == "__main__":
    main()
