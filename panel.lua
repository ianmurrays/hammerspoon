-- Borderless floating panel shared by the launcher-style webviews
-- (clipboard_history, gif_finder, stt history, scratchpad, slack custom status).
-- The page draws the rounded panel itself (html/panel.css); the window is transparent
-- and MARGIN px larger on each side so the panel's shadow is not clipped.

local M = {}

M.MARGIN = 30

local prevApp = nil

-- Frame for a w×h panel centred on the screen under the mouse
function M.frame(w, h)
    local screen = hs.mouse.getCurrentScreen():frame()
    return {
        x = screen.x + (screen.w - w) / 2 - M.MARGIN,
        y = screen.y + (screen.h - h) / 2 - M.MARGIN,
        w = w + 2 * M.MARGIN,
        h = h + 2 * M.MARGIN,
    }
end

-- onBlur runs when the panel loses key focus (click elsewhere, Cmd+Tab), like Spotlight
function M.new(w, h, usercontent, onBlur)
    return hs.webview.new(M.frame(w, h), { developerExtrasEnabled = false }, usercontent)
        :windowStyle({ "borderless" })
        :transparent(true)
        :allowTextEntry(true)
        :closeOnEscape(false)
        :shadow(false)
        :level(hs.drawing.windowLevels.floating)
        :windowCallback(function(action, _wv, state)
            if action == "focusChange" and state == false and onBlur then onBlur() end
        end)
end

-- Re-centre on the mouse's screen, remember the frontmost app, show and focus
function M.show(wv, w, h)
    local front = hs.application.frontmostApplication()
    if front and front:bundleID() ~= "org.hammerspoon.Hammerspoon" then prevApp = front end
    wv:frame(M.frame(w, h))
    wv:show()
    wv:hswindow():focus()
end

-- Hide; restoreFocus re-activates the app that was frontmost before the panel opened
-- (Escape, Enter). A blur already moved focus somewhere, so it passes false.
function M.hide(wv, restoreFocus)
    wv:hide()
    if restoreFocus and prevApp then prevApp:activate() end
end

return M
