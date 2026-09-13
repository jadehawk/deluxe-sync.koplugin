local Dpad = require("DeluxeDpad")

local events = Dpad.pageKeyEvents(nil)

local function hasKey(bindings, key)
    for _, binding in ipairs(bindings or {}) do
        if type(binding) == "table" and binding[1] == key then return true end
    end
    return false
end

assert(hasKey(events.DpadBack, "Back"), "Back key alias missing")
assert(hasKey(events.DpadBack, "Escape"), "Escape key alias missing")
assert(hasKey(events.DpadPrevPage, "LPgBack"), "left page-back key alias missing")
assert(hasKey(events.DpadNextPage, "RPgFwd"), "right page-forward key alias missing")
assert(hasKey(events.DpadPress, "Select"), "Kindle Select key alias missing")
assert(hasKey(events.DpadPress, "Return"), "Return key alias missing")
assert(hasKey(events.DpadMenu, "Menu"), "Menu key alias missing")

local actions = { false, function() end, false, function() end }
assert(Dpad.activeActionIndex(actions, 1) == 2, "activeActionIndex should skip disabled actions")
assert(Dpad.activeActionIndex(actions, 4) == 4, "activeActionIndex should preserve an active preferred action")
assert(Dpad.nextActionIndex(actions, 2, 1) == 4, "nextActionIndex should move right across disabled actions")
assert(Dpad.nextActionIndex(actions, 4, 1) == 2, "nextActionIndex should wrap forward")
assert(Dpad.nextActionIndex(actions, 2, -1) == 4, "nextActionIndex should wrap backward")
assert(Dpad.activeActionIndex({}, 1) == nil, "empty action rows should have no active index")

print("deluxe_dpad_test.lua: OK")
