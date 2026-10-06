-- Scratchpad Module for Hammerspoon
-- A simple textarea that syncs to iCloud with E2E encryption
--
-- To copy the encryption key to another Mac:
-- 1. Run: security find-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w
-- 2. Copy the output
-- 3. On the other Mac, run:
--    security add-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w "PASTE_KEY_HERE"

local M = {}
local htmlLoader = require("html_loader")
local panel = require("panel")

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

local function checkForConflicts()
    local dir = config.filePath:match("(.+)/[^/]+$")
    local basename = config.filePath:match("([^/]+)$"):match("(.+)%..+$")  -- "scratchpad"

    local conflicts = {}
    for file in hs.fs.dir(dir) do
        -- Match patterns like "scratchpad 2.txt", "scratchpad (1).txt"
        if file:match("^" .. basename .. " %d+%.") or file:match("^" .. basename .. " %(") then
            table.insert(conflicts, file)
        end
    end

    if #conflicts > 0 then
        hs.notify.new({
            title = "Scratchpad",
            informativeText = "iCloud conflict detected: " .. table.concat(conflicts, ", "),
            withdrawAfter = 15
        }):send()
        return true
    end
    return false
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
    -- "</" must become "<\/" so content containing "</script>" can't terminate the inlined script block
    local escaped = content:gsub("\\", "\\\\"):gsub("`", "\\`"):gsub("${", "\\${"):gsub("</", "<\\/")
    return htmlLoader.load("scratchpad", { ["{{CONTENT}}"] = escaped })
end

-- WebView management

-- Sentinel returned when the editor JS never initialized (e.g. CodeMirror CDN unreachable);
-- saving in that state would overwrite the file with empty content
local EDITOR_NOT_READY = "__SCRATCHPAD_EDITOR_NOT_READY__"
local GET_CONTENT_JS = "window.getEditorValue ? window.getEditorValue() : '" .. EDITOR_NOT_READY .. "'"

local WIDTH, HEIGHT = 640, 440

-- Save, then tell the page so its status line reads "Saved"
local function saveAndReport(content)
    if saveFile(content) and webview then
        webview:evaluateJavaScript("window.setStatus && setStatus('saved')")
    end
end

-- restoreFocus: re-activate the previous app (Escape, hotkey); a blur passes false
local function hideWebview(restoreFocus)
    if webview and isVisible then
        isVisible = false
        panel.hide(webview, restoreFocus)
        print("Scratchpad hidden")
    end
end

-- Read the editor, save, then hide
local function saveAndHide(restoreFocus)
    if isTransitioning or not (webview and isVisible) then return end
    isTransitioning = true
    webview:evaluateJavaScript(
        GET_CONTENT_JS,
        function(result, error)
            if result and result ~= EDITOR_NOT_READY then saveAndReport(result) end
            hideWebview(restoreFocus)
            isTransitioning = false
        end
    )
end

local function showWebview()
    if not webview then
        -- Create user content controller for JS -> Lua messages
        local usercontent = hs.webview.usercontent.new("scratchpad")
            :setCallback(function(msg)
                if type(msg.body) == "table" then
                    saveAndReport(msg.body.content)
                    if msg.body.action == "save_and_close" then
                        hideWebview(true)
                    end
                end
            end)

        -- Clicking elsewhere saves and hides, like Spotlight
        webview = panel.new(WIDTH, HEIGHT, usercontent, function() saveAndHide(false) end)
    end

    -- Check for iCloud conflicts
    checkForConflicts()

    -- Load current content
    local content = readFile()
    if content == nil then
        -- Decryption failed, don't show webview
        print("Scratchpad: cannot open - decryption failed")
        return
    end
    webview:html(buildHTML(content))
    panel.show(webview, WIDTH, HEIGHT)
    isVisible = true
    print("Scratchpad shown")
end

local function toggleWebview()
    if isTransitioning then return end

    if isVisible then
        saveAndHide(true)
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
    if hotkey then
        hotkey:delete()
        hotkey = nil
    end
    isVisible = false
    print("Scratchpad stopped")
end

-- Function for unified menu integration

function M.getMenuItems()
    return buildMenu()
end

return M
