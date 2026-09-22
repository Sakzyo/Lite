# Architecture

```text
AppKit windows, sidebar, dialogs, native menus
                 │
        LTWindow / LTPage interface
                 │
   CEF 154, native windowed NSView hosting
                 │
   Chromium subprocesses: Blink, V8, network, GPU
```

`lite/model` owns the data model, SQLite transactions, history queries, and local
command ranking, plus the profile-scoped Keychain login store. `lite/migration` owns schema adapters and import previews.
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
The engine boundary is explicit so a future Chrome-style or Chromium-core host
can provide extensions and more password-manager capabilities without replacing the organization model.

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
```

`LTLoginStore` keeps password values in macOS Keychain generic-password items,
scoped by the profile path. SQLite never receives login passwords. Native Library
commands explicitly save/fill/manage entries. Page scripts cannot call the store;
the native UI reads or fills a form only after a user action. Both the browser's
current URL and the page script check the exact origin before filling. HTTPS with
a valid certificate is required, except for HTTP loopback development pages.
Private windows have no persistent favicon cache or login-store connection.

The window sidebar uses `NSOutlineView` view reuse. Page title updates refresh the
affected row. Organization mutations rebuild visible tree metadata; expansion
saves are deferred outside outline notifications to avoid reentrant AppKit edits.
Favorites have no renderer until opened. Restoring a window loads only its selected
page and visible split page, regardless of how many pinned tabs exist.

## Upstream references

- [CEF architecture](https://chromiumembedded.github.io/cef/architecture)
- [CEF general usage](https://chromiumembedded.github.io/cef/general_usage)
- [CEF sandbox setup](https://chromiumembedded.github.io/cef/sandbox_setup)
- [CEF source and license](https://github.com/chromiumembedded/cef)

Chromium modifications: **none**. All Lite-specific code is in this repository.
