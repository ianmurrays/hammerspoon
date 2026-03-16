local M = {}

function M.load(name, replacements)
    local base = hs.configdir .. "/html/" .. name .. "/"

    local function readFile(filename)
        local path = base .. filename
        local f = io.open(path, "r")
        if not f then
            error("html_loader: missing file " .. path)
        end
        local content = f:read("*a")
        f:close()
        return content
    end

    local html = readFile("index.html")
    local css = readFile("style.css")
    local js = readFile("script.js")

    -- Apply replacements to JS content before inlining
    if replacements then
        for target, replacement in pairs(replacements) do
            local pos = string.find(js, target, 1, true)
            while pos do
                js = string.sub(js, 1, pos - 1) .. replacement .. string.sub(js, pos + #target)
                pos = string.find(js, target, pos + #replacement, true)
            end
        end
    end

    -- Replace <link rel="stylesheet" href="style.css"> with inlined <style>
    local cssTag = '<link rel="stylesheet" href="style.css">'
    local cssPos = string.find(html, cssTag, 1, true)
    if cssPos then
        html = string.sub(html, 1, cssPos - 1) .. "<style>\n" .. css .. "\n  </style>" .. string.sub(html, cssPos + #cssTag)
    end

    -- Replace <script src="script.js"></script> with inlined <script>
    local jsTag = '<script src="script.js"></script>'
    local jsPos = string.find(html, jsTag, 1, true)
    if jsPos then
        html = string.sub(html, 1, jsPos - 1) .. "<script>\n" .. js .. "\n  </script>" .. string.sub(html, jsPos + #jsTag)
    end

    return html
end

return M
