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

  test('begin reuses the pending nonce within the reuse window', () async {
    // Repeated Sign in clicks must not invalidate an email link already sent.
    var now = DateTime.utc(2026, 10, 22, 11, 40);
    final store = AuthStateStore(InMemorySecureKV(), now: () => now);
    final a = await store.begin();
    now = now.add(const Duration(minutes: 3));
    final b = await store.begin();
    expect(b, a);
    expect(await store.matches(a), isTrue);
  });

  test('reuse is measured from issue time, not extended by repeat clicks',
      () async {
    var now = DateTime.utc(2026, 10, 22, 11, 40);
    final store = AuthStateStore(InMemorySecureKV(), now: () => now);
    final a = await store.begin();
    now = now.add(AuthStateStore.reuseWindow - const Duration(minutes: 1));
    expect(await store.begin(), a);
    now = now.add(const Duration(minutes: 2));
    final b = await store.begin();
    expect(b, isNot(a));
    expect(await store.matches(a), isFalse);
    expect(await store.matches(b), isTrue);
  });

  test('begin issues a fresh nonce after clear', () async {
    final store = AuthStateStore(InMemorySecureKV());
    final a = await store.begin();
    await store.clear();
    final b = await store.begin();
    expect(b, isNot(a));
    expect(await store.matches(b), isTrue);
  });

  test('a nonce issued in the future (clock change) is not reused', () async {
    var now = DateTime.utc(2026, 10, 22, 12);
    final store = AuthStateStore(InMemorySecureKV(), now: () => now);
    final a = await store.begin();
    now = now.subtract(const Duration(hours: 3));
    expect(await store.begin(), isNot(a));
  });

  test('a pre-upgrade plain nonce still matches but is not reused', () async {
    final kv = InMemorySecureKV();
    await kv.write('slipreel.auth_state', 'legacy-nonce');
    final store = AuthStateStore(kv);
    expect(await store.matches('legacy-nonce'), isTrue);
    final fresh = await store.begin();
    expect(fresh, isNot('legacy-nonce'));
    expect(await store.matches(fresh), isTrue);
  });

  test('a corrupt stored value never matches and is replaced', () async {
    final kv = InMemorySecureKV();
    await kv.write('slipreel.auth_state', '{"nonce": 5}');
    final store = AuthStateStore(kv);
    expect(await store.matches('5'), isFalse);
    expect(await store.matches('{"nonce": 5}'), isFalse);
    final fresh = await store.begin();
    expect(await store.matches(fresh), isTrue);
  });

  test('overlapping begin calls share one nonce', () async {
    final store = AuthStateStore(InMemorySecureKV());
    final results = await Future.wait([store.begin(), store.begin()]);
    expect(results[0], results[1]);
    expect(await store.matches(results[0]), isTrue);
  });

  test('an empty or out-of-range stored value is treated as corrupt',
      () async {
    final now = DateTime.utc(2026, 10, 22, 12);
    for (final raw in [
      '{"nonce": "", "issued": ${now.millisecondsSinceEpoch}}',
      '{"nonce": "abc", "issued": 9000000000000000}',
    ]) {
      final kv = InMemorySecureKV();
      await kv.write('slipreel.auth_state', raw);
      final store = AuthStateStore(kv, now: () => now);
      expect(await store.matches(''), isFalse);
      expect(await store.matches('abc'), isFalse);
      final fresh = await store.begin();
      expect(fresh, isNotEmpty);
      expect(await store.matches(fresh), isTrue);
    }
  });

  test('matches is false when nothing pending', () async {
    final store = AuthStateStore(InMemorySecureKV());
    expect(await store.matches('anything'), isFalse);
  });

  test('clear removes the pending nonce', () async {
    final store = AuthStateStore(InMemorySecureKV());
    final nonce = await store.begin();
    expect(await store.matches(nonce), isTrue);
    await store.clear();
    expect(await store.matches(nonce), isFalse);
  });

  test('pricingUrl carries device + state', () {
    final store = AuthStateStore(InMemorySecureKV());
    final url = store.pricingUrl(deviceFingerprint: 'fp_abc', state: 'n1');
    expect(url.path, '/pricing');
    expect(url.queryParameters['device'], 'fp_abc');
    expect(url.queryParameters['state'], 'n1');
  });

  test('loginUrl carries device + state', () {
    final store = AuthStateStore(InMemorySecureKV());
    final url = store.loginUrl(deviceFingerprint: 'fp_abc', state: 'n1');
    expect(url.path, '/login');
    expect(url.queryParameters['device'], 'fp_abc');
    expect(url.queryParameters['state'], 'n1');
  });

  test('device_name is included when provided, omitted otherwise', () {
    final store = AuthStateStore(InMemorySecureKV());
    final withName = store.pricingUrl(
        deviceFingerprint: 'fp', state: 'n', deviceName: 'My Mac · macOS 15.1');
    expect(withName.queryParameters['device_name'], 'My Mac · macOS 15.1');
    final without = store.loginUrl(deviceFingerprint: 'fp', state: 'n');
    expect(without.queryParameters.containsKey('device_name'), isFalse);
  });
}
