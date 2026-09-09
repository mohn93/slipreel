import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';
import 'package:screen_recorder/licensing/auth_state_store.dart';
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

class _RetryStore extends InMemoryLicenseStore {
  bool fail = true;
  @override
  Future<void> save(LicenseTokens tokens) async {
    if (fail) throw StateError('storage unavailable');
    await super.save(tokens);
  }
}

EntitlementClaims _claims({bool exportEntitled = true}) => EntitlementClaims(
      sub: 'usr_1',
      plan: 'subscription',
      exportEntitled: exportEntitled,
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

  test('a callback can be retried after local storage recovers', () async {
    final store = _RetryStore();
    final auth = AuthStateStore(InMemorySecureKV());
    final nonce = await auth.begin();
    final c = LicensingController(store: store,
      verifier: _FakeVerifier({'jwt.ok': _claims()}),
      api: LicensingApi(baseUrl: 'https://x.test'), authState: auth);
    final link = Uri.parse('slipreel://auth?token=jwt.ok&refresh=rt&device_id=dev_1&state=$nonce');
    await c.handleDeepLink(link);
    expect(await store.load(), isNull);
    expect(await auth.matches(nonce), isTrue);
    store.fail = false;
    await c.handleDeepLink(link);
    expect(c.state, isA<EntitlementLoaded>());
    expect(c.signInFeedback.pending?.exportsUnlocked, isTrue);
    expect(await auth.matches(nonce), isFalse);
  });

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
    expect(c.signInFeedback.pending?.exportsUnlocked, isTrue);
    final saved = await store.load();
    expect(saved!.token, 'jwt.ok');
    expect(saved.refreshToken, 'rt_9');
    expect(saved.deviceId, 'dev_1');
    // Nonce consumed.
    expect(await auth.matches(nonce), isFalse);
  });

  test('signed-in account without export entitlement does not celebrate activation', () async {
    final auth = AuthStateStore(InMemorySecureKV());
    final nonce = await auth.begin();
    final c = LicensingController(
      store: InMemoryLicenseStore(),
      verifier: _FakeVerifier({'jwt.ok': _claims(exportEntitled: false)}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: auth,
    );
    await c.handleDeepLink(Uri.parse(
        'slipreel://auth?token=jwt.ok&refresh=rt&device_id=dev_1&state=$nonce'));
    expect(c.signInFeedback.pending?.exportsUnlocked, isFalse);
    c.dispose();
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

  test('openSignIn opens the login url with device + state', () async {
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
    final ok = await c.openSignIn();
    expect(ok, isTrue);
    expect(opened!.path, '/login');
    expect(opened!.queryParameters['device'], isNotEmpty);
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
