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
    {
        id = "linkjoke", name = "Crude link jokes",
        lines = { '"anal"', "{link}" },
    },
    {
        -- Every term in quotes, so it is only ever a word on its own:
        -- "trump" is not "trumpet", "vance" not "advance", "tory" not
        -- "victory". Words that are everyday or game chat too (party, vote,
        -- war, tax, left, right, president, inflation, woke) are left out.
        id = "politics", name = "Politics",
        lines = { '"democrat", "democrats", "democratic party", "republican", "republicans", "gop", "dnc", "rnc", "maga", "liberal", "liberals", "libtard", "libtards", "leftist", "leftists", "left wing", "right wing", "far left", "far right", "conservatives", "neocon", "neocons", "wokeness", "wokeism", "antifa", "blm", "proud boys", "qanon", "deep state", "trump", "biden", "obama", "kamala", "hillary", "pelosi", "aoc", "bernie", "desantis", "vance", "rfk", "newsom", "mcconnell", "schumer", "putin", "zelensky", "netanyahu", "xi jinping", "boris johnson", "starmer", "farage", "trudeau", "congress", "congressman", "congresswoman", "senate", "senator", "supreme court", "scotus", "potus", "white house", "capitol", "impeach", "impeachment", "filibuster", "electoral", "ballot", "ballots", "midterms", "presidential", "abortion", "pro life", "pro choice", "roe v wade", "gun control", "second amendment", "immigration", "illegals", "border wall", "deportation", "deportations", "socialism", "socialist", "communism", "communist", "marxist", "fascism", "fascist", "nazi", "nazis", "authoritarian", "tariff", "tariffs", "brexit", "tory", "tories", "labour party", "ukraine", "russia", "gaza", "palestine", "israel", "hamas", "idf", "zionist", "zionism", "cnn", "fox news", "msnbc", "fake news"' },
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

-- Letters spammers swap for look-alikes. A word in quotes accepts any of
-- them in that letter's place.
local LOOKALIKE = {
    a = "[a4@]", e = "[e3]", i = "[i1!]", l = "[l1i]", o = "[o0]", s = "[s5%$]", t = "[t7]",
}

-- A "quoted" word as a Lua pattern: its letters in order, each one or any of
-- its look-alikes, with spaces or symbols allowed between them. So "anal"
-- also finds "a n a l", "a.n.a.l" and "4nal". Whole-word is checked by
-- WholeWordIn, not here.
local function WholePattern(word)
    local parts = {}
    for c in word:gmatch("%S") do
        parts[#parts + 1] = LOOKALIKE[c] or (c:match("%w") and c) or ("%" .. c)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "[%s%p]*")
end

-- Whether the pattern turns up as a word of its own: no letter right before
-- it or right after it, so "anal" is found in "anal [link]" but not in
-- "canal" or "analysis".
local function WholeWordIn(lower, pattern)
    local from = 1
    while true do
        local first, last = lower:find(pattern, from)
        if not first then return false end
        local before = first > 1 and lower:sub(first - 1, first - 1) or ""
        local after = lower:sub(last + 1, last + 1)
        if not before:match("%a") and not after:match("%a") then return true end
        from = first + 1
    end
end

-- A word with * in it as a Lua pattern: every character as itself, and each
-- * as "anything, as little as it takes". So <*> is any guild tag and stops
-- at the first >. A word that is nothing but * would match every message,
-- and is dropped instead.
local function WildPattern(word)
    if not word:find("[^%*%s]") then return nil end
    local escaped = word:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
    return (escaped:gsub("%*", ".-"))
end

-- A line of words, as lowercase words (and squeezed, when asked). Three kinds
-- are special:
--   {link}     any link: an item, spell, quest or other, however it is named
--   "word"     only as a whole word, spaced out or with look-alike letters
--   <*>        * is a wildcard: anything, of any length
local function Words(line, squeeze)
    local out = {}
    for word in tostring(line or ""):gmatch("[^,]+") do
        word = ns.Lower(word:match("^%s*(.-)%s*$"))
        local quoted = word:match('^"(.+)"$')
        if word == "{link}" then
            out[#out + 1] = { link = true }
        elseif quoted then
            local pattern = WholePattern(quoted)
            if pattern then out[#out + 1] = { whole = pattern } end
        elseif word:find("*", 1, true) then
            local pattern = WildPattern(word)
            if pattern then out[#out + 1] = { wild = pattern } end
        elseif word ~= "" then
            out[#out + 1] = { plain = word, squeezed = squeeze and Squeeze(word) or nil }
        end
    end
    return out
end

-- A filter's own channels ("Trade, LookingForGroup") as a set of lowercase
-- names, or nil for "everywhere the Options allow". Only names: a channel's
-- number depends on the order it was joined, and differs between characters.
local function ChannelSet(text)
    local set, any = {}, false
    for name in tostring(text or ""):gmatch("[^,]+") do
        name = ns.Lower(name:match("^%s*(.-)%s*$"))
        if name ~= "" then
            any = true
            if not name:match("^%d+$") then set[name] = true end
        end
    end
    -- Only a blank box means everywhere. A list left with nothing usable in
    -- it (numbers only) works nowhere, rather than everywhere by accident.
    return any and set or nil
end
ns.ChannelSet = ChannelSet

-- The channels this character is in: { { number = 2, name = "Trade" } ... }.
-- "Trade - City" is "Trade", as the filters name it.
function ns.JoinedChannels()
    local out = {}
    local get = _G.GetChannelList
    if type(get) ~= "function" then return out end
    local results = { pcall(get) }
    if not results[1] then return out end
    -- Triples: number, name, disabled.
    for i = 2, #results, 3 do
        local number, name = ns.Num(results[i]), ns.Text(results[i + 1])
        if number and name then
            out[#out + 1] = { number = math.floor(number), name = name:match("^(.-)%s+%-%s+") or name }
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
                compiled[#compiled + 1] = { filter = filter, lines = lines, squeeze = filter.squeeze,
                                            channels = ChannelSet(filter.channels) }
            end
        end
    end
end

local function LineMatches(words, lower, squeezed)
    for _, word in ipairs(words) do
        if word.link then
            -- Every link carries the client's |H...|h markup in the raw
            -- text, whatever it links to. Nobody can type it by hand.
            if lower:find("|h", 1, true) then return true end
        elseif word.whole then
            if WholeWordIn(lower, word.whole) then return true end
        elseif word.wild then
            if lower:find(word.wild) then return true end
        elseif lower:find(word.plain, 1, true) then return true end
        -- A word that is all symbols ("<", "$") squeezes to nothing, and is
        -- only ever looked for as it is.
        if squeezed and word.plain and word.squeezed and word.squeezed ~= ""
            and squeezed:find(word.squeezed, 1, true) then
            return true
        end
    end
    return false
end

-- The first enabled filter a message matches, or nil. `only` tries just that
-- one filter, switched on or not: the editor's test box. `applies`, when
-- given, says whether a filter works where the message was said.
function ns.MatchFilter(message, only, applies)
    local text = ns.Text(message)
    if not text then return nil end
    local lower = ns.Lower(text)
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
      if not applies or applies(entry) then
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
    end
    return nil
end

-- For the editor's test box: the number of the first line of words the
-- message has none of, or nil when every line matches (it would be hidden).
function ns.MissingLine(message, filter)
    local text = ns.Text(message)
    if not text then return 1 end
    local lower = ns.Lower(text)
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

-------------------------------------------------------------------------------
-- The hidden messages log
-------------------------------------------------------------------------------
-- The last LOG_MAX messages ChairIgnore hid, newest last: when, what kind of
-- chat, from whom, what it said, and why (the listing, or which filter).
-- Kept for the session only, unless "keepLog" is on, when it lives in the
-- account's saved data. Local only: nothing here is ever sent anywhere.

ns.LOG_MAX = 200
local sessionLog = {}

function ns.HiddenLog()
    if ns.Get("keepLog") then
        local db = _G.ChairIgnoreDB
        if type(db) == "table" then
            db.log = type(db.log) == "table" and db.log or {}
            return db.log
        end
    end
    return sessionLog
end

function ns.ClearHiddenLog()
    wipe(sessionLog)
    local db = _G.ChairIgnoreDB
    if type(db) == "table" then db.log = nil end
end

-- "CHAT_MSG_RAID_LEADER" -> "raid leader"
local function KindName(event)
    return (tostring(event or ""):gsub("^CHAT_MSG_", ""):gsub("_", " "):lower())
end

local function Remember(event, message, sender, why)
    local log = ns.HiddenLog()
    local entry = {
        at = ns.Now(),
        kind = KindName(event),
        sender = ns.FullName(sender),
        -- A message the client kept secret can still be hidden (its sender
        -- is listed); there is just nothing of it to show.
        text = ns.Text(message),
        why = (why == "listed") and "listed" or (type(why) == "table" and why.name) or "?",
    }
    log[#log + 1] = entry
    while #log > ns.LOG_MAX do table.remove(log, 1) end
    if ns.ToIgnoredTab then pcall(ns.ToIgnoredTab, entry) end
end

-- A chat filter is called once per chat window showing the message. The line
-- ID is the same for all of them, so each message is counted once.
local lastLine, lastVerdict

-- Returns true to hide.
-- A channel as the filters name it: "Trade - City" is "trade".
local function ChannelName(channelName)
    local name = ns.Text(channelName)
    return name and ns.Lower(name:match("^(.-)%s+%-%s+") or name) or nil
end

local function Judge(event, message, sender, lineID, channelIndex, channelName)
    local full = ns.FullName(sender)
    if not full then return false end
    if ns.Get("hideListed") and ns.Players()[ns.Key(full)] then
        return true, "listed"
    end
    if ns.Key(full) == ns.Key(ns.FullName(Chaircraft.UnitFullName("player"))) then return false end
    local kind = KINDS[event]
    -- Where it was said, as a filter's channel list names it: a numbered
    -- channel by its name, and Say and Yell as themselves.
    local where
    if event == "CHAT_MSG_CHANNEL" then
        where = ChannelName(channelName)
    elseif event == "CHAT_MSG_SAY" then
        where = "say"
    elseif event == "CHAT_MSG_YELL" then
        where = "yell"
    end
    -- A filter that names its own channels works in those channels only,
    -- whatever the Options tab says; the rest go where the Options allow.
    local function Applies(entry)
        if entry.channels then
            return (where and entry.channels[where]) and true or false
        end
        return kind ~= nil and ns.Get(kind) == true
    end
    local filter = ns.MatchFilter(message, nil, Applies)
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
    local channelIndex, channelName = select(6, ...)
    local ok, hide, why = pcall(Judge, event, message, sender, lineID, channelIndex, channelName)
    hide = ok and hide == true
    if hide then
        if why == "listed" then
            ns.session.listed = ns.session.listed + 1
        elseif type(why) == "table" then
            why.blocked = (why.blocked or 0) + 1
            ns.session.filtered = ns.session.filtered + 1
        end
        pcall(Remember, event, message, sender, why)
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

-------------------------------------------------------------------------------
-- Sharing
-------------------------------------------------------------------------------
-- One filter as a line of text, to paste to a friend or a forum: its name,
-- its lines of words and its squeeze setting, serialized and compressed the
-- same way ChairAuras shares an aura. Never its count or whether it is on:
-- an imported filter always arrives switched off, for you to look at first.

local SHARE_PREFIX = "!CI:1!"

local function Lib(name)
    local stub = _G.LibStub
    if not stub then return nil end
    local ok, lib = pcall(stub.GetLibrary, stub, name, true)
    return ok and lib or nil
end

function ns.ExportFilter(filter)
    if type(filter) ~= "table" then return nil, "pick a filter first" end
    local serialize, deflate = Lib("LibSerialize"), Lib("LibDeflate")
    if not (serialize and deflate) then return nil, "this copy is missing LibSerialize or LibDeflate" end
    local lines = {}
    for _, line in ipairs(filter.lines or {}) do lines[#lines + 1] = tostring(line) end
    local ok, text = pcall(function()
        local packed = serialize:Serialize({ v = 1, name = tostring(filter.name or ""),
                                             lines = lines, squeeze = filter.squeeze and true or nil,
                                             channels = filter.channels })
        return SHARE_PREFIX .. deflate:EncodeForPrint(deflate:CompressDeflate(packed, { level = 9 }))
    end)
    if not ok then return nil, "could not be written" end
    return text
end

-- Adds the filter a string holds. Returns it, or nil and why not.
function ns.ImportFilter(text)
    text = tostring(text or ""):gsub("%s", "")
    if text:sub(1, #SHARE_PREFIX) ~= SHARE_PREFIX then return nil, "that is not a ChairIgnore filter" end
    local serialize, deflate = Lib("LibSerialize"), Lib("LibDeflate")
    if not (serialize and deflate) then return nil, "this copy is missing LibSerialize or LibDeflate" end
    local decoded = deflate:DecodeForPrint(text:sub(#SHARE_PREFIX + 1))
    local raw = decoded and deflate:DecompressDeflate(decoded)
    if not raw then return nil, "the text is damaged" end
    local ok, data = serialize:Deserialize(raw)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil, "the text is damaged" end

    -- Only plain text comes in, and not too much of it.
    local lines = {}
    for i = 1, math.min(#data.lines, 6) do
        if type(data.lines[i]) == "string" then lines[#lines + 1] = data.lines[i]:sub(1, 2000) end
    end
    if #lines == 0 then return nil, "the filter has no words" end
    local name = type(data.name) == "string" and data.name:sub(1, 60) or ""
    if not name:match("%S") then name = "Imported filter" end

    -- A second copy of a name gets " (2)", " (3)"...
    local taken = {}
    for _, f in ipairs(ns.Filters()) do taken[tostring(f.name)] = true end
    local base, n = name, 1
    while taken[name] do
        n = n + 1
        name = base .. " (" .. n .. ")"
    end

    local channels
    if type(data.channels) == "string" then
        local names = {}
        for entry in data.channels:sub(1, 200):gmatch("[^,]+") do
            entry = entry:match("^%s*(.-)%s*$")
            if entry ~= "" and not entry:match("^%d+$") then names[#names + 1] = entry end
        end
        channels = table.concat(names, ", ")
    end
    local filter = { name = name, lines = lines, squeeze = data.squeeze == true or nil,
                     channels = (channels and channels:match("%S")) and channels or nil,
                     enabled = false, blocked = 0 }
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
