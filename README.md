# Chaircraft

**One addon, one menu, one command.** Chaircraft brings together five quality-of-life parts (ChairPlus, ChairAuras, ChairSnack, ChairTracker and ChairIgnore) under a single `/chair` menu. It is made for **WoW Forever 1.60.1** (interface 16001) only, the client that runs classic content on the modern engine. Other versions of WoW are not supported.

Everything ships **switched off**. Nothing changes about your game until you turn it on, and each feature has its own switch.

- **Open the menu:** type `/chair`, click the chair on the minimap, or go to *Options > AddOns > Chaircraft*.
- **Find an option:** type part of its name in the search box at the top of the menu.
- **New here?** `/chair setup` opens a page of the most-used switches. `/chair whatsnew` lists what changed in this version.
- **Commands:** `/chair help` lists every command.
- **Health check:** `/chair status` shows which parts loaded and what each one found on your client.

---

## The on-screen display (OSD)

One slim, draggable line of information. Each item has its own switch. Add up to 30 dividers between items, and set the text size, scale, background and its opacity. Set a width past which items wrap onto a second line.

To change the order, drag items in the list on the menu's OSD page, or drag them left and right on the display itself while that page is open. A gold line shows where an item will land.

Nearly every item is interactive. **Hover** for detail and **click** to act. Some items do something else on a **right-click**:

| Item | Shows | Hover | Click |
|---|---|---|---|
| Money | Gold, silver, copper | Gold made or lost this session, every character's gold and the account total | Opens your bags; right-click prints every character's gold in chat |
| Free bag slots | General slots free (or free/total) | Every bag's free space | Opens your bags |
| Profession bags | Their slots, counted separately | Every bag's free space | Opens your bags |
| Durability | Your most worn piece, colored | Every piece, worst first, and the repair cost | Opens your character; right-click says it in chat |
| Ammo | What is left in the ammo slot | Ammo name and count | Opens your character |
| Soul shards | Shards carried (warlocks) | | Opens your bags |
| Coordinates | Your position on the zone map | | Opens the map |
| Zone name | Zone and subzone | Territory (friendly, contested...) and coordinates | Opens the map |
| XP and rested | Percent, XP/total, or both (hidden at the level cap) | XP to level, rested amount | |
| Watched reputation | The faction you watch and how far through its standing | Standing and what is left to the next | Opens the reputation window |
| My threat on target | Your threat, colored as it climbs | Whether you are tanking | |
| Clock | Local or realm time, 12 or 24 hour | Both times | Opens the clock; right-click switches 12 and 24 hour |
| Alarm | The in-game alarm and its message | | Opens the clock to set it |
| ChairTracker | Your reputation and skills window, dropped down on hover | | |
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
| Profession cooldowns | How many are ready, once one has been cast | Every character's, with the time left | |
| ChairIgnore | Its icon | How many are on your ignore list, and what it has hidden this session | Opens ChairIgnore |

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
- **Restock** ammo, reagents, food and water up to a count you set, in the merchant's own lots, within a per-visit spending limit and above a gold floor. Suggestions come from your equipped ammo and what in your bags the merchant sells.

**Profession cooldowns**
- Transmutes, Mooncloth and the Salt Shaker on every character, recorded when you cast them. An OSD item, an optional ready notice, and `/chair cooldowns`.

**Flight paths**
- A countdown while flying, and the flight time on each destination on the flight map.
- More than 2,000 routes, for both factions, are built in.
- Every flight is still timed in the background. A route the built-in list lacks, or has wrong, is learned the first time you fly it.
- `/chair plus flight new` lists what you have learned, formatted to paste straight into the list.

**Waypoint arrow**
- A large arrow pointing at the quest you selected or your map pin.
- Several styles, colors (by direction or custom), distance and quest name, size and opacity.

**Tooltips, mail and small automations**
- Sell prices on item tooltips, and item and spell IDs.
- An **Open all** button on the mailbox that takes every letter's gold and items. It skips cash-on-delivery and GM mail, and stops when your bags are full.
- Release in battlegrounds, skip cinematics, and dismount or stand up when an action needs it.

**Threat meter**
- Everyone's threat on your target as bars.
- Shows by group (solo, party, raid) and place (world, dungeons, raids, battlegrounds).
- Click-through options, class colors, pets.
- A warning, with optional sound, before you pull aggro.
- **Nameplate colors by aggro:** you have it, it is changing hands, a non-tank has it, or another tank has it, each in a color you pick.

**And more**
- Faster auto loot.
- Max camera zoom.
- Player filters (class, role, level) in the group finder.
- Hide the game's XP bar and status bar 2.
- Drag the character panel, bags, bank, auction house, professions, quest log, spellbook, talents, mail and other Blizzard windows by their headers. Their positions are remembered.
- On the **General** page: the minimap icon, copying settings from another character, and **backing up every setting** as one line of text to keep or paste onto another character.

## ChairAuras: buff, debuff and cooldown tracking (*Beta*)

Built to work like WeakAuras, as far as WoW Forever allows:

- **Triggers:** several per aura, combined with all, any or custom Lua.
  - Buffs, debuffs and cooldowns.
  - 22 built-in types: usable, range, casts, items, forms, threat, player status, chat and more.
  - Custom Lua triggers in WeakAuras' own shapes: status, event and state updater.
- **Displays:** icons, text, bars, textures, progress textures and models.
  - Extra texts written with WeakAuras' text codes.
  - Borders, backgrounds, glows and ticks.
  - Static and dynamic groups that grow in a line, a grid, a circle, or by custom code.
- **Conditions, actions and animations**, as on WeakAuras' tabs.
- **Load conditions:** class, race, zone, combat, group, role, instance, gear, encounter and more.
- **In combat,** this client hides aura data from addons. ChairAuras carries what it knew before the fight and draws cooldowns through the client's own duration objects.
- Custom Lua runs in a WeakAuras-style sandbox. Imported code waits for your approval.
- **Custom options** (`aura_env.config`) and **templates** made from your own spellbook.
- Share an aura as a line of text with **Export** and **Import**. Auras are account-wide.
- Libraries included: LibDeflate (zlib license) and LibSerialize (MIT).

## ChairSnack: consumables at hand

- Configurable grids of consumables, built from what is actually in your bags.
- Automatic bars pick your best food and water, buff food, hearthstone-style recalls, pet food and ammo.
- A keybind mode, and a minimap button.

## ChairTracker: reputation and skills

- A compact, draggable tracker for reputations and skills (weapon skills, Defense, professions and secondary skills) with colored progress bars, sorting and auto-hide. Skills are read at their real rank without opening the Skills window.
- It can dock into the OSD and drop down when hovered.

## ChairIgnore: one ignore list for every character, and chat filters

- **One list for the whole account**, with a note for each player and an optional number of days before they come off it. No 50-name limit.
- **Kept in step with the game's own ignore list** on each character: it fills the game's 50 slots from yours, newest first, and picks up anyone you ignore or unignore the normal way.
- **Hides chat from everyone on the list**, the ones past the game's 50 included.
- **Chat filters:** hide messages that contain a word from each of a few lines of words you write, with a box to try a message against a filter before you save it. `*` is a wildcard (`<*>` is any guild tag), each filter can be kept to channels you tick (Trade, LookingForGroup), `{link}` matches any link, and a word in `"quotes"` counts only on its own, even spaced out or with look-alike letters. Choose the kinds of chat they cover (channels, say and yell, whispers, group and guild), and friends and guildmates are spared. Each filter counts what it hides. It comes with five starter filters (gold selling, boost ads, guild recruiting, Thunderfury jokes, crude link jokes), all off.
- **Hidden tab:** the last 200 messages it hid, and why, with Show in chat and Unignore.
- **Share filters** as a line of text: Export and Import on the Chat filters tab.
- **Your normal Ignore goes to ChairIgnore:** ignore someone from the game's right-click menu or with `/ignore` and they are added to ChairIgnore's list, and a small window asks why.
- Commands: `/chair ignore add First Last: reason` (the reason is optional), `/chair ignore remove First Last`, `/chair ignore list`, `/chair ignore sync`, `/chair ignore status`.

---

## Installing

1. Put the `Chaircraft` folder in your WoW Forever client's `Interface/AddOns/` folder.
2. If you still have the standalone ChairPlus, ChairAuras, SnapSnack or WOW Forever Tracker, disable them. Chaircraft warns you if they are running alongside it.
3. Log in and type `/chair`.

Saved settings from the standalone addons carry over: the saved-variable names are unchanged. Settings are per character, except auras and ChairIgnore, which are account-wide.

## For developers

The `.tests` folder has an offline harness for each part. It runs the real Lua files against a mock client with [lupa](https://pypi.org/project/lupa/):

```
python .tests/chaircraft_test.py
```

To rebuild the flight times from the source list, run `.tests/tools/import_flight_times.py`.

## Credits

By **Chairface**. LibStub, CallbackHandler-1.0 (Ace3, see `Libs/Ace3-LICENSE.txt`) and LibDataBroker-1.1 are embedded under their own licenses. Chaircraft is released under the GNU GPL v3; see `LICENSE`.
