import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/license_store.dart';

void main() {
  test('concurrent nonce and license writes survive reopening the file', () async {
    final dir = await Directory.systemTemp.createTemp('license-store-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/license.json';
    final kv = FileSecureKV(path);
    await Future.wait([
      kv.write('license', 'signed-token'),
      kv.write('nonce', 'pending-sign-in'),
      kv.write('device', 'dev_1'),
    ]);
    final reopened = FileSecureKV(path);
    expect(await reopened.read('license'), 'signed-token');
    expect(await reopened.read('nonce'), 'pending-sign-in');
    expect(await reopened.read('device'), 'dev_1');
    await Future.wait([kv.delete('license'), kv.write('nonce', 'new-nonce')]);
    expect(await FileSecureKV(path).read('license'), isNull);
    expect(await FileSecureKV(path).read('nonce'), 'new-nonce');
  });

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
