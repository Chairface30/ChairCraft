# Changelog

## Unreleased

**Changed**
- **The waypoint arrow fades out under the game's on-screen messages.** When a zone or subzone name, a red or yellow message ("Out of range.", quest progress like "Claw: 1/7", quest accepted and completed), a raid warning or a boss emote appears over the arrow, the arrow fades out as the text fades in, stays hidden while the text fades away, and fades back in once the text is completely gone. Text elsewhere on the screen leaves it alone. Turn it off with "Fade under the game's on-screen messages" on the Travel page. Not yet confirmed in game.

## ChairCraft v1.10.0: Dodge, parry and block triggers

**New**
- **Dodge, parry and block triggers,** in their own group of the trigger list: Target dodged, Target parried and Target blocked (Overpower), and You dodged, You parried and You blocked (Revenge, Riposte, Counterattack). A partial block counts. Each shows for as long as you set (5 seconds for Overpower), with a timer. Give it a spell under "Until I cast" and casting it ends the window early, whatever its rank. The game hides auras and the combat log from addons, so ChairAuras listens for the dodge, parry and block feedback the game shows on your target and on you, and for the old combat chat lines where the game still sends them.
- **A Spell glows trigger.** It shows while the game lights a spell up on your action bars, which is how the game marks a proc that made it castable. It works in combat, where buffs can't be read. `/chair auras procs` lists every dodge, parry, block and glow ChairAuras has heard. Not yet confirmed in game.
- **A Target trigger for ChairAuras.** It is met when you have a target that is everything you tick: one you can attack, alive, a player. Give it a spell and the target must also be in that spell's range. **At least** and **At most** set a distance in yards, for a spell like Charge that has a minimum range as well as a maximum. The game gives no exact distance, so ChairAuras works it out from the ranges of the spells in your spellbook, plus, out of combat, the game's interact distances. `/chair auras range` shows how far it reads your target to be, and from what.

**Fixed**
- **"Hide when inactive" only dimmed an aura further instead of hiding it.** Hidden auras stayed faintly visible whenever auras were unlocked so they could be dragged, and unlocked is the default. That faint outline now shows only while the ChairAuras window is open.
- **Usable's "and the target is in range" counted no target as in range,** so an aura using it showed with nothing targeted. No target, or one the spell can't be cast at, now counts as out of range.

**Changed**
- **Auras say when the game won't let them be read.** In combat the game hides every buff and debuff from addons, so an aura can only show what was true when the fight started. It now says so: an aura that is showing turns half see-through and gray, and its stack count shows "?" (the `%s` text code too) instead of a number that may be out of date. The moment combat ends it shows the real state again. Earlier tries at following stacks through a fight (reading the game's buff bar, then its aura events) are gone: in game, both turned out to be hidden from addons too. `/chair auras debug` says "shown as unknown" for an aura in this state.
- **The waypoint arrow points at your corpse while you are dead.** It takes over from the selected quest and the map pin, says "Your corpse", and goes back to them once you are alive. A corpse in the next zone over is found too. `/chair arrow probe` lists the corpse API. Not yet confirmed in game.
- **`/chair auras probe` checks two ways to show stacks in combat.** Run it out of combat with stacks of a buff up (Plainsrunning, say), then probe again mid-fight without reloading. It tries the stack count API on that buff and reads the count on the game's own buff bar.

## ChairCraft v1.9.0: Bear and Cat Form bar, Frequent Flyer

**New**
- **Druids: the alternate resource bar only in Bear and Cat Form.** A new option on the Looting & comfort page, under Druid. Leave the alternate resource checkbox on for the Personal Resource Display in Edit Mode, and with this ticked the bar (your mana while shifted) is see-through and only shows in Bear or Cat Form. `/chair plus formbar` says whether ChairCraft found the bar and what it reads your form as.
- **Self Highlight only in combat.** A new option on the Looting & comfort page, under Everyday. With it ticked, the game's Self Highlight (circle, outline or both, from the Accessibility options) is off out of combat and comes back as you set it when combat starts. Pick your style in the game's options as usual, even while it is held off; switching the option off puts your style back for good.
- **The Legacy (progress track) window can be dragged.** Like the other Blizzard windows, drag it by its title bar and it stays where you drop it. Any other window the game opens as a panel now gets the same treatment. If a window still won't move, point at it and type `/chair plus movers add`.
- **The flight timer knows about Frequent Flyer.** A character with the Legacy perk unlocked gets countdowns and flight-map times 20% shorter, and their faster flights no longer throw off the times for your other characters. `/chair status` shows whether ChairCraft sees the perk.

## ChairCraft v1.8.2: combo points stay on their mob

**Fixed**
- **Combo points on nameplates followed you from mob to mob.** Combo points belong to the mob you built them on, but the pips showed the same count on whatever you targeted next. They now stay with that mob: a new target shows empty pips until you build points on it, and switching back to the first mob shows its points again.

## ChairCraft v1.8.1: ChairIgnore keeps your reasons

**Fixed**
- **ChairIgnore asked again why you ignored someone already on the list, and lost the reason you gave.** The game can send your ignore list a name short for a moment while it fills in. ChairIgnore took the missing name for an unignore and dropped the entry, reason and all; when the name came back it looked like a new ignore and the "Why?" box opened. A name the game's list drops now keeps its reason and expiry for 30 days, and if it comes back (or you ignore them again) the reason comes back too, with no prompt. Removing someone in ChairIgnore itself still forgets them. `/chair ignore status` counts how many came back this session.

## ChairCraft v1.8.0: settings shared by the account

**New**
- **The Map & Quest Log window can be dragged by its title bar**, like the other Blizzard windows, and stays where you drop it. It is kept by its top left corner, so opening the quest log beside the map still grows the window to the right. Maximized, the map fills the screen as before and can't be dragged; back in its window it returns to your spot. `/chair plus movers reset` hands it back to Blizzard.

**Changed**
- **Settings are shared by every character on the account**, except ChairTracker's bars and factions, which stay per character. ChairPlus's options and window positions and ChairSnack's bars, keybinds and positions start from your fullest character's setup (your own on a tie). The old per-character profiles are kept: the Home page's "Copy settings from" and ChairSnack's Profiles tab can still copy one across. Auras and ChairIgnore were already account-wide.
- **ChairIgnore keeps one list of people.** Each character's record of its game ignore list now lives in the account file, and anyone on any character's game list who was not yet on ChairIgnore's list is added to it.

**Fixed**
- **ChairIgnore could lose its whole list.** A character's game ignore list is read a few seconds after login, and if the game had not sent it yet it read as empty; the sync took that for "you unignored everyone" and took every name off ChairIgnore's list. A name the game keeps hidden read as missing and went the same way. Only a list read whole counts now, a name you remove in ChairIgnore stays removed (a character whose game list still holds them is brought up to date, not believed), and anyone still on a character's game list comes back onto the list the next time that character logs in.
- **Threat % on nameplates for mobs you have not targeted.** In combat the game keeps your own "in combat" flag hidden from addons, and ChairCraft read a hidden flag as "not fighting". A plate whose mob the game also wouldn't confirm was in the fight was then skipped, which is every plate except your target's. A hidden flag now counts as in combat, so those plates show your own threat (as text, or as the thin colored bar when the game won't print the number). The nameplate colors and the threat meter read the flag the same way.
- **Hidden values, everywhere.** A sweep of every part for values the game can hide in combat:
  - **ChairSnack:** an item or spell cooldown the game hides is still drawn on the button's swirl; only the number is left off. Your pet's family and level are read safely.
  - **ChairAuras:** a Lua error (`Core.lua:52: attempt to compare local 'text'`) whenever a mob yelled or someone spoke as a fight began. The game hides chat text in combat, and the chat listener for Chat triggers tested it before checking. Hidden lines are now skipped.
  - **ChairAuras:** a trigger that asks a yes/no the game hides (Player status, In range, Threat) reads as unknown instead of failing. Load conditions treat a hidden answer as unknown too.
  - **ChairAuras:** the Weapon enchant trigger now sees the off hand's enchant, and an item trigger gets its icon on clients without the item cache call. Both were cut off by a helper that passed on only the first six values.
  - **Threat meter:** "is this me", "can I attack it" and your group role are read safely. A mob the game won't say you can attack is no longer ruled out.
  - Every part now tests for a hidden value before doing anything else with it.
- **ChairAuras: the Item equipped, Item not equipped and Item type equipped load conditions** were unavailable on WoW Forever, which has those calls under a new name. They now work there.

**For developers**
- Two checkers in `.tests/tools`: `secret_audit.py` lists every place a value the game can hide is compared, tested, added up, joined or used as a table key, following it through locals, fields and function results. `globals_audit.py` lists the game functions an addon calls, and the calls to ones WoW Forever is known not to have. Both also run on Z-Perl and ItemRack.

## ChairCraft v1.7.0: threat on the nameplates

**New**
- **Threat % on enemy nameplates** (Threat meter, Nameplates page; off): during combat, a number inside each enemy nameplate's health bar, so a whole pack reads at a glance without tabbing.
  - **DPS and healers:** your own threat on every mob in the fight. A mob that's on you reads 100%.
  - **Tanks (in a group):** the highest threat behind you on each mob you hold, so you can see how close each one is to being pulled. On one someone else has, their name and your % toward taking it back, in red. Solo, you see your own threat.
  - Green under 70%, amber to 90%, red past it. **Position** puts it at the left, center or right of the bar.
  - The game only gives out everyone's numbers for mobs that you, your pet or someone in your group has targeted (plus focus, mouseover and bosses), so those are the mobs with full, colored numbers. On any other mob you see your own %, as white text or, if the game won't let it be printed, as a thin colored bar along the top of the health bar.
  - `/chair threat nameplates probe`, run in a fight, says what each plate shows and why.
- **Combo points on your target's nameplate** (rogues, and druids in Cat Form; Threat meter, Nameplates page; off): your combo points as a row of pips along the bottom of the target's health bar. A druid sees them only in Cat Form, and they come and go as you shift. `/chair threat combo` says what the game reports and why the pips did or did not show.
- The threat meter's Nameplate colors page is now just **Nameplates**.

**Fixed**
- **The spellbook can be dragged by its title bar again.** It only got its drag handle if it already existed when ChairCraft looked, so a spellbook the game created later never got one. It now gets one the first time it opens. Newer clients' combined spellbook and talents window (PlayerSpellsFrame) is covered too. `/chair plus movers` lists the windows it can move on this client.
- **A /reload in the air no longer spoils the flight timer.** The flight is not recorded (its time would span the reload), and the countdown carries on from the real takeoff instead of starting over at 00:00.

## ChairCraft v1.6.0: a clearer menu

**New**
- **Chat scroll bar on the left** (Chat page; off): each chat window's scroll bar, its arrows and the jump-to-bottom button move to the left side. The window's background moves over to make room, and the text stays where it is. Whisper windows opened later follow too, and switching it off puts everything back.

**Changed**
- **The menu is reorganized into plain-language pages.** A list down the left replaces the row of tabs, and the crowded Plus page is split by topic: **Home** (the minimap icon, Quick setup, What's new, copying and backing up settings), **Quests & NPCs**, **Buying & selling** (junk, repairs, restock), **Groups & people** (invites, duels, resurrection, summons, the group finder), **Chat**, **Looting & comfort** (faster loot, dismounting, cinematics, camera zoom, tooltips), **Travel** (flight paths and the waypoint arrow), **Info bar** (the old OSD page) and **Threat meter**, with its own **When & where** and **Nameplate colors** pages. Auras, Snack, Tracker and Ignore are listed under Tools and open beside the list, which stays up, so there is no Back button any more (Escape still steps back first). Every page starts with its name, and search results say which page an option is on. No setting changes.
- **The Open all mail button is gone.** The game's mailbox has its own now, so ChairCraft no longer adds one (it was under Plus, Tooltips, mail and small automations).
- **Credits read Chairface Chippendale** in the AddOns list, ChairTracker and the README.
- **An About section** at the bottom of the Home page: who makes ChairCraft, and a quiet note that in-game gold mailed to Chairface Chippendale is appreciated. ChairTracker's options no longer ask for tips in their header.
- **ChairTracker starts switched off on a new install**, like every other feature: its window no longer appears the first time ChairCraft loads. Turn it on with Show window in its options or `/chair tracker`. If you already use it, your window stays as it is, including a window you never touched, which older versions saved as "no setting".
- **The name is spelled ChairCraft** everywhere you read it: the AddOns list, the menu, chat, the minimap and options-page tooltips, the welcome page and the README. Nothing else changes: the folder, `/chair`, and your saved settings stay as they are.
- **The version reads "ChairCraft vX.X.X"** in the menu title, `/chair status`, What's new and the options page.

**Fixed**
- **Fixed errors in the game's Options > Advanced list** ("attempt to compare a secret number value" from the nameplate preview while scrolling or hovering checkboxes). ChairAuras' icon picker built its list with Blizzard's own icon provider, whose shared state then counted as addon-written, and the preview that uses it next failed. The picker now reads the same icon lists directly and never touches the provider.

## 1.5.0: restock and profession cooldowns

**New**
- **Restock** (Plus page, Merchants): at any merchant, buy back up to a count you set of ammo, reagents, food and water.
  - The **Items...** window keeps the list, with suggestions to add in one click: your equipped ammo, and at a merchant whatever in your bags they sell. An item ID box covers the rest, with a **Show item IDs in tooltips** switch beside it (the same switch as the menu's).
  - Bought in the merchant's own lots (arrows by the 200, water by the 5), never past a per-visit spending limit or under a gold floor you set, and never an item that costs tokens or honor.
  - It stops when your bags are full or the merchant closes, and never orders twice while a slow server delivers. One line in chat says what it bought and what it cost. Hold shift to skip it.
- **Profession cooldowns** on every character: transmutes, Mooncloth and the Salt Shaker, recorded when you cast them.
  - An **OSD item** with how many are ready; hover for each character's and the time left.
  - An optional **ready notice** in chat, once per cooldown.
  - `/chair cooldowns` lists them; `/chair cooldowns probe` prints the next casts' spell IDs and what the game says about their cooldowns.

- **ChairIgnore filters take a `*` wildcard:** anything, of any length. `<*>` is any guild tag, and `g*ld` catches "g.0.ld". A word that is nothing but `*` is ignored.
- **A ChairIgnore filter can be kept to channels you tick:** the editor lists Say, Yell, and a checkbox for every channel you are in, read from the game as you join and leave them. None ticked, it works everywhere the Options tab allows; ticked channels override the Options tab for that filter. Channels are kept by name, never number, since numbers change with the order they were joined; one a filter has that this character is not in stays listed, ticked. The filter list shows a filter's channels after its name, and shared filters keep them.
- **A Politics starter filter** (off): 109 party, politician, election, issue and news-outlet terms, each as a whole word, so "trumpet", "advance" and "victory" are left alone, and words that are everyday game chat too (party, vote, war, tax, left, right, woke) are left out. A filter line now holds up to 2,000 characters.
- **An Ignored chat tab** (off): switch it on in ChairIgnore's Options and everything ChairIgnore hides is also printed, with who sent it and why, in a chat tab of its own docked on the main chat window. The tab is made once, out of combat, and the game never writes to it. `/chair ignore tab on` or `off`; close the tab like any other.
- **Filters ignore case in every language:** accented letters (É, Ü) and Cyrillic now match whatever their case, as plain letters always did.
- **Long filter lines wrap:** a line of words grows its box as it gets longer, and the filter editor scrolls to fit.

**Changed**
- **Nameplate threat colors are for tanking only:** they apply while your role is Tank (or you have the tank role ticked in the group finder); otherwise enemy nameplates keep their normal colors.
- **ChairIgnore is account-wide:** its switches are set once and are the same on every character, like its list and filters. The first character to log in brings its switches along.
- **What's new** has a **Don't show after updates** box (also on the General page).
- **Quick setup and What's new** take the menu's place while they are up, and hand it back on the same page when they close.

## 1.4.0: finding things, and ChairIgnore round two

**New**
- **Search the menu:** a box in the menu's title bar finds any option by its name or its tooltip, on every page, plus ChairIgnore's options and each part by name. Pick a result to go straight to it; the option is highlighted for a moment.
- **Quick setup:** the first time Chaircraft loads on an account, one page of the most-used switches, since everything starts off. Reopen it from the General page or with `/chair setup`.
- **What's new:** after an update, a short list of what changed, once per version. Reopen it from the General page or with `/chair whatsnew`.
- **ChairIgnore**
  - **Smarter filter words:** `{link}` matches any item, spell or quest link, and a word in `"quotes"` counts only on its own, even spaced out ("a n a l") or with look-alike letters ("4nal"), and never inside another word ("canal").
  - A **Crude link jokes** starter filter (`"anal"` + `{link}`), off like the others.
  - **A Hidden tab:** the last 200 messages ChairIgnore hid, when, from whom, and which filter or listing hid them. **Show in chat** brings one back; **Unignore** takes a listed sender off. Kept for the session unless you tick the option to keep it.
  - **Share filters:** **Export** a filter as one line of text and **Import** someone else's. An imported filter arrives switched off.

## 1.3.0: ChairIgnore

**New**
- **ChairIgnore**, a fifth part with its own page in the `/chair` menu (`/chair ignore`). Everything in it ships off.
  - **One ignore list for the whole account**, with notes, an optional expiry in days, and no 50-name limit.
  - **Kept in step with each character's game ignore list:** the game's 50 slots are filled from yours, and anyone you ignore or unignore the normal way is picked up.
  - **Chat from everyone on the list is hidden**, past the game's 50 too.
  - **Chat filters** you write as lines of words, with a test box, a count of what each has hidden, and a choice of which kinds of chat they cover. Friends and guildmates are spared. Four starter filters come with it, all off.
  - **The normal Ignore goes to ChairIgnore:** ignoring someone from the right-click menu or with `/ignore` adds them to ChairIgnore's list and asks why.
  - Built for Forever's names: a first name and a surname ("First Last", or "First Last-Realm" in chat).
  - `/chair ignore add First Last: reason`, `remove`, `list`, `sync`, and `status` (what it is watching and has seen, for when something does not arrive).
- **An OSD item for ChairIgnore:** its portrait icon. Hover for the list's size and what it has hidden; click to open the page.
- **Money on the OSD:** hovering it now lists every character's gold and the account total.

**Changed**
- **Invites and duels:** the "Say in chat what was answered" option is gone, and answering invites, duels, resurrections and summons (and keyword invites) no longer says anything in chat.
- **The menu's version number** is read from the TOC, so it always shows the release. It said 1.0.
- **The menu is as wide as its nav row**, with a margin. The last nav button was cut off at the window's edge.

**Fixed**
- **Settings import:** auras brought in from a settings string now wait for your approval before any custom code in them runs, as they do through the aura Import. Aura edits made before the `/reload` are no longer lost.
- **Repair:** a repair that worked is no longer reported as "Could not repair". The result is checked once the server has answered.
- **Open all mail:** an item or gold the server refuses (a unique item you already carry, for example) is left in the mail instead of being asked for again until the mailbox closes. The "Took..." total counts only what actually came out.
- **ChairAuras, Options tab:** opening it no longer changes a slider option's saved value.
- **ChairAuras, several at once:** making, importing or dragging an aura, or deleting the one open, now clears any ctrl-click selection. A leftover selection could make Delete remove auras you had moved on from.

## 1.2.0: polish, new features, and ChairAuras phases 10 and 11

### Polish and new features

**New**
- **OSD**
  - A **watched reputation** item.
  - The **repair cost** on the durability tooltip (exact where the client gives it, otherwise the last merchant's quote).
  - **Background opacity**, and a **wrap width** past which items start a second line.
  - **Right-click actions:** money lists every character's gold, durability says itself in chat, and the clock switches 12 and 24 hour.
- **ChairPlus**
  - **Tooltip extras:** sell prices, and item and spell IDs.
  - An **Open all** button on the mailbox (it skips cash-on-delivery and GM mail, and stops when bags are full).
  - **Release in battlegrounds**, **skip cinematics**, and **dismount or stand when needed**.
- **Nameplate threat colors** on the Threat page: I have aggro, aggro changing, a non-tank has aggro, and another tank has aggro, each in your own color. `/chair threat nameplates` reports what this client lets it read.
- **A General page** in the menu: the minimap icon, locking the display, copying from another character, and **export and import of every setting** as one line of text.

**Fixed**
- **Chaircraft no longer makes Blizzard's own windows run their code:**
  - The menu no longer hides the options window directly.
  - The error-spam filter no longer replays the error frame's handler.
  - Hiding the XP bars makes them see-through and click-through instead of hiding them, and they stay that way after a reload, when the game's own bar layout used to bring them back.
  - Quest safety checks read the quest, not Blizzard's quest window.
- **Max camera zoom, left off,** no longer resets your own zoom setting every time any setting changed.
- **Repair:**
  - Guild funds are used even when you are short of gold.
  - "Repaired" is only said when it happened.
  - Junk selling stops at twelve per visit, so all of it can still be bought back.
- **Quests:**
  - A turn-in whose item the client has not loaded yet is left to you.
  - Blocked quests are refused when offered directly, too.
- **Gossip:** the one-option skip recognizes flight masters, innkeepers, trainers and vendors by their icon on this client.
- **Invite on keyword:** after turning the party into a raid, the invite waits for the raid to exist.
- **Faster loot:** with full bags, coin and currency are taken and the items left, without the "Inventory is full" flood.
- **The threat warning** can no longer be set above 100%, where it could never fire.
- **The OSD:**
  - The zone name follows zone changes.
  - Threat follows target changes.
  - A long name no longer leaves a gap once it is gone.
  - XP is hidden at the level cap.
  - Values the client keeps secret no longer break an item.
- **Wording:**
  - The OSD reset says where the display went (the center of the screen).
  - Help text no longer loses letters to color codes.
  - A broken slider texture path is fixed.
- **ChairSnack:**
  - The ammo low-supply warning can reach its own default (200).
  - Running out of ammo shows 0 instead of hiding the bar.
  - Secret aura data can no longer break the buff checks.
  - Bag changes are rescanned once per frame instead of once per bag.
- **ChairTracker:**
  - Clicking a profession bar in combat no longer gets blocked.
  - The standing sorts put skills after factions.
  - It does less work per redraw.
  - Its options talk about factions and skills, not just factions.
  - The fade and linger sliders gray out with auto-hide off.

**Polish**
- Tooltips on nearly every setting in the ChairPlus, ChairSnack and ChairTracker options, explaining what each does and, for the automation, what it will never do.
- Menu rows for settings that could only be set by command: the gossip, social and flight chat summaries, and the faster-loot throttle.
- US spelling throughout, and ChairSnack says ChairSnack.

### ChairAuras toward WeakAuras (phases 10 and 11)

- **A Free group layout**: each child sits at its own offset from the group's center, set with its X and Y on the Display tab.
- **Exports** now go out as `!CA:3!` strings, compressed with LibSerialize and LibDeflate (now included), so they are much shorter. Older `CA1:` strings still import. WeakAuras' own strings are not read.
- **Custom options** on a new **Options** tab: settings an aura offers, which its code reads as `aura_env.config`.
  - Types: toggles, text, numbers, sliders, colors, choices, multiple choices, headings and descriptions.
  - **Author mode** adds, orders and edits your own.
  - **Reset to defaults** puts them back.
- **From template**: pick a spell from your spellbook and what to watch about it. The choices are its cooldown, its buff, the buff missing, your debuff on the target, usable now, or after you cast it. Built from your own spellbook, so this client's own spells are included.
- **The editor** (phase 11):
  - A search box above the list.
  - **Ctrl-click** selects several auras. Dragging one moves them all, Delete removes them all, and **Copy tab to selected** copies the open tab's settings onto the rest.
  - Code boxes have **Run**, which compiles and runs the code once and shows what it returned or where it failed. Tab indents.
- **Aura triggers:**
  - **Also match** takes more names or spell IDs, split by commas, for spells with several ranks or buffs with several versions.
  - They can watch your **party** (you included), the **raid**, **group** (whichever you are in) or the **bosses**.
  - **Match count:** at least, at most or exactly so many matching auras, across every unit watched. `%{matchCount}` shows the number.
  - **One region per match** inside a group, with `%{unitName}` naming whose it is.
- **Text formatters**, after a colon in braces:
  - `abbr` (12.3k), `round`, `floor`, `ceil`, `time`, `upper`, `lower`
  - `norealm`, which drops the realm from a name
  - `maxN`, which cuts text to N characters
  - `class`, which colors a name by its unit's class
  - They chain: `%{unitName:norealm:class}`.
- **Group grid order**: a wrapping group can start each new line above the last (or left of it), instead of below.
- **Reputation trigger**: the faction you watch, or one by name, at a standing or better. Stacks show the standing, `%n` the faction, and a bar fills through the standing.
- **The guild window can be moved** by dragging its title bar, like the other windows ChairPlus frees, and it stays where you drop it. This covers the guild and communities window, an older-style guild window, and the guild bank.
- **ChairTracker reads every skill without the Skills panel ever being opened.** On WoW Forever the old skill functions only return spellbook tabs at 1/1, but `C_SkillInfo`, the Skills panel's own data source, returns every skill at its real rank: weapons (Feral Combat included), Defense, professions and secondary skills. ChairTracker now reads that directly, and keeps the last reading if the client hides the numbers in combat. Found with the new `/chair tracker skilldata` command.
- **Fixed: ChairTracker no longer trips Blizzard's Skills panel.** It used to make the panel fill itself, and Blizzard's row code then ran as Chaircraft's and hit a hidden value ("SkillsFrame.lua:466: attempt to compare field 'modifier'"). Nothing of the panel's is run any more.
- Not done: syntax coloring in code boxes, which needs a library whose license could not be confirmed.

## 1.1.0: ChairAuras toward WeakAuras

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
