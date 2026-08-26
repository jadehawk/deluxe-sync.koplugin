local UrlUtil = {}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

function UrlUtil.normalize(url)
    url = trim(url)
    if url == "" then return nil, "Server URL is empty" end
    if url:find("%s") then return nil, "Server URL contains whitespace" end

    local scheme, rest = url:match("^([%a][%w+.-]*)://(.+)$")
    if scheme then
        scheme = scheme:lower()
        if scheme ~= "http" and scheme ~= "https" then
            return nil, "Server URL must use http:// or https://"
        end
        url = scheme .. "://" .. rest
    else
        if url:find("://", 1, true) then
            return nil, "Server URL has an invalid scheme"
        end
        url = "https://" .. url
    end

    local authority = url:match("^https?://([^/%?#]+)")
    if not authority or authority == "" or authority:sub(1, 1) == ":" then
        return nil, "Server URL must include a host"
    end

    return url
end

return UrlUtil
