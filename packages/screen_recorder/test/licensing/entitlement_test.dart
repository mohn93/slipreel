import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';

EntitlementClaims _c({
  required String plan,
  String status = 'active',
  DateTime? updatesUntil,
  DateTime? exp,
}) =>
    EntitlementClaims(
      sub: 'u', plan: plan, exportEntitled: plan != 'free', status: status,
      updatesUntil: updatesUntil, deviceId: 'd', seatLimit: 2,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: exp ?? DateTime.utc(2030, 1, 1),
    );

void main() {
  final release = DateTime.utc(2026, 8, 27);
  final now = DateTime.utc(2026, 8, 27, 12);

  test('null claims cannot export', () {
    expect(canExport(null, appReleaseDate: release, now: now), false);
  });

  test('active subscription can export', () {
    expect(canExport(_c(plan: 'subscription', status: 'active'), appReleaseDate: release, now: now), true);
  });

  test('grace subscription can export', () {
    expect(canExport(_c(plan: 'subscription', status: 'grace'), appReleaseDate: release, now: now), true);
  });

  test('canceled subscription cannot export', () {
    expect(canExport(_c(plan: 'subscription', status: 'canceled'), appReleaseDate: release, now: now), false);
  });

  test('one-time on a build within the update window can export', () {
    expect(canExport(_c(plan: 'onetime', updatesUntil: DateTime.utc(2027, 1, 1)),
        appReleaseDate: release, now: now), true);
  });

  test('one-time on a build past the update window cannot export', () {
    expect(canExport(_c(plan: 'onetime', updatesUntil: DateTime.utc(2026, 1, 1)),
        appReleaseDate: release, now: now), false);
  });

  test('one-time with no updates_until cannot export', () {
    expect(canExport(_c(plan: 'onetime', updatesUntil: null), appReleaseDate: release, now: now), false);
  });

  test('free cannot export', () {
    expect(canExport(_c(plan: 'free', status: 'none'), appReleaseDate: release, now: now), false);
  });

  test('an expired token cannot export regardless of plan', () {
    expect(canExport(_c(plan: 'subscription', status: 'active', exp: DateTime.utc(2026, 8, 1)),
        appReleaseDate: release, now: now), false);
  });
}
