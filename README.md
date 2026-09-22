# Lite

A native macOS Chromium browser with a vertical sidebar, Spaces, pinned tabs,
nested folders, Favorites, a keyboard Command Bar, Split View, and Mini Lite.

**Status: runnable development build, not a production-qualified release.**
The app uses AppKit and Chromium Embedded Framework (CEF), not Electron or WebKit.
The CEF SDK is pinned to **154.0.23 / Chromium 154.0.8037.17**. No Chromium source
files are patched. The browser UI is native; only website content uses Chromium.

## Run

Requirements: macOS 14+, Xcode command-line tools, CMake 3.21+, Python 3.11+.
Apple Silicon is tested. The fetch script also selects the Intel SDK on Intel Macs.

```sh
./script/build_and_run.sh
```

This fetches the official CEF SDK if needed, verifies its upstream archive digest,
builds the native targets, runs core tests, stages and ad-hoc signs `dist/Lite.app`,
then opens it. Use `--build` to build without launching, or `--verify` to check the
launched process. The Codex Run action uses the same script.

## Implemented

- Native sidebar with pinned and temporary tabs, nested folders, context menus,
  drag and drop, Space switching, and a compact global Favorites area.
- Local, validated SQLite transactions for organization and restoration metadata.
- Website icons cached across launches and prefetched for unopened bookmarks;
  bookmark folders start collapsed at every launch.
- Manual save, fill, update, and deletion of website logins using macOS Keychain,
  available from the Library menu. Filling also offers accessible existing Keychain
  website passwords, restricted to the exact HTTPS host and port.
- GitHub Live Folders with account/repository/draft filters, periodic refresh, and
  optional API tokens kept in Keychain for access to private repositories.
- Browser Task Manager with live Chromium resource measurements, sorting, and
  guarded process termination; customizable, persisted native menu shortcuts.
- Native ad/tracker blocking and cosmetic hiding using bundled uBlock Origin Lite
  filter data, with a sidebar shield and persistent per-site controls. See the
  [supported subset and filter provenance](docs/content-blocking.md).
- Read-only Arc migration with preview, schema variations, ordering, nested folders,
  multiple containers, and safe rejection of broken references. HTML, Chromium JSON,
  and Safari plist bookmark import are separate workflows.
- Command Bar with direct address entry, search-first text queries, exact saved URL/title matches, and fuzzy browser commands.
- Real Chromium pages, navigation, TLS status, DevTools, find, zoom, print, HTML save,
  download callbacks, permission prompts, and transient popup windows.
- Two independent pages in a resizable horizontal or vertical split.
- Private in-memory Chromium contexts and no Lite history for private windows.
- Mini Lite for external links, with promotion to a selected Space.
- Background freezing/discard policy with guards for edited forms, media, capture,
  downloads, visible panes, and explicitly protected tabs.
- Native PiP requests and background media controls for supported HTML5 media.

## Release boundaries

This initial CEF embedding does **not** yet provide Chrome Web Store extensions,
Google password sync, automatic login-saving prompts, licensed Widevine/proprietary codecs, PWA installation,
or a signed automatic engine updater. Full browsing-session history/form/scroll
restoration after a renderer is discarded is not implemented; edited forms are
protected from automatic discard, and URL/title/pinned metadata survive.

It must not be advertised as a secure, maintained replacement for a current
production browser until engine update distribution, release signing/notarization,
security review, site compatibility, accessibility, and endurance testing have
been completed. CEF's sandbox and certificate validation remain enabled, but this
is not evidence of a security audit. See [release status](docs/release-status.md).

## Documentation

- [Architecture](docs/architecture.md)
- [macOS build and packaging](docs/build-macos.md)
- [Arc migration](docs/arc-migration.md)
- [Performance and measurements](docs/performance.md)
- [Keyboard shortcuts](docs/shortcuts.md)
- [Verification record](docs/verification.md)
- [Native content blocking](docs/content-blocking.md)

CEF, Chromium, uBlock Origin Lite, and Public Suffix List notices are included in the application Resources directory.
Lite contains no account service, telemetry SDK, AI subsystem, or proprietary Arc
assets. Arc names occur only when identifying an import source or imported data.
