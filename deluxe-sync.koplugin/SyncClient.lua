local UIManager = require("ui/uimanager")
local logger = require("logger")
local socketutil = require("socketutil")
local DiagnosticLog = require("DiagnosticLog")

local PROGRESS_TIMEOUTS = { 2, 5 }
local AUTH_TIMEOUTS = { 5, 10 }

local SyncClient = { service_spec = nil, custom_url = nil }

function SyncClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function SyncClient:init()
    local Spore = require("Spore")
    self.client = Spore.new_from_spec(self.service_spec, { base_url = self.custom_url })
    package.loaded["Spore.Middleware.PSDGinClient"] = {}
    require("Spore.Middleware.PSDGinClient").call = function(_, req)
        req.headers["accept"] = "application/vnd.koreader.v1+json"
    end
    package.loaded["Spore.Middleware.PSDAuth"] = {}
    require("Spore.Middleware.PSDAuth").call = function(args, req)
        req.headers["x-auth-user"] = args.username
        req.headers["x-auth-key"] = args.userkey
    end
    package.loaded["Spore.Middleware.PSDAsyncHTTP"] = {}
    require("Spore.Middleware.PSDAsyncHTTP").call = function(args, req)
        if not UIManager.looper then return end
        req:finalize()
        local result
        require("httpclient"):new():request({
            url = req.url,
            method = req.method,
            body = req.env.spore.payload,
            on_headers = function(headers)
                for header, value in pairs(req.headers) do
                    if type(header) == "string" then headers:add(header, value) end
                end
            end,
        }, function(res)
            result = res
            result.status = res.code
            coroutine.resume(args.thread)
        end)
        return coroutine.create(function() coroutine.yield(result) end)
    end
end

function SyncClient:_setup(username, userkey)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("PSDGinClient")
    self.client:enable("PSDAuth", { username = username, userkey = userkey })
end

function SyncClient:register(username, userkey)
    DiagnosticLog.log("register", self.custom_url or "", username)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("PSDGinClient")
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client:register({
            username = username,
            password = userkey,
        })
    end)
    socketutil:reset_timeout()
    if not ok then
        logger.dbg("Deluxe-Sync registration failed:", res)
        DiagnosticLog.log("register failure", self.custom_url or "", username, res)
        if type(res) == "table" and type(res.response) == "table" then
            return false, res.response.status, res.response.body or res.reason
        end
        return false, nil, res
    end
    DiagnosticLog.log("register response", self.custom_url or "", username, "status", res.status)
    return res.status == 201, res.status, res.body
end

function SyncClient:authorize(username, userkey)
    DiagnosticLog.log("authorize", self.custom_url or "", username)
    self:_setup(username, userkey)
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function() return self.client:authorize() end)
    socketutil:reset_timeout()
    if not ok then
        DiagnosticLog.log("authorize failure", self.custom_url or "", username, res)
        if type(res) == "table" and type(res.response) == "table" then
            return false, res.response.status, res.response.body or res.reason
        end
        return false, nil, res
    end
    DiagnosticLog.log("authorize response", self.custom_url or "", username, "status", res.status)
    return res.status == 200, res.status, res.body
end

function SyncClient:_publicCall(method, params)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("PSDGinClient")
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client[method](self.client, params or {})
    end)
    socketutil:reset_timeout()
    if not ok then
        if type(res) == "table" and type(res.response) == "table" then
            local response_body = res.response.body or res.reason or ""
            if method == "recovery_confirm" then
                DiagnosticLog.log("public request failure", method, self.custom_url or "", "status", res.response.status or "nil", "body_length", #tostring(response_body))
            else
                DiagnosticLog.log("public request failure", method, self.custom_url or "", "status", res.response.status or "nil", "body", response_body)
            end
            return false, res.response.status, response_body
        end
        if method == "recovery_confirm" then
            DiagnosticLog.log("public request failure", method, self.custom_url or "", "error", "<redacted-sensitive-error>")
        else
            DiagnosticLog.log("public request failure", method, self.custom_url or "", "error", tostring(res))
        end
        return false, nil, res
    end
    if method == "recovery_confirm" then
        DiagnosticLog.log("public request response", method, self.custom_url or "", "status", res.status, "body_length", #tostring(res.body or ""))
    else
        DiagnosticLog.log("public request response", method, self.custom_url or "", "status", res.status, "body", res.body)
    end
    return true, res.status, res.body
end

function SyncClient:recoveryCapability()
    DiagnosticLog.log("recovery capability request", self.custom_url or "")
    return self:_publicCall("recovery_capability", {})
end

function SyncClient:setRecoveryEmail(username, userkey, email)
    DiagnosticLog.log("recovery email update", self.custom_url or "", "username", username or "", "email", email or "")
    self:_setup(username, userkey)
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client:recovery_email({ email = email })
    end)
    socketutil:reset_timeout()
    if not ok then
        if type(res) == "table" and type(res.response) == "table" then
            DiagnosticLog.log("recovery email failure", self.custom_url or "", "status", res.response.status or "nil", "body", res.response.body or res.reason or "")
            return false, res.response.status, res.response.body or res.reason
        end
        DiagnosticLog.log("recovery email failure", self.custom_url or "", "error", tostring(res))
        return false, nil, res
    end
    DiagnosticLog.log("recovery email response", self.custom_url or "", "status", res.status, "body", res.body)
    return res.status == 200 or res.status == 204, res.status, res.body
end

function SyncClient:requestRecovery(username, email)
    DiagnosticLog.log("recovery code request", self.custom_url or "", "username", username or "", "email", email or "")
    return self:_publicCall("recovery_request", { username = username, email = email })
end

function SyncClient:confirmRecovery(username, email, code, new_userkey)
    DiagnosticLog.log(
        "recovery confirm request",
        self.custom_url or "",
        "username", username or "",
        "email", email or "",
        "code_length", #(code or ""),
        "new_userkey", "<redacted>"
    )
    return self:_publicCall("recovery_confirm", {
        username = username,
        email = email,
        code = code,
        new_userkey = new_userkey,
    })
end

function SyncClient:_async(method, username, userkey, params, callback)
    self:_setup(username, userkey)
    DiagnosticLog.log("http request", method, self.custom_url or "", params or {})
    socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
    local co = coroutine.create(function()
        local ok, res = pcall(function() return self.client[method](self.client, params or {}) end)
        if ok then
            DiagnosticLog.log("http response", method, self.custom_url or "", "status", res.status, "body", res.body)
            callback(true, res.status, res.body)
        else
            logger.dbg("Deluxe-Sync request failed:", method, res)
            DiagnosticLog.log("http failure", method, self.custom_url or "", res)
            callback(false, nil, nil)
        end
    end)
    self.client:enable("PSDAsyncHTTP", { thread = co })
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
    socketutil:reset_timeout()
end

function SyncClient:updateProgress(username, userkey, payload, callback)
    self:_async("update_progress", username, userkey, payload, callback)
end

function SyncClient:getProgress(username, userkey, document, callback)
    self:_async("get_progress", username, userkey, { document = document }, callback)
end

function SyncClient:listDocuments(username, userkey, callback)
    self:_async("list_documents", username, userkey, {}, callback)
end

return SyncClient
