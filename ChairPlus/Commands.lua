-- ChairPlus Commands.lua
-- The options panel and the slash commands.
--
-- The panel is built from plain frames and textures rather than any of the
-- options templates, because which of those exist has changed three times
-- across the clients in the TOC and a missing template is a hard error at load.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

-------------------------------------------------------------------------------
-- The option list
-------------------------------------------------------------------------------
-- Order is display order. A row with "sub" is indented under the one above it
-- and greys out when its parent is off.

-- `tab` picks which page of the window a row appears on: one of the keys in
-- PAGES below. Each page is one topic, named the way a player would put it,
-- so nobody has to read fifty switches to find the one they want. A header
-- marked newColumn starts the page's second column.

local ROWS = {
    -- The Home page: what belongs to the whole suite rather than a part.
    { header = "ChairCraft", tab = "general" },
    { key = "chairMinimapHidden", label = "Hide the minimap icon", tab = "general",
      get = function()
          local snack = Chaircraft.ChairSnack
          return snack and snack.GetMinimapDB and snack:GetMinimapDB().hide and true or false
      end,
      set = function(value)
          local snack = Chaircraft.ChairSnack
          if snack and snack.SetMinimapButtonHidden then snack:SetMinimapButtonHidden(value) end
      end,
      tip = "The chair on the minimap. /chair still opens the menu." },
    { key = "osdLocked",  label = "Lock the on-screen display", tab = "general",
      tip = "Unlocked, the display can be dragged anywhere." },
    { header = "Getting started", tab = "general" },
    { action = "Quick setup...", tab = "general",
      run = function() if Chaircraft.ShowWelcome then Chaircraft.ShowWelcome() end end,
      tip = "The most-used switches on one page, as shown the first time ChairCraft loads." },
    { action = "What's new...", tab = "general",
      run = function() if Chaircraft.ShowWhatsNew then Chaircraft.ShowWhatsNew() end end,
      tip = "What changed in this version." },
    { key = "whatsNewOff", label = "Don't show What's new after updates", tab = "general",
      get = function() return Chaircraft.WhatsNewOff and Chaircraft.WhatsNewOff() or false end,
      set = function(value) if Chaircraft.SetWhatsNewOff then Chaircraft.SetWhatsNewOff(value) end end,
      tip = "The list stays here and in /chair whatsnew either way." },
    -- Last on the page, and quiet: a credit and a thank-you, not a pitch.
    { header = "About", tab = "general" },
    { note = "ChairCraft is made by Chairface Chippendale.", tab = "general" },
    { note = "If it has earned a place in your UI and you'd like to say thanks, "
          .. "in-game gold mailed to Chairface Chippendale is always appreciated, "
          .. "and never expected.", tab = "general" },

    { header = "Quests", tab = "quests" },
    { key = "quests",              label = "Automate quests", tab = "quests" },
    { key = "questsAccept",        label = "Accept regular quests", tab = "quests",     sub = "quests",
      tip = "Quests offered by the NPC you are talking to. Blocked NPCs and quests are never taken." },
    { key = "questsDaily",         label = "Accept daily quests", tab = "quests",       sub = "quests" },
    { key = "questsWeekly",        label = "Accept weekly quests", tab = "quests",      sub = "quests" },
    { key = "questsTurnIn",        label = "Turn in completed quests", tab = "quests",  sub = "quests",
      tip = "Never hands in a quest that costs gold, a currency, a crafting reagent or an account-bound item, and never picks between several rewards: those wait for you." },
    { key = "questsShiftOverride", label = "Hold shift to suppress", tab = "quests",    sub = "quests",
      tip = "Holding shift while you talk to an NPC leaves everything to you." },
    { header = "Talking to NPCs", tab = "quests" },
    { key = "autoGossip",              label = "Skip single-option gossip", tab = "quests",
      tip = "Only when the window has one plain option and no quests. Flight masters, innkeepers, trainers, vendors, bankers and colored options are never picked." },
    { key = "autoGossipSummary",       label = "Say which option was taken", tab = "quests", sub = "autoGossip" },
    { key = "autoGossipShiftOverride", label = "Hold shift to suppress", tab = "quests",
                                       sub = "autoGossip" },

    { header = "Junk and repairs", tab = "shopping" },
    { key = "sellJunk",         label = "Sell junk automatically", tab = "shopping",
      tip = "Sells gray items when you open a merchant: twelve at most per visit, so everything sold can still be bought back." },
    { key = "sellJunkSummary",  label = "Report the take in chat", tab = "shopping",      sub = "sellJunk" },
    { key = "sellJunkKeepGear", label = "Keep unbound gray gear", tab = "shopping",       sub = "sellJunk",
      tip = "Gray weapons and armor that are not soulbound can still go on the auction house, so they are kept." },
    { key = "repairGear",       label = "Repair automatically", tab = "shopping" },
    { key = "repairSummary",    label = "Report the cost in chat", tab = "shopping",      sub = "repairGear" },
    { key = "repairGuildFunds", label = "Use guild funds first", tab = "shopping",        sub = "repairGear",
      tip = "The guild bank pays first, and your own gold covers what the guild's daily limit does not." },
    { header = "Restock", tab = "shopping" },
    { key = "restock",          label = "Restock consumables", tab = "shopping",
      tip = "Buys back up to the count you set of ammo, reagents, food and water, at any merchant that sells them. Hold shift to skip it.",
      button = { "Items...", function() ns.ToggleRestockPanel() end } },
    { key = "restockSummary",   label = "Report what was bought", tab = "shopping",       sub = "restock" },
    { slider = "restockCap",    label = "Spend at most per visit", tab = "shopping", sub = "restock", min = 0, max = 100, step = 1,
      fmt = "g", zero = "no limit" },
    { slider = "restockFloor",  label = "Keep at least", tab = "shopping", sub = "restock", min = 0, max = 500, step = 5, fmt = "g",
      zero = "no floor", tip = "Stops buying before your gold would drop under this." },

    { header = "Invites", tab = "groups" },
    { key = "autoInvite",          label = "Accept group invites from...", tab = "groups",
      tip = "Only from the people ticked below. Hold shift when the invite arrives to answer it yourself." },
    { key = "autoInviteFriends",   label = "friends", tab = "groups",                   sub = "autoInvite" },
    { key = "autoInviteGuild",     label = "guildmates", tab = "groups",                sub = "autoInvite" },
    { key = "keywordInvite",       label = "Invite on keyword", tab = "groups",
      button = { "Keywords...", function() ns.ToggleKeywordPanel() end } },
    { key = "declineGuildInvites", label = "Decline guild invites", tab = "groups" },
    { header = "Answer for me", tab = "groups" },
    { key = "declineDuels",        label = "Decline duels", tab = "groups" },
    { key = "autoResurrect",       label = "Accept resurrection", tab = "groups",
      tip = "Accepts a resurrection as soon as it is offered. Hold shift to answer it yourself." },
    { key = "autoSummon",          label = "Accept summons", tab = "groups",
      tip = "Accepts a summon as soon as it is offered. Hold shift to answer it yourself." },
    { key = "autoReleaseBG",    label = "Release in battlegrounds", tab = "groups" },
    { header = "Group finder", tab = "groups" },
    { key = "lfgFilters",       label = "Player filters in the group finder", tab = "groups" },

    { header = "Chat windows", tab = "chat" },
    { key = "chatScrollLeft",   label = "Chat scroll bar on the left", tab = "chat",
      tip = "Moves each chat window's scroll bar, its arrows and the jump-to-bottom button to the left side. The window's background moves over to make room, and the text stays where it is." },
    { header = "Messages", tab = "chat" },
    { key = "filterErrors",     label = "Hide \"Not enough rage\" spam", tab = "chat",
      tip = "Hides the red text you get while mashing a button (not enough rage, not ready yet). Real errors still show." },
    { key = "cooldownNotify",   label = "Say when a profession cooldown is ready", tab = "chat",
      tip = "Transmutes, Mooncloth and the Salt Shaker, on every character, recorded when you cast them. "
         .. "The Info bar page has an item for them too. /chair cooldowns lists them." },

    { header = "Looting", tab = "comfort" },
    { key = "fasterLoot",       label = "Faster auto loot", tab = "comfort",
      tip = "Takes the whole corpse the moment the loot is ready. With your bags full, only coin and currency are taken." },
    { slider = "fasterLootDelay", label = "Loot again after", tab = "comfort", sub = "fasterLoot", min = 0.1, max = 1, step = 0.05, fmt = "sec",
      tip = "How soon a second loot window is handled; lower is faster. Too low can take the same corpse twice." },
    { header = "Everyday", tab = "comfort" },
    { key = "autoDismount",     label = "Dismount and stand when needed", tab = "comfort" },
    { key = "skipCinematics",   label = "Skip cinematics", tab = "comfort" },
    { key = "maxCameraZoom",    label = "Max camera zoom", tab = "comfort",
      tip = "Lets the camera zoom out further than the game's own slider allows. Left off, the game's setting is not touched." },
    { key = "selfHighlightCombat", label = "Self Highlight only in combat", tab = "comfort",
      tip = "Turns the game's Self Highlight (Accessibility options) off out of combat, and back to the style you picked when combat starts. "
         .. "Pick a style there as usual; switching this off puts it back for good." },
    { header = "Druid", tab = "comfort", classes = { DRUID = true } },
    { key = "formAltBar", label = "Alternate resource bar only in Bear and Cat Form", tab = "comfort",
      classes = { DRUID = true },
      tip = "Leave the alternate resource checkbox on for the Personal Resource Display in Edit Mode, and the bar "
         .. "(your mana while shifted) is see-through except in Bear and Cat Form. "
         .. "/chair plus formbar says whether the bar was found and what your form reads as." },
    { header = "Tooltips", tab = "comfort" },
    { key = "tooltipExtras",    label = "Tooltip extras", tab = "comfort" },
    { key = "tooltipSellPrice", label = "Sell price", tab = "comfort",          sub = "tooltipExtras",
      tip = "What an item sells to a merchant for; a stack's worth for a stack in your bags." },
    { key = "tooltipIDs",       label = "Item and spell IDs", tab = "comfort",  sub = "tooltipExtras" },

    { header = "Flight paths", tab = "travel" },
    { key = "flight",           label = "Flight path timer", tab = "travel" },
    { key = "flightCountdown",  label = "Countdown while flying", tab = "travel",  sub = "flight" },
    { key = "flightTooltip",    label = "Time on the flight map", tab = "travel",  sub = "flight" },
    { key = "flightSummary",    label = "Say the time in chat on landing", tab = "travel", sub = "flight" },
    -- The waypoint arrow. A row with `choice` steps through a list of values
    -- with < and > buttons.
    { header = "Waypoint arrow", tab = "travel", newColumn = true },
    { key = "arrow",                label = "Show the waypoint arrow", tab = "travel" },
    { key = "arrowLocked",          label = "Locked in place", tab = "travel", sub = "arrow" },
    { choice = "arrowStyle",        label = "Style", tab = "travel", sub = "arrow",
      values = ns.ARROW_STYLES or { { value = "bevel", text = "3D arrow" } } },
    { key = "arrowDirectionColour", label = "Color by direction", tab = "travel", sub = "arrow",
      blockedBy = "arrowCustomColor" },
    { key = "arrowCustomColor",     label = "Custom color", tab = "travel", sub = "arrow",
      swatch = { "arrowColorR", "arrowColorG", "arrowColorB" } },
    { key = "arrowShowDistance",    label = "Show the distance", tab = "travel", sub = "arrow" },
    { key = "arrowShowName",        label = "Show the quest's name", tab = "travel", sub = "arrow" },
    { key = "arrowYieldToGuides",   label = "Step aside for guide arrows", tab = "travel", sub = "arrow",
      tip = "While RestedXP, TomTom (Questie's waypoints) or Guidelime shows its own arrow, this one leaves quests, your corpse and addon-placed map pins to it. Your own map pins and a guard's directions still show." },
    { slider = "arrowScale", label = "Size", tab = "travel", sub = "arrow", min = 0.5, max = 3, step = 0.05, fmt = "x" },
    { slider = "arrowAlpha", label = "Opacity", tab = "travel", sub = "arrow", min = 0.1, max = 1, step = 0.05, fmt = "pct" },

    -- The Info bar page. The items on the line (money, bags, durability...) are
    -- not rows here: they are the ordered list built from ns.OSD_ITEMS in
    -- BuildPanel.
    { header = "Display", tab = "osd" },
    { key = "osd",              label = "Show the display", tab = "osd",
      tip = "One slim line of information you can put anywhere. Pick what it shows in the list below." },
    { key = "osdBackground",    label = "Dark background", tab = "osd", sub = "osd",
      tip = "A dark panel behind the display's text, so it reads over anything." },
    { slider = "osdBgAlpha",    label = "Background opacity", tab = "osd", sub = "osdBackground", min = 0.1, max = 1, step = 0.05, fmt = "pct" },
    { slider = "osdMaxWidth",   label = "Wrap past", tab = "osd", sub = "osd", min = 0, max = 2000, step = 50, zero = "never",
      tip = "Items past this width start a second line. While you drag items on this page the display stays one line." },
    { slider = "osdFontSize",   label = "Text size", tab = "osd", sub = "osd", min = 8, max = 32, step = 1 },
    { slider = "osdScale",      label = "Scale", tab = "osd", sub = "osd", min = 0.5, max = 3, step = 0.05, fmt = "x" },
    { key = "osdBagsTotal",     label = "Bag space as free/total", tab = "osd", sub = "osd" },
    { choice = "osdXPMode",     label = "XP as", tab = "osd", sub = "osd",
      values = { { value = "pct", text = "percent" }, { value = "num", text = "XP/total" },
                 { value = "both", text = "both" } } },
    -- Not under "osd": it works whether or not the display is on.
    { key = "hideStatusBars",   label = "Hide game XP bars", tab = "osd",
      tip = "Makes the game's XP bar and status bar 2 see-through and click-through. The display can show XP instead." },
    { key = "osdHideMinimap",   label = "Hide addons' minimap buttons", tab = "osd", sub = "osd",
      tip = "An addon put on the display loses its minimap button, so there is one way in, not two. Take it off the display, or untick this, and the button comes back." },
    { header = "Clock and alarm", tab = "osd" },
    { key = "osdClockServer",   label = "Realm time", tab = "osd", sub = "osd",
      tip = "The realm's time rather than your computer's. Hovering the clock shows both." },
    { key = "osdClock24",       label = "24-hour", tab = "osd", sub = "osd" },

    -- The threat meter's three pages. Rows with `slider` are sliders rather than
    -- checkboxes: min, max, step, and how the value reads in the label.
    { header = "The meter", tab = "threat" },
    { key = "threat",                   label = "Show the threat meter", tab = "threat" },
    { key = "threatLocked",             label = "Locked in place", tab = "threat", sub = "threat" },
    { key = "threatClickThrough",       label = "Click-through", tab = "threat", sub = "threat" },
    { key = "threatClickThroughCombat", label = "Click-through in combat", tab = "threat", sub = "threat" },
    { header = "Bars", tab = "threat" },
    { key = "threatClassColours",       label = "Color bars by class", tab = "threat", sub = "threat" },
    { key = "threatShowPets",           label = "Include pets", tab = "threat", sub = "threat" },
    { key = "threatAlwaysMe",           label = "Always show my own bar", tab = "threat", sub = "threat" },
    { key = "threatShowTitle",          label = "Title with the mob's name", tab = "threat", sub = "threat" },
    { key = "threatGrowUp",             label = "Grow upwards", tab = "threat", sub = "threat" },
    { header = "Size", tab = "threat", newColumn = true },
    { slider = "threatWidth",     label = "Width", tab = "threat", sub = "threat", min = 120, max = 600, step = 10 },
    { slider = "threatRowHeight", label = "Bar height", tab = "threat", sub = "threat", min = 10, max = 40, step = 1 },
    { slider = "threatMaxRows",   label = "Most bars", tab = "threat", sub = "threat", min = 1, max = 40, step = 1 },
    { slider = "threatScale",     label = "Scale", tab = "threat", sub = "threat", min = 0.5, max = 3, step = 0.05, fmt = "x" },
    { header = "Look and warning", tab = "threat" },
    { slider = "threatAlpha",     label = "Opacity", tab = "threat", sub = "threat", min = 0.1, max = 1, step = 0.05, fmt = "pct" },
    { slider = "threatBgAlpha",   label = "Background", tab = "threat", sub = "threat", min = 0, max = 1, step = 0.05, fmt = "pct" },
    { key = "threatWarn",         label = "Warn before I pull aggro", tab = "threat", sub = "threat",
      tip = "A warning as your threat nears the tank's. Quiet whenever your group role is Tank." },
    { key = "threatWarnSound",    label = "With a sound", tab = "threat", sub = "threatWarn" },
    { sound = "threatWarnSoundID", label = "Sound", tab = "threat", sub = "threatWarnSound",
      default = "Raid warning", play = function() if ns.PlayThreatWarning then ns.PlayThreatWarning() end end,
      stop = function() if ns.StopThreatWarning then ns.StopThreatWarning() end end },
    { slider = "threatWarnAt",    label = "Warn at", tab = "threat", sub = "threatWarn", min = 50, max = 100, step = 5, fmt = "%" },
    { header = "When to show", tab = "threatwhen" },
    { key = "threatSolo",         label = "When solo", tab = "threatwhen", sub = "threat" },
    { key = "threatParty",        label = "In a party", tab = "threatwhen", sub = "threat" },
    { key = "threatRaid",         label = "In a raid", tab = "threatwhen", sub = "threat" },
    { key = "threatOutOfCombat",  label = "Out of combat too", tab = "threatwhen", sub = "threat" },
    { key = "threatShowEmpty",    label = "Before anyone has threat", tab = "threatwhen", sub = "threat" },
    { key = "threatTargetTarget", label = "Friend targeted: their target", tab = "threatwhen", sub = "threat",
      tip = "With a friendly player targeted, show threat on whatever they are fighting." },
    { slider = "threatShowAbove", label = "Only once my threat is over", tab = "threatwhen", sub = "threat", min = 0, max = 100, step = 5, fmt = "%", zero = "always" },
    { slider = "threatLinger",    label = "Stay up after the fight", tab = "threatwhen", sub = "threat", min = 0, max = 30, step = 1, fmt = "s" },
    { header = "Where", tab = "threatwhen", newColumn = true },
    { key = "threatWorld",        label = "Open world", tab = "threatwhen", sub = "threat" },
    { key = "threatDungeon",      label = "Dungeons", tab = "threatwhen", sub = "threat" },
    { key = "threatRaidZone",     label = "Raids", tab = "threatwhen", sub = "threat" },
    { key = "threatPvP",          label = "Battlegrounds and arenas", tab = "threatwhen", sub = "threat" },
    { header = "While you tank", tab = "threatnp" },
    { key = "nameplateThreat",  label = "Color enemy nameplates by aggro (tanking)", tab = "threatnp",
      tip = "While you are the tank (your group role, or the tank role ticked in the group finder), enemy nameplates take "
         .. "a color for who has aggro. Otherwise they keep their normal colors. Pick each color; untick one to leave that case alone. "
         .. "/chair threat nameplates probe says whether this client can read it in combat." },
    { key = "npMine",      label = "I have aggro", tab = "threatnp", sub = "nameplateThreat",
      swatch = { "npMineR", "npMineG", "npMineB" } },
    { key = "npChanging",  label = "Aggro changing", tab = "threatnp", sub = "nameplateThreat",
      swatch = { "npChangingR", "npChangingG", "npChangingB" },
      tip = "Someone is about to take it, or about to lose it." },
    { key = "npNonTank",   label = "A non-tank has aggro", tab = "threatnp", sub = "nameplateThreat",
      swatch = { "npNonTankR", "npNonTankG", "npNonTankB" },
      tip = "On a group member whose role is not Tank." },
    { key = "npOtherTank", label = "Another tank has aggro", tab = "threatnp", sub = "nameplateThreat",
      swatch = { "npOtherTankR", "npOtherTankG", "npOtherTankB" } },
    { header = "Threat on nameplates", tab = "threatnp" },
    { key = "npThreatText", label = "Show threat % on enemy nameplates", tab = "threatnp",
      tip = "During combat, a threat % inside each enemy nameplate's health bar, so a whole pack reads at a glance. "
         .. "As the tank: the highest threat behind you (100% pulls it off you), or, when someone else has it, "
         .. "their name and your % toward taking it back, in red. Otherwise: your own threat on every mob "
         .. "in the fight, 0% on one you have not hit yet. "
         .. "Green under 70%, amber to 90%, red past it." },
    { choice = "npThreatTextAlign", label = "Position", tab = "threatnp", sub = "npThreatText",
      values = { { value = "LEFT", text = "left" }, { value = "CENTER", text = "center" },
                 { value = "RIGHT", text = "right" } } },
    { header = "Combo points", tab = "threatnp", classes = { ROGUE = true, DRUID = true } },
    { key = "npComboPoints", label = "Show combo points on my target's nameplate", tab = "threatnp",
      classes = { ROGUE = true, DRUID = true },
      tip = "Your combo points (a druid's in Cat Form) as a row of pips along the bottom of your target's nameplate health bar. "
         .. "/chair threat combo says what the client reports and why the pips did or did not show." },
}
-- Read by the welcome window (labels and tips for its switches) and by the
-- menu's search box. Nothing outside this file changes it.
ns.ROWS = ROWS

-- The menu's pages, top to bottom as the sidebar lists them. `indent` hangs a
-- page under the one above it: the threat meter has three. "plus" and "arrow"
-- are the old names of pages that are now split or merged, still accepted
-- from anything that asks for them.
local PAGES = {
    { key = "general",    label = "Home" },
    { key = "quests",     label = "Quests & NPCs" },
    { key = "shopping",   label = "Buying & selling" },
    { key = "groups",     label = "Groups & people" },
    { key = "chat",       label = "Chat" },
    { key = "comfort",    label = "Looting & comfort" },
    { key = "travel",     label = "Travel" },
    { key = "osd",        label = "Info bar" },
    { key = "threat",     label = "Threat meter" },
    { key = "threatwhen", label = "When & where",     indent = true },
    { key = "threatnp",   label = "Nameplates",       indent = true },
}
local PAGE_ALIASES = { arrow = "travel" }
local PAGE_LABELS = {}
for _, page in ipairs(PAGES) do PAGE_LABELS[page.key] = page.label end

-- A row's tooltip: its own tip, or the description of the module it switches.
-- Whether a row is for this character: a row with `classes` only shows for
-- those classes (combo points are a rogue's and a druid's).
local function RowFits(row)
    if not row.classes then return true end
    local ok, _, class = pcall(_G.UnitClass, "player")
    class = ok and ns.Text(class) or nil
    return class ~= nil and row.classes[class] == true
end
ns.RowFits = RowFits

local function RowTip(row)
    if row.tip then return row.tip end
    local key = row.key or row.slider or row.choice
    local module = key and ns.modules and ns.modules[key]
    return module and module.desc or nil
end
ns.RowTip = RowTip

local function AttachTip(frame, row)
    local text = RowTip(row)
    if not (frame and text) then return end
    pcall(frame.HookScript, frame, "OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        pcall(function()
            tip:SetOwner(self, "ANCHOR_RIGHT")
            tip:AddLine(row.label, 1, 0.82, 0)
            tip:AddLine(text, 1, 1, 1, true)
            tip:Show()
        end)
    end)
    pcall(frame.HookScript, frame, "OnLeave", function()
        if _G.GameTooltip then pcall(_G.GameTooltip.Hide, _G.GameTooltip) end
    end)
end
ns.RowTip = RowTip

-- What a slider's label says about its value.
local function SliderText(row, value)
    value = ns.Num(value) or 0
    local shown
    if row.zero and value == 0 then
        shown = row.zero
    elseif row.fmt == "pct" then
        shown = math.floor(value * 100 + 0.5) .. "%"
    elseif row.fmt == "%" then
        shown = math.floor(value + 0.5) .. "%"
    elseif row.fmt == "s" then
        shown = math.floor(value + 0.5) .. "s"
    elseif row.fmt == "sec" then
        shown = string.format("%.2fs", value)
    elseif row.fmt == "g" then
        shown = math.floor(value + 0.5) .. "g"
    elseif row.fmt == "x" then
        shown = string.format("%.2f", value)
    else
        shown = tostring(math.floor(value + 0.5))
    end
    return row.label .. ": " .. shown
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------

local panel
local checkboxes = {}
local headers = {}
local moveButton
local tabButtons = {}
local osdOnlyWidgets = {}
local threatOnlyWidgets = {}
-- Widgets that belong to one page, by page. The older per-page lists above
-- work the same way; new pages use this.
local pageWidgets = {}
for _, page in ipairs(PAGES) do pageWidgets[page.key] = {} end
local choices = {}
local soundRows = {}
local swatches = {}
local osdItemRows = {}
ns.osdItemRows = osdItemRows      -- for the tests, which drag rows about
local arrowMoveButton
local copyChoice = { index = 1 }
local sliders = {}
local refreshing = false
local threatMoveButton, threatPreviewButton
local currentTab = "general"

-- The page of another part currently hosted in this window, if any. See
-- "Hosted pages" below.
local hosted
local navWidgets = {}
local partButtons = {}
local baseWidth, baseHeight, sidebarHeight
local EMBED_TOP = 44
-- The page list down the left. Pages, and the other parts' settings hosted
-- in the menu, all sit to its right.
local SIDEBAR = 160

local function MakeButton(parent, width, text)
    local button
    local ok = pcall(function()
        button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    end)
    if not (ok and button) then
        -- Same fallback reasoning as the checkboxes: a missing template is a
        -- hard error at load, so the panel has to be able to build itself out
        -- of nothing but a frame and two textures.
        button = CreateFrame("Button", nil, parent)
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.22, 0.18, 0.32, 1)
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.12)
    end
    button:SetSize(width, 22)

    -- The template supplies its own font string, but not under a name that has
    -- been stable across these clients, so the label is always ours.
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    button.labelText = label

    return button
end
ns.MakeButton = MakeButton

-- Sliders have their own template history, so the same fallback applies: ask
-- for the pretty one, build a plain one when it is not there.
local function MakeSlider(parent, width, low, high, step)
    local slider
    local ok = pcall(function()
        slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    end)
    if not (ok and slider) then
        slider = CreateFrame("Slider", nil, parent)
        local track = slider:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints()
        track:SetColorTexture(0.18, 0.15, 0.26, 1)
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(width, 16)
    slider:SetMinMaxValues(low, high)
    slider:SetValueStep(step)
    if slider.SetObeyStepOnDrag then pcall(slider.SetObeyStepOnDrag, slider, true) end

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 2)
    slider.labelText = label

    return slider
end

local function MakeCheckButton(parent)
    local cb
    for _, template in ipairs({ "UICheckButtonTemplate", "ChatConfigCheckButtonTemplate" }) do
        local ok = pcall(function()
            cb = CreateFrame("CheckButton", nil, parent, template)
        end)
        if ok and cb then return cb end
        cb = nil
    end
    -- No template answered, so build the thing by hand out of the same art.
    cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(24, 24)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    return cb
end
ns.MakeCheckButton = MakeCheckButton

local function RefreshPanel()
    if not panel then return end
    -- While another part's page is hosted, none of this window's own pages is
    -- showing: everything below is laid out for a page called "", which no
    -- widget belongs to. The hosted window is not fully opaque, and the page
    -- underneath used to show through it.
    local realTab = currentTab
    if hosted then currentTab = "" end
    for key, entry in pairs(checkboxes) do
        local onThisTab = (entry.tab == currentTab)
        entry.check:SetShown(onThisTab)
        entry.label:SetShown(onThisTab)

        if onThisTab then
            if entry.get then
                local ok, value = pcall(entry.get)
                entry.check:SetChecked(ok and value and true or false)
            else
                entry.check:SetChecked(ns.IsEnabled(key))
            end

            -- A sub-option of a feature that is off still holds its own value,
            -- but it is not doing anything, and showing it bright white
            -- alongside live options says otherwise.
            local parentOn = (not entry.sub) or ns.IsEnabled(entry.sub)
            -- A setting another one overrides is grayed while that one is on.
            if entry.blockedBy and ns.IsEnabled(entry.blockedBy) then parentOn = false end
            entry.check:SetEnabled(parentOn)
            entry.label:SetTextColor(parentOn and 1 or 0.5,
                                     parentOn and 1 or 0.5,
                                     parentOn and 1 or 0.5)
        end
    end

    for _, entry in ipairs(headers) do
        entry.fs:SetShown(entry.tab == currentTab)
    end

    for _, widget in ipairs(osdOnlyWidgets) do
        widget:SetShown(currentTab == "osd")
    end
    for _, widget in ipairs(threatOnlyWidgets) do
        widget:SetShown(currentTab == "threat")
    end
    for tab, list in pairs(pageWidgets) do
        for _, widget in ipairs(list) do widget:SetShown(currentTab == tab) end
    end

    for key, entry in pairs(choices) do
        local onThisTab = (entry.tab == currentTab)
        entry.label:SetShown(onThisTab)
        entry.prev:SetShown(onThisTab)
        entry.next:SetShown(onThisTab)
        if onThisTab then
            local value, text = ns.Get(key), nil
            for _, option in ipairs(entry.row.values) do
                if option.value == value then text = option.text end
            end
            local parentOn = (not entry.sub) or ns.IsEnabled(entry.sub)
            entry.label:SetText(entry.row.label .. ": |cffffffff" .. (text or tostring(value)) .. "|r")
            entry.label:SetTextColor(parentOn and 1 or 0.5, parentOn and 0.82 or 0.5,
                                     parentOn and 0 or 0.5)
        end
    end

    for key, entry in pairs(swatches) do
        local onThisTab = (entry.tab == currentTab)
        entry.button:SetShown(onThisTab)
        if onThisTab then
            entry.button.fill:SetColorTexture(ns.Num(ns.Get(entry.keys[1])) or 1,
                ns.Num(ns.Get(entry.keys[2])) or 1, ns.Num(ns.Get(entry.keys[3])) or 1, 1)
        end
    end

    for key, entry in pairs(soundRows) do
        local onThisTab = (entry.tab == currentTab)
        for _, widget in ipairs({ entry.label, entry.choose, entry.play, entry.stop }) do
            widget:SetShown(onThisTab)
        end
        if onThisTab then
            local value = ns.Get(key)
            local sounds = Chaircraft.ChairAuras and Chaircraft.ChairAuras.Sounds
            local name = entry.row.default
            if type(value) == "string" and value ~= "" then
                name = (sounds and sounds.Label and sounds:Label(value)) or value
            end
            local parentOn = (not entry.sub) or ns.IsEnabled(entry.sub)
            entry.fullName = tostring(name)
            entry.label:SetText(entry.row.label .. ": |cffffffff" .. tostring(name) .. "|r")
            entry.label:SetTextColor(parentOn and 1 or 0.5, parentOn and 0.82 or 0.5,
                                     parentOn and 0 or 0.5)
        end
    end

    -- The display can be arranged by dragging its items while this page is up.
    if ns.SetOSDArranging then
        ns.SetOSDArranging(panel:IsShown() and currentTab == "osd")
    end

    -- The OSD items, laid out in their saved order.
    if osdItemRows.top and ns.OSDOrder then
        local on = currentTab == "osd"
        local parentOn = ns.IsEnabled("osd")
        local order = ns.OSDOrder()
        local dividers = 0
        for i, item in ipairs(order) do
            local y = osdItemRows.top - (i - 1) * 24
            local row
            if item.divider then
                -- Divider rows are a pool, handed out in order; each is told
                -- which divider it stands for this time.
                dividers = dividers + 1
                row = osdItemRows.dividers[dividers]
                if row then row.key = item.key end
            else
                -- Other addons' feeds turn up after the page is built, so
                -- their rows are made the first time they are needed.
                row = osdItemRows[item.key]
                if not row and osdItemRows.MakeRow then row = osdItemRows.MakeRow(item) end
                if row then
                    row.check:SetChecked(ns.OSDItemOn(item))
                    row.check:SetEnabled(parentOn)
                end
            end
            if row then
                row.check:ClearAllPoints()
                row.check:SetPoint("TOPLEFT", osdItemRows.x, y)
                row.label:SetTextColor(parentOn and 1 or 0.5, parentOn and 1 or 0.5,
                                       parentOn and 1 or 0.5)
                for _, widget in ipairs({ row.check, row.label, row.up, row.down, row.handle }) do
                    widget:SetShown(on)
                end
            end
        end
        for n = dividers + 1, #osdItemRows.dividers do
            local row = osdItemRows.dividers[n]
            for _, widget in ipairs({ row.check, row.label, row.up, row.down, row.handle }) do
                widget:Hide()
            end
        end
        local add = osdItemRows.addButton
        if add then
            add:SetShown(on)
            add:SetEnabled(dividers < (ns.OSD_MAX_DIVIDERS or 30))
        end
        if osdItemRows.SetContentHeight then
            osdItemRows.SetContentHeight(#order * 24 + 4, on)
        end
    end

    if arrowMoveButton and arrowMoveButton.labelText then
        arrowMoveButton.labelText:SetText(
            ns.IsEnabled("arrowLocked") and "Move arrow" or "Lock arrow")
    end

    if copyChoice.label then
        local list = ns.OtherCharacters and ns.OtherCharacters() or {}
        if copyChoice.index > #list then copyChoice.index = 1 end
        local pick = list[copyChoice.index]
        copyChoice.label:SetText(pick and ("|cffffffff" .. pick.label .. "|r")
            or "|cff808080no other characters yet|r")
    end

    -- Setting a slider's value fires its OnValueChanged, which would write the
    -- setting straight back and re-apply everything; `refreshing` stops that.
    refreshing = true
    for key, entry in pairs(sliders) do
        local onThisTab = (entry.tab == currentTab)
        entry.slider:SetShown(onThisTab)
        entry.label:SetShown(onThisTab)
        if onThisTab then
            local value = ns.Num(ns.Get(key)) or entry.row.min
            pcall(entry.slider.SetValue, entry.slider, value)
            entry.label:SetText(SliderText(entry.row, value))
            local parentOn = (not entry.sub) or ns.IsEnabled(entry.sub)
            pcall(parentOn and entry.slider.Enable or entry.slider.Disable, entry.slider)
            entry.label:SetTextColor(parentOn and 1 or 0.5, parentOn and 0.82 or 0.5,
                                     parentOn and 0 or 0.5)
        end
    end
    refreshing = false

    if threatMoveButton and threatMoveButton.labelText then
        threatMoveButton.labelText:SetText(
            ns.IsEnabled("threatLocked") and "Move / resize" or "Lock meter")
    end
    if threatPreviewButton and threatPreviewButton.labelText then
        threatPreviewButton.labelText:SetText(
            ns.threatPreview and "End preview" or "Preview")
    end

    if moveButton and moveButton.labelText then
        -- The button says what pressing it will do, not what the state is.
        moveButton.labelText:SetText(
            ns.IsEnabled("osdLocked") and "Move display" or "Lock display")
    end

    -- The page on show is lit in the sidebar: one of this window's own, or
    -- the part whose settings are hosted.
    local function Light(button, selected)
        button.selected:SetShown(selected)
        button.mark:SetShown(selected)
        button.labelText:SetTextColor(selected and 1 or 0.86, selected and 0.82 or 0.86,
                                      selected and 0 or 0.86)
    end
    for tabKey, button in pairs(tabButtons) do
        Light(button, not hosted and tabKey == realTab)
    end
    for part, button in pairs(partButtons) do
        Light(button, hosted ~= nil and hosted.part == part)
    end
    currentTab = realTab
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------
-- The box in the menu's title bar. Finds any option by its label or its
-- tooltip, across every page, plus the other parts by name and whatever
-- options a part lists for searching (part.Search in Suite/Namespace.lua).

-- Results for a query, best first: label hits before tooltip-only hits.
-- Under two letters there is nothing to show.
function ns.SearchSettings(query)
    query = tostring(query or ""):lower():match("^%s*(.-)%s*$")
    if #query < 2 then return {} end
    local function Has(text)
        return type(text) == "string" and text:lower():find(query, 1, true) ~= nil
    end
    local byLabel, byTip = {}, {}
    for _, row in ipairs(ROWS) do
        local label = row.label or row.action
        if label and not row.header and RowFits(row) then
            local page = PAGE_LABELS[row.tab] or row.tab
            if Has(label) then
                byLabel[#byLabel + 1] = { label = label, where = page, row = row }
            elseif Has(RowTip(row)) then
                byTip[#byTip + 1] = { label = label, where = page, row = row }
            end
        end
    end
    for _, part in ipairs(Chaircraft and Chaircraft.parts or {}) do
        if part.key ~= "chairplus" then
            if Has(part.title) or Has(part.blurb) then
                byLabel[#byLabel + 1] = { label = part.title, where = "Page", part = part }
            end
            local ok, entries = pcall(function() return part.Search and part.Search() or {} end)
            for _, entry in ipairs(ok and entries or {}) do
                if Has(entry.label) then
                    byLabel[#byLabel + 1] = { label = entry.label, where = part.title, part = part, open = entry.open }
                end
            end
        end
    end
    for _, hit in ipairs(byTip) do byLabel[#byLabel + 1] = hit end
    return byLabel
end

-- A moment's highlight behind the row a search went to.
local flash
local function Flash(widget)
    if not (panel and widget) then return end
    if not flash then
        flash = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
        flash:SetColorTexture(1, 0.82, 0, 0.22)
    end
    flash:ClearAllPoints()
    flash:SetPoint("LEFT", widget, "LEFT", -4, 0)
    flash:SetSize(236, 26)
    flash:Show()
    flash.shownAt = (GetTime and GetTime()) or 0
    local shownAt = flash.shownAt
    ns.After(1.5, function()
        if flash and flash.shownAt == shownAt then flash:Hide() end
    end)
end

-- Takes you to a result: its page, with the row flashed, or the part's page.
function ns.GoToSetting(result)
    if type(result) ~= "table" then return end
    if result.row then
        ns.OpenPanel(result.row.tab)
        local key = result.row.key or result.row.slider
        local widget = (checkboxes[key] and checkboxes[key].check) or (sliders[key] and sliders[key].slider)
        Flash(widget)
    elseif result.part then
        pcall(result.part.Open)
        if result.open then pcall(result.open) end
    end
end

local function BuildSearch(close)
    local RESULTS = 8
    local box = CreateFrame("EditBox", nil, panel)
    box:SetSize(150, 20)
    box:SetPoint("RIGHT", close, "LEFT", -8, 0)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetMaxLetters(40)
    box:SetTextInsets(6, 6, 0, 0)
    local boxBg = box:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints()
    boxBg:SetColorTexture(1, 1, 1, 0.08)
    local hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 6, 0)
    hint:SetText("Search options")

    local list = CreateFrame("Frame", nil, panel)
    list:SetSize(270, 8)
    list:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -2)
    pcall(list.SetFrameLevel, list, (ns.Num(panel:GetFrameLevel()) or 1) + 30)
    local listBg = list:CreateTexture(nil, "BACKGROUND")
    listBg:SetAllPoints()
    listBg:SetColorTexture(0.08, 0.07, 0.12, 0.98)
    list:Hide()
    list.buttons = {}
    for i = 1, RESULTS do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(262, 20)
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.1)
        b.label = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        b.label:SetPoint("LEFT", 4, 0)
        b.label:SetWidth(180)
        b.label:SetJustifyH("LEFT")
        b.where = b:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        b.where:SetPoint("RIGHT", -4, 0)
        b:SetScript("OnClick", function(self)
            local result = self.result
            box:SetText("")
            box:ClearFocus()
            list:Hide()
            ns.GoToSetting(result)
        end)
        list.buttons[i] = b
    end
    list.none = list:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    list.none:SetPoint("TOPLEFT", 8, -8)
    list.none:SetText("Nothing matches.")

    local results = {}
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        hint:SetShown(text == "" and not self:HasFocus())
        results = ns.SearchSettings(text)
        if #text:gsub("%s", "") < 2 then list:Hide() return end
        for i, b in ipairs(list.buttons) do
            local r = results[i]
            b.result = r
            if r then
                b.label:SetText(r.label)
                b.where:SetText(r.where or "")
                b:Show()
            else
                b:Hide()
            end
        end
        list.none:SetShown(#results == 0)
        list:SetHeight(8 + math.max(1, math.min(#results, RESULTS)) * 20)
        list:Show()
    end)
    box:SetScript("OnEditFocusGained", function() hint:Hide() end)
    box:SetScript("OnEditFocusLost", function(self) hint:SetShown((self:GetText() or "") == "") end)
    box:SetScript("OnEnterPressed", function(self)
        local first = results[1]
        self:SetText("")
        self:ClearFocus()
        list:Hide()
        if first then ns.GoToSetting(first) end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        list:Hide()
    end)
    panel.search, panel.searchList = box, list
end

local function BuildPanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "ChairPlusPanel", UIParent)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetPoint("CENTER")

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.94)

    local function Edge(point1, point2, w, h)
        local t = panel:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.45, 0.35, 0.7, 0.9)
        t:SetPoint(point1)
        t:SetPoint(point2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 2)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    Edge("TOPLEFT", "BOTTOMLEFT", 2, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 2, nil)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("ChairCraft v" .. ((Chaircraft and Chaircraft.version) or "?"))

    local close = CreateFrame("Button", nil, panel)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -8, -8)
    local closeText = close:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    closeText:SetAllPoints()
    closeText:SetText("x")
    close:SetScript("OnClick", function() panel:Hide() end)
    BuildSearch(close)

    ---------------------------------------------------------------------------
    -- Sidebar
    ---------------------------------------------------------------------------
    -- Every page down the left, one topic each, then the other parts of the
    -- suite under their own heading. A page of this window shows beside it;
    -- a part's settings window is hosted beside it (see "Hosted pages"): the
    -- part keeps building its window exactly as before, it is only parented
    -- here. The sidebar stays up either way, so any page is one click away.
    local shade = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
    shade:SetColorTexture(1, 1, 1, 0.035)
    shade:SetPoint("TOPLEFT", 2, -EMBED_TOP)
    shade:SetPoint("BOTTOMLEFT", 2, 2)
    shade:SetWidth(SIDEBAR - 8)
    local rule = panel:CreateTexture(nil, "BORDER")
    rule:SetColorTexture(0.45, 0.35, 0.7, 0.5)
    rule:SetPoint("TOPLEFT", SIDEBAR - 6, -EMBED_TOP)
    rule:SetPoint("BOTTOMLEFT", SIDEBAR - 6, 2)
    rule:SetWidth(1)

    local sideY = -EMBED_TOP - 6
    local function SideButton(text, indent, onClick)
        local button = CreateFrame("Button", nil, panel)
        button:SetSize(SIDEBAR - 20, 22)
        button:SetPoint("TOPLEFT", 8, sideY)
        local selected = button:CreateTexture(nil, "BACKGROUND", nil, 2)
        selected:SetAllPoints()
        selected:SetColorTexture(0.62, 0.49, 1, 0.22)
        selected:Hide()
        button.selected = selected
        local mark = button:CreateTexture(nil, "ARTWORK")
        mark:SetColorTexture(1, 0.82, 0, 1)
        mark:SetPoint("TOPLEFT")
        mark:SetPoint("BOTTOMLEFT")
        mark:SetWidth(3)
        mark:Hide()
        button.mark = mark
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        local label = button:CreateFontString(nil, "ARTWORK",
            indent and "GameFontHighlightSmall" or "GameFontHighlight")
        label:SetPoint("LEFT", indent and 22 or 10, 0)
        label:SetPoint("RIGHT", -4, 0)
        label:SetJustifyH("LEFT")
        pcall(label.SetWordWrap, label, false)
        label:SetText(text)
        button.labelText = label
        button:SetScript("OnClick", onClick)
        sideY = sideY - 22
        navWidgets[#navWidgets + 1] = button
        return button
    end

    for _, page in ipairs(PAGES) do
        local key = page.key
        tabButtons[key] = SideButton(page.label, page.indent, function()
            if hosted then ns.ClosePage() end
            currentTab = key
            RefreshPanel()
        end)
    end

    -- The other parts of the suite, read from the suite table so that adding a
    -- part never means editing this file. Guarded so ChairPlus still builds a
    -- panel if it is ever loaded without the suite around it.
    if Chaircraft and Chaircraft.parts then
        local tools = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        tools:SetPoint("TOPLEFT", 18, sideY - 12)
        tools:SetText("TOOLS")
        navWidgets[#navWidgets + 1] = tools
        sideY = sideY - 30

        for _, part in ipairs(Chaircraft.parts) do
            if part.key ~= "chairplus" then
                partButtons[part] = SideButton((part.title:gsub("^Chair", "")), false, function()
                    local ok, opened = pcall(part.Open)
                    if not ok or not opened then
                        ns.Print("|cffff5555" .. part.title .. " did not answer.|r "
                            .. "If " .. part.route .. " is also silent, it failed to load.")
                    end
                end)
            end
        end
    end
    sidebarHeight = -sideY + 12

    ---------------------------------------------------------------------------
    -- Option rows
    ---------------------------------------------------------------------------
    -- Laid out per page: each page starts its own two columns, so a short
    -- page does not inherit the tall page's gaps. Every page opens with its
    -- name, large, the way the sidebar says it.
    local COL_X = { SIDEBAR + 16, SIDEBAR + 250 }
    local TOP = -76
    local tabY, tabCol = {}, {}
    for _, page in ipairs(PAGES) do
        tabY[page.key] = { TOP, TOP }
        tabCol[page.key] = 1
        local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        heading:SetPoint("TOPLEFT", COL_X[1], -EMBED_TOP - 6)
        heading:SetText(page.label)
        pageWidgets[page.key][#pageWidgets[page.key] + 1] = heading
    end

    local fitting = {}
    for _, row in ipairs(ROWS) do
        if RowFits(row) then fitting[#fitting + 1] = row end
    end
    for _, row in ipairs(fitting) do
        local tab = row.tab
        local y = tabY[tab]

        -- A header marked newColumn starts the page's second column. No page
        -- breaks a section across columns.
        if row.newColumn then tabCol[tab] = 2 end
        local col = tabCol[tab]

        if row.sound then
            -- A sound from the auras' list, picked in the auras' own picker.
            local indent = row.sub and 16 or 0
            local key = row.sound
            local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            label:SetPoint("TOPLEFT", COL_X[col] + indent + 4, y[col] - 4)
            label:SetWidth(220 - indent)
            label:SetJustifyH("LEFT")
            -- One line, cut short with "..." -- a long file name wrapped onto a
            -- second line, which sat behind the buttons under it. The whole
            -- name is on the Choose button's tooltip.
            pcall(label.SetWordWrap, label, false)
            pcall(label.SetMaxLines, label, 1)
            local choose = MakeButton(panel, 80, "Choose...")
            choose:SetPoint("TOPLEFT", COL_X[col] + indent + 4, y[col] - 22)
            choose:SetScript("OnClick", function()
                local sounds = Chaircraft.ChairAuras and Chaircraft.ChairAuras.Sounds
                if not (sounds and sounds.Open) then
                    ns.Print("The sound list lives in ChairAuras, which did not load.")
                    return
                end
                sounds:Open(ns.Get(key), "Master", function(value)
                    ns.Set(key, value or "")
                    RefreshPanel()
                end)
            end)
            local play = MakeButton(panel, 50, "Play")
            play:SetPoint("LEFT", choose, "RIGHT", 4, 0)
            play:SetScript("OnClick", function() if row.play then row.play() end end)
            local stop = MakeButton(panel, 50, "Stop")
            stop:SetPoint("LEFT", play, "RIGHT", 4, 0)
            stop:SetScript("OnClick", function() if row.stop then row.stop() end end)
            soundRows[key] = { label = label, choose = choose, play = play, stop = stop, row = row,
                               sub = row.sub, tab = tab }
            local entry = soundRows[key]
            choose:SetScript("OnEnter", function(self)
                local tip = _G.GameTooltip
                if not (tip and entry.fullName) then return end
                pcall(function()
                    tip:SetOwner(self, "ANCHOR_RIGHT")
                    tip:AddLine(row.label, 1, 0.82, 0)
                    tip:AddLine(entry.fullName, 1, 1, 1, true)
                    tip:Show()
                end)
            end)
            choose:SetScript("OnLeave", function()
                if _G.GameTooltip then pcall(_G.GameTooltip.Hide, _G.GameTooltip) end
            end)
            y[col] = y[col] - 48
        elseif row.choice then
            local indent = row.sub and 16 or 0
            local key = row.choice
            local prev = MakeButton(panel, 22, "<")
            prev:SetPoint("TOPLEFT", COL_X[col] + indent, y[col])
            local nextButton = MakeButton(panel, 22, ">")
            nextButton:SetPoint("LEFT", prev, "RIGHT", 2, 0)
            local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            label:SetPoint("LEFT", nextButton, "RIGHT", 6, 0)
            label:SetJustifyH("LEFT")
            local function Step(delta)
                local values = row.values
                local at = 1
                for i, option in ipairs(values) do
                    if option.value == ns.Get(key) then at = i end
                end
                at = (at - 1 + delta) % #values + 1
                ns.Set(key, values[at].value)
                RefreshPanel()
            end
            prev:SetScript("OnClick", function() Step(-1) end)
            nextButton:SetScript("OnClick", function() Step(1) end)
            AttachTip(prev, row)
            AttachTip(nextButton, row)
            choices[key] = { label = label, prev = prev, next = nextButton, row = row,
                             sub = row.sub, tab = tab }
            y[col] = y[col] - 26
        elseif row.slider then
            local indent = row.sub and 16 or 0
            local slider = MakeSlider(panel, 190 - indent, row.min, row.max, row.step)
            slider:SetPoint("TOPLEFT", COL_X[col] + indent + 4, y[col] - 16)
            local key = row.slider
            slider:SetScript("OnValueChanged", function(self, value)
                if refreshing then return end
                value = ns.Num(value) or row.min
                value = math.floor(value / row.step + 0.5) * row.step
                value = ns.Num(tonumber(string.format("%.4g", value))) or value
                slider.labelText:SetText(SliderText(row, value))
                if value ~= ns.Get(key) then ns.Set(key, value) end
            end)
            AttachTip(slider, row)
            sliders[key] = { slider = slider, label = slider.labelText, row = row,
                             sub = row.sub, tab = tab }
            y[col] = y[col] - 40
        elseif row.action then
            -- A button on its own line, for something the page opens rather
            -- than a setting it holds.
            local button = MakeButton(panel, 140, row.action)
            button:SetPoint("TOPLEFT", COL_X[col] + 4, y[col] - 2)
            button:SetScript("OnClick", function() pcall(row.run) end)
            AttachTip(button, row)
            pageWidgets[tab][#pageWidgets[tab] + 1] = button
            y[col] = y[col] - 28
        elseif row.note then
            -- A line of small gray text, wrapped to the column.
            local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            fs:SetPoint("TOPLEFT", COL_X[col] + 4, y[col] - 2)
            fs:SetWidth(220)
            fs:SetJustifyH("LEFT")
            fs:SetText(row.note)
            local ok, h = pcall(fs.GetStringHeight, fs)
            h = ok and ns.Num(h) or 12
            y[col] = y[col] - math.max(14, h) - 6
            headers[#headers + 1] = { fs = fs, tab = tab }
        elseif row.header then
            local h = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            h:SetPoint("TOPLEFT", COL_X[col], y[col] - 4)
            h:SetText("|cff9d7cff" .. row.header .. "|r")
            y[col] = y[col] - 24
            -- Headers are shown and hidden with the rows they head, but they
            -- are font strings, not checkboxes, so they live in their own list.
            headers[#headers + 1] = { fs = h, tab = tab }
        else
            local indent = row.sub and 16 or 0
            local check = MakeCheckButton(panel)
            check:SetSize(22, 22)
            check:SetPoint("TOPLEFT", COL_X[col] + indent, y[col])

            local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            label:SetPoint("LEFT", check, "RIGHT", 2, 0)
            label:SetText(row.label)
            label:SetJustifyH("LEFT")

            local key = row.key
            check:SetScript("OnClick", function(self)
                local value = self:GetChecked() and true or false
                if row.set then pcall(row.set, value) else ns.Set(key, value) end
                RefreshPanel()
                -- A window beside the menu may show the same switch.
                if ns.RefreshRestockPanel then pcall(ns.RefreshRestockPanel) end
            end)

            -- A row with more to say than fits in its label says it on hover.
            AttachTip(check, row)

            -- A color swatch after the label, for a row that switches a color
            -- on: clicking it opens the game's color picker.
            if row.swatch then
                local swatch = CreateFrame("Button", nil, panel)
                swatch.settingKey = row.key
                swatch:SetSize(18, 18)
                swatch:SetPoint("LEFT", label, "RIGHT", 8, 0)
                local edge = swatch:CreateTexture(nil, "BACKGROUND")
                edge:SetAllPoints()
                edge:SetColorTexture(0.8, 0.8, 0.8, 1)
                local fill = swatch:CreateTexture(nil, "ARTWORK")
                fill:SetPoint("TOPLEFT", 2, -2)
                fill:SetPoint("BOTTOMRIGHT", -2, 2)
                swatch.fill = fill
                local keys = row.swatch
                swatch:SetScript("OnClick", function()
                    ns.PickColor(ns.Get(keys[1]), ns.Get(keys[2]), ns.Get(keys[3]), function(r, g, b)
                        ns.SetMany({ [key] = true, [keys[1]] = r, [keys[2]] = g, [keys[3]] = b })
                        RefreshPanel()
                    end)
                end)
                swatches[key] = { button = swatch, keys = keys, tab = tab }
            end

            -- A button after the label, for a row whose details live in a
            -- window of their own.
            if row.button then
                local extra = MakeButton(panel, 80, row.button[1])
                extra:SetPoint("LEFT", label, "RIGHT", 8, 0)
                local onClick = row.button[2]
                extra:SetScript("OnClick", function() pcall(onClick) end)
                pageWidgets[tab][#pageWidgets[tab] + 1] = extra
            end

            checkboxes[key] = { check = check, label = label, sub = row.sub, tab = tab,
                                blockedBy = row.blockedBy, get = row.get }
            y[col] = y[col] - 22
        end
    end

    -- Moving the display lives here rather than only on a slash command,
    -- because "drag the thing" is the one setting nobody thinks to look for in
    -- a list of checkboxes. It belongs to the OSD page.
    moveButton = MakeButton(panel, 140, "Move display")
    moveButton:SetPoint("BOTTOMLEFT", COL_X[1], 14)
    moveButton:SetScript("OnClick", function()
        local nowLocked = not ns.IsEnabled("osdLocked")
        ns.Set("osdLocked", nowLocked)
        if nowLocked then
            ns.Print("Display locked where you left it.")
        else
            ns.Print("Drag the display where you want it, then press "
                .. "|cffffd100Lock display|r.")
        end
        RefreshPanel()
    end)

    local resetButton = MakeButton(panel, 140, "Reset position")
    resetButton:SetPoint("BOTTOMLEFT", moveButton, "BOTTOMRIGHT", 8, 0)
    resetButton:SetScript("OnClick", function()
        ns.SetMany(ns.DefaultOSDPosition())
        ns.Print("Display moved back to the center of the screen.")
    end)

    osdOnlyWidgets[#osdOnlyWidgets + 1] = moveButton
    osdOnlyWidgets[#osdOnlyWidgets + 1] = resetButton

    ---------------------------------------------------------------------------
    -- Threat page controls
    ---------------------------------------------------------------------------
    -- Unlocking also shows sample bars, so the meter can be placed and sized
    -- without waiting for a fight. Preview does the same without unlocking,
    -- to judge the look of a meter that is already where it belongs.
    threatMoveButton = MakeButton(panel, 140, "Move / resize")
    threatMoveButton:SetPoint("BOTTOMLEFT", COL_X[1], 14)
    threatMoveButton:SetScript("OnClick", function()
        local nowLocked = not ns.IsEnabled("threatLocked")
        ns.SetMany({ threat = true, threatLocked = nowLocked })
        if nowLocked then
            ns.Print("Threat meter locked where you left it.")
        else
            ns.Print("Drag the threat meter to move it, and its corner to resize it, "
                .. "then press |cffffd100Lock meter|r.")
        end
        RefreshPanel()
    end)

    threatPreviewButton = MakeButton(panel, 110, "Preview")
    threatPreviewButton:SetPoint("BOTTOMLEFT", threatMoveButton, "BOTTOMRIGHT", 8, 0)
    threatPreviewButton:SetScript("OnClick", function()
        if not ns.IsEnabled("threat") then ns.Set("threat", true) end
        if ns.SetThreatPreview then ns.SetThreatPreview(not ns.threatPreview) end
        RefreshPanel()
    end)

    local threatResetButton = MakeButton(panel, 140, "Reset position")
    threatResetButton:SetPoint("BOTTOMLEFT", threatPreviewButton, "BOTTOMRIGHT", 8, 0)
    threatResetButton:SetScript("OnClick", function()
        ns.SetMany({
            threatAnchor = ns.defaults.threatAnchor,
            threatRelAnchor = ns.defaults.threatRelAnchor,
            threatX = ns.defaults.threatX,
            threatY = ns.defaults.threatY,
        })
        ns.Print("Threat meter moved back to the top center.")
    end)

    threatOnlyWidgets[#threatOnlyWidgets + 1] = threatMoveButton
    threatOnlyWidgets[#threatOnlyWidgets + 1] = threatPreviewButton
    threatOnlyWidgets[#threatOnlyWidgets + 1] = threatResetButton

    ---------------------------------------------------------------------------
    -- OSD page: the items, in order
    ---------------------------------------------------------------------------
    -- Each item is a checkbox with ^ and v beside it. The order is the saved
    -- osdOrder; RefreshPanel lays the rows out in it, so moving one is a
    -- matter of saving the new order and refreshing.
    if ns.OSD_ITEMS then
        local x = COL_X[2]
        local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        header:SetPoint("TOPLEFT", x, tabY.osd[2] - 4)
        header:SetText("|cff9d7cffItems, left to right|r")
        headers[#headers + 1] = { fs = header, tab = "osd" }

        -- The rows scroll. Every divider makes the list a row longer, and a
        -- window sized to hold all of them ran off the bottom of the screen.
        -- The view runs down to just above the Add divider button, which
        -- sits under it and never scrolls, so the list gets whatever height
        -- the window has -- at least ten rows' worth.
        local MIN_VIEW = 10 * 24 + 8
        local BOTTOM = 72          -- the add button and the page's own buttons
        local scroll = CreateFrame("ScrollFrame", nil, panel)
        scroll:SetPoint("TOPLEFT", x, tabY.osd[2] - 24)
        scroll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", x, BOTTOM)
        scroll:SetWidth(234)
        local host = CreateFrame("Frame", nil, scroll)
        host:SetSize(234, MIN_VIEW)
        local function ViewHeight()
            local h = ns.Num(scroll:GetHeight())
            if h and h > 24 then return h end
            return MIN_VIEW
        end
        scroll:SetScrollChild(host)
        osdItemRows.scroll, osdItemRows.host = scroll, host

        local bar = CreateFrame("Slider", nil, panel)
        bar:SetOrientation("VERTICAL")
        bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
        bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
        bar:SetWidth(8)
        local track = bar:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints()
        track:SetColorTexture(1, 1, 1, 0.08)
        local thumb = bar:CreateTexture(nil, "OVERLAY")
        thumb:SetColorTexture(0.62, 0.49, 1, 0.8)
        thumb:SetSize(8, 40)
        bar:SetThumbTexture(thumb)
        bar:SetMinMaxValues(0, 0)
        bar:SetValueStep(1)
        bar:SetValue(0)
        bar:Hide()
        osdItemRows.bar = bar

        -- The offset is kept here rather than read back off the frame, so
        -- clamping never depends on what the client last rounded it to.
        osdItemRows.offset, osdItemRows.maxScroll = 0, 0
        local function ScrollTo(value)
            value = math.max(0, math.min(osdItemRows.maxScroll, ns.Num(value) or 0))
            osdItemRows.offset = value
            scroll:SetVerticalScroll(value)
            if (ns.Num(bar:GetValue()) or 0) ~= value then bar:SetValue(value) end
        end
        osdItemRows.ScrollTo = ScrollTo
        bar:SetScript("OnValueChanged", function(_, value) ScrollTo(value) end)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(_, delta)
            ScrollTo(osdItemRows.offset - (ns.Num(delta) or 0) * 48)
        end)

        -- RefreshPanel reports how tall the rows are; the bar only shows when
        -- they do not fit.
        function osdItemRows.SetContentHeight(height, on)
            osdItemRows.lastHeight, osdItemRows.lastOn = height, on
            local view = ViewHeight()
            host:SetHeight(math.max(height, view))
            osdItemRows.maxScroll = math.max(0, height - view)
            bar:SetMinMaxValues(0, osdItemRows.maxScroll)
            ScrollTo(osdItemRows.offset)
            scroll:SetShown(on)
            bar:SetShown(on and osdItemRows.maxScroll > 0)
        end

        osdItemRows.x = 0
        osdItemRows.top = 0
        local function BuildItemRow(item)
            local check = MakeCheckButton(host)
            check:SetSize(22, 22)
            check:SetScript("OnClick", function(self)
                ns.SetOSDItemOn(item, self:GetChecked() and true or false)
                RefreshPanel()
            end)
            local label = host:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            label:SetPoint("LEFT", check, "RIGHT", 2, 0)
            -- Held short of the ^ v buttons: an addon's name can be any length.
            label:SetWidth(160)
            label:SetJustifyH("LEFT")
            pcall(label.SetWordWrap, label, false)
            label:SetText(item.label)
            local down = MakeButton(host, 20, "v")
            down:SetPoint("TOPLEFT", check, "TOPLEFT", 210, 0)
            local up = MakeButton(host, 20, "^")
            up:SetPoint("RIGHT", down, "LEFT", -2, 0)
            local key = item.key
            up:SetScript("OnClick", function() ns.MoveOSDItem(key, -1) RefreshPanel() end)
            down:SetScript("OnClick", function() ns.MoveOSDItem(key, 1) RefreshPanel() end)
            osdItemRows[key] = { check = check, label = label, up = up, down = down, key = key }
            return osdItemRows[key]
        end
        for _, item in ipairs(ns.OSD_ITEMS) do BuildItemRow(item) end

        -- Divider rows: an x to remove it where the checkbox would be.
        osdItemRows.dividers = {}
        for n = 1, ns.OSD_MAX_DIVIDERS or 30 do
            local row = {}
            row.check = MakeButton(host, 22, "x")
            row.check:SetScript("OnClick", function()
                if row.key then ns.RemoveOSDDivider(row.key) end
                RefreshPanel()
            end)
            row.label = host:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
            row.label:SetText("||  Divider")
            row.down = MakeButton(host, 20, "v")
            row.down:SetPoint("TOPLEFT", row.check, "TOPLEFT", 210, 0)
            row.up = MakeButton(host, 20, "^")
            row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
            row.up:SetScript("OnClick", function()
                if row.key then ns.MoveOSDItem(row.key, -1) end
                RefreshPanel()
            end)
            row.down:SetScript("OnClick", function()
                if row.key then ns.MoveOSDItem(row.key, 1) end
                RefreshPanel()
            end)
            for _, widget in ipairs({ row.check, row.label, row.up, row.down }) do widget:Hide() end
            osdItemRows.dividers[n] = row
        end
        -- Dragging a row by its name moves it: a line shows where it will
        -- land, and letting go puts it there. The ^ and v buttons do the same
        -- one step at a time.
        local marker = host:CreateTexture(nil, "OVERLAY")
        marker:SetColorTexture(1, 0.82, 0, 0.9)
        marker:SetSize(230, 2)
        marker:Hide()
        osdItemRows.marker = marker

        local function DropIndex()
            local okC, _, cy = pcall(GetCursorPosition)
            local scale = ns.Num(host:GetEffectiveScale()) or 1
            local top = ns.Num(host:GetTop())
            cy = okC and ns.Num(cy) or nil
            if not (cy and top and scale > 0) then return nil end
            local rel = cy / scale - top
            return math.floor((osdItemRows.top - rel) / 24 + 0.5) + 1
        end
        osdItemRows.DropIndex = DropIndex

        local function Draggable(row)
            local handle = CreateFrame("Button", nil, host)
            handle:SetPoint("TOPLEFT", row.check, "TOPRIGHT", 0, 0)
            handle:SetPoint("BOTTOMRIGHT", row.up, "BOTTOMLEFT", -4, 0)
            handle:RegisterForDrag("LeftButton")
            local glow = handle:CreateTexture(nil, "HIGHLIGHT")
            glow:SetAllPoints()
            glow:SetColorTexture(1, 1, 1, 0.08)
            handle:SetScript("OnDragStart", function(self)
                self:SetScript("OnUpdate", function()
                    -- Held near the top or bottom edge, the list scrolls, so
                    -- a row can be dragged to a place that is out of view.
                    local okC, _, cy = pcall(GetCursorPosition)
                    local scale = ns.Num(scroll:GetEffectiveScale()) or 1
                    local top, bottom = ns.Num(scroll:GetTop()), ns.Num(scroll:GetBottom())
                    cy = okC and ns.Num(cy) or nil
                    if cy and top and bottom and scale > 0 then
                        cy = cy / scale
                        if cy > top - 16 then ScrollTo(osdItemRows.offset - 6)
                        elseif cy < bottom + 16 then ScrollTo(osdItemRows.offset + 6) end
                    end
                    local index = DropIndex()
                    if not index then return end
                    marker:ClearAllPoints()
                    marker:SetPoint("TOPLEFT", host, "TOPLEFT", osdItemRows.x,
                        osdItemRows.top - (index - 1) * 24 + 1)
                    marker:Show()
                end)
            end)
            handle:SetScript("OnDragStop", function(self)
                self:SetScript("OnUpdate", nil)
                marker:Hide()
                local index = DropIndex()
                if index and row.key and ns.MoveOSDItemTo then
                    -- Dropped below itself, the gap it leaves shifts the rest up.
                    local from
                    for i, item in ipairs(ns.OSDOrder()) do
                        if item.key == row.key then from = i end
                    end
                    if from and index > from then index = index - 1 end
                    ns.MoveOSDItemTo(row.key, index)
                end
                RefreshPanel()
            end)
            row.handle = handle
        end
        for _, item in ipairs(ns.OSD_ITEMS) do Draggable(osdItemRows[item.key]) end
        function osdItemRows.MakeRow(item)
            local row = BuildItemRow(item)
            Draggable(row)
            return row
        end
        for _, row in ipairs(osdItemRows.dividers) do Draggable(row) end

        -- Resized with the window, the view has a new height to scroll in.
        scroll:SetScript("OnSizeChanged", function()
            if osdItemRows.lastHeight then
                osdItemRows.SetContentHeight(osdItemRows.lastHeight, osdItemRows.lastOn)
            end
        end)

        osdItemRows.addButton = MakeButton(panel, 120, "Add divider")
        osdItemRows.addButton:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -6)
        osdItemRows.addButton:SetScript("OnClick", function()
            if ns.AddOSDDivider then ns.AddOSDDivider() end
            RefreshPanel()
            -- The new divider goes at the end, so bring the end into view.
            ScrollTo(osdItemRows.maxScroll)
        end)
        osdItemRows.addButton:Hide()

        tabY.osd[2] = tabY.osd[2] - 24 - MIN_VIEW - 6 - 22 - 16
    end

    ---------------------------------------------------------------------------
    -- Travel page: the arrow's controls
    ---------------------------------------------------------------------------
    arrowMoveButton = MakeButton(panel, 140, "Move arrow")
    arrowMoveButton:SetPoint("BOTTOMLEFT", COL_X[1], 14)
    arrowMoveButton:SetScript("OnClick", function()
        local nowLocked = not ns.IsEnabled("arrowLocked")
        ns.SetMany({ arrow = true, arrowLocked = nowLocked })
        ns.Print(nowLocked and "Waypoint arrow locked."
            or "Drag the arrow where you want it, then press |cffffd100Lock arrow|r.")
        RefreshPanel()
    end)
    local arrowResetButton = MakeButton(panel, 140, "Reset position")
    arrowResetButton:SetPoint("BOTTOMLEFT", arrowMoveButton, "BOTTOMRIGHT", 8, 0)
    arrowResetButton:SetScript("OnClick", function()
        ns.SetMany({
            arrowAnchor = ns.defaults.arrowAnchor, arrowRelAnchor = ns.defaults.arrowRelAnchor,
            arrowX = ns.defaults.arrowX, arrowY = ns.defaults.arrowY,
        })
        ns.Print("Waypoint arrow moved back to the top center.")
    end)
    pageWidgets.travel[#pageWidgets.travel + 1] = arrowMoveButton
    pageWidgets.travel[#pageWidgets.travel + 1] = arrowResetButton

    ---------------------------------------------------------------------------
    -- Home page: copying another character's settings
    ---------------------------------------------------------------------------
    -- On the bottom row: it is not a setting of its own, so it sits with the
    -- page's controls rather than in a column of checkboxes. (The minimap icon
    -- size slider that shared the row went when the icon moved into the
    -- minimap ring, where every addon's button is the same size.)
    do
        local x = COL_X[1]
        local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        header:SetPoint("BOTTOMLEFT", x, 36)
        header:SetText("Copy settings from:")

        local prev = MakeButton(panel, 22, "<")
        prev:SetPoint("BOTTOMLEFT", x, 12)
        local nextButton = MakeButton(panel, 22, ">")
        nextButton:SetPoint("LEFT", prev, "RIGHT", 2, 0)
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("LEFT", nextButton, "RIGHT", 6, 0)
        label:SetWidth(112)
        label:SetJustifyH("LEFT")
        copyChoice.label = label
        local function Step(delta)
            local count = #(ns.OtherCharacters and ns.OtherCharacters() or {})
            if count == 0 then return end
            copyChoice.index = (copyChoice.index - 1 + delta) % count + 1
            RefreshPanel()
        end
        prev:SetScript("OnClick", function() Step(-1) end)
        nextButton:SetScript("OnClick", function() Step(1) end)

        local copy = MakeButton(panel, 90, "Import")
        copy:SetPoint("BOTTOMRIGHT", -16, 12)
        copy:SetScript("OnClick", function()
            local list = ns.OtherCharacters and ns.OtherCharacters() or {}
            local pick = list[copyChoice.index]
            if pick then ns.ConfirmCopyCharacter(pick) end
        end)
        for _, widget in ipairs({ header, prev, nextButton, label, copy }) do
            pageWidgets.general[#pageWidgets.general + 1] = widget
        end

        -- Every setting of this character as one line of text, and back.
        local backupHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        backupHeader:SetPoint("BOTTOMLEFT", x, 96)
        backupHeader:SetText("Back up every setting as one line of text:")
        local export = MakeButton(panel, 140, "Export settings")
        export:SetPoint("BOTTOMLEFT", x, 70)
        export:SetScript("OnClick", function() if ns.OpenBackup then ns.OpenBackup("export") end end)
        local import = MakeButton(panel, 140, "Import settings")
        import:SetPoint("LEFT", export, "RIGHT", 8, 0)
        import:SetScript("OnClick", function() if ns.OpenBackup then ns.OpenBackup("import") end end)
        for _, widget in ipairs({ backupHeader, export, import }) do
            pageWidgets.general[#pageWidgets.general + 1] = widget
        end
    end

    -- Sized to the tallest page, so switching tabs never resizes the window
    -- under the cursor.
    local tallest = TOP
    for _, ys in pairs(tabY) do
        tallest = math.min(tallest, ys[1], ys[2])
    end
    -- Tall enough for the sidebar too: a part added to the suite adds a
    -- line to it, and the window grows to hold it rather than clipping it.
    baseWidth = SIDEBAR + 540
    baseHeight = math.max(-tallest + 54, sidebarHeight)
    panel:SetSize(baseWidth, baseHeight)

    -- Closing the window from a hosted page gives the page back to its part,
    -- so the next /chair opens on the main menu.
    -- A preview is for looking at while the options are open; closing them
    -- ends it, so sample bars are never left on screen by accident.
    panel:SetScript("OnHide", function()
        if hosted then ns.ClosePage() end
        if ns.threatPreview and ns.SetThreatPreview then ns.SetThreatPreview(false) end
        if ns.SetOSDArranging then ns.SetOSDArranging(false) end
    end)

    -- Escape closes the window, the same as any other panel. While a page is
    -- hosted, a stand-in takes the window's place in the list the client
    -- closes on Escape, and closing the stand-in means Back -- so the first
    -- Escape returns to the menu and the second closes it. This avoids taking
    -- the keyboard, which in combat would swallow keys meant for moving.
    if type(_G.UISpecialFrames) == "table" then
        tinsert(_G.UISpecialFrames, "ChairPlusPanel")
        local stand = CreateFrame("Frame", "ChairPlusPanelBack", panel)
        stand:Hide()
        stand:SetScript("OnHide", function()
            if hosted and panel:IsShown() then ns.ClosePage() end
        end)
        tinsert(_G.UISpecialFrames, "ChairPlusPanelBack")
        panel.backStand = stand
    end

    -- A frame is shown the moment it is created. Without this the first
    -- /chair built the panel, found it already "shown", and hid it -- so the
    -- menu only appeared on the second press of the command.
    panel:Hide()

    return panel
end

-- A page's key from what was asked for: an old name is mapped to where its
-- settings went. "plus" (the old main page) or nothing at all means the page
-- the menu was last on, and gives nil.
local function PageKey(tab)
    tab = PAGE_ALIASES[tab] or tab
    return PAGE_LABELS[tab] and tab or nil
end

-- Open the menu, optionally on a named page. This is what "/chair" and every
-- nav button go through.
-- Redraw the menu if it is up: the display's own drag reorders the items the
-- OSD page lists.
function ns.RefreshMenu()
    if panel and panel:IsShown() then RefreshPanel() end
end

function ns.OpenPanel(tab)
    BuildPanel()
    local page = PageKey(tab)
    if hosted and (page or tab == "plus") then ns.ClosePage() end
    if page then currentTab = page end
    RefreshPanel()
    panel:Show()
    if ns.SetOSDArranging then ns.SetOSDArranging(currentTab == "osd") end
    return true
end

-- Which of this window's own pages is showing ("general", "osd", ...).
-- Redraws the menu, for windows beside it that change its settings.
function ns.RefreshPanel()
    RefreshPanel()
end

function ns.CurrentPage()
    return currentTab
end

function ns.TogglePanel(tab)
    BuildPanel()
    -- Asking for the page you are already looking at closes the window; asking
    -- for a different one switches to it rather than shutting it in your face.
    local page = PageKey(tab)
    if panel:IsShown() and (page == nil or page == currentTab) and not hosted then
        panel:Hide()
        return true
    end
    return ns.OpenPanel(tab)
end

-------------------------------------------------------------------------------
-- Hosted pages
-------------------------------------------------------------------------------
-- The other parts' settings open inside this window rather than in windows of
-- their own. Each part builds its window exactly as it always has; this takes
-- that window, parents it beside the sidebar below a 44px header, hides the
-- part's own title and close button (the `chairChrome` list each part hangs on
-- its window), and hands it back untouched on Back.
--
-- `part` is an entry from Chaircraft.parts: Window() builds and returns the
-- part's window, Show() fills it and shows it the way the part always has.

local function RemoveSpecial(name)
    local list = _G.UISpecialFrames
    if type(list) ~= "table" then return false end
    for i = #list, 1, -1 do
        if list[i] == name then
            table.remove(list, i)
            return true
        end
    end
    return false
end

local function SetChrome(frame, shown)
    for _, widget in ipairs(frame.chairChrome or {}) do
        if widget.SetShown then widget:SetShown(shown) end
    end
end

function ns.HostedPart()
    return hosted and hosted.part or nil
end

-- For the parts' own ways in -- a gear button, a minimap click, a command --
-- so they open inside this window too. Returns false when the menu cannot host
-- the page, and the caller then opens its own window as before.
function ns.OpenPartPage(token)
    local find = Chaircraft and Chaircraft.FindPart
    local part = find and find(token)
    if not part then return false end
    return ns.OpenPage(part) and true or false
end

-- The page the menu is open on, or nil when it is closed (or showing another
-- part's settings). The arrow uses it to show itself only while being set up.
function ns.PanelPage()
    if not panel or not panel:IsShown() or hosted then return nil end
    return currentTab
end

function ns.HidePanel()
    if panel then panel:Hide() end
end

function ns.ClosePage()
    if not hosted then return end
    local page = hosted
    hosted = nil

    local frame = page.frame
    frame.chairEmbedded = nil
    frame:Hide()
    SetChrome(frame, true)
    frame:SetParent(UIParent)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    if page.movable then frame:SetMovable(true) end
    if page.dragged then frame:RegisterForDrag("LeftButton") end
    if page.special and frame.GetName and frame:GetName() then
        tinsert(_G.UISpecialFrames, frame:GetName())
    end

    if panel then
        if panel.backStand then
            panel.backStand:Hide()
            -- Put the window back in the Escape list on the next frame, not
            -- now: this very often runs from inside the client's walk of that
            -- list, and adding to it mid-walk could let the same Escape close
            -- the window as well.
            ns.After(0, function()
                if hosted then return end
                RemoveSpecial("ChairPlusPanel")
                tinsert(_G.UISpecialFrames, "ChairPlusPanel")
            end)
        end
        panel:SetSize(baseWidth, baseHeight)
        RefreshPanel()
    end
end

function ns.OpenPage(part)
    if type(part) ~= "table" or type(part.Window) ~= "function" then return false end
    BuildPanel()

    if hosted and hosted.part == part then
        panel:Show()
        return true
    end
    if hosted then ns.ClosePage() end

    local ok, frame = pcall(part.Window)
    if not ok or not frame then return false end

    local name = frame.GetName and frame:GetName() or nil
    local okM, movable = pcall(frame.IsMovable, frame)
    hosted = {
        part = part,
        frame = frame,
        movable = okM and movable and true or false,
        dragged = okM and movable and true or false,
        special = name and RemoveSpecial(name) or false,
    }

    frame.chairEmbedded = true
    SetChrome(frame, false)
    -- A part closing its own window while it is hosted (its toggle, a close
    -- command) means closing the page, so the menu is not left empty.
    if not frame.chairHideHooked and frame.HookScript then
        frame.chairHideHooked = true
        frame:HookScript("OnHide", function(self)
            if self.chairEmbedded and hosted and hosted.frame == self
                and panel and panel:IsShown() then
                panel:Hide()
            end
        end)
    end
    frame:SetParent(panel)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", panel, "TOPLEFT", SIDEBAR, -EMBED_TOP)
    pcall(frame.SetFrameStrata, frame, panel:GetFrameStrata())
    pcall(frame.SetFrameLevel, frame, (ns.Num(panel:GetFrameLevel()) or 1) + 5)
    frame:SetMovable(false)
    frame:RegisterForDrag()

    local w = ns.Num(frame:GetWidth()) or baseWidth
    local h = ns.Num(frame:GetHeight()) or baseHeight
    panel:SetSize(SIDEBAR + math.max(w, 300), math.max(h + EMBED_TOP, sidebarHeight or 0))

    -- Swap the window for the stand-in in the Escape list, so Escape means
    -- Back while a page is up.
    if panel.backStand then
        RemoveSpecial("ChairPlusPanel")
        panel.backStand:Show()
    end

    panel:Show()
    RefreshPanel()

    local okShow, err = pcall(part.Show)
    if not okShow then
        ns.Print("|cffff5555" .. (part.title or "That page") .. " failed to open:|r",
            ns.Text(err) or "unknown error")
        ns.ClosePage()
        return false
    end
    -- Anything the part does on show that re-anchors its window is undone here.
    -- Pinned by both corners, so a page that resizes the menu (ChairAuras'
    -- corner grip does) takes the window with it rather than pulling it loose.
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", panel, "TOPLEFT", SIDEBAR, -EMBED_TOP)
    frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    frame:Show()
    return true
end

-- Copy `pick` (from ns.OtherCharacters) over the account's settings, after
-- asking. The other parts read their settings at load, so the UI reloads
-- afterwards when any of them took a copy.
local function DoCopy(pick)
    local parts = ns.CopyCharacter(pick.key)
    if #parts == 0 then
        ns.Print("Nothing to copy from " .. pick.label .. ".")
        return
    end
    ns.Print("Copied " .. table.concat(parts, ", ") .. " settings from " .. pick.label .. ".")
    local others = false
    for _, part in ipairs(parts) do if part ~= "Plus" then others = true end end
    if others then
        if type(_G.ReloadUI) == "function" then
            ReloadUI()
        else
            ns.Print("Type |cffffd100/reload|r to finish.")
        end
    end
end

function ns.ConfirmCopyCharacter(pick)
    if type(_G.StaticPopup_Show) ~= "function" or type(_G.StaticPopupDialogs) ~= "table" then
        DoCopy(pick)
        return
    end
    StaticPopupDialogs["CHAIRCRAFT_COPY_CHARACTER"] = {
        text = "Replace the ChairCraft settings, shared by every character, with " .. pick.label
            .. "'s? The interface reloads afterwards.",
        button1 = "Copy",
        button2 = "Cancel",
        OnAccept = function() DoCopy(pick) end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    StaticPopup_Show("CHAIRCRAFT_COPY_CHARACTER")
end

-- The game's color picker, opened on r, g, b; `done` hears every change as it
-- is dragged, and the original color again on Cancel. The retail engine sets it
-- up with SetupColorPickerAndShow; older clients take the fields directly.
function ns.PickColor(r, g, b, done)
    local picker = _G.ColorPickerFrame
    r, g, b = ns.Num(r) or 1, ns.Num(g) or 1, ns.Num(b) or 1
    if not picker then
        ns.Print("This client has no color picker.")
        return
    end
    local function Current()
        local ok, cr, cg, cb = pcall(picker.GetColorRGB, picker)
        if ok and cr then done(cr, cg, cb) end
    end
    local function Cancel() done(r, g, b) end
    if type(picker.SetupColorPickerAndShow) == "function" then
        pcall(picker.SetupColorPickerAndShow, picker, {
            r = r, g = g, b = b, hasOpacity = false,
            swatchFunc = Current, cancelFunc = Cancel,
        })
        return
    end
    picker.hasOpacity = false
    picker.func = Current
    picker.swatchFunc = Current
    picker.cancelFunc = Cancel
    picker.previousValues = { r, g, b }
    pcall(picker.SetColorRGB, picker, r, g, b)
    if type(_G.ShowUIPanel) == "function" then
        pcall(_G.ShowUIPanel, picker)
    else
        picker:Show()
    end
end

-- What "/chair plus lfg" prints: which group finder this client has and what
-- it is made of, so custom filters can be written against the real thing.
-- Classic Era's newer finder (LFGParentFrame with LFGListingFrame and
-- LFGBrowseFrame, searching through C_LFGList) and the retail engine's
-- (PVEFrame, LFGListFrame) are both asked about.
function ns.LFGProbe()
    ns.LFGProbeBase()
    if ns.LFGProbeListing then ns.LFGProbeListing() end
end

function ns.LFGProbeBase()
    local function yes(v) return v and "|cff55ff55yes|r" or "|cffff5555no|r" end
    ns.Print("group finder:")
    for _, name in ipairs({ "LFGParentFrame", "LFGListingFrame", "LFGBrowseFrame",
                            "LFGFrame", "LFMFrame", "PVEFrame", "LFGListFrame",
                            "GroupFinderFrame" }) do
        local frame = _G[name]
        local shown = frame and frame.IsShown and select(2, pcall(frame.IsShown, frame))
        print(string.format("  %s = %s%s", name, yes(frame ~= nil),
            frame and (shown and " (showing)" or " (hidden)") or ""))
    end
    local browse = _G.LFGBrowseFrame
    if browse then
        local parts = {}
        for key, value in pairs(browse) do
            if type(value) == "table" and type(key) == "string" and value.GetObjectType then
                parts[#parts + 1] = key
            end
        end
        table.sort(parts)
        print("  LFGBrowseFrame parts: " .. (#parts > 0 and table.concat(parts, ", ") or "none"))
    end
    local list = _G.C_LFGList
    print("  C_LFGList = " .. yes(type(list) == "table"))
    if type(list) == "table" then
        local fns = {}
        for key, value in pairs(list) do
            if type(value) == "function" then fns[#fns + 1] = key end
        end
        table.sort(fns)
        print("  C_LFGList has " .. #fns .. " functions: " .. table.concat(fns, ", "))
        local ok, results = pcall(list.GetSearchResults or function() end)
        if ok then
            local count = type(results) == "table" and #results or tostring(results)
            print("  current search results: " .. tostring(count))
        end
    end
    for _, name in ipairs({ "LFGBrowseFrame_UpdateResults", "LFGBrowseSearchEntry_Update",
                            "LFGListSearchPanel_UpdateResults", "LFGListSearchEntry_Update" }) do
        print(string.format("  %s = %s", name, yes(type(_G[name]) == "function")))
    end
end

-- Keep the panel honest when a setting is changed from the command line.
local baseApplyAll = ns.ApplyAll
function ns.ApplyAll(...)
    baseApplyAll(...)
    if panel and panel:IsShown() then RefreshPanel() end
end

-- The minimap icon lives in ChairSnack but is the whole suite's now, so the
-- menu reaches across for it. Guarded at both ends: ChairSnack may not have
-- loaded, and older builds of it may not expose the setter.
function ns.MinimapIconSize()
    local snack = Chaircraft and Chaircraft.ChairSnack
    if not snack or type(snack.GetMinimapDB) ~= "function" then return 24 end
    local ok, db = pcall(snack.GetMinimapDB, snack)
    if not ok or type(db) ~= "table" then return 24 end
    return ns.Num(db.size) or 24
end

function ns.SetMinimapIconSize(size)
    local snack = Chaircraft and Chaircraft.ChairSnack
    if not snack or type(snack.SetMinimapButtonSize) ~= "function" then return end
    pcall(snack.SetMinimapButtonSize, snack, size)
end

-- The learned flight times as source, for pasting into ChairPlus/Flight.lua
-- over ns.flightDefaults. Reached from "/chair plus flights"; the menu button
-- that also opened it was removed once the times were hardcoded.
function ns.ShowFlightTimes()
    -- Called outright, not through an `and`: that truncates a multiple return
    -- to one value and the count comes back nil.
    local text, count
    if ns.FlightExport then text, count = ns.FlightExport() end
    if not text then
        ns.Print("No flight times recorded yet.")
        return
    end

    -- Parked on disk too. The write half of SavedVariables works on this
    -- client even though the read half does not, so a /reload puts this where
    -- it can be read straight out of the file.
    if _G.ChairPlusDB then _G.ChairPlusDB.flightsHint = text end

    if Chaircraft and Chaircraft.ShowTextBox then
        -- Two-way: the box shows what is known and takes back whatever is in
        -- it when Add is pressed, so the catalogue can be built up from other
        -- characters' lists a paste at a time until it is hardcoded.
        Chaircraft.ShowTextBox("Flight times", text, function(typed)
            local added, skipped = ns.ImportFlightTimes(typed)
            if not added then
                ns.Print("|cffff5555Nothing imported:|r", tostring(skipped))
                return
            end
            ns.Print(string.format(
                "Added %d route(s)%s.", added,
                (skipped or 0) > 0
                    and (", left " .. skipped .. " already known alone") or ""))
        end,
        "Paste flight times from anywhere -- this list, another character's, or"
            .. " straight out of SavedVariables -- then press Add. Routes you"
            .. " already have are left alone.",
        "Add")
        ns.Print(count .. " route(s). Also saved to "
            .. "|cffffd100ChairPlusDB.flightsHint|r in your SavedVariables.")
    else
        ns.Print(count .. " route(s):")
        for line in text:gmatch("[^" .. string.char(10) .. "]+") do
            print(line)
        end
    end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function Literal(value)
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "number" then return string.format("%.14g", value) end
    return string.format("%q", tostring(value))
end

local function Shown(value)
    if type(value) == "boolean" then
        return value and "|cff55ff55on|r" or "|cffff5555off|r"
    end
    return "|cffffd100" .. Literal(value) .. "|r"
end

local function PrintStatus()
    ns.Print("v" .. (ns.version or "?") .. " -- options, shared by every character on the account:")

    local listed = {}
    for _, row in ipairs(ROWS) do
        if row.key then
            listed[row.key] = true
            ns.Print("  " .. (row.sub and "  " or "") .. row.key
                .. " = " .. Shown(ns.Get(row.key)))
        end
    end

    -- Everything the panel does not show as a checkbox -- sizes, the position,
    -- the loot delay. Derived from the defaults rather than listed by hand, so
    -- a setting cannot go missing from here by being moved out of the panel.
    local rest = {}
    for key in pairs(ns.defaults) do
        if not listed[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    for _, key in ipairs(rest) do
        ns.Print("  " .. key .. " = " .. Shown(ns.Get(key)))
    end
    if ns.savedWasEmpty then
        ns.Print("|cffffd100This session started with no saved settings.|r "
            .. "That is the client's SavedVariables bug, not a lost file.")
    end
end

local function PrintBake()
    local diffs = ns.Diffs()
    if #diffs == 0 then
        ns.Print("Everything is on its default, so there is nothing to bake.")
        return
    end
    ns.Print("Paste this into |cffffd100ChairPlus\\Config.lua|r over ns.baked to "
        .. "keep these across a client restart:")
    local lines = { "ns.baked = {" }
    for _, diff in ipairs(diffs) do
        lines[#lines + 1] = string.format("    [%q] = %s,", diff.key, Literal(diff.value))
    end
    lines[#lines + 1] = "}"
    -- Printed bare, with no prefix or colour code. These lines are meant to be
    -- dragged out of chat and pasted into a file, and anything in front of them
    -- comes along for the ride.
    for _, line in ipairs(lines) do
        print(line)
    end
    -- Also parked where it can be read off disk after a /reload, since the write
    -- half of SavedVariables works on this client even though the read half
    -- does not.
    local ok, blob = pcall(table.concat, lines, "\n")
    if ok and _G.ChairPlusDB then _G.ChairPlusDB.bakeHint = blob end
end

local function PrintHelp()
    ns.Print("commands:")
    print("  |cffffd100/chair plus|r - open the options panel")
    print("  |cffffd100/chair plus status|r - list every option and its value")
    print("  |cffffd100/chair plus on||off||toggle <option>|r - change one option")
    print("  |cffffd100/chair plus osd lock||unlock|r - let the display be dragged")
    print("  |cffffd100/chair plus osd reset|r - put the display back in the center of the screen")
    print("  |cffffd100/chair plus font <8-32>|r, |cffffd100/chair plus scale <0.5-3>|r")
    print("  |cffffd100/chair plus delay <0.1-1>|r - seconds between auto loot sweeps")
    print("  |cffffd100/chair arrow|r - the waypoint arrow's options; "
        .. "|cffffd100on||off||toggle||lock||unlock||reset||probe|r, |cffffd100scale <0.5-3>|r")
    print("  |cffffd100/chair threat|r - the threat meter's options; "
        .. "|cffffd100on||off||toggle||lock||unlock||reset||preview||nameplates|r")
    print("  |cffffd100/chair plus formbar|r - druids: whether the alternate resource bar was found, and your form")
    print("  |cffffd100/chair plus movers reset|r - forget where every dragged Blizzard window was put")
    print("  |cffffd100/chair plus movers add|r - make the window under the mouse draggable by its title bar")
    print("  |cffffd100/chair plus bake|r - print current settings as code that survives a restart")
    print("  |cffffd100/chair plus keywords|r - the invite-on-keyword window")
    print("  |cffffd100/chair plus flights|r - the learned flight times, as code")
    print("  |cffffd100/chair plus flight probe|r - with a flight map open, why a "
        .. "destination does or does not get a hardcoded time")
    print("  |cffffd100/chair plus flight new|r - flown routes the hardcoded list is missing or has wrong")
    print("  |cffffd100/chair plus reset|r - back to defaults")
    print("  |cffffd100/chair plus api|r - which client APIs answered")
    print("  |cffffd100/chair plus lfg|r - with the group finder open, what it is built from")
end

local function SetNumber(key, raw, low, high, label)
    local value = tonumber(raw)
    if not value or value < low or value > high then
        ns.Print(label .. " takes a number from " .. low .. " to " .. high .. ".")
        return
    end
    if ns.Set(key, value) then
        ns.Print(label .. " set to |cffffd100" .. Literal(value) .. "|r.")
    end
end

local function Handler(input)
    input = ns.Text(input) or ""
    local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        ns.TogglePanel()

    elseif cmd == "status" or cmd == "list" then
        PrintStatus()

    elseif cmd == "help" then
        PrintHelp()

    elseif cmd == "bake" then
        PrintBake()

    elseif cmd == "flights" then
        ns.ShowFlightTimes()

    elseif cmd == "keywords" or cmd == "invite" then
        ns.ToggleKeywordPanel()

    elseif cmd == "flight" then
        local sub = (rest or ""):lower()
        if sub == "unlock" then
            ns.Set("flightLocked", false)
            ns.Print("Flight timer unlocked -- drag it, then "
                .. "|cffffd100/chair plus flight lock|r.")
        elseif sub == "lock" then
            ns.Set("flightLocked", true)
            ns.Print("Flight timer locked.")
        elseif sub == "probe" then
            if ns.FlightProbe then ns.FlightProbe() end
        elseif sub == "new" then
            -- Flown routes the hardcoded list lacks or has wrong, shaped like
            -- the list itself so they can be pasted straight into it.
            local text, count
            if ns.FlightCorrections then text, count = ns.FlightCorrections() end
            if not text then
                ns.Print("Every route flown so far matches the hardcoded list.")
            elseif Chaircraft and Chaircraft.ShowTextBox then
                Chaircraft.ShowTextBox("New flight times", text, nil,
                    "Routes flown that the list is missing or has wrong. Press ctrl-A then ctrl-C to copy.")
                ns.Print(count .. " route(s) to add to the flight list.")
            else
                for line in text:gmatch("[^" .. string.char(10) .. "]+") do print(line) end
            end
        elseif sub == "reset" then
            ns.SetMany({ flightAnchor = ns.defaults.flightAnchor,
                         flightRelAnchor = ns.defaults.flightRelAnchor,
                         flightX = ns.defaults.flightX,
                         flightY = ns.defaults.flightY })
            ns.Print("Flight timer moved back to the top of the screen.")
        else
            ns.Print("Use |cffffd100/chair plus flight lock|r, "
                .. "|cffffd100unlock|r, |cffffd100reset|r, |cffffd100new|r or "
                .. "|cffffd100probe|r (with a flight map open).")
        end

    elseif cmd == "cooldowns" or cmd == "cd" then
        if ns.CooldownsCommand then ns.CooldownsCommand(rest) end

    elseif cmd == "arrow" or cmd == "threat" then
        local sub, arg = (rest or ""):lower():match("^(%S*)%s*(.-)$")
        local label = (cmd == "arrow") and "Waypoint arrow" or "Threat meter"
        if sub == "" then
            -- Both have a page of their own now, and that is where the bare
            -- command lands, the same as "/chair osd".
            ns.TogglePanel(cmd)
        elseif sub == "nameplates" and cmd == "threat" then
            if ns.ProbeNameplates then ns.ProbeNameplates() end
        elseif sub == "combo" and cmd == "threat" then
            if ns.ProbeCombo then ns.ProbeCombo() end
        elseif sub == "preview" and cmd == "threat" then
            if not ns.IsEnabled("threat") then ns.Set("threat", true) end
            ns.SetThreatPreview(not ns.threatPreview)
            ns.Print("Threat meter preview " .. (ns.threatPreview and "on." or "off."))
        elseif sub == "" or sub == "toggle" or sub == "on" or sub == "off" then
            local value
            if sub == "on" then value = true
            elseif sub == "off" then value = false
            else value = not ns.IsEnabled(cmd) end
            ns.Set(cmd, value)
            ns.Print(label .. " " .. (value and "|cff55ff55on|r" or "|cffff5555off|r") .. ".")
        elseif sub == "unlock" then
            ns.SetMany({ [cmd] = true, [cmd .. "Locked"] = false })
            ns.Print(label .. " unlocked -- drag it, then |cffffd100/chair "
                .. cmd .. " lock|r.")
        elseif sub == "lock" then
            ns.Set(cmd .. "Locked", true)
            ns.Print(label .. " locked.")
        elseif sub == "reset" then
            ns.SetMany({
                [cmd .. "Anchor"] = ns.defaults[cmd .. "Anchor"],
                [cmd .. "RelAnchor"] = ns.defaults[cmd .. "RelAnchor"],
                [cmd .. "X"] = ns.defaults[cmd .. "X"],
                [cmd .. "Y"] = ns.defaults[cmd .. "Y"],
            })
            ns.Print(label .. " moved back to the top center.")
        elseif sub == "probe" and cmd == "arrow" then
            if ns.ArrowProbe then ns.ArrowProbe() end
        elseif sub == "scale" and cmd == "arrow" then
            SetNumber("arrowScale", arg, 0.5, 3, "Arrow scale")
        else
            ns.Print("Use |cffffd100/chair " .. cmd .. "|r, |cffffd100on|r, |cffffd100off|r, "
                .. "|cffffd100lock|r, |cffffd100unlock|r or |cffffd100reset|r"
                .. (cmd == "arrow" and ", |cffffd100probe|r or |cffffd100scale <n>|r."
                    or " or |cffffd100preview|r."))
        end

    elseif cmd == "formbar" then
        if ns.ProbeFormBar then ns.ProbeFormBar() end

    elseif cmd == "movers" then
        if (rest or ""):lower() == "reset" then
            if ns.ResetMovers then ns.ResetMovers() end
            ns.Print("Every dragged window goes back to Blizzard's "
                .. "spots the next time they open.")
        elseif (rest or ""):lower() == "add" then
            local name = ns.AdoptMoverUnderMouse and ns.AdoptMoverUnderMouse()
            if name then
                ns.Print(name .. " can now be dragged by its title bar.")
            else
                ns.Print("No window under the mouse that can be made movable. "
                    .. "Point at the window, then type the command.")
            end
        else
            ns.Print("Drag Blizzard's windows -- character, bags, bank, map and quest log, spellbook, talents, mail, merchant, group finder and more -- by their title bar. "
                .. "|cffffd100/chair plus movers reset|r puts them back.")
            -- Which windows this client has, so a window that won't drag can
            -- be told apart from one that goes by another name here.
            if ns.MoverStatus then
                local found, ready = ns.MoverStatus()
                local isReady = {}
                for _, name in ipairs(ready) do isReady[name] = true end
                local waiting = {}
                for _, name in ipairs(found) do
                    if not isReady[name] then waiting[#waiting + 1] = name end
                end
                ns.Print("  movable now: " .. (#ready > 0 and table.concat(ready, ", ") or "none"))
                if #waiting > 0 then
                    ns.Print("  found, not ready yet: " .. table.concat(waiting, ", "))
                end
                ns.Print("  windows that load when first opened (talents, trainer and others) join the list then.")
            end
        end

    elseif cmd == "lfg" then
        ns.LFGProbe()

    elseif cmd == "api" then
        for name, source in pairs(ns.apiSource) do
            print("  " .. name .. " -> " .. source)
        end

    elseif cmd == "reset" then
        if ns.saved then wipe(ns.saved) end
        ns.LoadSettings()
        ns.ApplyAll()
        ns.Print("Back to defaults" .. (next(ns.baked) and " and baked values." or "."))

    elseif cmd == "osd" then
        local sub = (rest or ""):lower()
        if sub == "unlock" then
            ns.Set("osdLocked", false)
            ns.Print("Display unlocked -- drag it, then |cffffd100/chair plus osd lock|r.")
        elseif sub == "lock" then
            ns.Set("osdLocked", true)
            ns.Print("Display locked.")
        elseif sub == "reset" then
            ns.SetMany(ns.DefaultOSDPosition())
            ns.Print("Display moved back to the center of the screen.")
        else
            ns.Print("Use |cffffd100/chair plus osd lock|r, |cffffd100unlock|r or |cffffd100reset|r.")
        end

    elseif cmd == "font" then
        SetNumber("osdFontSize", rest, 8, 32, "Font size")

    elseif cmd == "scale" then
        SetNumber("osdScale", rest, 0.5, 3, "Scale")

    elseif cmd == "delay" then
        SetNumber("fasterLootDelay", rest, 0.1, 1, "Loot delay")

    elseif cmd == "on" or cmd == "off" or cmd == "toggle" then
        local key = rest
        if ns.defaults[key] == nil then
            -- Case-insensitive second try, since nobody types camelCase reliably.
            for candidate in pairs(ns.defaults) do
                if candidate:lower() == key:lower() then key = candidate break end
            end
        end
        if ns.defaults[key] == nil then
            ns.Print("No option called |cffffd100" .. (key ~= "" and key or "<nothing>")
                .. "|r. Try |cffffd100/chair plus status|r.")
            return
        end
        if type(ns.defaults[key]) ~= "boolean" then
            ns.Print("|cffffd100" .. key .. "|r is not an on/off option.")
            return
        end
        local value
        if cmd == "on" then value = true
        elseif cmd == "off" then value = false
        else value = not ns.IsEnabled(key) end
        ns.Set(key, value)
        ns.Print(key .. " is now " .. (value and "|cff55ff55on|r" or "|cffff5555off|r"))

    else
        ns.Print("Unknown command. Try |cffffd100/chair plus help|r.")
    end
end

SLASH_CHAIRPLUS1 = "/chairplus"
SLASH_CHAIRPLUS2 = "/cp"
SlashCmdList["CHAIRPLUS"] = Handler
