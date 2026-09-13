local online = true
local scheduled = {}

package.loaded["EnhancedDataSyncCoordinator"] = nil
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return online end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, callback)
            table.insert(scheduled, { delay = delay, callback = callback })
        end,
    }
end

local EnhancedDataSyncCoordinator = require("EnhancedDataSyncCoordinator")

local servers = {
    { id = "one", enabled = true },
    { id = "two", enabled = true },
}
local calls = {}
local deferred = false
local deferred_callbacks = {}
local optional_documents = {}
local owner = {
    store = {
        getEnabledServers = function() return servers end,
    },
}
function owner:getOptionalDataDocuments()
    return optional_documents
end
function owner:syncOptionalDataForServer(server, document, callback)
    table.insert(calls, { id = server.id, document = document })
    if deferred then
        table.insert(deferred_callbacks, callback)
    else
        callback(true)
    end
end

local function completeDeferred()
    local callback = table.remove(deferred_callbacks, 1)
    assert(callback, "expected a deferred optional-data callback")
    callback(true)
end

local function runScheduled()
    while #scheduled > 0 do
        local item = table.remove(scheduled, 1)
        item.callback()
    end
end

local coordinator = EnhancedDataSyncCoordinator:new(owner)
coordinator:nudge({ one = "doc-one" }, false)
coordinator:nudge({ two = "doc-two" }, false)
assert(#scheduled == 1, "repeated nudges before a run must coalesce into one scheduled pass")
runScheduled()
assert(#calls == 2, "one coalesced pass must visit each enabled server once")
assert(calls[1].id == "one" and calls[1].document == "doc-one", "first server must keep its coalesced document identity")
assert(calls[2].id == "two" and calls[2].document == "doc-two", "second server must keep its coalesced document identity")
assert(coordinator.running == false, "coordinator must clear running state after the serialized pass")
assert(coordinator.completed_runs == 1, "a completed convergence pass must increment the completion counter once")

calls = {}
online = false
coordinator:nudge({ one = "offline-doc" }, true)
assert(#scheduled == 1, "offline nudge should remain scheduled for a connectivity check")
runScheduled()
assert(#calls == 0, "offline coordinator runs must not start optional data work")
assert(coordinator.pending_documents.one == "offline-doc", "offline work must remain pending instead of being discarded")
assert(coordinator.completed_runs == 1, "offline connectivity checks must not count as completed convergence passes")

online = true
coordinator:nudge(nil, true)
runScheduled()
assert(#calls == 2, "pending optional work must resume once connectivity returns")
assert(calls[1].document == "offline-doc", "pending document identity must survive the offline interval")
assert(coordinator.pending_documents.one == nil, "resumed work must drain pending document state")
assert(coordinator.completed_runs == 2, "resumed convergence must increment the completion counter after real work finishes")

servers = {
    { id = "one", enabled = true },
    { id = "two", enabled = true },
}
optional_documents = { one = "doc-one", two = "doc-two" }
calls = {}
deferred = true
deferred_callbacks = {}
coordinator = EnhancedDataSyncCoordinator:new(owner)
coordinator:nudge({ one = "doc-one" }, true)
local start_item = table.remove(scheduled, 1)
assert(start_item, "expected the initial convergence pass to be scheduled")
start_item.callback()
assert(coordinator.running == true and #calls == 1, "test setup must hold one convergence pass in flight")
coordinator:nudge({ one = "doc-one", two = "doc-two" }, false)
assert(coordinator.rerun == false, "a reader-ready global nudge matching the active pass must not request a duplicate convergence pass")
assert(next(coordinator.pending_documents) == nil, "matching in-flight global work must not queue duplicate document work")
completeDeferred()
runScheduled()
assert(#calls == 2 and calls[2].id == "two" and calls[2].document == "doc-two", "the active pass must already contain the full current document map")
completeDeferred()
runScheduled()
assert(#calls == 2, "a matching reader-ready global nudge must be absorbed instead of running a second pass")
assert(coordinator.running == false, "coordinator must finish normally after absorbing a matching global nudge")

servers = { { id = "one", enabled = true } }
optional_documents = { one = "old-doc" }
calls = {}
deferred_callbacks = {}
coordinator = EnhancedDataSyncCoordinator:new(owner)
coordinator:nudge({ one = "old-doc" }, true)
start_item = table.remove(scheduled, 1)
assert(start_item, "expected changed-document test pass to be scheduled")
start_item.callback()
coordinator:nudge({ one = "new-doc" }, false)
assert(coordinator.rerun == true, "a changed document identity during an active pass must request one follow-up pass")
completeDeferred()
runScheduled()
assert(#calls == 2 and calls[2].document == "new-doc", "the follow-up pass must preserve the changed document identity")
completeDeferred()
runScheduled()
assert(coordinator.running == false and next(coordinator.pending_documents) == nil, "changed-document follow-up must drain cleanly")

deferred = false
print("enhanced_data_sync_coordinator_test.lua: OK")
