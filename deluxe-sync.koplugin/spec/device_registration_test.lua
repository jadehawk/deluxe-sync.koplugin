local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local main = readFile("main.lua")
local store = readFile("ServerStore.lua")
local client = readFile("SyncClient.lua")
local api = readFile("api.json")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing expected device-registration integration: " .. text))
end

contains(api, '"register_device"', "device registration API route missing")
contains(api, '"path": "/api/v1/devices/current"', "device registration route must target the Stage 6 endpoint")
contains(api, '"required_params": ["legacy_device_id"]', "existing Deluxe device id must remain the required identity")
contains(api, '"koreader_device_id"', "KOReader UUID must be supported as an enhanced alias")
contains(client, 'function SyncClient:registerDevice(username, userkey, payload, callback)', "SyncClient device registration helper missing")
contains(client, 'self:_async("register_device", username, userkey, payload, callback)', "device registration must use authenticated async transport")

contains(store, 'device_registration = nil', "server capability cache must include device registration")
contains(store, 'device_registration_version = nil', "server capability cache must include device registration version")
contains(store, 'device_registered = nil', "server state must remember registration outcome")

contains(main, 'local Version = require("version")', "KOReader version provider missing")
contains(main, 'self.device_heartbeat_sent = {}', "heartbeat must be limited once per server per session")
contains(main, 'function ProgressSyncDeluxe:serverSupportsDeviceRegistration(server)', "device registration must be capability gated")
contains(main, 'capabilities.device_registration == true', "device registration must require explicit server support")
contains(main, 'tonumber(capabilities.device_registration_version)', "device registration must honor protocol version")
contains(main, 'G_reader_settings:readSetting("device_id")', "KOReader UUID must come from KOReader's persistent device id")
contains(main, 'pcall(Version.getCurrentRevision, Version)', "KOReader version should be gathered safely")
contains(main, 'legacy_device_id = tostring(self.store.data.device_id)', "legacy Deluxe identity must be preserved")
contains(main, 'deluxe_sync_version = PLUGIN_VERSION', "Deluxe-Sync version must be registered")
contains(main, 'client:registerDevice(server.username, server.userkey, self:getDeviceRegistrationPayload()', "heartbeat must send enhanced device payload")
contains(main, 'self.store:setCapability(server.id, "device_registration", device_supported)', "capability probe must cache device support")
contains(main, 'self.store:setCapability(server.id, "device_registration_version", device_registration_version)', "capability probe must cache device schema version")
contains(main, 'self:heartbeatDevice(server, client, true', "manual capability refresh must force a registration heartbeat")
contains(main, 'self:heartbeatDevice(server, nil, false)', "successful progress sync must send the once-per-session heartbeat")
contains(main, '_("Device Identity")', "server UI must expose enhanced device identity status")

print("device_registration_test.lua: OK")
