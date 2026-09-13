local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template

local SettingsBackupAdapter = require("SettingsBackupAdapter")
local DeluxeProfileAdapter = require("DeluxeProfileAdapter")

local RestoreMigrationController = {}
RestoreMigrationController.__index = RestoreMigrationController

function RestoreMigrationController:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function RestoreMigrationController:completeSettingsRestoreRequest(server, client, registration, request_id, status, message, callback)
    local owner = self.owner
    local server_response_message = self.deps.server_response_message
    callback = callback or function() end
    client:completeSettingsRestore(server.username, server.userkey, request_id, {
        legacy_device_id = tostring(owner.store.data.device_id),
        koreader_device_id = registration.koreader_device_id,
        status = status,
        message = message,
    }, function(ok, response_status, body)
        local success = ok and response_status == 200
        callback(success, response_status, success and nil or (server_response_message(body) or body or "Restore acknowledgement failed"))
    end)
end

function RestoreMigrationController:showSettingsRestorePrompt(server, restore, client, registration)
    local owner = self.owner
    local server_label = self.deps.server_label
    local decode = self.deps.decode
    local suppress_dialog_holds = self.deps.suppress_dialog_holds
    local request_id = tonumber(type(restore) == "table" and restore.request_id or nil)
    local snapshot = type(restore) == "table" and restore.snapshot or nil
    if not request_id or type(snapshot) ~= "table" or type(snapshot.settings) ~= "table" then return false end

    local prompt_key = tostring(server.id or server.url or "server") .. ":" .. tostring(request_id)
    if owner.settings_restore_seen[prompt_key] then return false end
    owner.settings_restore_seen[prompt_key] = true

    local created_at = tonumber(snapshot.created_at) or 0
    local created_label = created_at > 0 and os.date("%Y-%m-%d %H:%M", created_at) or _("Unknown date")
    local koreader_version = snapshot.koreader_version and tostring(snapshot.koreader_version) or _("Unknown")
    local setting_count = math.max(0, math.floor(tonumber(snapshot.setting_count) or 0))
    local dialog

    local function showResult(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
    end

    local function acknowledge(status, message, result_message)
        self:completeSettingsRestoreRequest(server, client, registration, request_id, status, message, function(ok, response_status, error_message)
            if ok then
                showResult(result_message)
            else
                showResult(T(_("Settings changed locally, but the server acknowledgement failed (%1). %2"), tostring(response_status or "network"), tostring(error_message or "Please try again later.")))
            end
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Restore KOReader settings backup?"),
        title_align = "left",
        buttons = {
            {{
                text = T(_("%1\nBackup: %2\nKOReader: %3\nSafe settings: %4"), server_label(server), created_label, koreader_version, tostring(setting_count)),
                enabled = false,
            }},
            {
                { text = _("Later"), callback = function() UIManager:close(dialog) end },
                { text = _("Restore"), callback = function()
                    UIManager:close(dialog)
                    client:getCurrentSettingsRestore(server.username, server.userkey, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
                        local data = decode(body)
                        local current = type(data) == "table" and data.restore or nil
                        local current_snapshot = type(current) == "table" and current.snapshot or nil
                        if not ok or status ~= 200 then
                            showResult(_("Unable to verify that this restore request is still pending. No settings were changed."))
                            return
                        end
                        if type(current) ~= "table"
                            or tonumber(current.request_id) ~= request_id
                            or type(current_snapshot) ~= "table"
                            or tostring(current_snapshot.snapshot_id or "") ~= tostring(snapshot.snapshot_id or "") then
                            showResult(_("This restore request is no longer pending. No settings were changed."))
                            return
                        end
                        local applied, result = SettingsBackupAdapter.apply(current_snapshot.settings)
                        if not applied then
                            acknowledge("failed", tostring(result or "Unable to apply settings"), _("The settings backup could not be applied."))
                            return
                        end
                        owner.store:saveSettingsBackupState(server.id, {
                            checksum = current_snapshot.checksum or result.checksum,
                            koreader_version = current_snapshot.koreader_version or registration.koreader_version,
                            snapshot_id = current_snapshot.snapshot_id,
                            uploaded_at = os.time(),
                        })
                        acknowledge("applied", "Confirmed and applied on reader", _("Settings restored. Restart KOReader to ensure every restored setting takes effect."))
                    end)
                end },
            },
            {{ text = _("Reject Restore Request"), callback = function()
                UIManager:close(dialog)
                acknowledge("rejected", "Rejected on reader", _("Settings restore request rejected. No settings were changed."))
            end }},
        },
    }
    suppress_dialog_holds(dialog)
    UIManager:show(dialog)
    return true
end

function RestoreMigrationController:checkSettingsRestoreForServer(server, client, callback)
    local owner = self.owner
    local decode = self.deps.decode
    local server_response_message = self.deps.server_response_message
    callback = callback or function() end
    if not owner.store or not SettingsBackupAdapter or not server or server.enabled == false then
        callback(false, nil, "Settings restore check is unavailable")
        return
    end
    client = client or owner:newClient(server)
    if not owner:serverSupportsSettingsRestore(server) then
        callback(true, 200, "Settings restore is not supported")
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.settings_restore_in_flight[sync_key] then
        callback(true, 200, "Settings restore check already in progress")
        return
    end
    owner.settings_restore_in_flight[sync_key] = true
    local registration = owner:getDeviceRegistrationPayload()
    client:getCurrentSettingsRestore(server.username, server.userkey, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
        owner.settings_restore_in_flight[sync_key] = nil
        local data = decode(body)
        if not ok or status ~= 200 or type(data) ~= "table" then
            callback(false, status, server_response_message(body) or body or "Settings restore check failed")
            return
        end
        if type(data.restore) ~= "table" then
            callback(true, status, "No pending settings restore")
            return
        end
        self:showSettingsRestorePrompt(server, data.restore, client, registration)
        callback(true, status, "Settings restore confirmation shown")
    end)
end

function RestoreMigrationController:completeDeluxeProfileRestoreRequest(server, client, registration, request_id, status, message, callback)
    local owner = self.owner
    local server_response_message = self.deps.server_response_message
    callback = callback or function() end
    client:completeDeluxeProfileRestore(server.username, server.userkey, request_id, {
        legacy_device_id = tostring(owner.store.data.device_id),
        koreader_device_id = registration.koreader_device_id,
        status = status,
        message = message,
    }, function(ok, response_status, body)
        local success = ok and response_status == 200
        callback(success, response_status, success and nil or (server_response_message(body) or body or "Deluxe-Sync profile restore acknowledgement failed"))
    end)
end

function RestoreMigrationController:showDeluxeProfileRestorePrompt(server, restore, client, registration)
    local owner = self.owner
    local decode = self.deps.decode
    local suppress_dialog_holds = self.deps.suppress_dialog_holds
    local request_id = tonumber(type(restore) == "table" and restore.request_id or nil)
    local profile = type(restore) == "table" and restore.profile or nil
    local portable = type(profile) == "table" and profile.profile or nil
    local access = type(restore) == "table" and restore.access or nil
    local profile_id = type(profile) == "table" and tostring(profile.profile_id or "") or ""
    if not request_id or profile_id == "" or type(portable) ~= "table" or type(portable.servers) ~= "table" or type(access) ~= "table" then return false end

    local prompt_key = tostring(server.id or server.url or "server") .. ":" .. tostring(request_id)
    if owner.deluxe_profile_restore_seen[prompt_key] then return false end
    owner.deluxe_profile_restore_seen[prompt_key] = true

    local created_at = tonumber(profile.created_at) or 0
    local created_label = created_at > 0 and os.date("%Y-%m-%d %H:%M", created_at) or _("Unknown date")
    local source_name = tostring(profile.source_device_name or _("Another reader"))
    local server_count = math.max(0, math.floor(tonumber(profile.server_count) or #portable.servers))
    local dialog

    local function showResult(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
    end

    local function acknowledge(status, message, result_message)
        self:completeDeluxeProfileRestoreRequest(server, client, registration, request_id, status, message, function(ok, response_status, error_message)
            if ok then
                showResult(result_message)
            else
                showResult(T(_("Deluxe-Sync changed locally, but the server acknowledgement failed (%1). %2"), tostring(response_status or "network"), tostring(error_message or "Please try again later.")))
            end
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Restore Deluxe-Sync server setup?"),
        title_align = "left",
        buttons = {
            {{
                text = T(_("From: %1\nBackup: %2\nConfigured servers: %3\n\nThis restores the same server URLs, usernames, and saved authentication so existing synced progress stays attached to the same accounts. No new accounts are created."), source_name, created_label, tostring(server_count)),
                enabled = false,
            }},
            {
                { text = _("Later"), callback = function() UIManager:close(dialog) end },
                { text = _("Restore"), callback = function()
                    UIManager:close(dialog)
                    client:getCurrentDeluxeProfileRestore(server.username, server.userkey, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
                        local data = decode(body)
                        local current = type(data) == "table" and data.restore or nil
                        local current_profile = type(current) == "table" and current.profile or nil
                        local current_portable = type(current_profile) == "table" and current_profile.profile or nil
                        local current_access = type(current) == "table" and current.access or nil
                        if not ok or status ~= 200 then
                            showResult(_("Unable to verify that this Deluxe-Sync restore request is still pending. No server setup was changed."))
                            return
                        end
                        if type(current) ~= "table"
                            or tonumber(current.request_id) ~= request_id
                            or type(current_profile) ~= "table"
                            or tostring(current_profile.profile_id or "") ~= profile_id
                            or type(current_portable) ~= "table"
                            or type(current_portable.servers) ~= "table"
                            or type(current_access) ~= "table" then
                            showResult(_("This Deluxe-Sync restore request is no longer pending. No server setup was changed."))
                            return
                        end
                        local applied, result = DeluxeProfileAdapter.apply(owner.store, {
                            servers = current_portable.servers,
                            settings = current_portable.settings,
                            access = current_access,
                        })
                        if not applied then
                            acknowledge("failed", tostring(result or "Unable to apply Deluxe-Sync profile"), _("The Deluxe-Sync server setup could not be restored."))
                            return
                        end
                        acknowledge("applied", "Confirmed and applied on reader", T(_("Deluxe-Sync restored %1 configured server account(s). Restart KOReader to complete the migration."), tostring(result.server_count or server_count)))
                        UIManager:scheduleIn(0.5, function() owner:showDataSharingReview() end)
                        UIManager:scheduleIn(1, function() owner:refreshEnhancedCapabilitiesForAll() end)
                    end)
                end },
            },
            {{ text = _("Reject Restore Request"), callback = function()
                UIManager:close(dialog)
                acknowledge("rejected", "Rejected on reader", _("Deluxe-Sync restore request rejected. No server setup was changed."))
            end }},
        },
    }
    suppress_dialog_holds(dialog)
    UIManager:show(dialog)
    return true
end

function RestoreMigrationController:checkDeluxeProfileRestoreForServer(server, client, callback)
    local owner = self.owner
    local decode = self.deps.decode
    local server_response_message = self.deps.server_response_message
    callback = callback or function() end
    if not owner.store or not DeluxeProfileAdapter or not server or server.enabled == false then
        callback(false, nil, "Deluxe-Sync profile restore check is unavailable", false)
        return
    end
    client = client or owner:newClient(server)
    if not owner:serverSupportsDeluxeProfileRestore(server) then
        callback(true, 200, "Deluxe-Sync profile restore is not supported", false)
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.deluxe_profile_restore_in_flight[sync_key] then
        callback(true, 200, "Deluxe-Sync profile restore check already in progress", true)
        return
    end
    owner.deluxe_profile_restore_in_flight[sync_key] = true
    local registration = owner:getDeviceRegistrationPayload()
    client:getCurrentDeluxeProfileRestore(server.username, server.userkey, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
        owner.deluxe_profile_restore_in_flight[sync_key] = nil
        local data = decode(body)
        if not ok or status ~= 200 or type(data) ~= "table" then
            callback(false, status, server_response_message(body) or body or "Deluxe-Sync profile restore check failed", false)
            return
        end
        if type(data.restore) ~= "table" then
            callback(true, status, "No pending Deluxe-Sync profile restore", false)
            return
        end
        self:showDeluxeProfileRestorePrompt(server, data.restore, client, registration)
        callback(true, status, "Deluxe-Sync profile restore confirmation shown", true)
    end)
end

function RestoreMigrationController:applyCurrentDeluxeProfileRestore(server, client, registration, expected_profile_id, callback)
    local owner = self.owner
    local decode = self.deps.decode
    callback = callback or function() end
    client:getCurrentDeluxeProfileRestore(server.username, server.userkey, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
        local data = decode(body)
        local current = type(data) == "table" and data.restore or nil
        local current_profile = type(current) == "table" and current.profile or nil
        local current_portable = type(current_profile) == "table" and current_profile.profile or nil
        local current_access = type(current) == "table" and current.access or nil
        local request_id = tonumber(type(current) == "table" and current.request_id or nil)
        local profile_id = type(current_profile) == "table" and tostring(current_profile.profile_id or "") or ""
        if not ok or status ~= 200 then
            callback(false, status, _("Unable to verify the Deluxe-Sync restore. No server setup was changed."))
            return
        end
        if not request_id
            or profile_id == ""
            or (expected_profile_id and expected_profile_id ~= "" and profile_id ~= tostring(expected_profile_id))
            or type(current_portable) ~= "table"
            or type(current_portable.servers) ~= "table"
            or type(current_access) ~= "table" then
            callback(false, status, _("The Deluxe-Sync restore is no longer available. No server setup was changed."))
            return
        end

        local applied, result = DeluxeProfileAdapter.apply(owner.store, {
            servers = current_portable.servers,
            settings = current_portable.settings,
            access = current_access,
        })
        if not applied then
            self:completeDeluxeProfileRestoreRequest(server, client, registration, request_id, "failed", tostring(result or "Unable to apply Deluxe-Sync profile"), function() end)
            callback(false, status, _("The Deluxe-Sync server setup could not be restored."))
            return
        end

        UIManager:scheduleIn(0.5, function() owner:showDataSharingReview() end)
        UIManager:scheduleIn(1, function() owner:refreshEnhancedCapabilitiesForAll() end)
        self:completeDeluxeProfileRestoreRequest(server, client, registration, request_id, "applied", "Confirmed and applied on reader", function(ack_ok, response_status, error_message)
            if not ack_ok then
                callback(false, response_status, T(_("Deluxe-Sync restored locally, but the server acknowledgement failed (%1). %2"), tostring(response_status or "network"), tostring(error_message or "Please try again later.")))
                return
            end
            callback(true, response_status or 200, T(_("Deluxe-Sync restored %1 configured server account(s). Restart KOReader to complete the migration."), tostring(result.server_count or #current_portable.servers)))
        end)
    end)
end

function RestoreMigrationController:showDeluxeProfileCandidatePrompt(server, candidate, client, registration)
    local owner = self.owner
    local server_response_message = self.deps.server_response_message
    local suppress_dialog_holds = self.deps.suppress_dialog_holds
    local profile_id = type(candidate) == "table" and tostring(candidate.profile_id or "") or ""
    local portable = type(candidate) == "table" and candidate.profile or nil
    if profile_id == "" or type(portable) ~= "table" or type(portable.servers) ~= "table" then return false end

    local prompt_key = tostring(server.id or server.url or "server") .. ":" .. profile_id
    if owner.deluxe_profile_candidate_seen[prompt_key] then return false end
    owner.deluxe_profile_candidate_seen[prompt_key] = true

    local created_at = tonumber(candidate.created_at) or 0
    local created_label = created_at > 0 and os.date("%Y-%m-%d %H:%M", created_at) or _("Unknown date")
    local source_name = tostring(candidate.source_device_name or _("Another reader"))
    local server_count = math.max(0, math.floor(tonumber(candidate.server_count) or #portable.servers))
    local dialog

    local function showResult(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
    end

    dialog = ButtonDialog:new{
        title = _("Deluxe-Sync backup found on another reader"),
        title_align = "left",
        buttons = {
            {{
                text = T(_("Source: %1\nBackup: %2\nConfigured servers: %3\n\nA saved Deluxe-Sync setup is available from another reader. Nothing will change unless you choose Restore."), source_name, created_label, tostring(server_count)),
                enabled = false,
            }},
            {
                { text = _("Cancel"), callback = function()
                    UIManager:close(dialog)
                    local state = owner.store:getDeluxeProfileState(server.id)
                    state.ignored_candidate_profile_id = profile_id
                    owner.store:saveDeluxeProfileState(server.id, state)
                end },
                { text = _("Restore"), callback = function()
                    UIManager:close(dialog)
                    client:requestDeluxeProfileRestore(server.username, server.userkey, profile_id, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
                        if not ok or status ~= 202 then
                            showResult(T(_("Unable to start Deluxe-Sync restore (%1). %2"), tostring(status or "network"), tostring(server_response_message(body) or body or "Please try again.")))
                            return
                        end
                        self:applyCurrentDeluxeProfileRestore(server, client, registration, profile_id, function(applied, _, message)
                            showResult(tostring(message or (applied and _("Deluxe-Sync setup restored.") or _("Unable to restore Deluxe-Sync setup."))))
                        end)
                    end)
                end },
            },
        },
    }
    suppress_dialog_holds(dialog)
    UIManager:show(dialog)
    return true
end

function RestoreMigrationController:checkDeluxeProfileCandidateForServer(server, client, callback)
    local owner = self.owner
    local decode = self.deps.decode
    local server_response_message = self.deps.server_response_message
    callback = callback or function() end
    if not owner.store or not DeluxeProfileAdapter or not server or server.enabled == false then
        callback(false, nil, "Deluxe-Sync profile candidate check is unavailable")
        return
    end
    client = client or owner:newClient(server)
    if not owner:serverSupportsDeluxeProfileRestore(server) then
        callback(true, 200, "Deluxe-Sync profile migration is not supported")
        return
    end

    local sync_key = tostring(server.id or server.url or "server")
    if owner.deluxe_profile_in_flight[sync_key] then
        callback(true, 200, "Deluxe-Sync profile candidate check already in progress")
        return
    end
    owner.deluxe_profile_in_flight[sync_key] = true
    local registration = owner:getDeviceRegistrationPayload()
    client:getDeluxeProfileCandidate(server.username, server.userkey, tostring(owner.store.data.device_id), registration.koreader_device_id, function(ok, status, body)
        owner.deluxe_profile_in_flight[sync_key] = nil
        local data = decode(body)
        if not ok or status ~= 200 or type(data) ~= "table" then
            callback(false, status, server_response_message(body) or body or "Deluxe-Sync profile candidate check failed")
            return
        end
        if type(data.profile) ~= "table" then
            callback(true, status, "No Deluxe-Sync profile migration candidate")
            return
        end
        local candidate_profile_id = tostring(data.profile.profile_id or "")
        local profile_state = owner.store:getDeluxeProfileState(server.id)
        if candidate_profile_id ~= "" and tostring(profile_state.ignored_candidate_profile_id or "") == candidate_profile_id then
            callback(true, status, "Deluxe-Sync profile migration candidate was declined on this reader")
            return
        end
        self:showDeluxeProfileCandidatePrompt(server, data.profile, client, registration)
        callback(true, status, "Deluxe-Sync profile migration candidate shown")
    end)
end

function RestoreMigrationController:checkDeluxeProfileMigrationForServer(server, client)
    local owner = self.owner
    client = client or owner:newClient(server)
    self:checkDeluxeProfileRestoreForServer(server, client, function(ok, _, _, pending)
        if ok and not pending then self:checkDeluxeProfileCandidateForServer(server, client) end
    end)
end

return RestoreMigrationController
