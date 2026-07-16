# macOS Distribution — Sign + Notarize + DMG Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a Developer ID-signed, notarized, stapled `Slipreel-<version>.dmg` for direct distribution, via one env-driven release script that runs locally and is wrapped by a tag-triggered GitHub Actions workflow.

**Architecture:** Xcode signs the `.app` with Developer ID + hardened runtime during `flutter build macos --release` (config committed in the Runner target's Release build settings); the #19 copy phase signs the nested Helpers hardened; then `scripts/release-macos.sh` verifies, notarizes, staples, packages the DMG, and signs/notarizes/staples the DMG. A thin workflow imports the cert + notary key from Secrets and calls the same script.

**Tech Stack:** bash (`set -euo pipefail`), Xcode/xcodebuild via `flutter build macos`, `codesign`, `xcrun notarytool`, `xcrun stapler`, `create-dmg` (Homebrew, build-time only), GitHub Actions (`macos-latest`).

## Global Constraints

- Direct distribution model: identity `Developer ID Application`, `ENABLE_HARDENED_RUNTIME = YES`, secure timestamp (`--timestamp`), notarized + stapled. No App Store, no provisioning profile.
- Team ID is committed (not sensitive). Certificates, `.p8` keys, `.p12` are NEVER committed — local keychain / GitHub Secrets only.
- `scripts/release-macos.sh` is the single source of truth; the workflow only supplies the environment and calls it.
- Local **ad-hoc dev builds must stay byte-for-byte unchanged**: the copy phase adds hardened-runtime options ONLY when signing with a real identity (`sign_id != "-"`).
- Always `flutter clean` before a release build (avoids the #19 incremental stale-seal).
- Flutter commands via `fvm flutter`. macOS deployment target 13.0. Do NOT run `dart format` on existing files.
- `create-dmg` is a build-machine-only dependency; it is never shipped and never a runtime dependency.
- The shippable app dir is `packages/screen_recorder` (Xcode project under `packages/screen_recorder/macos`). Release artifact goes to `dist/` (gitignored) at the repo root.
- `DEVELOPMENT_TEAM` value and the signing identity are the user's real values, obtained at implementation time from `security find-identity -v -p codesigning` (the 10-char team id in parens after `Developer ID Application: <name> (<TEAMID>)`). These are concrete values supplied by the controller during execution, not placeholders.

---

### Task 1: Release setup documentation

**Files:**
- Create: `docs/release/SETUP.md`

**Interfaces:**
- Produces: the human runbook for creating the Developer ID cert, the App Store Connect API key, the local `notarytool` keychain profile, and the exact GitHub Secrets the workflow (Task 5) consumes. Referenced by `release-macos.sh` error messages (Task 3).

- [ ] **Step 1: Write `docs/release/SETUP.md`**

````markdown
# Release setup (one-time)

Slipreel is distributed directly (signed + notarized DMG, not the App Store).
This is the one-time credential setup. After this, releasing is a single
command (`scripts/release-macos.sh`) or a tag push (CI).

## 1. Developer ID Application certificate

1. Keychain Access → menu **Keychain Access → Certificate Assistant →
   Request a Certificate From a Certificate Authority**. Enter your email,
   leave CA email blank, choose **Saved to disk**, save `CertificateSigningRequest.certSigningRequest`.
2. https://developer.apple.com/account → **Certificates, IDs & Profiles →
   Certificates → +** → **Developer ID Application** → Continue → upload the
   CSR → Continue → **Download** the `.cer`.
3. Double-click the `.cer` to install it into your **login** keychain.
4. Confirm:
   ```bash
   security find-identity -v -p codesigning
   ```
   You should see `Developer ID Application: <Your Name> (<TEAMID>)`. The
   10-character `<TEAMID>` is your Apple Team ID — you'll commit it in the
   Xcode config (Task 2) and add it as the `APPLE_TEAM_ID` secret.

## 2. App Store Connect API key (for notarytool)

1. https://appstoreconnect.apple.com → **Users and Access → Integrations →
   App Store Connect API → +** (Team Keys). Name it "Slipreel Notary",
   Access = **Developer**. Generate.
2. **Download the `.p8` now** — Apple shows it only once. Note the **Key ID**
   (on the row) and the **Issuer ID** (top of the page).
3. Store the `.p8` somewhere safe (e.g. `~/.appstoreconnect/private_keys/`).

## 3. Local notarytool keychain profile (convenience)

Stores the API key in your keychain so the script doesn't need the raw key
each run:
```bash
xcrun notarytool store-credentials "slipreel-notary" \
  --key /path/to/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <ISSUER_ID>
```
Then release locally with `NOTARY_PROFILE=slipreel-notary`.

## 4. Releasing

**Locally:**
```bash
NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 1.0.0
```
Produces `dist/Slipreel-1.0.0.dmg` (signed, notarized, stapled).

**Via CI:** push a tag `v1.0.0`. The workflow needs these repository
**Secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12` — export the cert+key from Keychain Access as a `.p12`, then base64 it |
| `MACOS_CERT_PASSWORD` | the password you set when exporting the `.p12` |
| `APPLE_TEAM_ID` | your `<TEAMID>` |
| `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_<KEYID>.p8` |
| `NOTARY_KEY_ID` | `<KEYID>` |
| `NOTARY_ISSUER_ID` | `<ISSUER_ID>` |

To export the `.p12`: Keychain Access → login keychain → find **Developer ID
Application: … (TEAMID)** → expand it, select **both** the certificate and
its private key → right-click → **Export 2 items** → `.p12` → set a password.
````

- [ ] **Step 2: Commit**

```bash
git add docs/release/SETUP.md
git commit -m "docs: one-time release credential setup (Developer ID + notary) (#1)"
```

---

### Task 2: Xcode Release signing config

**Files:**
- Modify: `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj` (the Runner *target* Release config block `33CC10FD2044A3C60003C045`, currently lines ~740-758)

**Interfaces:**
- Produces: a Release build config that signs with `Developer ID Application`, manual style, hardened runtime, secure timestamp, team `<TEAMID>`. Consumed by the build stage of `release-macos.sh` (Task 3/4) and the copy phase's identity resolution (Task 3).

**Controller note:** the `DEVELOPMENT_TEAM` value is the user's real 10-char team id from `security find-identity -v -p codesigning`. The controller provides it in the dispatch; the implementer substitutes it verbatim.

- [ ] **Step 1: Edit the Runner target Release build settings**

In `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj`, find the block `33CC10FD2044A3C60003C045 /* Release */` (it contains `CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;`). Replace its `buildSettings` so the signing keys are set. Change this:

```
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				INFOPLIST_FILE = Runner/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				PROVISIONING_PROFILE_SPECIFIER = "";
				SWIFT_VERSION = 5.0;
			};
```

to this (adds identity, team, hardened runtime, timestamp; switches to Manual):

```
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;
				CODE_SIGN_IDENTITY = "Developer ID Application";
				CODE_SIGN_STYLE = Manual;
				DEVELOPMENT_TEAM = <TEAMID>;
				ENABLE_HARDENED_RUNTIME = YES;
				OTHER_CODE_SIGN_FLAGS = "--timestamp";
				COMBINE_HIDPI_IMAGES = YES;
				INFOPLIST_FILE = Runner/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				PROVISIONING_PROFILE_SPECIFIER = "";
				SWIFT_VERSION = 5.0;
			};
```

(Only the Runner *target* Release block changes. Leave Debug/Profile and the project-level configs — including their `CODE_SIGN_IDENTITY = "-"` — untouched so `flutter run` and tests stay ad-hoc.)

- [ ] **Step 2: Verify the settings resolve**

```bash
cd packages/screen_recorder/macos
xcodebuild -project Runner.xcodeproj -target Runner -configuration Release -showBuildSettings 2>/dev/null | grep -E "CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|ENABLE_HARDENED_RUNTIME|OTHER_CODE_SIGN_FLAGS"
```

Expected: `CODE_SIGN_IDENTITY = Developer ID Application`, `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM = <TEAMID>`, `ENABLE_HARDENED_RUNTIME = YES`, `OTHER_CODE_SIGN_FLAGS = --timestamp`.

- [ ] **Step 3: Confirm the pbxproj still parses**

```bash
cd packages/screen_recorder/macos
xcodebuild -project Runner.xcodeproj -list >/dev/null && echo "pbxproj parses OK"
```

Expected: `pbxproj parses OK` (xcodebuild fully parses the project file; a malformed edit would error here and in Step 2's `-showBuildSettings`).

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj
git commit -m "build(macos): Developer ID + hardened runtime on the Release target (#1)"
```

---

### Task 3: Hardened signing of the bundled Helpers

**Files:**
- Modify: `scripts/copy-native-deps.sh` (the codesign block added in #19)

**Interfaces:**
- Consumes: the `sign_id` the copy phase already resolves (`${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}`).
- Produces: nested Helpers signed with hardened runtime + secure timestamp when a real Developer ID identity is used; unchanged ad-hoc signing when `sign_id == "-"`.

- [ ] **Step 1: Read the current signing block**

The block currently is:

```bash
if [[ $copied -gt 0 && "${CODE_SIGNING_ALLOWED:-}" == "YES" ]]; then
  sign_id="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  for b in ffmpeg ffprobe whisper-cli; do
    [[ -f "$HELPERS/$b" ]] || continue
    codesign --force --sign "$sign_id" "$HELPERS/$b" || {
      echo "error: codesign failed for Helpers/$b (identity: $sign_id)" >&2
      exit 1
    }
  done
fi
```

- [ ] **Step 2: Add hardened-runtime options for real identities only**

Replace that block with:

```bash
if [[ $copied -gt 0 && "${CODE_SIGNING_ALLOWED:-}" == "YES" ]]; then
  sign_id="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  # Notarization requires every nested executable to be hardened-signed with a
  # secure timestamp. Apply those only for a real Developer ID identity; keep
  # ad-hoc ("-") local builds byte-for-byte unchanged (no runtime opt, no
  # network round-trip for a timestamp).
  hardened_opts=()
  if [[ "$sign_id" != "-" ]]; then
    hardened_opts=(--options runtime --timestamp)
  fi
  for b in ffmpeg ffprobe whisper-cli; do
    [[ -f "$HELPERS/$b" ]] || continue
    codesign --force ${hardened_opts[@]+"${hardened_opts[@]}"} --sign "$sign_id" "$HELPERS/$b" || {
      echo "error: codesign failed for Helpers/$b (identity: $sign_id)" >&2
      exit 1
    }
  done
fi
```

(`${hardened_opts[@]+"${hardened_opts[@]}"}` is the bash-3.2-safe empty-array expansion — the same guard used elsewhere in the build script.)

- [ ] **Step 3: Syntax check + confirm the ad-hoc standalone path is unchanged**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
bash -n scripts/copy-native-deps.sh && echo "syntax OK"
# Standalone run (no CODE_SIGNING_ALLOWED) must still warn+skip / copy without signing:
STAGE=$(mktemp -d); mkdir -p "$STAGE/Slipreel.app/Contents"
BUILT_PRODUCTS_DIR="$STAGE" CONTENTS_FOLDER_PATH="Slipreel.app/Contents" scripts/copy-native-deps.sh && echo "standalone OK (no signing attempted)"
rm -rf "$STAGE"
```

Expected: `syntax OK`; the standalone run copies the real vendored binaries and prints the bundled count with no codesign attempt (CODE_SIGNING_ALLOWED unset → signing block skipped).

- [ ] **Step 4: Commit**

```bash
git add scripts/copy-native-deps.sh
git commit -m "build(macos): hardened-runtime + timestamp sign Helpers for a real identity (#1)"
```

---

### Task 4: `scripts/release-macos.sh` — sign + verify (stages 1-2)

**Files:**
- Create: `scripts/release-macos.sh`
- Modify: `.gitignore` (add `dist/`)

**Interfaces:**
- Produces: a Developer ID-signed, hardened, verified `Slipreel.app` and the script's preflight + build + verify stages. Task 5 extends the SAME file with notarize/DMG stages.
- CLI: `scripts/release-macos.sh <version>`; env: `NOTARY_PROFILE` or (`NOTARY_KEY`,`NOTARY_KEY_ID`,`NOTARY_ISSUER`), `SIGN_IDENTITY` (default `Developer ID Application`).

- [ ] **Step 1: Add `dist/` to `.gitignore`**

Append to the root `.gitignore` (after the `vendor/` entry from #19):

```
# Release artifacts (signed/notarized DMGs)
dist/
```

- [ ] **Step 2: Write the script skeleton + preflight + build + verify stages**

Create `scripts/release-macos.sh`:

```bash
#!/usr/bin/env bash
# Release pipeline for Slipreel (issue #1): build -> sign-verify -> notarize
# -> staple -> DMG -> sign/notarize/staple DMG. Single source of truth; the
# GitHub workflow imports credentials and calls this same script.
#
# Usage: scripts/release-macos.sh <version>
#   Local:  NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 1.0.0
#   CI:     NOTARY_KEY=notary.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=... scripts/release-macos.sh 1.0.0
# See docs/release/SETUP.md for credential setup.
set -euo pipefail

VERSION="${1:?usage: release-macos.sh <version> (e.g. 1.0.0)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PKG="$ROOT/packages/screen_recorder"
APP="$APP_PKG/build/macos/Build/Products/Release/Slipreel.app"
DIST="$ROOT/dist"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
FLUTTER="${FLUTTER:-fvm flutter}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# notarytool auth resolved once into an array (never word-split): a local
# keychain profile, or the CI API-key triple. Populated by preflight so a
# missing-credentials `die` aborts the whole script, not just a subshell.
NOTARY_ARGS=()
resolve_notary_args() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    die "no notary credentials: set NOTARY_PROFILE, or NOTARY_KEY+NOTARY_KEY_ID+NOTARY_ISSUER (see docs/release/SETUP.md)"
  fi
}

# Submit to Apple's notary service and wait; on failure, print the detailed
# log (fetched by the submission id from the submit output) and abort.
notarize() { # notarize <path-to-.zip-or-.dmg>
  local target="$1" out subid
  if out="$(xcrun notarytool submit "$target" "${NOTARY_ARGS[@]}" --wait 2>&1)"; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" >&2
    subid="$(printf '%s\n' "$out" | awk '/^ *id:/{print $2; exit}')"
    [[ -n "$subid" ]] && xcrun notarytool log "$subid" "${NOTARY_ARGS[@]}" >&2 2>/dev/null || true
    die "notarization failed for $target (see log above)"
  fi
}

# --- preflight ---------------------------------------------------------------
log "preflight"
command -v xcrun >/dev/null || die "Xcode command line tools required"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no 'Developer ID Application' certificate in the keychain (see docs/release/SETUP.md)"
command -v create-dmg >/dev/null || die "create-dmg not found: brew install create-dmg (build-machine only)"
resolve_notary_args   # validates credentials are present (populates NOTARY_ARGS) before the long build
mkdir -p "$DIST"

# --- stage 1: build ----------------------------------------------------------
log "building Slipreel $VERSION (clean release)"
( cd "$APP_PKG" && $FLUTTER clean >/dev/null && $FLUTTER build macos --release )
[[ -d "$APP" ]] || die "expected app not found at $APP"

# --- stage 2: verify signature ----------------------------------------------
log "verifying Developer ID signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP" \
  || die "codesign verification failed for the app bundle"
for b in ffmpeg ffprobe whisper-cli; do
  codesign --display --verbose=2 "$APP/Contents/Helpers/$b" 2>&1 | grep -q "flags=.*runtime" \
    || die "Helpers/$b is not signed with the hardened runtime"
done
# Pre-notarization spctl may report "rejected (not notarized)"; that is expected
# here and resolved after stapling. Just confirm the signing source is Developer ID.
codesign --display --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || die "app is not signed by a Developer ID Application authority"
log "signature + hardened runtime verified"

# --- stages 3-7 added in Task 5 ---------------------------------------------
log "sign+verify complete for $APP (notarize/DMG stages follow)"
```

- [ ] **Step 3: Make executable + syntax check**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
chmod +x scripts/release-macos.sh
bash -n scripts/release-macos.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 4: Preflight fails cleanly without credentials**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
scripts/release-macos.sh 0.0.0-test 2>&1 | tail -3 || true
```

Expected: exits non-zero at preflight with a clear message — either the missing-notary-credentials error, the missing-cert error, or the missing-create-dmg error (whichever applies on this machine). It must NOT reach the build stage without credentials. (The full green run happens in Task 7 with the user's real cert.)

- [ ] **Step 5: Commit**

```bash
git add scripts/release-macos.sh .gitignore
git commit -m "build(macos): release-macos.sh build + Developer ID sign-verify stages (#1)"
```

---

### Task 5: `scripts/release-macos.sh` — notarize + staple + DMG (stages 3-7)

**Files:**
- Modify: `scripts/release-macos.sh` (append stages after the Task 4 verify stage)

**Interfaces:**
- Consumes: `$APP`, `$DIST`, `$VERSION`, `$SIGN_IDENTITY`, `notary_args`, `die`, `log` from Task 4.
- Produces: `dist/Slipreel-<version>.dmg` (signed, notarized, stapled) and the final Gatekeeper gate.

- [ ] **Step 1: Replace the Task 4 trailer with the notarize/DMG stages**

Replace the final two lines of the script:

```bash
# --- stages 3-7 added in Task 5 ---------------------------------------------
log "sign+verify complete for $APP (notarize/DMG stages follow)"
```

with:

```bash
# --- stage 3: notarize the app ----------------------------------------------
APP_ZIP="$DIST/Slipreel-$VERSION-app.zip"
log "notarizing the app"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
rm -f "$APP_ZIP"

# --- stage 4: staple the app ------------------------------------------------
log "stapling the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" || die "stapler validate failed for the app"

# --- stage 5: build the DMG -------------------------------------------------
DMG="$DIST/Slipreel-$VERSION.dmg"
log "building $DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
create-dmg \
  --volname "Slipreel $VERSION" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Slipreel.app" 140 190 \
  --app-drop-link 400 190 \
  --no-internet-enable \
  "$DMG" "$STAGE/" \
  || die "create-dmg failed"
rm -rf "$STAGE"

# --- stage 6: sign + notarize + staple the DMG ------------------------------
log "signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" \
  || die "codesign failed for the DMG"
log "notarizing the DMG"
notarize "$DMG"
log "stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" || die "stapler validate failed for the DMG"

# --- stage 7: final Gatekeeper gate -----------------------------------------
log "final Gatekeeper assessment"
spctl -a -vvv --type open --context context:primary-signature "$DMG" 2>&1 \
  | grep -q "accepted" || die "spctl did not accept the notarized DMG"
log "DONE: $DMG ($(du -h "$DMG" | cut -f1))"
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
bash -n scripts/release-macos.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/release-macos.sh
git commit -m "build(macos): release-macos.sh notarize + staple + DMG stages (#1)"
```

(The green end-to-end run is Task 7, with the user's real credentials.)

---

### Task 6: GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/release-macos.yml`

**Interfaces:**
- Consumes: `scripts/release-macos.sh`, `scripts/build-native-deps.sh`, and the six Secrets documented in `docs/release/SETUP.md`.
- Produces: on a `v*` tag, a GitHub Release with `Slipreel-<version>.dmg` attached.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release-macos.yml`:

```yaml
name: Release macOS

on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      version:
        description: "Version (e.g. 1.0.0)"
        required: true

jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Resolve version
        id: ver
        run: |
          if [[ "${{ github.event_name }}" == "workflow_dispatch" ]]; then
            echo "version=${{ github.event.inputs.version }}" >> "$GITHUB_OUTPUT"
          else
            echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          fi

      - uses: subosito/flutter-action@v2
        with:
          channel: stable

      - name: Install create-dmg
        run: brew install create-dmg

      - name: Build native deps (ffmpeg + whisper-cli)
        run: scripts/build-native-deps.sh

      - name: Import Developer ID certificate
        env:
          CERT_B64: ${{ secrets.MACOS_CERT_P12_BASE64 }}
          CERT_PW: ${{ secrets.MACOS_CERT_PASSWORD }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/build.keychain"
          KP="$(uuidgen)"
          echo "$CERT_B64" | base64 -d > "$RUNNER_TEMP/cert.p12"
          security create-keychain -p "$KP" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KP" "$KEYCHAIN"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$CERT_PW" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KP" "$KEYCHAIN"
          security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
          rm -f "$RUNNER_TEMP/cert.p12"

      - name: Write notary key
        env:
          KEY_B64: ${{ secrets.NOTARY_KEY_P8_BASE64 }}
        run: echo "$KEY_B64" | base64 -d > "$RUNNER_TEMP/notary.p8"

      - name: Release pipeline
        env:
          NOTARY_KEY: ${{ runner.temp }}/notary.p8
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER: ${{ secrets.NOTARY_ISSUER_ID }}
        run: scripts/release-macos.sh "${{ steps.ver.outputs.version }}"

      - name: Publish GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: dist/Slipreel-*.dmg
          tag_name: ${{ github.ref_name }}
          fail_on_unmatched_files: true

      - name: Clean up keychain + key
        if: always()
        run: |
          rm -f "$RUNNER_TEMP/notary.p8"
          security delete-keychain "$RUNNER_TEMP/build.keychain" || true
```

- [ ] **Step 2: Lint the workflow YAML**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-macos.yml')); print('YAML OK')"
```

Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-macos.yml
git commit -m "ci: tag-triggered macOS release workflow calling release-macos.sh (#1)"
```

(CI is first-run-verified by the user pushing a real `v*` tag once Secrets are set — not part of local acceptance.)

---

### Task 7: End-to-end local verification (controller + user)

**Files:** none (runs the pipeline with the user's real credentials).

**Interfaces:**
- Consumes: everything above + the user's Developer ID cert and notary profile (created via Task 1's SETUP.md).

**This task is run by the controller with the user, not a subagent** (it needs the real cert/keychain and network access to Apple's notary service).

- [ ] **Step 1: Confirm the cert + team id**

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Confirm the `<TEAMID>` in parens matches what Task 2 committed in `DEVELOPMENT_TEAM`. If not, correct Task 2's value.

- [ ] **Step 2: Run the full pipeline**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 0.1.0
```

Expected: proceeds through build → verify → notarize (Accepted) → staple → DMG → notarize DMG (Accepted) → staple → final `spctl` accepted; prints `DONE: dist/Slipreel-0.1.0.dmg`.

- [ ] **Step 3: Independically confirm the artifact**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
xcrun stapler validate dist/Slipreel-0.1.0.dmg && echo "DMG stapled OK"
spctl -a -vvv --type open --context context:primary-signature dist/Slipreel-0.1.0.dmg
# Mount + check the app inside is stapled too:
hdiutil attach dist/Slipreel-0.1.0.dmg -nobrowse -mountpoint /tmp/slipreel-dmg
xcrun stapler validate "/tmp/slipreel-dmg/Slipreel.app" && echo "app stapled OK"
spctl -a -vvv --type execute "/tmp/slipreel-dmg/Slipreel.app"
hdiutil detach /tmp/slipreel-dmg
```

Expected: both `stapler validate` calls succeed; both `spctl` calls report `accepted` with source `Notarized Developer ID`.

- [ ] **Step 4: User acceptance (issue criteria)**

The user opens `dist/Slipreel-0.1.0.dmg` (ideally on a second Mac / fresh user account, Gatekeeper on): it mounts, the app drags to /Applications, launches with NO "unidentified developer" / "damaged" warning, and recording + export-via-bundled-ffmpeg work. This is the sub-project A acceptance gate.

---

## Self-review notes

- Spec coverage: signing config (T2), hardened Helpers (T3), notarize+staple+DMG script (T4/T5), workflow (T6), SETUP/cert+notary+secrets doc (T1), verification/acceptance (T7). Entitlements: spec keeps them as-is; no task needed unless T7's verify fails on a library-validation/JIT error, in which case add the minimal entitlement (documented contingency, not a planned change).
- `DEVELOPMENT_TEAM` and the notary values are real user-supplied values obtained via `security find-identity` / SETUP.md — concrete at execution, not placeholders.
- Local ad-hoc builds stay unchanged: T3 gates hardened options on `sign_id != "-"`; T2 only touches the Release target block.
- `create-dmg` is build-machine only (T4 preflight + T6 `brew install`); never a runtime dep.
- Deferred (sub-project B): Sparkle auto-update, appcast, in-app updater — no tasks here.
