-- ChairIgnore Filters.lua
-- What chat is hidden, and why.
--
--   listed players   anything from someone on the list, in every kind of
--                    chat. The game hides the ones on its own 50-name list;
--                    this covers everyone past that.
--   chat filters     messages matching a filter, in the kinds of chat picked
--                    on the Options page.
--
-- A filter is a few lines of words. A message matches when it has at least
-- one word from every line:
--
--     line 1   gold, g0ld
--     line 2   www, discount, cheapest
--
-- matches "cheapest GOLD here" but not "anyone selling gold?". Case never
-- matters. With "Ignore spaces and symbols" on, "g.o.l.d" and "g o l d" count
-- as "gold" too.
--
-- Filters are account-wide, like the list. Each counts what it has hidden.

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairIgnore

-------------------------------------------------------------------------------
-- The starter set
-------------------------------------------------------------------------------
-- Written for Chaircraft. All off: switch on the ones you want. `id` is what a
-- later version uses to find one it shipped, so it never changes.

local STARTERS = {
    {
        id = "gold", name = "Gold selling",
        lines = { "gold, g0ld, gold4, 4gold",
                  "www, dotcom, usd, discount, cheapest, instant delivery, fast delivery, promo code, coupon" },
        squeeze = true,
    },
    {
        id = "boost", name = "Boost and carry ads",
        lines = { "wts, selling, sell, cheap",
                  "boost, boosting, carry, carries" },
    },
    {
        id = "recruit", name = "Guild recruiting",
        lines = { "recruit, recruiting, looking for members, lf members, now recruiting",
                  "guild, <" },
    },
    {
        id = "thunderfury", name = "Thunderfury jokes",
        lines = { "thunderfury" },
    },
}

local function Copy(filter)
    local out = { lines = {} }
    for k, v in pairs(filter) do
        if k ~= "lines" then out[k] = v end
    end
    for i, line in ipairs(filter.lines or {}) do out.lines[i] = line end
    return out
end

function ns.InitFilters(db)
    db.filters = type(db.filters) == "table" and db.filters or {}
    db.shipped = type(db.shipped) == "table" and db.shipped or {}
    -- Each starter is added once. One you delete stays deleted.
    for _, starter in ipairs(STARTERS) do
        if not db.shipped[starter.id] then
            db.shipped[starter.id] = true
            local filter = Copy(starter)
            filter.enabled = false
            filter.blocked = 0
            db.filters[#db.filters + 1] = filter
        end
    end
    if ns.CompileFilters then ns.CompileFilters() end
end

function ns.Filters()
    local db = _G.ChairIgnoreDB
    return type(db) == "table" and type(db.filters) == "table" and db.filters or {}
end

-------------------------------------------------------------------------------
-- Matching
-------------------------------------------------------------------------------

local function Squeeze(text)
    return (text:gsub("[%s%p]", ""))
end

-- A line of words, as lowercase words (and squeezed, when asked).
local function Words(line, squeeze)
    local out = {}
    for word in tostring(line or ""):gmatch("[^,]+") do
        word = word:match("^%s*(.-)%s*$"):lower()
        if word ~= "" then
            out[#out + 1] = { plain = word, squeezed = squeeze and Squeeze(word) or nil }
        end
    end
    return out
end

-- Filters turned into word lists, redone whenever one changes.
local compiled = {}
function ns.CompileFilters()
    wipe(compiled)
    for _, filter in ipairs(ns.Filters()) do
        if filter.enabled then
            local lines = {}
            for _, line in ipairs(filter.lines or {}) do
                local words = Words(line, filter.squeeze)
                if #words > 0 then lines[#lines + 1] = words end
            end
            if #lines > 0 then
                compiled[#compiled + 1] = { filter = filter, lines = lines, squeeze = filter.squeeze }
            end
        end
    end
end

local function LineMatches(words, lower, squeezed)
    for _, word in ipairs(words) do
        if lower:find(word.plain, 1, true) then return true end
        -- A word that is all symbols ("<", "$") squeezes to nothing, and is
        -- only ever looked for as it is.
        if squeezed and word.squeezed and word.squeezed ~= "" and squeezed:find(word.squeezed, 1, true) then
            return true
        end
    end
    return false
end

-- The first enabled filter a message matches, or nil. `only` tries just that
-- one filter, switched on or not: the editor's test box.
function ns.MatchFilter(message, only)
    local text = ns.Text(message)
    if not text then return nil end
    local lower = text:lower()
    local squeezedText
    local list = compiled
    if only then
        list = {}
        local lines = {}
        for _, line in ipairs(only.lines or {}) do
            local words = Words(line, only.squeeze)
            if #words > 0 then lines[#lines + 1] = words end
        end
        if #lines > 0 then list[1] = { filter = only, lines = lines, squeeze = only.squeeze } end
    end
    for _, entry in ipairs(list) do
        if entry.squeeze and not squeezedText then squeezedText = Squeeze(lower) end
        local all = true
        for _, words in ipairs(entry.lines) do
            if not LineMatches(words, lower, entry.squeeze and squeezedText or nil) then
                all = false
                break
            end
        end
        if all then return entry.filter end
    end
    return nil
end

-- For the editor's test box: the number of the first line of words the
-- message has none of, or nil when every line matches (it would be hidden).
function ns.MissingLine(message, filter)
    local text = ns.Text(message)
    if not text then return 1 end
    local lower = text:lower()
    local squeezed = filter.squeeze and Squeeze(lower) or nil
    local number = 0
    for _, line in ipairs(filter.lines or {}) do
        local words = Words(line, filter.squeeze)
        if #words > 0 then
            number = number + 1
            if not LineMatches(words, lower, squeezed) then return number end
        end
    end
    if number == 0 then return 1 end
    return nil
end

-------------------------------------------------------------------------------
-- Chat
-------------------------------------------------------------------------------

-- Which kind of chat each event is, for the Options page's choices.
local KINDS = {
    CHAT_MSG_CHANNEL = "filterPublic",
    CHAT_MSG_SAY = "filterSayYell", CHAT_MSG_YELL = "filterSayYell",
    CHAT_MSG_EMOTE = "filterSayYell", CHAT_MSG_TEXT_EMOTE = "filterSayYell",
    CHAT_MSG_WHISPER = "filterWhisper",
    CHAT_MSG_PARTY = "filterGroup", CHAT_MSG_PARTY_LEADER = "filterGroup",
    CHAT_MSG_RAID = "filterGroup", CHAT_MSG_RAID_LEADER = "filterGroup",
    CHAT_MSG_RAID_WARNING = "filterGroup",
    CHAT_MSG_INSTANCE_CHAT = "filterGroup", CHAT_MSG_INSTANCE_CHAT_LEADER = "filterGroup",
    CHAT_MSG_GUILD = "filterGroup", CHAT_MSG_OFFICER = "filterGroup",
}
ns.CHAT_KINDS = KINDS

-- Hidden this session, for the OSD.
ns.session = { listed = 0, filtered = 0 }

local function IsSpared(sender)
    if not ns.Get("spareFriends") then return false end
    local fl = _G.C_FriendList
    if fl and fl.IsFriend then
        local ok, friend = pcall(fl.IsFriend, ns.ShortName(sender))
        if ok and friend == true then return true end
    end
    local guild = _G.C_GuildInfo
    if guild and guild.MemberExistsByName then
        local ok, inGuild = pcall(guild.MemberExistsByName, ns.ShortName(sender))
        if ok and inGuild == true then return true end
    end
    return false
end

-- A chat filter is called once per chat window showing the message. The line
-- ID is the same for all of them, so each message is counted once.
local lastLine, lastVerdict

-- Returns true to hide.
local function Judge(event, message, sender, lineID)
    local full = ns.FullName(sender)
    if not full then return false end
    if ns.Get("hideListed") and ns.Players()[ns.Key(full)] then
        return true, "listed"
    end
    local kind = KINDS[event]
    if not (kind and ns.Get(kind)) then return false end
    if ns.Key(full) == ns.Key(ns.FullName(ns.Text(UnitName and UnitName("player")))) then return false end
    local filter = ns.MatchFilter(message)
    if filter and not IsSpared(full) then return true, filter end
    return false
end

function ns.ChatFilter(_, event, message, sender, ...)
    if not ns.On() then return false end
    -- Compared inside a pcall: a secret line ID throws on comparison, and
    -- this runs inside the game's own chat code.
    local lineID = select(9, ...)
    local okSame, same = pcall(function() return lineID ~= nil and lineID == lastLine end)
    if okSame and same then return lastVerdict end
    local ok, hide, why = pcall(Judge, event, message, sender, lineID)
    hide = ok and hide == true
    if hide then
        if why == "listed" then
            ns.session.listed = ns.session.listed + 1
        elseif type(why) == "table" then
            why.blocked = (why.blocked or 0) + 1
            ns.session.filtered = ns.session.filtered + 1
        end
        -- The Hidden column and the session line change with every hit; an
        -- open window shows it at once. A closed one costs nothing.
        if ns.RefreshWindow then pcall(ns.RefreshWindow) end
    end
    lastLine, lastVerdict = (okSame and lineID or nil), hide
    return hide
end

-- The game's own "X is now being ignored" for names the sync added.
local function SystemFilter(_, _, message)
    return ns.IsSyncMessage(message)
end

local registered = false
function ns.ApplyChat()
    ns.CompileFilters()
    if registered then return end
    local add = _G.ChatFrame_AddMessageEventFilter
        or (_G.ChatFrameUtil and _G.ChatFrameUtil.AddMessageEventFilter)
    if type(add) ~= "function" then return end
    -- Registered once and left in place: the filter asks ns.On() each time,
    -- so switching off needs no removal.
    for event in pairs(KINDS) do pcall(add, event, ns.ChatFilter) end
    pcall(add, "CHAT_MSG_SYSTEM", SystemFilter)
    registered = true
end

-------------------------------------------------------------------------------
-- Editing
-------------------------------------------------------------------------------

-- How many filters are switched on.
function ns.FiltersOn()
    local n = 0
    for _, filter in ipairs(ns.Filters()) do
        if filter.enabled then n = n + 1 end
    end
    return n
end

function ns.NewFilter()
    local filter = { name = "New filter", lines = { "" }, enabled = false, blocked = 0 }
    local list = ns.Filters()
    list[#list + 1] = filter
    ns.CompileFilters()
    return filter
end

function ns.DeleteFilter(filter)
    local list = ns.Filters()
    for i, f in ipairs(list) do
        if f == filter then
            table.remove(list, i)
            ns.CompileFilters()
            return true
        end
    end
    return false
end
