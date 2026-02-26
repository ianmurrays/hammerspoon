# Hammerspoon Config

Personal Hammerspoon configuration for macOS automation — window management, Slack status, encrypted scratchpad, GIF search, and more.

## Modules

| Module | Purpose | Hotkey |
|---|---|---|
| `window_manager` | Rectangle-style window tiling with fraction cycling (1/2, 1/3, 2/3) | Ctrl+Alt+Cmd + arrows/F/Home/End |
| `scratchpad` | Encrypted markdown editor synced via iCloud | Ctrl+Alt+S |
| `gif_finder` | GIF search via Klipy API, copies URL to clipboard | Ctrl+Alt+G |
| `slack_status` | Auto-updates Slack status based on WiFi network; manual overrides and custom status via menu | — |
| `hyperduck` | Monitors iCloud file for URLs sent from iPhone, opens them on Mac | — |
| `battery_indicator` | Shows remaining battery time in menu bar | — |
| `screen_blur` | Full-screen blur overlay for privacy (downsample trick via `sips`) | Ctrl+Alt+B |
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

> **Note:** Home = Fn+Left and End = Fn+Right on Mac keyboards.

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
```

The scratchpad encryption key is generated automatically on first use. To copy it to another Mac:

```bash
# Export from source Mac
security find-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w

# Import on target Mac
security add-generic-password -a "hammerspoon" -s "scratchpad-encryption-key" -w "PASTE_KEY_HERE"
```

### iCloud Sync

The scratchpad and Hyperduck modules store files in iCloud Drive:

- **Scratchpad:** `~/Library/Mobile Documents/com~apple~CloudDocs/Scratchpad/scratchpad.txt`
- **Hyperduck:** `~/Library/Mobile Documents/com~apple~CloudDocs/Hyperduck/inbox.txt`

Hyperduck requires an iPhone Shortcut that appends timestamped URLs (`timestamp|url` format) to the inbox file. URLs older than 7 days are automatically purged.

## Reloading

After making changes, reload the config:

- **Menu bar:** Click the Hammerspoon icon → Reload Config
- **Console:** Open Hammerspoon console and press Cmd+Shift+R
