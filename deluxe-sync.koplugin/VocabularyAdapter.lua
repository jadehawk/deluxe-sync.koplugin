local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local sha = require("ffi/sha2")

local VocabularyAdapter = {}

VocabularyAdapter.DEFAULT_BATCH_SIZE = 500

local function clean(value)
    if value == nil then return nil end
    local text = tostring(value):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    return text
end

local function integer(value, fallback)
    local number = tonumber(value)
    if not number then return fallback end
    return math.max(0, math.floor(number))
end

local function identityText(value)
    return string.lower(clean(value) or "")
end

local function field(value)
    if value == nil then return "" end
    return tostring(value)
end

local function recordId(word, title)
    return sha.sha256(table.concat({ "vocabulary-v1", identityText(word), identityText(title) }, "\0"))
end

local function recordHash(record, include_context)
    local parts = {
        "vocabulary-record-v1",
        field(record.word),
        field(record.title),
        field(record.title_filter),
        field(record.create_time),
        field(record.review_time),
        field(record.due_time),
        field(record.review_count),
        field(record.streak_count),
    }
    if include_context then
        parts[#parts + 1] = field(record.prev_context)
        parts[#parts + 1] = field(record.next_context)
        parts[#parts + 1] = field(record.highlight)
    end
    return sha.sha256(table.concat(parts, "\0"))
end

local function normalizedRecord(row, include_context)
    local word = clean(row[1])
    if not word then return nil end
    local title = clean(row[2])
    local title_filter = row[3] == nil and nil or tostring(integer(row[3], 0))
    local record = {
        id = recordId(word, title),
        word = word,
        title = title,
        title_filter = title_filter,
        create_time = integer(row[4], 0),
        review_time = row[5] == nil and nil or integer(row[5], 0),
        due_time = integer(row[6], 0),
        review_count = integer(row[7], 0),
        streak_count = integer(row[8], 0),
    }
    if include_context then
        record.prev_context = clean(row[9])
        record.next_context = clean(row[10])
        record.highlight = clean(row[11])
    end
    record.record_hash = recordHash(record, include_context)
    return record
end

function VocabularyAdapter.databasePath()
    return DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
end

function VocabularyAdapter.tombstone(id)
    id = clean(id)
    if not id then return nil end
    return {
        id = id,
        record_hash = sha.sha256("vocabulary-delete-v1\0" .. id),
        deleted = true,
    }
end

function VocabularyAdapter.scan(include_context)
    include_context = include_context == true
    local db_path = VocabularyAdapter.databasePath()
    if lfs.attributes(db_path, "mode") ~= "file" then
        return {
            records = {},
            hashes = {},
            missing = true,
            context_included = include_context,
        }
    end

    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(db_path, "ro")
        if conn.set_busy_timeout then conn:set_busy_timeout(1000) end
        if not conn:rowexec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='vocabulary';")
            or not conn:rowexec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='title';") then
            error("KOReader Vocabulary Builder database is missing required tables")
        end

        local columns = [[
            v.word,
            t.name,
            t.filter,
            v.create_time,
            v.review_time,
            v.due_time,
            v.review_count,
            v.streak_count
        ]]
        if include_context then
            columns = columns .. [[,
            v.prev_context,
            v.next_context,
            v.highlight
            ]]
        end
        local statement = conn:prepare("SELECT " .. columns .. [[
            FROM vocabulary AS v
            LEFT JOIN title AS t ON t.id = v.title_id
            ORDER BY v.word COLLATE NOCASE ASC, v.word ASC
        ]])

        local records = {}
        local hashes = {}
        for row in statement:rows() do
            local record = normalizedRecord(row, include_context)
            if record then
                records[#records + 1] = record
                hashes[record.id] = record.record_hash
            end
        end
        statement:close()
        return {
            records = records,
            hashes = hashes,
            missing = false,
            context_included = include_context,
        }
    end)

    if conn then pcall(conn.close, conn) end
    if not ok then return nil, tostring(result) end
    return result
end

return VocabularyAdapter
