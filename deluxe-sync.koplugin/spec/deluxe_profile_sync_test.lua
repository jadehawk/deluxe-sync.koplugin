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

contains(api, '"put_deluxe_profile"', "Deluxe profile upload API method missing")
contains(api, '"get_deluxe_profile_candidate"', "Deluxe profile candidate API method missing")
contains(api, '"request_deluxe_profile_restore"', "Deluxe profile restore-request API method missing")
contains(api, '"get_current_deluxe_profile_restore"', "pending Deluxe profile restore API method missing")
contains(api, '"complete_deluxe_profile_restore"', "Deluxe profile restore acknowledgement API method missing")
contains(api, '"deluxe_profile"', "settings backup payload must support the protected Deluxe profile bundle")

contains(client, 'function SyncClient:getDeluxeProfileCandidate(username, userkey, legacy_device_id, koreader_device_id, callback)', "candidate SyncClient helper missing")
contains(client, 'function SyncClient:requestDeluxeProfileRestore(username, userkey, profile_id, legacy_device_id, koreader_device_id, callback)', "restore-request SyncClient helper missing")
contains(client, 'function SyncClient:getCurrentDeluxeProfileRestore(username, userkey, legacy_device_id, koreader_device_id, callback)', "pending restore SyncClient helper missing")
contains(client, 'function SyncClient:completeDeluxeProfileRestore(username, userkey, request_id, payload, callback)', "restore acknowledgement SyncClient helper missing")

contains(store, 'deluxe_profiles = nil', "server capability cache must include Deluxe profiles")
contains(store, 'deluxe_profile_restore = nil', "server capability cache must include Deluxe restore")
contains(store, 'deluxe_profile_checksum = nil', "settings backup state must track the protected profile checksum")

contains(adapter, 'function DeluxeProfileAdapter.capture(store)', "Deluxe profile capture helper missing")
contains(adapter, 'function DeluxeProfileAdapter.apply(store, profile)', "Deluxe profile restore helper missing")
contains(adapter, 'server[access_field] = access_by_index[index]', "restored server must receive its original saved authentication")
contains(adapter, 'Deluxe-Sync profile authentication data is incomplete', "incomplete authentication must fail closed")

contains(main, 'DeluxeProfileAdapter = require("DeluxeProfileAdapter")', "Deluxe profile adapter must load with Deluxe-Sync")
contains(main, 'function ProgressSyncDeluxe:serverSupportsDeluxeProfiles(server)', "Deluxe profile capability gate missing")
contains(main, 'function ProgressSyncDeluxe:serverSupportsDeluxeProfileRestore(server)', "Deluxe restore capability gate missing")
contains(main, 'function ProgressSyncDeluxe:cacheDeluxeProfileCapabilities(server, enhanced_capabilities)', "Deluxe capability cache helper missing")
contains(main, 'DeluxeProfileAdapter.capture(self.store)', "complete Deluxe setup must be captured during settings backup")
contains(main, 'payload.deluxe_profile = {', "settings backup must carry the protected Deluxe profile bundle")
contains(main, 'access = deluxe_capture.access', "protected server authentication must accompany the profile upload")
contains(main, 'stored_state.deluxe_profile_checksum == deluxe_capture.checksum', "profile changes must invalidate settings-backup dedupe")
contains(main, 'deluxe_profile_checksum = deluxe_capture and deluxe_capture.checksum', "uploaded profile checksum must be persisted")

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
