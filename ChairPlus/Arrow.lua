-- ChairPlus Arrow.lua
-- A large green arrow at the top of the screen, pointing at the current
-- waypoint.
--
-- What counts as "the current waypoint", in order:
--   0. your corpse, while you are dead -- it beats everything below;
--   1. the quest you have selected (super-tracked, by clicking it in the
--      tracker or on the map), wherever the client can say where it is --
--      including another zone, which is searched for (see FindQuest);
--   2. the map pin (ctrl-click on the world map);
--   3. nothing, and the arrow disappears.
--
-- Only a quest you picked counts. The watch list does not: the client adds
-- quests to it on its own as they are accepted, so falling back to it kept
-- the arrow up almost all the time with nothing actually chosen.
--
-- Every quest and map API is looked up when it is used and called inside a
-- pcall. This client's quest APIs are a moving target, and a missing one should
-- cost that step of the list, not the arrow. "/chair arrow probe" reports which
-- of them answered, which is how the quest step gets checked in game.
--
-- The art is ChairPlus\arrow.tga: 64 pre-rendered turns of a bevelled 3D arrow,
-- drawn in greys and tinted here. .tests/tools/make_arrow.py rebuilds it. Cell i
-- is the arrow turned i/64 of a turn counter-clockwise from straight ahead.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local TEXTURE = "Interface\\AddOns\\" .. suiteName .. "\\ChairPlus\\arrow"
local GRID, FRAMES = 8, 64
local TICK = 0.05
local ARRIVED_YARDS = 5
local TWO_PI = 2 * math.pi

local frame, arrowTex, label, subLabel, zoneLabel
local elapsed = 0

-------------------------------------------------------------------------------
-- Positions
-------------------------------------------------------------------------------
-- Everything below works in yards east and north of a map's top-left corner.
-- The map's own coordinates run east and SOUTH as fractions of its size, and
-- C_Map.GetMapWorldSize says how many yards that size is.

local function XY(vec)
    if type(vec) ~= "table" and type(vec) ~= "userdata" then return nil end
    local x, y
    if vec.GetXY then
        local ok, a, b = pcall(vec.GetXY, vec)
        if ok then x, y = a, b end
    end
    if x == nil then x, y = vec.x, vec.y end
    x, y = ns.Num(x), ns.Num(y)
    if not x or not y then return nil end
    return x, y
end

local function Vector(x, y)
    if type(_G.CreateVector2D) == "function" then
        local ok, vec = pcall(_G.CreateVector2D, x, y)
        if ok and vec then return vec end
    end
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

local function Call(tbl, name, ...)
    local fn = tbl and tbl[name]
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function PlayerMap()
    local ok, mapID = Call(_G.C_Map, "GetBestMapForUnit", "player")
    return ok and ns.Num(mapID) or nil
end

local function PlayerMapPos(mapID)
    local ok, vec = Call(_G.C_Map, "GetPlayerMapPosition", mapID, "player")
    if not ok then return nil end
    return XY(vec)
end

-- A point on one map re-expressed on another, through world coordinates. The
-- world axes are not assumed: the other map's own corners are converted too,
-- and the point is measured against those, so whichever way the client lays out
-- its world vectors the answer comes back in that map's fractions.
local function WorldPos(mapID, x, y)
    local ok, continent, vec = Call(_G.C_Map, "GetWorldPosFromMapPos", mapID, Vector(x, y))
    if not ok then return nil end
    local wx, wy = XY(vec)
    if not wx then return nil end
    return wx, wy, ns.Num(continent)
end

-- nil, "elsewhere" when the two maps are on different continents: world
-- coordinates are per continent, so there is no direction between them.
local function Translate(fromMap, x, y, toMap)
    if fromMap == toMap then return x, y end
    local wx, wy, wc = WorldPos(fromMap, x, y)
    local ox, oy, oc = WorldPos(toMap, 0, 0)
    if wc and oc and wc ~= oc then return nil, "elsewhere" end
    local ex, ey = WorldPos(toMap, 1, 0)
    local sx, sy = WorldPos(toMap, 0, 1)
    if not (wx and ox and ex and sx) then return nil end
    -- Solve point = origin + u*east + v*south for u, v.
    local ax, ay = ex - ox, ey - oy
    local bx, by = sx - ox, sy - oy
    local det = ax * by - ay * bx
    if det == 0 then return nil end
    local px, py = wx - ox, wy - oy
    return (px * by - py * bx) / det, (ax * py - ay * px) / det
end

local function MapYards(mapID)
    local ok, w, h = Call(_G.C_Map, "GetMapWorldSize", mapID)
    w, h = ok and ns.Num(w), ok and ns.Num(h)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    return w, h
end

-------------------------------------------------------------------------------
-- The waypoint
-------------------------------------------------------------------------------

local function TrackedQuest()
    local ok, id = Call(_G.C_SuperTrack, "GetSuperTrackedQuestID")
    id = ok and ns.Num(id) or nil
    if id and id > 0 then return id end
    return nil
end

local function QuestTitle(questID)
    local ok, title = Call(_G.C_QuestLog, "GetTitleForQuestID", questID)
    return (ok and ns.Text(title)) or ("Quest " .. questID)
end

-- The quest's marker on one map, if it has one there.
local function QuestOnMap(questID, mapID)
    if not mapID then return nil end
    local okList, list = Call(_G.C_QuestLog, "GetQuestsOnMap", mapID)
    if not okList or type(list) ~= "table" then return nil end
    for _, info in ipairs(list) do
        if type(info) == "table" and ns.Num(info.questID) == questID then
            local qx, qy = ns.Num(info.x), ns.Num(info.y)
            if qx and qy then return qx, qy end
        end
    end
    return nil
end

local function MapInfo(mapID)
    local ok, info = Call(_G.C_Map, "GetMapInfo", mapID)
    return (ok and type(info) == "table") and info or nil
end

local function MapName(mapID)
    local info = MapInfo(mapID)
    return info and ns.Text(info.name) or nil
end

local MAP_TYPE = (_G.Enum and _G.Enum.UIMapType) or {}
local CONTINENT = ns.Num(MAP_TYPE.Continent) or 2
local ZONE = ns.Num(MAP_TYPE.Zone) or 3

local function Children(mapID, mapType)
    local ok, list = Call(_G.C_Map, "GetMapChildrenInfo", mapID, mapType, true)
    local out = {}
    if ok and type(list) == "table" then
        for _, info in ipairs(list) do
            local id = type(info) == "table" and ns.Num(info.mapID)
            if id then out[#out + 1] = id end
        end
    end
    return out
end

-- The continent a map sits on, and the map above that (the world).
local function ContinentOf(mapID)
    for _ = 1, 10 do
        if not mapID then return nil end
        local info = MapInfo(mapID)
        if not info then return nil end
        if ns.Num(info.mapType) == CONTINENT then
            local parent = ns.Num(info.parentMapID)
            return mapID, (parent and parent > 0) and parent or nil
        end
        mapID = ns.Num(info.parentMapID)
        if not mapID or mapID <= 0 then return nil end
    end
    return nil
end

-- Maps worth asking about a quest that is not on the player's map, most
-- likely first: the client's own idea of the quest's zone, then every zone on
-- this continent, then every zone on the others.
local function CandidateMaps(questID, playerMap)
    local maps, seen = {}, {}
    local function Add(id)
        id = ns.Num(id)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            maps[#maps + 1] = id
        end
    end
    if type(_G.GetQuestUiMapID) == "function" then
        local okU, hint = pcall(_G.GetQuestUiMapID, questID)
        if okU then Add(hint) end
    end
    local okT, zone = Call(_G.C_TaskQuest, "GetQuestZoneID", questID)
    if okT then Add(zone) end

    local continent, world = ContinentOf(playerMap)
    if continent then
        for _, id in ipairs(Children(continent, ZONE)) do Add(id) end
    end
    if world then
        for _, other in ipairs(Children(world, CONTINENT)) do
            if other ~= continent then
                for _, id in ipairs(Children(other, ZONE)) do Add(id) end
            end
        end
    end
    return maps
end

-- Where the selected quest was last found, so the arrow re-checks one map a
-- tick instead of walking the world. A miss is remembered too, for a couple of
-- seconds: the full walk is dozens of calls, and the arrow ticks 20 times a
-- second.
local found = {}
local SEARCH_EVERY = 2

local function Now()
    local ok, t = pcall(_G.GetTime)
    return ok and ns.Num(t) or 0
end

local function FindQuest(questID, playerMap)
    local x, y = QuestOnMap(questID, playerMap)
    if x then return playerMap, x, y end

    local last = found[questID]
    if last and last.map then
        x, y = QuestOnMap(questID, last.map)
        if x then return last.map, x, y end
    end
    if last and not last.map and (Now() - last.at) < SEARCH_EVERY then return nil end

    for _, mapID in ipairs(CandidateMaps(questID, playerMap)) do
        if mapID ~= playerMap then
            x, y = QuestOnMap(questID, mapID)
            if x then
                found[questID] = { map = mapID, at = Now() }
                return mapID, x, y
            end
        end
    end
    found[questID] = { at = Now() }
    return nil
end

-- Where the client says the quest's objective is: its next waypoint if it has
-- one, else the quest's marker on whichever map carries it.
local function QuestTarget(playerMap)
    local questID = TrackedQuest()
    if not questID then return nil end

    local ok, mapID, x, y = Call(_G.C_QuestLog, "GetNextWaypoint", questID)
    mapID, x, y = ok and ns.Num(mapID), ok and ns.Num(x), ok and ns.Num(y)
    if mapID and x and y then
        return { map = mapID, x = x, y = y, name = QuestTitle(questID), kind = "quest" }
    end

    mapID, x, y = FindQuest(questID, playerMap)
    if mapID then
        return { map = mapID, x = x, y = y, name = QuestTitle(questID), kind = "quest" }
    end
    return nil
end

local function PinTarget()
    local okHas, has = Call(_G.C_Map, "HasUserWaypoint")
    if okHas and not has then return nil end
    local ok, point = Call(_G.C_Map, "GetUserWaypoint")
    if not ok or type(point) ~= "table" then return nil end
    local mapID = ns.Num(point.uiMapID)
    local x, y = XY(point.position)
    if not (mapID and x and y) then return nil end
    return { map = mapID, x = x, y = y, name = "Map pin", kind = "pin" }
end

-- Your corpse, while you are dead. The client places it on a map you ask
-- about, so the player's own map is asked first and then each map above it: a
-- corpse in the next zone over only shows on the continent. Whether you are
-- dead is asked too, but a secret answer does not stop it -- a corpse the
-- client will place is answer enough.
local function CorpseTarget(playerMap)
    local okDead, dead = Call(_G, "UnitIsDeadOrGhost", "player")
    if okDead and ns.Bool(dead) == false then return nil end
    local mapID = playerMap
    for _ = 1, 10 do
        if not mapID or mapID <= 0 then return nil end
        local ok, vec = Call(_G.C_DeathInfo, "GetCorpseMapPosition", mapID)
        if ok then
            local x, y = XY(vec)
            if x and y and (x > 0 or y > 0) then
                return { map = mapID, x = x, y = y, name = "Your corpse", kind = "corpse" }
            end
        end
        local info = MapInfo(mapID)
        mapID = info and ns.Num(info.parentMapID)
    end
    return nil
end

function ns.ArrowTarget(playerMap)
    return CorpseTarget(playerMap) or QuestTarget(playerMap) or PinTarget()
end

-- Bearing and distance from the player to a target, or nil when either end
-- cannot be placed. The bearing is radians COUNTER-clockwise from north, which
-- is the sense GetPlayerFacing uses, so the two subtract directly.
function ns.ArrowVector(target)
    local mapID = PlayerMap()
    if not mapID or not target then return nil end
    local px, py = PlayerMapPos(mapID)
    if not px then return nil end
    local tx, ty = Translate(target.map, target.x, target.y, mapID)
    if not tx then return nil, ty end
    local w, h = MapYards(mapID)
    if not w then return nil end
    local east = (tx - px) * w
    local north = -(ty - py) * h
    local yards = math.sqrt(east * east + north * north)
    local bearing = math.atan2(-east, north)
    return bearing, yards
end

-- Which of the 64 cells shows an arrow turned `relative` radians counter-
-- clockwise from straight ahead.
function ns.ArrowCell(relative)
    local turn = (relative % TWO_PI) / TWO_PI
    return math.floor(turn * FRAMES + 0.5) % FRAMES
end

-- Green when roughly ahead, through yellow to red when behind.
function ns.ArrowColour(relative)
    local off = math.abs(((relative + math.pi) % TWO_PI) - math.pi) / math.pi
    if off <= 0.25 then return 0.2, 1, 0.25 end
    if off <= 0.6 then
        local t = (off - 0.25) / 0.35
        return 0.2 + 0.8 * t, 1, 0.25 * (1 - t)
    end
    local t = math.min(1, (off - 0.6) / 0.4)
    return 1, 1 - 0.75 * t, 0
end

local function Yards(yards)
    if yards >= 1000 then return string.format("%.1fk yd", yards / 1000) end
    return string.format("%d yd", math.floor(yards + 0.5))
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

-- The styles on offer. The 3D ones (sheet = true) are 64 pre-rendered turns
-- each, drawn cell by cell like the original: "bevel" is arrow.tga above, the
-- rest come from .tests/tools/make_arrow3d_styles.py. The flat ones are single
-- textures pointing straight up, from make_arrow_styles.py, which the client
-- turns itself.
local ARROW_STYLES = {
    { value = "bevel",      text = "3D arrow",          sheet = true },
    { value = "needle3d",   text = "3D compass needle", sheet = true, file = "arrow3d_needle" },
    { value = "dart3d",     text = "3D GPS dart",       sheet = true, file = "arrow3d_dart" },
    { value = "chevron3d",  text = "3D chevrons",       sheet = true, file = "arrow3d_chevron" },
    { value = "triangle3d", text = "3D triangle",       sheet = true, file = "arrow3d_triangle" },
    { value = "flat",       text = "Flat arrow" },
    { value = "chevron",    text = "Chevrons" },
    { value = "needle",     text = "Compass needle" },
    { value = "dart",       text = "GPS dart" },
    { value = "triangle",   text = "Triangle" },
    { value = "ring",       text = "Ring pointer" },
}
ns.ARROW_STYLES = ARROW_STYLES

local function StyleEntry(style)
    for _, entry in ipairs(ARROW_STYLES) do
        if entry.value == style then return entry end
    end
    return nil
end

local function StyleTexture(style)
    if style == "bevel" then return TEXTURE end
    local entry = StyleEntry(style)
    if not entry then return nil end
    return "Interface\\AddOns\\" .. suiteName .. "\\ChairPlus\\" .. (entry.file or ("arrow_" .. style))
end

local function Style()
    local style = ns.Get("arrowStyle")
    if StyleTexture(style) then return style end
    return "bevel"
end

local shownStyle

local function SetCell(cell)
    local col, row = cell % GRID, math.floor(cell / GRID)
    arrowTex:SetTexCoord(col / GRID, (col + 1) / GRID, row / GRID, (row + 1) / GRID)
end

-- Turn a flat style `angle` radians counter-clockwise. SetRotation where the
-- client has it; otherwise the texture coordinates are turned instead, which
-- every client supports and looks the same for a square texture.
local function Turn(angle)
    if arrowTex.SetRotation and pcall(arrowTex.SetRotation, arrowTex, angle) then return end
    local c, s = math.cos(angle), math.sin(angle)
    local function corner(x, y)
        -- Screen corner (x, y) about the centre shows texture point turned by -angle.
        return 0.5 + (x * c + y * s), 0.5 + (-x * s + y * c)
    end
    local ulx, uly = corner(-0.5, -0.5)
    local llx, lly = corner(-0.5, 0.5)
    local urx, ury = corner(0.5, -0.5)
    local lrx, lry = corner(0.5, 0.5)
    arrowTex:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

-- Point the arrow `relative` radians counter-clockwise from straight ahead,
-- in whichever style is chosen.
local function Point(relative)
    local style = Style()
    if style ~= shownStyle then
        arrowTex:SetTexture(StyleTexture(style))
        arrowTex:SetTexCoord(0, 1, 0, 1)
        if arrowTex.SetRotation then pcall(arrowTex.SetRotation, arrowTex, 0) end
        shownStyle = style
    end
    local entry = StyleEntry(style)
    if entry and entry.sheet then
        SetCell(ns.ArrowCell(relative))
    else
        Turn(relative)
    end
end

local function Tint(relative, alpha)
    local r, g, b = 0.2, 1, 0.25
    if ns.Get("arrowCustomColor") then
        -- A color of your own choosing replaces the direction coloring.
        r = ns.Num(ns.Get("arrowColorR")) or r
        g = ns.Num(ns.Get("arrowColorG")) or g
        b = ns.Num(ns.Get("arrowColorB")) or b
    elseif relative and ns.Get("arrowDirectionColour") then
        r, g, b = ns.ArrowColour(relative)
    end
    arrowTex:SetVertexColor(r, g, b, alpha or 1)
end

-- The zone a map belongs to: the map itself if it is a zone, else the zone
-- above it (a subzone, a city district). nil for a continent or anything
-- that sits under none.
local ZONE_TYPE = ns.Num(((_G.Enum and _G.Enum.UIMapType) or {}).Zone) or 3
local function ZoneOf(mapID)
    for _ = 1, 10 do
        local info = mapID and MapInfo(mapID)
        if not info then return nil end
        local kind = ns.Num(info.mapType)
        if kind == ZONE_TYPE then return mapID, ns.Text(info.name) end
        if not kind or kind < ZONE_TYPE then return nil end
        mapID = ns.Num(info.parentMapID)
    end
    return nil
end

-- The game's own pop-up text: the zone and subzone names on entering, their
-- PvP lines, raid warnings and boss emotes. While any of it sits over the
-- arrow, the arrow fades out as the text fades in and comes back as it goes.
-- Only read, never driven (see never-drive-blizzard-frames); a string this
-- client lacks or will not measure is skipped.
local POPUP_TEXT = {
    "ZoneTextString", "PVPInfoTextString",
    "SubZoneTextString", "PVPArenaTextString",
    "RaidWarningFrameSlot1", "RaidWarningFrameSlot2",
    "RaidBossEmoteFrameSlot1", "RaidBossEmoteFrameSlot2",
}

-- A region's box in screen pixels, so frames at different scales compare.
local function ScreenBox(region, width, height)
    local okC, cx, cy = pcall(region.GetCenter, region)
    local okS, scale = pcall(region.GetEffectiveScale, region)
    cx, cy, scale = okC and ns.Num(cx), okC and ns.Num(cy), okS and ns.Num(scale)
    if not (cx and cy and scale and width and height) then return nil end
    local hw, hh = width * scale / 2, height * scale / 2
    cx, cy = cx * scale, cy * scale
    return cx - hw, cx + hw, cy - hh, cy + hh
end

-- A font string's box: as wide as its text, not the 512 the zone text is laid
-- out in.
local function TextBox(fs)
    local okW, w = pcall(fs.GetStringWidth, fs)
    local okH, h = pcall(fs.GetStringHeight, fs)
    w, h = okW and ns.Num(w), okH and ns.Num(h)
    if not w or w <= 0 then return nil end
    return ScreenBox(fs, w, (h and h > 0) and h or 24)
end

-- The red and yellow messages ("Out of range.", quest progress) go through
-- UIErrorsFrame, a scrolling message frame with no font strings of its own to
-- read. So its AddMessage is hooked (after the fact, never replaced): each
-- message is timed and measured in a hidden font string in the frame's font,
-- and counts as covering the frame's band, as wide as the text, while it is up
-- and fading. A message that cannot be measured counts as the frame's width.
local errorLines, measure = {}, nil
local ERROR_HOLD, ERROR_FADE = 2, 1.5

local function ErrorTiming()
    local f = _G.UIErrorsFrame
    local okH, hold = pcall(function() return f:GetTimeVisible() end)
    local okF, fade = pcall(function() return f:GetFadeDuration() end)
    hold, fade = okH and ns.Num(hold), okF and ns.Num(fade)
    return (hold and hold > 0) and hold or ERROR_HOLD, (fade and fade >= 0) and fade or ERROR_FADE
end

local function OnErrorMessage(_, text)
    if not ns.Get("arrowHideForZoneText") then return end
    local width
    if measure then
        local f = _G.UIErrorsFrame
        pcall(function() measure:SetFont(f:GetFont()) end)
        if pcall(measure.SetText, measure, text) then
            local ok, w = pcall(measure.GetStringWidth, measure)
            width = ok and ns.Num(w) or nil
            pcall(measure.SetText, measure, "")
        end
    end
    local hold, fade = ErrorTiming()
    local now = Now()
    -- Drop the ones long gone, and keep no more than the frame can show.
    for i = #errorLines, 1, -1 do
        local line = errorLines[i]
        if now - line.at > line.hold + line.fade then table.remove(errorLines, i) end
    end
    if #errorLines >= 5 then table.remove(errorLines, 1) end
    errorLines[#errorLines + 1] = { at = now, width = width, hold = hold, fade = fade }
end

local function HookErrors()
    local f = _G.UIErrorsFrame
    if measure or not f or type(_G.hooksecurefunc) ~= "function" then return end
    measure = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    measure:Hide()
    pcall(_G.hooksecurefunc, f, "AddMessage", OnErrorMessage)
end

-- The strongest error message still on screen and over the arrow's box.
local function ErrorCover(l, r, b, t)
    local f = _G.UIErrorsFrame
    if not f or #errorLines == 0 then return 0 end
    local okV, visible = pcall(f.IsVisible, f)
    if not (okV and ns.Bool(visible)) then return 0 end
    local okW, fw = pcall(f.GetWidth, f)
    local okH, fh = pcall(f.GetHeight, f)
    fw, fh = okW and ns.Num(fw), okH and ns.Num(fh)
    local now, cover = Now(), 0
    for _, line in ipairs(errorLines) do
        local age = now - line.at
        local a = 0
        if age < line.hold then
            a = 1
        elseif line.fade > 0 and age < line.hold + line.fade then
            a = 1 - (age - line.hold) / line.fade
        end
        if a > cover then
            local width = line.width and fw and math.min(line.width, fw) or fw
            local el, er, eb, et = ScreenBox(f, width, fh)
            if el and el < r and er > l and eb < t and et > b then cover = a end
        end
    end
    return cover
end

-- How strongly the pop-up text covers the arrow, 0 (not at all) to 1.
local function PopupCover()
    if not ns.Get("arrowHideForZoneText") then return 0 end
    local okW, fw = pcall(frame.GetWidth, frame)
    local okH, fh = pcall(frame.GetHeight, frame)
    local l, r, b, t = ScreenBox(frame, okW and ns.Num(fw), okH and ns.Num(fh))
    if not l then return 0 end
    for _, fs in ipairs({ label, subLabel, zoneLabel }) do
        local fl, fr, fb, ft = TextBox(fs)
        if fl then
            l, r, b, t = math.min(l, fl), math.max(r, fr), math.min(b, fb), math.max(t, ft)
        end
    end

    local cover = ErrorCover(l, r, b, t)
    for _, name in ipairs(POPUP_TEXT) do
        local fs = _G[name]
        local okV, visible = pcall(function() return fs and fs:IsVisible() end)
        if okV and ns.Bool(visible) then
            local okA, a = pcall(function() return fs:GetAlpha() * fs:GetParent():GetEffectiveAlpha() end)
            a = okA and ns.Num(a) or 1
            if a > cover then
                local pl, pr, pb, pt = TextBox(fs)
                if pl and pl < r and pr > l and pb < t and pt > b then cover = a end
            end
        end
    end
    return math.min(1, cover)
end

local function SetLines(distance, name, zone)
    label:SetText(distance or "")
    pcall(subLabel.SetText, subLabel, ns.Get("arrowShowName") and name or "")
    pcall(zoneLabel.SetText, zoneLabel, zone or "")
end

local function Update()
    local playerMap = PlayerMap()
    local target = ns.ArrowTarget(playerMap)
    local bearing, yards
    if target then bearing, yards = ns.ArrowVector(target) end

    ns.arrowState = { target = target, bearing = bearing, yards = yards }
    local alpha = math.max(0.1, math.min(1, ns.Num(ns.Get("arrowAlpha")) or 1))

    -- On another continent there is no direction to give, but there is still
    -- somewhere to go: say where, and leave the arrow out.
    if not bearing and target and yards == "elsewhere" then
        frame:SetAlpha(alpha * (1 - PopupCover()))
        frame:EnableMouse(not ns.Get("arrowLocked"))
        arrowTex:Hide()
        -- "Go to Kalimdor" is the instruction; the zone rides along with the
        -- quest's name underneath, for once you are there.
        local zone = MapName(target.map)
        local continent = MapName(ContinentOf(target.map))
        local detail = target.name or ""
        if continent and zone then detail = detail .. " (" .. zone .. ")" end
        SetLines(continent and ("Go to " .. continent)
            or (zone and ("Go to " .. zone)) or "On another continent", detail)
        return
    end

    if not bearing then
        -- Nothing selected, or nowhere to point from (inside an instance the
        -- client will not place the player): the arrow disappears. The frame
        -- itself stays shown, invisible and click-through, because a hidden
        -- frame stops getting OnUpdate and would never notice a new target.
        -- The one exception is while it is being set up: on the Travel page of
        -- the menu, or unlocked for moving, and only while the menu is open.
        -- Close the menu with nothing to track and it goes.
        local page = ns.PanelPage and ns.PanelPage()
        local moving = page ~= nil and (page == "travel" or not ns.Get("arrowLocked"))
        arrowTex:SetShown(moving)
        if moving then
            Point(0)
            Tint(nil, 0.6)
        end
        SetLines("", nil, nil)
        frame:SetAlpha(moving and alpha or 0)
        frame:EnableMouse(moving)
        return
    end

    frame:SetAlpha(alpha * (1 - PopupCover()))
    frame:EnableMouse(not ns.Get("arrowLocked"))
    arrowTex:Show()
    local okF, facing = pcall(_G.GetPlayerFacing)
    facing = okF and ns.Num(facing) or 0
    local relative = bearing - facing

    -- The target's zone, when it is not the one you are standing in -- a quest
    -- in the next zone over says where the arrow is taking you.
    local zone
    local targetZone, targetZoneName = ZoneOf(target.map)
    local hereZone = ZoneOf(playerMap)
    if targetZone and targetZone ~= hereZone then zone = targetZoneName end

    local distance
    if yards <= ARRIVED_YARDS then
        Point(0)
        Tint(nil, 0.45)
        distance = "Arrived"
    else
        Point(relative)
        Tint(relative, 1)
        distance = Yards(yards)
    end
    SetLines(ns.Get("arrowShowDistance") and distance or "", target.name, zone)
end

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if type(point) ~= "string" then return end
    ns.SetMany({
        arrowAnchor = point,
        arrowRelAnchor = type(relPoint) == "string" and relPoint or point,
        arrowX = ns.Num(x) or 0,
        arrowY = ns.Num(y) or 0,
    })
end

local function ApplyPosition()
    frame:ClearAllPoints()
    local ok = pcall(frame.SetPoint, frame, ns.Get("arrowAnchor") or "TOP", UIParent,
        ns.Get("arrowRelAnchor") or "TOP",
        ns.Num(ns.Get("arrowX")) or 0, ns.Num(ns.Get("arrowY")) or -60)
    if not ok then
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", 0, -60)
    end
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "ChairPlusArrow", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetSize(120, 150)

    arrowTex = frame:CreateTexture(nil, "ARTWORK")
    arrowTex:SetTexture(TEXTURE)
    arrowTex:SetSize(120, 120)
    arrowTex:SetPoint("TOP")

    label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("TOP", arrowTex, "BOTTOM", 0, 6)
    label:SetTextColor(1, 1, 1)

    subLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subLabel:SetPoint("TOP", label, "BOTTOM", 0, -2)

    -- The zone, under the quest's name and in the same font and size.
    zoneLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    zoneLabel:SetPoint("TOP", subLabel, "BOTTOM", 0, -2)

    HookErrors()

    frame:SetScript("OnDragStart", function(self)
        if ns.Get("arrowLocked") then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (ns.Num(dt) or 0)
        if elapsed < TICK then return end
        elapsed = 0
        local ok, err = pcall(Update)
        if not ok and not ns.arrowErrorShown then
            ns.arrowErrorShown = true
            ns.Print("|cffff5555Waypoint arrow:|r", ns.Text(err) or "unknown error")
        end
    end)
end

ns.RegisterModule("arrow", {
    title = "Waypoint arrow",
    desc = "A large arrow at the top of the screen pointing at the tracked quest or map pin, or your corpse while you are dead.",
    Apply = function(enabled)
        if not enabled then
            if frame then frame:Hide() end
            return
        end
        Build()
        local scale = ns.Num(ns.Get("arrowScale")) or 1
        if scale < 0.5 then scale = 0.5 elseif scale > 3 then scale = 3 end
        frame:SetScale(scale)

        local locked = ns.Get("arrowLocked") and true or false
        frame:EnableMouse(not locked)
        frame:SetMovable(not locked)
        if locked then frame:RegisterForDrag() else frame:RegisterForDrag("LeftButton") end

        ApplyPosition()
        frame:Show()
        shownStyle = nil        -- a style change takes effect on the next tick
        elapsed = TICK
    end,
})

-- What "/chair arrow probe" prints: every API the arrow could use, whether it
-- exists, and what the current target resolves to.
function ns.ArrowProbe()
    local names = {
        { "C_DeathInfo", "GetCorpseMapPosition" },
        { "C_SuperTrack", "GetSuperTrackedQuestID" },
        { "C_QuestLog", "GetNextWaypoint" },
        { "C_QuestLog", "GetQuestsOnMap" },
        { "C_Map", "GetMapInfo" },
        { "C_Map", "GetMapChildrenInfo" },
        { "C_TaskQuest", "GetQuestZoneID" },
        { "C_QuestLog", "GetTitleForQuestID" },
        { "C_Map", "GetUserWaypoint" },
        { "C_Map", "GetBestMapForUnit" },
        { "C_Map", "GetPlayerMapPosition" },
        { "C_Map", "GetWorldPosFromMapPos" },
        { "C_Map", "GetMapWorldSize" },
    }
    ns.Print("waypoint arrow APIs:")
    for _, pair in ipairs(names) do
        local tbl = _G[pair[1]]
        local present = type(tbl) == "table" and type(tbl[pair[2]]) == "function"
        print("  " .. pair[1] .. "." .. pair[2] .. " = "
            .. (present and "|cff55ff55yes|r" or "|cffff5555missing|r"))
    end
    for _, name in ipairs({ "GetPlayerFacing", "GetQuestUiMapID" }) do
        print("  " .. name .. " = " .. (type(_G[name]) == "function"
            and "|cff55ff55yes|r" or "|cffff5555missing|r"))
    end
    local playerMap = PlayerMap()
    print("  player map = " .. tostring(playerMap))
    local quest = TrackedQuest()
    print("  selected quest = " .. tostring(quest))
    local target = ns.ArrowTarget(playerMap)
    if target then
        local bearing, yards = ns.ArrowVector(target)
        print(string.format("  target = %s (%s) on map %s (%s), %s",
            tostring(target.name), target.kind, tostring(target.map),
            tostring(MapName(target.map)),
            type(yards) == "number" and Yards(yards)
                or (yards == "elsewhere" and "on another continent" or "cannot place it")))
    elseif quest then
        print("  target = none: the quest has no marker on any map the client "
            .. "would list (" .. #CandidateMaps(quest, playerMap) .. " searched)")
    else
        print("  target = none")
    end
end
