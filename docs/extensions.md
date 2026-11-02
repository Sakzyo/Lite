# Chrome extensions

Lite runs Manifest V3 Chrome extensions in regular windows. Open **View ›
Extensions…**, the puzzle-piece button in the address bar, or **Manage
Extensions** in the Command Bar.

## Adding extensions

- **Add from Chrome Web Store…** takes a `chromewebstore.google.com/detail/…`
  link or a 32-letter extension ID. While a Web Store detail page is open, the
  puzzle-piece menu also offers **Add This Extension to Lite…**. The Web Store's
  own "Add to Chrome" button does not work in Lite.
- **Add Folder…** loads an unpacked extension directory in place, like Chrome's
  "Load unpacked". Lite keeps a reference to the folder and never changes it.

After adding an extension, Lite lists what it can access (for example "Read and
change all your data on all websites"). **Remove** undoes the addition before
anything has run.

Chromium reads its extension list only at startup. Adding, updating, turning off
or removing an extension takes effect after **Restart Lite**. The restart closes
every window and reopens your saved tabs.

## Web Store package verification

Lite downloads the CRX3 package from Google's update service over HTTPS and
checks it before unpacking:

- Every RSA and ECDSA signature in the CRX3 header must verify over the signed
  header data and the ZIP archive.
- The developer key's SHA-256 prefix must equal the signed CRX ID and the
  requested extension ID.
- The Chrome Web Store publisher key (the SHA-256 Chromium's `crx_verifier.cc`
  requires for Web Store installs) must also have signed the package.

The archive is extracted with Info-ZIP, which strips absolute and `../` member
paths. Lite rejects symlinks and other special files. It writes the developer key
into `manifest.json` as `key` so Chromium assigns the Web Store ID when it loads
the files. **Update** downloads the current version again. A version that hasn't
changed is discarded, so no restart is needed.

## Storage

```text
~/Library/Application Support/Lite/Extensions/
  Extensions.json           # id, source, path, enabled
  <id>/<version-uuid>/      # verified Web Store packages
```

Chromium loads files lazily, so replaced or removed Web Store versions are
deleted only at the next launch, before the engine starts. Data an extension
stored (`chrome.storage`, IndexedDB and so on) lives in the Chromium profile and
is kept after removal. **Clear all website data** removes it.

## What works

Lite hosts pages with CEF's Alloy style, which on macOS is required for pages
inside native views. Lite passes the profile's enabled extensions to Chromium's
`--load-extension` switch, and CEF's Chrome bootstrap runs them for Alloy pages.
`script/test_extensions.py` checks these in the bundled engine:

- Content scripts.
- Background service workers, `runtime` messaging with a valid `sender.tab`, and
  `storage`.
- `chrome-extension://` pages with extension APIs. Action popups open in a
  native popover sized by Chromium's auto-resize (25×25 to 800×600, like
  Chrome). Options pages open in a tab. Hold Option in the extensions menu to
  open an extension's options instead of its popup.
- No extension runs in private windows.

## Limitations

CEF supports the full Chrome extension API only in Chrome-style windows, which
cannot be embedded in Lite's native layout. Upstream treats Alloy-style
extension support as limited to what CEF's own components need:

- Lite has no Chrome tab strip or Chrome windows. `chrome.tabs.create`,
  `chrome.windows.*` and `runtime.openOptionsPage` may not respond
  (`tabs.create` never resolves in testing), and `windowId` is `-1`. `tabs.get`
  works for a tab whose ID the extension already knows. Upstream reports also
  list `tabs.sendMessage`, `scripting.executeScript` and zoom/reload as working.
- `chrome.action` badges, icons that change at runtime, and `action.onClicked`
  are not shown. The extensions menu opens the popup or options page instead.
- Chromium does not auto-update `--load-extension` extensions. Use **Update**.
- Manifest V2 extensions, themes and Chrome Apps are rejected.
- Folder paths containing a comma can't be loaded, because the switch is
  comma-separated.
