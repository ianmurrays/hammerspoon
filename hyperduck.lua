-- Hyperduck URL Opener for Hammerspoon
-- Monitors an iCloud file for URLs and opens them in the default browser
--
-- Setup:
-- 1. Create an iPhone Shortcut that appends URLs to:
--    ~/Library/Mobile Documents/com~apple~CloudDocs/Hyperduck/inbox.txt
-- 2. This module monitors that file and opens new URLs automatically

local M = {}

-- Private state
local config = {}
local paths = {}
local pathWatcher = nil
local pollTimer = nil
local debounceTimer = nil
local menubarItem = nil
local recentUrls = {}
local machineId = ""

-- Get unique machine identifier (computer name + serial)
local function getMachineId()
    local name = hs.host.localizedName() or "Unknown"
    -- Sanitize name: replace spaces and special chars
    name = name:gsub("[^%w%-]", "-")

    local output, status = hs.execute("ioreg -l | grep IOPlatformSerialNumber | awk '{print $4}' | tr -d '\"'")
    local serial = "UNKNOWN"
    if status and output then
        serial = output:gsub("%s+$", "")
    end

    return name .. "-" .. serial
end

-- Get file paths for inbox and processed files
local function getFilePaths()
    local base = os.getenv("HOME") .. "/Library/Mobile Documents/com~apple~CloudDocs/Hyperduck/"
    return {
        base = base,
        inbox = base .. "inbox.txt",
        processed = base .. "processed-" .. machineId .. ".txt"
    }
end

-- Ensure directory exists
local function ensureDirectory()
    hs.fs.mkdir(paths.base)
end

-- Read file into array of lines
local function readLines(filePath)
    local lines = {}
    local f = io.open(filePath, "r")
    if not f then
        return lines
    end

    for line in f:lines() do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            table.insert(lines, trimmed)
        end
    end
    f:close()
    return lines
end

-- Append line to file
local function appendToFile(filePath, line)
    ensureDirectory()
    local f = io.open(filePath, "a")
    if not f then
        print("Hyperduck: Failed to open file for writing: " .. filePath)
        return false
    end
    f:write(line .. "\n")
    f:close()
    return true
end

-- Check if string looks like a URL
local function isValidUrl(str)
    return str:match("^https?://") or str:match("^file://")
end

-- Add URL to recent list (FIFO, max 3)
local function addToRecent(url)
    table.insert(recentUrls, 1, url)
    while #recentUrls > 3 do
        table.remove(recentUrls)
    end
end

-- Update menubar display
local function updateMenuBar()
    if menubarItem then
        menubarItem:setMenu(function()
            local menu = {}

            if #recentUrls > 0 then
                table.insert(menu, { title = "Recent URLs:", disabled = true })
                for _, url in ipairs(recentUrls) do
                    -- Truncate long URLs for display
                    local display = url
                    if #display > 50 then
                        display = display:sub(1, 47) .. "..."
                    end
                    table.insert(menu, {
                        title = display,
                        fn = function() hs.urlevent.openURL(url) end
                    })
                end
                table.insert(menu, { title = "-" })
            end

            table.insert(menu, {
                title = "Open Hyperduck Folder",
                fn = function() hs.open(paths.base) end
            })

            return menu
        end)
    end
end

-- Process inbox and open new URLs
local function processInbox()
    local inboxUrls = readLines(paths.inbox)
    local processedUrls = readLines(paths.processed)

    -- Create lookup table for processed URLs
    local processed = {}
    for _, url in ipairs(processedUrls) do
        processed[url] = true
    end

    -- Find and open new URLs
    local newCount = 0
    for _, url in ipairs(inboxUrls) do
        if not processed[url] then
            if isValidUrl(url) then
                print("Hyperduck: Opening " .. url)
                hs.urlevent.openURL(url)
                appendToFile(paths.processed, url)
                addToRecent(url)

                hs.notify.new({
                    title = "Hyperduck",
                    informativeText = url,
                    withdrawAfter = 3
                }):send()

                newCount = newCount + 1
            else
                print("Hyperduck: Skipping invalid URL: " .. url)
                -- Still mark as processed to avoid repeated warnings
                appendToFile(paths.processed, url)
            end
        end
    end

    if newCount > 0 then
        updateMenuBar()
    end
end

-- Debounced handler for file changes
local function onInboxChanged(changedPaths, flagTables)
    -- Cancel existing debounce timer
    if debounceTimer then
        debounceTimer:stop()
        debounceTimer = nil
    end

    -- Start new debounce timer (1 second)
    debounceTimer = hs.timer.doAfter(1, function()
        debounceTimer = nil
        processInbox()
    end)
end

-- Public API

function M.init(cfg)
    config = cfg or {}

    -- Initialize machine ID and paths
    machineId = getMachineId()
    paths = getFilePaths()

    print("Hyperduck: Machine ID is " .. machineId)
    print("Hyperduck: Monitoring " .. paths.inbox)

    -- Ensure directory and inbox file exist
    ensureDirectory()
    local f = io.open(paths.inbox, "a")
    if f then f:close() end

    -- Create menubar
    menubarItem = hs.menubar.new()
    menubarItem:setTitle("🔗")
    updateMenuBar()

    -- Process any existing URLs on startup
    processInbox()

    -- Start pathwatcher for inbox file
    pathWatcher = hs.pathwatcher.new(paths.inbox, onInboxChanged):start()

    -- Start backup polling timer (5 minutes)
    pollTimer = hs.timer.doEvery(300, processInbox)

    print("Hyperduck loaded")
    return M
end

function M.stop()
    if pathWatcher then
        pathWatcher:stop()
        pathWatcher = nil
    end

    if pollTimer then
        pollTimer:stop()
        pollTimer = nil
    end

    if debounceTimer then
        debounceTimer:stop()
        debounceTimer = nil
    end

    if menubarItem then
        menubarItem:delete()
        menubarItem = nil
    end

    recentUrls = {}
    print("Hyperduck stopped")
end

return M
