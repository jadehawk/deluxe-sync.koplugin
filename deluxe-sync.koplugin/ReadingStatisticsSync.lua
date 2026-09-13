local Device = require("device")
local DiagnosticLog = require("DiagnosticLog")

local ReadingStatisticsSync = {}
ReadingStatisticsSync.__index = ReadingStatisticsSync

function ReadingStatisticsSync:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function ReadingStatisticsSync:sync(server, callback)
    local owner = self.owner
    local ReadingStatisticsAdapter = self.deps.adapter
    callback = callback or function() end
    if not owner.store or not ReadingStatisticsAdapter or not server or server.enabled == false then
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

    local client = owner:newClient(server)
    if not owner:serverSupportsReadingStatistics(server) then
        callback(false, nil, "Reading statistics are not supported")
        return
    end

    owner.statistics_sync_in_flight[sync_key] = true
    local stored_state = owner.store:getReadingStatisticsState(server.id)
    local high_water = {
        start_time = tonumber(stored_state.start_time) or 0,
        id_book = tonumber(stored_state.id_book) or 0,
        page = tonumber(stored_state.page) or -1,
        initial_complete = stored_state.initial_complete == true,
    }
    local scan_cursor = ReadingStatisticsAdapter.makeScanCursor(stored_state)
    local registration = owner:getDeviceRegistrationPayload()

    local function cursorIsAfter(candidate, current)
        local candidate_time = tonumber(candidate.start_time) or 0
        local current_time = tonumber(current.start_time) or 0
        if candidate_time ~= current_time then return candidate_time > current_time end
        local candidate_book = tonumber(candidate.id_book) or 0
        local current_book = tonumber(current.id_book) or 0
        if candidate_book ~= current_book then return candidate_book > current_book end
        return (tonumber(candidate.page) or -1) > (tonumber(current.page) or -1)
    end

    local function finish(ok, status, message)
        owner.statistics_sync_in_flight[sync_key] = nil
        if DiagnosticLog then
            DiagnosticLog.log("reading statistics sync", self.deps.server_label(server), "ok", ok and true or false, "status", status or "nil", "message", message or "")
        end
        callback(ok, status, message)
    end

    local uploadNext
    uploadNext = function(cursor)
        local batch, read_error = ReadingStatisticsAdapter.readBatch(cursor, ReadingStatisticsAdapter.DEFAULT_BATCH_SIZE)
        if not batch then
            finish(false, nil, read_error or "Unable to read KOReader statistics")
            return
        end
        if batch.missing then
            finish(true, 200, "KOReader statistics database is not present")
            return
        end
        if #batch.events == 0 then
            high_water.initial_complete = true
            owner.store:saveReadingStatisticsState(server.id, high_water)
            finish(true, 200, "Reading statistics are up to date")
            return
        end

        client:putReadingStatistics(server.username, server.userkey, {
            legacy_device_id = tostring(owner.store.data.device_id),
            koreader_device_id = registration.koreader_device_id,
            device = tostring(Device.model or "KOReader device"),
            source_type = ReadingStatisticsAdapter.SOURCE_TYPE,
            source_schema_version = batch.source_schema_version,
            events = batch.events,
        }, function(ok, status, body)
            if not ok or status ~= 200 then
                finish(false, status, self.deps.server_response_message(body) or body or "Reading statistics upload failed")
                return
            end
            if cursorIsAfter(batch.cursor, high_water) then
                high_water.start_time = batch.cursor.start_time
                high_water.id_book = batch.cursor.id_book
                high_water.page = batch.cursor.page
            end
            owner.store:saveReadingStatisticsState(server.id, high_water)
            uploadNext(batch.cursor)
        end)
    end

    uploadNext(scan_cursor)
end

return ReadingStatisticsSync
