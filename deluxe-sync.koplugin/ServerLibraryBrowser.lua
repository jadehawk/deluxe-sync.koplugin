local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local GestureRange = require("ui/gesturerange")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Size = require("ui/size")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template
local Dpad = require("DeluxeDpad")
local Style = require("DeluxeUIStyle")
local CoverCache = require("CoverCache")
local DeluxeCoverPlaceholder = require("DeluxeCoverPlaceholder")
local DiagnosticLog = require("DiagnosticLog")

local ServerLibraryBrowser = InputContainer:extend{
    name = "deluxe_sync_server_library_browser",
    covers_fullscreen = true,
}

local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = source_path:match("^(.*)[/\\]ServerLibraryBrowser%.lua$") or "."
local ICONS = plugin_root .. "/dependencies/icons/"
local SWAP_ICON = ICONS .. "swap.svg"
local REFRESH_ICON = ICONS .. "refresh.svg"
local GRID_ICON = ICONS .. "view-grid.svg"
local LIST_ICON = ICONS .. "view-list.svg"
local CLOSE_ICON = ICONS .. "close.svg"
local LINK_ICON = ICONS .. "link.svg"
local SETTINGS_ICON = ICONS .. "settings.svg"

local function safeText(value, limit)
    local text = tostring(value or "")
    if #text > (limit or 120) then return text:sub(1, (limit or 120) - 1) .. "…" end
    return text
end

local function pageBounds(page, per_page, total)
    local pages = math.max(1, math.ceil(math.max(0, total) / math.max(1, per_page)))
    page = math.max(1, math.min(page or 1, pages))
    local first = (page - 1) * per_page + 1
    local last = math.min(total, first + per_page - 1)
    return first, last, pages, page
end

local function tappable(widget, width, height, callback)
    local item = InputContainer:new{ dimen = Geom:new{ w = width, h = height }, widget }
    item.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = item.dimen } } }
    item.onTapSelect = function()
        if callback then callback() end
        return true
    end
    return item
end

local function iconTap(icon, width, height, callback, focused, selected, enabled)
    local icon_size = math.min(Style.scale(26), math.max(1, height - Style.scale(10)))
    local icon_widget
    if icon:find("/", 1, true) or icon:find("\\", 1, true) then
        icon_widget = IconWidget:new{ file = icon, width = icon_size, height = icon_size }
    else
        icon_widget = IconWidget:new{ icon = icon, width = icon_size, height = icon_size }
    end
    local inset = math.max(1, Style.thinBorder())
    local inner_w = math.max(1, width - 2 * inset)
    local inner_h = math.max(1, height - 2 * inset)
    local frame = FrameContainer:new{
        width = inner_w,
        height = inner_h,
        margin = 0,
        padding = 0,
        bordersize = focused and Style.focusBorder() or 0,
        color = Blitbuffer.COLOR_BLACK,
        radius = 0,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, icon_widget },
    }
    return tappable(
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, frame },
        width,
        height,
        function() if enabled ~= false and callback then callback() end end
    )
end

local function noCoverWidget(width, height, focused, selected, disabled)
    local border = focused and Style.focusBorder() or (selected and 2 or Style.thinBorder())
    return DeluxeCoverPlaceholder.new(width, height, {
        border = border,
        background = disabled and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
    })
end

local function framedCover(image, width, height, focused, selected, disabled, disposable)
    if not image then return nil end
    local border = focused and Style.focusBorder() or (selected and 2 or Style.thinBorder())
    local inner_w = math.max(1, width - 2 * border)
    local inner_h = math.max(1, height - 2 * border)
    local image_w, image_h = image:getWidth(), image:getHeight()
    if image_w > inner_w or image_h > inner_h then
        local scale = math.min(inner_w / image_w, inner_h / image_h)
        image_w = math.max(1, math.floor(image_w * scale))
        image_h = math.max(1, math.floor(image_h * scale))
        image = RenderImage:scaleBlitBuffer(image, image_w, image_h, disposable == true)
        disposable = true
    end
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = disabled and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            ImageWidget:new{ image = image, image_disposable = disposable == true, scale_factor = 1 },
        },
    }
end

local function cachedServerCover(server, entry, width, height, focused, selected, disabled)
    local path = CoverCache.cachedPath(server, entry.item)
    if not path then return nil end
    local border = focused and Style.focusBorder() or (selected and 2 or Style.thinBorder())
    local inner_w = math.max(1, width - 2 * border)
    local inner_h = math.max(1, height - 2 * border)
    local ok, scaled = pcall(function() return RenderImage:renderImageFile(path, false, inner_w, inner_h) end)
    if not ok or not scaled then return nil end
    return framedCover(scaled, width, height, focused, selected, disabled, true)
end

local function progressText(entry)
    local value = tonumber(entry and entry.percentage)
    if value == nil then return _("Progress: —") end
    if value <= 1.000001 then value = value * 100 end
    value = math.max(0, math.min(100, value))
    return T(_("Progress: %1"), string.format("%d%%", math.floor(value + 0.5)))
end

local function entryStatus(entry)
    return progressText(entry)
end

local function entryMetadataNote(entry)
    if entry.is_logical then
        return T(_("Linked · %1 versions"), tonumber(entry.version_count) or 0)
    end
    return nil
end

local function gridTitle(entry)
    local title = entry and entry.grid_title or nil
    if title == nil or tostring(title) == "" then return _("Unknown") end
    return tostring(title)
end

local function updatedText(timestamp)
    timestamp = math.max(0, tonumber(timestamp) or 0)
    if timestamp == 0 then return _("Cached") end
    local now = os.time()
    local same_day = os.date("%Y%m%d", timestamp) == os.date("%Y%m%d", now)
    local label = same_day and os.date("%H:%M", timestamp) or os.date("%m/%d %H:%M", timestamp)
    return T(_("Updated %1"), label)
end

function ServerLibraryBrowser:init()
    self.entries = self.entries or {}
    self.server = self.server or {}
    self.server_label = self.server_label or self.server.name or self.server.url or _("Server")
    DiagnosticLog.log("ui open", "Server library page", "server", self.server_label, "entries", #self.entries)
    self.servers = self.servers or { self.server }
    self.view_mode = self.view_mode == "list" and "list" or "grid"
    self.grid_columns = math.max(2, math.min(8, tonumber(self.grid_columns) or 4))
    self.grid_rows = math.max(1, math.min(6, tonumber(self.grid_rows) or 2))
    self.list_rows = math.max(4, math.min(12, tonumber(self.list_rows) or 6))
    self.can_link = self.can_link == true
    self.documents = self.documents or {}
    self.authoritative = self.authoritative == true
    self.logical_mode = self.logical_mode == true
    self.refreshed_at = math.max(0, tonumber(self.refreshed_at) or 0)
    self.loading = self.loading == true
    self.closed = false
    self.page = math.max(1, tonumber(self.page) or 1)
    self.selected = {}
    self.link_mode = false
    self.key_focus_active = not Dpad.isTouchDevice(Device)
    self.key_focus_region = self.key_focus_active and "books" or nil
    self.key_header_index = 1
    self.key_book_index = 1
    self.key_footer_index = 2
    self.cover_attempted = self.cover_attempted or {}
    self.cover_fetch_active = false
    self.cover_fetch_scheduled = false
    self.prepared_shelves = self.prepared_shelves or {}
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        BrowserSwipeNext = { GestureRange:new{ ges = "swipe", range = self.dimen, direction = "west" } },
        BrowserSwipePrev = { GestureRange:new{ ges = "swipe", range = self.dimen, direction = "east" } },
    }
    self.key_events = Dpad.pageKeyEvents(Device)
    self:updateItems()
    self:rememberCurrentShelf()
end

function ServerLibraryBrowser:currentShelfState()
    if self.loading or not self.server or not self.server.id then return nil end
    return {
        server = self.server,
        server_label = self.server_label,
        servers = self.servers,
        entries = self.entries,
        documents = self.documents,
        authoritative = self.authoritative,
        logical_mode = self.logical_mode,
        refreshed_at = self.refreshed_at,
        can_link = self.can_link,
        page = self.page,
        key_book_index = self.key_book_index,
        key_focus_region = self.key_focus_region,
        cover_attempted = self.cover_attempted,
    }
end

function ServerLibraryBrowser:rememberCurrentShelf()
    local state = self:currentShelfState()
    if not state then return false end
    self.prepared_shelves = self.prepared_shelves or {}
    self.prepared_shelves[tostring(state.server.id)] = state
    return true
end

function ServerLibraryBrowser:getPreparedShelf(server_id)
    if not server_id then return nil end
    return self.prepared_shelves and self.prepared_shelves[tostring(server_id)] or nil
end

function ServerLibraryBrowser:restorePreparedShelf(server_id)
    local state = self:getPreparedShelf(server_id)
    if not state then return false end
    return self:replaceLibrary(state, true)
end

function ServerLibraryBrowser:setLoading(server, server_label)
    if self.closed then return false end
    local previous_entries = self.entries
    local previous_server_id = self.server and self.server.id and tostring(self.server.id) or nil
    local target_server = server or self.server
    local target_server_id = target_server and target_server.id and tostring(target_server.id) or nil
    local switching_servers = previous_server_id and target_server_id and previous_server_id ~= target_server_id
    if switching_servers then
        self:rememberCurrentShelf()
    elseif previous_server_id and self.prepared_shelves then
        self.prepared_shelves[previous_server_id] = nil
    end
    self.loading = true
    self.server = target_server
    self.server_label = server_label or (self.server and (self.server.name or self.server.url)) or _("Server")
    self.entries = {}
    self.documents = {}
    self.authoritative = false
    self.logical_mode = false
    self.can_link = false
    self.page = 1
    self.selected = {}
    self.link_mode = false
    self.key_book_index = 1
    self.cover_attempted = {}
    self.cover_fetch_active = false
    self.cover_fetch_scheduled = false
    self:updateItems()
    if not switching_servers then self:releaseLocalCovers(previous_entries) end
    return true
end

function ServerLibraryBrowser:replaceLibrary(state, restoring_prepared)
    if self.closed then return false end
    state = state or {}
    local previous_entries = self.entries
    local previous_server_id = self.server and self.server.id and tostring(self.server.id) or nil
    local next_server = state.server or self.server
    local next_server_id = next_server and next_server.id and tostring(next_server.id) or nil
    local switching_servers = previous_server_id and next_server_id and previous_server_id ~= next_server_id
    if switching_servers then
        self:rememberCurrentShelf()
    elseif previous_server_id and not restoring_prepared and self.prepared_shelves then
        self.prepared_shelves[previous_server_id] = nil
    end
    self.server = next_server
    self.server_label = state.server_label or (self.server and (self.server.name or self.server.url)) or _("Server")
    self.servers = state.servers or self.servers or { self.server }
    self.entries = state.entries or {}
    self.documents = state.documents or {}
    self.authoritative = state.authoritative == true
    self.logical_mode = state.logical_mode == true
    self.refreshed_at = math.max(0, tonumber(state.refreshed_at) or 0)
    self.can_link = state.can_link == true
    self.loading = false
    self.page = math.max(1, tonumber(state.page) or 1)
    self.selected = {}
    self.link_mode = false
    self.key_book_index = math.max(1, tonumber(state.key_book_index) or 1)
    self.key_focus_region = state.key_focus_region or self.key_focus_region
    self.cover_attempted = state.cover_attempted or {}
    self.cover_fetch_active = false
    self.cover_fetch_scheduled = false
    self:updateItems()
    if not switching_servers and previous_entries ~= self.entries and not restoring_prepared then
        self:releaseLocalCovers(previous_entries)
    end
    self:rememberCurrentShelf()
    return true
end

function ServerLibraryBrowser:perPage()
    if self.view_mode == "list" then return math.max(1, self.list_rows) end
    return math.max(1, self.grid_columns * self.grid_rows)
end

function ServerLibraryBrowser:visibleBounds()
    local first, last, pages, page = pageBounds(self.page, self:perPage(), #self.entries)
    self.page = page
    return first, last, pages
end

function ServerLibraryBrowser:visibleEntries()
    local first, last = self:visibleBounds()
    local visible = {}
    for index = first, last do
        local entry = self.entries[index]
        if entry then
            entry._browser_index = index
            visible[#visible + 1] = entry
        end
    end
    return visible
end

function ServerLibraryBrowser:groupVisible(visible)
    local groups = {}
    for visible_index, entry in ipairs(visible) do
        local key = entry.has_metadata and "metadata" or "unavailable"
        local group = groups[#groups]
        if not group or group.key ~= key then
            group = { key = key, entries = {} }
            groups[#groups + 1] = group
        end
        group.entries[#group.entries + 1] = entry
    end
    return groups
end

function ServerLibraryBrowser:groupTitle(group)
    local total = 0
    for entry_index, entry in ipairs(self.entries) do
        if (group.key == "metadata" and entry.has_metadata) or (group.key == "unavailable" and not entry.has_metadata) then total = total + 1 end
    end
    return group.key == "metadata"
        and T(_("BOOKS WITH METADATA (%1)"), total)
        or T(_("METADATA UNAVAILABLE (%1)"), total)
end

function ServerLibraryBrowser:itemKey(entry)
    return tostring(entry and (entry.id or (entry.item and (entry.item.document or entry.item.logical_book_id))) or "")
end

function ServerLibraryBrowser:isSelected(entry)
    return self.selected[self:itemKey(entry)] == true
end

function ServerLibraryBrowser:selectedEntries()
    local out = {}
    for entry_index, entry in ipairs(self.entries) do if self:isSelected(entry) then out[#out + 1] = entry end end
    return out
end

function ServerLibraryBrowser:selectedCount()
    local count = 0
    for selected_key in pairs(self.selected) do count = count + 1 end
    return count
end

function ServerLibraryBrowser:isLinkSelectable(entry)
    return self.can_link and entry and not entry.is_logical and entry.item and entry.item.document
end

function ServerLibraryBrowser:localCover(entry)
    if not entry or not entry.match or not entry.match.path then return nil end
    if entry._local_cover_checked then return entry._local_cover end
    entry._local_cover_checked = true
    if not self.on_local_cover then return nil end
    local ok, cover = pcall(self.on_local_cover, self, entry)
    if ok and cover then entry._local_cover = cover end
    return entry._local_cover
end

function ServerLibraryBrowser:releaseLocalCovers(entries)
    for entry_index, entry in ipairs(entries or self.entries or {}) do
        local cover = entry and entry._local_cover or nil
        if cover and cover.free then pcall(function() cover:free() end) end
        if entry then
            entry._local_cover = nil
            entry._local_cover_checked = nil
        end
    end
end

function ServerLibraryBrowser:releaseAllLocalCovers()
    local released = {}
    local function release(entries)
        if not entries or released[entries] then return end
        released[entries] = true
        self:releaseLocalCovers(entries)
    end
    release(self.entries)
    for server_id, state in pairs(self.prepared_shelves or {}) do
        release(state and state.entries)
    end
    self.prepared_shelves = {}
end

function ServerLibraryBrowser:coverWidget(entry, width, height, focused, selected, disabled)
    local server_cover = cachedServerCover(self.server, entry, width, height, focused, selected, disabled)
    if server_cover then return server_cover, true end
    local local_cover = self:localCover(entry)
    if local_cover then
        return framedCover(local_cover, width, height, focused, selected, disabled, false), true
    end
    return noCoverWidget(width, height, focused, selected, disabled), false
end

function ServerLibraryBrowser:toggleSelection(entry)
    if not self:isLinkSelectable(entry) then
        if entry and entry.is_logical then UIManager:show(InfoMessage:new{ text = _("This book is already linked.") }) end
        return
    end
    local key = self:itemKey(entry)
    self.selected[key] = not self.selected[key] or nil
    self:updateItems()
end

function ServerLibraryBrowser:activateEntry(entry)
    if not entry then return end
    if self.link_mode then
        self:toggleSelection(entry)
        return
    end
    if self.on_open_entry then self.on_open_entry(self, entry) end
end

function ServerLibraryBrowser:setLinkMode(enabled)
    if not self.can_link then return end
    self.link_mode = enabled == true
    if not self.link_mode then self.selected = {} end
    self.key_focus_region = "books"
    self:updateItems()
end

function ServerLibraryBrowser:toggleLinkModeFromHeader()
    if self.loading then return end
    if not self.can_link then
        UIManager:show(InfoMessage:new{ text = _("This server does not support book linking.") })
        return
    end
    self:setLinkMode(not self.link_mode)
end

function ServerLibraryBrowser:confirmLink()
    local selected = self:selectedEntries()
    if #selected < 2 then
        UIManager:show(InfoMessage:new{ text = _("Select at least two unlinked books to link.") })
        return
    end
    if self.on_link_selected then self.on_link_selected(self, selected) end
end

function ServerLibraryBrowser:toggleView()
    self.view_mode = self.view_mode == "grid" and "list" or "grid"
    self.page = 1
    self.key_book_index = 1
    if self.on_view_mode_change then self.on_view_mode_change(self.view_mode) end
    self:updateItems()
end

function ServerLibraryBrowser:setLayout(columns, rows, list_rows)
    self.grid_columns = math.max(2, math.min(8, tonumber(columns) or 4))
    self.grid_rows = math.max(1, math.min(6, tonumber(rows) or 2))
    self.list_rows = math.max(4, math.min(12, tonumber(list_rows) or 6))
    local first, last, pages, page = pageBounds(self.page, self:perPage(), #self.entries)
    self.page = page
    self.key_book_index = 1
    if self.on_layout_change then self.on_layout_change(self.grid_columns, self.grid_rows, self.list_rows) end
    self:updateItems()
end

function ServerLibraryBrowser:showLayoutSettings()
    if self.link_mode then return end
    local values = {
        grid_columns = self.grid_columns,
        grid_rows = self.grid_rows,
        list_rows = self.list_rows,
    }
    local dialog
    local function valueText(label, value) return T(_("%1: %2"), label, value) end
    local function refreshValues()
        local fields = {
            grid_columns_value = valueText(_("Columns"), values.grid_columns),
            grid_rows_value = valueText(_("Rows"), values.grid_rows),
            list_rows_value = valueText(_("Rows per page"), values.list_rows),
        }
        for field_id, text in pairs(fields) do
            local button = dialog and dialog:getButtonById(field_id)
            if button then button:setText(text, button.width) end
        end
        if dialog then UIManager:setDirty(dialog, "ui") end
    end
    local function adjust(key, delta, minimum, maximum)
        values[key] = math.max(minimum, math.min(maximum, values[key] + delta))
        refreshValues()
    end
    dialog = ButtonDialog:new{
        title = _("Synced Books Layout"),
        title_align = "left",
        width_factor = 0.94,
        buttons = {
            {{ text = _("Grid (Book Cards)"), enabled = false }},
            {
                { text = "−", callback = function() adjust("grid_columns", -1, 2, 8) end },
                { id = "grid_columns_value", text = valueText(_("Columns"), values.grid_columns), enabled = false },
                { text = "+", callback = function() adjust("grid_columns", 1, 2, 8) end },
            },
            {
                { text = "−", callback = function() adjust("grid_rows", -1, 1, 6) end },
                { id = "grid_rows_value", text = valueText(_("Rows"), values.grid_rows), enabled = false },
                { text = "+", callback = function() adjust("grid_rows", 1, 1, 6) end },
            },
            {{ text = _("List (Book List)"), enabled = false }},
            {
                { text = "−", callback = function() adjust("list_rows", -1, 4, 12) end },
                { id = "list_rows_value", text = valueText(_("Rows per page"), values.list_rows), enabled = false },
                { text = "+", callback = function() adjust("list_rows", 1, 4, 12) end },
            },
            {
                { text = _("Reset"), callback = function()
                    values.grid_columns, values.grid_rows, values.list_rows = 4, 2, 6
                    refreshValues()
                end },
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Save"), callback = function()
                    UIManager:close(dialog)
                    self:setLayout(values.grid_columns, values.grid_rows, values.list_rows)
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function ServerLibraryBrowser:closePage()
    if self.closed then return end
    if self.link_mode then self:setLinkMode(false); return end
    if self.on_close then self.on_close(self) else UIManager:close(self) end
end

function ServerLibraryBrowser:refreshPage()
    if self.closed or self.loading or self.link_mode then return end
    if self.on_refresh then self.on_refresh(self) end
end

function ServerLibraryBrowser:cycleServer()
    if self.closed or self.loading or self.link_mode or #self.servers < 2 then return end
    if self.on_cycle_server then self.on_cycle_server(self) end
end

function ServerLibraryBrowser:isHeaderFocused(index)
    return self.key_focus_active and self.key_focus_region == "header" and self.key_header_index == index
end

function ServerLibraryBrowser:isBookFocused(entry)
    if not self.key_focus_active or self.key_focus_region ~= "books" then return false end
    local visible = self:visibleEntries()
    return visible[self.key_book_index] == entry
end

function ServerLibraryBrowser:isFooterFocused(index)
    return self.key_focus_active and self.key_focus_region == "footer" and self.key_footer_index == index
end

function ServerLibraryBrowser:headerWidget(width, height)
    local line_h = math.max(1, Style.thinBorder())
    local row_h = math.max(1, height - line_h)
    local icon_w = row_h
    local title_w = math.max(1, width - 6 * icon_w)
    local title = self.loading
        and T(_("%1 · Loading…"), self.server_label)
        or (self.link_mode
            and T(_("LINK BOOKS · %1 selected"), self:selectedCount())
            or T(_("%1 · %2 books · %3"), self.server_label, #self.entries, updatedText(self.refreshed_at)))
    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, iconTap(SWAP_ICON, icon_w, row_h, function() self:cycleServer() end, self:isHeaderFocused(1), false, not self.loading and not self.link_mode and #self.servers > 1))
    table.insert(row, CenterContainer:new{
        dimen = Geom:new{ w = title_w, h = row_h },
        TextWidget:new{
            text = safeText(title, 72),
            face = Font:getFace("smallinfofontbold", Style.action_font),
            bold = true,
            max_width = title_w - Style.scale(8),
        },
    })
    table.insert(row, iconTap(REFRESH_ICON, icon_w, row_h, function() self:refreshPage() end, self:isHeaderFocused(2), false, not self.loading and not self.link_mode))
    table.insert(row, iconTap(SETTINGS_ICON, icon_w, row_h, function() self:showLayoutSettings() end, self:isHeaderFocused(3), false, not self.loading and not self.link_mode))
    table.insert(row, iconTap(LINK_ICON, icon_w, row_h, function() self:toggleLinkModeFromHeader() end, self:isHeaderFocused(4), self.link_mode, not self.loading))
    local toggle_icon = self.view_mode == "grid" and LIST_ICON or GRID_ICON
    table.insert(row, iconTap(toggle_icon, icon_w, row_h, function() self:toggleView() end, self:isHeaderFocused(5), false, not self.loading))
    table.insert(row, iconTap(CLOSE_ICON, icon_w, row_h, function() self:closePage() end, self:isHeaderFocused(6), false, true))
    local underline = FrameContainer:new{
        width = width,
        height = line_h,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = line_h }, HorizontalSpan:new{ width = width } },
    }
    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = width, h = row_h }, row },
        underline,
    }
end

function ServerLibraryBrowser:loadingWidget(width, height)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        TextWidget:new{
            text = T(_("Loading synced books from %1…"), self.server_label),
            face = Font:getFace("smallinfofontbold", Style.action_font),
            bold = true,
            max_width = math.max(1, width - 2 * Style.sectionPadding()),
        },
    }
end

function ServerLibraryBrowser:groupHeader(group, width, height)
    local inset = Style.sectionPadding()
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        LeftContainer:new{
            dimen = Geom:new{ w = width, h = height },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = inset },
                TextWidget:new{
                    text = self:groupTitle(group),
                    face = Font:getFace("smallinfofontbold", Style.section_font),
                    bold = true,
                    max_width = math.max(1, width - 2 * inset),
                },
            },
        },
    }
end

function ServerLibraryBrowser:gridWidget(width, height)
    local visible = self:visibleEntries()
    if #visible == 0 then
        return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, TextWidget:new{ text = _("No synced books to display."), face = Font:getFace("infofont") } }
    end
    local groups = self:groupVisible(visible)
    local cols = self.grid_columns
    local gap = Style.gridGap()
    local group_h = Style.sectionHeight()
    local title_h = Style.scale(18)
    local status_h = Style.scale(20)
    local item_gap = Style.scale(2)
    local book_rows = 0
    for group_index, group in ipairs(groups) do book_rows = book_rows + math.ceil(#group.entries / cols) end
    local gap_rows = #groups + book_rows + 1
    local cell_h = math.max(1, math.floor((height - #groups * group_h - gap_rows * gap) / math.max(1, book_rows)))
    local cell_w = math.max(1, math.floor((width - (cols + 1) * gap) / cols))
    local grid = VerticalGroup:new{ align = "center" }

    local function bookCell(entry)
        local cover_area_h = math.max(1, cell_h - title_h - status_h - 2 * item_gap)
        local cover_w = math.max(1, math.min(cell_w, math.floor(cover_area_h / 1.5)))
        local cover_h = math.max(1, math.min(cover_area_h, math.floor(cover_w * 1.5)))
        local focused = self:isBookFocused(entry)
        local selected = self:isSelected(entry)
        local disabled = self.link_mode and not self:isLinkSelectable(entry)
        local card = VerticalGroup:new{ align = "center" }
        local cover = self:coverWidget(entry, cover_w, cover_h, focused, selected, disabled)
        table.insert(card, cover)
        table.insert(card, VerticalSpan:new{ width = item_gap })
        table.insert(card, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = title_h },
            TextWidget:new{
                text = safeText(gridTitle(entry), 32),
                face = Font:getFace("cfont", Style.tertiary_font),
                bold = true,
                max_width = math.max(1, cell_w - Style.scale(4)),
            },
        })
        table.insert(card, VerticalSpan:new{ width = item_gap })
        table.insert(card, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = status_h },
            TextWidget:new{
                text = self.link_mode and (selected and _("✓ Selected") or (disabled and _("Linked") or _("Select"))) or entryStatus(entry),
                face = Font:getFace("cfont", Style.grid_status_font),
                bold = true,
                max_width = cell_w,
            },
        })
        return tappable(CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h }, card }, cell_w, cell_h, function() self:activateEntry(entry) end)
    end

    for group_index, group in ipairs(groups) do
        table.insert(grid, VerticalSpan:new{ width = gap })
        table.insert(grid, self:groupHeader(group, width, group_h))
        local index = 1
        while index <= #group.entries do
            table.insert(grid, VerticalSpan:new{ width = gap })
            local row = HorizontalGroup:new{ align = "center" }
            table.insert(row, HorizontalSpan:new{ width = gap })
            for column_index = 1, cols do
                local entry = group.entries[index]
                if entry then table.insert(row, bookCell(entry)) else table.insert(row, HorizontalSpan:new{ width = cell_w }) end
                table.insert(row, HorizontalSpan:new{ width = gap })
                index = index + 1
            end
            table.insert(grid, row)
        end
    end
    return grid
end

function ServerLibraryBrowser:listWidget(width, height)
    local visible = self:visibleEntries()
    if #visible == 0 then
        return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, TextWidget:new{ text = _("No synced books to display."), face = Font:getFace("infofont") } }
    end
    local groups = self:groupVisible(visible)
    local rows = self:perPage()
    local pad = Style.listPadding()
    local group_h = Style.sectionHeight()
    local row_h = math.max(1, math.floor((height - #groups * group_h) / rows))
    local status_face = Font:getFace("cfont", 15)
    local status_w = Style.scale(58)
    for visible_index, entry in ipairs(visible) do
        local probe_text = self.link_mode and _("✓ Selected") or entryStatus(entry)
        local probe = TextWidget:new{ text = probe_text, face = status_face, bold = true }
        status_w = math.max(status_w, probe:getSize().w + 2 * pad)
    end
    status_w = math.min(status_w, math.floor(width * 0.30))
    local list = VerticalGroup:new{ align = "center" }

    local function appendRow(entry)
        local cover_h = math.max(1, row_h - 2 * pad)
        local cover_w = math.max(1, math.floor(cover_h * 0.66))
        local meta_w = math.max(1, width - cover_w - status_w - 5 * pad)
        local focused = self:isBookFocused(entry)
        local selected = self:isSelected(entry)
        local disabled = self.link_mode and not self:isLinkSelectable(entry)
        local cover = self:coverWidget(entry, cover_w, cover_h, false, selected, disabled)
        local meta = VerticalGroup:new{ align = "left" }
        table.insert(meta, TextWidget:new{
            text = safeText(entry.title or _("Untitled"), 120),
            face = Font:getFace("cfont", 18),
            bold = true,
            max_width = meta_w,
        })
        if entry.author and entry.author ~= "" then
            table.insert(meta, TextWidget:new{
                text = safeText(entry.author, 90),
                face = Font:getFace("smallinfofont", Style.secondary_font),
                max_width = meta_w,
            })
        end
        local metadata_note = entryMetadataNote(entry)
        if metadata_note then
            table.insert(meta, TextWidget:new{
                text = metadata_note,
                face = Font:getFace("smallinfofont", Style.tertiary_font),
                max_width = meta_w,
            })
        end
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, HorizontalSpan:new{ width = pad })
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = 2 * pad })
        table.insert(row, CenterContainer:new{ dimen = Geom:new{ w = meta_w, h = row_h }, LeftContainer:new{ dimen = Geom:new{ w = meta_w, h = row_h }, meta } })
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = status_w, h = row_h },
            TextBoxWidget:new{
                text = self.link_mode and (selected and _("✓ Selected") or (disabled and entryStatus(entry) or _("Select"))) or entryStatus(entry),
                width = status_w - 2 * pad,
                alignment = "center",
                face = status_face,
                bold = true,
                height_overflow_show_ellipsis = true,
            },
        })
        table.insert(row, HorizontalSpan:new{ width = pad })
        local frame = FrameContainer:new{
            width = width,
            height = row_h,
            margin = 0,
            padding = 0,
            bordersize = focused and Style.focusBorder() or Style.thinBorder(),
            color = Blitbuffer.COLOR_BLACK,
            background = disabled and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
            row,
        }
        table.insert(list, tappable(frame, width, row_h, function() self:activateEntry(entry) end))
    end

    local shown = 0
    for group_index, group in ipairs(groups) do
        table.insert(list, self:groupHeader(group, width, group_h))
        for entry_index, entry in ipairs(group.entries) do appendRow(entry); shown = shown + 1 end
    end
    for filler_index = shown + 1, rows do table.insert(list, VerticalSpan:new{ width = row_h }) end
    return list
end

function ServerLibraryBrowser:footerWidget(width, height)
    if self.loading then
        return FrameContainer:new{
            width = width, height = height, margin = 0, padding = 0, bordersize = Style.thinBorder(), background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, TextWidget:new{ text = _("Loading…"), face = Font:getFace("smallinfofont", Style.tertiary_font) } },
        }
    end
    local first, last, pages = self:visibleBounds()
    if self.link_mode then
        local half = math.floor(width / 2)
        local function footerButton(text, button_width, index, callback)
            local focused = self:isFooterFocused(index)
            local frame = FrameContainer:new{
                width = button_width, height = height, margin = 0, padding = 0,
                bordersize = focused and Style.focusBorder() or Style.thinBorder(),
                background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
                CenterContainer:new{
                    dimen = Geom:new{ w = button_width, h = height },
                    TextWidget:new{ text = text, face = Font:getFace("smallinfofontbold", Style.action_font), bold = true, max_width = button_width - Style.scale(10) },
                },
            }
            return tappable(frame, button_width, height, callback)
        end
        return HorizontalGroup:new{
            align = "center",
            footerButton(_("Cancel Link Mode"), half, 1, function() self:setLinkMode(false) end),
            footerButton(T(_("Link %1 Books"), self:selectedCount()), width - half, 2, function() self:confirmLink() end),
        }
    end
    local current = math.max(1, math.min(self.page, pages))
    local can_back = current > 1
    local can_forward = current < pages
    local nav_w = math.floor(width * 0.86)
    local icon_size = math.floor(height * 0.60)
    local function slot(ratio) return math.max(1, math.floor(nav_w * ratio)) end
    local first_button = Button:new{ icon = "chevron.first", icon_width = icon_size, icon_height = icon_size, width = slot(0.18), enabled = can_back, callback = function() self:setPage(1) end, margin = 0, bordersize = 0, show_parent = self }
    local previous_button = Button:new{ icon = "chevron.left", icon_width = icon_size, icon_height = icon_size, width = slot(0.18), enabled = can_back, callback = function() self:setPage(current - 1) end, margin = 0, bordersize = 0, show_parent = self }
    local page_button = Button:new{ text = T(_("Page %1 of %2"), current, pages), text_font_face = "cfont", text_font_size = Style.tertiary_font, width = slot(0.28), margin = 0, bordersize = 0, show_parent = self }
    local next_button = Button:new{ icon = "chevron.right", icon_width = icon_size, icon_height = icon_size, width = slot(0.18), enabled = can_forward, callback = function() self:setPage(current + 1) end, margin = 0, bordersize = 0, show_parent = self }
    local last_button = Button:new{ icon = "chevron.last", icon_width = icon_size, icon_height = icon_size, width = slot(0.18), enabled = can_forward, callback = function() self:setPage(pages) end, margin = 0, bordersize = 0, show_parent = self }
    return FrameContainer:new{
        width = width, height = height, margin = 0, padding = 0, bordersize = Style.thinBorder(), background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalGroup:new{ align = "center", first_button, previous_button, page_button, next_button, last_button } },
    }
end

function ServerLibraryBrowser:pendingVisibleCover()
    for visible_index, entry in ipairs(self:visibleEntries()) do
        local key = self:itemKey(entry)
        if entry.item and entry.item.cover_url and not CoverCache.cachedPath(self.server, entry.item) and not self.cover_attempted[key] then
            return entry, key
        end
    end
end

function ServerLibraryBrowser:scheduleVisibleCoverPrefetch()
    if self.cover_fetch_active or self.cover_fetch_scheduled then return false end
    if not self:pendingVisibleCover() then return false end
    self.cover_fetch_scheduled = true
    UIManager:nextTick(function()
        self.cover_fetch_scheduled = false
        if self[1] then self:prefetchVisibleCover() end
    end)
    return true
end

function ServerLibraryBrowser:prefetchVisibleCover()
    if self.cover_fetch_active then return end
    local entry, key = self:pendingVisibleCover()
    if not entry then return end
    self.cover_attempted[key] = true
    self.cover_fetch_active = true
    local ok, downloaded_path = pcall(CoverCache.download, self.server, entry.item)
    self.cover_fetch_active = false
    if not self[1] then return end
    if ok and downloaded_path then
        self:updateItems()
    else
        self:scheduleVisibleCoverPrefetch()
    end
end

function ServerLibraryBrowser:updateCounts()
    local metadata, unavailable = 0, 0
    for entry_index, entry in ipairs(self.entries) do
        if entry.has_metadata then metadata = metadata + 1 else unavailable = unavailable + 1 end
    end
    self.metadata_count = metadata
    self.unavailable_count = unavailable
end

function ServerLibraryBrowser:updateItems()
    self:updateCounts()
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.dimen.w = self.width
    self.dimen.h = self.height
    local header_h = Style.headerHeight()
    local footer_h = self.link_mode and Style.headerHeight() or Style.scale(34)
    local content_h = math.max(Style.scale(100), self.height - header_h - footer_h)
    local shelf = self.loading
        and self:loadingWidget(self.width, content_h)
        or (self.view_mode == "list" and self:listWidget(self.width, content_h) or self:gridWidget(self.width, content_h))
    local root = VerticalGroup:new{
        align = "center",
        self:headerWidget(self.width, header_h),
        shelf,
        self:footerWidget(self.width, footer_h),
    }
    local frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        root,
    }
    if self[1] and self[1].free then self[1]:free() end
    self[1] = frame
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:scheduleVisibleCoverPrefetch()
end

function ServerLibraryBrowser:setPage(page)
    local first, last, pages = self:visibleBounds()
    local next_page = math.max(1, math.min(pages, tonumber(page) or 1))
    if next_page ~= self.page then
        self.page = next_page
        self.key_book_index = 1
        self.key_focus_region = "books"
        self:updateItems()
    end
    return true
end

function ServerLibraryBrowser:changePage(delta)
    return self:setPage(self.page + delta)
end

function ServerLibraryBrowser:onBrowserSwipeNext() return self:changePage(1) end
function ServerLibraryBrowser:onBrowserSwipePrev() return self:changePage(-1) end

function ServerLibraryBrowser:moveBooks(direction)
    local visible = self:visibleEntries()
    if #visible == 0 then self.key_focus_region = "header"; self:updateItems(); return true end
    local index = math.max(1, math.min(#visible, self.key_book_index or 1))
    if self.view_mode == "list" then
        if direction == "up" then
            if index > 1 then index = index - 1 else self.key_focus_region = "header" end
        elseif direction == "down" then
            if index < #visible then index = index + 1 elseif self.link_mode then self.key_focus_region = "footer" end
        elseif direction == "left" then return self:changePage(-1)
        elseif direction == "right" then return self:changePage(1) end
    else
        local cols = self.grid_columns
        if direction == "left" then
            if index > 1 then index = index - 1 else return self:changePage(-1) end
        elseif direction == "right" then
            if index < #visible then index = index + 1 else return self:changePage(1) end
        elseif direction == "up" then
            if index > cols then index = index - cols else self.key_focus_region = "header" end
        elseif direction == "down" then
            if index + cols <= #visible then
                index = index + cols
            elseif index < #visible then
                index = #visible
            elseif self.link_mode then
                self.key_focus_region = "footer"
            end
        end
    end
    self.key_book_index = index
    self:updateItems()
    return true
end

function ServerLibraryBrowser:moveFocus(direction)
    if not self.key_focus_active then
        self.key_focus_active = true
        self.key_focus_region = #self.entries > 0 and "books" or "header"
        self:updateItems()
        return true
    end
    if self.key_focus_region == "header" then
        if direction == "left" then self.key_header_index = math.max(1, self.key_header_index - 1)
        elseif direction == "right" then self.key_header_index = math.min(6, self.key_header_index + 1)
        elseif direction == "down" then self.key_focus_region = "books" end
        self:updateItems()
        return true
    elseif self.key_focus_region == "books" then
        return self:moveBooks(direction)
    elseif self.key_focus_region == "footer" then
        if direction == "left" or direction == "right" then self.key_footer_index = self.key_footer_index == 1 and 2 or 1
        elseif direction == "up" then self.key_focus_region = "books" end
        self:updateItems()
        return true
    end
    return true
end

function ServerLibraryBrowser:onDpadUp() return self:moveFocus("up") end
function ServerLibraryBrowser:onDpadDown() return self:moveFocus("down") end
function ServerLibraryBrowser:onDpadLeft() return self:moveFocus("left") end
function ServerLibraryBrowser:onDpadRight() return self:moveFocus("right") end
function ServerLibraryBrowser:onDpadPrevPage() return self:changePage(-1) end
function ServerLibraryBrowser:onDpadNextPage() return self:changePage(1) end

function ServerLibraryBrowser:onDpadPress()
    if not self.key_focus_active then return self:moveFocus("down") end
    if self.key_focus_region == "header" then
        if self.loading and self.key_header_index ~= 6 then return true end
        local actions = {
            function() self:cycleServer() end,
            function() self:refreshPage() end,
            function() self:showLayoutSettings() end,
            function() self:toggleLinkModeFromHeader() end,
            function() self:toggleView() end,
            function() self:closePage() end,
        }
        local action = actions[self.key_header_index]
        if action then action() end
    elseif self.key_focus_region == "books" then
        self:activateEntry(self:visibleEntries()[self.key_book_index])
    elseif self.key_focus_region == "footer" then
        if self.key_footer_index == 1 then self:setLinkMode(false) else self:confirmLink() end
    end
    return true
end

function ServerLibraryBrowser:onDpadMenu()
    self:toggleLinkModeFromHeader()
    return true
end

function ServerLibraryBrowser:onDpadBack()
    self:closePage()
    return true
end

function ServerLibraryBrowser:onClose()
    self:closePage()
    return true
end

return ServerLibraryBrowser
