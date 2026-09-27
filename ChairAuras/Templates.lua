local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Templates
-------------------------------------------------------------------------------
-- WeakAuras' "New from template", built from your own spellbook rather than
-- from a list shipped with the addon: every spell you know, made into the aura
-- people usually want for it. That covers this client's own spells (a list
-- written for Classic Era would not know them), and needs no data kept up to
-- date by hand.
--
--   cooldown   its cooldown: bright when ready, a swipe while it recovers
--   buff       the buff it puts on you, while it lasts
--   missing    the same buff, shown only while it is missing
--   debuff     your debuff on your target, while it lasts
--   usable     lit while you can cast it now
--   cast       for a few seconds after you cast it

local Templates = {}
ns.Templates = Templates

Templates.KINDS = {
    { value = "cooldown", text = "Cooldown" },
    { value = "buff",     text = "Buff on you" },
    { value = "missing",  text = "Buff missing" },
    { value = "debuff",   text = "Your debuff on the target" },
    { value = "usable",   text = "Usable now" },
    { value = "cast",     text = "After you cast it" },
}

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function Passive(spellID)
    local check = (_G.C_Spell and _G.C_Spell.IsSpellPassive) or _G.IsPassiveSpell
    return Try(check, spellID) == true
end

-- Every active spell in the spellbook, by name. Asked both ways this client
-- might answer: the C_SpellBook tables, or the old tab functions.
function Templates:Spells()
    local seen, out = {}, {}
    local function Add(spellID)
        spellID = ns.SafeNumber(spellID)
        if not spellID or seen[spellID] or Passive(spellID) then return end
        local name = ns.Engine:SpellName(spellID)
        if not name or name == "" then return end
        seen[spellID] = true
        out[#out + 1] = { value = spellID, text = name }
    end

    local book = _G.C_SpellBook
    local lines = book and Try(book.GetNumSpellBookSkillLines)
    if lines then
        for line = 1, lines do
            local info = Try(book.GetSpellBookSkillLineInfo, line)
            local offset = info and ns.SafeNumber(info.itemIndexOffset) or 0
            local count = info and ns.SafeNumber(info.numSpellBookItems) or 0
            for index = offset + 1, offset + count do
                local item = Try(book.GetSpellBookItemInfo, index, 0)
                if type(item) == "table" then Add(item.spellID or item.actionID) end
            end
        end
    else
        local tabs = Try(_G.GetNumSpellTabs) or 0
        for tab = 1, tabs do
            local _, _, offset, count = Try(_G.GetSpellTabInfo, tab)
            offset, count = ns.SafeNumber(offset) or 0, ns.SafeNumber(count) or 0
            for index = offset + 1, offset + count do
                local kind, spellID = Try(_G.GetSpellBookItemInfo, index, "spell")
                if kind == "SPELL" or kind == "FUTURESPELL" or kind == nil then Add(spellID) end
            end
        end
    end
    table.sort(out, function(a, b) return a.text < b.text end)
    return out
end

-- The aura a template makes, without an id.
function Templates:Make(kind, spellID)
    local name = ns.Engine:SpellName(spellID) or tostring(spellID)
    local aura = { display = {} }
    local trigger = { spellID = spellID }
    if kind == "cooldown" then
        trigger.type = "cooldown"
        aura.display.hide = false
        aura.name = name .. " cooldown"
    elseif kind == "buff" then
        aura.display.hide = true
        aura.display.iconText = "%t"
        aura.display.iconTextPoint = "BOTTOM"
    elseif kind == "missing" then
        aura.display.invert = true
        aura.display.hide = true
        aura.name = name .. " missing"
    elseif kind == "debuff" then
        trigger.unit, trigger.harmful, trigger.mine = "target", true, true
        aura.display.hide = true
        aura.display.iconText = "%t"
        aura.display.iconTextPoint = "BOTTOM"
        aura.name = name .. " on target"
    elseif kind == "usable" then
        trigger.type = "usable"
        aura.display.hide = false
        aura.name = name .. " usable"
    elseif kind == "cast" then
        trigger.type = "cast"
        trigger.duration = 3
        aura.display.hide = true
        aura.name = name .. " cast"
    else
        return nil
    end
    aura.triggers = { { trigger = trigger } }
    return aura
end
