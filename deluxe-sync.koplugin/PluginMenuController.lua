local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template

local PluginMenuController = {}
PluginMenuController.__index = PluginMenuController

function PluginMenuController:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function PluginMenuController:onDispatcherRegisterActions()
    Dispatcher:registerAction("deluxe_sync_set_autosync",
        { category="string", event="DeluxeSyncToggleAutoSync", title=_("Deluxe-Sync: Set Auto-Sync"), reader=true,
        args={true, false}, toggle={_("on"), _("off")},})
    Dispatcher:registerAction("deluxe_sync_toggle_autosync", { category="none", event="DeluxeSyncToggleAutoSync", title=_("Deluxe-Sync: Toggle Auto-Sync"), reader=true,})
    Dispatcher:registerAction("deluxe_sync_push_progress", { category="none", event="DeluxeSyncPushProgress", title=_("Deluxe-Sync: Push progress to all"), reader=true,})
    Dispatcher:registerAction("deluxe_sync_pull_progress", { category="none", event="DeluxeSyncPullProgress", title=_("Deluxe-Sync: Pull progress from all"), reader=true, separator=true,})
end

function PluginMenuController:canManualSync()
    local owner = self.owner
    return owner.store ~= nil
        and owner.ui ~= nil
        and owner.ui.document ~= nil
        and not owner.preview
        and #owner.store:getEnabledServers() > 0
end

function PluginMenuController:showManualSyncUnavailable()
    local owner = self.owner
    local text
    if owner.init_error then
        text = T(_("Deluxe-Sync failed to initialize:\n\n%1"), owner.init_error)
    elseif owner.preview then
        text = _("Preview mode is active. Exit or accept the preview before syncing.")
    elseif not owner.store or not owner.ui or owner.ui.document == nil then
        text = _("Deluxe-Sync is not ready for this document.")
    else
        text = _("No enabled sync servers are configured.")
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

function PluginMenuController:onDeluxeSyncToggleAutoSync(toggle)
    local owner = self.owner
    if not owner.store then
        self:showManualSyncUnavailable()
        return true
    end

    local enabled = toggle
    if enabled == nil then enabled = owner.store.data.settings.auto_sync ~= true end
    enabled = enabled == true
    if owner.store.data.settings.auto_sync ~= enabled then
        owner.store.data.settings.auto_sync = enabled
        owner.store:flush()
    end
    UIManager:show(InfoMessage:new{
        text = enabled and _("Deluxe-Sync Auto-Sync: on") or _("Deluxe-Sync Auto-Sync: off"),
        timeout = 3,
    })
    return true
end

function PluginMenuController:onDeluxeSyncPushProgress()
    local owner = self.owner
    if not self:canManualSync() then
        self:showManualSyncUnavailable()
        return true
    end
    owner:pushAll(true)
    return true
end

function PluginMenuController:onDeluxeSyncPullProgress()
    local owner = self.owner
    if not self:canManualSync() then
        self:showManualSyncUnavailable()
        return true
    end
    owner:pullAll(true)
    return true
end

function PluginMenuController:showServerOnboarding()
    local owner = self.owner
    local dialog
    dialog = ButtonDialog:new{
        title = _("There are no servers registered. Would you like to set one up now?"),
        title_align = "left",
        buttons = {
            {{
                text = _("Use complimentary Techy-Notes.com server"),
                callback = function()
                    UIManager:close(dialog)
                    owner:addServerDialog{
                        name = "Techy-Notes.com",
                        url = "https://sync.techy-notes.com",
                    }
                end,
            }},
            {{
                text = _("Add custom server"),
                callback = function()
                    UIManager:close(dialog)
                    owner:addServerDialog()
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    if self.deps.suppress_dialog_holds then self.deps.suppress_dialog_holds(dialog) end
    UIManager:show(dialog)
end

function PluginMenuController:showCredits()
    local plugin_version = self.deps.plugin_version or ""
    local credits = "# Deluxe-Sync for KOReader\n\n"
        .. "Version **" .. plugin_version .. "**\n\n"
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

    local viewer
    viewer = TextViewer:new{
        title = _("Credits"),
        text = credits,
        text_format = "md",
        justified = false,
        buttons_table = {{
            {
                text = "⇱",
                id = "top",
                callback = function() viewer.scroll_widget:scrollToTop() end,
            },
            {
                text = "⇲",
                id = "bottom",
                callback = function() viewer.scroll_widget:scrollToBottom() end,
            },
            {
                text = _("Close"),
                callback = function() viewer:onClose() end,
            },
        }},
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

function PluginMenuController:addToMainMenu(menu_items)
    local owner = self.owner
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
                checked_func = function() return owner.store and owner.store.data.settings[setting_name] == "silent" end,
                callback = function() owner.store.data.settings[setting_name] = "silent"; owner.store:flush() end,
            },
            {
                text = _("Prompt"),
                checked_func = function() return owner.store and owner.store.data.settings[setting_name] == "prompt" end,
                callback = function() owner.store.data.settings[setting_name] = "prompt"; owner.store:flush() end,
            },
            {
                text = _("Never"),
                checked_func = function() return owner.store and owner.store.data.settings[setting_name] == "never" end,
                callback = function() owner.store.data.settings[setting_name] = "never"; owner.store:flush() end,
            },
        }
    end

    if owner.init_error then
        table.insert(sub_items, {
            text = _("Initialization error"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("Deluxe-Sync failed to initialize:\n\n%1"), owner.init_error),
                })
            end,
        })
    end

    table.insert(sub_items, {
        text = _("Sync Behavior"),
        enabled_func = function() return owner.store ~= nil end,
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Sync to newer state (%1)"), strategyName(owner.store and owner.store.data.settings.sync_forward))
                end,
                sub_item_table = strategyChoices("sync_forward"),
            },
            {
                text_func = function()
                    return T(_("Sync to older state (%1)"), strategyName(owner.store and owner.store.data.settings.sync_backward))
                end,
                sub_item_table = strategyChoices("sync_backward"),
            },
        },
    })
    table.insert(sub_items, {
        text = _("Auto-Sync Documents"),
        checked_func = function() return owner.store ~= nil and owner.store.data.settings.auto_sync == true end,
        enabled_func = function() return owner.store ~= nil end,
        callback = function()
            owner.store.data.settings.auto_sync = owner.store.data.settings.auto_sync ~= true
            owner.store:flush()
        end,
    })
    table.insert(sub_items, {
        text = _("Push progress to all"),
        enabled_func = function()
            return self:canManualSync()
        end,
        callback = function() owner:pushAll(true) end,
    })
    table.insert(sub_items, {
        text = _("Pull progress from all"),
        enabled_func = function()
            return self:canManualSync()
        end,
        callback = function() owner:pullAll(true) end,
    })
    table.insert(sub_items, {
        text_func = function()
            local queued = owner.queue and owner.queue:count() or 0
            return T(_("Queued updates (%1)"), queued)
        end,
        enabled_func = function() return owner.queue ~= nil end,
        callback = function() owner:showQueuedUpdates() end,
        separator = true,
    })
    table.insert(sub_items, {
        text_func = function()
            local enabled = owner.store and #owner.store:getEnabledServers() or 0
            return T(_("Configured Servers (%1 enabled)"), enabled)
        end,
        enabled_func = function() return owner.store ~= nil end,
        sub_item_table_func = function() return nil end,
        callback = function() owner:showServers() end,
        separator = true,
    })
    table.insert(sub_items, {
        text = _("Diagnostic logging"),
        checked_func = function()
            return owner.store ~= nil and owner.store.data.settings.logging_enabled ~= false
        end,
        enabled_func = function() return owner.store ~= nil end,
        callback = function()
            local enabled = owner.store.data.settings.logging_enabled == false
            owner.store.data.settings.logging_enabled = enabled
            owner.store:flush()
            local diagnostic_log = self.deps.get_diagnostic_log and self.deps.get_diagnostic_log()
            if diagnostic_log then
                if not enabled then diagnostic_log.log("diagnostic logging", "disabled") end
                diagnostic_log.configure(enabled)
                if enabled then diagnostic_log.log("diagnostic logging", "enabled") end
            end
        end,
    })
    table.insert(sub_items, {
        text = _("Check for Updates"),
        enabled_func = function() return owner.store ~= nil end,
        callback = function() require("deluxe_sync_updater").check(owner, true) end,
        separator = true,
    })
    table.insert(sub_items, {
        text = _("Credits"),
        callback = function() self:showCredits() end,
    })

    menu_items.progress_sync_deluxe = {
        text = _("Deluxe-Sync"),
        sub_item_table_func = function()
            local diagnostic_log = self.deps.get_diagnostic_log and self.deps.get_diagnostic_log()
            if diagnostic_log then diagnostic_log.log("ui open", "Deluxe-Sync menu") end
            if owner.store and #owner.store:listServers() == 0 then
                self:showServerOnboarding()
                return {}
            end
            return sub_items
        end,
    }
end

return PluginMenuController
