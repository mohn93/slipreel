import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/licensing/trial_exports.dart';

void main() {
  test('three successful exports persist across service restarts', () async {
    final store = InMemorySecureKV();
    for (var i = 0; i < 3; i++) {
      final trial = TrialExports(store);
      expect(await trial.remaining, 3 - i);
      final lease = await trial.reserve();
      await lease!.complete(successful: true);
      await lease.complete(successful: true); // no double charge
    }
    expect(await TrialExports(store).reserve(), isNull);
  });
  test('failed/cancelled delivery does not consume; parallel reservations are rejected', () async {
    final trial = TrialExports(InMemorySecureKV());
    final first = trial.reserve();
    expect(await trial.reserve(), isNull);
    await (await first)!.complete(successful: false);
    expect(await trial.remaining, 3);
    final retry = await trial.reserve();
    expect(retry, isNotNull);
    await retry!.complete(successful: false);
  });
  test('invalid persisted counts do not grant extra exports', () async {
    final store = InMemorySecureKV();
    for (final count in ['-1', 'broken', '100']) {
      await store.write(TrialExports.storageKey, count);
      expect(await TrialExports(store).reserve(), isNull);
    }
  });
}
