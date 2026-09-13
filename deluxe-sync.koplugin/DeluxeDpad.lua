local Dpad = {}

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function appendGroup(bindings, group)
    if group then table.insert(bindings, { group }) end
end

function Dpad.isTouchDevice(device)
    if not device then return false end
    if type(device.isTouchDevice) == "function" then
        local ok, value = pcall(device.isTouchDevice, device)
        if ok then return value == true end
    end
    if type(device.isTouch) == "function" then
        local ok, value = pcall(device.isTouch, device)
        if ok then return value == true end
    end
    return false
end

-- Keep these aliases aligned with the Libby browser/libbee navigation model.
-- Older Kindles may report the center button as Select/Return and page keys as
-- LPg*/RPg* rather than the generic KOReader input groups.
function Dpad.pageKeyEvents(device)
    local events = {
        DpadBack = { { "Back" }, { "Escape" }, { "Esc" } },
        DpadPrevPage = { { "PgUp" }, { "PgBack" }, { "Prev" }, { "LPgBack" }, { "RPgBack" } },
        DpadNextPage = { { "PgDn" }, { "PgFwd" }, { "Next" }, { "LPgFwd" }, { "RPgFwd" } },
        DpadUp = { { "Up" } },
        DpadDown = { { "Down" } },
        DpadLeft = { { "Left" } },
        DpadRight = { { "Right" } },
        DpadPress = { { "Press" }, { "Enter" }, { "Return" }, { "Select" } },
        DpadMenu = { { "Menu" }, { "F10" } },
    }
    local groups = device and device.input and device.input.group or nil
    if groups then
        appendGroup(events.DpadBack, groups.Back)
        appendGroup(events.DpadPrevPage, groups.PgBack)
        appendGroup(events.DpadNextPage, groups.PgFwd)
        appendGroup(events.DpadUp, groups.Up)
        appendGroup(events.DpadDown, groups.Down)
        appendGroup(events.DpadLeft, groups.Left)
        appendGroup(events.DpadRight, groups.Right)
        appendGroup(events.DpadPress, groups.Press)
        appendGroup(events.DpadPress, groups.Enter)
        appendGroup(events.DpadMenu, groups.Menu)
    end
    return events
end

function Dpad.activeActionIndex(actions, preferred)
    local count = type(actions) == "table" and #actions or 0
    if count == 0 then return nil end
    preferred = clamp(tonumber(preferred) or 1, 1, count)
    for offset = 0, count - 1 do
        local index = ((preferred - 1 + offset) % count) + 1
        if type(actions[index]) == "function" then return index end
    end
    return nil
end

function Dpad.nextActionIndex(actions, current, delta)
    local count = type(actions) == "table" and #actions or 0
    if count == 0 then return nil end
    local index = clamp(tonumber(current) or 1, 1, count)
    local step = tonumber(delta) and tonumber(delta) < 0 and -1 or 1
    for _ = 1, count do
        index = ((index - 1 + step) % count) + 1
        if type(actions[index]) == "function" then return index end
    end
    return Dpad.activeActionIndex(actions, current)
end

return Dpad
