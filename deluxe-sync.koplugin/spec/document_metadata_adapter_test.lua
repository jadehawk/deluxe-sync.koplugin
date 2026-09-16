package.path = "./?.lua;" .. package.path

local DocumentMetadataAdapter = require("DocumentMetadataAdapter")

assert(DocumentMetadataAdapter.normalizeAsin(" b0dtt5lv77 ") == "B0DTT5LV77", "ASIN normalization must trim and uppercase")
assert(DocumentMetadataAdapter.normalizeAsin("B0DTT5LV7") == nil, "short identifiers must not be accepted as ASINs")
assert(DocumentMetadataAdapter.normalizeAsin("B0DTT5LV7!") == nil, "non-alphanumeric identifiers must not be accepted as ASINs")

assert(DocumentMetadataAdapter.extractAsinFromIdentifiers("isbn:9780553813227; asin:b0dtt5lv77") == "B0DTT5LV77", "labeled ASIN must be extracted from KOReader identifier text")
assert(DocumentMetadataAdapter.extractAsinFromIdentifiers("isbn:9780553813227, mobi-asin=B0DTT5LV77") == "B0DTT5LV77", "mobi-asin labels must be recognized")
assert(DocumentMetadataAdapter.extractAsinFromIdentifiers("amazon_asin B0DTT5LV77") == "B0DTT5LV77", "explicit Amazon ASIN labels separated by whitespace must be recognized")
assert(DocumentMetadataAdapter.extractAsinFromIdentifiers({ isbn = "9780553813227", asin = "b0dtt5lv77" }) == "B0DTT5LV77", "ASIN table entries must be recognized")
assert(DocumentMetadataAdapter.extractAsinFromIdentifiers({ "isbn:0306406152", "asin:B0DTT5LV77" }) == "B0DTT5LV77", "labeled ASIN array entries must be recognized")

assert(DocumentMetadataAdapter.extractAsinFromIdentifiers("B0DTT5LV77") == nil, "unlabeled 10-character identifiers must not be guessed as ASINs")
assert(DocumentMetadataAdapter.extractAsinFromIdentifiers("isbn:0306406152") == nil, "ISBN-10 values must never be guessed as ASINs")
assert(DocumentMetadataAdapter.extractAsinFromIdentifiers({ "0306406152" }) == nil, "unlabeled table values must never be guessed as ASINs")

assert(DocumentMetadataAdapter.normalizeSeriesIndex(" 3 ") == 3, "numeric string series indexes must normalize")
assert(DocumentMetadataAdapter.normalizeSeriesIndex("1.5") == 1.5, "decimal series indexes must be preserved")
assert(DocumentMetadataAdapter.normalizeSeriesIndex(0) == 0, "series index zero must remain valid")
assert(DocumentMetadataAdapter.normalizeSeriesIndex("not-a-number") == nil, "invalid series indexes must be ignored")

local ui = {
    document = {
        getProps = function()
            return {
                identifiers = "isbn:9780553813227; mobi-asin:b0dtt5lv77",
                series = "Raw Series",
                series_index = "2.5",
            }
        end,
    },
    doc_props = {
        display_title = "Example Book",
        authors = "Example Author",
        series = " Saved Series ",
        series_index = "3",
    },
}
assert(DocumentMetadataAdapter.extractAsin(ui) == "B0DTT5LV77", "KOReader document:getProps identifiers must feed ASIN extraction")
assert(DocumentMetadataAdapter.extractSeries(ui) == "Saved Series", "saved KOReader series metadata should take precedence and be trimmed")
assert(DocumentMetadataAdapter.extractSeriesIndex(ui) == 3, "saved KOReader series index should take precedence")

ui.doc_props.series = nil
ui.doc_props.series_index = nil
assert(DocumentMetadataAdapter.extractSeries(ui) == "Raw Series", "document:getProps series must be used as fallback")
assert(DocumentMetadataAdapter.extractSeriesIndex(ui) == 2.5, "document:getProps series index must be used as fallback")

ui.document.getProps = function()
    error("unsupported")
end
ui.doc_props.identifiers = "asin:B012345678"
assert(DocumentMetadataAdapter.extractAsin(ui) == "B012345678", "saved doc_props identifiers must provide a safe fallback when getProps is unavailable")

ui.doc_props.identifiers = "isbn:0306406152"
ui.doc_props.asin = " b0abc12345 "
assert(DocumentMetadataAdapter.extractAsin(ui) == "B0ABC12345", "explicit ASIN fields may provide a bare value")

print("document_metadata_adapter_test.lua: OK")
