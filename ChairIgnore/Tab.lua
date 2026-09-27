-- ChairIgnore Tab.lua
-- Everything ChairIgnore hides, shown in a chat tab of its own ("Ignored"),
-- docked on the main chat window. Off out of the box.
--
-- Care taken with the game's chat, which on this client carries values that
-- addons cannot read and which breaks when addon code has been through it:
--   * the tab is made once, with the game's own "new chat window" call,
--     never in combat (it waits for combat to end), and only when missing;
--   * a new window starts with no chat in it, and nothing is added: the game
--     never writes to it, so nothing of the game's chat passes through it;
--   * ChairIgnore only prints into it, the way print() does;
--   * it is found again by name, so a /reload or a new session reuses it.
-- /chair ignore tab off stops it; the tab itself is closed like any other
-- (right-click it, Close Window).

local suiteName, Chaircraft = ...
local ns = Chaircraft.ChairIgnore

ns.TAB_NAME = "Ignored"

-- The Ignored tab's chat frame, if there is one.
function ns.FindIgnoredTab()
    local count = tonumber(_G.NUM_CHAT_WINDOWS) or 10
    local info = _G.GetChatWindowInfo
    if type(info) ~= "function" then return nil end
    for i = 1, count do
        local ok, name = pcall(info, i)
        if ok and ns.Text(name) == ns.TAB_NAME then
            local frame = _G["ChatFrame" .. i]
            if frame then return frame, i end
        end
    end
    return nil
end

local waitingForCombat = false

-- Makes the tab if it is missing. Returns the frame, or nil and why not.
function ns.EnsureIgnoredTab()
    local frame = ns.FindIgnoredTab()
    if frame then return frame end
    local ok, locked = pcall(_G.InCombatLockdown)
    if ok and locked == true then
        waitingForCombat = true
        return nil, "in combat: it will be made when combat ends"
    end
    local open = _G.FCF_OpenNewWindow
    if type(open) ~= "function" then
        return nil, "this client cannot make one; make a chat tab named " .. ns.TAB_NAME .. " and it will be used"
    end
    local made, result = pcall(open, ns.TAB_NAME)
    if not made then return nil, "the game refused: " .. tostring(ns.Text(result) or "unknown error") end
    frame = ns.FindIgnoredTab()
    if not frame then return nil, "the tab did not appear" end
    return frame
end

local function TimeText(t)
    if type(date) ~= "function" then return "" end
    return "|cff808080" .. date("%H:%M", t or ns.Now()) .. "|r "
end

-- One hidden message, printed into the tab.
function ns.ToIgnoredTab(entry)
    if not (ns.On("ignoredTab") and type(entry) == "table") then return end
    local frame = ns.FindIgnoredTab()
    if not frame then return end
    local why = (entry.why == "listed") and "listed" or tostring(entry.why or "?")
    local line = TimeText(entry.at) .. "[" .. tostring(entry.kind or "?") .. "] "
        .. tostring(ns.ShortName(entry.sender or "?")) .. ": "
        .. (entry.text or "|cff808080(unreadable)|r")
        .. " |cff808080(" .. why .. ")|r"
    pcall(frame.AddMessage, frame, line, 0.75, 0.75, 0.75)
end

local function Turned(on)
    if not on then return end
    local frame, why = ns.EnsureIgnoredTab()
    if frame then
        ns.Print("Hidden messages go to the " .. ns.TAB_NAME .. " chat tab.")
    elseif why then
        ns.Print("No " .. ns.TAB_NAME .. " tab yet: " .. why .. ".")
    end
end
ns.IgnoredTabTurned = Turned

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if not waitingForCombat then return end
        waitingForCombat = false
        if ns.On("ignoredTab") then pcall(Turned, true) end
    elseif event == "PLAYER_LOGIN" then
        -- A few seconds in, once the chat windows are all set up.
        if C_Timer and C_Timer.After then
            C_Timer.After(3, function()
                if ns.On("ignoredTab") and not ns.FindIgnoredTab() then pcall(ns.EnsureIgnoredTab) end
            end)
        end
    end
end)
