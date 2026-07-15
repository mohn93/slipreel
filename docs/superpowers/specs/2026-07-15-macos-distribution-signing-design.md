# macOS Distribution — Developer ID Sign + Notarize + DMG — Design

**Date:** 2026-07-15
**Status:** Design — approved in brainstorming
**Branch:** `feat/macos-distribution`
**Issue:** #1 (distribution), sub-project A of two. Sub-project B (Sparkle auto-update) is separate and comes next.

## Goal

Produce a Developer ID-signed, notarized, stapled `Slipreel.dmg` for direct
distribution, via a **repeatable release pipeline**: one env-driven script
that runs locally today, wrapped by a thin tag-triggered GitHub Actions
workflow that calls the same script. A downloaded DMG on a clean Mac
(Gatekeeper on, no Homebrew) opens with no "unidentified developer" /
"damaged" warning, and recording + export-via-bundled-ffmpeg work.

## Scope decisions (locked in brainstorming)

- **Sub-project A only:** signing + hardened runtime + notarize + staple +
  DMG + the release script + the GitHub workflow. Sparkle auto-update /
  appcast / in-app updater = sub-project B.
- **Script-first, CI-wraps-script:** `scripts/release-macos.sh` is the single
  source of truth; the workflow supplies the environment and calls it.
- **Notary credentials = App Store Connect API key** (`.p8` + issuer id + key
  id). No 2FA prompts, identical locally and in CI.
- **Team ID is committed** in an xcconfig (not sensitive).
- **DMG output → a GitHub Release** on the `v*` tag (also the appcast host for
  sub-project B later).
- **Local verification this session** with the user's real cert; the CI
  workflow is designed now and first-run-verified by the user on a real tag.

## Current state (verified, supersedes the stale issue text)

- `Runner/Release.entitlements` already has `app-sandbox=false` +
  `device.audio-input` + `device.camera`. The sandbox-removal the issue asks
  for is already done. No hardened-runtime-specific entitlements present.
- `project.pbxproj` Release: `CODE_SIGN_IDENTITY = "-"` (ad-hoc), no
  `DEVELOPMENT_TEAM`, no `ENABLE_HARDENED_RUNTIME`.
- #19 already bundles + wires + ad-hoc-signs ffmpeg/ffprobe/whisper-cli in
  `Contents/Helpers/`. The copy phase (`scripts/copy-native-deps.sh`) signs
  each nested binary with the build identity via
  `${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}`, guarded on
  `CODE_SIGNING_ALLOWED == YES`. It does NOT yet pass hardened-runtime
  options.
- The bundled ffmpeg/whisper are **statically linked** (no external dylibs —
  verified in #19), so hardened-runtime library-validation has nothing
  external to reject.
- One workflow exists: `.github/workflows/test-all-platforms.yml` (CI tests).
  No release workflow.

## Prerequisites the user creates once (documented, not automated)

A setup doc (`docs/release/SETUP.md`) with exact click-by-click steps for:

1. **Developer ID Application certificate.** Keychain Access → Certificate
   Assistant → request a cert from a CA (save CSR to disk). Apple Developer
   portal → Certificates → + → Developer ID Application → upload CSR →
   download `.cer` → double-click to install into the login keychain. Confirm
   with `security find-identity -v -p codesigning` (shows
   `Developer ID Application: <name> (<TEAMID>)`).
2. **App Store Connect API key.** App Store Connect → Users and Access →
   Integrations → App Store Connect API → generate a key with **Developer**
   role → download the `.p8` **once** (Apple shows it a single time). Record
   the Issuer ID and Key ID.
3. **Local notary profile** (convenience): `xcrun notarytool store-credentials`
   into a named keychain profile so the script/CLI can reference it without
   passing the key each run.

The doc also lists the exact GitHub Secrets the workflow needs (below), so
CI setup is copy-paste when the user is ready.

## Design

### 1. Xcode Release signing config (committed)

- New `Runner/Configs/Signing.xcconfig` holding non-secret signing settings,
  included by the Release config:
  - `DEVELOPMENT_TEAM = <TEAMID>` (committed — not sensitive)
  - `CODE_SIGN_STYLE = Manual`
  - `CODE_SIGN_IDENTITY = Developer ID Application`
  - `ENABLE_HARDENED_RUNTIME = YES`
  - `OTHER_CODE_SIGN_FLAGS = --timestamp` (secure timestamp on the app sign)
- `project.pbxproj` Release config for the Runner target: replace
  `CODE_SIGN_IDENTITY = "-"` and reference the xcconfig. Debug/Profile stay
  ad-hoc (unchanged) so local `flutter run`/tests are unaffected.
- Rationale for Xcode-signs (not script-re-signs): Xcode knows the Flutter
  framework layout and deep-signs inside-out correctly; the script owns
  packaging + notarization, not re-signing frameworks.

### 2. Nested-helper hardened signing (copy phase change)

`scripts/copy-native-deps.sh`: when signing the Helpers, add
`--options runtime --timestamp` so each bundled executable is hardened-signed
with a secure timestamp (both required for notarization). Keep the existing
identity resolution and the `CODE_SIGNING_ALLOWED == YES` guard. For ad-hoc
local builds (`-` identity) `--options runtime` is harmless; for Developer ID
release builds it is required. Standalone script tests are unaffected (they
run with `CODE_SIGNING_ALLOWED` unset).

### 3. Entitlements

Keep `Release.entitlements` as-is (`app-sandbox=false`, audio, camera).
Because the helpers are static and spawned as separate signed processes, no
`disable-library-validation` / `allow-jit` is expected. The release script's
verification step (`codesign --verify --deep --strict` + `spctl`) is the
gate: if it fails on a library-validation or JIT error, add the minimal
entitlement and document why — but the default is to add nothing.

### 4. `scripts/release-macos.sh` — the release engine

One bash script, `set -euo pipefail`, env-driven, idempotent, verbose
per-stage logging. Reads config from env with sensible defaults:

- `APP_NAME=Slipreel`, `SCHEME`/paths derived from the repo.
- `NOTARY_PROFILE` (local keychain profile) OR
  `NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER` (API-key file, for CI).
- `VERSION` (from arg or the tag; also stamped into the DMG name).

Stages (each gated, fail-loud):

1. **Build** — `flutter clean` + `flutter build macos --release`. Xcode signs
   the app with Developer ID + hardened runtime; the copy phase signs Helpers
   hardened.
2. **Verify signature** — `codesign --verify --deep --strict --verbose=2` on
   the `.app`; assert each Helper is Developer-ID + hardened (`codesign -d
   --entitlements - ` / flags check); `spctl -a -vvv --type execute` (expect
   "accepted", source "Developer ID"). At this pre-notarization point `spctl`
   may say "rejected: not notarized" — acceptable; the post-staple check is
   the real gate.
3. **Notarize app** — zip the `.app` (`ditto -c -k --keepParent`), `xcrun
   notarytool submit --wait` with the API key/profile; on failure fetch and
   print the notary log (`notarytool log`) and abort.
4. **Staple app** — `xcrun stapler staple` the `.app`; `stapler validate`.
5. **DMG** — `create-dmg` (build-time-only tool; not shipped) producing
   `Slipreel-<version>.dmg` with an `/Applications` symlink and icon layout.
   If `create-dmg` is absent, the script errors with the one-line install
   hint (build-machine dep only, never a runtime dep).
6. **Sign + notarize + staple DMG** — `codesign --sign` the DMG with the
   Developer ID + `--timestamp`; `notarytool submit --wait`; `stapler staple`
   the DMG; `stapler validate`.
7. **Final gate** — `spctl -a -vvv --type open --context context:primary-signature`
   on the DMG (expect accepted); print the artifact path + size.

The script never commits or uploads; it only produces the artifact. Output:
`dist/Slipreel-<version>.dmg`.

### 5. `.github/workflows/release-macos.yml` — thin wrapper

- Trigger: push of a `v*` tag (plus `workflow_dispatch` for manual runs).
- Runner: `macos-latest`.
- Steps: checkout → set up Flutter (matching the test workflow) → build the
  native deps (run `scripts/build-native-deps.sh`, or restore from cache) →
  import the Developer ID cert from a base64 secret into a temporary keychain
  (`security create-keychain` / `import` / `set-key-partition-list`) → write
  the `.p8` from a secret → export the notary env vars → run
  `scripts/release-macos.sh $VERSION` → attach `dist/Slipreel-*.dmg` to a
  GitHub Release for the tag → delete the temp keychain.
- **GitHub Secrets required** (documented in SETUP.md):
  `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_TEAM_ID`,
  `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.
- The workflow contains no signing logic itself — it sets up the environment
  and calls the script, so local and CI releases are byte-for-byte the same
  process.

### 6. Native-deps in CI

The release script assumes `vendor/native/bin/` is populated (from #19's
`build-native-deps.sh`). Locally the user already has it. In CI the workflow
runs `build-native-deps.sh` (cached by the pinned ffmpeg/whisper versions) as
a prior step. This is noted but the heavy CI-caching optimization is a
follow-up, not required for A.

## Error handling / edge cases

- **No cert in keychain** → `codesign` fails fast; the script checks
  `security find-identity` up front and prints the SETUP.md pointer.
- **Notarization rejected** → fetch + print the `notarytool log` JSON (it
  names the offending unsigned/unhardened binary) and abort non-zero.
- **`create-dmg` missing** → error with `brew install create-dmg` hint
  (build-time only).
- **Incremental stale seal** (learned in #19) → the script always does
  `flutter clean` first, so the distribution build is never incremental.
- **Ad-hoc fallback** → with no Developer ID identity available, the script
  refuses to proceed past the signature-verify stage (it is a *release*
  script; ad-hoc DMGs are not shippable). Local non-release iteration keeps
  using plain `flutter build`.

## Testing / verification

- **Static checks:** `bash -n` on the script; the existing test suites stay
  green (no Dart/behavior changes beyond the copy-phase codesign flags, which
  are covered by a re-run of the #19 standalone copy-script states).
- **Local end-to-end (this session):** run `scripts/release-macos.sh` with the
  user's real cert + notary key; confirm `stapler validate` and
  `spctl -a -vvv` accept the stapled app and DMG. This is the acceptance gate
  for A.
- **CI:** first real tag push (user-run, when ready) verifies the workflow;
  designed now, not blocking A's local acceptance.
- **Clean-Mac acceptance (issue criteria):** the user opens the DMG on a
  second Mac / fresh account with Gatekeeper on — no warnings, app runs,
  export via bundled ffmpeg works.

## Non-goals (this sub-project)

- Sparkle auto-update, appcast, in-app "check for updates" (sub-project B).
- App Store / TestFlight (direct distribution only, per project decision).
- Windows/Linux packaging.
- CI native-deps build caching optimization (functional in CI; tuning later).
- Universal-vs-per-arch installer split (single universal DMG; the binaries
  are already universal).
