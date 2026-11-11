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

The helper compiles the observer with `CefV8Context::Eval` before any page script
runs and passes the native callback to it as an argument, so the callback never
exists on `window`. The observer captures the builtins it needs and calls nothing a
page can replace. A site cannot call the callback or fake a signal:

- Interaction counts only for trusted events. `input` and `change` also need a user
  gesture in the frame, because `element.click()` raises them as trusted events from
  script. Paste and drop count without one, because Lite's menu routing keeps Command-V
  from reaching the page as a `keydown`.
- Media and Picture in Picture state come from the real elements and contexts, read
  through the captured accessors. Forged events only cause a truthful re-check.
- Lite's login fill dispatches synthetic events, so `LTPasswords` raises the guard
  natively instead.

Two limits remain, and both need main-world code to go away or an isolated world:

- A site can still stay protected by really using media, such as a running silent
  `AudioContext` or a playing muted video. Both raise the flag as designed.
- `AudioContext` is still a `Proxy`, so `Function.prototype.toString` shows it as
  `function () { [native code] }` instead of naming it. A site can detect that wrapper.

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
- Injected code in an isolated world, instead of main-world code that a page can
  detect, such as the `AudioContext` wrapper.
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
and `synchronous=FULL`. The schema version is explicit in `user_version`, now 2, and
future unknown versions fail closed. A corrupt/unsupported profile is not silently
overwritten.

### History

History is one row per URL in the `history` table, separate from the organization:

| Column | Holds |
| --- | --- |
| `id` | Stable integer key, which the full-text index refers to |
| `url` | The URL as visited, unique |
| `title` | The last title seen for it |
| `address` | The URL in lowercase without its scheme or a leading `www.`, for prefix matching |
| `words` | The title's words, then the address's, for word matching |
| `visited` | The last visit |
| `visits` | How many visits |
| `rank` | Frecency, below |

A word is a run of letters and digits, folded to lowercase without diacritics, so "Café"
gives "cafe". `words` holds each one after a single space. `history_fts` is an FTS5 index over
`words`. It stores no text of its own: it reads the table, and triggers on the table keep it in
step. The `(address, rank)` index answers a prefix match without reading the table.

**Frecency.** Each visit has a weight that halves every 30 days, and a URL's frecency is the
sum. Lite stores it as `rank = ln(weight) + decay × time`. Every row decays by the same factor,
so ordering by `rank` orders by weight today without updating any row as time passes. A
visit sets `rank` to `logaddexp(rank, decay × now)`. A title that changes while a page stays
open, such as an unread count, renames the row without counting a visit.

**Search.** `searchHistory:limit:` takes the rows that match in three ways, each in frecency
order and capped at the limit, then keeps each row's best match:

1. Exact: the whole URL, or the whole title, found through FTS5 as a phrase at the start of
   `words`.
2. Address: the typed text, without a scheme or `www.`, starts the address. "gith" finds
   `https://www.github.com/…`.
3. Word: every typed word starts a word of the title or address, in any order. The 2,000
   most frecent rows are scanned first, in rank order, by looking for " " plus each typed word
   in `words`. If enough match, they are the best matches. Otherwise FTS5 answers, with each
   word as a quoted prefix, so nothing typed is query syntax. Both read `words`, so they agree.

Text inside a word, such as "thub", does not match. The Command Bar shows the best address
match above web search and the rest below it. A typed web address still opens first. The
History panel's `history:limit:` is unchanged: newest first, matching any part of the URL or
title, by scanning the table.

**Retention.** Visits older than 90 days are dropped, then the least frecent URLs beyond
100,000. The writer does this after the first visit it records and then at most hourly, 1,000
rows at a time, each batch its own turn of the writer so that saves queued meanwhile run in
between. Opening the store starts nothing on the writer.

**Deletion.** Deleting history also merges the full-text index, so words from deleted rows
leave the index at once rather than at a later automatic merge. Clearing all history drops
the delete trigger, deletes the rows and rebuilds the index in one transaction, which is
four times faster at 100,000 URLs than deleting row by row. Like any deleted SQLite row,
their bytes can remain in free pages until reused; Lite does not enable `secure_delete`.
Recovery backups are replaced as before.

**Migration.** Opening a version 1 database runs one transaction: it renames the old table,
copies each URL with one visit at its last visit time, builds the indexes and triggers, fills
the full-text index and sets version 2. Every step is safe to repeat, and an interrupted
migration leaves version 1. A build that knows only version 1 refuses a version 2 database,
and a backup of it, rather than downgrading it.

Private stores create the same schema in memory and record nothing. FTS5 is part of the
SQLite that macOS ships, which Lite links, on every supported macOS version, and a test
checks for it.

### Recently closed tabs and windows

The profile JSON keeps a `closed` list, oldest first and at most 30 entries
(`LTClosedLimit`), shared by every regular window. Closing a temporary tab adds a copy of
its node, read on the writer so it has the address of the tab's last queued save. Closing
a regular window adds its restoration state: Space, active and split tabs, frame, sidebar
and saved scroll positions. Tabs live in their Space, not in a window, so a window's tabs
stay in the sidebar after it closes and reopening it restores the view. Windows that close
because Lite quits or restarts are not added; those come back through the saved window list.
Mini and private windows are never added. A private window's tabs go to its own in-memory
store and end with it.

Reopen Closed Tab (⇧⌘T) takes the newest tab entry into the current Space. Reopen Closed
Window takes the newest window entry. With no window open, ⇧⌘T reopens the last window if
that was the last thing closed. Each reopen removes its entry in the same save that adds
the tab or window, by entry ID, so two quick presses never reopen one entry twice.

The list is browsing history, so deleting history edits it in the same writer operation,
before the recovery backups are refreshed. Clearing a period drops entries closed in it.
Deleting one address drops its closed tabs and removes its scroll positions from closed
windows. The validator rejects an entry of an unknown type, a tab that is not temporary or
has an address Lite cannot open, an invalid window state, and a list over the limit. A
profile saved before the list existed loads with an empty one.

### Auto-archive

Settings > "Archive unused tabs after" offers Never (the default), 12 Hours, 1 Day, 7 Days
and 30 Days, stored as `settings.archiveTabs`. Every five minutes the app delegate closes
temporary tabs that have not been selected for that long. Each one goes through the
window's normal close path, so it lands in Recently Closed like a tab closed by hand, and
Reopen Closed Tab brings it back, also after quitting.

A tab's age is its `lastUsed` time, which selecting the tab updates. A new tab starts
aging when it is created, and a tab from a profile saved before `lastUsed` was recorded
starts aging at the first sweep, so turning the setting on never closes a pile of old
tabs at once. These are always kept:

- pinned tabs, Favorites and folders, which are not temporary;
- each Space's selected tab, and any tab a window shows, including the other side of a
  split;
- a tab whose page is playing audio, capturing, downloading, holding unsaved work,
  kept awake, in Picture in Picture, or already closing;
- every tab in a private window, which has its own store and is never swept.

`LTProfile -idleTabsAt:excluding:` chooses the tabs, oldest first; the window re-checks the
tab's kind, use and age just before closing it. Selection times reach the main thread's
profile only after their save, so the close itself checks the age once more on the writer,
after any selection queued before it; a tab used again in between stays, unloaded. When no regular window is open, the app
archives on the profile writer and checks the age again there. Recently Closed holds 30
entries, so archiving many tabs at once can push older closed tabs out. Archived tabs are
not a separate list. `LiteArchiveTests` covers the choices, idle selection and everything
that is kept, older profiles, validation, and reopening an archived tab after the store is
reopened.

### Search engines and suggestions

Three profile settings hold the search configuration:

| Setting | Holds |
| --- | --- |
| `search` | The selected engine's name. A new profile has `DuckDuckGo` |
| `searchEngines` | The user's own engines, in the order added, at most 32 |
| `searchSuggestions` | Whether the Command Bar asks for suggestions. Absent means off |

An engine is a name, a search address and, optionally, a suggestions address. `%s` in an
address stands for the query. Seven engines are built in (`LTBuiltInSearchEngines`):
DuckDuckGo, Google, Bing, Brave Search, Ecosia, Kagi and Startpage, each with an https
search address and an https suggestions address. Settings lists them first, then the
user's own, with Add and Remove beside the menu. Removing the selected engine selects
DuckDuckGo in the same save.

**Filling the address.** The query replaces `%s` with every character percent-encoded
except letters, digits and `-._~`. The same rule serves a query string and a path, so an
address such as `https://docs.example/%s/index.html` works and the query stays one path
segment. Before this, the query went through `NSURLQueryItem`, which leaves `+` as it is,
and engines read "c++" as "c" and two spaces.

**Rules for a custom engine.** `LTCustomSearchEngine` checks an entry and returns what is
stored:

- The name is 1 to 64 characters on one line, and differs from every other engine's name
  without regard to case.
- The search address contains `%s`, has no spaces, is at most 2,048 characters, and is an
  http or https address that Lite can open. It cannot carry a user name or password.
- `%s` cannot be in the site's name, scheme or port, so a query never chooses which site
  receives it.
- The suggestions address follows the same rules and must be https, because it receives
  text as it is typed. http is accepted only for `localhost`, `127.0.0.1` and `::1`.
- `{searchTerms}`, the OpenSearch placeholder, is accepted and stored as `%s`.

The profile validator applies the same function: each stored engine must be exactly what
it returns, and `search` must name a built-in or stored engine. A save that would break
this is refused like any other invalid save. A profile from before these settings loads
unchanged. A build from before them knows only DuckDuckGo and Google: it refuses a profile
that selects another engine, as it would a damaged one, and preserves the file.

A private window starts with a new in-memory profile. Lite copies `search` and
`searchEngines` into it, so a private window searches with the engine the user chose. It
does not copy `searchSuggestions`.

**Suggestions.** `LTSearchSuggestionURL` decides whether anything may be sent. It returns
nothing unless `searchSuggestions` is on and the selected engine has a suggestions
address, and nothing for text that is:

- empty, longer than 256 characters, or more than one line;
- an address the Command Bar would open, such as `example.org/path` or `localhost:3000`;
- an address still being typed, meaning text without spaces that contains `:/`.

The Command Bar opens on the current page's address when it is used as the address bar,
so the page address is covered by the second rule. A partly typed host such as "gith" is
a search like any other and is sent. A private window has no fetcher at all, so the
setting cannot turn suggestions on there.

Each window that is not private creates one `LTSearchSuggestions` the first time its
Command Bar opens with suggestions on, and keeps it, so the connection to the engine is
reused. It waits
until typing has paused for 150 ms, cancels the previous request, and sends a GET with no
cookies, no credentials and no cache. It does not follow redirects, which would pass the
text to a host the user did not choose. The engine receives the text, and with it the
Mac's IP address, its language preference in `Accept-Language`, and `Lite-Browser` as the
user agent. A request ends after 4 seconds without an answer.

The answer must be OpenSearch suggestions JSON, `["query", ["one", "two"]]`, of at most
64 KiB. Lite keeps the first four entries that are single-line strings of at most 200
characters, dropping the typed text itself and repeats. Anything else, such as an error
page, gives no suggestions. Answers are remembered in memory while the Command Bar is
open and forgotten when it closes. Nothing about suggestions is written to disk.

Suggestions are listed directly under "Search for …", so the first row, which Return
opens, never changes when they arrive. If another row is selected when they arrive, it
stays selected. While the engine is being asked again, earlier suggestions that still
begin with the typed text stay listed. Choosing a suggestion searches for it with the
selected engine.

### Data export

`LTExporter` writes the committed sidebar in two formats. Export Bookmarks… and Export
Organization… are in the Library menu, Settings and the Command Bar. Each asks for a file
with a save panel, then builds and writes it atomically on a background queue from the
profile as last committed, which is never changed once published. A failed write shows an
alert. A private window refuses to export, because its sidebar is a temporary one of its own
and exporting it would look like the user's bookmarks were missing.

Both formats contain Favorites and, for each Space in order, its folders and pinned tabs in
sidebar order. A pinned tab is written with the address it was pinned at, not the page it has
since navigated to. Neither contains temporary tabs, which are open pages rather than saved
ones, history, recently closed items, window state, favicons, item identifiers or settings
other than Space colors. A GitHub Live Folder is written as an ordinary folder of the pull
requests it held, without its account or repository settings.

**Bookmarks file.** A Netscape bookmarks file, the HTML format that Safari, Chrome, Firefox
and Lite's own HTML import read. Favorites come first, as a folder marked
`PERSONAL_TOOLBAR_FOLDER` so Chrome and Firefox put them on the bookmarks bar, followed by
one folder per Space. Each tab uses the name the sidebar shows. Names and addresses escape
`& < > " '`. Empty folders are kept.

**Organization file.** JSON for moving a sidebar between Lite profiles:

```json
{
  "format": "lite-organization",
  "version": 1,
  "exported": "2026-11-10T00:00:00Z",
  "favorites": [{"title": "Example", "url": "https://example.com/", "customTitle": "Mine"}],
  "spaces": [{
    "name": "Work",
    "theme": "Graphite",
    "items": [
      {"type": "folder", "title": "Reading", "open": false, "items": [
        {"type": "tab", "title": "Docs", "url": "https://docs.example/"}
      ]}
    ]
  }]
}
```

`theme` appears only for a color the user chose, and `customTitle` only for a renamed tab.
Folders nest, so the file cannot describe a cycle or an item with two parents. Keys are
sorted, so the same sidebar always writes the same file.

Import Bookmarks… recognizes the file by its `format` and passes it to
`+[LTImporter parseOrganization:error:]`. As with the other imports, the user sees a preview
first, and the result is added as new Spaces with new identifiers; nothing already in the
profile is replaced. Favorites are added after the existing ones, and the colors of the new
Spaces are added to `spaceThemes`. A tab whose address Lite cannot open, such as
`javascript:` or one with a user name, is skipped and the preview says how many were. Any
other problem imports nothing: a missing format marker, a version newer than this build
reads, a file over 64 MB, no Spaces, an unknown item type, a field of the wrong type, folders
nested more than 64 deep, or more than 100,000 items. The result must then pass the profile
validator like any save. Items are created directly in file order rather than through
`addNode`, which scans its siblings, so import time grows linearly: in `LiteExportTests`,
10,000 tabs in 500 folders took 23 ms to export in both formats and 53 ms to read back on
Apple Silicon.

### Background writer

Each store has one serial writer queue. Organization saves, visit recording, history
deletion and recovery backups all run on it, so they reach the database in the order
they were made. Copying, validating, serializing and committing all happen there.

`commit:completion:` queues a save and returns at once. Its change block runs later, on
the writer, against a copy of the last committed model, so it can touch only that copy
and immutable values captured beforehand. It must not read `self`, AppKit objects or
pages. Whatever a block captured is released on the main thread.

`store.profile` holds committed state only. It changes on the main thread after
`COMMIT` succeeds, so code must not expect to read a queued save back straight away.
Work that needs the saved result goes in the completion, which runs on the main thread
after the model updates, in submission order. Writes that finish together post one
`LTStoreChanged`. A save that the writing window has already drawn, such as a page
title, names that window with `quietFor:` so it can skip its redraw.

History reads use a second, read-only connection. WAL lets them see the last commit
while the writer is inside the next one, so the Command Bar never waits on a save. They
do not show a visit that is still queued.

`commit:error:` remains for launch and quit. It blocks until that save and everything
queued before it finish, which costs a full save on the main thread.

A published model is read-only, because the writer reads it to start the next save while the
main thread reads it to draw. The writer seals each model before publishing it, which builds
lookups for `node:` and `childrenInSpace:` so they cost the main thread nothing. Sealing is why
a model must never be changed after it is published.

**When a queued write fails.** The user may already have moved on, so a failure has to
be safe at any later point:

- The failed write is dropped. SQLite rolls back, and the model stays at the last commit.
- Writes queued behind it still run. Each starts from the last commit, not from the
  dropped write, and is validated on its own, so one that depended on the dropped write
  either has no effect or fails validation by itself.
- Nothing is retried. A failing disk would fail again, and a change block may not be safe
  to run twice.
- `LTStoreChanged` is posted anyway, so windows redraw from the committed model. A tab that
  was closed comes back as an unloaded row, and a row that was added disappears.
- The user gets one alert for a burst of failures, saying the unsaved change was undone. A
  caller that passes a completion can handle the error itself: moving a tab shows its own
  alert, and the Shortcuts panel shows the error inline.
- Window layout saves and visit recording only log. They run constantly in the background,
  and an alert for each would be noise.

**Quit and crash.** Quitting finishes the queue, then saves window state and waits. If that
save fails, or an earlier queued write fails, the quit stops with every page open, as a
failed window save always has. After Chromium shuts down, `close` finishes anything pages
wrote while closing, checkpoints the WAL and refuses further writes. It runs before the
profile lock is released, so a new instance can never open a profile that still has writes
in progress.

A crash loses only what was still queued, normally a single save. Writes commit one at a
time and in order, so the database is always a clean prefix of what was submitted, and WAL
recovery on the next launch needs nothing from the app.

Pinned URL and current navigated URL are distinct. Custom titles are distinct from
page titles. Node IDs are stable UUIDs, independent of Arc IDs. Folder parent/Space
relationships, cycles, duplicates, selected tabs, and URLs are validated together.
Temporary tabs are a distinct node kind; history is a separate indexed SQL table
(see [History](#history)).
Private windows use an in-memory Lite store and a separate CEF off-record context.

Normal profiles live in `~/Library/Application Support/Lite/`:

```text
Lite.sqlite                # organization, window metadata, Lite history
Lite.sqlite-wal / -shm     # SQLite WAL files while running
Chromium/Default/          # normal Chromium profile/storage
Favicons/                  # bounded PNG favicon cache, shared by site origin
Chromium/pending/           # crash reports, kept 7 days at most
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
credential files or SQLite password fields. Crash reports are the exception to look out
for: they are memory snapshots, so one could hold a value that was in memory at the
crash. See [crash reporting](crash-reporting.md). Interrupted writes can leave encrypted
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
