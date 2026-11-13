local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local ReadingStatisticsAdapter = {}
ReadingStatisticsAdapter.MAX_PAGES = 20000
ReadingStatisticsAdapter.MAX_BODY_BYTES = 4 * 1024 * 1024

function ReadingStatisticsAdapter.databasePath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

function ReadingStatisticsAdapter.validTimezone(value)
    if type(value) ~= "string" or #value == 0 or #value > 100 then return false end
    if value == "UTC" then return true end
    return value:match("^[%a_]+/[%w_%+%-/]+$") ~= nil
        and not value:find("..", 1, true)
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function queryRows(conn, sql, bindings, convert)
    local statement = assert(conn:prepare(sql))
    local ok, result = pcall(function()
        if bindings then statement:bind(unpack(bindings)) end
        local rows = {}
        for row in statement:rows() do
            rows[#rows + 1] = convert(row)
        end
        return rows
    end)
    pcall(statement.close, statement)
    if not ok then error(result, 0) end
    return result
end

local function fromDatabase(action)
    local path = ReadingStatisticsAdapter.databasePath()
    if lfs.attributes(path, "mode") ~= "file" then
        return { missing = true }
    end
    local conn
    local ok, result = pcall(function()
        conn = assert(SQ3.open(path, "ro"))
        if conn.set_busy_timeout then conn:set_busy_timeout(1000) end
        local schema = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
        if schema < 20201010 then error("Unsupported KOReader statistics database schema " .. tostring(schema)) end
        for _, name in ipairs({ "book", "page_stat_data" }) do
            if not conn:rowexec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='" .. name .. "';") then
                error("KOReader statistics database is missing the " .. name .. " table")
            end
        end
        return action(conn)
    end)
    if conn then pcall(conn.close, conn) end
    if not ok then return nil, tostring(result) end
    return result
end

function ReadingStatisticsAdapter.listBooks()
    return fromDatabase(function(conn)
        local rows = queryRows(conn, [[
            SELECT lower(b.md5), MAX(COALESCE(b.title, '')), MAX(COALESCE(b.authors, ''))
            FROM book AS b
            WHERE EXISTS (SELECT 1 FROM page_stat_data AS p WHERE p.id_book = b.id
                          AND p.total_pages > 0 AND p.duration > 0)
            GROUP BY lower(b.md5) ORDER BY lower(b.md5)
        ]], nil, function(row)
            local md5 = row[1]
            if type(md5) ~= "string" or not md5:match("^[0-9a-f]+$") or #md5 ~= 32 then
                error("Invalid book MD5 in KOReader reading statistics")
            end
            local title = tostring(row[2] or "")
            local authors = tostring(row[3] or "")
            if #title > 4096 or #authors > 4096 then
                error("KOReader reading statistics book metadata exceeds the server limit")
            end
            return { md5 = md5, title = title, authors = authors }
        end)
        return { books = rows, missing = false }
    end)
end

function ReadingStatisticsAdapter.readBook(book, timezone)
    if type(book) ~= "table" or type(book.md5) ~= "string"
        or #book.md5 ~= 32 or not book.md5:match("^[0-9a-f]+$") then
        return nil, "Invalid KOReader book MD5"
    end
    if not ReadingStatisticsAdapter.validTimezone(timezone) then
        return nil, "Set a valid IANA reading time zone (for example America/New_York) in server settings"
    end
    return fromDatabase(function(conn)
        local now = os.time() + 300
        local rows = queryRows(conn, [[
            SELECT p.page, p.total_pages, p.start_time, MAX(p.duration)
            FROM page_stat_data AS p
            JOIN book AS b ON b.id = p.id_book
            WHERE lower(b.md5) = ? AND p.total_pages > 0 AND p.duration > 0
            GROUP BY p.page, p.total_pages, p.start_time
            ORDER BY p.start_time, p.page, p.total_pages
            LIMIT 20001
        ]], { book.md5 }, function(row)
            local page = tonumber(row[1])
            local total_pages = tonumber(row[2])
            local start_time = tonumber(row[3])
            local duration = tonumber(row[4])
            if not (isInteger(page) and isInteger(total_pages) and isInteger(start_time) and isInteger(duration))
                or page < 0 or total_pages < 1 or total_pages > 1000000 or page > total_pages
                or start_time < 946684800 or start_time > now or duration < 1 or duration > 86400 then
                error("Invalid KOReader reading history record for " .. book.md5)
            end
            return { page = page, total_pages = total_pages, start_time = start_time, duration = duration }
        end)
        if #rows > ReadingStatisticsAdapter.MAX_PAGES then
            error("Book exceeds 20,000 page records; use the server history-file importer")
        end
        return { version = 1, book = book, timezone = timezone, pages = rows }
    end)
end

return ReadingStatisticsAdapter
