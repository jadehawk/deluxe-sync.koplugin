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

local ui = {
    document = {
        getProps = function()
            return {
                identifiers = "isbn:9780553813227; mobi-asin:b0dtt5lv77",
            }
        end,
    },
    doc_props = {
        display_title = "Example Book",
        authors = "Example Author",
    },
}
assert(DocumentMetadataAdapter.extractAsin(ui) == "B0DTT5LV77", "KOReader document:getProps identifiers must feed ASIN extraction")

ui.document.getProps = function()
    error("unsupported")
end
ui.doc_props.identifiers = "asin:B012345678"
assert(DocumentMetadataAdapter.extractAsin(ui) == "B012345678", "saved doc_props identifiers must provide a safe fallback when getProps is unavailable")

ui.doc_props.identifiers = "isbn:0306406152"
ui.doc_props.asin = " b0abc12345 "
assert(DocumentMetadataAdapter.extractAsin(ui) == "B0ABC12345", "explicit ASIN fields may provide a bare value")

print("document_metadata_adapter_test.lua: OK")
