-- Keyboard lock for a keyboard clean, like Wipey or CleanMyKeyboard.
-- A full-screen overlay covers each screen and an event tap swallows all key,
-- modifier and media-key events. To unlock, hold Esc or the mouse button on the
-- overlay for 3 seconds, then release. The mouse stays live on purpose, but a
-- short click does nothing: a palm on the trackpad must not end the lock.
--
-- Config options (passed to init(cfg)):
--   hotkey      = {mods, key}  (default: {"ctrl","alt"}, "k")
--   holdSeconds = number       (hold to unlock, default: 3)
--   maxSeconds  = number       (automatic unlock, default: 300)
local M = {}

local ETYPES = hs.eventtap.event.types
local ESC = hs.keycodes.map["escape"]
local HINT_INDEX = 3 -- the third canvas element is the hint text

local config = {}
local hotkey, tap, holdTimer, capTimer
local holdDone = false
local canvases = {}

-- Forward declaration: the countdown closure in startHold() calls unlock().
local unlock

local function hintText()
  return "Hold Esc or the mouse button for " .. config.holdSeconds .. " seconds, then release, to unlock"
end

local function setHint(text)
  for _, canvas in pairs(canvases) do
    canvas:elementAttribute(HINT_INDEX, "text", text)
  end
end

local function cancelHold()
  if not holdTimer then
    return
  end
  holdTimer:stop()
  holdTimer = nil
  setHint(hintText())
end

local function startHold()
  if holdTimer or holdDone then
    return -- the key repeats while it is down; one countdown is enough
  end
  local left = config.holdSeconds
  setHint("Unlock in " .. left .. "...")
  holdTimer = hs.timer.doEvery(1, function()
    left = left - 1
    if left > 0 then
      setHint("Unlock in " .. left .. "...")
      return
    end
    -- The unlock waits for the release of Esc. If the tap stops while the key is
    -- still down, the app in front gets the repeats and the key-up event.
    holdTimer:stop()
    holdTimer = nil
    holdDone = true
    setHint("Release to unlock")
  end)
end

local function lock()
  if tap then
    return -- already locked
  end

  for _, screen in ipairs(hs.screen.allScreens()) do
    local canvas = hs.canvas.new(screen:fullFrame())
    canvas:appendElements(
      {
        type = "rectangle",
        action = "fill",
        fillColor = { white = 0, alpha = 0.92 },
        frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
      },
      {
        type = "text",
        text = "🧽 Keyboard locked",
        textSize = 48,
        textAlignment = "center",
        textColor = { white = 1, alpha = 0.9 },
        frame = { x = "0%", y = "42%", w = "100%", h = "10%" },
      },
      {
        type = "text",
        text = hintText(),
        textSize = 20,
        textAlignment = "center",
        textColor = { white = 1, alpha = 0.55 },
        frame = { x = "0%", y = "53%", w = "100%", h = "8%" },
      }
    )

    canvas:level(hs.canvas.windowLevels.screenSaver)
    canvas:behavior({ "canJoinAllSpaces", "stationary" })
    -- The mouse button uses the same hold as Esc. A single click must not unlock,
    -- because a palm on the trackpad is easy during a clean.
    canvas:mouseCallback(function(_, message)
      if message == "mouseDown" then
        startHold()
      elseif message == "mouseUp" then
        if holdDone then
          unlock()
        else
          cancelHold()
        end
      end
    end)
    canvas:canvasMouseEvents(true, true, false, false)
    canvas:show()

    canvases[tostring(screen:id())] = canvas
  end

  -- The tap starts here, not in init(). Hammerspoon puts each new tap at the head
  -- of the queue, so a tap that starts at lock time sees events before the stt
  -- (fn+space) and eject_lock taps and can block them.
  tap = hs.eventtap.new(
    { ETYPES.keyDown, ETYPES.keyUp, ETYPES.flagsChanged, ETYPES.systemDefined },
    function(e)
      local evType = e:getType()
      if evType == ETYPES.keyDown and e:getKeyCode() == ESC then
        startHold()
      elseif evType == ETYPES.keyUp and e:getKeyCode() == ESC then
        if holdDone then
          unlock()
        else
          cancelHold()
        end
      end
      return true -- swallow every key, modifier and media-key event
    end
  )
  tap:start()

  -- Failsafe. The mouse and the Esc hold are the normal exits, but a locked
  -- keyboard is a bad state to be stuck in.
  capTimer = hs.timer.doAfter(config.maxSeconds, unlock)

  print("keyboard_lock: locked")
end

unlock = function()
  if not tap then
    return
  end

  cancelHold()
  holdDone = false
  if capTimer then
    capTimer:stop()
    capTimer = nil
  end

  tap:stop()
  tap = nil

  for _, canvas in pairs(canvases) do
    canvas:delete()
  end
  canvases = {}

  print("keyboard_lock: unlocked")
end

-- Unified menu integration
function M.getMenuItems()
  return {
    { title = "Lock Keyboard", fn = lock },
  }
end

-- Public API

function M.init(cfg)
  config = cfg or {}
  config.holdSeconds = config.holdSeconds or 3
  config.maxSeconds = config.maxSeconds or 300

  local mods = (config.hotkey and config.hotkey[1]) or { "ctrl", "alt" }
  local key = (config.hotkey and config.hotkey[2]) or "k"

  -- ponytail: the hotkey locks, it does not toggle. A cloth that drags over
  -- ctrl+alt+k must not unlock the keyboard in the middle of a clean.
  hotkey = hs.hotkey.bind(mods, key, lock)

  print("Keyboard Lock loaded (hotkey: " .. table.concat(mods, "+") .. "+" .. key .. ")")
  return M
end

function M.stop()
  unlock()

  if hotkey then
    hotkey:delete()
    hotkey = nil
  end

  print("Keyboard Lock stopped")
end

return M
