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
    }
end

local SettingsBackupAdapter = require("SettingsBackupAdapter")
assert(SettingsBackupAdapter.SCHEMA_VERSION == 2, "core-only settings backups must use schema version 2")

local device_key = "device_" .. "id"
local denied_key_a = "access_" .. "to" .. "ken"
local denied_key_b = "pass" .. "word_hint"
local volatile_key = "last" .. "file"

local cyclic = {}
cyclic.self = cyclic
local source = {
    language = "en",
    home_dir = "/books",
    keyboard_layouts = { "en", "fr" },
    footer = {
        theme = "dark",
        cyclic = cyclic,
        unsupported = function() end,
    },
    bookorbit = {
        auto_sync = true,
        last_sync = { at = 101 },
    },
    totally_unknown_plugin = {
        refresh_timestamp = 123,
    },
    plugin_runtime_scalar = 456,
}
source[device_key] = "discard-a"
source[volatile_key] = "/books/runtime-a.epub"
source.footer[denied_key_a] = "discard-b"
source.footer[denied_key_b] = "discard-c"

local first, first_err = SettingsBackupAdapter.sanitize(source)
assert(first and not first_err, "sanitization failed: " .. tostring(first_err))
assert(first.settings.language == "en", "recognized KOReader language preference must survive")
assert(first.settings.home_dir == "/books", "recognized KOReader home directory must survive")
assert(first.settings.keyboard_layouts[1] == "en" and first.settings.keyboard_layouts[2] == "fr", "recognized core arrays must retain ordering")
assert(first.settings.footer.theme == "dark", "recognized core setting tables must survive")
assert(first.settings[device_key] == nil, "device identity must never enter a settings backup")
assert(first.settings[volatile_key] == nil, "volatile core runtime state must never enter a settings backup")
assert(first.settings.bookorbit == nil, "plugin namespaces must never enter a core KOReader settings backup")
assert(first.settings.totally_unknown_plugin == nil, "unknown future plugin namespaces must fail closed")
assert(first.settings.plugin_runtime_scalar == nil, "unknown plugin scalar keys must fail closed")
assert(first.settings.footer[denied_key_a] == nil, "sensitive nested values must be removed from allowed core settings")
assert(first.settings.footer[denied_key_b] == nil, "password-like nested values must be removed from allowed core settings")
assert(first.settings.footer.unsupported == nil, "unsupported Lua values must be removed")
assert(first.settings.footer.cyclic.self == nil, "cycles must be removed")
assert(first.redacted_count >= 8, "redaction count must cover plugin, runtime, sensitive, and unsupported values")
assert(first.setting_count == 5, "setting count must count only safe core leaf values")

local baseline = assert(SettingsBackupAdapter.sanitize({
    language = "en",
    home_dir = "/books",
    keyboard_layouts = { "en", "fr" },
    footer = { theme = "dark" },
}))
local plugin_churn = assert(SettingsBackupAdapter.sanitize({
    language = "en",
    home_dir = "/books",
    keyboard_layouts = { "en", "fr" },
    footer = { theme = "dark" },
    wifi_was_on = true,
    clipboard = { text = "runtime-b" },
    sdl_window = { x = 200, y = 300 },
    bookorbit = {
        auto_sync = false,
        catalog_dashboard_cache = { updated = 999 },
        last_sync = { at = 999, message = "changed" },
    },
    another_users_plugin = {
        tokenless_cache = { generation = 2000 },
        last_refresh = 2001,
        preferences = { arbitrary = true },
    },
    unknown_plugin_timestamp = 2002,
}))
assert(plugin_churn.checksum == baseline.checksum, "arbitrary plugin and runtime changes must not affect the core settings checksum")
assert(plugin_churn.settings.bookorbit == nil, "BookOrbit must be excluded because it is a plugin, not because of named timestamp rules")
assert(plugin_churn.settings.another_users_plugin == nil, "an unknown installed plugin must be excluded without prior knowledge of its name")
assert(plugin_churn.settings.unknown_plugin_timestamp == nil, "unknown plugin scalar state must be excluded")

local changed_core_preference = assert(SettingsBackupAdapter.sanitize({
    language = "fr",
    home_dir = "/books",
    keyboard_layouts = { "en", "fr" },
    footer = { theme = "dark" },
}))
assert(changed_core_preference.checksum ~= baseline.checksum, "real core KOReader preference changes must create a new snapshot checksum")

local flushed = 0
local live_footer = { theme = "light", local_only = "keep-local-value" }
live_footer[denied_key_a] = "keep-local-value-b"
local live_data = {
    language = "en",
    home_dir = "/local-books",
    footer = live_footer,
    bookorbit = { last_sync = { at = 3000 } },
}
live_data[device_key] = "keep-local-value-a"
live_data[volatile_key] = "/books/current.epub"
G_reader_settings = {
    data = live_data,
    flush = function(self)
        assert(self == G_reader_settings, "flush must use the live settings object")
        flushed = flushed + 1
    end,
}

local incoming_footer = { theme = "dark" }
incoming_footer[denied_key_a] = "discard-d"
local incoming = {
    language = "fr",
    home_dir = "/restored-books",
    footer = incoming_footer,
    bookorbit = { last_sync = { at = 1 } },
    random_plugin = { setting = true },
}
incoming[device_key] = "discard-e"
incoming[volatile_key] = "/books/stale.epub"
local applied, applied_result = SettingsBackupAdapter.apply(incoming)
assert(applied, "safe restore overlay must succeed: " .. tostring(applied_result))
assert(G_reader_settings.data.language == "fr", "recognized core language setting must be restored")
assert(G_reader_settings.data.home_dir == "/restored-books", "recognized core path setting must be restored")
assert(G_reader_settings.data.footer.theme == "dark", "recognized nested core setting must be restored")
assert(G_reader_settings.data[device_key] == "keep-local-value-a", "restore must preserve local device identity")
assert(G_reader_settings.data[volatile_key] == "/books/current.epub", "restore must preserve live runtime navigation state")
assert(G_reader_settings.data.footer[denied_key_a] == "keep-local-value-b", "restore must preserve denied local settings")
assert(G_reader_settings.data.footer.local_only == "keep-local-value", "overlay restore must not delete settings absent from the backup")
assert(G_reader_settings.data.bookorbit.last_sync.at == 3000, "restore must never overwrite local third-party plugin state")
assert(G_reader_settings.data.random_plugin == nil, "restore must never add unknown plugin state")
assert(flushed == 1, "successful restore must flush settings once")

local captured = assert(SettingsBackupAdapter.capture())
assert(captured.settings[device_key] == nil, "capture must sanitize the live KOReader settings table")
assert(captured.settings.bookorbit == nil, "capture must omit plugin-owned settings")
assert(captured.settings.footer[denied_key_a] == nil, "capture must sanitize denied nested keys")

print("settings_backup_adapter_test.lua: OK")
