local online = true
local scheduled = {}
local diagnostic = {}

package.loaded["AnnotationSync"] = nil
package.preload["device"] = function()
    return { model = "Test Reader" }
end
package.preload["ui/event"] = function()
    return {
        new = function(_, name)
            return { name = name }
        end,
    }
end
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
package.preload["DiagnosticLog"] = function()
    return {
        log = function(...)
            table.insert(diagnostic, { ... })
        end,
    }
end

local AnnotationSync = require("AnnotationSync")

local function runScheduled()
    while #scheduled > 0 do
        local item = table.remove(scheduled, 1)
        item.callback()
    end
end

local server = {
    id = "server-one",
    name = "Techy-Notes",
    url = "https://sync.techy-notes.com",
    username = "user",
    userkey = "key",
    annotations_enabled = true,
    capabilities = {
        annotations = true,
        annotations_version = 1,
    },
}

local event_sync_calls = {}
local event_owner = {
    store = {
        getEnabledServers = function() return { server } end,
    },
    annotation_sync_in_flight = {},
}
function event_owner:getDocumentDigest() return "doc-one" end
function event_owner:getServerDocumentDigest() return nil end
function event_owner:serverSupportsAnnotations(candidate)
    return candidate.capabilities.annotations == true
        and tonumber(candidate.capabilities.annotations_version) >= 1
end
function event_owner:syncAnnotationsForServer(candidate, document, callback)
    table.insert(event_sync_calls, { server = candidate, document = document })
    callback(true, 200, "")
end

local event_service = AnnotationSync:new(event_owner, {
    server_label = function(candidate) return candidate and candidate.name or "server" end,
})

assert(event_service:onAnnotationsModified() == true, "local annotation event should schedule sync")
assert(event_service:onAnnotationsModified() == true, "repeated local annotation event should debounce")
assert(#scheduled == 2, "each event should only schedule a debounce marker before coalescing")
runScheduled()
assert(#event_sync_calls == 1, "debounced annotation changes must produce one server sync")
assert(event_sync_calls[1].document == "doc-one", "annotation event sync must use the active document")

event_owner.annotation_sync_internal_event = true
assert(event_service:onAnnotationsModified() == false, "internal annotation persistence event must not loop back into sync")
runScheduled()
assert(#event_sync_calls == 1, "internal annotation update must not schedule another server sync")
event_owner.annotation_sync_internal_event = nil

online = false
assert(event_service:onAnnotationsModified() == false, "offline annotation event must defer to normal reconnect convergence")
assert(#scheduled == 0, "offline annotation event must not schedule network work")
online = true

local state = {
    cursor = 10,
    items = {
        ["stale-id"] = {
            revision = 1,
            deleted = false,
            fingerprint = "stale",
        },
    },
}
local pending = {
    {
        id = "stale-id",
        base_revision = 1,
        kind = "highlight",
        deleted = false,
        text = "Existing local highlight",
    },
    {
        id = "new-id",
        base_revision = 0,
        kind = "highlight",
        deleted = false,
        text = "New local highlight",
    },
}
local put_calls = {}
local saved = 0
local sync_finished = nil

local adapter = {}
function adapter.collectLocalChanges()
    return pending, false
end
function adapter.applyRemote()
    return false
end
function adapter.remember(current_state, remote)
    current_state.items[remote.id] = {
        revision = tonumber(remote.revision) or 0,
        deleted = remote.deleted == true,
    }
end

local client = {}
function client:getAnnotations(_username, _userkey, _document, _after, _limit, callback)
    callback(true, 200, {
        changes = {},
        cursor = 10,
        has_more = false,
    })
end
function client:putAnnotations(_username, _userkey, payload, callback)
    local bases = {}
    for _, item in ipairs(payload.annotations) do
        bases[item.id] = item.base_revision
    end
    table.insert(put_calls, bases)
    if #put_calls == 1 then
        callback(false, 422, "Unknown annotation stale-id cannot start at revision 1\n")
        return
    end
    callback(true, 200, {
        results = {
            { annotation = { id = "stale-id", revision = 1, deleted = false, kind = "highlight" } },
            { annotation = { id = "new-id", revision = 1, deleted = false, kind = "highlight" } },
        },
    })
end

local sync_owner = {
    annotation_sync_in_flight = {},
    store = {
        data = { device_id = "device-one" },
        getAnnotationState = function() return state end,
        saveAnnotationState = function()
            saved = saved + 1
        end,
    },
    ui = {
        annotation = { annotations = {} },
    },
}
function sync_owner:serverSupportsAnnotations() return true end
function sync_owner:newClient() return client end

local sync_service = AnnotationSync:new(sync_owner, {
    adapter = adapter,
    decode = function(body) return type(body) == "table" and body or nil end,
    server_label = function(candidate) return candidate.name end,
})

sync_service:sync(server, "doc-one", function(ok, status, body)
    sync_finished = { ok = ok, status = status, body = body }
end)

assert(#put_calls == 2, "one stale server revision should be rebased and retried instead of failing the whole batch")
assert(put_calls[1]["stale-id"] == 1, "first upload must reproduce the stale saved revision")
assert(put_calls[1]["new-id"] == 0, "new annotations must remain revision zero")
assert(put_calls[2]["stale-id"] == 0, "unknown server annotation must retry as a fresh revision-zero record")
assert(put_calls[2]["new-id"] == 0, "fresh annotations must remain in the recovered batch")
assert(sync_finished and sync_finished.ok == true and sync_finished.status == 200, "recovered annotation batch must finish successfully")
assert(state.items["stale-id"] and state.items["stale-id"].revision == 1, "successful retry must rebuild saved revision state")
assert(state.items["new-id"] and state.items["new-id"].revision == 1, "new annotation must be remembered after recovered upload")
assert(saved > 0, "annotation recovery must persist repaired state")

print("annotation_sync_runtime_test.lua: OK")
