-- GIF Finder Module for Hammerspoon
-- Search and copy GIF URLs via Klipy API (https://klipy.com)
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
</style>
</head>
<body>
  <input type="text" id="search-box" placeholder="Search for GIFs..." autofocus>
  <div id="status">Type a search term and press Enter</div>
  <div id="results"></div>
  <script>
    const searchBox = document.getElementById('search-box');
    const status = document.getElementById('status');
    const results = document.getElementById('results');
    const COLS = 3;
    let selectedIndex = -1;

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

    function clearSelection() {
      selectedIndex = -1;
      updateSelection();
    }

    function selectGif(url) {
      window.webkit.messageHandlers.gifFinder.postMessage({
        action: 'select',
        url: url
      });
    }

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
            searchBox.focus();
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
          const url = items[selectedIndex]?.dataset.url;
          if (url) selectGif(url);
        } else if (e.key === 'Escape') {
          e.preventDefault();
          clearSelection();
          searchBox.focus();
        } else if (e.key.length === 1) {
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
            while (results.firstChild) results.removeChild(results.firstChild);
            clearSelection();
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
    });

    window.showResults = function(jsonStr) {
      const gifs = JSON.parse(jsonStr);
      while (results.firstChild) results.removeChild(results.firstChild);
      selectedIndex = -1;

      if (gifs.length === 0) {
        status.className = '';
        status.textContent = 'No results found';
        return;
      }

      status.textContent = '';

      gifs.forEach((gif) => {
        const item = document.createElement('div');
        item.className = 'gif-item';
        item.dataset.url = gif.url;
        const img = document.createElement('img');
        img.src = gif.thumb;
        img.loading = 'lazy';
        item.appendChild(img);
        item.addEventListener('click', () => selectGif(gif.url));
        results.appendChild(item);
      });
    };

    window.showError = function(message) {
      status.className = 'error';
      status.textContent = message;
      while (results.firstChild) results.removeChild(results.firstChild);
      selectedIndex = -1;
    };

    window.resetUI = function() {
      searchBox.value = '';
      while (results.firstChild) results.removeChild(results.firstChild);
      selectedIndex = -1;
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
        -- Guard: webview may have closed while request was in flight
        if not webview or not isVisible then return end

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

        local json = hs.json.encode(gifs):gsub("'", "\\'")
        webview:evaluateJavaScript(string.format("window.showResults('%s')", json))
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
                    hs.pasteboard.setContents(msg.body.url)
                    hs.notify.new({
                        title = "GIF Finder",
                        informativeText = "GIF URL copied to clipboard",
                        withdrawAfter = 3
                    }):send()
                    hideWebview()
                elseif action == "close" then
                    hideWebview()
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
                end
            end)

        webview:html(buildHTML())
    end

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
    webview:evaluateJavaScript("if (window.resetUI) window.resetUI()")

    webview:show()
    webview:hswindow():focus()
    isVisible = true
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
end

return M
