-- Speech-to-Text Module for Hammerspoon
-- Records audio via a local parakeet-mlx daemon, transcribes on stop.
-- Daemon is started on demand and stopped after idle timeout.
-- Toggle recording with fn+Space, hold-to-talk with fn+Shift.
-- History viewer: Ctrl+Alt+H (configurable via history_hotkey)
--
-- Config options (passed via init(cfg)):
--   host              = string   (default: "127.0.0.1")
--   port              = number   (default: 9876)
--   paste_method      = "clipboard" or "keystrokes"
--   idle_timeout      = number   (seconds, default: 300)
--   llm_api_key       = string   (default: nil, disabled)
--   llm_api_url       = string   (default: Mistral chat completions endpoint)
--   llm_model         = string   (default: "mistral-small-latest")
--   llm_system_prompt = string   (custom cleanup prompt)
--   llm_timeout       = number   (seconds, default: 10)
--   play_tones        = boolean  (default: true, play sounds on state changes)
--   pause_media       = boolean  (default: true, pause media during recording)
--   media_ctl         = string   (default: "/opt/homebrew/bin/media-control")
--   history_hotkey    = table    (default: {{"ctrl", "alt"}, "h"})

local M = {}
local htmlLoader = require("html_loader")

-- Config defaults
local config = {
    host = "127.0.0.1",
    port = 9876,
    paste_method = "clipboard",
    idle_timeout = 5 * 60,
    daemon_cmd = "/opt/homebrew/bin/uv",
    daemon_dir = os.getenv("HOME") .. "/.hammerspoon/stt-daemon",
    -- LLM post-processing (nil api_key = disabled)
    llm_api_key = nil,
    llm_api_url = "https://api.mistral.ai/v1/chat/completions",
    llm_model = "mistral-small-latest",
    llm_system_prompt = "Clean up this speech transcription. Remove filler words (um, uh, like, you know), fix punctuation and capitalization, and apply light grammar fixes. Never use em-dashes, en-dashes, or any similar dash variants; use commas, semicolons, colons, or separate sentences instead. Preserve the original meaning and tone. Return ONLY the cleaned text, nothing else.",
    llm_timeout = 10,
    -- Tones & media control
    play_tones = true,
    pause_media = true,
    media_ctl = "/opt/homebrew/bin/media-control",
    -- History viewer
    history_hotkey = {{"ctrl", "alt"}, "h"},
}

-- History
local HISTORY_DIR = os.getenv("HOME") .. "/Library/Mobile Documents/com~apple~CloudDocs/STT"
local HISTORY_FILE = HISTORY_DIR .. "/history.txt"

-- Overlay
local PILL_WIDTH = 220
local PILL_HEIGHT = 36
local spinnerFrames = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

-- State: "idle" | "starting" | "recording" | "transcribing" | "polishing"
local state = "idle"
local sock = nil
local canvas = nil
local eventTap = nil
local fnShiftHeld = false
local animTimer = nil
local connectTimer = nil
local stopTimeout = nil
local idleTimer = nil
local llmTimer = nil
local daemonTask = nil
local generation = 0
local tones = {}
local mediaWasPlaying = false

-- History viewer state
local historyWebview = nil
local historyHotkey = nil
local historyVisible = false

-- Forward declarations
local showPill, updatePill, hideOverlay
local connectAndStart, retryConnect, sendCommand, handleMessage
local pasteText, cleanup, startDaemon, stopDaemon, resetIdleTimer, postProcessText
local appendHistory, cleanupWav
local playTone, pauseMedia, resumeMedia
local parseHistory, pushHistoryToJS, showHistoryWebview, hideHistoryWebview, toggleHistoryWebview

-- ── Daemon lifecycle ──────────────────────────────────────────────

startDaemon = function()
    if daemonTask and daemonTask:isRunning() then return end
    print("stt: starting daemon")
    daemonTask = hs.task.new(
        config.daemon_cmd,
        function(exitCode, stdout, stderr)
            print("stt: daemon exited (code=" .. tostring(exitCode) .. ")")
            daemonTask = nil
        end,
        function(task, stdout, stderr)
            return true -- discard streaming output
        end,
        {"run", "stt_daemon.py"}
    )
    daemonTask:setWorkingDirectory(config.daemon_dir)
    daemonTask:start()
end

stopDaemon = function()
    if daemonTask and daemonTask:isRunning() then
        print("stt: stopping daemon")
        daemonTask:terminate()
        daemonTask = nil
    end
end

resetIdleTimer = function()
    if idleTimer then idleTimer:stop() end
    idleTimer = hs.timer.doAfter(config.idle_timeout, function()
        idleTimer = nil
        print("stt: idle timeout (" .. config.idle_timeout .. "s), stopping daemon")
        stopDaemon()
    end)
end

-- ── Tones & media control ────────────────────────────────────────

playTone = function(name)
    if not config.play_tones then return end
    local snd = tones[name]
    if snd then
        snd:stop()  -- reset if still playing
        snd:play()
    end
end

pauseMedia = function()
    if not config.pause_media then return end
    local output, ok = hs.execute(config.media_ctl .. " get 2>/dev/null")
    if ok and output and #output > 0 then
        local parsed, info = pcall(hs.json.decode, output)
        if parsed and info and info.playing then
            mediaWasPlaying = true
            hs.execute(config.media_ctl .. " pause")
            print("stt: paused media (" .. (info.title or "unknown") .. ")")
        else
            mediaWasPlaying = false
            print("stt: media not playing, skipping pause")
        end
    else
        mediaWasPlaying = false
        print("stt: media-control not available")
    end
end

resumeMedia = function()
    if not config.pause_media then return end
    if mediaWasPlaying then
        mediaWasPlaying = false
        hs.execute(config.media_ctl .. " play")
        print("stt: resumed media playback")
    end
end

-- ── Commands & messages ───────────────────────────────────────────

sendCommand = function(cmd)
    local connected = sock and sock:connected()
    print("stt: sendCommand('" .. cmd .. "') connected=" .. tostring(connected))
    if connected then
        sock:write(hs.json.encode({cmd = cmd}) .. "\n")
    end

    if cmd == "stop" then
        playTone("stop")
        resumeMedia()
        if stopTimeout then stopTimeout:stop() end
        stopTimeout = hs.timer.doAfter(15, function()
            stopTimeout = nil
            if state ~= "idle" then
                print("stt: stop timeout — forcing cleanup")
                hideOverlay()
                cleanup()
                resetIdleTimer()
            end
        end)
    end
end

pasteText = function(text)
    if not text or #text == 0 then return end
    if config.paste_method == "clipboard" then
        hs.pasteboard.setContents(text)
        hs.eventtap.keyStroke({"cmd"}, "v")
    else
        hs.eventtap.keyStrokes(text)
    end
end

appendHistory = function(rawText, polishedText)
    if not rawText or #rawText == 0 then return end
    local ok, err = pcall(function()
        hs.fs.mkdir(HISTORY_DIR)
        local f = io.open(HISTORY_FILE, "a")
        if not f then
            print("stt: failed to open history file for writing")
            return
        end
        local writeOk, writeErr = pcall(function()
            local timestamp = os.date("!%Y-%m-%dT%H:%M:%S")
            local raw = rawText:gsub("\n", " ")
            f:write("--- " .. timestamp .. " ---\n")
            f:write("RAW: " .. raw .. "\n")
            if polishedText and #polishedText > 0 and polishedText ~= rawText then
                local polished = polishedText:gsub("\n", " ")
                f:write("LLM: " .. polished .. "\n")
            end
            f:write("\n")
        end)
        f:close()
        if not writeOk then error(writeErr) end
        print("stt: appended to history (" .. #rawText .. " chars)")
    end)
    if not ok then
        print("stt: history write error: " .. tostring(err))
    end
end

cleanupWav = function(path)
    if not path then return end
    local ok, err = os.remove(path)
    if ok then
        print("stt: cleaned up WAV: " .. path)
    else
        print("stt: failed to remove WAV: " .. tostring(err))
    end
end

-- ── History viewer ───────────────────────────────────────────────

parseHistory = function()
    local f = io.open(HISTORY_FILE, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end

    local entries = {}
    local current = nil
    for line in content:gmatch("[^\n]+") do
        local ts = line:match("^%-%-%- (.+) %-%-%-$")
        if ts then
            if current then table.insert(entries, current) end
            current = { timestamp = ts, raw = nil, llm = nil }
        elseif current then
            local rawText = line:match("^RAW: (.+)$")
            local llmText = line:match("^LLM: (.+)$")
            if rawText then
                current.raw = rawText
            elseif llmText then
                current.llm = llmText
            end
        end
    end
    if current then table.insert(entries, current) end

    -- Reverse: newest first
    local reversed = {}
    for i = #entries, 1, -1 do
        table.insert(reversed, entries[i])
    end
    return reversed
end

pushHistoryToJS = function()
    if not historyWebview or not historyVisible then return end
    local entries = parseHistory()
    local json = hs.json.encode(entries):gsub("'", "\\'")
    historyWebview:evaluateJavaScript(string.format("if (window.loadEntries) window.loadEntries('%s')", json))
end

showHistoryWebview = function()
    if not historyWebview then
        local usercontent = hs.webview.usercontent.new("sttHistory")
            :setCallback(function(msg)
                if type(msg.body) ~= "table" then return end
                local action = msg.body.action
                if action == "copy" then
                    hs.pasteboard.setContents(msg.body.text)
                elseif action == "close" then
                    hideHistoryWebview()
                end
            end)

        local screen = hs.mouse.getCurrentScreen():frame()
        local width = 720
        local height = 550
        local rect = {
            x = screen.x + (screen.w - width) / 2,
            y = screen.y + (screen.h - height) / 2,
            w = width,
            h = height
        }

        historyWebview = hs.webview.new(rect, { developerExtrasEnabled = false }, usercontent)
            :allowTextEntry(true)
            :windowStyle({"titled", "closable", "resizable"})
            :windowTitle("STT History")
            :closeOnEscape(false)
            :windowCallback(function(action, _wv, _state)
                if action == "closing" then
                    historyVisible = false
                    historyWebview = nil
                end
            end)

        historyWebview:html(htmlLoader.load("stt_history"))
    end

    -- Reposition to cursor's screen each time
    local screen = hs.mouse.getCurrentScreen():frame()
    local width = 720
    local height = 550
    historyWebview:frame({
        x = screen.x + (screen.w - width) / 2,
        y = screen.y + (screen.h - height) / 2,
        w = width,
        h = height
    })

    historyWebview:evaluateJavaScript("if (window.resetUI) window.resetUI()")

    historyWebview:show()
    historyWebview:hswindow():focus()
    historyVisible = true

    pushHistoryToJS()
end

hideHistoryWebview = function()
    if historyWebview and historyVisible then
        historyWebview:hide()
        historyVisible = false
    end
end

toggleHistoryWebview = function()
    if historyVisible then
        hideHistoryWebview()
    else
        showHistoryWebview()
    end
end

-- ── LLM post-processing ─────────────────────────────────────────

postProcessText = function(rawText, callback)
    local payload = hs.json.encode({
        model = config.llm_model,
        messages = {
            {role = "system", content = config.llm_system_prompt},
            {role = "user", content = rawText},
        },
        temperature = 0.1,
    })
    local headers = {
        ["Authorization"] = "Bearer " .. config.llm_api_key,
        ["Content-Type"] = "application/json",
    }

    local timedOut = false
    if llmTimer then llmTimer:stop() end
    llmTimer = hs.timer.doAfter(config.llm_timeout, function()
        llmTimer = nil
        timedOut = true
        print("stt: LLM timeout after " .. config.llm_timeout .. "s, using raw text")
        callback(rawText)
    end)

    hs.http.asyncPost(config.llm_api_url, payload, headers, function(status, body, _)
        if timedOut then return end
        if llmTimer then llmTimer:stop(); llmTimer = nil end

        if status ~= 200 then
            print("stt: LLM API error (status=" .. tostring(status) .. "), using raw text")
            callback(rawText)
            return
        end

        local ok, resp = pcall(hs.json.decode, body)
        if not ok or not resp or not resp.choices or #resp.choices == 0 then
            print("stt: LLM response parse failed, using raw text")
            callback(rawText)
            return
        end

        local content = resp.choices[1].message and resp.choices[1].message.content
        if not content or #content == 0 then
            print("stt: LLM returned empty content, using raw text")
            callback(rawText)
            return
        end

        content = content:match("^%s*(.-)%s*$")
        print("stt: LLM polished (" .. #rawText .. " -> " .. #content .. " chars)")
        callback(content)
    end)
end

cleanup = function()
    print("stt: cleanup()")
    if sock then pcall(function() sock:disconnect() end); sock = nil end
    if connectTimer then connectTimer:stop(); connectTimer = nil end
    if stopTimeout then stopTimeout:stop(); stopTimeout = nil end
    if llmTimer then llmTimer:stop(); llmTimer = nil end
    mediaWasPlaying = false
    state = "idle"
end

handleMessage = function(data)
    if not data then return end
    data = data:gsub("%s+$", "")
    print("stt: recv: " .. data:sub(1, 200))
    local ok, msg = pcall(hs.json.decode, data)
    if not ok or not msg then print("stt: JSON decode failed"); return end

    if msg.type == "ready" then
        if connectTimer then connectTimer:stop(); connectTimer = nil end
        if state == "starting" then
            state = "recording"
            updatePill("recording")
            playTone("start")
            pauseMedia()
        end
        sendCommand("start")

    elseif msg.type == "transcribing" then
        state = "transcribing"
        updatePill("transcribing")

    elseif msg.type == "final" then
        if stopTimeout then stopTimeout:stop(); stopTimeout = nil end
        local wavPath = msg.wav_path
        if config.llm_api_key and #config.llm_api_key > 0 and msg.text and #msg.text > 0 then
            state = "polishing"
            updatePill("polishing")
            local gen = generation
            local rawText = msg.text
            postProcessText(msg.text, function(text)
                if state ~= "polishing" or generation ~= gen then
                    cleanupWav(wavPath)
                    return
                end
                playTone("done")
                hideOverlay()
                pasteText(text)
                appendHistory(rawText, text)
                cleanupWav(wavPath)
                cleanup()
                resetIdleTimer()
            end)
        else
            playTone("done")
            hideOverlay()
            pasteText(msg.text)
            appendHistory(msg.text, nil)
            cleanupWav(wavPath)
            cleanup()
            resetIdleTimer()
        end

    elseif msg.type == "error" then
        if stopTimeout then stopTimeout:stop(); stopTimeout = nil end
        hs.alert.show("STT: " .. (msg.message or "unknown error"))
        if msg.wav_path then
            print("stt: WAV preserved for debugging: " .. msg.wav_path)
        end
        resumeMedia()
        hideOverlay()
        cleanup()
        resetIdleTimer()
    end
end

-- ── Overlay ───────────────────────────────────────────────────────

showPill = function(pillState)
    if canvas then canvas:delete(); canvas = nil end
    if animTimer then animTimer:stop(); animTimer = nil end

    local screen = hs.screen.mainScreen()
    local sf = screen:frame()
    local w, h = PILL_WIDTH, PILL_HEIGHT
    local x = sf.x + (sf.w - w) / 2
    local y = sf.y + sf.h - h - 40
    local ty = (h - 18) / 2

    canvas = hs.canvas.new({x = x, y = y, w = w, h = h})
    canvas:appendElements(
        -- [1] Background pill
        {type = "rectangle", fillColor = {hex = "#1a1a2e", alpha = 0.9},
         roundedRectRadii = {xRadius = h / 2, yRadius = h / 2}, action = "fill"},
        -- [2] Status indicator
        {type = "text", frame = {x = 14, y = ty, w = 18, h = 18}, text = ""},
        -- [3] Status text
        {type = "text", frame = {x = 34, y = ty, w = w - 74, h = 18}, text = ""},
        -- [4] Stop button
        {type = "text", frame = {x = w - 36, y = (h - 24) / 2, w = 28, h = 24},
         text = hs.styledtext.new("×", {
             font = {name = ".AppleSystemUIFont", size = 20},
             color = {white = 0.6},
             paragraphStyle = {alignment = "center"},
         })}
    )
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior({"canJoinAllSpaces", "stationary"})

    canvas:mouseCallback(function(c, cbMsg, id, mx, my)
        if cbMsg == "mouseDown" and mx > w - 36 then
            print("stt: stop button clicked, state=" .. state)
            if state == "recording" or state == "transcribing" then
                sendCommand("stop")
            elseif state == "polishing" then
                resumeMedia()
                hideOverlay()
                cleanup()
                resetIdleTimer()
            elseif state == "starting" then
                hideOverlay()
                cleanup()
            end
        end
    end)
    canvas:canvasMouseEvents(true, false, false, false)

    canvas:show()
    updatePill(pillState)
end

updatePill = function(pillState)
    if not canvas then return end
    if animTimer then animTimer:stop(); animTimer = nil end

    if pillState == "starting" then
        canvas[2].text = hs.styledtext.new(spinnerFrames[1], {
            font = {name = "Menlo", size = 14},
            color = {white = 0.7},
            paragraphStyle = {alignment = "center"},
        })
        canvas[3].text = hs.styledtext.new("Loading model…", {
            font = {name = ".AppleSystemUIFont", size = 14},
            color = {white = 0.7},
        })
        local idx = 1
        animTimer = hs.timer.doEvery(0.08, function()
            if not canvas then return end
            idx = (idx % #spinnerFrames) + 1
            canvas[2].text = hs.styledtext.new(spinnerFrames[idx], {
                font = {name = "Menlo", size = 14},
                color = {white = 0.7},
                paragraphStyle = {alignment = "center"},
            })
        end)

    elseif pillState == "recording" then
        canvas[2].text = hs.styledtext.new("●", {
            font = {name = ".AppleSystemUIFont", size = 12},
            color = {red = 1},
            paragraphStyle = {alignment = "center"},
        })
        canvas[3].text = hs.styledtext.new("Recording…", {
            font = {name = ".AppleSystemUIFont", size = 14},
            color = {white = 1},
        })
        local dotVisible = true
        animTimer = hs.timer.doEvery(0.6, function()
            if not canvas then return end
            dotVisible = not dotVisible
            canvas[2].text = hs.styledtext.new("●", {
                font = {name = ".AppleSystemUIFont", size = 12},
                color = {red = 1, alpha = dotVisible and 1 or 0.2},
                paragraphStyle = {alignment = "center"},
            })
        end)

    elseif pillState == "transcribing" then
        canvas[2].text = hs.styledtext.new(spinnerFrames[1], {
            font = {name = "Menlo", size = 14},
            color = {white = 0.7},
            paragraphStyle = {alignment = "center"},
        })
        canvas[3].text = hs.styledtext.new("Transcribing…", {
            font = {name = ".AppleSystemUIFont", size = 14},
            color = {white = 0.7},
        })
        local idx = 1
        animTimer = hs.timer.doEvery(0.08, function()
            if not canvas then return end
            idx = (idx % #spinnerFrames) + 1
            canvas[2].text = hs.styledtext.new(spinnerFrames[idx], {
                font = {name = "Menlo", size = 14},
                color = {white = 0.7},
                paragraphStyle = {alignment = "center"},
            })
        end)

    elseif pillState == "polishing" then
        canvas[2].text = hs.styledtext.new(spinnerFrames[1], {
            font = {name = "Menlo", size = 14},
            color = {hex = "#a78bfa"},
            paragraphStyle = {alignment = "center"},
        })
        canvas[3].text = hs.styledtext.new("Polishing…", {
            font = {name = ".AppleSystemUIFont", size = 14},
            color = {hex = "#a78bfa"},
        })
        local idx = 1
        animTimer = hs.timer.doEvery(0.08, function()
            if not canvas then return end
            idx = (idx % #spinnerFrames) + 1
            canvas[2].text = hs.styledtext.new(spinnerFrames[idx], {
                font = {name = "Menlo", size = 14},
                color = {hex = "#a78bfa"},
                paragraphStyle = {alignment = "center"},
            })
        end)
    end
end

hideOverlay = function()
    if animTimer then animTimer:stop(); animTimer = nil end
    if canvas then canvas:delete(); canvas = nil end
end

-- ── Connection ────────────────────────────────────────────────────

local function makeSocketCallback()
    return function(data, tag)
        handleMessage(data)
        if sock and sock:connected() then
            sock:read("\n")
        end
    end
end

retryConnect = function(attempt)
    if state ~= "starting" then return end
    if attempt > 60 then
        hs.alert.show("STT: daemon failed to start")
        resumeMedia()
        hideOverlay()
        cleanup()
        return
    end

    if sock then pcall(function() sock:disconnect() end) end
    sock = hs.socket.new(makeSocketCallback())
    sock:connect(config.host, config.port)
    sock:read("\n")

    connectTimer = hs.timer.doAfter(1, function()
        connectTimer = nil
        retryConnect(attempt + 1)
    end)
end

connectAndStart = function()
    print("stt: connectAndStart()")
    generation = generation + 1

    if idleTimer then idleTimer:stop(); idleTimer = nil end
    if sock then pcall(function() sock:disconnect() end); sock = nil end

    -- Daemon not running → start it and poll until ready
    if not daemonTask or not daemonTask:isRunning() then
        startDaemon()
        state = "starting"
        showPill("starting")
        retryConnect(0)
        return
    end

    -- Daemon running → connect directly
    sock = hs.socket.new(makeSocketCallback())
    sock:connect(config.host, config.port)
    sock:read("\n")

    state = "recording"
    showPill("recording")
    playTone("start")
    pauseMedia()

    -- If daemon is alive but not responding, restart it
    connectTimer = hs.timer.doAfter(2, function()
        connectTimer = nil
        if state == "recording" then
            print("stt: daemon not responding, restarting")
            resumeMedia()
            stopDaemon()
            startDaemon()
            state = "starting"
            updatePill("starting")
            retryConnect(0)
        end
    end)
end

-- ── Hotkeys (via eventtap for fn combinations) ────────────────────

local function toggleRecording()
    print("stt: toggle state=" .. state)
    if state == "idle" then
        connectAndStart()
    elseif state == "recording" then
        sendCommand("stop")
    elseif state == "starting" then
        hideOverlay()
        cleanup()
    end
end

-- ── Public API ────────────────────────────────────────────────────

function M.init(cfg)
    cfg = cfg or {}
    for k, v in pairs(cfg) do config[k] = v end

    -- Pre-load notification tones
    if config.play_tones then
        tones.start = hs.sound.getByName("Tink")
        tones.stop  = hs.sound.getByName("Pop")
        tones.done  = hs.sound.getByName("Glass")
        for _, snd in pairs(tones) do
            if snd then snd:volume(0.5) end
        end
    end

    -- fn+space: toggle dictation
    -- fn+shift: hold-to-talk (hold both to record, release either to stop)
    fnShiftHeld = false
    eventTap = hs.eventtap.new(
        {hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged},
        function(event)
            local evType = event:getType()
            local flags = event:getFlags()

            -- fn+space → toggle
            if evType == hs.eventtap.event.types.keyDown then
                if flags.fn and not flags.cmd and not flags.alt and not flags.ctrl
                   and event:getKeyCode() == hs.keycodes.map["space"] then
                    print("stt: fn+space pressed")
                    toggleRecording()
                    return true -- consume the event
                end
            end

            -- fn+shift → hold-to-talk
            if evType == hs.eventtap.event.types.flagsChanged then
                local bothHeld = flags.fn and flags.shift
                                 and not flags.cmd and not flags.alt and not flags.ctrl
                if bothHeld and not fnShiftHeld then
                    fnShiftHeld = true
                    print("stt: fn+shift held, state=" .. state)
                    if state == "idle" then connectAndStart() end
                elseif not bothHeld and fnShiftHeld then
                    fnShiftHeld = false
                    print("stt: fn+shift released, state=" .. state)
                    if state == "recording" then sendCommand("stop") end
                end
            end

            return false
        end
    )
    eventTap:start()

    historyHotkey = hs.hotkey.bind(config.history_hotkey[1], config.history_hotkey[2], toggleHistoryWebview)

    print("STT loaded (toggle: fn+Space, hold: fn+Shift, history: Ctrl+Alt+H)")
    return M
end

function M.showHistory()
    showHistoryWebview()
end

function M.stop()
    if state ~= "idle" then sendCommand("stop") end
    hideOverlay()
    cleanup()
    stopDaemon()
    if eventTap then eventTap:stop(); eventTap = nil end
    if idleTimer then idleTimer:stop(); idleTimer = nil end
    if historyWebview then historyWebview:delete(); historyWebview = nil end
    if historyHotkey then historyHotkey:delete(); historyHotkey = nil end
    historyVisible = false
    print("STT stopped")
end

return M
