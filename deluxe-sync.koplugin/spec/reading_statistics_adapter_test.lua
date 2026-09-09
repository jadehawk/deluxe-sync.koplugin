package.path = "./?.lua;" .. package.path

local captured = {}

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/mock/settings" end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            assert(path == "/mock/settings/statistics.sqlite3", "statistics DB path mismatch")
            assert(key == "mode", "lfs mode lookup expected")
            return "file"
        end,
    }
end

package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path, mode)
            captured.path = path
            captured.mode = mode
            local conn = {}
            function conn:set_busy_timeout(timeout) captured.timeout = timeout end
            function conn:rowexec(sql)
                if sql == "PRAGMA user_version;" then return 20221111 end
                if sql:find("name='book'", 1, true) then return 1 end
                if sql:find("name='page_stat_data'", 1, true) then return 1 end
                error("unexpected rowexec: " .. tostring(sql))
            end
            function conn:prepare(sql)
                captured.sql = sql
                local statement = {}
                function statement:bind(...)
                    captured.bind = { ... }
                end
                function statement:rows()
                    local rows = {
                        { 7, 12, 1788955200, 45, 300, "Book One", "Author One", "Series One", "en", 300, "abc123" },
                        { 7, 13, 1788955260, 30, 300, "Book One", "Author One", "Series One", "en", 300, "abc123" },
                    }
                    local index = 0
                    return function()
                        index = index + 1
                        return rows[index]
                    end
                end
                function statement:close() captured.statement_closed = true end
                return statement
            end
            function conn:close() captured.connection_closed = true end
            return conn
        end,
    }
end

local ReadingStatisticsAdapter = require("ReadingStatisticsAdapter")

assert(ReadingStatisticsAdapter.databasePath() == "/mock/settings/statistics.sqlite3", "database path must use KOReader settings directory")
local batch, err = ReadingStatisticsAdapter.readBatch({ start_time = 0, id_book = 0, page = -1, initial_complete = false }, 200)
assert(batch and not err, "readBatch failed: " .. tostring(err))
assert(captured.path == "/mock/settings/statistics.sqlite3", "SQLite open path mismatch")
assert(captured.mode == "ro", "statistics.sqlite3 must be opened read-only")
assert(captured.timeout == 1000, "read-only query should use a bounded busy timeout")
assert(captured.sql:find("FROM page_stat_data AS p", 1, true), "page_stat_data query missing")
assert(captured.sql:find("JOIN book AS b", 1, true), "book metadata join missing")
assert(captured.bind[1] == 0 and captured.bind[7] == 200, "initial cursor or batch limit mismatch")
assert(captured.statement_closed and captured.connection_closed, "SQLite resources must be closed")
assert(batch.source_schema_version == 20221111, "schema version mismatch")
assert(#batch.events == 2, "expected two normalized reading events")
assert(batch.events[1].source_book_id == 7, "source book id mismatch")
assert(batch.events[1].md5 == "abc123", "book md5 mismatch")
assert(batch.events[1].title == "Book One" and batch.events[1].authors == "Author One", "book metadata mismatch")
assert(batch.events[1].series == "Series One" and batch.events[1].language == "en", "series/language metadata mismatch")
assert(batch.events[1].page == 12 and batch.events[1].total_pages == 300, "page metadata mismatch")
assert(batch.events[1].duration == 45, "duration mismatch")
assert(type(batch.events[1].local_date) == "string" and batch.events[1].local_date:match("^%d%d%d%d%-%d%d%-%d%d$"), "local date normalization missing")
assert(type(batch.events[1].local_hour) == "number" and batch.events[1].local_hour >= 0 and batch.events[1].local_hour <= 23, "local hour normalization missing")
assert(type(batch.events[1].utc_offset_minutes) == "number", "UTC offset normalization missing")
assert(batch.cursor.start_time == 1788955260 and batch.cursor.id_book == 7 and batch.cursor.page == 13, "batch cursor must track the final row")

local incremental = ReadingStatisticsAdapter.makeScanCursor({
    start_time = 1000,
    id_book = 9,
    page = 4,
    initial_complete = true,
})
assert(incremental.start_time == 700, "incremental scans must rewind by five minutes")
assert(incremental.id_book == 0 and incremental.page == -1, "rewind must restart tuple ordering inside overlap window")
assert(incremental.initial_complete == true, "incremental state must remain marked complete")

local initial = ReadingStatisticsAdapter.makeScanCursor({
    start_time = 1000,
    id_book = 9,
    page = 4,
    initial_complete = false,
})
assert(initial.start_time == 1000 and initial.id_book == 9 and initial.page == 4, "unfinished historical imports must resume exactly")

print("reading_statistics_adapter_test.lua: OK")
