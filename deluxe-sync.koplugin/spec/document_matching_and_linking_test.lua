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
local settings_page = readFile("ServerSettingsPage.lua")
local library_browser = readFile("ServerLibraryBrowser.lua")
local library_controller = readFile("ServerLibraryController.lua")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing expected integration: " .. text))
end

local function excludes(source, text, message)
    assert(not source:find(text, 1, true), message or ("unexpected legacy integration: " .. text))
end

-- Existing configurations and unknown values remain binary-compatible by default.
contains(store, 'server.checksum_method == "filename" and "filename" or "binary"', "server checksum method must normalize to binary unless explicitly filename")
contains(settings_page, 'draft.checksum_method = draft.checksum_method == "filename" and "filename" or "binary"', "full-page settings must restore per-server matching method")
contains(settings_page, 'label = _("Book matching")', "full-page settings must expose the matching method")
contains(settings_page, 'self.draft.checksum_method == "filename" and _("Filename") or _("Binary")', "matching method must explicitly show Binary or Filename")
contains(settings_page, '_("DATA SHARED WITH THIS SERVER (IF SUPPORTED)")', "data-sharing controls must live on the full-page settings surface with remote-capability context")
excludes(main, 'Match documents by filename', "legacy filename-only checkbox should not remain in the server dialog")

-- Filename mode mirrors KOReader: MD5 of the basename, not the raw filename string.
contains(main, 'function ProgressSyncDeluxe:getFileNameDigest()', "filename digest helper missing")
contains(main, 'return md5(filename)', "filename mode must hash the filename exactly like KOReader")
contains(main, 'function ProgressSyncDeluxe:getServerDocumentDigest(server)', "per-server digest selector missing")
contains(main, 'if server and server.checksum_method == "filename" then', "filename matching must be selected per server")
contains(main, 'return self:getDocumentDigest()', "binary matching must retain the canonical partial MD5")

-- Push, queue and pull must independently derive the transmitted identity for each server.
contains(main, 'local document = self:getServerDocumentDigest(server) or canonical_document', "push/queue must use a per-server document identity")
contains(main, 'addRequest(self:getServerDocumentDigest(server) or canonical_document, false)', "pull must query the per-server document identity")
contains(main, 'self.store:getAliases(canonical_document)', "aliases must remain keyed by canonical binary identity")

-- Enhanced logical-book support is capability-gated and server authoritative.
contains(api, '"path": "/api/v1/capabilities"', "enhanced capability endpoint missing")
contains(api, '"path": "/api/v1/library"', "logical library endpoint missing")
contains(api, '"path": "/api/v1/logical-books"', "logical book create endpoint missing")
contains(api, '"progress_source_document"', "logical link request must support an explicit shared-progress source")
contains(client, 'function SyncClient:listLogicalLibrary', "logical library client method missing")
contains(client, 'function SyncClient:createLogicalBook', "logical book create client method missing")
contains(client, 'function SyncClient:getLogicalBook', "logical book detail client method missing")
contains(client, 'function SyncClient:unlinkLogicalBook', "logical book unlink client method missing")

-- Browse Synced Books now owns logical-link selection directly in the Libby-style grid/list browser.
contains(library_browser, 'local ServerLibraryBrowser = InputContainer:extend{', "synced-book browser must use a full-page InputContainer")
contains(library_browser, 'self.link_mode = enabled == true', "synced-book browser must expose integrated link mode")
contains(library_browser, 'function ServerLibraryBrowser:toggleLinkModeFromHeader()', "toolbar/D-pad Link activation must use one capability-aware path")
contains(library_browser, 'self:setLinkMode(not self.link_mode)', "supported Link activation must enter integrated link mode")
contains(library_browser, '_("This server does not support book linking.")', "unsupported Link activation must explain the capability limitation")
contains(library_browser, 'return self.can_link and entry and not entry.is_logical and entry.item and entry.item.document', "link mode must only select unlinked raw document records")
contains(library_browser, 'if entry and entry.is_logical then UIManager:show', "already-linked logical books must remain visible but unselectable")
contains(library_browser, '_("LINK BOOKS · %1 selected")', "link mode header must show selected count")
contains(library_browser, '_("Link %1 Books")', "link mode footer must expose the final link action")
contains(library_browser, 'if #selected < 2 then', "link mode must require at least two raw records")
contains(library_controller, 'self:showLogicalProgressSourcePicker(active_server, selected)', "browser link confirmation must reuse the existing shared-progress source picker for the currently displayed server")
contains(main, 'function ProgressSyncDeluxe:showLogicalProgressSourcePicker', "shared-progress picker compatibility delegate missing")
contains(library_controller, 'local a_percentage = tonumber(a.percentage) or -1', "shared-progress recommendation must rank by percentage")
contains(library_controller, 'progress_source_document = selected_book.document', "selected shared-progress source must be sent to the server")
contains(main, 'function ProgressSyncDeluxe:confirmUnlinkLogicalBook', "logical unlink compatibility delegate missing")
contains(library_controller, 'self:showLogicalBookInspection(active_server, entry.item, browser)', "logical browser entries must overlay logical-book details on the currently displayed server shelf")

print("document_matching_and_linking_test.lua: OK")
