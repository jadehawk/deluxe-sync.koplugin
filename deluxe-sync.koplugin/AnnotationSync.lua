local Device = require("device")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local DiagnosticLog = require("DiagnosticLog")

local AnnotationSync = {}
AnnotationSync.__index = AnnotationSync

function AnnotationSync:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function AnnotationSync:getLocalAnnotations()
    local owner = self.owner
    local annotation_module = owner.ui and owner.ui.annotation
    if annotation_module and type(annotation_module.annotations) == "table" then
        return annotation_module.annotations
    end
    local annotations
    if owner.ui and owner.ui.doc_settings and owner.ui.doc_settings.readSetting then
        annotations = owner.ui.doc_settings:readSetting("annotations")
    end
    if type(annotations) ~= "table" then annotations = {} end
    if annotation_module then annotation_module.annotations = annotations end
    return annotations
end

function AnnotationSync:persistLocalAnnotations(annotations)
    local owner = self.owner
    if type(annotations) ~= "table" then return end
    if owner.ui and owner.ui.annotation then owner.ui.annotation.annotations = annotations end
    if owner.ui and owner.ui.doc_settings and owner.ui.doc_settings.saveSetting then
        owner.ui.doc_settings:saveSetting("annotations", annotations)
        if owner.ui.doc_settings.flush then pcall(owner.ui.doc_settings.flush, owner.ui.doc_settings) end
    end
    if owner.ui and owner.ui.handleEvent then
        local previous = owner.annotation_sync_internal_event
        owner.annotation_sync_internal_event = true
        pcall(owner.ui.handleEvent, owner.ui, Event:new("AnnotationsModified"))
        owner.annotation_sync_internal_event = previous
    end
end

function AnnotationSync:logSkip(server, reason, document)
    if not DiagnosticLog then return end
    local label = self.deps.server_label and self.deps.server_label(server) or tostring(server and (server.name or server.url) or "server")
    DiagnosticLog.log("annotation sync skipped", label, "reason", reason, "document", document or "")
end

function AnnotationSync:onAnnotationsModified()
    local owner = self.owner
    if owner.annotation_sync_internal_event then
        self:logSkip(nil, "internal annotation update", owner:getDocumentDigest())
        return false
    end
    if not owner.store then
        self:logSkip(nil, "store unavailable", owner:getDocumentDigest())
        return false
    end
    if not NetworkMgr:isOnline() then
        self:logSkip(nil, "offline", owner:getDocumentDigest())
        return false
    end

    self.local_change_generation = (tonumber(self.local_change_generation) or 0) + 1
    local generation = self.local_change_generation
    UIManager:scheduleIn(0.75, function()
        if generation ~= self.local_change_generation then return end
        local canonical_document = owner:getDocumentDigest()
        local scheduled = 0
        for index, server in ipairs(owner.store:getEnabledServers()) do
            local document = owner:getServerDocumentDigest(server) or canonical_document
            if server.annotations_enabled ~= true then
                self:logSkip(server, "sharing disabled", document)
            elseif not owner:serverSupportsAnnotations(server) then
                self:logSkip(server, "server capability unavailable", document)
            elseif not document or document == "" then
                self:logSkip(server, "document unavailable", document)
            else
                scheduled = scheduled + 1
                UIManager:scheduleIn((index - 1) * 0.15, function()
                    owner:syncAnnotationsForServer(server, document, function(ok, status, body)
                        if DiagnosticLog then
                            DiagnosticLog.log(
                                "annotation event sync",
                                self.deps.server_label(server),
                                "document", document,
                                "status", status or "nil",
                                "ok", ok and true or false,
                                "message", body or ""
                            )
                        end
                    end)
                end)
            end
        end
        if scheduled == 0 and DiagnosticLog then
            DiagnosticLog.log("annotation event sync", "no eligible servers")
        end
    end)
    return true
end

function AnnotationSync:sync(server, document, callback)
    local owner = self.owner
    local AnnotationAdapter = self.deps.adapter
    callback = callback or function() end
    if not server or server.annotations_enabled ~= true then
        self:logSkip(server, "sharing disabled", document)
        callback(true, 200, "Annotation sharing is disabled")
        return
    end
    if not owner:serverSupportsAnnotations(server) or not document or document == "" then
        self:logSkip(server, not owner:serverSupportsAnnotations(server) and "server capability unavailable" or "document unavailable", document)
        callback(false, nil, "Annotation sync is not supported")
        return
    end

    local sync_key = tostring(server.id or server.url or "server") .. "\0" .. tostring(document)
    if owner.annotation_sync_in_flight[sync_key] then
        self:logSkip(server, "sync already in progress", document)
        callback(false, nil, "Annotation sync is already in progress")
        return
    end
    owner.annotation_sync_in_flight[sync_key] = true

    local annotations = self:getLocalAnnotations()
    local state = owner.store:getAnnotationState(server.id, document)
    local pending, ids_changed = AnnotationAdapter.collectLocalChanges(
        annotations,
        state,
        owner.store.data.device_id
    )
    local pending_by_id = {}
    for pending_index, item in ipairs(pending) do pending_by_id[tostring(item.id)] = true end
    local local_changed = ids_changed
    if ids_changed then self:persistLocalAnnotations(annotations) end

    local client = owner:newClient(server)
    local function saveState()
        owner.store:saveAnnotationState(server.id, document, state)
    end
    local function finish(ok, status, body)
        owner.annotation_sync_in_flight[sync_key] = nil
        saveState()
        if local_changed then self:persistLocalAnnotations(annotations) end
        if DiagnosticLog then
            DiagnosticLog.log(
                "annotation sync",
                self.deps.server_label(server),
                "document", document,
                "status", status or "nil",
                "ok", ok and true or false,
                "local_changes", #pending,
                "cursor", state.cursor or 0
            )
        end
        callback(ok, status, body)
    end
    local function applyServerAnnotation(remote)
        if type(remote) ~= "table" or not remote.id then return end
        if AnnotationAdapter.applyRemote(annotations, remote) then local_changed = true end
        AnnotationAdapter.remember(state, remote, annotations)
    end

    local rebased_unknown = {}
    local function rebaseUnknownAnnotation(status, body)
        if status ~= 422 then return false end
        local message
        if type(body) == "table" then
            message = body.message or body.error
        elseif type(body) == "string" then
            message = body
        end
        if type(message) == "string" then
            message = message:gsub("^%s+", ""):gsub("%s+$", "")
        end
        local sync_id = type(message) == "string"
            and message:match("^Unknown annotation (.-) cannot start at revision %d+$")
            or nil
        if not sync_id or rebased_unknown[sync_id] then return false end

        local found = false
        for _, item in ipairs(pending) do
            if tostring(item.id or "") == sync_id then
                item.base_revision = 0
                found = true
            end
        end
        if not found then return false end

        rebased_unknown[sync_id] = true
        state.items[sync_id] = nil
        saveState()
        if DiagnosticLog then
            DiagnosticLog.log(
                "annotation sync rebase",
                self.deps.server_label(server),
                "document", document,
                "annotation", sync_id,
                "reason", "server no longer knows saved revision"
            )
        end
        return true
    end

    local sendPending
    sendPending = function(offset)
        offset = offset or 1
        if offset > #pending then
            finish(true, 200, nil)
            return
        end
        local batch = {}
        for index = offset, math.min(#pending, offset + 199) do
            table.insert(batch, pending[index])
        end
        client:putAnnotations(server.username, server.userkey, {
            document = document,
            legacy_device_id = tostring(owner.store.data.device_id),
            device = tostring(Device.model or "KOReader device"),
            annotations = batch,
        }, function(ok, status, body)
            local data = self.deps.decode(body) or {}
            if not ok or status ~= 200 or type(data.results) ~= "table" then
                if rebaseUnknownAnnotation(status, body) then
                    sendPending(offset)
                    return
                end
                finish(false, status, body)
                return
            end
            for result_index, result in ipairs(data.results) do
                if type(result) == "table" and type(result.annotation) == "table" then
                    applyServerAnnotation(result.annotation)
                end
            end
            saveState()
            sendPending(offset + #batch)
        end)
    end

    local pullDeltas
    pullDeltas = function(after)
        client:getAnnotations(server.username, server.userkey, document, after, 200, function(ok, status, body)
            local data = self.deps.decode(body) or {}
            if not ok or status ~= 200 or type(data.changes) ~= "table" then
                finish(false, status, body)
                return
            end
            for change_index, change in ipairs(data.changes) do
                local remote = type(change) == "table" and change.annotation or nil
                if type(remote) == "table" and remote.id and not pending_by_id[tostring(remote.id)] then
                    applyServerAnnotation(remote)
                end
            end
            local next_cursor = tonumber(data.cursor)
            if next_cursor and next_cursor >= (tonumber(state.cursor) or 0) then state.cursor = next_cursor end
            saveState()
            if data.has_more == true then
                pullDeltas(state.cursor)
            else
                sendPending(1)
            end
        end)
    end

    pullDeltas(tonumber(state.cursor) or 0)
end

return AnnotationSync
