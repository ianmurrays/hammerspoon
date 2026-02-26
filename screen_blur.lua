-- Screen Blur Module for Hammerspoon
-- Hotkey-toggled full-screen blur overlay with frosted glass effect.
-- Requires ImageMagick: brew install imagemagick
--
-- Config options (passed via init(cfg)):
--   hotkey      = {mods, key}  (default: {"ctrl","alt"}, "b")
--   blurStrength = number      (downsample width in px, default: 128)
--   blurSigma    = number      (Gaussian blur sigma, default: 6)

local M = {}

-- Private state
local hotkey = nil
local canvases = {}
local isBlurred = false
local tmpFiles = {}
local keyTap = nil
local config = {}

-- Clean up temporary image files
local function cleanupTmpFiles()
    for _, path in ipairs(tmpFiles) do
        os.remove(path)
    end
    tmpFiles = {}
end

-- Capture a screen snapshot and return a blurred (downsampled) hs.image
local function captureAndBlurScreen(screen)
    local screenID = tostring(screen:id())
    local tmpPath = "/tmp/hs-blur-" .. screenID .. ".jpg"
    table.insert(tmpFiles, tmpPath)

    local snapshot = screen:snapshot()
    if not snapshot then
        print("screen_blur: failed to capture snapshot for screen " .. screenID)
        return nil
    end

    -- Downsample in memory via a temporary canvas (avoids writing full-res to disk)
    local blurStrength = config.blurStrength or 128
    local origSize = snapshot:size()
    local downH = math.floor(origSize.h * blurStrength / origSize.w)
    local downCanvas = hs.canvas.new({ x = 0, y = 0, w = blurStrength, h = downH })
    downCanvas:appendElements({
        type = "image",
        image = snapshot,
        imageScaling = "scaleToFit",
        frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
    })
    local smallImage = downCanvas:imageFromCanvas()
    downCanvas:delete()

    smallImage:saveToFile(tmpPath)

    -- Apply real Gaussian blur via ImageMagick
    local blurSigma = config.blurSigma or 6
    local cmd = string.format(
        "/opt/homebrew/bin/magick '%s' -blur 0x%d '%s'",
        tmpPath, blurSigma, tmpPath
    )
    local _, status = hs.execute(cmd)
    if not status then
        print("screen_blur: magick blur failed for screen " .. screenID)
        return nil
    end

    local blurredImage = hs.image.imageFromPath(tmpPath)
    if not blurredImage then
        print("screen_blur: failed to load blurred image for screen " .. screenID)
        return nil
    end

    return blurredImage
end

-- Hide the blur overlay
local function hideBlur()
    if keyTap then
        keyTap:stop()
    end

    for _, canvas in pairs(canvases) do
        canvas:delete()
    end
    canvases = {}

    cleanupTmpFiles()
    isBlurred = false
    print("screen_blur: blur hidden")
end

-- Show the blur overlay on all screens
local function showBlur()
    -- Clean up any existing canvases first
    for _, canvas in pairs(canvases) do
        canvas:delete()
    end
    canvases = {}
    cleanupTmpFiles()

    for _, screen in ipairs(hs.screen.allScreens()) do
        local blurredImage = captureAndBlurScreen(screen)
        if blurredImage then
            local frame = screen:fullFrame()
            local canvas = hs.canvas.new(frame)

            canvas:appendElements(
                {
                    type = "image",
                    image = blurredImage,
                    imageScaling = "scaleToFit",
                    frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
                },
                {
                    type = "rectangle",
                    fillColor = { white = 1.0, alpha = 0.15 },
                    frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
                }
            )

            canvas:level(hs.canvas.windowLevels.screenSaver)
            canvas:behavior({"canJoinAllSpaces", "stationary"})

            canvas:mouseCallback(function()
                hideBlur()
            end)
            canvas:canvasMouseEvents(true, false, false, false)

            canvas:show()
            canvases[tostring(screen:id())] = canvas
        end
    end

    -- Start eventtap to dismiss on any keypress
    if keyTap then
        keyTap:stop()
    end
    keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function()
        hideBlur()
        return true
    end)
    keyTap:start()

    isBlurred = true
    print("screen_blur: blur shown on " .. #hs.screen.allScreens() .. " screen(s)")
end

-- Toggle blur on/off
local function toggleBlur()
    if isBlurred then
        hideBlur()
    else
        showBlur()
    end
end

-- Unified menu integration
function M.getMenuItems()
    if isBlurred then
        return {
            { title = "Unblur Screen", fn = toggleBlur }
        }
    else
        return {
            { title = "Blur Screen", fn = toggleBlur }
        }
    end
end

-- Public API

function M.init(cfg)
    config = cfg or {}

    local hotkeyMods = (cfg.hotkey and cfg.hotkey[1]) or {"ctrl", "alt"}
    local hotkeyKey = (cfg.hotkey and cfg.hotkey[2]) or "b"

    hotkey = hs.hotkey.bind(hotkeyMods, hotkeyKey, toggleBlur)

    print("Screen Blur loaded (hotkey: " .. table.concat(hotkeyMods, "+") .. "+" .. hotkeyKey .. ")")
    return M
end

function M.stop()
    if isBlurred then
        hideBlur()
    end

    if hotkey then
        hotkey:delete()
        hotkey = nil
    end

    if keyTap then
        keyTap:stop()
        keyTap = nil
    end

    print("Screen Blur stopped")
end

return M
