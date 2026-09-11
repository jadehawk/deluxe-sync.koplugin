local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local main = readFile("main.lua")
local queue = readFile("SyncQueue.lua")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing queue retry integration: " .. text))
end

contains(main, "local QUEUE_RETRY_DELAYS = { 30, 120, 300, 900, 1800, 3600 }", "bounded retry backoff schedule mismatch")
contains(main, "function ProgressSyncDeluxe:cancelQueueRetry()", "queue retry timer cancellation missing")
contains(main, "UIManager:unschedule(self.queue_retry_action)", "queue retry timer must be replaceable")
contains(main, "function ProgressSyncDeluxe:scheduleQueueRetry()", "next-due queue retry scheduler missing")
contains(main, 'self:retryQueue(false, nil, "background")', "scheduled retry must use background mode")
contains(main, "next_retry_at = now + QUEUE_RETRY_DELAYS[1]", "new push failures must schedule the first retry")
contains(main, 'local mode = retry_mode or (interactive and "manual" or "background")', "retry mode selection missing")
contains(main, 'if mode == "background" then', "background due filtering missing")
contains(main, "item.auto_retry_exhausted ~= true", "exhausted automatic retries must stay paused")
contains(main, "tonumber(item.next_retry_at) <= now", "background retries must respect persisted due time")
contains(main, 'elseif mode == "network" then', "network reconnect retry mode missing")
contains(main, 'elseif mode == "manual" then', "manual retry reset mode missing")
contains(main, "item.retry_blocked = false", "manual retry must be able to retry a previously blocked queue item")
contains(main, "local retry_delay = QUEUE_RETRY_DELAYS[failure_count]", "retry failures must advance through backoff")
contains(main, "auto_retry_exhausted = exhausted", "retry budget exhaustion must persist")
contains(main, "retry_blocked = true", "authentication failures must stop automatic retry")
contains(main, "self:syncSettingsBackupForServer(server)", "successful retries must run settings snapshot convergence")
contains(main, 'end, "network")', "network reconnect must force a queue retry cycle")
contains(main, "if self:canAutoSync() then self:autoSyncPull() end", "network queue retry must not require Auto-Sync, while follow-up pull still does")
contains(main, "UIManager:scheduleIn(1, function() self:scheduleQueueRetry() end)", "reader-ready must resume persisted queue scheduling")
contains(main, "UIManager:scheduleIn(0.5, function() self:scheduleQueueRetry() end)", "resume must restore persisted queue scheduling")

contains(queue, "item.failure_count = tonumber(item.failure_count) or 0", "queue must persist failure count")
contains(queue, "item.next_retry_at = tonumber(item.next_retry_at)", "queue must persist next retry timestamp")
contains(queue, "item.auto_retry_exhausted = item.auto_retry_exhausted == true", "queue must persist automatic retry exhaustion")
contains(queue, "item.retry_blocked = item.retry_blocked == true", "queue must persist retry blocking")
contains(queue, "function SyncQueue:updateFailure(server_id, document, status, reason, retry_state)", "queue failure state update contract missing")
contains(queue, "item.next_retry_at = tonumber(retry_state.next_retry_at)", "queue failure update must persist next retry time")

local network_start = assert(main:find("function ProgressSyncDeluxe:onNetworkConnected()", 1, true))
local network_end = assert(main:find("\r\nend\r\n", network_start, true))
local network_body = main:sub(network_start, network_end)
assert(not network_body:find("if not self:canAutoSync() then return end", 1, true), "network reconnect must retry queued progress even when Auto-Sync is off")

print("queue_retry_test.lua: OK")
