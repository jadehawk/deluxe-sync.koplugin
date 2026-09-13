local SettingsBackupLifecycle = {}

local function snapshotMatches(snapshot, snapshot_id, schema_version)
    return type(snapshot) == "table"
        and tostring(snapshot.snapshot_id or "") == tostring(snapshot_id or "")
        and tonumber(snapshot.schema_version or 0) == tonumber(schema_version or 0)
end

function SettingsBackupLifecycle.run(options)
    assert(type(options) == "table", "settings backup lifecycle options are required")
    assert(type(options.finish) == "function", "settings backup lifecycle finish callback is required")
    assert(type(options.upload) == "function", "settings backup lifecycle upload callback is required")

    local stored_state = type(options.stored_state) == "table" and options.stored_state or {}
    local snapshot_id = stored_state.snapshot_id
    local checksum = options.checksum
    local schema_version = options.schema_version

    local function finish(ok, status, message, snapshot, uploaded)
        options.finish(ok, status, message, snapshot, uploaded == true)
    end

    local function uploadSnapshot()
        options.upload(function(ok, status, data, error_message)
            local snapshot = type(data) == "table" and data.snapshot or nil
            if not ok or status ~= 200 or type(snapshot) ~= "table" then
                finish(false, status, error_message or "Settings backup upload failed")
                return
            end
            finish(
                true,
                status,
                data.created == false and "Settings backup already stored" or "Settings backup uploaded",
                snapshot,
                true
            )
        end)
    end

    if options.unchanged and snapshot_id then
        assert(type(options.get) == "function", "settings backup lifecycle presence callback is required")
        options.get(snapshot_id, function(ok, status, data, error_message)
            local snapshot = type(data) == "table" and data.snapshot or nil
            if ok and status == 200 and snapshotMatches(snapshot, snapshot_id, schema_version) then
                finish(true, 200, "Settings backup is up to date", snapshot, false)
                return
            end

            -- A 404 is authoritative: the remembered server snapshot no longer exists.
            -- A successful 200 with the wrong identity/schema is also stale state. The
            -- server checksum may legitimately differ from the client's canonical checksum.
            if ok and (status == 404 or status == 200) then
                if type(options.invalidate) == "function" then options.invalidate(snapshot_id) end
                uploadSnapshot()
                return
            end

            -- Do not replace a remembered snapshot merely because its presence check had
            -- a transient transport/auth/server failure. Clear the in-flight guard and
            -- let the next lifecycle retry the presence check.
            finish(false, status, error_message or "Settings backup presence check failed")
        end)
        return
    end

    uploadSnapshot()
end

return SettingsBackupLifecycle
