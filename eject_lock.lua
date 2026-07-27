-- Magic Keyboard Eject key gestures: double-tap locks the screen, holding for
-- 4 seconds runs the "Eject TimeMachine Disk" Shortcut.
-- Eject emits an NSSystemDefined media-key event, not a regular keycode,
-- so it's caught via a systemDefined eventtap + systemKey().
local M = {}

-- ponytail: no hs.fs.attributes() check on the CLI — /usr/bin/shortcuts ships with
-- macOS, and a whatcable-style early return would take the lock-screen half down
-- with it. Ceiling: a missing binary shows up as a failure alert on first hold.
local SHORTCUTS = "/usr/bin/shortcuts"
local SHORTCUT_NAME = "Eject TimeMachine Disk"
local HOLD_SECONDS = 4

local tap
local lastTap = 0
local holdTimer

local function cancelHold()
  if holdTimer then
    holdTimer:stop()
    holdTimer = nil
  end
end

local function runShortcut()
  holdTimer = nil
  lastTap = 0 -- a tap right after a hold must not count as half of a double-tap
  hs.alert.show("Ejecting Time Machine disk…")
  -- ponytail: no single-flight guard — a second run needs another deliberate 4s hold.
  local task = hs.task.new(SHORTCUTS, function(exitCode, _, stdErr)
    if exitCode ~= 0 then
      hs.alert.show("Eject shortcut failed (exit " .. exitCode .. ")")
      print("eject_lock: shortcuts run failed: " .. (stdErr or ""))
    end
  end, { "run", SHORTCUT_NAME })
  task:start()
end

function M.init(cfg)
  local doubleTapInterval = cfg.doubleTapInterval or 0.4 -- seconds

  tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
    local sk = e:systemKey()
    if not sk or sk.key ~= "EJECT" then
      return false
    end

    -- Release: always disarms a pending hold, and always passes through. Flags are
    -- ignored on purpose — modifiers grabbed after the press would otherwise leave
    -- the timer armed, and a flagged keydown was passed through so macOS needs its
    -- matching keyup.
    if not sk.down then
      cancelHold()
      return false
    end

    -- Modifier combos (Ctrl+Cmd+Eject = restart, Ctrl+Shift+Eject = sleep displays)
    -- stay macOS's business.
    if next(e:getFlags()) then
      return false
    end

    -- Auto-repeat while held: consumed, since macOS never saw the keydown.
    if sk["repeat"] then
      return true
    end

    local now = hs.timer.secondsSinceEpoch()
    if now - lastTap < doubleTapInterval then
      -- Second tap: lock, and arm no hold timer. Once the login window is up this
      -- tap stops seeing the release, so a timer armed here would fire behind the
      -- lock screen and unmount the disk with no visible signal.
      lastTap = 0
      cancelHold()
      hs.caffeinate.lockScreen()
    else
      lastTap = now
      holdTimer = hs.timer.doAfter(HOLD_SECONDS, runShortcut)
    end
    return true -- consume so macOS doesn't also handle the press
  end)
  tap:start()

  print("eject_lock loaded")
  return M
end

function M.stop()
  if tap then tap:stop() end
  cancelHold()
end

return M
