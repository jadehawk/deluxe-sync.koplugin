local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")
local ltn12 = require("ltn12")
local socket_http = require("socket.http")
local socket_https = require("ssl.https")

local CoverCache = {}

local ROOT = DataStorage:getSettingsDir() .. "/deluxe-sync/covers"

local function mkdir(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        local ok = lfs.mkdir(path)
        if not ok and lfs.attributes(path, "mode") ~= "directory" then return false end
    end
    return true
end

local function serverDir(server)
    if not mkdir(ROOT) then return nil end
    local key = sha.md5(tostring(server and (server.id or server.url) or "server"))
    local dir = ROOT .. "/" .. key
    if not mkdir(dir) then return nil end
    return dir
end

local function keyFor(item)
    if item and type(item.cover_hash) == "string" and item.cover_hash:match("^[%w_-]+$") then
        return item.cover_hash
    end
    return sha.md5(table.concat({
        tostring(item and (item.document or item.logical_book_id or item.key) or ""),
        tostring(item and item.title or ""),
    }, "\0"))
end

function CoverCache.path(server, item)
    local dir = serverDir(server)
    if not dir then return nil end
    return dir .. "/" .. keyFor(item) .. ".img"
end

function CoverCache.cachedPath(server, item)
    local path = CoverCache.path(server, item)
    if not path then return nil end
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" and tonumber(attr.size or 0) > 0 then return path end
    return nil
end

function CoverCache.resolveUrl(server, item)
    local cover_url = item and item.cover_url
    if type(cover_url) ~= "string" or cover_url == "" or not server or type(server.url) ~= "string" then return nil end
    local base = server.url:gsub("/+$", "")
    if cover_url:sub(1, 1) == "/" then return base .. cover_url end
    if cover_url:sub(1, #base + 1) == base .. "/" then return cover_url end
    return nil
end

function CoverCache.download(server, item)
    local url = CoverCache.resolveUrl(server, item)
    if not url then return nil, "no trusted server cover URL" end
    local target = CoverCache.path(server, item)
    if not target then return nil, "cover cache unavailable" end
    if CoverCache.cachedPath(server, item) then return target end

    local tmp = target .. ".part"
    local file, err = io.open(tmp, "wb")
    if not file then return nil, err or "cannot open cover cache file" end
    local request = url:match("^https://") and socket_https or socket_http
    local ok, code = request.request{
        url = url,
        sink = ltn12.sink.file(file),
        headers = { ["User-Agent"] = "Deluxe-Sync-KOReader" },
    }
    if not ok or tonumber(code) ~= 200 then
        pcall(os.remove, tmp)
        return nil, "cover download failed: " .. tostring(code)
    end
    local attr = lfs.attributes(tmp)
    if not attr or tonumber(attr.size or 0) <= 0 then
        pcall(os.remove, tmp)
        return nil, "empty cover response"
    end
    pcall(os.remove, target)
    local renamed, rename_err = os.rename(tmp, target)
    if not renamed then
        pcall(os.remove, tmp)
        return nil, rename_err or "cannot finalize cover cache"
    end
    return target
end

return CoverCache
