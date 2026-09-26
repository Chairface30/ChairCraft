# Changelog

## 1.0.2

- **ChairTracker profession bars open their window** when clicked: Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring, Cooking, First Aid, Mining (through Smelting) and the rest that have one. Gathering and weapon skills have no window and stay unclickable.
- **WoW Forever 1.60.1 only.** The TOC declares interface 16001 alone; other versions of WoW list Chaircraft as out of date.

## 1.0.1

- **Grayed-out listings are hidden** in the group finder whenever the filters are on: delisted, or where your application was declined, timed out or failed, or you turned down the invite.
- **ChairAuras race condition** lists only the playable races: Human, Dwarf, Night Elf, Gnome, Orc, Undead, Tauren, Troll, and the two Skyborne (High Order and Windshaper).
- **Group finder role filter fixed.** It now reads the roles as the Classic Era finder reports them (lfgRoles, with "dps" for damage) and no longer counts an assigned role of "NONE". `/chair plus lfg` also shows nested fields now.
- **Arrange the OSD on the display itself.** While the menu is open on its OSD page, drag any item, or divider, left or right along the display. A gold line shows where it will land.
- **Hide addons' minimap buttons** (OSD page): an addon on the display loses its minimap button until it comes off again. Matched through LibDBIcon. Chairface's Casino keeps its button.
- **Friends and guild are two OSD items now**, each opening its own window: the friends list, and the guild window (or the friends window's guild tab on clients without one). Friends keeps the old item's setting and place in the order; Guild starts off.
- **Gold per hour** on the OSD, on a counter of its own: click it to start again without touching the session's total. The rate shows after the first minute.
- The movement speed tooltip shows just run and swim speed. Naming what changes your speed is gone: this client does not let an addon read it, so it could only guess.

## 1.0: first release

Chaircraft 1.0 merges ChairPlus, ChairAuras, ChairSnack and ChairTracker into one addon, under one `/chair` menu and one entry in *Options > AddOns*, with the minimap's chair icon.

### Summary

- **One menu for everything.** `/chair` opens the Plus, OSD, Threat and Arrow pages, plus the Auras, Snack and Tracker windows. ChairSnack and ChairTracker no longer add their own pages to the game's options; the single Chaircraft entry opens the menu.
- **An interactive OSD.**
  - New items: session time, gold made or lost this session, movement speed, hunter pet, new mail, friends and guild online, and Chairface's Casino tables.
  - Nearly every item has a hover tooltip and a click action. Bags and money open your bags; zone and coordinates open the map; durability, ammo and pet open their windows; latency frees memory.
- **Other addons on the OSD.** LibDataBroker is built in, so feeds and launchers from other addons (BugSack, Nova Instance Tracker, Questie, AtlasLoot...) can go on the line. Chaircraft publishes its own launcher too.
- **Invite on keyword.** A flyout keyword window beside the menu. It handles whispers, Battle.net whispers, guild and say/yell, whole-message or word matching, and turns a full party into a raid.
- **Flight times.** More than 2,000 hand-gathered routes for both factions are built in, looked up by stop name. Flights are still timed in the background, and `/chair plus flight new` lists routes to add to the list.
- **Hide the XP bar and status bar 2** with one switch on the OSD page.

### Changes in detail

- OSD item list scrolls and uses the window's full height; "Add divider" sits below the list; up to 30 dividers.
- OSD items can drag an unlocked display, so moving it is not blocked by the new click areas.
- Threat page: the warning sound's name stays on one line; the full name is on the Choose button's tooltip.
- Leatrix-derived flight data and all Leatrix references removed.
- US spelling throughout the interface.
- Offline test harness covers every new feature.
