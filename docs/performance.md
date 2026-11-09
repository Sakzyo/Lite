# Performance policy and measurements

Lite restores its SQLite organization first. Only the selected page (and a
restored second split pane) creates a Chromium browser. Other tabs remain small
native metadata objects until selected. Sidebar rows are native reusable views;
the browser chrome does not run in a web renderer.

Favicons use 32-pixel thumbnails and an `NSCache` budget of 4 MiB / 1,024 images.
The startup fetch queue has four requests at most, 512 KiB image-response limits,
a 128 KiB HTML-head limit, and a one-megapixel source-image limit. It neither
opens Chromium pages nor sends browser cookies or saved credentials. Cached icons
are available offline; missing or 30-day-old entries refresh in the background.
The disk cache is periodically pruned from a 64 MiB threshold to 48 MiB. These
are cache budgets, not measurements of the app's total memory consumption.

The policy checks every 30 seconds, with 10 seconds of timer tolerance, and also
responds to macOS memory pressure. Thresholds are measured since a page was last
visible:

| Mode | Freeze after | Discard after |
| --- | ---: | ---: |
| Balanced | 5 minutes | 30 minutes |
| Efficient (default) | 2 minutes | 10 minutes |
| Maximum Saving | 30 seconds | 3 minutes |

Visible split panes, loading pages, pages with possible unsaved work, playing media, camera/microphone
capture, downloads, PiP, closing pages, and Keep Awake tabs are protected. Memory
pressure can discard only otherwise eligible pages immediately. A website's before-unload objection
cancels an automatic discard and protects the page. Freeze uses Chromium's page
lifecycle API; discard closes the actual Chromium browser instance. Selecting a
discarded tab creates it again using its saved URL and normal cookie context.
The engine has no navigation-stack import API. Multi-entry and POST tabs, pages
with history state or session storage, and pages with user interactions that may
change application state remain protected. Eligible
single-entry pages preserve bounded scroll coordinates; arbitrary form contents
are never serialized. Actual timer freeze/resume and resource release are checked
by the current integration suite, rather than only inspecting local flags.

## Measured on 22 September 2026

Apple Silicon, macOS 26.5.2, 32 GiB RAM; Release build, bundled CEF 154.0.23,
Chromium 154.0.8037.17. Raw results: [arm64 JSON](benchmarks/2026-09-22-arm64.json).

| State | Chromium process family | Summed physical footprint | Summed RSS |
| --- | ---: | ---: | ---: |
| 1 loaded page | 6 processes | 207 MiB | 640 MiB |
| 10 loaded pages | 16 processes | 648 MiB | 1,675 MiB |
| 50 loaded pages | 56 processes | 2,177 MiB | 6,302 MiB |
| 49 discarded, 1 retained | 6 processes | 258 MiB | 713 MiB |

Closing 49 background browser instances reduced the measured physical footprint
by approximately 88%. RSS sums include shared mappings more than once and are not
a measure of unique RAM consumption. Physical footprint is summed from macOS
`proc_pid_rusage` for the app and its recursively enumerated children; it also
should not be interpreted as an exact increase in system free memory.

The 5-second idle CPU sample after a 6-second settling period was **2.15% of one
CPU core** across the process family. This short run does not establish sustained
near-zero idle CPU or battery life. The harness itself ticks at 5 Hz. Initial
page readiness was 0.48 seconds measured from harness startup, **excluding**
process launch and CEF initialization; it is not a cold application launch time.

## Reproduce and interpret

```sh
./script/build_and_run.sh --build
python3 script/test_browser.py
```

The harness uses 50 small, same-origin loopback pages, a fresh disposable profile,
and Chromium's mock Keychain switch **only for synthetic test data**. It checks
25 real-engine behaviors, including six login-fill checks, and loads 1/10/50 pages
and closes 49 of them. The
measurement verifies resource release through the same browser-close mechanism
used by discard; it does not wait for the policy's minute-scale deadlines.
The separately tested policy selects those actions and enforces protection rules.

Normal Lite launches do not enable a mock Keychain. These tests do not validate
real Keychain authorization or encrypted-cookie recovery across re-signing.

There is no controlled Arc/Chrome comparison yet. This workload is not equivalent
to 50 complex production websites, background video, calls, or extension-heavy
sessions. Upstream Chromium can initiate its own service traffic; Lite's disabled
optional background switches are not a guarantee of zero engine background work.
Remaining qualification includes long idle runs, mixed-site workloads, multiple
Spaces, media/capture, pressure testing, cold launch, energy use, and equivalent
baseline browsers on the same hardware.

## Profile saves

Profile writes run on a [serial background writer](architecture.md#background-writer), so
a save costs the main thread about 0.02 ms however large the profile is. The budget is
16.7 ms, one frame at 60 Hz. Measured on 5 November 2026 on Apple Silicon with 10 cores and
32 GiB RAM, macOS 26.5.2, Release builds. Raw results:
[arm64 JSON](benchmarks/2026-11-05-profile-saves-arm64.json).

Each table counts periods when the main thread could not have drawn or handled input.

**The store alone.** 40 saves, 100 ms apart, of 10,000 nodes, with no UI attached. Figures
are from three alternating before and after runs.

| | Before | After |
| ---: | ---: | ---: |
| Main-thread time per save, median | 44.1 ms | 0.009 ms |
| Largest main-thread gap | 56 to 59 ms | 2.9 to 3.2 ms |
| Saves that missed the budget | 39 of 40 | 0 of 40 |
| Time until the save is durable, median | 44.1 ms | 46 ms |

A save takes as long to become durable as it did. It no longer holds the main thread while
it does. Copying the model takes 1.2 ms of a 10,000-node save, validating 22 ms and
serializing 16 ms, which is why all of it moved and not only the SQLite commit.

**The running app.** `LiteTest.app` with a real window, 12 saves of each kind, 300 ms apart.
A quiet save changes a page title. A rename changes a row. A tab change adds or removes one.
Each figure is the number of gaps over budget, then the largest gap.

| Nodes | Build | Quiet | Rename | Tab change | Launch to first page |
| ---: | --- | ---: | ---: | ---: | ---: |
| 2,000 | Before | 11, 44 ms | 15, 439 ms | 15, 440 ms | 1.5 s |
| 2,000 | After | 0, 3.8 ms | 0, 6.1 ms | 0, 7.9 ms | 1.3 s |
| 10,000 | Before | not measurable | not measurable | not measurable | over 240 s |
| 10,000 | After | 0 to 2, 2.5 to 22.7 ms | 0, 4.6 to 4.8 ms | 0, 5.7 to 5.8 ms | 0.8 to 1.1 s |

The earlier build never loaded its first page at 10,000 nodes within 240 seconds, so saves
could not be measured there. The 10,000-node row above covers three runs. Two gaps in
one quiet window were over budget. The probe records everything on the main thread during
that window, not only saves, and that one was not traced to a cause. The largest gap in every
rename and tab-change window was within budget.

Moving writes alone did not meet the goal. With only the writer in place, a rename at 10,000
nodes still froze the app, because redrawing the sidebar took 7.9 seconds and launch took 20.
Three more changes were needed:

- The sidebar sorted the whole list once for every row, which is quadratic. It now uses
  lookups that the writer builds before it publishes a model. `refresh` at 10,000 nodes went
  from 7,878 ms to 0.4 ms.
- The sidebar now changes only what a save changed: nothing when no row's content differs,
  one row when one row came or went, and only the visible rows whose content differs.
- The favicon scan ran over every URL on the main thread after each save. It now runs in the
  background.

### What is still slow

- **Changes that reload the whole sidebar** still walk every row, which was about 50 ms at
  10,000 nodes in one Space. These are switching Spaces, reordering rows, moving or deleting a
  folder that has children, a change of more than 64 rows such as an import, and Pinned
  becoming empty or no longer empty. A GitHub Live Folder refresh that reorders its rows is
  one of these.
- **Opening a profile** still validates it on the main thread: 74 ms at 10,000 nodes.
- **Quitting** waits for the queue and for one last save on the main thread, by design.
- These figures come from one machine. Older hardware, a slow disk, a physically full volume
  and power loss have not been measured.

### Reproduce

```sh
clang -O3 -DNDEBUG -fobjc-arc -framework Foundation -framework Security \
  script/profile_benchmark.m .build/libLiteCore.a -lsqlite3 -o /private/tmp/lite-profile-benchmark
/private/tmp/lite-profile-benchmark
python3 script/package.py --test
python3 script/measure_native.py --nodes 10000 --duration 2 --save-probe --output /private/tmp/saves.json
```

The benchmark also compiles against the earlier synchronous store. The "before" app figures
came from the starting commit with the same probe added, using its synchronous API.

## History search

The Command Bar queries history on the main thread for every keystroke, so a query has to fit
in one frame: 16.7 ms at 60 Hz. `LiteHistoryTests` seeds 100,000 URLs, the retention cap, and
fails if the median of any of 14 typed queries, plus ranking the results, goes over that.
Measured on 9 November 2026 on an Apple M4 with 10 cores and 32 GiB RAM, macOS 26.5.2,
Release build, 25 warm runs per query. Raw results:
[arm64 JSON](benchmarks/2026-11-09-history-search-arm64.json).

| Typed | Results | Median | Slowest run |
| --- | ---: | ---: | ---: |
| `g` | 30 | 0.79 ms | 0.94 ms |
| `gi` | 30 | 0.60 ms | 0.64 ms |
| `gith` | 30 | 0.95 ms | 1.07 ms |
| `news` | 30 | 0.51 ms | 0.54 ms |
| `the` | 30 | 1.25 ms | 1.33 ms |
| `swift g` | 30 | 0.36 ms | 0.38 ms |
| `swift guide rel` | 30 | 2.07 ms | 2.11 ms |
| `pull request` | 30 | 1.27 ms | 1.33 ms |
| `zzzz` | 0 | 0.72 ms | 0.74 ms |

The rows are synthetic: hosts, paths and titles drawn from a fixed vocabulary of about 30
words, so a common word starts a word in about one row in six, and short prefixes match far
more rows than most real histories would. The first query plan took 47 ms for `g` in an
early Python harness on the same data. Four choices got there:

- **Common words scan frecent rows first.** FTS5 has to visit every row a word matches before
  it can rank them, and reading the index for `the` alone took 2.4 ms on this machine. So a
  word search first scans the 2,000 most frecent rows in rank order, checking each row's
  `words`. If 30 of them match, they are exactly the 30 best; only rarer words, which the
  index finds cheaply, go to FTS5. The two agree because both read the same `words` column.
- Each kind of match returns at most 30 rows in frecency order before they are merged, so the
  final sort sees a few dozen rows rather than every match.
- The address index includes `rank`, so an address match never reads the table.
- The read-only connection maps the database file instead of copying pages into SQLite's
  8 MB cache, which matters once history is larger than that.

**Intel.** The first version of this change took up to 21.5 ms for `the` on the hosted
`macos-15-intel` runner, which was 5 to 6 times slower than the M4 for every query, and
failed this check there. Scanning frecent rows first brought the slowest query on the M4 from
4.4 ms to 2.1 ms.

The writer's costs at the cap, for the record: recording a visit 0.1 ms until durable, a
retention pass that has nothing to delete 0.9 ms, deleting one URL 162 ms, nearly all of it
replacing the recovery backup, and clearing all history 347 ms. Clearing all of it skips the
per-row index trigger and rebuilds the index instead; with the trigger it took 1.3 s in the
Python harness, and Lite clears all history on the main thread at launch after website data
was cleared.

### What is still slow

- **The database is larger.** 100,000 URLs take 53 MB, against 20 MB for the version 1 table
  of the same rows. The address and words columns, the address index and the full-text index
  account for the difference. The recovery backup copies the whole database, at most once a
  minute, on the writer.
- **The History panel's search** still scans every row: 50 ms at 100,000 URLs for text that
  matches nothing.
- **Migrating** a version 1 history computes each row's address and words once, on the main
  thread while the profile opens. This was not measured at 100,000 rows.

### Reproduce

```sh
cmake --build .build --target LiteHistoryTests
.build/LiteHistoryTests --measure
```

## Current readiness measurements

The [1 October 2026 record](readiness-2026-10-01.md) contains the current baseline,
provisional regression budgets, before/after persistence measurements and limitations.
The figures above are historical results, not current-release guarantees.
