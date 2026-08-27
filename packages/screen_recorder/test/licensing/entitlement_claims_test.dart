import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';

void main() {
  test('parses a full subscription claim set', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'usr_1', 'iss': 'https://api.slipreel.app',
      'iat': 1750000000, 'exp': 1751209600,
      'plan': 'subscription', 'export': true, 'status': 'active',
      'updates_until': null, 'device_id': 'dev_1', 'seat_limit': 2,
    });
    expect(c.sub, 'usr_1');
    expect(c.plan, 'subscription');
    expect(c.exportEntitled, true);
    expect(c.status, 'active');
    expect(c.updatesUntil, isNull);
    expect(c.deviceId, 'dev_1');
    expect(c.seatLimit, 2);
    expect(c.issuedAt, DateTime.fromMillisecondsSinceEpoch(1750000000 * 1000, isUtc: true));
    expect(c.expiresAt, DateTime.fromMillisecondsSinceEpoch(1751209600 * 1000, isUtc: true));
  });

  test('parses a one-time claim with an updates_until date', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'usr_2', 'iss': 'x', 'iat': 1750000000, 'exp': 1751209600,
      'plan': 'onetime', 'export': true, 'status': 'active',
      'updates_until': '2027-08-01T00:00:00.000Z', 'device_id': 'dev_2', 'seat_limit': 2,
    });
    expect(c.plan, 'onetime');
    expect(c.updatesUntil, DateTime.utc(2027, 8, 1));
  });

  test('parses a bare-date updates_until as UTC', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'u', 'iss': 'x', 'iat': 1750000000, 'exp': 1751209600,
      'plan': 'onetime', 'export': true, 'status': 'active',
      'updates_until': '2027-08-27', 'device_id': 'd', 'seat_limit': 2,
    });
    expect(c.updatesUntil!.isUtc, true);
    // Compared via the same local->UTC conversion rather than a fixed
    // DateTime.utc(2027, 8, 27) literal, so this test is not tied to the
    // machine's local timezone offset (a bare date has no offset of its
    // own, so DateTime.parse interprets it as local midnight first).
    expect(c.updatesUntil, DateTime.parse('2027-08-27').toUtc());
  });

  test('applies safe defaults for missing optional fields', () {
    final c = EntitlementClaims.fromJson({
      'sub': 'usr_3', 'iss': 'x', 'iat': 1750000000, 'exp': 1751209600, 'plan': 'free',
    });
    expect(c.exportEntitled, false);
    expect(c.status, 'none');
    expect(c.deviceId, '');
    expect(c.seatLimit, 0);
    expect(c.updatesUntil, isNull);
  });
}
