local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local json = require("json")

local DeluxeProfileAdapter = require("DeluxeProfileAdapter")
local SettingsBackupAdapter = require("SettingsBackupAdapter")
local VocabularyAdapter = require("VocabularyAdapter")

local EnhancedDataSyncController = {}
EnhancedDataSyncController.__index = EnhancedDataSyncController

local function decode(body)
    if type(body) == "table" then return body end
    if not body or body == "" then return nil end
    local ok, parsed = pcall(json.decode, body)
    if ok then return parsed end
end

function EnhancedDataSyncController:new(owner, coordinator)
    return setmetatable({
        owner = owner,
        coordinator = coordinator,
    }, self)
end

function EnhancedDataSyncController:serverSupportsAnnotations(server)
    local capabilities = server and server.capabilities or {}
    return capabilities.annotations == true
        and (tonumber(capabilities.annotations_version) or 0) >= 1
end

function EnhancedDataSyncController:serverSupportsReadingStatistics(server)
    local capabilities = server and server.capabilities or {}
    local direction = capabilities.reading_statistics_direction
    return capabilities.reading_statistics == true
        and capabilities.reading_statistics_events == true
        and (tonumber(capabilities.reading_statistics_version) or 0) >= 1
        and (direction == nil or direction == "client_to_server")
end

function EnhancedDataSyncController:cacheReadingStatisticsCapabilities(server, enhanced_capabilities)
    local owner = self.owner
    local version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.reading_statistics_version) or nil
    local events_supported = type(enhanced_capabilities) == "table" and enhanced_capabilities.reading_statistics_events == true
    local direction = type(enhanced_capabilities) == "table" and enhanced_capabilities.reading_statistics_direction or nil
    local supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.reading_statistics == true
        and events_supported
        and (version or 0) >= 1
        and (direction == nil or direction == "client_to_server")
    owner.store:setCapability(server.id, "reading_statistics", supported)
    owner.store:setCapability(server.id, "reading_statistics_version", version)
    owner.store:setCapability(server.id, "reading_statistics_events", events_supported)
    owner.store:setCapability(server.id, "reading_statistics_direction", direction)
    return supported
end

function EnhancedDataSyncController:refreshReadingStatisticsCapabilities(server, client)
    local owner = self.owner
    client = client or owner:newClient(server)
    local ok, status, body = client:capabilities()
    local data = decode(body)
    if ok and (status == 404 or status == 405) then
        return self:cacheReadingStatisticsCapabilities(server, nil)
    end
    if not ok or status ~= 200 or type(data) ~= "table" or type(data.capabilities) ~= "table" then
        return false
    end
    return self:cacheReadingStatisticsCapabilities(server, data.capabilities)
end

function EnhancedDataSyncController:serverSupportsVocabulary(server)
    local capabilities = server and server.capabilities or {}
    local direction = capabilities.vocabulary_direction
    return VocabularyAdapter ~= nil
        and capabilities.vocabulary_builder == true
        and (tonumber(capabilities.vocabulary_builder_version) or 0) >= 1
        and (direction == nil or direction == "client_to_server")
end

function EnhancedDataSyncController:cacheVocabularyCapabilities(server, enhanced_capabilities)
    local owner = self.owner
    local version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.vocabulary_builder_version) or nil
    local batch_max = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.vocabulary_builder_batch_max) or nil
    local direction = type(enhanced_capabilities) == "table" and enhanced_capabilities.vocabulary_direction or nil
    local context_supported = type(enhanced_capabilities) == "table" and enhanced_capabilities.vocabulary_context == true
    local supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.vocabulary_builder == true
        and (version or 0) >= 1
        and (direction == nil or direction == "client_to_server")
    owner.store:setCapability(server.id, "vocabulary_builder", supported)
    owner.store:setCapability(server.id, "vocabulary_builder_version", version)
    owner.store:setCapability(server.id, "vocabulary_builder_batch_max", batch_max)
    owner.store:setCapability(server.id, "vocabulary_context", context_supported)
    owner.store:setCapability(server.id, "vocabulary_direction", direction)
    return supported
end

function EnhancedDataSyncController:serverSupportsSettingsBackups(server)
    local capabilities = server and server.capabilities or {}
    return capabilities.settings_backups == true
        and (tonumber(capabilities.settings_backups_version) or 0) >= 1
        and (tonumber(capabilities.settings_snapshot_schema_version) or 0) >= SettingsBackupAdapter.SCHEMA_VERSION
end

function EnhancedDataSyncController:serverSupportsSettingsRestore(server)
    local capabilities = server and server.capabilities or {}
    local direction = capabilities.settings_restore_direction
    return self:serverSupportsSettingsBackups(server)
        and capabilities.settings_restore == true
        and (direction == nil or direction == "server_request_client_confirm")
end

function EnhancedDataSyncController:serverSupportsDeluxeProfiles(server)
    local capabilities = server and server.capabilities or {}
    return DeluxeProfileAdapter ~= nil
        and capabilities.deluxe_profiles == true
        and (tonumber(capabilities.deluxe_profiles_version) or 0) >= 1
        and (tonumber(capabilities.deluxe_profile_schema_version) or 0) >= DeluxeProfileAdapter.SCHEMA_VERSION
end

function EnhancedDataSyncController:serverSupportsDeluxeProfileRestore(server)
    local capabilities = server and server.capabilities or {}
    local direction = capabilities.deluxe_profile_restore_direction
    return self:serverSupportsDeluxeProfiles(server)
        and capabilities.deluxe_profile_restore == true
        and (direction == nil or direction == "cross_device_client_confirm")
end

function EnhancedDataSyncController:cacheSettingsBackupCapabilities(server, enhanced_capabilities)
    local owner = self.owner
    local backup_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.settings_backups_version) or nil
    local schema_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.settings_snapshot_schema_version) or nil
    local restore_direction = type(enhanced_capabilities) == "table" and enhanced_capabilities.settings_restore_direction or nil
    local backup_supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.settings_backups == true
        and (backup_version or 0) >= 1
        and (schema_version or 0) >= SettingsBackupAdapter.SCHEMA_VERSION
    local restore_supported = backup_supported
        and enhanced_capabilities.settings_restore == true
        and (restore_direction == nil or restore_direction == "server_request_client_confirm")
    owner.store:setCapability(server.id, "settings_backups", backup_supported)
    owner.store:setCapability(server.id, "settings_backups_version", backup_version)
    owner.store:setCapability(server.id, "settings_snapshot_schema_version", schema_version)
    owner.store:setCapability(server.id, "settings_restore", restore_supported)
    owner.store:setCapability(server.id, "settings_restore_direction", restore_direction)
    return backup_supported, restore_supported
end

function EnhancedDataSyncController:cacheDeluxeProfileCapabilities(server, enhanced_capabilities)
    local owner = self.owner
    local profile_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.deluxe_profiles_version) or nil
    local schema_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.deluxe_profile_schema_version) or nil
    local restore_direction = type(enhanced_capabilities) == "table" and enhanced_capabilities.deluxe_profile_restore_direction or nil
    local profile_supported = type(enhanced_capabilities) == "table"
        and DeluxeProfileAdapter ~= nil
        and enhanced_capabilities.deluxe_profiles == true
        and (profile_version or 0) >= 1
        and (schema_version or 0) >= DeluxeProfileAdapter.SCHEMA_VERSION
    local restore_supported = profile_supported
        and enhanced_capabilities.deluxe_profile_restore == true
        and (restore_direction == nil or restore_direction == "cross_device_client_confirm")
    owner.store:setCapability(server.id, "deluxe_profiles", profile_supported)
    owner.store:setCapability(server.id, "deluxe_profiles_version", profile_version)
    owner.store:setCapability(server.id, "deluxe_profile_schema_version", schema_version)
    owner.store:setCapability(server.id, "deluxe_profile_restore", restore_supported)
    owner.store:setCapability(server.id, "deluxe_profile_restore_direction", restore_direction)
    return profile_supported, restore_supported
end

function EnhancedDataSyncController:refreshSettingsBackupCapabilities(server, client)
    local owner = self.owner
    client = client or owner:newClient(server)
    local ok, status, body = client:capabilities()
    local data = decode(body)
    if ok and (status == 404 or status == 405) then
        self:cacheDeluxeProfileCapabilities(server, nil)
        return self:cacheSettingsBackupCapabilities(server, nil)
    end
    if not ok or status ~= 200 or type(data) ~= "table" or type(data.capabilities) ~= "table" then
        return false, false
    end
    self:cacheDeluxeProfileCapabilities(server, data.capabilities)
    return self:cacheSettingsBackupCapabilities(server, data.capabilities)
end

function EnhancedDataSyncController:cacheEnhancedCapabilities(server, enhanced_capabilities)
    local owner = self.owner
    local logical_supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.logical_books == true
        and enhanced_capabilities.logical_library == true
    local rich_position_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.rich_position_version) or nil
    local rich_supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.rich_progress == true
        and (rich_position_version or 0) >= 1
    local device_registration_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.device_registration_version) or nil
    local device_supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.device_registration == true
        and (device_registration_version or 0) >= 1
    local annotation_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.annotations_version) or nil
    local annotation_supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.annotations == true
        and (annotation_version or 0) >= 1
    local client_notices_version = type(enhanced_capabilities) == "table" and tonumber(enhanced_capabilities.client_notices_version) or nil
    local client_notices_supported = type(enhanced_capabilities) == "table"
        and enhanced_capabilities.client_notices == true
        and (client_notices_version or 0) >= 1

    owner.store:setCapability(server.id, "logical_books", logical_supported)
    owner.store:setCapability(server.id, "logical_library", logical_supported)
    owner.store:setCapability(server.id, "rich_progress", rich_supported)
    owner.store:setCapability(server.id, "rich_position_version", rich_position_version)
    owner.store:setCapability(server.id, "device_registration", device_supported)
    owner.store:setCapability(server.id, "device_registration_version", device_registration_version)
    owner.store:setCapability(server.id, "annotations", annotation_supported)
    owner.store:setCapability(server.id, "annotations_version", annotation_version)
    owner.store:setCapability(server.id, "client_notices", client_notices_supported)
    owner.store:setCapability(server.id, "client_notices_version", client_notices_version)
    if not client_notices_supported and owner.store.saveClientNotices then owner.store:saveClientNotices(server.id, {}, os.time()) end
    self:cacheReadingStatisticsCapabilities(server, enhanced_capabilities)
    self:cacheVocabularyCapabilities(server, enhanced_capabilities)
    self:cacheSettingsBackupCapabilities(server, enhanced_capabilities)
    self:cacheDeluxeProfileCapabilities(server, enhanced_capabilities)
end

function EnhancedDataSyncController:refreshEnhancedCapabilities(server, client)
    local owner = self.owner
    if not owner.store or not server or server.enabled == false then return false, nil end
    client = client or owner:newClient(server)
    local ok, status, body = client:capabilities()
    local data = decode(body)

    if ok and (status == 404 or status == 405) then
        self:cacheEnhancedCapabilities(server, nil)
        return false, status
    end
    if not ok or status ~= 200 or type(data) ~= "table" or type(data.capabilities) ~= "table" then
        return false, status
    end
    self:cacheEnhancedCapabilities(server, data.capabilities)
    return true, status
end

function EnhancedDataSyncController:refreshEnhancedCapabilitiesAsync(server, client, callback)
    local owner = self.owner
    callback = callback or function() end
    if not owner.store or not server or server.enabled == false then
        callback(false, nil)
        return
    end
    client = client or owner:newClient(server)
    client:capabilitiesAsync(function(ok, status, body)
        local data = decode(body)
        if status == 404 or status == 405 then
            self:cacheEnhancedCapabilities(server, nil)
            callback(false, status)
            return
        end
        if not ok or status ~= 200 or type(data) ~= "table" or type(data.capabilities) ~= "table" then
            -- Lifecycle refreshes fail closed: progress sync remains available, but
            -- enhanced/background features stay dormant until capabilities can be
            -- confirmed on a later refresh. This also prevents repeated probes.
            self:cacheEnhancedCapabilities(server, nil)
            callback(false, status)
            return
        end
        self:cacheEnhancedCapabilities(server, data.capabilities)
        callback(true, status)
    end)
end

function EnhancedDataSyncController:refreshEnhancedCapabilitiesForAll()
    local owner = self.owner
    if not owner.store or not NetworkMgr:isOnline() then return end
    local servers = owner.store:getEnabledServers()
    local pending = #servers
    if pending == 0 then
        self:nudgeOptionalDataAll(false)
        return
    end

    local function finishServer()
        pending = pending - 1
        if pending == 0 then self:nudgeOptionalDataAll(false) end
    end

    for index, server in ipairs(servers) do
        UIManager:scheduleIn((index - 1) * 0.25, function()
            local client = owner:newClient(server)
            self:refreshEnhancedCapabilitiesAsync(server, client, function(supported)
                if supported then
                    owner:checkSettingsRestoreForServer(server, client)
                    owner:checkDeluxeProfileMigrationForServer(server, client)
                end
                finishServer()
            end)
        end)
    end
end

function EnhancedDataSyncController:getOptionalDataDocuments()
    local owner = self.owner
    local documents = {}
    if not owner.store then return documents end
    local canonical_document = owner:getDocumentDigest()
    for server_index, server in ipairs(owner.store:getEnabledServers()) do
        local document = owner:getServerDocumentDigest(server) or canonical_document
        if document and document ~= "" then
            documents[tostring(server.id)] = document
        end
    end
    return documents
end

function EnhancedDataSyncController:nudgeOptionalData(server, document, immediate)
    if not self.coordinator then return end
    local documents = {}
    if server and server.id and document and document ~= "" then
        documents[tostring(server.id)] = document
    end
    self.coordinator:nudge(documents, immediate == true)
end

function EnhancedDataSyncController:nudgeOptionalDataAll(immediate)
    if not self.coordinator then return end
    self.coordinator:nudge(self:getOptionalDataDocuments(), immediate == true)
end

function EnhancedDataSyncController:syncOptionalDataForServer(server, document, callback)
    local owner = self.owner
    callback = callback or function() end
    local steps = {}
    if server and server.annotations_enabled == true and document and document ~= "" then
        steps[#steps + 1] = function(done) owner:syncAnnotationsForServer(server, document, done) end
    end
    if server and server.settings_backup_enabled == true then
        steps[#steps + 1] = function(done) owner:syncSettingsBackupForServer(server, done) end
    end
    if server and server.deluxe_config_backup_enabled == true then
        steps[#steps + 1] = function(done) owner:syncDeluxeProfileBackupForServer(server, done) end
    end
    if server and server.vocabulary_enabled == true then
        steps[#steps + 1] = function(done) owner:syncVocabularyForServer(server, done) end
    end
    if server and server.reading_statistics_enabled == true then
        steps[#steps + 1] = function(done) owner:syncReadingStatisticsForServer(server, done) end
    end

    local index = 0
    local function runNext()
        index = index + 1
        local step = steps[index]
        if not step then
            callback(true)
            return
        end
        step(function() runNext() end)
    end
    runNext()
end

return EnhancedDataSyncController
