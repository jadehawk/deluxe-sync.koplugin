local Resolver = {}

local function progressKey(item)
    return tostring(item.group_key or item.progress or "")
end

function Resolver.group(results)
    local groups_by_progress = {}
    local groups = {}
    for _, result in ipairs(results or {}) do
        if result.ok and result.progress ~= nil then
            local key = progressKey(result)
            local group = groups_by_progress[key]
            if not group then
                group = {
                    progress = result.progress,
                    percentage = result.percentage,
                    timestamp = result.timestamp or 0,
                    servers = {},
                }
                groups_by_progress[key] = group
                table.insert(groups, group)
            end
            table.insert(group.servers, result)
            if (result.timestamp or 0) > (group.timestamp or 0) then
                group.timestamp = result.timestamp
                group.percentage = result.percentage
            end
        end
    end
    table.sort(groups, function(a, b)
        if (a.timestamp or 0) == (b.timestamp or 0) then
            return (a.percentage or 0) > (b.percentage or 0)
        end
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    return groups
end

function Resolver.failures(results)
    local out = {}
    for _, result in ipairs(results or {}) do
        if not result.ok then table.insert(out, result) end
    end
    return out
end

function Resolver.samePosition(results)
    local key
    local seen = false
    for _, result in ipairs(results or {}) do
        if result.ok and result.progress ~= nil then
            local current = progressKey(result)
            if not seen then
                key = current
                seen = true
            elseif current ~= key then
                return false
            end
        end
    end
    return seen
end

function Resolver.chooseAutomatic(results, local_progress, local_percentage, local_timestamp)
    local groups = Resolver.group(results)
    local group = groups[1]
    if not group then return nil, "same" end
    if local_progress ~= nil and tostring(group.progress or "") == tostring(local_progress) then
        return group, "same"
    end

    local remote_timestamp = tonumber(group.timestamp) or 0
    local current_timestamp = tonumber(local_timestamp) or 0
    if remote_timestamp > 0 and current_timestamp > 0 then
        return group, remote_timestamp > current_timestamp and "newer" or "older"
    end

    local remote_percentage = tonumber(group.percentage) or 0
    local current_percentage = tonumber(local_percentage) or 0
    return group, remote_percentage > current_percentage and "newer" or "older"
end

return Resolver
