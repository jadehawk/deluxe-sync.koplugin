local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local I18N = require("I18N")
local _ = I18N.translate

local ProgressLifecycleController = {}
ProgressLifecycleController.__index = ProgressLifecycleController

function ProgressLifecycleController:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function ProgressLifecycleController:canAutoSync()
    local owner = self.owner
    return owner.store ~= nil
        and owner.store.data.settings.auto_sync == true
        and owner.ui.document ~= nil
        and not owner.preview
        and #owner.store:getEnabledServers() > 0
end

function ProgressLifecycleController:autoSyncPush()
    local owner = self.owner
    if not self:canAutoSync() then return end
    if NetworkMgr:isOnline() then
        owner:pushAll(false)
    else
        owner:queueCurrentProgress()
    end
end

function ProgressLifecycleController:autoSyncPull()
    local owner = self.owner
    if not self:canAutoSync() or not NetworkMgr:isOnline() then return end
    owner:pullAll(false)
end

function ProgressLifecycleController:cancelQueueRetry()
    local owner = self.owner
    if not owner.queue_retry_action then return end
    UIManager:unschedule(owner.queue_retry_action)
    owner.queue_retry_action = nil
end

function ProgressLifecycleController:scheduleQueueRetry()
    local owner = self.owner
    local diagnostic_log = self.deps.diagnostic_log
    self:cancelQueueRetry()
    if not owner.queue or owner.queue:count() == 0 or not NetworkMgr:isOnline() then return end

    local now = os.time()
    local next_retry_at = nil
    for item_index, item in ipairs(owner.queue:list()) do
        local server = owner.store:getServer(item.server_id)
        if server and server.enabled ~= false and item.retry_blocked ~= true and item.auto_retry_exhausted ~= true then
            local due = tonumber(item.next_retry_at) or now
            if next_retry_at == nil or due < next_retry_at then next_retry_at = due end
        end
    end
    if next_retry_at == nil then return end

    local delay = math.max(1, next_retry_at - now)
    local action
    action = function()
        if owner.queue_retry_action ~= action then return end
        owner.queue_retry_action = nil
        if not NetworkMgr:isOnline() then return end
        self:retryQueue(false, nil, "background")
    end
    owner.queue_retry_action = action
    UIManager:scheduleIn(delay, action)
    if diagnostic_log then diagnostic_log.log("queue retry scheduled", "seconds", delay, "items", owner.queue:count()) end
end

function ProgressLifecycleController:retryQueue(interactive, complete_callback, retry_mode)
    local owner = self.owner
    local diagnostic_log = self.deps.diagnostic_log
    local server_label = assert(self.deps.server_label, "ProgressLifecycleController requires server_label")
    local queue_failure_reason = assert(self.deps.queue_failure_reason, "ProgressLifecycleController requires queue_failure_reason")
    local is_book_not_found_response = assert(self.deps.is_book_not_found_response, "ProgressLifecycleController requires is_book_not_found_response")
    local queue_retry_delays = assert(self.deps.queue_retry_delays, "ProgressLifecycleController requires queue_retry_delays")
    local mode = retry_mode or (interactive and "manual" or "background")
    self:cancelQueueRetry()

    local stale_server_ids = {}
    for item_index, item in ipairs(owner.queue:list()) do
        local server = owner.store:getServer(item.server_id)
        if not server or server.enabled == false then stale_server_ids[item.server_id] = true end
    end
    for server_id in pairs(stale_server_ids) do
        owner.queue:removeServer(server_id)
        if diagnostic_log then diagnostic_log.log("queue cleanup", "server", server_id, "reason", "missing or disabled") end
    end

    local now = os.time()
    local items = {}
    local queue_state_changed = false
    for item_index, item in ipairs(owner.queue:list()) do
        local server = owner.store:getServer(item.server_id)
        if server and server.enabled ~= false then
            local include = true
            if mode == "background" then
                include = item.retry_blocked ~= true
                    and item.auto_retry_exhausted ~= true
                    and (tonumber(item.next_retry_at) == nil or tonumber(item.next_retry_at) <= now)
            elseif mode == "network" then
                include = item.retry_blocked ~= true
                if include and item.auto_retry_exhausted == true then
                    item.failure_count = 0
                    item.next_retry_at = nil
                    item.auto_retry_exhausted = false
                    queue_state_changed = true
                end
            elseif mode == "manual" then
                item.failure_count = 0
                item.next_retry_at = nil
                item.auto_retry_exhausted = false
                item.retry_blocked = false
                queue_state_changed = true
            end
            if include then table.insert(items, item) end
        end
    end
    if queue_state_changed then owner.queue:save() end

    if #items == 0 then
        self:scheduleQueueRetry()
        if interactive then UIManager:show(InfoMessage:new{ text = _("No queued progress updates are ready to retry.") }) end
        if complete_callback then complete_callback() end
        return
    end

    local pending = 0
    local scan_complete = false
    local completion_called = false
    local function finish()
        if completion_called then return end
        completion_called = true
        self:scheduleQueueRetry()
        if complete_callback then complete_callback() end
    end
    local function done()
        pending = pending - 1
        if scan_complete and pending == 0 then finish() end
    end

    for item_index, item in ipairs(items) do
        local server = owner.store:getServer(item.server_id)
        if server and server.enabled ~= false then
            pending = pending + 1
            local payload = item.payload
            local strip_metadata = payload.metadata ~= nil
                and (server.metadata_enabled == false or (server.capabilities and server.capabilities.metadata_compatible == false))
            local strip_position = payload.position ~= nil and not owner:serverSupportsRichProgress(server)
            if strip_metadata or strip_position then
                local sanitized = {
                    document = payload.document,
                    progress = payload.progress,
                    percentage = payload.percentage,
                    device = payload.device,
                    device_id = payload.device_id,
                }
                if not strip_metadata then sanitized.metadata = payload.metadata end
                if not strip_position then sanitized.position = payload.position end
                payload = sanitized
                item.payload = payload
                owner.queue:save()
            end
            owner:newClient(server):updateProgress(server.username, server.userkey, payload, function(ok, status, body)
                if ok and (status == 200 or status == 202) then
                    owner.queue:remove(item.server_id, item.document)
                    owner:heartbeatDevice(server, nil, false)
                    owner:nudgeOptionalData(server, payload.document, false)
                elseif is_book_not_found_response(status, body) then
                    owner.queue:remove(item.server_id, item.document)
                    if diagnostic_log then diagnostic_log.log("queue drop not tracked", server_label(server), "document", item.document, "status", status, "body", body) end
                elseif status == 401 then
                    local failure_count = (tonumber(item.failure_count) or 0) + 1
                    owner.queue:updateFailure(item.server_id, item.document, status, queue_failure_reason(status, body), {
                        failure_count = failure_count,
                        next_retry_at = nil,
                        auto_retry_exhausted = true,
                        retry_blocked = true,
                    })
                else
                    local failure_count = (tonumber(item.failure_count) or 0) + 1
                    local retry_delay = queue_retry_delays[failure_count]
                    local exhausted = retry_delay == nil
                    owner.queue:updateFailure(item.server_id, item.document, status, queue_failure_reason(status, body), {
                        failure_count = failure_count,
                        next_retry_at = retry_delay and (os.time() + retry_delay) or nil,
                        auto_retry_exhausted = exhausted,
                        retry_blocked = false,
                    })
                    if exhausted and diagnostic_log then
                        diagnostic_log.log("queue auto retry exhausted", server_label(server), "document", item.document, "failures", failure_count)
                    end
                end
                done()
            end)
        end
    end
    scan_complete = true
    if pending == 0 then finish() end
    if interactive then UIManager:show(InfoMessage:new{ text = _("Queued updates are being retried.") }) end
end

function ProgressLifecycleController:scheduleAutomaticUpdateCheck()
    local owner = self.owner
    if owner._automatic_update_check_done or not owner.store or not NetworkMgr:isOnline() then return end
    owner._automatic_update_check_done = true
    UIManager:scheduleIn(1, function()
        require("deluxe_sync_updater").checkAutomatic(owner)
    end)
end

function ProgressLifecycleController:scheduleOptionalDataFallback(delay, reason)
    local owner = self.owner
    local coordinator = owner.enhanced_data_sync
    local completed_before = coordinator and tonumber(coordinator.completed_runs) or 0
    local diagnostic_log = self.deps.diagnostic_log
    if diagnostic_log then
        diagnostic_log.log("optional data fallback", "scheduled", "reason", reason or "unknown", "completed_runs", completed_before)
    end
    UIManager:scheduleIn(delay, function()
        local completed_now = coordinator and tonumber(coordinator.completed_runs) or 0
        if completed_now ~= completed_before then
            if diagnostic_log then
                diagnostic_log.log("optional data fallback", "skipped", "reason", reason or "unknown", "completed_before", completed_before, "completed_now", completed_now)
            end
            return
        end
        if diagnostic_log then
            diagnostic_log.log("optional data fallback", "nudge", "reason", reason or "unknown", "completed_runs", completed_now)
        end
        owner:nudgeOptionalDataAll(false)
    end)
end

function ProgressLifecycleController:onReaderReady()
    local owner = self.owner
    local diagnostic_log = self.deps.diagnostic_log
    if diagnostic_log then diagnostic_log.log("lifecycle", "reader ready") end
    UIManager:scheduleIn(0.5, function() owner:showDataSharingReview() end)
    owner:onDispatcherRegisterActions()
    owner.last_page_turn_timestamp = 0
    owner.last_auto_sync_page = owner.ui.getCurrentPage and owner.ui:getCurrentPage() or nil
    self:scheduleAutomaticUpdateCheck()
    if NetworkMgr:isOnline() then
        UIManager:scheduleIn(1, function() self:scheduleQueueRetry() end)
        self:scheduleOptionalDataFallback(2, "reader_ready")
    end
    if self:canAutoSync() then
        UIManager:nextTick(function() self:autoSyncPull() end)
    end
end

function ProgressLifecycleController:onPageUpdate(page)
    local owner = self.owner
    if page ~= nil and page ~= owner.last_auto_sync_page then
        owner.last_auto_sync_page = page
        owner.last_page_turn_timestamp = os.time()
    end
end

function ProgressLifecycleController:onResume()
    local owner = self.owner
    local diagnostic_log = self.deps.diagnostic_log
    if diagnostic_log then diagnostic_log.log("lifecycle", "resume") end
    if NetworkMgr:isOnline() then
        UIManager:scheduleIn(0.5, function() self:scheduleQueueRetry() end)
        self:scheduleOptionalDataFallback(1.5, "resume")
    end
    if not self:canAutoSync() then return end
    UIManager:scheduleIn(1, function() self:autoSyncPull() end)
end

function ProgressLifecycleController:onSuspend()
    local diagnostic_log = self.deps.diagnostic_log
    if diagnostic_log then diagnostic_log.log("lifecycle", "suspend") end
    self:autoSyncPush()
end

function ProgressLifecycleController:onNetworkConnected()
    local owner = self.owner
    local diagnostic_log = self.deps.diagnostic_log
    if diagnostic_log then diagnostic_log.log("lifecycle", "network connected") end
    self:scheduleAutomaticUpdateCheck()
    UIManager:scheduleIn(1, function() owner:refreshEnhancedCapabilitiesForAll() end)
    UIManager:scheduleIn(0.5, function()
        self:retryQueue(false, function()
            if self:canAutoSync() then self:autoSyncPull() end
        end, "network")
    end)
end

function ProgressLifecycleController:onCloseDocument()
    local owner = self.owner
    local diagnostic_log = self.deps.diagnostic_log
    if diagnostic_log then diagnostic_log.log("lifecycle", "close document", "preview", owner.preview and true or false) end
    if owner.preview then owner.preview = nil; return end
    self:autoSyncPush()
end

return ProgressLifecycleController
