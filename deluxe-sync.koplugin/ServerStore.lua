local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local DiagnosticLog = require("DiagnosticLog")
local UrlUtil = require("UrlUtil")

local ServerStore = {}

local SETTINGS_DIR = DataStorage:getSettingsDir() .. "/deluxe-sync"
local SETTINGS_FILE = SETTINGS_DIR .. "/settings.lua"

local defaults = {
    servers = {},
    aliases = {},
    known_documents = {},
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
    o.data.settings = o.data.settings or deepCopy(defaults.settings)
    if o.data.settings.auto_sync == nil then o.data.settings.auto_sync = false end
    if o.data.settings.sync_forward == nil then o.data.settings.sync_forward = "prompt" end
    if o.data.settings.sync_backward == nil then o.data.settings.sync_backward = "never" end

    local servers_changed = false
    for _, server in ipairs(o.data.servers) do
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
    server.capabilities = server.capabilities or {
        metadata_compatible = nil,
        metadata_retained = nil,
        document_listing = nil,
        account_recovery = nil,
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

function ServerStore:setKnownDocuments(server_id, documents)
    self.data.known_documents[server_id] = documents or {}
    self:flush()
end

function ServerStore:getKnownDocuments(server_id)
    return self.data.known_documents[server_id] or {}
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

return ServerStore
