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
