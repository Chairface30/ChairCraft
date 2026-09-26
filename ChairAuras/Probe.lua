local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- What this client allows: /chair auras probe
-------------------------------------------------------------------------------
-- ChairAuras is growing toward WeakAuras' feature set, and every piece of that
-- rests on a client call: custom Lua needs loadstring and setfenv, a health
-- trigger needs a readable UnitHealth, a combat log trigger needs the combat
-- log. This client is the retail engine running classic content, with some
-- calls missing, some protected and some returning secret values -- and the
-- offline harness can say nothing about which. So the client is asked.
--
-- Two halves. The checks run when the command is typed. The listener runs from
-- login and notes which events actually fire here and what they carry, since
-- an event that never fires looks exactly like one that exists but is quiet.
-- Both are printed and kept in ChairAurasDB.probe, so the saved file carries
-- the answers after a /reload.

local Probe = {}
ns.Probe = Probe

-- "yes", "missing", "secret", "error: ...", or "yes: detail".
local function Fn(path)
    local value = _G
    for part in path:gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
    end
    return value
end

local function Describe(value)
    if value == nil then return "nil" end
    if ns.IsSecret(value) then return "SECRET" end
    local kind = type(value)
    if kind == "table" then return "table" end
    if kind == "function" then return "function" end
    local ok, text = pcall(tostring, value)
    return ok and text or "?"
end

-- Call path(...) and describe what came back, value by value.
local function Returns(path, ...)
    local fn = Fn(path)
    if type(fn) ~= "function" then return "missing" end
    local results = { pcall(fn, ...) }
    if not results[1] then return "error: " .. Describe(results[2]) end
    local parts, secret = {}, false
    for i = 2, math.min(#results, 9) do
        local d = Describe(results[i])
        if d == "SECRET" then secret = true end
        parts[#parts + 1] = d
    end
    local text = table.concat(parts, ", ")
    if secret then return "secret: " .. text end
    return "yes: " .. (text ~= "" and text or "(nothing)")
end

local function Exists(path)
    return type(Fn(path)) == "function" and "yes" or "missing"
end

-- The fields of a returned table, each marked readable or secret.
local function Fields(data, names)
    if type(data) ~= "table" then return "no table (" .. Describe(data) .. ")" end
    local parts = {}
    for _, name in ipairs(names) do
        parts[#parts + 1] = name .. "=" .. Describe(data[name])
    end
    return table.concat(parts, " ")
end

-------------------------------------------------------------------------------
-- The checks
-------------------------------------------------------------------------------

local CHECKS = {}
-- A buff read out of combat: { spellId, instanceID, name }. The in-combat run
-- asks for this same buff by both handles.
local known
local function Check(group, name, run) CHECKS[#CHECKS + 1] = { group, name, run } end

-- Custom Lua
Check("lua", "loadstring", function()
    local load = Fn("loadstring")
    if type(load) ~= "function" then return "missing" end
    local ok, fn = pcall(load, "return 1 + 1")
    if not ok or type(fn) ~= "function" then return "error: " .. Describe(fn) end
    local okR, value = pcall(fn)
    return (okR and value == 2) and "yes" or ("error: " .. Describe(value))
end)
Check("lua", "setfenv", function()
    local load, set = Fn("loadstring"), Fn("setfenv")
    if type(set) ~= "function" then return "missing" end
    if type(load) ~= "function" then return "untested (no loadstring)" end
    local fn = load("return probeValue")
    local ok = pcall(set, fn, { probeValue = 42 })
    if not ok then return "error: refused" end
    local okR, value = pcall(fn)
    return (okR and value == 42) and "yes" or "error: environment not applied"
end)
Check("lua", "getfenv", function() return Exists("getfenv") end)
Check("lua", "issecretvalue", function() return Exists("issecretvalue") end)
Check("lua", "canaccessvalue", function() return Exists("canaccessvalue") end)
Check("lua", "C_Timer.After / NewTimer / NewTicker", function()
    return Exists("C_Timer.After") .. " / " .. Exists("C_Timer.NewTimer") .. " / "
        .. Exists("C_Timer.NewTicker")
end)

-- Auras
Check("auras", "C_UnitAuras.GetAuraDataByIndex (player, 1)", function()
    local fn = Fn("C_UnitAuras.GetAuraDataByIndex")
    if type(fn) ~= "function" then return "missing" end
    local ok, data = pcall(fn, "player", 1, "HELPFUL")
    if not ok then return "error: " .. Describe(data) end
    if data == nil then return "yes, but you have no buff to read -- buff up and probe again" end
    if not ns.IsSecret(data.spellId) and not ns.IsSecret(data.auraInstanceID) then
        known = { spellId = data.spellId, instanceID = data.auraInstanceID,
                  name = ns.SafeText(data.name) }
    end
    return "yes: " .. Fields(data, { "name", "spellId", "icon", "applications", "duration",
        "expirationTime", "sourceUnit", "auraInstanceID", "dispelName", "isStealable",
        "isFromPlayerOrPlayerPet", "points" })
end)
Check("auras", "C_UnitAuras.GetAuraDataByAuraInstanceID", function()
    return Exists("C_UnitAuras.GetAuraDataByAuraInstanceID")
end)
Check("auras", "C_UnitAuras.GetPlayerAuraBySpellID", function()
    return Exists("C_UnitAuras.GetPlayerAuraBySpellID")
end)
Check("auras", "AuraUtil.ForEachAura", function() return Exists("AuraUtil.ForEachAura") end)
Check("auras", "UnitAura / UnitBuff / UnitDebuff", function()
    return Exists("UnitAura") .. " / " .. Exists("UnitBuff") .. " / " .. Exists("UnitDebuff")
end)
Check("auras", "target auras", function()
    local fn = Fn("C_UnitAuras.GetAuraDataByIndex")
    if type(fn) ~= "function" then return "missing" end
    local okE, exists = pcall(UnitExists, "target")
    if not (okE and exists) then return "untested (no target)" end
    local ok, data = pcall(fn, "target", 1, "HARMFUL")
    if not ok then return "error: " .. Describe(data) end
    if data == nil then
        ok, data = pcall(fn, "target", 1, "HELPFUL")
        if data == nil then return "yes, but the target has no auras" end
    end
    return "yes: " .. Fields(data, { "name", "spellId", "applications", "duration",
        "expirationTime", "sourceUnit" })
end)

-- Units
Check("units", "UnitHealth / UnitHealthMax (player)", function()
    return Returns("UnitHealth", "player") .. " | " .. Returns("UnitHealthMax", "player")
end)
Check("units", "UnitPower / UnitPowerMax (player)", function()
    return Returns("UnitPower", "player") .. " | " .. Returns("UnitPowerMax", "player")
end)
Check("units", "UnitHealthPercent", function() return Exists("UnitHealthPercent") end)
Check("units", "UnitHealth (target)", function()
    local okE, exists = pcall(UnitExists, "target")
    if not (okE and exists) then return "untested (no target)" end
    return Returns("UnitHealth", "target") .. " | " .. Returns("UnitHealthMax", "target")
end)
Check("units", "UnitCastingInfo / UnitChannelInfo (player)", function()
    return Returns("UnitCastingInfo", "player") .. " | " .. Returns("UnitChannelInfo", "player")
end)
Check("units", "UnitDetailedThreatSituation", function()
    return Returns("UnitDetailedThreatSituation", "player", "target")
end)
Check("units", "UnitXP / UnitXPMax / GetXPExhaustion", function()
    return Returns("UnitXP", "player") .. " | " .. Returns("UnitXPMax", "player") .. " | "
        .. Returns("GetXPExhaustion")
end)
Check("units", "GetMoney", function() return Returns("GetMoney") end)
Check("units", "GetShapeshiftForm / GetShapeshiftFormInfo(1)", function()
    return Returns("GetShapeshiftForm") .. " | " .. Returns("GetShapeshiftFormInfo", 1)
end)
Check("units", "UnitInRange / CheckInteractDistance", function()
    return Exists("UnitInRange") .. " / " .. Exists("CheckInteractDistance")
end)
Check("units", "UnitGroupRolesAssigned / GetNumGroupMembers", function()
    return Exists("UnitGroupRolesAssigned") .. " / " .. Exists("GetNumGroupMembers")
end)
Check("units", "C_NamePlate.GetNamePlateForUnit", function()
    return Exists("C_NamePlate.GetNamePlateForUnit")
end)

-- Spells
Check("spells", "C_Spell.GetSpellCooldown (Auto Attack)", function()
    local fn = Fn("C_Spell.GetSpellCooldown")
    if type(fn) ~= "function" then return Returns("GetSpellCooldown", 6603) end
    local ok, data = pcall(fn, 6603)
    if not ok then return "error: " .. Describe(data) end
    return "yes: " .. Fields(data, { "startTime", "duration", "isEnabled", "modRate" })
end)
Check("spells", "GetSpellCharges / C_Spell.GetSpellCharges", function()
    return Exists("GetSpellCharges") .. " / " .. Exists("C_Spell.GetSpellCharges")
end)
Check("spells", "C_Spell.IsSpellUsable / IsUsableSpell", function()
    local modern = Fn("C_Spell.IsSpellUsable")
    if type(modern) == "function" then return Returns("C_Spell.IsSpellUsable", 6603) end
    return Returns("IsUsableSpell", 6603)
end)
Check("spells", "IsSpellInRange / C_Spell.IsSpellInRange", function()
    return Exists("IsSpellInRange") .. " / " .. Exists("C_Spell.IsSpellInRange")
end)
Check("spells", "IsSpellKnown / IsPlayerSpell / C_SpellBook.IsSpellKnown", function()
    return Exists("IsSpellKnown") .. " / " .. Exists("IsPlayerSpell") .. " / "
        .. Exists("C_SpellBook.IsSpellKnown")
end)
Check("spells", "GetTotemInfo(1)", function() return Returns("GetTotemInfo", 1) end)
Check("spells", "GetSpecialization (talent specs)", function() return Exists("GetSpecialization") end)
Check("spells", "GetTalentInfo", function() return Exists("GetTalentInfo") end)

-- Items
Check("items", "C_Item.GetItemCooldown / GetItemCooldown (Hearthstone)", function()
    local modern = Fn("C_Item.GetItemCooldown")
    if type(modern) == "function" then return Returns("C_Item.GetItemCooldown", 6948) end
    return Returns("GetItemCooldown", 6948)
end)
Check("items", "GetInventoryItemCooldown (trinket 13)", function()
    return Returns("GetInventoryItemCooldown", "player", 13)
end)
Check("items", "C_Item.GetItemCount / GetItemCount (Hearthstone)", function()
    local modern = Fn("C_Item.GetItemCount")
    if type(modern) == "function" then return Returns("C_Item.GetItemCount", 6948) end
    return Returns("GetItemCount", 6948)
end)
Check("items", "GetWeaponEnchantInfo", function() return Returns("GetWeaponEnchantInfo") end)
Check("items", "GetInventoryItemID (main hand)", function()
    return Returns("GetInventoryItemID", "player", 16)
end)

-- The world
Check("world", "GetInstanceInfo", function() return Returns("GetInstanceInfo") end)
Check("world", "C_Map.GetBestMapForUnit", function() return Returns("C_Map.GetBestMapForUnit", "player") end)
Check("world", "GetRealZoneText / GetMinimapZoneText", function()
    return Returns("GetRealZoneText") .. " | " .. Returns("GetMinimapZoneText")
end)
Check("world", "CombatLogGetCurrentEventInfo", function()
    return Exists("CombatLogGetCurrentEventInfo")
end)
Check("world", "SendChatMessage", function()
    -- Present is all that can be said without sending something.
    return Exists("SendChatMessage") .. " (whether it is protected here is untested)"
end)
Check("world", "C_EncodingUtil", function()
    local util = Fn("C_EncodingUtil")
    if type(util) ~= "table" then return "missing" end
    local parts = {}
    for _, name in ipairs({ "CompressString", "DecompressString", "EncodeBase64",
                            "DecodeBase64", "SerializeCBOR", "DeserializeCBOR" }) do
        if type(util[name]) == "function" then parts[#parts + 1] = name end
    end
    return "yes: " .. table.concat(parts, ", ")
end)
Check("world", "C_TooltipInfo", function()
    return type(Fn("C_TooltipInfo")) == "table" and "yes" or "missing"
end)

-- Drawing
Check("drawing", "ActionButton_ShowOverlayGlow", function()
    return Exists("ActionButton_ShowOverlayGlow")
end)
Check("drawing", "LibCustomGlow (from another addon)", function()
    local stub = Fn("LibStub")
    if type(stub) ~= "table" and type(stub) ~= "function" then return "no LibStub" end
    local ok, lib = pcall(function() return LibStub("LibCustomGlow-1.0", true) end)
    return (ok and lib) and "yes" or "not loaded"
end)
Check("drawing", "PlayerModel frames", function()
    local ok, model = pcall(CreateFrame, "PlayerModel")
    if not ok or not model then return "error: " .. Describe(model) end
    model:Hide()
    return "yes"
end)
Check("drawing", "animation types", function()
    local frame = CreateFrame("Frame")
    local ok, group = pcall(frame.CreateAnimationGroup, frame)
    if not ok or not group then return "no animation groups" end
    local have = {}
    for _, kind in ipairs({ "Alpha", "Scale", "Translation", "Rotation", "Path" }) do
        if pcall(group.CreateAnimation, group, kind) then have[#have + 1] = kind end
    end
    return "yes: " .. table.concat(have, ", ")
end)
-- What phase 7's shapes lean on: a round progress texture colors the swipe,
-- a model loads by unit or ID.
Check("drawing", "Cooldown swipe texture and color", function()
    local okC, cd = pcall(CreateFrame, "Cooldown", nil, CreateFrame("Frame"), "CooldownFrameTemplate")
    if not okC or not cd then return "no cooldown frame" end
    local have = {}
    for _, name in ipairs({ "SetSwipeTexture", "SetSwipeColor", "SetReverse", "SetHideCountdownNumbers" }) do
        have[#have + 1] = (type(cd[name]) == "function" and "" or "no ") .. name
    end
    return table.concat(have, ", ")
end)
Check("drawing", "PlayerModel methods", function()
    local ok, model = pcall(CreateFrame, "PlayerModel")
    if not ok or not model then return "no PlayerModel" end
    model:Hide()
    local have = {}
    for _, name in ipairs({ "SetUnit", "SetDisplayInfo", "SetModel", "SetFacing", "SetPortraitZoom" }) do
        have[#have + 1] = (type(model[name]) == "function" and "" or "no ") .. name
    end
    return table.concat(have, ", ")
end)
Check("drawing", "the texture picker's files", function()
    local texture = CreateFrame("Frame"):CreateTexture()
    local out = {}
    for _, path in ipairs({ "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "Interface\\Cooldown\\ping4",
                            "Interface\\Cooldown\\star4", "Interface\\Cooldown\\starburst",
                            "Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64",
                            "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" }) do
        local ok, loaded = pcall(texture.SetTexture, texture, path)
        out[#out + 1] = path:match("[^\\]+$") .. "=" .. ((ok and loaded ~= false) and "yes" or "no")
    end
    return table.concat(out, ", ")
end)
Check("drawing", "Texture:SetRotation / SetTexCoord", function()
    local texture = CreateFrame("Frame"):CreateTexture()
    return (type(texture.SetRotation) == "function" and "SetRotation" or "no SetRotation")
        .. " / " .. (type(texture.SetTexCoord) == "function" and "SetTexCoord" or "no SetTexCoord")
end)

-- Secrets: in combat this client hides values from addons. What still gets
-- through, and whether a secret can at least be handed to a widget to draw.
Check("secrets", "in combat now", function()
    local ok, locked = pcall(InCombatLockdown)
    return (ok and locked) and "yes" or "no"
end)
Check("secrets", "aura data carried by UNIT_AURA (player)", function()
    return auraFromEvent and ("yes: " .. auraFromEvent)
        or "untested (no buff gained since login -- gain one, then probe)"
end)
Check("secrets", "C_UnitAuras.GetAuraDataByAuraInstanceID (player)", function()
    if not lastInstanceID then return "untested (no aura instance seen yet)" end
    local fn = Fn("C_UnitAuras.GetAuraDataByAuraInstanceID")
    if type(fn) ~= "function" then return "missing" end
    local ok, data = pcall(fn, "player", lastInstanceID)
    if not ok then return "error: " .. Describe(data) end
    return "yes: " .. Fields(data, { "name", "spellId", "applications", "duration", "expirationTime" })
end)
Check("secrets", "AuraUtil.ForEachAura (player, packed)", function()
    local fn = Fn("AuraUtil.ForEachAura")
    if type(fn) ~= "function" then return "missing" end
    local first
    local ok, err = pcall(fn, "player", "HELPFUL", nil, function(data)
        first = first or data
        return true
    end, true)
    if not ok then return "error: " .. Describe(err) end
    if not first then return "yes, but nothing to read" end
    return "yes: " .. Fields(first, { "name", "spellId", "applications", "duration", "expirationTime" })
end)
Check("secrets", "C_UnitAuras.GetAuraSlots / GetAuraDataBySlot", function()
    local slots, bySlot = Fn("C_UnitAuras.GetAuraSlots"), Fn("C_UnitAuras.GetAuraDataBySlot")
    if type(slots) ~= "function" then return "missing" end
    local results = { pcall(slots, "player", "HELPFUL") }
    if not results[1] then return "error: " .. Describe(results[2]) end
    local slot = results[3]
    if not slot or type(bySlot) ~= "function" then return "yes (no slot to read)" end
    local ok, data = pcall(bySlot, "player", slot)
    if not ok then return "error: " .. Describe(data) end
    return "yes: " .. Fields(data, { "name", "spellId", "applications", "duration", "expirationTime" })
end)
Check("secrets", "C_UnitAuras.GetAuraDuration", function() return Exists("C_UnitAuras.GetAuraDuration") end)
Check("secrets", "C_Spell.GetSpellCooldownDuration", function() return Exists("C_Spell.GetSpellCooldownDuration") end)
Check("secrets", "UnitHealthPercent (player)", function() return Returns("UnitHealthPercent", "player") end)
Check("secrets", "C_CurveUtil / C_DurationUtil", function()
    return (type(Fn("C_CurveUtil")) == "table" and "C_CurveUtil" or "no C_CurveUtil") .. " / "
        .. (type(Fn("C_DurationUtil")) == "table" and "C_DurationUtil" or "no C_DurationUtil")
end)
Check("secrets", "a status bar takes a secret health value", function()
    local bar = CreateFrame("StatusBar")
    bar:Hide()
    local okM, max = pcall(UnitHealthMax, "player")
    pcall(bar.SetMinMaxValues, bar, 0, okM and max or 1)
    local okH, health = pcall(UnitHealth, "player")
    local ok, err = pcall(bar.SetValue, bar, okH and health or 0)
    return ok and "yes" or ("no: " .. Describe(err))
end)
Check("secrets", "a font string takes a secret number", function()
    local text = CreateFrame("Frame"):CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local okH, health = pcall(UnitHealth, "player")
    local ok, err = pcall(text.SetText, text, okH and health or 0)
    local okF = pcall(text.SetFormattedText, text, "%d", okH and health or 0)
    return (ok and "SetText yes" or ("SetText no: " .. Describe(err)))
        .. " / " .. (okF and "SetFormattedText yes" or "SetFormattedText no")
end)
Check("secrets", "a cooldown swipe takes a secret spell cooldown", function()
    local fn = Fn("C_Spell.GetSpellCooldown")
    if type(fn) ~= "function" then return "missing" end
    local okI, info = pcall(fn, 6603)
    if not okI or type(info) ~= "table" then return "no cooldown to read" end
    local okC, cd = pcall(CreateFrame, "Cooldown", nil, CreateFrame("Frame"), "CooldownFrameTemplate")
    if not okC or not cd then return "no cooldown frame" end
    local ok, err = pcall(cd.SetCooldown, cd, info.startTime, info.duration)
    local fromDuration = type(cd.SetCooldownFromDurationObject) == "function"
    return (ok and "SetCooldown yes" or ("SetCooldown no: " .. Describe(err)))
        .. " / SetCooldownFromDurationObject " .. (fromDuration and "exists" or "missing")
end)

-- The same buff, asked for in combat by the handles that might survive.
local function KnownLabel()
    return known and ((known.name or "?") .. " spell " .. tostring(known.spellId)
        .. " instance " .. tostring(known.instanceID)) or nil
end
Check("combat", "buff remembered from out of combat", function()
    return KnownLabel() and ("yes: " .. KnownLabel())
        or "untested (probe out of combat first, with a buff up)"
end)
Check("combat", "that buff by spell ID (GetPlayerAuraBySpellID)", function()
    if not known then return "untested (no buff remembered)" end
    local fn = Fn("C_UnitAuras.GetPlayerAuraBySpellID")
    if type(fn) ~= "function" then return "missing" end
    local ok, data = pcall(fn, known.spellId)
    if not ok then return "error: " .. Describe(data) end
    if data == nil then return "nil (not found, or hidden)" end
    return "yes: " .. Fields(data, { "name", "spellId", "applications", "duration",
        "expirationTime", "auraInstanceID" })
end)
Check("combat", "that buff by instance ID (GetAuraDataByAuraInstanceID)", function()
    if not known then return "untested (no buff remembered)" end
    local fn = Fn("C_UnitAuras.GetAuraDataByAuraInstanceID")
    if type(fn) ~= "function" then return "missing" end
    local ok, data = pcall(fn, "player", known.instanceID)
    if not ok then return "error: " .. Describe(data) end
    if data == nil then return "nil (gone, or hidden)" end
    return "yes: " .. Fields(data, { "name", "spellId", "applications", "duration", "expirationTime" })
end)
Check("combat", "that buff's timer drawn from its duration object", function()
    if not known then return "untested (no buff remembered)" end
    local fn = Fn("C_UnitAuras.GetAuraDuration")
    if type(fn) ~= "function" then return "missing" end
    local ok, duration = pcall(fn, "player", known.instanceID)
    if not ok then return "error: " .. Describe(duration) end
    if duration == nil then return "nil (no duration object)" end
    local okC, cd = pcall(CreateFrame, "Cooldown", nil, CreateFrame("Frame"), "CooldownFrameTemplate")
    if not okC or not cd then return "got " .. Describe(duration) .. ", no cooldown frame to try" end
    local okS, err = pcall(cd.SetCooldownFromDurationObject, cd, duration)
    return "got " .. Describe(duration) .. "; swipe " .. (okS and "took it" or ("refused: " .. Describe(err)))
end)
Check("combat", "a spell cooldown drawn from its duration object (Auto Attack)", function()
    local fn = Fn("C_Spell.GetSpellCooldownDuration")
    if type(fn) ~= "function" then return "missing" end
    local ok, duration = pcall(fn, 6603)
    if not ok then return "error: " .. Describe(duration) end
    if duration == nil then return "nil (no duration object)" end
    local okC, cd = pcall(CreateFrame, "Cooldown", nil, CreateFrame("Frame"), "CooldownFrameTemplate")
    if not okC or not cd then return "got " .. Describe(duration) .. ", no cooldown frame to try" end
    local okS, err = pcall(cd.SetCooldownFromDurationObject, cd, duration)
    return "got " .. Describe(duration) .. "; swipe " .. (okS and "took it" or ("refused: " .. Describe(err)))
end)
Check("combat", "a status bar timer from a duration object", function()
    local bar = CreateFrame("StatusBar")
    bar:Hide()
    local have = {}
    for _, name in ipairs({ "SetTimerDuration", "SetValueFromDuration", "SetDuration" }) do
        if type(bar[name]) == "function" then have[#have + 1] = name end
    end
    return #have > 0 and ("yes: " .. table.concat(have, ", ")) or "no timer methods on status bars"
end)
Check("combat", "your own cast events in combat", function()
    local entry = Probe.seen and Probe.seen.UNIT_SPELLCAST_SUCCEEDED
    return entry and ("seen: " .. (entry.sample or "")) or "not seen (cast something, then probe)"
end)

-- Stacks: every buff and debuff on you with more than zero of anything that
-- could be a stack count, read every way this client offers -- the per-index
-- read ChairAuras uses, C_UnitAuras.GetUnitAuras (what Plater uses), and by
-- instance ID -- so the one that works in combat can be seen.
local STACK_NAMES = { "applications", "stackCount", "count", "charges", "stacks" }
local function StackFields(data)
    if type(data) ~= "table" then return Describe(data) end
    local parts = { tostring(ns.SafeText(data.name) or Describe(data.name)) }
    for _, field in ipairs(STACK_NAMES) do
        if data[field] ~= nil then parts[#parts + 1] = field .. "=" .. Describe(data[field]) end
    end
    parts[#parts + 1] = "spellId=" .. Describe(data.spellId)
    return table.concat(parts, " ")
end

Check("stacks", "C_UnitAuras.GetUnitAuras (player, HELPFUL)", function()
    local fn = Fn("C_UnitAuras.GetUnitAuras")
    if type(fn) ~= "function" then return "missing" end
    local ok, list = pcall(fn, "player", "HELPFUL")
    if not ok then return "error: " .. Describe(list) end
    if type(list) ~= "table" then return "no list: " .. Describe(list) end
    local lines = {}
    for i, data in ipairs(list) do
        if i > 8 then break end
        lines[#lines + 1] = StackFields(data)
    end
    return "yes, " .. #list .. " aura(s): " .. table.concat(lines, " | ")
end)
Check("stacks", "C_UnitAuras.GetUnitAuras (player, HARMFUL)", function()
    local fn = Fn("C_UnitAuras.GetUnitAuras")
    if type(fn) ~= "function" then return "missing" end
    local ok, list = pcall(fn, "player", "HARMFUL")
    if not ok then return "error: " .. Describe(list) end
    if type(list) ~= "table" then return "no list: " .. Describe(list) end
    local lines = {}
    for i, data in ipairs(list) do
        if i > 8 then break end
        lines[#lines + 1] = StackFields(data)
    end
    return "yes, " .. #list .. " aura(s): " .. table.concat(lines, " | ")
end)
Check("stacks", "C_UnitAuras.GetUnitAuras (target, HARMFUL)", function()
    local fn = Fn("C_UnitAuras.GetUnitAuras")
    if type(fn) ~= "function" then return "missing" end
    local okE, exists = pcall(UnitExists, "target")
    if not (okE and exists) then return "untested (no target)" end
    local ok, list = pcall(fn, "target", "HARMFUL")
    if not ok then return "error: " .. Describe(list) end
    if type(list) ~= "table" then return "no list: " .. Describe(list) end
    local lines = {}
    for i, data in ipairs(list) do
        if i > 8 then break end
        lines[#lines + 1] = StackFields(data)
    end
    return "yes, " .. #list .. " aura(s): " .. table.concat(lines, " | ")
end)
Check("stacks", "per-index read (what ChairAuras uses), every buff", function()
    local fn = Fn("C_UnitAuras.GetAuraDataByIndex")
    if type(fn) ~= "function" then return "missing" end
    local lines = {}
    for i = 1, 40 do
        local ok, data = pcall(fn, "player", i, "HELPFUL")
        if not ok then return "error: " .. Describe(data) end
        if not data then break end
        lines[#lines + 1] = StackFields(data)
    end
    if #lines == 0 then return "yes, but no buffs" end
    return "yes: " .. table.concat(lines, " | ")
end)
Check("stacks", "C_StringUtil.TruncateWhenZero (shows a secret stack count)", function()
    return Exists("C_StringUtil.TruncateWhenZero")
end)
Check("stacks", "C_UnitAuras.GetAuraApplicationDisplayCount", function()
    return Exists("C_UnitAuras.GetAuraApplicationDisplayCount")
end)

-------------------------------------------------------------------------------
-- The listener: which events fire here, and what they carry
-------------------------------------------------------------------------------

local WATCH = {
    "UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_HEALTH",
    "UNIT_POWER_UPDATE", "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE",
    "ACTIONBAR_UPDATE_USABLE", "PLAYER_TOTEM_UPDATE", "UNIT_THREAT_LIST_UPDATE",
    "ENCOUNTER_START", "READY_CHECK", "CHAT_MSG_SAY", "CHAT_MSG_PARTY",
    "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER", "UNIT_INVENTORY_CHANGED",
    "BAG_UPDATE_COOLDOWN", "UPDATE_SHAPESHIFT_FORM", "PLAYER_TARGET_CHANGED",
}

local seen = {}      -- event -> { count, sample }
local refused = {}   -- events this client will not register
Probe.seen = seen
-- From the player's own UNIT_AURA: an aura instance ID to look up later, and
-- how readable the aura data the event itself carries is.
local lastInstanceID, auraFromEvent

-- Not registered at login. Registering some events is a protected action
-- here, and the client answers it with an ADDON_ACTION_FORBIDDEN error --
-- three of them, every login, from the first version of this. So it only
-- starts listening when asked, and each registration is checked afterwards:
-- a refused one is named in the report rather than left as "not seen".
-- COMBAT_LOG_EVENT_UNFILTERED is left out altogether: the first probe found
-- the combat log's API missing, and registering its event is refused.
local listener = CreateFrame("Frame")
local listening = false

local function StartListening()
    if listening then return end
    listening = true
    for _, event in ipairs(WATCH) do
        local ok = pcall(listener.RegisterEvent, listener, event)
        local okR, registered = pcall(listener.IsEventRegistered, listener, event)
        if not ok or (okR and registered == false) then refused[event] = true end
    end
end
Probe.StartListening = StartListening

listener:SetScript("OnEvent", function(_, event, ...)
    local entry = seen[event]
    if not entry then
        entry = { count = 0 }
        seen[event] = entry
    end
    entry.count = entry.count + 1
    -- In combat the update info's own lists are secret tables: reading into
    -- one throws, so this looks through a pcall and keeps what it can.
    if event == "UNIT_AURA" and select(1, ...) == "player" then pcall(function(...)
        local info = select(2, ...)
        if type(info) == "table" and not ns.IsSecret(info) then
            local added = type(info.addedAuras) == "table" and info.addedAuras[1]
            if type(added) == "table" then
                auraFromEvent = Fields(added, { "name", "spellId", "applications",
                    "duration", "expirationTime", "auraInstanceID" })
                if not ns.IsSecret(added.auraInstanceID) then lastInstanceID = added.auraInstanceID end
            end
            local updated = type(info.updatedAuraInstanceIDs) == "table" and info.updatedAuraInstanceIDs[1]
            if updated and not ns.IsSecret(updated) then lastInstanceID = updated end
        end
    end, ...) end
    if entry.sample then return end
    -- The first one, argument by argument. UNIT_AURA's second argument is
    -- the update info a modern client sends; its shape is the point.
    local parts = {}
    for i = 1, math.min(select("#", ...), 6) do
        local value = select(i, ...)
        local d = Describe(value)
        if d == "table" and event == "UNIT_AURA" then
            d = "table{" .. Fields(value, { "isFullUpdate", "addedAuras",
                "updatedAuraInstanceIDs", "removedAuraInstanceIDs" }) .. "}"
        end
        parts[#parts + 1] = d
    end
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        parts[#parts + 1] = "info=" .. Returns("CombatLogGetCurrentEventInfo")
    end
    entry.sample = table.concat(parts, ", ")
end)

-------------------------------------------------------------------------------
-- Running it
-------------------------------------------------------------------------------

local function Colour(result)
    if result:find("^yes") then return "|cff55ff55" .. result .. "|r" end
    if result:find("^secret") or result:find("SECRET") then return "|cffffd100" .. result .. "|r" end
    if result:find("^untested") then return "|cff9d9d9d" .. result .. "|r" end
    return "|cffff5555" .. result .. "|r"
end

function Probe:Run()
    local saved = { results = {}, events = {} }
    local okB, version, build = pcall(GetBuildInfo)
    saved.client = okB and (tostring(version) .. " " .. tostring(build)) or "?"
    local okD, when = pcall(date, "%Y-%m-%d %H:%M")
    saved.when = okD and when or "?"
    -- Stored before anything is asked, and filled in as it goes: a problem
    -- part way through still leaves what came before it in the file.
    if type(ChairAurasDB) == "table" then
        local okL, locked = pcall(InCombatLockdown)
        local key = (okL and locked) and "combat" or "calm"
        if type(ChairAurasDB.probe) ~= "table" or type(ChairAurasDB.probe.runs) ~= "table" then
            ChairAurasDB.probe = { runs = {} }
        end
        ChairAurasDB.probe.runs[key] = saved
        saved.state = key
    end

    ns.Print("what this client allows (" .. saved.client .. "):")
    local group
    for _, check in ipairs(CHECKS) do
        local ok, result = pcall(check[3])
        result = ok and tostring(result) or ("error: " .. Describe(result))
        if check[1] ~= group then
            group = check[1]
            print("  |cff9d7cff" .. group .. "|r")
        end
        print("    " .. check[2] .. ": " .. Colour(result))
        saved.results[check[1] .. ": " .. check[2]] = result
    end

    local firstListen = not listening
    StartListening()
    print("  |cff9d7cffevents seen since the first probe|r"
        .. (firstListen and " |cff9d9d9d(listening from now -- probe again later for these)|r" or ""))
    for _, event in ipairs(WATCH) do
        local entry = seen[event]
        local line
        if refused[event] then
            line = "|cffff5555not registrable here|r"
        elseif entry then
            line = string.format("|cff55ff55%d|r  first: %s", entry.count, entry.sample or "")
        else
            line = "|cff9d9d9dnot seen yet|r"
        end
        print("    " .. event .. ": " .. line)
        saved.events[event] = refused[event] and "refused"
            or (entry and (entry.count .. " | " .. (entry.sample or ""))) or "not seen"
    end

    ns.Print("kept in the saved file too (" .. tostring(saved.state) .. " run):"
        .. " |cffffd100/reload|r and it is in ChairAurasDB.probe. Probe once in combat"
        .. " and once out of it -- this client hides more in combat.")
    ns.Print("for the fullest answer: have a buff up, a hostile target with a debuff,"
        .. " and cast or fight a little before probing.")
    return saved
end
