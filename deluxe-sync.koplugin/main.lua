local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local Blitbuffer = require("ffi/blitbuffer")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CheckButton = require("ui/widget/checkbutton")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
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

local DiagnosticLog
local SyncClient
local SyncQueue
local ServerStore
local Resolver
local LocalLibrary

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
    if type(body) == "string" and body ~= "" then
        return body
    end
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
    ensureReaderMenuOrder()

    -- Register first so an initialization failure cannot make the plugin vanish
    -- from KOReader's menu. The diagnostic entry below will expose the error.
    self.ui.menu:registerToMainMenu(self)

    local ok, err = pcall(function()
        self.path = plugin_root
        package.path = self.path .. "/?.lua;" .. package.path
        DiagnosticLog = require("DiagnosticLog")
        DiagnosticLog.log("plugin init", "start")
        SyncClient = require("SyncClient")
        SyncQueue = require("SyncQueue")
        ServerStore = require("ServerStore")
        Resolver = require("Resolver")
        LocalLibrary = require("LocalLibrary")
        self.store = ServerStore:new()
        DiagnosticLog.configure(self.store.data.settings.logging_enabled ~= false)
        self.queue = SyncQueue:new()
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

function ProgressSyncDeluxe:showServerOnboarding()
    local dialog
    dialog = ButtonDialog:new{
        title = _("There are no servers registered. Would you like to set one up now?"),
        title_align = "left",
        buttons = {
            {{
                text = _("Use complimentary Techy-Notes.com server"),
                callback = function()
                    UIManager:close(dialog)
                    self:addServerDialog{
                        name = "Techy-Notes.com",
                        url = "https://sync.techy-notes.com",
                    }
                end,
            }},
            {{
                text = _("Add custom server"),
                callback = function()
                    UIManager:close(dialog)
                    self:addServerDialog()
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
end

function ProgressSyncDeluxe:showCredits()
    local credits = "# Deluxe-Sync for KOReader\n\n"
        .. "Version **" .. PLUGIN_VERSION .. "**\n\n"
        .. "A multi-server KOSync companion for KOReader, built to synchronize reading progress across independent KOReader-compatible servers while keeping conflict review and server inspection reader-friendly.\n\n"
        .. "## With appreciation\n\n"
        .. "Deluxe-Sync builds on the open-source KOReader ecosystem and the KOSync protocol implemented by KOReader's built-in Progress Sync plugin.\n\n"
        .. "- [KOReader](https://github.com/koreader/koreader) — the reader, plugin platform, widgets, network APIs, and KOSync implementation that make Deluxe-Sync possible.\n"
        .. "- [BookOrbit](https://github.com/bookorbit/bookorbit) — a KOReader-compatible sync server used while validating interoperability, metadata-aware synchronization, and server-library behavior.\n\n"
        .. "Many thanks to the authors and contributors who make these projects available to the community.\n\n"
        .. "## Links & Support\n\n"
        .. "- [Techy Notes](https://techy-notes.com) — blog, projects, notes, and guides.\n"
        .. "- [Jadehawk on YouTube](https://youtube.com/@jadehawk) — project videos and tutorials.\n"
        .. "- [Buy Me a Coffee](https://buymeacoffee.com/jadehawk) — if you would like to support my projects.\n"
        .. "- [Deluxe-Sync on GitHub](https://github.com/jadehawk/deluxe-sync.koplugin) — source code, releases, and issue tracking.\n\n"
        .. "Deluxe-Sync is an independent personal project and is not affiliated with KOReader, BookOrbit, or the services listed above."

    local viewer = TextViewer:new{
        title = _("Credits"),
        text = credits,
        text_format = "md",
        justified = false,
        add_default_buttons = true,
    }
    if viewer.box_widget then
        local box_widget = viewer.box_widget
        box_widget.html_link_tapped_callback = function(link)
            local uri = link and (link.uri or link.link or link.href)
            if type(uri) ~= "string" or not uri:match("^https?://") then return end
            if type(Device.canOpenLink) == "function" and Device:canOpenLink() then
                Device:openLink(uri)
            else
                UIManager:show(InfoMessage:new{
                    text = _("Open this link on another device:") .. "\n\n" .. uri,
                })
            end
        end
        box_widget.onTapText = function(widget, _arg, ges)
            local pos = widget:getPosFromAbsPos(ges.pos)
            if not pos then return end
            local link = widget:getLinkByPosition(pos)
            if link then
                widget.html_link_tapped_callback(link)
                return true
            end
        end
    end
    UIManager:show(viewer)
end

function ProgressSyncDeluxe:addToMainMenu(menu_items)
    local sub_items = {}
    local function strategyName(value)
        if value == "silent" then return _("Silently") end
        if value == "never" then return _("Never") end
        return _("Prompt")
    end
    local function strategyChoices(setting_name)
        return {
            {
                text = _("Silently"),
                checked_func = function() return self.store and self.store.data.settings[setting_name] == "silent" end,
                callback = function() self.store.data.settings[setting_name] = "silent"; self.store:flush() end,
            },
            {
                text = _("Prompt"),
                checked_func = function() return self.store and self.store.data.settings[setting_name] == "prompt" end,
                callback = function() self.store.data.settings[setting_name] = "prompt"; self.store:flush() end,
            },
            {
                text = _("Never"),
                checked_func = function() return self.store and self.store.data.settings[setting_name] == "never" end,
                callback = function() self.store.data.settings[setting_name] = "never"; self.store:flush() end,
            },
        }
    end

    if self.init_error then
        table.insert(sub_items, {
            text = _("Initialization error"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("Deluxe-Sync failed to initialize:\n\n%1"), self.init_error),
                })
            end,
        })
    end

    table.insert(sub_items, {
        text = _("Sync Behavior"),
        enabled_func = function() return self.store ~= nil end,
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Sync to newer state (%1)"), strategyName(self.store and self.store.data.settings.sync_forward))
                end,
                sub_item_table = strategyChoices("sync_forward"),
            },
            {
                text_func = function()
                    return T(_("Sync to older state (%1)"), strategyName(self.store and self.store.data.settings.sync_backward))
                end,
                sub_item_table = strategyChoices("sync_backward"),
            },
        },
    })
    table.insert(sub_items, {
        text = _("Auto-Sync Documents"),
        checked_func = function() return self.store ~= nil and self.store.data.settings.auto_sync ~= false end,
        enabled_func = function() return self.store ~= nil end,
        callback = function()
            self.store.data.settings.auto_sync = self.store.data.settings.auto_sync == false
            self.store:flush()
        end,
    })
    table.insert(sub_items, {
        text = _("Push progress to all"),
        enabled_func = function()
            return self.store ~= nil and self.ui.document ~= nil and not self.preview and #self.store:getEnabledServers() > 0
        end,
        callback = function() self:pushAll(true) end,
    })
    table.insert(sub_items, {
        text = _("Pull progress from all"),
        enabled_func = function()
            return self.store ~= nil and self.ui.document ~= nil and not self.preview and #self.store:getEnabledServers() > 0
        end,
        callback = function() self:pullAll(true) end,
    })
    table.insert(sub_items, {
        text_func = function()
            local queued = self.queue and self.queue:count() or 0
            return T(_("Queued updates (%1)"), queued)
        end,
        enabled_func = function() return self.queue ~= nil end,
        callback = function() self:retryQueue(true) end,
        separator = true,
    })
    table.insert(sub_items, {
        text_func = function()
            local enabled = self.store and #self.store:getEnabledServers() or 0
            return T(_("Configured Servers (%1 enabled)"), enabled)
        end,
        enabled_func = function() return self.store ~= nil end,
        callback = function() self:showServers() end,
        separator = true,
    })
    table.insert(sub_items, {
        text = _("Diagnostic logging"),
        checked_func = function()
            return self.store ~= nil and self.store.data.settings.logging_enabled ~= false
        end,
        enabled_func = function() return self.store ~= nil end,
        callback = function()
            local enabled = self.store.data.settings.logging_enabled == false
            self.store.data.settings.logging_enabled = enabled
            self.store:flush()
            if not enabled then DiagnosticLog.log("diagnostic logging", "disabled") end
            DiagnosticLog.configure(enabled)
            if enabled then DiagnosticLog.log("diagnostic logging", "enabled") end
        end,
    })
    table.insert(sub_items, {
        text = _("Check for Updates"),
        enabled_func = function() return self.store ~= nil end,
        callback = function() require("deluxe_sync_updater").check(self, true) end,
        separator = true,
    })
    table.insert(sub_items, {
        text = _("Credits"),
        callback = function() self:showCredits() end,
    })

    menu_items.progress_sync_deluxe = {
        text = _("Deluxe-Sync"),
        sub_item_table_func = function()
            if self.store and #self.store:listServers() == 0 then
                self:showServerOnboarding()
                return {}
            end
            return sub_items
        end,
    }
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

function ProgressSyncDeluxe:getMetadata()
    local props = self.ui.doc_props or {}
    return {
        filename = self:getFileName(),
        title = props.display_title,
        authors = props.authors,
    }
end

function ProgressSyncDeluxe:getCurrentProgress()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress(), self.ui.paging:getLastPercent()
    end
    return self.ui.rolling:getLastProgress(), self.ui.rolling:getLastPercent()
end

function ProgressSyncDeluxe:newClient(server)
    return SyncClient:new{
        custom_url = server.url,
        service_spec = self.path .. "/api.json",
    }
end

function ProgressSyncDeluxe:pushAll(interactive)
    if DiagnosticLog then DiagnosticLog.log("push all", "interactive", interactive and true or false) end
    if self.preview then
        if DiagnosticLog then DiagnosticLog.log("push blocked", "preview active") end
        if interactive then UIManager:show(InfoMessage:new{ text = _("Preview mode is active. Exit or accept the preview before syncing.") }) end
        return
    end
    local document = self:getDocumentDigest()
    local progress, percentage = self:getCurrentProgress()
    local metadata = self:getMetadata()
    local servers = self.store:getEnabledServers()
    local pending = #servers
    local success, queued, failed, not_tracked = 0, 0, 0, 0
    if pending == 0 then return end

    local function done()
        pending = pending - 1
        if pending == 0 and interactive then
            UIManager:show(InfoMessage:new{
                text = T(_("Deluxe-Sync\n\nSynced: %1\nKOSync compatibility errors: %2\nQueued: %3\nFailed: %4\n\nCompatibility error means the server rejected a standard KOSync document hash because it requires its own library match."), success, not_tracked, queued, failed),
            })
        end
    end

    for unused_index, server in ipairs(servers) do
        local payload = {
            document = document,
            progress = tostring(progress),
            percentage = percentage,
            device = Device.model,
            device_id = self.store.data.device_id,
        }
        local capabilities = server.capabilities or {}
        if server.metadata_enabled ~= false and capabilities.metadata_compatible ~= false then
            payload.metadata = metadata
        end

        local function finalizeFailure(status, body, failed_payload)
            if isBookNotFoundResponse(status, body) then
                not_tracked = not_tracked + 1
                self.queue:remove(server.id, document)
                if DiagnosticLog then DiagnosticLog.log("push not tracked", serverLabel(server), "document", document, "status", status, "body", body) end
            elseif status == 401 then
                failed = failed + 1
            else
                queued = queued + 1
                self.queue:push{
                    server_id = server.id,
                    document = document,
                    payload = failed_payload,
                }
            end
            done()
        end

        local function send(current_payload, is_metadata_probe)
            self:newClient(server):updateProgress(server.username, server.userkey, current_payload, function(ok, status, body)
                if ok and (status == 200 or status == 202) then
                    success = success + 1
                    self.queue:remove(server.id, document)
                    if is_metadata_probe then
                        self.store:setCapability(server.id, "metadata_compatible", true)
                    end
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
    local document = self:getDocumentDigest()
    local progress, percentage = self:getCurrentProgress()
    if not document or progress == nil then return end
    local metadata = self:getMetadata()
    for unused_index, server in ipairs(self.store:getEnabledServers()) do
        local payload = {
            document = document,
            progress = tostring(progress),
            percentage = percentage,
            device = Device.model,
            device_id = self.store.data.device_id,
        }
        local capabilities = server.capabilities or {}
        if server.metadata_enabled ~= false and capabilities.metadata_compatible ~= false then
            payload.metadata = metadata
        end
        self.queue:push{
            server_id = server.id,
            document = document,
            payload = payload,
        }
    end
    if DiagnosticLog then DiagnosticLog.log("auto sync", "queued offline progress", "servers", #self.store:getEnabledServers()) end
end

function ProgressSyncDeluxe:retryQueue(interactive, complete_callback)
    local items = self.queue:list()
    if #items == 0 then
        if interactive then UIManager:show(InfoMessage:new{ text = _("No queued progress updates.") }) end
        if complete_callback then complete_callback() end
        return
    end

    local pending = 0
    local scan_complete = false
    local function done()
        pending = pending - 1
        if scan_complete and pending == 0 and complete_callback then complete_callback() end
    end

    for unused_index, item in ipairs(items) do
        local server = self.store:getServer(item.server_id)
        if server and server.enabled ~= false then
            pending = pending + 1
            local payload = item.payload
            if payload.metadata ~= nil and (server.metadata_enabled == false or (server.capabilities and server.capabilities.metadata_compatible == false)) then
                payload = {
                    document = payload.document,
                    progress = payload.progress,
                    percentage = payload.percentage,
                    device = payload.device,
                    device_id = payload.device_id,
                }
                item.payload = payload
                self.queue:save()
            end
            self:newClient(server):updateProgress(server.username, server.userkey, payload, function(ok, status, body)
                if ok and (status == 200 or status == 202) then
                    self.queue:remove(item.server_id, item.document)
                elseif isBookNotFoundResponse(status, body) then
                    self.queue:remove(item.server_id, item.document)
                    if DiagnosticLog then DiagnosticLog.log("queue drop not tracked", serverLabel(server), "document", item.document, "status", status, "body", body) end
                end
                done()
            end)
        end
    end
    scan_complete = true
    if pending == 0 and complete_callback then complete_callback() end
    if interactive then UIManager:show(InfoMessage:new{ text = _("Queued updates are being retried.") }) end
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
        addRequest(canonical_document, false)
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
        table.insert(left_column, TextBoxWidget:new{
            text = _("Cover unavailable"),
            width = left_width,
            face = detail_face,
            alignment = "center",
        })
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

    local percent = math.floor((tonumber(group.percentage) or 0) * 100 + 0.5)
    if DiagnosticLog then DiagnosticLog.log("pull apply", "mode", "percentage fallback", "percentage", group.percentage or "", "percent", percent) end
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
        table.insert(left_column, TextBoxWidget:new{
            text = _("Cover unavailable"),
            width = left_width,
            face = detail_face,
            alignment = "center",
        })
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
        table.insert(left_column, TextBoxWidget:new{
            text = _("Cover unavailable"),
            width = left_width,
            face = detail_face,
            alignment = "center",
        })
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

function ProgressSyncDeluxe:showServers(state)
    state = state or {}
    if not state.enabled then
        state.enabled = {}
        for _, server in ipairs(self.store:listServers()) do
            state.enabled[server.id] = server.enabled ~= false
        end
    end
    state.query = state.query or ""

    local function matches(server)
        return state.query == "" or serverLabel(server):lower():find(state.query:lower(), 1, true) ~= nil
    end

    local server_scroll
    local function reopen(preserve_scroll)
        if preserve_scroll and server_scroll then
            state.scroll_offset = server_scroll:getScrolledOffset()
        else
            state.scroll_offset = nil
        end
        UIManager:close(self.servers_dialog)
        UIManager:nextTick(function() self:showServers(state) end)
    end

    self.servers_dialog = ButtonDialog:new{
        title = _("Deluxe-Sync"),
        title_align = "left",
        width = math.floor(Device.screen:getWidth() * 0.92),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(self.servers_dialog) end },
            {
                text = _("✓  OK"),
                callback = function()
                    for _, server in ipairs(self.store:listServers()) do
                        self.store:setServerEnabled(server.id, state.enabled[server.id] == true)
                    end
                    UIManager:close(self.servers_dialog)
                end,
            },
        }},
    }

    local body_width = self.servers_dialog:getAddedWidgetAvailableWidth()
    local scrollbar_width = ScrollableContainer:getScrollbarWidth()
    local grid_width = math.max(1, body_width - scrollbar_width)
    local title_face = Font:getFace("smallinfofont", 14)

    local selected, available = {}, {}
    for _, server in ipairs(self.store:listServers()) do
        if matches(server) then
            table.insert(state.enabled[server.id] and selected or available, server)
        end
    end

    local grid_rows = {}
    local function addSection(title, servers, enabled)
        table.insert(grid_rows, {{
            text = title,
            enabled = false,
            align = "left",
            bordersize = 0,
            text_font_face = "smallinfofont",
            text_font_size = 15,
            text_font_bold = true,
        }})
        if #servers == 0 then
            table.insert(grid_rows, {{
                text = _("No matching servers"),
                enabled = false,
                align = "left",
                radius = math.max(7, Device.screen:scaleBySize(7)),
                text_font_face = "smallinfofont",
                text_font_size = 15,
                text_font_bold = false,
            }})
            return
        end
        local row = {}
        for _, server in ipairs(servers) do
            local selected_server = server
            table.insert(row, {
                text = (enabled and "●  " or "○  ") .. serverLabel(selected_server),
                align = "left",
                radius = math.max(8, Device.screen:scaleBySize(8)),
                padding_h = math.max(7, Device.screen:scaleBySize(7)),
                padding_v = math.max(8, Device.screen:scaleBySize(8)),
                text_font_face = "smallinfofont",
                text_font_size = 16,
                text_font_bold = true,
                callback = function()
                    state.enabled[selected_server.id] = not enabled
                    reopen(true)
                end,
                hold_callback = function()
                    UIManager:close(self.servers_dialog)
                    self:showServer(selected_server)
                end,
            })
            if #row == 2 then
                table.insert(grid_rows, row)
                row = {}
            end
        end
        if #row > 0 then
            table.insert(grid_rows, row)
        end
    end

    addSection(T(_("SELECTED (%1)"), #selected), selected, true)
    addSection(T(_("AVAILABLE SERVERS (%1)"), #available), available, false)

    local server_grid = ButtonTable:new{
        buttons = grid_rows,
        width = grid_width,
        zero_sep = true,
        show_parent = self.servers_dialog,
    }

    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, TextBoxWidget:new{
        text = _("Select servers to use for sync:"),
        width = body_width,
        face = title_face,
        alignment = "left",
    })
    table.insert(body, VerticalSpan:new{ width = 5 })

    table.insert(body, ButtonTable:new{
        buttons = {{ {
            text = state.query ~= "" and T(_("Search: %1"), state.query) or _("⌕  Search servers…"),
            align = "left",
            radius = math.max(8, Device.screen:scaleBySize(8)),
            text_font_face = "smallinfofont",
            text_font_size = 16,
            text_font_bold = true,
            callback = function()
                local search_dialog
                search_dialog = MultiInputDialog:new{
                    title = _("Deluxe-Sync"),
                    title_align = "left",
                    fields = {{ text = state.query, hint = _("Search servers…") }},
                    buttons = {{
                        { text = _("Cancel"), callback = function() UIManager:close(search_dialog) end },
                        { text = _("Search"), callback = function()
                            state.query = util.trim((search_dialog:getFields()[1]) or "")
                            UIManager:close(search_dialog)
                            reopen(false)
                        end },
                    }},
                }
                suppressDialogContainerHolds(search_dialog)
                UIManager:show(search_dialog)
                search_dialog:onShowKeyboard()
            end,
        } }},
        width = body_width,
        zero_sep = true,
        show_parent = self.servers_dialog,
    })
    table.insert(body, VerticalSpan:new{ width = 8 })

    table.insert(body, FrameContainer:new{
        width = body_width,
        bordersize = 0,
        padding = 0,
        (function()
            server_scroll = FreeScrollableContainer:new{
                dimen = Geom:new{ w = body_width, h = math.floor(Device.screen:getHeight() * 0.50) },
                show_parent = self.servers_dialog,
                server_grid,
            }
            return server_scroll
        end)(),
    })
    table.insert(body, VerticalSpan:new{ width = 8 })
    table.insert(body, TextBoxWidget:new{
        text = _("Tap and hold a server for details and options."),
        width = body_width,
        face = title_face,
        alignment = "left",
    })
    table.insert(body, VerticalSpan:new{ width = 8 })

    table.insert(body, ButtonTable:new{
        buttons = {{ {
            text = _("+  Add server…"),
            align = "center",
            radius = math.max(8, Device.screen:scaleBySize(8)),
            padding_h = math.max(10, Device.screen:scaleBySize(10)),
            padding_v = math.max(10, Device.screen:scaleBySize(10)),
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            text_font_face = "smallinfofont",
            text_font_size = 16,
            text_font_bold = true,
            callback = function()
                UIManager:close(self.servers_dialog)
                self:addServerDialog()
            end,
        } }},
        width = body_width,
        zero_sep = true,
        show_parent = self.servers_dialog,
    })

    self.servers_dialog:addWidget(body)
    suppressDialogContainerHolds(self.servers_dialog)
    UIManager:show(self.servers_dialog)
    if state.scroll_offset and server_scroll then
        local offset = state.scroll_offset
        UIManager:nextTick(function()
            if server_scroll then
                server_scroll:setScrolledOffset(offset)
                server_scroll:_scrollBy(0, 0)
            end
        end)
    end
end

function ProgressSyncDeluxe:addServerDialog(existing)
    existing = existing or {}
    local dialog, check_button_metadata

    local function collectServer(require_password)
        local values = dialog:getFields()
        local name = util.trim(values[1] or "")
        local url = util.trim(values[2] or "")
        local username = util.trim(values[3] or "")
        local password = values[4] or ""
        if url == "" or username == "" or (require_password and password == "" and not existing.userkey) then
            UIManager:show(InfoMessage:new{
                text = _("Server URL, username, and password are required."),
            })
            return
        end
        local key = password ~= "" and userkey(password) or existing.userkey
        if not key then
            UIManager:show(InfoMessage:new{ text = _("Password is required.") })
            return
        end
        local metadata_enabled = check_button_metadata.checked
        local capabilities = existing.capabilities
        if metadata_enabled and existing.metadata_enabled == false and capabilities then
            capabilities.metadata_compatible = nil
        end
        return {
            id = existing.id,
            name = name ~= "" and name or url,
            url = url,
            username = username,
            userkey = key,
            enabled = existing.enabled ~= false,
            metadata_enabled = metadata_enabled,
            capabilities = capabilities,
        }
    end

    local buttons = {
        {
            text = existing.id and _("Back to server details") or _("Cancel"),
            callback = function()
                UIManager:close(dialog)
                if existing.id then
                    self:showServer(self.store:getServer(existing.id) or existing)
                else
                    self:showServers()
                end
            end,
        },
    }
    if not existing.id then
        table.insert(buttons, {
            text = _("Sign up"),
            callback = function()
                local server = collectServer(true)
                if not server then return end
                UIManager:close(dialog)
                self:registerServerAccount(server)
            end,
        })
    end
    table.insert(buttons, {
        text = existing.id and _("Save / sign in") or _("Sign in / save"),
        is_enter_default = true,
        callback = function()
            local server = collectServer(not existing.id)
            if not server then return end
            self.store:upsertServer(server)
            UIManager:close(dialog)
            self:testServer(server)
        end,
    })

    dialog = MultiInputDialog:new{
        title = _("Deluxe-Sync"),
        fields = {
            { text = existing.name or "", hint = _("Server name") },
            { text = existing.url or "", hint = _("Server URL") },
            { text = existing.username or "", hint = _("Username") },
            { text = "", hint = existing.userkey and _("Password (leave blank to keep current)") or _("Password"), text_type = "password" },
        },
        buttons = { buttons },
    }
    check_button_metadata = CheckButton:new{
        text = _("Enable Metadata"),
        checked = existing.metadata_enabled ~= false,
        parent = dialog,
    }
    dialog:addWidget(check_button_metadata)
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ProgressSyncDeluxe:showServerFailureDialog(server, title, message, status)
    local dialog
    dialog = ButtonDialog:new{
        title = title,
        title_align = "left",
        buttons = {
            {{ text = serverLabel(server), enabled = false }},
            {{ text = T(_("Username: %1"), server.username or ""), enabled = false }},
            {{ text = message, enabled = false }},
            {{ text = T(_("HTTP %1"), status or "?"), enabled = false }},
            {
                { text = _("Back to Server Setup"), callback = function()
                    UIManager:close(dialog)
                    self:addServerDialog(server)
                end },
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    suppressDialogContainerHolds(dialog)
    UIManager:show(dialog)
end

function ProgressSyncDeluxe:registerServerAccount(server)
    UIManager:show(InfoMessage:new{
        text = T(_("Registering %1 on %2..."), server.username, serverLabel(server)),
        timeout = 1,
    })
    local ok, status, body = self:newClient(server):register(server.username, server.userkey)
    if not ok then
        local message = serverResponseMessage(body)
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
            message = message or _("The server did not complete the registration request.")
        end
        self:showServerFailureDialog(server, title, message or _("Unknown server error"), status)
        return
    end
    self.store:upsertServer(server)
    UIManager:show(InfoMessage:new{
        text = T(_("Account created on %1. Testing sign in and server capabilities..."), serverLabel(server)),
        timeout = 2,
    })
    self:testServer(server)
end

function ProgressSyncDeluxe:testServer(server)
    local client = self:newClient(server)
    local ok, status, body = client:authorize(server.username, server.userkey)
    if not ok then
        local message
        if status == 401 then
            message = _("The username or password was not accepted. Check your credentials and try again.")
        else
            message = serverResponseMessage(body) or _("The server did not accept the sign-in request.")
        end
        self:showServerFailureDialog(server, _("SIGN-IN FAILED"), message, status)
        return
    end
    client:listDocuments(server.username, server.userkey, function(list_ok, list_status, body)
        local data = decode(body)
        if list_ok and list_status == 200 and data and type(data.documents) == "table" then
            self.store:setCapability(server.id, "document_listing", true)
            self.store:setKnownDocuments(server.id, data.documents)
            UIManager:show(InfoMessage:new{ text = T(_("%1 connected. Remote library listing supported (%2 books)."), serverLabel(server), #data.documents) })
        else
            self.store:setCapability(server.id, "document_listing", false)
            UIManager:show(InfoMessage:new{ text = T(_("%1 connected. Standard KOSync mode; remote library listing is not supported."), serverLabel(server)) })
        end
    end)
end

function ProgressSyncDeluxe:showServer(server)
    local caps = server.capabilities or {}
    local listing = caps.document_listing == true and _("Supported") or (caps.document_listing == false and _("Not supported") or _("Unknown"))
    local buttons = {
        {{ text = T(_("Enabled: %1"), server.enabled ~= false and _("Yes") or _("No")), callback = function() self.store:setServerEnabled(server.id, server.enabled == false); UIManager:close(self.server_dialog); self:showServer(self.store:getServer(server.id)) end }},
        {{ text = T(_("Remote library: %1"), listing), enabled = false }},
        {{ text = _("Refresh / test capabilities"), callback = function() UIManager:close(self.server_dialog); self:testServer(server) end }},
        {{ text = _("Browse tracked books"), callback = function() UIManager:close(self.server_dialog); self:refreshServerLibrary(server) end }},
        {{ text = _("Edit server"), callback = function() UIManager:close(self.server_dialog); self:addServerDialog(server) end }},
        {{ text = _("Delete server"), callback = function()
            local confirm_dialog
            confirm_dialog = ButtonDialog:new{
                title = _("Delete server?"),
                title_align = "left",
                buttons = {
                    {{ text = T(_("Delete %1 from Deluxe-Sync? This cannot be undone."), serverLabel(server)), enabled = false }},
                    {
                        { text = _("Cancel"), callback = function() UIManager:close(confirm_dialog) end },
                        { text = _("Delete"), callback = function()
                            UIManager:close(confirm_dialog)
                            UIManager:close(self.server_dialog)
                            if self.queue then self.queue:removeServer(server.id) end
                            self.store:removeServer(server.id)
                            self:showServers()
                        end },
                    },
                },
            }
            suppressDialogContainerHolds(confirm_dialog)
            UIManager:show(confirm_dialog)
        end }},
        {{ text = _("Back to server list"), callback = function() UIManager:close(self.server_dialog); self:showServers() end }},
    }
    self.server_dialog = ButtonDialog:new{ title = _("Deluxe-Sync"), title_align = "left", buttons = buttons }
    suppressDialogContainerHolds(self.server_dialog)
    UIManager:show(self.server_dialog)
end

function ProgressSyncDeluxe:refreshServerLibrary(server)
    if server.capabilities and server.capabilities.document_listing == false then
        return self:showServerLibrary(server, self.store:getKnownDocuments(server.id), false)
    end
    self:newClient(server):listDocuments(server.username, server.userkey, function(ok, status, body)
        local data = decode(body)
        if ok and status == 200 and data and type(data.documents) == "table" then
            self.store:setCapability(server.id, "document_listing", true)
            self.store:setKnownDocuments(server.id, data.documents)
            self:showServerLibrary(server, data.documents, true)
        else
            self.store:setCapability(server.id, "document_listing", false)
            self:showServerLibrary(server, self.store:getKnownDocuments(server.id), false)
        end
    end)
end

function ProgressSyncDeluxe:showServerDocumentInspection(server, doc, match, documents, authoritative)
    if not doc then return end

    local title = doc.title or (match and match.title) or doc.filename or (match and match.filename)
        or T(_("Unknown book (%1)"), tostring(doc.document or ""):sub(1, 8))
    local author = doc.authors or (match and match.authors) or _("Metadata Unavailable")
    if type(author) == "table" then
        local parts = {}
        for _, value in ipairs(author) do table.insert(parts, tostring(value)) end
        author = #parts > 0 and table.concat(parts, ", ") or _("Metadata Unavailable")
    elseif author ~= nil then
        author = tostring(author)
    end
    local filename = doc.filename or (match and match.filename) or _("Unknown filename")
    local timestamp = tonumber(doc.timestamp) or 0
    local stamp = timestamp > 0 and os.date("%Y-%m-%d %H:%M", timestamp) or _("Unknown date")
    local local_status = match
        and T(_("%1 (%2)"), match.filename or _("book"), match.confidence or _("Unknown"))
        or _("Not found")

    local title_face = Font:getFace("smallinfofontbold")
    local book_title_face = Font:getFace("smallinfofontbold")
    local detail_face = Font:getFace("x_smallinfofont")
    local label_face = Font:getFace("smallinfofontbold")

    self.server_book_dialog = ButtonDialog:new{
        title = _("Deluxe-Sync"),
        title_align = "left",
        title_face = title_face,
        width_factor = 0.98,
        use_info_style = false,
        dismissable = false,
        buttons = {{
            {
                text = _("Back to server book list"),
                callback = function()
                    UIManager:close(self.server_book_dialog)
                    self:showServerLibrary(server, documents, authoritative)
                end,
            },
        }},
    }

    local available_width = self.server_book_dialog:getAddedWidgetAvailableWidth()
    local gap = math.max(8, math.floor(available_width * 0.025))
    local left_width = math.floor(available_width * 0.39)
    local right_width = available_width - left_width - gap
    local cover_max_width = math.max(80, left_width - 16)
    local cover_max_height = math.floor(Device.screen:getHeight() * 0.30)

    local left_column = VerticalGroup:new{ align = "center" }
    local thumbnail
    if match and match.path and self.ui.bookinfo then
        local ok, cover = pcall(function()
            return self.ui.bookinfo:getCoverImage(self.ui.document, match.path)
        end)
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
        local placeholder_width = math.min(cover_max_width, math.floor(cover_max_height * 0.67))
        local placeholder_height = math.min(cover_max_height, math.floor(placeholder_width / 0.67))
        local placeholder_border = 1
        local placeholder_padding = math.max(6, Device.screen:scaleBySize(6))
        local placeholder_inner_width = math.max(1, placeholder_width - (placeholder_border + placeholder_padding) * 2)
        local placeholder_inner_height = math.max(1, placeholder_height - (placeholder_border + placeholder_padding) * 2)
        local placeholder_content = VerticalGroup:new{ align = "center" }
        table.insert(placeholder_content, IconWidget:new{
            icon = "resources/icons/mdlight/book.opened.svg",
            width = math.max(32, math.floor(placeholder_width * 0.28)),
            height = math.max(32, math.floor(placeholder_width * 0.28)),
        })
        table.insert(placeholder_content, VerticalSpan:new{ width = 8 })
        table.insert(placeholder_content, TextBoxWidget:new{
            text = _("Cover unavailable"),
            width = math.max(40, placeholder_inner_width - 4),
            face = detail_face,
            alignment = "center",
        })
        table.insert(left_column, CenterContainer:new{
            dimen = Geom:new{ w = left_width, h = placeholder_height },
            FrameContainer:new{
                bordersize = placeholder_border,
                radius = math.max(4, Device.screen:scaleBySize(4)),
                padding = placeholder_padding,
                CenterContainer:new{
                    dimen = Geom:new{ w = placeholder_inner_width, h = placeholder_inner_height },
                    placeholder_content,
                },
            },
        })
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
        text = _("LOCAL MATCH"),
        width = left_width,
        face = label_face,
        alignment = "center",
    })
    table.insert(left_column, TextBoxWidget:new{
        text = local_status,
        width = left_width,
        face = detail_face,
        alignment = "center",
    })

    local right_column = VerticalGroup:new{}
    table.insert(right_column, TextBoxWidget:new{
        text = _("SERVER RECORD"),
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
                text = tostring(value or ""),
                width = remote_value_width,
                face = remote_value_face,
                alignment = "left",
            },
        })
    end
    addRemoteRow(_("Last Sync"), stamp)
    addRemoteRow(_("Position"), doc.percentage ~= nil and formatPercent(doc.percentage) or _("Unknown"))
    addRemoteRow(_("Server"), serverLabel(server))
    addRemoteRow(_("Document ID"), tostring(doc.document or _("Unknown")))
    addRemoteRow(_("Listing source"), authoritative and _("Live server response") or _("Cached server record"))

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
    table.insert(right_column, VerticalSpan:new{ width = 10 })
    table.insert(right_column, TextBoxWidget:new{
        text = _("Inspection only. You are browsing this server record; no reading position or sync state will be changed."),
        width = right_width,
        face = detail_face,
        alignment = "center",
    })

    self.server_book_dialog:addWidget(HorizontalGroup:new{
        align = "top",
        left_column,
        HorizontalSpan:new{ width = gap },
        right_column,
    })
    suppressDialogContainerHolds(self.server_book_dialog)
    UIManager:show(self.server_book_dialog)
end

function ProgressSyncDeluxe:showServerLibrary(server, documents, authoritative)
    documents = documents or {}
    table.sort(documents, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    local local_matches = LocalLibrary.scan(documents)
    local rows = {}

    for document_index, doc in ipairs(documents) do
        local item = doc
        local match = local_matches[item.document or ""]
        local server_has_metadata = item.title ~= nil or item.authors ~= nil
        local title = item.title or item.filename
        local author = item.authors
        if type(author) == "table" then
            local parts = {}
            for author_index, value in ipairs(author) do table.insert(parts, tostring(value)) end
            author = #parts > 0 and table.concat(parts, ", ") or nil
        elseif author ~= nil then
            author = tostring(author)
        end
        table.insert(rows, {
            item = item,
            match = match,
            title = title or T(_("Unknown book (%1)"), tostring(item.document or ""):sub(1, 8)),
            author = author,
            has_metadata = server_has_metadata,
        })
    end

    local function backToServerDetails()
        UIManager:close(self.library_dialog)
        self:showServer(self.store:getServer(server.id) or server)
    end

    self.library_dialog = ButtonDialog:new{
        width = math.floor(Device.screen:getWidth() * 0.94),
        buttons = {{
            { text = _("Back to server details"), callback = backToServerDetails },
        }},
    }

    local body_width = self.library_dialog:getAddedWidgetAvailableWidth()
    local scrollbar_width = ScrollableContainer:getScrollbarWidth()
    local list_width = math.max(1, body_width - scrollbar_width - Device.screen:scaleBySize(4))
    local card_height = math.max(70, math.floor(Device.screen:getHeight() * 0.102))
    local card_gap = math.max(8, Device.screen:scaleBySize(8))
    local card_padding = math.max(8, Device.screen:scaleBySize(8))
    local icon_slot = math.max(46, math.floor(list_width * 0.13))
    local arrow_slot = math.max(52, math.floor(list_width * 0.12))
    local icon_size = math.max(26, Device.screen:scaleBySize(26))
    local chevron_size = math.max(22, Device.screen:scaleBySize(22))
    local title_face = Font:getFace("smallinfofontbold")
    local subtitle_face = Font:getFace("smallinfofont")

    local with_metadata, without_metadata = {}, {}
    for row_index, entry in ipairs(rows) do
        table.insert(entry.has_metadata and with_metadata or without_metadata, entry)
    end

    local cards = VerticalGroup:new{ align = "left" }
    local rendered_count = 0
    local function addCard(selected)
        if rendered_count > 0 then table.insert(cards, VerticalSpan:new{ width = card_gap }) end
        rendered_count = rendered_count + 1

        local current_trailing_slot = selected.has_metadata and arrow_slot or 0
        local current_text_width = math.max(80, list_width - icon_slot - current_trailing_slot - card_padding * 2)
        local subtitle = selected.has_metadata and (selected.author or _("Unknown author")) or _("Metadata Unavailable")
        local details = VerticalGroup:new{ align = "left" }
        table.insert(details, TextWidget:new{
            text = selected.title,
            max_width = current_text_width,
            face = title_face,
            padding = 0,
        })
        table.insert(details, VerticalSpan:new{ width = math.max(2, Device.screen:scaleBySize(2)) })
        table.insert(details, TextWidget:new{
            text = subtitle,
            max_width = current_text_width,
            face = subtitle_face,
            padding = 0,
        })

        local trailing
        if selected.has_metadata then
            trailing = CenterContainer:new{
                dimen = Geom:new{ w = current_trailing_slot, h = card_height - card_padding * 2 },
                IconWidget:new{
                    icon = "chevron.right",
                    width = chevron_size,
                    height = chevron_size,
                    alpha = true,
                },
            }
        else
            trailing = HorizontalSpan:new{ width = 0 }
        end

        local card = FrameContainer:new{
            width = list_width,
            height = card_height,
            bordersize = 1,
            radius = math.max(8, Device.screen:scaleBySize(8)),
            padding = card_padding,
            HorizontalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = icon_slot, h = card_height - card_padding * 2 },
                    IconWidget:new{
                        icon = "book.opened",
                        width = icon_size,
                        height = icon_size,
                        alpha = true,
                    },
                },
                LeftContainer:new{
                    dimen = Geom:new{ w = current_text_width, h = card_height - card_padding * 2 },
                    details,
                },
                trailing,
            },
        }

        local tappable_card = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = list_width, h = card_height },
            card,
        }
        tappable_card.ges_events = {
            TapCard = {
                GestureRange:new{
                    ges = "tap",
                    range = tappable_card.dimen,
                },
            },
        }
        tappable_card.onTapCard = function()
            UIManager:close(self.library_dialog)
            self:showServerDocumentInspection(server, selected.item, selected.match, documents, authoritative)
            return true
        end
        table.insert(cards, tappable_card)
    end

    for metadata_index, entry in ipairs(with_metadata) do addCard(entry) end

    if #without_metadata > 0 then
        if #with_metadata > 0 then table.insert(cards, VerticalSpan:new{ width = math.max(12, card_gap) }) end
        local divider_label = TextWidget:new{
            text = T(_("Metadata Unavailable (%1)"), #without_metadata),
            face = title_face,
            padding = 0,
        }
        local divider_gap = math.max(8, Device.screen:scaleBySize(8))
        local divider_line_width = math.max(20, math.floor((list_width - divider_label:getSize().w - divider_gap * 2) / 2))
        local divider_height = math.max(divider_label:getSize().h, Device.screen:scaleBySize(2))
        table.insert(cards, HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = divider_line_width, h = divider_height },
                LineWidget:new{ dimen = Geom:new{ w = divider_line_width, h = 1 } },
            },
            HorizontalSpan:new{ width = divider_gap },
            divider_label,
            HorizontalSpan:new{ width = divider_gap },
            CenterContainer:new{
                dimen = Geom:new{ w = divider_line_width, h = divider_height },
                LineWidget:new{ dimen = Geom:new{ w = divider_line_width, h = 1 } },
            },
        })
        table.insert(cards, VerticalSpan:new{ width = math.max(6, Device.screen:scaleBySize(6)) })
        rendered_count = 0
        for unavailable_index, entry in ipairs(without_metadata) do addCard(entry) end
    end

    if #rows == 0 then
        table.insert(cards, TextBoxWidget:new{
            text = _("No known books."),
            width = list_width,
            face = subtitle_face,
            alignment = "center",
        })
    end

    local header_icon_size = math.max(30, math.floor(body_width * 0.08))
    local header_title_width = math.max(120, body_width - header_icon_size * 2)
    local body = VerticalGroup:new{ align = "left" }
    table.insert(body, HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = header_icon_size },
        TextBoxWidget:new{
            text = _("Browse Tracked Books"),
            width = header_title_width,
            face = Font:getFace("smallinfofontbold"),
            alignment = "center",
        },
        IconButton:new{
            icon = "cre.render.reload",
            width = header_icon_size,
            height = header_icon_size,
            padding = 4,
            callback = function()
                UIManager:close(self.library_dialog)
                self:refreshServerLibrary(self.store:getServer(server.id) or server)
            end,
            show_parent = self.library_dialog,
        },
    })
    table.insert(body, TextBoxWidget:new{
        text = T(_("%1 tracked books"), #documents),
        width = body_width,
        face = Font:getFace("smallinfofont"),
        alignment = "center",
    })
    table.insert(body, VerticalSpan:new{ width = math.max(8, Device.screen:scaleBySize(8)) })
    table.insert(body, FreeScrollableContainer:new{
        dimen = Geom:new{ w = body_width, h = math.floor(Device.screen:getHeight() * 0.69) },
        show_parent = self.library_dialog,
        cards,
    })

    self.library_dialog:addWidget(body)
    suppressDialogContainerHolds(self.library_dialog)
    UIManager:show(self.library_dialog)
end
function ProgressSyncDeluxe:canAutoSync()
    return self.store ~= nil
        and self.store.data.settings.auto_sync ~= false
        and self.ui.document ~= nil
        and not self.preview
        and #self.store:getEnabledServers() > 0
end

function ProgressSyncDeluxe:autoSyncPush()
    if not self:canAutoSync() then return end
    if NetworkMgr:isOnline() then
        self:pushAll(false)
    else
        self:queueCurrentProgress()
    end
end

function ProgressSyncDeluxe:autoSyncPull()
    if not self:canAutoSync() or not NetworkMgr:isOnline() then return end
    self:pullAll(false)
end

function ProgressSyncDeluxe:scheduleAutomaticUpdateCheck()
    if self._automatic_update_check_done or not self.store or not NetworkMgr:isOnline() then return end
    self._automatic_update_check_done = true
    UIManager:scheduleIn(1, function()
        require("deluxe_sync_updater").checkAutomatic(self)
    end)
end

function ProgressSyncDeluxe:onReaderReady()
    self.last_page_turn_timestamp = 0
    self.last_auto_sync_page = self.ui.getCurrentPage and self.ui:getCurrentPage() or nil
    self:scheduleAutomaticUpdateCheck()
    if self:canAutoSync() then
        UIManager:nextTick(function() self:autoSyncPull() end)
    end
end

function ProgressSyncDeluxe:onPageUpdate(page)
    if page ~= nil and page ~= self.last_auto_sync_page then
        self.last_auto_sync_page = page
        self.last_page_turn_timestamp = os.time()
    end
end

function ProgressSyncDeluxe:onResume()
    if not self:canAutoSync() then return end
    UIManager:scheduleIn(1, function() self:autoSyncPull() end)
end

function ProgressSyncDeluxe:onSuspend()
    self:autoSyncPush()
end

function ProgressSyncDeluxe:onNetworkConnected()
    self:scheduleAutomaticUpdateCheck()
    if not self:canAutoSync() then return end
    UIManager:scheduleIn(0.5, function()
        self:retryQueue(false, function()
            self:autoSyncPull()
        end)
    end)
end

function ProgressSyncDeluxe:onCloseDocument()
    if self.preview then self.preview = nil; return end
    self:autoSyncPush()
end

return ProgressSyncDeluxe
