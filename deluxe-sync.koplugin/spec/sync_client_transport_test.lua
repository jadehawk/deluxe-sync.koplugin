package.path = "./?.lua;" .. package.path

local captured_timeouts = {}
local reset_count = 0
local subprocess_count = 0
local scheduled_count = 0
local pipe_payload
local encoded_values = {}
local encode_count = 0

local ui_manager = {
    looper = nil,
    setInputTimeout = function() end,
    scheduleIn = function(_, _, callback)
        scheduled_count = scheduled_count + 1
        callback()
    end,
}

package.preload["ui/uimanager"] = function() return ui_manager end
package.preload["logger"] = function() return { dbg = function() end } end
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_, block_timeout, total_timeout)
            captured_timeouts[#captured_timeouts + 1] = { block_timeout, total_timeout }
        end,
        reset_timeout = function()
            reset_count = reset_count + 1
        end,
    }
end
package.preload["DiagnosticLog"] = function()
    return { log = function() end }
end
package.preload["string.buffer"] = function()
    return {
        encode = function(value)
            encode_count = encode_count + 1
            local token = "encoded:" .. tostring(encode_count)
            encoded_values[token] = value
            return token
        end,
        decode = function(token)
            return encoded_values[token]
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(task, with_pipe)
            assert(with_pipe == true, "background HTTP transport must request a child-to-parent pipe")
            subprocess_count = subprocess_count + 1
            task(4321, 99)
            return 4321, 88
        end,
        writeToFD = function(fd, payload)
            assert(fd == 99, "background child must write to its pipe fd")
            pipe_payload = payload
            return true
        end,
        getNonBlockingReadSize = function(fd)
            assert(fd == 88, "background parent must poll its pipe fd")
            return pipe_payload and #pipe_payload or 0
        end,
        isSubProcessDone = function(pid)
            assert(pid == 4321, "background parent must poll the spawned child")
            return true
        end,
        readAllFromFD = function(fd)
            assert(fd == 88, "background parent must read its pipe fd")
            local payload = pipe_payload or ""
            pipe_payload = nil
            return payload
        end,
    }
end

local response_mode = "wantread"
local enabled_middlewares = {}
local fake_client = {
    reset_middlewares = function() enabled_middlewares = {} end,
    enable = function(_, name) enabled_middlewares[#enabled_middlewares + 1] = name end,
    update_progress = function()
        if response_mode == "wantread" then
            error("common/Spore/Protocols.lua:85: wantread")
        end
        return { status = 200, body = '{"ok":true}' }
    end,
    capabilities = function()
        return { status = 200, body = '{"capabilities":{}}' }
    end,
}

package.preload["Spore"] = function()
    return {
        new_from_spec = function()
            return fake_client
        end,
    }
end

local SyncClient = require("SyncClient")
local client = SyncClient:new{
    service_spec = "api.json",
    custom_url = "https://sync-beta.techy-notes.com",
}

local failure_callback_called = false
client:updateProgress("reader", "key", { document = "abc" }, function(ok, status, body)
    failure_callback_called = true
    assert(ok == false, "transport failure must report failure")
    assert(status == nil, "transport failure must not invent an HTTP status")
    assert(type(body) == "string" and body:find("wantread", 1, true), "transport error must be preserved for retry classification")
end)

assert(failure_callback_called, "background transport failure must complete the parent callback")
assert(subprocess_count == 1, "non-Turbo transport must run through a background subprocess")
assert(captured_timeouts[1] and captured_timeouts[1][1] == 5 and captured_timeouts[1][2] == 15,
    "background LuaSec request must use the safer 5/15 timeout budget")
assert(reset_count == 1, "child socket timeout must be reset after the failed request")
assert(scheduled_count >= 1, "background subprocess result must return through the UI scheduler")

response_mode = "success"
local success_callback_called = false
client:updateProgress("reader", "key", { document = "def" }, function(ok, status, body)
    success_callback_called = true
    assert(ok == true, "successful background transport must report success")
    assert(status == 200, "successful background transport must preserve HTTP status")
    assert(body == '{"ok":true}', "successful background transport must preserve response body")
end)

assert(success_callback_called, "background transport success must complete the parent callback")
assert(subprocess_count == 2, "each non-Turbo request must be isolated from the UI thread")
assert(captured_timeouts[2] and captured_timeouts[2][1] == 5 and captured_timeouts[2][2] == 15,
    "successful background LuaSec request must keep the 5/15 timeout budget")
assert(reset_count == 2, "child socket timeout must be reset after every request")

ui_manager.looper = {}
local looper_callback_called = false
client:updateProgress("reader", "key", { document = "looper" }, function(ok, status)
    looper_callback_called = true
    assert(ok == true and status == 200, "KOReader looper transport must preserve successful progress responses")
end)
assert(looper_callback_called, "KOReader looper transport must complete the progress callback")
assert(captured_timeouts[3] and captured_timeouts[3][1] == 5 and captured_timeouts[3][2] == 20,
    "KOReader looper progress requests must allow the 5/20 timeout budget")
assert(subprocess_count == 2, "KOReader looper transport must not fork the background fallback")
ui_manager.looper = nil

local capability_callback_called = false
client:capabilitiesAsync(function(ok, status, body)
    capability_callback_called = true
    assert(ok == true, "public capability discovery must use the background transport")
    assert(status == 200, "public capability discovery must preserve HTTP status")
    assert(body == '{"capabilities":{}}', "public capability discovery must preserve response body")
end)
assert(capability_callback_called, "background capability discovery must complete the parent callback")
assert(subprocess_count == 3, "public capability discovery must not fall back to the UI thread")
for _, middleware in ipairs(enabled_middlewares) do
    assert(middleware ~= "PSDAuth", "public capability discovery must not attach authenticated middleware")
end

print("sync_client_transport_test.lua: OK")
