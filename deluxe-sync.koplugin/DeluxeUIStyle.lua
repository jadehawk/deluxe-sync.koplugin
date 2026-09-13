local Device = require("device")

local Style = {
    header_font = 19,
    action_font = 15,
    primary_font = 17,
    value_font = 14,
    setting_label_font = 13,
    secondary_font = 14,
    tertiary_font = 13,
    section_font = 14,
    grid_status_font = 14,
}

function Style.scale(value)
    return math.max(1, Device.screen:scaleBySize(value))
end

function Style.headerHeight()
    return math.max(40, Style.scale(42))
end

function Style.gap()
    return Style.scale(8)
end

function Style.compactGap()
    return Style.scale(4)
end

function Style.sectionGap()
    return Style.scale(2)
end

function Style.cellHeight()
    return math.max(36, Style.scale(38))
end

function Style.sectionHeight()
    return math.max(20, Style.scale(22))
end

function Style.focusBorder()
    return math.max(2, Style.scale(3))
end

function Style.thinBorder()
    return 1
end

function Style.sectionPadding()
    return Style.scale(3)
end

function Style.cellPadding()
    return Style.scale(3)
end

function Style.pageMargin()
    return Style.scale(6)
end

function Style.gridGap()
    return Style.scale(8)
end

function Style.listPadding()
    return Style.scale(5)
end

return Style
