"""Build ChairPlus/FlightData.lua from Chairface's flight times list.

    python .tests/tools/import_flight_times.py "path/to/flight timers.txt"

The list is one route per line, "seconds, -- Stop, Stop, Stop", under an
ALLIANCE or HORDE heading. Stops are named the way the flight map names them,
up to the first comma. Rerun this rather than editing FlightData.lua by hand.
"""
import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "ChairPlus" / "FlightData.lua"

# Names in the list that are not what the flight map calls the stop: other
# locales' names, and one spelling slip.
ALIASES = {
    "Baie-du-Butin": "Booty Bay",
    "Bourbe-à-brac": "Mudsprocket",
    "Burg Nethergarde": "Nethergarde Keep",
    "Nethergarde": "Nethergarde Keep",
    "Cabestan": "Ratchet",
    "Ratschet": "Ratchet",
    "Clairière de Griffebranche": "Talonbranch Glade",
    "Dunkelhain": "Darkshire",
    "Eisenschmiede": "Ironforge",
    "Kapelle des hoffnungsvollen Lichts": "Light's Hope Chapel",
    "Long-guet": "Everlook",
    "Mondfederfeste": "Feathermoon",
    "Mondlichtung": "Moonglade",
    "Reflet-de-Lune": "Moonglade",
    "Sanctuaire d'émeraude": "Emerald Sanctuary",
    "Seenhain": "Lakeshire",
    "Silbermond": "Silvermoon City",
    "Sturmwind": "Stormwind",
    "Süderstade": "Southshore",
    "Tarrens Mühle": "Tarren Mill",
    "Tristessa": "Tranquillien",
    "Unterstadt": "Undercity",
    "Thondoril River": "Thondroril River",
}


def parse(path):
    data = {"Alliance": {}, "Horde": {}}
    faction = None
    notes = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8-sig").splitlines(), 1):
        text = line.strip()
        if text.upper() in ("ALLIANCE", "HORDE"):
            faction = text.title()
            continue
        match = re.match(r"^(\d+)\s*,\s*--\s*(.+)$", text)
        if not match:
            continue
        if faction is None:
            sys.exit(f"line {number}: a route before any ALLIANCE/HORDE heading")
        seconds = int(match.group(1))
        stops_text = re.sub(r"\s*(\(|--).*$", "", match.group(2))
        stops = []
        for name in stops_text.split(","):
            name = ALIASES.get(name.strip(), name.strip())
            if name and (not stops or stops[-1] != name):
                stops.append(name)
        if len(stops) < 2:
            notes.append(f"line {number}: fewer than two stops, skipped")
            continue
        key = " > ".join(stops)
        routes = data[faction]
        if key in routes and routes[key] != seconds:
            notes.append(f"line {number}: {faction} {key} listed as {routes[key]} and {seconds}; kept {routes[key]}")
            continue
        routes[key] = seconds
    return data, notes


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(data):
    lines = [
        "-- ChairPlus FlightData.lua",
        "-- Flight times, in seconds at normal flight speed, gathered by Chairface.",
        "-- Written by .tests/tools/import_flight_times.py -- rerun that rather than",
        "-- editing here.",
        "--",
        "-- Keyed by faction, then the route: each stop's name as the flight map gives",
        "-- it, up to the first comma, source first, joined by \" > \". A time actually",
        "-- flown on this client is kept in ChairPlusDB.flights and wins over this",
        "-- table, so an entry that is wrong or missing here is learned the first time",
        "-- the route is flown.",
        "",
        "local suiteName, Chaircraft = ...",
        "local ns = Chaircraft.ChairPlus",
        "",
        "ns.flightData = {",
    ]
    for faction in ("Alliance", "Horde"):
        lines.append(f"    {faction} = {{")
        for key in sorted(data[faction]):
            lines.append(f"        [{lua_string(key)}] = {data[faction][key]},")
        lines.append("    },")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    data, notes = parse(sys.argv[1])
    write(data)
    for note in notes:
        print(note)
    print(f"{OUT.name}: {len(data['Alliance'])} Alliance, {len(data['Horde'])} Horde routes")
