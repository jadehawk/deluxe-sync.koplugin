package.path = "./?.lua;" .. package.path

local AnnotationAdapter = require("AnnotationAdapter")

local annotations = {
    {
        datetime = "2026-09-09 03:00:00",
        text = "Highlighted text",
        chapter = "Chapter One",
        drawer = "lighten",
        color = "yellow",
        page = "/body/DocFragment[1]",
        pos0 = "/body/DocFragment[1]/p[1].0",
        pos1 = "/body/DocFragment[1]/p[1].10",
    },
    {
        datetime = "2026-09-09 03:01:00",
        text = "Text with note",
        note = "My note",
        drawer = "underscore",
    },
    {
        datetime = "2026-09-09 03:02:00",
        chapter = "Bookmark chapter",
        page = 8,
    },
}

local next_id = 0
local function ids(_device, _annotation, _index, _nonce)
    next_id = next_id + 1
    return "test-id-" .. tostring(next_id)
end

assert(AnnotationAdapter.ensureIds(annotations, "device-a", ids) == true, "first pass must assign stable ids")
assert(AnnotationAdapter.ensureIds(annotations, "device-a", ids) == false, "second pass must preserve assigned ids")
assert(annotations[1].deluxe_sync_id == "test-id-1", "highlight id mismatch")
assert(annotations[2].deluxe_sync_id == "test-id-2", "note id mismatch")
assert(annotations[3].deluxe_sync_id == "test-id-3", "bookmark id mismatch")
assert(AnnotationAdapter.kind(annotations[1]) == "highlight", "drawer without note must be highlight")
assert(AnnotationAdapter.kind(annotations[2]) == "note", "drawer plus note must be note")
assert(AnnotationAdapter.kind(annotations[3]) == "bookmark", "annotation without drawer must be bookmark")
assert(AnnotationAdapter.kind({ note = "Standalone note" }) == "note", "note-only annotations must remain notes")

local first_fingerprint = AnnotationAdapter.fingerprint(annotations[1])
local same_position_different_key_order = {
    datetime = annotations[1].datetime,
    text = annotations[1].text,
    chapter = annotations[1].chapter,
    drawer = annotations[1].drawer,
    color = annotations[1].color,
    page = annotations[1].page,
    pos0 = annotations[1].pos0,
    pos1 = annotations[1].pos1,
    deluxe_sync_id = annotations[1].deluxe_sync_id,
}
assert(first_fingerprint == AnnotationAdapter.fingerprint(same_position_different_key_order), "fingerprint must ignore Lua table key order")
annotations[1].text = "Edited highlight"
assert(first_fingerprint ~= AnnotationAdapter.fingerprint(annotations[1]), "content edit must change fingerprint")

local state = { cursor = 0, items = {} }
local outbound = AnnotationAdapter.collectLocalChanges(annotations, state, "device-a", ids)
assert(#outbound == 3, "initial sync must send all local annotations")
assert(outbound[1].base_revision == 0, "new annotations start from server revision zero")
assert(outbound[1].kind == "highlight", "wire kind mismatch")
assert(outbound[2].kind == "note", "wire note kind mismatch")
assert(outbound[3].kind == "bookmark", "wire bookmark kind mismatch")

local server_highlight = {
    id = annotations[1].deluxe_sync_id,
    document = "book-a",
    kind = "highlight",
    revision = 1,
    deleted = false,
    created_datetime = annotations[1].datetime,
    updated_datetime = "2026-09-09 03:05:00",
    text = "Edited on remote",
    chapter = "Chapter One",
    drawer = "lighten",
    color = "blue",
    page = "/body/DocFragment[1]",
    pos0 = "/body/DocFragment[1]/p[1].0",
    pos1 = "/body/DocFragment[1]/p[1].10",
}
assert(AnnotationAdapter.applyRemote(annotations, server_highlight), "remote edit must apply")
AnnotationAdapter.remember(state, server_highlight, annotations)
assert(annotations[1].text == "Edited on remote", "remote text must replace local text")
assert(annotations[1].color == "blue", "remote style must replace local style")
assert(state.items[server_highlight.id].revision == 1, "server revision must be remembered")

local server_note = {
    id = annotations[2].deluxe_sync_id,
    kind = "note",
    revision = 1,
    deleted = false,
    created_datetime = annotations[2].datetime,
    text = annotations[2].text,
    note = annotations[2].note,
    drawer = annotations[2].drawer,
}
local server_bookmark = {
    id = annotations[3].deluxe_sync_id,
    kind = "bookmark",
    revision = 1,
    deleted = false,
    created_datetime = annotations[3].datetime,
    chapter = annotations[3].chapter,
    page = annotations[3].page,
}
AnnotationAdapter.remember(state, server_note, annotations)
AnnotationAdapter.remember(state, server_bookmark, annotations)
local no_changes = AnnotationAdapter.collectLocalChanges(annotations, state, "device-a", ids)
assert(#no_changes == 0, "matching fingerprints and revisions must produce no write")

annotations[2].note = "Locally edited note"
local edited = AnnotationAdapter.collectLocalChanges(annotations, state, "device-a", ids)
assert(#edited == 1, "one local edit must create one wire update")
assert(edited[1].id == annotations[2].deluxe_sync_id, "edited annotation id must stay stable")
assert(edited[1].base_revision == 1, "local edit must target last observed server revision")

local deleted_id = annotations[3].deluxe_sync_id
table.remove(annotations, 3)
local with_delete = AnnotationAdapter.collectLocalChanges(annotations, state, "device-a", ids)
local tombstone
for _, item in ipairs(with_delete) do
    if item.id == deleted_id then tombstone = item end
end
assert(tombstone and tombstone.deleted == true, "missing known annotation must create a tombstone")
assert(tombstone.base_revision == 1, "tombstone must target last observed revision")

local remote_delete = { id = annotations[1].deluxe_sync_id, revision = 2, deleted = true, kind = "highlight" }
assert(AnnotationAdapter.applyRemote(annotations, remote_delete), "remote tombstone must remove local annotation")
AnnotationAdapter.remember(state, remote_delete, annotations)
for _, annotation in ipairs(annotations) do
    assert(annotation.deluxe_sync_id ~= remote_delete.id, "remote deleted annotation must stay absent")
end
local after_delete = AnnotationAdapter.collectLocalChanges(annotations, state, "device-a", ids)
for _, item in ipairs(after_delete) do
    assert(item.id ~= remote_delete.id, "applied tombstone must not be resurrected on next local scan")
end

print("annotation_adapter_test.lua: OK")
