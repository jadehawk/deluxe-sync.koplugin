package.path = "./?.lua;" .. package.path
package.preload["ui/network/manager"] = function() return { isOnline = function() return true end } end
package.preload["ui/uimanager"] = function() return { scheduleIn = function(_, _, callback) callback() end } end
package.preload["json"] = function() return { decode = function(value) return value end } end
package.preload["DeluxeProfileAdapter"] = function() return { SCHEMA_VERSION = 1 } end
package.preload["SettingsBackupAdapter"] = function() return { SCHEMA_VERSION = 2 } end
package.preload["VocabularyAdapter"] = function() return {} end

local state = {}
local server = {
    id = "server", url = "https://sync.example.org", username = "reader",
    capabilities = {},
}
local store = {}
function store:getReadingStatisticsState() return state end
function store:setCapability(_, key, value) server.capabilities[key] = value end
function store:saveClientNotices() end

local controller = require("EnhancedDataSyncController"):new({ store = store }, nil)
assert(controller:cacheReadingStatisticsCapabilities(server,
    { reading_statistics = true, reading_statistics_version = 1 }) == true)
assert(server.capabilities.reading_statistics == true)
assert(server.capabilities.reading_statistics_probe_allowed == false,
    "known enhanced server must never use fallback probing")
assert(controller:cacheReadingStatisticsCapabilities(server,
    { reading_statistics = false, reading_statistics_version = 1 }) == false)
assert(server.capabilities.reading_statistics == false)
assert(controller:cacheReadingStatisticsCapabilities(server,
    { reading_statistics = true, reading_statistics_version = 0 }) == false)

local client = {
    capabilities = function() return true, 404, nil end,
}
local supported, status = controller:refreshEnhancedCapabilities(server, client)
assert(not supported and status == 404)
assert(server.capabilities.reading_statistics_probe_allowed == true)
assert(server.capabilities.reading_statistics == false)
assert(controller:serverSupportsReadingStatistics(server) == false,
    "unverified 404 fallback is not an advertised capability")

state = {
    protocol = "koreader_v1", server_url = server.url, username = server.username,
    probe_confirmed = true, endpoint_unsupported = false,
}
controller:cacheReadingStatisticsCapabilities(server, nil)
assert(server.capabilities.reading_statistics == true,
    "remember server acknowledgment across future 404 discovery responses")
controller:allowKOReaderStatisticsProbe(server)
assert(server.capabilities.reading_statistics_probe_allowed == true)

-- An explicit negative capability response takes precedence over a past probe.
controller:cacheReadingStatisticsCapabilities(server,
    { reading_statistics = false, reading_statistics_version = 1 })
assert(server.capabilities.reading_statistics == false)
assert(server.capabilities.reading_statistics_probe_allowed == false)

state.endpoint_unsupported = true
controller:cacheReadingStatisticsCapabilities(server, nil)
controller:allowKOReaderStatisticsProbe(server)
assert(server.capabilities.reading_statistics == false)
assert(server.capabilities.reading_statistics_probe_allowed == false,
    "a negative 404/405 endpoint probe must be cached")

state.endpoint_unsupported = false
server.username = "another-reader"
controller:cacheReadingStatisticsCapabilities(server, nil)
assert(server.capabilities.reading_statistics == false,
    "successful probe for old credentials must not authorize a different account")
controller:allowKOReaderStatisticsProbe(server)
assert(server.capabilities.reading_statistics_probe_allowed == true,
    "a different account may make its own consent-gated probe")

-- A valid negative capabilities response must not trigger the missing-endpoint fallback.
client.capabilities = function()
    return true, 200, { capabilities = { reading_statistics = false, reading_statistics_version = 1 } }
end
assert(controller:refreshEnhancedCapabilities(server, client) == true)
assert(server.capabilities.reading_statistics_probe_allowed == false)
print("koreader_statistics_capabilities_test.lua: OK")
