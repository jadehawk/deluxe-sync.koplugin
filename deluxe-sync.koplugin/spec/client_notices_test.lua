local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing client-notices integration: " .. text))
end

local api = readFile("api.json")
local client = readFile("SyncClient.lua")
local controller = readFile("EnhancedDataSyncController.lua")
local store = readFile("ServerStore.lua")
local main = readFile("main.lua")
local lifecycle = readFile("ProgressLifecycleController.lua")

contains(api, '"client_notices"', "client notices endpoint is missing from the service contract")
contains(api, '"path": "/api/v1/client-notices"', "client notices endpoint path mismatch")
contains(client, "function SyncClient:getClientNotices(username, userkey, callback)", "authenticated client-notices transport missing")
contains(client, 'self:_async("client_notices", username, userkey, {}, callback)', "client notices must use authenticated async transport")

contains(controller, "enhanced_capabilities.client_notices == true", "capability discovery must gate client notices")
contains(controller, 'owner.store:setCapability(server.id, "client_notices", client_notices_supported)', "client-notices capability must persist per server")
contains(controller, 'owner.store:setCapability(server.id, "client_notices_version", client_notices_version)', "client-notices protocol version must persist per server")
contains(controller, 'owner.store:saveClientNotices(server.id, {}, os.time())', "unsupported capability refresh must clear stale attention state")

contains(store, "client_notices = {}", "client notices must persist in Deluxe-Sync settings")
contains(store, "function ServerStore:saveClientNotices(server_id, notices, checked_at)", "client notice state writer missing")
contains(store, "function ServerStore:markClientNoticeShown(server_id, notice_id, at)", "notice-throttling timestamp writer missing")
contains(store, "function ServerStore:serverNeedsAttention(server_id)", "persistent attention state query missing")
contains(store, "if not live_ids[notice_id] then state.last_shown[notice_id] = nil end", "resolved notices must clear their suppression timestamp")

contains(main, "local CLIENT_NOTICE_REPEAT_SECONDS = 24 * 60 * 60", "notice repeat suppression must remain 24 hours")
contains(main, "function ProgressSyncDeluxe:refreshClientNotices(server)", "client notice refresh flow missing")
contains(main, "function ProgressSyncDeluxe:scheduleClientNoticesRefresh(server, delay)", "post-sync notice scheduler missing")
contains(main, "local due_needs_attention = false", "popup persistence must be based only on notices due now")
contains(main, "self.store:markClientNoticeShown(server.id, notice.id, now)", "displayed notices must persist their shown timestamp")
contains(main, 'return "⚠ " .. label', "servers page must keep a persistent attention marker")
contains(main, "self:scheduleClientNoticesRefresh(server, 1)", "successful direct sync must schedule a notice check")
contains(lifecycle, "owner:scheduleClientNoticesRefresh(server, 1)", "successful queued retry must schedule a notice check")

print("client_notices_test.lua: OK")
