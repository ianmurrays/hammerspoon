-- Hyperduck URL Opener for Hammerspoon
-- Monitors an iCloud file for URLs and opens them in the default browser
--
-- Setup:
-- 1. Create an iPhone Shortcut that appends timestamped URLs to:
--    ~/Library/Mobile Documents/com~apple~CloudDocs/Hyperduck/inbox.txt
--    Format: timestamp|url (e.g., 1736172000|https://example.com)
-- 2. This module monitors that file and opens new URLs automatically
-- 3. URLs older than purgeAfterDays (default 7) are automatically removed

local M = {}

-- Private state
local config = {}
local paths = {}
local pathWatcher = nil
local pollTimer = nil
local debounceTimer = nil
local recentUrls = {}
local machineId = ""
local updateCallback = nil

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
		processed = base .. "processed-" .. machineId .. ".txt",
	}
end

-- Ensure directory exists
local function ensureDirectory()
	hs.fs.mkdir(paths.base)
end

-- Parse timestamp|url format, returns {timestamp, url} or nil
local function parseEntry(line)
	local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then
		return nil
	end

	local timestamp, url = trimmed:match("^(%d+)|(.+)$")
	if timestamp and url then
		return { timestamp = tonumber(timestamp), url = url }
	end

	-- Backward compat: plain URL without timestamp (treat as old)
	if trimmed:match("^https?://") or trimmed:match("^file://") then
		return { timestamp = 0, url = trimmed }
	end

	return nil
end

-- Read file into array of {timestamp, url} entries
local function readEntries(filePath)
	local entries = {}
	local f = io.open(filePath, "r")
	if not f then
		return entries
	end

	for line in f:lines() do
		local entry = parseEntry(line)
		if entry then
			table.insert(entries, entry)
		end
	end
	f:close()
	return entries
end

-- Append timestamped entry to file
local function appendEntry(filePath, url)
	ensureDirectory()
	local f = io.open(filePath, "a")
	if not f then
		print("Hyperduck: Failed to open file for writing: " .. filePath)
		return false
	end
	local timestamp = os.time()
	f:write(timestamp .. "|" .. url .. "\n")
	f:close()
	return true
end

-- Purge entries older than maxAgeDays from file
local function purgeOldEntries(filePath, maxAgeDays)
	local entries = readEntries(filePath)
	if #entries == 0 then
		return
	end

	local cutoff = os.time() - (maxAgeDays * 24 * 60 * 60)
	local kept = {}
	local purged = 0

	for _, entry in ipairs(entries) do
		if entry.timestamp >= cutoff then
			table.insert(kept, entry)
		else
			purged = purged + 1
		end
	end

	if purged > 0 then
		local f = io.open(filePath, "w")
		if f then
			for _, entry in ipairs(kept) do
				f:write(entry.timestamp .. "|" .. entry.url .. "\n")
			end
			f:close()
			print("Hyperduck: Purged " .. purged .. " old entries from " .. filePath)
		end
	end
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

-- Notify unified menu of changes
local function notifyUpdate()
	if updateCallback then
		updateCallback()
	end
end

-- Purge old entries from both files
local function purgeFiles()
	local maxAgeDays = config.purgeAfterDays or 7
	purgeOldEntries(paths.inbox, maxAgeDays)
	purgeOldEntries(paths.processed, maxAgeDays)
end

-- Process inbox and open new URLs
local function processInbox()
	-- Purge old entries first
	purgeFiles()

	local inboxEntries = readEntries(paths.inbox)
	local processedEntries = readEntries(paths.processed)

	-- Create lookup table for processed URLs (by URL, ignoring timestamp)
	local processed = {}
	for _, entry in ipairs(processedEntries) do
		processed[entry.url] = true
	end

	-- Find and open new URLs
	local newCount = 0
	for _, entry in ipairs(inboxEntries) do
		if not processed[entry.url] then
			if isValidUrl(entry.url) then
				print("Hyperduck: Opening " .. entry.url)
				hs.urlevent.openURL(entry.url)
				appendEntry(paths.processed, entry.url)
				addToRecent(entry.url)

				hs.notify
					.new({
						title = "Hyperduck",
						informativeText = entry.url,
						withdrawAfter = 3,
					})
					:send()

				newCount = newCount + 1
			else
				print("Hyperduck: Skipping invalid URL: " .. entry.url)
				-- Still mark as processed to avoid repeated warnings
				appendEntry(paths.processed, entry.url)
			end
		end
	end

	if newCount > 0 then
		notifyUpdate()
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
	print("Hyperduck: Purging entries older than " .. (config.purgeAfterDays or 7) .. " days")

	-- Ensure directory and inbox file exist
	ensureDirectory()
	local f = io.open(paths.inbox, "a")
	if f then
		f:close()
	end

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

	recentUrls = {}
	updateCallback = nil
	print("Hyperduck stopped")
end

-- Functions for unified menu integration

function M.getMenuItems()
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
				fn = function()
					hs.urlevent.openURL(url)
				end,
			})
		end
		table.insert(menu, { title = "-" })
	end

	table.insert(menu, {
		title = "Open Hyperduck Folder",
		fn = function()
			hs.open(paths.base)
		end,
	})

	return menu
end

function M.setUpdateCallback(fn)
	updateCallback = fn
end

return M
