local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
-- Everything the window does, and a few things it does not. These stay because
-- they are faster than clicking once you know them, and because a window that
-- fails to build must not take the configuration with it -- Config:Open catches
-- its own errors and says so, and every setting is still reachable from here.

local KINDS = { buff = "buff", debuff = "debuff", cd = "cooldown", cooldown = "cooldown" }
local UNITS = { player = "player", target = "target", focus = "focus", pet = "pet" }

local function Tokenize(text)
    local tokens = {}
    for word in string.gmatch(text or "", "%S+") do
        tokens[#tokens + 1] = word
    end
    return tokens
end

-- Auras are addressed by their position in the list the way /chair auras list prints it,
-- because nobody wants to type a5 -- but the id is what everything stores, so
-- the number is turned into one here and nowhere else.
local function AuraAt(index)
    local auras = ns.GetAuras()
    local n = tonumber(index)
    if not n or not auras[n] then
        ns.Print("no aura number", tostring(index), "-- /chair auras list shows them.")
        return nil
    end
    return auras[n], n
end

local function Describe(aura, index)
    local trigger = ns.Trigger(aura)
    local bits = { index .. "." }

    if ns.IsGroup(aura) then
        bits[#bits + 1] = "|cff40c4ff" .. (aura.type == "dynamic" and "dynamic" or "group")
            .. "|r"
        bits[#bits + 1] = aura.name or aura.id
        bits[#bits + 1] = "|cff808080(" .. #ns.Children(aura.id) .. " inside)|r"
    else
        local name = ns.Engine:Describe(aura)
        bits[#bits + 1] = name

        if ns.TriggerFieldValue(trigger, "type") == "cooldown" then
            bits[#bits + 1] = "cooldown"
        else
            bits[#bits + 1] = ns.TriggerFieldValue(trigger, "harmful") and "debuff" or "buff"
            bits[#bits + 1] = "on " .. ns.TriggerFieldValue(trigger, "unit")
            if ns.TriggerFieldValue(trigger, "match") == "name" then
                bits[#bits + 1] = "|cffffd100by name|r"
            end
        end

        if ns.TriggerFieldValue(trigger, "mine") then bits[#bits + 1] = "mine-only" end
        if ns.DisplayField(aura, "invert") then bits[#bits + 1] = "inverted" end
        if ns.DisplayField(aura, "hide") then bits[#bits + 1] = "hides" end
    end

    if aura.parent then
        local parent = ns.FindAura(aura.parent)
        bits[#bits + 1] = "|cff808080in " .. ((parent and (parent.name or parent.id)) or "?") .. "|r"
    end
    if aura.load and next(aura.load) then
        bits[#bits + 1] = "|cff808080[load]|r"
    end

    local ok, line = pcall(table.concat, bits, " ")
    return ok and line or (index .. ". <unprintable>")
end

local function Added(aura)
    ns.Engine:Rebuild()
    ns.RequestUpdate()
    local auras = ns.GetAuras()
    ns.Print("added", Describe(aura, #auras))
end

-------------------------------------------------------------------------------

local function NewAura(fields)
    local profile = ns.GetProfile()
    if not profile then return nil end
    fields.id = ns.NextID(profile)
    profile.auras[#profile.auras + 1] = fields
    return fields
end

local function CmdAdd(tokens, startAt)
    local kind, unit = nil, nil
    local at = startAt

    -- Both qualifiers are optional and order does not matter, so each is taken
    -- only while it still matches: "add debuff target moonfire" and plain
    -- "add moonfire" both have to work.
    while tokens[at] do
        local word = string.lower(tokens[at])
        if not kind and KINDS[word] then
            kind = KINDS[word]
            at = at + 1
        elseif not unit and UNITS[word] then
            unit = UNITS[word]
            at = at + 1
        else
            break
        end
    end

    local rest = table.concat(tokens, " ", at)
    if rest == "" then
        ns.Print("usage: /chair auras add [buff|debuff|cd] [player|target|focus|pet] <spell or ID>")
        return
    end

    local spellID = ns.ResolveSpell(rest)
    if not spellID then
        ns.Print("this client does not know a spell called", rest,
                 "-- try its numeric ID, or |cffffd100/chair auras name", rest, "|r to match the text instead.")
        return
    end

    kind = kind or "buff"
    -- A debuff asked for without a unit means the target. Nobody watches their
    -- own debuffs by default, and getting it wrong is a silent empty icon.
    unit = unit or (kind == "debuff" and "target" or "player")

    local aura = NewAura({
        type = "icon",
        trigger = {
            type    = (kind == "cooldown") and "cooldown" or "aura",
            harmful = (kind == "debuff") or nil,
            unit    = (unit ~= "player") and unit or nil,
            spellID = spellID,
        },
    })
    if aura then Added(aura) end
end

-- The command for everything that has no spell to name: Well Fed, a server's own
-- buff, a proc known only by the words on it.
local function CmdName(tokens, startAt)
    local kind, unit = nil, nil
    local at = startAt

    while tokens[at] do
        local word = string.lower(tokens[at])
        if not kind and KINDS[word] then
            kind = KINDS[word]
            at = at + 1
        elseif not unit and UNITS[word] then
            unit = UNITS[word]
            at = at + 1
        else
            break
        end
    end

    local text = table.concat(tokens, " ", at)
    if text == "" then
        ns.Print('usage: /chair auras name [buff|debuff] [player|target] <text on the aura>')
        ns.Print('example: |cffffd100/chair auras name Well Fed|r')
        return
    end

    kind = kind or "buff"
    unit = unit or (kind == "debuff" and "target" or "player")

    local aura = NewAura({
        type = "icon",
        name = text,
        trigger = {
            match   = "name",
            text    = text,
            harmful = (kind == "debuff") or nil,
            unit    = (unit ~= "player") and unit or nil,
        },
    })
    if aura then Added(aura) end
end

local function CmdGroup(tokens, startAt, dynamic)
    local name = table.concat(tokens, " ", startAt)
    local aura = NewAura({
        type = dynamic and "dynamic" or "group",
        name = (name ~= "" and name) or (dynamic and "Dynamic group" or "Group"),
    })
    if aura then Added(aura) end
end

-- /chair auras put 4 2 -- put aura 4 inside group 2. Both are list positions, which is
-- what /chair auras list prints, and "put 4" with no second number takes it out again.
local function CmdPut(tokens, startAt)
    local aura = AuraAt(tokens[startAt])
    if not aura then return end

    local target = tokens[startAt + 1]
    if not target then
        aura.parent = nil
        ns.Engine:Rebuild()
        ns.Print("took it out of its group.")
        return
    end

    local group = AuraAt(target)
    if not group then return end
    if not ns.IsGroup(group) then
        ns.Print("number", target, "is not a group.")
        return
    end
    if ns.WouldLoop(aura, group.id) then
        ns.Print("a group cannot be put inside itself.")
        return
    end

    aura.parent = group.id
    ns.Engine:Rebuild()
    ns.RequestUpdate()
    ns.Print("moved into", group.name or group.id)
end

local function CmdCursor()
    -- The payload this client puts on the cursor for a spell, printed as well as
    -- acted on: the ID is the fourth value, and seeing all four is what settled
    -- that a dragged spell was arriving as its spellbook index.
    local a, b, c, d = GetCursorInfo()
    ns.Print("cursor:", tostring(a), tostring(b), tostring(c), tostring(d))

    local spellID, what = ns.SpellFromCursor()
    if what ~= "spell" then
        ns.Print("put a spell on the cursor first -- drag one out of the spellbook.")
        return
    end
    if not spellID then
        ns.Print("could not read a spell ID off the cursor.")
        return
    end

    ClearCursor()
    CmdAdd({ tostring(spellID) }, 1)
end

local function CmdList()
    local auras = ns.GetAuras()
    if #auras == 0 then
        ns.Print("nothing yet -- /chair auras add <spell>, or /chair auras name <text>")
        return
    end
    ns.Print("auras:")
    for index, aura in ipairs(auras) do
        ns.Print(" ", Describe(aura, index))
    end
end

local function CmdRemove(tokens, startAt)
    local aura, index = AuraAt(tokens[startAt])
    if not aura then return end

    for _, child in ipairs(ns.Children(aura.id)) do
        child.parent = aura.parent
    end

    table.remove(ns.GetAuras(), index)
    ns.Engine:Rebuild()
    ns.RequestUpdate()
    ns.Print("removed", index)
end

local function CmdRename(tokens, startAt)
    local aura, index = AuraAt(tokens[startAt])
    if not aura then return end

    local text = table.concat(tokens, " ", startAt + 1)
    if not ns.Config:Rename(aura.id, text) then return end

    if text == "" then
        ns.Print("cleared the name --", index, "is called after what it watches again.")
    else
        ns.Print("renamed", index, "to", text)
    end
end

local function CmdLoad(tokens, startAt)
    local aura = AuraAt(tokens[startAt])
    if not aura then return end
    ns.Print(ns.Engine:Describe(aura) .. ":", ns.Load:Explain(aura))
end

local function CmdExport(tokens, startAt)
    local aura = tokens[startAt] and AuraAt(tokens[startAt]) or nil
    if tokens[startAt] and not aura then return end
    ns.Config:OpenExport(aura)
end

local function CmdImport()
    ns.Config:OpenImport()
end

-- /chair auras move 5 2 -- put 5 where 2 is. With "in" it goes inside 2 instead, which
-- only means anything when 2 is a group.
local function CmdMove(tokens, startAt)
    local aura = AuraAt(tokens[startAt])
    if not aura then return end

    local target = AuraAt(tokens[startAt + 1])
    if not target then return end

    local inside = (tokens[startAt + 2] or ""):lower() == "in"
    if not ns.MoveAura(aura, target, inside) then
        ns.Print("that move cannot be made -- a group cannot go inside itself.")
        return
    end

    ns.Engine:Rebuild()
    ns.RequestUpdate()
    ns.Print(inside and "moved it inside." or "moved it.")
end

local function CmdIcons()
    local source, count = ns.Icons:Source()
    local scanned, ceiling, running = ns.Icons:ScanProgress()
    ns.Print("icon list:", count, "from", source)
    ns.Print("spell index:", #ns.Icons:SpellIndex(), "named icons,",
             running and ("scanning, " .. math.floor(scanned / ceiling * 100) .. "%")
                     or (scanned > 0 and "done" or "not started -- open the picker"))
end

local function CmdLock()
    local profile = ns.GetProfile()
    if not profile then return end
    profile.locked = not profile.locked
    ns.Display:ApplyLock()
    ns.Print(profile.locked and "locked."
        or "unlocked -- drag any icon, and the group it is in comes with it.")
end

-- The auras written into Presets.lua, on purpose rather than because the file
-- went missing. Both directions are here: putting them back, and telling the
-- addon not to put them back, which is the only way to leave the list empty
-- across a logout.
local function CmdPreset(tokens, index)
    local word = string.lower(tokens[index] or "")

    if word == "off" then
        ns.presetEnabled = false
        ns.Print("the built-in auras will not be seeded again this session. "
              .. "An empty list will stay empty until you log out; it comes "
              .. "back next login unless you edit Presets.lua.")
        return
    end

    if word == "on" then
        ns.presetEnabled = true
        ns.Print("the built-in auras will be seeded into an empty profile again.")
        return
    end

    if word == "" then
        ns.Print(#(ns.PRESET_AURAS or {}), "aura(s) are written into the addon;",
                 "seeding is",
                 (ns.presetEnabled and "|cff33ff33on|r" or "|cffff5555off|r") .. ".")
        ns.Print("|cffffd100/chair auras preset load|r replaces what you have with them.")
        ns.Print("|cffffd100/chair auras preset off|r stops them coming back into an empty list.")
        return
    end

    if word ~= "load" then
        ns.Print("|cffffd100/chair auras preset|r, |cffffd100load|r, |cffffd100off|r or |cffffd100on|r.")
        return
    end

    -- Replaces rather than merges: the point of this command is "give me back
    -- the setup I had", and a merge would answer with two of everything.
    local count = ns.ApplyPreset(ns.GetProfile(), true)
    ns.Engine:Rebuild()
    ns.RequestUpdate()
    ns.Print("loaded", count, "built-in aura(s), replacing what was there.")
end

local function CmdStatus()
    local witness = ns.loadWitness or {}
    ns.Print("v" .. ns.version, "|cff808080profile", ns.ProfileKey() .. "|r")
    ns.Print("saved data arrived:", witness.arrival or "?",
             "|cff808080(ADDON_LOADED", tostring(witness.atAddonLoaded),
             "PLAYER_LOGIN", tostring(witness.atPlayerLogin) .. ")|r")

    local auras, groups = 0, 0
    for _, aura in ipairs(ns.GetAuras()) do
        if ns.IsGroup(aura) then groups = groups + 1 else auras = auras + 1 end
    end
    ns.Print(auras, "aura(s) in", groups, "group(s).")

    -- The question /chair auras status exists to answer, now that an empty file does not
    -- mean an empty screen: are these the saved auras, or the built-in ones?
    if (witness.seeded or 0) > 0 then
        ns.Print("|cffffa500these came from Presets.lua|r -- no saved auras "
              .. "arrived. |cffffd100/chair auras preset|r explains it.")
    end

    -- Which load conditions this client can actually answer. A condition it
    -- cannot answer never blocks an aura, and this is where that is visible.
    local usable, blind = {}, {}
    for _, condition in ipairs(ns.Load.CONDITIONS) do
        local list = ns.Load:Available(condition) and usable or blind
        list[#list + 1] = condition.label
    end
    if #blind > 0 then
        local ok, line = pcall(table.concat, blind, ", ")
        ns.Print("|cff808080load conditions this client cannot answer:|r",
                 ok and line or "?")
    end
end

local function CmdHelp()
    ns.Print("commands:")
    ns.Print("  |cffffd100/chair auras|r                      open the window")
    ns.Print("  |cffffd100/chair auras add [buff|debuff|cd] [unit] <spell>|r")
    ns.Print("  |cffffd100/chair auras name [buff|debuff] [unit] <text>|r   match the words on")
    ns.Print("      the aura, for things with no spell: |cffffd100/chair auras name Well Fed|r")
    ns.Print("  |cffffd100/chair auras group [name]|r         a group that keeps its slots")
    ns.Print("  |cffffd100/chair auras dyn [name]|r           a group that closes its gaps")
    ns.Print("  |cffffd100/chair auras put <n> [group n]|r    move one into a group, or out")
    ns.Print("  |cffffd100/chair auras move <n> <n> [in]|r   reorder, or drop one inside")
    ns.Print("  |cffffd100/chair auras rename <n> [name]|r   name it, or clear it to go back")
    ns.Print("  |cffffd100/chair auras list|r / |cffffd100/chair auras remove <n>|r / |cffffd100/chair auras load <n>|r")
    ns.Print("  |cffffd100/chair auras cursor|r               add whatever is on the cursor")
    ns.Print("  |cffffd100/chair auras export [n]|r / |cffffd100/chair auras import|r   strings to pass around")
    ns.Print("  |cffffd100/chair auras icons|r              where the icon list comes from")
    ns.Print("  |cffffd100/chair auras preset [load|off]|r   the auras written into the addon,")
    ns.Print("      which fill an empty profile when the client loses the file")
    ns.Print("  |cffffd100/chair auras why|r                 what the engine and the display")
    ns.Print("      think of each aura: whether it matched and its stack count")
    ns.Print("  |cffffd100/chair auras lock|r / |cffffd100/chair auras status|r")
end

-------------------------------------------------------------------------------

SLASH_CHAIRAURAS1 = "/ca"
SLASH_CHAIRAURAS2 = "/chairauras"

-- Everything the engine and the display believe about each aura, side by side.
--
-- This exists because "the stacks do not show" is true of several different
-- faults -- the aura not matching, the count not being read, the shape not
-- drawing one -- and they all look identical on screen. Each line below
-- separates them, so the next report names the fault instead of the symptom.
local function CmdWhy()
    local auras = ns.GetAuras() or {}
    if #auras == 0 then
        ns.Print("there are no auras configured.")
        return
    end

    local states = ns.Engine and ns.Engine.states or {}
    local regions = ns.Display and ns.Display.__regions or {}

    for _, aura in ipairs(auras) do
        local id = tostring(aura.id)
        local label = tostring(aura.name or id)

        if ns.IsGroup(aura) then
            ns.Print("|cffffd100" .. label .. "|r (group) -- draws nothing itself.")
        else
            local state = states[id] or {}
            local frame = regions[id]
            local kind = ns.RegionKind(aura)

            ns.Print("|cffffd100" .. label .. "|r (" .. tostring(kind) .. ")",
                     "loaded=" .. tostring(state.loaded),
                     "shown=" .. tostring(state.shown),
                     "stacks=" .. (state.count == nil and "|cffff5555unreadable|r"
                                   or tostring(state.count)))

            local wanted = ns.DisplayField(aura, "stacks")
            local drawn = "n/a"
            if frame and frame.count and frame.count.GetText then
                local ok, text = pcall(frame.count.GetText, frame.count)
                drawn = ok and ((text == nil or text == "") and "(blank)" or text)
                        or "(error)"
            end
            -- Concatenated rather than passed as another argument: an empty
            -- argument prints as "unreadable", which would be a diagnostic
            -- reporting a fault in itself.
            local note = ""
            if kind ~= "icon" then
                note = " |cffff5555(only an icon draws one -- use %s in the "
                    .. "text instead)|r"
            end
            ns.Print("   stack number: setting=" .. tostring(wanted),
                     "drawn=" .. tostring(drawn) .. note)
        end
    end
end

SlashCmdList["CHAIRAURAS"] = function(message)
    if not ns.ready then
        ns.Print("still waiting for saved data -- try again in a moment.")
        return
    end

    local tokens = Tokenize(message)
    local command = string.lower(tokens[1] or "")

    if command == "" then
        ns.Config:Toggle()
    elseif command == "add" then
        CmdAdd(tokens, 2)
    elseif command == "name" then
        CmdName(tokens, 2)
    elseif command == "group" then
        CmdGroup(tokens, 2, false)
    elseif command == "dyn" or command == "dynamic" then
        CmdGroup(tokens, 2, true)
    elseif command == "put" then
        CmdPut(tokens, 2)
    elseif command == "cursor" then
        CmdCursor()
    elseif command == "list" then
        CmdList()
    elseif command == "remove" or command == "delete" then
        CmdRemove(tokens, 2)
    elseif command == "rename" then
        CmdRename(tokens, 2)
    elseif command == "load" then
        CmdLoad(tokens, 2)
    elseif command == "export" then
        CmdExport(tokens, 2)
    elseif command == "import" then
        CmdImport()
    elseif command == "link" or command == "chat"
        or command == "linktest" or command == "linktype" then
        ns.Print("chat links are gone -- use |cffffd100/chair auras export|r "
                 .. "and paste the string instead.")
    elseif command == "move" then
        CmdMove(tokens, 2)
    elseif command == "icons" then
        CmdIcons()
    elseif command == "lock" then
        CmdLock()
    elseif command == "preset" or command == "presets" then
        CmdPreset(tokens, 2)
    elseif command == "why" then
        CmdWhy()
    elseif command == "status" then
        CmdStatus()
    elseif command == "help" then
        CmdHelp()
    else
        ns.Print("no command called", command .. ".", "|cffffd100/chair auras help|r lists them.")
    end
end
