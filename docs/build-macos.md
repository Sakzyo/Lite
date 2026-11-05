# Build Lite on macOS

## Toolchain

- macOS 14 or newer; Apple Silicon first.
- Xcode 16+ with the macOS SDK selected by `xcode-select`.
- CMake 3.21+ and Python 3.12+.
- About 1.5 GB for the SDK, build objects, and application. The first download is
  roughly 135 MB for arm64 or 142 MB for Intel, before extraction.

```sh
./script/build_and_run.sh --build
./script/build_and_run.sh --verify
```

The script sets a local module cache, enables the CEF sandbox, builds `Lite`,
`LiteTestApp`, `LiteHelper`, `LiteCore`, and `LiteTests`, then runs CTest. `script/package.py`
stages a real bundle at `dist/Lite.app` with the framework, five helper bundles,
original Lite icon, URL registration, camera/microphone purpose strings, and
third-party licenses. No other browser installation is used as a runtime.

The default Run action closes instances launched from this checkout's bundle
through Lite's save/close path before rebuilding. A canceled website close aborts
the rebuild. Save unfinished form work first. `--build` does not stop or launch
the app. Other installations of Lite are not targeted.

## SDK pin

`script/fetch_cef.py` pins the CEF version and official SHA-1 archive digest for
each architecture. HTTPS verifies transport; the digest detects archive damage.
The archive is obtained from the CEF project's linked Spotify CDN. Archive paths
and symlinks are checked before extraction. Updating the engine requires updating
the version/digests and rebuilding/testing the complete bundle;
`script/update_cef.py` writes them from the CEF release index. Lite's reported
Chromium version comes from the SDK's `cef_version.h` at configure time. Installed SDK
identity, Mach-O architecture and file hashes are validated, with staged extraction
and recoverable replacement. See [updates and distribution](updates-and-distribution.md)
for the Sparkle feed, routine engine-update process and emergency releases.

The SDK and generated bundles are ignored by Git. Do not commit user profiles,
Chromium caches, real Arc exports, or downloaded SDK archives.

## Tests

```sh
ctest --test-dir .build --output-on-failure
.build/LiteTests lite/tests/fixtures
```

An optional read-only local schema check prints counts, not browsing URLs:

```sh
.build/LiteTests lite/tests/fixtures --check-arc
```

`Lite` contains no test code. `LiteTestApp` is the same application built with
`LITE_TEST_BUILD`, which adds `LTSmoke`, `LTNativeSmoke`, the `--lite-*` flags and
`LITE_START_URL`. `script/package.py --test` stages it as `dist/LiteTest.app`, and the
Chromium, extension, native-window, endurance and measurement scripts run that bundle
by default. `script/test_package.py` fails if a release bundle contains those markers,
and `script/test_release_binary.py` confirms a running release bundle ignores the flags.
`script/test_crash_capture.py` crashes a helper in a disposable profile and requires a
stored report.

The bundled-engine harness uses loopback test pages and a disposable profile:

```sh
python3 script/package.py --test
python3 script/test_browser.py
cat test-results/engine.json
```

The harness exercises Chromium web APIs, navigation, private storage isolation,
independent page instances, form protection, freeze, discard, and restoration.
It uses Chromium's test-only mock Keychain with synthetic pages; it does not
access real cookie-encryption keys. Do not use the test bundle, test profile or mock
Keychain for personal browsing.

## Keychain access in local builds

The stock CEF SDK uses the Chromium Safe Storage Keychain item to encrypt cookies.
An ad-hoc signature changes when the executable changes, so macOS may request
authorization again after a rebuild. Until that system prompt is resolved,
cookie initialization can hold page loads open with a blank page. This was
confirmed by a process sample waiting in `SecItemCopyMatching` during validation.
Complete any macOS authorization yourself; Lite does not read your login password,
change Keychain access rules, or disable cookie encryption. A stable release
signing identity and an application-specific Keychain namespace are release gates.
CEF 156 adds settings for the latter, which Lite does not use yet; see
[Keychain and cookie continuity](updates-and-distribution.md#keychain-and-cookie-continuity).

## Signing and distribution

The default produced app is **ad-hoc signed for local development**, not Developer
ID signed or notarized. `python3 script/package.py --production` requires an
existing Developer ID identity, notarytool credential profile, HTTPS feed and
Ed25519 public key. It signs nested code first, notarizes, staples and verifies
the extracted final distribution archive. A successful local `codesign --verify
--deep --strict` alone does not establish trust or notarization. See
[the exact configuration and prerequisites](updates-and-distribution.md).

Do not disable Gatekeeper or the Chromium sandbox to distribute this build.
Intel builds are selected on Intel hosts but have not been tested on hardware.
