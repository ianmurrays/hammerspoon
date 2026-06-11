-- Mouse Grid: keyboard-driven mouse control (Mouseless-style)
-- Tap left Cmd alone to show a full-screen hint grid. Type a cell's two
-- characters, then a subgrid key (or Space for cell center) to click there.
-- Modifiers on the final key: Shift = right click, Ctrl = double click,
-- Alt = move only, Cmd = arm drag (next selection drops). Backspace undoes
-- one level, Tab moves to the next screen, "," enters scroll mode, Esc exits.
-- Tap left Alt alone for free mode: i/j/k/l move the cursor smoothly
-- (Shift = fast, Ctrl = slow), Space clicks (Shift = right, Ctrl = double,
-- Cmd = drag toggle), m/,/.// scroll, Esc or idle timeout exits.

local M = {}

local etypes = hs.eventtap.event.types
local eprops = hs.eventtap.event.properties
local kmap = hs.keycodes.map

local KEYCODE_LEFT_CMD = 55
local KEYCODE_LEFT_ALT = 58
local MAGIC = 0x4D475244 -- tags self-synthesized events so taps ignore them

-- Config defaults (overridden via M.init(cfg))
local config = {
    firstChars = "abcdefghijklmnopqrstuvwxyz",   -- rows (a-z, top to bottom)
    secondChars = "qwertasdfgzxcvb",             -- columns (keyboard rows, left to right)
    subgridKeys = { "qwert", "asdfg", "zxcvb" }, -- 5x3 subgrid, spatial layout
    tapTimeout = 0.25,   -- max seconds for a modifier tap to trigger
    scrollKey = ",",
    scrollStep = 40,     -- pixels per scroll keypress (Shift = x5)
    dragSteps = 5,       -- interpolation steps for drag movement
    freeSpeed = 600,         -- free mode cursor speed, px/sec
    freeFastMultiplier = 4,  -- free mode speed with Shift held
    freeSlowMultiplier = 0.25, -- free mode speed with Ctrl held
    freeIdleTimeout = 10,    -- seconds of inactivity before free mode exits
    colors = {
        background = { red = 0, green = 0, blue = 0, alpha = 0.18 },
        gridLine = { white = 1, alpha = 0.25 },
        label = { white = 1, alpha = 0.85 },
        rowHighlight = { red = 1, green = 0.8, blue = 0.2, alpha = 0.25 },
        subBackground = { red = 0.1, green = 0.1, blue = 0.15, alpha = 0.3 },
        subLabel = { red = 1, green = 0.85, blue = 0.3, alpha = 1 },
        badge = { red = 1, green = 0.3, blue = 0.3, alpha = 0.9 },
    },
}

-- Private state
local activationTap = nil
local modalTap = nil
local gridCanvas = nil   -- currently shown grid canvas (owned by canvasCache)
local focusCanvas = nil  -- per-keystroke feedback canvas
local canvasCache = {}   -- screen id -> { frame, canvas }
local screenWatcher = nil
local currentScreen = nil
local mode = "idle"      -- idle | first | second | sub | scroll | free
local selRow, selCol = nil, nil
local dragOrigin = nil   -- global point while a grid drag is armed
local tapPending = nil   -- { kc, downAt } while a tap-candidate modifier is held

-- Free mode state
local freeTap = nil
local freeCanvas = nil       -- badge canvas while free mode is active
local freeHeld = {}          -- set: movement key char -> true
local freeButtonHeld = false -- left button held by free-mode drag toggle
local freeMoveTimer, freeIdleTimer = nil, nil
local freeLastTick = 0
local freeRemX, freeRemY = 0, 0 -- fractional pixel remainders
local freeBadgeScreenId = nil

-- Forward declarations (must precede every function that references them)
local cellRect, cellCenter, subCellPoint, buildGridElements, getGridCanvas
local postMouse, postClick, doClick, armDrag, finishDrag, cancelDrag
local enterScrollMode, exitScrollMode, handleScrollKey, postScroll
local pointOnScreen, clampToScreens, freeMoveTick, startFreeMove, stopFreeMove
local updateFreeBadge, resetFreeIdle, toggleFreeDrag
local enterFreeMode, exitFreeMode, toggleFreeMode
local freeKeyImpl, handleFreeKey
local performAction, drawFocus, addBadge, showOnScreen, moveToNextScreen
local showOverlay, hideOverlay, toggleOverlay
local modalKeyImpl, handleModalKey, onlyFlag, handleActivationEvent

-- Tap-to-activate specs: actions are closures so the forward-declared
-- locals resolve at call time, not at table construction
local tapSpecs = {
    [KEYCODE_LEFT_CMD] = { flag = "cmd", action = function() toggleOverlay() end },
    [KEYCODE_LEFT_ALT] = { flag = "alt", action = function() toggleFreeMode() end },
}

-- Geometry: cell rects are in canvas-local coordinates; click points are
-- global (fullFrame offset applied), so they land correctly on any monitor.

cellRect = function(row, col)
    local f = currentScreen:fullFrame()
    local cw = f.w / #config.secondChars
    local ch = f.h / #config.firstChars
    return { x = (col - 1) * cw, y = (row - 1) * ch, w = cw, h = ch }
end

cellCenter = function(row, col)
    local f = currentScreen:fullFrame()
    local r = cellRect(row, col)
    return { x = f.x + r.x + r.w / 2, y = f.y + r.y + r.h / 2 }
end

subCellPoint = function(row, col, sr, sc)
    local f = currentScreen:fullFrame()
    local r = cellRect(row, col)
    local sw = r.w / #config.subgridKeys[1]
    local sh = r.h / #config.subgridKeys
    return {
        x = f.x + r.x + (sc - 0.5) * sw,
        y = f.y + r.y + (sr - 0.5) * sh,
    }
end

buildGridElements = function(frame)
    local rows, cols = #config.firstChars, #config.secondChars
    local cw, ch = frame.w / cols, frame.h / rows
    local elems = {}

    elems[#elems + 1] = {
        type = "rectangle", action = "fill",
        fillColor = config.colors.background,
        frame = { x = 0, y = 0, w = frame.w, h = frame.h },
    }
    for c = 1, cols - 1 do
        elems[#elems + 1] = {
            type = "segments", action = "stroke",
            strokeColor = config.colors.gridLine, strokeWidth = 0.5,
            coordinates = { { x = c * cw, y = 0 }, { x = c * cw, y = frame.h } },
        }
    end
    for r = 1, rows - 1 do
        elems[#elems + 1] = {
            type = "segments", action = "stroke",
            strokeColor = config.colors.gridLine, strokeWidth = 0.5,
            coordinates = { { x = 0, y = r * ch }, { x = frame.w, y = r * ch } },
        }
    end

    local fs = math.max(9, math.min(ch * 0.4, cw * 0.55))
    for r = 1, rows do
        for c = 1, cols do
            elems[#elems + 1] = {
                type = "text",
                text = config.firstChars:sub(r, r) .. config.secondChars:sub(c, c),
                textSize = fs, textFont = "Menlo",
                textColor = config.colors.label, textAlignment = "center",
                frame = {
                    x = (c - 1) * cw,
                    y = (r - 1) * ch + (ch - fs * 1.25) / 2,
                    w = cw, h = fs * 1.5,
                },
            }
        end
    end
    return elems
end

getGridCanvas = function(screen)
    local id = tostring(screen:id())
    local f = screen:fullFrame()
    local cached = canvasCache[id]
    if cached and cached.frame.x == f.x and cached.frame.y == f.y
        and cached.frame.w == f.w and cached.frame.h == f.h then
        return cached.canvas
    end
    if cached then cached.canvas:delete() end

    local canvas = hs.canvas.new(f)
    canvas:level(hs.canvas.windowLevels.screenSaver)
    canvas:behavior({ "canJoinAllSpaces", "stationary" })
    -- Single bulk install: never append elements one by one (slow with ~270)
    canvas:appendElements(table.unpack(buildGridElements(f)))
    canvasCache[id] = { frame = { x = f.x, y = f.y, w = f.w, h = f.h }, canvas = canvas }
    print("mouse_grid: built grid canvas for screen " .. id)
    return canvas
end

-- Mouse event synthesis

postMouse = function(evType, point, clickState)
    local ev = hs.eventtap.event.newMouseEvent(evType, point)
    -- Clear flags so a still-held Shift/Ctrl/Cmd from the final keystroke
    -- doesn't turn this into a modified click
    ev:setFlags({})
    ev:setProperty(eprops.eventSourceUserData, MAGIC)
    if clickState then ev:setProperty(eprops.mouseEventClickState, clickState) end
    ev:post()
end

postClick = function(point, kind)
    if kind == "right" then
        postMouse(etypes.rightMouseDown, point)
        postMouse(etypes.rightMouseUp, point)
    elseif kind == "double" then
        postMouse(etypes.leftMouseDown, point, 1)
        postMouse(etypes.leftMouseUp, point, 1)
        postMouse(etypes.leftMouseDown, point, 2)
        postMouse(etypes.leftMouseUp, point, 2)
    else
        postMouse(etypes.leftMouseDown, point, 1)
        postMouse(etypes.leftMouseUp, point, 1)
    end
    print(string.format("mouse_grid: %s click at %.0f,%.0f", kind, point.x, point.y))
end

doClick = function(point, kind)
    hideOverlay()
    -- Small delay so the overlay is gone before the click lands
    hs.timer.doAfter(0.05, function()
        hs.mouse.absolutePosition(point)
        postClick(point, kind)
    end)
end

armDrag = function(point)
    hs.mouse.absolutePosition(point)
    postMouse(etypes.leftMouseDown, point, 1)
    dragOrigin = point
    selRow, selCol = nil, nil
    mode = "first"
    drawFocus()
    print(string.format("mouse_grid: drag armed at %.0f,%.0f", point.x, point.y))
end

finishDrag = function(point)
    local origin = dragOrigin
    dragOrigin = nil
    hideOverlay()
    hs.timer.doAfter(0.05, function()
        for i = 1, config.dragSteps do
            local t = i / config.dragSteps
            local p = {
                x = origin.x + (point.x - origin.x) * t,
                y = origin.y + (point.y - origin.y) * t,
            }
            hs.mouse.absolutePosition(p)
            postMouse(etypes.leftMouseDragged, p)
            hs.timer.usleep(20000)
        end
        postMouse(etypes.leftMouseUp, point, 1)
        print(string.format("mouse_grid: dropped at %.0f,%.0f", point.x, point.y))
    end)
end

cancelDrag = function()
    if not dragOrigin then return end
    postMouse(etypes.leftMouseUp, dragOrigin, 1)
    dragOrigin = nil
    print("mouse_grid: drag cancelled")
end

-- Scroll mode

enterScrollMode = function()
    mode = "scroll"
    if gridCanvas then gridCanvas:hide() end
    drawFocus()
end

exitScrollMode = function()
    mode = "first"
    if gridCanvas then
        gridCanvas:show()
        if focusCanvas then focusCanvas:orderAbove(gridCanvas) end
    end
    drawFocus()
end

postScroll = function(h, v)
    local ev = hs.eventtap.event.newScrollEvent({ h, v }, {}, "pixel")
    ev:setProperty(eprops.eventSourceUserData, MAGIC)
    ev:post()
end

handleScrollKey = function(ch, kc, flags)
    local step = config.scrollStep * (flags.shift and 5 or 1)
    local h, v = 0, 0
    if ch == "j" or kc == kmap.down then v = -step
    elseif ch == "k" or kc == kmap.up then v = step
    elseif ch == "h" or kc == kmap.left then h = step
    elseif ch == "l" or kc == kmap.right then h = -step
    else return end
    postScroll(h, v)
end

-- Free mode: relative cursor movement, no overlay

local FREE_MOVE = { i = true, j = true, k = true, l = true }
-- Scroll keys matched by physical keycode (the four keys right of N), so
-- they work on any layout: "m,./" on US, "m,.-" on Spanish ISO, etc.
local FREE_SCROLL_KEYCODES = { 46, 43, 47, 44 } -- up, down, left, right
local FREE_SCROLL = {
    [46] = { 0, 1 }, [43] = { 0, -1 }, [47] = { 1, 0 }, [44] = { -1, 0 },
}
local FREE_DRAG_TIPS = "FREE · DRAG · ijkl move · Space drops · Esc cancels"

local function freeTipsLabel()
    local keys = ""
    for _, kc in ipairs(FREE_SCROLL_KEYCODES) do
        local ch = kmap[kc]
        keys = keys .. ((type(ch) == "string" and #ch == 1) and ch or "?")
    end
    return "FREE · ijkl move (⇧ fast ⌃ slow) · Space click (⇧ right ⌃ dbl ⌘ drag) · "
        .. keys .. " scroll · Esc"
end

pointOnScreen = function(x, y)
    for _, s in ipairs(hs.screen.allScreens()) do
        local f = s:fullFrame()
        if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then
            return s
        end
    end
    return nil
end

clampToScreens = function(nx, ny, ox, oy)
    -- Accept the new point if it's on some screen; otherwise slide along
    -- edges (x-only / y-only) so L-shaped layouts don't trap the cursor
    local s = pointOnScreen(nx, ny)
    if s then return nx, ny, s end
    s = pointOnScreen(nx, oy)
    if s then return nx, oy, s end
    s = pointOnScreen(ox, ny)
    if s then return ox, ny, s end
    return ox, oy, pointOnScreen(ox, oy)
end

freeMoveTick = function()
    local now = hs.timer.secondsSinceEpoch()
    local dt = math.min(now - freeLastTick, 0.05) -- clamp stalls
    freeLastTick = now

    local dx = (freeHeld.l and 1 or 0) - (freeHeld.j and 1 or 0)
    local dy = (freeHeld.k and 1 or 0) - (freeHeld.i and 1 or 0)
    if dx == 0 and dy == 0 then return end
    if dx ~= 0 and dy ~= 0 then dx, dy = dx * 0.7071, dy * 0.7071 end

    local mods = hs.eventtap.checkKeyboardModifiers()
    local mult = (mods.shift and config.freeFastMultiplier)
        or (mods.ctrl and config.freeSlowMultiplier) or 1

    -- Re-read each tick: drag events or the user may have moved the cursor
    local pos = hs.mouse.absolutePosition()
    local fx = dx * config.freeSpeed * mult * dt + freeRemX
    local fy = dy * config.freeSpeed * mult * dt + freeRemY
    local ix = fx >= 0 and math.floor(fx) or math.ceil(fx)
    local iy = fy >= 0 and math.floor(fy) or math.ceil(fy)
    freeRemX, freeRemY = fx - ix, fy - iy

    local nx, ny, scr = clampToScreens(pos.x + ix, pos.y + iy, pos.x, pos.y)
    local p = { x = nx, y = ny }
    hs.mouse.absolutePosition(p)
    if freeButtonHeld then postMouse(etypes.leftMouseDragged, p) end
    if scr and scr:id() ~= freeBadgeScreenId then updateFreeBadge() end
    resetFreeIdle() -- holding a movement key counts as activity
end

startFreeMove = function()
    if freeMoveTimer then return end
    freeLastTick = hs.timer.secondsSinceEpoch()
    freeRemX, freeRemY = 0, 0
    freeMoveTimer = hs.timer.doEvery(1 / 60, freeMoveTick)
end

stopFreeMove = function()
    if freeMoveTimer then freeMoveTimer:stop(); freeMoveTimer = nil end
end

updateFreeBadge = function()
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    freeBadgeScreenId = scr:id()
    local f = scr:fullFrame()
    local label = freeButtonHeld and FREE_DRAG_TIPS or freeTipsLabel()
    local w = math.min(f.w - 40, 34 + utf8.len(label) * 8.7)
    local h = 38
    if freeCanvas then freeCanvas:delete() end
    freeCanvas = hs.canvas.new({ x = f.x + (f.w - w) / 2, y = f.y + f.h - 76, w = w, h = h })
    freeCanvas:level(hs.canvas.windowLevels.screenSaver)
    freeCanvas:behavior({ "canJoinAllSpaces", "stationary" })
    freeCanvas:appendElements(
        {
            type = "rectangle", action = "fill",
            fillColor = { red = 0.06, green = 0.06, blue = 0.1, alpha = 0.9 },
            roundedRectRadii = { xRadius = 8, yRadius = 8 },
            frame = { x = 0, y = 0, w = w, h = h },
        },
        {
            type = "text", text = label, textSize = 15,
            textColor = { white = 1, alpha = 0.95 }, textAlignment = "center",
            frame = { x = 0, y = 9, w = w, h = 22 },
        }
    )
    freeCanvas:show()
end

resetFreeIdle = function()
    if freeIdleTimer then freeIdleTimer:setNextTrigger(config.freeIdleTimeout) end
end

toggleFreeDrag = function(pos)
    if freeButtonHeld then
        postMouse(etypes.leftMouseUp, pos, 1)
        freeButtonHeld = false
        print("mouse_grid: free drag dropped")
    else
        postMouse(etypes.leftMouseDown, pos, 1)
        freeButtonHeld = true
        print("mouse_grid: free drag started")
    end
    updateFreeBadge()
end

enterFreeMode = function()
    mode = "free"
    freeHeld = {}
    freeButtonHeld = false
    freeRemX, freeRemY = 0, 0
    freeTap:start()
    updateFreeBadge()
    freeIdleTimer = hs.timer.doAfter(config.freeIdleTimeout, function()
        print("mouse_grid: free mode idle timeout")
        exitFreeMode()
    end)
    print("mouse_grid: free mode on")
end

exitFreeMode = function()
    if freeButtonHeld then -- never leave the system with a stuck button
        postMouse(etypes.leftMouseUp, hs.mouse.absolutePosition(), 1)
        freeButtonHeld = false
    end
    stopFreeMove()
    if freeIdleTimer then freeIdleTimer:stop(); freeIdleTimer = nil end
    if freeTap then freeTap:stop() end
    if freeCanvas then freeCanvas:delete(); freeCanvas = nil end
    freeHeld = {}
    freeBadgeScreenId = nil
    mode = "idle"
    print("mouse_grid: free mode off")
end

toggleFreeMode = function()
    if mode == "free" then
        exitFreeMode()
    elseif mode ~= "idle" then -- grid is up: switch to free mode
        cancelDrag()
        hideOverlay()
        enterFreeMode()
    else
        enterFreeMode()
    end
end

freeKeyImpl = function(ev)
    -- Consumed keys never reach the activation tap, so cancel pending taps
    -- here too (same reason as modalKeyImpl)
    tapPending = nil

    local isDown = ev:getType() == etypes.keyDown
    local kc = ev:getKeyCode()
    local flags = ev:getFlags()
    local ch = kmap[kc]
    if type(ch) ~= "string" or #ch ~= 1 then
        ch = ev:getCharacters(true)
    end
    ch = ch and ch:lower() or ""
    resetFreeIdle()

    if FREE_MOVE[ch] then
        if isDown then
            freeHeld[ch] = true
            startFreeMove()
        else
            freeHeld[ch] = nil
            if not next(freeHeld) then stopFreeMove() end
        end
        return
    end

    if not isDown then return end -- everything below acts on keyDown only
    local repeating = (ev:getProperty(eprops.keyboardEventAutorepeat) or 0) ~= 0

    if kc == kmap.escape then
        if not repeating then exitFreeMode() end
        return
    end

    if kc == kmap.space then
        if repeating then return end -- no machine-gun clicks
        local pos = hs.mouse.absolutePosition()
        if flags.cmd or freeButtonHeld then
            -- Cmd+Space toggles the button; any Space while held drops it
            toggleFreeDrag(pos)
        elseif flags.shift then
            postClick(pos, "right")
        elseif flags.ctrl then
            postClick(pos, "double")
        else
            postClick(pos, "left")
        end
        return
    end

    local sv = FREE_SCROLL[kc] -- keycode-matched: layout-independent
    if sv then -- autorepeat-driven, like grid scroll mode
        local step = config.scrollStep * (flags.shift and 5 or 1)
        postScroll(sv[1] * step, sv[2] * step)
    end
end

handleFreeKey = function(ev)
    local ok, err = pcall(freeKeyImpl, ev)
    if not ok then
        -- A live error here would leave the tap consuming the keyboard
        print("mouse_grid: error in free key handler: " .. tostring(err))
        pcall(exitFreeMode)
    end
    return true -- consume everything while free mode is active
end

-- Action dispatch: modifiers are read from the final keystroke only

performAction = function(point, flags)
    if dragOrigin then
        finishDrag(point)
    elseif flags.cmd then
        armDrag(point)
    elseif flags.alt then
        hideOverlay()
        hs.timer.doAfter(0.05, function() hs.mouse.absolutePosition(point) end)
        print(string.format("mouse_grid: moved to %.0f,%.0f", point.x, point.y))
    elseif flags.shift then
        doClick(point, "right")
    elseif flags.ctrl then
        doClick(point, "double")
    else
        doClick(point, "left")
    end
end

-- Focus canvas: all per-keystroke visual feedback lives here so the big
-- grid canvas is never mutated while visible

addBadge = function(elems, frame, label)
    local w = math.min(frame.w - 40, 34 + utf8.len(label) * 8.7)
    local h = 38
    local x = (frame.w - w) / 2
    local y = frame.h - 76 -- bottom-center: covers fewer menus/toolbars
    elems[#elems + 1] = {
        type = "rectangle", action = "fill",
        fillColor = { red = 0.06, green = 0.06, blue = 0.1, alpha = 0.9 },
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        frame = { x = x, y = y, w = w, h = h },
    }
    elems[#elems + 1] = {
        type = "text", text = label, textSize = 15,
        textColor = { white = 1, alpha = 0.95 }, textAlignment = "center",
        frame = { x = x, y = y + 9, w = w, h = 22 },
    }
end

-- Context-sensitive key hints, shown in every grid mode
local MODE_TIPS = {
    first = "type 2-char cell · , scroll · Tab screen · Esc close",
    second = "column letter · Bksp back",
    sub = "pick point (qwert/asdfg/zxcvb) · Space center · ⇧ right ⌃ dbl ⌥ move ⌘ drag",
    scroll = "SCROLL · h/j/k/l · ⇧ fast · , or Esc back",
}

drawFocus = function()
    if not focusCanvas then return end
    local f = currentScreen:fullFrame()
    local elems = {}

    if dragOrigin then
        local ox, oy = dragOrigin.x - f.x, dragOrigin.y - f.y
        elems[#elems + 1] = {
            type = "circle", action = "stroke",
            strokeColor = config.colors.badge, strokeWidth = 2,
            center = { x = ox, y = oy }, radius = 8,
        }
        elems[#elems + 1] = {
            type = "circle", action = "fill",
            fillColor = config.colors.badge,
            center = { x = ox, y = oy }, radius = 2.5,
        }
    end

    if mode == "second" and selRow then
        local ch = f.h / #config.firstChars
        elems[#elems + 1] = {
            type = "rectangle", action = "fill",
            fillColor = config.colors.rowHighlight,
            frame = { x = 0, y = (selRow - 1) * ch, w = f.w, h = ch },
        }
    elseif mode == "sub" and selRow and selCol then
        local r = cellRect(selRow, selCol)
        local sgRows = #config.subgridKeys
        local sgCols = #config.subgridKeys[1]
        local zx, zy, zw, zh = r.x, r.y, r.w, r.h

        elems[#elems + 1] = {
            type = "rectangle", action = "fill",
            fillColor = config.colors.subBackground,
            frame = { x = zx, y = zy, w = zw, h = zh },
        }
        elems[#elems + 1] = {
            type = "rectangle", action = "stroke",
            strokeColor = config.colors.subLabel, strokeWidth = 1.5,
            frame = r,
        }
        for c = 1, sgCols - 1 do
            elems[#elems + 1] = {
                type = "segments", action = "stroke",
                strokeColor = config.colors.gridLine, strokeWidth = 0.5,
                coordinates = {
                    { x = zx + c * zw / sgCols, y = zy },
                    { x = zx + c * zw / sgCols, y = zy + zh },
                },
            }
        end
        for sr = 1, sgRows - 1 do
            elems[#elems + 1] = {
                type = "segments", action = "stroke",
                strokeColor = config.colors.gridLine, strokeWidth = 0.5,
                coordinates = {
                    { x = zx, y = zy + sr * zh / sgRows },
                    { x = zx + zw, y = zy + sr * zh / sgRows },
                },
            }
        end
        local scw, sch = zw / sgCols, zh / sgRows
        local fs = math.max(7, math.min(sch * 0.55, scw * 0.7))
        for sr = 1, sgRows do
            local rowKeys = config.subgridKeys[sr]
            for sc = 1, #rowKeys do
                elems[#elems + 1] = {
                    type = "text", text = rowKeys:sub(sc, sc),
                    textSize = fs, textFont = "Menlo",
                    textColor = config.colors.subLabel, textAlignment = "center",
                    frame = {
                        x = zx + (sc - 1) * scw,
                        y = zy + (sr - 1) * sch + (sch - fs * 1.25) / 2,
                        w = scw, h = fs * 1.5,
                    },
                }
            end
        end
    end

    local tips = MODE_TIPS[mode]
    if tips then
        addBadge(elems, f, (dragOrigin and "DRAG · " or "") .. tips)
    end

    if #elems == 0 then
        elems[1] = { type = "rectangle", action = "skip", frame = { x = 0, y = 0, w = 1, h = 1 } }
    end
    focusCanvas:replaceElements(table.unpack(elems))
end

-- Overlay lifecycle

showOnScreen = function(screen)
    currentScreen = screen
    local f = screen:fullFrame()
    gridCanvas = getGridCanvas(screen)
    gridCanvas:show()
    focusCanvas = hs.canvas.new(f)
    focusCanvas:level(hs.canvas.windowLevels.screenSaver)
    focusCanvas:behavior({ "canJoinAllSpaces", "stationary" })
    focusCanvas:show()
    focusCanvas:orderAbove(gridCanvas)
    selRow, selCol = nil, nil
    mode = "first"
    drawFocus()
end

moveToNextScreen = function()
    if not currentScreen then return end
    local nxt = currentScreen:next()
    if not nxt or nxt:id() == currentScreen:id() then return end
    if gridCanvas then gridCanvas:hide(); gridCanvas = nil end
    if focusCanvas then focusCanvas:delete(); focusCanvas = nil end
    showOnScreen(nxt)
    print("mouse_grid: moved overlay to " .. (currentScreen:name() or "next screen"))
end

showOverlay = function(screen)
    showOnScreen(screen or hs.mouse.getCurrentScreen() or hs.screen.mainScreen())
    modalTap:start()
    print("mouse_grid: overlay shown on " .. (currentScreen:name() or "screen"))
end

hideOverlay = function()
    if modalTap then modalTap:stop() end
    if gridCanvas then gridCanvas:hide(); gridCanvas = nil end -- cached, not deleted
    if focusCanvas then focusCanvas:delete(); focusCanvas = nil end
    mode = "idle"
    selRow, selCol = nil, nil
    print("mouse_grid: overlay hidden")
end

toggleOverlay = function()
    if mode == "free" then -- switch free -> grid
        exitFreeMode()
        showOverlay(hs.mouse.getCurrentScreen())
    elseif mode ~= "idle" then
        cancelDrag()
        hideOverlay()
    else
        showOverlay(hs.mouse.getCurrentScreen())
    end
end

-- Modal key handling (consumes every keyDown while the overlay is up)

modalKeyImpl = function(ev)
    -- This tap consumes keyDowns before the activation tap can see them, so
    -- cancel a pending tap here too — otherwise Cmd+finalKey (arm drag)
    -- ends with the Cmd release reading as a tap and toggling the overlay off
    tapPending = nil

    local kc = ev:getKeyCode()
    local flags = ev:getFlags()
    -- Resolve the key from its keycode (modifier-independent): character
    -- translation is unreliable while Cmd/Ctrl are held, which would break
    -- modifier actions on the final key
    local ch = kmap[kc]
    if type(ch) ~= "string" or #ch ~= 1 then
        ch = ev:getCharacters(true)
    end
    ch = ch and ch:lower() or ""

    if mode == "scroll" then
        if kc == kmap.escape or ch == config.scrollKey then
            exitScrollMode()
        else
            handleScrollKey(ch, kc, flags)
        end
        return
    end

    if kc == kmap.escape then
        cancelDrag()
        hideOverlay()
        return
    end

    if kc == kmap.tab then
        moveToNextScreen()
        return
    end

    if kc == kmap.delete then -- Backspace: pop one selection level
        if mode == "sub" then
            mode = "second"
            drawFocus()
        elseif mode == "second" then
            selRow = nil
            mode = "first"
            drawFocus()
        end
        return
    end

    if mode == "sub" and kc == kmap.space then
        performAction(cellCenter(selRow, selCol), flags)
        return
    end

    if ch == "" then return end

    if mode == "first" then
        if ch == config.scrollKey then
            enterScrollMode()
            return
        end
        local i = config.firstChars:find(ch, 1, true)
        if i then
            selRow = i
            mode = "second"
            drawFocus()
        end
    elseif mode == "second" then
        local i = config.secondChars:find(ch, 1, true)
        if i then
            selCol = i
            mode = "sub"
            drawFocus()
        end
    elseif mode == "sub" then
        for sr, rowKeys in ipairs(config.subgridKeys) do
            local sc = rowKeys:find(ch, 1, true)
            if sc then
                performAction(subCellPoint(selRow, selCol, sr, sc), flags)
                return
            end
        end
        print(string.format("mouse_grid: unmatched subgrid key ch=%q kc=%d", ch, kc))
    end
end

handleModalKey = function(ev)
    local ok, err = pcall(modalKeyImpl, ev)
    if not ok then
        -- A live error here would leave the tap consuming the keyboard
        print("mouse_grid: error in key handler: " .. tostring(err))
        pcall(cancelDrag)
        pcall(hideOverlay)
    end
    return true
end

-- Activation: quick tap of left Cmd (grid) or left Alt (free mode) alone —
-- press+release under tapTimeout, cancelled by any other key, modifier,
-- click, or scroll while the candidate key is down

onlyFlag = function(flags, want)
    for _, f in ipairs({ "cmd", "alt", "shift", "ctrl", "fn" }) do
        if f ~= want and flags[f] then return false end
    end
    return flags[want] == true
end

handleActivationEvent = function(ev)
    if ev:getProperty(eprops.eventSourceUserData) == MAGIC then return false end

    if ev:getType() == etypes.flagsChanged then
        local kc = ev:getKeyCode()
        local spec = tapSpecs[kc]
        if spec then
            local flags = ev:getFlags()
            if onlyFlag(flags, spec.flag) then -- candidate pressed, alone
                tapPending = { kc = kc, downAt = hs.timer.secondsSinceEpoch() }
            elseif not flags[spec.flag] then -- candidate released
                if tapPending and tapPending.kc == kc
                    and (hs.timer.secondsSinceEpoch() - tapPending.downAt) < config.tapTimeout then
                    local ok, err = pcall(spec.action)
                    if not ok then print("mouse_grid: toggle error: " .. tostring(err)) end
                end
                tapPending = nil
            else
                tapPending = nil -- another modifier joined while held
            end
        else
            tapPending = nil -- right Cmd / Shift / fn etc. changed
        end
    else
        tapPending = nil -- keyDown, mouse button, or scroll while held
    end
    return false -- never consume; coexists with stt's eventtap
end

-- Public API

function M.init(cfg)
    cfg = cfg or {}
    for k, v in pairs(cfg) do config[k] = v end

    local sgCols = #config.subgridKeys[1]
    for _, rowKeys in ipairs(config.subgridKeys) do
        if #rowKeys ~= sgCols then
            print("mouse_grid: warning - subgridKeys rows have unequal lengths")
            break
        end
    end
    if config.firstChars:find(config.scrollKey, 1, true)
        or config.secondChars:find(config.scrollKey, 1, true) then
        print("mouse_grid: warning - scrollKey '" .. config.scrollKey
            .. "' collides with hint alphabets")
    end

    modalTap = hs.eventtap.new({ etypes.keyDown }, handleModalKey)
    freeTap = hs.eventtap.new({ etypes.keyDown, etypes.keyUp }, handleFreeKey)
    activationTap = hs.eventtap.new({
        etypes.flagsChanged, etypes.keyDown,
        etypes.leftMouseDown, etypes.rightMouseDown, etypes.otherMouseDown,
        etypes.scrollWheel,
    }, handleActivationEvent)
    activationTap:start()

    screenWatcher = hs.screen.watcher.new(function()
        print("mouse_grid: screen layout changed, flushing canvas cache")
        if mode == "free" then
            exitFreeMode()
        elseif mode ~= "idle" then
            cancelDrag()
            hideOverlay()
        end
        for _, entry in pairs(canvasCache) do entry.canvas:delete() end
        canvasCache = {}
    end)
    screenWatcher:start()

    print("Mouse Grid loaded (tap left Cmd for grid, left Alt for free mode)")
    return M
end

function M.stop()
    if mode == "free" then exitFreeMode() end
    cancelDrag()
    if mode ~= "idle" then hideOverlay() end
    if activationTap then activationTap:stop(); activationTap = nil end
    if modalTap then modalTap:stop(); modalTap = nil end
    if freeTap then freeTap:stop(); freeTap = nil end
    if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
    for _, entry in pairs(canvasCache) do entry.canvas:delete() end
    canvasCache = {}
    print("Mouse Grid stopped")
end

return M
