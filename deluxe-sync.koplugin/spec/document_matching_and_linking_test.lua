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

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing expected integration: " .. text))
end

local function excludes(source, text, message)
    assert(not source:find(text, 1, true), message or ("unexpected legacy integration: " .. text))
end

-- Existing configurations and unknown values remain binary-compatible by default.
contains(store, 'server.checksum_method == "filename" and "filename" or "binary"', "server checksum method must normalize to binary unless explicitly filename")
contains(main, 'local checksum_method = existing.checksum_method == "filename" and "filename" or "binary"', "edit dialog must restore per-server matching method")
contains(main, 'id = "matching_toggle"', "server dialog must expose a compact matching-method toggle")
contains(main, 'T(_("Match: %1"), checksum_method == "filename" and _("Filename") or _("Binary"))', "matching method must explicitly show Binary or Filename")
contains(main, 'id = "metadata_toggle"', "metadata toggle must share the compact server option row")
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

-- Browse Tracked Books only offers unlinked raw records and uses native ButtonDialog scrolling.
contains(main, 'if book.kind == "raw" and book.document then table.insert(raw_books, book) end', "link selection must exclude already-linked logical records")
contains(main, 'local selected_documents = {}', "logical link selection state missing")
contains(main, 'local button_id = "logical_link_book_" .. tostring(index)', "logical link choices must use native button rows")
contains(main, 'dialog:getButtonById(button_id)', "logical link choices must update native buttons safely")
contains(main, 'rows_per_page = { 6, 5, 4, 3 }', "logical link picker should use ButtonDialog native scrolling")
excludes(main, 'local selections = {}', "crash-prone checkbox selection container should be removed")
contains(main, 'function ProgressSyncDeluxe:showLogicalProgressSourcePicker', "shared-progress picker missing")
contains(main, 'local a_percentage = tonumber(a.percentage) or -1', "shared-progress recommendation must rank by percentage")
contains(main, 'progress_source_document = selected_book.document', "selected shared-progress source must be sent to the server")
contains(main, 'function ProgressSyncDeluxe:confirmUnlinkLogicalBook', "logical unlink UI missing")
contains(main, 'self:showLogicalBookInspection(server, selected.item)', "logical cards must open logical-book details")

print("document_matching_and_linking_test.lua: OK")
