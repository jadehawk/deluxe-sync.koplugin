local DiagnosticLog = require("DiagnosticLog")

local DeluxeProfileBackupSync = {}
DeluxeProfileBackupSync.__index = DeluxeProfileBackupSync

function DeluxeProfileBackupSync:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function DeluxeProfileBackupSync:sync(server, callback)
    local owner = self.owner
    local DeluxeProfileAdapter = self.deps.adapter
    callback = callback or function() end
    if not server or server.deluxe_config_backup_enabled ~= true then
        callback(true, 200, "Deluxe-Sync config backup is disabled")
        return
    end
    if not owner.store or not DeluxeProfileAdapter or server.enabled == false then
        callback(false, nil, "Deluxe-Sync config backup is unavailable")
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.deluxe_profile_backup_in_flight[sync_key] then
        callback(true, 200, "Deluxe-Sync config backup already in progress")
        return
    end

    local client = owner:newClient(server)
    if not owner:serverSupportsDeluxeProfiles(server) then
        callback(true, 200, "Deluxe-Sync config backup is not supported")
        return
    end

    local captured, capture_error = DeluxeProfileAdapter.capture(owner.store)
    if not captured then
        callback(false, nil, capture_error or "Unable to capture Deluxe-Sync config")
        return
    end
    local stored_state = owner.store:getDeluxeProfileState(server.id)
    if stored_state.checksum == captured.checksum then
        callback(true, 200, "Deluxe-Sync config backup is up to date")
        return
    end

    local registration = owner:getDeviceRegistrationPayload()
    local payload = {
        legacy_device_id = tostring(owner.store.data.device_id),
        koreader_device_id = registration.koreader_device_id,
        profile = {
            servers = captured.profile.servers,
            settings = captured.profile.settings,
            access = captured.access,
        },
    }
    owner.deluxe_profile_backup_in_flight[sync_key] = true
    client:putDeluxeProfile(server.username, server.userkey, payload, function(ok, status, body)
        owner.deluxe_profile_backup_in_flight[sync_key] = nil
        local success = ok and status == 200
        if success then
            owner.store:saveDeluxeProfileState(server.id, {
                checksum = captured.checksum,
                uploaded_at = os.time(),
                ignored_candidate_profile_id = stored_state.ignored_candidate_profile_id,
            })
        end
        local message = self.deps.server_response_message(body) or body or (success and "Deluxe-Sync config backup uploaded" or "Deluxe-Sync config backup failed")
        if DiagnosticLog then
            DiagnosticLog.log("deluxe profile backup", self.deps.server_label(server), "ok", success, "status", status or "nil", "message", message)
        end
        callback(success, status, message)
    end)
end

return DeluxeProfileBackupSync
