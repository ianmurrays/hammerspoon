-- Locks the screen when the Magic Keyboard's Eject key is double-tapped.
-- Eject emits an NSSystemDefined media-key event, not a regular keycode,
-- so it's caught via a systemDefined eventtap + systemKey().
local M = {}

local tap
local lastTap = 0

function M.init(cfg)
  local doubleTapInterval = cfg.doubleTapInterval or 0.4 -- seconds

  tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
    local sk = e:systemKey()
    if sk and sk.key == "EJECT" and sk.down and not sk["repeat"]
       and not next(e:getFlags()) then
      local now = hs.timer.secondsSinceEpoch()
      if now - lastTap < doubleTapInterval then
        lastTap = 0
        hs.caffeinate.lockScreen()
      else
        lastTap = now
      end
      return true -- consume so macOS doesn't also handle the press
    end
    return false
  end)
  tap:start()

  print("eject_lock loaded")
  return M
end

function M.stop()
  if tap then tap:stop() end
end

return M
