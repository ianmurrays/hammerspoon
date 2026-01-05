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
local statusMenu = nil
local wifiWatcher = nil

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
-- FORWARD DECLARATIONS
-- ============================================

local updateMenuBar
local wifiChanged
local startStatusRefreshTimer
local stopStatusRefreshTimer

-- ============================================
-- SLACK API FUNCTIONS
-- ============================================

local function updateSlackStatus(statusText, statusEmoji, expiration, isManual, menuEmoji, retryCount, silent)
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
    if statusMenu then
        statusMenu:setTitle(currentStatusEmoji)
        statusMenu:setMenu(buildMenu)
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

    -- Set up menu bar
    statusMenu = hs.menubar.new()
    updateMenuBar()

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

    -- Remove menu bar
    if statusMenu then
        statusMenu:delete()
        statusMenu = nil
    end

    print("Slack Status Updater stopped")
end

return M
