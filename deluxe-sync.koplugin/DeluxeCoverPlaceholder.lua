local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local I18N = require("I18N")
local _ = I18N.translate

local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_root = source_path:match("^(.*)[/\\]DeluxeCoverPlaceholder%.lua$") or "."
local NO_COVER_IMAGE = plugin_root .. "/dependencies/icons/no-cover.png"

local DeluxeCoverPlaceholder = {}

function DeluxeCoverPlaceholder.fit(max_width, max_height)
    max_width = math.max(1, math.floor(tonumber(max_width) or 1))
    max_height = math.max(1, math.floor(tonumber(max_height) or 1))
    local width = math.min(max_width, math.floor(max_height * 2 / 3))
    local height = math.min(max_height, math.floor(width * 3 / 2))
    if height > max_height then
        height = max_height
        width = math.min(max_width, math.floor(height * 2 / 3))
    end
    return math.max(1, width), math.max(1, height)
end

function DeluxeCoverPlaceholder.new(width, height, opts)
    opts = opts or {}
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or 1))
    local border = math.max(0, math.floor(tonumber(opts.border) or 0))
    local inner_w = math.max(1, width - 2 * border)
    local inner_h = math.max(1, height - 2 * border)
    local image_w, image_h = DeluxeCoverPlaceholder.fit(inner_w, inner_h)
    local ok, scaled = pcall(function()
        return RenderImage:renderImageFile(NO_COVER_IMAGE, false, image_w, image_h)
    end)
    local child
    if ok and scaled then
        child = ImageWidget:new{ image = scaled, image_disposable = true, scale_factor = 1 }
    else
        child = TextWidget:new{ text = _("No cover"), face = Font:getFace("smallinfofont", 13) }
    end
    return FrameContainer:new{
        width = width,
        height = height,
        margin = 0,
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = opts.background or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            child,
        },
    }
end

function DeluxeCoverPlaceholder.centered(max_width, max_height, opts)
    local width, height = DeluxeCoverPlaceholder.fit(max_width, max_height)
    return CenterContainer:new{
        dimen = Geom:new{ w = math.max(1, math.floor(max_width)), h = math.max(1, math.floor(max_height)) },
        DeluxeCoverPlaceholder.new(width, height, opts),
    }
end

return DeluxeCoverPlaceholder
