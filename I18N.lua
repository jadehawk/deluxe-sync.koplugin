local JSON = require("json")

local I18N = {}

local function moduleDir()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)[/\\][^/\\]+$")
    return path or "."
end

local ROOT = moduleDir()
local DEFAULT_LANGUAGE = "en"

local function normalizeLanguage(language)
    language = tostring(language or DEFAULT_LANGUAGE):gsub("_", "-")
    if language == "" then return DEFAULT_LANGUAGE end
    return language
end

local function loadCatalog(language)
    local path = ROOT .. "/i18n/" .. language .. ".json"
    local file = io.open(path, "rb")
    if not file then return nil end

    local content = file:read("*a")
    file:close()
    if not content or content == "" then return nil end

    local ok, catalog = pcall(JSON.decode, content)
    if not ok or type(catalog) ~= "table" then return nil end
    return catalog
end

local english = loadCatalog(DEFAULT_LANGUAGE) or {}
local requested_language = DEFAULT_LANGUAGE
if G_reader_settings and G_reader_settings.readSetting then
    requested_language = normalizeLanguage(G_reader_settings:readSetting("language"))
end

local catalog = english
if requested_language ~= DEFAULT_LANGUAGE then
    catalog = loadCatalog(requested_language)
    if not catalog then
        local base_language = requested_language:match("^([^-]+)")
        if base_language and base_language ~= DEFAULT_LANGUAGE then
            catalog = loadCatalog(base_language)
        end
    end
    catalog = catalog or english
end

function I18N.translate(text)
    if type(text) ~= "string" then return text end
    return catalog[text] or english[text] or text
end

function I18N.getLanguage()
    return requested_language
end

function I18N.getDefaultLanguage()
    return DEFAULT_LANGUAGE
end

return I18N
