package.path = "./?.lua;" .. package.path

local UpdatePolicy = require("update_policy")

local function isNewer(candidate, current)
    local function parse(version)
        local a, b, c = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)$")
        if not a then return nil end
        return tonumber(a), tonumber(b), tonumber(c)
    end
    local a, b, c = parse(candidate)
    local x, y, z = parse(current)
    if not a or not x then return false end
    if a ~= x then return a > x end
    if b ~= y then return b > y end
    return c > z
end

assert(UpdatePolicy.should_prompt("0.1.1", "0.1.0", nil, isNewer) == true)
assert(UpdatePolicy.should_prompt("0.1.1", "0.1.0", "0.1.1", isNewer) == false)
assert(UpdatePolicy.should_prompt("0.1.0", "0.1.0", nil, isNewer) == false)
assert(UpdatePolicy.should_prompt("0.0.9", "0.1.0", nil, isNewer) == false)
assert(UpdatePolicy.should_prompt("", "0.1.0", nil, isNewer) == false)

print("update_policy_test.lua: OK")
