import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/auth_state_store.dart';
import 'package:screen_recorder/licensing/device_fingerprint.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';
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

class _FakeFingerprint extends DeviceFingerprint {
  @override
  Future<String> compute() async => 'fp-mac';
  @override
  Future<String?> describe() async => 'Test Mac';
}

/// Answers each claim from [results] in order, then stays pending.
class _ClaimApi extends LicensingApi {
  _ClaimApi(this.results) : super(baseUrl: 'https://x.test');
  final List<HandoffResult> results;
  final claims = <({String state, String fingerprint})>[];
  @override
  Future<HandoffResult> claimHandoff({
    required String state,
    required String fingerprint,
  }) async {
    claims.add((state: state, fingerprint: fingerprint));
    return results.isEmpty ? const HandoffPending() : results.removeAt(0);
  }
}

EntitlementClaims _claims() => EntitlementClaims(
      sub: 'usr_1',
      plan: 'onetime',
      exportEntitled: true,
      status: 'active',
      updatesUntil: DateTime.utc(2099, 1, 1),
      deviceId: 'dev_1',
      seatLimit: 2,
      issuedAt: DateTime.utc(2026, 8, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
    );

const _creds = HandoffCredentials(
  token: 'jwt.ok',
  refreshToken: 'rt_1',
  deviceId: 'dev_1',
);

Duration? _fast(Duration _) => const Duration(milliseconds: 1);

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 40));

/// Waits until [done] holds (fails after 5 s) so slow machines do not flake.
Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryLicenseStore store;
  late AuthStateStore auth;
  setUp(() {
    store = InMemoryLicenseStore();
    auth = AuthStateStore(InMemorySecureKV());
  });

  LicensingController build(_ClaimApi api, {bool polling = true}) =>
      LicensingController(
        store: store,
        verifier: _FakeVerifier({'jwt.ok': _claims()}),
        api: api,
        authState: auth,
        fingerprint: _FakeFingerprint(),
        openUrl: (_) async => true,
        handoffDelay: polling ? _fast : null,
      );

  test('new nonces advertise cross-device support', () async {
    expect(AuthStateStore.supportsHandoff(await auth.begin()), isTrue);
  });

  test('a sign-in approved on another device activates this Mac', () async {
    final api = _ClaimApi([const HandoffPending(), _creds]);
    final c = build(api);
    await c.openSignIn();
    await _until(() => c.state is EntitlementLoaded);
    expect(c.signInFeedback.pending?.exportsUnlocked, isTrue);
    final saved = await store.load();
    expect(saved!.refreshToken, 'rt_1');
    expect(saved.deviceId, 'dev_1');
    expect(await auth.pending(), isNull);
    expect(api.claims.first.fingerprint, 'fp-mac');
    final count = api.claims.length;
    await _settle();
    expect(api.claims.length, count, reason: 'polling stops after success');
    c.dispose();
  });

  test('a deep link for the same sign-in after polling finished is ignored quietly', () async {
    final c = build(_ClaimApi([_creds]));
    await c.openSignIn();
    final nonce = (await auth.pending())!;
    await _until(() => c.state is EntitlementLoaded);
    final success = c.signInFeedback.pending;
    expect(success?.exportsUnlocked, isTrue);
    await c.handleDeepLink(Uri.parse(
        'slipreel://auth?token=jwt.ok&refresh=rt_1&device_id=dev_1&state=$nonce'));
    expect(c.signInFeedback.pending, same(success));
    expect(c.state, isA<EntitlementLoaded>());
    c.dispose();
  });

  test('a deep link that wins the race stops polling', () async {
    final api = _ClaimApi([]);
    final c = build(api);
    await c.openSignIn();
    final nonce = (await auth.pending())!;
    await c.handleDeepLink(Uri.parse(
        'slipreel://auth?token=jwt.ok&refresh=rt_1&device_id=dev_1&state=$nonce'));
    expect(c.state, isA<EntitlementLoaded>());
    final count = api.claims.length;
    await _settle();
    expect(api.claims.length, count);
    c.dispose();
  });

  test('a seat-limit failure approved elsewhere is reported and stops polling', () async {
    final api = _ClaimApi([const HandoffFailed('seat_limit')]);
    final c = build(api);
    await c.openSignIn();
    await _until(() => c.signInFeedback.pending != null);
    expect(c.signInFeedback.pending?.title, 'Device limit reached');
    expect(await auth.pending(), isNull);
    final count = api.claims.length;
    await _settle();
    expect(api.claims.length, count);
    c.dispose();
  });

  test('a pending sign-in resumes waiting after relaunch', () async {
    await auth.begin();
    final c = build(_ClaimApi([_creds]));
    await c.load();
    await _until(() => c.state is EntitlementLoaded);
    c.dispose();
  });

  test('older nonces without the prefix are not polled', () async {
    final kv = InMemorySecureKV();
    await kv.write('slipreel.auth_state', 'legacy-nonce');
    auth = AuthStateStore(kv);
    final api = _ClaimApi([_creds]);
    final c = build(api);
    await c.load();
    await _settle();
    expect(api.claims, isEmpty);
    c.dispose();
  });

  test('sign out stops polling', () async {
    final api = _ClaimApi([]);
    final c = build(api);
    await c.openSignIn();
    await c.signOut();
    final count = api.claims.length;
    await _settle();
    expect(api.claims.length, count);
    c.dispose();
  });

  test('no polling without a schedule', () async {
    final api = _ClaimApi([_creds]);
    final c = build(api, polling: false);
    await c.openSignIn();
    await _settle();
    expect(api.claims, isEmpty);
    c.dispose();
  });
}
