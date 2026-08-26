local ResponseUtil = {}

function ResponseUtil.isHtml(body)
    if type(body) ~= "string" then return false end
    local sample = body:sub(1, 1024):lower()
    sample = sample:gsub("^%s+", "")
    return sample:find("<!doctype html", 1, true) == 1
        or sample:find("<html", 1, true) == 1
        or sample:find("<head", 1, true) ~= nil
        or sample:find("<body", 1, true) ~= nil
end

return ResponseUtil
