package.path = "./?.lua;" .. package.path

local captured = { sql = {} }

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/mock/settings" end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            assert(path == "/mock/settings/vocabulary_builder.sqlite3", "Vocabulary Builder DB path mismatch")
            assert(key == "mode", "lfs mode lookup expected")
            return "file"
        end,
    }
end

package.preload["ffi/sha2"] = function()
    return {
        sha256 = function(value) return "sha256:" .. tostring(value) end,
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
                if sql:find("name='vocabulary'", 1, true) then return 1 end
                if sql:find("name='title'", 1, true) then return 1 end
                error("unexpected rowexec: " .. tostring(sql))
            end
            function conn:prepare(sql)
                captured.sql[#captured.sql + 1] = sql
                local includes_context = sql:find("v.prev_context", 1, true) ~= nil
                local statement = {}
                function statement:rows()
                    local rows
                    if includes_context then
                        rows = {
                            { " quaint ", " The Widow ", 1, 1789107292, 1789107292, 1789107592, 2, 1, " before passage ", " after passage ", " highlighted words " },
                        }
                    else
                        rows = {
                            { " quaint ", " The Widow ", 1, 1789107292, 1789107292, 1789107592, 2, 1 },
                        }
                    end
                    local index = 0
                    return function()
                        index = index + 1
                        return rows[index]
                    end
                end
                function statement:close() captured.statement_closed = (captured.statement_closed or 0) + 1 end
                return statement
            end
            function conn:close() captured.connection_closed = (captured.connection_closed or 0) + 1 end
            return conn
        end,
    }
end

local VocabularyAdapter = require("VocabularyAdapter")

assert(VocabularyAdapter.databasePath() == "/mock/settings/vocabulary_builder.sqlite3", "database path must use KOReader settings directory")

local without_context, err = VocabularyAdapter.scan(false)
assert(without_context and not err, "context-free vocabulary scan failed: " .. tostring(err))
assert(captured.path == "/mock/settings/vocabulary_builder.sqlite3", "SQLite open path mismatch")
assert(captured.mode == "ro", "Vocabulary Builder DB must be opened read-only")
assert(captured.timeout == 1000, "Vocabulary Builder query should use a bounded busy timeout")
assert(#without_context.records == 1, "expected one normalized vocabulary record")
assert(without_context.context_included == false, "context-free scan must report context disabled")
assert(without_context.records[1].word == "quaint", "word normalization mismatch")
assert(without_context.records[1].title == "The Widow", "title normalization mismatch")
assert(without_context.records[1].title_filter == "1", "title filter normalization mismatch")
assert(without_context.records[1].review_count == 2 and without_context.records[1].streak_count == 1, "review counters mismatch")
assert(without_context.records[1].prev_context == nil and without_context.records[1].next_context == nil and without_context.records[1].highlight == nil, "context-free scan must not populate passage fields")
assert(not captured.sql[1]:find("prev_context", 1, true), "context-free SQL must not read prev_context")
assert(not captured.sql[1]:find("next_context", 1, true), "context-free SQL must not read next_context")
assert(not captured.sql[1]:find("highlight", 1, true), "context-free SQL must not read highlight")
assert(without_context.hashes[without_context.records[1].id] == without_context.records[1].record_hash, "record hash map mismatch")

local with_context = assert(VocabularyAdapter.scan(true))
assert(with_context.context_included == true, "context scan must report context enabled")
assert(captured.sql[2]:find("v.prev_context", 1, true), "context SQL must explicitly read prev_context")
assert(captured.sql[2]:find("v.next_context", 1, true), "context SQL must explicitly read next_context")
assert(captured.sql[2]:find("v.highlight", 1, true), "context SQL must explicitly read highlight")
assert(with_context.records[1].prev_context == "before passage", "previous reading context normalization mismatch")
assert(with_context.records[1].next_context == "after passage", "next reading context normalization mismatch")
assert(with_context.records[1].highlight == "highlighted words", "highlight context normalization mismatch")
assert(with_context.records[1].id == without_context.records[1].id, "reading-context consent must not change vocabulary identity")
assert(with_context.records[1].record_hash ~= without_context.records[1].record_hash, "reading-context consent must change the uploaded record hash")

local tombstone = assert(VocabularyAdapter.tombstone(without_context.records[1].id))
assert(tombstone.id == without_context.records[1].id and tombstone.deleted == true, "tombstone identity mismatch")
assert(type(tombstone.record_hash) == "string" and tombstone.record_hash ~= "", "tombstone must have a deterministic hash")
assert(captured.statement_closed == 2 and captured.connection_closed == 2, "SQLite resources must be closed after both scans")

print("vocabulary_adapter_test.lua: OK")
