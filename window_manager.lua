-- Window Manager Module for Hammerspoon
-- Rectangle-style window management with keyboard shortcuts
-- Supports cycling through 1/2 → 1/3 → 2/3 fractions

local M = {}

-- Private state
local hotkeys = {}
local cycleState = {}  -- { [windowId] = { action = "left", index = 1 } }
local fractions = {1/2, 1/3, 2/3}

-- Get focused window, skip fullscreen
local function getFocusedWindow()
    local win = hs.window.focusedWindow()
    if not win or win:isFullScreen() then
        return nil
    end
    return win
end

-- Set window frame with instant snapping
local function setFrame(win, frame)
    local prevDuration = hs.window.animationDuration
    hs.window.animationDuration = 0
    win:setFrame(frame)
    hs.window.animationDuration = prevDuration
end

-- Get next cycle index for a window/action combination
local function getNextCycleIndex(windowId, action)
    local state = cycleState[windowId]
    if state and state.action == action then
        -- Same action on same window, advance cycle
        local nextIndex = (state.index % #fractions) + 1
        cycleState[windowId] = { action = action, index = nextIndex }
        return nextIndex
    else
        -- Different action or window, start at 1
        cycleState[windowId] = { action = action, index = 1 }
        return 1
    end
end

-- Position window with cycling support
local function positionWindow(action)
    local win = getFocusedWindow()
    if not win then return end

    local windowId = win:id()
    local screenFrame = win:screen():frame()
    local cycleIndex = getNextCycleIndex(windowId, action)
    local fraction = fractions[cycleIndex]

    local frame
    if action == "left" then
        frame = {
            x = screenFrame.x,
            y = screenFrame.y,
            w = screenFrame.w * fraction,
            h = screenFrame.h
        }
    elseif action == "right" then
        frame = {
            x = screenFrame.x + screenFrame.w * (1 - fraction),
            y = screenFrame.y,
            w = screenFrame.w * fraction,
            h = screenFrame.h
        }
    elseif action == "top" then
        frame = {
            x = screenFrame.x,
            y = screenFrame.y,
            w = screenFrame.w,
            h = screenFrame.h * fraction
        }
    elseif action == "bottom" then
        frame = {
            x = screenFrame.x,
            y = screenFrame.y + screenFrame.h * (1 - fraction),
            w = screenFrame.w,
            h = screenFrame.h * fraction
        }
    end

    setFrame(win, frame)
end

-- Non-cycling position functions

local function maximize()
    local win = getFocusedWindow()
    if not win then return end

    local screenFrame = win:screen():frame()
    setFrame(win, screenFrame)
    -- Clear cycle state for this window
    cycleState[win:id()] = nil
end

local function nextDisplay()
    local win = getFocusedWindow()
    if not win then return end

    local currentScreen = win:screen()
    local currentFrame = currentScreen:frame()
    local screens = hs.screen.allScreens()

    -- Find the screen to the right (smallest x that is > current x)
    local targetScreen = nil
    local minX = math.huge
    for _, screen in ipairs(screens) do
        local frame = screen:frame()
        if frame.x > currentFrame.x and frame.x < minX then
            minX = frame.x
            targetScreen = screen
        end
    end

    if targetScreen then
        win:moveToScreen(targetScreen, false, true, 0)
    end
end

local function prevDisplay()
    local win = getFocusedWindow()
    if not win then return end

    local currentScreen = win:screen()
    local currentFrame = currentScreen:frame()
    local screens = hs.screen.allScreens()

    -- Find the screen to the left (largest x that is < current x)
    local targetScreen = nil
    local maxX = -math.huge
    for _, screen in ipairs(screens) do
        local frame = screen:frame()
        if frame.x < currentFrame.x and frame.x > maxX then
            maxX = frame.x
            targetScreen = screen
        end
    end

    if targetScreen then
        win:moveToScreen(targetScreen, false, true, 0)
    end
end

-- Public API

function M.init(cfg)
    cfg = cfg or {}

    local mods = {"ctrl", "alt", "cmd"}

    local bindings = {
        { mods, "left",  function() positionWindow("left") end },
        { mods, "right", function() positionWindow("right") end },
        { mods, "up",    function() positionWindow("top") end },
        { mods, "down",  function() positionWindow("bottom") end },
        { mods, "f",     maximize },
        { mods, "end",   nextDisplay },   -- fn+right produces "end"
        { mods, "home",  prevDisplay },   -- fn+left produces "home"
    }

    for _, binding in ipairs(bindings) do
        local hk = hs.hotkey.bind(binding[1], binding[2], binding[3])
        table.insert(hotkeys, hk)
    end

    print("Window Manager loaded (Rectangle-style shortcuts with cycling)")
    return M
end

function M.stop()
    for _, hk in ipairs(hotkeys) do
        hk:delete()
    end
    hotkeys = {}
    cycleState = {}
    print("Window Manager stopped")
end

return M
