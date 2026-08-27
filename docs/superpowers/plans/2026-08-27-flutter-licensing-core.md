# Flutter Licensing Core Implementation Plan (Phase 5a)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Dart licensing core inside the macOS app (`packages/screen_recorder/lib/licensing/`): the entitlement-token claims model, an offline Ed25519 JWT verifier, the client-side `canExport` rule, and a secure token store — all unit-tested with `flutter test`, with no native/plugin coupling in the tested logic.

**Architecture:** The server mints EdDSA (Ed25519) JWT entitlement tokens (Phase 3). This module verifies them **offline** against an embedded public key (injected, so tests use an ephemeral keypair), parses the claims, and derives whether export is unlocked from `plan`/`status`/`updates_until` plus the app's build release date. Token bytes live behind a `LicenseStore` abstraction (an in-memory fake for tests; a `flutter_secure_storage`/Keychain impl behind a tiny `SecureKV` interface for the app). This plan builds the testable core only; the native integration — device-id method channel, `slipreel://` URL scheme + `app_links`, the HTTP refresh client, the Riverpod controller, and `main.dart` wiring — is **Phase 5b**.

**Tech Stack:** Dart/Flutter (fvm), `flutter_test`, the `cryptography` package (Ed25519), `flutter_secure_storage` (Keychain, behind an interface). The existing `crypto` dep (sha256) is used later (5b fingerprint), not here.

**Spec:** [docs/superpowers/specs/2026-08-26-stripe-licensing-design.md](../specs/2026-08-26-stripe-licensing-design.md) (§2 entitlement rules, §4 token format)

**Builds on:** Phases 1–4b (branch `feat/stripe-licensing`, PR #65) — the server that mints these tokens and the web pages that hand them off. This plan adds only app-side Dart; it wires nothing into the running app yet (that is 5b).

## Global Constraints

- **Location:** all code under `packages/screen_recorder/lib/licensing/`; tests under `packages/screen_recorder/test/licensing/`. Package name is `screen_recorder` (import as `package:screen_recorder/licensing/...`).
- **Run tests with:** `cd packages/screen_recorder && flutter test test/licensing/` (fvm `flutter` is on PATH).
- **Token format (spec §4):** EdDSA (Ed25519) JWT. Claims: `sub`, `iss`, `iat`, `exp` (epoch seconds), `plan` ∈ {subscription,onetime,free}, `export` (bool), `status` ∈ {active,grace,canceled,none}, `updates_until` (ISO date string or null), `device_id`, `seat_limit`.
- **canExport rule (spec §2):** subscription → `status` in {active,grace}; onetime → `appReleaseDate <= updates_until`; free/absent/expired → false.
- **Offline + safe:** the verifier NEVER throws on malformed input — it returns null. The public key is injected (not hardcoded here) so tests use a generated keypair.
- **No secrets:** no keys committed; the store holds only tokens the server issued, behind Keychain in the real impl.
- **DO NOT run `dart format` on files** — the repo's pinned formatter reflows large regions; match the surrounding style by hand (see the project's dart-format gotcha).
- **No native/plugin calls in tested logic:** `SecureLicenseStore` delegates to a `SecureKV` interface; tests use an in-memory `SecureKV`. The `flutter_secure_storage`-backed `SecureKV` impl is a thin wrapper (a few lines), not unit-tested here.
- **Git:** branch `feat/stripe-licensing`. Stage only files you created/changed.

---

## File Structure

```
packages/screen_recorder/
  pubspec.yaml                       # + cryptography, flutter_secure_storage
  lib/licensing/
    entitlement_claims.dart          # EntitlementClaims + fromJson
    entitlement_verifier.dart        # EntitlementVerifier (Ed25519 + JWT parse)
    entitlement.dart                 # EntitlementState + canExport()
    license_store.dart               # LicenseTokens, LicenseStore, InMemory + Secure (SecureKV)
  test/licensing/
    entitlement_claims_test.dart
    entitlement_verifier_test.dart
    entitlement_test.dart
    license_store_test.dart
```

---

### Task 1: Dependencies + entitlement claims model

Adds the two deps and the claims model with tolerant JSON parsing. Deliverable: `flutter test test/licensing/entitlement_claims_test.dart` passes.

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml`
- Create: `packages/screen_recorder/lib/licensing/entitlement_claims.dart`
- Create: `packages/screen_recorder/test/licensing/entitlement_claims_test.dart`

**Interfaces:**
- Produces: `class EntitlementClaims` with fields `sub, plan, exportEntitled, status, updatesUntil (DateTime?), deviceId, seatLimit, issuedAt (DateTime), expiresAt (DateTime)` and `factory EntitlementClaims.fromJson(Map<String,dynamic>)`.

- [ ] **Step 1: Add deps to `pubspec.yaml`** — under `dependencies:` (keep existing), add:

```yaml
  cryptography: ^2.7.0
  flutter_secure_storage: ^9.2.2
```
Then: `cd packages/screen_recorder && flutter pub get`

- [ ] **Step 2: Write the failing test `test/licensing/entitlement_claims_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';

void main() {
  test('parses a full subscription claim set', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'usr_1', 'iss': 'https://api.slipreel.app',
      'iat': 1750000000, 'exp': 1751209600,
      'plan': 'subscription', 'export': true, 'status': 'active',
      'updates_until': null, 'device_id': 'dev_1', 'seat_limit': 2,
    });
    expect(c.sub, 'usr_1');
    expect(c.plan, 'subscription');
    expect(c.exportEntitled, true);
    expect(c.status, 'active');
    expect(c.updatesUntil, isNull);
    expect(c.deviceId, 'dev_1');
    expect(c.seatLimit, 2);
    expect(c.issuedAt, DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000, isUtc: true));
    expect(c.expiresAt, DateTime.fromMillisecondsSinceEpoch(1751209600 * 1000, isUtc: true));
  });

  test('parses a one-time claim with an updates_until date', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'usr_2', 'iss': 'x', 'iat': 1750000000, 'exp': 1751209600,
      'plan': 'onetime', 'export': true, 'status': 'active',
      'updates_until': '2027-08-01T00:00:00.000Z', 'device_id': 'dev_2', 'seat_limit': 2,
    });
    expect(c.plan, 'onetime');
    expect(c.updatesUntil, DateTime.utc(2027, 8, 1));
  });

  test('applies safe defaults for missing optional fields', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'usr_3', 'iss': 'x', 'iat': 1750000000, 'exp': 1751209600, 'plan': 'free',
    });
    expect(c.exportEntitled, false);
    expect(c.status, 'none');
    expect(c.deviceId, '');
    expect(c.seatLimit, 0);
    expect(c.updatesUntil, isNull);
  });
}
```

- [ ] **Step 3: Run it — expect FAIL**

Run: `cd packages/screen_recorder && flutter test test/licensing/entitlement_claims_test.dart`
Expected: FAIL — `entitlement_claims.dart` doesn't exist.

- [ ] **Step 4: Implement `lib/licensing/entitlement_claims.dart`**

```dart
/// Claims carried by a server-issued Ed25519 entitlement token (spec §4).
class EntitlementClaims {
  const EntitlementClaims({
    required this.sub,
    required this.plan,
    required this.exportEntitled,
    required this.status,
    required this.updatesUntil,
    required this.deviceId,
    required this.seatLimit,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String sub;
  final String plan; // 'subscription' | 'onetime' | 'free'
  final bool exportEntitled;
  final String status; // 'active' | 'grace' | 'canceled' | 'none'
  final DateTime? updatesUntil;
  final String deviceId;
  final int seatLimit;
  final DateTime issuedAt;
  final DateTime expiresAt;

  factory EntitlementClaims.fromJson(Map<String, dynamic> json) {
    DateTime fromEpochSeconds(Object? v) =>
        DateTime.fromMillisecondsSinceEpoch(((v as num).toInt()) * 1000, isUtc: true);
    final rawUntil = json['updates_until'];
    return EntitlementClaims(
      sub: json['sub'] as String,
      plan: json['plan'] as String,
      exportEntitled: json['export'] as bool? ?? false,
      status: json['status'] as String? ?? 'none',
      updatesUntil: rawUntil == null ? null : DateTime.parse(rawUntil as String),
      deviceId: json['device_id'] as String? ?? '',
      seatLimit: (json['seat_limit'] as num?)?.toInt() ?? 0,
      issuedAt: fromEpochSeconds(json['iat']),
      expiresAt: fromEpochSeconds(json['exp']),
    );
  }
}
```

- [ ] **Step 5: Run it — expect PASS (3 tests)**

Run: `cd packages/screen_recorder && flutter test test/licensing/entitlement_claims_test.dart`

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/pubspec.yaml packages/screen_recorder/pubspec.lock \
  packages/screen_recorder/lib/licensing/entitlement_claims.dart \
  packages/screen_recorder/test/licensing/entitlement_claims_test.dart
git commit -m "feat(app): entitlement token claims model"
```

---

### Task 2: Offline Ed25519 JWT verifier

Verifies an EdDSA JWT against an injected public key, returning claims or null (never throwing). Deliverable: a test signs tokens with an ephemeral keypair and proves valid → claims and every tampering → null.

**Files:**
- Create: `packages/screen_recorder/lib/licensing/entitlement_verifier.dart`
- Create: `packages/screen_recorder/test/licensing/entitlement_verifier_test.dart`

**Interfaces:**
- Consumes: `EntitlementClaims` (Task 1); the `cryptography` package.
- Produces: `class EntitlementVerifier` — constructed with `List<int> publicKeyBytes` (32-byte Ed25519 key) and an `issuer` (default `https://api.slipreel.app`); method `Future<EntitlementClaims?> verify(String jwt, {DateTime? now, bool ignoreExpiry = false})`.

- [ ] **Step 1: Write the failing test `test/licensing/entitlement_verifier_test.dart`**

```dart
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';

String _b64url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Build a signed EdDSA JWT for tests.
Future<String> _makeJwt(
  SimpleKeyPair kp, {
  required Map<String, dynamic> payload,
  String alg = 'EdDSA',
}) async {
  final header = _b64url(utf8.encode(jsonEncode({'alg': alg, 'typ': 'JWT'})));
  final body = _b64url(utf8.encode(jsonEncode(payload)));
  final signingInput = utf8.encode('$header.$body');
  final sig = await Ed25519().sign(signingInput, keyPair: kp);
  return '$header.$body.${_b64url(sig.bytes)}';
}

Map<String, dynamic> _claims({
  String iss = 'https://api.slipreel.app',
  int? exp,
}) =>
    {
      'sub': 'usr_1', 'iss': iss,
      'iat': 1750000000, 'exp': exp ?? 1900000000,
      'plan': 'subscription', 'export': true, 'status': 'active',
      'updates_until': null, 'device_id': 'dev_1', 'seat_limit': 2,
    };

void main() {
  late SimpleKeyPair kp;
  late List<int> pub;

  setUp(() async {
    kp = await Ed25519().newKeyPair();
    pub = (await kp.extractPublicKey()).bytes;
  });

  test('verifies a valid token and returns claims', () async {
    final jwt = await _makeJwt(kp, payload: _claims());
    final v = EntitlementVerifier(pub);
    final claims = await v.verify(jwt, now: DateTime.utc(2025, 6, 1));
    expect(claims, isNotNull);
    expect(claims!.sub, 'usr_1');
    expect(claims.plan, 'subscription');
  });

  test('rejects a tampered payload', () async {
    final jwt = await _makeJwt(kp, payload: _claims());
    final parts = jwt.split('.');
    final forged = _b64url(utf8.encode(jsonEncode(_claims()..['sub'] = 'attacker')));
    final tampered = '${parts[0]}.$forged.${parts[2]}';
    expect(await EntitlementVerifier(pub).verify(tampered, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects a token signed by a different key', () async {
    final other = await Ed25519().newKeyPair();
    final jwt = await _makeJwt(other, payload: _claims());
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects an expired token', () async {
    final jwt = await _makeJwt(kp, payload: _claims(exp: 1750100000));
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects a wrong issuer', () async {
    final jwt = await _makeJwt(kp, payload: _claims(iss: 'https://evil.example'));
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects a non-EdDSA alg header', () async {
    final jwt = await _makeJwt(kp, payload: _claims(), alg: 'HS256');
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects malformed input without throwing', () async {
    final v = EntitlementVerifier(pub);
    expect(await v.verify('not-a-jwt'), isNull);
    expect(await v.verify('a.b'), isNull);
    expect(await v.verify(''), isNull);
  });

  test('ignoreExpiry allows an expired but otherwise valid token', () async {
    final jwt = await _makeJwt(kp, payload: _claims(exp: 1750100000));
    final claims = await EntitlementVerifier(pub)
        .verify(jwt, now: DateTime.utc(2025, 6, 1), ignoreExpiry: true);
    expect(claims, isNotNull);
  });
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `cd packages/screen_recorder && flutter test test/licensing/entitlement_verifier_test.dart`

- [ ] **Step 3: Implement `lib/licensing/entitlement_verifier.dart`**

```dart
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'entitlement_claims.dart';

/// Verifies EdDSA (Ed25519) entitlement JWTs offline against an embedded public
/// key. Returns the claims on success, or null for any invalid/malformed token.
/// Never throws — a bad token is simply "not entitled".
class EntitlementVerifier {
  EntitlementVerifier(this._publicKeyBytes,
      {this.issuer = 'https://api.slipreel.app'});

  final List<int> _publicKeyBytes; // 32-byte Ed25519 public key
  final String issuer;
  final Ed25519 _algorithm = Ed25519();

  Future<EntitlementClaims?> verify(
    String jwt, {
    DateTime? now,
    bool ignoreExpiry = false,
  }) async {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;

      final header = _decodeSegment(parts[0]);
      if (header['alg'] != 'EdDSA') return null;

      final signingInput = utf8.encode('${parts[0]}.${parts[1]}');
      final signature = Signature(
        _decodeBytes(parts[2]),
        publicKey: SimplePublicKey(_publicKeyBytes, type: KeyPairType.ed25519),
      );
      final ok = await _algorithm.verify(signingInput, signature: signature);
      if (!ok) return null;

      final payload = _decodeSegment(parts[1]);
      if (payload['iss'] != issuer) return null;

      final claims = EntitlementClaims.fromJson(payload);
      final at = (now ?? DateTime.now()).toUtc();
      if (!ignoreExpiry && at.isAfter(claims.expiresAt)) return null;
      return claims;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decodeSegment(String segment) =>
      jsonDecode(utf8.decode(_decodeBytes(segment))) as Map<String, dynamic>;

  List<int> _decodeBytes(String segment) {
    final normalized = segment.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized.length % 4 == 0
        ? normalized
        : normalized + '=' * (4 - normalized.length % 4);
    return base64.decode(padded);
  }
}
```

- [ ] **Step 4: Run it — expect PASS (8 tests)**

Run: `cd packages/screen_recorder && flutter test test/licensing/entitlement_verifier_test.dart`

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/licensing/entitlement_verifier.dart \
  packages/screen_recorder/test/licensing/entitlement_verifier_test.dart
git commit -m "feat(app): offline ed25519 entitlement token verifier"
```

---

### Task 3: Entitlement state + canExport rule

The client-side export rule and the state type the controller (5b) will hold. Deliverable: tests prove the truth table from spec §2.

**Files:**
- Create: `packages/screen_recorder/lib/licensing/entitlement.dart`
- Create: `packages/screen_recorder/test/licensing/entitlement_test.dart`

**Interfaces:**
- Consumes: `EntitlementClaims` (Task 1).
- Produces:
  - `bool canExport(EntitlementClaims? claims, {required DateTime appReleaseDate, DateTime? now})`
  - sealed `EntitlementState` with `EntitlementLoading`, `EntitlementSignedOut`, `EntitlementLoaded(EntitlementClaims claims)`.

- [ ] **Step 1: Write the failing test `test/licensing/entitlement_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';

EntitlementClaims _c({
  required String plan,
  String status = 'active',
  DateTime? updatesUntil,
  DateTime? exp,
}) =>
    EntitlementClaims(
      sub: 'u', plan: plan, exportEntitled: plan != 'free', status: status,
      updatesUntil: updatesUntil, deviceId: 'd', seatLimit: 2,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: exp ?? DateTime.utc(2030, 1, 1),
    );

void main() {
  final release = DateTime.utc(2026, 8, 27);
  final now = DateTime.utc(2026, 8, 27, 12);

  test('null claims cannot export', () {
    expect(canExport(null, appReleaseDate: release, now: now), false);
  });

  test('active subscription can export', () {
    expect(canExport(_c(plan: 'subscription', status: 'active'), appReleaseDate: release, now: now), true);
  });

  test('grace subscription can export', () {
    expect(canExport(_c(plan: 'subscription', status: 'grace'), appReleaseDate: release, now: now), true);
  });

  test('canceled subscription cannot export', () {
    expect(canExport(_c(plan: 'subscription', status: 'canceled'), appReleaseDate: release, now: now), false);
  });

  test('one-time on a build within the update window can export', () {
    expect(canExport(_c(plan: 'onetime', updatesUntil: DateTime.utc(2027, 1, 1)),
        appReleaseDate: release, now: now), true);
  });

  test('one-time on a build past the update window cannot export', () {
    expect(canExport(_c(plan: 'onetime', updatesUntil: DateTime.utc(2026, 1, 1)),
        appReleaseDate: release, now: now), false);
  });

  test('one-time with no updates_until cannot export', () {
    expect(canExport(_c(plan: 'onetime', updatesUntil: null), appReleaseDate: release, now: now), false);
  });

  test('free cannot export', () {
    expect(canExport(_c(plan: 'free', status: 'none'), appReleaseDate: release, now: now), false);
  });

  test('an expired token cannot export regardless of plan', () {
    expect(canExport(_c(plan: 'subscription', status: 'active', exp: DateTime.utc(2026, 8, 1)),
        appReleaseDate: release, now: now), false);
  });
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `cd packages/screen_recorder && flutter test test/licensing/entitlement_test.dart`

- [ ] **Step 3: Implement `lib/licensing/entitlement.dart`**

```dart
import 'entitlement_claims.dart';

/// The app's current licensing state. The controller (Phase 5b) transitions
/// through these; the export gate (Phase 6) reads the loaded claims via
/// [canExport].
sealed class EntitlementState {
  const EntitlementState();
}

class EntitlementLoading extends EntitlementState {
  const EntitlementLoading();
}

class EntitlementSignedOut extends EntitlementState {
  const EntitlementSignedOut();
}

class EntitlementLoaded extends EntitlementState {
  const EntitlementLoaded(this.claims);
  final EntitlementClaims claims;
}

/// Whether export is unlocked, per spec §2. [appReleaseDate] is this build's
/// release date (baked at build time in Phase 5b) — the version ceiling for
/// one-time licenses.
bool canExport(
  EntitlementClaims? claims, {
  required DateTime appReleaseDate,
  DateTime? now,
}) {
  if (claims == null) return false;
  final at = (now ?? DateTime.now()).toUtc();
  if (at.isAfter(claims.expiresAt)) return false;

  switch (claims.plan) {
    case 'subscription':
      return claims.status == 'active' || claims.status == 'grace';
    case 'onetime':
      final until = claims.updatesUntil;
      return until != null && !appReleaseDate.isAfter(until);
    default:
      return false;
  }
}
```

- [ ] **Step 4: Run it — expect PASS (9 tests)**

Run: `cd packages/screen_recorder && flutter test test/licensing/entitlement_test.dart`

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/licensing/entitlement.dart \
  packages/screen_recorder/test/licensing/entitlement_test.dart
git commit -m "feat(app): entitlement state and canExport rule"
```

---

### Task 4: Secure token store

The token cache abstraction: an in-memory fake for tests, and a Keychain-backed impl behind a tiny `SecureKV` interface (so its logic is testable). Deliverable: tests prove round-trip, clear, and corrupt-data tolerance.

**Files:**
- Create: `packages/screen_recorder/lib/licensing/license_store.dart`
- Create: `packages/screen_recorder/test/licensing/license_store_test.dart`

**Interfaces:**
- Produces:
  - `class LicenseTokens { final String token, refreshToken, deviceId; Map toJson(); factory fromJson(Map); }`
  - `abstract interface class LicenseStore { Future<void> save(LicenseTokens); Future<LicenseTokens?> load(); Future<void> clear(); }`
  - `class InMemoryLicenseStore implements LicenseStore`
  - `abstract interface class SecureKV { Future<String?> read(String); Future<void> write(String, String); Future<void> delete(String); }`
  - `class FlutterSecureKV implements SecureKV` (wraps `FlutterSecureStorage`) and `class InMemorySecureKV implements SecureKV`
  - `class SecureLicenseStore implements LicenseStore` (uses a `SecureKV`)

- [ ] **Step 1: Write the failing test `test/licensing/license_store_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/license_store.dart';

void main() {
  const tokens = LicenseTokens(token: 'jwt', refreshToken: 'rt', deviceId: 'dev_1');

  test('LicenseTokens round-trips through JSON', () {
    final restored = LicenseTokens.fromJson(tokens.toJson());
    expect(restored.token, 'jwt');
    expect(restored.refreshToken, 'rt');
    expect(restored.deviceId, 'dev_1');
  });

  test('InMemoryLicenseStore saves, loads, and clears', () async {
    final store = InMemoryLicenseStore();
    expect(await store.load(), isNull);
    await store.save(tokens);
    expect((await store.load())!.token, 'jwt');
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('SecureLicenseStore persists via its SecureKV', () async {
    final store = SecureLicenseStore(InMemorySecureKV());
    await store.save(tokens);
    final loaded = await store.load();
    expect(loaded!.deviceId, 'dev_1');
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('SecureLicenseStore returns null on corrupt stored data', () async {
    final kv = InMemorySecureKV();
    await kv.write('slipreel.license', 'not json');
    final store = SecureLicenseStore(kv);
    expect(await store.load(), isNull);
  });
}
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `cd packages/screen_recorder && flutter test test/licensing/license_store_test.dart`

- [ ] **Step 3: Implement `lib/licensing/license_store.dart`**

```dart
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The tokens the app caches after activation: the signed entitlement token,
/// the device refresh token, and the server device id (dev_...).
class LicenseTokens {
  const LicenseTokens({
    required this.token,
    required this.refreshToken,
    required this.deviceId,
  });

  final String token;
  final String refreshToken;
  final String deviceId;

  Map<String, dynamic> toJson() =>
      {'token': token, 'refresh': refreshToken, 'device_id': deviceId};

  factory LicenseTokens.fromJson(Map<String, dynamic> json) => LicenseTokens(
        token: json['token'] as String,
        refreshToken: json['refresh'] as String,
        deviceId: json['device_id'] as String,
      );
}

abstract interface class LicenseStore {
  Future<void> save(LicenseTokens tokens);
  Future<LicenseTokens?> load();
  Future<void> clear();
}

/// Test/fallback store; no persistence.
class InMemoryLicenseStore implements LicenseStore {
  LicenseTokens? _tokens;
  @override
  Future<void> save(LicenseTokens tokens) async => _tokens = tokens;
  @override
  Future<LicenseTokens?> load() async => _tokens;
  @override
  Future<void> clear() async => _tokens = null;
}

/// A minimal secure key/value surface so [SecureLicenseStore] is testable
/// without the platform Keychain plugin.
abstract interface class SecureKV {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKV implements SecureKV {
  FlutterSecureKV([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemorySecureKV implements SecureKV {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}

/// Keychain-backed license store (via [SecureKV]). Corrupt data loads as null.
class SecureLicenseStore implements LicenseStore {
  SecureLicenseStore(this._kv);
  final SecureKV _kv;
  static const _key = 'slipreel.license';

  @override
  Future<void> save(LicenseTokens tokens) =>
      _kv.write(_key, jsonEncode(tokens.toJson()));

  @override
  Future<LicenseTokens?> load() async {
    final raw = await _kv.read(_key);
    if (raw == null) return null;
    try {
      return LicenseTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clear() => _kv.delete(_key);
}
```

- [ ] **Step 4: Run it — expect PASS (4 tests)**

Run: `cd packages/screen_recorder && flutter test test/licensing/license_store_test.dart`

- [ ] **Step 5: Run the whole licensing suite + analyze**

Run: `cd packages/screen_recorder && flutter test test/licensing/ && flutter analyze lib/licensing test/licensing`
Expected: all licensing tests pass; no analyzer issues in the new files.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/licensing/license_store.dart \
  packages/screen_recorder/test/licensing/license_store_test.dart
git commit -m "feat(app): secure license token store"
```

---

## Self-Review

**Spec coverage (Phase 5a — the testable core of the app licensing module):**
- Token verification offline (spec §4, EdDSA, embedded public key) → Task 2. Claims model → Task 1. `canExport` truth table (spec §2: subscription active/grace, one-time version ceiling, free/expired = no) → Task 3. Token caching (Keychain) → Task 4. The public key is injected here (baked as a const in 5b); the app release date is a parameter here (baked in 5b).
- Out of scope (Phase 5b): device fingerprint (hardware UUID method channel + Swift), `slipreel://` scheme + `app_links` deep-link delivery, `url_launcher` browser handoff + `state` nonce, the HTTP `/v1/token/refresh` client, the Riverpod `LicensingController`, `main.dart` wiring, the baked public-key + release-date consts, and running-app verification. Out of scope entirely: the export gate + paywall UI (Phase 6).

**Placeholder scan:** No TBD/TODO. `EntitlementVerifier` takes the public key as a constructor arg (real const baked in 5b) — intentional, not a placeholder. `canExport` takes `appReleaseDate` as a parameter (baked in 5b) — intentional.

**Type consistency:** `EntitlementClaims` fields (`plan`/`status`/`updatesUntil`/`exportEntitled`/`deviceId`/`seatLimit`/`issuedAt`/`expiresAt`) are produced in Task 1 and consumed identically in Tasks 2–3. `EntitlementVerifier.verify(...) → EntitlementClaims?` matches `canExport(EntitlementClaims?, ...)`. `LicenseTokens` (`token`/`refreshToken`/`deviceId`) JSON keys (`token`/`refresh`/`device_id`) round-trip in Task 4 and match what 5b's refresh client will read. `SecureKV`/`LicenseStore` interfaces match their in-memory and Keychain impls. Claim field names match the server token (spec §4): `export`, `updates_until`, `device_id`, `seat_limit`, `iat`, `exp`, `iss`.

**Convention note:** tests follow the repo's `flutter_test` style (`package:screen_recorder/...` imports, `test(...)`); no `dart format` is run (per the repo's pinned-formatter gotcha) — style is matched by hand.

---

## Execution Handoff

Choose how to execute — see the offer in chat. All four tasks are pure Dart with `flutter test` coverage (well-suited to autonomous subagents). Phase 5b (native integration + controller + app wiring) will need running-app verification and is planned separately after this lands.
