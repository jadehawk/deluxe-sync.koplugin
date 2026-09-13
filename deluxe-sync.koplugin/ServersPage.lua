local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template
local Dpad = require("DeluxeDpad")
local Style = require("DeluxeUIStyle")
local DiagnosticLog = require("DiagnosticLog")

local ServersPage = InputContainer:extend{
    name = "deluxe_sync_servers_page",
    covers_fullscreen = true,
}

local function tapContainer(widget, width, height, tap_callback, hold_callback)
    local item = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        widget,
    }
    item.ges_events = {}
    if tap_callback then
        item.ges_events.TapSelect = { GestureRange:new{ ges = "tap", range = item.dimen } }
        item.onTapSelect = function()
            tap_callback()
            return true
        end
    end
    if hold_callback then
        item.ges_events.HoldSelect = { GestureRange:new{ ges = "hold", range = item.dimen } }
        item.onHoldSelect = function()
            hold_callback()
            return true
        end
    end
    return item
end

local function headerButton(text, width, height, callback, focused)
    local border = focused and Style.focusBorder() or Style.thinBorder()
    local inset = Style.scale(3)
    local button_width = math.max(1, width - 2 * inset)
    local button_height = math.max(1, height - 2 * inset)
    local frame = FrameContainer:new{
        width = button_width,
        height = button_height,
        margin = 0,
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = button_width, h = button_height },
            TextWidget:new{
                text = text,
                face = Font:getFace("smallinfofontbold", Style.action_font),
                bold = true,
                max_width = math.max(1, button_width - Style.scale(10)),
            },
        },
    }
    return tapContainer(CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        frame,
    }, width, height, callback)
end

function ServersPage:init()
    self.servers = self.servers or {}
    DiagnosticLog.log("ui open", "Servers page", "servers", #self.servers)
    self.label_fn = self.label_fn or function(server) return server.name or server.url or _("Server") end
    self.enabled = {}
    for _, server in ipairs(self.servers) do self.enabled[server.id] = server.enabled ~= false end
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.key_focus_active = not Dpad.isTouchDevice(Device)
    self.key_focus_region = self.key_focus_active and (#self.servers > 0 and "tiles" or "add") or nil
    self.key_header_index = 2
    self.key_tile_index = 1
    self.key_events = Dpad.pageKeyEvents(Device)
    self:updateItems()
end

function ServersPage:visibleGroups()
    local enabled_servers, disabled_servers = {}, {}
    for _, server in ipairs(self.servers) do
        table.insert(self.enabled[server.id] and enabled_servers or disabled_servers, server)
    end
    return enabled_servers, disabled_servers
end

function ServersPage:closePage()
    if self.on_close then self.on_close(self) else UIManager:close(self) end
end

function ServersPage:confirmPage()
    if self.on_confirm then self.on_confirm(self, self.enabled) else self:closePage() end
end

function ServersPage:openSyncedBooks()
    if self.on_browse then self.on_browse(self) end
end

function ServersPage:openServer(server)
    if self.on_open_server then self.on_open_server(self, server) end
end

function ServersPage:toggleServer(server)
    if not server then return end
    self.enabled[server.id] = not (self.enabled[server.id] == true)
    if self.on_toggle then self.on_toggle(self, server, self.enabled[server.id] == true) end
    self:updateItems()
end

function ServersPage:isHeaderFocused(index)
    return self.key_focus_active and self.key_focus_region == "header" and self.key_header_index == index
end

function ServersPage:isAddFocused()
    return self.key_focus_active and self.key_focus_region == "add"
end

function ServersPage:isTileFocused(index)
    return self.key_focus_active and self.key_focus_region == "tiles" and self.key_tile_index == index
end

function ServersPage:headerWidget(width, height)
    local side_width = math.floor(width * 0.24)
    local title_width = math.max(1, width - 2 * side_width)
    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, headerButton(_("Synced Books"), side_width, height, function() self:openSyncedBooks() end, self:isHeaderFocused(1)))
    table.insert(row, CenterContainer:new{
        dimen = Geom:new{ w = title_width, h = height },
        TextWidget:new{
            text = self.plugin_version and T(_("Deluxe-Sync v%1"), self.plugin_version) or _("Deluxe-Sync"),
            face = Font:getFace("smallinfofontbold", Style.header_font),
            bold = true,
            max_width = title_width - Style.scale(8),
        },
    })
    table.insert(row, headerButton(_("Close"), side_width, height, function() self:closePage() end, self:isHeaderFocused(2)))
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = Style.thinBorder(),
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
end

function ServersPage:sectionTitle(text, width)
    local height = Style.sectionHeight()
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
                    text = text,
                    face = Font:getFace("smallinfofontbold", Style.section_font),
                    bold = true,
                    max_width = math.max(1, width - 2 * inset),
                },
            },
        },
    }
end

function ServersPage:actionRow(text, width, callback, focused)
    local height = Style.cellHeight()
    local border = focused and Style.focusBorder() or Style.thinBorder()
    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = Style.cellPadding(),
        bordersize = border,
        radius = Style.scale(8),
        color = Blitbuffer.COLOR_BLACK,
        background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width - 2 * Style.cellPadding(), h = height - 2 * Style.cellPadding() },
            TextWidget:new{
                text = text,
                face = Font:getFace("smallinfofontbold", Style.primary_font),
                bold = true,
                max_width = width - Style.scale(18),
            },
        },
    }
    return tapContainer(frame, width, height, callback)
end

function ServersPage:serverTile(server, visual_index, width, height)
    local focused = self:isTileFocused(visual_index)
    local selected = self.enabled[server.id] == true
    local border = focused and Style.focusBorder() or Style.thinBorder()
    local padding = Style.cellPadding()
    local inner_width = math.max(1, width - 2 * padding - 2 * border)
    local body = LeftContainer:new{
        dimen = Geom:new{ w = inner_width, h = math.max(1, height - 2 * padding - 2 * border) },
        TextWidget:new{
            text = (selected and "●  " or "○  ") .. tostring(self.label_fn(server)),
            face = Font:getFace("smallinfofontbold", Style.primary_font),
            bold = true,
            max_width = inner_width,
        },
    }
    local frame = FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = padding,
        bordersize = border,
        radius = Style.scale(8),
        color = Blitbuffer.COLOR_BLACK,
        background = focused and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        body,
    }
    return tapContainer(
        frame,
        width,
        height,
        function() self:toggleServer(server) end,
        function() self:openServer(server) end
    )
end

function ServersPage:addServerSection(content, title, group, body_width, tile_width, tile_height, gap, flat)
    table.insert(content, self:sectionTitle(T(title, #group), body_width))
    if #group == 0 then
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = body_width, h = Style.cellHeight() },
            TextWidget:new{
                text = _("No servers"),
                face = Font:getFace("smallinfofont", Style.secondary_font),
            },
        })
        table.insert(content, VerticalSpan:new{ width = gap })
        return
    end
    local index = 1
    while index <= #group do
        local row = HorizontalGroup:new{ align = "center" }
        local first = group[index]
        local first_visual = #flat + 1
        table.insert(flat, first)
        table.insert(row, self:serverTile(first, first_visual, tile_width, tile_height))
        table.insert(row, HorizontalSpan:new{ width = gap })
        local second = group[index + 1]
        if second then
            local second_visual = #flat + 1
            table.insert(flat, second)
            table.insert(row, self:serverTile(second, second_visual, tile_width, tile_height))
        else
            table.insert(row, HorizontalSpan:new{ width = tile_width })
        end
        table.insert(content, row)
        table.insert(content, VerticalSpan:new{ width = gap })
        index = index + 2
    end
end

function ServersPage:ensureFocusedVisible()
    if not self.scroll_container or self.key_focus_region ~= "tiles" or not self.key_tile_index then return end
    local count = #self.visible_servers
    if count <= 1 then return end
    local ratio = math.max(0, math.min(1, (self.key_tile_index - 0.5) / count))
    self.scroll_container:scrollToRatio(nil, ratio)
end

function ServersPage:updateItems()
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.dimen.w = self.width
    self.dimen.h = self.height
    local header_height = Style.headerHeight()
    local content_height = math.max(1, self.height - header_height)
    local scrollbar = ScrollableContainer:getScrollbarWidth()
    local margin = Style.pageMargin()
    local gap = Style.gap()
    local body_width = math.max(1, self.width - scrollbar - 2 * margin)
    local tile_width = math.max(1, math.floor((body_width - gap) / 2))
    local tile_height = math.max(50, Style.scale(58))
    local enabled_servers, disabled_servers = self:visibleGroups()
    self.visible_servers = {}

    local content = VerticalGroup:new{ align = "center" }
    table.insert(content, VerticalSpan:new{ width = Style.compactGap() })
    table.insert(content, TextBoxWidget:new{
        text = _("NOTE: Click to Enable/Disable or Click and HOLD to EDIT Server"),
        width = body_width,
        face = Font:getFace("smallinfofont", Style.tertiary_font),
        alignment = "center",
    })
    table.insert(content, VerticalSpan:new{ width = gap })
    self:addServerSection(content, _("ENABLED SERVERS (%1)"), enabled_servers, body_width, tile_width, tile_height, gap, self.visible_servers)
    self:addServerSection(content, _("DISABLED SERVERS (%1)"), disabled_servers, body_width, tile_width, tile_height, gap, self.visible_servers)
    table.insert(content, self:actionRow(_("+  Add server…"), body_width, function()
        if self.on_add then self.on_add(self) end
    end, self:isAddFocused()))
    table.insert(content, VerticalSpan:new{ width = gap })
    if self.key_focus_active then
        table.insert(content, TextBoxWidget:new{
            text = _("D-pad: OK toggles a server · Menu opens server details"),
            width = body_width,
            face = Font:getFace("smallinfofont", Style.tertiary_font),
            alignment = "center",
        })
        table.insert(content, VerticalSpan:new{ width = gap })
    end

    if #self.visible_servers == 0 and self.key_focus_region == "tiles" then self.key_focus_region = "add" end
    if #self.visible_servers > 0 then self.key_tile_index = math.max(1, math.min(#self.visible_servers, self.key_tile_index or 1)) end

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

function ServersPage:moveTile(direction)
    local count = #self.visible_servers
    if count == 0 then self.key_focus_region = "add"; self:updateItems(); return true end
    local index = self.key_tile_index or 1
    if direction == "left" then
        if index % 2 == 0 then index = index - 1 end
    elseif direction == "right" then
        if index % 2 == 1 and index < count then index = index + 1 end
    elseif direction == "up" then
        if index > 2 then
            index = index - 2
        else
            self.key_focus_region = "header"
            self.key_header_index = 1
        end
    elseif direction == "down" then
        if index + 2 <= count then
            index = index + 2
        elseif index < count and index % 2 == 1 then
            index = count
        else
            self.key_focus_region = "add"
        end
    end
    self.key_tile_index = index
    self:updateItems()
    return true
end

function ServersPage:moveFocus(direction)
    if not self.key_focus_active then
        self.key_focus_active = true
        self.key_focus_region = #self.visible_servers > 0 and "tiles" or "add"
        self:updateItems()
        return true
    end
    if self.key_focus_region == "header" then
        if direction == "left" or direction == "right" then
            self.key_header_index = self.key_header_index == 1 and 2 or 1
        elseif direction == "down" then
            self.key_focus_region = #self.visible_servers > 0 and "tiles" or "add"
        end
    elseif self.key_focus_region == "tiles" then
        return self:moveTile(direction)
    elseif self.key_focus_region == "add" then
        if direction == "up" then
            if #self.visible_servers > 0 then
                self.key_focus_region = "tiles"
                self.key_tile_index = #self.visible_servers
            else
                self.key_focus_region = "header"
                self.key_header_index = 1
            end
        end
    end
    self:updateItems()
    return true
end

function ServersPage:onDpadUp() return self:moveFocus("up") end
function ServersPage:onDpadDown() return self:moveFocus("down") end
function ServersPage:onDpadLeft() return self:moveFocus("left") end
function ServersPage:onDpadRight() return self:moveFocus("right") end

function ServersPage:onDpadPress()
    if not self.key_focus_active then return self:moveFocus("down") end
    if self.key_focus_region == "header" then
        if self.key_header_index == 1 then self:openSyncedBooks() else self:closePage() end
    elseif self.key_focus_region == "tiles" then
        self:toggleServer(self.visible_servers[self.key_tile_index])
    elseif self.key_focus_region == "add" and self.on_add then
        self.on_add(self)
    end
    return true
end

function ServersPage:onDpadMenu()
    if self.key_focus_region == "tiles" then
        local server = self.visible_servers[self.key_tile_index]
        if server then self:openServer(server) end
    elseif self.on_add then
        self.on_add(self)
    end
    return true
end

function ServersPage:changePage(delta)
    if #self.visible_servers == 0 then return true end
    self.key_focus_active = true
    self.key_focus_region = "tiles"
    self.key_tile_index = math.max(1, math.min(#self.visible_servers, (self.key_tile_index or 1) + delta * 6))
    self:updateItems()
    return true
end

function ServersPage:onDpadPrevPage() return self:changePage(-1) end
function ServersPage:onDpadNextPage() return self:changePage(1) end
function ServersPage:onDpadBack() self:closePage(); return true end
function ServersPage:onClose() self:closePage(); return true end

return ServersPage
