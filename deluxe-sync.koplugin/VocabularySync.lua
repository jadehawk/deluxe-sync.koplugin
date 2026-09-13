local Device = require("device")
local DiagnosticLog = require("DiagnosticLog")

local VocabularySync = {}
VocabularySync.__index = VocabularySync

function VocabularySync:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function VocabularySync:sync(server, callback)
    local owner = self.owner
    local VocabularyAdapter = self.deps.adapter
    callback = callback or function() end
    if not owner.store or not VocabularyAdapter or not server or server.enabled == false then
        callback(false, nil, "Vocabulary Builder sync is unavailable")
        return
    end
    if server.vocabulary_enabled ~= true then
        callback(true, 200, "Vocabulary Builder sharing is disabled")
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.vocabulary_sync_in_flight[sync_key] then
        callback(false, nil, "Vocabulary Builder sync is already in progress")
        return
    end

    local client = owner:newClient(server)
    local capabilities = server.capabilities or {}
    if not owner:serverSupportsVocabulary(server) then
        callback(false, nil, "Vocabulary Builder is not supported")
        return
    end

    local include_context = server.vocabulary_context_enabled == true and capabilities.vocabulary_context == true
    owner.vocabulary_sync_in_flight[sync_key] = true

    local function finish(ok, status, message)
        owner.vocabulary_sync_in_flight[sync_key] = nil
        if DiagnosticLog then
            DiagnosticLog.log("vocabulary sync", self.deps.server_label(server), "ok", ok and true or false, "status", status or "nil", "context", include_context, "message", message or "")
        end
        callback(ok, status, message)
    end

    local snapshot, read_error = VocabularyAdapter.scan(include_context)
    if not snapshot then
        finish(false, nil, read_error or "Unable to read KOReader Vocabulary Builder")
        return
    end
    if snapshot.missing then
        finish(true, 200, "KOReader Vocabulary Builder database is not present")
        return
    end

    local stored_state = owner.store:getVocabularyState(server.id)
    local previous = stored_state.items or {}
    local context_changed = stored_state.context_included ~= include_context
    local pending = {}
    for record_index, record in ipairs(snapshot.records or {}) do
        if context_changed or previous[record.id] ~= record.record_hash then
            pending[#pending + 1] = record
        end
    end
    local deleted_ids = {}
    for id in pairs(previous) do
        if snapshot.hashes[id] == nil then deleted_ids[#deleted_ids + 1] = id end
    end
    table.sort(deleted_ids)
    for deleted_index, id in ipairs(deleted_ids) do
        local tombstone = VocabularyAdapter.tombstone(id)
        if tombstone then pending[#pending + 1] = tombstone end
    end

    local next_state = {
        items = snapshot.hashes,
        context_included = include_context,
        uploaded_at = os.time(),
    }
    if #pending == 0 then
        if context_changed then owner.store:saveVocabularyState(server.id, next_state) end
        finish(true, 200, "Vocabulary Builder is up to date")
        return
    end

    local registration = owner:getDeviceRegistrationPayload()
    local batch_size = math.max(1, math.min(math.floor(tonumber(capabilities.vocabulary_builder_batch_max) or VocabularyAdapter.DEFAULT_BATCH_SIZE), 500))
    local offset = 1
    local function uploadNext()
        if offset > #pending then
            owner.store:saveVocabularyState(server.id, next_state)
            finish(true, 200, "Vocabulary Builder sync complete")
            return
        end
        local records = {}
        local last = math.min(#pending, offset + batch_size - 1)
        for index = offset, last do records[#records + 1] = pending[index] end
        client:putVocabulary(server.username, server.userkey, {
            legacy_device_id = tostring(owner.store.data.device_id),
            koreader_device_id = registration.koreader_device_id,
            device = tostring(Device.model or "KOReader device"),
            include_context = include_context,
            records = records,
        }, function(ok, status, body)
            if not ok or status ~= 200 then
                finish(false, status, self.deps.server_response_message(body) or body or "Vocabulary Builder upload failed")
                return
            end
            offset = last + 1
            uploadNext()
        end)
    end
    uploadNext()
end

return VocabularySync
