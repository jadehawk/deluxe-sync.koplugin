package.path = "./?.lua;" .. package.path

local SettingsBackupLifecycle = require("SettingsBackupLifecycle")

local function runLifecycle(state, responses)
    local calls = { get = {}, upload = 0, invalidated = {}, finishes = {} }
    SettingsBackupLifecycle.run({
        unchanged = true,
        stored_state = state,
        checksum = "checksum-a",
        schema_version = 2,
        get = function(snapshot_id, done)
            calls.get[#calls.get + 1] = snapshot_id
            local response = assert(table.remove(responses.get, 1), "missing GET response")
            done(response.ok, response.status, response.data, response.message)
        end,
        invalidate = function(snapshot_id)
            calls.invalidated[#calls.invalidated + 1] = snapshot_id
            state.snapshot_id = nil
            state.uploaded_at = 0
        end,
        upload = function(done)
            calls.upload = calls.upload + 1
            local response = assert(table.remove(responses.upload, 1), "missing upload response")
            done(response.ok, response.status, response.data, response.message)
        end,
        finish = function(ok, status, message, snapshot, uploaded)
            calls.finishes[#calls.finishes + 1] = {
                ok = ok,
                status = status,
                message = message,
                snapshot = snapshot,
                uploaded = uploaded,
            }
            if uploaded and snapshot then state.snapshot_id = snapshot.snapshot_id end
        end,
    })
    return calls
end

local state = {
    checksum = "checksum-a",
    koreader_version = "v2026.09",
    snapshot_id = "snapshot-a",
    uploaded_at = 100,
}

local recreated = runLifecycle(state, {
    get = {
        { ok = true, status = 404, data = { error = "not_found" } },
    },
    upload = {
        {
            ok = true,
            status = 200,
            data = {
                created = true,
                snapshot = {
                    snapshot_id = "snapshot-b",
                    checksum = "checksum-a",
                    schema_version = 2,
                },
            },
        },
    },
})
assert(#recreated.get == 1 and recreated.get[1] == "snapshot-a", "deleted snapshot must be revalidated by remembered id")
assert(#recreated.invalidated == 1 and recreated.invalidated[1] == "snapshot-a", "404 must invalidate the deleted server snapshot id")
assert(recreated.upload == 1, "404 must immediately trigger one replacement upload")
assert(state.snapshot_id == "snapshot-b", "replacement upload must persist the new snapshot id")
assert(#recreated.finishes == 1 and recreated.finishes[1].ok == true and recreated.finishes[1].uploaded == true, "replacement upload must complete successfully")

local converged = runLifecycle(state, {
    get = {
        {
            ok = true,
            status = 200,
            data = {
                snapshot = {
                    snapshot_id = "snapshot-b",
                    checksum = "checksum-a",
                    schema_version = 2,
                },
            },
        },
    },
    upload = {},
})
assert(#converged.get == 1 and converged.get[1] == "snapshot-b", "later convergence must check the replacement snapshot id")
assert(converged.upload == 0, "present replacement snapshot must not be uploaded again")
assert(#converged.invalidated == 0, "matching replacement snapshot must remain valid")
assert(#converged.finishes == 1 and converged.finishes[1].uploaded == false, "matching replacement snapshot must finish without upload")

local transient_state = {
    checksum = "checksum-a",
    snapshot_id = "snapshot-c",
    uploaded_at = 200,
}
local failed_check = runLifecycle(transient_state, {
    get = {
        { ok = false, status = nil, data = nil, message = "network failure" },
    },
    upload = {},
})
assert(failed_check.upload == 0, "transient presence-check failures must not blindly upload")
assert(#failed_check.invalidated == 0 and transient_state.snapshot_id == "snapshot-c", "transient failures must preserve the remembered snapshot id")
assert(#failed_check.finishes == 1 and failed_check.finishes[1].ok == false, "transient presence-check failure must finish and release the caller guard")

local retry_after_failure = runLifecycle(transient_state, {
    get = {
        { ok = true, status = 404, data = { error = "not_found" } },
    },
    upload = {
        {
            ok = true,
            status = 200,
            data = {
                created = true,
                snapshot = {
                    snapshot_id = "snapshot-d",
                    checksum = "checksum-a",
                    schema_version = 2,
                },
            },
        },
    },
})
assert(retry_after_failure.upload == 1 and transient_state.snapshot_id == "snapshot-d", "a later lifecycle must recover after a failed presence check")

local upload_failure_state = {
    checksum = "checksum-a",
    snapshot_id = "snapshot-e",
    uploaded_at = 300,
}
local failed_upload = runLifecycle(upload_failure_state, {
    get = {
        { ok = true, status = 404, data = { error = "not_found" } },
    },
    upload = {
        { ok = false, status = nil, data = nil, message = "upload network failure" },
    },
})
assert(failed_upload.upload == 1, "deleted snapshot must still attempt its replacement upload")
assert(upload_failure_state.snapshot_id == nil, "authoritative 404 must remain invalidated when replacement upload fails")
assert(#failed_upload.finishes == 1 and failed_upload.finishes[1].ok == false, "failed replacement upload must release the caller guard")

local retry_after_upload_failure = runLifecycle(upload_failure_state, {
    get = {},
    upload = {
        {
            ok = true,
            status = 200,
            data = {
                created = true,
                snapshot = {
                    snapshot_id = "snapshot-f",
                    checksum = "checksum-a",
                    schema_version = 2,
                },
            },
        },
    },
})
assert(#retry_after_upload_failure.get == 0, "invalidated snapshot state must not recheck a deleted snapshot id")
assert(retry_after_upload_failure.upload == 1 and upload_failure_state.snapshot_id == "snapshot-f", "a later lifecycle must retry and recover after a failed replacement upload")

print("settings_backup_lifecycle_test.lua: OK")
