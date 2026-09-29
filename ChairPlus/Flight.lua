-- ChairPlus Flight.lua
-- How long a flight path takes: learn it once, then count it down.
--
-- Three parts, and they fail independently on purpose:
--
--   TIMING polls one question: are we on a taxi. Which call answers that is
--   looked up, not assumed -- the first version hardcoded IsOnTaxi(), which
--   this client does not have, so every flight silently did nothing. The taxi
--   events (PLAYER_CONTROL_LOST/GAINED) are deliberately not used: they fire
--   for vehicles, mind control and cutscenes too.
--
--   NAMING needs the flight map to tell us where we are and where we asked to
--   go. Two generations of that API exist and this client has neither addon
--   nor documentation to say which, so both are tried. Without a name there is
--   no key to file the time under, so the flight is timed but not saved.
--
--   DISPLAY is the countdown, and the tooltip line on the flight map.
--
-- Times come from three places, most trusted first: what was flown on this
-- client (ChairPlusDB.flights), the hardcoded table (FlightData.lua, keyed by
-- stop names), and a two-ended fallback. Every flight is still timed behind
-- the scenes, so a hardcoded time that is wrong here -- or a route the table
-- has never heard of -- is learned the first time it is flown, and
-- "/chair plus flight new" lists what the table should gain.
--
-- On speed effects: a route's duration is fixed, so the base time is written
-- once and never averaged. A permanent speed increase scales every route by
-- the same factor, which makes it measurable from any route already known --
-- see the note above Record.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairPlus"
local ns = Chaircraft.ChairPlus

local frame, label
local hooked = false
local taxiOpen = false
local tookHook = false
local tooltipMethod = "none"

-------------------------------------------------------------------------------
-- Am I on a taxi?
-------------------------------------------------------------------------------
-- The one fact the whole module rests on, and the first version guessed at the
-- call: it asked for IsOnTaxi(), got nil, and silently decided every flight
-- was not happening -- no clock, no recording, nothing on the map. A feature
-- that does nothing and says nothing is worse than one that refuses loudly.
--
-- So the call is looked up rather than assumed, in order of confidence, and
-- which one answered is reported by /chair status.

local taxiProbe, taxiProbeName

local function FindTaxiProbe()
    local candidates = {
        { name = "UnitOnTaxi", make = function(fn) return function() return fn("player") end end },
        { name = "IsOnTaxi",   make = function(fn) return fn end },
        { name = "UnitInVehicle", make = function(fn) return function() return fn("player") end end },
    }
    for _, candidate in ipairs(candidates) do
        local fn = _G[candidate.name]
        if type(fn) == "function" then
            -- Present is not the same as working. Call it once: a function
            -- that throws is no more use than one that is missing.
            local probe = candidate.make(fn)
            if pcall(probe) then
                taxiProbe, taxiProbeName = probe, candidate.name
                return true
            end
        end
    end
    taxiProbe, taxiProbeName = nil, nil
    return false
end

local function OnTaxi()
    if not taxiProbe then return false end
    local ok, value = pcall(taxiProbe)
    return (ok and value) and true or false
end

-- Flight in progress.
local flying = false
local startedAt = 0
local route = nil          -- { source =, dest =, expected = }
local pending = nil        -- set when a node is chosen, before takeoff

-------------------------------------------------------------------------------
-- A flight across a reload
-------------------------------------------------------------------------------
-- A /reload mid-air wipes everything above: the session that lands never saw
-- the takeoff. So the route and the takeoff time are written down when a
-- known route takes off (ChairPlusDB.flightInFlight, with whose flight it is),
-- and a session that finds itself already on a taxi picks them up again: the
-- countdown carries on where the flight really is, and the flight is marked
-- so it is never recorded -- its time spans a reload, and a wrong time is
-- worse than none. Landing clears it; so does logging in on the ground.

local IN_FLIGHT_MAX = 30 * 60   -- no taxi runs this long: an older note is stale

local function WallClock()
    local get = _G.GetServerTime or _G.time
    return type(get) == "function" and ns.Num(get()) or nil
end

local function Owner()
    return ns.profileKey and tostring(ns.profileKey) or nil
end

local function SaveInFlight(r)
    local db = _G.ChairPlusDB
    local now = WallClock()
    if type(db) ~= "table" or not now or not (r and r.source and r.dest) then return end
    db.flightInFlight = { who = Owner(), at = now, source = r.source, dest = r.dest,
                          path = r.path, hardcoded = r.hardcoded }
end

local function ClearInFlight()
    local db = _G.ChairPlusDB
    if type(db) == "table" then db.flightInFlight = nil end
end

-- The saved flight, and how many seconds ago it took off, if it is ours and
-- recent enough to be the one we are on.
local function SavedInFlight()
    local db = _G.ChairPlusDB
    local saved = type(db) == "table" and db.flightInFlight or nil
    local now = WallClock()
    if type(saved) ~= "table" or not now then return nil end
    local ago = now - (ns.Num(saved.at) or 0)
    if saved.who ~= Owner() or ago < 0 or ago > IN_FLIGHT_MAX then return nil end
    return saved, ago
end

-------------------------------------------------------------------------------
-- The database
-------------------------------------------------------------------------------
-- Lives at the top of ChairPlusDB, shared by every character: settings are
-- per character (Config.lua), but a route takes as long for one as another.

local function FlightDB()
    local db = _G.ChairPlusDB
    if type(db) ~= "table" then return nil end
    if type(db.flights) ~= "table" then db.flights = {} end
    return db.flights
end

-------------------------------------------------------------------------------
-- Flight times written down in code
-------------------------------------------------------------------------------
-- The destination for "/chair plus flights". Anything in here seeds a route
-- that has never been flown, so a fresh character -- or a cold start that the
-- client blanked -- comes up already knowing the map instead of relearning it
-- one flight at a time.
--
-- Times are the BASE, at normal flight speed with no bonus applied, which is
-- the same normalisation the recorder uses. That is what makes the list worth
-- hardcoding: it stays correct after a permanent speed increase, because the
-- measured factor is applied on top of it rather than baked into it.
--
-- Seeded routes are never overwritten by a flight, and a flight never
-- overwrites a route already known -- the base is written once either way.

ns.flightDefaults = {
    -- ["Stormwind, Elwynn > Ironforge, Dun Morogh"] = 150.0,
}

local function RouteKey(source, dest)
    source = ns.Text(source)
    dest = ns.Text(dest)
    if not source or not dest or source == "" or dest == "" then return nil end
    return source .. " > " .. dest
end

-- A route is the path the client flies, not just its two ends. Learning a new
-- flight point can reroute A to B through a different stop, and a time filed
-- under "A > B" would then be read against a flight it was never measured on --
-- and Record would take the difference for a change in speed and rescale every
-- route in the database. Keyed by the full path, a reroute is simply a route
-- not flown yet.
--
-- A direct flight's path key is "A > B", the same as the two-ended key, so
-- every one-hop time recorded before paths were known is still exact.
local function PathKey(path)
    if type(path) ~= "table" or #path < 2 then return nil end
    local ok, key = pcall(table.concat, path, " > ")
    return ok and key or nil
end

-- The key a flight is recorded under, and the one to fall back on for an
-- estimate. The fallback is the two-ended key of a multi-hop path: a time from
-- before paths were known, a seeded one, or an import. Good enough for a
-- countdown, never trusted to measure speed from, never written to.
local function RouteKeys(source, dest, path)
    local exact = PathKey(path)
    if not exact then return RouteKey(source, dest), nil end
    if #path > 2 then return exact, RouteKey(source, dest) end
    return exact, nil
end

-- A route's duration is fixed. It is a scripted path at a fixed speed, so the
-- same flight always takes the same time -- which means averaging samples is
-- not just pointless but harmful: the moment a permanent speed increase is
-- picked up, a mean drags the stored number to somewhere the flight has never
-- actually taken and never will.
--
-- So the base time is written once and then left alone. What CAN change is the
-- player's flight speed, and because a permanent increase scales every route
-- by the same factor, one flight over a route we already know measures it:
--
--     implied factor = measured seconds / stored base
--
-- That factor is global, stored once, and applied to every estimate. When the
-- means of reading the speed bonus directly turns up, it replaces the
-- measurement and nothing else here has to change.

local DEFAULT_SPEED = 1

local function SpeedFactor()
    local db = _G.ChairPlusDB
    local value = db and ns.Num(db.flightSpeed)
    if not value or value <= 0 then return DEFAULT_SPEED end
    return value
end

local function SetSpeedFactor(value)
    local db = _G.ChairPlusDB
    if type(db) ~= "table" then return end
    db.flightSpeed = value
end
ns.FlightSpeed = SpeedFactor

-- The stored base, at normal flight speed, with no factor applied.
local function BaseTime(entry)
    if type(entry) ~= "table" then return nil end
    -- `avg` is the shape this used before the model was corrected; reading it
    -- means a database recorded under the old rules still works.
    return ns.Num(entry.base) or ns.Num(entry.avg)
end

-- What this flight should take right now: the fixed base, scaled by whatever
-- the player's current flight speed has been measured to be.
-- The third return is true when the time came off the two-ended fallback
-- rather than the path actually being flown.
--
-- `hardcoded` is the route's time from FlightData.lua, when the flight map
-- could place it. Order of trust: a time flown on this client, then the
-- hardcoded one, then the two-ended fallback.
function ns.FlightTime(source, dest, path, hardcoded)
    local db = FlightDB()
    local key, fallback = RouteKeys(source, dest, path)
    if not db or not key then return nil end
    local entry = db[key]
    local base = BaseTime(entry)
    local approximate = false
    hardcoded = ns.Num(hardcoded)
    if not base and hardcoded and hardcoded > 0 then
        entry = { base = hardcoded, n = 0, hardcoded = true }
        base = hardcoded
    end
    if not base and fallback then
        entry = db[fallback]
        base = BaseTime(entry)
        approximate = true
    end
    if not base then return nil end
    return base * SpeedFactor(), entry, approximate
end

-- Put the hardcoded times into the database, for routes not already known.
-- Never overwrites: a time measured on this character outranks a list typed
-- into a file, and the list is the floor rather than the authority.
local function SeedDefaults()
    local db = FlightDB()
    if not db or type(ns.flightDefaults) ~= "table" then return 0 end
    local added = 0
    for key, seconds in pairs(ns.flightDefaults) do
        local base = ns.Num(seconds)
        if base and base > 0 and type(key) == "string"
            and type(db[key]) ~= "table" then
            -- n = 0 says "never actually flown", which is the honest count
            -- and keeps the tooltip from claiming experience it has not got.
            db[key] = { base = base, n = 0, fromCode = true }
            added = added + 1
        end
    end
    return added
end

-- Every known route as a pasteable Lua block, sorted so two exports of the
-- same data are the same text.
function ns.FlightExport()
    local db = FlightDB()
    local keys = {}
    if db then
        for key, entry in pairs(db) do
            if BaseTime(entry) then keys[#keys + 1] = key end
        end
    end
    table.sort(keys)

    local lines = { "ns.flightDefaults = {" }
    for _, key in ipairs(keys) do
        local entry = db[key]
        local flown = ns.Num(entry.n) or 0
        lines[#lines + 1] = string.format("    [%q] = %.1f,%s", key,
            BaseTime(entry),
            flown == 0 and "   -- from code, never flown" or "")
    end
    lines[#lines + 1] = "}"

    local ok, text = pcall(table.concat, lines, string.char(10))
    return ok and text or nil, #keys
end

-- Read flight times out of pasted text and add the ones we do not have.
--
-- Deliberately a scanner rather than loadstring. The text is pasted by hand
-- and may be half a file, a fragment out of SavedVariables, or two exports
-- stuck together -- a parser that demands valid Lua would reject all three,
-- and running pasted text as code to read three numbers out of it is a poor
-- trade. So it accepts both shapes it will actually meet:
--
--     ["A > B"] = 207.1                        the exported list
--     ["A > B"] = { ["base"] = 207.1, ... }    straight out of SavedVariables
--
-- Existing routes are never overwritten: a time measured here outranks one
-- typed in, and the count of what was skipped is reported rather than hidden.
function ns.ImportFlightTimes(text)
    if type(text) ~= "string" or text == "" then return nil, "nothing to read" end

    local found = {}
    local total = 0
    local pos = 1
    while true do
        local _, stop, key = text:find('%[%s*"([^"]+)"%s*%]%s*=%s*', pos)
        if not stop then break end
        local rest = text:sub(stop + 1)

        local seconds = tonumber(rest:match("^(%-?%d+%.?%d*)"))
        if not seconds then
            -- A table. %b handles the nesting so a stray brace inside cannot
            -- run the match off the end of the entry.
            local inner = rest:match("^%b{}")
            if inner then
                seconds = tonumber(inner:match('"base"%s*%]%s*=%s*(%-?%d+%.?%d*)')
                    or inner:match('base%s*=%s*(%-?%d+%.?%d*)'))
            end
        end

        if seconds and seconds > 0 and key:find(">", 1, true) then
            found[key] = seconds
            total = total + 1
        end
        pos = stop + 1
    end

    if total == 0 then return nil, "no flight times found in that text" end

    local db = FlightDB()
    if not db then return nil, "no database to import into" end

    local added, skipped = 0, 0
    for key, seconds in pairs(found) do
        if type(db[key]) == "table" and BaseTime(db[key]) then
            skipped = skipped + 1
        else
            db[key] = { base = seconds, n = 0, fromImport = true }
            added = added + 1
        end
    end
    return added, skipped
end

-- How far off an observation has to be before it is treated as a real speed
-- change rather than the ordinary jitter of when the clock starts and stops.
local SPEED_TOLERANCE = 0.03
-- Outside this the observation is not a speed change, it is a flight that went
-- wrong -- a stall, a disconnect, a path that was not the one we thought.
local SPEED_MIN, SPEED_MAX = 0.2, 3

-- How far a flown time may be from the hardcoded one before it counts as the
-- table being wrong for this client, rather than the clock starting a moment
-- late.
local HARDCODED_TOLERANCE = 3

-- Third return: the hardcoded time this flight replaced, when it disagreed.
local function Record(source, dest, seconds, path, hardcoded)
    local db = FlightDB()
    local key = RouteKeys(source, dest, path)
    if not db or not key or not seconds or seconds <= 0 then return nil end

    local factor = SpeedFactor()
    local entry = db[key]
    local base = BaseTime(entry)

    if not base then
        -- First time on this route. Store it at base speed, so the number is
        -- comparable with every other route however fast we happen to be now.
        -- This is also how the hardcoded table is kept honest: what was flown
        -- is stored, and wins over the table from then on. A hardcoded time is
        -- never used to measure speed -- it came from another client.
        entry = { base = seconds / factor, n = 1 }
        db[key] = entry
        hardcoded = ns.Num(hardcoded)
        if hardcoded and math.abs(entry.base - hardcoded) > HARDCODED_TOLERANCE then
            entry.hardcoded = hardcoded
            return entry, nil, hardcoded
        end
        return entry, nil
    end

    entry.n = (ns.Num(entry.n) or 0) + 1
    entry.base = base            -- normalise an old-shape entry in place
    entry.avg = nil
    entry.min, entry.max, entry.last = nil, nil, nil

    -- The base never moves. A difference means our speed changed, not that the
    -- route did.
    local implied = seconds / base
    if implied >= SPEED_MIN and implied <= SPEED_MAX
        and math.abs(implied - factor) > SPEED_TOLERANCE then
        SetSpeedFactor(implied)
        return entry, implied
    end

    return entry, nil
end

-------------------------------------------------------------------------------
-- Reading the flight map
-------------------------------------------------------------------------------
-- Returns a list of { name, slot, current } or nil if neither API answers.
-- Classic exposes globals; the retail engine moved them into C_TaxiMap. This
-- client is the retail engine running classic content, so it could be either.

local function TaxiNodes()
    local numNodes = _G.NumTaxiNodes
    local nodeName = _G.TaxiNodeName
    local nodeType = _G.TaxiNodeGetType

    if type(numNodes) == "function" and type(nodeName) == "function" then
        local ok, count = pcall(numNodes)
        count = ok and (ns.Num(count) or 0) or 0
        if count > 0 then
            local out = {}
            for index = 1, count do
                local okName, name = pcall(nodeName, index)
                local kind
                if type(nodeType) == "function" then
                    local okKind, value = pcall(nodeType, index)
                    kind = okKind and ns.Text(value) or nil
                end
                if okName and ns.Text(name) then
                    local x, y
                    if type(_G.TaxiNodePosition) == "function" then
                        local okP, px, py = pcall(_G.TaxiNodePosition, index)
                        if okP then x, y = ns.Num(px), ns.Num(py) end
                    end
                    out[#out + 1] = {
                        name = ns.Text(name),
                        slot = index,
                        current = (kind == "CURRENT"),
                        -- NONE and DISTANT are points you have not found or
                        -- cannot reach from here.
                        known = (kind == "CURRENT" or kind == "REACHABLE"),
                        x = x, y = y,
                    }
                end
            end
            return out
        end
    end

    local taxiMap = _G.C_TaxiMap
    if taxiMap and type(taxiMap.GetAllTaxiNodes) == "function" then
        local ok, nodes = pcall(taxiMap.GetAllTaxiNodes)
        if ok and type(nodes) == "table" then
            local currentState = _G.Enum and _G.Enum.FlightPathState
                and _G.Enum.FlightPathState.Current
            local out = {}
            for _, node in ipairs(nodes) do
                local name = ns.Text(node.name)
                if name then
                    local pos, x, y = node.position, nil, nil
                    if type(pos) == "table" or type(pos) == "userdata" then
                        if pos.GetXY then
                            local okP, px, py = pcall(pos.GetXY, pos)
                            if okP then x, y = px, py end
                        end
                        if x == nil then x, y = pos.x, pos.y end
                    end
                    local states = _G.Enum and _G.Enum.FlightPathState
                    out[#out + 1] = {
                        name = name,
                        slot = ns.Num(node.slotIndex),
                        current = (currentState ~= nil and node.state == currentState),
                        known = not (states and states.Unreachable ~= nil
                                     and node.state == states.Unreachable),
                        x = ns.Num(x), y = ns.Num(y),
                    }
                end
            end
            return out
        end
    end

    return nil
end

local function CurrentNodeName()
    local nodes = TaxiNodes()
    if not nodes then return nil end
    for _, node in ipairs(nodes) do
        if node.current then return node.name end
    end
    return nil
end

local function NodeNameBySlot(slot)
    slot = ns.Num(slot)
    if not slot then return nil end
    local nodes = TaxiNodes()
    if not nodes then return nil end
    for _, node in ipairs(nodes) do
        if node.slot == slot then return node.name end
    end
    return nil
end

-- The stops the client will fly through to reach node `slot`, source first and
-- destination last, or nil. The client has already chosen the path by the time
-- the map is open, so it is read rather than worked out: a path computed here
-- would only be right until it disagreed with the server.
--
-- Classic-era calls, and neither is confirmed on this client. Anything short of
-- a complete path that starts here and ends at `slot` comes back nil, and the
-- flight falls back to being keyed by its two ends.
local function RoutePath(slot)
    slot = ns.Num(slot)
    local numRoutes, nodeSlot = _G.GetNumRoutes, _G.TaxiGetNodeSlot
    if not slot or type(numRoutes) ~= "function" or type(nodeSlot) ~= "function" then
        return nil
    end
    local ok, hops = pcall(numRoutes, slot)
    hops = ok and ns.Num(hops) or nil
    if not hops or hops < 1 then return nil end

    local nodes = TaxiNodes()
    if not nodes then return nil end
    local bySlot, here = {}, nil
    for _, node in ipairs(nodes) do
        if node.slot then bySlot[node.slot] = node.name end
        if node.current then here = node.slot end
    end
    if not here or not bySlot[here] or not bySlot[slot] then return nil end

    -- Each hop has two ends, and the third argument picks which: Blizzard's own
    -- flight map reads true as the start and false as the end. Rather than lean
    -- on that, both are read and the chain is followed from where we stand --
    -- whichever end matches the last stop, the other is the next one. A hop
    -- that does not join on is not a path, whatever the flag means.
    local path, at = { bySlot[here] }, here
    for hop = 1, hops do
        local okA, a = pcall(nodeSlot, slot, hop, true)
        local okB, b = pcall(nodeSlot, slot, hop, false)
        a = okA and ns.Num(a) or nil
        b = okB and ns.Num(b) or nil
        local nextStop
        if a == at then nextStop = b elseif b == at then nextStop = a end
        if not nextStop or not bySlot[nextStop] then return nil end
        path[#path + 1] = bySlot[nextStop]
        at = nextStop
    end
    if at ~= slot then return nil end
    return path
end

-------------------------------------------------------------------------------
-- The hardcoded table (FlightData.lua)
-------------------------------------------------------------------------------
-- Keyed by faction, then the route's stops by name, "Ironforge > Thelsamar",
-- each name cut at its first comma: the flight map says "Ironforge, Dun
-- Morogh" where the table says "Ironforge". Names rather than positions
-- because this client's flight maps are framed differently from any list
-- written against another client's -- found in game on 2026-09-25.
--
-- A route with no readable path falls back to its two ends: right for a direct
-- flight, and for a multi-hop one simply not found.

local function Faction()
    local ok, faction = pcall(_G.UnitFactionGroup, "player")
    faction = ok and ns.Text(faction) or nil
    if faction == "Alliance" or faction == "Horde" then return faction end
    return nil
end

-- "The Sepulcher" from "The Sepulcher, Silverpine Forest".
local function ShortName(name)
    if type(name) ~= "string" then return nil end
    return name:match("^%s*(.-)%s*,") or name:match("^%s*(.-)%s*$")
end

-- The table's key for a list of full node names, or nil.
local function TableKey(names)
    if type(names) ~= "table" or #names < 2 then return nil end
    local parts = {}
    for i, name in ipairs(names) do
        local short = ShortName(name)
        if not short or short == "" then return nil end
        parts[i] = short
    end
    return table.concat(parts, " > ")
end

-- Seconds for a table key, this faction's list first and then the other's,
-- for neutral stops both sides share.
local function HardcodedTime(key)
    local data = ns.flightData
    if not key or type(data) ~= "table" then return nil end
    local faction = Faction()
    local order = { faction or "Alliance", faction == "Horde" and "Alliance" or "Horde" }
    for _, side in ipairs(order) do
        local routes = data[side]
        local seconds = type(routes) == "table" and ns.Num(routes[key]) or nil
        if seconds then return seconds end
    end
    return nil
end

-- The stops to look `slot` up by: the path, or failing that its two ends.
local function LookupNames(slot, path)
    if path then return path end
    local here, there = CurrentNodeName(), NodeNameBySlot(slot)
    if not here or not there then return nil end
    return { here, there }
end

-- When the client will not say which stops a flight passes through -- this
-- one does not (2026-09-26: every time flown was saved under its two ends
-- only) -- the table can: every route in it from here to there whose stops
-- in between are all flight points you know, the fastest of them being the
-- one the game flies. Indexed by ends the first time it is needed.
local endsIndex = setmetatable({}, { __mode = "k" })

local function Ends(routes)
    local index = endsIndex[routes]
    if index then return index end
    index = {}
    for key, seconds in pairs(routes) do
        if type(key) == "string" then
            local stops = {}
            for stop in (key .. " > "):gmatch("(.-) > ") do stops[#stops + 1] = stop:lower() end
            if #stops >= 2 then
                local ends = stops[1] .. "|" .. stops[#stops]
                index[ends] = index[ends] or {}
                table.insert(index[ends], { stops = stops, seconds = ns.Num(seconds), key = key })
            end
        end
    end
    endsIndex[routes] = index
    return index
end

-- The best route in the table from `here` to `there` over known points:
-- seconds, and the route's key.
local function ByEnds(here, there)
    local data = ns.flightData
    here, there = ShortName(here), ShortName(there)
    if type(data) ~= "table" or not here or not there then return nil end
    local known = {}
    for _, node in ipairs(TaxiNodes() or {}) do
        if node.known ~= false then
            local short = ShortName(node.name)
            if short then known[short:lower()] = true end
        end
    end
    local faction = Faction()
    local order = { faction or "Alliance", faction == "Horde" and "Alliance" or "Horde" }
    for _, side in ipairs(order) do
        local routes = data[side]
        if type(routes) == "table" then
            local best
            for _, route in ipairs(Ends(routes)[here:lower() .. "|" .. there:lower()] or {}) do
                local usable = route.seconds ~= nil
                for i = 2, #route.stops - 1 do
                    if not known[route.stops[i]] then usable = false break end
                end
                if usable and (not best or route.seconds < best.seconds) then best = route end
            end
            if best then return best.seconds, best.key end
        end
    end
    return nil
end
ns.FlightByEnds = ByEnds

-- The hardcoded time for flying to node `slot` along `path` (from RoutePath),
-- in seconds at normal speed, or nil. With no path from the client, the
-- route is worked out from the table (see ByEnds).
local function Hardcoded(slot, path)
    local seconds = HardcodedTime(TableKey(LookupNames(slot, path)))
    if seconds or path then return seconds end
    local here, there = CurrentNodeName(), NodeNameBySlot(slot)
    return (ByEnds(here, there))
end

-- What "/chair plus flight probe" prints, with a flight map open: every link
-- in the chain from the flight map to the table, so a lookup that finds
-- nothing in game says which link it was.
function ns.FlightProbe()
    local function yes(v) return v and "|cff55ff55yes|r" or "|cffff5555no|r" end
    ns.Print("flight time lookup:")
    print("  C_TaxiMap.GetAllTaxiNodes = "
        .. yes(_G.C_TaxiMap and type(_G.C_TaxiMap.GetAllTaxiNodes) == "function")
        .. "  GetNumRoutes = " .. yes(type(_G.GetNumRoutes) == "function")
        .. "  TaxiGetNodeSlot = " .. yes(type(_G.TaxiGetNodeSlot) == "function"))
    print("  faction = " .. tostring(Faction())
        .. "  table routes = " .. ns.FlightHardcodedCount())

    local nodes = TaxiNodes()
    if not nodes or #nodes == 0 then
        print("  |cffff5555No flight map nodes.|r Open a flight map, then run this again.")
        return
    end
    local here
    for _, node in ipairs(nodes) do if node.current then here = node end end
    if not here then
        print("  |cffff5555No node is marked as the one you are standing at.|r")
        return
    end
    print(string.format("  here: %s (slot %s)", here.name, tostring(here.slot)))

    local found, missing, shown = 0, 0, 0
    for _, node in ipairs(nodes) do
        if not node.current and node.slot then
            local path = RoutePath(node.slot)
            local key = TableKey(LookupNames(node.slot, path))
            local seconds = HardcodedTime(key)
            if not seconds and not path then
                local byEnds, routeKey = ByEnds(here.name, node.name)
                if byEnds then seconds, key = byEnds, (routeKey or key) .. " |cff9d9d9d(worked out)|r" end
            end
            if seconds then found = found + 1 else missing = missing + 1 end
            if shown < 12 then
                shown = shown + 1
                print(string.format("  %s: %s -> %s", node.name,
                    key or "|cffff5555no route|r",
                    seconds and string.format("%ds", seconds)
                        or "|cffff5555not in the table|r"))
            end
        end
    end
    print(string.format("  %d found, %d not found.", found, missing))
end

function ns.FlightHardcodedCount()
    local n = 0
    for _, routes in pairs(ns.flightData or {}) do
        if type(routes) == "table" then
            for _ in pairs(routes) do n = n + 1 end
        end
    end
    return n
end

-- Routes flown on this client that the table is missing or has wrong, in the
-- datasheet's own "seconds, -- Stop, Stop" shape under a faction heading, so
-- they can go straight into the list FlightData.lua is built from. Returns
-- the text and how many routes, or nil and 0.
function ns.FlightCorrections()
    local db = FlightDB()
    if not db then return nil, 0 end
    local byFaction = { Alliance = {}, Horde = {} }
    local count = 0
    for key, entry in pairs(db) do
        local base = BaseTime(entry)
        local flown = type(entry) == "table" and (ns.Num(entry.n) or 0) or 0
        local side = type(entry) == "table" and byFaction[entry.faction] or nil
        if base and flown > 0 and side and type(key) == "string" then
            local names = {}
            for name in (key .. " > "):gmatch("(.-) > ") do names[#names + 1] = name end
            local tableKey = TableKey(names)
            local routes = type(ns.flightData) == "table" and ns.flightData[entry.faction]
            local listed = tableKey and type(routes) == "table" and ns.Num(routes[tableKey]) or nil
            if tableKey and (not listed or math.abs(listed - base) > HARDCODED_TOLERANCE) then
                side[#side + 1] = {
                    sort = tableKey,
                    text = string.format("%d, -- %s%s", math.floor(base + 0.5),
                        (tableKey:gsub(" > ", ", ")),
                        listed and string.format(" (list had %d)", listed) or " (new)"),
                }
                count = count + 1
            end
        end
    end
    if count == 0 then return nil, 0 end
    local lines = {}
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local side = byFaction[faction]
        if #side > 0 then
            table.sort(side, function(x, y) return x.sort < y.sort end)
            lines[#lines + 1] = faction:upper()
            for _, line in ipairs(side) do lines[#lines + 1] = line.text end
            lines[#lines + 1] = ""
        end
    end
    return table.concat(lines, string.char(10)), count
end

-------------------------------------------------------------------------------
-- The countdown
-------------------------------------------------------------------------------

-- Zero-padded both sides, so the clock is a fixed width and does not jump
-- about as it crosses a minute.
local function Clock(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "ChairPlusFlightTimer", UIParent)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetSize(240, 60)

    label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    label:SetPoint("CENTER")
    label:SetJustifyH("CENTER")

    -- Draggable, because the right spot depends on what else is on screen and
    -- there is no arrangement that suits every UI. Saved the same way the
    -- display's position is: the whole anchor tuple, not a guessed point.
    frame:SetScript("OnDragStart", function(self)
        if ns.Get("flightLocked") then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        if type(point) ~= "string" then return end
        ns.SetMany({
            flightAnchor = point,
            flightRelAnchor = type(relPoint) == "string" and relPoint or point,
            flightX = ns.Num(x) or 0,
            flightY = ns.Num(y) or 0,
        })
    end)

    frame:Hide()
    return frame
end

local function PositionFrame()
    if not frame then return end
    frame:ClearAllPoints()
    local anchor = ns.Get("flightAnchor") or "TOP"
    local relAnchor = ns.Get("flightRelAnchor") or anchor
    local x = ns.Num(ns.Get("flightX")) or 0
    local y = ns.Num(ns.Get("flightY")) or -180
    local ok = pcall(frame.SetPoint, frame, anchor, UIParent, relAnchor, x, y)
    if not ok then
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
    end
end

local function ShowCountdown(text)
    if not ns.Get("flightCountdown") then
        if frame then frame:Hide() end
        return
    end
    BuildFrame()
    PositionFrame()

    local size = ns.Num(ns.Get("flightFontSize")) or 32
    local font, _, flags = label:GetFont()
    if font then pcall(label.SetFont, label, font, size, flags or "OUTLINE") end

    pcall(label.SetText, label, text)
    frame:Show()
end

local function HideCountdown()
    if frame then frame:Hide() end
end

-- Unlocked, the timer has to be visible to be dragged -- and it is only ever
-- shown mid-flight, which is a poor moment to be arranging the UI. So while it
-- is unlocked it sits there showing a sample.
local function ShowPreview()
    BuildFrame()
    PositionFrame()
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    local size = ns.Num(ns.Get("flightFontSize")) or 32
    local font, _, flags = label:GetFont()
    if font then pcall(label.SetFont, label, font, size, flags or "OUTLINE") end
    pcall(label.SetText, label, "00:00 |cff808080drag me|r")
    frame:Show()
end

-------------------------------------------------------------------------------
-- The flight itself
-------------------------------------------------------------------------------

local function Begin()
    flying = true
    startedAt = ns.Num(GetTime()) or 0

    route = pending or {}
    pending = nil

    if route.source and route.dest then
        SaveInFlight(route)
    else
        -- No destination picked this session: already in the air when the UI
        -- loaded. If it is the flight written down at takeoff, carry on its
        -- countdown from the real takeoff time -- and never record it.
        local saved, ago = SavedInFlight()
        if saved then
            route = { source = saved.source, dest = saved.dest, path = saved.path,
                      hardcoded = saved.hardcoded, noRecord = true }
            startedAt = startedAt - ago
        end
    end

    if route.source and route.dest then
        route.expected = ns.FlightTime(route.source, route.dest, route.path, route.hardcoded)
    end
end

local function Finish()
    local now = ns.Num(GetTime()) or 0
    local seconds = now - startedAt
    flying = false
    HideCountdown()
    ClearInFlight()

    if not route or not route.source or not route.dest then
        route = nil
        return
    end

    -- Timed across a reload: the countdown was worth carrying on, the time is
    -- not worth keeping.
    if route.noRecord then
        route = nil
        return
    end

    -- A flight cut short -- hearthstone, disconnect, a taxi that never really
    -- started -- would poison the average, and the average is the whole point.
    if seconds < 5 then
        route = nil
        return
    end

    local entry, newFactor, replaced = Record(route.source, route.dest, seconds,
        route.path, route.hardcoded)
    if entry and not entry.faction then entry.faction = Faction() end

    -- A changed speed is worth saying even when the per-flight summary is off:
    -- it silently re-estimates every route in the database, and that is not
    -- something to discover by wondering why the numbers moved. So is a
    -- hardcoded time that turned out wrong here, once, when it is replaced.
    if newFactor then
        ns.Print(string.format(
            "Flight speed now measures %.2fx -- every estimate rescaled.",
            newFactor))
    elseif replaced then
        ns.Print(string.format("%s took %s, not the %s on file -- using yours from now on.",
            (RouteKeys(route.source, route.dest, route.path)), Clock(seconds),
            Clock(replaced * SpeedFactor())))
    elseif entry and ns.Get("flightSummary") then
        ns.Print(string.format("%s took %s",
            (RouteKeys(route.source, route.dest, route.path)), Clock(seconds)))
    end
    route = nil
end

-- Polled rather than driven by events. IsOnTaxi is the one fact that matters
-- and it is always readable; the events that look like they mean "taxi" mean
-- several other things too.
local function Tick()
    local onTaxi = OnTaxi()

    if onTaxi and not flying then
        Begin()
    elseif flying and not onTaxi then
        Finish()
        return
    end

    if not flying then return end

    local now = ns.Num(GetTime()) or 0
    local elapsed = now - startedAt
    local dest = (route and route.dest) and (" " .. route.dest) or ""

    if route and route.expected then
        -- Clamped at zero, never counting past it. A route takes what it
        -- takes, so an estimate that has run out means the clock is a second
        -- out, not that the flight is late -- and a timer that ticks upward
        -- past the arrival it promised reads as broken.
        local remaining = math.max(0, route.expected - elapsed)
        ShowCountdown(Clock(remaining) .. "|cff808080" .. dest .. "|r")
    else
        -- Never flown this route: count up from 00:00, and learn it on
        -- arrival. Said out loud, because a clock climbing towards an unknown
        -- number looks identical to a countdown that is running backwards
        -- until you notice which way the digits are going.
        ShowCountdown(Clock(elapsed) .. "|cff808080" .. dest
            .. " (timing)|r")
    end
end

-------------------------------------------------------------------------------
-- Hooks into the flight map
-------------------------------------------------------------------------------

local function OnTakeTaxiNode(slot)
    local dest = NodeNameBySlot(slot)
    local source = CurrentNodeName()
    -- Recorded even when one half is missing: Begin() checks for both, and a
    -- half-known route still gets a clock, just not a saved time.
    local path = RoutePath(slot)
    -- Looked up now, while the map is open: the key is built from it.
    local okH, hardcoded = pcall(Hardcoded, slot, path)
    pending = { source = source, dest = dest, path = path,
                hardcoded = okH and hardcoded or nil }
end

-- Adds the flight time for a destination to whatever tooltip is open.
local function AppendFlightLine(dest, slot)
    if not ns.Get("flightTooltip") then return end
    local tooltip = _G.GameTooltip
    if not tooltip or not dest then return end

    local source = CurrentNodeName()
    if not source then return end

    -- The node you are standing on. There is no flight to it and never will
    -- be, so "not yet known" there is an answer to a question nobody asked.
    if dest == source then return end

    local path = RoutePath(slot)
    local okH, hardcoded = pcall(Hardcoded, slot, path)
    local seconds, entry = ns.FlightTime(source, dest, path, okH and hardcoded or nil)
    if not seconds then
        pcall(tooltip.AddLine, tooltip, "|cff808080Flight time not yet known|r")
    else
        local suffix = ""
        local n = entry and ns.Num(entry.n) or 0
        if n > 1 then suffix = " |cff808080(" .. n .. " flights)|r" end
        pcall(tooltip.AddLine, tooltip,
            "|cffffd100Flight: " .. Clock(seconds) .. "|r" .. suffix)
    end
    pcall(tooltip.Show, tooltip)
end

-- Route one: the classic taxi frame, where every node button goes through
-- TaxiNodeOnButtonEnter and the button knows its own slot.
local function OnNodeTooltip(button)
    local slot = button and (button.slot
        or (type(button.GetID) == "function" and button:GetID()))
    AppendFlightLine(NodeNameBySlot(slot), slot)
end

-- Route two, for a client whose flight map is not that: watch the tooltip
-- itself while the map is open and match its first line against the node
-- names. Slower and less exact, but it does not care which UI drew the node,
-- which is the point -- the first version hung everything on a classic-only
-- function and showed nothing at all when it was absent.
local function OnTooltipShow()
    if not taxiOpen then return end
    if not ns.Get("flightTooltip") then return end

    local line = _G.GameTooltipTextLeft1
    local text = line and type(line.GetText) == "function" and ns.Text(line:GetText())
    if not text or text == "" then return end

    local nodes = TaxiNodes()
    if not nodes then return end
    for _, node in ipairs(nodes) do
        -- Exact first; a node name often carries its zone while the tooltip
        -- shows only the stop, or the other way about.
        if node.name == text
            or node.name:sub(1, #text) == text
            or text:sub(1, #node.name) == node.name then
            AppendFlightLine(node.name, node.slot)
            return
        end
    end
end

local function InstallHooks()
    if hooked then return end
    local hook = _G.hooksecurefunc

    if type(hook) == "function" and type(_G.TakeTaxiNode) == "function" then
        pcall(hook, "TakeTaxiNode", OnTakeTaxiNode)
        tookHook = true
    end

    if type(hook) == "function" and type(_G.TaxiNodeOnButtonEnter) == "function" then
        pcall(hook, "TaxiNodeOnButtonEnter", OnNodeTooltip)
        tooltipMethod = "TaxiNodeOnButtonEnter"
    else
        local tooltip = _G.GameTooltip
        if tooltip and type(tooltip.HookScript) == "function" then
            local ok = pcall(tooltip.HookScript, tooltip, "OnShow", OnTooltipShow)
            if ok then tooltipMethod = "GameTooltip OnShow" end
        end
    end

    hooked = true
end

-- What this module found on this client. Reported by /chair status, because a
-- flight timer that cannot see flights should say so rather than sit quiet.
function ns.FlightStatus()
    local db = FlightDB()
    local routes = 0
    if db then for _ in pairs(db) do routes = routes + 1 end end
    return {
        taxiProbe = taxiProbeName,
        nodes = TaxiNodes() ~= nil,
        tookHook = tookHook,
        tooltip = tooltipMethod,
        routes = routes,
        hardcoded = ns.FlightHardcodedCount(),
        speed = SpeedFactor(),
    }
end

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

local driver

ns.RegisterModule("flight", {
    title = "Flight path timer",
    desc = "Learn how long each flight takes, then count it down.",
    Apply = function(enabled)
        if not driver then
            driver = CreateFrame("Frame")
            driver.elapsed = 0
            driver:SetScript("OnUpdate", function(self, delta)
                self.elapsed = self.elapsed + (delta or 0)
                -- Four times a second: the clock only ever shows whole
                -- seconds, and a taxi lasts minutes.
                if self.elapsed < 0.25 then return end
                self.elapsed = 0
                local ok, err = pcall(Tick)
                if not ok then
                    -- Never let a broken tick run every frame forever.
                    self:SetScript("OnUpdate", nil)
                    ns.Print("|cffff5555Flight timer stopped:|r", ns.Text(err))
                end
            end)
        end

        if enabled then
            if not FindTaxiProbe() then
                -- Nothing else in here can work without this, and it is the
                -- exact failure the first version hid.
                ns.Print("|cffff5555Flight timer off:|r this client offers no way"
                    .. " to tell when you are on a taxi.")
                driver:Hide()
                return
            end

            InstallHooks()
            SeedDefaults()
            -- On the ground: whatever flight was written down is over.
            if not flying and not OnTaxi() then ClearInFlight() end
            BuildFrame()
            if ns.Get("flightLocked") then
                frame:EnableMouse(false)
                frame:SetMovable(false)
                frame:RegisterForDrag()
                if not flying then frame:Hide() end
            else
                ShowPreview()
            end
            driver:RegisterEvent("TAXIMAP_OPENED")
            driver:RegisterEvent("TAXIMAP_CLOSED")
            driver:SetScript("OnEvent", function(_, event)
                taxiOpen = (event == "TAXIMAP_OPENED")
            end)
            driver:Show()
        else
            driver:UnregisterAllEvents()
            driver:Hide()
            HideCountdown()
            flying = false
            route, pending = nil, nil
        end
    end,
})
