local sidecar_data = {
    partial_md5_checksum = "ABCDEF0123456789ABCDEF0123456789",
    doc_path = "/old/location/book.epub",
    doc_props = {
        title = "Recovered Book",
        authors = "Recovered Author",
    },
}

local directories = {
    ["/home"] = { "nested", "book.sdr", "book.epub" },
    ["/home/nested"] = {},
    ["/home/book.sdr"] = { "metadata.epub.lua" },
}

local attributes = {
    ["/home"] = { mode = "directory" },
    ["/home/nested"] = { mode = "directory" },
    ["/home/book.sdr"] = { mode = "directory" },
    ["/home/book.sdr/metadata.epub.lua"] = { mode = "file" },
    ["/home/book.epub"] = { mode = "file" },
}

package.preload["document/documentregistry"] = function()
    return { hasProvider = function() return false end }
end
package.preload["ui/widget/booklist"] = function()
    return {
        hasBookBeenOpened = function() return false end,
        getDocSettings = function() return nil end,
    }
end
package.preload["apps/filemanager/filemanagerbookinfo"] = function()
    return { extendProps = function(props) return props or {} end }
end
package.preload["apps/filemanager/filemanagerutil"] = function()
    return { getHomeFolder = function() return "/home" end }
end
package.preload["luasettings"] = function()
    return {
        open = function(_, path)
            assert(path == "/home/book.sdr/metadata.epub.lua")
            return {
                readSetting = function(_, key)
                    return sidecar_data[key]
                end,
            }
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            local entries = assert(directories[path], "unexpected directory: " .. tostring(path))
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end, nil
        end,
        attributes = function(path)
            return attributes[path]
        end,
    }
end
package.preload["util"] = function()
    return {
        splitFilePathName = function(path)
            local dir, name = tostring(path):match("^(.*[/])([^/]*)$")
            return dir, name or path
        end,
        partialMD5 = function()
            error("sidecar Find Match must not hash book files")
        end,
    }
end

package.loaded["LocalLibrary"] = nil
local LocalLibrary = dofile("LocalLibrary.lua")

local match = assert(LocalLibrary.findByDocument("abcdef0123456789abcdef0123456789", "/home"))
assert(match.document == sidecar_data.partial_md5_checksum, "stored partial MD5 should be returned")
assert(match.path == "/home/book.epub", "stale doc_path should recover the sibling book beside its .sdr folder")
assert(match.filename == "book.epub", "local filename should be recovered")
assert(match.title == "Recovered Book", "local title should come from doc_props")
assert(match.authors == "Recovered Author", "local author should come from doc_props")
assert(match.confidence == "sidecar-binary", "sidecar checksum matches must be identified as binary")
assert(match.book_exists == true, "recovered sibling book should be marked available")
assert(LocalLibrary.findByDocument("00000000000000000000000000000000", "/home") == nil, "unknown checksum should not produce a false match")

print("local_library_sidecar_test.lua: OK")
