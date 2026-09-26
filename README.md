# Chaircraft

**One addon, one menu, one command.** Chaircraft brings together four quality-of-life addons (ChairPlus, ChairAuras, ChairSnack and ChairTracker) under a single `/chair` menu. It is built for the classic-era clients, including the Forever client that runs classic content on the modern engine.

Everything ships **switched off**. Nothing changes about your game until you turn it on, and each feature has its own switch.

- **Open the menu:** type `/chair`, click the chair on the minimap, or go to *Options > AddOns > Chaircraft*.
- **Commands:** `/chair help` lists every command.
- **Health check:** `/chair status` shows which parts loaded and what each one found on your client.

---

## The on-screen display (OSD)

One slim, draggable line of information. Each item has its own switch. Add up to 30 dividers between items, and set the text size, scale and background.

To change the order, drag items in the list on the menu's OSD page, or drag them left and right on the display itself while that page is open. A gold line shows where an item will land.

Nearly every item is interactive. **Hover** for detail and **click** to act:

| Item | Shows | Hover | Click |
|---|---|---|---|
| Money | Gold, silver, copper | Gold made or lost this session | Opens your bags |
| Free bag slots | General slots free (or free/total) | Every bag's free space | Opens your bags |
| Profession bags | Their slots, counted separately | Every bag's free space | Opens your bags |
| Durability | Your most worn piece, colored | Every piece, worst first | Opens your character |
| Ammo | What is left in the ammo slot | Ammo name and count | Opens your character |
| Soul shards | Shards carried (warlocks) | | Opens your bags |
| Coordinates | Your position on the zone map | | Opens the map |
| Zone name | Zone and subzone | Territory (friendly, contested...) and coordinates | Opens the map |
| XP and rested | Percent, XP/total, or both | XP to level, rested amount | |
| My threat on target | Your threat, colored as it climbs | Whether you are tanking | |
| Clock | Local or realm time, 12 or 24 hour | Both times | Opens the clock |
| Alarm | The in-game alarm and its message | | Opens the clock to set it |
| ChairTracker | Your reputation window, dropped down on hover | | |
| Frame rate and latency | fps and ms, colored when high | Home and world latency, the ten heaviest addons by memory | Frees unused addon memory |
| Session time | Time since you logged in (survives /reload) | When you logged in | |
| Gold per hour | Your rate, green up and red down, on its own counter | Time counted and gold made | Restarts the count |
| Gold this session | Green when up, red when down | Gold per hour | Starts the count again |
| Movement speed | Your speed now, 100% being a normal run | Run and swim speed | |
| Hunter pet | Happiness face, name, health | Damage and loyalty | Opens the pet window |
| New mail | A mail icon while mail is waiting | Who sent it | |
| Friends online | How many friends are online, Battle.net included | Who is online, and where | Opens the friends list |
| Guild online | How many guildmates are online (only in a guild) | Your guild, who is online, and where | Opens the guild window |
| Casino table | The running Chairface's Casino game and its host | | Opens the casino lobby |

### Other addons on the OSD

Chaircraft includes **LibDataBroker**, the standard that Titan Panel-style bars use. Any addon that publishes a data feed or a launcher appears at the end of the OSD item list, ready to tick on. Examples are BugSack's error count, Nova Instance Tracker's lockouts, and the Questie and AtlasLoot buttons. Their text updates live, and clicks and tooltips go straight to the addon.

Tick **Hide addons' minimap buttons** and an addon you put on the display loses its minimap button, so there is one way in, not two. Take the addon off the display, or untick the setting, and the button comes back. This works with any addon that uses LibDBIcon for its minimap button. Chairface's Casino always keeps its minimap button, since its OSD item only shows while a table is up.

Chaircraft also publishes its own launcher, so other bar addons can show a chair button that opens the menu.

---

## ChairPlus: automation and helpers

**Quests and gossip**
- Accept and turn in quests automatically: regular, daily and weekly each switchable.
- Safety checks refuse any turn-in that would spend gold, currency, reagents or bound items.
- Skip gossip windows that have only one option.
- Hold shift to handle any of this yourself.

**Invites and social**
- Accept group invites from friends and guildmates.
- **Invite on keyword.** A flyout keyword window beside the menu lets you add and remove keywords ("inv", "invite" and anything else).
  - Choose where keywords count: whispers, Battle.net whispers, guild chat, say and yell.
  - Choose whether the whole message must match.
  - Optionally turn a full party into a raid.
  - It never invites the same player twice in ten seconds, and never when you are not the leader.
- Decline duels and guild invites.
- Accept resurrection and summons.
- Hide the "Not enough rage" error spam.

**Merchants**
- Sell gray items on arrival, with the option to keep unbound gray gear. The total is reported in chat.
- Repair automatically, guild funds first if you like, with the cost reported in chat.

**Flight paths**
- A countdown while flying, and the flight time on each destination on the flight map.
- More than 2,000 routes, for both factions, are built in.
- Every flight is still timed in the background. A route the built-in list lacks, or has wrong, is learned the first time you fly it.
- `/chair plus flight new` lists what you have learned, formatted to paste straight into the list.

**Waypoint arrow**
- A large arrow pointing at the quest you selected or your map pin.
- Several styles, colors (by direction or custom), distance and quest name, size and opacity.

**Threat meter**
- Everyone's threat on your target as bars.
- Shows by group (solo, party, raid) and place (world, dungeons, raids, battlegrounds).
- Click-through options, class colors, pets.
- A warning, with optional sound, before you pull aggro.

**And more**
- Faster auto loot.
- Max camera zoom.
- Player filters (class, role, level) in the group finder.
- Hide the game's XP bar and status bar 2.
- Drag the character panel, bags, bank, auction house, professions, quest log, spellbook, talents, mail and other Blizzard windows by their headers. Their positions are remembered.
- Copy settings from another character.

## ChairAuras: buff, debuff and cooldown tracking

- Icons and bars for the auras and cooldowns you care about, with load conditions: class, zone, combat and more.
- Groups, sounds, and presets.
- Share an aura as a line of text with **Export** and **Import**.
- Auras are account-wide.

## ChairSnack: consumables at hand

- Configurable grids of consumables, built from what is actually in your bags.
- Automatic bars pick your best food and water, buff food, hearthstone-style recalls, pet food and ammo.
- A keybind mode, and a minimap button.

## ChairTracker: reputation

- A compact, draggable reputation tracker with colored progress bars, sorting and auto-hide.
- It can dock into the OSD and drop down when hovered.

---

## Installing

1. Put the `Chaircraft` folder in `World of Warcraft/<client>/Interface/AddOns/`.
2. If you still have the standalone ChairPlus, ChairAuras, SnapSnack or WOW Forever Tracker, disable them. Chaircraft warns you if they are running alongside it.
3. Log in and type `/chair`.

Saved settings from the standalone addons carry over: the saved-variable names are unchanged. Settings are per character, except auras, which are account-wide.

## For developers

The `.tests` folder has an offline harness for each part. It runs the real Lua files against a mock client with [lupa](https://pypi.org/project/lupa/):

```
python .tests/chaircraft_test.py
```

To rebuild the flight times from the source list, run `.tests/tools/import_flight_times.py`.

## Credits

By **Chairface**. LibStub, CallbackHandler-1.0 (Ace3, see `Libs/Ace3-LICENSE.txt`) and LibDataBroker-1.1 are embedded under their own licenses. Chaircraft is released under the GNU GPL v3; see `LICENSE`.
