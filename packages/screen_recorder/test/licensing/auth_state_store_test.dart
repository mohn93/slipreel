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
}
