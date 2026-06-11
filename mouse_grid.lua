-- Mouse Grid: keyboard-driven mouse control (Mouseless-style)
-- Tap left Cmd alone to show a full-screen hint grid. Type a cell's two
-- characters, then a subgrid key (or Space for cell center) to click there.
-- Modifiers on the final key: Shift = right click, Ctrl = double click,
-- Alt = move only, Cmd = arm drag (next selection drops). Backspace undoes
-- one level, Tab moves to the next screen, "," enters scroll mode, Esc exits.

local M = {}

local etypes = hs.eventtap.event.types
local eprops = hs.eventtap.event.properties
local kmap = hs.keycodes.map

local KEYCODE_LEFT_CMD = 55
local MAGIC = 0x4D475244 -- tags self-synthesized events so taps ignore them

-- Config defaults (overridden via M.init(cfg))
local config = {
    firstChars = "asdfghjkl",                    -- rows (home row)
    secondChars = "abcdefghijklmnopqrstuvwxyz",  -- columns
    subgridKeys = { "qwert", "asdfg", "zxcvb" }, -- 5x3 subgrid, spatial layout
    tapTimeout = 0.25,   -- max seconds for a left-Cmd tap to trigger
    scrollKey = ",",
    scrollStep = 40,     -- pixels per scroll keypress (Shift = x5)
    dragSteps = 5,       -- interpolation steps for drag movement
    colors = {
        background = { red = 0, green = 0, blue = 0, alpha = 0.35 },
        gridLine = { white = 1, alpha = 0.25 },
        label = { white = 1, alpha = 0.85 },
        rowHighlight = { red = 1, green = 0.8, blue = 0.2, alpha = 0.25 },
        subBackground = { red = 0.1, green = 0.1, blue = 0.15, alpha = 0.95 },
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
local mode = "idle"      -- idle | first | second | sub | scroll
local selRow, selCol = nil, nil
local dragOrigin = nil   -- global point while a drag is armed
local cmdPending, cmdDownAt = false, 0

-- Forward declarations (must precede every function that references them)
local cellRect, cellCenter, subCellPoint, buildGridElements, getGridCanvas
local postMouse, doClick, armDrag, finishDrag, cancelDrag
local enterScrollMode, exitScrollMode, handleScrollKey
local performAction, drawFocus, addBadge, showOnScreen, moveToNextScreen
local showOverlay, hideOverlay, toggleOverlay
local modalKeyImpl, handleModalKey, handleActivationEvent

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

doClick = function(point, kind)
    hideOverlay()
    -- Small delay so the overlay is gone before the click lands
    hs.timer.doAfter(0.05, function()
        hs.mouse.absolutePosition(point)
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

handleScrollKey = function(ch, kc, flags)
    local step = config.scrollStep * (flags.shift and 5 or 1)
    local h, v = 0, 0
    if ch == "j" or kc == kmap.down then v = -step
    elseif ch == "k" or kc == kmap.up then v = step
    elseif ch == "h" or kc == kmap.left then h = step
    elseif ch == "l" or kc == kmap.right then h = -step
    else return end
    local ev = hs.eventtap.event.newScrollEvent({ h, v }, {}, "pixel")
    ev:setProperty(eprops.eventSourceUserData, MAGIC)
    ev:post()
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
    local w, h = 360, 32
    local x = (frame.w - w) / 2
    elems[#elems + 1] = {
        type = "rectangle", action = "fill",
        fillColor = { red = 0.06, green = 0.06, blue = 0.1, alpha = 0.9 },
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        frame = { x = x, y = 28, w = w, h = h },
    }
    elems[#elems + 1] = {
        type = "text", text = label, textSize = 13,
        textColor = { white = 1, alpha = 0.95 }, textAlignment = "center",
        frame = { x = x, y = 36, w = w, h = 18 },
    }
end

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
        addBadge(elems, f, "DRAG · pick drop point · Esc cancels")
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
    elseif mode == "scroll" then
        addBadge(elems, f, "SCROLL · h/j/k/l · Shift = fast · Esc exits")
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
    if mode ~= "idle" then
        cancelDrag()
        hideOverlay()
    else
        showOverlay(hs.mouse.getCurrentScreen())
    end
end

-- Modal key handling (consumes every keyDown while the overlay is up)

modalKeyImpl = function(ev)
    -- This tap consumes keyDowns before the activation tap can see them, so
    -- cancel a pending Cmd-tap here too — otherwise Cmd+finalKey (arm drag)
    -- ends with the Cmd release reading as a tap and toggling the overlay off
    cmdPending = false

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

-- Activation: quick tap of left Cmd alone (press+release under tapTimeout,
-- cancelled by any other key, modifier, click, or scroll while Cmd is down)

handleActivationEvent = function(ev)
    if ev:getProperty(eprops.eventSourceUserData) == MAGIC then return false end

    if ev:getType() == etypes.flagsChanged then
        local flags = ev:getFlags()
        local kc = ev:getKeyCode()
        if kc == KEYCODE_LEFT_CMD then
            local onlyCmd = flags.cmd
                and not (flags.shift or flags.alt or flags.ctrl or flags.fn)
            if onlyCmd then
                cmdPending = true
                cmdDownAt = hs.timer.secondsSinceEpoch()
            elseif not flags.cmd then
                if cmdPending
                    and (hs.timer.secondsSinceEpoch() - cmdDownAt) < config.tapTimeout then
                    local ok, err = pcall(toggleOverlay)
                    if not ok then print("mouse_grid: toggle error: " .. tostring(err)) end
                end
                cmdPending = false
            else
                cmdPending = false -- another modifier joined while Cmd held
            end
        else
            cmdPending = false -- right Cmd / Shift / fn etc. changed
        end
    else
        cmdPending = false -- keyDown, mouse button, or scroll while Cmd held
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
    activationTap = hs.eventtap.new({
        etypes.flagsChanged, etypes.keyDown,
        etypes.leftMouseDown, etypes.rightMouseDown, etypes.otherMouseDown,
        etypes.scrollWheel,
    }, handleActivationEvent)
    activationTap:start()

    screenWatcher = hs.screen.watcher.new(function()
        print("mouse_grid: screen layout changed, flushing canvas cache")
        if mode ~= "idle" then
            cancelDrag()
            hideOverlay()
        end
        for _, entry in pairs(canvasCache) do entry.canvas:delete() end
        canvasCache = {}
    end)
    screenWatcher:start()

    print("Mouse Grid loaded (tap left Cmd to toggle)")
    return M
end

function M.stop()
    cancelDrag()
    if mode ~= "idle" then hideOverlay() end
    if activationTap then activationTap:stop(); activationTap = nil end
    if modalTap then modalTap:stop(); modalTap = nil end
    if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
    for _, entry in pairs(canvasCache) do entry.canvas:delete() end
    canvasCache = {}
    print("Mouse Grid stopped")
end

return M
