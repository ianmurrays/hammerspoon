-- Scratchpad Module for Hammerspoon
-- A simple textarea that syncs to iCloud

local M = {}

-- Private state
local webview = nil
local menubarItem = nil
local hotkey = nil
local config = {}
local isVisible = false
local isTransitioning = false

-- File I/O

local function ensureDirectory()
    local dir = config.filePath:match("(.+)/[^/]+$")
    hs.fs.mkdir(dir)
end

local function readFile()
    local f = io.open(config.filePath, "r")
    if not f then
        ensureDirectory()
        f = io.open(config.filePath, "w")
        if f then f:close() end
        return ""
    end
    local content = f:read("*a")
    f:close()
    return content or ""
end

local function saveFile(content)
    ensureDirectory()
    local f = io.open(config.filePath, "w")
    if f then
        f:write(content or "")
        f:close()
        print("Scratchpad saved")
        return true
    end
    print("Scratchpad: Failed to save file")
    hs.notify.new({
        title = "Scratchpad",
        informativeText = "Failed to save - check iCloud folder permissions",
        withdrawAfter = 5
    }):send()
    return false
end

-- HTML template

local function buildHTML(content)
    -- Only escape closing textarea tag to prevent breaking out of the element
    local escaped = content:gsub("</textarea>", "&lt;/textarea&gt;")

    return [[
<!DOCTYPE html>
<html>
<head>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      background: #1e1e1e;
      padding: 16px;
    }
    textarea {
      width: 100%;
      height: calc(100vh - 32px);
      border: none;
      outline: none;
      resize: none;
      font-size: 14px;
      line-height: 1.5;
      font-family: 'SF Mono', Menlo, Monaco, monospace;
      background: #1e1e1e;
      color: #d4d4d4;
      padding: 8px;
      border-radius: 4px;
    }
    textarea::placeholder { color: #666; }
  </style>
</head>
<body>
  <textarea id="content" placeholder="Type here..." autofocus>]] .. escaped .. [[</textarea>
  <script>
    const textarea = document.getElementById('content');

    function save(andClose) {
      window.webkit.messageHandlers.scratchpad.postMessage({
        action: andClose ? 'save_and_close' : 'save',
        content: textarea.value
      });
    }

    // Save on blur
    textarea.addEventListener('blur', () => save(false));

    // Escape to save and close
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        save(true);
      }
      // Cmd+S to save
      if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault();
        save(false);
      }
    });
  </script>
</body>
</html>
]]
end

-- WebView management

local function hideWebview()
    if webview and isVisible then
        webview:hide()
        isVisible = false
        print("Scratchpad hidden")
    end
end

local function showWebview()
    if not webview then
        -- Create user content controller for JS -> Lua messages
        local usercontent = hs.webview.usercontent.new("scratchpad")
            :setCallback(function(msg)
                if type(msg.body) == "table" then
                    saveFile(msg.body.content)
                    if msg.body.action == "save_and_close" then
                        hideWebview()
                    end
                end
            end)

        -- Get screen dimensions for centering
        local screen = hs.screen.mainScreen():frame()
        local width = 600
        local height = 400
        local rect = {
            x = (screen.w - width) / 2,
            y = (screen.h - height) / 2,
            w = width,
            h = height
        }

        webview = hs.webview.new(rect, { developerExtrasEnabled = false }, usercontent)
            :allowTextEntry(true)
            :windowStyle({"titled", "closable", "resizable"})
            :windowTitle("Scratchpad")
            :closeOnEscape(false) -- We handle Escape manually for saving
            :windowCallback(function(action, wv, state)
                if action == "closing" then
                    -- Save before hiding
                    webview:evaluateJavaScript(
                        "document.getElementById('content').value",
                        function(result, error)
                            if result then saveFile(result) end
                        end
                    )
                    isVisible = false
                end
            end)
    end

    -- Load current content
    local content = readFile()
    webview:html(buildHTML(content))
    webview:show()
    webview:hswindow():focus()
    isVisible = true
    print("Scratchpad shown")
end

local function toggleWebview()
    if isTransitioning then return end

    if isVisible then
        isTransitioning = true
        if webview then
            webview:evaluateJavaScript(
                "document.getElementById('content').value",
                function(result, error)
                    if result then saveFile(result) end
                    hideWebview()
                    isTransitioning = false
                end
            )
        else
            hideWebview()
            isTransitioning = false
        end
    else
        showWebview()
    end
end

-- Menu bar

local function buildMenu()
    return {
        { title = "Show Scratchpad", fn = toggleWebview },
        { title = "-" },
        { title = "Open in Finder", fn = function()
            local dir = config.filePath:match("(.+)/[^/]+$")
            hs.open(dir)
        end }
    }
end

-- Public API

function M.init(cfg)
    config.filePath = cfg.filePath or (os.getenv("HOME") .. "/Library/Mobile Documents/com~apple~CloudDocs/Scratchpad/scratchpad.txt")
    config.hotkey = cfg.hotkey or { {"ctrl", "alt"}, "s" }

    -- Menu bar
    menubarItem = hs.menubar.new()
    menubarItem:setTitle("📝")
    menubarItem:setMenu(buildMenu)

    -- Hotkey
    hotkey = hs.hotkey.bind(config.hotkey[1], config.hotkey[2], toggleWebview)

    print("Scratchpad loaded (Ctrl+Option+S to toggle)")
    return M
end

function M.stop()
    if webview then
        webview:delete()
        webview = nil
    end
    if menubarItem then
        menubarItem:delete()
        menubarItem = nil
    end
    if hotkey then
        hotkey:delete()
        hotkey = nil
    end
    isVisible = false
    print("Scratchpad stopped")
end

return M
