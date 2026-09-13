# Changelog

## [0.2.0.0] - 2026-09-13

### Changed

- Promoted the accumulated Deluxe-Sync enhanced-server, privacy, backup, library, and UI work to the four-part release version line.
- Server editing now uses a centered **Authenticate / Sign in** action that validates the current draft credentials, saves them only after successful authentication, and refreshes server capabilities in the same flow.
- Simplified the server edit page by removing duplicate Synced Books and enable/disable actions, shortening the server address label to **URL**, and truncating long displayed URLs.
- Confirmed direct updater compatibility from the live 0.1.2 release to 0.2.0.0 and future four-part updates such as 0.2.0.1.

## [0.1.15] - 2026-09-10

### Fixed

- Settings snapshot convergence now treats a server 404 as authoritative, clears the deleted snapshot ID locally, and recreates the snapshot through a fresh client request so an unchanged backup deleted on the server can reliably return on the next successful sync lifecycle.
- Settings-backup in-flight state is now tokenized and protected by a watchdog so an interrupted presence-check or replacement-upload request cannot permanently suppress later backup convergence.

### Tests

- Added executable Lua 5.1 lifecycle coverage for deleted snapshot A → 404 → recreated snapshot B → subsequent no-op revalidation, plus transient presence-check failure and failed replacement-upload recovery on a later lifecycle.

## [0.1.14] - 2026-09-10

### Fixed

- Successful progress pushes now run the settings-backup lifecycle, so an unchanged KOReader settings snapshot that was deleted from the server is detected and recreated without requiring a local settings change.
- Failed transient progress pushes now retry in the background on a bounded persisted schedule: 30 seconds, 2 minutes, 5 minutes, 15 minutes, 30 minutes, then 60 minutes. After the sixth background retry, automatic attempts pause without deleting the queued progress.
- Queue retry no longer depends on Auto-Sync being enabled when the network reconnects. Authentication failures remain blocked from automatic retry; manual retry, a newer push, or a later reconnect can resume eligible queued progress.

### Tests

- Added Lua 5.1 regression coverage for push-triggered settings snapshot revalidation, persisted retry state, bounded backoff/exhaustion, reconnect behavior, and manual retry reset.

## [0.1.13] - 2026-09-10

### Fixed

- Unchanged settings backups now revalidate the remembered snapshot against the server before skipping upload. If that server snapshot was deleted, Deluxe-Sync immediately recreates the same core-settings baseline through the idempotent backup endpoint instead of trusting stale local state.

### Tests

- Extended Lua 5.1 settings-backup integration coverage for server-authoritative snapshot presence checks and missing-snapshot upload fallback.

## [0.1.12] - 2026-09-10

### Fixed

- Prevented arbitrary third-party plugin activity from creating duplicate KOReader settings snapshots when core KOReader preferences have not changed.
- Settings snapshot schema 2 is core-only and fail-closed: unknown plugin namespaces, scalar values, caches, timestamps, and preferences are excluded automatically, while recognized KOReader core settings remain restorable. Deluxe-Sync setup and preferences continue through the separate protected Deluxe profile.

### Tests

- Added Lua 5.1 coverage proving a fictional unknown plugin can change arbitrary runtime/preferences without changing the core settings checksum, while a real KOReader core preference change still produces a new snapshot.

## [0.1.11] - 2026-09-10

### Added

- Added protected cross-device Deluxe-Sync profile migration for enhanced Techy-Notes servers, including every configured server URL, username, supported plugin preference, and the saved authentication needed to reconnect to the same existing remote account.
- Added reader-side discovery of complete setup backups from another registered reader, followed by explicit Prepare Restore and Restore Setup confirmation steps.

### Changed

- Deluxe-Sync authentication is carried separately from public profile metadata, targeted only to the selected reader, and restored onto the original URL/username pair; migration does not create or register replacement remote accounts.
- Cross-device profile restore revalidates the pending targeted request immediately before changing local server configuration, rejects incomplete authentication sets, and preserves the destination reader's local device identity and sync caches.
- Settings-backup deduplication now includes the protected Deluxe profile checksum, while readers that already backed up an identical migrated profile are no longer offered that same setup again.

### Tests

- Added Lua 5.1 coverage for protected profile capture/apply, complete-authentication enforcement, candidate discovery, targeted restore requests, explicit confirmation ordering, pending-request revalidation, acknowledgement, capability gating, lifecycle integration, and existing-account preservation.

## [0.1.10] - 2026-09-09

### Changed

- Settings snapshots now exclude KOReader runtime/session state such as last-opened navigation, transient UI history, current frontlight/night-mode state, and closed rotation state, so ordinary reading no longer creates backup churn.
- Same-device restore now revalidates the pending server request immediately before applying settings, so a snapshot deleted or cancelled while the confirmation dialog is open cannot be restored from stale in-memory data.

### Tests

- Extended Lua 5.1 coverage to prove volatile runtime changes keep the same snapshot checksum, real preference changes produce a new checksum, and restores preserve the reader's current runtime/navigation state.

## [0.1.9] - 2026-09-09

### Changed

- Refresh enhanced server capabilities on every network reconnect and check for pending same-device restore requests before Stage 8/9 background synchronization.
- Condense the server-details action area into two buttons per row where possible while keeping Back to Server List full width.

### Tests

- Extended Stage 9 Lua 5.1 integration coverage for reconnect capability refresh and restore polling.

## [0.1.8] - 2026-09-09

### Added

- Added capability-gated Stage 9 KOReader settings backups for enhanced servers advertising settings-backup protocol v1.
- Added client-side sanitization with an explicit credential/device-identity deny-list before any settings snapshot leaves the reader, plus server-side sanitization as a second boundary.
- Added versioned per-device snapshots with deterministic checksums so unchanged settings are not uploaded repeatedly.
- Added same-device restore requests with an on-reader **Later / Restore / Reject Restore Request** confirmation flow; the server cannot silently apply settings.
- Added Settings Backups status to server capability/details cards and automatic backup checks on reader ready, resume, reconnect, capability refresh, and document close.

### Changed

- Restore applies only the sanitized backup overlay and preserves excluded local credentials/device identity; array settings replace their previous arrays instead of being recursively merged.
- Standard KOSync servers remain unchanged and receive no settings-backup or restore traffic.

### Tests

- Added executable Lua 5.1 coverage for settings sanitization, deterministic capture, array restore semantics, per-server dedup state, API wiring, capability gating, lifecycle triggers, and explicit restore confirmation ordering.

## [0.1.7] - 2026-09-09

### Added

- Added capability-gated Stage 8 reading-statistics ingestion for enhanced servers advertising reading-statistics protocol v1.
- Added a read-only KOReader `statistics.sqlite3` adapter that normalizes historical `page_stat_data` with book metadata, device-local dates/hours, and timezone offsets.
- Added persistent per-server import cursors with an overlap window for safe incremental uploads after the first historical import.
- Added Reading Statistics status to server capability/details cards.

### Changed

- Historical statistics upload now starts independently of progress Auto-Sync on reader ready, resume, network reconnect, successful progress pushes, capability refresh, and document close.
- Replayed overlap rows are intentionally safe: the client high-water cursor never moves backward and the server performs deterministic event deduplication.
- Deluxe-Sync never writes to KOReader's live statistics database; Stage 8 remains one-way KOReader to server.

### Tests

- Added executable Lua 5.1 coverage for read-only statistics parsing, normalization, cursor rewind/resume behavior, API wiring, capability gating, and upload lifecycle integration.

## [0.1.6] - 2026-09-09

### Added

- Added capability-gated Stage 7 annotation synchronization for KOReader highlights, notes, and bookmarks on enhanced servers advertising annotation protocol v1.
- Added stable per-annotation Deluxe sync IDs plus persistent per-server/document delta cursors and server revisions.
- Added revisioned deletion tombstones and server-wins stale-write conflict handling so offline devices cannot silently resurrect deleted annotations.
- Added Annotations status to server capability/details cards.

### Changed

- Successful push and pull workflows now start annotation convergence independently of the normal progress queue; standard KOSync servers receive no annotation requests.
- Annotation positions remain owned by the exact physical document. Linked-book aggregation never translates highlight/bookmark locations across different files.

### Tests

- Added dynamic annotation adapter coverage and Stage 7 integration assertions, with the complete 12-spec suite and modified runtime syntax checked under Lua 5.1.5.

## [0.1.5] - 2026-09-09

### Added

- Added capability-gated enhanced device registration for servers advertising device-registration v1.
- Added KOReader UUID, model/platform, KOReader version, Deluxe-Sync version, and client capability reporting while preserving the existing Deluxe device ID.
- Added once-per-session device heartbeat after successful sync and forced registration during Refresh / Test Capabilities.
- Added Device Identity status to server capability/details cards.

### Changed

- Existing Deluxe and KOReader identities can now be associated by a compatible server as one durable physical device without changing behavior on standard KOSync servers.

### Tests

- Added device-registration protocol regression coverage alongside the full Lua 5.1 suite.

## [0.1.4] - 2026-09-08

### Added

- Added capability-gated rich reading positions for enhanced servers: universal `pctQ`, KOReader page/page-count hints, and native rolling XPointer when available.
- Added rich-position support reporting to the server capability test/details UI.

### Changed

- Alternate linked-book pulls now prefer the portable rich `pctQ` fallback while exact same-file pulls continue using KOReader's native page/XPointer.
- Queued and metadata-fallback requests preserve rich position only for servers that advertise `rich_progress` version 1 or newer; ordinary KOSync servers keep the legacy payload.

### Tests

- Added rich-progress protocol regression coverage and resolver coverage for retaining the newest representative rich position.

## [0.1.3] - 2026-09-08

### Added

- Added per-server Binary/Filename document matching, with Binary remaining the backward-compatible default and Filename matching KOReader's MD5-of-basename behavior.
- Added enhanced-server logical-book browsing, linking, linked-book inspection, and unlinking from Browse Tracked Books.
- Added explicit shared-progress source selection when linking, recommending the furthest stored position by default.

### Fixed

- Replaced the crash-prone Link Books checkbox/scroll composition with KOReader native auto-scrolling button rows.
- Compacted Add/Edit server options into the existing action row so Metadata and Binary/Filename matching remain visible without adding height above the onscreen keyboard.

### Tests

- Added Lua 5.1 regression coverage for per-server matching, enhanced logical-book API wiring, linking selection, and explicit shared-progress source requests.

## [0.1.2] - 2026-09-03

### Added

- Added KOReader gesture/dispatcher actions for Deluxe-Sync Auto-Sync On/Off, Auto-Sync Toggle, Push Progress to All, and Pull Progress from All.
- Added gesture-safe availability checks and user-facing feedback when syncing is unavailable because the plugin is not ready, preview mode is active, or no sync server is enabled.

### Changed

- Bumped Deluxe-Sync to version 0.1.2.
- Updated the in-plugin updater to accept both current three-part `x.y.z` versions and future four-part `w.x.y.z` versions, including `v`-prefixed GitHub release tags.
- Normalized legacy three-part versions as `0.x.y.z` for comparisons so future four-part releases sort predictably.
- Updated README version synchronization and GitHub release validation to accept both supported version formats.
- Documented the new KOReader gesture actions and their safe multi-server behavior in the README.
- Updated the release workflow so the matching changelog section is used as the GitHub release notes.

### Tests

- Added Dispatcher registration regression coverage.
- Added updater comparison coverage for three-part, four-part, prefixed, mixed-format, and invalid version strings.
