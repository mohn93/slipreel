import 'dart:async';
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
  Future<EntitlementClaims?> verify(
    String jwt, {
    DateTime? now,
    bool ignoreExpiry = false,
  }) async => _table[jwt];
}

// An api stub returning a queued refresh result.
class _FakeApi extends LicensingApi {
  _FakeApi(this.result) : super(baseUrl: 'https://x.test');
  RefreshResult result;
  String? lastRefreshToken;
  @override
  Future<RefreshResult> refresh({
    required String refreshToken,
    required String deviceId,
  }) async {
    lastRefreshToken = refreshToken;
    return result;
  }
}

class _DeferredApi extends LicensingApi {
  final response = Completer<RefreshResult>();
  int calls = 0;
  @override
  Future<RefreshResult> refresh({
    required String refreshToken,
    required String deviceId,
  }) {
    calls++;
    return response.future;
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
  LicensingController build({
    LicenseStore? store,
    _FakeVerifier? verifier,
    _FakeApi? api,
  }) {
    return LicensingController(
      store: store ?? InMemoryLicenseStore(),
      verifier: verifier ?? _FakeVerifier(const {}),
      api: api ?? _FakeApi(const RefreshTransient()),
      authState: AuthStateStore(InMemorySecureKV()),
    );
  }

  test(
    'concurrent refreshes share one request and cannot undo sign-out',
    () async {
      final store = InMemoryLicenseStore();
      await store.save(
        const LicenseTokens(
          token: 'old',
          refreshToken: 'rt',
          deviceId: 'dev_1',
        ),
      );
      final api = _DeferredApi();
      final c = LicensingController(
        store: store,
        verifier: _FakeVerifier({'fresh': _claims(device: 'dev_1')}),
        api: api,
        authState: AuthStateStore(InMemorySecureKV()),
      );
      final first = c.refreshNow();
      final second = c.refreshIfNeeded();
      await Future<void>.delayed(Duration.zero);
      expect(api.calls, 1);
      await c.signOut();
      api.response.complete(const RefreshOk('fresh'));
      await Future.wait([first, second]);
      expect(await store.load(), isNull);
      expect(c.state, isA<EntitlementSignedOut>());
    },
  );

  test('background credential revocation preserves a new browser sign-in nonce', () async {
    final store = InMemoryLicenseStore();
    await store.save(const LicenseTokens(token: 'old', refreshToken: 'rt', deviceId: 'dev_1'));
    final auth = AuthStateStore(InMemorySecureKV());
    final api = _DeferredApi();
    final c = LicensingController(store: store, verifier: _FakeVerifier({}),
        api: api, authState: auth);
    final pending = c.refreshNow();
    await Future<void>.delayed(Duration.zero);
    final nonce = await auth.begin();
    api.response.complete(const RefreshRevoked());
    await pending;
    expect(await store.load(), isNull);
    expect(await auth.matches(nonce), isTrue);
  });

  test('due refresh retries after offline failure without a restart', () async {
    var now = DateTime.utc(2030, 1, 1);
    final store = InMemoryLicenseStore();
    await store.save(
      const LicenseTokens(token: 'old', refreshToken: 'rt', deviceId: 'dev_1'),
    );
    final api = _FakeApi(const RefreshTransient());
    final c = LicensingController(
      store: store,
      verifier: _FakeVerifier({'fresh': _claims(device: 'dev_1')}),
      api: api,
      authState: AuthStateStore(InMemorySecureKV()),
      now: () => now,
    );
    await c.load();
    await c.refreshIfNeeded();
    expect(c.state, isA<EntitlementSignedOut>());
    api.result = const RefreshOk('fresh');
    await c.refreshIfNeeded(); // retry backoff
    expect(c.state, isA<EntitlementSignedOut>());
    now = now.add(const Duration(minutes: 5));
    await c.refreshIfNeeded();
    expect(c.state, isA<EntitlementLoaded>());
  });

  test('load with no cached token -> signed out', () async {
    final c = build();
    await c.load();
    expect(c.state, isA<EntitlementSignedOut>());
  });

  test('load with a valid cached token -> loaded', () async {
    final store = InMemoryLicenseStore();
    await store.save(
      const LicenseTokens(token: 'tok', refreshToken: 'rt', deviceId: 'dev_1'),
    );
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
    await store.save(
      const LicenseTokens(token: 'bad', refreshToken: 'rt', deviceId: 'dev_1'),
    );
    final c = build(store: store, verifier: _FakeVerifier(const {'bad': null}));
    await c.load();
    expect(c.state, isA<EntitlementSignedOut>());
  });

  test('refreshNow success replaces token + state', () async {
    final store = InMemoryLicenseStore();
    await store.save(
      const LicenseTokens(token: 'old', refreshToken: 'rt', deviceId: 'dev_1'),
    );
    final api = _FakeApi(const RefreshOk('fresh'));
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

  test(
    'refreshNow transient failure keeps existing state (offline grace)',
    () async {
      final store = InMemoryLicenseStore();
      await store.save(
        const LicenseTokens(
          token: 'good',
          refreshToken: 'rt',
          deviceId: 'dev_1',
        ),
      );
      final c = build(
        store: store,
        verifier: _FakeVerifier({'good': _claims(device: 'dev_1')}),
        api: _FakeApi(const RefreshTransient()), // offline / server error
      );
      await c.load();
      expect(c.state, isA<EntitlementLoaded>());
      await c.refreshNow();
      expect(c.state, isA<EntitlementLoaded>()); // unchanged
      expect(await store.load(), isNotNull); // credentials kept
    },
  );

  test('refreshNow revoked -> signed out and credentials cleared '
      '(device deactivated server-side)', () async {
    final store = InMemoryLicenseStore();
    await store.save(
      const LicenseTokens(token: 'good', refreshToken: 'rt', deviceId: 'dev_1'),
    );
    final c = build(
      store: store,
      verifier: _FakeVerifier({'good': _claims(device: 'dev_1')}),
      api: _FakeApi(const RefreshRevoked()), // seat deactivated
    );
    await c.load();
    expect(c.state, isA<EntitlementLoaded>());
    await c.refreshNow();
    expect(c.state, isA<EntitlementSignedOut>()); // locked
    expect(await store.load(), isNull); // credentials cleared
  });
}
