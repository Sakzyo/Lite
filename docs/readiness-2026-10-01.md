# Production-readiness work — 1 October 2026

Status: **development build; production release gates remain open**. Work extends
the existing AppKit/CEF checkout. No extension loader, sync service, PWA installer,
DRM integration, new UI framework or permanent background service was added.

## Environment and evidence discipline

Local machine: Mac16,12, arm64, 32 GiB RAM, macOS 26.5.2. Release CMake build,
CEF 154.0.23 / Chromium 154.0.8037.17. Only disposable profiles, synthetic login
credentials and loopback fixtures were used for automated tests. Browser tests
use mock Keychain and ephemeral certificate pins only in their test process.
The combined audio/video fixture uses Chromium's fake devices while retaining
Lite's actual Allow/Deny sheet; it does not auto-grant access or change TCC.
The ordinary application does not add those switches or disable the sandbox.

The unchanged baseline passed 48 Chromium checks. Its native-window, command-bar
and Settings screenshots are saved in
`test-results/readiness-2026-10-01/baseline/`. Baseline engine results and the
same-machine native-process measurements are in that directory too. Current
verification logs are under `test-results/release/` and the dated directory.
Uncompleted or unavailable tests below are not passes.

## Completed local verification

The final packaged application passed **95/95 Chromium integration checks** in
79.48 seconds, including two restart phases, and **35/35 actual native-window
checks** in 12.72 seconds. Both suites verified graceful application exit.
`test-results/release/engine-final-artifact.json` identifies the tested executable.
The Release build, all seven CTest targets, 11 SDK/update Python tests, five
packaging tests, seven endurance-runner checks and strict ad-hoc signature
verification pass. Hosted CI and production-signing checks have not run.

The engine suite observes timer counts during freeze/resume, backward/forward
navigation, scroll restoration, actual browser destruction, HTTP Basic/Digest
and proxy authentication (including wrong-password retry and cancellation),
download pause/resume/cancel/interruption, and downloaded-file security xattrs.
It seeds cookies, local/session storage, IndexedDB, Cache Storage and service
workers, then checks deletion after reload and process restart. The full partition
reset also checks permission removal and preservation of an unrelated profile file.

Native coverage uses the real `LTWindow`, sidebar, command bar, Settings, Downloads,
split panes and multiple regular/private windows. Canceling native window-close
and application-quit confirmations preserves every page. Private Clear Data
tests both cancellation and replacement with an empty private context while
retaining regular-window markers. The release log directory retains actual results;
earlier fixture/build failures are not counted as passes.

## Acceptance matrix

| Requirement | Acceptance criterion | Implementation and evidence | Remaining gate |
| --- | --- | --- | --- |
| Baseline and resource budgets | Reproduce fresh-process launch, family footprint/RSS, CPU/wakeups and large-profile writes with the same fixtures | `script/measure_native.py`, `script/resource_sample.c`, baseline JSON and native screenshots; CEF 1/10/50-page workload | OS-cache-cold launch, system-wide network attribution, battery measurement and public mixed-site comparison remain distinct checks |
| SDK integrity | Wrong version/architecture/corrupt or interrupted replacement never becomes usable | `fetch_cef.py`, `sdk_support.py`, pinned archive hashes, file-manifest receipts; `test_updates.py` | Track new upstream releases and update reviewed pins routinely |
| Authenticated app updates | Verify publisher authenticity before extraction; reject downgrade, architecture or schema mismatch; complete compatible bundle | Pinned Sparkle 2.10.0; signed feed and Ed25519 archive verification; `LiteUpdateTests` and real signature/tamper tests | Publisher keys, hosted signed feed, Developer ID bundles, end-to-end interrupted installation and signed upgrade recovery |
| Production distribution | Inside-out Developer ID signing, appropriate CEF entitlements, notarization, staple and verify extracted final artifact | `package.py --production`, `resources/entitlements/`, `test_package.py`; local ad-hoc path retained | No valid Developer ID identity is configured; Apple Developer/notary credentials required. Production runtime entitlements still need signed execution on each architecture |
| Keychain continuity | Existing synthetic vault and encrypted cookies survive two signed upgrades without authorization weakening | Vault regressions use injected synthetic key material; bundle ID and vault namespace unchanged; CEF encryption retained | A pair of production signed builds and a disposable macOS account are required to qualify real Chromium Safe Storage continuity. This CEF SDK has no supported Lite-specific namespace setting |
| Permissions | Exact origin and all requested bits; denial for unsupported capabilities; no callback survives cancellation or navigation; inspect/revoke grants | Native prompts expose exact origin/all bits; notifications grant/revoke/restart checks; combined fake audio/video denial, grant, track stop and navigation/closure cancellation; explicit screen-source limitation | Real macOS camera/microphone/location authorization and spoken VoiceOver still need hardware/user verification |
| Website-data deletion | Seed storage, clear, reload/restart, verify absence; keep organization/passwords and private separation | Per-origin engine completion callbacks; full Chromium partition reset before CEF initialization; `LiteWebsiteDataTests`; error-returning history deletion and backup sanitization | Full signed-build end-to-end restart qualification and all embedded/partitioned third-party storage variants |
| Sessions and discard | Preserve real history and work; release eligible browser instances; never replay POST or store sensitive forms | Protects multi-entry/POST, history.state, sessionStorage, observed interaction and media; bounded scroll metadata for eligible pages; real navigation/freeze/discard tests | CEF cannot import serialized navigation entries. Complete history across application restart and arbitrary unobserved JavaScript state remain unsupported; release gate stays open |
| Profile recovery | Malformed fields cause NSError recovery, preserve originals, keep bounded known-good backups, survive failed writes | `LiteProfileTests`, explicit Restore Backup UI, SQLite FULL transactions, two backups and three preserved-original limit; profile benchmark | 10,000-node writes still synchronously occupy the main thread for tens of milliseconds; no claim of stall-free unlimited profiles |
| HTTP/proxy authentication | Actual Basic/Digest/proxy challenge succeeds, cancel/navigation/closure cancels callback, private credentials stay separate | CEF auth callback and native secure password field, synthetic local challenge fixtures | Real enterprise proxy policy, multi-step external accounts and platform SSO remain unqualified |
| Downloads and popups | Accurate terminal/interrupted states, bounded regular history across windows/restart, private history ephemeral, verify quarantine | Engine pause/resume/cancel, deliberate truncated-response interruption, duplicate-file preservation and real quarantine/WhereFroms xattrs; `LTDownloadHistory` persistence/retention tests; existing Downloads surface and popup origin/security/private title | Physical disk-exhaustion and native Save As qualification, account-bound OAuth popups and production Gatekeeper execution |
| Automated release gate | Release compile + core/vault/blocking/profile/updater/storage/download tests + separate engine/native suites + artifact verification | `script/verify_release.sh`; `.github/workflows/release-verification.yml` | Hosted CI jobs have not been run from this checkout; local success is not remote-CI evidence |
| Native UI and accessibility | Test actual sidebar, command bar, settings/downloads, both split-focus directions, close cancellation and private windows | `LTNativeSmoke`, `test_native.py`, native screenshots; existing AppKit styling retained | Physical drag/drop edge cases, full VoiceOver spoken output, Full Keyboard Access system mode, all scaling/contrast configurations |
| Compatibility and endurance | Supported macOS/CPU matrix, real login/OAuth/test payments/media/capture, sleep/wake/network/disk/upgrade and long sessions | Available arm64/macOS 26.5.2 fixture runs; bounded repeatable stress workloads | Intel hardware, macOS 14/15 hosts, sandbox accounts/payment test credentials, human TCC/VoiceOver checks and multi-hour endurance |

## Measurements

`measure_native.py` seeds 2,000 pinned nodes, lazily opens one loopback page in the
real native window, measures from `open -n` to its DOM-ready beacon, settles six
seconds, then samples the complete recursive process family for 15 seconds.
This is a fresh process/profile launch, not a reboot or filesystem-cache purge.
It measures fixture requests, not all external Chromium traffic. Other desktop
applications remained running. CPU counters are converted from Mach absolute
ticks; a separate 250 ms busy-loop calibration verified the conversion.
Process enumeration uses `proc_listchildpids`, whose return value is a PID count
in Apple's [libproc implementation](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c).

Same-method before/after samples are preserved in the checked-in
[raw measurement record](benchmarks/2026-10-01-arm64.json):

| Workload / metric | Before | After |
| --- | ---: | ---: |
| 2,000 nodes, one page: first DOM-ready | 2.900 s | 3.224 s |
| Summed physical footprint | 264.194 MiB | 280.273 MiB |
| Summed RSS | 728.766 MiB | 731.031 MiB |
| Idle CPU, one-core equivalent | 0.872% | 1.547% |
| Interrupt wakeups/s | 53.555 | 82.582 |
| Fixture requests during sample | 0 | 0 |
| Three-origin mixed: first DOM-ready | 3.156 s | 2.504 s |
| Summed physical footprint | 445.932 MiB | 470.869 MiB |
| Summed RSS | 993.188 MiB | 999.266 MiB |
| CPU, one-core equivalent (active canvas) | 3.983% | 4.523% |
| Interrupt wakeups/s | 106.413 | 154.082 |
| Fixture requests during sample | 0 | 0 |

Process counts remain six for the single-page fixture and eight for the mixed
fixture. Both updated samples exited gracefully. The mixed launch metric is the
first DOM-ready beacon; sampling begins only after all three pages are ready.
The single-page footprint rose 6.1%, startup 11.2%, CPU by 0.675 percentage points
and wakeups by 54.2%; the mixed footprint rose 5.6%. These samples do not demonstrate
a memory, CPU or battery improvement. They do not cross the provisional startup,
footprint or single-page CPU triggers below. One baseline sample cannot establish
normal variance or attribute the CPU/wakeup increase to a specific change.

The original 50-page engine workload reached 2,236.334 MiB physical footprint
(6,649.984 MiB summed RSS, 55 processes), then 303.898 MiB (778.797 MiB RSS,
six processes) after closing 49 browser instances. This workload is deliberately
simple; complex public pages must not be represented by these figures.

Twenty synchronous durable title edits with fixed synthetic profiles gave:

| Nodes | Baseline median / p95 | Updated median / p95 |
| --- | --- | --- |
| 2,000 | 17.74 / 18.74 ms | 7.97 / 8.54 ms |
| 10,000 | 89.47 / 91.51 ms | 40.91 / 43.36 ms |

The targeted changes remove redundant JSON round trips and sorted-key output;
SQLite ordering, FULL durability, transactional validation and disk-error handling
remain. Read/open time includes validation; it must not be conflated with edit
time. Physical footprint and summed RSS are different counters: RSS double-counts
shared mappings, and neither sum is a precise increase in system-wide used RAM.

Provisional regression investigation thresholds for the identical local fixture:
20% plus 50 MiB settled footprint growth, 30% plus 0.3 s launch regression,
idle CPU exceeding 3% of one core, or browser count failing to return after close.
These are investigation triggers, not universal product limits or battery claims.

## Completed bounded endurance

Three cycles completed in **349.79 seconds (5 minutes 50 seconds)** of measured
execution. All nine phases passed: each cycle ran the 95-check engine suite with
its process restarts and repeated browser creation/closure, the 35-check native
suite, and a fresh 2,000-node native measurement. Every phase ended with no leftover
application process and no forced cleanup. The journal at
`test-results/readiness-2026-10-01/endurance/run.json` binds the results to the
same final executable and verification-script hashes. Its complete metrics are
also retained in the checked-in raw measurement record.

| Repeated native sample | Physical footprint | RSS | CPU, one core | Interrupt wakeups/s |
| --- | ---: | ---: | ---: | ---: |
| Cycle 1 | 281.460 MiB | 729.656 MiB | 1.071% | 52.931 |
| Cycle 2 | 279.772 MiB | 729.453 MiB | 1.543% | 82.531 |
| Cycle 3 | 282.632 MiB | 730.594 MiB | 1.152% | 51.613 |

Every sample retained six processes and generated zero fixture requests during
the sampling interval. The fresh-process launch times were 1.768, 1.726 and 1.441
seconds, illustrating warm-cache/run variability. Within the final full engine
run, each of three 10-tab cycles returned to one browser, with summed footprints
of 354.2, 371.7 and 359.9 MiB. The native and engine workloads differ and these
figures must not be compared as one sequence.

These results show stable bounded workloads and clean closure over the measured
interval. They do not establish absence of leaks, multi-hour endurance, public-site
compatibility or battery savings. CPU/wakeup variation remains visible; the initial
before/after increase has not been attributed to a particular implementation change.

## Native appearance and platform qualification

Before/after screenshots cover the empty native window (1260 × 820), command bar
(650 × 430), and Settings (620 × 724). Visual inspection confirms the same sidebar
width, control placement, spacing, font hierarchy and command layout. Settings
changes only the factual version/distribution footer. No theme colors, fonts or
layout constants were changed. macOS vibrancy/activation and the system screen
recording indicator differ between captures, so these are not pixel-identical
golden-image tests. `native-clear-confirmation.jpg` records the new deletion
explanation using the existing native alert styling; Cancel was exercised manually.

The bundle declares macOS 14.0 as its minimum. A declared minimum and CI runner
configuration do not establish tested support:

| macOS | arm64 | x86_64 | Required qualification |
| --- | --- | --- | --- |
| 14 | Unrun; CI configured | Unrun | Actual release, native/engine suites, signed upgrade and Keychain tests |
| 15 | Unrun | Unrun; CI configured | Same tests on both architectures |
| 26.5.2 | Local Release fixture verification | Unrun | Intel host plus signed distribution checks; local hardware/TCC and accessibility checks remain open |

The mixed fixture uses three loopback origins and three real native windows:
a document page, a canvas animation and a local-storage/IndexedDB application.
It supplies repeatable mixed browser work, not coverage of public-site login,
OAuth, payment, DRM or capture compatibility. Those require explicit sandbox
accounts, test merchants and actual device authorization. Physical drag/drop,
spoken VoiceOver, system Full Keyboard Access, contrast/scaling, sleep/wake,
physical volume exhaustion and multi-hour sessions remain unrun.

## Deliberate limitations and recovery semantics

Full browsing-data deletion must restart because CEF has no public all-origins
storage eraser for inactive origins. The restart closes private windows too;
their data remains in memory only. Startup is blocked if deletion is incomplete
or another process holds the profile. Restored pages remain unloaded until the
user selects one, so storage is not immediately recreated. Bookmarks, organization,
saved passwords and download history are kept. Normal recovery backups have their
deleted history removed; explicitly preserved damaged originals remain untouched.

Generic site grants remain in the engine until revoked; camera/microphone decisions
apply to their capture request. CEF does not expose Chromium's AcceptThisTime API. Screen capture is safely denied
where the embedding cannot provide a source chooser. Site reset clears the
selected exact origin and shared HTTP cache; other open pages can keep transient
in-memory objects until reload. Website code may recreate its data after loading.
Revocation resets grants immediately and reloads the page to end existing capture.
A site's before-unload cancellation can prevent that reload and leave an existing
stream alive; closing that tab ends it. Unconditional live-stream termination on
revocation is not qualified by these tests.

Multi-page close and quit use one native aggregate confirmation before touching
any browser, because CEF's close API cannot preflight and roll back multiple
before-unload handlers. Cancel keeps every page; the explicit Close All choice
authorizes discarding unsaved work. Individual tab close still uses the site's
before-unload dialog. Complete navigation stacks cannot survive restart in this
CEF embedding; saved state does not include passwords, payment data or arbitrary
form contents.

Extension loading, Chrome Web Store integration, sync services, PWA installation
and licensed DRM remain outside scope. Automatic save/update prompts for supported
login forms and the authenticated encrypted profile vault **already exist**;
older documentation calling password storage manual-only was stale. Cross-frame
and custom forms may require explicit Library actions. No real purchases or
personal-account authentication were used for verification.

## Reproduce

```sh
./script/verify_release.sh
python3 script/measure_native.py --duration 15 --output test-results/release/native-measurement.json
python3 script/measure_native.py --mixed --nodes 30 --duration 15 --output test-results/release/mixed-native-measurement.json
python3 script/endurance.py --cycles 3 --record test-results/endurance/run.json
```

The endurance journal resumes completed phases only for the same application and
verification scripts/fixtures. Each phase uses a fresh disposable profile and
completes only after its runner exits and the exact application/profile pair has
closed. Timeout cleanup tries graceful termination before a forced stop, and a
forced stop remains a failure. Seven isolated runner regressions exercise these
cleanup and matching rules; they do not simulate physical disk failure.

Build output: `dist/Lite.app`. Production configuration is documented in
[updates and distribution](updates-and-distribution.md). Tests and local signing
do not constitute a security audit, production notarization or release approval.
