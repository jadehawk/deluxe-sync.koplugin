local Device = require("device")
local UIManager = require("ui/uimanager")
local DiagnosticLog = require("DiagnosticLog")

local SettingsBackupSync = {}
SettingsBackupSync.__index = SettingsBackupSync

function SettingsBackupSync:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function SettingsBackupSync:sync(server, callback)
    local owner = self.owner
    local SettingsBackupAdapter = self.deps.adapter
    local SettingsBackupLifecycle = self.deps.lifecycle
    callback = callback or function() end
    if not server or server.settings_backup_enabled ~= true then
        callback(true, 200, "KOReader settings backup is disabled")
        return
    end
    if not owner.store or not SettingsBackupAdapter or not SettingsBackupLifecycle or not server or server.enabled == false then
        callback(false, nil, "Settings backup sync is unavailable")
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.settings_backup_in_flight[sync_key] then
        callback(true, 200, "Settings backup sync already in progress")
        return
    end
    local client = owner:newClient(server)
    if not owner:serverSupportsSettingsBackups(server) then
        callback(true, 200, "Settings backups are not supported")
        return
    end

    local captured, capture_error = SettingsBackupAdapter.capture()
    if not captured then
        callback(false, nil, capture_error or "Unable to capture KOReader settings")
        return
    end

    local registration = owner:getDeviceRegistrationPayload()
    local stored_state = owner.store:getSettingsBackupState(server.id)
    local unchanged = stored_state.checksum == captured.checksum
        and tostring(stored_state.koreader_version or "") == tostring(registration.koreader_version or "")
    local sync_token = {}

    local function finish(ok, status, message, snapshot, uploaded)
        if uploaded and type(snapshot) == "table" then
            owner.store:saveSettingsBackupState(server.id, {
                checksum = captured.checksum,
                koreader_version = registration.koreader_version,
                snapshot_id = snapshot.snapshot_id,
                uploaded_at = os.time(),
            })
        end
        if owner.settings_backup_in_flight[sync_key] == sync_token then
            owner.settings_backup_in_flight[sync_key] = nil
        end
        if DiagnosticLog then
            DiagnosticLog.log("settings backup sync", self.deps.server_label(server), "ok", ok and true or false, "status", status or "nil", "message", message or "")
        end
        if ok then
            owner:checkSettingsRestoreForServer(server, client)
            owner:checkDeluxeProfileMigrationForServer(server, client)
        end
        callback(ok, status, message)
    end

    owner.settings_backup_in_flight[sync_key] = sync_token
    UIManager:scheduleIn(15, function()
        if owner.settings_backup_in_flight[sync_key] ~= sync_token then return end
        owner.settings_backup_in_flight[sync_key] = nil
        if DiagnosticLog then
            DiagnosticLog.log("settings backup sync watchdog", self.deps.server_label(server), "message", "Cleared stale in-flight state")
        end
    end)

    local payload = {
        legacy_device_id = tostring(owner.store.data.device_id),
        koreader_device_id = registration.koreader_device_id,
        device = tostring(Device.model or "KOReader device"),
        koreader_version = registration.koreader_version,
        schema_version = SettingsBackupAdapter.SCHEMA_VERSION,
        client_redacted_count = captured.redacted_count,
        settings = captured.settings,
    }
    SettingsBackupLifecycle.run({
        unchanged = unchanged,
        stored_state = stored_state,
        checksum = captured.checksum,
        schema_version = SettingsBackupAdapter.SCHEMA_VERSION,
        get = function(snapshot_id, done)
            client:getSettingsBackup(server.username, server.userkey, snapshot_id, function(ok, status, body)
                local data = self.deps.decode(body)
                done(ok, status, data, self.deps.server_response_message(body) or (not ok and "Settings backup presence check failed" or nil))
            end)
        end,
        invalidate = function(snapshot_id)
            if tostring(stored_state.snapshot_id or "") ~= tostring(snapshot_id or "") then return end
            stored_state = {
                checksum = captured.checksum,
                koreader_version = registration.koreader_version,
                snapshot_id = nil,
                uploaded_at = 0,
            }
            owner.store:saveSettingsBackupState(server.id, stored_state)
            if DiagnosticLog then
                DiagnosticLog.log("settings backup snapshot missing", self.deps.server_label(server), "snapshot", tostring(snapshot_id))
            end
        end,
        upload = function(done)
            local upload_client = owner:newClient(server)
            upload_client:putSettingsBackup(server.username, server.userkey, payload, function(ok, status, body)
                local data = self.deps.decode(body)
                done(ok, status, data, self.deps.server_response_message(body) or body or "Settings backup upload failed")
            end)
        end,
        finish = finish,
    })
end

return SettingsBackupSync
