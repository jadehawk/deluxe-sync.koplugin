local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local main = readFile("main.lua")
local store = readFile("ServerStore.lua")
local client = readFile("SyncClient.lua")
local api = readFile("api.json")
local adapter = readFile("DeluxeProfileAdapter.lua")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing Deluxe profile integration: " .. text))
end

local function excludes(source, text, message)
    assert(not source:find(text, 1, true), message or ("unexpected Deluxe profile integration: " .. text))
end

contains(api, '"put_deluxe_profile"', "Deluxe profile upload API method missing")
contains(api, '"get_deluxe_profile_candidate"', "Deluxe profile candidate API method missing")
contains(api, '"request_deluxe_profile_restore"', "Deluxe profile restore-request API method missing")
contains(api, '"get_current_deluxe_profile_restore"', "pending Deluxe profile restore API method missing")
contains(api, '"complete_deluxe_profile_restore"', "Deluxe profile restore acknowledgement API method missing")

contains(client, 'function SyncClient:putDeluxeProfile(username, userkey, payload, callback)', "protected-profile upload SyncClient helper missing")
contains(client, 'function SyncClient:getDeluxeProfileCandidate(username, userkey, legacy_device_id, koreader_device_id, callback)', "candidate SyncClient helper missing")
contains(client, 'function SyncClient:requestDeluxeProfileRestore(username, userkey, profile_id, legacy_device_id, koreader_device_id, callback)', "restore-request SyncClient helper missing")
contains(client, 'function SyncClient:getCurrentDeluxeProfileRestore(username, userkey, legacy_device_id, koreader_device_id, callback)', "pending restore SyncClient helper missing")
contains(client, 'function SyncClient:completeDeluxeProfileRestore(username, userkey, request_id, payload, callback)', "restore acknowledgement SyncClient helper missing")

contains(store, 'deluxe_profiles = nil', "server capability cache must include Deluxe profiles")
contains(store, 'deluxe_profile_restore = nil', "server capability cache must include Deluxe restore")
contains(store, 'deluxe_profile_sync = {}', "protected-profile backup must have independent sync state")
contains(store, 'function ServerStore:getDeluxeProfileState(server_id)', "protected-profile state reader missing")
contains(store, 'function ServerStore:saveDeluxeProfileState(server_id, state)', "protected-profile state writer missing")

contains(adapter, 'function DeluxeProfileAdapter.capture(store)', "Deluxe profile capture helper missing")
contains(adapter, 'function DeluxeProfileAdapter.apply(store, profile)', "Deluxe profile restore helper missing")
contains(adapter, 'server[access_field] = access_by_index[index]', "restored server must receive its original saved authentication")
contains(adapter, 'Deluxe-Sync profile authentication data is incomplete', "incomplete authentication must fail closed")
contains(adapter, 'server.data_sharing_version = existing and', "profile restore must preserve only local consent state")
contains(adapter, 'server.deluxe_config_backup_enabled = existing and existing.deluxe_config_backup_enabled == true or false', "newly restored servers must not inherit remote config-backup consent")

contains(main, 'DeluxeProfileAdapter = require("DeluxeProfileAdapter")', "Deluxe profile adapter must load with Deluxe-Sync")
contains(main, 'function ProgressSyncDeluxe:serverSupportsDeluxeProfiles(server)', "Deluxe profile capability gate missing")
contains(main, 'function ProgressSyncDeluxe:serverSupportsDeluxeProfileRestore(server)', "Deluxe restore capability gate missing")
contains(main, 'function ProgressSyncDeluxe:cacheDeluxeProfileCapabilities(server, enhanced_capabilities)', "Deluxe capability cache helper missing")
contains(main, 'function ProgressSyncDeluxe:syncDeluxeProfileBackupForServer(server, callback)', "independent Deluxe-Sync config backup loop missing")
contains(main, 'steps[#steps + 1] = function(done) self:syncDeluxeProfileBackupForServer(server, done) end', "coordinator must include consented Deluxe-Sync config backup")
contains(main, 'server.deluxe_config_backup_enabled ~= true', "config backup must require explicit per-server consent")
contains(main, 'local captured, capture_error = DeluxeProfileAdapter.capture(self.store)', "consented config backup must capture the complete Deluxe setup")
contains(main, 'client:putDeluxeProfile(server.username, server.userkey, payload', "protected config backup must use the dedicated Deluxe profile endpoint")
contains(main, 'access = captured.access', "protected server authentication must accompany only the dedicated profile upload")
contains(main, 'self.store:getDeluxeProfileState(server.id)', "config backup dedupe must use independent state")
contains(main, 'self.store:saveDeluxeProfileState(server.id, {', "uploaded profile checksum must be persisted independently")
excludes(main, 'payload.deluxe_profile = {', "KOReader settings snapshots must never piggyback Deluxe-Sync credentials")
excludes(main, 'stored_state.deluxe_profile_checksum ==', "KOReader settings dedupe must not depend on protected-profile changes")

contains(main, 'function ProgressSyncDeluxe:checkDeluxeProfileCandidateForServer(server, client, callback)', "cross-device candidate discovery missing")
contains(main, 'client:getDeluxeProfileCandidate(server.username, server.userkey', "candidate discovery must use authenticated transport")
contains(main, 'function ProgressSyncDeluxe:showDeluxeProfileCandidatePrompt(server, candidate, client, registration)', "candidate confirmation dialog missing")
contains(main, 'text = _("Prepare Restore")', "candidate migration must require explicit preparation")
contains(main, 'client:requestDeluxeProfileRestore(server.username, server.userkey', "reader must target the selected profile to itself")
contains(main, 'including the saved authentication for each existing server account', "candidate prompt must explain full account restoration")

contains(main, 'function ProgressSyncDeluxe:checkDeluxeProfileRestoreForServer(server, client, callback)', "pending Deluxe restore polling missing")
contains(main, 'client:getCurrentDeluxeProfileRestore(server.username, server.userkey', "pending Deluxe restore must use authenticated transport")
contains(main, 'function ProgressSyncDeluxe:showDeluxeProfileRestorePrompt(server, restore, client, registration)', "Deluxe restore confirmation dialog missing")
contains(main, 'text = _("Restore Setup")', "Deluxe restore must require explicit reader confirmation")
contains(main, 'No new accounts are created.', "restore prompt must explain account identity preservation")
contains(main, 'DeluxeProfileAdapter.apply(self.store, {', "confirmed pending profile must be applied through the safe adapter")
contains(main, 'client:completeDeluxeProfileRestore(server.username, server.userkey', "reader restore decision must be acknowledged")
contains(main, 'This Deluxe-Sync restore request is no longer pending. No server setup was changed.', "stale restore prompt must fail closed")
contains(main, 'UIManager:scheduleIn(0.5, function() self:showDataSharingReview() end)', "restored servers must enter local data-sharing review")

contains(main, 'deluxe_profiles = true', "device registration must advertise Deluxe profile support")
contains(main, 'deluxe_profile_restore = true', "device registration must advertise Deluxe profile restore support")
contains(main, 'self:checkDeluxeProfileMigrationForServer(server, client)', "normal Stage 9 lifecycle must check profile restore/candidates")
contains(main, 'function ProgressSyncDeluxe:refreshEnhancedCapabilitiesForAll()', "network capability refresh must remain the migration trigger")

local candidate_prompt = assert(main:find('text = _("Prepare Restore")', 1, true))
local request_restore = assert(main:find('client:requestDeluxeProfileRestore(server.username, server.userkey', candidate_prompt, true))
assert(request_restore > candidate_prompt, "restore request must only be created after explicit candidate confirmation")

local restore_prompt = assert(main:find('text = _("Restore Setup")', 1, true))
local revalidate = assert(main:find('client:getCurrentDeluxeProfileRestore(server.username, server.userkey', restore_prompt, true))
local apply_profile = assert(main:find('DeluxeProfileAdapter.apply(self.store, {', revalidate, true))
assert(revalidate > restore_prompt, "pending Deluxe profile must be revalidated after explicit restore confirmation")
assert(apply_profile > revalidate, "Deluxe profile must not be applied before pending-request revalidation")

print("deluxe_profile_sync_test.lua: OK")
