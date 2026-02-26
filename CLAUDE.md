# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Hammerspoon configuration written in Lua. No build step, no tests, no linter. To apply changes, reload the Hammerspoon config (Cmd+Shift+R in Hammerspoon console, or click "Reload Config" in the Hammerspoon menu).

## Architecture

**Entry point:** `init.lua` — requires all modules and calls their `.init(cfg)` methods with configuration.

**Module pattern:** Every module follows the same structure:
```lua
local M = {}
function M.init(cfg) ... return M end
function M.stop() ... end
return M
```

**Modules:**

| Module | Purpose | Hotkey |
|---|---|---|
| `slack_status` | Auto-updates Slack status based on WiFi network; manual overrides and custom status via menu | — |
| `window_manager` | Rectangle-style window tiling with fraction cycling (1/2 → 1/3 → 2/3) | Ctrl+Alt+Cmd + arrows/f/home/end |
| `scratchpad` | Encrypted markdown editor synced via iCloud | Ctrl+Alt+S |
| `gif_finder` | GIF search via Klipy API, copies URL to clipboard | Ctrl+Alt+G |
| `hyperduck` | Monitors iCloud file for URLs sent from iPhone, opens them on Mac | — |
| `battery_indicator` | Shows remaining battery time in menu bar | — |
| `unified_menu` | Combines slack_status, hyperduck, and scratchpad into a single menubar item | — |

**Unified menu integration:** Modules that appear in the unified menubar expose `getMenuItems()` (returns menu table) and optionally `setUpdateCallback(fn)` so the unified menu can refresh when state changes.

**Webview modules** (`scratchpad`, `gif_finder`, `slack_status` custom status form) use `hs.webview` with embedded HTML/JS. Communication between Lua and JS uses `hs.webview.usercontent` message handlers (`window.webkit.messageHandlers.<name>.postMessage(...)`).

## Secrets

All secrets are stored in macOS Keychain, never in code. Retrieved via `security find-generic-password`:
- `slack-status-token` — Slack API token (xoxp-...)
- `klipy-api-key` — Klipy GIF search API key
- `scratchpad-encryption-key` — AES-256-CBC key for scratchpad encryption

## Workflow

- After completing a task, update `README.md` if the changes affect user-facing behavior, setup instructions, hotkeys, or module descriptions.

## Key Conventions

- **Lua scoping:** `local` forward declarations must appear *above* any function that references them (closures capture locals by position). If a function calls a forward-declared local, the `local foo` line must precede the function definition in the source file — not just precede the assignment `foo = function(...)`.
- Webview CSS: scope styles to specific containers (e.g. `.buttons button` not `button`) to avoid bleeding into other elements like emoji grids or custom widgets
- Modules use `hs.http.asyncGet`/`asyncPost` for network calls (non-blocking)
- Window animations are disabled (`hs.window.animationDuration = 0`) for instant snapping
- iCloud paths use `~/Library/Mobile Documents/com~apple~CloudDocs/`
- Slack status uses exponential backoff retry (`retryBaseDelay * 2^retryCount`) and debounced WiFi change handling
