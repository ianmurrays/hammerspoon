-- Capsule toasts drawn with hs.canvas, replacing hs.alert for module notices.
-- toast.show({icon=, title=, detail=, tint=, seconds=, segments=, active=})
--   icon: short string in a 28px circle; tint: "red" | "blue" | nil
--   detail: optional monospace second line
--   segments/active: optional segmented control (e.g. locales) with the active index highlighted

local M = {}

local H = 44      -- capsule height
local PAD = 20    -- canvas margin around the capsule so the shadow isn't clipped
local STACK = 52  -- vertical offset per live toast
local BOTTOM = 80 -- capsule bottom edge above the screen bottom

local TINTS = {
    red = { bg = { red = 1, green = 69 / 255, blue = 58 / 255, alpha = 0.22 }, fg = { hex = "#FF6961" } },
    blue = { bg = { red = 10 / 255, green = 132 / 255, blue = 1, alpha = 0.22 }, fg = { hex = "#64B0FF" } },
}
local NEUTRAL = { bg = { white = 1, alpha = 0.1 }, fg = { white = 1 } }

local live = {} -- slot index -> canvas
local measurer = nil

local function styled(text, size, color, mono)
    return hs.styledtext.new(text, {
        font = { name = mono and "Menlo" or ".AppleSystemUIFont", size = size },
        color = color,
    })
end

local function measure(st)
    measurer = measurer or hs.canvas.new({ x = 0, y = 0, w = 1, h = 1 })
    local size = measurer:minimumTextSize(st)
    return math.ceil(size.w), math.ceil(size.h)
end

local function freeSlot()
    local i = 1
    while live[i] do i = i + 1 end
    return i
end

function M.show(opts)
    local tint = TINTS[opts.tint] or NEUTRAL
    local elements = {}
    local x = 8 + 28 + 10 -- left pad + icon + gap

    local title = styled(opts.title or "", 13, { white = 1 })
    local titleW, titleH = measure(title)
    local detail, detailW, detailH
    if opts.detail then
        detail = styled(opts.detail, 11, { red = 235 / 255, green = 235 / 255, blue = 245 / 255, alpha = 0.55 }, true)
        detailW, detailH = measure(detail)
    end

    if detail then
        local top = (H - titleH - detailH - 1) / 2
        elements[#elements + 1] = { type = "text", text = title, frame = { x = PAD + x, y = PAD + top, w = titleW + 2, h = titleH } }
        elements[#elements + 1] = { type = "text", text = detail, frame = { x = PAD + x, y = PAD + top + titleH + 1, w = detailW + 2, h = detailH } }
        x = x + math.max(titleW, detailW)
    else
        elements[#elements + 1] = { type = "text", text = title, frame = { x = PAD + x, y = PAD + (H - titleH) / 2, w = titleW + 2, h = titleH } }
        x = x + titleW
    end

    local rightPad = 18
    if opts.segments and #opts.segments > 0 then
        x = x + 10
        local segH, segX = 26, x + 2
        local segs = {}
        for i, label in ipairs(opts.segments) do
            local on = i == opts.active
            local st = styled(label, 12, on and { white = 1 } or { red = 235 / 255, green = 235 / 255, blue = 245 / 255, alpha = 0.6 })
            local w, h = measure(st)
            segs[#segs + 1] = { st = st, x = segX, w = w + 20, h = h, on = on }
            segX = segX + w + 20 + 2
        end
        local containerW = segX - x
        elements[#elements + 1] = {
            type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 0.08 },
            roundedRectRadii = { xRadius = 16, yRadius = 16 },
            frame = { x = PAD + x, y = PAD + (H - segH - 4) / 2, w = containerW, h = segH + 4 },
        }
        for _, s in ipairs(segs) do
            if s.on then
                elements[#elements + 1] = {
                    type = "rectangle", action = "fill", fillColor = { hex = "#0A84FF" },
                    roundedRectRadii = { xRadius = 13, yRadius = 13 },
                    frame = { x = PAD + s.x, y = PAD + (H - segH) / 2, w = s.w, h = segH },
                }
            end
            elements[#elements + 1] = {
                type = "text", text = s.st,
                frame = { x = PAD + s.x + 10, y = PAD + (H - s.h) / 2, w = s.w - 18, h = s.h },
            }
        end
        x = x + containerW
        rightPad = 6
    end

    local capW = x + rightPad
    local icon = styled(opts.icon or "", 13, tint.fg)
    local iconW, iconH = measure(icon)
    -- Background and icon go first so they draw under the text
    table.insert(elements, 1, {
        type = "rectangle", action = "strokeAndFill",
        fillColor = { red = 28 / 255, green = 28 / 255, blue = 30 / 255, alpha = 0.94 },
        strokeColor = { white = 1, alpha = 0.16 }, strokeWidth = 0.5,
        roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
        withShadow = true,
        shadow = { blurRadius = 16, color = { white = 0, alpha = 0.35 }, offset = { h = -8, w = 0 } },
        frame = { x = PAD, y = PAD, w = capW, h = H },
    })
    table.insert(elements, 2, {
        type = "circle", action = "fill", fillColor = tint.bg,
        center = { x = PAD + 8 + 14, y = PAD + H / 2 }, radius = 14,
    })
    table.insert(elements, 3, {
        type = "text", text = icon,
        frame = { x = PAD + 8 + 14 - iconW / 2, y = PAD + (H - iconH) / 2, w = iconW + 2, h = iconH },
    })

    local slot = freeSlot()
    local screen = hs.screen.mainScreen():frame()
    local c = hs.canvas.new({
        x = screen.x + (screen.w - capW) / 2 - PAD,
        y = screen.y + screen.h - BOTTOM - H - (slot - 1) * STACK - PAD,
        w = capW + 2 * PAD,
        h = H + 2 * PAD,
    })
    c:appendElements(elements)
    c:level(hs.canvas.windowLevels.overlay)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    live[slot] = c
    c:show(0.15)

    hs.timer.doAfter(opts.seconds or 2, function()
        live[slot] = nil
        c:delete(0.2)
    end)
    return c
end

return M
