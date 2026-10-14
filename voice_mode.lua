-- Voice mode for Claude Code
-- Speaks Claude's replies with hs.speech and sends push-to-talk transcripts (from stt) to
-- Claude's terminal (iTerm or Orca, without moving focus) or window. Driven by the
-- voice-mode skill and the hook in ~/.claude/hooks/voice-mode.py, through hammerspoon://
-- URL events:
--   voice-mode?state=on&session=<id>&pid=<pid>&iterm=<id>&orca=<handle>
--                                                claims the session; saves the terminal target
--                                                (iterm/orca, either optional) and the frontmost window
--   voice-mode?state=off&session=<id>            only the owner session can turn it off
--   voice-batch?msg=<id>&i=<n>&final=<0|1>&text=  a MessageDisplay batch to speak
--   voice-turn?state=busy|idle                   UserPromptSubmit / Stop, StopFailure
-- The hook ignores every session except the one in OWNER_FILE.
-- While on, the stt pill stays on screen (your turn / thinking / speaking). With auto_listen,
-- dictation starts by itself once Claude's turn has ended and it has finished speaking.

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
local stt = nil
local autoListen = true
local listenTimer = nil
local LISTEN_GRACE = 1  -- s after the turn ends and speech stops, for MessageDisplay batches still in flight

-- ── Pill and auto-listen ──────────────────────────────────────────

local function speaking()
    return synth:isSpeaking() or (#queue > 0 and not muted)
end

local function updatePill()
    if not active then return stt.setIdlePill(nil) end
    stt.setIdlePill(speaking() and "voice-speaking" or busy and "voice-thinking" or "voice-idle")
end

-- Claude's turn is over and it is quiet: start listening, after a grace period for late batches
local function maybeListen()
    if listenTimer then listenTimer:stop(); listenTimer = nil end
    if not active or not autoListen or busy or muted or speaking() then return end
    local token = activation
    listenTimer = hs.timer.doAfter(LISTEN_GRACE, function()
        listenTimer = nil
        if token == activation and not busy and not muted and not speaking() then stt.listen() end
    end)
end

-- ── Speech ────────────────────────────────────────────────────────

local function speakNext()
    if muted or synth:isSpeaking() or #queue == 0 then
        updatePill()
        if not synth:isSpeaking() then maybeListen() end
        return
    end
    synth:speak(table.remove(queue, 1))
    updatePill()
end

local function say(text)
    table.insert(queue, text)
    speakNext()
end

local function silence()
    queue = {}
    msgs = {}
    if listenTimer then listenTimer:stop(); listenTimer = nil end
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
-- With a terminal target (iTerm session or Orca terminal, passed by the skill) the
-- transcript is written straight into Claude's terminal and focus never moves. Without
-- one, Claude's window is focused and the transcript pasted. A failed send to a target
-- never falls back to the window: it is the window, not the tab, and may hold another session.

-- argv: session uuid, "esc" or "text", text. Prints "ok" or "missing".
local ITERM_SCRIPT = [[
on run argv
	if application "iTerm2" is not running then return "missing"
	set E to character id 27
	tell application "iTerm2"
		repeat with w in windows
			repeat with t in tabs of w
				set m to (sessions of t whose id is (item 1 of argv))
				if m is not {} then
					tell item 1 of m
						if item 2 of argv is "esc" then
							write text E newline NO
						else
							write text (E & "[200~" & (item 3 of argv) & E & "[201~") newline NO
							delay 0.05
							write text (character id 13) newline NO
						end if
					end tell
					return "ok"
				end if
			end repeat
		end repeat
	end tell
	return "missing"
end run]]
local ESC_GAP = 0.4     -- s between Esc and the transcript, so Claude has cancelled its turn
local TURN_TIMEOUT = 1.5  -- s for UserPromptSubmit to arrive after a send

local outbox = {}       -- transcripts waiting to be sent, one send at a time
local sending = false
local prompts = 0       -- voice-turn busy events seen; the watchdog compares it
local orcaBin = nil

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

-- Copies the transcript and, if voice mode is still on for this recording, unmutes it
local function failSubmit(text, why, token)
    hs.pasteboard.setContents(text)
    toast.show({icon = "!", title = "Not sent to Claude", detail = why .. ". Transcript copied.", tint = "red"})
    if token == activation and active then
        muted = false
        updatePill()
        maybeListen()
    end
end

-- Runs a command without blocking, killed after 10 s. done(ok, stdout)
local function run(path, args, done)
    local task
    local timer = hs.timer.doAfter(10, function() task:terminate() end)
    task = hs.task.new(path, function(code, out)
        timer:stop()
        done(code == 0, out or "")
    end, args)
    if not task:start() then timer:stop(); done(false, "") end
end

-- Control characters other than newline and tab would reach the terminal as keys
local function clean(text)
    return (text:gsub("[%z\1-\8\11-\31\127]", ""))
end

-- payload: the transcript, or nil for Esc. done(ok, why)
local function sendITerm(uuid, payload, done)
    local args = {"-e", ITERM_SCRIPT, uuid, payload and "text" or "esc", payload and payload:gsub("\n", "\r") or ""}
    run("/usr/bin/osascript", args, function(ok, out)
        if ok and out:match("^ok") then return done(true) end
        done(false, ok and "Claude's iTerm session is gone" or "Couldn't reach iTerm")
    end)
end

local function sendOrca(handle, payload, done)
    if orcaBin == nil then
        orcaBin = false
        for _, path in ipairs({"/opt/homebrew/bin/orca", "/usr/local/bin/orca"}) do
            if hs.fs.attributes(path) then orcaBin = path; break end
        end
    end
    if not orcaBin then return done(false, "The orca CLI isn't installed") end
    -- Not --interrupt: it sends Ctrl+C, and a second one exits Claude
    local args = {"terminal", "send", "--terminal", handle, "--text", payload or "\27"}
    if payload then table.insert(args, "--enter") end
    run(orcaBin, args, function(ok) done(ok, "Couldn't reach Claude's Orca terminal") end)
end

-- Focus Claude's window, cancel its turn if it is working, paste, press Return, and give
-- focus back. Each step checks that Claude's window still has focus, so keystrokes never
-- land in another app.
local function sendFocused(text, token, done)
    local win = owner.winId and hs.window.get(owner.winId)
    if not win then return done(false, "Claude's window is gone") end
    local prev = hs.window.focusedWindow()
    win:focus()
    whenFocused(function(ok)
        if not ok then return done(false, "Couldn't focus Claude's window") end
        local wasBusy = busy
        if wasBusy then
            hs.eventtap.keyStroke({}, "escape")
            busy = false
        end
        hs.timer.doAfter(wasBusy and ESC_GAP or 0, function()
            if token ~= activation or not isFocused() then return done(false, "Focus moved") end
            hs.pasteboard.setContents(text)
            hs.eventtap.keyStroke({"cmd"}, "v")
            hs.timer.doAfter(0.2, function()
                if token ~= activation or not isFocused() then return done(false, "Focus moved") end
                hs.eventtap.keyStroke({}, "return")
                if prev and prev:id() ~= owner.winId then
                    hs.timer.doAfter(0.1, function() prev:focus() end)
                end
                done(true)
            end)
        end)
    end)
end

local sendNext

local function submit(text, token)
    table.insert(outbox, {text = text, token = token})
    if not sending then sendNext() end
end

sendNext = function()
    local item = table.remove(outbox, 1)
    sending = item ~= nil
    if not item then return end
    local text, token, seen = item.text, item.token, prompts
    local live = function() return token == activation and active end
    local function finish(ok, why)
        if not ok then
            failSubmit(text, why, token)
        elseif live() then
            busy = true
            updatePill()
            -- A write that landed in a dialog or a dead shell starts no turn
            hs.timer.doAfter(TURN_TIMEOUT, function()
                if live() and prompts == seen then
                    busy = false
                    failSubmit(text, "Claude didn't start a turn", token)
                end
            end)
        end
        sendNext()
    end
    if not live() then return finish(false, "Voice mode changed") end
    if not ownerAlive() then
        M.off()
        return finish(false, "The Claude session has ended")
    end
    local o = owner
    local send = o.orca and function(p, cb) sendOrca(o.orca, p, cb) end
        or o.iterm and function(p, cb) sendITerm(o.iterm, p, cb) end
    if not send then return sendFocused(text, token, finish) end
    if not busy then return send(clean(text), finish) end
    send(nil, function(ok, why)
        if not ok then return finish(false, why) end
        busy = false
        hs.timer.doAfter(ESC_GAP, function()
            if not live() then return finish(false, "Voice mode changed") end
            send(clean(text), finish)
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
        if token == activation then muted = false; updatePill() end
    end
end

-- ── On / off ──────────────────────────────────────────────────────

-- iterm: $ITERM_SESSION_ID (w0t1p0:<uuid>), orca: $ORCA_TERMINAL_HANDLE. Either one lets
-- transcripts go straight to the terminal; without them the frontmost window is used.
function M.on(session, pid, iterm, orca)
    iterm = iterm and iterm:match("^w%d+t%d+p%d+:([%x%-]+)$")
    orca = orca and orca:match("^term_[%w%-]+$")
    local win = hs.window.focusedWindow()
    if not session or session == "" or not pid or not (win or iterm or orca) then
        toast.show({icon = "!", title = "Voice mode", detail = "Missing session, pid, or window", tint = "red"})
        return
    end
    local f = io.open(OWNER_FILE, "w")
    if not f then return end
    f:write(session)
    f:close()
    activation = activation + 1
    -- The skill turns voice mode on inside a turn; its Stop marks the end
    active, busy, muted = true, true, false
    owner = {session = session, pid = pid, winId = win and win:id(), iterm = iterm, orca = orca}
    silence()
    toast.show({icon = "🎙", title = "Voice mode on", detail = orca and "Orca terminal" or iterm and "iTerm session" or win:title(), tint = "blue"})
    say("Voice mode on.")
end

function M.off()
    os.remove(OWNER_FILE)
    if not active then return end
    activation = activation + 1
    active, owner, busy, muted = false, nil, false, false
    silence()
    updatePill()
    toast.show({icon = "🎙", title = "Voice mode off"})
    say("Voice mode off.")
end

function M.isActive() return active end

-- cfg.stt: the stt module (required). cfg.auto_listen: default true.
function M.init(cfg)
    stt = cfg.stt
    if cfg.auto_listen ~= nil then autoListen = cfg.auto_listen end
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
            M.on(params.session, tonumber(params.pid), params.iterm, params.orca)
        elseif params.state == "off" and active and params.session == owner.session then
            M.off()
        end
    end)
    hs.urlevent.bind("voice-batch", function(_, params) onBatch(params) end)
    hs.urlevent.bind("voice-turn", function(_, params)
        if not active then return end
        busy = params.state == "busy"
        if busy then prompts = prompts + 1 end
        -- A new prompt ends a barge-in: speak this turn's reply
        if busy then muted = false; msgs = {} end
        updatePill()
        maybeListen()
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
