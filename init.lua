-- Hammerspoon Configuration

local slackStatus = require("slack_status")
local scratchpad = require("scratchpad")

-- Read Slack token from macOS Keychain
-- One-time setup: security add-generic-password -a "$USER" -s "slack-status-token" -w "xoxp-your-token-here"
local function getKeychainPassword(service, account)
    local output, status = hs.execute(string.format(
        '/usr/bin/security find-generic-password -s "%s" -a "%s" -w 2>/dev/null',
        service, account
    ))
    if status and output then
        return output:gsub("%s+$", "") -- trim trailing whitespace
    end
    return nil
end

local slackToken = getKeychainPassword("slack-status-token", os.getenv("USER"))

if not slackToken then
    hs.alert.show("Slack token not found in Keychain! Add it with:\nsecurity add-generic-password -a \"$USER\" -s \"slack-status-token\" -w \"your-token\"")
end

slackStatus.init({
    token = slackToken,

    -- WiFi network to status mapping
    statusMap = {
        ["M-Net"] = {
            text = "Working from home",
            emoji = ":house:",
            menuEmoji = "🏠",
        },
        ["POP2"] = {
            text = "In the office",
            emoji = ":office:",
            menuEmoji = "🏢",
        },
        ["Serpens"] = {
            text = "On the go",
            emoji = ":iphone:",
            menuEmoji = "📱",
        }
    },

    -- Manual status options (shown in menu bar)
    manualStatuses = {
        {
            name = "🏠 Working from home",
            text = "Working from home",
            emoji = ":house:",
            useEndOfDay = true
        },
        {
            name = "🏢 In the office",
            text = "In the office",
            emoji = ":office:",
            useEndOfDay = true
        },
        {
            name = "📱 On the go",
            text = "On the go",
            emoji = ":iphone:",
            useEndOfDay = true
        },
        {
            name = "🤒 Sick",
            text = "Sick",
            emoji = ":face_with_thermometer:",
            useEndOfDay = true
        },
        {
            name = "👨 Sick child",
            text = "Sick child",
            emoji = ":child:",
            useEndOfDay = true
        }
    },

    -- Default status when not on a recognized network
    defaultStatus = {
        text = "",
        emoji = "",
        expiration = 0
    },

    -- Set to true to NOT clear your status when WiFi is not detected or on unknown networks
    -- Set to false to clear status on unknown networks
    preserveStatusOnUnknown = true,

    -- Resilience configuration
    wifiChangeDelay = 3,   -- Seconds to wait after WiFi change before updating
    maxRetries = 3,        -- Maximum number of retry attempts for failed HTTP requests
    retryBaseDelay = 2,    -- Base delay in seconds for exponential backoff (2s, 4s, 8s)

    -- Auto-refresh configuration (status expires after this interval, then gets refreshed)
    refreshInterval = 5 * 60 - 10,  -- 5 minutes - 10 seconds in seconds, so we refresh before the status expires
})

-- Initialize Scratchpad (Ctrl+Option+S to toggle)
scratchpad.init({})
