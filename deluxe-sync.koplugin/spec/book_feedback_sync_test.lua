local function readFile(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function contains(source, text, message)
    assert(source:find(text, 1, true), message or ("missing book-feedback contract: " .. text))
end

local function count(source, text)
    local found = 0
    local offset = 1
    while true do
        local start_at = source:find(text, offset, true)
        if not start_at then return found end
        found = found + 1
        offset = start_at + #text
    end
end

local main = readFile("main.lua")
local api = readFile("api.json")
local lifecycle = readFile("ProgressLifecycleController.lua")
local enhanced = readFile("EnhancedDataSyncController.lua")
local store = readFile("ServerStore.lua")
local profile = readFile("DeluxeProfileAdapter.lua")

contains(main, 'BookFeedbackAdapter = require("BookFeedbackAdapter")', "plugin must load the KOReader summary feedback adapter")
contains(main, "function ProgressSyncDeluxe:serverSupportsBookFeedback(server)", "feedback capability/consent gate is missing")
contains(main, "server.book_feedback_enabled == true", "ratings/reviews must require explicit per-server consent")
contains(main, "capabilities.book_feedback == true", "ratings/reviews must require server capability")
contains(main, "(tonumber(capabilities.book_feedback_version) or 0) >= 1", "ratings/reviews must require protocol v1")
assert(count(main, "local book_feedback = self:getBookFeedback()") >= 2, "online and offline push paths must read KOReader feedback")
assert(count(main, "self:applyBookFeedbackToPayload(server, payload, book_feedback)") >= 2, "online and offline payloads must use the same feedback gate")
contains(main, "fallback_payload.rating_present = current_payload.rating_present", "metadata fallback must preserve rating clear/value presence")
contains(main, "fallback_payload.review_note_present = current_payload.review_note_present", "metadata fallback must preserve review clear/value presence")

contains(api, '"optional_params": ["metadata", "position", "rating", "rating_present", "review_note", "review_note_present"]', "Spore API must accept feedback fields")
contains(api, '"payload": ["document", "metadata", "position", "rating", "rating_present", "review_note", "review_note_present", "progress", "percentage", "device", "device_id"]', "Spore API must serialize feedback fields")

contains(lifecycle, "local strip_book_feedback = has_book_feedback and not owner:serverSupportsBookFeedback(server)", "queued retries must re-check current feedback consent/capability")
contains(lifecycle, "if strip_metadata or strip_position or strip_book_feedback then", "queued retry sanitization must include feedback")
contains(lifecycle, "sanitized.review_note_present = payload.review_note_present", "queued retries must preserve allowed review presence semantics")

contains(enhanced, "enhanced_capabilities.book_feedback == true", "server capability probe must discover book-feedback support")
contains(enhanced, 'owner.store:setCapability(server.id, "book_feedback", book_feedback_supported)', "book-feedback capability must be cached")
contains(enhanced, 'owner.store:setCapability(server.id, "book_feedback_version", book_feedback_version)', "book-feedback protocol version must be cached")

contains(store, "ServerStore.DATA_SHARING_VERSION = 3", "new ratings/reviews category must advance the consent schema")
contains(store, "server.book_feedback_enabled = server.book_feedback_enabled == true", "ratings/reviews consent must fail closed")
contains(profile, "server.book_feedback_enabled = existing and existing.book_feedback_enabled == true or false", "profile restore must keep ratings/reviews consent local")

print("book_feedback_sync_test.lua: OK")
