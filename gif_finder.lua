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
    return [[
<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #212121;
    font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
    color: #e0e0e0;
    padding: 12px;
    height: 100vh;
    display: flex;
    flex-direction: column;
  }
  #search-box {
    width: 100%;
    padding: 10px 14px;
    font-size: 15px;
    background: #2c2c2c;
    border: 1px solid #444;
    border-radius: 6px;
    color: #e0e0e0;
    outline: none;
    flex-shrink: 0;
  }
  #search-box:focus { border-color: #6c9bff; }
  #search-box::placeholder { color: #777; }
  #tabs {
    display: flex;
    margin-top: 8px;
    flex-shrink: 0;
    border-bottom: 1px solid #444;
  }
  #tabs button {
    flex: 1;
    padding: 8px 0;
    background: none;
    border: none;
    color: #888;
    font-size: 13px;
    cursor: pointer;
    border-bottom: 2px solid transparent;
    font-family: inherit;
  }
  #tabs button:hover { color: #ccc; }
  #tabs button.active {
    color: #6c9bff;
    border-bottom-color: #6c9bff;
  }
  #status {
    text-align: center;
    padding: 16px;
    color: #888;
    font-size: 13px;
    flex-shrink: 0;
  }
  #status.error { color: #ff6b6b; }
  #results {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    grid-auto-rows: 150px;
    gap: 8px;
    margin-top: 10px;
    overflow-y: auto;
    min-height: 0;
    flex: 1;
  }
  .gif-item {
    border-radius: 6px;
    overflow: hidden;
    cursor: pointer;
    background: #2c2c2c;
    position: relative;
  }
  .gif-item:hover { outline: 2px solid #6c9bff; }
  .gif-item.selected { outline: 3px solid #6c9bff; }
  .gif-item img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
  .gif-item .star-btn {
    position: absolute;
    top: 4px;
    right: 4px;
    width: 28px;
    height: 28px;
    background: rgba(0,0,0,0.6);
    border: none;
    border-radius: 50%;
    cursor: pointer;
    font-size: 16px;
    line-height: 28px;
    text-align: center;
    color: #888;
    padding: 0;
    opacity: 0;
    transition: opacity 0.15s;
    z-index: 2;
  }
  .gif-item:hover .star-btn,
  .gif-item.selected .star-btn { opacity: 1; }
  .gif-item .star-btn.favorited { color: #ffd700; opacity: 1; }
</style>
</head>
<body>
  <input type="text" id="search-box" placeholder="Search for GIFs..." autofocus>
  <div id="tabs">
    <button class="active" data-tab="search">Search</button>
    <button data-tab="favorites">Favorites</button>
    <button data-tab="recents">Recents</button>
  </div>
  <div id="status">Type a search term and press Enter</div>
  <div id="results"></div>
  <script>
    const searchBox = document.getElementById('search-box');
    const status = document.getElementById('status');
    const results = document.getElementById('results');
    const COLS = 3;
    let selectedIndex = -1;
    let currentTab = 'search';
    let favoritesSet = new Set();

    function getItems() {
      return results.querySelectorAll('.gif-item');
    }

    function updateSelection() {
      getItems().forEach((el, i) => {
        el.classList.toggle('selected', i === selectedIndex);
      });
      const items = getItems();
      if (selectedIndex >= 0 && items[selectedIndex]) {
        items[selectedIndex].scrollIntoView({ block: 'nearest' });
      }
    }

    function clearGrid() {
      while (results.firstChild) results.removeChild(results.firstChild);
      selectedIndex = -1;
    }

    function clearSelection() {
      selectedIndex = -1;
      updateSelection();
    }

    function selectGif(url, thumb) {
      window.webkit.messageHandlers.gifFinder.postMessage({
        action: 'select',
        url: url,
        thumb: thumb
      });
    }

    function renderGrid(gifs) {
      clearGrid();

      if (gifs.length === 0) {
        status.className = '';
        if (currentTab === 'search') {
          status.textContent = 'No results found';
        } else if (currentTab === 'favorites') {
          status.textContent = 'No favorites yet \u2014 star GIFs from search results';
        } else {
          status.textContent = 'No recent GIFs';
        }
        return;
      }

      status.textContent = '';

      gifs.forEach((gif) => {
        const item = document.createElement('div');
        item.className = 'gif-item';
        item.dataset.url = gif.url;
        item.dataset.thumb = gif.thumb;

        const star = document.createElement('button');
        const isFav = favoritesSet.has(gif.url);
        star.className = 'star-btn' + (isFav ? ' favorited' : '');
        star.textContent = isFav ? '\u2605' : '\u2606';
        star.addEventListener('click', (e) => {
          e.stopPropagation();
          window.webkit.messageHandlers.gifFinder.postMessage({
            action: 'toggleFavorite',
            thumb: gif.thumb,
            url: gif.url
          });
        });
        item.appendChild(star);

        const img = document.createElement('img');
        img.src = gif.thumb;
        img.loading = 'lazy';
        item.appendChild(img);
        item.addEventListener('click', () => selectGif(gif.url, gif.thumb));
        results.appendChild(item);
      });
    }

    function switchTab(tabName) {
      currentTab = tabName;
      document.querySelectorAll('#tabs button').forEach(b => {
        b.classList.toggle('active', b.dataset.tab === tabName);
      });

      clearGrid();

      if (tabName === 'search') {
        searchBox.style.display = '';
        status.className = '';
        status.textContent = 'Type a search term and press Enter';
        searchBox.focus();
      } else {
        searchBox.style.display = 'none';
        status.className = '';
        status.textContent = '';
      }

      window.webkit.messageHandlers.gifFinder.postMessage({
        action: 'switchTab',
        tab: tabName
      });
    }

    document.querySelectorAll('#tabs button').forEach(btn => {
      btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    document.addEventListener('keydown', (e) => {
      const items = getItems();
      const inGrid = selectedIndex >= 0;

      if (inGrid) {
        if (e.key === 'ArrowDown') {
          e.preventDefault();
          const next = selectedIndex + COLS;
          if (next < items.length) selectedIndex = next;
          updateSelection();
        } else if (e.key === 'ArrowUp') {
          e.preventDefault();
          const next = selectedIndex - COLS;
          if (next < 0) {
            clearSelection();
            if (currentTab === 'search') {
              searchBox.focus();
            }
          } else {
            selectedIndex = next;
            updateSelection();
          }
        } else if (e.key === 'ArrowLeft') {
          e.preventDefault();
          if (selectedIndex > 0) {
            selectedIndex--;
            updateSelection();
          }
        } else if (e.key === 'ArrowRight') {
          e.preventDefault();
          if (selectedIndex < items.length - 1) {
            selectedIndex++;
            updateSelection();
          }
        } else if (e.key === 'Enter') {
          e.preventDefault();
          const item = items[selectedIndex];
          const url = item?.dataset.url;
          const thumb = item?.dataset.thumb;
          if (url) selectGif(url, thumb);
        } else if (e.key === 'Escape') {
          e.preventDefault();
          clearSelection();
          if (currentTab === 'search') {
            searchBox.focus();
          }
        } else if (e.key.length === 1 && currentTab === 'search') {
          clearSelection();
          searchBox.focus();
        }
        return;
      }

      // Search box mode
      if (document.activeElement === searchBox) {
        if (e.key === 'Enter') {
          e.preventDefault();
          const query = searchBox.value.trim();
          if (query) {
            status.className = '';
            status.textContent = 'Searching...';
            clearGrid();
            window.webkit.messageHandlers.gifFinder.postMessage({
              action: 'search',
              query: query
            });
          }
        } else if (e.key === 'Escape') {
          e.preventDefault();
          window.webkit.messageHandlers.gifFinder.postMessage({ action: 'close' });
        } else if ((e.key === 'ArrowDown' || e.key === 'Tab') && items.length > 0) {
          e.preventDefault();
          selectedIndex = 0;
          updateSelection();
          searchBox.blur();
        }
      }

      // Non-search tab, not in grid
      if (currentTab !== 'search' && !inGrid) {
        if ((e.key === 'ArrowDown' || e.key === 'Tab') && items.length > 0) {
          e.preventDefault();
          selectedIndex = 0;
          updateSelection();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          window.webkit.messageHandlers.gifFinder.postMessage({ action: 'close' });
        }
      }
    });

    window.showResults = function(jsonStr) {
      const gifs = JSON.parse(jsonStr);
      renderGrid(gifs);
    };

    window.showError = function(message) {
      status.className = 'error';
      status.textContent = message;
      clearGrid();
    };

    window.setFavorites = function(jsonStr) {
      const urls = JSON.parse(jsonStr);
      favoritesSet = new Set(urls);
      document.querySelectorAll('.gif-item').forEach(item => {
        const star = item.querySelector('.star-btn');
        if (star) {
          const isFav = favoritesSet.has(item.dataset.url);
          star.className = 'star-btn' + (isFav ? ' favorited' : '');
          star.textContent = isFav ? '\u2605' : '\u2606';
        }
      });
    };

    window.resetUI = function() {
      searchBox.value = '';
      searchBox.style.display = '';
      clearGrid();
      currentTab = 'search';
      document.querySelectorAll('#tabs button').forEach(b => {
        b.classList.toggle('active', b.dataset.tab === 'search');
      });
      status.className = '';
      status.textContent = 'Type a search term and press Enter';
      searchBox.focus();
    };
  </script>
</body>
</html>
]]
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
