-- Slack Status Updater Module for Hammerspoon
-- Automatically updates your Slack status based on WiFi network

local M = {}
local htmlLoader = require("html_loader")
local panel = require("panel")

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
local applyManualStatus, clearStatus

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getExpirationTimestamp(minutes)
    -- Round up to the next 5-minute boundary so Slack shows a clean expiry time
    local ts = os.time() + (minutes * 60)
    local interval = 5 * 60
    return ts + (interval - ts % interval) % interval
end

local function cancelPendingWifiUpdate()
    if wifiChangeTimer then
        wifiChangeTimer:stop()
        wifiChangeTimer = nil
        print("Cancelled pending WiFi update")
    end
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

local EXPIRY_LABELS = { ["30"] = "30 min", ["60"] = "1 hour", ["120"] = "2 hours", ["240"] = "4 hours",
    eod = "End of day", ["0"] = "Don't clear" }

local function buildCustomStatusHTML()
    local presets = {}
    for i, status in ipairs(config.manualStatuses) do
        table.insert(presets, {
            index = i,
            emoji = status.name:match("^(.-) ") or "💬",
            text = status.text,
            expiry = status.useEndOfDay and EXPIRY_LABELS.eod or EXPIRY_LABELS["0"],
        })
    end
    -- "</" must become "<\/" so preset text can't terminate the inlined script block
    local json = hs.json.encode(presets):gsub("</", "<\\/")
    return htmlLoader.load("slack_status", { ["{{PRESETS}}"] = json })
end

-- Height of the palette before JS measures itself: search row, preset rows, emoji section, footer
local PALETTE_WIDTH = 600
local function paletteHeight()
    return 56 + 41 + #config.manualStatuses * 37 + 8 + 104 + 38
end

local function closeCustomStatusForm(restoreFocus)
    local wv = customStatusWebview
    if not wv then return end
    customStatusWebview = nil
    panel.hide(wv, restoreFocus)
    wv:delete()
end

local function showCustomStatusForm()
    closeCustomStatusForm(false)

    local uc = hs.webview.usercontent.new("customStatus")
    uc:setCallback(function(msg)
        local body = msg.body
        if type(body) ~= "table" then return end
        if body.action == "submit" then
            local expiration = 0
            if body.expiration == "eod" then
                expiration = getEndOfDayTimestamp()
            elseif tonumber(body.expiration) and tonumber(body.expiration) > 0 then
                expiration = getExpirationTimestamp(tonumber(body.expiration))
            end
            cancelPendingWifiUpdate()
            updateSlackStatus(body.text, body.emoji, expiration, true, "✏️")
            closeCustomStatusForm(true)
        elseif body.action == "preset" then
            local status = config.manualStatuses[tonumber(body.index)]
            if status then applyManualStatus(status) end
            closeCustomStatusForm(true)
        elseif body.action == "clear" then
            clearStatus()
            closeCustomStatusForm(true)
        elseif body.action == "resize" then
            local wv = customStatusWebview
            local h = tonumber(body.height)
            if wv and h then
                local f = wv:frame()
                wv:frame({ x = f.x, y = f.y, w = f.w, h = math.ceil(h) + 2 * panel.MARGIN })
            end
        elseif body.action == "cancel" then
            closeCustomStatusForm(true)
        end
    end)

    local h = paletteHeight()
    customStatusWebview = panel.new(PALETTE_WIDTH, h, uc, function() closeCustomStatusForm(false) end)
    customStatusWebview:html(buildCustomStatusHTML())
    panel.show(customStatusWebview, PALETTE_WIDTH, h)
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

applyManualStatus = function(status)
    local expiration = status.useEndOfDay and getEndOfDayTimestamp() or 0
    -- Extract emoji from name (everything before first space)
    local menuEmoji = status.name:match("^(.-) ") or "💬"
    cancelPendingWifiUpdate()
    updateSlackStatus(status.text, status.emoji, expiration, true, menuEmoji)
end

clearStatus = function()
    print("Clearing Slack status")
    manualStatusActive = false
    stopStatusRefreshTimer()
    cancelPendingWifiUpdate()
    updateSlackStatus("", "", 0, false, "💬")
end

local function buildMenu()
    local menuItems = {}

    -- Add manual status options
    for _, status in ipairs(config.manualStatuses) do
        table.insert(menuItems, {
            title = status.name,
            fn = function() applyManualStatus(status) end
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
        fn = function() clearStatus() end
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
    cancelPendingWifiUpdate()

    local currentNetwork = hs.wifi.currentNetwork()

    if currentNetwork then
        print("WiFi changed to: " .. currentNetwork)

        local status = config.statusMap[currentNetwork]
        if status then
            print("Scheduling Slack status update in " .. config.wifiChangeDelay .. "s: " .. status.text)

            -- Delay the update to allow network connectivity to stabilize
            wifiChangeTimer = hs.timer.doAfter(config.wifiChangeDelay, function()
                wifiChangeTimer = nil
                -- A manual status may have been set while we were waiting
                if manualStatusActive then
                    print("Manual status set during delay, skipping WiFi-based update")
                    return
                end
                local expiration = getExpirationTimestamp(15)
                print("Updating Slack status: " .. status.text .. " (expires in 15 min)")
                updateSlackStatus(status.text, status.emoji, expiration, false, status.menuEmoji)
                startStatusRefreshTimer()
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
    closeCustomStatusForm(false)

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
