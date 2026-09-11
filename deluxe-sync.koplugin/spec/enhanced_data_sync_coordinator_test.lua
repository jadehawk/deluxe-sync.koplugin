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
local owner = {
    store = {
        getEnabledServers = function() return servers end,
    },
}
function owner:syncOptionalDataForServer(server, document, callback)
    table.insert(calls, { id = server.id, document = document })
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

calls = {}
online = false
coordinator:nudge({ one = "offline-doc" }, true)
assert(#scheduled == 1, "offline nudge should remain scheduled for a connectivity check")
runScheduled()
assert(#calls == 0, "offline coordinator runs must not start optional data work")
assert(coordinator.pending_documents.one == "offline-doc", "offline work must remain pending instead of being discarded")

online = true
coordinator:nudge(nil, true)
runScheduled()
assert(#calls == 2, "pending optional work must resume once connectivity returns")
assert(calls[1].document == "offline-doc", "pending document identity must survive the offline interval")
assert(coordinator.pending_documents.one == nil, "resumed work must drain pending document state")

print("enhanced_data_sync_coordinator_test.lua: OK")
