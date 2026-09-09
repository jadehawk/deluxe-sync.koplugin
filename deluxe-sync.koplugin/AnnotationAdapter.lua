local AnnotationAdapter = {}

AnnotationAdapter.ID_FIELD = "deluxe_sync_id"

local function clean(value)
    if value == nil then return nil end
    local text = tostring(value)
    if text == "" then return nil end
    return text
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

local function stableEncode(value, seen)
    local kind = type(value)
    if value == nil then return "nil" end
    if kind == "boolean" or kind == "number" or kind == "string" then
        return kind .. ":" .. tostring(value)
    end
    if kind ~= "table" then return kind .. ":" .. tostring(value) end
    seen = seen or {}
    if seen[value] then return "table:<cycle>" end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do table.insert(keys, key) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = { "table{" }
    for _, key in ipairs(keys) do
        table.insert(parts, stableEncode(key, seen))
        table.insert(parts, "=")
        table.insert(parts, stableEncode(value[key], seen))
        table.insert(parts, ";")
    end
    table.insert(parts, "}")
    seen[value] = nil
    return table.concat(parts)
end

function AnnotationAdapter.kind(annotation)
    if type(annotation) ~= "table" then return "bookmark" end
    if clean(annotation.note) then return "note" end
    if annotation.drawer ~= nil and annotation.drawer ~= false and annotation.drawer ~= "" then
        return "highlight"
    end
    return "bookmark"
end

function AnnotationAdapter.fingerprint(annotation)
    if type(annotation) ~= "table" then return "" end
    return table.concat({
        AnnotationAdapter.kind(annotation),
        clean(annotation.datetime) or "",
        clean(annotation.datetime_updated) or "",
        clean(annotation.text) or "",
        clean(annotation.note) or "",
        clean(annotation.chapter) or "",
        clean(annotation.drawer) or "",
        clean(annotation.color) or "",
        clean(annotation.pageno) or "",
        clean(annotation.pageref) or "",
        stableEncode(annotation.page),
        stableEncode(annotation.pos0),
        stableEncode(annotation.pos1),
    }, "\0")
end

local function defaultIdFactory(_device_id, _annotation, index, nonce)
    return string.format("ds1-%x-%08x-%d-%d", os.time(), math.random(0, 0x7fffffff), index or 0, nonce or 0)
end

function AnnotationAdapter.ensureIds(annotations, device_id, id_factory)
    annotations = type(annotations) == "table" and annotations or {}
    id_factory = id_factory or defaultIdFactory
    local used = {}
    local changed = false
    for _, annotation in ipairs(annotations) do
        if type(annotation) == "table" and clean(annotation[AnnotationAdapter.ID_FIELD]) then
            used[tostring(annotation[AnnotationAdapter.ID_FIELD])] = true
        end
    end
    for index, annotation in ipairs(annotations) do
        if type(annotation) == "table" and not clean(annotation[AnnotationAdapter.ID_FIELD]) then
            local nonce = 0
            local id
            repeat
                id = tostring(id_factory(device_id, annotation, index, nonce))
                nonce = nonce + 1
            until id ~= "" and not used[id]
            annotation[AnnotationAdapter.ID_FIELD] = id
            used[id] = true
            changed = true
        end
    end
    return changed
end

function AnnotationAdapter.toWire(annotation, base_revision)
    if type(annotation) ~= "table" then return nil end
    local id = clean(annotation[AnnotationAdapter.ID_FIELD])
    if not id then return nil end
    return {
        id = id,
        base_revision = tonumber(base_revision) or 0,
        kind = AnnotationAdapter.kind(annotation),
        deleted = false,
        created_datetime = clean(annotation.datetime),
        updated_datetime = clean(annotation.datetime_updated),
        text = clean(annotation.text),
        note = clean(annotation.note),
        chapter = clean(annotation.chapter),
        drawer = clean(annotation.drawer),
        color = clean(annotation.color),
        page = deepCopy(annotation.page),
        pos0 = deepCopy(annotation.pos0),
        pos1 = deepCopy(annotation.pos1),
        pageno = tonumber(annotation.pageno),
        pageref = clean(annotation.pageref),
    }
end

local function findIndex(annotations, id)
    for index, annotation in ipairs(annotations or {}) do
        if type(annotation) == "table" and tostring(annotation[AnnotationAdapter.ID_FIELD] or "") == id then
            return index, annotation
        end
    end
end

function AnnotationAdapter.applyRemote(annotations, remote)
    annotations = type(annotations) == "table" and annotations or {}
    if type(remote) ~= "table" then return false end
    local id = clean(remote.id)
    if not id then return false end
    local index, local_annotation = findIndex(annotations, id)
    if remote.deleted == true then
        if index then
            table.remove(annotations, index)
            return true
        end
        return false
    end

    local annotation = local_annotation or {}
    annotation[AnnotationAdapter.ID_FIELD] = id
    annotation.datetime = remote.created_datetime or annotation.datetime
    annotation.datetime_updated = remote.updated_datetime
    annotation.text = remote.text
    annotation.note = remote.note
    annotation.chapter = remote.chapter
    annotation.drawer = remote.kind == "bookmark" and nil or remote.drawer
    annotation.color = remote.color
    annotation.page = deepCopy(remote.page)
    annotation.pos0 = deepCopy(remote.pos0)
    annotation.pos1 = deepCopy(remote.pos1)
    annotation.pageno = remote.pageno
    annotation.pageref = remote.pageref
    if not local_annotation then table.insert(annotations, annotation) end
    return true
end

function AnnotationAdapter.remember(state, remote, annotations)
    state.items = state.items or {}
    local id = clean(remote and remote.id)
    if not id then return end
    local _, local_annotation = findIndex(annotations or {}, id)
    state.items[id] = {
        revision = tonumber(remote.revision) or 0,
        deleted = remote.deleted == true,
        fingerprint = local_annotation and AnnotationAdapter.fingerprint(local_annotation) or nil,
    }
end

function AnnotationAdapter.collectLocalChanges(annotations, state, device_id, id_factory)
    annotations = type(annotations) == "table" and annotations or {}
    state = type(state) == "table" and state or {}
    state.items = state.items or {}
    local ids_changed = AnnotationAdapter.ensureIds(annotations, device_id, id_factory)
    local local_by_id = {}
    local outbound = {}

    for _, annotation in ipairs(annotations) do
        local id = clean(annotation[AnnotationAdapter.ID_FIELD])
        if id then
            local_by_id[id] = annotation
            local fingerprint = AnnotationAdapter.fingerprint(annotation)
            local known = state.items[id]
            if not known or known.deleted == true or known.fingerprint ~= fingerprint then
                table.insert(outbound, AnnotationAdapter.toWire(annotation, known and known.revision or 0))
            end
        end
    end

    for id, known in pairs(state.items) do
        if not local_by_id[id] and known.deleted ~= true then
            table.insert(outbound, {
                id = id,
                base_revision = tonumber(known.revision) or 0,
                deleted = true,
            })
        end
    end

    return outbound, ids_changed
end

return AnnotationAdapter
