# Release status — 1 October 2026

Lite remains a **development build, not a production-qualified browser**. The
[readiness matrix](readiness-2026-10-01.md) gives acceptance criteria, implementation,
actual test evidence and remaining gates for every requested production area.

## Implemented release infrastructure

- Exact-version/architecture CEF validation, archive integrity, staged SDK
  replacement, rollback and interrupted-operation recovery.
- Pinned Sparkle updates with signed feeds and pre-extraction archive verification,
  complete-bundle delivery, increasing build numbers and profile/CPU compatibility.
  Local builds have no configured feed/key and cannot install updates.
- Separate ad-hoc development and Developer ID/notarization/stapling packaging
  paths, explicit entitlements, final extracted-artifact checks, local verification
  entry point and checked-in CI workflow.
- Validated persisted data, bounded durable recovery backups, explicit native
  Restore Backup UI and preservation of damaged originals. Profile writes retain
  SQLite FULL durability with less serialization work.
- Native authentication and permission request handling, per-origin storage reset,
  full storage-partition reset on restart, bounded download history, quarantine
  verification, safe discard guards and bounded nonsensitive scroll metadata.
- Actual native-window regression harness alongside the separate Chromium suite.
  See the readiness record for which checks passed; infrastructure alone is not
  proof that every release scenario is qualified.

## Blocking release gates

1. **Publisher setup:** configured Developer ID Application identity and private
   key, an Apple Developer/notarytool credential profile, Ed25519 publisher keys,
   and hosted HTTPS signed feeds for each architecture. None are invented or
   weakened for local builds. Follow [updates and distribution](updates-and-distribution.md).
2. **Distribution qualification:** run the real signed update installer with valid
   and invalid releases, interrupted installation, recovery and an existing
   synthetic profile. Local Sparkle signature tests do not prove complete signed
   installation recovery.
3. **Keychain continuity:** test synthetic vault and encrypted cookies across at
   least two production-signed upgrades. Stock CEF still uses Chromium Safe
   Storage; this bundled SDK exposes no supported Lite-specific namespace setting.
   Authorization and cookie encryption remain enabled.
4. **Session capability:** CEF exposes navigation entries but cannot import a
   serialized stack into a new browser. Multi-entry/POST, history.state,
   sessionStorage, observed interaction and media protect tabs from automatic
   discard; arbitrary unobserved JavaScript state cannot be detected. Full history after application restart is
   still unsupported; no requests are replayed to manufacture it.
5. **Broader qualification:** real Intel hardware and macOS 14/15 hosts, sandbox
   login/OAuth/payment accounts, actual capture/TCC workflows, spoken VoiceOver,
   Full Keyboard Access, scaling/contrast/drag-drop, sleep/wake, network/disk
   pressure, extended mixed-site endurance and independent security review.

Available local hardware is Apple Silicon on macOS 26.5.2. Other matrix entries
and hosted CI are **unrun**, not passed. No battery improvement is claimed.

## Deliberate capability boundaries

- No extension loading or Chrome Web Store UI, sync service, PWA installation or
  licensed Widevine/proprietary-codec integration was added.
- Supported login submissions already offer native Save/Update prompts. Lite's
  profile-scoped encrypted vault keeps key material separately in macOS Keychain;
  private windows install no capture bridge and have no login-store connection.
  Custom, embedded or multi-step forms may need explicit Library actions.
  This is not full Apple Passwords/iCloud access or Google password synchronization.
- GitHub Live Folders support github.com; private repositories require a user's
  authorized token. Account-bound results and platform search limits still apply.
- HTML Save writes source HTML, not an offline archive of linked resources.
- Mini Lite promotion transfers a URL rather than the live navigation stack.
- Full website-data reset closes all windows and restarts the engine. Organization
  and saved passwords remain. Preserved damaged-profile originals remain untouched
  and may contain old history; routine recovery backups have deleted history removed.
- Permission revocation resets grants and requests a reload to end existing
  capture. Canceling a site's before-unload prompt can keep its current stream
  alive; closing that tab ends it. Unconditional termination during revocation
  remains unqualified.
