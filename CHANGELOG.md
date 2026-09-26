# Changelog

## Unreleased: ChairAuras toward WeakAuras (phases 1 to 9)

- **More load conditions** (phase 9), grouped on the Load tab. Lists are typed with commas.
  - You: character name (or Name-Realm), realm, guild, faction, effective level, have a pet, flagged for PvP.
  - Group: group size (solo counts as 1), group leader, group role, raid role (main tank, main assist).
  - Where: instance type, instance size, difficulty, zone or instance ID. `/chair auras where` shows the IDs where you stand.
  - Gear: item equipped, item not equipped (by name or ID), item type equipped (Shields, Daggers...).
  - Spells: spell not known.
  - Encounter: in a boss encounter, and which encounter IDs.
  - As before, a condition this client cannot answer never hides an aura.

- **Animations** (phase 8), on a new Animations tab, in WeakAuras' own shape:
  - **Start** plays as an aura comes up, **main** loops while it shows, **finish** plays as it goes. Nothing animates at login or after a reload.
  - Each one is none, one of WeakAuras' presets, or custom:
    - Start presets: slide in from any side, fade in, grow, shrink, spiral, bounce, star shake.
    - Main presets: shake, spin, flip, wobble, pulse, flash, rotate either way, spiral, orbit, bounce.
    - Finish presets: the start presets, played the other way.
  - Custom animations: a duration (or a share of the aura's own timer, for main), easing, and any of fade, move, zoom, rotate and color. Each follows one of WeakAuras' paths, or a Lua function of your own.
  - A finishing aura keeps its place in a dynamic group until it ends, then the group closes up.
  - **Play it** previews the chosen animation.
- **New ways to draw an aura** (phase 7), picked from "Draw it as":
  - **Texture**: a picture from the game's files, a file path or ID, or the aura's own icon. It can be colored, turned, mirrored, and blended normally or additively.
  - **Progress texture**: a texture that fills with the timer. As a bar it fills in any of four directions; round, it sweeps like a cooldown. Health and power, and cooldowns in combat, are drawn the same way bars draw them.
  - **Model**: a unit's model, or one by display or file ID, with facing and zoom.
- **More icon and bar options:**
  - Icons: zoom, reverse swipe, swipe edge, and the countdown numbers on or off.
  - Bars: a bar texture (including LibSharedMedia ones), background color and opacity, fill direction, a spark, and inverse.
- **Sub-regions** on every aura:
  - a border and a background
  - **any number of extra texts**, each placed, sized, styled and written with the text codes
  - **ticks** on bars and progress textures, at seconds left or at a percent
  - **a glow while it shows**, in three styles: pulse, pixel (lines running round the edge) or shine (dots). A condition's glow uses the same style.
- **Dynamic groups:**
  - They can grow round a **circle**, with a radius, start angle and arc.
  - **Custom growth and custom sort** are Lua functions in WeakAuras' signatures.
  - A custom state updater's states each get **a region of their own** inside a group (WeakAuras' clones).
  - Imported growth, sort and animation code waits for approval like the rest.
- `/chair auras probe` also checks the swipe-texture and model methods these use, and whether the picker's texture files load on this client.

- **Actions** (phase 6), WeakAuras-style, on the Actions tab:
  - When it comes up and when it goes away: the sound as before, plus a chat message (text codes work; to you, say, party, raid, guild or yell) and custom code.
  - Glow another frame while it shows: the action button carrying the trigger's spell, your player, target, focus or pet frame, or any frame by name. The glow is anchored over the frame, not made part of it, so protected frames are left alone.
  - Custom code on init (once, and again after an edit), on load and on unload.
  - Imported action code waits for approval like all custom code.
- **Conditions** (phase 5), WeakAuras-style, on a new Conditions tab:
  - A check on any trigger's value -- active, stacks, time left, duration, name, whether it is assumed in combat, or any value a custom trigger sets -- with operators to suit (>= <= = for numbers and time, is / contains for names, true / false). Several checks combine as all-of or any-of, or write your own custom Lua check.
  - Changes while it holds: transparency, color, greyed out, glow (a pulsing border -- this client has no action-button glow), size, or replacement text. Once, as it starts: play a sound, a chat message (to you, say, party, raid or guild) or custom code.
  - Later conditions override earlier ones; "else if" links a condition to the one above; conditions reorder with up and down.
  - A value this client keeps secret never matches. Imported condition code waits for approval like all custom code.
  - Rules in the shape removed on 2026-09-25 are still dropped on load.
- **A spell trigger now finds the buff that spell gives**, even when the buff has a different ID (Plainsrunning is cast as 1259918 and sits on you as 1299038): a buff wearing the chosen spell's name counts. Stack settings and %s work on it.
- **The stack setting reads the same stack count %s shows**; it looked at only one of the fields a client can put it in.
- **A warning in the editor** when an aura set to 'Show when missing' asks for %s, %t or %p -- it shows only while the buff is missing, so those are always empty.
- **A bigger ChairAuras window, resizable from its corner.** It opens as tall as fits a 1920x1080 screen, the list and editor stretch with it, and the size is remembered.
- **Fixed: resizing ChairAuras inside the Chaircraft menu split it in two** -- the menu's background stayed behind as a separate movable window, with the controls on a panel that would not move. There the grip now resizes the menu itself, and a page is pinned to the menu by both corners, so it all moves and sizes as one.
- **ChairTracker on the display turns its auto-hide on**, at 2 seconds, if it was off. It happens once each time the tracker is put on the display, so turning auto-hide back off afterwards is kept, and a delay you set yourself is left alone.
- **Drag auras in the list to reorder or regroup them**: the top of a row drops above it, the bottom below it, the middle of a group inside it, and below the last row takes it to the end outside every group. A gold line shows where it will land, and the list scrolls while you drag near its edge.
- **The window is now titled ChairAuras *Beta*** while it grows toward WeakAuras.
- **Text codes** (phase 4), WeakAuras-style: %i draws the icon, %c is custom Lua text (%c1, %c2 for several values), %stacks or %{field} shows any value of the trigger's state, %2.p reads trigger 2. %t and %p keep ChairAuras' meaning (time left, per cent left) unless the aura is set to WeakAuras codes, where %p is time left and %t the full duration. Time can be shown auto, as a clock or in seconds, with 0-3 decimals.
- **Every text has its own font, size, outline and color**: text auras, bar text, and the text on icons. Fonts include the game's and any LibSharedMedia fonts other addons bring.
- **Built-in trigger types** (phase 3), WeakAuras' generic triggers that this client can answer:
  - Spells: **Usable** (castable now, optionally in range), **Spell known**, **In range**, **Charges**, **Your cast** (shows for a while after you cast a spell -- your own casts are the only ones this client names in combat).
  - Items: **Item cooldown**, **Slot cooldown** (trinkets and other worn items), **Item count**, **Item equipped**, **Weapon enchant** (poisons, oils, stones, imbues, with time left).
  - You: **Stance / form**, **Threat**, **Experience**, **Money**, **Player status** (combat, mounted, resting, stealthed, swimming, group, raid, target, PvP, indoors, taxi...), **Zone**.
  - Events: **Chat message** (by channel and text), **Ready check**.
  - **Health** and **Power** bars: this client keeps both secret, so the bar is handed the value to draw; they cannot be compared or used in custom code.
  - The trigger type is picked from a dropdown, grouped (Auras & cooldowns, Spells, Items, You, Events, Bars, Custom); long lists like player status and equipment slot are dropdowns too. The Trigger tab shows only the settings of the type picked; item settings take a dragged item.
- **Fixed: multi-hop flights now find their time in the flight list.** This client does not say which stops a flight passes through, so the lookup fell back to the two ends and missed every multi-hop route. It now works the route out from the list: every route between the two ends over flight points you know, the fastest being the one flown. `/chair plus flight probe` marks these as worked out.
- **Fixed: the threat warning no longer fires for tanks.** It skipped you only while you held aggro, so a tank not on top for a moment (the pull, a taunt swap) was told to ease off. It now stays quiet whenever your chosen role is Tank: the role you have in the group, or, with none assigned, the roles ticked in the group finder.
- **Custom Lua triggers** (phase 2), with WeakAuras' three kinds and field names:
  - **Status**: your function says whether it is on, on the events listed or every update; an optional untrigger holds it on until it says off.
  - **Event**: your function fires it on an event; it hides after a duration or when your untrigger says so.
  - **State updater** (WeakAuras' TSU): your function fills in `allstates`; `autoHide` states go when they expire.
  - Optional duration, name, icon and stacks functions.
  - Events as WeakAuras writes them: `UNIT_POWER_UPDATE:player` unit filters, `TRIGGER:n` to watch another trigger, custom events from `WeakAuras.ScanEvents`. The combat log is reported as unavailable on this client.
  - A small `WeakAuras` global (`ScanEvents`, `GetData`, `IsOptionsOpen`, ...) for code written against it, only when the real WeakAuras is not loaded.
  - **Imported custom code waits for approval**: the aura's Trigger tab has "Approve its code", or `/chair auras trust <n>` lists the code and `/chair auras trust <n> yes` approves it.
- **Several triggers per aura**, WeakAuras-style. The Trigger tab has a strip: one button per trigger, **+** to add one (a copy of the open one), Remove.
- **Show when:** All, Any, or **Custom** -- a Lua function given the triggers' answers (`trigger[1]`, `trigger[2]`...). Custom code runs in a sandbox like WeakAuras': `aura_env`, and RunScript, mail/trade money, macro editing, the saved variables and the rest of WeakAuras' blocked list are refused.
- **Info from:** the aura's timer, stacks, name and icon come from the first active trigger or a chosen one.
- **Auras no longer freeze in combat.** This client refuses every aura read to addons in combat and makes cooldowns secret (found with the new probe). Now:
  - a buff you had at the pull keeps counting down to its known expiry and hides when it runs out; recasting its spell refreshes it;
  - cooldowns keep drawing correctly in combat through the client's display-only duration objects, and ready/not is worked out from the cooldown length learned out of combat plus your casts.
  - These are marked "assumed" in `/chair auras why`, which now shows each trigger.
- **Text on icons**, WeakAuras-style: an icon can carry its own text (`%t` time left, `%s`, `%n`, `%p`, `%d`) at any of nine spots, in any size and color. Text-only auras remain their own type.
- **Fixed:** ChairTracker's profession bars caused `ADDON_ACTION_BLOCKED` on `StatusBar:SetSize()` in combat. The secure button that opens a profession is no longer attached to the bars; it is laid over a bar only while the mouse is on it, out of combat.
- **`/chair auras probe`** reports what this client lets auras use, in and out of combat, and keeps the answers in the saved file.
- Saved auras migrate automatically (database version 3); old `CA1:` export strings still import.

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
