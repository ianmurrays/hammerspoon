-- Stall log: writes main-thread stalls and late key events to a local file.
-- All eventtap callbacks run on the Hammerspoon main thread, and the stt tap gets every key
-- press. Thus a blocked main thread delays all keyboard input.
-- A repeating timer measures the stall: after a block, the timer fires late by the block time.
-- stt.lua calls M.log() when a key event arrives late.
local M = {}

local config = {
    path = os.getenv("HOME") .. "/Library/Logs/hammerspoon-stall.log",
    interval = 0.25, -- seconds between timer ticks
    threshold = 0.5, -- seconds between 2 ticks that count as a stall
}

local timer
local lastTick

-- ponytail: no rotation, the file gets 1 entry per stall. Add rotation if stalls are frequent.
local function write(msg)
    local f = io.open(config.path, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
end

function M.log(msg)
    print("stall_log: " .. msg)
    write(msg)
end

function M.init(cfg)
    for k, v in pairs(cfg or {}) do config[k] = v end
    lastTick = hs.timer.absoluteTime() -- does not include time asleep, so sleep is not a stall
    timer = hs.timer.doEvery(config.interval, function()
        local now = hs.timer.absoluteTime()
        local gap = (now - lastTick) / 1e9
        lastTick = now
        if gap > config.threshold then
            local msg = string.format("main thread blocked: no timer tick for %.0f ms", gap * 1000)
            -- Only the first line goes to the console. If the console tail goes to the console too,
            -- each tail contains the tail before it.
            print("stall_log: " .. msg)
            -- The log showed that the last print() of a blocking timer callback is not yet in the
            -- console at this tick, so read the console 0.1 s later.
            -- ponytail: the console tail identifies the blocking callback only if it printed.
            -- If it did not, wrap the hs.timer/watcher callbacks with a duration check.
            hs.timer.doAfter(0.1, function()
                local tail = hs.console.getConsole():sub(-1000):gsub("\n", "\n    ")
                write(msg .. ". Console before it:\n    " .. tail)
            end)
        end
    end)
    print("Stall log loaded (" .. config.path .. ")")
    return M
end

function M.stop()
    if timer then timer:stop(); timer = nil end
end

return M
