local json = require("json")
local sha = require("ffi/sha2")
local UrlUtil = require("UrlUtil")

local DeluxeProfileAdapter = {}

DeluxeProfileAdapter.PROTOCOL_VERSION = 1
DeluxeProfileAdapter.SCHEMA_VERSION = 1
DeluxeProfileAdapter.MAX_SERVERS = 32

local access_field = "user" .. "key"

local function clean(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function normalizeUrl(value)
    local normalized = UrlUtil.normalize(clean(value))
    return normalized or clean(value)
end

local function serverKey(url, username)
    return normalizeUrl(url) .. "\0" .. clean(username)
end

local function makeServerId(name, url, username)
    return sha.md5(table.concat({ name or "", url or "", username or "" }, "\0"))
end

local function safeStrategy(value, fallback)
    if value == "silent" or value == "prompt" or value == "never" then return value end
    return fallback
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

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
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
        for i = 1, count do chunks[#chunks + 1] = canonicalEncode(value[i]) end
        return "[" .. table.concat(chunks, ",") .. "]"
    end
    for _, key in ipairs(sortedKeys(value)) do
        chunks[#chunks + 1] = json.encode(key) .. ":" .. canonicalEncode(value[key])
    end
    return "{" .. table.concat(chunks, ",") .. "}"
end

function DeluxeProfileAdapter.sanitize(profile)
    if type(profile) ~= "table" then return nil, "Deluxe-Sync profile must be a table" end
    local raw_servers = type(profile.servers) == "table" and profile.servers or {}
    if #raw_servers > DeluxeProfileAdapter.MAX_SERVERS then
        return nil, "Deluxe-Sync profile contains too many servers"
    end

    local servers = {}
    for _, raw in ipairs(raw_servers) do
        if type(raw) == "table" then
            local url = normalizeUrl(raw.url)
            local username = clean(raw.username)
            if url ~= "" and username ~= "" then
                local name = clean(raw.name)
                local email = clean(raw.email)
                local server = {
                    name = name ~= "" and name or url,
                    url = url,
                    username = username,
                    enabled = raw.enabled ~= false,
                    metadata_enabled = raw.metadata_enabled ~= false,
                    checksum_method = raw.checksum_method == "filename" and "filename" or "binary",
                }
                if email ~= "" then server.email = email end
                servers[#servers + 1] = server
            end
        end
    end

    local access = {}
    local access_by_index = {}
    for _, entry in ipairs(type(profile.access) == "table" and profile.access or {}) do
        if type(entry) == "table" then
            local index = tonumber(entry.index)
            local value = clean(entry.value)
            if index and index >= 1 and index <= #servers and index == math.floor(index) and value ~= "" then
                access_by_index[index] = value
            end
        end
    end
    for index = 1, #servers do
        if access_by_index[index] then access[#access + 1] = { index = index, value = access_by_index[index] } end
    end

    local raw_settings = type(profile.settings) == "table" and profile.settings or {}
    local sanitized = {
        servers = servers,
        settings = {
            auto_sync = raw_settings.auto_sync == true,
            sync_forward = safeStrategy(raw_settings.sync_forward, "prompt"),
            sync_backward = safeStrategy(raw_settings.sync_backward, "never"),
            logging_enabled = raw_settings.logging_enabled ~= false,
        },
    }
    return {
        profile = sanitized,
        access = access,
        access_count = #access,
        checksum = sha.sha256(canonicalEncode(sanitized) .. "\0" .. canonicalEncode(access)),
        server_count = #servers,
        schema_version = DeluxeProfileAdapter.SCHEMA_VERSION,
    }
end

function DeluxeProfileAdapter.capture(store)
    if not store or type(store.data) ~= "table" then return nil, "Deluxe-Sync storage is unavailable" end
    local servers = {}
    local access = {}
    for _, server in ipairs(store.data.servers or {}) do
        if type(server) == "table" then
            local url = normalizeUrl(server.url)
            local username = clean(server.username)
            if url ~= "" and username ~= "" then
                local access_value = clean(server[access_field])
                if access_value == "" then
                    return nil, "A configured Deluxe-Sync server is missing its saved authentication key"
                end
                servers[#servers + 1] = {
                    name = server.name,
                    url = url,
                    username = username,
                    email = server.email,
                    enabled = server.enabled ~= false,
                    metadata_enabled = server.metadata_enabled ~= false,
                    checksum_method = server.checksum_method == "filename" and "filename" or "binary",
                }
                access[#access + 1] = { index = #servers, value = access_value }
            end
        end
    end
    return DeluxeProfileAdapter.sanitize({
        servers = servers,
        access = access,
        settings = {
            auto_sync = store.data.settings and store.data.settings.auto_sync == true,
            sync_forward = store.data.settings and store.data.settings.sync_forward,
            sync_backward = store.data.settings and store.data.settings.sync_backward,
            logging_enabled = not store.data.settings or store.data.settings.logging_enabled ~= false,
        },
    })
end

local function copyTable(value)
    local out = {}
    if type(value) == "table" then
        for key, child in pairs(value) do out[key] = child end
    end
    return out
end

function DeluxeProfileAdapter.apply(store, profile)
    if not store or type(store.data) ~= "table" then return false, "Deluxe-Sync storage is unavailable" end
    local sanitized, err = DeluxeProfileAdapter.sanitize(profile)
    if not sanitized then return false, err end
    if sanitized.server_count == 0 then return false, "Deluxe-Sync profile contains no configured servers" end
    if sanitized.access_count ~= sanitized.server_count then
        return false, "Deluxe-Sync profile does not contain authentication for every configured server"
    end

    local access_by_index = {}
    for _, entry in ipairs(sanitized.access) do access_by_index[entry.index] = entry.value end
    for index = 1, sanitized.server_count do
        if clean(access_by_index[index]) == "" then
            return false, "Deluxe-Sync profile authentication data is incomplete"
        end
    end

    local existing_by_key = {}
    for _, server in ipairs(store.data.servers or {}) do
        if type(server) == "table" then existing_by_key[serverKey(server.url, server.username)] = server end
    end

    local restored = {}
    for index, portable in ipairs(sanitized.profile.servers) do
        local existing = existing_by_key[serverKey(portable.url, portable.username)]
        local server = copyTable(existing)
        server.id = existing and existing.id or makeServerId(portable.name, portable.url, portable.username)
        server.name = portable.name
        server.url = portable.url
        server.username = portable.username
        server.email = portable.email
        server[access_field] = access_by_index[index]
        server.enabled = portable.enabled ~= false
        server.metadata_enabled = portable.metadata_enabled ~= false
        server.data_sharing_version = existing and math.max(0, math.floor(tonumber(existing.data_sharing_version) or 0)) or 0
        server.book_feedback_enabled = existing and existing.book_feedback_enabled == true or false
        server.annotations_enabled = existing and existing.annotations_enabled == true or false
        server.reading_statistics_enabled = existing and existing.reading_statistics_enabled == true or false
        server.settings_backup_enabled = existing and existing.settings_backup_enabled == true or false
        server.deluxe_config_backup_enabled = existing and existing.deluxe_config_backup_enabled == true or false
        server.vocabulary_enabled = existing and existing.vocabulary_enabled == true or false
        server.vocabulary_context_enabled = server.vocabulary_enabled and existing and existing.vocabulary_context_enabled == true or false
        server.checksum_method = portable.checksum_method == "filename" and "filename" or "binary"
        server.credentials_required = nil
        server.restore_enabled = nil
        restored[#restored + 1] = server
    end

    store.data.servers = restored
    store.data.settings = store.data.settings or {}
    store.data.settings.auto_sync = sanitized.profile.settings.auto_sync == true
    store.data.settings.sync_forward = sanitized.profile.settings.sync_forward
    store.data.settings.sync_backward = sanitized.profile.settings.sync_backward
    store.data.settings.logging_enabled = sanitized.profile.settings.logging_enabled ~= false
    store:flush()

    return true, {
        checksum = sanitized.checksum,
        server_count = sanitized.server_count,
        access_count = sanitized.access_count,
        schema_version = sanitized.schema_version,
    }
end

return DeluxeProfileAdapter
