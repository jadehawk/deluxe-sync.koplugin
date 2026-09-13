local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template
local util = require("util")
local Dpad = require("DeluxeDpad")
local Style = require("DeluxeUIStyle")
local DiagnosticLog = require("DiagnosticLog")

local ServerSettingsPage = InputContainer:extend{
    name = "deluxe_sync_server_settings_page",
    covers_fullscreen = true,
}

local function tapContainer(widget, width, height, callback)
    local item = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        widget,
    }
    if callback then
        item.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = item.dimen } },
        }
        item.onTapSelect = function()
            callback()
            return true
        end
    end
    return item
end

local function boolText(value)
    return value and _("ON") or _("OFF")
end

local function capabilityText(value)
    if value == true then return _("Supported") end
    if value == false then return _("Not supported") end
    return _("Unknown")
end

local function showUnsupportedFeature()
    UIManager:show(InfoMessage:new{ text = _("Feature not supported by remote server") })
end

local function ellipsize(value, max_chars)
    value = tostring(value or "")
    max_chars = math.max(6, tonumber(max_chars) or 36)
    if #value <= max_chars then return value end
    return value:sub(1, max_chars - 1) .. "…"
end

local function maskEmail(email)
    email = tostring(email or "")
    if email == "" then return _("Not set") end
    local local_part, domain = email:match("^([^@]+)@(.+)$")
    if not local_part or not domain then return ellipsize(email, 30) end
    return local_part:sub(1, 1) .. "***@" .. ellipsize(domain, 24)
end

local function defaultDraft(server)
    local draft = util.tableDeepCopy(server or {})
    draft.name = draft.name or ""
    draft.url = draft.url or ""
    draft.username = draft.username or ""
    draft.email = draft.email or ""
    draft.enabled = draft.enabled ~= false
    draft.metadata_enabled = draft.metadata_enabled ~= false
    draft.annotations_enabled = draft.annotations_enabled == true
    draft.reading_statistics_enabled = draft.reading_statistics_enabled == true
    draft.settings_backup_enabled = draft.settings_backup_enabled == true
    draft.deluxe_config_backup_enabled = draft.deluxe_config_backup_enabled == true
    draft.vocabulary_enabled = draft.vocabulary_enabled == true
    draft.vocabulary_context_enabled = draft.vocabulary_enabled and draft.vocabulary_context_enabled == true or false
    draft.checksum_method = draft.checksum_method == "filename" and "filename" or "binary"
    draft.capabilities = draft.capabilities or {}
    return draft
end

function ServerSettingsPage:init()
    self.server = self.server or {}
    self.is_new = self.is_new == true or self.server.id == nil
    DiagnosticLog.log("ui open", "Server settings page", "server", self.server.name or self.server.url or "new", "new", self.is_new)
    self.label_fn = self.label_fn or function(server) return server.name or server.url or _("Server") end
    self.draft = defaultDraft(self.server)
    self.password = ""
    self.dirty = false
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.key_focus_active = not Dpad.isTouchDevice(Device)
    self.key_focus_region = self.key_focus_active and "body" or nil
    self.key_header_index = 1
    self.key_body_row = 1
    self.key_body_col = 1
    self.key_events = Dpad.pageKeyEvents(Device)
    self:updateItems()
end

function ServerSettingsPage:serverTitle()
    if self.is_new then return _("Add Server") end
    return self.label_fn(self.draft)
end

function ServerSettingsPage:applySavedServer(server)
    if type(server) ~= "table" then return end
    self.server = server
    self.is_new = false
    self.draft = defaultDraft(server)
    self.password = ""
    self.dirty = false
    self:updateItems()
end

function ServerSettingsPage:markDirty()
    self.dirty = true
end

function ServerSettingsPage:closePage()
    if self.on_back then
        self.on_back(self)
    else
        UIManager:close(self)
    end
end

function ServerSettingsPage:requestBack()
    if not self.dirty then
        self:closePage()
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = _("Discard unsaved changes?"),
        title_align = "left",
        buttons = {
            {{ text = _("Your changes have not been saved."), enabled = false }},
            {
                { text = _("Keep editing"), callback = function() UIManager:close(dialog) end },
                { text = _("Discard"), callback = function()
                    UIManager:close(dialog)
                    self.dirty = false
                    self:closePage()
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function ServerSettingsPage:editTextField(title, field, hint, text_type)
    local dialog
    local initial = field == "password" and "" or tostring(self.draft[field] or "")
    dialog = MultiInputDialog:new{
        title = title,
        title_align = "left",
        fields = {{
            text = initial,
            hint = hint or title,
            text_type = text_type,
        }},
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = (dialog:getFields()[1]) or ""
                if field == "password" then
                    self.password = value
                else
                    self.draft[field] = util.trim(value)
                end
                self:markDirty()
                UIManager:close(dialog)
                self:updateItems()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ServerSettingsPage:toggleSharing(field)
    if field == "vocabulary_context_enabled" and self.draft.vocabulary_enabled ~= true then
        UIManager:show(InfoMessage:new{ text = _("Enable Vocabulary Builder before sharing reading context.") })
        return
    end
    self.draft[field] = not (self.draft[field] == true)
    if field == "vocabulary_enabled" and not self.draft.vocabulary_enabled then
        self.draft.vocabulary_context_enabled = false
    end
    self:markDirty()
    self:updateItems()
    if field == "deluxe_config_backup_enabled" and self.draft[field] then
        UIManager:show(InfoMessage:new{
            text = _("Deluxe-Sync Config Backup includes server URLs, usernames, and saved authentication keys. Enable it only for a server you trust."),
        })
    elseif field == "vocabulary_context_enabled" and self.draft[field] then
        UIManager:show(InfoMessage:new{
            text = _("Vocabulary Reading Context can include surrounding book passages and highlighted text."),
        })
    end
end

function ServerSettingsPage:headerActions()
    return {
        function() self:requestBack() end,
        function()
            if self.on_save then self.on_save(self, self.draft, self.password) end
        end,
    }
end

function ServerSettingsPage:isHeaderFocused(index)
    return self.key_focus_active and self.key_focus_region == "header" and self.key_header_index == index
end

function ServerSettingsPage:isBodyFocused(row, col)
    return self.key_focus_active and self.key_focus_region == "body"
        and self.key_body_row == row and self.key_body_col == col
end

function ServerSettingsPage:headerButton(text, width, height, callback, focused)
    local border = focused and Style.focusBorder() or Style.thinBorder()
    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            TextWidget:new{
                text = text,
                face = Font:getFace("smallinfofontbold", Style.action_font),
                bold = true,
                max_width = math.max(1, width - Style.scale(10)),
            },
        },
    }
    return tapContainer(frame, width, height, callback)
end

function ServerSettingsPage:headerWidget(width, height)
    local side_width = math.floor(width * 0.25)
    local title_width = math.max(1, width - 2 * side_width)
    local save_text = self.is_new and _("Sign in") or (self.dirty and _("Save *") or _("Close"))
    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, self:headerButton(_("‹ Servers"), side_width, height, function() self:requestBack() end, self:isHeaderFocused(1)))
    table.insert(row, CenterContainer:new{
        dimen = Geom:new{ w = title_width, h = height },
        TextWidget:new{
            text = ellipsize(self:serverTitle(), 30),
            face = Font:getFace("smallinfofontbold", Style.header_font),
            bold = true,
            max_width = math.max(1, title_width - Style.scale(8)),
        },
    })
    table.insert(row, self:headerButton(save_text, side_width, height, function()
        if not self.is_new and not self.dirty then
            self:requestBack()
            return
        end
        if self.on_save then self.on_save(self, self.draft, self.password) end
    end, self:isHeaderFocused(2)))
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
end

function ServerSettingsPage:sectionTitle(text, width)
    local height = Style.sectionHeight()
    local inset = Style.sectionPadding()
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            TextWidget:new{
                text = text,
                face = Font:getFace("smallinfofontbold", Style.section_font),
                bold = true,
                max_width = math.max(1, width - 2 * inset),
            },
        },
    }
end

function ServerSettingsPage:cellWidget(cell, width, height, focus_row, focus_col)
    local focused = cell.callback and self:isBodyFocused(focus_row, focus_col)
    local border = focused and Style.focusBorder() or Style.thinBorder()
    local padding = Style.cellPadding()
    local value_right_inset = Style.scale(6)
    local available = math.max(1, width - 2 * padding - value_right_inset)
    local value = tostring(type(cell.value) == "function" and cell.value() or cell.value or "")
    local value_face = "smallinfofontbold"
    if cell.centered then
        local text = tostring(cell.label or value or "")
        local inner_height = math.max(1, height - 2 * padding)
        local background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
        if cell.danger and not focused then background = Blitbuffer.COLOR_LIGHT_GRAY end
        local frame = FrameContainer:new{
            width = width,
            height = height,
            margin = 0,
            padding = padding,
            bordersize = border,
            color = Blitbuffer.COLOR_BLACK,
            background = background,
            CenterContainer:new{
                dimen = Geom:new{ w = available, h = inner_height },
                TextWidget:new{
                    text = text,
                    face = Font:getFace(value_face, Style.value_font),
                    bold = true,
                    max_width = available,
                },
            },
        }
        return tapContainer(frame, width, height, cell.callback)
    end
    local value_text = value
    if cell.callback then value_text = value ~= "" and (value .. "  ›") or "›" end
    local label_text = tostring(cell.label or "")
    if value ~= "" then label_text = label_text .. ":" end
    local inner_height = math.max(1, height - 2 * padding)
    local label_widget = TextWidget:new{
        text = label_text,
        face = Font:getFace("smallinfofont", Style.setting_label_font),
        max_width = available,
    }
    local label_natural_width = math.min(available, label_widget:getSize().w)
    local value_widget
    local value_width = 0
    local value_gap = 0
    if value_text ~= "" then
        value_gap = math.min(6, math.max(0, available - label_natural_width - 1))
        local value_max_width = math.max(1, available - label_natural_width - value_gap)
        value_widget = TextWidget:new{
            text = value_text,
            face = Font:getFace(value_face, Style.value_font),
            max_width = value_max_width,
        }
        value_width = math.min(value_max_width, value_widget:getSize().w)
    end
    local label_width = math.max(label_natural_width, available - value_width - value_gap)
    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, LeftContainer:new{
        dimen = Geom:new{ w = label_width, h = inner_height },
        label_widget,
    })
    if value_widget then
        if value_gap > 0 then table.insert(row, HorizontalSpan:new{ width = value_gap }) end
        table.insert(row, RightContainer:new{
            dimen = Geom:new{ w = value_width, h = inner_height },
            value_widget,
        })
    end
    local body = LeftContainer:new{
        dimen = Geom:new{ w = available, h = math.max(1, height - 2 * padding) },
        row,
    }
    local background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
    if cell.danger and not focused then background = Blitbuffer.COLOR_LIGHT_GRAY end
    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = padding,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = background,
        body,
    }
    return tapContainer(frame, width, height, cell.callback)
end

function ServerSettingsPage:addSection(content, text, body_width, visual_state)
    table.insert(content, VerticalSpan:new{ width = Style.sectionGap() })
    table.insert(content, self:sectionTitle(text, body_width))
    visual_state.rows = visual_state.rows + 1
end

function ServerSettingsPage:addCellRow(content, left, right, body_width, cell_width, gap, cell_height, visual_state)
    visual_state.rows = visual_state.rows + 1
    local focus_row
    if (left and left.callback) or (right and right.callback) then
        focus_row = #self.focus_rows + 1
        self.focus_rows[focus_row] = {
            left and left.callback or false,
            right and right.callback or false,
        }
        self.focus_visual_rows[focus_row] = visual_state.rows
    end
    local row = HorizontalGroup:new{ align = "center" }
    if left then
        table.insert(row, self:cellWidget(left, cell_width, cell_height, focus_row, 1))
    else
        table.insert(row, HorizontalSpan:new{ width = cell_width })
    end
    table.insert(row, HorizontalSpan:new{ width = gap })
    if right then
        table.insert(row, self:cellWidget(right, cell_width, cell_height, focus_row, 2))
    else
        table.insert(row, HorizontalSpan:new{ width = cell_width })
    end
    table.insert(content, row)
end

function ServerSettingsPage:accountCells()
    return {
        {
            { label = _("Server name"), value = function() return self.draft.name ~= "" and self.draft.name or _("Not set") end,
              callback = function() self:editTextField(_("Server name"), "name", _("Server name")) end },
            { label = _("URL"), value = function() return self.draft.url ~= "" and ellipsize(self.draft.url, 30) or _("Not set") end,
              callback = function() self:editTextField(_("URL"), "url", _("https://sync.example.com")) end },
        },
        {
            { label = _("Username"), value = function() return self.draft.username ~= "" and self.draft.username or _("Not set") end,
              callback = function() self:editTextField(_("Username"), "username", _("Username")) end },
            { label = _("Password"), value = function()
                if self.password ~= "" then return _("New password entered") end
                return self.draft.userkey and _("••••••••") or _("Not set")
              end, callback = function() self:editTextField(_("Password"), "password", _("Password"), "password") end },
        },
        {
            { label = _("Recovery email"), value = function() return maskEmail(self.draft.email) end,
              callback = function() self:editTextField(_("Recovery email"), "email", _("Email")) end },
            { label = _("Server"), value = function() return self.draft.enabled ~= false and _("Enabled") or _("Disabled") end,
              callback = function()
                self.draft.enabled = not (self.draft.enabled ~= false)
                self:markDirty()
                self:updateItems()
              end },
        },
    }
end

function ServerSettingsPage:sharingCells()
    return {
        {
            { label = _("Reading Progress"), value = _("ON (Default)"), static = true },
            { label = _("Book Metadata"), value = function() return boolText(self.draft.metadata_enabled ~= false) end,
              callback = function() self.draft.metadata_enabled = not (self.draft.metadata_enabled ~= false); self:markDirty(); self:updateItems() end },
        },
        {
            { label = _("Annotations"), value = function() return boolText(self.draft.annotations_enabled) end,
              callback = function() self:toggleSharing("annotations_enabled") end },
            { label = _("Reading Statistics"), value = function() return boolText(self.draft.reading_statistics_enabled) end,
              callback = function() self:toggleSharing("reading_statistics_enabled") end },
        },
        {
            { label = _("KOReader Settings Backup"), value = function() return boolText(self.draft.settings_backup_enabled) end,
              callback = function() self:toggleSharing("settings_backup_enabled") end },
            { label = _("Deluxe-Sync Config Backup"), value = function() return boolText(self.draft.deluxe_config_backup_enabled) end,
              callback = function() self:toggleSharing("deluxe_config_backup_enabled") end },
        },
        {
            { label = _("Vocabulary Builder"), value = function() return boolText(self.draft.vocabulary_enabled) end,
              callback = function() self:toggleSharing("vocabulary_enabled") end },
            { label = _("Vocabulary Reading Context"), value = function() return boolText(self.draft.vocabulary_context_enabled) end,
              callback = function() self:toggleSharing("vocabulary_context_enabled") end },
        },
    }
end

function ServerSettingsPage:capabilityCells()
    local caps = self.draft.capabilities or {}
    local device_identity = caps.device_registration == true and caps.device_registered == true
        and _("Registered") or capabilityText(caps.device_registration)
    return {
        {
            { label = _("Library Listing"), value = capabilityText(caps.document_listing), static = true },
            { label = _("Linked Books"), value = capabilityText(caps.logical_library), static = true },
        },
        {
            { label = _("Rich Position"), value = capabilityText(caps.rich_progress), static = true },
            { label = _("Device Identity"), value = device_identity, static = true },
        },
        {
            { label = _("Annotations"), value = capabilityText(caps.annotations), static = true },
            { label = _("Reading Statistics"), value = capabilityText(caps.reading_statistics), static = true },
        },
        {
            { label = _("Settings Backups"), value = capabilityText(caps.settings_backups), static = true },
            { label = _("Vocabulary Builder"), value = capabilityText(caps.vocabulary_builder), static = true },
        },
    }
end

function ServerSettingsPage:actionCells()
    if self.is_new then
        return {
            {
                { label = _("Create account"), value = "", callback = function()
                    if self.on_signup then self.on_signup(self, self.draft, self.password) end
                end },
                { label = _("Save / sign in"), value = "", callback = function()
                    if self.on_save then self.on_save(self, self.draft, self.password) end
                end },
            },
        }
    end
    return {
        {
            { label = _("Account Recovery"), value = "", callback = function()
                local caps = self.draft.capabilities or {}
                if caps.account_recovery == false then
                    showUnsupportedFeature()
                    return
                end
                if self.on_recovery then self.on_recovery(self, self.draft) end
            end },
            { label = _("Delete Server"), value = "", danger = true, callback = function()
                if self.on_delete then self.on_delete(self, self.draft) end
            end },
        },
    }
end

function ServerSettingsPage:buildContent(body_width, cell_width, gap, cell_height)
    self.focus_rows = {}
    self.focus_visual_rows = {}
    local visual_state = { rows = 0 }
    local content = VerticalGroup:new{ align = "center" }
    self:addSection(content, _("ACCOUNT & CONNECTION"), body_width, visual_state)
    for _, pair in ipairs(self:accountCells()) do
        self:addCellRow(content, pair[1], pair[2], body_width, cell_width, gap, cell_height, visual_state)
    end

    self:addSection(content, _("SYNC"), body_width, visual_state)
    self:addCellRow(content,
        { label = _("Book matching"), value = function() return self.draft.checksum_method == "filename" and _("Filename") or _("Binary") end,
          callback = function()
            self.draft.checksum_method = self.draft.checksum_method == "filename" and "binary" or "filename"
            self:markDirty()
            self:updateItems()
          end },
        { label = self.is_new and _("Save server first") or _("Authenticate / Sign in"), value = "", centered = true,
          callback = not self.is_new and function()
            if self.on_authenticate then self.on_authenticate(self, self.draft, self.password) end
          end or nil, static = self.is_new },
        body_width, cell_width, gap, cell_height, visual_state)

    self:addSection(content, _("DATA SHARED WITH THIS SERVER (IF SUPPORTED)"), body_width, visual_state)
    for _, pair in ipairs(self:sharingCells()) do
        self:addCellRow(content, pair[1], pair[2], body_width, cell_width, gap, cell_height, visual_state)
    end

    self:addSection(content, _("SERVER CAPABILITIES"), body_width, visual_state)
    for _, pair in ipairs(self:capabilityCells()) do
        self:addCellRow(content, pair[1], pair[2], body_width, cell_width, gap, cell_height, visual_state)
    end

    self:addSection(content, _("ACTIONS"), body_width, visual_state)
    for _, pair in ipairs(self:actionCells()) do
        self:addCellRow(content, pair[1], pair[2], body_width, cell_width, gap, cell_height, visual_state)
    end
    table.insert(content, VerticalSpan:new{ width = Style.gap() })
    self.total_visual_rows = math.max(1, visual_state.rows)

    if #self.focus_rows == 0 then
        self.key_focus_region = "header"
    else
        self.key_body_row = math.max(1, math.min(#self.focus_rows, tonumber(self.key_body_row) or 1))
        local row = self.focus_rows[self.key_body_row]
        if not row[self.key_body_col] then self.key_body_col = row[1] and 1 or 2 end
    end
    return content
end

function ServerSettingsPage:ensureFocusedVisible()
    if not self.scroll_container or self.key_focus_region ~= "body" or #self.focus_rows == 0 then return end
    local visual = self.focus_visual_rows[self.key_body_row] or self.key_body_row
    local ratio = math.max(0, math.min(1, (visual - 0.5) / self.total_visual_rows))
    self.scroll_container:scrollToRatio(nil, ratio)
end

function ServerSettingsPage:updateItems()
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.dimen.w = self.width
    self.dimen.h = self.height
    local header_height = Style.headerHeight()
    local content_height = math.max(1, self.height - header_height)
    local scrollbar = ScrollableContainer:getScrollbarWidth()
    local margin = Style.pageMargin()
    local gap = Style.compactGap()
    local body_width = math.max(1, self.width - scrollbar - 2 * margin)
    local cell_width = math.max(1, math.floor((body_width - gap) / 2))
    local cell_height = Style.cellHeight()
    local content = self:buildContent(body_width, cell_width, gap, cell_height)
    self.scroll_container = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = content_height },
        show_parent = self,
        CenterContainer:new{ dimen = Geom:new{ w = self.width, h = content:getSize().h }, content },
    }
    local root = VerticalGroup:new{
        align = "center",
        self:headerWidget(self.width, header_height),
        self.scroll_container,
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
    UIManager:nextTick(function() self:ensureFocusedVisible() end)
end

function ServerSettingsPage:moveBody(direction)
    local row_count = #self.focus_rows
    if row_count == 0 then
        self.key_focus_region = "header"
        self:updateItems()
        return true
    end
    if direction == "left" or direction == "right" then
        local other = self.key_body_col == 1 and 2 or 1
        if self.focus_rows[self.key_body_row][other] then self.key_body_col = other end
    elseif direction == "up" then
        if self.key_body_row > 1 then
            self.key_body_row = self.key_body_row - 1
            local row = self.focus_rows[self.key_body_row]
            if not row[self.key_body_col] then self.key_body_col = row[1] and 1 or 2 end
        else
            self.key_focus_region = "header"
            self.key_header_index = self.key_body_col == 1 and 1 or 2
        end
    elseif direction == "down" and self.key_body_row < row_count then
        self.key_body_row = self.key_body_row + 1
        local row = self.focus_rows[self.key_body_row]
        if not row[self.key_body_col] then self.key_body_col = row[1] and 1 or 2 end
    end
    self:updateItems()
    return true
end

function ServerSettingsPage:moveFocus(direction)
    if not self.key_focus_active then
        self.key_focus_active = true
        self.key_focus_region = #self.focus_rows > 0 and "body" or "header"
        self:updateItems()
        return true
    end
    if self.key_focus_region == "header" then
        if direction == "left" or direction == "right" then
            self.key_header_index = self.key_header_index == 1 and 2 or 1
        elseif direction == "down" and #self.focus_rows > 0 then
            self.key_focus_region = "body"
            self.key_body_col = self.key_header_index == 1 and 1 or 2
            local row = self.focus_rows[self.key_body_row]
            if not row[self.key_body_col] then self.key_body_col = row[1] and 1 or 2 end
        end
        self:updateItems()
        return true
    end
    return self:moveBody(direction)
end

function ServerSettingsPage:onDpadUp() return self:moveFocus("up") end
function ServerSettingsPage:onDpadDown() return self:moveFocus("down") end
function ServerSettingsPage:onDpadLeft() return self:moveFocus("left") end
function ServerSettingsPage:onDpadRight() return self:moveFocus("right") end

function ServerSettingsPage:onDpadPress()
    if not self.key_focus_active then return self:moveFocus("down") end
    if self.key_focus_region == "header" then
        local action = self:headerActions()[self.key_header_index]
        if action then action() end
    else
        local row = self.focus_rows[self.key_body_row]
        local action = row and row[self.key_body_col]
        if type(action) == "function" then action() end
    end
    return true
end

function ServerSettingsPage:jumpRows(delta)
    if #self.focus_rows == 0 then return true end
    self.key_focus_active = true
    self.key_focus_region = "body"
    self.key_body_row = math.max(1, math.min(#self.focus_rows, self.key_body_row + delta))
    local row = self.focus_rows[self.key_body_row]
    if not row[self.key_body_col] then self.key_body_col = row[1] and 1 or 2 end
    self:updateItems()
    return true
end

function ServerSettingsPage:onDpadPrevPage() return self:jumpRows(-4) end
function ServerSettingsPage:onDpadNextPage() return self:jumpRows(4) end
function ServerSettingsPage:onDpadBack() self:requestBack(); return true end
function ServerSettingsPage:onDpadMenu() if self.on_save then self.on_save(self, self.draft, self.password) end; return true end
function ServerSettingsPage:onClose() self:requestBack(); return true end

return ServerSettingsPage
