local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local EnhancedDataSyncCoordinator = {}
EnhancedDataSyncCoordinator.__index = EnhancedDataSyncCoordinator

local function mergeDocuments(target, incoming)
    if type(incoming) ~= "table" then return end
    for server_id, document in pairs(incoming) do
        if document and document ~= "" then
            target[tostring(server_id)] = document
        end
    end
end

function EnhancedDataSyncCoordinator:new(owner)
    return setmetatable({
        owner = owner,
        scheduled = false,
        running = false,
        rerun = false,
        pending_documents = {},
    }, self)
end

function EnhancedDataSyncCoordinator:nudge(documents, immediate)
    mergeDocuments(self.pending_documents, documents)
    if self.running then
        self.rerun = true
        return
    end
    if self.scheduled then return end

    self.scheduled = true
    UIManager:scheduleIn(immediate and 0 or 0.25, function()
        self.scheduled = false
        self:run()
    end)
end

function EnhancedDataSyncCoordinator:run()
    if self.running then
        self.rerun = true
        return
    end
    if not NetworkMgr:isOnline() then return end

    local owner = self.owner
    if not owner or not owner.store then return end
    local servers = owner.store:getEnabledServers()
    if #servers == 0 then return end

    self.running = true
    local documents = self.pending_documents
    self.pending_documents = {}
    local index = 1

    local function finish()
        self.running = false
        if self.rerun or next(self.pending_documents) ~= nil then
            self.rerun = false
            self:nudge(nil, false)
        end
    end

    local function runNextServer()
        local server = servers[index]
        index = index + 1
        if not server then
            finish()
            return
        end
        local document = documents[tostring(server.id)]
        owner:syncOptionalDataForServer(server, document, function()
            UIManager:scheduleIn(0.05, runNextServer)
        end)
    end

    runNextServer()
end

return EnhancedDataSyncCoordinator
