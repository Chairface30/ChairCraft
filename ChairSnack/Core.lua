-- SnapSnack Core.lua
-- Shared addon table, API compatibility layer, and cross-module state.
-- Loaded first; every other file expects what this file defines.

local suiteName, Chaircraft = ...
-- Merged into Chaircraft. addonName stays "SnapSnack" so every frame
-- name, keybinding and printed prefix below is byte-identical to the
-- standalone addon; only the shared table is new.
local addonName = "SnapSnack"
local addon = Chaircraft.ChairSnack
addon.name = addonName
-- What the player sees. addonName stays "SnapSnack" because every frame name
-- and keybinding is built from it; this is the half that is allowed to change.
addon.displayName = "ChairSnack"

-------------------------------
-- API Compatibility Layer
-------------------------------
-- Three generations of client have to be kept happy at once:
--
--   * Vanilla/TBC Classic, where everything below is a plain global.
--   * The Anniversary client, which added C_Container but kept the globals.
--   * Forever, which runs the retail engine -- the item, spell, spellbook and
--     aura globals are gone entirely and only the C_ namespaces answer.
--
-- So nothing here assumes: each entry takes the namespaced function when the
-- client has one and falls back to the global otherwise. Where the two
-- disagree about their return shape -- spells, the spellbook and auras all
-- returned a tuple and now return a table -- the wrapper normalises to the
-- old tuple, because that is what the call sites in this addon read.

local C_Item = _G.C_Item
local C_Container = _G.C_Container
local C_Spell = _G.C_Spell
local C_SpellBook = _G.C_SpellBook
local C_UnitAuras = _G.C_UnitAuras
local C_PvP = _G.C_PvP

-- Which side of each shim answered, for /chair snack api. Porting to a new client is
-- mostly a matter of finding out what is actually there, and guessing from the
-- outside is slower than asking.
local apiSource = {}
addon.apiSource = apiSource

-- Namespaced function if the client has it, global of that name otherwise.
local function Pick(namespace, namespaceName, key, globalName)
    local fn = namespace and namespace[key]
    if type(fn) == "function" then
        apiSource[key] = namespaceName
        return fn
    end
    fn = _G[globalName or key]
    apiSource[key] = (type(fn) == "function") and "global" or "MISSING"
    return fn
end

-- Items
addon.GetItemInfo = Pick(C_Item, "C_Item", "GetItemInfo")
addon.GetItemInfoInstant = Pick(C_Item, "C_Item", "GetItemInfoInstant")
addon.GetItemCount = Pick(C_Item, "C_Item", "GetItemCount")
addon.GetItemSpell = Pick(C_Item, "C_Item", "GetItemSpell")
addon.IsUsableItem = Pick(C_Item, "C_Item", "IsUsableItem")
-- Never lived on C_Container despite the name pairing; it is an item cooldown.
addon.GetItemCooldown = Pick(C_Item, "C_Item", "GetItemCooldown")
addon.PickupItem = Pick(C_Item, "C_Item", "PickupItem")

-- Containers
addon.GetContainerNumSlots = Pick(C_Container, "C_Container", "GetContainerNumSlots")
addon.GetContainerItemID = Pick(C_Container, "C_Container", "GetContainerItemID")

addon.GetContainerItemInfo = (C_Container and C_Container.GetContainerItemInfo) or function(bag, slot)
    local icon, itemCount, locked, quality, readable, lootable, itemLink, isFiltered, noValue, itemID = _G.GetContainerItemInfo(bag, slot)
    if itemID then
        return {
            iconFileID = icon,
            stackCount = itemCount,
            isLocked = locked,
            quality = quality,
            isReadable = readable,
            hasLoot = lootable,
            hyperlink = itemLink,
            isFiltered = isFiltered,
            hasNoValue = noValue,
            itemID = itemID,
        }
    end
    return nil
end

apiSource.GetContainerItemInfo = (C_Container and C_Container.GetContainerItemInfo)
    and "C_Container" or "global"

-- Spells
-- Old: name, rank, icon, castTime, minRange, maxRange, spellID
-- New: a table, and no rank at all -- ranks left the game with the retail
-- engine, so the second return is nil rather than faked.
local rawGetSpellInfo = Pick(C_Spell, "C_Spell", "GetSpellInfo")

function addon.GetSpellInfo(spell)
    if not spell or not rawGetSpellInfo then return nil end
    local a, b, c, d, e, f, g = rawGetSpellInfo(spell)
    if type(a) == "table" then
        return a.name, nil, a.iconID, a.castTime, a.minRange, a.maxRange, a.spellID
    end
    return a, b, c, d, e, f, g
end

addon.GetSpellTexture = Pick(C_Spell, "C_Spell", "GetSpellTexture")

-- Normalised to the old four-value shape, which is what a Cooldown frame wants.
-- This generation returns a table instead, and every field in it comes back
-- plain rather than secret -- confirmed, because a secret reaching SetCooldown
-- would take the whole draw with it.
local rawGetSpellCooldown = Pick(C_Spell, "C_Spell", "GetSpellCooldown")

function addon.GetSpellCooldown(spell)
    if not spell or not rawGetSpellCooldown then return nil end

    local a, b, c = rawGetSpellCooldown(spell)
    if type(a) == "table" then
        return a.startTime, a.duration, a.isEnabled
    end
    return a, b, c
end

-- Spellbook
-- The bank argument changed from the string BOOKTYPE_SPELL to an enum value,
-- so callers pass addon.SPELL_BOOK and the wrappers translate it to whichever
-- form the resolved function actually wants.
local modernSpellBook = C_SpellBook and type(C_SpellBook.GetSpellBookItemName) == "function"
local PLAYER_BANK = (_G.Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
local LEGACY_BANK = _G.BOOKTYPE_SPELL or "spell"

addon.SPELL_BOOK = modernSpellBook and PLAYER_BANK or LEGACY_BANK
apiSource.SpellBook = modernSpellBook and "C_SpellBook"
    or (_G.GetSpellBookItemName and "global" or "MISSING")

local function ResolveBank(bank)
    if modernSpellBook then
        return type(bank) == "number" and bank or PLAYER_BANK
    end
    return type(bank) == "string" and bank or LEGACY_BANK
end

-- Enum.SpellBookItemType back to the strings the old call returned. Only the
-- kinds this addon tests for need a name; anything else is reported as its
-- number, which matches nothing and so is skipped.
local SPELL_BOOK_ITEM_TYPES = {
    [1] = "SPELL",
    [2] = "FUTURESPELL",
    [3] = "PETACTION",
    [4] = "FLYOUT",
}

local rawGetSpellBookItemName = modernSpellBook and C_SpellBook.GetSpellBookItemName or _G.GetSpellBookItemName
local rawGetSpellBookItemInfo = modernSpellBook and C_SpellBook.GetSpellBookItemInfo or _G.GetSpellBookItemInfo

function addon.GetSpellBookItemName(index, bank)
    if not rawGetSpellBookItemName then return nil end
    return rawGetSpellBookItemName(index, ResolveBank(bank))
end

-- Old: itemType string, then the spell ID. Only the string is read here.
function addon.GetSpellBookItemInfo(index, bank)
    if not rawGetSpellBookItemInfo then return nil end
    local info = rawGetSpellBookItemInfo(index, ResolveBank(bank))
    if type(info) == "table" then
        return SPELL_BOOK_ITEM_TYPES[info.itemType] or info.itemType, info.spellID
    end
    return info
end

-- Auras
-- Old: name, icon, count, debuffType, duration, expirationTime, source,
--      isStealable, nameplateShowPersonal, spellId
local rawGetBuffData = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex
apiSource.BuffData = rawGetBuffData and "C_UnitAuras"
    or (_G.UnitBuff and "global" or "MISSING")

-- This client can decide an aura is secret, and then it refuses to hand it to
-- tainted code -- by throwing, not by answering nil:
--
--   GetBuffDataByIndex(): Auras cannot be accessed when secret while tainted
--   by 'SnapSnack'
--
-- Every call this addon makes is tainted by this addon, so there is nothing to
-- fix at the call site: the read simply has to be allowed to fail. A refusal
-- and an empty slot are different answers, and the caller needs to tell them
-- apart -- an empty slot ends a scan, a refusal invalidates it -- so the
-- refusal is the second return rather than a nil that looks like the end of
-- the list.
function addon.BuffData(unit, index)
    if rawGetBuffData then
        local ok, aura = pcall(rawGetBuffData, unit, index)
        if not ok then return nil, true end
        return aura
    end
    if _G.UnitBuff then
        local ok, name, icon, applications, dispelName, duration,
              expirationTime, sourceUnit, isStealable, nameplateShowPersonal,
              spellId = pcall(_G.UnitBuff, unit, index)
        if not ok then return nil, true end
        if not name then return nil end
        return {
            name = name, icon = icon, applications = applications,
            dispelName = dispelName, duration = duration,
            expirationTime = expirationTime, sourceUnit = sourceUnit,
            isStealable = isStealable,
            nameplateShowPersonal = nameplateShowPersonal, spellId = spellId,
        }
    end
    return nil
end

-- Zone
addon.GetZonePVPInfo = Pick(C_PvP, "C_PvP", "GetZonePVPInfo")

-------------------------------
-- Shared State
-------------------------------
-- Tables are shared by reference; each module grabs a local alias. Scalars have
-- to live inside a table so writes from one file are visible in another.

addon.frames = {}
addon.itemButtons = {}
addon.knownConsumables = {}

addon.state = {
    inCity = false,
    bindingMode = false,
    pendingBindButton = nil,
    needsUpdate = false,
}

-------------------------------
-- Utilities
-------------------------------

function addon:Print(msg)
    print("|cff00ff00" .. (addon.displayName or addonName) .. "|r: " .. msg)
end

-- Class checks live here rather than beside the bars that read them most.
-- Whether a bar exists at all can depend on class -- the ammo bar is not drawn
-- for anyone but a hunter -- so the database and the layout ask this too, and
-- both of those load before the bars do.
function addon:IsHunter()
    local _, class = UnitClass("player")
    return class == "HUNTER"
end

function addon:IsRogue()
    local _, class = UnitClass("player")
    return class == "ROGUE"
end

-- Offset of a named anchor point from the centre of a width x height rectangle.
-- Used by the grid layout to convert between anchor points without moving the
-- frame on screen.
function addon.PointOffsetFromCenter(point, width, height)
    local dx, dy = 0, 0
    if point:find("LEFT") then
        dx = -width / 2
    elseif point:find("RIGHT") then
        dx = width / 2
    end
    if point:find("TOP") then
        dy = height / 2
    elseif point:find("BOTTOM") then
        dy = -height / 2
    end
    return dx, dy
end

-- Seconds as mm:ss, or as whole minutes once past an hour.
function addon.FormatDuration(seconds)
    if not seconds or seconds <= 0 then return "" end
    if seconds >= 3600 then
        return string.format("%dh", math.floor(seconds / 3600))
    end
    if seconds >= 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
    end
    return string.format("%ds", math.floor(seconds))
end

function addon.DeepCopy(src)
    if type(src) ~= "table" then return src end
    local dst = {}
    for k, v in pairs(src) do
        dst[k] = addon.DeepCopy(v)
    end
    return dst
end

-- Fill in any key present in defaults but missing from target, recursively.
function addon.ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            addon.ApplyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

-- Whether to draw our own cooldown seconds on an icon.
--
-- Plenty of people already run a cooldown-count addon, and two sets of numbers
-- on one icon is worse than none, so the default defers to whatever is already
-- doing the job. "always" and "never" override the detection.
local COOLDOWN_COUNT_ADDONS = { "OmniCC", "tullaCC", "CooldownCount", "ElvUI" }

local function AddonLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(name)
    end
    if IsAddOnLoaded then return IsAddOnLoaded(name) end
    return false
end

function addon.ShouldDrawCooldownNumbers()
    local mode = (addon:GetGlobal() or {}).cooldownNumbers or "auto"
    if mode == "never" then return false end
    if mode == "always" then return true end

    for _, name in ipairs(COOLDOWN_COUNT_ADDONS) do
        local ok, loaded = pcall(AddonLoaded, name)
        if ok and loaded then return false end
    end
    return true
end

-- Seconds as a cooldown reads best: hours, then minutes, then seconds.
function addon.FormatCooldown(seconds)
    if not seconds or seconds <= 0 then return "" end
    if seconds >= 3600 then return string.format("%dh", math.ceil(seconds / 3600)) end
    if seconds >= 60 then return string.format("%dm", math.ceil(seconds / 60)) end
    -- Whole seconds only: the redraw ticker runs once a second, so tenths
    -- would sit there stale between updates rather than counting.
    return string.format("%d", math.ceil(seconds))
end

_G["SnapSnack"] = addon
