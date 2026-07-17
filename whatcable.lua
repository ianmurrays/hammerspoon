-- WhatCable Module for Hammerspoon
-- Shows USB-C/Thunderbolt port and cable data in the menu bar via the whatcable CLI
-- (https://github.com/darrylmorley/whatcable)

local M = {}

local WHATCABLE = "/opt/homebrew/bin/whatcable"

-- Private state
local menubarItem = nil
local refreshTimer = nil
local debounceTimer = nil
local watchers = {}
local runningTask = nil
local cached = nil -- decoded JSON from the last successful run
local lastError = nil
local config = {}

local function portHasWarning(port)
    if port.dataLink and port.dataLink.isWarning then
        return true
    end
    if port.charging and port.charging.isWarning then
        return true
    end
    for _, display in ipairs(port.displays or {}) do
        if display.isWarning then
            return true
        end
    end
    -- Cable trust verdict: tier is "green" / "amber" / "red"
    if port.trust and (port.trust.tier == "amber" or port.trust.tier == "red") then
        return true
    end
    for _, flag in ipairs((port.cable and port.cable.trustFlags) or {}) do
        if flag.severity == "warning" then
            return true
        end
    end
    return false
end

local function updateTitle()
    if not menubarItem then
        return
    end
    local title = "🔌"
    if cached then
        for _, port in ipairs(cached.ports or {}) do
            if port.connectionActive and portHasWarning(port) then
                title = "🔌⚠️"
                break
            end
        end
    end
    menubarItem:setTitle(title)
end

local function refresh()
    if runningTask then
        return
    end
    runningTask = hs.task.new(WHATCABLE, function(exitCode, stdOut, stdErr)
        runningTask = nil
        if exitCode ~= 0 then
            lastError = string.format("whatcable exited with code %d", exitCode)
            updateTitle()
            return
        end
        local ok, data = pcall(hs.json.decode, stdOut)
        if ok and data then
            cached = data
            lastError = nil
        else
            lastError = "Failed to parse whatcable JSON output"
        end
        updateTitle()
    end, { "--json" })
    runningTask:start()
end

-- Debounced refresh for watcher events (PD/link negotiation settles a moment after plug-in)
local function scheduleRefresh()
    if debounceTimer then
        debounceTimer:stop()
    end
    debounceTimer = hs.timer.doAfter(2, refresh)
end

-- Indented, non-clickable detail line
local function detailLine(text)
    return { title = "    " .. text, disabled = true }
end

-- Recursive USB device tree (ports[].devices / otherUSBDevices.devices)
local function appendDeviceTree(items, devices, depth)
    for _, dev in ipairs(devices or {}) do
        -- ponytail: unnamed nodes are hubs in practice (whatcable's own UI shows "Unknown")
        local label = dev.name or "Hub"
        table.insert(items, detailLine(string.rep("    ", depth) .. string.format("%s - %s", label, dev.speed or "?")))
        appendDeviceTree(items, dev.children, depth + 1)
    end
end

local function buildMenu()
    refresh() -- ponytail: menu shows cached data; this run lands by the next open

    if not cached then
        return { { title = lastError or "Loading…", disabled = true } }
    end

    local items = {}

    if lastError then
        table.insert(items, { title = "⚠️ " .. lastError, disabled = true })
        table.insert(items, { title = "-" })
    end

    local adapter = cached.adapter
    if adapter then
        -- name/manufacturer are present mostly on Apple bricks; fall back for third-party chargers
        local label = adapter.name
            or adapter.description
            or (adapter.watts and (adapter.watts .. "W adapter"))
            or "Power adapter"
        table.insert(items, { title = string.format("⚡ %s (%s)", label, adapter.source or "?"), disabled = true })
    end

    for _, port in ipairs(cached.ports or {}) do
        table.insert(items, { title = "-" })
        local portLabel = port.type or port.name or "Port"
        if port.connectionActive then
            local title = string.format("%s — %s", portLabel, port.headline or "")
            if portHasWarning(port) then
                title = "⚠️ " .. title
            end
            table.insert(items, { title = title, disabled = true })
            if port.dataLink and port.dataLink.summary then
                table.insert(items, detailLine(port.dataLink.summary))
            end
            if port.charging and port.charging.summary then
                table.insert(items, detailLine(port.charging.summary))
            end
            local cable = port.cable
            if cable then
                local line = string.format("Cable: %s, %dW", cable.speed or "?", cable.maxWatts or 0)
                local brand = (cable.curatedBrands and cable.curatedBrands[1]) or cable.vendorName
                if brand then
                    line = line .. " (" .. brand .. ")"
                end
                table.insert(items, detailLine(line))
            end
            for _, display in ipairs(port.displays or {}) do
                table.insert(
                    items,
                    detailLine(string.format("%s: %s", display.monitorName or "Display", display.summary or ""))
                )
            end
            appendDeviceTree(items, port.devices, 0)
            if port.bullets and #port.bullets > 0 then
                local details = {}
                for _, bullet in ipairs(port.bullets) do
                    table.insert(details, { title = bullet, disabled = true })
                end
                table.insert(items, { title = "    Details", menu = details })
            end
        else
            table.insert(items, { title = string.format("%s: nothing connected", portLabel), disabled = true })
        end
    end

    -- USB devices behind a Thunderbolt tunnel that match no physical port (docks)
    local other = cached.otherUSBDevices
    if other then
        table.insert(items, { title = "-" })
        local title = "Other USB devices"
        if other.behindPort then
            title = title .. " (behind " .. other.behindPort .. ")"
        end
        table.insert(items, { title = title, disabled = true })
        appendDeviceTree(items, other.devices, 0)
    end

    return items
end

-- Public API

function M.init(cfg)
    config.refreshInterval = cfg.refreshInterval or 60

    if not hs.fs.attributes(WHATCABLE) then
        hs.alert.show("whatcable CLI not found at " .. WHATCABLE)
        return M
    end

    menubarItem = hs.menubar.new()
    menubarItem:setTitle("🔌")
    menubarItem:setMenu(buildMenu)

    watchers.usb = hs.usb.watcher.new(scheduleRefresh):start()
    watchers.battery = hs.battery.watcher.new(scheduleRefresh):start()
    watchers.screen = hs.screen.watcher.new(scheduleRefresh):start()
    refreshTimer = hs.timer.doEvery(config.refreshInterval, refresh)

    refresh()

    print("WhatCable loaded (watchers + " .. config.refreshInterval .. "s fallback refresh)")
    return M
end

function M.stop()
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end
    if debounceTimer then
        debounceTimer:stop()
        debounceTimer = nil
    end
    for name, watcher in pairs(watchers) do
        watcher:stop()
        watchers[name] = nil
    end
    if runningTask then
        runningTask:terminate()
        runningTask = nil
    end
    if menubarItem then
        menubarItem:delete()
        menubarItem = nil
    end
    print("WhatCable stopped")
end

return M
