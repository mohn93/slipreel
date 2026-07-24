# macOS Auto-Update — Sparkle + Appcast — Design

**Date:** 2026-07-23
**Status:** Design — approved in brainstorming
**Branch:** `feat/sparkle-auto-update`
**Issue:** #1 (distribution), sub-project B of two. Sub-project A (Developer ID
sign + notarize + staple + DMG + tag-triggered release pipeline) is MERGED
(PR #40); this builds directly on it.

## Goal

Ship in-app auto-update for the direct-distribution macOS build: the app checks
an appcast, tells the user when a newer notarized DMG is available, and installs
it with one click. Updates reuse the DMG the sub-project A pipeline already
produces, signs, notarizes, and staples — no second artifact. The whole thing
stays repeatable: the existing release script + GitHub workflow gain an appcast
step, and no per-release human bookkeeping is required beyond pushing a `v*` tag.

## Scope decisions (locked in brainstorming)

- **Integration:** the `auto_updater` Flutter plugin (leanflutter), which wraps
  **Sparkle 2** and bundles `Sparkle.framework` via CocoaPods. Dart API for
  feed URL + manual/scheduled checks. Not raw-Sparkle-via-platform-channel.
- **Appcast host:** **GitHub Pages** — `appcast.xml` served from a `gh-pages`
  branch at a stable URL. DMG enclosures inside it point at the per-tag GitHub
  Release assets (already published by A). Clean stable URL, CDN caching, no
  churn on the default branch.
- **Check cadence:** **auto + manual.** Sparkle scheduled background check
  (daily) with its standard first-run "check automatically?" consent prompt,
  PLUS the existing Settings "Check for updates" tile for on-demand checks.
- **Update UI:** **Sparkle's built-in native dialog** ("A new version is
  available", release notes area, Install & Relaunch). No custom Flutter UI.
- **Update payload:** reuse the notarized DMG. No zip/pkg second artifact.

## Current state (verified)

- Flutter macOS app: CocoaPods with `use_frameworks!` (Podfile `platform :osx,
  '13.0'`), bundle id `com.slipreel.app`, pubspec `version: 1.0.0+1`.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` already has an
  About section with a **disabled** "Check for updates — Coming soon" `ListTile`
  directly under the `PackageInfo` version string. This is the manual-check
  entry point; B wires it up and drops the disabled state.
- Sub-project A: `scripts/release-macos.sh` builds + Developer-ID-signs +
  hardened-runtime + notarizes + staples the app, builds the DMG, then
  signs/notarizes/staples the DMG, publishing it to a GitHub Release on `v*`.
  `.github/workflows/release-macos.yml` wraps the script (temp keychain import,
  `melos bootstrap`, `permissions: contents: write`).
- No Sparkle references in source today (grep hits are only DerivedData
  artifacts).

## Prerequisites the user creates once (documented in SETUP.md)

1. **EdDSA update-signing keypair.** Run Sparkle's `generate_keys` once. It
   stores the **private** key in the login keychain and prints the **public**
   key (base64). The public key is committed (Info.plist `SUPublicEDKey`); the
   private key never leaves the keychain locally.
2. **CI secret for the private key.** Export the private key
   (`generate_keys -x private-key.pem` or the documented export) and add it as
   the GitHub Secret `SPARKLE_ED_PRIVATE_KEY` so CI can sign the DMG.
3. **Enable GitHub Pages** for the repo, source = the `gh-pages` branch (root).
   One-time; the workflow thereafter pushes `appcast.xml` to that branch.

`docs/release/SETUP.md` gains a "Sparkle auto-update" section covering all three
plus the new secret in the secrets table.

## Design

### 1. Flutter integration (`auto_updater`)

- Add `auto_updater` to `packages/screen_recorder/pubspec.yaml` dependencies;
  `pod install` pulls `Sparkle.framework` into the Runner.
- A small `UpdaterService` (Dart) initialises the updater at app start:
  `setFeedURL(<appcast URL>)`, `setScheduledCheckInterval(86400)`. The feed URL
  is a compile-time constant (also mirrored in Info.plist `SUFeedURL` so Sparkle
  has it before Dart runs / for the first-run prompt).
- Wire the Settings tile ([settings_screen.dart:309]) `onTap` to
  `autoUpdater.checkForUpdates()`; remove `enabled: false` and the "Coming soon"
  subtitle. Manual check surfaces Sparkle's native UI (including its own
  "you're up to date" path), so no bespoke result handling is needed for v1.
- `UpdaterService` is a thin, independently-testable unit: it owns the feed URL
  constant and the updater lifecycle; the UI depends only on a
  `checkForUpdates()` call. No Sparkle types leak into widget code.

### 2. Info.plist / signing config (committed)

Add to `packages/screen_recorder/macos/Runner/Info.plist`:

- `SUFeedURL` = `https://mohn93.github.io/slipreel/appcast.xml`
- `SUPublicEDKey` = `<base64 EdDSA public key>` (public; safe to commit)
- `SUEnableAutomaticChecks` = `true`
- `SUScheduledCheckInterval` = `86400`

No entitlement changes: the app is non-sandboxed (Release.entitlements has
`app-sandbox=false` from A), so Sparkle needs no sandbox XPC wiring.

### 3. Monotonic version scheme (correctness — do not skip)

Sparkle decides "is the appcast newer than what's installed?" by comparing the
appcast's `sparkle:version` against the running app's **`CFBundleVersion`**. In
Flutter, `CFBundleVersion` = `$(FLUTTER_BUILD_NUMBER)` = the `+N` in the pubspec
version, currently hardcoded `1`. Shipping `1.0.1+1` leaves `CFBundleVersion` at
`1` → Sparkle sees no change → **no update offered.**

Fix — derive a monotonic build number from the semver in `release-macos.sh` and
stamp it into the build, with no human bookkeeping:

- `BUILD_NUMBER = major*1000000 + minor*1000 + patch` (e.g. `1.0.0` → `1000000`,
  `1.0.1` → `1000001`, `1.1.0` → `1001000`, `2.0.0` → `2000000`). Assumes minor
  and patch < 1000, which is safe for this project's cadence; the script
  validates the bound and fails loud otherwise.
- Pass `--build-name="$VERSION" --build-number="$BUILD_NUMBER"` to
  `flutter build macos` so the shipped app's `CFBundleShortVersionString` = the
  semver and `CFBundleVersion` = the monotonic integer.
- The appcast item uses the **same** integer for `sparkle:version` and the
  semver for `sparkle:shortVersionString` (display). Numeric ordering is then
  unambiguous and correct.

This keeps `pubspec.yaml` version as the human-facing default for non-release
builds; the release path overrides both fields deterministically.

### 4. Appcast generation + signing (`scripts/update-appcast.sh`)

New build-machine-only script. Inputs: version, derived build number, DMG path,
and the enclosure download URL (the tag's GitHub Release asset). Steps:

1. Run Sparkle's `sign_update <dmg>` (EdDSA, private key from keychain locally /
   `SPARKLE_ED_PRIVATE_KEY` in CI) → yields `sparkle:edSignature` + byte length.
2. Emit a new `<item>`: `<title>`, `<pubDate>`, `sparkle:version` (integer),
   `sparkle:shortVersionString` (semver), `<sparkle:minimumSystemVersion>`
   (13.0, matching the deployment target), and the `<enclosure>` with `url`
   (GitHub Release DMG), `sparkle:edSignature`, `length`, and
   `type="application/octet-stream"`.
3. **Prepend** the item to the existing `appcast.xml` (accumulating history —
   never regenerate from a directory of DMGs we don't keep). If no appcast
   exists yet, create the channel skeleton first.

Sparkle CLI tools (`sign_update`, `generate_keys`) come from `brew install
sparkle` — a build-machine dep, never shipped, same category as `create-dmg`.
The script is env-driven and callable locally and from CI identically.

### 5. Release pipeline + workflow changes

- `release-macos.sh`: compute `BUILD_NUMBER` (section 3); pass it through to the
  `flutter build`; after the DMG is notarized + stapled, call
  `update-appcast.sh` to produce/update a local `appcast.xml` (written under
  `dist/`). Keep the script's single-source-of-truth shape: it produces the DMG
  **and** the appcast entry; publishing is still the workflow's job.
- **Verify-stage extension (correctness — the A-analogue gotcha):** Sparkle
  ships nested executables in `Sparkle.framework` (`Autoupdate`, `Updater.app`,
  and XPC services). Each must be hardened-runtime + secure-timestamp +
  Developer-ID signed or notarization rejects the bundle. Xcode's deep-sign over
  `use_frameworks!` normally covers embedded frameworks, but the script's verify
  stage gains an explicit **capture-then-grep** assertion that Sparkle's nested
  Mach-O executables carry `flags=…runtime` — the same pattern already used for
  the ffmpeg/whisper Helpers — so a signing gap is caught before the
  notarization round-trip, not after.
- `.github/workflows/release-macos.yml`:
  - `brew install sparkle` alongside `create-dmg`.
  - Write `SPARKLE_ED_PRIVATE_KEY` into the environment for `update-appcast.sh`.
  - After "Publish GitHub Release", a step that checks out `gh-pages`, copies the
    updated `appcast.xml`, commits, and pushes. `contents: write` (already
    declared) covers the branch push. The enclosure URL is the just-published
    release asset URL, deterministic from the tag + DMG filename.

### 6. Release notes (deferred, non-blocking)

v1 appcast items may carry no release notes; Sparkle renders a minimal dialog
without them. A follow-up can add a `sparkle:releaseNotesLink` or an embedded
`<description>` (e.g. sourced from the GitHub Release body). Flagged, not built.

## Error handling / edge cases

- **No EdDSA private key** (local keychain miss / missing CI secret) →
  `sign_update` fails; `update-appcast.sh` aborts non-zero with the SETUP.md
  pointer, before any appcast is written.
- **`sparkle` tools missing** → `update-appcast.sh` errors with the
  `brew install sparkle` hint (build-machine dep only).
- **Sparkle framework not hardened** → caught by the verify-stage assertion
  (section 5) with the offending path, before notarization.
- **Build-number bound exceeded** (minor/patch ≥ 1000) → `release-macos.sh`
  fails loud rather than emitting a non-monotonic number.
- **First release / empty appcast** → script creates the channel skeleton, then
  prepends. Idempotent re-runs for the same version replace that version's item
  rather than duplicating it.
- **Downgrade protection** → numeric `sparkle:version` ordering means an older
  tag never supersedes a newer installed build.

## Testing / verification

- **Static:** `bash -n` on `update-appcast.sh` and the edited `release-macos.sh`;
  a focused test that the derived build number is monotonic across a version
  sequence and that a generated `<item>` is well-formed XML with the required
  Sparkle fields. Existing Dart/engine/recorder suites stay green (the only Dart
  change is the `UpdaterService` + the Settings tile wiring).
- **Local end-to-end (this session, best-effort):** add the plugin, `pod
  install`, build the Release app, and confirm `Sparkle.framework` is embedded +
  hardened and the manual "Check for updates" tile invokes Sparkle's UI. Full
  install-an-update requires two published tags.
- **CI / real update (user-run gate):** cut `v1.0.1` after `v1.0.0` exists →
  the workflow publishes the DMG, pushes the appcast, and an installed `v1.0.0`
  build offers + installs `v1.0.1`. This is the same "first real tag" gate that
  sub-project A already carries.

## Non-goals (this sub-project)

- Delta updates (full DMG each time).
- Beta / multiple release channels (single stable channel).
- Custom in-app update UI or in-app release-notes rendering.
- Windows/Linux updaters.
- App Store update path (direct distribution only, per project decision).
