# Changelog

## 1.0: first release

Chaircraft 1.0 merges ChairPlus, ChairAuras, ChairSnack and ChairTracker into one addon, under one `/chair` menu and one entry in *Options > AddOns*, with the minimap's chair icon.

### Summary

- **One menu for everything.** `/chair` opens the Plus, OSD, Threat and Arrow pages, plus the Auras, Snack and Tracker windows. ChairSnack and ChairTracker no longer add their own pages to the game's options; the single Chaircraft entry opens the menu.
- **An interactive OSD.**
  - New items: session time, gold made or lost this session, movement speed, hunter pet, new mail, friends and guild online, and Chairface's Casino tables.
  - Nearly every item has a hover tooltip and a click action. Bags and money open your bags; zone and coordinates open the map; durability, ammo and pet open their windows; latency frees memory.
  - The movement speed tooltip explains what is making you faster or slower.
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
