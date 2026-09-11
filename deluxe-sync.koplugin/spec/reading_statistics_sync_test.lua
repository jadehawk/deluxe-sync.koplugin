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
local adapter = readFile("ReadingStatisticsAdapter.lua")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing reading-statistics integration: " .. text))
end

contains(api, '"put_reading_statistics"', "statistics event API method missing")
contains(api, '"path": "/api/v1/statistics/events"', "statistics event API path mismatch")
contains(api, '"required_params": ["legacy_device_id", "events"]', "statistics events must include Deluxe device identity")
contains(client, 'function SyncClient:putReadingStatistics(username, userkey, payload, callback)', "statistics SyncClient helper missing")
contains(client, 'self:_async("put_reading_statistics", username, userkey, payload, callback)', "statistics upload must use authenticated async transport")

contains(adapter, 'DataStorage:getSettingsDir() .. "/statistics.sqlite3"', "adapter must use KOReader statistics database")
contains(adapter, 'SQ3.open(db_path, "ro")', "statistics database must be opened read-only")
contains(adapter, 'FROM page_stat_data AS p', "page_stat_data ingestion query missing")
contains(adapter, 'JOIN book AS b ON b.id = p.id_book', "statistics query must join KOReader book metadata")
contains(adapter, 'INCREMENTAL_REWIND_SECONDS = 300', "incremental overlap window missing")

contains(store, 'reading_statistics_sync = {}', "per-server statistics cursor storage missing")
contains(store, 'function ServerStore:getReadingStatisticsState(server_id)', "statistics cursor getter missing")
contains(store, 'function ServerStore:saveReadingStatisticsState(server_id, state)', "statistics cursor persistence missing")
contains(store, 'self.data.reading_statistics_sync[id] = nil', "removing a server must clear statistics cursor state")
contains(store, 'reading_statistics = nil', "server capability cache must include reading statistics")
contains(store, 'reading_statistics_version = nil', "server capability cache must include statistics protocol version")

contains(main, 'ReadingStatisticsAdapter = require("ReadingStatisticsAdapter")', "statistics adapter must load with Deluxe-Sync")
contains(main, 'function ProgressSyncDeluxe:serverSupportsReadingStatistics(server)', "statistics capability gate missing")
contains(main, 'function ProgressSyncDeluxe:cacheReadingStatisticsCapabilities(server, enhanced_capabilities)', "statistics capability cache helper missing")
contains(main, 'function ProgressSyncDeluxe:syncReadingStatisticsForServer(server, callback)', "per-server statistics upload loop missing")
contains(main, 'server.reading_statistics_enabled ~= true', "statistics upload must require explicit per-server consent")
contains(main, 'function ProgressSyncDeluxe:syncReadingStatisticsForAll()', "multi-server statistics upload trigger missing")
contains(main, 'ReadingStatisticsAdapter.makeScanCursor(stored_state)', "incremental statistics scan cursor missing")
contains(main, 'self.store:saveReadingStatisticsState(server.id, high_water)', "statistics high-water cursor must persist")
contains(main, 'client:putReadingStatistics(server.username, server.userkey', "normalized statistics batches must upload")
contains(main, 'self.statistics_sync_in_flight[sync_key]', "duplicate concurrent statistics uploads must be suppressed")
contains(main, 'steps[#steps + 1] = function(done) self:syncReadingStatisticsForServer(server, done) end', "coordinator must include consented statistics work")
contains(main, 'UIManager:scheduleIn(2, function() self:nudgeOptionalDataAll(false) end)', "reader-ready must nudge optional-data convergence")
contains(main, 'function ProgressSyncDeluxe:refreshEnhancedCapabilitiesForAll()', "network reconnect capability refresh coordinator missing")
contains(main, 'self:nudgeOptionalDataAll(false)', "network capability refresh must nudge optional-data convergence")
contains(main, 'UIManager:scheduleIn(1, function() self:refreshEnhancedCapabilitiesForAll() end)', "network reconnect statistics/capability trigger missing")
contains(main, 'reading_statistics = true', "device registration must advertise statistics support")
contains(main, '_("Reading Statistics")', "server capability UI must expose reading statistics")

local statistics_sync = assert(main:find('function ProgressSyncDeluxe:syncReadingStatisticsForServer(server, callback)', 1, true))
local consent_gate = assert(main:find('server.reading_statistics_enabled ~= true', statistics_sync, true))
local first_read = assert(main:find('ReadingStatisticsAdapter.makeScanCursor(stored_state)', statistics_sync, true))
assert(consent_gate < first_read, "disabled reading statistics must not inspect the KOReader statistics database")

local rewind_position = assert(main:find('local scan_cursor = ReadingStatisticsAdapter.makeScanCursor(stored_state)', 1, true))
local high_water_position = assert(main:find('if cursorIsAfter(batch.cursor, high_water) then', rewind_position, true))
assert(high_water_position > rewind_position, "overlap replay must preserve a monotonic high-water cursor")

print("reading_statistics_sync_test.lua: OK")
