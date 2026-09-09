# Changelog

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
