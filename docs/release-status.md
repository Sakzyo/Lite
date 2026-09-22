# Release status

Lite 0.1 is a native, runnable Chromium browser development build. It is not yet
the production-quality browser described by every item in the product brief.

## Required before a production release

- A maintained, signed Chromium/CEF security-update pipeline.
- Developer ID signing, CEF hardened-runtime entitlement review, notarization,
  stapling, and Intel/macOS-version coverage. Local bundle relocation has passed
  the same 19 engine checks as the workspace build.
- Stable Keychain authorization across upgrades and a dedicated Lite encryption
  namespace. Ad-hoc rebuilds can trigger macOS authorization for Chromium Safe
  Storage; unresolved authorization can stall cookie initialization/page loads.
- Security review of permission UX, download handling, popups, private-context
  lifetime, malformed imports, disk exhaustion, and crash recovery.
- Extensive website/login/media testing, VoiceOver/Full Keyboard Access review,
  long-running memory tests, battery measurements, and baseline-browser comparison.
- Broader renderer/session restoration: navigation entries, scroll offsets,
  crash recovery prompts, and carefully scoped form-state preservation.
- Broader large-profile sidebar performance and favicon compatibility testing.
- Full source-visible release criteria and regression coverage for remaining UI
  interactions, including trackpad Space gestures and every drag/drop edge case.

## Deliberate architecture limitations in this build

- No Chrome Web Store extension loading. Login saving/filling is manual through
  Library, backed by the Mac's Keychain; automatic save prompts, cross-frame
  filling, passkeys, and Google/iCloud password synchronization are not implemented.
  Existing macOS Internet-password items can be selected when Keychain permits
  access. This does not grant access to every Apple Passwords/iCloud vault entry.
- GitHub Live Folders support github.com only. Private-repository results require
  an authorized GitHub token; live private-account access has not been verified.
  GitHub's 1,000-result search cap requires narrowing large queries.
- No licensed Widevine or proprietary-codec redistribution, and no promise of
  streaming-service DRM support.
- No PWA installation or Chromium account/sync services.
- Clear Browsing Data currently clears Lite history, cookies, HTTP cache,
  authentication cache, and certificate exceptions. It is not a comprehensive
  storage-partition eraser; IndexedDB/local storage can be inspected in DevTools.
- HTML Save writes source HTML; it does not archive linked assets offline.
- Split persistence is window/session based, rather than named reusable split groups.
- Temporary Mini Lite pages are promoted by URL; their live back/forward stack is
  not transferred into the destination window.

No unsupported feature is represented by a working-looking mock. Settings states
the extension/DRM boundaries; saved-login dialogs explain the local-only store. There is no AI, theme editor, analytics SDK,
account requirement, proprietary branding, or cloud service.
