local BookFeedbackAdapter = {}

local STATE_KEY = "deluxe_sync_book_feedback_state"

local function normalizeRating(value)
    local rating = tonumber(value)
    if not rating or rating < 1 or rating > 5 or rating ~= math.floor(rating) then return nil end
    return rating
end

local function normalizeReviewNote(value)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

function BookFeedbackAdapter.extract(ui)
    local doc_settings = ui and ui.doc_settings
    if not doc_settings or type(doc_settings.readSetting) ~= "function" then return {} end

    local summary = doc_settings:readSetting("summary")
    if type(summary) ~= "table" then return {} end

    local state = doc_settings:readSetting(STATE_KEY)
    if type(state) ~= "table" then state = {} end

    local rating = normalizeRating(summary.rating)
    local review_note = normalizeReviewNote(summary.note)
    local changed = false
    local feedback = {}

    if rating ~= nil then
        feedback.rating_present = true
        feedback.rating = rating
        if state.rating_known ~= true then
            state.rating_known = true
            changed = true
        end
    elseif state.rating_known == true then
        -- KOReader represents an explicitly cleared rating as nil. Remembering
        -- that a rating was previously observed lets the server distinguish a
        -- real clear from a book that has simply never been rated here.
        feedback.rating_present = true
    end

    if review_note ~= nil then
        feedback.review_note_present = true
        feedback.review_note = review_note
        if state.review_known ~= true then
            state.review_known = true
            changed = true
        end
    elseif state.review_known == true then
        -- Same clear semantics as rating: an absent note after a known note is
        -- an explicit local clear, while an untouched book remains omitted.
        feedback.review_note_present = true
    end

    if changed and type(doc_settings.saveSetting) == "function" then
        doc_settings:saveSetting(STATE_KEY, state)
        if type(doc_settings.flush) == "function" then doc_settings:flush() end
    end

    return feedback
end

return BookFeedbackAdapter
