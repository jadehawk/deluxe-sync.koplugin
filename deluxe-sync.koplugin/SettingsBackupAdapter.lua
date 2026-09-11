local json = require("json")
local sha = require("ffi/sha2")
local CoreReaderSettings = require("CoreReaderSettings")

local SettingsBackupAdapter = {}

SettingsBackupAdapter.PROTOCOL_VERSION = 1
SettingsBackupAdapter.SCHEMA_VERSION = 2
SettingsBackupAdapter.MAX_DEPTH = 16

local sensitive_key_parts = {
    "password",
    "passwd",
    "passphrase",
    "userkey",
    "user_key",
    "token",
    "secret",
    "api_key",
    "apikey",
    "auth_key",
    "authorization",
    "credential",
    "cookie",
}

local denied_exact_keys = {
    device_id = true,
    koreader_device_id = true,
    deluxe_device_id = true,
    wifi_password = true,
    proxy_password = true,
}

-- KOReader persists some current-session/runtime values in settings.reader.lua.
-- These are core keys, but they are not durable preferences and should neither
-- create backup churn nor be restored from an older snapshot.
local volatile_exact_keys = {
    lastfile = true,
    lastdir = true,
    filemanagermenu_tab_index = true,
    history_filter = true,
    highlight_dialog_position = true,
    cre_fonts_recently_selected = true,
    wikipedia_last_language = true,
    last_migration_date = true,
    reader_timer_remain_time = true,
    frontlight_intensity = true,
    frontlight_warmth = true,
    is_frontlight_on = true,
    night_mode = true,
    closed_rotation_mode = true,
    wifi_was_on = true,
}

local volatile_exact_paths = {
    ["clipboard"] = true,
    ["sdl_window"] = true,
}

local function shouldDenyKey(key)
    local normalized = tostring(key or ""):lower()
    if denied_exact_keys[normalized] or volatile_exact_keys[normalized] then return true end
    for _, part in ipairs(sensitive_key_parts) do
        if normalized:find(part, 1, true) then return true end
    end
    return false
end

local function shouldDenyPath(path)
    return volatile_exact_paths[tostring(path or ""):lower()] == true
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function classifyTable(value)
    local count = 0
    local max_index = 0
    local numeric_only = true
    for key in pairs(value) do
        count = count + 1
        if type(key) == "number" and key >= 1 and key == math.floor(key) then
            if key > max_index then max_index = key end
        else
            numeric_only = false
        end
    end
    if count == 0 then return "object", 0 end
    if numeric_only and max_index == count then return "array", max_index end
    return "object", count
end

local function sanitizeValue(value, path, depth, seen, redacted)
    local value_type = type(value)
    if depth > SettingsBackupAdapter.MAX_DEPTH then
        redacted[#redacted + 1] = path ~= "" and path or "<root>"
        return nil
    end
    if value == nil or value_type == "string" or value_type == "boolean" then
        return value
    end
    if value_type == "number" then
        return isFiniteNumber(value) and value or nil
    end
    if value_type ~= "table" then
        redacted[#redacted + 1] = path ~= "" and path or "<root>"
        return nil
    end
    if seen[value] then
        redacted[#redacted + 1] = path ~= "" and path or "<root>"
        return nil
    end
    seen[value] = true

    local kind, count = classifyTable(value)
    local out = {}
    if kind == "array" then
        for i = 1, count do
            local child_path = string.format("%s[%d]", path, i)
            local sanitized = sanitizeValue(value[i], child_path, depth + 1, seen, redacted)
            if sanitized ~= nil then
                out[#out + 1] = sanitized
            end
        end
    else
        for key, child in pairs(value) do
            if type(key) ~= "string" then
                redacted[#redacted + 1] = path ~= "" and (path .. ".<non-string-key>") or "<non-string-key>"
            else
                local child_path = path ~= "" and (path .. "." .. key) or key
                local unknown_root_key = path == "" and not CoreReaderSettings.allows(key)
                if unknown_root_key or shouldDenyKey(key) or shouldDenyPath(child_path) then
                    redacted[#redacted + 1] = child_path
                else
                    local sanitized = sanitizeValue(child, child_path, depth + 1, seen, redacted)
                    if sanitized ~= nil then out[key] = sanitized end
                end
            end
        end
    end

    seen[value] = nil
    return out
end

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function canonicalEncode(value)
    local value_type = type(value)
    if value == nil then return "null" end
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then return string.format("%.17g", value) end
    if value_type == "string" then return json.encode(value) end
    if value_type ~= "table" then return "null" end

    local kind, count = classifyTable(value)
    local chunks = {}
    if kind == "array" then
        for i = 1, count do
            chunks[#chunks + 1] = canonicalEncode(value[i])
        end
        return "[" .. table.concat(chunks, ",") .. "]"
    end

    for _, key in ipairs(sortedKeys(value)) do
        chunks[#chunks + 1] = json.encode(key) .. ":" .. canonicalEncode(value[key])
    end
    return "{" .. table.concat(chunks, ",") .. "}"
end

local function countSettings(value)
    if type(value) ~= "table" then return 1 end
    local kind, count = classifyTable(value)
    if kind == "array" then
        local total = 0
        for i = 1, count do total = total + countSettings(value[i]) end
        return total
    end
    local total = 0
    for _, child in pairs(value) do total = total + countSettings(child) end
    return total
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, child in pairs(value) do copy[key] = deepCopy(child) end
    return copy
end

local function overlay(target, source)
    for key, value in pairs(source) do
        local value_kind = type(value) == "table" and classifyTable(value) or nil
        if type(value) == "table" and value_kind ~= "array" and type(target[key]) == "table" then
            overlay(target[key], value)
        else
            target[key] = deepCopy(value)
        end
    end
end

function SettingsBackupAdapter.sanitize(settings)
    if type(settings) ~= "table" then
        return nil, "settings must be a table"
    end
    local redacted = {}
    local sanitized = sanitizeValue(settings, "", 0, {}, redacted)
    if type(sanitized) ~= "table" then
        return nil, "settings could not be sanitized"
    end
    local canonical = canonicalEncode(sanitized)
    return {
        settings = sanitized,
        checksum = sha.sha256(canonical),
        setting_count = countSettings(sanitized),
        redacted_count = #redacted,
        redacted_paths = redacted,
        schema_version = SettingsBackupAdapter.SCHEMA_VERSION,
    }
end

function SettingsBackupAdapter.capture()
    if not G_reader_settings or type(G_reader_settings.data) ~= "table" then
        return nil, "KOReader global settings are unavailable"
    end
    return SettingsBackupAdapter.sanitize(G_reader_settings.data)
end

function SettingsBackupAdapter.apply(settings)
    if not G_reader_settings or type(G_reader_settings.data) ~= "table" then
        return false, "KOReader global settings are unavailable"
    end
    local sanitized, err = SettingsBackupAdapter.sanitize(settings)
    if not sanitized then return false, err end
    overlay(G_reader_settings.data, sanitized.settings)
    if G_reader_settings.flush then G_reader_settings:flush() end
    return true, sanitized
end

return SettingsBackupAdapter
