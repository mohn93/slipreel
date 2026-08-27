# Flutter Licensing — Native Integration (Phase 5b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the pure-Dart licensing core (Phase 5a) into the running macOS app: register the `slipreel://` URL scheme, receive the deep-linked entitlement token, derive a stable device fingerprint natively, refresh tokens over HTTP, and expose a Riverpod `LicensingController` so the rest of the app can read entitlement state.

**Architecture:** A `LicensingController` (Riverpod, constructed in `main.dart` like `UpdaterService`) owns the entitlement lifecycle. On start it loads the cached token from the Keychain (`SecureLicenseStore` from 5a), verifies it offline (`EntitlementVerifier` from 5a) against a **baked-in Ed25519 public key**, and publishes an `EntitlementState`. "Unlock export" mints a one-time `state` nonce and opens `slipreel.app/pricing?device=<fp>&state=<nonce>` in the browser via `url_launcher`; the web flow deep-links `slipreel://auth?token=&refresh=&device_id=&state=` back, delivered by `app_links`. The controller checks the `state` echo, verifies the token, persists `{token, refresh, device_id}`, and flips the state. A daily/launch `POST /v1/token/refresh` re-mints. The device fingerprint is the sha256 of the macOS `IOPlatformUUID`, fetched over a new `slipreel/device` MethodChannel mirroring the existing `slipreel/window` one.

**Tech Stack:** Flutter/Dart, Riverpod, `app_links` (deep links), `url_launcher` (already present), `http` (already present transitively — add explicit), `crypto` (already present, for sha256), `cryptography` + `flutter_secure_storage` (Phase 5a), Swift/IOKit (native channel).

**Spec:** docs/superpowers/specs/2026-08-26-stripe-licensing-design.md (§4 token format, §8 desktop activation flow, §9 Flutter app changes).

## Global Constraints

- Package under work: `packages/screen_recorder` (Dart package name `screen_recorder`). Run all Flutter commands with `fvm flutter` from `packages/screen_recorder`.
- **NEVER run `dart format`** on existing or new files — the repo's pinned formatter reflows unrelated lines. `fvm flutter analyze` is the style/lint gate. Match surrounding style by hand.
- No emoji in commit messages, code comments, or docs. Succinct, straightforward.
- Stage only files you changed (`git add <path>` per file). Never `git add -A` / `git add .`. Other agents may share the checkout.
- Branch: `feat/stripe-licensing` (already checked out). Do NOT open a PR or merge; commits accumulate on the branch (PR #65 already tracks it).
- All Stripe/server work is TEST MODE. API base default (release) `https://api.slipreel.app`; site base default (release) `https://slipreel.app`. Debug overridable via `--dart-define`.
- The token/refresh contract is fixed by the server (do not change it): `POST /v1/token/refresh` with JSON `{ "refresh_token": string, "device_id": string }` → `200 { "token": string }` on success, `401 { "error": "invalid refresh token" }` otherwise.
- The deep link shape is fixed by the Phase 4b web pages: `slipreel://auth?token=<jwt>&refresh=<rt>&device_id=<dev_...>&state=<nonce>`.
- Phase 5a public interfaces this plan consumes (do NOT modify their signatures):
  - `EntitlementVerifier(List<int> publicKeyBytes, {String issuer})` with `Future<EntitlementClaims?> verify(String jwt, {DateTime? now, bool ignoreExpiry})`.
  - `EntitlementClaims` (fields: `sub`, `plan`, `exportEntitled`, `status`, `updatesUntil`, `deviceId`, `seatLimit`, `issuedAt`, `expiresAt`).
  - Sealed `EntitlementState`: `EntitlementLoading`, `EntitlementSignedOut`, `EntitlementLoaded(EntitlementClaims claims)`; and `bool canExport(EntitlementClaims claims, {required DateTime appReleaseDate, DateTime? now})`.
  - `LicenseTokens({required String token, required String refreshToken, required String deviceId})` (JSON keys `token` / `refresh` / `device_id`); `LicenseStore` interface (`Future<void> save(LicenseTokens)`, `Future<LicenseTokens?> load()`, `Future<void> clear()`); `InMemoryLicenseStore`; `SecureLicenseStore(SecureKV)`; `SecureKV` interface (`Future<String?> read(key)`, `Future<void> write(key, value)`, `Future<void> delete(key)`); `FlutterSecureKV([FlutterSecureStorage?])`.

---

## File Structure

- `packages/screen_recorder/lib/licensing/licensing_config.dart` — CREATE. Compile-time API/site base + baked public key + app release date consts.
- `packages/screen_recorder/lib/licensing/entitlement_public_key.g.dart` — CREATE (generated-style). The raw 32-byte Ed25519 public key baked in.
- `packages/screen_recorder/lib/licensing/build_release_date.g.dart` — CREATE (generated-style). `const buildReleaseDate`.
- `packages/screen_recorder/lib/licensing/device_fingerprint.dart` — CREATE. `DeviceFingerprint` (native channel → sha256 hex).
- `packages/screen_recorder/lib/licensing/licensing_api.dart` — CREATE. `LicensingApi.refresh(...)`.
- `packages/screen_recorder/lib/licensing/auth_state_store.dart` — CREATE. Pending `state` nonce persistence + pricing-URL builder.
- `packages/screen_recorder/lib/licensing/deep_link.dart` — CREATE. Pure parser for `slipreel://auth?...`.
- `packages/screen_recorder/lib/licensing/licensing_controller.dart` — CREATE. Riverpod controller + `entitlementProvider`.
- `packages/screen_recorder/macos/Runner/MainFlutterWindow.swift` — MODIFY. Add the `slipreel/device` channel.
- `packages/screen_recorder/macos/Runner/Info.plist` — MODIFY. Add `CFBundleURLTypes` (scheme `slipreel`).
- `packages/screen_recorder/pubspec.yaml` — MODIFY. Add `app_links`, explicit `http`.
- `packages/screen_recorder/lib/main.dart` — MODIFY. Construct + wire `LicensingController`; start deep-link listener; provider override.
- Tests under `packages/screen_recorder/test/licensing/`.

---

## Task 1: Dependencies + `slipreel://` URL scheme registration

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml`
- Modify: `packages/screen_recorder/macos/Runner/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: `app_links` and `http` available to later tasks; `slipreel://` scheme registered so macOS routes deep links to the app.

- [ ] **Step 1: Add deps to pubspec**

In `packages/screen_recorder/pubspec.yaml`, under `dependencies:` (near the existing `url_launcher: ^6.2.0` and `crypto: ^3.0.3`), add:

```yaml
  app_links: ^6.3.0
  http: ^1.2.0
```

- [ ] **Step 2: Resolve**

Run: `cd packages/screen_recorder && fvm flutter pub get`
Expected: resolves without version conflicts. If `app_links` pulls a newer major, record the resolved version but keep the caret as written unless it fails.

- [ ] **Step 3: Register the URL scheme in Info.plist**

In `packages/screen_recorder/macos/Runner/Info.plist`, add this key/value inside the top-level `<dict>` (place it right after the `NSPrincipalClass` block):

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.slipreel.app</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>slipreel</string>
			</array>
		</dict>
	</array>
```

- [ ] **Step 4: Verify analyze still clean**

Run: `cd packages/screen_recorder && fvm flutter analyze`
Expected: no new issues (deps added, nothing imports them yet).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/pubspec.yaml packages/screen_recorder/pubspec.lock packages/screen_recorder/macos/Runner/Info.plist
git commit -m "feat(app): register slipreel:// scheme, add app_links + http deps"
```

---

## Task 2: Baked public key, release date, and licensing config

**Files:**
- Create: `packages/screen_recorder/lib/licensing/entitlement_public_key.g.dart`
- Create: `packages/screen_recorder/lib/licensing/build_release_date.g.dart`
- Create: `packages/screen_recorder/lib/licensing/licensing_config.dart`
- Test: `packages/screen_recorder/test/licensing/licensing_config_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `const List<int> kEntitlementPublicKey` (raw 32-byte Ed25519 key).
  - `const DateTime buildReleaseDate` (UTC).
  - `class LicensingConfig` with `static const String apiBase`, `static const String siteBase`, `static String get apiBaseResolved` / `siteBaseResolved` (honor `--dart-define`).

- [ ] **Step 1: Extract the raw public key bytes from the server key**

The server's `ENTITLEMENT_ED25519_PUBLIC_KEY` (in `server/.env`) is base64 of the SPKI DER. For Ed25519 the SPKI DER is 44 bytes: a 12-byte prefix + the 32-byte raw key. Extract the raw 32 bytes:

Run (from repo root):

```bash
node -e 'const b=process.env.PK; if(!b){console.error("set PK");process.exit(1)} const d=Buffer.from(b,"base64"); const raw=d.subarray(d.length-32); console.log(JSON.stringify([...raw]))' PK="$(grep -E "^ENTITLEMENT_ED25519_PUBLIC_KEY=" server/.env | cut -d= -f2-)"
```

Expected: prints a JSON array of 32 integers. If `server/.env` is absent locally, generate a throwaway keypair with `npm --prefix server run gen:entitlement-keys` and use its public line (this is TEST mode; the production key is baked at release time). Record which key was used.

- [ ] **Step 2: Write the baked key file**

Create `packages/screen_recorder/lib/licensing/entitlement_public_key.g.dart` (paste the 32 ints from Step 1 in place of the ellipsis):

```dart
// GENERATED at build/release time from the server's ENTITLEMENT_ED25519 public
// key (raw 32-byte Ed25519 key, i.e. the SPKI DER minus its 12-byte prefix).
// Regenerate whenever the server signing key rotates. See the Phase 5b plan,
// Task 2, for the extraction command. Public key only — safe to commit.
const List<int> kEntitlementPublicKey = <int>[
  // 32 bytes:
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];
```

- [ ] **Step 3: Write the release-date file**

Create `packages/screen_recorder/lib/licensing/build_release_date.g.dart`:

```dart
// GENERATED at release time. The one-time export ceiling (spec §2/§4) compares
// this build's release date against the token's `updates_until`. The release
// pipeline overwrites this with the actual publish date; the checked-in value
// is the date this build was cut.
const DateTime buildReleaseDate = _buildReleaseDate;
final DateTime _buildReleaseDate = DateTime.utc(2026, 8, 27);
```

Note: a top-level `const DateTime` cannot call `DateTime.utc(...)` (not a const constructor), so expose it via a `final`. Consumers read `buildReleaseDate`.

- [ ] **Step 4: Write the failing config test**

Create `packages/screen_recorder/test/licensing/licensing_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/build_release_date.g.dart';
import 'package:screen_recorder/licensing/entitlement_public_key.g.dart';
import 'package:screen_recorder/licensing/licensing_config.dart';

void main() {
  test('baked public key is 32 bytes', () {
    expect(kEntitlementPublicKey.length, 32);
    for (final b in kEntitlementPublicKey) {
      expect(b, inInclusiveRange(0, 255));
    }
  });

  test('build release date is UTC', () {
    expect(buildReleaseDate.isUtc, isTrue);
  });

  test('release-mode bases default to production hosts', () {
    // With no --dart-define overrides, resolved bases fall back to the consts.
    expect(LicensingConfig.apiBaseResolved, LicensingConfig.apiBase);
    expect(LicensingConfig.siteBaseResolved, LicensingConfig.siteBase);
    expect(LicensingConfig.apiBase, 'https://api.slipreel.app');
    expect(LicensingConfig.siteBase, 'https://slipreel.app');
  });
}
```

- [ ] **Step 5: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_config_test.dart`
Expected: FAIL — `licensing_config.dart` does not exist.

- [ ] **Step 6: Write the config**

Create `packages/screen_recorder/lib/licensing/licensing_config.dart`:

```dart
/// Compile-time licensing endpoints. Release builds target the production
/// hosts; debug builds can point at a local server via --dart-define:
///   flutter run --dart-define=SLIPREEL_API_BASE=http://localhost:8787 \
///               --dart-define=SLIPREEL_SITE_BASE=http://localhost:8788
class LicensingConfig {
  const LicensingConfig._();

  static const String apiBase = 'https://api.slipreel.app';
  static const String siteBase = 'https://slipreel.app';

  static const String _apiOverride =
      String.fromEnvironment('SLIPREEL_API_BASE');
  static const String _siteOverride =
      String.fromEnvironment('SLIPREEL_SITE_BASE');

  static String get apiBaseResolved =>
      _apiOverride.isEmpty ? apiBase : _apiOverride;
  static String get siteBaseResolved =>
      _siteOverride.isEmpty ? siteBase : _siteOverride;
}
```

- [ ] **Step 7: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_config_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder/lib/licensing/entitlement_public_key.g.dart packages/screen_recorder/lib/licensing/build_release_date.g.dart packages/screen_recorder/lib/licensing/licensing_config.dart packages/screen_recorder/test/licensing/licensing_config_test.dart
git commit -m "feat(app): baked entitlement pubkey, release date, licensing config"
```

---

## Task 3: Device fingerprint (native channel + sha256)

**Files:**
- Create: `packages/screen_recorder/lib/licensing/device_fingerprint.dart`
- Modify: `packages/screen_recorder/macos/Runner/MainFlutterWindow.swift`
- Test: `packages/screen_recorder/test/licensing/device_fingerprint_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `class DeviceFingerprint({MethodChannel? channel})` with `Future<String> compute()` returning the lowercase hex sha256 of the native hardware id. Throws `DeviceFingerprintUnavailable` if the native side returns null/empty.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/licensing/device_fingerprint_test.dart`:

```dart
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/device_fingerprint.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('slipreel/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('hashes the native hardware id with sha256', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'hardwareId');
      return 'ABCDEF12-3456-7890-ABCD-EF1234567890';
    });
    final fp = await DeviceFingerprint().compute();
    final expected = sha256
        .convert(utf8.encode('ABCDEF12-3456-7890-ABCD-EF1234567890'))
        .toString();
    expect(fp, expected);
    expect(fp.length, 64);
  });

  test('throws when native id is missing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(DeviceFingerprint().compute(),
        throwsA(isA<DeviceFingerprintUnavailable>()));
  });
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/device_fingerprint_test.dart`
Expected: FAIL — `device_fingerprint.dart` missing.

- [ ] **Step 3: Write the Dart side**

Create `packages/screen_recorder/lib/licensing/device_fingerprint.dart`:

```dart
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Thrown when the platform cannot supply a stable hardware id.
class DeviceFingerprintUnavailable implements Exception {
  const DeviceFingerprintUnavailable();
  @override
  String toString() => 'DeviceFingerprintUnavailable';
}

/// Stable per-machine fingerprint: sha256 of the macOS IOPlatformUUID, fetched
/// over the `slipreel/device` channel (handled in MainFlutterWindow.swift).
/// The raw UUID never leaves the device; only its hash is sent to the server.
class DeviceFingerprint {
  DeviceFingerprint({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('slipreel/device');

  final MethodChannel _channel;

  Future<String> compute() async {
    final raw = await _channel.invokeMethod<String>('hardwareId');
    if (raw == null || raw.isEmpty) {
      throw const DeviceFingerprintUnavailable();
    }
    return sha256.convert(utf8.encode(raw)).toString();
  }
}
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/device_fingerprint_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the native channel handler**

In `packages/screen_recorder/macos/Runner/MainFlutterWindow.swift`:

At the top, add `import IOKit` under the existing imports:

```swift
import Cocoa
import FlutterMacOS
import IOKit
```

Inside `awakeFromNib()`, right after the existing `channel.setMethodCallHandler { ... }` closure block (before `RegisterGeneratedPlugins`), register the device channel:

```swift
    let deviceChannel = FlutterMethodChannel(
      name: "slipreel/device",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "hardwareId":
        result(Self.hardwareUUID())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
```

Add this static helper as a method on `MainFlutterWindow` (place it near the other private helpers):

```swift
  /// The Mac's stable hardware UUID (IOPlatformUUID). Survives reinstalls and
  /// app updates; changes only with a logic-board swap. Returns nil if the
  /// registry lookup fails (the Dart side treats nil as "unavailable").
  private static func hardwareUUID() -> String? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let cf = IORegistryEntryCreateCFProperty(
      service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
    return cf?.takeRetainedValue() as? String
  }
```

Note: `kIOMainPortDefault` requires the macOS 12 SDK (the deployment target is already 12+ for this app). If a build errors on the symbol, fall back to `kIOMasterPortDefault` (deprecated but functional).

- [ ] **Step 6: Verify the native code compiles (build check deferred to Task 8)**

The Swift change is verified when the app is built in Task 8. For now, re-run analyze to confirm the Dart side is clean:

Run: `cd packages/screen_recorder && fvm flutter analyze`
Expected: no new issues.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/licensing/device_fingerprint.dart packages/screen_recorder/test/licensing/device_fingerprint_test.dart packages/screen_recorder/macos/Runner/MainFlutterWindow.swift
git commit -m "feat(app): device fingerprint via IOPlatformUUID sha256"
```

---

## Task 4: Licensing HTTP client (token refresh)

**Files:**
- Create: `packages/screen_recorder/lib/licensing/licensing_api.dart`
- Test: `packages/screen_recorder/test/licensing/licensing_api_test.dart`

**Interfaces:**
- Consumes: `LicensingConfig` (Task 2) for the default base URL.
- Produces: `class LicensingApi({String? baseUrl, http.Client? client})` with `Future<String?> refresh({required String refreshToken, required String deviceId})` — returns the new JWT string on 200, `null` on 401/other/non-JSON/network error. (The app never calls `/v1/token` directly — that is minted by the web session; the app only refreshes.)

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/licensing/licensing_api_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/licensing/licensing_api.dart';

void main() {
  test('refresh posts refresh_token + device_id and returns token', () async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'token': 'new.jwt.here'}), 200,
          headers: {'content-type': 'application/json'});
    });
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    final token = await api.refresh(refreshToken: 'rt_123', deviceId: 'dev_9');

    expect(token, 'new.jwt.here');
    expect(seen.url.toString(), 'https://api.example.test/v1/token/refresh');
    expect(seen.method, 'POST');
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['refresh_token'], 'rt_123');
    expect(body['device_id'], 'dev_9');
    expect(seen.headers['content-type'], contains('application/json'));
  });

  test('refresh returns null on 401', () async {
    final client = MockClient((req) async =>
        http.Response(jsonEncode({'error': 'invalid refresh token'}), 401));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'), isNull);
  });

  test('refresh returns null on network error', () async {
    final client = MockClient((req) async => throw http.ClientException('down'));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'), isNull);
  });

  test('refresh returns null when body has no token', () async {
    final client =
        MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'), isNull);
  });
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_api_test.dart`
Expected: FAIL — `licensing_api.dart` missing.

- [ ] **Step 3: Implement**

Create `packages/screen_recorder/lib/licensing/licensing_api.dart`:

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'licensing_config.dart';

/// Thin HTTP client for the VPS licensing endpoints the app calls directly.
/// The only app-initiated call is token refresh; initial minting happens in
/// the browser (web session), delivered back via the slipreel:// deep link.
class LicensingApi {
  LicensingApi({String? baseUrl, http.Client? client})
      : _baseUrl = baseUrl ?? LicensingConfig.apiBaseResolved,
        _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  /// POST /v1/token/refresh. Returns the new signed entitlement token, or null
  /// on any failure (auth rejected, network down, malformed response). Callers
  /// keep using the cached token until its own `exp` on a null result.
  Future<String?> refresh({
    required String refreshToken,
    required String deviceId,
  }) async {
    try {
      final res = await _client.post(
        Uri.parse('$_baseUrl/v1/token/refresh'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'refresh_token': refreshToken,
          'device_id': deviceId,
        }),
      );
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['token'] is String) {
        return decoded['token'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_api_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/licensing/licensing_api.dart packages/screen_recorder/test/licensing/licensing_api_test.dart
git commit -m "feat(app): licensing api client (token refresh)"
```

---

## Task 5: Auth-state nonce + deep-link parser

**Files:**
- Create: `packages/screen_recorder/lib/licensing/auth_state_store.dart`
- Create: `packages/screen_recorder/lib/licensing/deep_link.dart`
- Test: `packages/screen_recorder/test/licensing/auth_state_store_test.dart`
- Test: `packages/screen_recorder/test/licensing/deep_link_test.dart`

**Interfaces:**
- Consumes: `SecureKV` / `InMemorySecureKV` (Phase 5a, in `license_store.dart`), `LicensingConfig` (Task 2).
- Produces:
  - `class AuthStateStore(SecureKV kv)` with `Future<String> begin()` (generates + persists a fresh nonce, returns it), `Future<bool> matches(String state)`, `Future<void> clear()`, and `Uri pricingUrl({required String deviceFingerprint, required String state})`.
  - `class AuthDeepLink({required String token, required String refresh, required String deviceId, required String state})` with `static AuthDeepLink? parse(Uri uri)` — returns null unless the URI is `slipreel://auth` with all four params present and non-empty.

- [ ] **Step 1: Write the failing deep-link parser test**

Create `packages/screen_recorder/test/licensing/deep_link_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/deep_link.dart';

void main() {
  test('parses a well-formed slipreel://auth link', () {
    final uri = Uri.parse(
        'slipreel://auth?token=jwt.abc&refresh=rt_1&device_id=dev_2&state=n0nce');
    final link = AuthDeepLink.parse(uri);
    expect(link, isNotNull);
    expect(link!.token, 'jwt.abc');
    expect(link.refresh, 'rt_1');
    expect(link.deviceId, 'dev_2');
    expect(link.state, 'n0nce');
  });

  test('rejects wrong host', () {
    final uri = Uri.parse('slipreel://other?token=a&refresh=b&device_id=c&state=d');
    expect(AuthDeepLink.parse(uri), isNull);
  });

  test('rejects wrong scheme', () {
    final uri = Uri.parse('https://auth?token=a&refresh=b&device_id=c&state=d');
    expect(AuthDeepLink.parse(uri), isNull);
  });

  test('rejects when a param is missing', () {
    final uri = Uri.parse('slipreel://auth?token=a&refresh=b&device_id=c');
    expect(AuthDeepLink.parse(uri), isNull);
  });

  test('rejects when a param is empty', () {
    final uri =
        Uri.parse('slipreel://auth?token=&refresh=b&device_id=c&state=d');
    expect(AuthDeepLink.parse(uri), isNull);
  });
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/deep_link_test.dart`
Expected: FAIL — `deep_link.dart` missing.

- [ ] **Step 3: Implement the parser**

Create `packages/screen_recorder/lib/licensing/deep_link.dart`:

```dart
/// Parsed `slipreel://auth?token=&refresh=&device_id=&state=` callback from the
/// web activation flow. The shape is fixed by the site's success/login pages.
class AuthDeepLink {
  const AuthDeepLink({
    required this.token,
    required this.refresh,
    required this.deviceId,
    required this.state,
  });

  final String token;
  final String refresh;
  final String deviceId;
  final String state;

  /// Returns null unless [uri] is a slipreel://auth link with all four params
  /// present and non-empty. Note macOS delivers the authority as the URI host.
  static AuthDeepLink? parse(Uri uri) {
    if (uri.scheme != 'slipreel') return null;
    if (uri.host != 'auth') return null;
    final q = uri.queryParameters;
    final token = q['token'] ?? '';
    final refresh = q['refresh'] ?? '';
    final deviceId = q['device_id'] ?? '';
    final state = q['state'] ?? '';
    if (token.isEmpty || refresh.isEmpty || deviceId.isEmpty || state.isEmpty) {
      return null;
    }
    return AuthDeepLink(
      token: token,
      refresh: refresh,
      deviceId: deviceId,
      state: state,
    );
  }
}
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/deep_link_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing auth-state test**

Create `packages/screen_recorder/test/licensing/auth_state_store_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/auth_state_store.dart';
import 'package:screen_recorder/licensing/license_store.dart';

void main() {
  test('begin persists a nonce that matches once', () async {
    final store = AuthStateStore(InMemorySecureKV());
    final nonce = await store.begin();
    expect(nonce, isNotEmpty);
    expect(await store.matches(nonce), isTrue);
    expect(await store.matches('wrong'), isFalse);
  });

  test('begin generates a fresh nonce each call', () async {
    final store = AuthStateStore(InMemorySecureKV());
    final a = await store.begin();
    final b = await store.begin();
    expect(a, isNot(b));
    // Only the latest pending nonce is valid.
    expect(await store.matches(a), isFalse);
    expect(await store.matches(b), isTrue);
  });

  test('matches is false when nothing pending', () async {
    final store = AuthStateStore(InMemorySecureKV());
    expect(await store.matches('anything'), isFalse);
  });

  test('pricingUrl carries device + state', () {
    final store = AuthStateStore(InMemorySecureKV());
    final url = store.pricingUrl(deviceFingerprint: 'fp_abc', state: 'n1');
    expect(url.path, '/pricing');
    expect(url.queryParameters['device'], 'fp_abc');
    expect(url.queryParameters['state'], 'n1');
  });
}
```

- [ ] **Step 6: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/auth_state_store_test.dart`
Expected: FAIL — `auth_state_store.dart` missing.

- [ ] **Step 7: Implement the auth-state store**

Create `packages/screen_recorder/lib/licensing/auth_state_store.dart`:

```dart
import 'dart:convert';
import 'dart:math';

import 'licensing_config.dart';
import 'license_store.dart';

/// Owns the single-use `state` nonce for the browser activation handoff, and
/// builds the pricing URL that carries the device fingerprint + nonce. The
/// nonce guards against a stray/forged deep link activating a token: only the
/// nonce the app just generated is accepted on the callback.
class AuthStateStore {
  AuthStateStore(this._kv);

  final SecureKV _kv;
  static const _key = 'slipreel.auth_state';

  /// Generates a fresh 256-bit nonce, persists it as the sole pending state,
  /// and returns it. Any previously pending nonce is overwritten.
  Future<String> begin() async {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final nonce = base64Url.encode(bytes).replaceAll('=', '');
    await _kv.write(_key, nonce);
    return nonce;
  }

  /// True iff [state] equals the currently pending nonce (constant-time-ish
  /// equality on equal-length strings is not required here — the nonce is
  /// single-use and unguessable).
  Future<bool> matches(String state) async {
    final pending = await _kv.read(_key);
    if (pending == null || pending.isEmpty) return false;
    return pending == state;
  }

  Future<void> clear() => _kv.delete(_key);

  /// `${siteBase}/pricing?device=<fp>&state=<nonce>`.
  Uri pricingUrl({
    required String deviceFingerprint,
    required String state,
  }) {
    final base = Uri.parse(LicensingConfig.siteBaseResolved);
    return base.replace(
      path: '/pricing',
      queryParameters: {'device': deviceFingerprint, 'state': state},
    );
  }
}
```

Note: this uses `SecureKV.read/write/delete`. Confirm those exact method names exist in `license_store.dart` (Phase 5a); if the interface uses different names, match them (do not change the 5a interface).

- [ ] **Step 8: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/auth_state_store_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 9: Commit**

```bash
git add packages/screen_recorder/lib/licensing/deep_link.dart packages/screen_recorder/lib/licensing/auth_state_store.dart packages/screen_recorder/test/licensing/deep_link_test.dart packages/screen_recorder/test/licensing/auth_state_store_test.dart
git commit -m "feat(app): auth state nonce store + deep-link parser"
```

---

## Task 6: LicensingController — load, verify, refresh

**Files:**
- Create: `packages/screen_recorder/lib/licensing/licensing_controller.dart`
- Test: `packages/screen_recorder/test/licensing/licensing_controller_test.dart`

**Interfaces:**
- Consumes: `SecureLicenseStore`/`LicenseStore`, `LicenseTokens`, `EntitlementVerifier`, `EntitlementClaims`, `EntitlementState` (5a); `LicensingApi` (Task 4); `AuthStateStore` (Task 5).
- Produces:
  - `class LicensingController extends StateNotifier<EntitlementState>` constructed with `{required LicenseStore store, required EntitlementVerifier verifier, required LicensingApi api, required AuthStateStore authState, DateTime Function() now = DateTime.now}`.
  - `Future<void> load()` — reads cached tokens, verifies, sets state to `EntitlementLoaded` or `EntitlementSignedOut`.
  - `Future<void> refreshNow()` — calls `api.refresh`, on success verifies + persists + updates state; on failure keeps current state.
  - `final licensingControllerProvider = StateNotifierProvider<LicensingController, EntitlementState>(...)` (throws until overridden in `main.dart`).
  - `final entitlementProvider = Provider<EntitlementState>((ref) => ref.watch(licensingControllerProvider));`

- [ ] **Step 1: Write the failing test (load + refresh paths)**

Create `packages/screen_recorder/test/licensing/licensing_controller_test.dart`. Use a fake verifier and a fake api so no network/crypto is exercised (the real verifier is already covered by Phase 5a tests):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';
import 'package:screen_recorder/licensing/auth_state_store.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/licensing/licensing_api.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';

// A verifier stub: returns a preset claims for a known token string.
class _FakeVerifier extends EntitlementVerifier {
  _FakeVerifier(this._table) : super(const <int>[]);
  final Map<String, EntitlementClaims?> _table;
  @override
  Future<EntitlementClaims?> verify(String jwt,
          {DateTime? now, bool ignoreExpiry = false}) async =>
      _table[jwt];
}

// An api stub returning a queued refresh result.
class _FakeApi extends LicensingApi {
  _FakeApi(this.result) : super(baseUrl: 'https://x.test');
  String? result;
  String? lastRefreshToken;
  @override
  Future<String?> refresh(
      {required String refreshToken, required String deviceId}) async {
    lastRefreshToken = refreshToken;
    return result;
  }
}

EntitlementClaims _claims({required String device}) => EntitlementClaims(
      sub: 'usr_1',
      plan: 'subscription',
      exportEntitled: true,
      status: 'active',
      updatesUntil: null,
      deviceId: device,
      seatLimit: 2,
      issuedAt: DateTime.utc(2026, 8, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
    );

void main() {
  LicensingController build(
      {LicenseStore? store, _FakeVerifier? verifier, _FakeApi? api}) {
    return LicensingController(
      store: store ?? InMemoryLicenseStore(),
      verifier: verifier ?? _FakeVerifier(const {}),
      api: api ?? _FakeApi(null),
      authState: AuthStateStore(InMemorySecureKV()),
    );
  }

  test('load with no cached token -> signed out', () async {
    final c = build();
    await c.load();
    expect(c.state, isA<EntitlementSignedOut>());
  });

  test('load with a valid cached token -> loaded', () async {
    final store = InMemoryLicenseStore();
    await store.save(const LicenseTokens(
        token: 'tok', refreshToken: 'rt', deviceId: 'dev_1'));
    final c = build(
      store: store,
      verifier: _FakeVerifier({'tok': _claims(device: 'dev_1')}),
    );
    await c.load();
    expect(c.state, isA<EntitlementLoaded>());
    expect((c.state as EntitlementLoaded).claims.sub, 'usr_1');
  });

  test('load with an unverifiable cached token -> signed out', () async {
    final store = InMemoryLicenseStore();
    await store.save(const LicenseTokens(
        token: 'bad', refreshToken: 'rt', deviceId: 'dev_1'));
    final c = build(store: store, verifier: _FakeVerifier(const {'bad': null}));
    await c.load();
    expect(c.state, isA<EntitlementSignedOut>());
  });

  test('refreshNow success replaces token + state', () async {
    final store = InMemoryLicenseStore();
    await store.save(const LicenseTokens(
        token: 'old', refreshToken: 'rt', deviceId: 'dev_1'));
    final api = _FakeApi('fresh');
    final c = build(
      store: store,
      verifier: _FakeVerifier({'fresh': _claims(device: 'dev_1')}),
      api: api,
    );
    await c.load(); // signed out (old not in table)
    await c.refreshNow();
    expect(api.lastRefreshToken, 'rt');
    expect(c.state, isA<EntitlementLoaded>());
    final saved = await store.load();
    expect(saved!.token, 'fresh');
    expect(saved.refreshToken, 'rt'); // refresh token unchanged by /refresh
  });

  test('refreshNow with no cached tokens is a no-op', () async {
    final c = build();
    await c.load();
    await c.refreshNow();
    expect(c.state, isA<EntitlementSignedOut>());
  });

  test('refreshNow failure keeps existing state', () async {
    final store = InMemoryLicenseStore();
    await store.save(const LicenseTokens(
        token: 'good', refreshToken: 'rt', deviceId: 'dev_1'));
    final c = build(
      store: store,
      verifier: _FakeVerifier({'good': _claims(device: 'dev_1')}),
      api: _FakeApi(null), // refresh fails
    );
    await c.load();
    expect(c.state, isA<EntitlementLoaded>());
    await c.refreshNow();
    expect(c.state, isA<EntitlementLoaded>()); // unchanged
  });
}
```

Note: the fake verifier `extends EntitlementVerifier` and overrides `verify`; confirm `EntitlementVerifier.verify` is not `final` (it should be a plain method). If 5a marks the class non-extendable, instead introduce a minimal `abstract class TokenVerifier { Future<EntitlementClaims?> verify(...) }` that `EntitlementVerifier` implements, and type the controller against `TokenVerifier` — but prefer extending if possible to avoid touching 5a.

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_controller_test.dart`
Expected: FAIL — `licensing_controller.dart` missing.

- [ ] **Step 3: Implement the controller (load + refresh only for now)**

Create `packages/screen_recorder/lib/licensing/licensing_controller.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_state_store.dart';
import 'entitlement.dart';
import 'entitlement_verifier.dart';
import 'license_store.dart';
import 'licensing_api.dart';

/// Owns the entitlement lifecycle: loads the cached token on launch, verifies
/// it offline, and re-mints via /v1/token/refresh. Deep-link activation and
/// the browser handoff are added in Task 7.
class LicensingController extends StateNotifier<EntitlementState> {
  LicensingController({
    required LicenseStore store,
    required EntitlementVerifier verifier,
    required LicensingApi api,
    required AuthStateStore authState,
    DateTime Function() now = DateTime.now,
  })  : _store = store,
        _verifier = verifier,
        _api = api,
        _authState = authState,
        _now = now,
        super(const EntitlementLoading());

  final LicenseStore _store;
  final EntitlementVerifier _verifier;
  final LicensingApi _api;
  final AuthStateStore _authState;
  final DateTime Function() _now;

  /// Read the Keychain token, verify it, publish loaded/signed-out. Called once
  /// at startup before the UI reads entitlement.
  Future<void> load() async {
    final tokens = await _store.load();
    if (tokens == null) {
      state = const EntitlementSignedOut();
      return;
    }
    final claims = await _verifier.verify(tokens.token, now: _now());
    state = claims == null
        ? const EntitlementSignedOut()
        : EntitlementLoaded(claims);
  }

  /// Re-mint from the stored refresh token. No-op without cached tokens; keeps
  /// current state if the network/auth call fails (offline grace lives in the
  /// cached token's own exp).
  Future<void> refreshNow() async {
    final tokens = await _store.load();
    if (tokens == null) return;
    final fresh = await _api.refresh(
      refreshToken: tokens.refreshToken,
      deviceId: tokens.deviceId,
    );
    if (fresh == null) return;
    final claims = await _verifier.verify(fresh, now: _now());
    if (claims == null) return;
    await _store.save(LicenseTokens(
      token: fresh,
      refreshToken: tokens.refreshToken,
      deviceId: tokens.deviceId,
    ));
    state = EntitlementLoaded(claims);
  }
}

/// Overridden in main.dart with the fully-wired instance.
final licensingControllerProvider =
    StateNotifierProvider<LicensingController, EntitlementState>((ref) {
  throw UnimplementedError(
      'licensingControllerProvider must be overridden in main.dart');
});

/// Read-only entitlement state for gates/UI.
final entitlementProvider = Provider<EntitlementState>(
  (ref) => ref.watch(licensingControllerProvider),
);
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_controller_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/licensing/licensing_controller.dart packages/screen_recorder/test/licensing/licensing_controller_test.dart
git commit -m "feat(app): LicensingController load + refresh"
```

---

## Task 7: LicensingController — deep-link activation, unlock, sign-out

**Files:**
- Modify: `packages/screen_recorder/lib/licensing/licensing_controller.dart`
- Test: `packages/screen_recorder/test/licensing/licensing_controller_activation_test.dart`

**Interfaces:**
- Consumes: `AuthDeepLink` (Task 5), `DeviceFingerprint` (Task 3), an injectable URL opener.
- Produces (new methods on `LicensingController`):
  - `Future<void> handleDeepLink(Uri uri)` — parses; if it is an auth link and `authState.matches(state)`, verifies the token, persists `{token, refresh, device_id}`, clears the nonce, sets `EntitlementLoaded`; ignores non-matching/invalid links (no state change).
  - `Future<bool> unlockExport()` — computes the fingerprint, `authState.begin()`, opens `authState.pricingUrl(...)` via the injected opener; returns whether the browser launch was requested.
  - `Future<void> signOut()` — clears the store + auth nonce, sets `EntitlementSignedOut`.
  - Constructor gains `{DeviceFingerprint? fingerprint, Future<bool> Function(Uri) openUrl}` (opener defaults to `url_launcher.launchUrl`).

- [ ] **Step 1: Write the failing activation test**

Create `packages/screen_recorder/test/licensing/licensing_controller_activation_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';
import 'package:screen_recorder/licensing/auth_state_store.dart';
import 'package:screen_recorder/licensing/device_fingerprint.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/licensing/licensing_api.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';

class _FakeVerifier extends EntitlementVerifier {
  _FakeVerifier(this._table) : super(const <int>[]);
  final Map<String, EntitlementClaims?> _table;
  @override
  Future<EntitlementClaims?> verify(String jwt,
          {DateTime? now, bool ignoreExpiry = false}) async =>
      _table[jwt];
}

EntitlementClaims _claims() => EntitlementClaims(
      sub: 'usr_1',
      plan: 'subscription',
      exportEntitled: true,
      status: 'active',
      updatesUntil: null,
      deviceId: 'dev_1',
      seatLimit: 2,
      issuedAt: DateTime.utc(2026, 8, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('slipreel/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('valid deep link with matching state activates', () async {
    final store = InMemoryLicenseStore();
    final auth = AuthStateStore(InMemorySecureKV());
    final nonce = await auth.begin();
    final c = LicensingController(
      store: store,
      verifier: _FakeVerifier({'jwt.ok': _claims()}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: auth,
      openUrl: (_) async => true,
    );
    await c.handleDeepLink(Uri.parse(
        'slipreel://auth?token=jwt.ok&refresh=rt_9&device_id=dev_1&state=$nonce'));
    expect(c.state, isA<EntitlementLoaded>());
    final saved = await store.load();
    expect(saved!.token, 'jwt.ok');
    expect(saved.refreshToken, 'rt_9');
    expect(saved.deviceId, 'dev_1');
    // Nonce consumed.
    expect(await auth.matches(nonce), isFalse);
  });

  test('deep link with wrong state is ignored', () async {
    final store = InMemoryLicenseStore();
    final auth = AuthStateStore(InMemorySecureKV());
    await auth.begin();
    final c = LicensingController(
      store: store,
      verifier: _FakeVerifier({'jwt.ok': _claims()}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: auth,
      openUrl: (_) async => true,
    );
    await c.load(); // signed out
    await c.handleDeepLink(Uri.parse(
        'slipreel://auth?token=jwt.ok&refresh=rt&device_id=dev_1&state=WRONG'));
    expect(c.state, isA<EntitlementSignedOut>());
    expect(await store.load(), isNull);
  });

  test('deep link with unverifiable token is ignored', () async {
    final store = InMemoryLicenseStore();
    final auth = AuthStateStore(InMemorySecureKV());
    final nonce = await auth.begin();
    final c = LicensingController(
      store: store,
      verifier: _FakeVerifier(const {'jwt.bad': null}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: auth,
      openUrl: (_) async => true,
    );
    await c.load();
    await c.handleDeepLink(Uri.parse(
        'slipreel://auth?token=jwt.bad&refresh=rt&device_id=dev_1&state=$nonce'));
    expect(c.state, isA<EntitlementSignedOut>());
    expect(await store.load(), isNull);
  });

  test('unlockExport opens the pricing url with device + state', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => 'HW-UUID-123');
    Uri? opened;
    final auth = AuthStateStore(InMemorySecureKV());
    final c = LicensingController(
      store: InMemoryLicenseStore(),
      verifier: _FakeVerifier(const {}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: auth,
      openUrl: (u) async {
        opened = u;
        return true;
      },
    );
    final ok = await c.unlockExport();
    expect(ok, isTrue);
    expect(opened, isNotNull);
    expect(opened!.path, '/pricing');
    expect(opened!.queryParameters['device'], isNotEmpty);
    expect(opened!.queryParameters['state'], isNotEmpty);
    // The state we opened with is the one now pending.
    expect(await auth.matches(opened!.queryParameters['state']!), isTrue);
  });

  test('signOut clears the store and state', () async {
    final store = InMemoryLicenseStore();
    await store.save(const LicenseTokens(
        token: 't', refreshToken: 'r', deviceId: 'd'));
    final c = LicensingController(
      store: store,
      verifier: _FakeVerifier(const {}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: AuthStateStore(InMemorySecureKV()),
      openUrl: (_) async => true,
    );
    await c.signOut();
    expect(c.state, isA<EntitlementSignedOut>());
    expect(await store.load(), isNull);
  });
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_controller_activation_test.dart`
Expected: FAIL — the new methods/params do not exist yet.

- [ ] **Step 3: Extend the controller**

Edit `packages/screen_recorder/lib/licensing/licensing_controller.dart`:

Add imports at the top:

```dart
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'deep_link.dart';
import 'device_fingerprint.dart';
```

Add the two new constructor params (opener + fingerprint) and fields:

```dart
    DeviceFingerprint? fingerprint,
    Future<bool> Function(Uri url)? openUrl,
```

Wire them in the initializer list:

```dart
        _fingerprint = fingerprint ?? DeviceFingerprint(),
        _openUrl = openUrl ?? _defaultOpen,
```

Fields + default opener:

```dart
  final DeviceFingerprint _fingerprint;
  final Future<bool> Function(Uri url) _openUrl;

  static Future<bool> _defaultOpen(Uri url) =>
      launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication);
```

Add the methods:

```dart
  /// Handle a slipreel:// callback. Ignores anything that is not a valid auth
  /// link whose `state` matches the nonce we last generated (guards against a
  /// forged/stray deep link activating a token). On success: verify, persist,
  /// consume the nonce, publish loaded.
  Future<void> handleDeepLink(Uri uri) async {
    final link = AuthDeepLink.parse(uri);
    if (link == null) return;
    if (!await _authState.matches(link.state)) return;
    final claims = await _verifier.verify(link.token, now: _now());
    if (claims == null) return;
    await _store.save(LicenseTokens(
      token: link.token,
      refreshToken: link.refresh,
      deviceId: link.deviceId,
    ));
    await _authState.clear();
    state = EntitlementLoaded(claims);
  }

  /// Start the browser purchase/sign-in flow. Generates a fresh nonce, then
  /// opens ${site}/pricing?device=<fp>&state=<nonce>. Returns whether the
  /// browser launch was requested (false if url_launcher declined).
  Future<bool> unlockExport() async {
    final fp = await _fingerprint.compute();
    final nonce = await _authState.begin();
    final url = _authState.pricingUrl(deviceFingerprint: fp, state: nonce);
    return _openUrl(url);
  }

  /// Clear local credentials and the pending nonce; revert to signed-out.
  /// (Server-side seat release via DELETE /v1/devices/:id is done from the web
  /// account page; a native call can be added later.)
  Future<void> signOut() async {
    await _store.clear();
    await _authState.clear();
    state = const EntitlementSignedOut();
  }
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_controller_activation_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the whole licensing suite**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/`
Expected: all Phase 5a + 5b licensing tests PASS. Then `fvm flutter analyze` — no new issues.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/licensing/licensing_controller.dart packages/screen_recorder/test/licensing/licensing_controller_activation_test.dart
git commit -m "feat(app): deep-link activation, unlock, sign-out"
```

---

## Task 8: Wire into main.dart + app_links listener + run-app verification

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`
- Create: `packages/screen_recorder/lib/licensing/deep_link_listener.dart`

**Interfaces:**
- Consumes: everything above.
- Produces: a constructed, loaded `LicensingController` provided via `ProviderScope.overrides`; an `app_links` subscription that forwards incoming + initial URIs to `controller.handleDeepLink`.

- [ ] **Step 1: Deep-link listener wrapper**

Create `packages/screen_recorder/lib/licensing/deep_link_listener.dart`:

```dart
import 'dart:async';

import 'package:app_links/app_links.dart';

import 'licensing_controller.dart';

/// Bridges app_links to the LicensingController. Forwards the cold-start link
/// (if the app was launched by a slipreel:// URL) and every subsequent link.
class DeepLinkListener {
  DeepLinkListener(this._controller, {AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final LicensingController _controller;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  Future<void> start() async {
    final initial = await _appLinks.getInitialLink();
    if (initial != null) {
      await _controller.handleDeepLink(initial);
    }
    _sub = _appLinks.uriLinkStream.listen((uri) {
      _controller.handleDeepLink(uri);
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}
```

- [ ] **Step 2: Construct + load in main(), before runApp**

In `packages/screen_recorder/lib/main.dart`, add imports near the other `licensing`/service imports:

```dart
import 'licensing/auth_state_store.dart';
import 'licensing/deep_link_listener.dart';
import 'licensing/entitlement_public_key.g.dart';
import 'licensing/entitlement_verifier.dart';
import 'licensing/license_store.dart';
import 'licensing/licensing_api.dart';
import 'licensing/licensing_controller.dart';
```

(Adjust the relative prefix to match how other imports in `main.dart` are written — they may use `package:screen_recorder/...`. Match the file's existing convention.)

Just after the `updaterService` block (around line 184, before `runApp`), add:

```dart
  // Licensing: load the cached entitlement token, verify it offline, and wire
  // the slipreel:// deep-link handoff. Constructed here (like UpdaterService)
  // so the same instance is shared via the provider override below.
  final licensingStore = SecureLicenseStore(FlutterSecureKV());
  final licensingController = LicensingController(
    store: licensingStore,
    verifier: EntitlementVerifier(kEntitlementPublicKey),
    api: LicensingApi(),
    authState: AuthStateStore(FlutterSecureKV()),
  );
  await licensingController.load();
  final deepLinkListener = DeepLinkListener(licensingController);
  unawaited(deepLinkListener.start());
  if (Platform.isMacOS) {
    // Refresh in the background on launch (best-effort; offline keeps cache).
    unawaited(licensingController.refreshNow());
  }
```

Note: confirm `FlutterSecureKV` is the concrete `SecureKV` from Phase 5a's `license_store.dart`. If its constructor needs a `FlutterSecureStorage` argument, pass a default `FlutterSecureKV()` as 5a defines it.

- [ ] **Step 3: Add the provider override**

In the `overrides:` list of the `ProviderScope` (near `updaterServiceProvider.overrideWithValue(updaterService)`), add:

```dart
      licensingControllerProvider.overrideWith((ref) => licensingController),
```

- [ ] **Step 4: Analyze**

Run: `cd packages/screen_recorder && fvm flutter analyze`
Expected: no new issues. Fix any import path mismatches.

- [ ] **Step 5: Build the macOS app (verifies the Swift channel + Info.plist compile)**

Run: `cd packages/screen_recorder && fvm flutter build macos --debug`
Expected: build succeeds. If `kIOMainPortDefault` is unresolved, switch to `kIOMasterPortDefault` (Task 3, Step 5 note) and rebuild.

- [ ] **Step 6: Run the app and verify the deep-link round-trip (hybrid manual verification)**

Launch the app (debug) pointing at a reachable API/site if available, otherwise verify the deep-link plumbing in isolation:

1. Start the app: `cd packages/screen_recorder && fvm flutter run -d macos` (or attach via the flutter-qa MCP / simulator tooling).
2. Confirm the app started signed-out (no cached token): entitlement state is `EntitlementSignedOut` (inspect via a debug log line you add temporarily, or the flutter-qa probe).
3. Trigger a deep link from a terminal to exercise `app_links` + the parser + nonce guard. First make the app generate + persist a nonce by invoking `unlockExport()` (temporarily from a debug affordance) — capture the `state` it opened with from logs — then:

```bash
open "slipreel://auth?token=<a-token-signed-by-the-test-key>&refresh=rt_test&device_id=dev_test&state=<the-nonce>"
```

Expected: the app logs the deep link, verifies, persists to Keychain, and flips to `EntitlementLoaded`. If you do not yet have a token signed by the baked key, this end-to-end verification lands in Phase 7 (live server) — in that case verify up to the nonce-mismatch rejection path (a link with `state=WRONG` must be ignored) and confirm the app received the URL at all.

4. Screenshot / log the state transition as proof.

Note: the automated tests (Tasks 3–7) already prove the parse/verify/persist/nonce logic headlessly; this step proves the native URL delivery + Keychain + build wiring that unit tests cannot.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/main.dart packages/screen_recorder/lib/licensing/deep_link_listener.dart
git commit -m "feat(app): wire LicensingController + deep-link listener into main"
```

---

## Self-Review Notes (author checklist — resolved)

- **Spec §8 coverage:** fingerprint (Task 3), nonce + pricing URL open (Task 5/7), app_links delivery + state check + offline verify + Keychain persist (Tasks 5–8), `CFBundleURLTypes` (Task 1). Covered.
- **Spec §4 coverage:** offline verify uses the 5a verifier + baked key (Task 2/6). `canExport`/release-date ceiling: the const lands here (Task 2); the actual gate call is Phase 6 (not this plan) — noted, not a gap.
- **Spec §9 coverage:** `licensing_controller.dart`, `licensing_api.dart`, `device_fingerprint.dart`, `entitlementProvider` all present. `entitlement_token_verifier.dart` naming: 5a shipped it as `entitlement_verifier.dart` — consistent with 5a, not the spec's tentative name. Fine.
- **Deferred (explicitly not in this plan):** the paywall UI + export gate (Phase 6); native seat-release on sign-out (web handles it); the release pipeline overwriting `build_release_date.g.dart` (ops); live token round-trip needing the deployed server + real signing key (Phase 7).
- **Type consistency:** `LicenseTokens` fields `token`/`refreshToken`/`deviceId`; `EntitlementVerifier.verify(jwt, {now, ignoreExpiry})`; `SecureKV.read/write/delete` — all as consumed. Confirm the `SecureKV` method names against 5a in Task 5, Step 7 (the one interface detail to double-check before writing).
