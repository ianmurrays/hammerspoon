-- Mouse Grid: keyboard-driven mouse control (Mouseless-style)
-- Tap left Cmd alone to show a full-screen hint grid. Type a cell's two
-- characters, then a subgrid key (or Space for cell center) to click there.
-- Modifiers on the final key: Shift = right click, Ctrl = double click,
-- Alt = move only, Cmd = arm drag (next selection drops). Backspace undoes
-- one level, Tab moves to the next screen, "," enters scroll mode, Esc exits.
-- Nudge: HOLD the final key instead of tapping it, then use arrows or
-- h/j/k/l to move the cursor in small steps (Shift = bigger); releasing the
-- held key executes the action at the nudged position.
-- Tap left Alt alone for free mode: h/j/k/l move the cursor smoothly
-- (Shift = fast, Ctrl = slow), Space clicks (Shift = right, Ctrl = double,
-- Cmd = drag toggle), m/,/.// scroll, Esc or idle timeout exits.
-- Double-tap left Cmd for hints mode (Shortcat-style): actionable UI
-- elements of the focused window are scanned via the Accessibility API and
-- labelled; typing a label clicks the element (same final-key modifiers as
-- the grid). Space enters search: type the element's text to filter, Tab
-- cycles matches, Enter acts. Backspace un-types, Esc exits.

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
    nudgeStep = 2,       -- pixels per nudge keypress while holding the final key (Shift = x5)
    dragSteps = 5,       -- interpolation steps for drag movement
    freeSpeed = 600,         -- free mode cursor speed, px/sec
    freeFastMultiplier = 4,  -- free mode speed with Shift held
    freeSlowMultiplier = 0.25, -- free mode speed with Ctrl held
    freeIdleTimeout = 10,    -- seconds of inactivity before free mode exits
    hintChars = "fjdkslaghrueiwoqp", -- hints mode label alphabet (home-row first)
    doubleTapWindow = 0.3,   -- max seconds between two Cmd taps for hints mode
    hintsMaxDepth = 60,      -- AX traversal depth limit (browser trees are deep)
    hintsMaxElements = 400,  -- cap on rendered hints (also stops the search early)
    hintsRescanDelay = 0.2,  -- delay before the one-shot rescan after an AX fixup
    hintsMinElements = 5,    -- fewer first-pass results than this triggers the rescan
    hintsRoles = {           -- AX roles considered actionable (set-style, overridable)
        AXButton = true, AXLink = true, AXMenuItem = true, AXMenuItemCheckbox = true,
        AXCheckBox = true, AXRadioButton = true, AXPopUpButton = true, AXComboBox = true,
        AXTextField = true, AXTextArea = true, AXMenuButton = true,
        AXDisclosureTriangle = true, AXSlider = true, AXCell = true,
    },
    enhancedUIApps = {       -- Chromium: needs AXEnhancedUserInterface for web content
        ["com.google.Chrome"] = true, ["company.thebrowser.Browser"] = true,
        ["com.brave.Browser"] = true, ["com.microsoft.edgemac"] = true,
        ["org.chromium.Chromium"] = true, ["com.vivaldi.Vivaldi"] = true,
    },
    electronApps = {         -- Electron: AXManualAccessibility (no window-manager side effects)
        ["com.tinyspeck.slackmacgap"] = true, ["com.hnc.Discord"] = true,
        ["com.microsoft.VSCode"] = true, ["notion.id"] = true,
    },
    colors = {
        background = { red = 0, green = 0, blue = 0, alpha = 0.3 },
        gridLine = { white = 1, alpha = 0.25 },
        label = { white = 1, alpha = 0.9 },
        labelBackground = { red = 0, green = 0, blue = 0, alpha = 0.55 },
        rowHighlight = { red = 1, green = 0.8, blue = 0.2, alpha = 0.25 },
        subBackground = { red = 0.1, green = 0.1, blue = 0.15, alpha = 0.3 },
        subLabel = { red = 1, green = 0.85, blue = 0.3, alpha = 1 },
        badge = { red = 1, green = 0.3, blue = 0.3, alpha = 0.9 },
        hintBackground = { red = 1, green = 0.85, blue = 0.3, alpha = 0.95 },
        hintLabel = { red = 0.1, green = 0.1, blue = 0.1, alpha = 1 },
        hintTyped = { red = 0.8, green = 0.1, blue = 0.1, alpha = 1 },
        hintDimAlpha = 0.15, -- alpha multiplier for hints filtered out by typing
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
local nudgeKey = nil     -- subgrid char (or "space") held for nudging
local tapPending = nil   -- { kc, downAt } while a tap-candidate modifier is held

-- Hints mode state
local hintsTap = nil          -- dedicated modal eventtap while hints are up
local hintsCanvas = nil       -- hint-badge canvas
local hints = {}              -- array of { label, frame (global), cx, cy }
local hintsTyped = ""         -- label prefix typed so far
local hintsQuery = nil        -- search text while the search sub-mode is active (nil = label mode)
local hintsSelIdx = 1         -- selected match while searching (Tab cycles)
local hintsSearch = nil       -- in-flight elementSearch object (supports :cancel())
local hintsScanGen = 0        -- generation counter: drops stale async callbacks
local hintsWinFrame = nil     -- focused window AXFrame at scan time (clip rect)
local hintsNotice = nil       -- status string shown in the toast instead of tips
local hintsAXFixup = nil      -- { axApp, attr } to restore on exit
local hintsRescanTimer = nil  -- one-shot rescan timer after an AX fixup
local hintsRescanned = false  -- only rescan once per session
local lastCmdTapAt = 0        -- when the last lone-Cmd tap completed (double-tap detect)

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
local beginNudge, endNudgeCancel
local showOverlay, hideOverlay, toggleOverlay
local modalKeyImpl, handleModalKey, onlyFlag, handleActivationEvent
local generateHintLabels, hintsRoot, applyAXFixup, restoreAXFixup
local startHintsScan, onHintsScanResults, drawHints
local armHintsDrag, performHintsAction
local enterHintsMode, exitHintsMode, toggleHints
local hintsKeyImpl, handleHintsKey
local dismissActiveOverlay

-- Tap-to-activate specs: actions are closures so the forward-declared
-- locals resolve at call time, not at table construction
local tapSpecs = {
    [KEYCODE_LEFT_CMD] = {
        flag = "cmd",
        action = function() toggleOverlay() end,
        doubleAction = function() toggleHints() end, -- two taps within doubleTapWindow
    },
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
    -- Menlo advance width is ~0.6em; pad so the pill hugs the two letters
    local bw, bh = fs * 0.6 * 2 + 8, fs * 1.4
    for r = 1, rows do
        for c = 1, cols do
            elems[#elems + 1] = {
                type = "rectangle", action = "fill",
                fillColor = config.colors.labelBackground,
                roundedRectRadii = { xRadius = 3, yRadius = 3 },
                frame = {
                    x = (c - 1) * cw + (cw - bw) / 2,
                    y = (r - 1) * ch + (ch - bh) / 2,
                    w = bw, h = bh,
                },
            }
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
    dismissActiveOverlay()
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
    dismissActiveOverlay()
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

local FREE_MOVE = { h = true, j = true, k = true, l = true }
-- Scroll keys matched by physical keycode (the four keys right of N), so
-- they work on any layout: "m,./" on US, "m,.-" on Spanish ISO, etc.
local FREE_SCROLL_KEYCODES = { 46, 43, 47, 44 } -- left, up, down, right
local FREE_SCROLL = {
    [46] = { 1, 0 }, [43] = { 0, 1 }, [47] = { 0, -1 }, [44] = { -1, 0 },
}
local FREE_DRAG_TIPS = "FREE · DRAG · hjkl move · Space drops · Esc cancels"

local function freeTipsLabel()
    local keys = ""
    for _, kc in ipairs(FREE_SCROLL_KEYCODES) do
        local ch = kmap[kc]
        keys = keys .. ((type(ch) == "string" and #ch == 1) and ch or "?")
    end
    return "FREE · hjkl move (⇧ fast ⌃ slow) · Space click (⇧ right ⌃ dbl ⌘ drag) · "
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

    local dx = (freeHeld.l and 1 or 0) - (freeHeld.h and 1 or 0)
    local dy = (freeHeld.j and 1 or 0) - (freeHeld.k and 1 or 0)
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
    elseif mode == "hints" then -- switch hints -> free
        cancelDrag()
        exitHintsMode()
        enterFreeMode()
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
    lastCmdTapAt = 0

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
        if flags.fn then return "pass" end -- fn+Space is the STT toggle; don't swallow it
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
    local ok, result = pcall(freeKeyImpl, ev)
    if not ok then
        -- A live error here would leave the tap consuming the keyboard
        print("mouse_grid: error in free key handler: " .. tostring(result))
        pcall(exitFreeMode)
        return true
    end
    if result == "pass" then return false end -- let the event reach other taps (e.g. STT)
    return true -- consume everything else while free mode is active
end

-- Hints mode: Shortcat-style element hints. The focused window's
-- accessibility tree is searched (async, so big browser trees don't
-- beachball Hammerspoon) for actionable roles; each hit gets a short label
-- drawn at its top-left. Typing a label filters live; completing one acts
-- at the element's center with the same final-key modifiers as the grid.

local HINTS_TIPS = "type label · Space search · ⇧ right ⌃ dbl ⌥ move ⌘ drag · Bksp undo · Esc"

-- Prefix-free label set (Vimium-style trie expansion): pop the oldest
-- (shortest) label and replace it with its children — removing the parent
-- is what keeps the set prefix-free, so an exact match can fire immediately
-- even while longer labels exist
generateHintLabels = function(n)
    local chars = {}
    for i = 1, #config.hintChars do chars[i] = config.hintChars:sub(i, i) end
    local queue, head = {}, 1
    for _, c in ipairs(chars) do queue[#queue + 1] = c end
    while #queue - head + 1 < n do
        local parent = queue[head]
        head = head + 1
        for _, c in ipairs(chars) do queue[#queue + 1] = parent .. c end
    end
    local labels = {}
    for i = head, math.min(#queue, head + n - 1) do labels[#labels + 1] = queue[i] end
    return labels
end

-- Chromium hides web content from the AX tree unless AXEnhancedUserInterface
-- is set; Electron uses AXManualAccessibility instead. Enabled only while
-- hints mode is active (AXEnhancedUserInterface is the VoiceOver flag and is
-- known to glitch window snapping), and only for known bundle IDs.
applyAXFixup = function(app)
    hintsAXFixup = nil
    if not app then return end
    local bundle = app:bundleID()
    local attr = (config.enhancedUIApps[bundle] and "AXEnhancedUserInterface")
        or (config.electronApps[bundle] and "AXManualAccessibility")
    if not attr then return end
    local axApp = hs.axuielement.applicationElement(app)
    if not axApp then return end
    local ok, prev = pcall(axApp.attributeValue, axApp, attr)
    if ok and prev == true then return end -- already on: nothing to restore
    pcall(axApp.setAttributeValue, axApp, attr, true)
    hintsAXFixup = { axApp = axApp, attr = attr }
    print("mouse_grid: enabled " .. attr .. " on " .. tostring(bundle))
end

restoreAXFixup = function()
    if not hintsAXFixup then return end
    pcall(hintsAXFixup.axApp.setAttributeValue, hintsAXFixup.axApp, hintsAXFixup.attr, false)
    hintsAXFixup = nil
end

hintsRoot = function(app)
    if not app then return nil end
    local axApp = hs.axuielement.applicationElement(app)
    if not axApp then return nil end
    local ok, win = pcall(axApp.attributeValue, axApp, "AXFocusedWindow")
    if ok and win then return win end
    local w = app:focusedWindow()
    return w and hs.axuielement.windowElement(w) or nil
end

-- Searchable text for an element (Shortcat-style search sub-mode)
local elementText = function(el)
    local parts = {}
    for _, attr in ipairs({ "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue" }) do
        local ok, v = pcall(el.attributeValue, el, attr)
        if ok and type(v) == "string" and #v > 0 then
            parts[#parts + 1] = v:sub(1, 200)
        end
    end
    return table.concat(parts, " "):lower()
end

-- Indices into `hints` matching the current search query (plain substring)
local hintsMatchIndices = function()
    local q = hintsQuery or ""
    local out = {}
    for i, h in ipairs(hints) do
        if q == "" or (h.text and h.text:find(q, 1, true)) then
            out[#out + 1] = i
        end
    end
    return out
end

drawHints = function()
    if not hintsCanvas then return end
    local f = currentScreen:fullFrame()
    local elems = {}
    local bg, fg, typedColor = config.colors.hintBackground,
        config.colors.hintLabel, config.colors.hintTyped
    local cw, bh = 7, 16 -- Menlo 11pt advance width, badge height

    local matchList = hintsQuery and hintsMatchIndices() or nil
    if matchList then
        -- Search sub-mode: outline matches instead of labels (typing goes
        -- to the query); the Tab-selected match gets the accent outline
        local sel = matchList[math.min(math.max(hintsSelIdx, 1), math.max(#matchList, 1))]
        for _, i in ipairs(matchList) do
            local h = hints[i]
            local isSel = (i == sel)
            elems[#elems + 1] = {
                type = "rectangle", action = "stroke",
                strokeColor = isSel and config.colors.badge or bg,
                strokeWidth = isSel and 2.5 or 1.5,
                roundedRectRadii = { xRadius = 3, yRadius = 3 },
                frame = { x = h.frame.x - f.x, y = h.frame.y - f.y,
                    w = h.frame.w, h = h.frame.h },
            }
        end
        local label = string.format("%sSEARCH · \"%s\" · %d hits · ⇥ next · ⏎ act (⇧ right ⌃ dbl ⌥ move ⌘ drag) · Esc back",
            dragOrigin and "DRAG · " or "", hintsQuery, #matchList)
        if hintsNotice then label = "HINTS · " .. hintsNotice end
        addBadge(elems, f, label)
        hintsCanvas:replaceElements(table.unpack(elems))
        return
    end

    for _, h in ipairs(hints) do
        local matched = h.label:sub(1, #hintsTyped) == hintsTyped
        local alpha = matched and 1 or config.colors.hintDimAlpha
        local bw = 8 + #h.label * cw
        local bx = math.max(0, math.min(h.frame.x - f.x, f.w - bw))
        local by = math.max(0, math.min(h.frame.y - f.y, f.h - bh))
        elems[#elems + 1] = {
            type = "rectangle", action = "fill",
            fillColor = { red = bg.red, green = bg.green, blue = bg.blue,
                alpha = (bg.alpha or 1) * alpha },
            roundedRectRadii = { xRadius = 3, yRadius = 3 },
            frame = { x = bx, y = by, w = bw, h = bh },
        }
        local tx = bx + 4
        if matched and #hintsTyped > 0 then -- typed prefix in accent color
            elems[#elems + 1] = {
                type = "text", text = h.label:sub(1, #hintsTyped),
                textSize = 11, textFont = "Menlo", textColor = typedColor,
                frame = { x = tx, y = by + 1.5, w = #hintsTyped * cw + 2, h = 14 },
            }
            tx = tx + #hintsTyped * cw
        end
        local rest = matched and h.label:sub(#hintsTyped + 1) or h.label
        if #rest > 0 then
            elems[#elems + 1] = {
                type = "text", text = rest,
                textSize = 11, textFont = "Menlo",
                textColor = { red = fg.red, green = fg.green, blue = fg.blue,
                    alpha = (fg.alpha or 1) * alpha },
                frame = { x = tx, y = by + 1.5, w = #rest * cw + 4, h = 14 },
            }
        end
    end

    local label
    if hintsNotice then
        label = "HINTS · " .. hintsNotice
    elseif hintsSearch then
        label = "HINTS · scanning…"
    else
        label = (dragOrigin and "HINTS · DRAG · " or "HINTS · ") .. HINTS_TIPS
    end
    addBadge(elems, f, label)

    hintsCanvas:replaceElements(table.unpack(elems))
end

onHintsScanResults = function(results)
    -- Clip to focused window ∩ current screen: drops offscreen and
    -- scrolled-out elements that still report a frame
    local f = currentScreen:fullFrame()
    local clip = { x = f.x, y = f.y, w = f.w, h = f.h }
    local wf = hintsWinFrame
    if wf then
        local x1, y1 = math.max(clip.x, wf.x), math.max(clip.y, wf.y)
        local x2 = math.min(clip.x + clip.w, wf.x + wf.w)
        local y2 = math.min(clip.y + clip.h, wf.y + wf.h)
        if x2 > x1 and y2 > y1 then
            clip = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
        end
    end

    local list, seen = {}, {}
    for i = 1, #results do
        local el = results[i]
        -- pcall everything: AX elements die mid-flight when apps mutate their UI
        local ok, fr = pcall(el.attributeValue, el, "AXFrame")
        if ok and type(fr) == "table" and fr.w and fr.w > 2 and fr.h > 2 then
            local cx, cy = fr.x + fr.w / 2, fr.y + fr.h / 2
            if cx >= clip.x and cx < clip.x + clip.w
                and cy >= clip.y and cy < clip.y + clip.h then
                -- Dedupe by rounded frame: kills nested AXCell duplicates
                local key = math.floor(fr.x) .. ":" .. math.floor(fr.y)
                    .. ":" .. math.floor(fr.w) .. ":" .. math.floor(fr.h)
                if not seen[key] then
                    seen[key] = true
                    list[#list + 1] = {
                        frame = { x = fr.x, y = fr.y, w = fr.w, h = fr.h },
                        cx = cx, cy = cy,
                        text = elementText(el), -- for the search sub-mode
                    }
                end
            end
        end
    end

    -- Chromium/Electron populate the web subtree lazily after the AX
    -- attribute flips, so a thin first pass gets one delayed rescan
    if #list < config.hintsMinElements and hintsAXFixup and not hintsRescanned then
        hintsRescanned = true
        hintsRescanTimer = hs.timer.doAfter(config.hintsRescanDelay, function()
            hintsRescanTimer = nil
            if mode == "hints" then
                startHintsScan(hs.application.frontmostApplication())
                drawHints()
            end
        end)
        return
    end

    table.sort(list, function(a, b) -- reading order, so labels are predictable
        if a.frame.y ~= b.frame.y then return a.frame.y < b.frame.y end
        return a.frame.x < b.frame.x
    end)
    while #list > config.hintsMaxElements do list[#list] = nil end

    local labels = generateHintLabels(#list)
    hints = {}
    for i, item in ipairs(list) do
        hints[i] = { label = labels[i], frame = item.frame,
            cx = item.cx, cy = item.cy, text = item.text }
    end
    hintsTyped = ""
    hintsSelIdx = 1
    if #hints == 0 then
        hintsNotice = "no clickable elements found"
        local gen = hintsScanGen
        hs.timer.doAfter(1.2, function()
            if gen == hintsScanGen and mode == "hints" then exitHintsMode() end
        end)
    else
        hintsNotice = nil
    end
    drawHints()
    print(string.format("mouse_grid: hints found %d elements", #hints))
end

startHintsScan = function(app)
    hintsScanGen = hintsScanGen + 1
    local gen = hintsScanGen
    local root = hintsRoot(app)
    if not root then
        hintsNotice = "no focusable window"
        drawHints()
        hs.timer.doAfter(1.2, function()
            if gen == hintsScanGen and mode == "hints" then exitHintsMode() end
        end)
        return
    end
    local okF, wf = pcall(root.attributeValue, root, "AXFrame")
    hintsWinFrame = (okF and type(wf) == "table") and wf or nil
    local roles = config.hintsRoles
    hintsSearch = root:elementSearch(
        function(_, results)
            if gen ~= hintsScanGen or mode ~= "hints" then return end -- stale
            hintsSearch = nil
            local ok, err = pcall(onHintsScanResults, results)
            if not ok then
                print("mouse_grid: hints scan error: " .. tostring(err))
                pcall(exitHintsMode)
            end
        end,
        function(el) -- criteria: actionable role?
            local ok, role = pcall(el.attributeValue, el, "AXRole")
            return ok and role ~= nil and roles[role] == true
        end,
        { count = config.hintsMaxElements, depth = config.hintsMaxDepth }
    )
end

armHintsDrag = function(point)
    hs.mouse.absolutePosition(point)
    postMouse(etypes.leftMouseDown, point, 1)
    dragOrigin = point
    hintsTyped = "" -- full hint set comes back for picking the drop target
    if hintsQuery then hintsQuery = "" end -- stay in search, clear the query
    hintsSelIdx = 1
    drawHints()
    print(string.format("mouse_grid: drag armed at %.0f,%.0f (hints)", point.x, point.y))
end

performHintsAction = function(point, flags)
    if not dragOrigin and flags.cmd then
        armHintsDrag(point)
    else
        -- finishDrag/doClick/alt-move all dismiss via dismissActiveOverlay
        performAction(point, flags)
    end
end

enterHintsMode = function()
    if mode == "free" then
        exitFreeMode()
    elseif mode ~= "idle" then
        cancelDrag()
        hideOverlay()
    end
    local app = hs.application.frontmostApplication()
    -- Anchor to the screen of the window being scanned, not the cursor's —
    -- they can differ, and a wrong clip rect rejects every scanned element
    local focusedWindow = hs.window.focusedWindow()
    currentScreen = (focusedWindow and focusedWindow:screen())
        or hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    mode = "hints"
    hints = {}
    hintsTyped = ""
    hintsQuery = nil
    hintsSelIdx = 1
    hintsNotice = nil
    hintsRescanned = false
    applyAXFixup(app)
    hintsCanvas = hs.canvas.new(currentScreen:fullFrame())
    hintsCanvas:level(hs.canvas.windowLevels.screenSaver)
    hintsCanvas:behavior({ "canJoinAllSpaces", "stationary" })
    hintsCanvas:show()
    hintsTap:start()
    startHintsScan(app)
    drawHints() -- "scanning…" badge until results arrive
    print("mouse_grid: hints mode on (" .. (app and app:name() or "?") .. ")")
end

-- Idempotent: also called from pcall error paths and async timers
exitHintsMode = function()
    hintsScanGen = hintsScanGen + 1 -- invalidate in-flight callbacks
    if hintsSearch then pcall(hintsSearch.cancel, hintsSearch); hintsSearch = nil end
    if hintsRescanTimer then hintsRescanTimer:stop(); hintsRescanTimer = nil end
    if hintsTap then hintsTap:stop() end
    if hintsCanvas then hintsCanvas:delete(); hintsCanvas = nil end
    restoreAXFixup()
    hints = {}
    hintsTyped = ""
    hintsQuery = nil
    hintsSelIdx = 1
    hintsNotice = nil
    hintsWinFrame = nil
    -- dragOrigin intentionally untouched: finishDrag reads it after dismissal
    -- and Esc runs its own cancelDrag()
    mode = "idle"
    print("mouse_grid: hints mode off")
end

toggleHints = function()
    if mode == "hints" then
        cancelDrag()
        exitHintsMode()
    else
        enterHintsMode()
    end
end

hintsKeyImpl = function(ev)
    -- This tap eats keys before the activation tap sees them, so cancel
    -- pending taps here too (same reason as modalKeyImpl) — and clear the
    -- double-tap timestamp so a stale half-double-tap can't fire later
    tapPending = nil
    lastCmdTapAt = 0

    if ev:getType() ~= etypes.keyDown then return end

    local kc = ev:getKeyCode()
    local flags = ev:getFlags()
    local repeating = (ev:getProperty(eprops.keyboardEventAutorepeat) or 0) ~= 0
    if repeating and kc ~= kmap.delete and kc ~= kmap.tab then return end

    -- Resolve from keycode (modifier-independent), same as modalKeyImpl:
    -- character translation is unreliable while Cmd/Ctrl are held
    local ch = kmap[kc]
    if type(ch) ~= "string" or #ch ~= 1 then
        ch = ev:getCharacters(true)
    end
    ch = ch and ch:lower() or ""

    if kc == kmap.escape then
        if hintsQuery then -- leave search, back to labels
            hintsQuery, hintsSelIdx = nil, 1
            drawHints()
        else
            cancelDrag()
            exitHintsMode()
        end
        return
    end

    if hintsQuery then -- search sub-mode: typing edits the query
        if kc == kmap["return"] or kc == kmap.padenter then
            local matchList = hintsMatchIndices()
            if #matchList > 0 then
                local h = hints[matchList[math.min(math.max(hintsSelIdx, 1), #matchList)]]
                performHintsAction({ x = h.cx, y = h.cy }, flags)
            end
            return
        end
        if kc == kmap.tab then -- cycle through matches (Shift = backwards)
            local n = #hintsMatchIndices()
            if n > 0 then
                hintsSelIdx = flags.shift and ((hintsSelIdx - 2) % n + 1)
                    or (hintsSelIdx % n + 1)
                drawHints()
            end
            return
        end
        if kc == kmap.delete then
            if #hintsQuery > 0 then
                hintsQuery = hintsQuery:sub(1, -2)
            else
                hintsQuery = nil -- Backspace on empty query leaves search
            end
            hintsSelIdx = 1
            drawHints()
            return
        end
        if flags.cmd or flags.ctrl or flags.alt then return end
        if #ch == 1 and ch:match("[%g ]") then
            hintsQuery = hintsQuery .. ch
            hintsSelIdx = 1
            drawHints()
        end
        return
    end

    if kc == kmap.space then -- enter search sub-mode (Shortcat-style)
        hintsQuery, hintsSelIdx = "", 1
        drawHints()
        return
    end

    if kc == kmap.delete then -- Backspace: un-type one label char
        hintsTyped = hintsTyped:sub(1, -2)
        drawHints()
        return
    end

    if ch == "" or not config.hintChars:find(ch, 1, true) then return end
    local candidate = hintsTyped .. ch
    local exact, anyPrefix = nil, false
    for _, h in ipairs(hints) do
        if h.label == candidate then exact = h end
        if h.label:sub(1, #candidate) == candidate then anyPrefix = true end
    end
    if not anyPrefix then return end -- typo: ignore instead of dead-ending
    hintsTyped = candidate
    if exact then -- labels are prefix-free, so an exact match is unique
        performHintsAction({ x = exact.cx, y = exact.cy }, flags)
    else
        drawHints()
    end
end

handleHintsKey = function(ev)
    local ok, err = pcall(hintsKeyImpl, ev)
    if not ok then
        -- A live error here would leave the tap consuming the keyboard
        print("mouse_grid: error in hints key handler: " .. tostring(err))
        pcall(cancelDrag)
        pcall(exitHintsMode)
    end
    return true -- consume everything while hints mode is active
end

-- Action dispatch: modifiers are read from the final keystroke only.
-- doClick/finishDrag/the alt branch run from both grid and hints modes, so
-- they must tear down whichever overlay is active — calling hideOverlay()
-- from a hints path would leave hintsTap consuming the keyboard forever.

dismissActiveOverlay = function()
    if mode == "hints" then exitHintsMode() else hideOverlay() end
end

performAction = function(point, flags)
    if dragOrigin then
        finishDrag(point)
    elseif flags.cmd then
        armDrag(point)
    elseif flags.alt then
        dismissActiveOverlay()
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
    sub = "pick point (qwert/asdfg/zxcvb) · Space center · hold to nudge · ⇧ right ⌃ dbl ⌥ move ⌘ drag",
    scroll = "SCROLL · h/j/k/l · ⇧ fast · , or Esc back",
}
local NUDGE_TIPS = "NUDGE · hjkl/arrows move (⇧ big) · release key to act (⇧ right ⌃ dbl ⌥ move ⌘ drag) · Bksp back"

beginNudge = function(key, point)
    nudgeKey = key
    hs.mouse.absolutePosition(point)
    if gridCanvas then gridCanvas:hide() end -- unobstructed view; cursor is the indicator
    drawFocus()
end

-- Cancel or finish a nudge while the overlay stays up: restore the grid
endNudgeCancel = function()
    nudgeKey = nil
    if gridCanvas then
        gridCanvas:show()
        if focusCanvas then focusCanvas:orderAbove(gridCanvas) end
    end
    drawFocus()
end

drawFocus = function()
    if not focusCanvas then return end
    local f = currentScreen:fullFrame()
    local elems = {}

    if nudgeKey then -- badge only: the real cursor is the indicator
        addBadge(elems, f, (dragOrigin and "DRAG · " or "") .. NUDGE_TIPS)
        focusCanvas:replaceElements(table.unpack(elems))
        return
    end

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
    nudgeKey = nil
    print("mouse_grid: overlay hidden")
end

toggleOverlay = function()
    if mode == "free" then -- switch free -> grid
        exitFreeMode()
        showOverlay(hs.mouse.getCurrentScreen())
    elseif mode == "hints" then -- switch hints -> grid
        cancelDrag()
        exitHintsMode()
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
    -- This tap consumes keys before the activation tap can see them, so
    -- cancel a pending tap here too — otherwise Cmd+finalKey (arm drag)
    -- ends with the Cmd release reading as a tap and toggling the overlay off
    tapPending = nil
    lastCmdTapAt = 0 -- typing also breaks a half-finished double tap

    local isDown = ev:getType() == etypes.keyDown
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

    -- Nudge: the final key is being held; arrows/hjkl move the cursor,
    -- releasing the held key acts at the nudged position
    if nudgeKey then
        if not isDown then
            if ch == nudgeKey or (nudgeKey == "space" and kc == kmap.space) then
                nudgeKey = nil
                performAction(hs.mouse.absolutePosition(), flags)
                if mode ~= "idle" and gridCanvas then
                    -- a drag was armed: overlay stays up, bring the grid back
                    gridCanvas:show()
                    if focusCanvas then focusCanvas:orderAbove(gridCanvas) end
                end
            end
            return
        end
        if kc == kmap.escape then
            nudgeKey = nil
            cancelDrag()
            hideOverlay()
            return
        end
        if kc == kmap.delete then -- cancel the nudge, back to the subgrid
            endNudgeCancel()
            return
        end
        local step = config.nudgeStep * (flags.shift and 5 or 1)
        local dx, dy = 0, 0
        if ch == "k" or kc == kmap.up then dy = -step
        elseif ch == "j" or kc == kmap.down then dy = step
        elseif ch == "h" or kc == kmap.left then dx = -step
        elseif ch == "l" or kc == kmap.right then dx = step
        else return end -- includes autorepeats of the held key
        local pos = hs.mouse.absolutePosition()
        hs.mouse.absolutePosition({ x = pos.x + dx, y = pos.y + dy })
        return
    end

    if not isDown then return end -- keyUps only matter while nudging

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
        beginNudge("space", cellCenter(selRow, selCol))
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
                beginNudge(ch, subCellPoint(selRow, selCol, sr, sc))
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

-- Activation: quick tap of left Cmd (grid; two taps within doubleTapWindow
-- for hints) or left Alt (free mode) alone — press+release under tapTimeout,
-- cancelled by any other key, modifier, click, or scroll while the candidate
-- key is down

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
                    -- Double tap: a second qualifying tap shortly after the
                    -- first upgrades to doubleAction (grid flash is fine —
                    -- the grid canvas is cached and cheap to show)
                    local now = hs.timer.secondsSinceEpoch()
                    local action = spec.action
                    if spec.doubleAction and (now - lastCmdTapAt) < config.doubleTapWindow then
                        lastCmdTapAt = 0
                        action = spec.doubleAction
                    elseif spec.doubleAction then
                        lastCmdTapAt = now
                    end
                    local ok, err = pcall(action)
                    if not ok then print("mouse_grid: toggle error: " .. tostring(err)) end
                end
                tapPending = nil
            else
                tapPending = nil -- another modifier joined while held
                lastCmdTapAt = 0
            end
        else
            tapPending = nil -- right Cmd / Shift / fn etc. changed
            lastCmdTapAt = 0
        end
    else
        tapPending = nil -- keyDown, mouse button, or scroll while held
        lastCmdTapAt = 0
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
    if #config.hintChars < 2 then -- label expansion needs at least 2 chars
        print("mouse_grid: warning - hintChars too short, using default")
        config.hintChars = "fjdkslaghrueiwoqp"
    elseif #config.hintChars < 8 then
        print("mouse_grid: warning - short hintChars makes hint labels long")
    end

    modalTap = hs.eventtap.new({ etypes.keyDown, etypes.keyUp }, handleModalKey)
    freeTap = hs.eventtap.new({ etypes.keyDown, etypes.keyUp }, handleFreeKey)
    hintsTap = hs.eventtap.new({ etypes.keyDown, etypes.keyUp }, handleHintsKey)
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
        elseif mode == "hints" then
            cancelDrag()
            exitHintsMode()
        elseif mode ~= "idle" then
            cancelDrag()
            hideOverlay()
        end
        for _, entry in pairs(canvasCache) do entry.canvas:delete() end
        canvasCache = {}
    end)
    screenWatcher:start()

    print("Mouse Grid loaded (tap left Cmd for grid, double-tap for hints, left Alt for free mode)")
    return M
end

function M.stop()
    if mode == "free" then exitFreeMode() end
    if mode == "hints" then pcall(exitHintsMode) end
    cancelDrag()
    if mode ~= "idle" then hideOverlay() end
    if activationTap then activationTap:stop(); activationTap = nil end
    if modalTap then modalTap:stop(); modalTap = nil end
    if freeTap then freeTap:stop(); freeTap = nil end
    if hintsTap then hintsTap:stop(); hintsTap = nil end
    if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
    for _, entry in pairs(canvasCache) do entry.canvas:delete() end
    canvasCache = {}
    print("Mouse Grid stopped")
end

return M
