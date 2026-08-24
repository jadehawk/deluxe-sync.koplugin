local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local DiagnosticLog = require("DiagnosticLog")

local SyncQueue = {}
local SETTINGS_DIR = DataStorage:getSettingsDir() .. "/deluxe-sync"
local FILE = SETTINGS_DIR .. "/queue.lua"

function SyncQueue:new()
    local o = setmetatable({}, { __index = self })
    if not lfs.attributes(SETTINGS_DIR, "mode") then pcall(lfs.mkdir, SETTINGS_DIR) end
    o.settings = LuaSettings:open(FILE)
    o.items = o.settings:readSetting("items", {}) or {}
    DiagnosticLog.log("queue loaded", "items", #o.items)
    return o
end

function SyncQueue:save()
    self.settings:saveSetting("items", self.items)
    self.settings:flush()
end

function SyncQueue:push(item)
    local filtered = {}
    for _, old in ipairs(self.items) do
        if not (old.server_id == item.server_id and old.document == item.document) then
            table.insert(filtered, old)
        end
    end
    item.queued_at = item.queued_at or os.time()
    item.reason = item.reason or "Pending retry"
    table.insert(filtered, item)
    self.items = filtered
    self:save()
    DiagnosticLog.log("queue push", "server", item.server_id, "document", item.document, "reason", item.reason, "count", #self.items)
end

function SyncQueue:updateFailure(server_id, document, status, reason)
    for _, item in ipairs(self.items) do
        if item.server_id == server_id and item.document == document then
            item.last_status = status
            item.reason = reason or "Pending retry"
            item.last_attempt_at = os.time()
            self:save()
            DiagnosticLog.log("queue update failure", "server", server_id, "document", document, "status", status or "nil", "reason", item.reason)
            return true
        end
    end
    return false
end

function SyncQueue:remove(server_id, document)
    local filtered = {}
    for _, item in ipairs(self.items) do
        if not (item.server_id == server_id and item.document == document) then
            table.insert(filtered, item)
        end
    end
    self.items = filtered
    self:save()
    DiagnosticLog.log("queue remove", "server", server_id, "document", document, "count", #self.items)
end

function SyncQueue:removeServer(server_id)
    local filtered = {}
    for _, item in ipairs(self.items) do
        if item.server_id ~= server_id then table.insert(filtered, item) end
    end
    self.items = filtered
    self:save()
    DiagnosticLog.log("queue remove server", "server", server_id, "count", #self.items)
end

function SyncQueue:list()
    return self.items
end

function SyncQueue:count(server_id)
    local count = 0
    for _, item in ipairs(self.items) do
        if not server_id or item.server_id == server_id then count = count + 1 end
    end
    return count
end

return SyncQueue
