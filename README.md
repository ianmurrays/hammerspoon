# Hammerspoon Config

Personal Hammerspoon configuration for macOS automation — window management, Slack status, encrypted scratchpad, GIF search, and more.

## Modules

| Module | Purpose | Hotkey |
|---|---|---|
| `window_manager` | Rectangle-style window tiling with fraction cycling (1/2, 1/3, 2/3) | Ctrl+Alt+Cmd + arrows/F/Home/End |
| `scratchpad` | Encrypted markdown editor synced via iCloud | Ctrl+Alt+S |
| `gif_finder` | GIF search via Klipy API with favorites and recents, copies URL to clipboard | Ctrl+Alt+G |
| `slack_status` | Auto-updates Slack status based on WiFi network; manual overrides and custom status via menu | — |
| `hyperduck` | Monitors iCloud file for URLs sent from iPhone, opens them on Mac | — |
| `battery_indicator` | Shows remaining battery time in menu bar | — |
| `screen_blur` | Full-screen blur overlay for privacy (downsample trick via `sips`) | Ctrl+Alt+B |
| `stt` | Local speech-to-text via parakeet-mlx daemon with optional LLM post-processing, audio tones, and media pause/resume | fn+Space (toggle) / fn+Shift (hold) |
| `unified_menu` | Combines Slack Status, Hyperduck, Scratchpad, and Screen Blur into a single menubar item | — |

## Hotkeys

| Shortcut | Action |
|---|---|
| Ctrl+Alt+Cmd+Left | Tile window left (cycles 1/2 → 1/3 → 2/3) |
| Ctrl+Alt+Cmd+Right | Tile window right (cycles 1/2 → 1/3 → 2/3) |
| Ctrl+Alt+Cmd+Up | Tile window top (cycles 1/2 → 1/3 → 2/3) |
| Ctrl+Alt+Cmd+Down | Tile window bottom (cycles 1/2 → 1/3 → 2/3) |
| Ctrl+Alt+Cmd+F | Maximize window |
| Ctrl+Alt+Cmd+Home | Move window to previous display |
| Ctrl+Alt+Cmd+End | Move window to next display |
| Ctrl+Alt+S | Toggle scratchpad |
| Ctrl+Alt+G | Toggle GIF finder |
| Ctrl+Alt+B | Toggle screen blur overlay (also dismisses on click or any keypress) |
| fn+Space | Toggle speech-to-text recording (press to start, press again to stop and paste) |
| fn+Shift | Hold-to-talk speech-to-text (hold both to record, release to stop and paste) |

> **Note:** Home = Fn+Left and End = Fn+Right on Mac keyboards.

## File Structure

Webview modules (`gif_finder`, `slack_status`, `scratchpad`) store their HTML, CSS, and JS in separate files under `html/`:

```
html/
  gif_finder/    — GIF search UI
  slack_status/  — Custom status form
  scratchpad/    — CodeMirror markdown editor
```

Each directory contains `index.html`, `style.css`, and `script.js`. At runtime, `html_loader.lua` reads these files and inlines the CSS/JS into the HTML before passing it to `hs.webview:html()`.

## Setup

### Prerequisites

1. Install [Hammerspoon](https://www.hammerspoon.org/)
2. Grant Accessibility permissions when prompted (System Settings → Privacy & Security → Accessibility)

### Keychain Secrets

Store secrets in the macOS Keychain — they are never saved in code.

```bash
# Slack API token (xoxp-...)
security add-generic-password -a "$USER" -s "slack-status-token" -w "YOUR_TOKEN"

# Klipy GIF search API key (https://partner.klipy.com)
security add-generic-password -a "$USER" -s "klipy-api-key" -w "YOUR_API_KEY"

# Mistral API key for STT post-processing (optional — omit to disable)
security add-generic-password -a "$USER" -s "mistral-api-key" -w "YOUR_API_KEY"
```

### STT Daemon

The speech-to-text module requires a local Python daemon running `parakeet-mlx`:

```bash
cd ~/.hammerspoon/stt-daemon
uv sync
uv run stt_daemon.py
```

To run as a background service via launchd:

```bash
cp ~/.hammerspoon/stt-daemon/com.local.stt-daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.local.stt-daemon.plist
```

Logs are written to `~/Library/Logs/stt-daemon.log`.

#### LLM Post-Processing (Optional)

When a Mistral API key is present in the keychain, transcribed text is sent through the Mistral API to remove filler words, fix punctuation/capitalization, and apply light grammar corrections. The pill overlay shows a purple "Polishing..." spinner during this step. If the API call fails or times out (10s), the raw transcription is pasted instead.

Configuration options in `init.lua`:

```lua
stt.init({
    llm_api_key = mistralApiKey,
    -- llm_model = "mistral-small-latest",           -- model to use
    -- llm_system_prompt = "...",                     -- custom prompt
    -- llm_api_url = "https://api.mistral.ai/v1/chat/completions",  -- API endpoint
    -- llm_timeout = 10,                             -- seconds before fallback
})
```

The API uses the OpenAI-compatible chat completions format, so other providers (OpenRouter, Groq, Together, etc.) work by changing `llm_api_url`, `llm_model`, and `llm_api_key`.

#### Audio Tones & Media Control

By default, the STT module plays subtle macOS system sounds at key moments:
- **Tink** — recording starts
- **Pop** — recording stops
- **Glass** — transcription/polishing complete

It also pauses any currently playing media (Spotify, Music, YouTube, etc.) when recording starts and resumes it when recording stops. Media state detection uses [`media-control`](https://github.com/ungive/media-control), which must be installed via Homebrew:

```bash
brew tap ungive/media-control && brew install media-control
```

Both features can be disabled in `init.lua`:

```lua
stt.init({
    play_tones = false,   -- disable notification sounds
    pause_media = false,  -- disable media pause/resume
})
```

The scratchpad encryption key is generated automatically on first use. To copy it to another Mac:

```bash
# Export from source Mac
security find-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w

# Import on target Mac
security add-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w "PASTE_KEY_HERE"
```

### iCloud Sync

The scratchpad, Hyperduck, and GIF Finder modules store files in iCloud Drive:

- **Scratchpad:** `~/Library/Mobile Documents/com~apple~CloudDocs/Scratchpad/scratchpad.txt`
- **Hyperduck:** `~/Library/Mobile Documents/com~apple~CloudDocs/Hyperduck/inbox.txt`
- **GIF Finder:** `~/Library/Mobile Documents/com~apple~CloudDocs/GifFinder/favorites.json` and `recents.json`

Hyperduck requires an iPhone Shortcut that appends timestamped URLs (`timestamp|url` format) to the inbox file. URLs older than 7 days are automatically purged.

## Reloading

After making changes, reload the config:

- **Menu bar:** Click the Hammerspoon icon → Reload Config
- **Console:** Open Hammerspoon console and press Cmd+Shift+R
