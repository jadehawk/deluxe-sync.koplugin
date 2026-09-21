local BookFeedbackAdapter = dofile("BookFeedbackAdapter.lua")

local function newSettings(summary, state)
    local settings = {
        values = {
            summary = summary or {},
            deluxe_sync_book_feedback_state = state,
        },
        save_count = 0,
        flush_count = 0,
    }

    function settings:readSetting(key)
        return self.values[key]
    end

    function settings:saveSetting(key, value)
        self.values[key] = value
        self.save_count = self.save_count + 1
    end

    function settings:flush()
        self.flush_count = self.flush_count + 1
    end

    return settings
end

local untouched = newSettings({})
local untouched_feedback = BookFeedbackAdapter.extract({ doc_settings = untouched })
assert(next(untouched_feedback) == nil, "untouched books must not emit an implicit clear")
assert(untouched.save_count == 0, "untouched books must not create feedback state")

local settings = newSettings({ rating = 5, note = "Loved it" })
local first = BookFeedbackAdapter.extract({ doc_settings = settings })
assert(first.rating_present == true and first.rating == 5, "KOReader whole-star rating must be emitted")
assert(first.review_note_present == true and first.review_note == "Loved it", "KOReader completion note must be emitted")
assert(settings.values.deluxe_sync_book_feedback_state.rating_known == true, "rating-known state must persist")
assert(settings.values.deluxe_sync_book_feedback_state.review_known == true, "review-known state must persist")
assert(settings.save_count == 1 and settings.flush_count == 1, "first observed feedback must persist clear-tracking state")

local repeated = BookFeedbackAdapter.extract({ doc_settings = settings })
assert(repeated.rating_present == true and repeated.rating == 5, "known rating must remain syncable")
assert(repeated.review_note_present == true and repeated.review_note == "Loved it", "known review must remain syncable")
assert(settings.save_count == 1 and settings.flush_count == 1, "unchanged known state must not be rewritten")

settings.values.summary.rating = nil
settings.values.summary.note = nil
local cleared = BookFeedbackAdapter.extract({ doc_settings = settings })
assert(cleared.rating_present == true and cleared.rating == nil, "known KOReader rating removal must emit an explicit clear")
assert(cleared.review_note_present == true and cleared.review_note == nil, "known KOReader note removal must emit an explicit clear")
assert(settings.save_count == 1 and settings.flush_count == 1, "clear emission must reuse persisted known-state markers")

local invalid = newSettings({ rating = 4.5, note = "" })
local invalid_feedback = BookFeedbackAdapter.extract({ doc_settings = invalid })
assert(next(invalid_feedback) == nil, "KOReader-native ingestion must reject non-whole local ratings and empty notes")
assert(invalid.save_count == 0, "invalid/empty feedback must not create known-state markers")

print("book_feedback_adapter_test.lua: OK")
