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

Visible split panes, loading pages, edited forms, playing media, camera/microphone
capture, downloads, PiP, closing pages, and Keep Awake tabs are protected. Memory
pressure can discard other pages immediately. A website's before-unload objection
cancels an automatic discard and protects the page. Freeze uses Chromium's page
lifecycle API; discard closes the actual Chromium browser instance. Selecting a
discarded tab creates it again using its saved URL and normal cookie context.
Back/forward entries and scroll/form state are not currently serialized across
discard, so unsaved forms are guarded rather than reconstructed.

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
