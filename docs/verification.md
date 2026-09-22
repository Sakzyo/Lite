# Verification record — 22 September 2026

## Bluetooth privacy crash fix

- The supplied crash report identified a macOS TCC abort caused by a missing
  `NSBluetoothAlwaysUsageDescription` in Lite's bundle metadata. Added the purpose
  string for Bluetooth website features, including nearby-device passkey sign-in.
- `python3 script/test_package.py` reproduced the missing key in both the source
  plist and existing app. Packaging now runs this regression check automatically;
  both plists must contain a nonempty string.
- `./script/build_and_run.sh --verify` passed Release build, all 98 core checks,
  the new packaging check, and ad-hoc signature validation. The updated app launched
  and displayed the restored sign-in page. Hardware Bluetooth access and completed
  passkey authentication were not exercised.

## GitHub, task manager, shortcuts, Keychain, and Find update

- Release build, CTest, packaging, and ad-hoc signature validation passed.
- **98 core checks passed**. Additional cases cover shortcut normalization and
  modified Tab/Return, GitHub query validation, draft/review/assignee filters,
  incomplete-result rejection, stable tab identities, preserving custom titles and
  ordinary bookmarks, retaining open closed-PR tabs, and removing stale configuration.
- **114 checks passed with `--check-keychain`**, including synthetic existing
  Internet-password lookup, selected-entry retrieval, host/port rejection, separate
  GitHub token storage, and deletion of all synthetic test entries.
- **30 bundled Chromium checks passed**, including task enumeration, real resource
  measurements, rejection of browser-process termination, ending a test renderer,
  reloading it successfully, and the existing six credential-fill safety checks.
- A separately identified app copy and disposable profile verified the native UI:
  a public `cli/cli` Live Folder fetched 63 open PRs without a token and restored
  collapsed on restart; the persisted configuration was inspected.
  Private GitHub accounts/tokens were not used for live-network verification.
- Shortcut recording rejected a conflicting Command-T, accepted Option-Command-M
  for Task Manager, and preserved that binding after relaunch. Browser commands
  worked while a website input was focused. Task Manager showed changing CPU/memory
  values, sorted by memory, kept selection across refresh, confirmed termination,
  and removed the ended renderer from its list.
- The native Keychain picker filled a synthetic local login without submitting it;
  the test entry was deleted. The close button, search cancel button, and Escape
  dismissed Find. Keyboard deletion cleared its query without dismissing the bar.
- No personal passwords or private GitHub data were used. Apple Passwords/iCloud
  vault access remains subject to macOS API/access-group restrictions; this is not
  a full iCloud Passwords integration or a security audit.

## Automated checks

- `./script/build_and_run.sh --build`: Release compilation, CTest, packaging,
  and local ad-hoc signing passed on Apple Silicon/macOS 26.5.2.
- `LiteTests`: **80 passed, 0 failed**, covering organization, nested moves,
  cycle rejection, ordering, persisted split state, transactional rejection,
  SQLite reopen, private history, URL handling, Command Bar ranking, lifecycle
  policy, malformed imports, three Arc schema fixtures, and a 2,000-pin import.
- With the loopback fixture server running, `LiteTests lite/tests/fixtures
  --check-icons --check-keychain`: **91 passed**. Additional coverage includes
  startup folder collapse, cached icons after restart, bounded HTML discovery,
  oversized response/pixel-dimension rejection, and real Keychain save/read/update/delete with
  synthetic credentials and separate profile namespaces. Test entries were deleted.
- Command Bar regressions cover strict title/URL matching, partial and fuzzy
  match exclusion, direct opening of typed web addresses (including bare domains,
  local addresses, paths, queries and fragments), search precedence for ordinary
  text, literal query encoding, and old exact history entries beyond the recent limit.
- `python3 script/test_browser.py`: **25 passed**, using real bundled Chromium
  for DOM, JavaScript fetch, cookies, IndexedDB, WebAssembly, WebGL2, navigation,
  independent pages, private isolation, edited-form protection, freezing,
  discard, and restoration. Login checks exercise the actual fill scripts with
  synthetic data: filling without submission and rejecting a different origin,
  cross-site form action, hidden password field, and password-creation field.
  The test process also exited gracefully.
- The same 19 checks passed after `ditto` copied the complete application to a
  temporary directory outside the project. All bundle symlinks resolved inside
  the copied bundle. `otool -L` showed system dependencies for the host; CEF is
  loaded from the embedded Frameworks directory.
- `codesign --verify --deep --strict` passed for both bundles. This is integrity
  validation of an ad-hoc signature, not notarization.
- Python syntax, shell syntax, and authored-source whitespace checks passed.

## Native UI checks performed

- Startup/login update: an isolated copied app displayed icons for an unopened
  Favorite and a nested bookmark. Both folders started collapsed, including after
  expanding them and restarting. The native Save Login sheet captured a synthetic
  form; after relaunch, Fill Saved Login restored its username and masked password
  while the page still reported “Not submitted.” Manage Saved Logins deleted the
  test entry and subsequently showed an empty list. Private-window access was
  refused with a clear explanation.
- Direct-link update: typed a new loopback HTTP URL into the Command Bar and
  pressed Return. Open address was selected first, and Chromium loaded that
  exact URL, including its query string, in a new tab.
- Command Bar update: an empty field and typed partial/exact titles were checked
  in the running app. The search icon has a separate layout column; a partial
  title selects Search, and its full title selects the existing tab. Sidebar
  reveal/hide and pin/collapse transitions were exercised with page content
  remaining usable and no residual divider after the animation.
- Sidebar update: the rebuilt main window and Mini Lite were checked in a
  separate, synthetic profile. Pages fill the window vertically, navigation
  lives in the sidebar, and collapsing removes the divider and window controls.
  Moving from the page to the left edge revealed the sidebar over unchanged
  page geometry; leaving it hid the sidebar, and page navigation still worked.
  Native window zoom and sidebar restoration on relaunch were also exercised.
- Actual public HTTPS content and loopback HTML rendered visibly in AppKit windows.
- Command Bar URL/tab selection worked; two independently interactive pages were
  visible together; dragging the split divider resized both pages; changing focus
  updated navigation without swapping panes.
- Sidebar folder collapse/expand was exercised after fixing a synchronous outline
  reload during collapse. Expansion-state commits are deferred until AppKit ends
  its outline update.
- Native Save completed a synthetic download. The downloaded file contained the
  expected `lite-ok` payload and Downloads displayed completion.
- Chromium DevTools opened and exposed the actual page DOM and styles.
- A private window opened with separate organization. Cookie/local-storage
  isolation was checked by the engine harness.
- An external URL opened in Mini Lite. Promotion placed the page in the selected
  Research Space and persisted that selection.
- A local canvas-stream video played, exposed native media actions, and entered
  Chromium PiP. The page reported “Playing in picture-in-picture.”

## Limits of this evidence

These checks are not the full production acceptance suite. Real Keychain access
can require user authorization after ad-hoc rebuilds; the disposable automated
profiles use Chromium's mock Keychain for cookie encryption. The new login-store
checks use real Keychain items in isolated namespaces. The normal application preserves encrypted
storage and does not enable that switch. Hardware camera/microphone permissions,
real login/payment sites, licensed DRM, long-running media, every drag/drop case,
VoiceOver, Intel hardware, older supported macOS versions, crash/power-loss and
disk-full recovery, energy use, and baseline-browser comparisons remain release
qualification work. See [release status](release-status.md) and
[performance methodology](performance.md).

## Native uBOL filtering — 22–23 September 2026

- Canonical build and ad-hoc bundle signing passed. All 98 existing core checks
  and 50 new content-blocking checks passed, plus both packaging checks.
- All 36 bundled Chromium checks passed in an isolated profile, including the
  original navigation, storage, lifecycle, login-fill, and task-manager checks.
- Real upstream filters stopped direct and redirected tracker requests before
  they reached the loopback server. Service-worker fetches were also blocked.
  Allowed content remained accessible; site/global pause restored requests and
  cosmetic content, and re-enabling restored blocking. Private-context filtering
  remained enabled while the regular context was paused.
- Cosmetic hiding passed with `style-src 'none'`, including elements inserted
  after page load. The native sheet and sidebar were visually checked in a
  separate signed app/profile. Its pause/apply/reload/re-enable flow was exercised
  through the UI; no top bar was added.
- Indexed matching of 10,000 benign synthetic requests took approximately 0.12 s
  on this Mac. This is a focused matcher measurement, not a browsing benchmark.
- Scope, skipped-rule categories, pinned versions, and licensing are documented
  in [content blocking](content-blocking.md). Filter resources add about 8.2 MiB
  to the bundle, including the compressed upstream input sources.
