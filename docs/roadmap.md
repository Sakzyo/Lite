# Roadmap

## Lite 1.0 goals

Lite is at version 0.1.0, so the next major version is 1.0. These goals were set on
5 November 2026. The [release gates](release-status.md) still
apply: meeting these goals does not by itself qualify Lite as a production browser.

### Security and release

- **Keep the engine current.** Done: Lite is on CEF 156.0.26 / Chromium 156.0.8078.88,
  and a scheduled CI job opens a pull request when a newer stable CEF release is out.
- **Remove test code from the app.** Done: `LTSmoke`, `LTNativeSmoke` and the `--lite-*`
  flags are built only into `dist/LiteTest.app`, and packaging fails if a release binary
  contains them.
- **Hide lifecycle plumbing from pages.** Done: the `__liteLifecycle` global is gone,
  and forged events no longer raise protection flags. A site can still stay protected
  by really using media, and the `AudioContext` wrapper is still detectable. See
  [architecture](architecture.md#engine-boundary).
- **Add crash reporting.** Done: Lite collects crash reports for endurance testing and
  real use, and sends them to Sentry only when the user approves them. See
  [crash reporting](crash-reporting.md). The README's telemetry statement was reviewed:
  no SDK is linked, and it now names consented crash reports.

### Everyday browsing

- **Make the Command Bar search history.** Done: partial text finds history by the start
  of its address, so "gith" finds github.com, and by the start of any word in a title or
  URL, through SQLite FTS5. Results rank by how they matched, then by frecency: a visit
  count in which each visit's weight halves every 30 days. History keeps 90 days and at
  most 100,000 URLs, pruned on the background writer. With 100,000 URLs the slowest
  Command Bar query measured took 2.1 ms of the 16.7 ms frame on Apple Silicon, and CI
  checks the same budget on Intel. The profile database is 2.6 times as large as before
  at that size, and the History panel's own search still
  scans every row. See [history search](performance.md#history-search) and
  [history](architecture.md#history).
- **Make closed tabs recoverable.** Done: the 30 most recently closed tabs and windows
  are saved in the profile, so Reopen Closed Tab works after quitting Lite, and Reopen
  Closed Window brings back a window's Space, tabs, split and frame. Deleting history
  removes them too. Private windows keep their own list, which ends with the window. See
  [recently closed tabs and windows](architecture.md#recently-closed-tabs-and-windows).
- **Widen search.** Done: Settings offers DuckDuckGo, Google, Bing, Brave Search, Ecosia,
  Kagi and Startpage, and up to 32 search engines of your own, each a name and a search
  address with `%s` where the query goes. Private windows search with the same engine.
  Command Bar suggestions are off until you turn them on in Settings. When they are on,
  Lite sends the text you type to the selected engine, without cookies, and lists up to
  four suggestions under the search row. Addresses, and anything typed in a private
  window, are not sent. A query's `+` now reaches the engine as typed; before, engines
  read it as a space. See
  [search engines and suggestions](architecture.md#search-engines-and-suggestions).
- **Add data export.** Done: Settings, the Library menu and the Command Bar export
  Favorites and every Space's folders and pinned tabs as a bookmarks file, which Safari,
  Chrome, Firefox and Lite import, or as a Lite organization file. The organization file
  also keeps Space colors, which folders are open, and both a tab's page title and the name
  you gave it, and Import Bookmarks reads it back into new Spaces. Temporary tabs, history
  and window state are not exported, and private windows cannot export. See
  [data export](architecture.md#data-export).

### Performance

- **Move profile writes off the main thread.** Done: visit recording, organization
  saves, history deletion and recovery backups run on a serial background writer. At
  10,000 nodes a save costs the main thread about 0.02 ms, and renames and opening or
  closing a tab stayed within the frame budget in the running app. Changes that reload the
  whole sidebar, such as switching Spaces or reordering rows, still take about 50 ms. See
  [profile saves](performance.md#profile-saves) and
  [background writer](architecture.md#background-writer).

### Content blocking

- **Update filters without an app release.** Done: a release build configured with a filter
  feed checks it at most once a day, downloads a set only when its signature and every
  file's hash verify, refuses older sets, and swaps the new rules in without a relaunch.
  Settings for it are in the Content Blocking sheet. `script/sign_filters.py` creates the
  key and publishes a feed. Choosing where the feed is hosted, and keeping the key, are
  still to do before a release uses it. See
  [filter updates](content-blocking.md#filter-updates).
- **Close the filtering gaps.** Partly done: Content Blocking has a local custom
  network-filter editor for URL patterns and `@@` allow exceptions, with whole-edit
  validation and temporary private-window edits. Custom rules survive filter updates.
  Scriptlets, regex network rules, custom cosmetic filters and an element picker
  remain to do. See [custom network filters](content-blocking.md#custom-network-filters).

### Extensions

- **Update extensions automatically.** Check for new versions in the background and
  apply them at the next launch, without interrupting the session.

### Accessibility and languages

- **Respect display settings.** Done: Reduce Transparency draws each Space backdrop as
  one flat color, and Increase Contrast mutes the Space tint so black or white text keeps
  at least 7:1 contrast on the sidebar backdrop for every Space color, including on
  selected and hovered rows. It also strengthens borders and outlines the selected row
  and Favorites. Both take effect without a relaunch. Pages themselves are left to
  Chromium. See [display settings](architecture.md#display-settings).
- **Complete VoiceOver testing.** Cover spoken output across the sidebar, Command Bar
  and panels, and fix what it finds.
- **Make the UI localizable.** Move all UI text out of hard-coded English.

### Browser features

- **Auto-archive tabs.** Temporary tabs archive themselves after a period of disuse.
- **Add Peek.** Preview a link without leaving the current page.
- **Add Boosts.** Support per-site customization.
- **Add reader mode.**
- **Add translation.**

### Code and documentation

- **Correct stale docs.** Done: [release status](release-status.md) and the
  [readiness record](readiness-2026-10-01.md) now say hosted CI has passed on `master`
  since 2 November 2026, on macOS 15 arm64 and Intel runners.
- **Split up `LTWindow.mm`.** Move string-based command dispatch into its own testable
  router.

### Not 1.0 goals

The move to a Chromium-core host is tracked separately in
[ADR-001](architecture.md#adr-001-move-the-engine-host-from-cef-alloy-to-a-chromium-core-host),
along with the capabilities that depend on it: the full extension API, restored
back/forward history after restart, and changing extensions without a restart.
Proprietary codecs and Widevine are also outside these goals.
