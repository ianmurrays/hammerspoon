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
local panel = require("panel")

local WIDTH, HEIGHT = 740, 520

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

-- Stored GIF: { thumb, url, width, height, title }; entries saved before the redesign
-- only have thumb and url, and the UI treats them as square and untitled.
local function gifEntry(g)
    return { thumb = g.thumb, url = g.url, width = g.width, height = g.height, title = g.title }
end

local function addToRecents(gif)
    local filtered = {}
    for _, r in ipairs(recents) do
        if r.url ~= gif.url then
            table.insert(filtered, r)
        end
    end
    table.insert(filtered, 1, gifEntry(gif))
    while #filtered > 10 do
        table.remove(filtered)
    end
    recents = filtered
    saveRecents()
end

local function toggleFavorite(gif)
    if favoritesSet[gif.url] then
        local filtered = {}
        for _, fav in ipairs(favorites) do
            if fav.url ~= gif.url then
                table.insert(filtered, fav)
            end
        end
        favorites = filtered
    else
        table.insert(favorites, gifEntry(gif))
    end
    saveFavorites()
end

local function pushJsonToJS(fnName, data)
    if not webview or not isVisible then return end
    -- JSON is a valid JS literal, so it is passed as-is (no string escaping to get wrong)
    webview:evaluateJavaScript(string.format("if (window.%s) window.%s(%s)", fnName, fnName, hs.json.encode(data)))
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

local function hideWebview(restoreFocus)
    if webview and isVisible then
        isVisible = false
        panel.hide(webview, restoreFocus)
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
            local sm = item.file and item.file.sm and item.file.sm.gif
            local hd = item.file and item.file.hd and item.file.hd.gif
            if sm and sm.url and hd and hd.url then
                table.insert(gifs, {
                    thumb = sm.url,
                    url = hd.url,
                    width = tonumber(sm.width or hd.width),
                    height = tonumber(sm.height or hd.height),
                    title = item.title,
                })
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
                    addToRecents(msg.body.gif)
                    hs.pasteboard.setContents(msg.body.gif.url)
                    hs.notify.new({
                        title = "GIF Finder",
                        informativeText = "GIF URL copied to clipboard",
                        withdrawAfter = 3
                    }):send()
                    hideWebview(true)
                elseif action == "selectHtml" then
                    addToRecents(msg.body.gif)
                    hs.pasteboard.setContents('<img src="' .. msg.body.gif.url .. '">')
                    hs.notify.new({
                        title = "GIF Finder",
                        informativeText = "GIF img tag copied to clipboard",
                        withdrawAfter = 3
                    }):send()
                    hideWebview(true)
                elseif action == "close" then
                    hideWebview(true)
                elseif action == "switchTab" then
                    currentTab = msg.body.tab
                    if msg.body.tab == "favorites" then
                        pushJsonToJS("showResults", favorites)
                    elseif msg.body.tab == "recents" then
                        pushJsonToJS("showResults", recents)
                    end
                elseif action == "toggleFavorite" then
                    toggleFavorite(msg.body.gif)
                    if currentTab == "favorites" then
                        pushJsonToJS("showResults", favorites)
                    end
                end
            end)

        webview = panel.new(WIDTH, HEIGHT, usercontent, function() hideWebview(false) end)

        webview:html(buildHTML())
    end

    -- Reload data from disk (picks up iCloud sync changes)
    loadFavorites()
    loadRecents()

    -- Reset UI on re-show
    currentTab = "search"
    webview:evaluateJavaScript("if (window.resetUI) window.resetUI()")

    isVisible = true
    panel.show(webview, WIDTH, HEIGHT)

    -- Push favorites set for star rendering
    pushFavoritesToJS()
end

local function toggleWebview()
    if isVisible then
        hideWebview(true)
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
