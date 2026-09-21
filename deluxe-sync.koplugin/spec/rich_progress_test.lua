local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local main = readFile("main.lua")
local controller = readFile("EnhancedDataSyncController.lua")
local lifecycle = readFile("ProgressLifecycleController.lua")
local store = readFile("ServerStore.lua")
local api = readFile("api.json")

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing expected rich-progress integration: " .. text))
end

contains(api, '"optional_params": ["metadata", "position",', "progress API must accept optional rich position")
contains(api, '"document", "metadata", "position",', "progress API must serialize rich position")
contains(store, 'rich_progress = nil', "server capability cache must include rich progress")
contains(store, 'rich_position_version = nil', "server capability cache must include rich position version")

contains(main, 'function ProgressSyncDeluxe:getRichPosition(progress, percentage)', "KOReader rich-position producer missing")
contains(main, 'pctQ = math.floor(ratio * 1000000 + 0.5)', "pctQ must be derived from KOReader percentage")
contains(main, 'document:getCurrentPage()', "rich position should include KOReader page hint when available")
contains(main, 'document:getPageCount()', "rich position should include KOReader page count when available")
contains(main, 'if document and not document.info.has_pages and progress ~= nil then', "rolling documents should expose native XPointer")
contains(main, 'if xpath ~= "" and #xpath <= 120 then position.xpath = xpath end', "XPointer must honor server byte-size boundary")
contains(main, 'function ProgressSyncDeluxe:serverSupportsRichProgress(server)', "rich progress must be capability gated")
contains(main, 'capabilities.rich_progress == true', "rich progress must require explicit server support")
contains(main, 'tonumber(capabilities.rich_position_version)', "rich progress must require a supported schema version")
contains(main, 'payload.position = rich_position', "supported servers must receive rich position")
contains(lifecycle, 'local strip_position = payload.position ~= nil and not owner:serverSupportsRichProgress(server)', "queued payloads must strip rich fields for unsupported servers")
contains(main, 'position = type(data.position) == "table" and data.position or nil', "pull results must retain server rich position")
contains(main, 'tonumber(group.position.pctQ) / 1000000', "alternate-document pull must use pctQ as portable fallback")
contains(controller, 'owner.store:setCapability(server.id, "rich_progress", rich_supported)', "capability probe must cache rich support")
contains(controller, 'owner.store:setCapability(server.id, "rich_position_version", rich_position_version)', "capability probe must cache rich schema version")
contains(main, '_("Rich Position")', "server UI must surface rich-position support")

print("rich_progress_test.lua: OK")
