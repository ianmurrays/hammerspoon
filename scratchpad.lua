-- Scratchpad Module for Hammerspoon
-- A simple textarea that syncs to iCloud with E2E encryption
--
-- To copy the encryption key to another Mac:
-- 1. Run: security find-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w
-- 2. Copy the output
-- 3. On the other Mac, run:
--    security add-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w "PASTE_KEY_HERE"

local M = {}

-- Private state
local webview = nil
local menubarItem = nil
local hotkey = nil
local config = {}
local isVisible = false
local isTransitioning = false

-- Keychain constants
local KEYCHAIN_ACCOUNT = "hammerspoon"
local KEYCHAIN_SERVICE = "scratchpad-encryption-key"

local function getEncryptionKey()
    local cmd = string.format(
        'security find-generic-password -a "%s" -s "%s" -w 2>/dev/null',
        KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE
    )
    local output, status = hs.execute(cmd)
    if status and output and #output > 0 then
        return output:gsub("%s+$", "")
    end
    return nil
end

local function createEncryptionKey()
    local genCmd = "openssl rand -base64 32"
    local key, genStatus = hs.execute(genCmd)
    if not genStatus or not key then
        return nil, "Failed to generate key"
    end
    key = key:gsub("%s+$", "")

    local storeCmd = string.format(
        'security add-generic-password -a "%s" -s "%s" -w "%s"',
        KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE, key
    )
    local _, storeStatus = hs.execute(storeCmd)
    if not storeStatus then
        return nil, "Failed to store key in Keychain"
    end

    return key
end

-- Encryption helpers

local function encrypt(plaintext, key)
    local encoded = hs.base64.encode(plaintext)
    local cmd = string.format(
        'echo "%s" | base64 -d | openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:%s -base64',
        encoded, key
    )
    local output, status = hs.execute(cmd)
    if status and output then
        return output:gsub("%s+$", "")
    end
    return nil
end

local function decrypt(ciphertext, key)
    local cmd = string.format(
        'echo "%s" | openssl enc -aes-256-cbc -pbkdf2 -d -pass pass:%s -base64 2>/dev/null',
        ciphertext:gsub("%s+$", ""), key
    )
    local output, status = hs.execute(cmd)
    if status and output then
        return output
    end
    return nil
end

local function isEncrypted(content)
    return content:match("^U2FsdGVk")
end

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

    if not content or content == "" then
        return ""
    end

    if isEncrypted(content) then
        -- Encrypted file: MUST have key, error if missing
        local key = getEncryptionKey()
        if not key then
            hs.notify.new({
                title = "Scratchpad",
                informativeText = "Encryption key not found in Keychain. Import the key first.",
                withdrawAfter = 10
            }):send()
            return nil  -- Signal error to caller
        end

        local decrypted = decrypt(content, key)
        if decrypted then
            return decrypted
        else
            hs.notify.new({
                title = "Scratchpad",
                informativeText = "Decryption failed - wrong key or corrupted file",
                withdrawAfter = 5
            }):send()
            return nil
        end
    else
        -- Plaintext file (migration): will be encrypted on save
        return content
    end
end

local function saveFile(content)
    ensureDirectory()

    -- Check if existing file is encrypted
    local existingFile = io.open(config.filePath, "r")
    local existingContent = existingFile and existingFile:read("*a") or ""
    if existingFile then existingFile:close() end

    local key = getEncryptionKey()

    -- If encrypted file exists but no key, refuse to overwrite
    if isEncrypted(existingContent) and not key then
        hs.notify.new({
            title = "Scratchpad",
            informativeText = "Cannot save: encryption key not found. Import the key first.",
            withdrawAfter = 10
        }):send()
        return false
    end

    -- Create key if needed (new file or plaintext migration)
    if not key then
        key = createEncryptionKey()
        if not key then
            hs.notify.new({
                title = "Scratchpad",
                informativeText = "Failed to create encryption key",
                withdrawAfter = 5
            }):send()
            return false
        end
    end

    local encrypted = encrypt(content or "", key)
    if not encrypted then
        hs.notify.new({
            title = "Scratchpad",
            informativeText = "Encryption failed",
            withdrawAfter = 5
        }):send()
        return false
    end

    local f = io.open(config.filePath, "w")
    if f then
        f:write(encrypted)
        f:close()
        print("Scratchpad saved (encrypted)")
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
    -- Escape backslashes and backticks for JavaScript string embedding
    local escaped = content:gsub("\\", "\\\\"):gsub("`", "\\`"):gsub("${", "\\${")

    return [[
<!DOCTYPE html>
<html>
<head>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.css">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/theme/material-darker.min.css">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { background: #212121; padding: 8px; height: 100vh; }
    .CodeMirror {
      height: calc(100vh - 16px);
      font-family: 'SF Mono', Menlo, Monaco, monospace;
      font-size: 14px;
      line-height: 1.5;
      border-radius: 4px;
    }
  </style>
</head>
<body>
  <textarea id="content"></textarea>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/mode/markdown/markdown.min.js"></script>
  <script>
    const initialContent = `]] .. escaped .. [[`;
    const editor = CodeMirror.fromTextArea(document.getElementById('content'), {
      mode: 'markdown',
      theme: 'material-darker',
      lineWrapping: true,
      autofocus: true,
      lineNumbers: false,
      viewportMargin: Infinity
    });
    editor.setValue(initialContent);

    // Expose getValue for Lua callbacks
    window.getEditorValue = () => editor.getValue();

    function save(andClose) {
      window.webkit.messageHandlers.scratchpad.postMessage({
        action: andClose ? 'save_and_close' : 'save',
        content: editor.getValue()
      });
    }

    // Save on blur
    editor.on('blur', () => save(false));

    // Escape to save and close, Cmd+S to save
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        save(true);
      }
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

        -- Get screen dimensions for centering (use screen where mouse cursor is)
        local screen = hs.mouse.getCurrentScreen():frame()
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
                        "window.getEditorValue ? window.getEditorValue() : ''",
                        function(result, error)
                            if result then saveFile(result) end
                        end
                    )
                    isVisible = false
                end
            end)
    end

    -- Reposition to cursor's screen each time
    local screen = hs.mouse.getCurrentScreen():frame()
    local width = 600
    local height = 400
    webview:frame({
        x = screen.x + (screen.w - width) / 2,
        y = screen.y + (screen.h - height) / 2,
        w = width,
        h = height
    })

    -- Load current content
    local content = readFile()
    if content == nil then
        -- Decryption failed, don't show webview
        print("Scratchpad: cannot open - decryption failed")
        return
    end
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
                "window.getEditorValue ? window.getEditorValue() : ''",
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
