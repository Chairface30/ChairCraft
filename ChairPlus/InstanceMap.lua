-- ChairPlus InstanceMap.lua
-- Dungeon and raid entrances on the world map.
--
-- This client has no Encounter Journal data, so its world map draws no
-- entrances of its own. Where each one is comes from the client's tables
-- instead (InstanceData.lua, built by .tests/tools/build_instances.py): an
-- icon on every zone map that shows the entrance, and on the continent map,
-- placed from its own zone's map. Hovering one names what is entered there;
-- clicking it puts the game's map pin on it, which the waypoint arrow follows.
--
-- Everything sits on a frame of our own laid over the map's canvas. The map
-- is only read (which map it shows, its pin levels), never driven, and an
-- error here is caught so it can never break the map.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairPlus

local SIZE = 20             -- icon size on screen, whatever the zoom
local enabled = false
local overlay, built
local pins, used = {}, 0
local drawnFor             -- the map the icons were last drawn for

local function Canvas()
    local map = _G.WorldMapFrame
    local sc = map and map.ScrollContainer
    return map, sc and sc.Child
end

local function ShownMap()
    local map = Canvas()
    if not map or type(map.GetMapID) ~= "function" then return nil end
    local ok, mapID = pcall(map.GetMapID, map)
    return ok and ns.Num(mapID) or nil
end

-- The game's own dungeon and raid icons, when it has them.
local function HasAtlas(name)
    local CT = _G.C_Texture
    if not (CT and type(CT.GetAtlasInfo) == "function") then return false end
    local ok, info = pcall(CT.GetAtlasInfo, name)
    return ok and info ~= nil
end

local function SetIcon(tex, raid)
    local atlas = raid and "Raid" or "Dungeon"
    if HasAtlas(atlas) and pcall(tex.SetAtlas, tex, atlas) then
        tex:SetVertexColor(1, 1, 1)
        return
    end
    -- no such atlas: the target frame's skull, which every client has
    tex:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    pcall(tex.SetTexCoord, tex, 0, 1, 0, 1)
    if raid then tex:SetVertexColor(1, 0.55, 0.3) else tex:SetVertexColor(1, 1, 1) end
end

local function IsRaid(entry)
    for _, inst in ipairs(entry.instances) do
        if not inst[2] then return false end
    end
    return true
end

-- Put the game's map pin on an entrance, on its own zone's map.
local function PinIt(entry)
    local CM = _G.C_Map
    local mk = _G.UiMapPoint and _G.UiMapPoint.CreateFromCoordinates
    local pos = entry.maps[entry.home]
    if not (CM and type(CM.SetUserWaypoint) == "function" and type(mk) == "function" and pos) then return end
    local okP, point = pcall(mk, entry.home, pos[1], pos[2])
    if okP and point and pcall(CM.SetUserWaypoint, point) then
        local track = _G.C_SuperTrack and _G.C_SuperTrack.SetSuperTrackedUserWaypoint
        if type(track) == "function" then pcall(track, true) end
        ns.Print("map pin set on " .. entry.name .. ".")
    end
end

local function Pin()
    used = used + 1
    local p = pins[used]
    if not p then
        p = CreateFrame("Button", nil, overlay)
        p:SetSize(SIZE, SIZE)
        p.icon = p:CreateTexture(nil, "ARTWORK")
        p.icon:SetAllPoints()
        p:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
        p:SetScript("OnEnter", function(self)
            local e = self.entry
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(e.name, 1, 1, 1)
            for _, inst in ipairs(e.instances) do
                GameTooltip:AddDoubleLine(inst[1], inst[2] and "Raid" or "Dungeon", 1, 0.82, 0, 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("Click to put a map pin here.", 0.6, 1, 0.6)
            GameTooltip:Show()
        end)
        p:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p:SetScript("OnClick", function(self) if self.entry then PinIt(self.entry) end end)
        pins[used] = p
    end
    p:Show()
    return p
end

-- An icon's anchor offsets are counted in its own scaled units, and the icons
-- are scaled to stay one size as the map zooms: the offsets are divided by
-- that scale, or every icon drifts away from its spot.
local function Place(p, x, y, w, h, inv)
    p:SetScale(inv)
    p:ClearAllPoints()
    p:SetPoint("CENTER", overlay, "TOPLEFT", x * w / inv, -y * h / inv)
end

-- Where a zone map lies on a bigger map (the continent), as fractions of it:
-- left, right, top, bottom. nil when the game can't say.
local rectCache = {}
local function RectOn(zone, mapID)
    local key = zone .. ":" .. mapID
    local r = rectCache[key]
    if r == nil then
        r = false
        local fn = _G.C_Map and _G.C_Map.GetMapRectOnMap
        if type(fn) == "function" then
            local ok, l, ri, t, b = pcall(fn, zone, mapID)
            l, ri, t, b = ns.Num(l), ns.Num(ri), ns.Num(t), ns.Num(b)
            if ok and l and ri and t and b and ri > l and b > t then r = { l, ri, t, b } end
        end
        rectCache[key] = r
    end
    return r or nil
end

-- What kind of map is shown: the continents get every entrance on them.
local function IsContinent(mapID)
    local fn = _G.C_Map and _G.C_Map.GetMapInfo
    if type(fn) ~= "function" then return false end
    local ok, info = pcall(fn, mapID)
    local kind = ok and type(info) == "table" and ns.Num(info.mapType)
    local continent = _G.Enum and _G.Enum.UIMapType and _G.Enum.UIMapType.Continent or 2
    return kind == continent
end

-- The map's own level for dungeon entrances, so quest pins and the like still
-- go over ours; above the map art if the map doesn't say.
local function Level(map, child)
    local base = (child:GetFrameLevel() or 1) + 10
    local okM, mgr = pcall(function() return map:GetPinFrameLevelsManager() end)
    if not (okM and type(mgr) == "table" and mgr.GetValidFrameLevel) then return base end
    local ok, level = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_DUNGEON_ENTRANCE")
    return (ok and ns.Num(level)) or base
end

local function Refresh()
    if not overlay then return end
    for i = 1, used do pins[i]:Hide() end
    used = 0
    local map, child = Canvas()
    if not enabled or not (map and map:IsShown()) then
        drawnFor = nil
        overlay:Hide()
        return
    end
    overlay:Show()
    overlay:SetFrameLevel(Level(map, child))
    local mapID = ShownMap()
    drawnFor = mapID
    if not mapID then return end
    local okS, scale = pcall(overlay.GetEffectiveScale, overlay)
    local inv = (okS and ns.Num(scale) and scale > 0) and (UIParent:GetEffectiveScale() / scale) or 1
    -- the overlay covers the canvas exactly: its size is the canvas's
    local w, h = ns.Num(child:GetWidth()) or 0, ns.Num(child:GetHeight()) or 0
    local continent = IsContinent(mapID)
    for _, e in ipairs(ns.instanceEntrances or {}) do
        local x, y
        local pos = e.maps[mapID]
        if pos then
            x, y = pos[1], pos[2]
        elseif continent then
            local r = RectOn(e.home, mapID)
            local home = e.maps[e.home]
            if r and home then
                x, y = r[1] + home[1] * (r[2] - r[1]), r[3] + home[2] * (r[4] - r[3])
            end
        end
        if x then
            local p = Pin()
            p.entry = e
            SetIcon(p.icon, IsRaid(e))
            Place(p, x, y, w, h, inv)
        end
    end
end

-- From the map's own hooks: an error must never break the map, but the first
-- one is said in chat so it gets reported.
local reported = false
local function SafeRefresh()
    local ok, err = pcall(Refresh)
    if not ok and not reported then
        reported = true
        ns.Print("|cffff5555instance icons on the world map:|r", err)
    end
end
ns.RefreshInstanceMap = SafeRefresh

local function Build()
    if built then return true end
    local map, child = Canvas()
    if not (map and child) then return false end
    built = true
    overlay = CreateFrame("Frame", nil, child)
    overlay:SetAllPoints(child)
    if type(map.OnMapChanged) == "function" then
        pcall(hooksecurefunc, map, "OnMapChanged", SafeRefresh)
    end
    map:HookScript("OnShow", SafeRefresh)
    child:HookScript("OnSizeChanged", SafeRefresh)
    -- Not every way of changing the map tells its hooks, and zooming changes
    -- how big the icons must be drawn: checked a few times a second while the
    -- map is open (the overlay is hidden, and so silent, while it is closed).
    local tick, lastInv = 0, nil
    overlay:SetScript("OnUpdate", function(self, dt)
        tick = tick + (ns.Num(dt) or 0)
        if tick < 0.2 then return end
        tick = 0
        local okS, scale = pcall(self.GetEffectiveScale, self)
        local inv = okS and ns.Num(scale) or nil
        if ShownMap() ~= drawnFor or inv ~= lastInv then
            lastInv = inv
            SafeRefresh()
        end
    end)
    return true
end

-- The world map can arrive after login on some clients: built when it does.
local waiter
local function BuildWhenReady()
    if Build() then return end
    if waiter then return end
    waiter = CreateFrame("Frame")
    waiter:RegisterEvent("ADDON_LOADED")
    waiter:SetScript("OnEvent", function(self)
        if Build() then
            self:UnregisterAllEvents()
            SafeRefresh()
        end
    end)
end

ns.RegisterModule("instanceMap", {
    title = "Instance entrances on the world map",
    desc = "Draw an icon on the world map where each dungeon and raid is entered.",
    Apply = function(on)
        enabled = on and true or false
        if enabled then BuildWhenReady() end
        SafeRefresh()
    end,
})
