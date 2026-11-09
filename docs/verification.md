# Current verification

See the [1 October 2026 readiness record](readiness-2026-10-01.md),
[profile recovery evidence](profile-recovery.md), and
[update/distribution procedure](updates-and-distribution.md). Earlier entries below
are historical snapshots; their check counts and capability descriptions do not
supersede the current acceptance matrix.

# Verification record — 22 September 2026

## Background profile writer with media consent — 6 November 2026

- `./script/verify_release.sh` **passed**, exit code 0, on `c213bee`, which merges this work
  with stable test signing and the consent request. It was run with
  `LITE_TEST_SIGNING_IDENTITY` set. This is the first run in which the `combinedMedia*`
  checks passed: macOS reported camera and microphone `authorized`.
- Every stage passed: 9 of 9 CTest suites, update, endurance and package tests, the
  release-binary check, crash capture, 106 Chromium checks, 5 extension checks, 48
  native-window checks, `codesign --verify --deep --strict` on both bundles and
  `git diff --check`.
- The run before it failed `test_browser.py` with a timeout. Another app covered the test
  window for 520 of 688 samples. In the passing run the browser suite was never covered, and
  the native suite was covered for 10 of 158 samples.
- The fixture server logged one traceback from a client that disconnected during a 404. It
  decided no check.
- `--measure` was not used.

## Background profile writer — 5 November 2026

- `./script/verify_release.sh` **did not pass**. It stopped at the same three
  `combinedMedia*` camera and microphone consent checks as the records below. The script
  exits there, so it did not reach its extension, native, signing or `git diff --check` steps.
- Everything before that step passed: 9 of 9 CTest suites, update tests, endurance runner
  tests, package tests on each bundle, the release-binary check and `test_crash_capture.py`.
  In `test_browser.py`, the three consent checks were its only failures.
- The steps the script did not reach were run by hand and passed: 5 extension checks,
  48 native-window checks (three runs in a row), `codesign --verify --deep --strict` on both
  bundles and `git diff --check`.
- `LiteProfileTests`: **198 passed**, 47 of them new, ten runs in a row. They cover write
  ordering, a commit held open inside its fsync while the main thread keeps working, failures
  from injected disk faults, validation and raised exceptions, `close`, and a child process
  killed with SIGKILL partway through its queue, which must leave an exact prefix of its writes.
- `LiteCoreTests` with `--check-icons`: **106 passed**, including the background favicon scan.
- ThreadSanitizer reported no races across `LiteProfileTests`. It was run by hand and is not
  part of the script.
- New native check `nativeSidebarFollowsSaves` compares the real outline's rows to the model
  after each of 15 saves, covering no change, row changes, expansion and full reloads.
- **Native focus:** `test_native.py` needs window focus and port 18743 to itself. Run alongside
  another session's GUI tests, it failed focus checks and `nativeCrashUploadOnlyApprovedReport`.
  Those failures stopped when the machine was quiet.
- Measurements: [profile saves](performance.md#profile-saves).
- **Not exercised:** an alert for a failed write as a user sees it. The tests prove the
  notification is posted and the model and disk are correct, but no test shows the alert in a
  window. Also not exercised: a physically full disk, power loss, and hardware other than one
  Apple Silicon Mac.

## Crash reporting — 5 November 2026

- `./script/verify_release.sh` **did not pass**. It stopped at the same three
  `combinedMedia*` camera and microphone consent checks as the records below.
- Everything before that step passed, including 9 of 9 CTest suites (35 new crash report
  checks), 18 update tests, 8 endurance runner tests, 7 package tests on each bundle, and
  the new `test_crash_capture.py`, which crashes a sandboxed helper and requires a report.
- The steps the script did not reach were run by hand and passed: 5 extension checks,
  47 native-window checks, `codesign --verify --deep --strict` on both bundles and
  `git diff --check`.
- The native suite ran the real consent sheet against a loopback fixture. Of three
  seeded reports, the server received only the approved one, with no cookies. The
  private-run and expired reports were deleted without being offered.
- **Not exercised:** a real Sentry upload, symbol publishing, and crash capture under a
  Developer ID hardened-runtime signature. Chromium's Crashpad handler runs unsandboxed,
  as it does in Chrome; the renderer sandbox is unchanged.

## Lifecycle plumbing hidden from pages — 5 November 2026

- `./script/verify_release.sh` **did not pass**. It stopped at the same three
  `combinedMedia*` camera and microphone consent checks as the records below.
- Everything before that step passed, and so did every other browser check, including
  10 new `lifecycle*` checks and `inputInteractionProtected`.
- The steps the script did not reach were run by hand and passed: 5 extension checks,
  41 native-window checks, `codesign --verify --deep --strict` on both bundles and
  `git diff --check`.
- `formProtectionSignal` and the pointer, keyboard and change interaction checks used to
  dispatch synthetic events, which is the forgery this change blocks. They now send real
  input through the Chrome DevTools Protocol, and assert the same protection.
- `/lifecycle-probe` attacks the observer from its own strict-CSP page: forged events,
  patched prototypes, a replaced `navigator`, script-raised trusted events, stack
  inspection and a non-media `<video>`. Run against weaker observers as controls, the
  original failed every related check, and the old script with only its global hidden
  still let the page protect itself and reach an internal listener.
- Login fill now raises the guard natively. No automated check covers that line.

## Test code removed from release binaries — 5 November 2026

- `./script/verify_release.sh` **did not pass**. It stopped at the same three
  `combinedMedia*` camera and microphone consent checks as the CEF 156 record below.
- Everything before that step passed, including 8 of 8 CTest suites, 6 package tests
  on each bundle, and the new runtime check of the release bundle. All other browser
  checks passed against `dist/LiteTest.app`.
- The steps the script did not reach were run by hand and passed: 5 extension checks,
  41 native-window checks, `codesign --verify --deep --strict` on both bundles and
  `git diff --check`.
- `nm` found no smoke or `ForTesting` symbols in the release executable, and 275 in
  the test executable. As a control, the runtime check fails when pointed at the test
  bundle. `LITE_PROFILE_DIR` stays in release builds because it is not test-only.

## CEF 156 update — 5 November 2026

Run on Apple Silicon with macOS 26.5.2, moving from CEF 154.0.23 to
156.0.15+gcf671c0+chromium-156.0.8078.80. Both archives matched the digests in the CEF
release index. The Intel archive's header and framework architecture were inspected;
it was not built or run.

- `./script/verify_release.sh` **did not pass**: it stopped at `test_browser.py` on
  `combinedMediaGranted`, `combinedMediaProtected` and `combinedMediaStopped`. These
  need macOS camera and microphone consent for the exact ad hoc build, which an
  unattended run cannot give. The same three checks failed on CEF 154 in every run.
- Everything before that step passed: 8 of 8 CTest suites, 17 update tests, 7 endurance
  runner tests, 5 package tests, and all other browser checks.
- The steps the script did not reach were run by hand and passed: 5 extension checks,
  41 native-window checks, `codesign --verify --deep --strict` and `git diff --check`.
- Two unrelated flakes appeared on the unmodified CEF 154 build. `backgroundResume`
  failed 1 of 4 browser runs. `nativeCommandShortcutAndNames` and `nativeCommandEscape`
  failed 2 of 3 native runs while another application was frontmost.
- Performance measurements were not repeated, so [performance](performance.md) still
  describes CEF 154.

## Developer Tools crash and YouTube follow-up — 27 September 2026

- The supplied incident `66A846B1-E073-41C2-9F99-1B9C65CA302C` is the earlier
  `EXC_BAD_ACCESS` at address `0x10` in `-[LTPage showDevTools]`: the regular
  page client was constructed with a nil page. Developer Tools now has a dedicated
  lifecycle-only CEF client, with no page/policy dereferences. The automated browser
  test opens it, opens it again to check window reuse, closes it, verifies browser
  cleanup, and evaluates JavaScript in the surviving parent page.
- The native filter now also handles escaped keys in serialized player-response
  objects. The bundled player fallback covers visible/reused skip buttons,
  distinct finite client-ad media, and explicit `SSAP, AD` markers. Negative
  fixtures protect ordinary/unknown/live media, hidden controls, stale ad classes,
  and the user's volume and playback speed.
- `./script/build_and_run.sh --verify` passed: **98 core checks**, **70 blocking
  checks**, two packaging checks, signing, and launch. All **44 bundled Chromium
  checks** passed, including strict-CSP fixtures, gzip and serialized JSON,
  in-page player replacement, site/global pause, immediate pause/resume without
  navigation, cosmetic independence, private-context isolation, and the crash
  regression. Logs: `.build/crash-youtube-final-build.log` and
  `.build/crash-youtube-full-browser.log`.
- The supplied [video](https://www.youtube.com/watch?v=GoHmHA37Sbg) was checked
  in a signed-out private window. The main film reached its opening scene with
  no visible pre-roll and advanced beyond 1:05 of the 8:01 video; Developer Tools
  opened without the reported crash. Media
  requests initially showed HTTP 403/connection-reset errors before playback
  began. This single visit does not establish whether an ad was offered or cover
  every account, server variant, or future YouTube player change.

## YouTube pre-roll filtering — 27 September 2026

- `./script/build_and_run.sh --verify` passed Release compilation, 98 core checks,
  66 content-blocking checks, both packaging checks, and ad-hoc signature validation.
- All 41 bundled Chromium checks passed in a disposable profile. The new YouTube
  cases cover the initial inline player response, compressed Fetch/XHR responses,
  in-page video changes, ordinary video data and unrelated API preservation,
  incomplete final response tokens, site/global pause, cosmetic independence,
  and private-context isolation. HTTPS fixtures use a temporary key pinned only
  in the test process; the regular profile and system trust store are unchanged.
- A signed-out private-window live check loaded the official Blender Big Buck
  Bunny video and reached the film's opening frame without a visible pre-roll.
  Repeat live checks encountered `ERR_CONNECTION_CLOSED`, so this does not establish
  universal ad removal or sustained playback across accounts and server variants.
- Developer Tools exposed an existing null-page dereference in the shared CEF
  client. The constructor now handles its page-less client; opening and closing
  Developer Tools was verified after the fix. The final app remains running, and
  the disposable private window was closed.

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
- `LiteHistoryTests` (added 9 November 2026): **48 passed**, covering address-prefix
  and word-prefix history matching, frecency ranking, retention by age and URL count,
  the version 1 to 2 schema migration, private stores, and a frame-budget check of
  Command Bar queries at 100,000 URLs.
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
## Encrypted login vault verification — 2026-09-27

- `script/build_and_run.sh --build`: Release build, all three CTest suites, both
  package tests, and ad-hoc bundle signature verification passed.
- `LiteVaultTests` uses test-only injected random keys and verifies encrypted
  round-trips, encrypted origin/username/password metadata, fresh IVs, 0600/0700
  permissions, updates from independent stores, concurrent writes, canceled
  transactions, deletion, tampering with each envelope component, truncation,
  wrong/missing keys, duplicate identities, and symlink/hard-link rejection.
- `LiteTests lite/tests/fixtures --check-keychain`: **122 passed, 0 failed**, using
  only synthetic Keychain entries and disposable profiles. Includes actual vault
  key creation, save/read/update/delete, legacy migration, restart persistence,
  interrupted migration cleanup, preserving damaged data and missing-key failure.
  These tests need access to macOS Keychain outside the command sandbox.
- `script/test_browser.py`: **48 bundled Chromium checks passed**. New checks
  exercise the actual renderer-to-browser submission bridge, hidden bridge API,
  rejection of cross-site actions (including submit-button overrides), hidden and
  new-password fields, untrusted synthetic submit events, and private-window
  exclusion. Existing fill/origin and browser regressions also passed.
- Native UI in a disposable profile: a user click on a synthetic loopback login
  showed the Save sheet; Cancel created no vault. Save produced exactly one
  encrypted credential file, mode 0600 in a mode 0700 directory, with no plaintext
  test site, username or password. After quitting/relaunching, Fill Saved Login
  restored the username and masked password without submitting the form. The
  synthetic key and profile were removed afterward.

No personal passwords were inspected. Automatic prompts cover standard main-frame
login submissions; custom, embedded and multi-step flows retain the manual Save
command. This remains an ad-hoc signed local build, not a notarized release or an
independent security audit. Storage design and recovery boundaries are documented
in [architecture.md](architecture.md).
