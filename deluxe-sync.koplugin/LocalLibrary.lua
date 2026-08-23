local DocumentRegistry = require("document/documentregistry")
local BookList = require("ui/widget/booklist")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
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
