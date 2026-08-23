# Deluxe-Sync

Deluxe-Sync is a KOReader plugin that extends the built-in KOSync workflow to multiple independent KOReader-compatible servers.

Current plugin version: **0.1.0**

## Implemented in this initial build

- Multiple server profiles, each with its own URL, username, derived KOSync user key, enable/disable state, and detected capabilities.
- Standard KOReader KOSync account registration, authentication, and progress API compatibility.
- Push the current reading position to every enabled server in parallel/asynchronously.
- Auto-Sync Documents is enabled by default. It pulls on document ready/resume, pushes on suspend/close, queues offline pushes, and drains queued updates before pulling when the network reconnects.
- Sync Behavior controls automatic pulls independently for newer and older remote states: Silently / Prompt / Never. Defaults are Prompt for newer states and Never for older states.
- Per-server retry queue. A newer queued position for the same server/book replaces an older one; transient/offline failures are retried automatically on network reconnect while Auto-Sync is enabled.
- Manual Pull always opens the read-only multi-server Sync Card, grouping identical exact progress values and sorting differing positions newest-first. Automatic Prompt uses the same card; automatic Silent may apply the selected newest remote state according to Sync Behavior.
- Opening Deluxe-Sync with no registered servers shows onboarding with a complimentary `Techy-Notes.com` option (`https://sync.techy-notes.com`), custom-server setup, or cancel. The complimentary path reuses the normal server editor and registration flow with only name/URL prefilled.
- Optional `GET /syncs/documents` capability detection for enhanced servers.
- Remote-library browsing for enhanced servers and locally cached known-document browsing for standard servers.
- Server-library scans against KOReader's configured home library, with binary checksum matches taking priority over filename and title/author matches.
- Server-library browsing uses compact grouped cards separated into **With Metadata** and **Metadata Unavailable** sections. Selecting a server book opens an inspection-only two-column Book Review with book information and that single server record; it never changes the reader position or sync state.
- Alias-aware pulls: after a merge, Deluxe-Sync queries both the canonical local document ID and legacy IDs retained for each server.
- Safe progress preview: save the exact local position, jump to the remote percentage, suppress Deluxe-Sync syncing while previewing, inspect/adjust with the normal reader, then either restore the original position or accept the current local position.
- Merge aliases: when a remote document record is accepted as the same book as the current local file, the remote document ID is retained as an alias of the local canonical document ID.
- On merge acceptance, the actual local reader position is pushed under the local document ID, avoiding reuse of an XPointer from a potentially different EPUB edition.
- Built-in GitHub update checks support one automatic check per KOReader session, manual checks from the Deluxe-Sync menu, per-version skip persistence, safe staged replacement, and a restart prompt after installation.
- A Credits page shows the installed plugin version, project acknowledgements, and clickable project/support links.

## Compatibility targets used during development

- Enhanced metadata/document-listing server: `https://sync.send2ereader.net`
- Standard KOSync server: `https://boxofbooks.org/api/v1/koreader`

Credentials are deliberately not stored in the repository. Users enter passwords in the server editor; the plugin derives the same MD5 KOSync user key used by KOReader's built-in Progress Sync plugin.

All plugin-owned runtime state is kept under KOReader's `settings/deluxe-sync/` directory. `settings.lua` stores servers, aliases, known documents, and plugin options; `queue.lua` stores retry work; `logs/deluxe-sync.log` records plugin diagnostics. Diagnostic logging is enabled by default and can be disabled from the Deluxe-Sync menu without removing the logging implementation.

## Installation

1. Download the latest `deluxe-sync.koplugin.zip` from GitHub Releases.
2. Extract the ZIP.
3. Copy the entire `deluxe-sync.koplugin` folder to KOReader's `plugins` folder.
4. Restart KOReader.
5. Open a book, then use **Deluxe-Sync** from the reader menu.

After the initial installation, future releases can be installed directly from **Deluxe-Sync → Check for Updates**.

## Preview / merge workflow

1. Pull the current book from all servers.
2. Select a remote position to preview.
3. Deluxe-Sync records the exact current local position and jumps to the remote percentage.
4. Choose **Inspect / adjust position** or **Hide to see preview** to dismiss the preview controls and inspect the actual local page. Page forward/backward as needed.
5. While preview mode is active, a small **Preview Menu** button stays visible on the reader. Tap it at any time to reopen the preview controls.
6. Use **Return without changes** at the bottom of the preview card to restore the exact original position, or accept the inspected position and continue to the merge/sync choices.

While preview mode is active, Deluxe-Sync push/pull actions are disabled and automatic Deluxe-Sync syncing is suppressed. The on-reader **Preview Menu** control disappears automatically as soon as preview mode ends.

## Localization

Deluxe-Sync uses plugin-owned JSON catalogs under `i18n/`. English is the default and fallback language in `i18n/en.json`. At startup the plugin reads KOReader's current UI language, first looks for an exact catalog such as `i18n/pt-BR.json`, then falls back to the base language such as `i18n/pt.json`, and finally to English. Missing keys fall back to their English/source text, so an incomplete translation never leaves the interface blank.

New user-facing strings should be routed through `I18N.translate` (the local `_()` helper) and added to `i18n/en.json`; additional languages only require another JSON catalog with matching keys.

## UI status

The synchronization engine, local-library matching, and preview/merge flow are implemented. Server-library browsing is intentionally inspection-only and uses KOReader-native compact cards grouped by metadata availability, with a two-column single-server Book Review for record inspection.

## Development

The repository contains the installable KOReader plugin in `deluxe-sync.koplugin/` together with its Lua tests under `deluxe-sync.koplugin/spec/`. The compatibility target is Lua 5.1 / LuaJIT as used by KOReader.
