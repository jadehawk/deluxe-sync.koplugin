local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local DiagnosticLog = {
    enabled = true,
}

local SETTINGS_DIR = DataStorage:getSettingsDir() .. "/deluxe-sync"
local LOG_DIR = SETTINGS_DIR .. "/logs"

local function ensureDir(path)
    if not lfs.attributes(path, "mode") then
        pcall(lfs.mkdir, path)
    end
end

local function ensurePaths()
    ensureDir(SETTINGS_DIR)
    ensureDir(LOG_DIR)
end

local function stringify(value)
    if value == nil then return "nil" end
    if type(value) == "table" then
        local parts = {}
        for k, v in pairs(value) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(value)
end

function DiagnosticLog.configure(enabled)
    DiagnosticLog.enabled = enabled ~= false
    ensurePaths()
end

function DiagnosticLog.getSettingsDir()
    ensurePaths()
    return SETTINGS_DIR
end

function DiagnosticLog.getLogDir()
    ensurePaths()
    return LOG_DIR
end

function DiagnosticLog.getLogPath()
    ensurePaths()
    return LOG_DIR .. "/deluxe-sync.log"
end

function DiagnosticLog.log(...)
    if not DiagnosticLog.enabled then return end
    ensurePaths()
    local values = { ... }
    local parts = {}
    for i = 1, #values do parts[i] = stringify(values[i]) end
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " | " .. table.concat(parts, " ") .. "\n"
    local file = io.open(DiagnosticLog.getLogPath(), "a")
    if not file then return end
    file:write(line)
    file:close()
end

return DiagnosticLog
