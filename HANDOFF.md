# Deluxe-Sync Development Handoff

## Project

Deluxe-Sync is a KOReader plugin that extends KOSync progress synchronization to multiple independent KOReader-compatible servers.

Workspace: `C:\Users\Admin\Documents\Github Working Repos\deluxe-sync.koplugin`

The repository is currently an initial working tree with no commits yet on `master`; source files and the packaged `dist/deluxe-sync.koplugin/` tree are presently untracked. Do not assume a clean Git baseline.

## Current implemented capabilities

- Multiple server profiles with independent URL, username, derived KOSync user key, enabled state, and detected capabilities.
- Standard KOReader KOSync registration, authentication, progress push, and progress pull compatibility.
- Push current reading position to all enabled servers asynchronously.
- Per-server retry queue with newer progress replacing stale queued progress for the same server/book.
- Read-only Sync Card that pulls the current book from all enabled servers, groups identical exact positions, and sorts differing positions newest-first.
- Optional enhanced-server `GET /syncs/documents` capability detection.
- Enhanced remote-library browsing and cached known-document browsing for standard servers.
- Local-library matching with binary checksum preferred over filename and title/author matching.
- Metadata-aware library rows showing title, authors, filename, percentage, last-sync timestamp, and local-match confidence.
- Alias-aware pulls and merge aliases for remote document IDs that represent the same local book.
- Safe remote-position preview that preserves/restores the exact local position and suppresses Deluxe-Sync syncing while preview mode is active.
- Merge workflow pushes the actual accepted local reader position under the canonical local document ID rather than reusing a potentially incompatible remote XPointer.
- Plugin-owned localization catalogs under `i18n/`, with English fallback.
- Plugin runtime state under KOReader `settings/deluxe-sync/`, including settings, retry queue, and diagnostics.

## Compatibility targets

Development has used these two server types:

- Enhanced metadata/document-listing server: `https://sync.send2ereader.net`
- Standard KOSync server: `https://boxofbooks.org/api/v1/koreader`

Not every KOSync-compatible server supports enhanced metadata/document APIs, so capability-dependent behavior must remain optional and backward compatible.

## Important source layout

- `main.lua` — plugin UI and orchestration, including server management and preview/merge flows.
- `ServerStore.lua` — persisted server profiles/capabilities.
- `SyncClient.lua` — KOSync network operations.
- `SyncQueue.lua` — retry queue.
- `LocalLibrary.lua` — local library discovery/matching.
- `Resolver.lua` — matching/resolution logic.
- `DiagnosticLog.lua` — plugin diagnostics.
- `I18N.lua` and `i18n/en.json` — plugin localization.
- `spec/` — Lua tests.
- `dist/deluxe-sync.koplugin/` — packaged plugin copy; source changes that ship to users must remain synchronized with this tree.

## Current UI and sync state

The server-management UI is implemented in `ProgressSyncDeluxe:showServers()` in `main.lua`. Configured rows support tap-and-hold for details/options and the screen now tells the user about that interaction. `+  Add server…` is visually emphasized. Navigation is explicit: server details can return to the server list, tracked books and edit-server can return to server details, and cancelling a new-server dialog returns to the server list.

Each server has an `Enable Metadata` checkbox. Metadata is enabled by default; disabling it prevents metadata from being sent regardless of automatic compatibility detection. Re-enabling it allows the server to be probed again.

The main Deluxe-Sync menu no longer contains the redundant disabled `Preview Menu` item; preview mode keeps its separate on-reader shortcut.

All Deluxe-Sync dialogs suppress KOReader's parent `MovableContainer` hold/hold-pan/hold-release gestures. Intentional long-press actions remain implemented only on the specific child controls that expose a real hold action (for example server rows and Sync Card remote-position rows). New dialogs without a documented tap-and-hold action must receive the same container-hold suppression so blank-area holds cannot enter KOReader's movable-dialog state machine.

Auto-Sync Documents is enabled by default. `Sync Behavior` has independent settings for newer and older remote states with `Silently / Prompt / Never`; defaults are `Prompt` for newer and `Never` for older. Manual Pull always uses the multi-server Sync Card. Automatic pulls use the newest grouped remote state, compare timestamps when local activity timing is available and percentage as fallback, then obey Sync Behavior.

Auto-Sync pulls on document ready/resume, pushes on suspend/close, queues pushes directly while offline, and on `NetworkConnected` drains queued updates before performing the automatic pull. The retry queue is for outbound progress updates that could not be delivered; transient failures are retained, while authentication and known document-not-tracked failures are handled separately.

Opening Tools → Deluxe-Sync with zero registered servers shows onboarding before the normal submenu. Choices are complimentary `Techy-Notes.com`, custom server, or cancel. The complimentary path opens the normal Add Server dialog prefilled with `Techy-Notes.com` and `https://sync.techy-notes.com`; username/password remain blank so the user can create an account through the existing registration flow. Onboarding is based on zero registered servers, not enabled-server count or the Auto-Sync toggle.

Registration compatibility: accept and inspect `201`, legacy `402`, `403`, and `409` responses. `402` remains the legacy KOSync existing-account signal; `409` is classified from the response body (Techy-Notes uses `Username already taken`); `403` is not treated as an existing account and must surface the server's restriction (BookOrbit uses `Registration disabled. Create credentials in BookOrbit settings.`). Authentication `401` means the supplied username/password were not accepted. Registration/sign-in failures use the themed Deluxe-Sync failure dialog with server, username, HTTP status, server message, and a `Back to Server Setup` action. If Spore throws an unexpected-status wrapper, `SyncClient` must recover the embedded response status/body instead of degrading to `HTTP ?`.

Server-library browsing is inspection-only. Browse Tracked Books uses compact KOReader cards grouped into With Metadata and Metadata Unavailable. Selecting a server book must never invoke preview/apply logic or move the open document; it opens a two-column Book Review showing book information on the left and only that server record on the right, with an explicit Back to server book list path. The normal multi-server Pull Results/preview/sync workflow remains separate and unchanged.

Keep source and packaged `dist` copies synchronized for every shipping change.

## Emulator deployment rule

- After every approved plugin change, keep `dist/deluxe-sync.koplugin/` synchronized and deploy that packaged copy to `/home/jadehawk/koreader-adept-test/plugins/deluxe-sync.koplugin/` before reporting the work complete.
- Verify the changed implementation or user-facing strings are present in the emulator plugin copy after deployment.
- For UI changes, do not stop at file-copy verification: launch the KOReader emulator, navigate the affected flow with X11 input automation when practical, and visually/textually verify the final rendered screen and back-navigation before reporting the UI change complete.

## Verification requirement

After any change under this KOReader plugin, run the complete Lua test suite using Lua 5.1 and a Linux-only PATH before considering the work complete:

```text
wsl bash -lc "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /mnt/c/Users/Admin/OneDrive/GitHubRepos/bookorbit/.thinkforge-worktrees/<worktree-name> && find koreader-plugin/spec -maxdepth 1 -name '*_test.lua' -print0 | sort -z | xargs -0 -n1 /usr/bin/lua5.1"
```

For this standalone Deluxe-Sync repository, preserve the same verification requirements—Linux-only PATH, `/usr/bin/lua5.1`, and every `*_test.lua` under `spec/`—while using the actual Deluxe-Sync workspace path rather than the BookOrbit example path above.

## Resume point

The current implementation includes the server-management polish, metadata control, explicit back-navigation, default-on Auto-Sync Documents, Sync Behavior, automatic queue draining, zero-server onboarding, grouped compact tracked-book browsing, and inspection-only single-server Book Review described above. Continue from emulator/manual UI validation of these flows and any follow-up fixes discovered there.
