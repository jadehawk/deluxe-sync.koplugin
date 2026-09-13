local Device = require("device")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template

local LocalLibrary = require("LocalLibrary")
local DeluxeCoverPlaceholder = require("DeluxeCoverPlaceholder")
local Style = require("DeluxeUIStyle")

local ServerRecordInspection = {}

local function compactText(value, max_chars)
    local text = tostring(value or "")
    max_chars = math.max(8, tonumber(max_chars) or 32)
    if #text <= max_chars then return text end
    return text:sub(1, max_chars - 3) .. "..."
end

local function compactIdentifier(value)
    local text = tostring(value or "")
    if #text <= 20 then return text end
    return text:sub(1, 8) .. "..." .. text:sub(-8)
end

function ServerRecordInspection.show(plugin, server, doc, match, documents, authoritative, logical_mode, deps)
    if not doc then return end
    deps = deps or {}
    local format_percent = assert(deps.format_percent, "ServerRecordInspection requires format_percent")
    local server_label = assert(deps.server_label, "ServerRecordInspection requires server_label")
    local suppress_dialog_holds = assert(deps.suppress_dialog_holds, "ServerRecordInspection requires suppress_dialog_holds")
    local browser = deps.browser
    local browser_entry = deps.entry

    local title = doc.title or (match and match.title) or doc.filename or (match and match.filename)
        or T(_("Unknown book (%1)"), tostring(doc.document or ""):sub(1, 8))
    local author = doc.authors or (match and match.authors) or _("Metadata Unavailable")
    if type(author) == "table" then
        local parts = {}
        for author_index, value in ipairs(author) do table.insert(parts, tostring(value)) end
        author = #parts > 0 and table.concat(parts, ", ") or _("Metadata Unavailable")
    elseif author ~= nil then
        author = tostring(author)
    end
    local filename = doc.filename or (match and match.filename) or _("Unknown filename")
    local timestamp = tonumber(doc.timestamp) or 0
    local stamp = timestamp > 0 and os.date("%Y-%m-%d %H:%M", timestamp) or _("Unknown date")
    local confidence_labels = {
        binary = _("Binary"),
        ["sidecar-binary"] = _("Binary"),
        filename = _("Filename"),
        metadata = _("Metadata"),
    }
    local confidence = match and (confidence_labels[match.confidence] or tostring(match.confidence or _("Matched"))) or nil
    local local_status = match and T(_("Found · %1"), confidence) or _("Not found")
    local document_label = compactIdentifier(doc.document or _("Unknown"))
    local title_face = Font:getFace("smallinfofontbold", Style.header_font)
    local book_title_face = Font:getFace("smallinfofontbold", Style.primary_font)
    local detail_face = Font:getFace("smallinfofont", Style.secondary_font)
    local tertiary_face = Font:getFace("smallinfofont", Style.tertiary_font)
    local label_face = Font:getFace("smallinfofontbold", Style.section_font)

    local footer_buttons = {
        {
            text = _("Back to server book list"),
            callback = function()
                UIManager:close(plugin.server_book_dialog)
                if not browser or browser.closed then
                    plugin:showServerLibrary(server, documents, authoritative, logical_mode)
                end
            end,
        },
    }
    if not match and doc.document and tostring(doc.document) ~= "" then
        footer_buttons[#footer_buttons + 1] = {
            text = _("Find Match"),
            callback = function()
                local searching = InfoMessage:new{ text = _("Searching KOReader sidecars for this document…") }
                UIManager:show(searching)
                UIManager:nextTick(function()
                    local found = LocalLibrary.findByDocument(doc.document)
                    UIManager:close(searching)
                    if not found then
                        UIManager:show(InfoMessage:new{
                            text = T(_("No local KOReader book matched document %1."), tostring(doc.document)),
                        })
                        return
                    end
                    if found.book_exists == false then
                        UIManager:show(InfoMessage:new{
                            text = T(_("A matching KOReader sidecar was found, but its book file is no longer available.\n\n%1"), tostring(found.path or found.sidecar or "")),
                        })
                        return
                    end
                    if browser_entry then
                        browser_entry.match = found
                        if found.title and tostring(found.title) ~= "" then browser_entry.grid_title = tostring(found.title) end
                        browser_entry._local_cover_checked = nil
                        browser_entry._local_cover = nil
                    end
                    if browser and not browser.closed then browser:updateItems() end
                    UIManager:close(plugin.server_book_dialog)
                    plugin:showServerDocumentInspection(server, doc, found, documents, authoritative, logical_mode, browser, browser_entry)
                end)
            end,
        }
    end

    plugin.server_book_dialog = ButtonDialog:new{
        title = _("Deluxe-Sync"),
        title_align = "left",
        title_face = title_face,
        width_factor = 0.98,
        use_info_style = false,
        dismissable = false,
        buttons = { footer_buttons },
    }

    local available_width = plugin.server_book_dialog:getAddedWidgetAvailableWidth()
    local gap = math.max(8, math.floor(available_width * 0.025))
    local left_width = math.floor(available_width * 0.39)
    local right_width = available_width - left_width - gap
    local cover_max_width = math.max(80, left_width - 16)
    local cover_max_height = math.floor(Device.screen:getHeight() * 0.30)

    local left_column = VerticalGroup:new{ align = "center" }
    local thumbnail
    if match and match.path and plugin.ui.bookinfo then
        local ok, cover = pcall(function()
            return plugin.ui.bookinfo:getCoverImage(plugin.ui.document, match.path)
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
    if match and match.path then
        table.insert(left_column, TextBoxWidget:new{
            text = compactText(match.path, 34),
            width = left_width,
            face = tertiary_face,
            alignment = "center",
        })
    end

    local right_column = VerticalGroup:new{}
    table.insert(right_column, TextBoxWidget:new{
        text = _("SERVER RECORD"),
        width = right_width,
        face = label_face,
        alignment = "center",
    })
    table.insert(right_column, VerticalSpan:new{ width = 5 })

    local remote_label_face = Font:getFace("smallinfofont", Style.setting_label_font)
    local remote_value_face = Font:getFace("smallinfofontbold", Style.value_font)
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
    addRemoteRow(_("Position"), doc.percentage ~= nil and format_percent(doc.percentage) or _("Unknown"))
    addRemoteRow(_("Server"), server_label(server))
    addRemoteRow(_("Document ID"), document_label)
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

    plugin.server_book_dialog:addWidget(HorizontalGroup:new{
        align = "top",
        left_column,
        HorizontalSpan:new{ width = gap },
        right_column,
    })
    suppress_dialog_holds(plugin.server_book_dialog)
    UIManager:show(plugin.server_book_dialog)
end

return ServerRecordInspection
