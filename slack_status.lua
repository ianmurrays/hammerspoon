-- Slack Status Updater Module for Hammerspoon
-- Automatically updates your Slack status based on WiFi network

local M = {}

-- ============================================
-- PRIVATE STATE
-- ============================================

local config = {}
local manualStatusActive = false
local wifiChangeTimer = nil
local statusRefreshTimer = nil
local currentStatusEmoji = "💬"
local wifiWatcher = nil
local updateCallback = nil
local customStatusWebview = nil
local updateSlackStatus

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getExpirationTimestamp(minutes)
    return os.time() + (minutes * 60)
end

local function getEndOfDayTimestamp()
    local now = os.date("*t")
    local endOfDay = os.time({
        year = now.year,
        month = now.month,
        day = now.day,
        hour = 23,
        min = 59,
        sec = 59
    })
    return endOfDay
end

-- ============================================
-- CUSTOM STATUS FORM
-- ============================================

local function buildCustomStatusHTML()
    return [[
<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #212121;
    font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
    color: #e0e0e0;
    padding: 20px;
    height: 100vh;
    display: flex;
    flex-direction: column;
  }
  label {
    font-size: 13px;
    color: #aaa;
    margin-bottom: 4px;
    display: block;
  }
  input, select {
    width: 100%;
    padding: 8px 12px;
    font-size: 14px;
    background: #2c2c2c;
    border: 1px solid #444;
    border-radius: 6px;
    color: #e0e0e0;
    outline: none;
    margin-bottom: 14px;
  }
  input:focus, select:focus { border-color: #6c9bff; }
  input::placeholder { color: #666; }
  select { -webkit-appearance: none; cursor: pointer; }
  .emoji-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-bottom: 12px;
  }
  .emoji-btn {
    width: 34px;
    height: 34px;
    font-size: 20px;
    background: transparent;
    border: 2px solid transparent;
    border-radius: 6px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
  }
  .emoji-btn:hover { background: #3a3a3a; }
  .emoji-btn.selected { background: #4a9eff; border-color: #6c9bff; }
  .custom-code {
    width: 100%;
    padding: 6px 10px;
    font-size: 13px;
    background: #2c2c2c;
    border: 1px solid #444;
    border-radius: 6px;
    color: #e0e0e0;
    outline: none;
    margin-bottom: 14px;
  }
  .custom-code:focus { border-color: #6c9bff; }
  .custom-code::placeholder { color: #666; }
  .buttons {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    margin-top: auto;
    padding-top: 14px;
  }
  .buttons button {
    padding: 8px 20px;
    font-size: 14px;
    border: none;
    border-radius: 6px;
    cursor: pointer;
  }
  .buttons button.cancel {
    background: #444;
    color: #ccc;
  }
  .buttons button.cancel:hover { background: #555; }
  .buttons button.submit {
    background: #4a9eff;
    color: #fff;
  }
  .buttons button.submit:hover { background: #3a8eef; }
</style>
</head>
<body>
  <label>Emoji</label>
  <div class="emoji-grid" id="emojiGrid">
    <button class="emoji-btn selected" data-code=":speech_balloon:" type="button">💬</button>
    <button class="emoji-btn" data-code=":house:" type="button">🏠</button>
    <button class="emoji-btn" data-code=":office:" type="button">🏢</button>
    <button class="emoji-btn" data-code=":coffee:" type="button">☕</button>
    <button class="emoji-btn" data-code=":fork_and_knife:" type="button">🍽️</button>
    <button class="emoji-btn" data-code=":phone:" type="button">📞</button>
    <button class="emoji-btn" data-code=":face_with_thermometer:" type="button">🤒</button>
    <button class="emoji-btn" data-code=":books:" type="button">📚</button>
    <button class="emoji-btn" data-code=":dart:" type="button">🎯</button>
    <button class="emoji-btn" data-code=":briefcase:" type="button">💼</button>
    <button class="emoji-btn" data-code=":airplane:" type="button">✈️</button>
    <button class="emoji-btn" data-code=":beach_with_umbrella:" type="button">🏖️</button>
    <button class="emoji-btn" data-code=":car:" type="button">🚗</button>
    <button class="emoji-btn" data-code=":runner:" type="button">🏃</button>
    <button class="emoji-btn" data-code=":mute:" type="button">🔇</button>
    <button class="emoji-btn" data-code=":calendar:" type="button">📅</button>
    <button class="emoji-btn" data-code=":palm_tree:" type="button">🌴</button>
    <button class="emoji-btn" data-code=":headphones:" type="button">🎧</button>
    <button class="emoji-btn" data-code=":writing_hand:" type="button">✍️</button>
    <button class="emoji-btn" data-code=":microscope:" type="button">🔬</button>
  </div>

  <label>Or enter Slack shortcode</label>
  <input class="custom-code" type="text" id="customCode" placeholder=":custom_emoji:">

  <label>Status text</label>
  <input type="text" id="statusText" placeholder="What's your status?" autofocus>

  <label>Clear after</label>
  <select id="expiration">
    <option value="30">30 minutes</option>
    <option value="60" selected>1 hour</option>
    <option value="120">2 hours</option>
    <option value="240">4 hours</option>
    <option value="eod">End of day</option>
    <option value="0">Don't clear</option>
  </select>

  <div class="buttons">
    <button class="cancel" onclick="doCancel()">Cancel</button>
    <button class="submit" onclick="doSubmit()">Set Status</button>
  </div>

<script>
  var selectedEmoji = ':speech_balloon:';

  document.getElementById('emojiGrid').addEventListener('click', function(e) {
    var btn = e.target.closest('.emoji-btn');
    if (!btn) return;
    document.querySelectorAll('.emoji-btn').forEach(function(b) { b.classList.remove('selected'); });
    btn.classList.add('selected');
    selectedEmoji = btn.getAttribute('data-code');
    document.getElementById('customCode').value = '';
  });

  document.getElementById('customCode').addEventListener('input', function() {
    if (this.value.trim()) {
      document.querySelectorAll('.emoji-btn').forEach(function(b) { b.classList.remove('selected'); });
    }
  });

  function doSubmit() {
    var custom = document.getElementById('customCode').value.trim();
    var emoji = custom || selectedEmoji;
    var text = document.getElementById('statusText').value.trim();
    var exp = document.getElementById('expiration').value;
    window.webkit.messageHandlers.customStatus.postMessage({
      action: 'submit', emoji: emoji, text: text, expiration: exp
    });
  }
  function doCancel() {
    window.webkit.messageHandlers.customStatus.postMessage({ action: 'cancel' });
  }
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') { doCancel(); }
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { doSubmit(); }
  });
</script>
</body>
</html>
]]
end

local function showCustomStatusForm()
    -- Close existing form if open
    if customStatusWebview then
        customStatusWebview:delete()
        customStatusWebview = nil
    end

    local uc = hs.webview.usercontent.new("customStatus")
    uc:setCallback(function(msg)
        local body = msg.body
        if body.action == "submit" then
            local expiration = 0
            if body.expiration == "eod" then
                expiration = getEndOfDayTimestamp()
            elseif tonumber(body.expiration) and tonumber(body.expiration) > 0 then
                expiration = getExpirationTimestamp(tonumber(body.expiration))
            end
            updateSlackStatus(body.text, body.emoji, expiration, true, "✏️")
            if customStatusWebview then
                customStatusWebview:delete()
                customStatusWebview = nil
            end
        elseif body.action == "cancel" then
            if customStatusWebview then
                customStatusWebview:delete()
                customStatusWebview = nil
            end
        end
    end)

    local screen = hs.screen.mainScreen():frame()
    local w, h = 400, 460
    local frame = hs.geometry.rect(
        (screen.w - w) / 2 + screen.x,
        (screen.h - h) / 2 + screen.y,
        w, h
    )

    customStatusWebview = hs.webview.new(frame, { javaScriptEnabled = true }, uc)
    customStatusWebview:windowTitle("Set Custom Status")
    customStatusWebview:allowTextEntry(true)
    customStatusWebview:level(hs.drawing.windowLevels.modalPanel)
    customStatusWebview:windowCallback(function(action, wv)
        if action == "closing" then
            customStatusWebview = nil
        end
    end)
    customStatusWebview:html(buildCustomStatusHTML())
    customStatusWebview:show()
    customStatusWebview:hswindow():focus()
end

-- ============================================
-- FORWARD DECLARATIONS
-- ============================================

local updateMenuBar
local wifiChanged
local startStatusRefreshTimer
local stopStatusRefreshTimer

-- ============================================
-- SLACK API FUNCTIONS
-- ============================================

updateSlackStatus = function(statusText, statusEmoji, expiration, isManual, menuEmoji, retryCount, silent)
    isManual = isManual or false
    menuEmoji = menuEmoji or "💬"
    retryCount = retryCount or 0
    silent = silent or false

    local url = "https://slack.com/api/users.profile.set"

    local profile = {
        status_text = statusText,
        status_emoji = statusEmoji,
        status_expiration = expiration
    }

    local headers = {
        ["Authorization"] = "Bearer " .. config.token,
        ["Content-Type"] = "application/json; charset=utf-8"
    }

    local payload = hs.json.encode({profile = profile})

    hs.http.asyncPost(url, payload, headers, function(status, body, headers)
        if status == 200 then
            local response = hs.json.decode(body)
            if response.ok then
                if isManual then
                    manualStatusActive = true
                    print("Manual status set: '" .. statusText .. "' " .. statusEmoji)
                else
                    print("Auto status updated: '" .. statusText .. "' " .. statusEmoji)
                end
                if retryCount > 0 then
                    print("Success after " .. retryCount .. " retry attempt(s)")
                end

                -- Update menu bar icon to reflect current status
                currentStatusEmoji = menuEmoji
                updateMenuBar()

                if not silent then
                    hs.notify.new({
                        title = "Slack Status Updated",
                        informativeText = statusText,
                        withdrawAfter = 3
                    }):send()
                end
            else
                local errorMsg = response.error or "Unknown error"
                print("Slack API Error: " .. errorMsg)
                hs.notify.new({
                    title = "Slack Update Failed",
                    informativeText = "Error: " .. errorMsg,
                    withdrawAfter = 5
                }):send()
            end
        else
            -- HTTP request failed (network error, timeout, etc.)
            if retryCount < config.maxRetries then
                local nextRetry = retryCount + 1
                local delay = config.retryBaseDelay * (2 ^ retryCount)  -- Exponential backoff
                print("HTTP Error (Status " .. status .. "). Retry " .. nextRetry .. "/" .. config.maxRetries .. " in " .. delay .. "s")

                -- Schedule retry with exponential backoff
                hs.timer.doAfter(delay, function()
                    updateSlackStatus(statusText, statusEmoji, expiration, isManual, menuEmoji, nextRetry, silent)
                end)
            else
                print("HTTP Error when calling Slack API: Status " .. status .. " (max retries exceeded)")
                hs.notify.new({
                    title = "Slack API Error",
                    informativeText = "HTTP Status: " .. status .. " (retries exhausted)",
                    withdrawAfter = 5
                }):send()
            end
        end
    end)
end

-- ============================================
-- STATUS REFRESH TIMER
-- ============================================

stopStatusRefreshTimer = function()
    if statusRefreshTimer then
        statusRefreshTimer:stop()
        statusRefreshTimer = nil
        print("Status refresh timer stopped")
    end
end

startStatusRefreshTimer = function()
    stopStatusRefreshTimer()  -- Clear any existing timer
    statusRefreshTimer = hs.timer.doEvery(config.refreshInterval, function()
        if manualStatusActive then
            print("Manual status active, skipping auto-refresh")
            return
        end

        local currentNetwork = hs.wifi.currentNetwork()
        if currentNetwork then
            local status = config.statusMap[currentNetwork]
            if status then
                local expiration = getExpirationTimestamp(15)
                print("Refreshing status: " .. status.text .. " (expires in 15 min)")
                -- Pass silent=true to suppress notification on refresh
                updateSlackStatus(status.text, status.emoji, expiration, false, status.menuEmoji, nil, true)
            end
        end
    end)
    print("Status refresh timer started (every " .. (config.refreshInterval / 60) .. " min)")
end

-- ============================================
-- MENU BAR
-- ============================================

local function buildMenu()
    local menuItems = {}

    -- Add manual status options
    for _, status in ipairs(config.manualStatuses) do
        table.insert(menuItems, {
            title = status.name,
            fn = function()
                local expiration = status.useEndOfDay and getEndOfDayTimestamp() or 0
                -- Extract emoji from name (everything before first space)
                local menuEmoji = status.name:match("^(.-) ") or "💬"
                updateSlackStatus(status.text, status.emoji, expiration, true, menuEmoji)
            end
        })
    end

    -- Separator
    table.insert(menuItems, { title = "-" })

    -- Custom status option
    table.insert(menuItems, {
        title = "Set Custom Status...",
        fn = function()
            showCustomStatusForm()
        end
    })

    -- Separator
    table.insert(menuItems, { title = "-" })

    -- Clear status option
    table.insert(menuItems, {
        title = "Clear Status",
        fn = function()
            print("Clearing Slack status from menu bar")
            manualStatusActive = false
            stopStatusRefreshTimer()
            updateSlackStatus("", "", 0, false, "💬")
        end
    })

    -- Separator
    table.insert(menuItems, { title = "-" })

    -- Re-enable auto status
    table.insert(menuItems, {
        title = "Resume Auto-Update from WiFi",
        fn = function()
            print("Resuming automatic WiFi-based updates")
            manualStatusActive = false
            wifiChanged() -- Trigger immediate update based on current WiFi
            hs.notify.new({
                title = "Slack Status",
                informativeText = "Automatic WiFi-based updates resumed",
                withdrawAfter = 3
            }):send()
        end
    })

    return menuItems
end

updateMenuBar = function()
    if updateCallback then
        updateCallback()
    end
end

-- ============================================
-- WIFI WATCHER
-- ============================================

wifiChanged = function()
    -- Don't auto-update if manual status is active
    if manualStatusActive then
        print("Manual status active, skipping WiFi-based update")
        return
    end

    -- Cancel any pending WiFi change update (debounce rapid events)
    if wifiChangeTimer then
        wifiChangeTimer:stop()
        print("Cancelled pending WiFi update (debounce)")
    end

    local currentNetwork = hs.wifi.currentNetwork()

    if currentNetwork then
        print("WiFi changed to: " .. currentNetwork)

        local status = config.statusMap[currentNetwork]
        if status then
            print("Scheduling Slack status update in " .. config.wifiChangeDelay .. "s: " .. status.text)

            -- Delay the update to allow network connectivity to stabilize
            wifiChangeTimer = hs.timer.doAfter(config.wifiChangeDelay, function()
                local expiration = getExpirationTimestamp(15)
                print("Updating Slack status: " .. status.text .. " (expires in 15 min)")
                updateSlackStatus(status.text, status.emoji, expiration, false, status.menuEmoji)
                startStatusRefreshTimer()
                wifiChangeTimer = nil
            end)
        else
            print("Network '" .. currentNetwork .. "' not recognized")
            stopStatusRefreshTimer()
            if not config.preserveStatusOnUnknown then
                print("Scheduling status clear in " .. config.wifiChangeDelay .. "s")

                wifiChangeTimer = hs.timer.doAfter(config.wifiChangeDelay, function()
                    print("Clearing status (preserveStatusOnUnknown is false)")
                    updateSlackStatus(config.defaultStatus.text, config.defaultStatus.emoji, config.defaultStatus.expiration, false, "💬")
                    wifiChangeTimer = nil
                end)
            else
                print("Preserving current status (preserveStatusOnUnknown is true)")
            end
        end
    else
        print("No WiFi connection detected")
        stopStatusRefreshTimer()
        if not config.preserveStatusOnUnknown then
            print("Scheduling status clear in " .. config.wifiChangeDelay .. "s")

            wifiChangeTimer = hs.timer.doAfter(config.wifiChangeDelay, function()
                print("Clearing status (preserveStatusOnUnknown is false)")
                updateSlackStatus(config.defaultStatus.text, config.defaultStatus.emoji, config.defaultStatus.expiration, false, "💬")
                wifiChangeTimer = nil
            end)
        else
            print("Preserving current status (preserveStatusOnUnknown is true)")
        end
    end
end

-- ============================================
-- PUBLIC API
-- ============================================

function M.init(cfg)
    -- Store configuration
    config.token = cfg.token
    config.statusMap = cfg.statusMap or {}
    config.manualStatuses = cfg.manualStatuses or {}
    config.defaultStatus = cfg.defaultStatus or { text = "", emoji = "", expiration = 0 }
    config.preserveStatusOnUnknown = cfg.preserveStatusOnUnknown
    if config.preserveStatusOnUnknown == nil then
        config.preserveStatusOnUnknown = true
    end
    config.wifiChangeDelay = cfg.wifiChangeDelay or 3
    config.maxRetries = cfg.maxRetries or 3
    config.retryBaseDelay = cfg.retryBaseDelay or 2
    config.refreshInterval = cfg.refreshInterval or (5 * 60)

    -- Request location permissions if needed (for WiFi access on macOS 14+)
    if hs.location.servicesEnabled() then
        hs.location.start()
        print("Location services started - this enables WiFi detection")
    end

    -- Create and start the WiFi watcher
    wifiWatcher = hs.wifi.watcher.new(wifiChanged)
    wifiWatcher:start()

    -- Update status immediately on init
    wifiChanged()

    print("Slack Status Updater loaded successfully!")
    print("Click the 💬 icon in your menu bar to set manual statuses")

    return M
end

function M.stop()
    -- Stop all timers
    stopStatusRefreshTimer()
    if wifiChangeTimer then
        wifiChangeTimer:stop()
        wifiChangeTimer = nil
    end

    -- Stop WiFi watcher
    if wifiWatcher then
        wifiWatcher:stop()
        wifiWatcher = nil
    end

    -- Close custom status form if open
    if customStatusWebview then
        customStatusWebview:delete()
        customStatusWebview = nil
    end

    updateCallback = nil

    print("Slack Status Updater stopped")
end

-- Functions for unified menu integration

function M.getMenuItems()
    return buildMenu()
end

function M.getCurrentEmoji()
    return currentStatusEmoji
end

function M.setUpdateCallback(fn)
    updateCallback = fn
end

return M
