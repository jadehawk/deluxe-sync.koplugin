# Changelog

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
