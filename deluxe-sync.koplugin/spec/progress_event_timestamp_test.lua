local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
    return source
end

local main = readFile("main.lua")
local controller = readFile("EnhancedDataSyncController.lua")
local lifecycle = readFile("ProgressLifecycleController.lua")
local store = readFile("ServerStore.lua")
local api = readFile("api.json")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing progress-event timestamp integration: " .. text))
end

local function count(source, text)
    local total = 0
    local offset = 1
    while true do
        local start_pos, end_pos = source:find(text, offset, true)
        if not start_pos then return total end
        total = total + 1
        offset = end_pos + 1
    end
end

contains(api, '"event_timestamp"', "progress transport must serialize event_timestamp")
contains(store, "progress_event_timestamp = nil", "server capability storage must include progress_event_timestamp")
contains(controller, "enhanced_capabilities.progress_event_timestamp == true", "enhanced capability probe must detect progress_event_timestamp")
contains(controller, 'owner.store:setCapability(server.id, "progress_event_timestamp", progress_event_timestamp_supported)', "enhanced capability probe must cache progress_event_timestamp")

contains(main, "function ProgressSyncDeluxe:serverSupportsProgressEventTimestamp(server)", "progress event timestamp must be capability gated")
contains(main, "return capabilities.progress_event_timestamp == true", "unknown or standard servers must not receive event_timestamp")
assert(count(main, "local progress_event_timestamp = os.time()") == 2, "direct and offline progress snapshots must each capture one event timestamp")
assert(count(main, "payload.event_timestamp = progress_event_timestamp") == 2, "direct and offline payloads must use their captured timestamp when support is already confirmed")
contains(main, "payload = failed_payload,\n                    event_timestamp = progress_event_timestamp,", "failed online pushes must preserve the original event timestamp in the queue item")
contains(main, "payload = payload,\n            event_timestamp = progress_event_timestamp,", "offline queue entries must preserve the original event timestamp independently of capability state")
contains(main, "fallback_payload.event_timestamp = current_payload.event_timestamp", "metadata fallback must preserve the original timestamp")

contains(lifecycle, "capability_probe_attempted", "queue retry must distinguish capability preflight from actual delivery")
contains(lifecycle, "capabilities.progress_event_timestamp", "queue retry must inspect the tri-state timestamp capability")
contains(lifecycle, "owner:refreshEnhancedCapabilitiesAsync(server, nil", "unknown timestamp capability must be resolved before retry delivery")
contains(lifecycle, "self:retryQueue(interactive, complete_callback, mode, true)", "retry must resume only after capability preflight completes")
contains(lifecycle, '_("Waiting for server capability check")', "unresolved capability probes must leave queued progress pending instead of sending without a timestamp")
contains(lifecycle, "local preserved_event_timestamp = tonumber(payload.event_timestamp) or tonumber(item.queued_at)", "legacy queue entries must retain their original queued event time")
contains(lifecycle, "item.event_timestamp = preserved_event_timestamp", "queued event time must be preserved independently of the outgoing payload")
contains(lifecycle, "payload.event_timestamp = tonumber(item.event_timestamp) or tonumber(item.queued_at)", "supported retries must restore the original queued event timestamp")
contains(lifecycle, "elseif payload.event_timestamp ~= nil then", "confirmed unsupported retry targets must strip event_timestamp")
contains(lifecycle, "payload.event_timestamp = nil", "confirmed unsupported retry targets must not leak event_timestamp")
contains(lifecycle, "if supports_event_timestamp then sanitized.event_timestamp = payload.event_timestamp end", "sanitized retry payloads must preserve supported timestamps")
contains(lifecycle, 'diagnostic_log.log("queue retry event timestamp"', "retry diagnostics must expose the preserved event timestamp")
local preflight = assert(lifecycle:find("queue retry capability preflight", 1, true))
local delivery_gate = assert(lifecycle:find("local supports_event_timestamp = owner:serverSupportsProgressEventTimestamp(server)", 1, true))
assert(preflight < delivery_gate, "capability preflight must complete before a queued timestamp can be stripped or sent")
assert(not lifecycle:find("event_timestamp = os.time()", 1, true), "retry execution time must never replace the original progress event time")

print("progress_event_timestamp_test.lua: OK")
