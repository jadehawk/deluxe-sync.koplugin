local DocumentRegistry = require("document/documentregistry")
local BookList = require("ui/widget/booklist")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local LocalLibrary = {}

local function normalize(value)
    value = tostring(value or ""):lower()
    value = value:gsub("%.[%w%d]+$", "")
    value = value:gsub("[^%w]+", " ")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("%s+", " ")
    return value
end

local function basename(path)
    local _, name = util.splitFilePathName(path)
    return name or path
end

local function cachedProps(file)
    local props
    if BookList.hasBookBeenOpened(file) then
        local settings = BookList.getDocSettings(file)
        if settings then props = settings:readSetting("doc_props") end
    end
    return FileManagerBookInfo.extendProps(props or {}, file)
end

local function walk(dir, callback)
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok or not iter then return end
    for entry in iter, state do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                if not entry:match("%.sdr$") then walk(path, callback) end
            elseif attr and attr.mode == "file" and DocumentRegistry:hasProvider(path) then
                callback(path)
            end
        end
    end
end

local function existingFile(path)
    if not path or path == "" then return nil end
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file" and path or nil
end

local function resolveSidecarBookPath(sidecar_path, stored_path)
    local existing = existingFile(stored_path)
    if existing then return existing end
    local sdr_dir, extension = tostring(sidecar_path or ""):match("^(.*%.sdr)/metadata%.([^/]+)%.lua$")
    if sdr_dir and extension then
        local sibling = sdr_dir:gsub("%.sdr$", "") .. "." .. extension
        existing = existingFile(sibling)
        if existing then return existing end
    end
    return stored_path
end

local function walkSidecars(dir, callback)
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok or not iter then return false end
    for entry in iter, state do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                if entry:match("%.sdr$") then
                    local sidecar_ok, sidecar_iter, sidecar_state = pcall(lfs.dir, path)
                    if sidecar_ok and sidecar_iter then
                        for sidecar_name in sidecar_iter, sidecar_state do
                            if sidecar_name:match("^metadata%.[^/]+%.lua$") then
                                if callback(path .. "/" .. sidecar_name) then return true end
                            end
                        end
                    end
                elseif walkSidecars(path, callback) then
                    return true
                end
            end
        end
    end
    return false
end

function LocalLibrary.findByDocument(document, root)
    if not document or tostring(document) == "" then return nil end
    root = root or filemanagerutil.getHomeFolder()
    local wanted = tostring(document):lower()
    local found
    walkSidecars(root, function(sidecar_path)
        local ok, settings = pcall(function() return LuaSettings:open(sidecar_path) end)
        if not ok or not settings then return false end
        local digest = settings:readSetting("partial_md5_checksum")
        if not digest or tostring(digest):lower() ~= wanted then return false end
        local props = settings:readSetting("doc_props") or {}
        local stored_path = settings:readSetting("doc_path")
        local book_path = resolveSidecarBookPath(sidecar_path, stored_path)
        found = {
            path = book_path,
            document = tostring(digest),
            filename = book_path and basename(book_path) or nil,
            title = props.display_title or props.title,
            authors = props.authors,
            confidence = "sidecar-binary",
            sidecar = sidecar_path,
            book_exists = existingFile(book_path) ~= nil,
        }
        return true
    end)
    return found
end

function LocalLibrary.scan(remote_documents, root)
    root = root or filemanagerutil.getHomeFolder()
    local by_digest = {}
    local by_filename = {}
    local by_title_author = {}

    for _, remote in ipairs(remote_documents or {}) do
        if remote.document then by_digest[remote.document] = true end
        if remote.filename then by_filename[normalize(remote.filename)] = true end
        if remote.title then
            by_title_author[normalize(remote.title) .. "\0" .. normalize(remote.authors)] = true
        end
    end

    local matches = {}
    walk(root, function(path)
        local props = cachedProps(path)
        local filename_key = normalize(basename(path))
        local title_key = normalize(props.display_title or props.title) .. "\0" .. normalize(props.authors)
        local digest
        local confidence
        local matched_remote

        if by_filename[filename_key] then
            confidence = "filename"
        elseif by_title_author[title_key] and title_key ~= "\0" then
            confidence = "metadata"
        end

        -- Binary identity is authoritative and upgrades any heuristic match.
        digest = util.partialMD5(path)
        if digest and by_digest[digest] then confidence = "binary" end

        if confidence then
            for _, remote in ipairs(remote_documents or {}) do
                if confidence == "binary" and remote.document == digest then
                    matched_remote = remote
                    break
                elseif confidence == "filename" and normalize(remote.filename) == filename_key then
                    matched_remote = remote
                    break
                elseif confidence == "metadata" and normalize(remote.title) .. "\0" .. normalize(remote.authors) == title_key then
                    matched_remote = remote
                    break
                end
            end
        end

        if matched_remote then
            matches[matched_remote.document or tostring(matched_remote)] = {
                path = path,
                document = digest,
                filename = basename(path),
                title = props.display_title or props.title,
                authors = props.authors,
                confidence = confidence,
            }
        end
    end)

    return matches
end

function LocalLibrary.matchCurrent(remote, current_file, current_props, current_digest)
    if not remote or not current_file then return end
    local filename = basename(current_file)
    local local_title = current_props and (current_props.display_title or current_props.title)
    local local_authors = current_props and current_props.authors
    if current_digest and remote.document == current_digest then return "binary" end
    if remote.filename and normalize(remote.filename) == normalize(filename) then return "filename" end
    if remote.title and normalize(remote.title) == normalize(local_title)
            and normalize(remote.authors) == normalize(local_authors) then
        return "metadata"
    end
end

return LocalLibrary
