package.path = "./?.lua;" .. package.path

local function stub(name, value)
    package.preload[name] = function() return value or {} end
end

stub("ui/widget/confirmbox", { new = function(_, value) return value end })
stub("device", {})
stub("ui/widget/infomessage", { new = function(_, value) return value end })
stub("ui/network/manager", {})
stub("ui/uimanager", {})
stub("libs/libkoreader-lfs", {})
stub("ltn12", {})
stub("rapidjson", {})
stub("ssl.https", {})
stub("I18N", { translate = function(text) return text end })

local Updater = require("deluxe_sync_updater")

assert(Updater.isNewer("0.1.1", "0.1.0") == true)
assert(Updater.isNewer("0.2.0", "0.1.9") == true)
assert(Updater.isNewer("1.0.0", "0.9.9") == true)
assert(Updater.isNewer("0.1.0", "0.1.0") == false)
assert(Updater.isNewer("0.0.9", "0.1.0") == false)
assert(Updater.isNewer("1.0.0.0", "0.1.2") == true)
assert(Updater.isNewer("v1.0.0.0", "0.1.2") == true)
assert(Updater.isNewer("0.0.1.3", "0.1.2") == true)
assert(Updater.isNewer("0.0.1.2", "0.1.2") == false)
assert(Updater.isNewer("0.0.1.1", "0.1.2") == false)
assert(Updater.isNewer("0.1.2", "0.0.1.1") == true)
assert(Updater.isNewer("1.2.3.4.5", "0.1.2") == false)
assert(Updater.isNewer("development", "0.1.0") == false)

assert(Updater._trustedReleaseUrl("https://github.com/jadehawk/deluxe-sync.koplugin/releases/download/v0.1.0/deluxe-sync.koplugin.zip") == true)
assert(Updater._trustedReleaseUrl("https://example.com/deluxe-sync.koplugin.zip") == false)
assert(Updater._trustedReleaseUrl("https://github.com/jadehawk/deluxe-sync.koplugin/releases/download/v0.1.0/file.zip\nX-Test: bad") == false)

assert(Updater._safeArchivePath("deluxe-sync.koplugin/main.lua") == "deluxe-sync.koplugin/main.lua")
assert(Updater._safeArchivePath("./deluxe-sync.koplugin/main.lua") == "deluxe-sync.koplugin/main.lua")
assert(Updater._safeArchivePath("../main.lua") == nil)
assert(Updater._safeArchivePath("/absolute/main.lua") == nil)
assert(Updater._safeArchivePath("C:/absolute/main.lua") == nil)

print("updater_helpers_test.lua: OK")
