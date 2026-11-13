package.path = "./?.lua;" .. package.path

local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local function contains(source, snippet)
    assert(source:find(snippet, 1, true), "Missing reading-statistics integration: " .. snippet)
end

local main = readFile("main.lua")
local controller = readFile("EnhancedDataSyncController.lua")
local lifecycle = readFile("ProgressLifecycleController.lua")
local store_source = readFile("ServerStore.lua")
local client_source = readFile("SyncClient.lua")
local api = readFile("api.json")
local stats_source = readFile("ReadingStatisticsSync.lua")

contains(api, '"post_koreader_statistics"')
contains(api, '"path": "/api/v1/stats/koreader"')
contains(api, '"method": "POST"')
assert(not api:find("/api/v1/statistics/events", 1, true), "legacy event endpoint must not be used")
contains(client_source, 'self:_async("post_koreader_statistics", username, userkey, payload, callback)')
contains(store_source, "function ServerStore:getReadingStatisticsState(server_id)")
contains(store_source, "function ServerStore:saveReadingStatisticsState(server_id, state)")
contains(store_source, "self.data.reading_statistics_sync[id] = nil")
contains(main, 'ReadingStatisticsAdapter = require("ReadingStatisticsAdapter")')
contains(main, 'ReadingStatisticsSync = require("ReadingStatisticsSync")')
contains(main, "function ProgressSyncDeluxe:serverSupportsReadingStatistics(server)")
contains(main, "function ProgressSyncDeluxe:syncReadingStatisticsForServer(server, callback)")
contains(main, "function ProgressSyncDeluxe:syncReadingStatisticsForAll()")
contains(controller, 'steps[#steps + 1] = function(done) owner:syncReadingStatisticsForServer(server, done) end')
contains(controller, '"reading_statistics_probe_allowed"')
contains(lifecycle, 'self:scheduleOptionalDataFallback(2, "reader_ready")')
contains(lifecycle, 'UIManager:scheduleIn(1, function() owner:refreshEnhancedCapabilitiesForAll() end)')
contains(main, 'reading_statistics = true')
contains(main, '_("Reading Statistics")')
local consent = assert(stats_source:find('server.reading_statistics_enabled ~= true', 1, true))
local first_read = assert(stats_source:find('owner.store:getReadingStatisticsState(server.id)', consent, true))
assert(consent < first_read, "consent must precede inspection of reading history")

package.preload["DiagnosticLog"] = function() return { log = function() end } end
package.preload["json"] = function() return {
    encode = function(payload)
        return payload.book.md5 .. ":" .. payload.timezone .. ":" .. tostring(payload.pages[1].duration)
    end,
    decode = function() error("invalid response") end,
} end
package.preload["ffi/sha2"] = function() return { md5 = function(value) return value end } end

local Adapter = {}
Adapter.MAX_BODY_BYTES = 4 * 1024 * 1024
local hash = string.rep("a", 32)
local records = 1
local duration = 30
local missing = false
local read_count = 0
function Adapter.validTimezone(value) return value == "UTC" or value == "America/New_York" end
function Adapter.listBooks()
    read_count = read_count + 1
    if missing then return { missing = true } end
    return { books = { { md5 = hash, title = "Book", authors = "Author" } } }
end
function Adapter.readBook(book, zone)
    assert(book.md5 == hash)
    local pages = {}
    for i = 1, records do
        pages[i] = { page = i, total_pages = 100, start_time = 1762041600 + i, duration = duration }
    end
    return { version = 1, book = book, timezone = zone, pages = pages }
end

local state = { start_time = 9999, initial_complete = true } -- migrate old event cursor
local saved_count = 0
local store = {}
function store:getReadingStatisticsState() return state end
function store:saveReadingStatisticsState(_, value)
    state = value
    saved_count = saved_count + 1
end
local server = {
    id = "server-1", url = "https://example.org", username = "reader", userkey = "hashed",
    enabled = true, reading_statistics_enabled = false, reading_statistics_timezone = "UTC",
    capabilities = {},
}
function store:setCapability(_, key, value) server.capabilities[key] = value end
local active_server = server
function store:getServer() return active_server end
local requests = {}
local responder = function(payload, callback)
    callback(true, 200, { version = 1, document = payload.book.md5, accepted = #payload.pages })
end
local client = {}
function client:postKOReaderStatistics(username, key, payload, callback)
    assert(username == "reader" and key == "hashed")
    requests[#requests + 1] = payload
    responder(payload, callback)
end
local owner = {
    store = store, statistics_sync_in_flight = {}, ui = nil,
    newClient = function() return client end,
    serverSupportsReadingStatistics = function(_, s)
        local caps = s.capabilities
        return caps.reading_statistics == true and caps.reading_statistics_version == 1
    end,
}
local syncService = require("ReadingStatisticsSync"):new(owner, {
    adapter = Adapter,
    server_label = function() return "server" end,
    server_response_message = function(body) return type(body) == "table" and body.message or nil end,
})
local function sync()
    local result
    syncService:sync(server, function(ok, status, message)
        result = { ok = ok, status = status, message = message }
    end)
    return result
end

-- Consent and capability discovery gate every request, not normal progress sync.
assert(sync().ok and read_count == 0 and #requests == 0)
server.reading_statistics_enabled = true
assert(sync().ok and read_count == 0 and #requests == 0)
server.capabilities.reading_statistics_probe_allowed = true
assert(sync().ok and #requests == 1 and read_count == 1)
assert(state.protocol == "koreader_v1" and state.probe_confirmed)
assert(state.sent[hash] and state.server_url == server.url and state.username == server.username)
assert(sync().ok and #requests == 1, "unchanged history must not resend")
duration = 40
assert(sync().ok and #requests == 2, "changed duration must resend")
assert(requests[2].pages[1].duration == 40)
server.reading_statistics_timezone = "America/New_York"
assert(sync().ok and #requests == 3, "timezone change must resend")

-- Unacknowledged requests never advance the fingerprint.
duration = 50
responder = function(payload, callback)
    callback(true, 200, { version = 1, document = payload.book.md5, accepted = 0 })
end
local failed = sync()
assert(not failed.ok and failed.message:find("acknowledge") and #requests == 4)
responder = function(payload, callback)
    callback(true, 200, { version = 1, document = payload.book.md5, accepted = #payload.pages })
end
assert(sync().ok and #requests == 5)

-- A 409 conflict must be surfaced and must not claim success.
duration = 60
responder = function(_, callback) callback(true, 409, { message = "Re-import the original history." }) end
failed = sync()
assert(not failed.ok and failed.status == 409 and failed.message:find("Re-import", 1, true), "409 result: " .. tostring(failed.ok) .. " " .. tostring(failed.status) .. " " .. tostring(failed.message))
assert(not state.sent[hash]:find(":60", 1, true))

-- An absent endpoint is probed at most once, even on servers without capabilities.
responder = function(_, callback) callback(true, 404, { message = "Not Found" }) end
failed = sync()
assert(not failed.ok and failed.status == 404 and state.endpoint_unsupported)
local count = #requests
assert(sync().ok and #requests == count, "404 must disable further probes")
server.capabilities.reading_statistics = true
server.capabilities.reading_statistics_version = 1
assert(sync().ok and #requests == count, "404 must also suppress repeated advertised attempts")

-- New server account does not reuse fingerprints or endpoint-failure state.
server.url = "https://new.example.org"
responder = function(payload, callback)
    callback(true, 200, { version = 1, document = payload.book.md5, accepted = #payload.pages })
end
assert(sync().ok and #requests == count + 1)
assert(not state.endpoint_unsupported and state.server_url == server.url)

-- Missing timezone/history is a clean skip or error without a request.
server.reading_statistics_timezone = ""
failed = sync()
assert(not failed.ok and failed.message:find("Time Zone"))
server.reading_statistics_timezone = "UTC"
missing = true
count = #requests
assert(sync().ok and #requests == count)
missing = false

duration = 65
local previous_max = Adapter.MAX_BODY_BYTES
Adapter.MAX_BODY_BYTES = 1
local request_count = #requests
failed = sync()
assert(not failed.ok and failed.message:find("4 MB", 1, true)
    and #requests == request_count, "oversized payload must not reach server")
Adapter.MAX_BODY_BYTES = previous_max

-- A late HTTP response must not save state into an edited server/account.
duration = 70
local pending_callback
responder = function(_, callback) pending_callback = callback end
local before_state = state.sent[hash]
local before_saves = saved_count
syncService:sync(server, function(ok, _, message)
    assert(not ok and message:find("settings changed"))
end)
assert(pending_callback and owner.statistics_sync_in_flight[server.id])
local concurrent
syncService:sync(server, function(ok, _, message)
    concurrent = not ok and message:find("already in progress", 1, true) ~= nil
end)
assert(concurrent and #requests == request_count + 1, "concurrent sync must not create a second request")
active_server = {
    id = server.id, url = "https://changed.example.org", username = "reader", userkey = "hashed",
    enabled = true, reading_statistics_enabled = true, reading_statistics_timezone = "UTC",
    capabilities = { reading_statistics = true, reading_statistics_version = 1 },
}
pending_callback(true, 200, { version = 1, document = hash, accepted = 1 })
assert(saved_count == before_saves and state.sent[hash] == before_state)
assert(not owner.statistics_sync_in_flight[server.id])
assert(saved_count >= 4, "acknowledgments must persist per-server fingerprints")
assert(not owner.statistics_sync_in_flight[server.id], "in-flight state must be released")
print("reading_statistics_sync_test.lua: OK")
