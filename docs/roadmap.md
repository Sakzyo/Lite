# Roadmap

## Lite 1.0 goals

Lite is at version 0.1.0, so the next major version is 1.0. These goals were set on
5 November 2026. The [release gates](release-status.md) still
apply: meeting these goals does not by itself qualify Lite as a production browser.

### Security and release

- **Keep the engine current.** Done: Lite is on CEF 156.0.15 / Chromium 156.0.8078.80,
  and a scheduled CI job opens a pull request when a newer stable CEF release is out.
- **Remove test code from the app.** Done: `LTSmoke`, `LTNativeSmoke` and the `--lite-*`
  flags are built only into `dist/LiteTest.app`, and packaging fails if a release binary
  contains them.
- **Hide lifecycle plumbing from pages.** Done: the `__liteLifecycle` global is gone,
  and forged events no longer raise protection flags. A site can still stay protected
  by really using media, and the `AudioContext` wrapper is still detectable. See
  [architecture](architecture.md#engine-boundary).
- **Add crash reporting.** Collect crash reports for endurance testing and real use,
  and send them only with the user's consent. The README says Lite has no telemetry
  SDK, so that statement must be reviewed when this lands.

### Everyday browsing

- **Make the Command Bar search history.** Partial text such as "gith" finds
  github.com. Record visits so results rank by frequency and recency, add full-text
  search, and limit how long history is kept.
- **Make closed tabs recoverable.** Reopen Closed Tab survives quitting Lite, and
  closed windows can be restored.
- **Widen search.** Support more search engines, including custom ones, and add search
  suggestions to the Command Bar.
- **Add data export.** Bookmarks and the profile's organization can be exported, not
  only imported.

### Performance

- **Move profile writes off the main thread.** Use a serial background writer for
  visit recording and organization saves. A 10,000-node save must no longer miss the
  frame budget.

### Content blocking

- **Update filters without an app release.** Deliver signed filter updates.
- **Close the filtering gaps.** Add scriptlets, regex network rules, custom filters
  and an element picker.

### Extensions

- **Update extensions automatically.** Check for new versions in the background and
  apply them at the next launch, without interrupting the session.

### Accessibility and languages

- **Respect display settings.** Honor Reduce Transparency and Increase Contrast,
  including on the tinted backdrops.
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

- **Correct stale docs.** [Release status](release-status.md) and the
  [readiness record](readiness-2026-10-01.md) still say hosted CI has not run, but it
  passed on `master` on 2 November 2026.
- **Split up `LTWindow.mm`.** Move string-based command dispatch into its own testable
  router.

### Not 1.0 goals

The move to a Chromium-core host is tracked separately in
[ADR-001](architecture.md#adr-001-move-the-engine-host-from-cef-alloy-to-a-chromium-core-host),
along with the capabilities that depend on it: the full extension API, restored
back/forward history after restart, and changing extensions without a restart.
Proprietary codecs and Widevine are also outside these goals.
