local DiagnosticLog = require("DiagnosticLog")
local json = require("json")
local md5 = require("ffi/sha2").md5

local ReadingStatisticsSync = {}
ReadingStatisticsSync.__index = ReadingStatisticsSync

function ReadingStatisticsSync:new(owner, deps)
    return setmetatable({ owner = owner, deps = deps or {} }, self)
end

local function stateFor(server, previous)
    if type(previous) ~= "table" or previous.protocol ~= "koreader_v1"
        or previous.server_url ~= server.url or previous.username ~= server.username then
        return {
            protocol = "koreader_v1", server_url = server.url, username = server.username,
            sent = {}, endpoint_unsupported = false, probe_confirmed = false,
        }
    end
    previous.sent = type(previous.sent) == "table" and previous.sent or {}
    return previous
end

local function acknowledged(body, payload)
    if type(body) == "string" then
        local ok, decoded = pcall(json.decode, body)
        if not ok then return false end
        body = decoded
    end
    return type(body) == "table" and body.version == 1
        and body.document == payload.book.md5 and body.accepted == #payload.pages
end

function ReadingStatisticsSync:sync(server, callback)
    local owner = self.owner
    local adapter = self.deps.adapter
    callback = callback or function() end
    if not owner.store or not adapter or not server or server.enabled == false then
        callback(false, nil, "Reading statistics sync is unavailable")
        return
    end
    if server.reading_statistics_enabled ~= true then
        callback(true, 200, "Reading statistics sharing is disabled")
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.statistics_sync_in_flight[sync_key] then
        callback(false, nil, "Reading statistics sync is already in progress")
        return
    end

    local stored_state = stateFor(server, owner.store:getReadingStatisticsState(server.id))
    local capabilities = server.capabilities or {}
    local advertised = owner:serverSupportsReadingStatistics(server)
    local can_probe = capabilities.reading_statistics_probe_allowed == true
    if stored_state.endpoint_unsupported or not (advertised or can_probe) then
        callback(true, 200, "Reading statistics endpoint is not supported by this server")
        return
    end
    if not adapter.validTimezone(server.reading_statistics_timezone) then
        callback(false, nil, "Set Reading Time Zone in this server's settings before uploading statistics")
        return
    end

    owner.statistics_sync_in_flight[sync_key] = true
    local function targetUnchanged()
        if not owner.store.getServer then return true end
        local current = owner.store:getServer(server.id)
        return current ~= nil and current.enabled ~= false
            and current.reading_statistics_enabled == true
            and current.url == server.url and current.username == server.username
            and current.userkey == server.userkey
            and current.reading_statistics_timezone == server.reading_statistics_timezone
    end
    local function finish(ok, status, message)
        owner.statistics_sync_in_flight[sync_key] = nil
        DiagnosticLog.log("reading statistics sync", self.deps.server_label(server),
            "ok", ok and true or false, "status", status or "nil", "message", message or "")
        callback(ok, status, message)
    end

    if not targetUnchanged() then
        finish(false, nil, "Server settings changed before reading statistics upload")
        return
    end

    -- Persist finished page records before reading a snapshot. Do not create a
    -- synthetic turn for the currently open page.
    if owner.ui and owner.ui.statistics and type(owner.ui.statistics.insertDB) == "function" then
        local flushed, reason = pcall(owner.ui.statistics.insertDB, owner.ui.statistics)
        if not flushed then
            finish(false, nil, "Could not flush KOReader statistics: " .. tostring(reason))
            return
        end
    end

    local listing, list_error = adapter.listBooks()
    if not listing then
        finish(false, nil, list_error or "Unable to read KOReader statistics")
        return
    end
    if listing.missing or #listing.books == 0 then
        finish(true, 200, "No recorded reading history to upload")
        return
    end

    local client = owner:newClient(server)
    local function uploadNext(index)
        while index <= #listing.books do
            if not targetUnchanged() then
                finish(false, nil, "Server settings changed during reading statistics upload")
                return
            end
            local book = listing.books[index]
            local payload, read_error = adapter.readBook(book, server.reading_statistics_timezone)
            if not payload then
                finish(false, nil, read_error or "Unable to read book history")
                return
            end
            if payload.missing or #payload.pages == 0 then
                finish(false, nil, "Reading history changed during sync; retry later")
                return
            end

            local encoded_ok, body = pcall(json.encode, payload)
            if not encoded_ok or type(body) ~= "string" then
                finish(false, nil, "Could not encode KOReader reading history")
                return
            end
            if #body > adapter.MAX_BODY_BYTES then
                finish(false, nil, "Book history exceeds the 4 MB upload limit; use the server history-file importer")
                return
            end
            local fingerprint = md5(body)
            if stored_state.sent[book.md5] ~= fingerprint then
                client:postKOReaderStatistics(server.username, server.userkey, payload, function(ok, status, response)
                    if not targetUnchanged() then
                        finish(false, nil, "Server settings changed during reading statistics upload")
                        return
                    end
                    if status == 404 or status == 405 then
                        stored_state.endpoint_unsupported = true
                        stored_state.probe_confirmed = false
                        owner.store:saveReadingStatisticsState(server.id, stored_state)
                        owner.store:setCapability(server.id, "reading_statistics", false)
                        owner.store:setCapability(server.id, "reading_statistics_probe_allowed", false)
                        finish(false, status, "This server does not support the KOReader statistics endpoint")
                        return
                    end
                    if not ok or status ~= 200 then
                        finish(false, status, self.deps.server_response_message(response)
                            or tostring(response or "Reading statistics upload failed"))
                        return
                    end
                    if not acknowledged(response, payload) then
                        finish(false, status, "Server did not acknowledge the reading history; retry later")
                        return
                    end
                    stored_state.sent[book.md5] = fingerprint
                    stored_state.probe_confirmed = true
                    owner.store:saveReadingStatisticsState(server.id, stored_state)
                    if can_probe then owner.store:setCapability(server.id, "reading_statistics", true) end
                    uploadNext(index + 1)
                end)
                return
            end
            index = index + 1
        end
        finish(true, 200, "Reading statistics are up to date")
    end
    uploadNext(1)
end

return ReadingStatisticsSync
