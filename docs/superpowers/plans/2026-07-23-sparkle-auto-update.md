# Sparkle Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the direct-distribution macOS build in-app auto-update: it checks a GitHub-Pages-hosted appcast and installs newer notarized DMGs via Sparkle's native UI.

**Architecture:** The `auto_updater` Flutter plugin wraps Sparkle 2 (bundled as `Sparkle.framework` via CocoaPods). A thin `UpdaterService` owns the feed URL + scheduled-check lifecycle behind an injectable backend so it is unit-testable without the plugin. The sub-project A release pipeline (`scripts/release-macos.sh`) gains a monotonic build number and a Sparkle-framework hardened-signing check; a new `scripts/update-appcast.sh` EdDSA-signs each DMG and prepends a versioned `<item>` to `appcast.xml`; the release workflow publishes that appcast to a `gh-pages` branch.

**Tech Stack:** Flutter (macOS), Dart, Riverpod, `auto_updater` plugin, Sparkle 2, Sparkle CLI tools (`sign_update`, `generate_keys` via `brew install sparkle`), bash, GitHub Actions, GitHub Pages.

## Global Constraints

- Repo workflow: work on branch `feat/sparkle-auto-update`; open a PR to `main` (repo practice; there is no `dev` branch). Never commit directly to `main`.
- Commit/PR/doc style: no emoji, succinct, straightforward.
- Do NOT run `dart format` on existing files (pinned formatter reflows unrelated lines; CI does not enforce it). Match surrounding style by hand.
- macOS builds need `melos bootstrap` first (regenerates the gitignored `pubspec_overrides.yaml` for the vendored `video_player_avfoundation`).
- Signing identity: `Developer ID Application`, Team `UD7WB2694V` (Becoming Ventures, LLC). App is non-sandboxed (`Release.entitlements` `app-sandbox=false`). Hardened runtime + secure timestamp on every nested executable.
- Feed URL (canonical, used verbatim in Dart and Info.plist): `https://mohn93.github.io/slipreel/appcast.xml`
- Repo slug for enclosure URLs: `mohn93/slipreel`. Enclosure URL form: `https://github.com/mohn93/slipreel/releases/download/v<VERSION>/<DMG-filename>`
- Minimum system version in appcast items: `13.0` (matches the Podfile deployment target).
- Monotonic build number formula: `CFBundleVersion = major*1000000 + minor*1000 + patch` (minor and patch must be `< 1000`). Same integer used for the appcast `sparkle:version`; the semver is `sparkle:shortVersionString`.
- Scheduled check interval: `86400` seconds (daily). Automatic checks enabled.
- Sparkle CLI tools and `create-dmg` are build-machine-only deps, never shipped.
- Local test runner is `fvm flutter` (pinned SDK); CI uses plain `flutter`.

---

## File Structure

- `docs/release/SETUP.md` (modify) — append a "Sparkle auto-update" section (key generation, Pages, CI secret).
- `packages/screen_recorder/pubspec.yaml` (modify) — add `auto_updater`.
- `packages/screen_recorder/lib/update/updater_backend.dart` (create) — `UpdaterBackend` interface + `SparkleUpdaterBackend` (delegates to the plugin's global `autoUpdater`).
- `packages/screen_recorder/lib/update/updater_service.dart` (create) — `UpdaterService` + `updaterServiceProvider`.
- `packages/screen_recorder/test/update/updater_service_test.dart` (create) — unit tests with a fake backend.
- `packages/screen_recorder/lib/main.dart` (modify) — construct + init `UpdaterService`, override the provider.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` (modify) — wire the "Check for updates" tile.
- `packages/screen_recorder/macos/Runner/Info.plist` (modify) — Sparkle keys.
- `scripts/lib/version.sh` (create) — sourceable `derive_build_number`.
- `scripts/lib/version.test.sh` (create) — bash test for the derivation.
- `scripts/update-appcast.sh` (create) — sign + prepend appcast item.
- `scripts/update-appcast.test.sh` (create) — bash test with a fake `sign_update`.
- `scripts/release-macos.sh` (modify) — source version.sh, stamp build number, verify Sparkle framework, write `dist/appcast.xml`.
- `.github/workflows/release-macos.yml` (modify) — install sparkle, publish appcast to `gh-pages`.

---

## Task 1: SETUP.md — Sparkle auto-update runbook

**Files:**
- Modify: `docs/release/SETUP.md` (append a new section at the end)

**Interfaces:**
- Produces: the documented one-time steps and the exact GitHub Secret name `SPARKLE_ED_PRIVATE_KEY`; the EdDSA **public** key value that Task 3 pastes into Info.plist.

This is a docs-only task. It is first because it instructs the user to run `generate_keys`, whose printed public key Task 3 needs and whose exported private key Task 7's CI needs.

- [ ] **Step 1: Append the Sparkle section to SETUP.md**

Append this to the end of `docs/release/SETUP.md`:

```markdown
## Sparkle auto-update (sub-project B)

Auto-update signs each DMG with an EdDSA (ed25519) key that is separate from
the Apple Developer ID signature. Do this once.

### 1. Generate the EdDSA update keypair

Install the Sparkle CLI tools and generate a keypair:

    brew install sparkle
    generate_keys

`generate_keys` stores the PRIVATE key in your login keychain and prints the
PUBLIC key (a base64 string). Copy the public key: it goes in
`packages/screen_recorder/macos/Runner/Info.plist` as `SUPublicEDKey`
(committed — the public key is not sensitive).

Export the private key for CI (keep this file secret, do not commit it):

    generate_keys -x sparkle_private_key

### 2. Add the CI secret

In GitHub → repo Settings → Secrets and variables → Actions, add:

| Secret name             | Value                                            |
| ----------------------- | ------------------------------------------------ |
| `SPARKLE_ED_PRIVATE_KEY`| The full contents of the `sparkle_private_key` file from step 1 |

(No public key secret — it is committed in Info.plist.)

### 3. Enable GitHub Pages

Repo Settings → Pages → Build and deployment → Source = "Deploy from a branch",
Branch = `gh-pages`, folder = `/ (root)`. The release workflow creates and
pushes to `gh-pages` on the first release; after that Pages serves
`https://mohn93.github.io/slipreel/appcast.xml`.

### Local releases

For a local `scripts/release-macos.sh` run the DMG is signed with the private
key in your login keychain automatically (no env needed). To sign with an
explicit key file instead, set `SPARKLE_ED_KEY_FILE=/path/to/sparkle_private_key`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/release/SETUP.md
git commit -m "docs(release): Sparkle auto-update setup runbook (#1 sub-project B)"
```

---

## Task 2: Flutter — auto_updater plugin, UpdaterService, wired Settings tile

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml`
- Create: `packages/screen_recorder/lib/update/updater_backend.dart`
- Create: `packages/screen_recorder/lib/update/updater_service.dart`
- Create: `packages/screen_recorder/test/update/updater_service_test.dart`
- Modify: `packages/screen_recorder/lib/main.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/settings_screen.dart`

**Interfaces:**
- Produces:
  - `abstract class UpdaterBackend { Future<void> setFeedURL(String url); Future<void> setScheduledCheckInterval(int seconds); Future<void> checkForUpdates(); }`
  - `class SparkleUpdaterBackend implements UpdaterBackend` (delegates to the plugin's `autoUpdater`)
  - `class UpdaterService { UpdaterService(UpdaterBackend backend); Future<void> init(); Future<void> checkForUpdates(); static const String feedUrl; static const int scheduledCheckInterval; }`
  - `final updaterServiceProvider = Provider<UpdaterService>(...)`

- [ ] **Step 1: Add the plugin dependency**

From the package dir, add the plugin (this resolves and pins the current version so the constraint is never wrong):

```bash
cd packages/screen_recorder && fvm flutter pub add auto_updater
```

Expected: `pubspec.yaml` gains an `auto_updater:` line under `dependencies:` and `flutter pub get` succeeds.

- [ ] **Step 2: Write the failing UpdaterService test**

Create `packages/screen_recorder/test/update/updater_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/update/updater_backend.dart';
import 'package:screen_recorder_macos/update/updater_service.dart';

class _FakeBackend implements UpdaterBackend {
  final List<String> calls = [];
  String? feedUrl;
  int? interval;

  @override
  Future<void> setFeedURL(String url) async {
    feedUrl = url;
    calls.add('setFeedURL');
  }

  @override
  Future<void> setScheduledCheckInterval(int seconds) async {
    interval = seconds;
    calls.add('setScheduledCheckInterval');
  }

  @override
  Future<void> checkForUpdates() async => calls.add('checkForUpdates');
}

void main() {
  test('init sets the feed URL and the daily interval, and is idempotent',
      () async {
    final backend = _FakeBackend();
    final service = UpdaterService(backend);

    await service.init();
    await service.init(); // second call must not re-configure

    expect(backend.feedUrl,
        'https://mohn93.github.io/slipreel/appcast.xml');
    expect(backend.interval, 86400);
    expect(backend.calls.where((c) => c == 'setFeedURL').length, 1);
  });

  test('checkForUpdates delegates to the backend', () async {
    final backend = _FakeBackend();
    final service = UpdaterService(backend);

    await service.checkForUpdates();

    expect(backend.calls, contains('checkForUpdates'));
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd packages/screen_recorder && fvm flutter test test/update/updater_service_test.dart
```

Expected: FAIL — `updater_backend.dart` / `updater_service.dart` do not exist (compile error).

- [ ] **Step 4: Write the backend**

Create `packages/screen_recorder/lib/update/updater_backend.dart`:

```dart
import 'package:auto_updater/auto_updater.dart';

/// Thin seam over the `auto_updater` plugin so [UpdaterService] can be unit
/// tested without the native Sparkle plugin (which only loads in a real macOS
/// app process). The production implementation just forwards to the plugin's
/// global `autoUpdater` singleton.
abstract class UpdaterBackend {
  Future<void> setFeedURL(String url);
  Future<void> setScheduledCheckInterval(int seconds);
  Future<void> checkForUpdates();
}

/// Real backend: delegates to Sparkle via the `auto_updater` plugin.
class SparkleUpdaterBackend implements UpdaterBackend {
  @override
  Future<void> setFeedURL(String url) => autoUpdater.setFeedURL(url);

  @override
  Future<void> setScheduledCheckInterval(int seconds) =>
      autoUpdater.setScheduledCheckInterval(seconds);

  @override
  Future<void> checkForUpdates() => autoUpdater.checkForUpdates();
}
```

- [ ] **Step 5: Write the service + provider**

Create `packages/screen_recorder/lib/update/updater_service.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'updater_backend.dart';

/// Owns the Sparkle feed URL and the scheduled-check lifecycle. Kept free of
/// plugin types (the backend is injected) so it is unit-testable and so no
/// Sparkle detail leaks into widgets — the UI only ever calls
/// [checkForUpdates].
class UpdaterService {
  UpdaterService(this._backend);

  final UpdaterBackend _backend;
  bool _initialized = false;

  /// GitHub-Pages-hosted appcast. Mirrors `SUFeedURL` in Info.plist.
  static const String feedUrl =
      'https://mohn93.github.io/slipreel/appcast.xml';

  /// Daily background check (seconds). Sparkle's minimum honored value is 3600.
  static const int scheduledCheckInterval = 86400;

  /// Point Sparkle at the feed and enable the daily background check. Safe to
  /// call more than once; only the first call configures the updater.
  Future<void> init() async {
    if (_initialized) return;
    await _backend.setFeedURL(feedUrl);
    await _backend.setScheduledCheckInterval(scheduledCheckInterval);
    _initialized = true;
  }

  /// Foreground check — surfaces Sparkle's native UI (including its own
  /// "you're up to date" dialog when there is nothing newer).
  Future<void> checkForUpdates() => _backend.checkForUpdates();
}

/// App-wide updater. Overridden in `main()` with the instance that was already
/// initialized at startup so the Settings tile shares one updater.
final updaterServiceProvider = Provider<UpdaterService>(
  (ref) => UpdaterService(SparkleUpdaterBackend()),
);
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd packages/screen_recorder && fvm flutter test test/update/updater_service_test.dart
```

Expected: PASS (both tests).

- [ ] **Step 7: Initialize the updater in main() and override the provider**

In `packages/screen_recorder/lib/main.dart`:

Add to the import block (near the other `dart:` imports at the top):

```dart
import 'dart:io' show Platform;
```

Add with the other local imports (alphabetically near `update`/`ui`):

```dart
import 'update/updater_backend.dart';
import 'update/updater_service.dart';
```

Just before the `runApp(ProviderScope(` call (after the other services are constructed, around line 176), add:

```dart
  // Auto-update (macOS only). Construct once, wire Sparkle's feed + daily
  // background check at startup, and share the same instance with the
  // Settings "Check for updates" tile via the provider override below.
  final updaterService = UpdaterService(SparkleUpdaterBackend());
  if (Platform.isMacOS) {
    unawaited(updaterService.init());
  }
```

Inside the `overrides: [` list, add one entry (place it after `wallpaperFavoritesProvider.overrideWith(...)`, before the closing `]`):

```dart
      updaterServiceProvider.overrideWithValue(updaterService),
```

- [ ] **Step 8: Wire the Settings "Check for updates" tile**

In `packages/screen_recorder/lib/ui/screens/settings_screen.dart`:

Add to the import block (with the other relative imports):

```dart
import '../../update/updater_service.dart';
```

Replace the disabled tile (currently around lines 305-314):

```dart
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.system_update_alt,
                  color: context.palette.textSecondary),
              title: Text('Check for updates',
                  style: TextStyle(color: context.palette.textSecondary)),
              subtitle: Text('Coming soon',
                  style: TextStyle(color: context.palette.textSecondary)),
              enabled: false,
            ),
```

with:

```dart
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.system_update_alt,
                  color: context.palette.textPrimary),
              title: Text('Check for updates',
                  style: TextStyle(color: context.palette.textPrimary)),
              trailing: Icon(Icons.chevron_right,
                  size: 16, color: context.palette.textSecondary),
              onTap: () async {
                try {
                  await ref.read(updaterServiceProvider).checkForUpdates();
                } catch (_) {
                  // Sparkle unavailable (non-macOS / test host) — nothing to do.
                }
              },
            ),
```

- [ ] **Step 9: Analyze + run the full package test suite**

```bash
cd packages/screen_recorder && fvm flutter analyze && fvm flutter test
```

Expected: analyze reports no new issues; the suite passes (including the new updater tests).

- [ ] **Step 10: Commit**

```bash
git add packages/screen_recorder/pubspec.yaml packages/screen_recorder/pubspec.lock \
  packages/screen_recorder/lib/update/ packages/screen_recorder/test/update/ \
  packages/screen_recorder/lib/main.dart \
  packages/screen_recorder/lib/ui/screens/settings_screen.dart
git commit -m "feat(update): auto_updater plugin + UpdaterService, wire Check-for-updates tile (#1)"
```

---

## Task 3: Info.plist Sparkle keys

**Files:**
- Modify: `packages/screen_recorder/macos/Runner/Info.plist`

**Interfaces:**
- Consumes: the `SUPublicEDKey` base64 value the user generated in Task 1 (`generate_keys`). Obtain the actual value from the user before editing; do not invent one — a wrong key makes every real update fail signature validation.

- [ ] **Step 1: Add the Sparkle keys**

In `packages/screen_recorder/macos/Runner/Info.plist`, inside the top-level `<dict>` (e.g. after the `NSCameraUsageDescription` entry, before `</dict>`), add:

```xml
	<key>SUFeedURL</key>
	<string>https://mohn93.github.io/slipreel/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>PASTE_THE_SUPUBLICEDKEY_FROM_TASK_1</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
```

Replace `PASTE_THE_SUPUBLICEDKEY_FROM_TASK_1` with the exact base64 public key printed by `generate_keys` in Task 1 (ask the user for it if not already in the conversation).

- [ ] **Step 2: Validate the plist is well-formed**

```bash
plutil -lint packages/screen_recorder/macos/Runner/Info.plist
```

Expected: `packages/screen_recorder/macos/Runner/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/macos/Runner/Info.plist
git commit -m "feat(update): Sparkle Info.plist keys (feed URL, EdDSA public key, daily checks) (#1)"
```

---

## Task 4: Monotonic build number (`scripts/lib/version.sh`)

**Files:**
- Create: `scripts/lib/version.sh`
- Create: `scripts/lib/version.test.sh`

**Interfaces:**
- Produces: `derive_build_number <major.minor.patch>` — echoes `major*1000000 + minor*1000 + patch` to stdout; returns non-zero (message on stderr) for non-integer components or minor/patch `>= 1000`. Sourceable with no side effects.

This is its own task because it is the correctness pivot (§3 of the spec): Sparkle compares the appcast `sparkle:version` against the installed `CFBundleVersion`, so the release must stamp a strictly increasing integer or updates are never offered.

- [ ] **Step 1: Write the failing test**

Create `scripts/lib/version.test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for derive_build_number. Run: bash scripts/lib/version.test.sh
set -euo pipefail
source "$(dirname "$0")/version.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

eq "$(derive_build_number 1.0.0)" 1000000
eq "$(derive_build_number 1.0.1)" 1000001
eq "$(derive_build_number 1.1.0)" 1001000
eq "$(derive_build_number 2.0.0)" 2000000
eq "$(derive_build_number 10.20.30)" 10020030

# strictly increasing across a realistic release sequence
prev=0
for v in 1.0.0 1.0.1 1.0.9 1.1.0 1.2.0 2.0.0 10.0.0; do
  n="$(derive_build_number "$v")"
  (( n > prev )) || fail "$v -> $n not greater than previous $prev"
  prev="$n"
done

# rejects malformed input
if derive_build_number 1.2 2>/dev/null; then fail "accepted '1.2'"; fi
if derive_build_number 1.0.x 2>/dev/null; then fail "accepted '1.0.x'"; fi
if derive_build_number 1.0.1000 2>/dev/null; then fail "accepted patch >= 1000"; fi
if derive_build_number 1.1000.0 2>/dev/null; then fail "accepted minor >= 1000"; fi

echo "version.test.sh: OK"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash scripts/lib/version.test.sh
```

Expected: FAIL — `version.sh` does not exist (source error).

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/version.sh`:

```bash
#!/usr/bin/env bash
# Shared version helpers for the release pipeline. Sourceable, no side effects.

# Sparkle decides "is the appcast newer than what's installed?" by comparing
# the appcast's sparkle:version against the running app's CFBundleVersion.
# Flutter maps CFBundleVersion to the build number, so it MUST increase every
# release. Derive a strictly-increasing integer from the semver instead of
# hand-bumping pubspec's +N. Assumes minor and patch < 1000 (validated).
derive_build_number() { # derive_build_number <major.minor.patch>
  local v="${1:-}" major minor patch
  IFS=. read -r major minor patch <<<"$v"
  if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
    echo "derive_build_number: version must be MAJOR.MINOR.PATCH integers, got '$v'" >&2
    return 1
  fi
  if (( minor >= 1000 || patch >= 1000 )); then
    echo "derive_build_number: minor/patch must be < 1000 for a monotonic build number (got '$v')" >&2
    return 1
  fi
  echo $(( major * 1000000 + minor * 1000 + patch ))
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash scripts/lib/version.test.sh
```

Expected: `version.test.sh: OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/version.sh scripts/lib/version.test.sh
git commit -m "feat(release): monotonic build number derived from semver (#1)"
```

---

## Task 5: Appcast generator (`scripts/update-appcast.sh`)

**Files:**
- Create: `scripts/update-appcast.sh`
- Create: `scripts/update-appcast.test.sh`

**Interfaces:**
- Consumes: `sign_update` on PATH (from `brew install sparkle`); optional `SPARKLE_ED_KEY_FILE` env (else the login keychain key).
- Produces: `update-appcast.sh <version> <build_number> <dmg_path> <enclosure_url> [appcast_path]` — EdDSA-signs the DMG and prepends a versioned `<item>` to the appcast (creating the channel skeleton if absent). Idempotent: re-running the same version replaces that version's item rather than duplicating it. Default `appcast_path` is `dist/appcast.xml`.

- [ ] **Step 1: Write the failing test**

Create `scripts/update-appcast.test.sh`:

```bash
#!/usr/bin/env bash
# Test for update-appcast.sh using a fake sign_update. Run: bash scripts/update-appcast.test.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake sign_update on PATH: prints a canned Sparkle signature line.
cat > "$tmp/sign_update" <<'FAKE'
#!/usr/bin/env bash
echo 'sparkle:edSignature="FAKESIG==" length="42"'
FAKE
chmod +x "$tmp/sign_update"
export PATH="$tmp:$PATH"

appcast="$tmp/appcast.xml"
touch "$tmp/Slipreel-1.0.0.dmg" "$tmp/Slipreel-1.0.1.dmg"

# first release creates the skeleton and the 1.0.0 item
"$here/update-appcast.sh" 1.0.0 1000000 "$tmp/Slipreel-1.0.0.dmg" \
  "https://example.com/Slipreel-1.0.0.dmg" "$appcast"
grep -q '<sparkle:version>1000000</sparkle:version>' "$appcast" || fail "missing 1.0.0 version"
grep -q 'sparkle:edSignature="FAKESIG=="' "$appcast" || fail "missing signature"
grep -q 'url="https://example.com/Slipreel-1.0.0.dmg"' "$appcast" || fail "missing enclosure url"

# second release prepends 1.0.1 and keeps 1.0.0
"$here/update-appcast.sh" 1.0.1 1000001 "$tmp/Slipreel-1.0.1.dmg" \
  "https://example.com/Slipreel-1.0.1.dmg" "$appcast"
grep -q '<sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>' "$appcast" || fail "dropped 1.0.0"
grep -q '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>' "$appcast" || fail "missing 1.0.1"
first="$(grep -n 'shortVersionString' "$appcast" | head -1)"
[[ "$first" == *1.0.1* ]] || fail "1.0.1 not prepended (newest first)"

# idempotent: re-running 1.0.1 leaves exactly one 1.0.1 item
"$here/update-appcast.sh" 1.0.1 1000001 "$tmp/Slipreel-1.0.1.dmg" \
  "https://example.com/Slipreel-1.0.1.dmg" "$appcast"
count="$(grep -c '<sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>' "$appcast")"
[[ "$count" == "1" ]] || fail "duplicate 1.0.1 items ($count)"

# well-formed XML (skip gracefully if xmllint is absent)
if command -v xmllint >/dev/null; then
  xmllint --noout "$appcast" || fail "appcast is not well-formed XML"
fi

echo "update-appcast.test.sh: OK"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash scripts/update-appcast.test.sh
```

Expected: FAIL — `update-appcast.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `scripts/update-appcast.sh`:

```bash
#!/usr/bin/env bash
# Generate/append a Sparkle appcast entry for a released DMG. Build-machine
# only (needs the `sparkle` CLI: brew install sparkle). EdDSA-signs the DMG and
# prepends a versioned <item> to appcast.xml (newest first), creating the
# channel skeleton on first run. Idempotent per version.
#
# Usage: update-appcast.sh <version> <build_number> <dmg> <enclosure_url> [appcast]
#   Signing key: SPARKLE_ED_KEY_FILE=<file> (else the login-keychain key).
set -euo pipefail

VERSION="${1:?usage: update-appcast.sh <version> <build_number> <dmg> <url> [appcast]}"
BUILD="${2:?build_number required}"
DMG="${3:?dmg path required}"
URL="${4:?enclosure url required}"
APPCAST="${5:-dist/appcast.xml}"
MIN_OS="13.0"
FEED_TITLE="Slipreel"
FEED_LINK="https://mohn93.github.io/slipreel/appcast.xml"

command -v sign_update >/dev/null \
  || { echo "ERROR: sign_update not found: brew install sparkle (build-machine only)" >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "ERROR: DMG not found: $DMG" >&2; exit 1; }

# EdDSA-sign the DMG. sign_update prints:  sparkle:edSignature="..." length="..."
sign_args=()
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && sign_args=(-f "$SPARKLE_ED_KEY_FILE")
sig="$(sign_update ${sign_args[@]+"${sign_args[@]}"} "$DMG")" \
  || { echo "ERROR: sign_update failed (missing EdDSA key? see docs/release/SETUP.md)" >&2; exit 1; }
grep -q 'sparkle:edSignature=' <<<"$sig" \
  || { echo "ERROR: sign_update output missing edSignature: $sig" >&2; exit 1; }

pubdate="$(LC_ALL=C date -u +'%a, %d %b %Y %H:%M:%S +0000')"

# The <item> block. sig already carries the edSignature + length attributes.
item="    <item>
      <title>${FEED_TITLE} ${VERSION}</title>
      <pubDate>${pubdate}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <enclosure url=\"${URL}\" ${sig} type=\"application/octet-stream\" />
    </item>"

mkdir -p "$(dirname "$APPCAST")"

if [[ ! -f "$APPCAST" ]]; then
  cat > "$APPCAST" <<SKEL
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${FEED_TITLE}</title>
    <link>${FEED_LINK}</link>
    <description>Slipreel updates</description>
    <language>en</language>
    <!-- ITEMS -->
  </channel>
</rss>
SKEL
fi

# Drop any existing <item> for this version (idempotent replace), then insert
# the fresh item right after the marker so newest is first.
tmp="$(mktemp)"
awk -v ver="$VERSION" '
  /<item>/ { buf=$0 ORS; inItem=1; hit=0; next }
  inItem {
    buf=buf $0 ORS
    if (index($0, "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>")) hit=1
    if ($0 ~ /<\/item>/) { if (!hit) printf "%s", buf; inItem=0; buf="" }
    next
  }
  { print }
' "$APPCAST" > "$tmp"

awk -v item="$item" '
  { print }
  /<!-- ITEMS -->/ { print item }
' "$tmp" > "$APPCAST"
rm -f "$tmp"

echo "update-appcast: wrote $VERSION ($BUILD) -> $APPCAST"
```

- [ ] **Step 4: Make it executable and run the test to verify it passes**

```bash
chmod +x scripts/update-appcast.sh && bash scripts/update-appcast.test.sh
```

Expected: `update-appcast.test.sh: OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/update-appcast.sh scripts/update-appcast.test.sh
git commit -m "feat(release): update-appcast.sh signs DMG + prepends Sparkle item (#1)"
```

---

## Task 6: release-macos.sh — build number, Sparkle-framework verify, local appcast

**Files:**
- Modify: `scripts/release-macos.sh`

**Interfaces:**
- Consumes: `derive_build_number` (Task 4), `scripts/update-appcast.sh` (Task 5).
- Produces: a release build stamped with the monotonic `CFBundleVersion`, a verify-stage assertion that Sparkle's nested executables are hardened, and `dist/appcast.xml` (honoring `APPCAST_PATH` override).

- [ ] **Step 1: Source version.sh and derive the build number**

In `scripts/release-macos.sh`, after the line `FLUTTER="${FLUTTER:-fvm flutter}"` (around line 18), add:

```bash
# shellcheck source=scripts/lib/version.sh
source "$ROOT/scripts/lib/version.sh"
BUILD_NUMBER="$(derive_build_number "$VERSION")" \
  || die "invalid version '$VERSION' (need MAJOR.MINOR.PATCH, minor/patch < 1000)"
```

- [ ] **Step 2: Stamp the build during the build stage**

In the stage-1 build step, change the build command from:

```bash
( cd "$APP_PKG" && $FLUTTER clean >/dev/null && $FLUTTER build macos --release ) \
  || die "flutter build macos --release failed"
```

to:

```bash
log "release $VERSION -> CFBundleShortVersionString $VERSION, CFBundleVersion $BUILD_NUMBER"
( cd "$APP_PKG" && $FLUTTER clean >/dev/null \
    && $FLUTTER build macos --release \
        --build-name="$VERSION" --build-number="$BUILD_NUMBER" ) \
  || die "flutter build macos --release failed"
```

- [ ] **Step 3: Verify Sparkle's nested executables are hardened**

In the stage-2 verify section, immediately after the Helpers hardened-runtime `for b in ffmpeg ffprobe whisper-cli; do ... done` loop (before the app-authority check), add:

```bash
# Sparkle ships nested executables (Autoupdate, Updater.app, XPC services)
# inside Sparkle.framework; each must be hardened or notarization rejects the
# bundle. Xcode's deep-sign over use_frameworks! normally covers embedded
# frameworks — assert it here (capture-then-grep, same rationale as the
# Helpers loop) to fail before the notarization round-trip, not after. Only
# Mach-O *executables* need the runtime flag; skip the Sparkle dylib itself.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE_FW" ]] || die "Sparkle.framework missing from the bundle (auto_updater not embedded?)"
while IFS= read -r macho; do
  [[ "$(file -b "$macho")" == *"Mach-O"*"executable"* ]] || continue
  fhdr="$(codesign --display --verbose=2 "$macho" 2>&1)" \
    || die "codesign could not read $macho:"$'\n'"$fhdr"
  grep -q "flags=.*runtime" <<<"$fhdr" \
    || die "Sparkle executable not hardened: $macho ($(grep -oE 'flags=[^ ]+' <<<"$fhdr" || echo 'no flags line'))"
done < <(find "$SPARKLE_FW" -type f -perm -111)
log "Sparkle.framework nested executables hardened"
```

- [ ] **Step 4: Generate the local appcast after the final gate**

At the very end of the script, after the final `log "DONE: $DMG ..."` line, add:

```bash
# --- stage 8: appcast entry (Sparkle auto-update) ---------------------------
# The enclosure points at the GitHub Release asset the workflow publishes for
# this tag; the URL is deterministic from the tag + DMG name. Written locally
# for inspection/e2e; CI republishes the canonical accumulating feed to
# gh-pages (honors APPCAST_PATH so CI can target its own copy).
REPO_SLUG="${REPO_SLUG:-mohn93/slipreel}"
ENCLOSURE_URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION/$(basename "$DMG")"
APPCAST_OUT="${APPCAST_PATH:-$DIST/appcast.xml}"
if command -v sign_update >/dev/null; then
  log "writing appcast entry -> $APPCAST_OUT"
  "$ROOT/scripts/update-appcast.sh" "$VERSION" "$BUILD_NUMBER" "$DMG" "$ENCLOSURE_URL" "$APPCAST_OUT" \
    || die "appcast generation failed"
else
  log "sparkle tools absent (brew install sparkle) — skipping appcast entry"
fi
```

- [ ] **Step 5: Syntax-check the script**

```bash
bash -n scripts/release-macos.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/release-macos.sh
git commit -m "feat(release): stamp monotonic build, verify Sparkle framework, emit appcast (#1)"
```

---

## Task 7: Release workflow — install sparkle, publish appcast to gh-pages

**Files:**
- Modify: `.github/workflows/release-macos.yml`

**Interfaces:**
- Consumes: `scripts/lib/version.sh`, `scripts/update-appcast.sh`, GitHub Secret `SPARKLE_ED_PRIVATE_KEY`.
- Produces: `Sparkle.framework` embedded in the CI build (via `flutter pub get` + pods) and the published `appcast.xml` on the `gh-pages` branch.

- [ ] **Step 1: Install the sparkle CLI alongside create-dmg**

In `.github/workflows/release-macos.yml`, change the create-dmg step:

```yaml
      - name: Install create-dmg
        run: brew install create-dmg
```

to:

```yaml
      - name: Install create-dmg and sparkle
        run: brew install create-dmg sparkle
```

- [ ] **Step 2: Sign with the CI key file during the release step**

In the "Release pipeline" step's `env:` block, add the Sparkle key file path, and write the secret to it just before running the script. Change the step from:

```yaml
      - name: Release pipeline
        env:
          # CI installs plain `flutter` (subosito), not fvm — override the
          # script's `fvm flutter` default.
          FLUTTER: flutter
          NOTARY_KEY: ${{ runner.temp }}/notary.p8
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER: ${{ secrets.NOTARY_ISSUER_ID }}
        run: scripts/release-macos.sh "${{ steps.ver.outputs.version }}"
```

to:

```yaml
      - name: Release pipeline
        env:
          # CI installs plain `flutter` (subosito), not fvm — override the
          # script's `fvm flutter` default.
          FLUTTER: flutter
          NOTARY_KEY: ${{ runner.temp }}/notary.p8
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER: ${{ secrets.NOTARY_ISSUER_ID }}
          SPARKLE_ED_KEY_FILE: ${{ runner.temp }}/sparkle_ed_priv
        run: |
          printf '%s' "${{ secrets.SPARKLE_ED_PRIVATE_KEY }}" > "$SPARKLE_ED_KEY_FILE"
          scripts/release-macos.sh "${{ steps.ver.outputs.version }}"
```

- [ ] **Step 3: Publish the appcast to gh-pages after the release**

After the "Publish GitHub Release" step and before the "Clean up keychain + key" step, add two steps:

```yaml
      - name: Build appcast against the published feed
        env:
          SPARKLE_ED_KEY_FILE: ${{ runner.temp }}/sparkle_ed_priv
        run: |
          source scripts/lib/version.sh
          BUILD="$(derive_build_number "${{ steps.ver.outputs.version }}")"
          DMG="$(ls dist/Slipreel-*.dmg)"
          URL="https://github.com/${{ github.repository }}/releases/download/v${{ steps.ver.outputs.version }}/$(basename "$DMG")"
          mkdir -p out
          # Start from the currently-published feed so history accumulates;
          # first release 404s and update-appcast.sh creates the skeleton.
          curl -fsSL https://mohn93.github.io/slipreel/appcast.xml -o out/appcast.xml || true
          scripts/update-appcast.sh "${{ steps.ver.outputs.version }}" "$BUILD" "$DMG" "$URL" out/appcast.xml

      - name: Deploy appcast to GitHub Pages
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./out
          keep_files: true
```

- [ ] **Step 4: Delete the Sparkle key in cleanup**

Change the final cleanup step from:

```yaml
      - name: Clean up keychain + key
        if: always()
        run: |
          rm -f "$RUNNER_TEMP/notary.p8"
          security delete-keychain "$RUNNER_TEMP/build.keychain" || true
```

to:

```yaml
      - name: Clean up keychain + keys
        if: always()
        run: |
          rm -f "$RUNNER_TEMP/notary.p8" "$RUNNER_TEMP/sparkle_ed_priv"
          security delete-keychain "$RUNNER_TEMP/build.keychain" || true
```

- [ ] **Step 5: Validate the workflow YAML**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-macos.yml')); print('yaml OK')"
```

Expected: `yaml OK`

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release-macos.yml
git commit -m "ci(release): install sparkle, publish appcast to gh-pages (#1)"
```

---

## Task 8: Local end-to-end verification

**Files:** none (verification only; no code changes unless a check fails).

**Interfaces:**
- Consumes: everything above. This is the acceptance gate for the branch, mirroring sub-project A's Task 7. The full "install an update" path needs two published tags and is the user-run CI gate; this task verifies everything that can be checked locally.

- [ ] **Step 1: Bootstrap and static-check the whole change**

```bash
melos bootstrap
bash scripts/lib/version.test.sh
bash scripts/update-appcast.test.sh
bash -n scripts/release-macos.sh && echo "release syntax OK"
cd packages/screen_recorder && fvm flutter analyze && fvm flutter test && cd -
```

Expected: both bash tests print `OK`, `release syntax OK`, analyze clean, Dart suite green.

- [ ] **Step 2: Confirm the plugin embeds Sparkle.framework (release build)**

```bash
cd packages/screen_recorder && fvm flutter build macos --release && cd -
ls -d packages/screen_recorder/build/macos/Build/Products/Release/Slipreel.app/Contents/Frameworks/Sparkle.framework \
  && echo "Sparkle embedded"
```

Expected: the path lists and prints `Sparkle embedded`. (This is a plain dev build — ad-hoc signed — so the hardened-runtime assertions are not exercised here; that happens under `release-macos.sh`.)

- [ ] **Step 3: Sanity-check the appcast the release script would emit**

Run the release script far enough to produce an appcast only if the user's Developer ID + notary creds are set up and they want a full local release. Otherwise verify the appcast generator directly against the just-built DMG-less path is covered by Task 5's test. If doing a full local release:

```bash
NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 1.0.1
xmllint --noout dist/appcast.xml && echo "appcast well-formed"
grep -q '<sparkle:version>1000001</sparkle:version>' dist/appcast.xml && echo "version stamped"
```

Expected: `appcast well-formed` and `version stamped`. (Skip if not doing a full notarized local release; the CI path is the authoritative gate.)

- [ ] **Step 4: Manual UI check (optional, requires a running app)**

Launch the release build, open Settings → About, click "Check for updates". Expect Sparkle's native dialog to appear (either "up to date" or, once a newer appcast entry exists, an update prompt). This confirms the tile wiring end to end.

- [ ] **Step 5: Final branch status**

```bash
git status && git log --oneline main..HEAD
```

Expected: clean tree; the commit log shows Tasks 1-7. Ready to open a PR to `main`.

---

## Self-Review

**Spec coverage:**
- Integration (`auto_updater` + Sparkle) → Task 2. ✓
- Appcast host = GitHub Pages / gh-pages → Task 7 (deploy) + Task 5 (feed shape). ✓
- Check cadence auto + manual → Task 2 (interval + tile) + Info.plist `SUEnableAutomaticChecks` Task 3. ✓
- Sparkle native dialog → Task 2 (no custom UI; foreground `checkForUpdates`). ✓
- Update payload = reuse notarized DMG → Task 5 (enclosure → release DMG). ✓
- Info.plist keys (SUFeedURL, SUPublicEDKey, auto keys) → Task 3. ✓
- Monotonic version scheme → Task 4 + Task 6 (stamp). ✓
- update-appcast.sh sign + prepend/merge + skeleton + idempotent → Task 5. ✓
- release-macos.sh build-number + Sparkle-framework verify + appcast call → Task 6. ✓
- Workflow: brew install sparkle, SPARKLE_ED_PRIVATE_KEY, gh-pages push → Task 7. ✓
- SETUP.md runbook + secret + Pages → Task 1. ✓
- Release notes deferred (non-goal for v1) → not implemented, per spec. ✓
- Testing (bash tests, monotonic test, well-formed item, suite green, e2e) → Tasks 4, 5, 8. ✓

**Placeholder scan:** The only intentional fill-in is the `SUPublicEDKey` value in Task 3, which is a real user-provided secret sourced at implementation time (Task 1 generates it) — explicitly flagged, not a vague TODO. No "add error handling"/"similar to Task N" placeholders; all code is shown in full.

**Type/name consistency:** `UpdaterBackend` (methods `setFeedURL`, `setScheduledCheckInterval`, `checkForUpdates`), `SparkleUpdaterBackend`, `UpdaterService` (`init`, `checkForUpdates`, `feedUrl`, `scheduledCheckInterval`), `updaterServiceProvider` used identically in Tasks 2 (define), 2 (main override + tile). `derive_build_number` identical in Tasks 4, 6, 7. `update-appcast.sh` arg order `<version> <build_number> <dmg> <url> [appcast]` identical in Tasks 5, 6, 7. `SPARKLE_ED_KEY_FILE` / `SPARKLE_ED_PRIVATE_KEY` consistent across Tasks 1, 5, 7. Feed URL string identical everywhere. ✓
