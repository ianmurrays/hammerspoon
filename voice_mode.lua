-- Voice mode for Claude Code
-- Speaks Claude's replies with hs.speech and sends push-to-talk transcripts (from stt) to
-- the Claude Code window. Driven by the voice-mode skill and the hook in
-- ~/.claude/hooks/voice-mode.py, through hammerspoon:// URL events:
--   voice-mode?state=on&session=<id>&pid=<pid>   saves the frontmost window, claims the session
--   voice-mode?state=off&session=<id>            only the owner session can turn it off
--   voice-batch?msg=<id>&i=<n>&final=<0|1>&text=  a MessageDisplay batch to speak
--   voice-turn?state=busy|idle                   UserPromptSubmit / Stop, StopFailure
-- The hook ignores every session except the one in OWNER_FILE.

local M = {}
local toast = require("toast")

local OWNER_FILE = os.getenv("HOME") .. "/.claude/voice-mode-session"

local active = false
local activation = 0    -- bumped on every on/off, so a recording started earlier can't submit
local owner = nil       -- {session = id, pid = n, winId = n}
local busy = false      -- Claude is working on a turn (UserPromptSubmit seen, no Stop yet)
local muted = false     -- set by barge-in; drops speech until the next prompt is submitted
local synth = nil
local queue = {}
local msgs = {}         -- message_id -> {next = index, pending = {}, fence = bool}

-- ── Speech ────────────────────────────────────────────────────────

local function speakNext()
    if muted or synth:isSpeaking() or #queue == 0 then return end
    synth:speak(table.remove(queue, 1))
end

local function say(text)
    table.insert(queue, text)
    speakNext()
end

local function silence()
    queue = {}
    msgs = {}
    synth:stop()
end

-- Markdown line → speakable text, or nil for lines that should not be read aloud
-- (code fences and their contents, table rows, rules).
local function cleanLine(line, m)
    if line:match("^%s*```") or line:match("^%s*~~~") then
        m.fence = not m.fence
        return nil
    end
    if m.fence or line:match("^%s*|") or line:match("^%s*[-*_][-*_][-*_]+%s*$") then return nil end
    line = line:gsub("^%s*#+%s*", "")
        :gsub("^%s*>%s?", "")
        :gsub("^%s*[-*+]%s+", "")
        :gsub("^%s*%d+[.)]%s+", "")
        :gsub("%[(.-)%]%b()", "%1")
        :gsub("https?://%S+", "a link")
        :gsub("[`*]", "")
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return nil end
    return line
end

-- Batches of one message can arrive out of order (one `open` per hook run), so they
-- are spoken strictly by index.
local function onBatch(params)
    if not active or muted then return end
    local id, i = params.msg, tonumber(params.i)
    if not id or not i then return end
    local m = msgs[id]
    if not m then m = {next = 0, pending = {}, fence = false}; msgs[id] = m end
    m.pending[i] = params.text or ""
    while m.pending[m.next] do
        for line in (m.pending[m.next] .. "\n"):gmatch("(.-)\n") do
            local text = cleanLine(line, m)
            if text then say(text) end
        end
        m.pending[m.next] = nil
        m.next = m.next + 1
    end
    if params.final == "1" and not next(m.pending) then msgs[id] = nil end
end

-- ── Submitting a transcript ───────────────────────────────────────

local function ownerAlive()
    local _, ok = hs.execute("/bin/kill -0 " .. owner.pid .. " 2>/dev/null")
    return ok == true
end

local function isFocused()
    local f = hs.window.focusedWindow()
    return f and f:id() == owner.winId
end

-- Polls every 50 ms, up to 1 s, for Claude's window to have focus.
local function whenFocused(fn, tries)
    tries = tries or 20
    if isFocused() then return fn(true) end
    if tries == 0 then return fn(false) end
    hs.timer.doAfter(0.05, function() whenFocused(fn, tries - 1) end)
end

local function failSubmit(text, why)
    hs.pasteboard.setContents(text)
    toast.show({icon = "!", title = "Not sent to Claude", detail = why .. ". Transcript copied.", tint = "red"})
end

-- Focus Claude's window, cancel its turn if it is working, paste, press Return, and give
-- focus back. Each step checks that Claude's window still has focus, so keystrokes never
-- land in another app.
local function submit(text, token)
    if token ~= activation or not active then return failSubmit(text, "Voice mode changed") end
    if not ownerAlive() then
        M.off()
        return failSubmit(text, "The Claude session has ended")
    end
    local win = hs.window.get(owner.winId)
    if not win then return failSubmit(text, "Claude's window is gone") end
    local prev = hs.window.focusedWindow()
    win:focus()
    whenFocused(function(ok)
        if not ok then return failSubmit(text, "Couldn't focus Claude's window") end
        local wasBusy = busy
        if wasBusy then
            hs.eventtap.keyStroke({}, "escape")
            busy = false
        end
        hs.timer.doAfter(wasBusy and 0.4 or 0, function()
            if token ~= activation or not isFocused() then return failSubmit(text, "Focus moved") end
            hs.pasteboard.setContents(text)
            hs.eventtap.keyStroke({"cmd"}, "v")
            hs.timer.doAfter(0.2, function()
                if token ~= activation or not isFocused() then return failSubmit(text, "Focus moved") end
                hs.eventtap.keyStroke({}, "return")
                if prev and prev:id() ~= owner.winId then
                    hs.timer.doAfter(0.1, function() prev:focus() end)
                end
            end)
        end)
    end)
end

-- Called by stt when a recording starts. Returns the function that delivers this
-- recording's transcript, or nil (stt pastes as usual). stt calls it with nil when the
-- recording is discarded, which lets Claude speak again. Captures the activation, so a
-- recording that outlives a mode change can't submit into a new session.
function M.claimRecording()
    if not active then return nil end
    muted = true
    silence()
    local token = activation
    return function(text)
        if text then return submit(text, token) end
        if token == activation then muted = false end
    end
end

-- ── On / off ──────────────────────────────────────────────────────

function M.on(session, pid)
    local win = hs.window.focusedWindow()
    if not session or session == "" or not pid or not win then
        toast.show({icon = "!", title = "Voice mode", detail = "Missing session, pid, or window", tint = "red"})
        return
    end
    local f = io.open(OWNER_FILE, "w")
    if not f then return end
    f:write(session)
    f:close()
    activation = activation + 1
    active, busy, muted = true, false, false
    owner = {session = session, pid = pid, winId = win:id()}
    silence()
    toast.show({icon = "🎙", title = "Voice mode on", detail = win:title(), tint = "blue"})
    say("Voice mode on.")
end

function M.off()
    os.remove(OWNER_FILE)
    if not active then return end
    activation = activation + 1
    active, owner, busy, muted = false, nil, false, false
    silence()
    toast.show({icon = "🎙", title = "Voice mode off"})
    say("Voice mode off.")
end

function M.isActive() return active end

function M.init()
    -- A reload loses the saved window and speech state, so a leftover owner file is stale
    os.remove(OWNER_FILE)
    synth = hs.speech.new()
    synth:setCallback(function(_, what)
        -- stop() clears the queue first, so the didFinish(false) it causes only reaches
        -- lines queued after it (such as "Voice mode off.")
        if what == "didFinish" then speakNext() end
    end)

    hs.urlevent.bind("voice-mode", function(_, params)
        if params.state == "on" then
            M.on(params.session, tonumber(params.pid))
        elseif params.state == "off" and active and params.session == owner.session then
            M.off()
        end
    end)
    hs.urlevent.bind("voice-batch", function(_, params) onBatch(params) end)
    hs.urlevent.bind("voice-turn", function(_, params)
        if not active then return end
        busy = params.state == "busy"
        -- A new prompt ends a barge-in: speak this turn's reply
        if busy then muted = false; msgs = {} end
    end)

    local prevShutdown = hs.shutdownCallback
    hs.shutdownCallback = function()
        os.remove(OWNER_FILE)
        if prevShutdown then prevShutdown() end
    end
    return M
end

function M.stop()
    M.off()
    for _, name in ipairs({"voice-mode", "voice-batch", "voice-turn"}) do hs.urlevent.bind(name, nil) end
end

return M
