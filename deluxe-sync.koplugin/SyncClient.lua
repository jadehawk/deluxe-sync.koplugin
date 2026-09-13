local UIManager = require("ui/uimanager")
local logger = require("logger")
local socketutil = require("socketutil")
local DiagnosticLog = require("DiagnosticLog")
local UrlUtil = require("UrlUtil")

local PROGRESS_TIMEOUTS = { 2, 5 }
local SYNC_FALLBACK_TIMEOUTS = { 5, 15 }
local AUTH_TIMEOUTS = { 5, 10 }
local BACKGROUND_POLL_INTERVAL = 0.25

local SyncClient = { service_spec = nil, custom_url = nil }

function SyncClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function SyncClient:init()
    local normalized_url, url_error = UrlUtil.normalize(self.custom_url)
    if not normalized_url then
        self.init_error = url_error
        DiagnosticLog.log("client init rejected", self.custom_url or "", url_error or "invalid URL")
        return
    end
    self.custom_url = normalized_url

    local Spore = require("Spore")
    local ok, client_or_error = pcall(Spore.new_from_spec, self.service_spec, { base_url = self.custom_url })
    if not ok then
        self.init_error = tostring(client_or_error)
        DiagnosticLog.log("client init failure", self.custom_url or "", self.init_error)
        return
    end
    self.client = client_or_error
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
    if not self.client then return false, self.init_error or "Sync client is unavailable" end
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("PSDGinClient")
    self.client:enable("PSDAuth", { username = username, userkey = userkey })
    return true
end

function SyncClient:_setupPublic()
    if not self.client then return false, self.init_error or "Sync client is unavailable" end
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("PSDGinClient")
    return true
end

function SyncClient:register(username, userkey)
    DiagnosticLog.log("register", self.custom_url or "", username)
    if not self.client then return false, nil, self.init_error or "Sync client is unavailable" end
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
    local setup_ok, setup_error = self:_setup(username, userkey)
    if not setup_ok then return false, nil, setup_error end
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
    if not self.client then return false, nil, self.init_error or "Sync client is unavailable" end
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

function SyncClient:capabilities()
    DiagnosticLog.log("capability request", self.custom_url or "")
    return self:_publicCall("capabilities", {})
end

function SyncClient:capabilitiesAsync(callback)
    DiagnosticLog.log("capability request async", self.custom_url or "")
    self:_async("capabilities", nil, nil, {}, callback, true)
end

function SyncClient:setRecoveryEmail(username, userkey, email)
    DiagnosticLog.log("recovery email update", self.custom_url or "", "username", username or "", "email", email or "")
    local setup_ok, setup_error = self:_setup(username, userkey)
    if not setup_ok then return false, nil, setup_error end
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

function SyncClient:_async(method, username, userkey, params, callback, public_request)
    local setup_ok, setup_error
    if public_request then
        setup_ok, setup_error = self:_setupPublic()
    else
        setup_ok, setup_error = self:_setup(username, userkey)
    end
    if not setup_ok then
        DiagnosticLog.log("http request blocked", method, self.custom_url or "", setup_error or "Sync client is unavailable")
        callback(false, nil, setup_error)
        return
    end
    DiagnosticLog.log("http request", method, self.custom_url or "", params or {})

    local function deliver(ok, status, body)
        if ok then
            DiagnosticLog.log("http response", method, self.custom_url or "", "status", status, "body", body)
            callback(true, status, body)
        else
            local transport_error = tostring(body or "Network or server unavailable")
            logger.dbg("Deluxe-Sync request failed:", method, transport_error)
            DiagnosticLog.log("http failure", method, self.custom_url or "", transport_error)
            callback(false, nil, transport_error)
        end
    end

    if UIManager.looper then
        socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
        local co = coroutine.create(function()
            local ok, res = pcall(function() return self.client[method](self.client, params or {}) end)
            if ok then
                deliver(true, res.status, res.body)
            else
                deliver(false, nil, res)
            end
        end)
        self.client:enable("PSDAsyncHTTP", { thread = co })
        coroutine.resume(co)
        UIManager:setInputTimeout()
        socketutil:reset_timeout()
        return
    end

    local function runTightSynchronousFallback()
        socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
        local ok, res = pcall(function() return self.client[method](self.client, params or {}) end)
        socketutil:reset_timeout()
        if ok then
            deliver(true, res.status, res.body)
        else
            deliver(false, nil, res)
        end
    end

    -- Turbo is disabled by default on KOReader. Running LuaSec directly here would
    -- block the reader UI for every HTTPS request, which is especially painful
    -- when several sync servers are queried on book open. Do the synchronous
    -- Spore/LuaSec request in a forked background process and only deliver its
    -- small serialized result back on the main UI loop.
    local ffi_ok, ffiutil = pcall(require, "ffi/util")
    local buffer_ok, buffer = pcall(require, "string.buffer")
    if not ffi_ok or not buffer_ok or type(ffiutil.runInSubProcess) ~= "function" then
        runTightSynchronousFallback()
        return
    end
    local pid, parent_read_fd = ffiutil.runInSubProcess(function(unused_pid, child_write_fd)
        socketutil:set_timeout(SYNC_FALLBACK_TIMEOUTS[1], SYNC_FALLBACK_TIMEOUTS[2])
        local ok, res = pcall(function() return self.client[method](self.client, params or {}) end)
        socketutil:reset_timeout()
        local result
        if ok then
            result = { ok = true, status = res.status, body = res.body }
        else
            result = { ok = false, error = tostring(res or "Network or server unavailable") }
        end
        local encoded_ok, encoded = pcall(buffer.encode, result)
        if not encoded_ok then
            encoded = buffer.encode({ ok = false, error = "Could not serialize background HTTP response" })
        end
        ffiutil.writeToFD(child_write_fd, encoded, true)
    end, true)

    if not pid then
        -- Last-resort compatibility path for platforms where fork is unavailable.
        -- Keep KOReader's original tight timeout budget so this can never recreate
        -- the long reader freeze that the background path is designed to avoid.
        runTightSynchronousFallback()
        return
    end

    local function collectLater()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(1, collectLater)
        end
    end

    local function poll()
        local has_output = parent_read_fd and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0
        local subprocess_done = ffiutil.isSubProcessDone(pid)
        if not subprocess_done and not has_output then
            UIManager:scheduleIn(BACKGROUND_POLL_INTERVAL, poll)
            return
        end

        local raw = parent_read_fd and ffiutil.readAllFromFD(parent_read_fd) or ""
        parent_read_fd = nil
        if not subprocess_done then UIManager:scheduleIn(1, collectLater) end

        local decoded_ok, result = pcall(buffer.decode, raw)
        if not decoded_ok or type(result) ~= "table" then
            deliver(false, nil, "Background HTTP request returned an invalid response")
        elseif result.ok then
            deliver(true, result.status, result.body)
        else
            deliver(false, nil, result.error)
        end
    end

    UIManager:scheduleIn(BACKGROUND_POLL_INTERVAL, poll)
end

function SyncClient:updateProgress(username, userkey, payload, callback)
    self:_async("update_progress", username, userkey, payload, callback)
end

function SyncClient:registerDevice(username, userkey, payload, callback)
    self:_async("register_device", username, userkey, payload, callback)
end

function SyncClient:getAnnotations(username, userkey, document, after, limit, callback)
    self:_async("get_annotations", username, userkey, {
        document = document,
        after = tonumber(after) or 0,
        limit = tonumber(limit) or 200,
    }, callback)
end

function SyncClient:putAnnotations(username, userkey, payload, callback)
    self:_async("put_annotations", username, userkey, payload, callback)
end

function SyncClient:putReadingStatistics(username, userkey, payload, callback)
    self:_async("put_reading_statistics", username, userkey, payload, callback)
end

function SyncClient:putVocabulary(username, userkey, payload, callback)
    self:_async("put_vocabulary", username, userkey, payload, callback)
end

function SyncClient:putSettingsBackup(username, userkey, payload, callback)
    self:_async("put_settings_backup", username, userkey, payload, callback)
end

function SyncClient:getSettingsBackup(username, userkey, snapshot_id, callback)
    self:_async("get_settings_backup", username, userkey, {
        snapshot_id = snapshot_id,
    }, callback)
end

function SyncClient:getCurrentSettingsRestore(username, userkey, legacy_device_id, koreader_device_id, callback)
    self:_async("get_current_settings_restore", username, userkey, {
        legacy_device_id = legacy_device_id,
        koreader_device_id = koreader_device_id,
    }, callback)
end

function SyncClient:completeSettingsRestore(username, userkey, request_id, payload, callback)
    payload = payload or {}
    payload.request_id = request_id
    self:_async("complete_settings_restore", username, userkey, payload, callback)
end

function SyncClient:putDeluxeProfile(username, userkey, payload, callback)
    self:_async("put_deluxe_profile", username, userkey, payload, callback)
end

function SyncClient:getDeluxeProfileCandidate(username, userkey, legacy_device_id, koreader_device_id, callback)
    self:_async("get_deluxe_profile_candidate", username, userkey, {
        legacy_device_id = legacy_device_id,
        koreader_device_id = koreader_device_id,
    }, callback)
end

function SyncClient:requestDeluxeProfileRestore(username, userkey, profile_id, legacy_device_id, koreader_device_id, callback)
    self:_async("request_deluxe_profile_restore", username, userkey, {
        profile_id = profile_id,
        legacy_device_id = legacy_device_id,
        koreader_device_id = koreader_device_id,
    }, callback)
end

function SyncClient:getCurrentDeluxeProfileRestore(username, userkey, legacy_device_id, koreader_device_id, callback)
    self:_async("get_current_deluxe_profile_restore", username, userkey, {
        legacy_device_id = legacy_device_id,
        koreader_device_id = koreader_device_id,
    }, callback)
end

function SyncClient:completeDeluxeProfileRestore(username, userkey, request_id, payload, callback)
    payload = payload or {}
    payload.request_id = request_id
    self:_async("complete_deluxe_profile_restore", username, userkey, payload, callback)
end

function SyncClient:getProgress(username, userkey, document, callback)
    self:_async("get_progress", username, userkey, { document = document }, callback)
end

function SyncClient:listDocuments(username, userkey, callback)
    self:_async("list_documents", username, userkey, {}, callback)
end


function SyncClient:listLogicalLibrary(username, userkey, callback)
    self:_async("logical_library", username, userkey, {}, callback)
end

function SyncClient:createLogicalBook(username, userkey, payload, callback)
    self:_async("create_logical_book", username, userkey, payload, callback)
end

function SyncClient:getLogicalBook(username, userkey, id, callback)
    self:_async("get_logical_book", username, userkey, { id = id }, callback)
end

function SyncClient:unlinkLogicalBook(username, userkey, id, callback)
    self:_async("unlink_logical_book", username, userkey, { id = id }, callback)
end

return SyncClient
