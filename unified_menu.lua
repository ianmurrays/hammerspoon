-- Unified Menu Module for Hammerspoon
-- Combines hyperduck, scratchpad, and slack_status into a single menubar

local M = {}

-- Private state
local menubarItem = nil
local modules = {}

-- Build the unified menu from all modules
local function buildUnifiedMenu()
    local menu = {}

    -- Slack Status section
    table.insert(menu, { title = "Slack Status", disabled = true })
    local slackItems = modules.slackStatus and modules.slackStatus.getMenuItems()
    if slackItems and type(slackItems) == "table" then
        for _, item in ipairs(slackItems) do
            table.insert(menu, item)
        end
    end

    -- Separator
    table.insert(menu, { title = "-" })

    -- Hyperduck section
    table.insert(menu, { title = "Hyperduck", disabled = true })
    local hyperduckItems = modules.hyperduck and modules.hyperduck.getMenuItems()
    if hyperduckItems and type(hyperduckItems) == "table" then
        for _, item in ipairs(hyperduckItems) do
            table.insert(menu, item)
        end
    end

    -- Separator
    table.insert(menu, { title = "-" })

    -- Scratchpad section
    table.insert(menu, { title = "Scratchpad", disabled = true })
    local scratchpadItems = modules.scratchpad and modules.scratchpad.getMenuItems()
    if scratchpadItems and type(scratchpadItems) == "table" then
        for _, item in ipairs(scratchpadItems) do
            table.insert(menu, item)
        end
    end

    -- Separator
    table.insert(menu, { title = "-" })

    -- Screen Blur section
    table.insert(menu, { title = "Screen Blur", disabled = true })
    local screenBlurItems = modules.screenBlur and modules.screenBlur.getMenuItems()
    if screenBlurItems and type(screenBlurItems) == "table" then
        for _, item in ipairs(screenBlurItems) do
            table.insert(menu, item)
        end
    end

    return menu
end

-- Update the menubar icon and menu
local function updateMenuBar()
    if not menubarItem then
        return
    end

    -- Get current emoji from Slack Status module
    local emoji = "💬"
    if modules.slackStatus and modules.slackStatus.getCurrentEmoji then
        emoji = modules.slackStatus.getCurrentEmoji()
    end

    menubarItem:setTitle(emoji)
    menubarItem:setMenu(buildUnifiedMenu)
end

-- Public API

function M.init(cfg)
    modules.hyperduck = cfg.hyperduck
    modules.scratchpad = cfg.scratchpad
    modules.slackStatus = cfg.slackStatus
    modules.screenBlur = cfg.screenBlur

    -- Create menubar
    menubarItem = hs.menubar.new()
    updateMenuBar()

    -- Register for updates from modules that support it
    if modules.slackStatus and modules.slackStatus.setUpdateCallback then
        modules.slackStatus.setUpdateCallback(updateMenuBar)
    end

    if modules.hyperduck and modules.hyperduck.setUpdateCallback then
        modules.hyperduck.setUpdateCallback(updateMenuBar)
    end

    print("Unified Menu loaded")
    return M
end

function M.stop()
    -- Clear callbacks first to prevent updates to deleted menubar
    if modules.slackStatus and modules.slackStatus.setUpdateCallback then
        modules.slackStatus.setUpdateCallback(nil)
    end

    if modules.hyperduck and modules.hyperduck.setUpdateCallback then
        modules.hyperduck.setUpdateCallback(nil)
    end

    -- Then delete menubar
    if menubarItem then
        menubarItem:delete()
        menubarItem = nil
    end

    modules = {}
    print("Unified Menu stopped")
end

return M
