package.path = "./?.lua;" .. package.path

local logs = {}
local captured = {}

package.preload["ui/uimanager"] = function() return { looper = nil, setInputTimeout = function() end } end
package.preload["logger"] = function() return { dbg = function() end } end
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end
package.preload["DiagnosticLog"] = function()
    return {
        log = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
            logs[#logs + 1] = table.concat(parts, " ")
        end,
    }
end

local fake_client = {
    reset_middlewares = function() end,
    enable = function() end,
    recovery_capability = function(_, params)
        captured.capability = params
        return { status = 200, body = '{"supported":true,"code_ttl_seconds":900}' }
    end,
    recovery_email = function(_, params)
        captured.email = params
        return { status = 204, body = "" }
    end,
    recovery_request = function(_, params)
        captured.request = params
        return { status = 202, body = '{"accepted":true}' }
    end,
    recovery_confirm = function(_, params)
        captured.confirm = params
        return { status = 200, body = '{"reset":true}' }
    end,
}

package.preload["Spore"] = function()
    return { new_from_spec = function() return fake_client end }
end

local SyncClient = require("SyncClient")
local client = SyncClient:new{ service_spec = "api.json", custom_url = "http://192.168.1.20:8080" }

local ok, status = client:recoveryCapability()
assert(ok == true and status == 200)

local existing_key = "abcdefabcdefabcdefabcdefabcdefab"
ok, status = client:setRecoveryEmail("reader", existing_key, "reader@example.com")
assert(ok == true and status == 204)
assert(captured.email.email == "reader@example.com")

ok, status = client:requestRecovery("reader", "reader@example.com")
assert(ok == true and status == 202)
assert(captured.request.username == "reader")
assert(captured.request.email == "reader@example.com")

local code = "482193"
local key = "0123456789abcdef0123456789abcdef"
ok, status = client:confirmRecovery("reader", "reader@example.com", code, key)
assert(ok == true and status == 200)
assert(captured.confirm.username == "reader")
assert(captured.confirm.email == "reader@example.com")
assert(captured.confirm.code == code)
assert(captured.confirm.new_userkey == key)

local joined = table.concat(logs, "\n")
assert(not joined:find(code, 1, true), "recovery code leaked into diagnostics")
assert(not joined:find(key, 1, true), "authentication-equivalent userkey leaked into diagnostics")
assert(not joined:find(existing_key, 1, true), "existing userkey leaked into diagnostics")
assert(joined:find("code_length 6", 1, true), "expected recovery code length diagnostic")
assert(joined:find("new_userkey <redacted>", 1, true), "expected redacted userkey diagnostic")

fake_client.recovery_confirm = function()
    error({ response = { status = 410, body = "Recovery code expired" } })
end
ok, status = client:confirmRecovery("reader", "reader@example.com", code, key)
assert(ok == false and status == 410)
joined = table.concat(logs, "\n")
assert(not joined:find(code, 1, true), "recovery code leaked on failure")
assert(not joined:find(key, 1, true), "userkey leaked on failure")
assert(joined:find("status 410", 1, true), "expected recovery failure status")
assert(joined:find("body_length", 1, true), "expected recovery failure body length diagnostic")

print("recovery_client_test.lua: OK")
