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
