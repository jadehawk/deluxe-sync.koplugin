local Device = require("device")
local Version = require("version")
local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local Blitbuffer = require("ffi/blitbuffer")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local IconButton = require("ui/widget/iconbutton")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local FreeScrollableContainer = ScrollableContainer:extend{}

function FreeScrollableContainer:onScrollPageUp()
    if not self._is_scrollable then return false end
    self:_scrollBy(0, -self._crop_h)
    return true
end

function FreeScrollableContainer:onScrollPageDown()
    if not self._is_scrollable then return false end
    self:_scrollBy(0, self._crop_h)
    return true
end
local Geom = require("ui/geometry")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template
local md5 = require("ffi/sha2").md5
local json = require("json")
local logger = require("logger")
local util = require("util")

local source_path = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local plugin_root = source_path:match("^(.*)[/\\]main%.lua$") or "."
local PluginMeta = dofile(plugin_root .. "/_meta.lua")
local PLUGIN_VERSION = assert(PluginMeta.version, "Missing plugin version in _meta.lua")
local QUEUE_DISABLE_THRESHOLD = 20
local QUEUE_RETRY_DELAYS = { 30, 120, 300, 900, 1800, 3600 }
local CLIENT_NOTICE_REPEAT_SECONDS = 24 * 60 * 60

local DiagnosticLog
local SyncClient
local SyncQueue
local ServerStore
local UrlUtil
local ResponseUtil
local Resolver
local LocalLibrary
local DocumentMetadataAdapter
local BookFeedbackAdapter
local AnnotationAdapter
local ReadingStatisticsAdapter
local VocabularyAdapter
local SettingsBackupAdapter
local SettingsBackupLifecycle
local DeluxeProfileAdapter
local EnhancedDataSyncCoordinator
local EnhancedDataSyncController
local RestoreMigrationController
local ProgressLifecycleController
local ServerLibraryController
local VocabularySync
local ReadingStatisticsSync
local AnnotationSync
local SettingsBackupSync
local DeluxeProfileBackupSync
local PluginMenuController
local DeluxeCoverPlaceholder

local ProgressSyncDeluxe = WidgetContainer:extend{
    name = "progresssyncdeluxe",
    is_doc_only = true,
    PLUGIN_VERSION = PLUGIN_VERSION,
}

local function insertAfterProgressSync(order)
    if type(order) ~= "table" then return end
    local found_deluxe
    for unused_index, name in ipairs(order) do
        if name == "progress_sync_deluxe" then
            found_deluxe = true
            break
        end
    end
    if found_deluxe then
        for i = #order, 1, -1 do
            if order[i] == "progress_sync_deluxe" then table.remove(order, i) end
        end
    end
    for i, name in ipairs(order) do
        if name == "progress_sync" then
            table.insert(order, i + 1, "progress_sync_deluxe")
            return
        end
    end
    table.insert(order, "progress_sync_deluxe")
end

local function ensureReaderMenuOrder()
    local reader_order = require("ui/elements/reader_menu_order")
    insertAfterProgressSync(reader_order.tools)

    -- A device may have a custom settings/reader_menu_order.lua. MenuSorter
    -- overlays that table after the default order, which would otherwise undo
    -- our placement. Adjust only the in-memory reader/tools order returned by
    -- MenuSorter; do not rewrite the user's menu-order file on disk.
    local MenuSorter = require("ui/menusorter")
    if not MenuSorter._progress_sync_deluxe_order_hook then
        local original_read = MenuSorter.readMSSettings
        MenuSorter.readMSSettings = function(self, config_prefix)
            local user_order = original_read(self, config_prefix)
            if config_prefix == "reader" and type(user_order) == "table" and type(user_order.tools) == "table" then
                insertAfterProgressSync(user_order.tools)
            end
            return user_order
        end
        MenuSorter._progress_sync_deluxe_order_hook = true
    end
end

local function userkey(password)
    return md5(password or "")
end

local function formatPercent(value)
    return string.format("%.1f%%", (tonumber(value) or 0) * 100)
end

local function decode(body)
    if type(body) == "table" then return body end
    if not body or body == "" then return nil end
    local ok, parsed = pcall(json.decode, body)
    if ok then return parsed end
end

local function serverResponseMessage(body)
    local data = decode(body)
    if type(data) == "table" then
        return data.message or data.error
    end
    if ResponseUtil and ResponseUtil.isHtml(body) then
        return nil
    end
    if type(body) == "string" and body ~= "" then
        return body
    end
end

local function userFacingServerFailure(status, body)
    if not status then
        return _("The server could not be reached. It may be offline or temporarily unavailable.")
    end
    if status == 401 then
        return _("Authentication failed. Check the username and password.")
    end
    if status >= 500 then
        return _("The server returned an error. Please try again later.")
    end
    if ResponseUtil and ResponseUtil.isHtml(body) then
        return "Unexpected HTML response from server (HTTP " .. tostring(status) .. "). Check the server URL."
    end
    local message = serverResponseMessage(body)
    local lower = tostring(message or ""):lower()
    if lower:find("protocols.lua", 1, true) or lower:find("wantread", 1, true) or lower:find("socket", 1, true) then
        return _("The server could not be reached. It may be offline or temporarily unavailable.")
    end
    return message or T(_("The server request failed (HTTP %1)."), status)
end

local function queueFailureReason(status, body)
    if not status then return _("Server unavailable") end
    if status == 401 then return _("Authentication failed") end
    if status >= 500 then return _("Server error") end
    return T(_("Sync failed (HTTP %1)"), status)
end

local function isBookNotFoundResponse(status, body)
    if status ~= 404 then return false end
    local data = decode(body) or {}
    local message = tostring(data.message or data.error or body or ""):lower()
    return message:find("book not found", 1, true) ~= nil
        or message:find("document hash", 1, true) ~= nil
end

local function serverLabel(server)
    return server.name or server.url or _("Unnamed server")
end

local function suppressDialogContainerHolds(dialog)
    if not (dialog and dialog.movable and dialog.movable.ges_events) then return end
    dialog.movable.ges_events.MovableHold = nil
    dialog.movable.ges_events.MovableHoldPan = nil
    dialog.movable.ges_events.MovableHoldRelease = nil
end

function ProgressSyncDeluxe:init()
    self.preview = nil
    self.init_error = nil
    self.device_heartbeat_sent = {}
    self.annotation_sync_in_flight = {}
    self.statistics_sync_in_flight = {}
    self.vocabulary_sync_in_flight = {}
    self.settings_backup_in_flight = {}
    self.settings_restore_in_flight = {}
    self.settings_restore_seen = {}
    self.deluxe_profile_in_flight = {}
    self.deluxe_profile_backup_in_flight = {}
    self.data_sharing_review_shown = false
    self.deluxe_profile_candidate_seen = {}
    self.deluxe_profile_restore_in_flight = {}
    self.deluxe_profile_restore_seen = {}
    self.client_notice_in_flight = {}
    self.client_notice_scheduled = {}
    ensureReaderMenuOrder()

    -- Register first so an initialization failure cannot make the plugin vanish
    -- from KOReader's menu. The diagnostic entry below will expose the error.
    self.ui.menu:registerToMainMenu(self)

    local ok, err = pcall(function()
        self.path = plugin_root
        package.path = self.path .. "/?.lua;" .. package.path
        PluginMenuController = require("PluginMenuController")
        self.plugin_menu_controller = PluginMenuController:new(self, {
            plugin_version = PLUGIN_VERSION,
            suppress_dialog_holds = suppressDialogContainerHolds,
            get_diagnostic_log = function() return DiagnosticLog end,
        })
        DiagnosticLog = require("DiagnosticLog")
        DiagnosticLog.log("plugin init", "start")
        SyncClient = require("SyncClient")
        SyncQueue = require("SyncQueue")
        ServerStore = require("ServerStore")
        UrlUtil = require("UrlUtil")
        ResponseUtil = require("ResponseUtil")
        Resolver = require("Resolver")
        LocalLibrary = require("LocalLibrary")
        DocumentMetadataAdapter = require("DocumentMetadataAdapter")
        BookFeedbackAdapter = require("BookFeedbackAdapter")
        AnnotationAdapter = require("AnnotationAdapter")
        ReadingStatisticsAdapter = require("ReadingStatisticsAdapter")
        VocabularyAdapter = require("VocabularyAdapter")
        SettingsBackupAdapter = require("SettingsBackupAdapter")
        SettingsBackupLifecycle = require("SettingsBackupLifecycle")
        DeluxeProfileAdapter = require("DeluxeProfileAdapter")
        EnhancedDataSyncCoordinator = require("EnhancedDataSyncCoordinator")
        EnhancedDataSyncController = require("EnhancedDataSyncController")
        RestoreMigrationController = require("RestoreMigrationController")
        ProgressLifecycleController = require("ProgressLifecycleController")
        ServerLibraryController = require("ServerLibraryController")
        VocabularySync = require("VocabularySync")
        ReadingStatisticsSync = require("ReadingStatisticsSync")
        AnnotationSync = require("AnnotationSync")
        SettingsBackupSync = require("SettingsBackupSync")
        DeluxeProfileBackupSync = require("DeluxeProfileBackupSync")
        DeluxeCoverPlaceholder = require("DeluxeCoverPlaceholder")
        self.store = ServerStore:new()
        DiagnosticLog.configure(self.store.data.settings.logging_enabled ~= false)
        self.queue = SyncQueue:new()
        self.enhanced_data_sync = EnhancedDataSyncCoordinator:new(self)
        self.enhanced_data_controller = EnhancedDataSyncController:new(self, self.enhanced_data_sync)
        self.restore_migration_controller = RestoreMigrationController:new(self, {
            decode = decode,
            server_response_message = serverResponseMessage,
            server_label = serverLabel,
            suppress_dialog_holds = suppressDialogContainerHolds,
        })
        self.progress_lifecycle_controller = ProgressLifecycleController:new(self, {
            diagnostic_log = DiagnosticLog,
            server_label = serverLabel,
            queue_failure_reason = queueFailureReason,
            is_book_not_found_response = isBookNotFoundResponse,
            queue_retry_delays = QUEUE_RETRY_DELAYS,
        })
        self.server_library_controller = ServerLibraryController:new(self, {
            decode = decode,
            format_percent = formatPercent,
            server_response_message = serverResponseMessage,
            server_label = serverLabel,
            suppress_dialog_holds = suppressDialogContainerHolds,
        })
        self.vocabulary_sync_service = VocabularySync:new(self, {
            adapter = VocabularyAdapter,
            server_label = serverLabel,
            server_response_message = serverResponseMessage,
        })
        self.reading_statistics_sync_service = ReadingStatisticsSync:new(self, {
            adapter = ReadingStatisticsAdapter,
            server_label = serverLabel,
            server_response_message = serverResponseMessage,
        })
        self.annotation_sync_service = AnnotationSync:new(self, {
            adapter = AnnotationAdapter,
            decode = decode,
            server_label = serverLabel,
        })
        self.settings_backup_sync_service = SettingsBackupSync:new(self, {
            adapter = SettingsBackupAdapter,
            lifecycle = SettingsBackupLifecycle,
            decode = decode,
            server_label = serverLabel,
            server_response_message = serverResponseMessage,
        })
        self.deluxe_profile_backup_sync_service = DeluxeProfileBackupSync:new(self, {
            adapter = DeluxeProfileAdapter,
            server_label = serverLabel,
            server_response_message = serverResponseMessage,
        })
        DiagnosticLog.log("plugin init", "storage ready", "servers", #self.store:listServers(), "queue", self.queue:count())
        if not self.store.data.device_id then
            self.store.data.device_id = md5(table.concat({ tostring(Device.model or "device"), tostring(os.time()), tostring(math.random()) }, ":"))
            self.store:flush()
        end
    end)

    if not ok then
        self.init_error = tostring(err)
        logger.err("Deluxe-Sync initialization failed:", self.init_error)
        if DiagnosticLog then DiagnosticLog.log("plugin init", "failed", self.init_error) end
    end
end

function ProgressSyncDeluxe:onDispatcherRegisterActions()
    if not self.plugin_menu_controller then return end
    return self.plugin_menu_controller:onDispatcherRegisterActions()
end

function ProgressSyncDeluxe:canManualSync()
    return self.plugin_menu_controller ~= nil and self.plugin_menu_controller:canManualSync()
end

function ProgressSyncDeluxe:showManualSyncUnavailable()
    if not self.plugin_menu_controller then return end
    return self.plugin_menu_controller:showManualSyncUnavailable()
end

function ProgressSyncDeluxe:onDeluxeSyncToggleAutoSync(toggle)
    if not self.plugin_menu_controller then return true end
    return self.plugin_menu_controller:onDeluxeSyncToggleAutoSync(toggle)
end

function ProgressSyncDeluxe:onDeluxeSyncPushProgress()
    if not self.plugin_menu_controller then return true end
    return self.plugin_menu_controller:onDeluxeSyncPushProgress()
end

function ProgressSyncDeluxe:onDeluxeSyncPullProgress()
    if not self.plugin_menu_controller then return true end
    return self.plugin_menu_controller:onDeluxeSyncPullProgress()
end

function ProgressSyncDeluxe:showServerOnboarding()
    if not self.plugin_menu_controller then return end
    return self.plugin_menu_controller:showServerOnboarding()
end

function ProgressSyncDeluxe:showCredits()
    if not self.plugin_menu_controller then return end
    return self.plugin_menu_controller:showCredits()
end

function ProgressSyncDeluxe:addToMainMenu(menu_items)
    if not self.plugin_menu_controller then return end
    return self.plugin_menu_controller:addToMainMenu(menu_items)
end

function ProgressSyncDeluxe:getDocumentDigest()
    return self.ui.doc_settings:readSetting("partial_md5_checksum")
end

function ProgressSyncDeluxe:getFileName()
    local file = self.ui.document.file
    if not file then return end
    local _ignored, filename = util.splitFilePathName(file)
    return filename
end

function ProgressSyncDeluxe:getFileNameDigest()
    local filename = self:getFileName()
    if not filename then return end
    return md5(filename)
end

function ProgressSyncDeluxe:getServerDocumentDigest(server)
    if server and server.checksum_method == "filename" then
        return self:getFileNameDigest()
    end
    return self:getDocumentDigest()
end

function ProgressSyncDeluxe:getMetadata()
    local props = self.ui.doc_props or {}
    return {
        filename = self:getFileName(),
        title = props.display_title,
        authors = props.authors,
        asin = DocumentMetadataAdapter and DocumentMetadataAdapter.extractAsin(self.ui) or nil,
        series = DocumentMetadataAdapter and DocumentMetadataAdapter.extractSeries(self.ui) or nil,
        series_index = DocumentMetadataAdapter and DocumentMetadataAdapter.extractSeriesIndex(self.ui) or nil,
    }
end

function ProgressSyncDeluxe:getBookFeedback()
    if not BookFeedbackAdapter then return {} end
    return BookFeedbackAdapter.extract(self.ui)
end

function ProgressSyncDeluxe:applyBookFeedbackToPayload(server, payload, feedback)
    if not self:serverSupportsBookFeedback(server) or type(feedback) ~= "table" then return payload end

    if feedback.rating_present == true then
        payload.rating_present = true
        if feedback.rating ~= nil then payload.rating = feedback.rating end
    end
    if feedback.review_note_present == true then
        payload.review_note_present = true
        if feedback.review_note ~= nil then payload.review_note = feedback.review_note end
    end
    return payload
end

function ProgressSyncDeluxe:getCurrentProgress()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress(), self.ui.paging:getLastPercent()
    end
    return self.ui.rolling:getLastProgress(), self.ui.rolling:getLastPercent()
end

function ProgressSyncDeluxe:getRichPosition(progress, percentage)
    local ratio = tonumber(percentage)
    if ratio == nil then return nil end
    ratio = math.max(0, math.min(1, ratio))
    local position = { pctQ = math.floor(ratio * 1000000 + 0.5) }

    local document = self.ui and self.ui.document
    if document and document.getCurrentPage then
        local page = tonumber(document:getCurrentPage())
        if page and page >= 0 and page <= 65535 then position.page = math.floor(page) end
    elseif self.ui and self.ui.getCurrentPage then
        local page = tonumber(self.ui:getCurrentPage())
        if page and page >= 0 and page <= 65535 then position.page = math.floor(page) end
    end
    if document and document.getPageCount then
        local pages = tonumber(document:getPageCount())
        if pages and pages > 0 and pages <= 65535 then position.pages = math.floor(pages) end
    end

    if document and not document.info.has_pages and progress ~= nil then
        local xpath = tostring(progress)
        if xpath ~= "" and #xpath <= 120 then position.xpath = xpath end
    end
    return position
end

function ProgressSyncDeluxe:serverSupportsProgressEventTimestamp(server)
    local capabilities = server and server.capabilities or {}
    return capabilities.progress_event_timestamp == true
end

function ProgressSyncDeluxe:serverSupportsRichProgress(server)
    local capabilities = server and server.capabilities or {}
    return capabilities.rich_progress == true
        and (tonumber(capabilities.rich_position_version) or 0) >= 1
end

function ProgressSyncDeluxe:serverSupportsBookFeedback(server)
    local capabilities = server and server.capabilities or {}
    return server ~= nil
        and server.book_feedback_enabled == true
        and capabilities.book_feedback == true
        and (tonumber(capabilities.book_feedback_version) or 0) >= 1
end

function ProgressSyncDeluxe:serverSupportsDeviceRegistration(server)
    local capabilities = server and server.capabilities or {}
    return capabilities.device_registration == true
        and (tonumber(capabilities.device_registration_version) or 0) >= 1
end

function ProgressSyncDeluxe:serverSupportsAnnotations(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsAnnotations(server)
end

function ProgressSyncDeluxe:serverSupportsReadingStatistics(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsReadingStatistics(server)
end

function ProgressSyncDeluxe:cacheReadingStatisticsCapabilities(server, enhanced_capabilities)
    if not self.enhanced_data_controller then return false end
    return self.enhanced_data_controller:cacheReadingStatisticsCapabilities(server, enhanced_capabilities)
end

function ProgressSyncDeluxe:refreshReadingStatisticsCapabilities(server, client)
    if not self.enhanced_data_controller then return false end
    return self.enhanced_data_controller:refreshReadingStatisticsCapabilities(server, client)
end

function ProgressSyncDeluxe:serverSupportsVocabulary(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsVocabulary(server)
end

function ProgressSyncDeluxe:cacheVocabularyCapabilities(server, enhanced_capabilities)
    if not self.enhanced_data_controller then return false end
    return self.enhanced_data_controller:cacheVocabularyCapabilities(server, enhanced_capabilities)
end

function ProgressSyncDeluxe:serverSupportsSettingsBackups(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsSettingsBackups(server)
end

function ProgressSyncDeluxe:serverSupportsSettingsRestore(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsSettingsRestore(server)
end

function ProgressSyncDeluxe:serverSupportsDeluxeProfiles(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsDeluxeProfiles(server)
end

function ProgressSyncDeluxe:serverSupportsDeluxeProfileRestore(server)
    return self.enhanced_data_controller ~= nil
        and self.enhanced_data_controller:serverSupportsDeluxeProfileRestore(server)
end

function ProgressSyncDeluxe:cacheSettingsBackupCapabilities(server, enhanced_capabilities)
    if not self.enhanced_data_controller then return false, false end
    return self.enhanced_data_controller:cacheSettingsBackupCapabilities(server, enhanced_capabilities)
end

function ProgressSyncDeluxe:cacheDeluxeProfileCapabilities(server, enhanced_capabilities)
    if not self.enhanced_data_controller then return false, false end
    return self.enhanced_data_controller:cacheDeluxeProfileCapabilities(server, enhanced_capabilities)
end

function ProgressSyncDeluxe:refreshSettingsBackupCapabilities(server, client)
    if not self.enhanced_data_controller then return false, false end
    return self.enhanced_data_controller:refreshSettingsBackupCapabilities(server, client)
end

function ProgressSyncDeluxe:cacheEnhancedCapabilities(server, enhanced_capabilities)
    if not self.enhanced_data_controller then return end
    return self.enhanced_data_controller:cacheEnhancedCapabilities(server, enhanced_capabilities)
end

function ProgressSyncDeluxe:refreshEnhancedCapabilities(server, client)
    if not self.enhanced_data_controller then return false, nil end
    return self.enhanced_data_controller:refreshEnhancedCapabilities(server, client)
end

function ProgressSyncDeluxe:refreshEnhancedCapabilitiesAsync(server, client, callback)
    if not self.enhanced_data_controller then
        if callback then callback(false, nil) end
        return
    end
    return self.enhanced_data_controller:refreshEnhancedCapabilitiesAsync(server, client, callback)
end

function ProgressSyncDeluxe:refreshEnhancedCapabilitiesForAll()
    if not self.enhanced_data_controller then return end
    return self.enhanced_data_controller:refreshEnhancedCapabilitiesForAll()
end

function ProgressSyncDeluxe:getOptionalDataDocuments()
    if not self.enhanced_data_controller then return {} end
    return self.enhanced_data_controller:getOptionalDataDocuments()
end

function ProgressSyncDeluxe:nudgeOptionalData(server, document, immediate)
    if not self.enhanced_data_controller then return end
    return self.enhanced_data_controller:nudgeOptionalData(server, document, immediate)
end

function ProgressSyncDeluxe:nudgeOptionalDataAll(immediate)
    if not self.enhanced_data_controller then return end
    return self.enhanced_data_controller:nudgeOptionalDataAll(immediate)
end

function ProgressSyncDeluxe:syncOptionalDataForServer(server, document, callback)
    if not self.enhanced_data_controller then
        if callback then callback(false) end
        return
    end
    return self.enhanced_data_controller:syncOptionalDataForServer(server, document, callback)
end

function ProgressSyncDeluxe:syncVocabularyForServer(server, callback)
    if not self.vocabulary_sync_service then
        if callback then callback(false, nil, "Vocabulary Builder sync is unavailable") end
        return
    end
    return self.vocabulary_sync_service:sync(server, callback)
end

function ProgressSyncDeluxe:syncReadingStatisticsForServer(server, callback)
    if not self.reading_statistics_sync_service then
        if callback then callback(false, nil, "Reading statistics sync is unavailable") end
        return
    end
    return self.reading_statistics_sync_service:sync(server, callback)
end

function ProgressSyncDeluxe:syncReadingStatisticsForAll()
    self:nudgeOptionalDataAll(false)
end

function ProgressSyncDeluxe:completeSettingsRestoreRequest(server, client, registration, request_id, status, message, callback)
    if not self.restore_migration_controller then
        if callback then callback(false, nil, "Settings restore controller unavailable") end
        return
    end
    return self.restore_migration_controller:completeSettingsRestoreRequest(server, client, registration, request_id, status, message, callback)
end

function ProgressSyncDeluxe:showSettingsRestorePrompt(server, restore, client, registration)
    if not self.restore_migration_controller then return false end
    return self.restore_migration_controller:showSettingsRestorePrompt(server, restore, client, registration)
end

function ProgressSyncDeluxe:checkSettingsRestoreForServer(server, client, callback)
    if not self.restore_migration_controller then
        if callback then callback(false, nil, "Settings restore controller unavailable") end
        return
    end
    return self.restore_migration_controller:checkSettingsRestoreForServer(server, client, callback)
end

function ProgressSyncDeluxe:completeDeluxeProfileRestoreRequest(server, client, registration, request_id, status, message, callback)
    if not self.restore_migration_controller then
        if callback then callback(false, nil, "Deluxe-Sync restore controller unavailable") end
        return
    end
    return self.restore_migration_controller:completeDeluxeProfileRestoreRequest(server, client, registration, request_id, status, message, callback)
end

function ProgressSyncDeluxe:showDeluxeProfileRestorePrompt(server, restore, client, registration)
    if not self.restore_migration_controller then return false end
    return self.restore_migration_controller:showDeluxeProfileRestorePrompt(server, restore, client, registration)
end

function ProgressSyncDeluxe:checkDeluxeProfileRestoreForServer(server, client, callback)
    if not self.restore_migration_controller then
        if callback then callback(false, nil, "Deluxe-Sync restore controller unavailable", false) end
        return
    end
    return self.restore_migration_controller:checkDeluxeProfileRestoreForServer(server, client, callback)
end

function ProgressSyncDeluxe:applyCurrentDeluxeProfileRestore(server, client, registration, expected_profile_id, callback)
    if not self.restore_migration_controller then
        if callback then callback(false, nil, _("Deluxe-Sync restore controller unavailable")) end
        return
    end
    return self.restore_migration_controller:applyCurrentDeluxeProfileRestore(server, client, registration, expected_profile_id, callback)
end

function ProgressSyncDeluxe:showDeluxeProfileCandidatePrompt(server, candidate, client, registration)
    if not self.restore_migration_controller then return false end
    return self.restore_migration_controller:showDeluxeProfileCandidatePrompt(server, candidate, client, registration)
end

function ProgressSyncDeluxe:checkDeluxeProfileCandidateForServer(server, client, callback)
    if not self.restore_migration_controller then
        if callback then callback(false, nil, "Deluxe-Sync restore controller unavailable") end
        return
    end
    return self.restore_migration_controller:checkDeluxeProfileCandidateForServer(server, client, callback)
end

function ProgressSyncDeluxe:checkDeluxeProfileMigrationForServer(server, client)
    if not self.restore_migration_controller then return end
    return self.restore_migration_controller:checkDeluxeProfileMigrationForServer(server, client)
end

function ProgressSyncDeluxe:syncSettingsBackupForServer(server, callback)
    if not self.settings_backup_sync_service then
        if callback then callback(false, nil, "Settings backup sync is unavailable") end
        return
    end
    return self.settings_backup_sync_service:sync(server, callback)
end

function ProgressSyncDeluxe:syncDeluxeProfileBackupForServer(server, callback)
    if not self.deluxe_profile_backup_sync_service then
        if callback then callback(false, nil, "Deluxe-Sync config backup is unavailable") end
        return
    end
    return self.deluxe_profile_backup_sync_service:sync(server, callback)
end

function ProgressSyncDeluxe:syncSettingsBackupsForAll()
    self:nudgeOptionalDataAll(false)
end

function ProgressSyncDeluxe:getLocalAnnotations()
    if not self.annotation_sync_service then return {} end
    return self.annotation_sync_service:getLocalAnnotations()
end

function ProgressSyncDeluxe:persistLocalAnnotations(annotations)
    if not self.annotation_sync_service then return end
    return self.annotation_sync_service:persistLocalAnnotations(annotations)
end

function ProgressSyncDeluxe:syncAnnotationsForServer(server, document, callback)
    if not self.annotation_sync_service then
        if callback then callback(false, nil, "Annotation sync is unavailable") end
        return
    end
    return self.annotation_sync_service:sync(server, document, callback)
end

function ProgressSyncDeluxe:getDeviceRegistrationPayload()
    local koreader_device_id
    if G_reader_settings and G_reader_settings.readSetting then
        koreader_device_id = G_reader_settings:readSetting("device_id")
        if koreader_device_id ~= nil then koreader_device_id = tostring(koreader_device_id) end
    end

    local koreader_version
    if Version and Version.getCurrentRevision then
        local ok, value = pcall(Version.getCurrentRevision, Version)
        if ok and value ~= nil then koreader_version = tostring(value) end
    end

    local platform_parts = {}
    if jit and jit.os then table.insert(platform_parts, tostring(jit.os)) end
    if jit and jit.arch then table.insert(platform_parts, tostring(jit.arch)) end

    return {
        legacy_device_id = tostring(self.store.data.device_id),
        koreader_device_id = koreader_device_id,
        display_name = tostring(Device.model or "KOReader device"),
        model = tostring(Device.model or "KOReader device"),
        platform = #platform_parts > 0 and table.concat(platform_parts, "/") or nil,
        koreader_version = koreader_version,
        deluxe_sync_version = PLUGIN_VERSION,
        capabilities = {
            standard_kosync = true,
            rich_progress = true,
            logical_books = true,
            book_feedback = true,
            book_feedback_version = 1,
            device_registration = true,
            annotations = true,
            reading_statistics = true,
            settings_backups = true,
            deluxe_profiles = true,
            deluxe_profile_restore = true,
        },
    }
end

function ProgressSyncDeluxe:heartbeatDevice(server, client, force, callback)
    callback = callback or function() end
    if not self:serverSupportsDeviceRegistration(server) then
        callback(false, nil, nil)
        return
    end
    if not force and self.device_heartbeat_sent[server.id] then
        callback(true, 200, nil)
        return
    end

    client = client or self:newClient(server)
    client:registerDevice(server.username, server.userkey, self:getDeviceRegistrationPayload(), function(ok, status, body)
        local registered = ok and status == 200
        self.store:setCapability(server.id, "device_registered", registered)
        if registered then self.device_heartbeat_sent[server.id] = true end
        if DiagnosticLog then
            DiagnosticLog.log("device heartbeat", serverLabel(server), "status", status or "nil", "registered", registered)
        end
        callback(registered, status, body)
    end)
end

function ProgressSyncDeluxe:newClient(server)
    return SyncClient:new{
        custom_url = server.url,
        service_spec = self.path .. "/api.json",
    }
end

function ProgressSyncDeluxe:serverSupportsClientNotices(server)
    local capabilities = server and server.capabilities or {}
    return capabilities.client_notices == true
        and (tonumber(capabilities.client_notices_version) or 0) >= 1
end

function ProgressSyncDeluxe:refreshClientNotices(server)
    if not self.store or not server or server.enabled == false or not self:serverSupportsClientNotices(server) then return end
    self.client_notice_in_flight = self.client_notice_in_flight or {}
    if self.client_notice_in_flight[server.id] then return end
    self.client_notice_in_flight[server.id] = true
    self:newClient(server):getClientNotices(server.username, server.userkey, function(ok, status, body)
        self.client_notice_in_flight[server.id] = nil
        if status == 404 or status == 405 then
            self.store:setCapability(server.id, "client_notices", false)
            self.store:saveClientNotices(server.id, {}, os.time())
            return
        end
        if not ok or status ~= 200 then
            if DiagnosticLog then DiagnosticLog.log("client notices failure", serverLabel(server), "status", status, "body", body) end
            return
        end
        local data = decode(body) or {}
        local notices = type(data.notices) == "table" and data.notices or {}
        local now = os.time()
        local state = self.store:saveClientNotices(server.id, notices, now)
        local due = {}
        local due_needs_attention = false
        for _, notice in ipairs(notices) do
            if type(notice) == "table" and type(notice.id) == "string" and notice.id ~= "" then
                local severity = tostring(notice.severity or "info")
                local last_shown = tonumber(state.last_shown[notice.id]) or 0
                if now - last_shown >= CLIENT_NOTICE_REPEAT_SECONDS then
                    due[#due + 1] = notice
                    if severity == "warning" or severity == "error" then due_needs_attention = true end
                end
            end
        end
        if #due == 0 then return end
        local lines = {}
        for _, notice in ipairs(due) do
            self.store:markClientNoticeShown(server.id, notice.id, now)
            local title = tostring(notice.title or "")
            local message = tostring(notice.message or "")
            if title ~= "" and message ~= "" then
                lines[#lines + 1] = title .. ": " .. message
            elseif message ~= "" then
                lines[#lines + 1] = message
            elseif title ~= "" then
                lines[#lines + 1] = title
            end
        end
        if #lines == 0 then return end
        local heading = due_needs_attention
            and T(_("%1 synced, but the server needs attention:"), serverLabel(server))
            or T(_("%1 has a server notice:"), serverLabel(server))
        local message = heading .. "\n\n" .. table.concat(lines, "\n\n")
        local options = { text = message }
        if not due_needs_attention then options.timeout = 6 end
        UIManager:show(InfoMessage:new(options))
    end)
end

function ProgressSyncDeluxe:scheduleClientNoticesRefresh(server, delay)
    if not self.store or not server or not self:serverSupportsClientNotices(server) then return end
    self.client_notice_scheduled = self.client_notice_scheduled or {}
    if self.client_notice_scheduled[server.id] then return end
    local action
    action = function()
        if self.client_notice_scheduled[server.id] ~= action then return end
        self.client_notice_scheduled[server.id] = nil
        self:refreshClientNotices(server)
    end
    self.client_notice_scheduled[server.id] = action
    UIManager:scheduleIn(tonumber(delay) or 1, action)
end

function ProgressSyncDeluxe:cancelQueueRetry()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:cancelQueueRetry()
end

function ProgressSyncDeluxe:scheduleQueueRetry()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:scheduleQueueRetry()
end

function ProgressSyncDeluxe:queueForServer(server, item)
    self.queue:push(item)
    self:scheduleQueueRetry()
    local count = self.queue:count(server.id)
    if count < QUEUE_DISABLE_THRESHOLD then return false end

    self.store:setServerEnabled(server.id, false)
    self.queue:removeServer(server.id)
    self:scheduleQueueRetry()
    if DiagnosticLog then DiagnosticLog.log("server auto disabled", serverLabel(server), "queued", count) end
    UIManager:show(InfoMessage:new{
        text = T(_("%1 automatically disabled after %2 queued updates."), serverLabel(server), QUEUE_DISABLE_THRESHOLD),
    })
    return true
end

function ProgressSyncDeluxe:pushAll(interactive)
    if DiagnosticLog then DiagnosticLog.log("push all", "interactive", interactive and true or false) end
    if self.preview then
        if DiagnosticLog then DiagnosticLog.log("push blocked", "preview active") end
        if interactive then UIManager:show(InfoMessage:new{ text = _("Preview mode is active. Exit or accept the preview before syncing.") }) end
        return
    end
    local canonical_document = self:getDocumentDigest()
    local progress, percentage = self:getCurrentProgress()
    local progress_event_timestamp = os.time()
    local metadata = self:getMetadata()
    local rich_position = self:getRichPosition(progress, percentage)
    local book_feedback = self:getBookFeedback()
    local servers = self.store:getEnabledServers()
    local pending = #servers
    local success, queued, failed, not_tracked = 0, 0, 0, 0
    if pending == 0 then return end

    local function done()
        pending = pending - 1
        if pending == 0 and interactive then
            self:showStatusCard(_("Deluxe-Sync"), {
                { label = _("Status"), value = _("Push Complete") },
                { label = _("Synced"), value = tostring(success) },
                { label = _("KOSync Errors"), value = tostring(not_tracked) },
                { label = _("Queued"), value = tostring(queued) },
                { label = _("Failed"), value = tostring(failed) },
            })
        end
    end

    for unused_index, server in ipairs(servers) do
        local document = self:getServerDocumentDigest(server) or canonical_document
        local payload = {
            document = document,
            progress = tostring(progress),
            percentage = percentage,
            device = Device.model,
            device_id = self.store.data.device_id,
        }
        local capabilities = server.capabilities or {}
        if self:serverSupportsProgressEventTimestamp(server) then
            payload.event_timestamp = progress_event_timestamp
            if DiagnosticLog then DiagnosticLog.log("progress event timestamp", serverLabel(server), "event_timestamp", progress_event_timestamp) end
        end
        if server.metadata_enabled ~= false and capabilities.metadata_compatible ~= false then
            payload.metadata = metadata
        end
        if self:serverSupportsRichProgress(server) and rich_position then
            payload.position = rich_position
        end

        self:applyBookFeedbackToPayload(server, payload, book_feedback)

        local function finalizeFailure(status, body, failed_payload)
            if isBookNotFoundResponse(status, body) then
                not_tracked = not_tracked + 1
                self.queue:remove(server.id, document)
                self:scheduleQueueRetry()
                if DiagnosticLog then DiagnosticLog.log("push not tracked", serverLabel(server), "document", document, "status", status, "body", body) end
            elseif status == 401 then
                failed = failed + 1
            else
                queued = queued + 1
                local now = os.time()
                local auto_disabled = self:queueForServer(server, {
                    server_id = server.id,
                    document = document,
                    payload = failed_payload,
                    event_timestamp = progress_event_timestamp,
                    reason = queueFailureReason(status, body),
                    last_status = status,
                    failure_count = 1,
                    last_attempt_at = now,
                    next_retry_at = now + QUEUE_RETRY_DELAYS[1],
                })
                if auto_disabled then
                    queued = queued - 1
                    failed = failed + 1
                end
            end
            done()
        end

        local function send(current_payload, is_metadata_probe)
            self:newClient(server):updateProgress(server.username, server.userkey, current_payload, function(ok, status, body)
                if ok and (status == 200 or status == 202) then
                    success = success + 1
                    self.queue:remove(server.id, document)
                    self:scheduleQueueRetry()
                    if is_metadata_probe then
                        self.store:setCapability(server.id, "metadata_compatible", true)
                    end
                    self:heartbeatDevice(server, nil, false)
                    self:nudgeOptionalData(server, payload.document, false)
                    self:scheduleClientNoticesRefresh(server, 1)

                    done()
                elseif is_metadata_probe and (status == 400 or status == 404 or status == 422) then
                    if DiagnosticLog then DiagnosticLog.log("metadata fallback", serverLabel(server), "status", status, "body", body) end
                    self.store:setCapability(server.id, "metadata_compatible", false)
                    local fallback_payload = {
                        document = current_payload.document,
                        progress = current_payload.progress,
                        percentage = current_payload.percentage,
                        device = current_payload.device,
                        device_id = current_payload.device_id,
                    }
                    if self:serverSupportsProgressEventTimestamp(server) and current_payload.event_timestamp ~= nil then
                        fallback_payload.event_timestamp = current_payload.event_timestamp
                    end
                    if self:serverSupportsRichProgress(server) and current_payload.position ~= nil then
                        fallback_payload.position = current_payload.position
                    end
                    if current_payload.rating_present ~= nil then fallback_payload.rating_present = current_payload.rating_present end
                    if current_payload.rating ~= nil then fallback_payload.rating = current_payload.rating end
                    if current_payload.review_note_present ~= nil then fallback_payload.review_note_present = current_payload.review_note_present end
                    if current_payload.review_note ~= nil then fallback_payload.review_note = current_payload.review_note end
                    send(fallback_payload, false)
                else
                    finalizeFailure(status, body, current_payload)
                end
            end)
        end

        send(payload, payload.metadata ~= nil)
    end
end

function ProgressSyncDeluxe:queueCurrentProgress()
    if self.preview then return end
    local canonical_document = self:getDocumentDigest()
    local progress, percentage = self:getCurrentProgress()
    local progress_event_timestamp = os.time()
    if not canonical_document or progress == nil then return end
    local metadata = self:getMetadata()
    local rich_position = self:getRichPosition(progress, percentage)
    local book_feedback = self:getBookFeedback()
    for unused_index, server in ipairs(self.store:getEnabledServers()) do
        local document = self:getServerDocumentDigest(server) or canonical_document
        local payload = {
            document = document,
            progress = tostring(progress),
            percentage = percentage,
            device = Device.model,
            device_id = self.store.data.device_id,
        }
        local capabilities = server.capabilities or {}
        if self:serverSupportsProgressEventTimestamp(server) then
            payload.event_timestamp = progress_event_timestamp
            if DiagnosticLog then DiagnosticLog.log("progress event timestamp", serverLabel(server), "event_timestamp", progress_event_timestamp) end
        end
        if server.metadata_enabled ~= false and capabilities.metadata_compatible ~= false then
            payload.metadata = metadata
        end
        if self:serverSupportsRichProgress(server) and rich_position then
            payload.position = rich_position
        end
        self:applyBookFeedbackToPayload(server, payload, book_feedback)
        self:queueForServer(server, {
            server_id = server.id,
            document = document,
            payload = payload,
            event_timestamp = progress_event_timestamp,
            reason = _("Waiting for connection"),
        })
    end
    if DiagnosticLog then DiagnosticLog.log("auto sync", "queued offline progress", "servers", #self.store:getEnabledServers()) end
end

function ProgressSyncDeluxe:showQueuedUpdates()
    local items = self.queue:list()
    local rows = {
        { label = _("Queued"), value = tostring(#items) },
    }
    if #items == 0 then
        table.insert(rows, { label = _("Status"), value = _("No queued updates") })
    else
        for unused_index, item in ipairs(items) do
            local server = self.store:getServer(item.server_id)
            local payload = item.payload or {}
            local metadata = payload.metadata or {}
            local book = metadata.title or metadata.filename or item.document or _("Unknown document")
            local reason = item.reason or _("Pending retry")
            table.insert(rows, { label = server and serverLabel(server) or _("Unknown server"), value = book .. " — " .. reason })
        end
    end
    local actions
    if #items > 0 then
        actions = {
            { text = _("Retry Queued Updates"), callback = function(card)
                UIManager:close(card)
                self:retryQueue(true, function() self:showQueuedUpdates() end, "manual")
            end },
            { text = _("Close") },
        }
    end
    self:showStatusCard(_("Queued Updates"), rows, actions)
end

function ProgressSyncDeluxe:retryQueue(interactive, complete_callback, retry_mode)
    if not self.progress_lifecycle_controller then
        if complete_callback then complete_callback() end
        return
    end
    return self.progress_lifecycle_controller:retryQueue(interactive, complete_callback, retry_mode)
end

function ProgressSyncDeluxe:handleAutomaticPull(results)
    local current_progress, local_percentage = self:getCurrentProgress()
    local group, direction = Resolver.chooseAutomatic(results, current_progress, local_percentage, self.last_page_turn_timestamp)
    if not group or direction == "same" then return end

    local setting_name = direction == "newer" and "sync_forward" or "sync_backward"
    local strategy = self.store.data.settings[setting_name] or (direction == "newer" and "prompt" or "never")
    if DiagnosticLog then
        DiagnosticLog.log("auto pull decision", "direction", direction, "strategy", strategy, "remote", group.percentage or "", "local", local_percentage or "")
    end

    if strategy == "silent" then
        self:applyRemotePosition(group)
    elseif strategy == "prompt" then
        self:showPullResults(results)
    end
end

function ProgressSyncDeluxe:pullAll(interactive)
    if interactive == nil then interactive = true end
    if self.auto_pull_in_flight then return end
    self.auto_pull_in_flight = not interactive
    if DiagnosticLog then DiagnosticLog.log("pull all", interactive and "manual" or "automatic") end
    local canonical_document = self:getDocumentDigest()
    local servers = self.store:getEnabledServers()
    local requests = {}
    local results = {}

    if interactive then
        self.pull_status = InfoMessage:new{
            text = T(_("Querying %1 sync servers..."), #servers),
        }
        UIManager:show(self.pull_status)
    end

    for unused_index, server in ipairs(servers) do
        local seen = {}
        local function addRequest(document, is_alias)
            if document and not seen[document] then
                seen[document] = true
                table.insert(requests, {
                    server = server,
                    document = document,
                    is_alias = is_alias and true or false,
                })
            end
        end
        addRequest(self:getServerDocumentDigest(server) or canonical_document, false)
        for unused_index, alias in ipairs(self.store:getAliases(canonical_document)) do
            if alias.server_id == server.id then addRequest(alias.remote_document, true) end
        end
    end

    local pending = #requests
    if pending == 0 then
        self.auto_pull_in_flight = false
        if self.pull_status then UIManager:close(self.pull_status); self.pull_status = nil end
        if interactive then UIManager:show(InfoMessage:new{ text = _("No enabled sync servers could be queried.") }) end
        return
    end

    local function finish()
        pending = pending - 1
        logger.dbg("Deluxe-Sync pull pending:", pending, "results:", #results)
        if pending == 0 then
            if self.pull_status then
                UIManager:close(self.pull_status)
                self.pull_status = nil
            end
            -- Do not open a new modal from the same async HTTP callback tick in
            -- which we just closed the querying message. Some KOReader/device
            -- combinations finish cleaning up that window after the callback,
            -- which can discard a dialog shown immediately here.
            self.auto_pull_in_flight = false
            UIManager:nextTick(function()
                local ok, err = xpcall(function()
                    if interactive then
                        logger.dbg("Deluxe-Sync: building Sync Card with", #results, "results")
                        self:showPullResults(results)
                    else
                        self:handleAutomaticPull(results)
                    end
                end, debug.traceback)
                if not ok then
                    logger.err("Deluxe-Sync: failed to process pull results:", err)
                    if interactive then
                        UIManager:show(InfoMessage:new{
                            text = _("Deluxe-Sync could not display the Sync Card.") .. "\n\n" .. tostring(err),
                        })
                    end
                end
            end)
        end
    end

    for unused_index, request in ipairs(requests) do
        local server = request.server
        self:newClient(server):getProgress(server.username, server.userkey, request.document, function(ok, status, body)
            local data = decode(body) or {}
            local has_remote_record = status == 200 and (data.progress ~= nil or data.percentage ~= nil or data.timestamp ~= nil)
            if ok and status == 200 then
                self:nudgeOptionalData(server, request.document, false)
                self:scheduleClientNoticesRefresh(server, 1)
            end
            if DiagnosticLog then
                DiagnosticLog.log(
                    "pull result",
                    serverLabel(server),
                    "status", status,
                    "document", request.document,
                    "has_record", has_remote_record,
                    "decoded", data,
                    "raw", body
                )
            end
            logger.dbg("Deluxe-Sync pull:", serverLabel(server), "status", status, "document", request.document, "progress", data.progress, "percentage", data.percentage)
            local display_percentage = server.ui_test_percentage or data.percentage
            table.insert(results, {
                ok = ok and has_remote_record,
                status = status,
                server = server,
                document = request.document,
                is_alias = request.is_alias,
                progress = data.progress,
                group_key = server.ui_test_group_key,
                percentage = display_percentage,
                position = type(data.position) == "table" and data.position or nil,
                timestamp = data.timestamp,
                device = data.device,
                device_id = data.device_id,
                empty = ok and status == 200 and not has_remote_record,
            })
            finish()
        end)
    end
end

function ProgressSyncDeluxe:showPullResults(results)
    self.last_pull_results = results
    if DiagnosticLog then DiagnosticLog.log("sync card", "results", #results) end
    local groups = Resolver.group(results)
    local failures = {}
    local empty_results = {}
    for unused_index, result_item in ipairs(Resolver.failures(results)) do
        if result_item.empty then
            table.insert(empty_results, result_item)
        else
            table.insert(failures, result_item)
        end
    end

    local current_progress, local_percentage = self:getCurrentProgress()
    local metadata = self:getMetadata() or {}
    local title = metadata.title or self:getFileName() or _("Current book")
    local author = metadata.authors or _("Unknown author")
    if type(author) == "table" then author = table.concat(author, ", ") end
    local filename = metadata.filename or self:getFileName() or _("Unknown filename")

    local title_face = Font:getFace("smallinfofontbold")
    local book_title_face = Font:getFace("smallinfofontbold")
    local detail_face = Font:getFace("x_smallinfofont")
    local label_face = Font:getFace("smallinfofontbold")
    local footer_face = Font:getFace("xx_smallinfofont")

    self.pull_dialog = ButtonDialog:new{
        title = _("Deluxe-Sync"),
        title_align = "left",
        title_face = title_face,
        width_factor = 0.98,
        use_info_style = false,
        buttons = {
            {{
                text = _("Close — make no changes"),
                callback = function() UIManager:close(self.pull_dialog) end,
            }},
        },
    }

    local available_width = self.pull_dialog:getAddedWidgetAvailableWidth()
    local gap = math.max(8, math.floor(available_width * 0.025))
    local left_width = math.floor(available_width * 0.39)
    local right_width = available_width - left_width - gap
    local cover_max_width = math.max(80, left_width - 16)
    local cover_max_height = math.floor(Device.screen:getHeight() * 0.30)

    local left_column = VerticalGroup:new{ align = "center" }
    local thumbnail
    if self.ui.bookinfo and self.ui.document then
        local ok, cover = pcall(function() return self.ui.bookinfo:getCoverImage(self.ui.document) end)
        if ok then thumbnail = cover end
    end
    if thumbnail then
        local cover_width, cover_height = thumbnail:getWidth(), thumbnail:getHeight()
        if cover_width > cover_max_width or cover_height > cover_max_height then
            local scale = math.min(cover_max_width / cover_width, cover_max_height / cover_height)
            cover_width = math.max(1, math.floor(cover_width * scale))
            cover_height = math.max(1, math.floor(cover_height * scale))
            thumbnail = RenderImage:scaleBlitBuffer(thumbnail, cover_width, cover_height, true)
        end
        table.insert(left_column, CenterContainer:new{
            dimen = Geom:new{ w = left_width, h = cover_height },
            ImageWidget:new{ image = thumbnail, width = cover_width, height = cover_height },
        })
    else
        table.insert(left_column, DeluxeCoverPlaceholder.centered(cover_max_width, cover_max_height, { border = 1 }))
    end
    table.insert(left_column, VerticalSpan:new{ width = 4 })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(title),
        width = left_width,
        face = book_title_face,
        line_height = 0.2,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(author),
        width = left_width,
        face = detail_face,
        line_height = 0.15,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(filename),
        width = left_width,
        face = detail_face,
        line_height = 0.15,
        alignment = "center",
    })
    table.insert(left_column, VerticalSpan:new{ width = 5 })
    table.insert(left_column, TextBoxWidget:new{
        text = _("THIS DEVICE"),
        width = left_width,
        face = label_face,
        alignment = "center",
    })
    local local_ratio = math.max(0, math.min(1, tonumber(local_percentage) or 0))
    local local_bar = ProgressWidget:new{
        width = math.floor(left_width * 0.78),
        height = math.max(6, math.floor(Device.screen:getHeight() * 0.012)),
        percentage = local_ratio,
        ticks = nil,
        last = nil,
    }
    table.insert(left_column, CenterContainer:new{
        dimen = Geom:new{ w = left_width, h = local_bar:getSize().h },
        local_bar,
    })
    table.insert(left_column, TextBoxWidget:new{
        text = formatPercent(local_percentage),
        width = left_width,
        face = label_face,
        alignment = "center",
    })

    local remote_buttons = {}
    local remote_card_height = math.max(50, math.floor(Device.screen:getHeight() * 0.075))
    for group_index, group in ipairs(groups) do
        local selected_group = group
        local names = {}
        for server_index, result_item in ipairs(group.servers) do
            table.insert(names, serverLabel(result_item.server))
        end
        local timestamp = tonumber(group.timestamp) or 0
        local stamp = timestamp > 0 and os.date("%Y-%m-%d %H:%M", timestamp) or _("Unknown date")
        local label = T(_("%1\n%2 — %3"), stamp, formatPercent(group.percentage), table.concat(names, " + "))
        table.insert(remote_buttons, {{
            text = label,
            height = remote_card_height,
            background = Blitbuffer.COLOR_WHITE,
            font_face = "smallinfofont",
            callback = function()
                UIManager:close(self.pull_dialog)
                self:applyRemotePosition(selected_group)
            end,
            hold_callback = function()
                UIManager:close(self.pull_dialog)
                self:previewRemotePosition(selected_group)
            end,
        }})
    end

    if #remote_buttons == 0 then
        table.insert(remote_buttons, {{ text = _("No remote positions available."), enabled = false }})
    end

    local right_column = VerticalGroup:new{}
    table.insert(right_column, TextBoxWidget:new{
        text = _("REMOTE POSITIONS"),
        width = right_width,
        face = label_face,
        alignment = "center",
    })
    table.insert(right_column, VerticalSpan:new{ width = 3 })

    local scrollbar_width = ScrollableContainer:getScrollbarWidth()
    local remote_table_width = math.max(1, right_width - scrollbar_width)
    local remote_table = ButtonTable:new{
        buttons = remote_buttons,
        width = remote_table_width,
        show_parent = self.pull_dialog,
    }
    remote_table:setupGridScrollBehaviour()
    local remote_scroll_height = math.floor(Device.screen:getHeight() * 0.46)
    table.insert(right_column, ScrollableContainer:new{
        dimen = Geom:new{ w = right_width, h = remote_scroll_height },
        show_parent = self.pull_dialog,
        step_scroll_grid = remote_table:getStepScrollGrid(),
        remote_table,
    })
    local hidden_count = #empty_results + #failures
    if hidden_count > 0 then
        table.insert(right_column, VerticalSpan:new{ width = 3 })
        table.insert(right_column, TextBoxWidget:new{
            text = _("Servers with no progress record or no connection are not displayed."),
            width = right_width,
            face = footer_face,
            alignment = "center",
        })
    end
    table.insert(right_column, VerticalSpan:new{ width = 5 })
    table.insert(right_column, TextBoxWidget:new{
        text = _("Tap to Sync | Hold for Details"),
        width = right_width,
        face = footer_face,
        alignment = "center",
    })

    self.pull_dialog:addWidget(HorizontalGroup:new{
        align = "top",
        left_column,
        HorizontalSpan:new{ width = gap },
        right_column,
    })

    if DiagnosticLog then
        DiagnosticLog.log("sync card", "local", local_percentage, "current_progress", current_progress or "", "groups", #groups, "hidden", hidden_count)
    end
    suppressDialogContainerHolds(self.pull_dialog)
    UIManager:show(self.pull_dialog)
end

function ProgressSyncDeluxe:applyRemotePosition(group)
    if not group then return end
    local canonical = self:getDocumentDigest()
    local exact_match = false
    for unused_index, result_item in ipairs(group.servers or {}) do
        if result_item.document == canonical then
            exact_match = true
            break
        end
    end

    if exact_match and group.progress ~= nil then
        if DiagnosticLog then DiagnosticLog.log("pull apply", "mode", "exact", "progress", group.progress, "percentage", group.percentage or "") end
        if self.ui.document.info.has_pages then
            self.ui:handleEvent(Event:new("GotoPage", tonumber(group.progress)))
        else
            self.ui:handleEvent(Event:new("GotoXPointer", group.progress))
        end
        return
    end

    local ratio = tonumber(group.percentage) or 0
    if type(group.position) == "table" and tonumber(group.position.pctQ) then
        ratio = math.max(0, math.min(1, tonumber(group.position.pctQ) / 1000000))
    end
    local percent = math.floor(ratio * 100 + 0.5)
    if DiagnosticLog then DiagnosticLog.log("pull apply", "mode", "portable percentage fallback", "percentage", ratio, "percent", percent) end
    self.ui:handleEvent(Event:new("GotoPercent", percent))
end

function ProgressSyncDeluxe:captureBookLocation()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getBookLocation()
    end
    return { xpointer = self.ui.rolling:getBookLocation() }
end

function ProgressSyncDeluxe:restoreBookLocation(location)
    self.ui:handleEvent(Event:new("RestoreBookLocation", location))
end

function ProgressSyncDeluxe:showPreviewShortcut()
    if not self.preview or self.preview_shortcut then return end

    local screen_w = Device.screen:getWidth()
    local screen_h = Device.screen:getHeight()
    local margin = math.max(8, Device.screen:scaleBySize(8))
    local offset = Device.screen:scaleBySize(30)
    local button_w = math.min(math.floor(screen_w * 0.32), Device.screen:scaleBySize(150))
    local button_h = math.max(38, Device.screen:scaleBySize(38))
    local button = Button:new{
        text = _("Preview Menu"),
        width = button_w,
        height = button_h,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        text_font_face = "smallinfofont",
        text_font_size = 16,
        text_font_bold = true,
        callback = function()
            if DiagnosticLog then DiagnosticLog.log("preview shortcut", "tap") end
            self:showPreviewControls()
        end,
    }

    self.preview_shortcut = WidgetContainer:new{
        dimen = Geom:new{
            x = math.max(margin, screen_w - button_w - margin - offset),
            y = math.max(margin, screen_h - button_h - margin - offset),
            w = button_w,
            h = button_h,
        },
        button,
    }
    self[1] = self.preview_shortcut
    self.dimen = nil
    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("progress_sync_deluxe_preview_shortcut", self.preview_shortcut)
    end
    if DiagnosticLog then DiagnosticLog.log("preview shortcut", "show") end
    UIManager:setDirty(self.ui, "ui")
end

function ProgressSyncDeluxe:hidePreviewShortcut()
    if not self.preview_shortcut then return end
    local shortcut = self.preview_shortcut
    self.preview_shortcut = nil
    self[1] = nil
    self.dimen = nil
    if self.ui and self.ui.view and self.ui.view.view_modules
        and self.ui.view.view_modules.progress_sync_deluxe_preview_shortcut == shortcut then
        self.ui.view.view_modules.progress_sync_deluxe_preview_shortcut = nil
    end
    if shortcut.free then shortcut:free() end
    if DiagnosticLog then DiagnosticLog.log("preview shortcut", "hide") end
    UIManager:setDirty(self.ui, "ui")
end

function ProgressSyncDeluxe:previewRemotePosition(group)
    if DiagnosticLog then DiagnosticLog.log("preview", "start", "target", group.percentage or "") end
    if self.preview then return end
    local original_progress, original_percentage = self:getCurrentProgress()
    self.preview = {
        original_location = self:captureBookLocation(),
        original_document = self:getDocumentDigest(),
        original_progress = original_progress,
        original_percentage = original_percentage,
        remote = group,
    }
    self:showPreviewShortcut()
    local percent = math.floor((tonumber(group.percentage) or 0) * 100 + 0.5)
    self.ui:handleEvent(Event:new("GotoPercent", percent))
    UIManager:nextTick(function() self:showPreviewControls() end)
end

function ProgressSyncDeluxe:showPreviewControls()
    if not self.preview then return end

    local names = {}
    for unused_index, result in ipairs(self.preview.remote.servers or {}) do
        table.insert(names, serverLabel(result.server))
    end
    local server_names = #names > 0 and table.concat(names, " + ") or _("Remote server")
    local remote_timestamp = tonumber(self.preview.remote.timestamp) or 0
    local remote_stamp = remote_timestamp > 0 and os.date("%Y-%m-%d %H:%M", remote_timestamp) or _("Unknown date")

    local metadata = self:getMetadata() or {}
    local title = metadata.title or self:getFileName() or _("Current book")
    local author = metadata.authors or _("Unknown author")
    if type(author) == "table" then author = table.concat(author, ", ") end
    local filename = metadata.filename or self:getFileName() or _("Unknown filename")

    local title_face = Font:getFace("smallinfofontbold")
    local book_title_face = Font:getFace("smallinfofontbold")
    local detail_face = Font:getFace("x_smallinfofont")
    local label_face = Font:getFace("smallinfofontbold")

    self.preview_dialog = ButtonDialog:new{
        title = _("Deluxe-Sync"),
        title_align = "left",
        title_face = title_face,
        width_factor = 0.98,
        use_info_style = false,
        dismissable = false,
        buttons = {
            {{
                text = _("Hide to see preview"),
                callback = function()
                    UIManager:close(self.preview_dialog)
                end,
            }, {
                text = _("Back to Pull Results"),
                callback = function()
                    UIManager:close(self.preview_dialog)
                    self:returnToPullResults()
                end,
            }},
        },
    }

    local available_width = self.preview_dialog:getAddedWidgetAvailableWidth()
    local gap = math.max(8, math.floor(available_width * 0.025))
    local left_width = math.floor(available_width * 0.39)
    local right_width = available_width - left_width - gap
    local cover_max_width = math.max(80, left_width - 16)
    local cover_max_height = math.floor(Device.screen:getHeight() * 0.30)

    local left_column = VerticalGroup:new{ align = "center" }
    local thumbnail
    if self.ui.bookinfo and self.ui.document then
        local ok, cover = pcall(function() return self.ui.bookinfo:getCoverImage(self.ui.document) end)
        if ok then thumbnail = cover end
    end
    if thumbnail then
        local cover_width, cover_height = thumbnail:getWidth(), thumbnail:getHeight()
        if cover_width > cover_max_width or cover_height > cover_max_height then
            local scale = math.min(cover_max_width / cover_width, cover_max_height / cover_height)
            cover_width = math.max(1, math.floor(cover_width * scale))
            cover_height = math.max(1, math.floor(cover_height * scale))
            thumbnail = RenderImage:scaleBlitBuffer(thumbnail, cover_width, cover_height, true)
        end
        table.insert(left_column, CenterContainer:new{
            dimen = Geom:new{ w = left_width, h = cover_height },
            ImageWidget:new{ image = thumbnail, width = cover_width, height = cover_height },
        })
    else
        table.insert(left_column, DeluxeCoverPlaceholder.centered(cover_max_width, cover_max_height, { border = 1 }))
    end

    table.insert(left_column, VerticalSpan:new{ width = 3 })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(title),
        width = left_width,
        face = book_title_face,
        line_height = 0.2,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(author),
        width = left_width,
        face = detail_face,
        line_height = 0.15,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(filename),
        width = left_width,
        face = detail_face,
        line_height = 0.15,
        alignment = "center",
    })

    table.insert(left_column, VerticalSpan:new{ width = 5 })
    table.insert(left_column, TextBoxWidget:new{
        text = _("THIS DEVICE"),
        width = left_width,
        face = label_face,
        alignment = "center",
    })
    local original_ratio = math.max(0, math.min(1, tonumber(self.preview.original_percentage) or 0))
    local original_bar = ProgressWidget:new{
        width = math.floor(left_width * 0.78),
        height = math.max(6, math.floor(Device.screen:getHeight() * 0.012)),
        percentage = original_ratio,
        ticks = nil,
        last = nil,
    }
    table.insert(left_column, CenterContainer:new{
        dimen = Geom:new{ w = left_width, h = original_bar:getSize().h },
        original_bar,
    })
    table.insert(left_column, TextBoxWidget:new{
        text = formatPercent(self.preview.original_percentage),
        width = left_width,
        face = label_face,
        alignment = "center",
    })

    local right_column = VerticalGroup:new{}
    table.insert(right_column, TextBoxWidget:new{
        text = _("REMOTE POSITION PREVIEW"),
        width = right_width,
        face = label_face,
        alignment = "center",
    })
    table.insert(right_column, VerticalSpan:new{ width = 5 })

    local remote_label_face = Font:getFace("smallinfofont", 16)
    local remote_value_face = Font:getFace("smallinfofontbold", 16)
    local remote_padding = math.max(6, Device.screen:scaleBySize(6))
    local remote_inner_width = math.max(1, right_width - 2 - remote_padding * 2)
    local remote_label_width = math.floor(remote_inner_width * 0.30)
    local remote_value_width = math.max(1, remote_inner_width - remote_label_width)
    local remote_rows = VerticalGroup:new{ align = "left" }
    local function addRemoteRow(label, value)
        table.insert(remote_rows, HorizontalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text = label .. ":",
                width = remote_label_width,
                face = remote_label_face,
                alignment = "left",
            },
            TextBoxWidget:new{
                text = value,
                width = remote_value_width,
                face = remote_value_face,
                alignment = "left",
            },
        })
    end
    addRemoteRow(_("Last Sync"), remote_stamp)
    addRemoteRow(_("Position"), formatPercent(self.preview.remote.percentage))
    addRemoteRow(_("Server"), server_names)
    local remote_content = LeftContainer:new{
        dimen = Geom:new{ w = remote_inner_width, h = remote_rows:getSize().h },
        remote_rows,
    }
    table.insert(right_column, FrameContainer:new{
        width = right_width,
        bordersize = 1,
        radius = math.max(6, Device.screen:scaleBySize(6)),
        padding = remote_padding,
        remote_content,
    })

    table.insert(right_column, VerticalSpan:new{ width = 12 })
    table.insert(right_column, TextBoxWidget:new{
        text = _("ACTIONS"),
        width = right_width,
        face = label_face,
        alignment = "left",
    })
    table.insert(right_column, VerticalSpan:new{ width = 4 })

    local action_height = math.max(50, math.floor(Device.screen:getHeight() * 0.075))
    local function addAction(text, callback)
        table.insert(right_column, ButtonTable:new{
            buttons = {{ {
                text = text,
                height = action_height,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                font_face = "smallinfofontbold",
                callback = callback,
            } }},
            width = right_width,
            show_parent = self.preview_dialog,
        })
        table.insert(right_column, VerticalSpan:new{ width = 4 })
    end

    addAction(_("Inspect / adjust position"), function()
        UIManager:close(self.preview_dialog)
    end)
    addAction(_("Accept this position"), function()
        UIManager:close(self.preview_dialog)
        self:showPreviewDecision()
    end)

    self.preview_dialog:addWidget(HorizontalGroup:new{
        align = "top",
        left_column,
        HorizontalSpan:new{ width = gap },
        right_column,
    })

    if DiagnosticLog then
        DiagnosticLog.log("preview card", "show", "remote", self.preview.remote.percentage or "", "original", self.preview.original_percentage or "", "servers", server_names)
    end
    suppressDialogContainerHolds(self.preview_dialog)
    UIManager:show(self.preview_dialog)
end

function ProgressSyncDeluxe:showPreviewDecision()
    if not self.preview then return end

    local _ignored, percentage = self:getCurrentProgress()
    local original_percentage = self.preview.original_percentage or 0
    local metadata = self:getMetadata() or {}
    local title = metadata.title or self:getFileName() or _("Current book")
    local author = metadata.authors or _("Unknown author")
    if type(author) == "table" then author = table.concat(author, ", ") end
    local filename = metadata.filename or self:getFileName() or _("Unknown filename")

    local title_face = Font:getFace("smallinfofontbold")
    local book_title_face = Font:getFace("smallinfofontbold")
    local detail_face = Font:getFace("x_smallinfofont")
    local label_face = Font:getFace("smallinfofontbold")

    self.preview_decision_dialog = ButtonDialog:new{
        title = _("Deluxe-Sync"),
        title_align = "left",
        title_face = title_face,
        width_factor = 0.98,
        use_info_style = false,
        dismissable = false,
        -- ButtonDialog derives its title/content width from the footer ButtonTable,
        -- so keep a real Back action here instead of an empty footer.
        buttons = {{ {
            text = _("Back to Preview"),
            font_face = "smallinfofontbold",
            callback = function()
                UIManager:close(self.preview_decision_dialog)
                self:showPreviewControls()
            end,
        } }},
    }

    local available_width = self.preview_decision_dialog:getAddedWidgetAvailableWidth()
    local gap = math.max(8, math.floor(available_width * 0.025))
    local left_width = math.floor(available_width * 0.39)
    local right_width = available_width - left_width - gap
    local cover_max_width = math.max(80, left_width - 16)
    local cover_max_height = math.floor(Device.screen:getHeight() * 0.30)

    local left_column = VerticalGroup:new{ align = "center" }
    local thumbnail
    if self.ui.bookinfo and self.ui.document then
        local ok, cover = pcall(function() return self.ui.bookinfo:getCoverImage(self.ui.document) end)
        if ok then thumbnail = cover end
    end
    if thumbnail then
        local cover_width, cover_height = thumbnail:getWidth(), thumbnail:getHeight()
        if cover_width > cover_max_width or cover_height > cover_max_height then
            local scale = math.min(cover_max_width / cover_width, cover_max_height / cover_height)
            cover_width = math.max(1, math.floor(cover_width * scale))
            cover_height = math.max(1, math.floor(cover_height * scale))
            thumbnail = RenderImage:scaleBlitBuffer(thumbnail, cover_width, cover_height, true)
        end
        table.insert(left_column, CenterContainer:new{
            dimen = Geom:new{ w = left_width, h = cover_height },
            ImageWidget:new{ image = thumbnail, width = cover_width, height = cover_height },
        })
    else
        table.insert(left_column, DeluxeCoverPlaceholder.centered(cover_max_width, cover_max_height, { border = 1 }))
    end

    table.insert(left_column, VerticalSpan:new{ width = 4 })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(title),
        width = left_width,
        face = book_title_face,
        line_height = 0.2,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(author),
        width = left_width,
        face = detail_face,
        line_height = 0.15,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = tostring(filename),
        width = left_width,
        face = detail_face,
        line_height = 0.15,
        alignment = "center",
    })
    table.insert(left_column, VerticalSpan:new{ width = 5 })
    table.insert(left_column, TextBoxWidget:new{
        text = _("THIS DEVICE"),
        width = left_width,
        face = label_face,
        alignment = "center",
    })
    local confirmed_ratio = math.max(0, math.min(1, tonumber(percentage) or 0))
    local confirmed_bar = ProgressWidget:new{
        width = math.floor(left_width * 0.78),
        height = math.max(6, math.floor(Device.screen:getHeight() * 0.012)),
        percentage = confirmed_ratio,
        ticks = nil,
        last = nil,
    }
    table.insert(left_column, CenterContainer:new{
        dimen = Geom:new{ w = left_width, h = confirmed_bar:getSize().h },
        confirmed_bar,
    })
    table.insert(left_column, TextBoxWidget:new{
        text = formatPercent(percentage),
        width = left_width,
        face = label_face,
        alignment = "center",
    })

    local right_column = VerticalGroup:new{}
    table.insert(right_column, TextBoxWidget:new{
        text = _("CONFIRMED POSITION"),
        width = right_width,
        face = label_face,
        alignment = "center",
    })
    table.insert(right_column, VerticalSpan:new{ width = 5 })
    local position_label_face = Font:getFace("smallinfofont", 16)
    local position_value_face = Font:getFace("smallinfofontbold", 16)
    local position_padding = math.max(6, Device.screen:scaleBySize(6))
    local position_inner_width = math.max(1, right_width - 2 - position_padding * 2)
    local position_value_width = math.floor(position_inner_width * 0.22)
    local position_label_width = math.max(1, position_inner_width - position_value_width)
    local position_rows = VerticalGroup:new{ align = "left" }
    local function addPositionRow(label, value)
        local value_widget = TextBoxWidget:new{
            text = value,
            width = position_value_width,
            face = position_value_face,
            alignment = "left",
        }
        table.insert(position_rows, HorizontalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text = label .. ":",
                width = position_label_width,
                face = position_label_face,
                alignment = "left",
            },
            value_widget,
        })
    end
    addPositionRow(_("Original Device Position"), formatPercent(original_percentage))
    addPositionRow(_("Server Position"), formatPercent(self.preview.remote.percentage))
    addPositionRow(_("Preview Landed At"), formatPercent(percentage))
    local position_content = LeftContainer:new{
        dimen = Geom:new{ w = position_inner_width, h = position_rows:getSize().h },
        position_rows,
    }
    table.insert(right_column, FrameContainer:new{
        width = right_width,
        bordersize = 1,
        radius = math.max(6, Device.screen:scaleBySize(6)),
        padding = position_padding,
        position_content,
    })
    table.insert(right_column, VerticalSpan:new{ width = 10 })
    table.insert(right_column, TextBoxWidget:new{
        text = _("ACTIONS"),
        width = right_width,
        face = label_face,
        alignment = "left",
    })
    table.insert(right_column, VerticalSpan:new{ width = 4 })

    local action_height = math.max(46, math.floor(Device.screen:getHeight() * 0.065))
    local function addAction(text, callback)
        table.insert(right_column, ButtonTable:new{
            buttons = {{ {
                text = text,
                height = action_height,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                font_face = "smallinfofontbold",
                callback = callback,
            } }},
            width = right_width,
            show_parent = self.preview_decision_dialog,
        })
        table.insert(right_column, VerticalSpan:new{ width = 3 })
    end

    addAction(_("Accept Remote Position"), function()
        UIManager:close(self.preview_decision_dialog)
        self:acceptPreviewLocalOnly()
    end)
    addAction(_("Keep Device Position → Update Selected Server"), function()
        UIManager:close(self.preview_decision_dialog)
        self:restorePreviewAndUpdateSelected()
    end)
    addAction(_("Accept Remote → Sync All Servers"), function()
        UIManager:close(self.preview_decision_dialog)
        self:acceptPreviewAndSyncAll()
    end)
    addAction(_("Cancel — Restore Original Position"), function()
        UIManager:close(self.preview_decision_dialog)
        self:cancelPreview()
    end)

    self.preview_decision_dialog:addWidget(HorizontalGroup:new{
        align = "top",
        left_column,
        HorizontalSpan:new{ width = gap },
        right_column,
    })

    suppressDialogContainerHolds(self.preview_decision_dialog)
    UIManager:show(self.preview_decision_dialog)
end

function ProgressSyncDeluxe:cancelPreview()
    if DiagnosticLog then DiagnosticLog.log("preview", "cancel") end
    if not self.preview then return end
    local original = self.preview.original_location
    self.preview = nil
    self:hidePreviewShortcut()
    self:restoreBookLocation(original)
end

function ProgressSyncDeluxe:returnToPullResults()
    local results = self.last_pull_results
    self:cancelPreview()
    if results then
        UIManager:nextTick(function() self:showPullResults(results) end)
    end
end

function ProgressSyncDeluxe:acceptPreviewLocalOnly()
    if not self.preview then return end
    local _ignored, percentage = self:getCurrentProgress()
    if DiagnosticLog then DiagnosticLog.log("preview", "accept local only", "percentage", percentage) end
    self.preview = nil
    self:hidePreviewShortcut()
    UIManager:show(InfoMessage:new{
        text = T(_("Local reading position updated to %1. No server records were changed."), formatPercent(percentage)),
    })
end

function ProgressSyncDeluxe:restorePreviewAndUpdateSelected()
    if not self.preview then return end
    local preview = self.preview
    local original_location = preview.original_location
    local original_progress = preview.original_progress
    local original_percentage = preview.original_percentage or 0
    self.preview = nil
    self:hidePreviewShortcut()
    self:restoreBookLocation(original_location)

    local selected = preview.remote.servers or {}
    for unused_index, result in ipairs(selected) do
        local server = result.server
        if server then
            local payload = {
                document = result.document or preview.original_document,
                progress = tostring(original_progress),
                percentage = original_percentage,
                device = Device.model,
                device_id = self.store.data.device_id,
            }
            self:newClient(server):updateProgress(server.username, server.userkey, payload, function(ok, status, body)
                if DiagnosticLog then
                    DiagnosticLog.log("preview", "update selected", serverLabel(server), "ok", ok and true or false, "status", status, "body", body)
                end
            end)
        end
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Device position restored to %1 and sent to the selected server result."), formatPercent(original_percentage)),
    })
end

function ProgressSyncDeluxe:acceptPreviewAndSyncAll()
    if not self.preview then return end
    local _ignored, percentage = self:getCurrentProgress()
    self.preview = nil
    self:hidePreviewShortcut()
    self:pushAll(false)
    UIManager:show(InfoMessage:new{
        text = T(_("Remote position accepted at %1 and is being pushed to all enabled servers."), formatPercent(percentage)),
    })
end

function ProgressSyncDeluxe:serverFromSettingsDraft(draft, password, require_password)
    draft = draft or {}
    local name = util.trim(draft.name or "")
    local url = util.trim(draft.url or "")
    local username = util.trim(draft.username or "")
    local email = util.trim(draft.email or "")
    password = password or ""
    if url == "" or username == "" or (require_password and password == "" and not draft.userkey) then
        UIManager:show(InfoMessage:new{ text = _("Server URL, username, and password are required.") })
        return nil
    end
    local normalized_url, url_error = UrlUtil.normalize(url)
    if not normalized_url then
        UIManager:show(InfoMessage:new{ text = url_error or _("Server URL is invalid.") })
        return nil
    end
    local key = password ~= "" and userkey(password) or draft.userkey
    if not key then
        UIManager:show(InfoMessage:new{ text = _("Password is required.") })
        return nil
    end
    return {
        id = draft.id,
        name = name ~= "" and name or normalized_url,
        url = normalized_url,
        username = username,
        email = email ~= "" and email or nil,
        userkey = key,
        enabled = draft.enabled ~= false,
        metadata_enabled = draft.metadata_enabled ~= false,
        data_sharing_version = ServerStore.DATA_SHARING_VERSION,
        book_feedback_enabled = draft.book_feedback_enabled == true,
        annotations_enabled = draft.annotations_enabled == true,
        reading_statistics_enabled = draft.reading_statistics_enabled == true,
        settings_backup_enabled = draft.settings_backup_enabled == true,
        deluxe_config_backup_enabled = draft.deluxe_config_backup_enabled == true,
        vocabulary_enabled = draft.vocabulary_enabled == true,
        vocabulary_context_enabled = draft.vocabulary_enabled == true and draft.vocabulary_context_enabled == true,
        checksum_method = draft.checksum_method == "filename" and "filename" or "binary",
        capabilities = util.tableDeepCopy(draft.capabilities or {}),
    }
end

function ProgressSyncDeluxe:showServers()
    local ServersPage = require("ServersPage")
    local page
    page = ServersPage:new{
        servers = self.store:listServers(),
        label_fn = function(server)
            local label = serverLabel(server)
            if self.store and self.store:serverNeedsAttention(server.id) then return "⚠ " .. label end
            return label
        end,
        plugin_version = PLUGIN_VERSION,
        on_close = function(current)
            self.servers_page = nil
            UIManager:close(current)
        end,
        on_toggle = function(current, server, enabled)
            self.store:setServerEnabled(server.id, enabled == true)
            if enabled ~= true and self.queue then self.queue:removeServer(server.id) end
        end,
        on_browse = function(current)
            local target
            for server_index, server in ipairs(self.store:listServers()) do
                local capabilities = server.capabilities or {}
                if server.enabled ~= false and capabilities.document_listing == true then
                    target = server
                    break
                end
            end
            if not target then
                UIManager:show(InfoMessage:new{ text = _("No enabled server supports Synced Books.") })
                return
            end
            self.servers_page = nil
            UIManager:close(current)
            self:showCachedServerLibrary(target)
        end,
        on_open_server = function(current, server)
            self.servers_page = nil
            UIManager:close(current)
            self:showServer(server)
        end,
        on_add = function(current)
            self.servers_page = nil
            UIManager:close(current)
            self:addServerDialog()
        end,
    }
    self.servers_page = page
    UIManager:show(page)
end

function ProgressSyncDeluxe:showDataSharingDialog(server, on_save, on_cancel)
    server = server or {}
    local values = {
        metadata_enabled = server.metadata_enabled ~= false,
        book_feedback_enabled = server.book_feedback_enabled == true,
        annotations_enabled = server.annotations_enabled == true,
        reading_statistics_enabled = server.reading_statistics_enabled == true,
        settings_backup_enabled = server.settings_backup_enabled == true,
        deluxe_config_backup_enabled = server.deluxe_config_backup_enabled == true,
        vocabulary_enabled = server.vocabulary_enabled == true,
        vocabulary_context_enabled = server.vocabulary_enabled == true and server.vocabulary_context_enabled == true,
    }
    local dialog
    local labels = {
        { id = "metadata_sharing", field = "metadata_enabled", label = _("Book Metadata") },
        { id = "book_feedback_sharing", field = "book_feedback_enabled", label = _("Ratings & Reviews") },
        { id = "annotation_sharing", field = "annotations_enabled", label = _("Annotations / Highlights / Notes") },
        { id = "statistics_sharing", field = "reading_statistics_enabled", label = _("Reading Statistics") },
        { id = "settings_sharing", field = "settings_backup_enabled", label = _("KOReader Settings Backup") },
        { id = "config_sharing", field = "deluxe_config_backup_enabled", label = _("Deluxe-Sync Config Backup") },
        { id = "vocabulary_sharing", field = "vocabulary_enabled", label = _("Vocabulary Builder") },
        { id = "vocabulary_context_sharing", field = "vocabulary_context_enabled", label = _("Vocabulary Reading Context") },
    }
    local function buttonText(item)
        return T(_("%1: %2"), item.label, values[item.field] and _("On") or _("Off"))
    end
    local function toggle(item)
        if item.field == "vocabulary_context_enabled" and not values.vocabulary_enabled then
            UIManager:show(InfoMessage:new{ text = _("Enable Vocabulary Builder before sharing reading context.") })
            return
        end
        values[item.field] = not values[item.field]
        if item.field == "vocabulary_enabled" and not values.vocabulary_enabled then
            values.vocabulary_context_enabled = false
            local context_button = dialog:getButtonById("vocabulary_context_sharing")
            if context_button then
                local context_item = labels[#labels]
                context_button:setText(buttonText(context_item), context_button.width)
            end
        end
        local button = dialog:getButtonById(item.id)
        if button then button:setText(buttonText(item), button.width) end
        UIManager:setDirty(dialog, "ui")
        if item.field == "book_feedback_enabled" and values[item.field] then
            UIManager:show(InfoMessage:new{
                text = _("Ratings & Reviews can include your personal rating and private KOReader review note. Enable this only if you want those stored on this server."),
            })
        elseif item.field == "deluxe_config_backup_enabled" and values[item.field] then
            UIManager:show(InfoMessage:new{
                text = _("Deluxe-Sync Config Backup includes your configured server URLs, usernames, and saved authentication keys. Enable it only for a server you trust to hold your complete Deluxe-Sync setup."),
            })
        elseif item.field == "vocabulary_context_enabled" and values[item.field] then
            UIManager:show(InfoMessage:new{
                text = _("Vocabulary Reading Context can include surrounding book passages and highlighted text. Enable it only if you want those excerpts stored on this server."),
            })
        end
    end

    local rows = {
        {{
            text = _("Reading Progress: On (required)"),
            callback = function()
                UIManager:show(InfoMessage:new{ text = _("Reading progress is the core Deluxe-Sync service and is always shared with an enabled server.") })
            end,
        }},
    }
    for _, item in ipairs(labels) do
        local current = item
        rows[#rows + 1] = {{
            id = current.id,
            text = buttonText(current),
            callback = function() toggle(current) end,
        }}
    end
    rows[#rows + 1] = {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
                if on_cancel then on_cancel() end
            end,
        },
        {
            text = _("Save"),
            is_enter_default = true,
            callback = function()
                for field, value in pairs(values) do server[field] = value end
                server.data_sharing_version = ServerStore.DATA_SHARING_VERSION
                UIManager:close(dialog)
                if on_save then on_save(server) end
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = T(_("Data shared with %1"), serverLabel(server)),
        title_align = "left",
        buttons = rows,
    }
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
end

function ProgressSyncDeluxe:showDataSharingReview()
    if self.data_sharing_review_shown or not self.store then return end
    local pending = self.store:getServersNeedingDataSharingReview()
    if #pending == 0 then return end
    self.data_sharing_review_shown = true
    local server = pending[1]
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Review data sharing (%1 remaining)"), #pending),
        title_align = "left",
        buttons = {
            {{
                text = T(_("Review %1"), serverLabel(server)),
                callback = function()
                    UIManager:close(dialog)
                    self:showDataSharingDialog(server, function(updated)
                        self.store:upsertServer(updated)
                        self.data_sharing_review_shown = false
                        local remaining = self.store:getServersNeedingDataSharingReview()
                        local message
                        if #remaining > 0 then
                            message = T(_("Saved for %1. Servers remaining to review: %2."), serverLabel(updated), #remaining)
                        else
                            message = T(_("Saved for %1. Data-sharing review is complete."), serverLabel(updated))
                        end
                        UIManager:show(InfoMessage:new{ text = message, timeout = 1.5 })
                        if #remaining > 0 then
                            UIManager:scheduleIn(1.6, function() self:showDataSharingReview() end)
                        end
                    end, function()
                        self.data_sharing_review_shown = false
                    end)
                end,
            }},
            {{
                text = _("Later"),
                callback = function()
                    UIManager:close(dialog)
                    self.data_sharing_review_shown = false
                end,
            }},
        },
    }
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
end

function ProgressSyncDeluxe:showServerSettingsPage(existing)
    existing = existing or {}
    local ServerSettingsPage = require("ServerSettingsPage")
    local page

    local function closePage()
        if page then
            self.server_settings_page = nil
            UIManager:close(page)
        end
    end

    local function requireSaved()
        if page and page.dirty then
            UIManager:show(InfoMessage:new{ text = _("Save your changes before using this action.") })
            return false
        end
        return true
    end

    local function saveDraft(draft, password, require_password)
        local server = self:serverFromSettingsDraft(draft, password, require_password)
        if not server then return nil end
        return self.store:upsertServer(server)
    end

    page = ServerSettingsPage:new{
        server = existing,
        is_new = existing.id == nil,
        label_fn = serverLabel,
        on_back = function()
            closePage()
            self:showServers()
        end,
        on_save = function(current, draft, password)
            local saved = saveDraft(draft, password, draft.id == nil)
            if not saved then return end
            current:applySavedServer(saved)
            UIManager:show(InfoMessage:new{ text = _("Saved."), timeout = 1.2 })
            self:testServer(saved, {
                show_result = false,
                on_complete = function(updated)
                    if self.server_settings_page == current then current:applySavedServer(updated or saved) end
                end,
            })
        end,
        on_signup = function(current, draft, password)
            local server = self:serverFromSettingsDraft(draft, password, true)
            if not server then return end
            current.dirty = false
            closePage()
            self:registerServerAccount(server)
        end,
        on_authenticate = function(current, draft, password)
            local candidate = self:serverFromSettingsDraft(draft, password, false)
            if not candidate then return end
            if DiagnosticLog then DiagnosticLog.log("ui action", "Authenticate / Sign in", "server", serverLabel(candidate)) end
            self:testServer(candidate, {
                show_result = false,
                on_authorized = function(authenticated)
                    local saved = self.store:upsertServer(authenticated)
                    if self.server_settings_page == current then current:applySavedServer(saved) end
                    return saved
                end,
                on_complete = function(updated)
                    if self.server_settings_page == current then
                        current:applySavedServer(updated or self.store:getServer(candidate.id) or candidate)
                        UIManager:show(InfoMessage:new{ text = _("Signed in. Settings saved and capabilities refreshed."), timeout = 2 })
                    end
                end,
            })
        end,
        on_recovery = function(_current, draft)
            if not requireSaved() then return end
            local saved = self.store:getServer(draft.id) or existing
            closePage()
            self:showRecoveryDialog(saved)
        end,
        on_delete = function(_current, draft)
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete %1 from Deluxe-Sync?\nThis cannot be undone."), serverLabel(draft)),
                cancel_text = _("Cancel"),
                ok_text = _("Delete"),
                ok_callback = function()
                    closePage()
                    if self.queue then self.queue:removeServer(draft.id) end
                    self.store:removeServer(draft.id)
                    self:showServers()
                end,
            })
        end,
    }
    self.server_settings_page = page
    UIManager:show(page)
end

function ProgressSyncDeluxe:addServerDialog(existing)
    self:showServerSettingsPage(existing or {})
end

function ProgressSyncDeluxe:showRecoveryDialog(existing)
    existing = existing or {}
    local dialog

    local function collect(require_reset)
        local values = dialog:getFields()
        local data = {
            name = util.trim(values[1] or ""),
            url = util.trim(values[2] or ""),
            username = util.trim(values[3] or ""),
            email = util.trim(values[4] or ""),
            code = util.trim(values[5] or ""),
            password = values[6] or "",
            password_confirm = values[7] or "",
        }
        if data.url == "" or data.username == "" or data.email == "" then
            UIManager:show(InfoMessage:new{ text = _("Server URL, username, and email are required for account recovery.") })
            return
        end
        if require_reset then
            if data.code == "" or data.password == "" or data.password_confirm == "" then
                UIManager:show(InfoMessage:new{ text = _("Recovery code and both new password fields are required.") })
                return
            end
            if data.password ~= data.password_confirm then
                UIManager:show(InfoMessage:new{ text = _("The new passwords do not match.") })
                return
            end
        end
        return data
    end

    local function recoveryServer(data)
        data = data or existing
        return {
            name = data.name and data.name ~= "" and data.name or data.url,
            url = data.url,
            username = data.username,
        }
    end

    local function showRecoveryReply(data, status_text, message, status, actions)
        local rows = {
            { label = _("Server"), value = serverLabel(recoveryServer(data)) },
            { label = _("Status"), value = status_text },
            { label = _("Message"), value = message },
        }
        if status then
            table.insert(rows, { label = _("HTTP"), value = tostring(status) })
        end
        self:showStatusCard(_("Deluxe-Sync"), rows, actions)
    end

    local function unsupported(data, status)
        showRecoveryReply(
            data,
            _("Recovery Not Supported"),
            _("This server does not support Deluxe-Sync account recovery."),
            status
        )
    end

    local function requestCode()
        local data = collect(false)
        if not data then return end
        DiagnosticLog.log("recovery UI request code", data.url, "username", data.username, "email", data.email)
        local client = self:newClient({ url = data.url })
        local cap_ok, cap_status, cap_body = client:recoveryCapability()
        local cap_data = decode(cap_body)
        DiagnosticLog.log("recovery capability result", data.url, "status", cap_status or "nil", "body", cap_body or "")
        if not cap_ok or cap_status ~= 200 or (type(cap_data) == "table" and cap_data.supported == false) then
            return unsupported(data, cap_status)
        end
        local ok, status, body = client:requestRecovery(data.username, data.email)
        DiagnosticLog.log("recovery request result", data.url, "status", status or "nil", "body", body or "")
        if ok and (status == 200 or status == 202) then
            showRecoveryReply(
                data,
                _("Recovery Code Requested"),
                _("If the account details are valid, a time-limited recovery code has been sent to the supplied email address."),
                status
            )
            return
        end
        if status == 404 or status == 405 then return unsupported(data, status) end
        showRecoveryReply(
            data,
            _("Recovery Request Failed"),
            serverResponseMessage(body) or _("The server could not start account recovery."),
            status
        )
    end

    local function confirmReset()
        local data = collect(true)
        if not data then return end
        local new_key = userkey(data.password)
        DiagnosticLog.log("recovery UI confirm", data.url, "username", data.username, "email", data.email, "code_length", #data.code, "new_userkey", "<redacted>")
        local client = self:newClient({ url = data.url })
        local ok, status, body = client:confirmRecovery(data.username, data.email, data.code, new_key)
        DiagnosticLog.log("recovery confirm result", data.url, "status", status or "nil", "body_length", #tostring(body or ""))
        if not ok or (status ~= 200 and status ~= 204) then
            if status == 404 or status == 405 then return unsupported(data, status) end
            showRecoveryReply(
                data,
                _("Password Reset Failed"),
                serverResponseMessage(body) or _("The recovery code was not accepted or has expired."),
                status
            )
            return
        end

        local auth_ok, auth_status, auth_body = client:authorize(data.username, new_key)
        DiagnosticLog.log("recovery post-reset authorize", data.url, "username", data.username, "status", auth_status or "nil")
        if not auth_ok then
            showRecoveryReply(
                data,
                _("Credential Verification Failed"),
                serverResponseMessage(auth_body) or _("The password was reset, but the new credentials could not be verified. Please try signing in manually."),
                auth_status
            )
            return
        end

        local capabilities = existing.capabilities or {}
        capabilities.account_recovery = true
        local server = {
            id = existing.id,
            name = data.name ~= "" and data.name or data.url,
            url = data.url,
            username = data.username,
            email = data.email,
            userkey = new_key,
            enabled = existing.enabled ~= false,
            metadata_enabled = existing.metadata_enabled ~= false,
            checksum_method = existing.checksum_method == "filename" and "filename" or "binary",
            capabilities = capabilities,
        }
        local saved = self.store:upsertServer(server)
        UIManager:close(dialog)
        showRecoveryReply(
            data,
            _("Password Reset Complete"),
            _("Password reset completed and the new credentials were verified."),
            status,
            {{
                text = _("Continue"),
                callback = function(card)
                    UIManager:close(card)
                    self:testServer(saved)
                end,
            }}
        )
    end

    dialog = MultiInputDialog:new{
        title = _("Deluxe-Sync — Account Recovery"),
        fields = {
            { text = existing.name or "", hint = _("Server name") },
            { text = existing.url or "", hint = _("URL (http:// or https://; defaults to https://)") },
            { text = existing.username or "", hint = _("Username") },
            { text = existing.email or "", hint = _("Email") },
            { text = "", hint = _("Recovery code") },
            { text = "", hint = _("New password"), text_type = "password" },
            { text = "", hint = _("Confirm new password"), text_type = "password" },
        },
        buttons = {
            {
                { text = _("Cancel"), callback = function()
                    UIManager:close(dialog)
                    if existing.id then self:showServer(self.store:getServer(existing.id) or existing) else self:addServerDialog(existing) end
                end },
                { text = _("Request Recovery Code"), callback = requestCode },
            },
            {{ text = _("Reset Password & Sign In"), is_enter_default = true, callback = confirmReset }},
        },
    }
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ProgressSyncDeluxe:showServerFailureDialog(server, title, message, status)
    local rows = {
        { label = _("Server"), value = serverLabel(server) },
        { label = _("Username"), value = server.username or "" },
        { label = _("Status"), value = title },
        { label = _("Message"), value = message },
    }
    if status then table.insert(rows, { label = _("HTTP"), value = tostring(status) }) end
    self:showStatusCard(_("Deluxe-Sync"), rows, {
        { text = _("Back to Server Setup"), callback = function(card)
            UIManager:close(card)
            self:addServerDialog(server)
        end },
        { text = _("Close") },
    })
end

function ProgressSyncDeluxe:registerServerAccount(server)
    UIManager:show(InfoMessage:new{
        text = T(_("Registering %1 on %2..."), server.username, serverLabel(server)),
        timeout = 1,
    })
    local ok, status, body = self:newClient(server):register(server.username, server.userkey)
    if not ok then
        local message = userFacingServerFailure(status, body)
        local title = _("REGISTRATION FAILED")
        if status == 402 then
            title = _("ACCOUNT NOT CREATED")
            message = message or _("That username is already registered on this server. Use Sign in / save with your existing password, or choose a different username.")
        elseif status == 409 then
            local lower = tostring(message or ""):lower()
            if lower:find("username", 1, true) and (lower:find("taken", 1, true) or lower:find("exist", 1, true) or lower:find("register", 1, true)) then
                title = _("ACCOUNT NOT CREATED")
                message = T(_("%1\n\nUse Sign in / save with your existing password, or choose a different username."), message or _("That username is already registered on this server."))
            else
                message = message or _("The server reported a registration conflict.")
            end
        elseif status == 403 then
            title = _("REGISTRATION NOT AVAILABLE")
            message = message or _("This server does not allow account creation through KOReader.")
        elseif not status then
            title = _("CONNECTION FAILED")
            message = userFacingServerFailure(status, body)
        end
        self:showServerFailureDialog(server, title, message or _("Unknown server error"), status)
        return
    end
    self.store:upsertServer(server)
    self:testServer(server)
end

function ProgressSyncDeluxe:showStatusCard(title, rows, actions)
    local dialog
    local title_face = Font:getFace("smallinfofontbold")
    local label_face = Font:getFace("smallinfofontbold", 17)
    local value_face = Font:getFace("smallinfofont", 17)
    local button_rows = {}

    if actions and #actions > 0 then
        local action_row = {}
        for _, action in ipairs(actions) do
            local item = action
            table.insert(action_row, {
                text = item.text,
                callback = function()
                    if item.callback then item.callback(dialog) else UIManager:close(dialog) end
                end,
            })
        end
        table.insert(button_rows, action_row)
    else
        table.insert(button_rows, {{
            text = _("Close"),
            callback = function() UIManager:close(dialog) end,
        }})
    end

    dialog = ButtonDialog:new{
        title = title or _("Deluxe-Sync"),
        title_align = "left",
        title_face = title_face,
        width_factor = 0.82,
        use_info_style = false,
        buttons = button_rows,
    }

    local available_width = dialog:getAddedWidgetAvailableWidth()
    local padding = math.max(8, Device.screen:scaleBySize(8))
    local inner_width = math.max(1, available_width - padding * 2 - 2)
    local label_width = math.floor(inner_width * 0.42)
    local value_width = math.max(1, inner_width - label_width)
    local row_widgets = VerticalGroup:new{ align = "left" }

    for _, row in ipairs(rows or {}) do
        table.insert(row_widgets, HorizontalGroup:new{
            align = "center",
            TextBoxWidget:new{
                text = tostring(row.label or "") .. ":",
                width = label_width,
                face = label_face,
                alignment = "left",
            },
            TextBoxWidget:new{
                text = tostring(row.value or ""),
                width = value_width,
                face = value_face,
                alignment = "left",
            },
        })
    end

    local content = LeftContainer:new{
        dimen = Geom:new{ w = inner_width, h = row_widgets:getSize().h },
        row_widgets,
    }
    dialog:addWidget(FrameContainer:new{
        width = available_width,
        bordersize = 1,
        radius = math.max(7, Device.screen:scaleBySize(7)),
        padding = padding,
        content,
    })
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
    return dialog
end

function ProgressSyncDeluxe:showServerTestResult(server, listing_supported, book_count, recovery_supported, logical_supported, rich_supported, device_supported, device_registered, annotation_supported, reading_statistics_supported, settings_backup_supported, vocabulary_supported)
    local listing_value = listing_supported
        and T(_("Supported (%1 Books)"), book_count or 0)
        or _("Not Supported")
    local device_value = _("Not Supported")
    if device_supported then device_value = device_registered and _("Registered") or _("Supported") end
    self:showStatusCard(_("Deluxe-Sync"), {
        { label = _("Server"), value = serverLabel(server) },
        { label = _("Status"), value = _("Connected") },
        { label = _("Library Listing"), value = listing_value },
        { label = _("Account Recovery"), value = recovery_supported and _("Supported") or _("Not Supported") },
        { label = _("Linked Books"), value = logical_supported and _("Supported") or _("Not Supported") },
        { label = _("Rich Position"), value = rich_supported and _("Supported") or _("Not Supported") },
        { label = _("Device Identity"), value = device_value },
        { label = _("Annotations"), value = annotation_supported and _("Supported") or _("Not Supported") },
        { label = _("Reading Statistics"), value = reading_statistics_supported and _("Supported") or _("Not Supported") },
        { label = _("Settings Backups"), value = settings_backup_supported and _("Supported") or _("Not Supported") },
        { label = _("Vocabulary Builder"), value = vocabulary_supported and _("Supported") or _("Not Supported") },
    })
end

function ProgressSyncDeluxe:testServer(server, options)
    options = options or {}
    local client = self:newClient(server)
    local ok, status, body = client:authorize(server.username, server.userkey)
    if not ok then
        local title = status and _("SIGN-IN FAILED") or _("CONNECTION FAILED")
        local message = userFacingServerFailure(status, body)
        self:showServerFailureDialog(server, title, message, status)
        return
    end
    if options.on_authorized then
        local authorized_server = options.on_authorized(server)
        if not authorized_server then return end
        server = authorized_server
    end
    local recovery_ok, recovery_status, recovery_body = client:recoveryCapability()
    local recovery_data = decode(recovery_body)
    local recovery_supported = recovery_ok and recovery_status == 200 and not (type(recovery_data) == "table" and recovery_data.supported == false)
    self.store:setCapability(server.id, "account_recovery", recovery_supported)
    DiagnosticLog.log("recovery capability test", server.url or "", "status", recovery_status or "nil", "supported", recovery_supported, "body", recovery_body or "")
    local capability_ok, capability_status, capability_body = client:capabilities()
    local capability_data = decode(capability_body)
    local enhanced_capabilities = capability_ok and capability_status == 200 and type(capability_data) == "table" and capability_data.capabilities or nil
    self:cacheEnhancedCapabilities(server, enhanced_capabilities)
    server = self.store:getServer(server.id) or server
    local cached_capabilities = server.capabilities or {}
    local logical_supported = cached_capabilities.logical_books == true and cached_capabilities.logical_library == true
    local rich_supported = cached_capabilities.rich_progress == true
    local device_supported = cached_capabilities.device_registration == true
    local annotation_supported = cached_capabilities.annotations == true
    local reading_statistics_supported = self:serverSupportsReadingStatistics(server)
    local vocabulary_supported = self:serverSupportsVocabulary(server)
    local settings_backup_supported = self:serverSupportsSettingsBackups(server)
    if recovery_supported and server.email and server.email ~= "" then
        local email_ok, email_status, email_body = client:setRecoveryEmail(server.username, server.userkey, server.email)
        DiagnosticLog.log("recovery email enrollment result", server.url or "", "username", server.username or "", "email", server.email, "status", email_status or "nil", "ok", email_ok, "body", email_body or "")
    end

    local function finishTest(device_registered)
        client:listDocuments(server.username, server.userkey, function(list_ok, list_status, body)
            local data = decode(body)
            local listing_supported = list_ok and list_status == 200 and data and type(data.documents) == "table"
            local book_count = 0
            if listing_supported then
                book_count = #data.documents
                self.store:setCapability(server.id, "document_listing", true)
            else
                self.store:setCapability(server.id, "document_listing", false)
            end
            local updated = self.store:getServer(server.id) or server
            if options.on_complete then options.on_complete(updated) end
            if options.show_result ~= false then
                self:showServerTestResult(updated, listing_supported, book_count, recovery_supported, logical_supported, rich_supported, device_supported, device_registered, annotation_supported, reading_statistics_supported, settings_backup_supported, vocabulary_supported)
            end
        end)
    end

    if device_supported then
        self:heartbeatDevice(server, client, true, function(registered) finishTest(registered) end)
    else
        self.store:setCapability(server.id, "device_registered", false)
        finishTest(false)
    end
end

function ProgressSyncDeluxe:showServer(server)
    if not server then
        self:showServers()
        return
    end
    self:showServerSettingsPage(server)
end

function ProgressSyncDeluxe:showCachedServerLibrary(server, browser)
    if not self.server_library_controller then return false end
    return self.server_library_controller:showCachedServerLibrary(server, browser)
end

function ProgressSyncDeluxe:refreshServerLibrary(server, browser)
    if not self.server_library_controller then return end
    return self.server_library_controller:refreshServerLibrary(server, browser)
end
function ProgressSyncDeluxe:showLogicalLinkPicker(server, documents)
    if not self.server_library_controller then return end
    return self.server_library_controller:showLogicalLinkPicker(server, documents)
end

function ProgressSyncDeluxe:showLogicalProgressSourcePicker(server, selected)
    if not self.server_library_controller then return end
    return self.server_library_controller:showLogicalProgressSourcePicker(server, selected)
end

function ProgressSyncDeluxe:confirmUnlinkLogicalBook(server, logical_book, browser)
    if not self.server_library_controller then return end
    return self.server_library_controller:confirmUnlinkLogicalBook(server, logical_book, browser)
end

function ProgressSyncDeluxe:showLogicalBookInspection(server, summary, browser)
    if not self.server_library_controller then return end
    return self.server_library_controller:showLogicalBookInspection(server, summary, browser)
end

function ProgressSyncDeluxe:showServerDocumentInspection(server, doc, match, documents, authoritative, logical_mode, browser, entry)
    local ServerRecordInspection = require("ServerRecordInspection")
    return ServerRecordInspection.show(self, server, doc, match, documents, authoritative, logical_mode, {
        format_percent = formatPercent,
        server_label = serverLabel,
        suppress_dialog_holds = suppressDialogContainerHolds,
        browser = browser,
        entry = entry,
    })
end

function ProgressSyncDeluxe:showServerLibrary(server, documents, authoritative, logical_mode, existing_page, refreshed_at)
    if not self.server_library_controller then return end
    return self.server_library_controller:showServerLibrary(server, documents, authoritative, logical_mode, existing_page, refreshed_at)
end

function ProgressSyncDeluxe:canAutoSync()
    return self.progress_lifecycle_controller ~= nil
        and self.progress_lifecycle_controller:canAutoSync()
end

function ProgressSyncDeluxe:autoSyncPush()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:autoSyncPush()
end

function ProgressSyncDeluxe:autoSyncPull()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:autoSyncPull()
end

function ProgressSyncDeluxe:scheduleAutomaticUpdateCheck()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:scheduleAutomaticUpdateCheck()
end

function ProgressSyncDeluxe:onReaderReady()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:onReaderReady()
end

function ProgressSyncDeluxe:onPageUpdate(page)
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:onPageUpdate(page)
end

function ProgressSyncDeluxe:onAnnotationsModified()
    if not self.annotation_sync_service then return end
    return self.annotation_sync_service:onAnnotationsModified()
end

function ProgressSyncDeluxe:onResume()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:onResume()
end

function ProgressSyncDeluxe:onSuspend()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:onSuspend()
end

function ProgressSyncDeluxe:onNetworkConnected()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:onNetworkConnected()
end

function ProgressSyncDeluxe:onCloseDocument()
    if not self.progress_lifecycle_controller then return end
    return self.progress_lifecycle_controller:onCloseDocument()
end

return ProgressSyncDeluxe
