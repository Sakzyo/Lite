# Crash reporting

Lite captures crashes locally and sends a report only when the user clicks **Send** for
it. Nothing else leaves the Mac, and no crash reporting SDK is linked: Crashpad ships
inside CEF, and uploads are one plain HTTPS request from `LTCrashReports`.

## What happens after a crash

1. CEF's Crashpad writes a minidump to `Chromium/pending/` in the profile. It covers
   crashes in the browser process and in helpers such as renderers and the GPU process.
2. On the next launch, before the engine starts, `LTCrashReports` deletes any report
   from a run that had a private window, and any report older than 7 days.
3. If this build has an upload endpoint, a sheet offers the remaining reports together.
   **Don't Send** is the default button. Declining deletes them.
4. **Send** posts each report once. A sent report is deleted. A failed one is kept, and
   Lite asks again on the next launch.

Regular Clear Browsing Data removes reports, because it removes the `Chromium` directory.

## What a report contains

A minidump is an unencrypted snapshot of process memory. It can hold fragments of web
pages, typed text, web addresses, file paths with the macOS account name, and process
command lines. The consent sheet says so. This is why Lite never offers a report
without asking, and why each one lasts at most 7 days.

Reports from private sessions stay on disk until the next launch, when they are deleted
without being offered. A crash cannot run Lite's cleanup, so this is the earliest point
at which that can happen.

## Upload rules

- `resources/crash_reporter.cfg` must never set `ServerURL`. Crashpad would then upload
  every report by itself, with no consent. `script/test_package.py` fails if it does.
- `LITE_CRASH_UPLOAD_URL` sets the endpoint at production packaging. It must be an HTTPS
  `sentry.io` minidump URL, because the consent sheet names Sentry. Find it under
  **Client Keys → Minidump Endpoint** in the Sentry project settings.
- Without it, the build has no endpoint, shows no sheet and cannot upload. All local
  builds work this way.
- Requests use an ephemeral session with no cookies, and refuse redirects so a report
  cannot reach a host the user was not told about. They carry the product and version
  beyond the minidump itself.

## Symbols

Crash stacks need symbols to be readable. Publishing them to Sentry is not automated
yet: a release needs Lite's dSYMs and CEF's matching `release_symbols` archive.

## Endurance testing

`script/endurance.py` records every report a phase leaves in its profile and fails that
phase. `script/test_crash_capture.py` crashes a sandboxed helper during verification to
confirm that capture still works.
