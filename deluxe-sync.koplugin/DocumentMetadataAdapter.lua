local DocumentMetadataAdapter = {}

local EXPLICIT_ASIN_FIELDS = {
    "asin",
    "mobi_asin",
    "mobi-asin",
    "amazon_asin",
    "amazon-asin",
}

local function trim(value)
    if type(value) ~= "string" then return nil end
    local text = value:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

local function normalizeLabel(value)
    local text = trim(value)
    if not text then return nil end
    return text:lower():gsub("[%s_%-]+", "")
end

function DocumentMetadataAdapter.normalizeAsin(value)
    local text = trim(value)
    if not text then return nil end
    text = text:upper()
    if #text ~= 10 or not text:match("^[A-Z0-9]+$") then return nil end
    return text
end

local function isAsinLabel(value)
    local label = normalizeLabel(value)
    return label == "asin"
        or label == "mobiasin"
        or label == "amazonasin"
        or label == "amazon"
end

function DocumentMetadataAdapter.extractAsinFromIdentifiers(identifiers)
    if type(identifiers) == "string" then
        local upper = identifiers:upper()

        for label, value in upper:gmatch("([A-Z][A-Z0-9_%-]*)%s*[:=#]%s*([A-Z0-9]+)") do
            if isAsinLabel(label) then
                local asin = DocumentMetadataAdapter.normalizeAsin(value)
                if asin then return asin end
            end
        end

        for _, label in ipairs({ "ASIN", "MOBI%-ASIN", "MOBI_ASIN", "AMAZON%-ASIN", "AMAZON_ASIN" }) do
            local value = upper:match("%f[%a]" .. label .. "%f[^%w_%-]%s+([A-Z0-9]+)")
            local asin = DocumentMetadataAdapter.normalizeAsin(value)
            if asin then return asin end
        end

        return nil
    end

    if type(identifiers) ~= "table" then return nil end

    for key, value in pairs(identifiers) do
        if type(key) == "string" and isAsinLabel(key) then
            local asin = DocumentMetadataAdapter.normalizeAsin(value)
            if asin then return asin end
            asin = DocumentMetadataAdapter.extractAsinFromIdentifiers(value)
            if asin then return asin end
        elseif type(key) == "number" then
            local asin = DocumentMetadataAdapter.extractAsinFromIdentifiers(value)
            if asin then return asin end
        end
    end

    return nil
end

local function extractExplicitField(props)
    if type(props) ~= "table" then return nil end
    for _, key in ipairs(EXPLICIT_ASIN_FIELDS) do
        local value = props[key]
        local asin = DocumentMetadataAdapter.normalizeAsin(value)
            or DocumentMetadataAdapter.extractAsinFromIdentifiers(value)
        if asin then return asin end
    end
    return nil
end

local function rawProps(ui)
    if not ui or not ui.document then return {} end
    local ok, props = pcall(function()
        return ui.document:getProps()
    end)
    if ok and type(props) == "table" then return props end
    return {}
end

function DocumentMetadataAdapter.extractAsin(ui)
    if type(ui) ~= "table" then return nil end

    local props = type(ui.doc_props) == "table" and ui.doc_props or {}
    local raw = rawProps(ui)

    return extractExplicitField(raw)
        or DocumentMetadataAdapter.extractAsinFromIdentifiers(raw.identifiers)
        or extractExplicitField(props)
        or DocumentMetadataAdapter.extractAsinFromIdentifiers(props.identifiers)
end

return DocumentMetadataAdapter
