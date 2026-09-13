local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local I18N = require("I18N")
local _ = I18N.translate
local T = require("ffi/util").template

local DiagnosticLog = require("DiagnosticLog")
local LocalLibrary = require("LocalLibrary")
local ServerLibraryBrowser = require("ServerLibraryBrowser")

local ServerLibraryController = {}
ServerLibraryController.__index = ServerLibraryController

function ServerLibraryController:new(owner, deps)
    return setmetatable({
        owner = owner,
        deps = deps or {},
    }, self)
end

function ServerLibraryController:showCachedServerLibrary(server, browser)
    local owner = self.owner
    if not server then return false end
    if browser and not browser.closed and owner.library_browser == browser
            and browser.restorePreparedShelf and browser:restorePreparedShelf(server.id) then
        return true
    end
    local documents = owner.store:getKnownDocuments(server.id)
    local meta = owner.store:getKnownDocumentsMeta(server.id)
    local refreshed_at = math.max(0, tonumber(meta.refreshed_at) or 0)
    if #documents == 0 and refreshed_at == 0 then
        self:refreshServerLibrary(server, browser)
        return false
    end
    local logical_mode = meta.logical_mode == true
    if refreshed_at == 0 and server.capabilities and server.capabilities.logical_library == true then
        for unused_index, document in ipairs(documents) do
            if document.kind == "logical" or document.kind == "raw" then
                logical_mode = true
                break
            end
        end
    end
    self:showServerLibrary(server, documents, false, logical_mode, browser, refreshed_at)
    return true
end

function ServerLibraryController:refreshServerLibrary(server, browser)
    local owner = self.owner
    local decode = self.deps.decode

    local function cachedState()
        local meta = owner.store:getKnownDocumentsMeta(server.id)
        return owner.store:getKnownDocuments(server.id), meta.logical_mode == true, math.max(0, tonumber(meta.refreshed_at) or 0)
    end

    local function present(documents, authoritative, logical_mode, refreshed_at)
        if browser and (browser.closed or owner.library_browser ~= browser) then return end
        self:showServerLibrary(server, documents, authoritative, logical_mode, browser, refreshed_at)
    end

    if browser then
        if browser.closed or owner.library_browser ~= browser then return end
        browser:setLoading(server, self.deps.server_label(server))
    end

    local function loadRawLibrary()
        owner:newClient(server):listDocuments(server.username, server.userkey, function(ok, status, body)
            local data = decode(body)
            if ok and status == 200 and data and type(data.documents) == "table" then
                local refreshed_at = os.time()
                owner.store:setCapability(server.id, "document_listing", true)
                owner.store:setKnownDocuments(server.id, data.documents, { logical_mode = false, refreshed_at = refreshed_at })
                present(data.documents, true, false, refreshed_at)
            else
                local listing_unsupported = status == 404 or status == 405
                if listing_unsupported then owner.store:setCapability(server.id, "document_listing", false) end
                local cached, cached_logical, refreshed_at = cachedState()
                present(cached, false, cached_logical, refreshed_at)
            end
        end)
    end

    local capabilities = server.capabilities or {}
    if capabilities.logical_library ~= true then
        return loadRawLibrary()
    end

    owner:newClient(server):listLogicalLibrary(server.username, server.userkey, function(ok, status, body)
        local data = decode(body)
        if ok and status == 200 and data and type(data.books) == "table" then
            local refreshed_at = os.time()
            owner.store:setKnownDocuments(server.id, data.books, { logical_mode = true, refreshed_at = refreshed_at })
            present(data.books, true, true, refreshed_at)
        elseif status == 404 or status == 405 then
            owner.store:setCapability(server.id, "logical_books", false)
            owner.store:setCapability(server.id, "logical_library", false)
            loadRawLibrary()
        else
            local cached, cached_logical, refreshed_at = cachedState()
            if #cached > 0 or refreshed_at > 0 then
                present(cached, false, cached_logical, refreshed_at)
            else
                loadRawLibrary()
            end
        end
    end)
end

function ServerLibraryController:showLogicalLinkPicker(server, documents)
    local raw_books = {}
    for unused_index, book in ipairs(documents or {}) do
        if book.kind == "raw" and book.document then table.insert(raw_books, book) end
    end
    DiagnosticLog.log("logical link picker", server.name or server.url or "", "raw_books", #raw_books)
    if #raw_books < 2 then
        UIManager:show(InfoMessage:new{ text = _("At least two unlinked books are required.") })
        return self:refreshServerLibrary(server)
    end

    local dialog
    local selected_documents = {}
    local buttons = {}
    local format_percent = self.deps.format_percent

    local function choiceLabel(book)
        local percentage = book.percentage ~= nil and format_percent(book.percentage) or _("Unknown")
        local title = book.title or book.filename or tostring(book.document)
        local marker = selected_documents[book.document] and "[x]" or "[ ]"
        return T(_("%1 %2 — %3"), marker, tostring(title), percentage)
    end

    for index, book in ipairs(raw_books) do
        local selected_book = book
        local button_id = "logical_link_book_" .. tostring(index)
        table.insert(buttons, {{
            id = button_id,
            text = choiceLabel(selected_book),
            callback = function()
                local document = selected_book.document
                selected_documents[document] = not selected_documents[document]
                local button = dialog:getButtonById(button_id)
                if button then button:setText(choiceLabel(selected_book), button.width) end
                UIManager:setDirty(dialog, "ui")
            end,
        }})
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
                self:refreshServerLibrary(server)
            end,
        },
        {
            text = _("Continue"),
            callback = function()
                local selected = {}
                for unused_index, book in ipairs(raw_books) do
                    if selected_documents[book.document] then table.insert(selected, book) end
                end
                if #selected < 2 then
                    return UIManager:show(InfoMessage:new{ text = _("Select at least two books to link.") })
                end
                UIManager:close(dialog)
                self:showLogicalProgressSourcePicker(server, selected)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Link Books"),
        title_align = "left",
        width_factor = 0.98,
        rows_per_page = { 6, 5, 4, 3 },
        buttons = buttons,
    }
    local width = dialog:getAddedWidgetAvailableWidth()
    dialog:addWidget(TextBoxWidget:new{
        text = _("Select alternate versions of the same book. Each raw sync record remains stored separately and can be unlinked later."),
        width = width,
        face = Font:getFace("smallinfofont"),
        alignment = "left",
    })
    self.deps.suppress_dialog_holds(dialog)
    UIManager:show(dialog)
end

function ServerLibraryController:showLogicalProgressSourcePicker(server, selected)
    local owner = self.owner
    local format_percent = self.deps.format_percent
    local server_response_message = self.deps.server_response_message
    table.sort(selected, function(a, b)
        local a_percentage = tonumber(a.percentage) or -1
        local b_percentage = tonumber(b.percentage) or -1
        if a_percentage ~= b_percentage then return a_percentage > b_percentage end
        return (tonumber(a.timestamp) or 0) > (tonumber(b.timestamp) or 0)
    end)

    local dialog
    local buttons = {}
    for index, book in ipairs(selected) do
        local selected_book = book
        local percentage = selected_book.percentage ~= nil and format_percent(selected_book.percentage) or _("Unknown")
        local title = selected_book.title or selected_book.filename or tostring(selected_book.document)
        local device = selected_book.device or _("Unknown device")
        local label = T(_("%1 — %2 — %3"), tostring(title), percentage, tostring(device))
        if index == 1 then label = T(_("Recommended: %1"), label) end
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(dialog)
                local documents = {}
                for unused_index, candidate in ipairs(selected) do table.insert(documents, candidate.document) end
                local linking = InfoMessage:new{ text = _("Linking books...") }
                UIManager:show(linking)
                owner:newClient(server):createLogicalBook(server.username, server.userkey, {
                    documents = documents,
                    progress_source_document = selected_book.document,
                }, function(ok, status, body)
                    UIManager:close(linking)
                    if ok and status == 201 then
                        UIManager:show(InfoMessage:new{ text = _("Books linked."), timeout = 3 })
                    else
                        local message = server_response_message(body) or T(_("Linking failed (HTTP %1)."), tostring(status or "?"))
                        UIManager:show(InfoMessage:new{ text = message })
                    end
                    self:refreshServerLibrary(owner.store:getServer(server.id) or server)
                end)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(dialog)
            self:refreshServerLibrary(server)
        end,
    }})

    dialog = ButtonDialog:new{
        title = _("Choose Shared Reading Position"),
        title_align = "left",
        width_factor = 0.98,
        buttons = buttons,
    }
    local width = dialog:getAddedWidgetAvailableWidth()
    dialog:addWidget(TextBoxWidget:new{
        text = _("Choose which version supplies the starting shared progress. The furthest position is recommended by default; choose another version if you intentionally restarted or moved backward."),
        width = width,
        face = Font:getFace("smallinfofont"),
        alignment = "left",
    })
    self.deps.suppress_dialog_holds(dialog)
    UIManager:show(dialog)
end

function ServerLibraryController:confirmUnlinkLogicalBook(server, logical_book, browser)
    local owner = self.owner
    local server_response_message = self.deps.server_response_message
    local logical_id = tonumber(logical_book.logical_book_id)
    if not logical_id then return end
    local dialog
    dialog = ButtonDialog:new{
        title = _("Unlink linked book?"),
        title_align = "left",
        buttons = {
            {{
                text = _("This removes only the grouping. The raw sync records and their stored progress remain intact."),
                enabled = false,
            }},
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog); self:showLogicalBookInspection(server, logical_book, browser) end },
                { text = _("Unlink All"), callback = function()
                    UIManager:close(dialog)
                    local working = InfoMessage:new{ text = _("Unlinking books...") }
                    UIManager:show(working)
                    owner:newClient(server):unlinkLogicalBook(server.username, server.userkey, logical_id, function(ok, status, body)
                        UIManager:close(working)
                        if ok and status == 200 then
                            UIManager:show(InfoMessage:new{ text = _("Books unlinked."), timeout = 3 })
                            if browser and not browser.closed then
                                browser.closed = true
                                if owner.library_browser == browser then owner.library_browser = nil end
                                UIManager:close(browser)
                                if browser.releaseAllLocalCovers then browser:releaseAllLocalCovers() elseif browser.releaseLocalCovers then browser:releaseLocalCovers() end
                            end
                            self:refreshServerLibrary(owner.store:getServer(server.id) or server)
                        else
                            local message = server_response_message(body) or T(_("Unlink failed (HTTP %1)."), tostring(status or "?"))
                            UIManager:show(InfoMessage:new{ text = message })
                        end
                    end)
                end },
            },
        },
    }
    self.deps.suppress_dialog_holds(dialog)
    UIManager:show(dialog)
end

function ServerLibraryController:showLogicalBookInspection(server, summary, browser)
    local owner = self.owner
    local decode = self.deps.decode
    local format_percent = self.deps.format_percent
    local server_response_message = self.deps.server_response_message
    local logical_id = tonumber(summary and summary.logical_book_id)
    if not logical_id then
        if browser and not browser.closed then return end
        return self:refreshServerLibrary(server)
    end
    owner:newClient(server):getLogicalBook(server.username, server.userkey, logical_id, function(ok, status, body)
        local data = decode(body)
        local logical_book = data and data.logical_book
        if not ok or status ~= 200 or type(logical_book) ~= "table" then
            local message = server_response_message(body) or T(_("Linked book could not be loaded (HTTP %1)."), tostring(status or "?"))
            UIManager:show(InfoMessage:new{ text = message })
            if browser and not browser.closed then return end
            return self:refreshServerLibrary(server)
        end

        local timestamp = tonumber(logical_book.timestamp) or 0
        local rows = {
            { label = _("Linked Versions"), value = tostring(tonumber(logical_book.linked_count) or 0) },
            { label = _("Shared Position"), value = logical_book.percentage ~= nil and format_percent(logical_book.percentage) or _("Unknown") },
            { label = _("Last Sync"), value = timestamp > 0 and os.date("%Y-%m-%d %H:%M", timestamp) or _("Unknown date") },
            { label = _("Last Device"), value = tostring(logical_book.device or _("Unknown device")) },
            { label = _("Source Document"), value = tostring(logical_book.source_document or _("Unknown")) },
        }
        local members = type(logical_book.members) == "table" and logical_book.members or {}
        for index = 1, math.min(#members, 3) do
            local member = members[index]
            local member_name = member.filename or member.title or member.document or _("Unknown")
            local member_percentage = member.percentage ~= nil and format_percent(member.percentage) or _("Unknown")
            table.insert(rows, { label = T(_("Version %1"), index), value = T(_("%1 — %2"), tostring(member_name), member_percentage) })
        end
        if #members > 3 then
            table.insert(rows, { label = _("More Versions"), value = tostring(#members - 3) })
        end

        owner:showStatusCard(logical_book.title or _("Linked Book"), rows, {
            { text = _("Back"), callback = function(card)
                UIManager:close(card)
                if not browser or browser.closed then self:showCachedServerLibrary(server) end
            end },
            { text = _("Unlink All"), callback = function(card) UIManager:close(card); self:confirmUnlinkLogicalBook(server, logical_book, browser) end },
        })
    end)
end

local function authorText(value)
    if type(value) == "table" then
        local parts = {}
        for unused_index, author in ipairs(value) do
            if author ~= nil and tostring(author) ~= "" then parts[#parts + 1] = tostring(author) end
        end
        return #parts > 0 and table.concat(parts, ", ") or nil
    end
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function metadataValuePresent(value)
    if value == nil then return false end
    if type(value) == "table" then return next(value) ~= nil end
    return tostring(value) ~= ""
end

local function remoteMetadataAvailable(item)
    if type(item) ~= "table" then return false end
    if item.metadata_available == true then return true end
    if metadataValuePresent(item.title) or metadataValuePresent(item.authors) then return true end
    if type(item.metadata) == "table"
            and (metadataValuePresent(item.metadata.title) or metadataValuePresent(item.metadata.authors)) then
        return true
    end
    if type(item.versions) == "table" then
        for unused_index, version in ipairs(item.versions) do
            if remoteMetadataAvailable(version) then return true end
        end
    end
    return false
end

function ServerLibraryController:showServerLibrary(server, documents, authoritative, logical_mode, existing_page, refreshed_at)
    local owner = self.owner
    local server_label = self.deps.server_label
    documents = documents or {}
    refreshed_at = math.max(0, tonumber(refreshed_at) or 0)
    local local_matches = LocalLibrary.scan(documents)
    local entries = {}

    for unused_index, item in ipairs(documents) do
        local is_logical = logical_mode == true and item.kind == "logical"
        local match = not is_logical and local_matches[item.document or ""] or nil
        local metadata_title = type(item.metadata) == "table" and item.metadata.title or nil
        local known_title = item.title or metadata_title or (match and match.title)
        local title = known_title or item.filename
        local author = authorText(item.authors) or authorText(match and match.authors)
        local has_metadata = remoteMetadataAvailable(item)
        local identity = item.logical_book_id or item.document or item.filename or tostring(item)
        entries[#entries + 1] = {
            id = tostring(identity),
            item = item,
            match = match,
            title = title or T(_("Unknown book (%1)"), tostring(identity):sub(1, 8)),
            grid_title = known_title or _("Unknown"),
            author = author,
            has_metadata = has_metadata,
            is_logical = is_logical,
            version_count = tonumber(item.linked_count) or (type(item.versions) == "table" and #item.versions or 0),
            percentage = tonumber(item.percentage),
            timestamp = tonumber(item.timestamp or item.updated_at or item.cover_selected_at) or 0,
        }
    end

    table.sort(entries, function(a, b)
        if a.has_metadata ~= b.has_metadata then return a.has_metadata end
        if a.timestamp ~= b.timestamp then return a.timestamp > b.timestamp end
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)

    local browse_servers = {}
    for unused_index, candidate in ipairs(owner.store:listServers()) do
        local candidate_caps = candidate.capabilities or {}
        if candidate.enabled ~= false and candidate_caps.document_listing == true then
            browse_servers[#browse_servers + 1] = candidate
        end
    end
    local found_current = false
    for unused_index, candidate in ipairs(browse_servers) do
        if candidate.id == server.id then found_current = true break end
    end
    if not found_current then table.insert(browse_servers, 1, server) end

    local caps = server.capabilities or {}
    local can_link = logical_mode == true and caps.logical_books == true and caps.logical_library == true

    if existing_page then
        if existing_page.closed or owner.library_browser ~= existing_page then return end
        existing_page:replaceLibrary{
            server = server,
            server_label = server_label(server),
            servers = browse_servers,
            entries = entries,
            documents = documents,
            authoritative = authoritative,
            logical_mode = logical_mode,
            refreshed_at = refreshed_at,
            can_link = can_link,
        }
        return
    end

    local page
    local function closeBrowser(browser)
        local target = browser or page
        if not target or target.closed then return end
        target.closed = true
        if owner.library_browser == target then owner.library_browser = nil end
        UIManager:close(target)
        if target.releaseAllLocalCovers then target:releaseAllLocalCovers() elseif target.releaseLocalCovers then target:releaseLocalCovers() end
    end

    local function currentServer(browser)
        local current = (browser and browser.server) or server
        if current and current.id then return owner.store:getServer(current.id) or current end
        return current
    end

    page = ServerLibraryBrowser:new{
        server = server,
        server_label = server_label(server),
        servers = browse_servers,
        entries = entries,
        documents = documents,
        authoritative = authoritative,
        logical_mode = logical_mode,
        refreshed_at = refreshed_at,
        can_link = can_link,
        on_local_cover = function(unused_browser, entry)
            local match = entry and entry.match
            if not match or not match.path or not owner.ui or not owner.ui.bookinfo then return nil end
            return owner.ui.bookinfo:getCoverImage(owner.ui.document, match.path)
        end,
        view_mode = owner.store:getSetting("server_library_view_mode", "grid"),
        grid_columns = owner.store:getSetting("server_library_grid_columns", 4),
        grid_rows = owner.store:getSetting("server_library_grid_rows", 2),
        list_rows = owner.store:getSetting("server_library_list_rows", 6),
        on_view_mode_change = function(mode)
            owner.store:setSetting("server_library_view_mode", mode)
        end,
        on_layout_change = function(columns, rows, list_rows)
            owner.store:setSetting("server_library_grid_columns", columns)
            owner.store:setSetting("server_library_grid_rows", rows)
            owner.store:setSetting("server_library_list_rows", list_rows)
        end,
        on_close = function(browser)
            local active_server = currentServer(browser)
            closeBrowser(browser)
            if active_server then owner:showServer(active_server) end
        end,
        on_refresh = function(browser)
            local active_server = currentServer(browser)
            if active_server then self:refreshServerLibrary(active_server, browser) end
        end,
        on_cycle_server = function(browser)
            local servers = browser.servers or {}
            if #servers < 2 then return end
            local active_server = currentServer(browser)
            local current_index = 1
            for index, candidate in ipairs(servers) do
                if active_server and candidate.id == active_server.id then current_index = index break end
            end
            local next_index = current_index + 1
            if next_index > #servers then next_index = 1 end
            self:showCachedServerLibrary(servers[next_index], browser)
        end,
        on_open_entry = function(browser, entry)
            local active_server = currentServer(browser)
            local active_documents = browser.documents or {}
            local active_authoritative = browser.authoritative == true
            local active_logical_mode = browser.logical_mode == true
            if not active_server then return end
            if entry.is_logical then
                self:showLogicalBookInspection(active_server, entry.item, browser)
            else
                owner:showServerDocumentInspection(active_server, entry.item, entry.match, active_documents, active_authoritative, active_logical_mode, browser, entry)
            end
        end,
        on_link_selected = function(browser, selected_entries)
            local active_server = currentServer(browser)
            local selected = {}
            for unused_index, entry in ipairs(selected_entries or {}) do
                if entry.item and entry.item.document then selected[#selected + 1] = entry.item end
            end
            if #selected < 2 or not active_server then return end
            closeBrowser(browser)
            self:showLogicalProgressSourcePicker(active_server, selected)
        end,
    }
    owner.library_browser = page
    UIManager:show(page)
end

return ServerLibraryController
