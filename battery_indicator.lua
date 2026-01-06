-- Battery Time Indicator Module for Hammerspoon
-- Shows remaining battery time in the menu bar

local M = {}

-- Private state
local menubarItem = nil
local updateTimer = nil
local config = {}

-- Format minutes into H:MM string
local function formatTime(minutes)
    if type(minutes) ~= "number" or minutes < 0 then
        return "--:--"
    end
    local hours = math.floor(minutes / 60)
    local mins = math.floor(minutes % 60)
    return string.format("%d:%02d", hours, mins)
end

-- Get the display text for the menu bar
local function getDisplayText()
    local isCharging = hs.battery.isCharging()
    local isCharged = hs.battery.isCharged()
    local percentage = hs.battery.percentage()

    -- Fully charged
    if isCharged then
        return "Full"
    end

    -- Charging: show time to full
    if isCharging then
        local timeToFull = hs.battery.timeToFullCharge()
        return formatTime(timeToFull)
    end

    -- Discharging: show time remaining
    local timeRemaining = hs.battery.timeRemaining()
    -- timeRemaining returns -2 when on AC power (not charging, not discharging)
    if timeRemaining == -2 then
        return "AC"
    end
    return formatTime(timeRemaining)
end

-- Build the dropdown menu with detailed stats
local function buildMenu()
    -- Also refresh the title when menu is opened
    if menubarItem then
        menubarItem:setTitle(getDisplayText())
    end

    local percentage = hs.battery.percentage()
    local isCharging = hs.battery.isCharging()
    local isCharged = hs.battery.isCharged()
    local powerSource = hs.battery.powerSource()
    local cycles = hs.battery.cycles()
    local amperage = hs.battery.amperage()
    local maxCapacity = hs.battery.maxCapacity()
    local designCapacity = hs.battery.designCapacity()
    local healthPercent = (maxCapacity and designCapacity and designCapacity > 0)
        and math.floor((maxCapacity / designCapacity) * 100) or nil

    -- Determine power state text
    local powerState
    if isCharged then
        powerState = "Charged"
    elseif isCharging then
        powerState = "Charging"
    elseif powerSource == "AC Power" then
        powerState = "On AC (Not Charging)"
    else
        powerState = "On Battery"
    end

    -- Format amperage (negative = discharging)
    local amperageText = amperage and string.format("%d mA", amperage) or "N/A"

    local menuItems = {
        { title = string.format("%.0f%%", percentage or 0), disabled = true },
        { title = powerState, disabled = true },
        { title = "-" },
        { title = string.format("Amperage: %s", amperageText), disabled = true },
        { title = string.format("Health: %s", healthPercent and (healthPercent .. "%") or "N/A"), disabled = true },
        { title = string.format("Cycles: %s", cycles or "N/A"), disabled = true },
    }

    return menuItems
end

-- Update the menu bar display
local function updateMenuBar()
    if menubarItem then
        menubarItem:setTitle(getDisplayText())
    end
end

-- Public API

function M.init(cfg)
    config.refreshInterval = cfg.refreshInterval or 60

    -- Create menu bar item
    menubarItem = hs.menubar.new()
    menubarItem:setMenu(buildMenu)

    -- Initial update
    updateMenuBar()

    -- Start periodic updates
    updateTimer = hs.timer.doEvery(config.refreshInterval, updateMenuBar)

    print("Battery Indicator loaded (updates every " .. config.refreshInterval .. "s)")
    return M
end

function M.stop()
    if updateTimer then
        updateTimer:stop()
        updateTimer = nil
    end
    if menubarItem then
        menubarItem:delete()
        menubarItem = nil
    end
    print("Battery Indicator stopped")
end

return M
