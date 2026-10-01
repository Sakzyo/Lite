# Updates and distribution

Lite now embeds Sparkle 2.10.0 for complete application updates. The checked-in
configuration is a **local development configuration**: it has no feed or public
key and creates no updater controller or background update requests. A native
“Check for Updates…” item explains this state. It must not be presented as a
working public update service.

## Build dependencies

Run `python3 script/fetch_cef.py` and `python3 script/fetch_sparkle.py` before CMake.
CEF remains pinned to `154.0.23+g062ebe4+chromium-154.0.8037.17`. The CEF CDN supplies
SHA-1 archive digests; these existing exact pins detect corrupted archives, and
HTTPS authenticates transport. Sparkle's ZIP SHA-256 is pinned to the value in its
[2.10.0 Package.swift](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Package.swift).
Review both dependency pins before shipping a security release.

CEF acceptance checks the exact header version, actual Mach-O architecture, required
build files, and an installed SHA-256 manifest created only from a verified archive.
A header alone cannot bypass verification. Fetches serialize under a filesystem
lock, download to a partial file, extract to an isolated directory, and validate
before replacing the installation. Failed downloads, checksum failures, unsafe
archive paths/links, and extraction failures preserve the prior tree. Replacement
retains one previous directory until the new tree validates; a process killed
between the renames restores that tree on the next fetch. A completed replacement
with a damaged new tree and a retained recovery tree stops with the recovery path
instead of deleting either blindly. Never manually point CMake at staging trees.
Checks run at build time; no SDK verification loop runs in the browser.

## Local and production packaging

`python3 script/package.py` stages and verifies a new `dist/Lite.app`, signs it
ad hoc, and replaces the previous local bundle only after verification. It remains
usable without an Apple account. It is **not notarized or Developer ID signed**.
A running app should be closed normally before replacing its local build; use the
existing build script's close handling when appropriate.

Production uses the same complete-bundle path:

```sh
export LITE_SIGNING_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
export LITE_NOTARY_PROFILE='lite-notary'
export LITE_UPDATE_FEED_URL='https://your-host/arm64/appcast.xml'
export LITE_UPDATE_PUBLIC_KEY='PUBLIC_BASE64_ED25519_KEY'
export LITE_BUILD_NUMBER='2'
python3 script/package.py --production
```

The identity is selected automatically only when exactly one valid Developer ID
Application identity is available. `LITE_NOTARY_PROFILE` names credentials already
configured with `xcrun notarytool store-credentials`; the script never creates an
Apple account, modifies signing identities, or prints secrets. The build number
must be an increasing positive integer; every published build must exceed all
previously released builds, including emergency releases.

Production signs nested CEF libraries, the versioned CEF framework, each helper,
Sparkle's nested executables/services and framework, then Lite. Library validation
stays enabled. Sparkle's own XPC entitlements are preserved. Renderer/GPU/plugin
helpers receive `allow-jit`; the browser and general helper receive only supported
capture/device entitlements. There is no unsigned-executable-memory exception,
get-task-allow, or disabled CEF sandbox. These choices follow Chromium's
[renderer](https://github.com/chromium/chromium/blob/main/chrome/app/helper-renderer-entitlements.plist),
[GPU](https://github.com/chromium/chromium/blob/main/chrome/app/helper-gpu-entitlements.plist),
and [browser](https://github.com/chromium/chromium/blob/main/chrome/app/app-entitlements.plist)
entitlement definitions. Their complete compatibility under a real Developer ID
signature still needs capture, WebGL, V8, and helper-launch testing on both CPUs.

The production command submits a ZIP for notarization, waits for completion,
staples and validates the application, and runs Gatekeeper assessment. It then
creates the distribution ZIP, re-extracts its actual bytes, verifies signatures,
resources, dependencies, architecture and the staple, and writes a SHA-256 sidecar.
Any unsuccessful step exits nonzero. No public upload is performed.

## Authenticated updates and schema compatibility

The release bundle must contain an HTTPS feed URL and a 32-byte Ed25519 public key.
Sparkle verifies both the signed feed and downloaded archive before extraction;
signed-feed failures never expire into a weaker fallback. Lite permits only newer
integer build numbers, complete `application` archives over HTTPS, matching CPU
architecture, and declared profile compatibility. Deltas and package installers
are rejected. Update metadata must include `lite:minimumProfileSchema`,
`lite:maximumProfileSchema`, and `lite:architecture`, using the namespace
`https://lite.app/xml-namespaces/updates` and the exact `lite` prefix.

`LTProfileSchemaVersion` and `LTMinimumReadableProfileSchema` in the bundle describe
the current schema and oldest supported migration input. They are both `1` today.
Changing them requires migration/backup/unsupported-version tests; do not widen
the compatibility range merely to make an update install. The feed declares the
range supported by the **destination** app. A future incompatible app must use a
migration bridge or an informational release, not bypass this gate.

Sparkle owns download cancellation, installer recovery, signature validation and
atomic replacement. Lite does not implement cryptography or a parallel installer.
Automatic checks require Sparkle's normal opt-in and run at most on its daily
schedule. Automatic downloading/installing is disabled; users explicitly choose
to install. Release-note downloads and system profiling are disabled. Sparkle's
installation exits through Lite's normal quit flow, so successful before-unload
and quit-cancellation verification remains a release gate.

Generate publisher keys once with `vendor/sparkle/bin/generate_keys --account
lite-updates`, retaining the private key in the publisher's Keychain and embedding
only the public key. Use an archive directory per architecture:

```sh
python3 script/prepare_appcast.py /path/to/release-archives/arm64 \
  --download-url-prefix https://your-host/arm64/ --account lite-updates
```

This validates notarized complete ZIPs, invokes Sparkle's appcast generator with
zero deltas, adds compatibility metadata from each verified app, and re-signs and
verifies the feed using Sparkle. It prepares files locally; publishing is a separate
release action. The [Sparkle setup](https://sparkle-project.org/documentation/)
and [security settings](https://sparkle-project.org/documentation/customization/)
describe key rotation and signed-feed behavior. Test changes in a separate feed
before making any feed public.

## Routine engine and emergency security release

1. Review upstream CEF/Chromium and Sparkle security releases. Update exact SDK pins
   and archive digests from upstream; retain the old released bundle for testing.
2. Build each architecture separately with an increasing build number. Run the
   full local entry point and available hardware acceptance checks.
3. Package with Developer ID/notarization, retain the notarization result, then
   prepare the signed architecture-specific feed. Preserve rollback diagnostics
   and profile backups; never downgrade the user's data with an old binary.
4. Exercise signed old→new installation on disposable profiles: valid signature,
   wrong key/tampered feed/archive, interrupted download, interrupted installation,
   insufficient disk, user-canceled quit, successful relaunch, history/vault/cookie
   continuity, and recovery. Upload archives before the signed feed only after
   these gates pass. Emergency releases use the same integrity/migration gates.

## Keychain and cookie continuity

Lite's vault already uses a profile-specific Keychain item, authenticated encrypted
storage, and private-window separation. Production updates retain bundle IDs,
profile paths and the publisher's signing identity. Ad-hoc-to-ad-hoc checks do not
prove stable Keychain authorization across a Developer ID upgrade.

The pinned CEF public settings/header expose no supported macOS OSCrypt product
namespace option. Its framework still references Chromium Safe Storage. Lite does
not rename that item, copy its secret, weaken authorization, switch cookie
providers, or use mock Keychain for ordinary browsing. A Lite-specific namespace
is unavailable in this SDK. Adopting one would require an upstream-supported CEF
option (or separately reviewed engine change) plus an explicit encrypted-cookie migration.
The mandatory release gate is verified signed cookie/Keychain continuity with the
supported configuration, not a speculative namespace change.
Changing only the bundle display name cannot safely migrate existing cookies.

This environment has **zero valid code-signing identities**. Required external
inputs are a Developer ID Application identity/private key, notarization account
credentials saved as a notarytool profile, a publisher-owned Sparkle Ed25519 key,
and a controlled HTTPS feed/download host. Real signed upgrade/recovery and
cookie/Keychain continuity tests remain unverified until those inputs and an older
signed release are available. Synthetic mock-Keychain engine tests do not count
as real encrypted-cookie continuity evidence.

## Automated evidence

`./script/verify_release.sh` builds Release, runs CTest (core, vault, blocking and
new native regressions), SDK/update regressions, stages/verifies the app, and runs
the separate Chromium suite, then the real native-window suite. Output is retained under `test-results/release/` and
`test-results/engine.json` and `test-results/native.json`. `--measure` also runs the disposable native-profile
measurement harness; timing variation is reported, not automatically failed.
`.github/workflows/release-verification.yml` runs this entry point on macOS 14
arm64 and macOS 15 Intel. The workflow is checked in but has not run on GitHub as
part of this local session. Native VoiceOver/Full Keyboard Access and real signed
upgrade acceptance are separate gates, not implied by CI success.

Current focused checks: 20 native updater policy/parser checks and 11 Python tests pass.
The latter include real Sparkle signature verification of synthetic bytes and
signed feed XML, tamper rejection, correct/mismatched SDKs, archive corruption,
interrupted download/replacement, unsafe archive paths, and simulated ENOSPC.
These do **not** prove Sparkle's complete installation recovery: that scenario
requires exercising signed old/new applications with the prerequisites above.
Seven runner tests also cover exact app/profile matching, timeout failure status,
graceful cleanup and the forced-stop fallback; they do not replace browser runs.

The native-window suite passed 35 checks with a graceful application exit. It
uses actual AppKit controls and Chromium pages for split focus in both directions,
sidebar visibility, command-bar keys, settings/download accessibility labels,
before-unload and multi-page window-close cancellation, application quit
cancellation across regular/private windows, storage separation, private data
clearing with a fresh context, page/window closure and HTTP authentication. It
uses only a disposable profile and synthetic credentials; it does not establish
spoken VoiceOver output or system-level Full
Keyboard Access behavior.
