local Device = require("device")
local Event = require("ui/event")
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
        pcall(owner.ui.handleEvent, owner.ui, Event:new("AnnotationsModified"))
    end
end

function AnnotationSync:sync(server, document, callback)
    local owner = self.owner
    local AnnotationAdapter = self.deps.adapter
    callback = callback or function() end
    if not server or server.annotations_enabled ~= true then
        callback(true, 200, "Annotation sharing is disabled")
        return
    end
    if not owner:serverSupportsAnnotations(server) or not document or document == "" then
        callback(false, nil, "Annotation sync is not supported")
        return
    end

    local sync_key = tostring(server.id or server.url or "server") .. "\0" .. tostring(document)
    if owner.annotation_sync_in_flight[sync_key] then
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
