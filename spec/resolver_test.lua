package.path = "./?.lua;" .. package.path

local Resolver = require("Resolver")

local results = {
    { ok = true, progress = "xp-a", percentage = 0.42, timestamp = 100, server = { name = "A" } },
    { ok = true, progress = "xp-a", percentage = 0.42, timestamp = 110, server = { name = "B" } },
    { ok = true, progress = "xp-b", percentage = 0.61, timestamp = 120, server = { name = "C" } },
    { ok = false, status = 503, server = { name = "D" } },
}

local groups = Resolver.group(results)
assert(#groups == 2, "expected two distinct progress groups")
assert(groups[1].progress == "xp-b", "newest group must be first")
assert(groups[2].progress == "xp-a", "matching positions must be grouped")
assert(#groups[2].servers == 2, "two servers should share xp-a")
assert(#Resolver.failures(results) == 1, "one failure expected")
assert(Resolver.samePosition({ results[1], results[2] }) == true, "same position should agree")
assert(Resolver.samePosition({ results[1], results[3] }) == false, "different positions should conflict")

local ui_test_results = {
    { ok = true, progress = "xp-a", group_key = "ui-a", percentage = 0.12, timestamp = 100, server = { name = "UI A" } },
    { ok = true, progress = "xp-a", group_key = "ui-b", percentage = 0.34, timestamp = 110, server = { name = "UI B" } },
}
local ui_test_groups = Resolver.group(ui_test_results)
assert(#ui_test_groups == 2, "explicit UI test grouping keys should keep cloned server rows separate")
assert(ui_test_groups[1].percentage == 0.34, "UI test groups should still sort newest/highest consistently")

local auto_group, auto_direction = Resolver.chooseAutomatic(results, "local-xp", 0.50, 115)
assert(auto_group.progress == "xp-b", "automatic sync should choose the newest remote group")
assert(auto_direction == "newer", "remote timestamp newer than local activity should be newer")

local _, older_direction = Resolver.chooseAutomatic(results, "local-xp", 0.70, 130)
assert(older_direction == "older", "remote timestamp older than local activity should be older")

local _, percentage_direction = Resolver.chooseAutomatic({
    { ok = true, progress = "xp-c", percentage = 0.80, timestamp = nil, server = { name = "E" } },
}, "local-xp", 0.60, 0)
assert(percentage_direction == "newer", "percentage should be the fallback when timestamps cannot be compared")

local _, same_direction = Resolver.chooseAutomatic({ results[3] }, "xp-b", 0.61, 0)
assert(same_direction == "same", "matching progress must not trigger an automatic move")

print("resolver_test.lua: OK")
