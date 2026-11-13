package.path = "./?.lua;" .. package.path

local hash = string.rep("a", 32)
local captured = { opened = 0, closed = 0, statements_closed = 0 }
local present = true
local book_rows = { { hash, "Book One", "Author One" } }
local page_rows = {
    { 12, 300, 1762041600, 45 },
    { 13, 300, 1762045260, 30 },
}

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/mock/settings" end }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            assert(path == "/mock/settings/statistics.sqlite3" and key == "mode")
            return present and "file" or nil
        end,
    }
end

package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path, mode)
            assert(path == "/mock/settings/statistics.sqlite3" and mode == "ro")
            captured.opened = captured.opened + 1
            local conn = {}
            function conn:set_busy_timeout(timeout) assert(timeout == 1000) end
            function conn:rowexec(sql)
                if sql == "PRAGMA user_version;" then return 20221111 end
                if sql:find("name='book'", 1, true) or sql:find("name='page_stat_data'", 1, true) then
                    return 1
                end
                error("unexpected query: " .. tostring(sql))
            end
            function conn:prepare(sql)
                local rows
                if sql:find("GROUP BY lower(b.md5)", 1, true) then
                    rows = book_rows
                    assert(sql:find("MAX(COALESCE(b.title", 1, true))
                else
                    assert(sql:find("MAX(p.duration)", 1, true))
                    assert(sql:find("GROUP BY p.page, p.total_pages, p.start_time", 1, true))
                    assert(sql:find("LIMIT 20001", 1, true))
                    rows = page_rows
                end
                local stmt = {}
                function stmt:bind(value) assert(value == hash) end
                function stmt:rows()
                    local index = 0
                    return function()
                        index = index + 1
                        return rows[index]
                    end
                end
                function stmt:close() captured.statements_closed = captured.statements_closed + 1 end
                return stmt
            end
            function conn:close() captured.closed = captured.closed + 1 end
            return conn
        end,
    }
end

local adapter = require("ReadingStatisticsAdapter")
assert(adapter.databasePath() == "/mock/settings/statistics.sqlite3")
assert(adapter.validTimezone("America/New_York"))
assert(adapter.validTimezone("Etc/GMT+1") and adapter.validTimezone("UTC"))
for _, timezone in ipairs({ "", "../x", "EST", "bad zone", "America/../UTC", string.rep("x", 101) }) do
    assert(not adapter.validTimezone(timezone), timezone)
end

local list, err = adapter.listBooks()
assert(list and not err and not list.missing and #list.books == 1)
assert(list.books[1].md5 == hash and list.books[1].title == "Book One")
local payload = assert(adapter.readBook(list.books[1], "America/New_York"))
assert(payload.version == 1 and payload.book.md5 == hash and payload.timezone == "America/New_York")
assert(#payload.pages == 2 and payload.pages[1].duration == 45)
assert(payload.pages[2].start_time == 1762045260)
assert(captured.opened == 2 and captured.closed == 2 and captured.statements_closed == 2)

local invalid, reason = adapter.readBook({ md5 = "unsafe' OR 1=1" }, "UTC")
assert(not invalid and reason:find("MD5"))
assert(not adapter.readBook(list.books[1], "Invalid/../Zone"))
page_rows = { { 5, 10, 1762041600, -1 } }
invalid, reason = adapter.readBook(list.books[1], "UTC")
assert(not invalid and reason:find("Invalid KOReader reading history"))
assert(captured.opened == captured.closed, "failed read must close DB")

page_rows = {}
for i = 1, 20001 do page_rows[i] = { 1, 200, 1762041600 + i, 5 } end
invalid, reason = adapter.readBook(list.books[1], "UTC")
assert(not invalid and reason:find("20,000"), "large book must fail rather than truncate")
assert(captured.opened == captured.closed and captured.statements_closed == captured.opened)

book_rows = { { "invalid", "Invalid", "Author" } }
invalid, reason = adapter.listBooks()
assert(not invalid and reason:find("Invalid book MD5"))
assert(captured.opened == captured.closed)

present = false
local missing = assert(adapter.listBooks())
assert(missing.missing and captured.opened == captured.closed)
print("reading_statistics_adapter_test.lua: OK")
