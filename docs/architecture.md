# Architecture

Lite is moving from CEF to a Chromium-core host; see
[ADR-001](#adr-001-move-the-engine-host-from-cef-alloy-to-a-chromium-core-host).
Until that cutover, everything else in this document describes the current CEF build.

```text
AppKit windows, sidebar, dialogs, native menus
                 │
        LTWindow / LTPage interface
                 │
   CEF, native windowed NSView hosting
                 │
   Chromium subprocesses: Blink, V8, network, GPU
```

`lite/model` owns the data model, SQLite transactions, history queries, and local
command ranking, plus the profile-scoped encrypted login vault. `lite/migration` owns schema adapters and import previews.
`lite/browser` owns CEF clients, request contexts, helper startup, native page
views, downloads, permissions, media requests, and lifecycle callbacks.
`lite/macos` owns native view composition and user commands.
`LTGitHub` polls GitHub's read-only search API, validates complete paginated PR
results, and transactionally updates only the folder's managed tabs. Its optional
token is stored outside SQLite in a profile-scoped Keychain item. Redirects never
receive the token. Private stores do not start the integration.
`LTShortcuts` persists normalized menu bindings and rejects conflicts. Native menu
equivalents are dispatched before Chromium can consume them in editable page content.
`LTTaskManager` retains CEF's task-manager observer while its panel is open so task
identities and measurements remain stable, and releases it before CEF shutdown.
`lite/performance` contains a small policy function and a tolerant timer/memory
pressure source. `lite/tests` contains model/import tests and bundled-engine tests.

## Engine boundary

CEF's macOS native-parent integration uses **Alloy style**, backed by Chromium.
It supplies the content engine and security processes but does not provide the
entire Chrome application. Lite implements its own native tab/window/history UI.
The engine boundary is explicit so that the Chromium-core host chosen in
[ADR-001](#adr-001-move-the-engine-host-from-cef-alloy-to-a-chromium-core-host)
can provide the full extension API and more password-manager capabilities without
replacing the organization model.

`LTExtensions` (in `lite/model`) keeps the profile's extension list and verifies
Chrome Web Store CRX3 packages. Before `CefInitialize`, `main.mm` passes the
enabled, loadable directories to Chromium's `--load-extension` switch. CEF's
Chrome bootstrap then runs content scripts, service workers and
`chrome-extension://` pages for Lite's Alloy pages. The list is fixed for the
engine's lifetime, so changes need a restart. Replaced Web Store versions are
deleted only before the next engine start. See [extensions](extensions.md).

The main process loads the bundled framework with `CefScopedLibraryLoader`.
Each helper initializes `CefScopedSandboxContext` **before** loading the framework.
There is no `--no-sandbox`, certificate bypass, disabled site isolation,
`--single-process`, or global GPU-disable flag. CEF runs its native message loop;
Lite does not poll `CefDoMessageLoopWork` on a high-frequency timer.

The renderer helper installs a small, non-privileged lifecycle observer for form
edits and HTML media events. Its callback can only mark lifecycle protection flags.
It cannot access files, the organization database, permissions, navigation, or
native application commands. Media actions use Chromium's existing page/media
mechanisms. This is browser plumbing, not a user script/customization subsystem.

Website popups retain Chromium's opener and request context, including private
contexts. Downloads use CEF callbacks and the system save dialog. Permission
decisions are explicit prompts; camera/microphone additionally require macOS TCC.
Certificate errors use Chromium's default handling and are never overridden.

## ADR-001: Move the engine host from CEF Alloy to a Chromium-core host

- **Status:** Accepted; migration not started. CEF remains the shipping engine.
- **Date:** 5 November 2026
- **Deciders:** Sakzyo

### Context

Lite's largest product gaps come from the host rather than from Lite's own code:

- Alloy-style pages have no Chrome tab strip or windows, so `chrome.tabs.create`
  and `chrome.windows.*` fail and action badges are missing. Extensions cannot be
  auto-updated or changed without a restart.
- CEF cannot import a serialized navigation stack, so back/forward history is lost
  across restarts and most tabs with real history cannot be discarded.
- CEF 154, current when this was decided, exposed no supported way to change the
  Safe Storage Keychain namespace. CEF 156 adds `keychain_service_name` and
  `keychain_account_name` settings; Lite does not use them yet.
- Stock CEF binaries have no proprietary codecs, so enabling them already requires
  a custom engine build.

Chrome-style CEF windows would provide the extension API, but they cannot be
embedded in Lite's native layout, which is the product.

### Decision

Build Lite from the Chromium source tree, as a downstream of `//chrome`, and drive
it from Lite's existing AppKit interface. **Chromium-core host** means this
`//chrome` layer. A bare `//content` embedder is not enough, because it would leave
Lite to rebuild the extension system, session restore and password manager itself.

```text
AppKit windows, sidebar, dialogs, native menus
                 │
        LTWindow / LTPage interface
                 │
   Lite Chromium host: Browser, TabStripModel, WebContents
                 │
   Chromium subprocesses: Blink, V8, network, GPU
```

Lite keeps its own repository, data model, SQLite store and AppKit UI. The Chromium
revision is pinned, and changes to Chromium live here as a small, reviewable patch
series rather than a long-lived fork.

### Options considered

| | A: Stay on CEF Alloy | B: CEF Chrome style | C: Chromium core (chosen) | D: `//content` embedder |
| --- | --- | --- | --- | --- |
| Native sidebar layout | Yes | No | Yes | Yes |
| Full extension API | No | Yes | Expected | Lite must build it |
| Restored navigation history | No | Not assessed | Expected | Lite must build it |
| Chromium patches | None | None | Small series | Smaller series |
| Build and CI cost | Low | Low | Very high | Very high |
| Upstream rebase work | Low | Low | High | Medium |

A cannot close the gaps above. B gives up the native layout. D pays nearly the same
build cost as C without its features. C is the only option that keeps the layout
and removes the host limits, in exchange for owning a browser build.

### Consequences

Becomes possible:

- Real `Browser` and `TabStripModel` objects behind the extension API.
- Session restore through `NavigationController::Restore`, including back/forward
  history after restart and discard of tabs with history.
- Extension install, auto-update and enable/disable without restarting the engine.
- Injected code in an isolated world, instead of page-visible globals such as
  `__liteLifecycle`.
- Request hooks that cover WebSockets.

Becomes harder:

- **Security response is now Lite's job.** Every Chromium milestone and security
  refresh has to be rebased, built and shipped. A late release is a user-facing
  vulnerability, so the updater and publisher setup become prerequisites for
  cutover, not follow-ups.
- **Build infrastructure.** CMake and `fetch_cef.py` give way to GN and a full
  Chromium checkout. The current 30-minute hosted workflow cannot build it, so
  remote or cached builds are required. Cost and duration are unmeasured.
- **Patch maintenance.** Each `//chrome` change adds to rebase work, so every patch
  must justify itself.

Does not change:

- **Google sync and Chrome-only services** stay unavailable to a third-party
  Chromium build.
- **Widevine** still needs a Google license and signing. Building from source
  makes proprietary codecs a build option, but licensing needs review first.
- The sandbox, certificate handling and privacy rules in this document still apply.

### Design constraints for the port

- `LTEngine.h` is the seam. CEF symbols are confined to `LTEngine.mm` (150 uses),
  `helper.cc` (19), `main.mm` (15), `LTYouTubeFilter.h` (1) and one test.
  `lite/model` and the sidebar should not need engine changes.
- Lazy tabs are the hardest mapping. Sidebar nodes without a renderer are metadata
  today, while `TabStripModel` holds live tabs. The port must define what extensions
  see for unopened and discarded tabs, and for tabs in other Spaces.
- `BrowserWindow` is a large interface shaped around Chromium's Views UI. Whether
  an AppKit `LTWindow` can implement it directly is the main technical risk.
- `Chromium/Default/` must migrate in place. Cookies encrypted under Chromium Safe
  Storage must survive a change of Keychain namespace, and the Lite vault format
  stays unchanged. Whether Lite's vault gives way to Chromium's password manager
  is a separate decision.

### Migration plan

1. **Spike.** Build a pinned Chromium with one AppKit `LTWindow` hosting a
   `WebContents`. Pass only if `chrome.tabs.create` resolves, restored history
   works, and build time, app size and the memory table in
   [performance](performance.md) are measured. If `BrowserWindow` proves unworkable,
   revisit this decision before going further.
2. **Second backend.** Implement `LTEngine.h` against the new host beside CEF, with
   CEF still the default.
3. **Port.** Move content blocking, the renderer observer, login capture, downloads,
   permissions, the Task Manager and extensions.
4. **Parity.** Pass the Chromium integration and native-window suites at their
   current 95/95 and 35/35, `script/test_extensions.py`, and upgrade of a synthetic
   CEF profile including cookies and vault.
5. **Cutover.** Stand up the Chromium update pipeline and signed delivery, ship,
   then remove CEF, its scripts and its documentation.

CEF pins keep receiving updates throughout. The migration is no reason to let the
shipping engine fall further behind.

## Data integrity

`LTStore` validates a copied model before a `BEGIN IMMEDIATE` / `COMMIT` transaction.
Only after the commit succeeds does the in-memory model change. SQLite uses WAL
and `synchronous=FULL`. Schema version 1 is explicit; future unknown versions fail
closed. A corrupt/unsupported profile is not silently overwritten.

Pinned URL and current navigated URL are distinct. Custom titles are distinct from
page titles. Node IDs are stable UUIDs, independent of Arc IDs. Folder parent/Space
relationships, cycles, duplicates, selected tabs, and URLs are validated together.
Temporary tabs are a distinct node kind; history is a separate indexed SQL table.
Private windows use an in-memory Lite store and a separate CEF off-record context.

Normal profiles live in `~/Library/Application Support/Lite/`:

```text
Lite.sqlite                # organization, window metadata, Lite history
Lite.sqlite-wal / -shm     # SQLite WAL files while running
Chromium/Default/          # normal Chromium profile/storage
Favicons/                  # bounded PNG favicon cache, shared by site origin
Credentials/Logins.vault    # authenticated encrypted website accounts/passwords
Extensions/Extensions.json  # extension list; Web Store packages in Extensions/<id>/
```

`LTLoginStore` keeps website accounts and passwords in one `LTLoginVault` file.
The entire JSON payload (including origins and usernames) is AES-256-CBC encrypted
with a fresh random IV. Encrypt-then-MAC HMAC-SHA-256 authenticates the version,
IV and ciphertext with an independent 256-bit key; the tag is compared without an
early exit before decryption. Security.framework generates the 64 bytes of key
material and stores them only in a profile-scoped, non-synchronizing login Keychain
item using macOS's default application access controls. The key is fetched for
each operation rather than cached by the store. This local ad-hoc build uses the
login Keychain, not the entitlement-based Data Protection Keychain; it does not
claim a separate Touch ID or screen-lock policy. See [Apple's Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

The credential directory is mode 0700 and the vault is 0600, with inherited ACLs
removed. Descriptor-relative I/O rejects symlinks, non-owner files and hard-linked
vault files. Directory locking serializes read/modify/write across stores and
processes. Updates write only ciphertext into an exclusive 0600 temporary file,
flush it, atomically rename it, then flush the directory. There are no plaintext
credential files or SQLite password fields. Interrupted writes can leave encrypted
temporary files. A missing key, failed authentication, or invalid data fails closed
without resetting the vault. Older Lite Keychain logins migrate on first access;
their originals are deleted only after a successful vault commit, under the same
lock. Retry preserves any newer vault entry. Other apps' passwords and GitHub API
tokens are not migrated.

In regular main frames, a renderer listener captures a user-activated, trusted
submission of a visible same-origin form containing one current-password field.
It keeps its callback in a closure; there is no page API to read or write the vault.
The browser validates the actual frame origin and certificate independently before
offering a native Save sheet. The submitted values remain in memory until the user
chooses Save; Cancel does not persist them. A redirect never changes their recorded
origin. Submission is not proof that the server accepted the login. Multi-step,
custom JavaScript, password-creation and embedded forms may need the manual Save
command. Private windows install no capture callback and have no login-store
connection. Fill remains explicit and checks the exact scheme, host and port both
natively and in the page. HTTPS with a valid certificate is required, except for
HTTP loopback development pages. Private windows also have no persistent favicon cache.

The default file is `~/Library/Application Support/Lite/Credentials/Logins.vault`.
Copying it alone to another Mac does not make the credentials readable: its original
Keychain key is required. Encryption protects stored data, not an already compromised
macOS session or values while being entered/filled on a website. Local ad-hoc builds
can prompt for Keychain access after rebuilds; stable release signing remains a
distribution requirement.

The window sidebar uses `NSOutlineView` view reuse. Page title updates refresh the
affected row. Organization mutations rebuild visible tree metadata; expansion
saves are deferred outside outline notifications to avoid reentrant AppKit edits.
Favorites have no renderer until opened. Restoring a window loads only its selected
page and visible split page, regardless of how many pinned tabs exist.

Window chrome is drawn with layer-backed AppKit views only (`LTTheme`): a
`CAGradientLayer` backdrop tinted per Space (`spaceThemes` in profile settings) and
rounded, clipped content cards hosting each split page. No image assets or extra
frameworks beyond QuartzCore are used.

## Upstream references

- [CEF architecture](https://chromiumembedded.github.io/cef/architecture)
- [CEF general usage](https://chromiumembedded.github.io/cef/general_usage)
- [CEF sandbox setup](https://chromiumembedded.github.io/cef/sandbox_setup)
- [CEF source and license](https://github.com/chromiumembedded/cef)
- [Chromium macOS build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)

Chromium modifications: **none** in the current CEF build. All Lite-specific code is
in this repository. ADR-001 replaces this with a pinned Chromium revision and a patch
series once the migration reaches its port phase.
