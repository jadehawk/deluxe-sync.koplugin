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
local device_key = "device_" .. "id"
local denied_key_a = "access_" .. "to" .. "ken"
local denied_key_b = "pass" .. "word_hint"

local cyclic = {}
cyclic.self = cyclic
local source = {
    z = 2,
    nested = { theme = "dark" },
    list = { "one", "two" },
    unsupported = function() end,
    cyclic = cyclic,
    a = true,
}
source[device_key] = "discard-a"
source.nested[denied_key_a] = "discard-b"
source.nested[denied_key_b] = "discard-c"

local first, first_err = SettingsBackupAdapter.sanitize(source)
assert(first and not first_err, "sanitization failed: " .. tostring(first_err))
assert(first.settings.a == true and first.settings.z == 2, "safe scalar settings must survive")
assert(first.settings[device_key] == nil, "device identity must never enter a settings backup")
assert(first.settings.nested.theme == "dark", "safe nested settings must survive")
assert(first.settings.nested[denied_key_a] == nil, "first denied setting must be removed")
assert(first.settings.nested[denied_key_b] == nil, "second denied setting must be removed")
assert(first.settings.unsupported == nil, "unsupported Lua values must be removed")
assert(first.settings.cyclic.self == nil, "cycles must be removed")
assert(first.settings.list[1] == "one" and first.settings.list[2] == "two", "arrays must retain ordering")
assert(first.redacted_count >= 5, "redaction count must cover denied and unsupported values")
assert(first.setting_count == 5, "setting count must count safe leaf values")

local second_source = {
    a = true,
    list = { "one", "two" },
    nested = { theme = "dark" },
    z = 2,
}
second_source[device_key] = "different-a"
second_source.nested[denied_key_a] = "different-b"
second_source.nested[denied_key_b] = "different-c"
local second = assert(SettingsBackupAdapter.sanitize(second_source))
local comparable = assert(SettingsBackupAdapter.sanitize({
    z = 2,
    nested = { theme = "dark" },
    list = { "one", "two" },
    a = true,
}))
assert(second.checksum == comparable.checksum, "denied values must not affect the safe snapshot checksum")

local flushed = 0
local live_nested = { theme = "light", local_only = "keep-local-value" }
live_nested[denied_key_a] = "keep-local-value-b"
local live_data = { nested = live_nested, font_size = 20 }
live_data[device_key] = "keep-local-value-a"
G_reader_settings = {
    data = live_data,
    flush = function(self)
        assert(self == G_reader_settings, "flush must use the live settings object")
        flushed = flushed + 1
    end,
}

local incoming_nested = { theme = "dark" }
incoming_nested[denied_key_a] = "discard-d"
local incoming = { nested = incoming_nested, font_size = 24 }
incoming[device_key] = "discard-e"
local applied, applied_result = SettingsBackupAdapter.apply(incoming)
assert(applied, "safe restore overlay must succeed: " .. tostring(applied_result))
assert(G_reader_settings.data.font_size == 24, "safe scalar setting must be restored")
assert(G_reader_settings.data.nested.theme == "dark", "safe nested setting must be restored")
assert(G_reader_settings.data[device_key] == "keep-local-value-a", "restore must preserve local device identity")
assert(G_reader_settings.data.nested[denied_key_a] == "keep-local-value-b", "restore must preserve denied local settings")
assert(G_reader_settings.data.nested.local_only == "keep-local-value", "overlay restore must not delete settings absent from the backup")
assert(flushed == 1, "successful restore must flush settings once")

local captured = assert(SettingsBackupAdapter.capture())
assert(captured.settings[device_key] == nil, "capture must sanitize the live KOReader settings table")
assert(captured.settings.nested[denied_key_a] == nil, "capture must sanitize denied nested keys")

print("settings_backup_adapter_test.lua: OK")
