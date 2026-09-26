local suiteName, Chaircraft = ...
-- Merged into Chaircraft. See the note in ChairSnack/Core.lua.
local addonName = "ChairAuras"
local ns = Chaircraft.ChairAuras

-------------------------------------------------------------------------------
-- Auras written down in code
-------------------------------------------------------------------------------
-- This client writes the saved file correctly and then does not read it back.
-- The witness in Database.lua has recorded "never seen" through a full cold
-- start with a perfectly good ChairAuras.lua sitting on disk, so the profile
-- that comes up is the empty one every time the game is restarted.
--
-- Nothing in the addon can fix that. What it can do is stop depending on it:
-- the auras below are the ones that were live, transcribed out of
-- WTF/.../SavedVariables/ChairAuras.lua, and they are seeded into any profile
-- that arrives with no auras in it. A cold start now comes up with the setup
-- instead of with nothing, and the file on disk becomes an optimisation rather
-- than the only copy.
--
-- Precedence is deliberately one-way. If the saved data does turn up -- on a
-- /reload it reliably does -- it has auras in it, the seed does not run, and
-- everything edited in the window survives untouched. The seed is the floor,
-- not an override.
--
-- The cost of that rule: deleting every aura and logging out comes back to
-- this list, because "the user emptied it" and "the client lost it" are the
-- same profile. /chair auras preset is the deliberate way back to this list, and
-- /chair auras preset off switches the seeding off for the session.
--
-- Class locks live on the individual auras, never on the "Buffs" group that
-- holds them. The group was locked to DRUID until 2026-09-22, which meant a
-- hunter saw nothing at all here and reasonably read that as the auras having
-- been lost. A container should not decide who the contents are for.
--
-- Editing this list by hand is the intended way to change what a cold start
-- brings up. The shape is exactly the shape Database.lua describes: ids are
-- verbatim from the live profile (a2 and a3 were deleted before this was
-- taken, and the gap is kept so an id in an old /chair auras list still matches), and
-- anything omitted falls through to the defaults tables.

local PRESET_AURAS = {
    {
        id     = "a1",
        type   = "dynamic",
        name   = "Buffs",
        growth = "HCENTER",
        display = {
            size       = 50,
            icon       = 132091,
            invert     = true,
            hide       = true,
            swipe      = false,
            stacks     = false,
            flash      = false,
            desaturate = false,
        },
        -- No class condition. This one is only a container, and locking it to
        -- a class hid every aura inside it on every other character -- which
        -- is indistinguishable from the auras having been lost. Its children
        -- carry their own class locks where they need them.
        load = {
            alive   = true,
            combat  = false,
            mounted = false,
        },
        actions = { onShow = "12867" },
        pos = { x = -1, y = -170, pivot = "CENTER" },
    },
    {
        id     = "a4",
        parent = "a1",
        name   = "Well Fed",
        trigger = { match = "name", text = "Well Fed" },
        display = {
            size       = 50,
            icon       = 134062,
            invert     = true,
            hide       = true,
            swipe      = false,
            stacks     = false,
            flash      = false,
            desaturate = false,
        },
        -- Deliberately no class: anyone can eat.
        load = {
            alive   = true,
            combat  = false,
            mounted = false,
        },
        actions = { onShow = "12867" },
    },
    {
        id     = "a7",
        parent = "a1",
        name   = "Aspect of the Hawk",
        trigger = { match = "name", text = "Aspect of the Hawk" },
        display = {
            size       = 50,
            -- The spell, not a picked icon: the addon asks the client for the
            -- texture at runtime, so there is no file id here to guess wrong.
            iconSpell  = 13165,
            invert     = true,
            hide       = true,
            swipe      = false,
            stacks     = false,
            flash      = false,
            desaturate = false,
        },
        load = {
            class   = { HUNTER = true },
            alive   = true,
            combat  = false,
            mounted = false,
        },
        actions = { onShow = "12867" },
    },
    {
        id     = "a5",
        parent = "a1",
        name   = "Mark of the Wild",
        trigger = { match = "name", text = "Mark of the Wild" },
        display = {
            size       = 50,
            icon       = 136078,
            invert     = true,
            hide       = true,
            swipe      = false,
            stacks     = false,
            flash      = false,
            desaturate = false,
        },
        load = {
            class   = { DRUID = true },
            alive   = true,
            combat  = false,
            mounted = false,
        },
    },
    {
        id     = "a6",
        parent = "a1",
        name   = "thorns",
        trigger = { match = "name", text = "thorns" },
        display = {
            size       = 50,
            icon       = 136104,
            invert     = true,
            hide       = true,
            swipe      = false,
            stacks     = false,
            flash      = false,
            desaturate = false,
        },
        load = {
            class   = { DRUID = true },
            alive   = true,
            combat  = false,
            mounted = false,
        },
    },
}
ns.PRESET_AURAS = PRESET_AURAS

-- The profile is edited in place and written back to disk, and the compactor
-- strips defaults out of whatever it is handed. Both of those would reach into
-- this file if the tables themselves were handed over, so a copy goes in and
-- the list above stays the list above for the rest of the session.
local function CopyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = CopyValue(inner) end
    return out
end

-- Off. A new profile starts with no auras at all; now that the client reads the
-- saved file back, there is no lost setup to cover for. The list above is still
-- one command away: /chair auras preset load puts it in, and /chair auras
-- preset on seeds it into an empty profile for the rest of the session.
ns.presetEnabled = false

-- Returns how many auras were put in, so the caller can say so rather than
-- leaving the player to wonder where four auras came from.
function ns.ApplyPreset(profile, force)
    profile = profile or ns.profile
    if not profile then return 0 end

    local auras = profile.auras or {}
    if #auras > 0 and not force then return 0 end

    profile.auras = {}
    for _, aura in ipairs(PRESET_AURAS) do
        profile.auras[#profile.auras + 1] = CopyValue(aura)
    end

    return #profile.auras
end

-- Seeding, as opposed to applying: the question of whether this profile should
-- get the preset at all. Asked once, from InitDatabase, before anything has
-- drawn.
function ns.SeedPreset(profile)
    if not ns.presetEnabled then return 0 end
    return ns.ApplyPreset(profile, false)
end
