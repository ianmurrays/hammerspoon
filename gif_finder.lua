-- GIF Finder Module for Hammerspoon
-- Search and copy GIF URLs via Klipy API (https://klipy.com)
--
-- Features: GIF search, favorites (synced via iCloud), recents (last 10)
--
-- Setup:
--   1. Sign up at https://partner.klipy.com and create an API key
--   2. Store it in macOS Keychain:
--      security add-generic-password -a "$USER" -s "klipy-api-key" -w "YOUR_API_KEY"
--   3. Reload Hammerspoon config
--
-- Usage: Ctrl+Option+G to toggle the GIF search window

local M = {}
local htmlLoader = require("html_loader")

-- Private state
local webview = nil
local hotkey = nil
local config = {}
local isVisible = false

-- Favorites/Recents state
local favorites = {}
local favoritesSet = {}
local recents = {}
local currentTab = "search"

-- iCloud persistence
local ICLOUD_DIR = os.getenv("HOME") .. "/Library/Mobile Documents/com~apple~CloudDocs/GifFinder"
local FAVORITES_PATH = ICLOUD_DIR .. "/favorites.json"
local RECENTS_PATH = ICLOUD_DIR .. "/recents.json"

-- Forward declaration
local pushFavoritesToJS

local function ensureDirectory()
    hs.fs.mkdir(ICLOUD_DIR)
end

local function readJsonFile(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, decoded = pcall(hs.json.decode, content)
    if not ok then return {} end
    return decoded
end

local function writeJsonFile(path, data)
    ensureDirectory()
    local f = io.open(path, "w")
    if not f then
        print("GIF Finder: Failed to write " .. path)
        return
    end
    f:write(hs.json.encode(data))
    f:close()
end

local function rebuildFavoritesSet()
    favoritesSet = {}
    for _, fav in ipairs(favorites) do
        favoritesSet[fav.url] = true
    end
end

local function loadFavorites()
    favorites = readJsonFile(FAVORITES_PATH)
    rebuildFavoritesSet()
end

local function saveFavorites()
    writeJsonFile(FAVORITES_PATH, favorites)
    rebuildFavoritesSet()
    pushFavoritesToJS()
end

local function loadRecents()
    recents = readJsonFile(RECENTS_PATH)
end

local function saveRecents()
    writeJsonFile(RECENTS_PATH, recents)
end

local function addToRecents(thumb, url)
    local filtered = {}
    for _, r in ipairs(recents) do
        if r.url ~= url then
            table.insert(filtered, r)
        end
    end
    table.insert(filtered, 1, { thumb = thumb, url = url })
    while #filtered > 10 do
        table.remove(filtered)
    end
    recents = filtered
    saveRecents()
end

local function toggleFavorite(thumb, url)
    if favoritesSet[url] then
        local filtered = {}
        for _, fav in ipairs(favorites) do
            if fav.url ~= url then
                table.insert(filtered, fav)
            end
        end
        favorites = filtered
    else
        table.insert(favorites, { thumb = thumb, url = url })
    end
    saveFavorites()
end

local function pushJsonToJS(fnName, data)
    if not webview or not isVisible then return end
    local json = hs.json.encode(data):gsub("'", "\\'")
    webview:evaluateJavaScript(string.format("if (window.%s) window.%s('%s')", fnName, fnName, json))
end

pushFavoritesToJS = function()
    if not webview or not isVisible then return end
    local urls = {}
    for url, _ in pairs(favoritesSet) do
        table.insert(urls, url)
    end
    pushJsonToJS("setFavorites", urls)
end

local function buildHTML()
    return htmlLoader.load("gif_finder")
end

local function hideWebview()
    if webview and isVisible then
        webview:hide()
        isVisible = false
    end
end

local function searchKlipy(query)
    if not config.apiKey then
        if webview and isVisible then
            webview:evaluateJavaScript("window.showError('Klipy API key not configured')")
        end
        return
    end

    local encoded = hs.http.encodeForQuery(query)
    local url = string.format(
        "https://api.klipy.com/api/v1/%s/gifs/search?q=%s&per_page=30&customer_id=hammerspoon&format_filter=gif",
        config.apiKey, encoded
    )

    hs.http.asyncGet(url, nil, function(statusCode, body, _headers)
        if not webview or not isVisible then return end
        if currentTab ~= "search" then return end

        if statusCode ~= 200 then
            webview:evaluateJavaScript(
                string.format("window.showError('Klipy API error (HTTP %d)')", statusCode)
            )
            return
        end

        local ok, parsed = pcall(hs.json.decode, body)
        if not ok or not parsed or not parsed.data or not parsed.data.data then
            webview:evaluateJavaScript("window.showError('Failed to parse response')")
            return
        end

        local gifs = {}
        for _, item in ipairs(parsed.data.data) do
            local thumb = item.file
                and item.file.sm
                and item.file.sm.gif
                and item.file.sm.gif.url
            local full = item.file
                and item.file.hd
                and item.file.hd.gif
                and item.file.hd.gif.url
            if thumb and full then
                table.insert(gifs, { thumb = thumb, url = full })
            end
        end

        pushJsonToJS("showResults", gifs)
    end)
end

local function showWebview()
    if not webview then
        local usercontent = hs.webview.usercontent.new("gifFinder")
            :setCallback(function(msg)
                if type(msg.body) ~= "table" then return end

                local action = msg.body.action
                if action == "search" then
                    searchKlipy(msg.body.query)
                elseif action == "select" then
                    addToRecents(msg.body.thumb, msg.body.url)
                    hs.pasteboard.setContents(msg.body.url)
                    hs.notify.new({
                        title = "GIF Finder",
                        informativeText = "GIF URL copied to clipboard",
                        withdrawAfter = 3
                    }):send()
                    hideWebview()
                elseif action == "selectHtml" then
                    addToRecents(msg.body.thumb, msg.body.url)
                    hs.pasteboard.setContents('<img src="' .. msg.body.url .. '">')
                    hs.notify.new({
                        title = "GIF Finder",
                        informativeText = "GIF img tag copied to clipboard",
                        withdrawAfter = 3
                    }):send()
                    hideWebview()
                elseif action == "close" then
                    hideWebview()
                elseif action == "switchTab" then
                    currentTab = msg.body.tab
                    if msg.body.tab == "favorites" then
                        pushJsonToJS("showResults", favorites)
                    elseif msg.body.tab == "recents" then
                        pushJsonToJS("showResults", recents)
                    end
                elseif action == "toggleFavorite" then
                    toggleFavorite(msg.body.thumb, msg.body.url)
                    if currentTab == "favorites" then
                        pushJsonToJS("showResults", favorites)
                    end
                end
            end)

        local screen = hs.mouse.getCurrentScreen():frame()
        local width = 720
        local height = 500
        local rect = {
            x = screen.x + (screen.w - width) / 2,
            y = screen.y + (screen.h - height) / 2,
            w = width,
            h = height
        }

        webview = hs.webview.new(rect, { developerExtrasEnabled = false }, usercontent)
            :allowTextEntry(true)
            :windowStyle({"titled", "closable", "resizable"})
            :windowTitle("GIF Finder")
            :closeOnEscape(false)
            :windowCallback(function(action, _wv, _state)
                if action == "closing" then
                    isVisible = false
                    webview = nil
                end
            end)

        webview:html(buildHTML())
    end

    -- Reload data from disk (picks up iCloud sync changes)
    loadFavorites()
    loadRecents()

    -- Reposition to cursor's screen each time
    local screen = hs.mouse.getCurrentScreen():frame()
    local width = 720
    local height = 500
    webview:frame({
        x = screen.x + (screen.w - width) / 2,
        y = screen.y + (screen.h - height) / 2,
        w = width,
        h = height
    })

    -- Reset UI on re-show
    currentTab = "search"
    webview:evaluateJavaScript("if (window.resetUI) window.resetUI()")

    webview:show()
    webview:hswindow():focus()
    isVisible = true

    -- Push favorites set for star rendering
    pushFavoritesToJS()
end

local function toggleWebview()
    if isVisible then
        hideWebview()
    else
        showWebview()
    end
end

-- Public API

function M.init(cfg)
    config.apiKey = cfg.apiKey
    config.hotkey = cfg.hotkey or { {"ctrl", "alt"}, "g" }

    if not config.apiKey then
        print("GIF Finder: Klipy API key not found. Store it with:")
        print('  security add-generic-password -a "$USER" -s "klipy-api-key" -w "YOUR_API_KEY"')
        print("  Then reload Hammerspoon config.")
        return M
    end

    loadFavorites()
    loadRecents()

    hotkey = hs.hotkey.bind(config.hotkey[1], config.hotkey[2], toggleWebview)

    print("GIF Finder loaded (Ctrl+Option+G to toggle)")
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
    favorites = {}
    favoritesSet = {}
    recents = {}
    currentTab = "search"
end

return M
