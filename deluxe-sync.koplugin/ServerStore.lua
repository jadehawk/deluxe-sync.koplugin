local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local DiagnosticLog = require("DiagnosticLog")
local UrlUtil = require("UrlUtil")

local ServerStore = {}

ServerStore.DATA_SHARING_VERSION = 3

local SETTINGS_DIR = DataStorage:getSettingsDir() .. "/deluxe-sync"
local SETTINGS_FILE = SETTINGS_DIR .. "/settings.lua"

local defaults = {
    servers = {},
    aliases = {},
    known_documents = {},
    known_documents_meta = {},
    annotation_sync = {},
    reading_statistics_sync = {},
    settings_backup_sync = {},
    deluxe_profile_sync = {},
    vocabulary_sync = {},
    client_notices = {},
    settings = {
        auto_sync = false,
        sync_forward = "prompt",
        sync_backward = "never",
        logging_enabled = true,
    },
}

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

local function makeId(name, url, username)
    return md5(table.concat({ name or "", url or "", username or "" }, "\0"))
end

function ServerStore:new()
    local o = setmetatable({}, { __index = self })
    if not lfs.attributes(SETTINGS_DIR, "mode") then pcall(lfs.mkdir, SETTINGS_DIR) end
    o.settings_obj = LuaSettings:open(SETTINGS_FILE)
    o.data = o.settings_obj:readSetting("data", deepCopy(defaults))
    o.data.servers = o.data.servers or {}
    o.data.aliases = o.data.aliases or {}
    o.data.known_documents = o.data.known_documents or {}
    o.data.known_documents_meta = o.data.known_documents_meta or {}
    o.data.annotation_sync = o.data.annotation_sync or {}
    o.data.reading_statistics_sync = o.data.reading_statistics_sync or {}
    o.data.settings_backup_sync = o.data.settings_backup_sync or {}
    o.data.deluxe_profile_sync = o.data.deluxe_profile_sync or {}
    o.data.vocabulary_sync = o.data.vocabulary_sync or {}
    o.data.client_notices = o.data.client_notices or {}
    o.data.settings = o.data.settings or deepCopy(defaults.settings)
    if o.data.settings.auto_sync == nil then o.data.settings.auto_sync = false end
    if o.data.settings.sync_forward == nil then o.data.settings.sync_forward = "prompt" end
    if o.data.settings.sync_backward == nil then o.data.settings.sync_backward = "never" end

    local servers_changed = false
    for _, server in ipairs(o.data.servers) do
        local sharing_version = math.max(0, math.floor(tonumber(server.data_sharing_version) or 0))
        if server.data_sharing_version ~= sharing_version then
            server.data_sharing_version = sharing_version
            servers_changed = true
        end
        for _, field in ipairs({ "book_feedback_enabled", "annotations_enabled", "reading_statistics_enabled", "settings_backup_enabled", "deluxe_config_backup_enabled", "vocabulary_enabled", "vocabulary_context_enabled" }) do
            if server[field] ~= true and server[field] ~= false then
                server[field] = false
                servers_changed = true
            end
        end
        local checksum_method = server.checksum_method == "filename" and "filename" or "binary"
        if server.checksum_method ~= checksum_method then
            server.checksum_method = checksum_method
            servers_changed = true
        end
        local normalized_url, url_error = UrlUtil.normalize(server.url)
        if normalized_url then
            if server.url ~= normalized_url then
                DiagnosticLog.log("server URL normalized", server.name or "", server.url or "", normalized_url)
                server.url = normalized_url
                servers_changed = true
            end
        elseif server.enabled ~= false then
            DiagnosticLog.log("server disabled invalid URL", server.name or "", server.url or "", url_error or "invalid URL")
            server.enabled = false
            servers_changed = true
        end
    end
    if servers_changed then
        o.settings_obj:saveSetting("data", o.data)
        o.settings_obj:flush()
    end
    return o
end

function ServerStore:flush()
    self.settings_obj:saveSetting("data", self.data)
    self.settings_obj:flush()
end

function ServerStore:getSkippedUpdateVersion()
    local version = self.data.settings.skipped_update_version
    if type(version) ~= "string" or version == "" then return nil end
    return version
end

function ServerStore:setSkippedUpdateVersion(version)
    if version ~= nil and (type(version) ~= "string" or version == "") then
        return nil, "Skipped update version must be a non-empty string"
    end
    self.data.settings.skipped_update_version = version
    self:flush()
    return true
end

function ServerStore:getSetting(key, default)
    local value = self.data.settings[key]
    if value == nil then return default end
    return value
end

function ServerStore:setSetting(key, value)
    self.data.settings[key] = value
    self:flush()
    return true
end

function ServerStore:listServers()
    return self.data.servers
end

function ServerStore:getEnabledServers()
    local out = {}
    for _, server in ipairs(self.data.servers) do
        if server.enabled ~= false then table.insert(out, server) end
    end
    return out
end

function ServerStore:getServersNeedingDataSharingReview()
    local out = {}
    for _, server in ipairs(self.data.servers) do
        if (tonumber(server.data_sharing_version) or 0) < ServerStore.DATA_SHARING_VERSION then
            out[#out + 1] = server
        end
    end
    return out
end

function ServerStore:getServer(id)
    for _, server in ipairs(self.data.servers) do
        if server.id == id then return server end
    end
end

function ServerStore:upsertServer(server)
    server.id = server.id or makeId(server.name, server.url, server.username)
    DiagnosticLog.log("server upsert", server.name or "", server.url or "", server.username or "", "email", server.email or "", "enabled", server.enabled ~= false)
    server.enabled = server.enabled ~= false
    server.metadata_enabled = server.metadata_enabled ~= false
    server.data_sharing_version = math.max(0, math.floor(tonumber(server.data_sharing_version) or 0))
    server.book_feedback_enabled = server.book_feedback_enabled == true
    server.annotations_enabled = server.annotations_enabled == true
    server.reading_statistics_enabled = server.reading_statistics_enabled == true
    server.settings_backup_enabled = server.settings_backup_enabled == true
    server.deluxe_config_backup_enabled = server.deluxe_config_backup_enabled == true
    server.vocabulary_enabled = server.vocabulary_enabled == true
    server.vocabulary_context_enabled = server.vocabulary_enabled and server.vocabulary_context_enabled == true or false
    server.checksum_method = server.checksum_method == "filename" and "filename" or "binary"
    server.capabilities = server.capabilities or {
        metadata_compatible = nil,
        metadata_retained = nil,
        document_listing = nil,
        account_recovery = nil,
        logical_books = nil,
        logical_library = nil,
        book_feedback = nil,
        book_feedback_version = nil,
        progress_event_timestamp = nil,
        rich_progress = nil,
        rich_position_version = nil,
        device_registration = nil,
        device_registration_version = nil,
        device_registered = nil,
        annotations = nil,
        annotations_version = nil,
        reading_statistics = nil,
        reading_statistics_version = nil,
        reading_statistics_events = nil,
        reading_statistics_direction = nil,
        settings_backups = nil,
        settings_backups_version = nil,
        settings_snapshot_schema_version = nil,
        settings_restore = nil,
        settings_restore_direction = nil,
        deluxe_profiles = nil,
        deluxe_profiles_version = nil,
        deluxe_profile_schema_version = nil,
        deluxe_profile_restore = nil,
        deluxe_profile_restore_direction = nil,
        vocabulary_builder = nil,
        vocabulary_builder_version = nil,
        vocabulary_builder_batch_max = nil,
        vocabulary_context = nil,
        vocabulary_direction = nil,
        client_notices = nil,
        client_notices_version = nil,
    }
    for i, existing in ipairs(self.data.servers) do
        if existing.id == server.id then
            self.data.servers[i] = server
            self:flush()
            return server
        end
    end
    table.insert(self.data.servers, server)
    self:flush()
    return server
end

function ServerStore:removeServer(id)
    DiagnosticLog.log("server remove", id)
    for i = #self.data.servers, 1, -1 do
        if self.data.servers[i].id == id then table.remove(self.data.servers, i) end
    end
    self.data.known_documents[id] = nil
    self.data.known_documents_meta[id] = nil
    self.data.annotation_sync[id] = nil
    self.data.reading_statistics_sync[id] = nil
    self.data.settings_backup_sync[id] = nil
    self.data.deluxe_profile_sync[id] = nil
    self.data.vocabulary_sync[id] = nil
    self.data.client_notices[id] = nil
    for canonical_document, aliases in pairs(self.data.aliases or {}) do
        local filtered = {}
        for _, alias in ipairs(aliases) do
            if alias.server_id ~= id then table.insert(filtered, alias) end
        end
        if #filtered > 0 then
            self.data.aliases[canonical_document] = filtered
        else
            self.data.aliases[canonical_document] = nil
        end
    end
    self:flush()
end

function ServerStore:setServerEnabled(id, enabled)
    DiagnosticLog.log("server enabled", id, enabled and true or false)
    local server = self:getServer(id)
    if not server then return false end
    server.enabled = enabled and true or false
    self:flush()
    return true
end

function ServerStore:setCapability(id, key, value)
    local server = self:getServer(id)
    if not server then return end
    server.capabilities = server.capabilities or {}
    server.capabilities[key] = value
    self:flush()
end

function ServerStore:getClientNoticeState(server_id)
    self.data.client_notices = self.data.client_notices or {}
    local state = self.data.client_notices[server_id]
    if type(state) ~= "table" then
        state = { notices = {}, last_shown = {}, checked_at = 0 }
        self.data.client_notices[server_id] = state
    end
    state.notices = type(state.notices) == "table" and state.notices or {}
    state.last_shown = type(state.last_shown) == "table" and state.last_shown or {}
    state.checked_at = tonumber(state.checked_at) or 0
    return state
end

function ServerStore:saveClientNotices(server_id, notices, checked_at)
    local state = self:getClientNoticeState(server_id)
    local current = type(notices) == "table" and notices or {}
    local live_ids = {}
    for _, notice in ipairs(current) do
        if type(notice) == "table" and type(notice.id) == "string" and notice.id ~= "" then
            live_ids[notice.id] = true
        end
    end
    for notice_id in pairs(state.last_shown) do
        if not live_ids[notice_id] then state.last_shown[notice_id] = nil end
    end
    state.notices = current
    state.checked_at = tonumber(checked_at) or os.time()
    self.data.client_notices[server_id] = state
    self:flush()
    return state
end

function ServerStore:markClientNoticeShown(server_id, notice_id, at)
    if type(notice_id) ~= "string" or notice_id == "" then return false end
    local state = self:getClientNoticeState(server_id)
    state.last_shown[notice_id] = tonumber(at) or os.time()
    self.data.client_notices[server_id] = state
    self:flush()
    return true
end

function ServerStore:serverNeedsAttention(server_id)
    local state = self:getClientNoticeState(server_id)
    for _, notice in ipairs(state.notices) do
        local severity = type(notice) == "table" and tostring(notice.severity or "") or ""
        if severity == "warning" or severity == "error" then return true end
    end
    return false
end

function ServerStore:setKnownDocuments(server_id, documents, options)
    self.data.known_documents[server_id] = documents or {}
    self.data.known_documents_meta = self.data.known_documents_meta or {}
    local meta = self.data.known_documents_meta[server_id] or {}
    options = type(options) == "table" and options or {}
    if options.logical_mode ~= nil then meta.logical_mode = options.logical_mode == true end
    if options.refreshed_at ~= nil then meta.refreshed_at = math.max(0, tonumber(options.refreshed_at) or 0) end
    self.data.known_documents_meta[server_id] = meta
    self:flush()
end

function ServerStore:getKnownDocuments(server_id)
    return self.data.known_documents[server_id] or {}
end

function ServerStore:getKnownDocumentsMeta(server_id)
    local meta = self.data.known_documents_meta and self.data.known_documents_meta[server_id] or nil
    if type(meta) ~= "table" then return { refreshed_at = 0, logical_mode = false } end
    return {
        refreshed_at = math.max(0, tonumber(meta.refreshed_at) or 0),
        logical_mode = meta.logical_mode == true,
    }
end

function ServerStore:addAlias(canonical_document, server_id, remote_document, metadata)
    DiagnosticLog.log("alias add", "canonical", canonical_document, "server", server_id, "remote", remote_document)
    self.data.aliases[canonical_document] = self.data.aliases[canonical_document] or {}
    local aliases = self.data.aliases[canonical_document]
    for _, alias in ipairs(aliases) do
        if alias.server_id == server_id and alias.remote_document == remote_document then
            alias.metadata = metadata or alias.metadata
            self:flush()
            return alias
        end
    end
    local alias = {
        server_id = server_id,
        remote_document = remote_document,
        metadata = metadata,
    }
    table.insert(aliases, alias)
    self:flush()
    return alias
end

function ServerStore:getAliases(canonical_document)
    return self.data.aliases[canonical_document] or {}
end

function ServerStore:findCanonicalDocument(server_id, remote_document)
    for canonical, aliases in pairs(self.data.aliases) do
        for _, alias in ipairs(aliases) do
            if alias.server_id == server_id and alias.remote_document == remote_document then
                return canonical
            end
        end
    end
end

function ServerStore:getAnnotationState(server_id, document)
    if not server_id or not document then return { cursor = 0, items = {} } end
    self.data.annotation_sync = self.data.annotation_sync or {}
    self.data.annotation_sync[server_id] = self.data.annotation_sync[server_id] or {}
    local state = self.data.annotation_sync[server_id][document]
    if type(state) ~= "table" then
        state = { cursor = 0, items = {} }
        self.data.annotation_sync[server_id][document] = state
    end
    state.cursor = tonumber(state.cursor) or 0
    state.items = type(state.items) == "table" and state.items or {}
    return state
end

function ServerStore:saveAnnotationState(server_id, document, state)
    if not server_id or not document or type(state) ~= "table" then return false end
    self.data.annotation_sync = self.data.annotation_sync or {}
    self.data.annotation_sync[server_id] = self.data.annotation_sync[server_id] or {}
    self.data.annotation_sync[server_id][document] = state
    self:flush()
    return true
end

function ServerStore:getReadingStatisticsState(server_id)
    if not server_id then
        return { start_time = 0, id_book = 0, page = -1, initial_complete = false }
    end
    self.data.reading_statistics_sync = self.data.reading_statistics_sync or {}
    local state = self.data.reading_statistics_sync[server_id]
    if type(state) ~= "table" then
        state = { start_time = 0, id_book = 0, page = -1, initial_complete = false }
        self.data.reading_statistics_sync[server_id] = state
    end
    state.start_time = math.max(0, math.floor(tonumber(state.start_time) or 0))
    state.id_book = math.max(0, math.floor(tonumber(state.id_book) or 0))
    state.page = math.floor(tonumber(state.page) or -1)
    state.initial_complete = state.initial_complete == true
    return state
end

function ServerStore:saveReadingStatisticsState(server_id, state)
    if not server_id or type(state) ~= "table" then return false end
    self.data.reading_statistics_sync = self.data.reading_statistics_sync or {}
    self.data.reading_statistics_sync[server_id] = state
    self:flush()
    return true
end

function ServerStore:getSettingsBackupState(server_id)
    if not server_id then
        return { checksum = nil, deluxe_profile_checksum = nil, koreader_version = nil, snapshot_id = nil, uploaded_at = 0 }
    end
    self.data.settings_backup_sync = self.data.settings_backup_sync or {}
    local state = self.data.settings_backup_sync[server_id]
    if type(state) ~= "table" then
        state = { checksum = nil, deluxe_profile_checksum = nil, koreader_version = nil, snapshot_id = nil, uploaded_at = 0 }
        self.data.settings_backup_sync[server_id] = state
    end
    state.uploaded_at = math.max(0, math.floor(tonumber(state.uploaded_at) or 0))
    return state
end

function ServerStore:saveSettingsBackupState(server_id, state)
    if not server_id or type(state) ~= "table" then return false end
    self.data.settings_backup_sync = self.data.settings_backup_sync or {}
    self.data.settings_backup_sync[server_id] = state
    self:flush()
    return true
end

function ServerStore:getDeluxeProfileState(server_id)
    if not server_id then return { checksum = nil, uploaded_at = 0 } end
    self.data.deluxe_profile_sync = self.data.deluxe_profile_sync or {}
    local state = self.data.deluxe_profile_sync[server_id]
    if type(state) ~= "table" then
        state = { checksum = nil, uploaded_at = 0 }
        self.data.deluxe_profile_sync[server_id] = state
    end
    state.uploaded_at = math.max(0, math.floor(tonumber(state.uploaded_at) or 0))
    return state
end

function ServerStore:saveDeluxeProfileState(server_id, state)
    if not server_id or type(state) ~= "table" then return false end
    self.data.deluxe_profile_sync = self.data.deluxe_profile_sync or {}
    self.data.deluxe_profile_sync[server_id] = state
    self:flush()
    return true
end

function ServerStore:getVocabularyState(server_id)
    if not server_id then return { items = {}, context_included = false, uploaded_at = 0 } end
    self.data.vocabulary_sync = self.data.vocabulary_sync or {}
    local state = self.data.vocabulary_sync[server_id]
    if type(state) ~= "table" then
        state = { items = {}, context_included = false, uploaded_at = 0 }
        self.data.vocabulary_sync[server_id] = state
    end
    state.items = type(state.items) == "table" and state.items or {}
    state.context_included = state.context_included == true
    state.uploaded_at = math.max(0, math.floor(tonumber(state.uploaded_at) or 0))
    return state
end

function ServerStore:saveVocabularyState(server_id, state)
    if not server_id or type(state) ~= "table" then return false end
    self.data.vocabulary_sync = self.data.vocabulary_sync or {}
    self.data.vocabulary_sync[server_id] = state
    self:flush()
    return true
end

return ServerStore
