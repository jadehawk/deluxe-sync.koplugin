# Changelog

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
