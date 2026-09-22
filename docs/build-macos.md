# Build Lite on macOS

## Toolchain

- macOS 14 or newer; Apple Silicon first.
- Xcode 16+ with the macOS SDK selected by `xcode-select`.
- CMake 3.21+ and Python 3.11+.
- About 1.5 GB for the SDK, build objects, and application. The first download is
  roughly 132 MB for arm64 or 138 MB for Intel, before extraction.

```sh
./script/build_and_run.sh --build
./script/build_and_run.sh --verify
```

The script sets a local module cache, enables the CEF sandbox, builds `Lite`,
`LiteHelper`, `LiteCore`, and `LiteTests`, then runs CTest. `script/package.py`
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
the version/digests and rebuilding/testing the complete bundle. There is currently
no automatic update delivery, and upstream CEF security updates must be tracked
before any public production release.

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

The bundled-engine harness uses loopback test pages and a disposable profile:

```sh
python3 script/test_browser.py
cat test-results/engine.json
```

The harness exercises Chromium web APIs, navigation, private storage isolation,
independent page instances, form protection, freeze, discard, and restoration.
It uses Chromium's test-only mock Keychain with synthetic pages; it does not
access real cookie-encryption keys. Test options are never needed for ordinary
browsing. Do not use the test profile or mock Keychain for personal browsing.

## Keychain access in local builds

The stock CEF SDK uses the Chromium Safe Storage Keychain item to encrypt cookies.
An ad-hoc signature changes when the executable changes, so macOS may request
authorization again after a rebuild. Until that system prompt is resolved,
cookie initialization can hold page loads open with a blank page. This was
confirmed by a process sample waiting in `SecItemCopyMatching` during validation.
Complete any macOS authorization yourself; Lite does not read your login password,
change Keychain access rules, or disable cookie encryption. A stable release
signing identity and an application-specific Keychain namespace are release gates.
The pinned SDK does not expose the latter setting; newer upstream CEF work is
tracked in its [settings definition](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types.h).

## Signing and distribution

The produced app is **ad-hoc signed for local development**, not Developer ID
signed or notarized. A successful `codesign --verify --deep --strict` checks local
bundle integrity; it does not establish trust or notarization. Release work needs
the owner's Apple Developer identity, validated hardened-runtime entitlements for
CEF/helpers, notarization, stapling, and a tested engine-update distribution path.
No signing identity or account was assumed, created, or changed.

Do not disable Gatekeeper or the Chromium sandbox to distribute this build.
Intel builds are selected on Intel hosts but have not been tested on hardware.
