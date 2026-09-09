local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local ReadingStatisticsAdapter = {}

ReadingStatisticsAdapter.SOURCE_TYPE = "koreader_statistics"
ReadingStatisticsAdapter.CURRENT_SCHEMA_VERSION = 20221111
ReadingStatisticsAdapter.DEFAULT_BATCH_SIZE = 200
ReadingStatisticsAdapter.INCREMENTAL_REWIND_SECONDS = 300

local function asInteger(value, fallback)
    local number = tonumber(value)
    if not number then return fallback end
    return math.floor(number)
end

local function clean(value)
    if value == nil then return nil end
    local text = tostring(value)
    if text == "" then return nil end
    return text
end

local function timezoneOffsetMinutes(timestamp)
    local zone = os.date("%z", timestamp)
    if type(zone) == "string" then
        local sign, hours, minutes = zone:match("^([+-])(%d%d)(%d%d)$")
        if sign then
            local offset = (tonumber(hours) or 0) * 60 + (tonumber(minutes) or 0)
            return sign == "-" and -offset or offset
        end
    end
    return 0
end

local function normalizedCursor(state)
    state = type(state) == "table" and state or {}
    return {
        start_time = math.max(0, asInteger(state.start_time, 0)),
        id_book = math.max(0, asInteger(state.id_book, 0)),
        page = asInteger(state.page, -1),
        initial_complete = state.initial_complete == true,
    }
end

function ReadingStatisticsAdapter.databasePath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

function ReadingStatisticsAdapter.makeScanCursor(state)
    local cursor = normalizedCursor(state)
    if cursor.initial_complete and cursor.start_time > 0 then
        cursor.start_time = math.max(0, cursor.start_time - ReadingStatisticsAdapter.INCREMENTAL_REWIND_SECONDS)
        cursor.id_book = 0
        cursor.page = -1
    end
    return cursor
end

local function eventFromRow(row)
    local start_time = asInteger(row[3], 0)
    local page = asInteger(row[2], 0)
    local id_book = asInteger(row[1], 0)
    return {
        source_book_id = id_book,
        source_event_key = table.concat({ tostring(id_book), tostring(page), tostring(start_time) }, ":"),
        md5 = clean(row[11]),
        title = clean(row[6]),
        authors = clean(row[7]),
        series = clean(row[8]),
        language = clean(row[9]),
        pages = math.max(0, asInteger(row[10], 0)),
        start_time = start_time,
        duration = math.max(1, asInteger(row[4], 1)),
        page = math.max(0, page),
        total_pages = math.max(0, asInteger(row[5], 0)),
        local_date = os.date("%Y-%m-%d", start_time),
        local_hour = asInteger(os.date("%H", start_time), 0),
        utc_offset_minutes = timezoneOffsetMinutes(start_time),
    }
end

function ReadingStatisticsAdapter.readBatch(state, limit)
    local db_path = ReadingStatisticsAdapter.databasePath()
    if lfs.attributes(db_path, "mode") ~= "file" then
        return {
            events = {},
            cursor = normalizedCursor(state),
            source_schema_version = nil,
            missing = true,
        }
    end

    local cursor = normalizedCursor(state)
    limit = math.max(1, math.min(asInteger(limit, ReadingStatisticsAdapter.DEFAULT_BATCH_SIZE), 500))

    local conn
    local ok, result = pcall(function()
        conn = SQ3.open(db_path, "ro")
        if conn.set_busy_timeout then conn:set_busy_timeout(1000) end

        local schema_version = asInteger(conn:rowexec("PRAGMA user_version;"), 0)
        if schema_version < 20201010 then
            error("Unsupported KOReader statistics database schema " .. tostring(schema_version))
        end
        if not conn:rowexec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='book';")
            or not conn:rowexec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_stat_data';") then
            error("KOReader statistics database is missing required tables")
        end

        local statement = conn:prepare([[
            SELECT p.id_book,
                   p.page,
                   p.start_time,
                   p.duration,
                   p.total_pages,
                   b.title,
                   b.authors,
                   b.series,
                   b.language,
                   b.pages,
                   b.md5
            FROM page_stat_data AS p
            JOIN book AS b ON b.id = p.id_book
            WHERE p.id_book IS NOT NULL
              AND p.start_time > 0
              AND p.duration > 0
              AND (
                    p.start_time > ?
                 OR (p.start_time = ? AND p.id_book > ?)
                 OR (p.start_time = ? AND p.id_book = ? AND p.page > ?)
              )
            ORDER BY p.start_time ASC, p.id_book ASC, p.page ASC
            LIMIT ?
        ]])
        statement:bind(
            cursor.start_time,
            cursor.start_time,
            cursor.id_book,
            cursor.start_time,
            cursor.id_book,
            cursor.page,
            limit
        )

        local events = {}
        local next_cursor = normalizedCursor(cursor)
        for row in statement:rows() do
            local event = eventFromRow(row)
            events[#events + 1] = event
            next_cursor.start_time = event.start_time
            next_cursor.id_book = event.source_book_id
            next_cursor.page = event.page
        end
        statement:close()

        return {
            events = events,
            cursor = next_cursor,
            source_schema_version = schema_version,
            missing = false,
        }
    end)

    if conn then pcall(conn.close, conn) end
    if not ok then return nil, tostring(result) end
    return result
end

return ReadingStatisticsAdapter
