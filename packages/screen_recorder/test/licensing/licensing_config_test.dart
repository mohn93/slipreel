import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/build_release_date.g.dart';
import 'package:screen_recorder/licensing/entitlement_public_key.g.dart';
import 'package:screen_recorder/licensing/licensing_config.dart';

void main() {
  test('baked public key is 32 bytes', () {
    expect(kEntitlementPublicKey.length, 32);
    for (final b in kEntitlementPublicKey) {
      expect(b, inInclusiveRange(0, 255));
    }
  });

  test('build release date is UTC', () {
    expect(buildReleaseDate.isUtc, isTrue);
  });

  test('release-mode bases default to production hosts', () {
    // With no --dart-define overrides, resolved bases fall back to the consts.
    expect(LicensingConfig.apiBaseResolved, LicensingConfig.apiBase);
    expect(LicensingConfig.siteBaseResolved, LicensingConfig.siteBase);
    expect(LicensingConfig.apiBase, 'https://api.slipreel.app');
    expect(LicensingConfig.siteBase, 'https://slipreel.app');
  });
}
