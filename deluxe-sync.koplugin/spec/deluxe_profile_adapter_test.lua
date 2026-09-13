package.path = "./?.lua;" .. package.path

package.preload["json"] = function()
    local function encodeString(value)
        return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    return { encode = encodeString }
end

package.preload["ffi/sha2"] = function()
    return {
        sha256 = function(value) return "hash:" .. tostring(value) end,
        md5 = function(value) return "id:" .. tostring(value) end,
    }
end

package.preload["UrlUtil"] = function()
    return {
        normalize = function(value)
            if type(value) ~= "string" or value == "" then return nil end
            return value:gsub("/+$", "")
        end,
    }
end

local DeluxeProfileAdapter = require("DeluxeProfileAdapter")
local access_field = "user" .. "key"

local store = {
    data = {
        device_id = "keep-device",
        servers = {
            {
                id = "keep-techy-id",
                name = "Current Techy",
                url = "https://sync.techy-notes.com/",
                username = "reader",
                enabled = true,
                metadata_enabled = true,
                checksum_method = "binary",
                capabilities = { settings_backups = true },
            },
        },
        aliases = { keep = true },
        known_documents = { keep = true },
        annotation_sync = { keep = true },
        reading_statistics_sync = { keep = true },
        settings_backup_sync = { keep = true },
        settings = {
            auto_sync = false,
            sync_forward = "silent",
            sync_backward = "never",
            logging_enabled = true,
        },
    },
    flush_count = 0,
    flush = function(self) self.flush_count = self.flush_count + 1 end,
}
store.data.servers[1][access_field] = "local-access-value"

local captured = assert(DeluxeProfileAdapter.capture(store))
assert(captured.server_count == 1, "capture must include configured servers")
assert(captured.access_count == 1, "capture must include authentication for every configured server")
assert(captured.profile.servers[1].name == "Current Techy", "capture must retain portable server labels")
assert(captured.profile.servers[1][access_field] == nil, "public portable profile must not inline authentication material")
assert(captured.access[1].index == 1 and captured.access[1].value == "local-access-value", "authentication must travel in the protected access channel")
assert(captured.profile.settings.sync_forward == "silent", "portable profile must retain silent sync strategy")
assert(captured.profile.device_id == nil, "portable profile must exclude Deluxe device identity")
assert(captured.profile.known_documents == nil, "portable profile must exclude document cache state")

local incoming = {
    servers = {
        {
            name = "Techy-Notes",
            url = "https://sync.techy-notes.com",
            username = "reader",
            enabled = true,
            metadata_enabled = false,
            checksum_method = "filename",
        },
        {
            name = "Other KOSync",
            url = "https://other.example.test",
            username = "other-reader",
            enabled = true,
            metadata_enabled = true,
            checksum_method = "binary",
        },
    },
    access = {
        { index = 1, value = "restored-techy-access" },
        { index = 2, value = "restored-other-access" },
    },
    settings = {
        auto_sync = true,
        sync_forward = "prompt",
        sync_backward = "silent",
        logging_enabled = false,
    },
}

local applied, result = DeluxeProfileAdapter.apply(store, incoming)
assert(applied, "portable profile apply must succeed: " .. tostring(result))
assert(result.server_count == 2, "both portable servers must be restored")
assert(result.access_count == 2, "all restored servers must receive their saved authentication")
assert(store.data.servers[1].id == "keep-techy-id", "matching server must preserve its local identity")
assert(store.data.servers[1][access_field] == "restored-techy-access", "matching server must restore the source account authentication exactly")
assert(store.data.servers[1].enabled == true, "matching server must retain the source enabled state")
assert(store.data.servers[1].metadata_enabled == false, "portable server preferences must restore")
assert(store.data.servers[1].checksum_method == "filename", "portable matching mode must restore")
assert(store.data.servers[1].credentials_required == nil and store.data.servers[1].restore_enabled == nil, "matching server must not retain legacy credential placeholders")
assert(store.data.servers[2][access_field] == "restored-other-access", "new local server entry must restore the same remote account authentication")
assert(store.data.servers[2].username == "other-reader", "restored server must keep the original remote username")
assert(store.data.servers[2].enabled == true, "new local server entry must retain the source enabled state")
assert(store.data.servers[2].credentials_required == nil and store.data.servers[2].restore_enabled == nil, "restored account must be ready to use without re-authentication")
assert(store.data.settings.auto_sync == true, "portable plugin preferences must restore")
assert(store.data.settings.sync_backward == "silent", "all supported sync strategies must restore")
assert(store.data.settings.logging_enabled == false, "logging preference must restore")
assert(store.data.device_id == "keep-device", "profile restore must preserve Deluxe device identity")
assert(store.data.aliases.keep == true, "profile restore must preserve local alias state")
assert(store.data.known_documents.keep == true, "profile restore must preserve local document caches")
assert(store.data.annotation_sync.keep == true, "profile restore must preserve annotation cursors")
assert(store.data.reading_statistics_sync.keep == true, "profile restore must preserve statistics cursors")
assert(store.data.settings_backup_sync.keep == true, "profile restore must preserve backup cursors")
assert(store.flush_count == 1, "profile restore must flush storage exactly once")

local incomplete = {
    servers = incoming.servers,
    access = { { index = 1, value = "only-one-access" } },
    settings = incoming.settings,
}
local incomplete_ok, incomplete_err = DeluxeProfileAdapter.apply(store, incomplete)
assert(incomplete_ok == false, "restore must reject a profile missing authentication for any server")
assert(tostring(incomplete_err):find("every configured server", 1, true), "incomplete restore must explain why it was rejected")
assert(store.flush_count == 1, "rejected incomplete restore must not mutate or flush storage")

local missing_access_store = {
    data = { servers = { { url = "https://missing.example.test", username = "reader", enabled = true } }, settings = {} },
}
local missing_capture, missing_capture_err = DeluxeProfileAdapter.capture(missing_access_store)
assert(missing_capture == nil, "capture must reject a configured server with no saved authentication")
assert(tostring(missing_capture_err):find("missing its saved authentication key", 1, true), "capture failure must identify incomplete server authentication")

print("deluxe_profile_adapter_test.lua: OK")
