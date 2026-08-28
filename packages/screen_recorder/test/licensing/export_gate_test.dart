import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/export_gate.dart';

EntitlementClaims _claims({
  required String plan,
  required String status,
  DateTime? updatesUntil,
  bool exportEntitled = true,
}) =>
    EntitlementClaims(
      sub: 'usr_1',
      plan: plan,
      exportEntitled: exportEntitled,
      status: status,
      updatesUntil: updatesUntil,
      deviceId: 'dev_1',
      seatLimit: 2,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
    );

void main() {
  final release = DateTime.utc(2026, 8, 27);

  group('canExportNow', () {
    test('loading -> false', () {
      expect(canExportNow(const EntitlementLoading(), appReleaseDate: release),
          isFalse);
    });
    test('signed out -> false', () {
      expect(canExportNow(const EntitlementSignedOut(), appReleaseDate: release),
          isFalse);
    });
    test('active subscription -> true', () {
      final s = EntitlementLoaded(_claims(plan: 'subscription', status: 'active'));
      expect(canExportNow(s, appReleaseDate: release), isTrue);
    });
    test('one-time within ceiling -> true', () {
      final s = EntitlementLoaded(_claims(
          plan: 'onetime',
          status: 'active',
          updatesUntil: DateTime.utc(2027, 1, 1)));
      expect(canExportNow(s, appReleaseDate: release), isTrue);
    });
  });

  group('paywallReasonFor', () {
    test('entitled -> null (no paywall)', () {
      final s = EntitlementLoaded(_claims(plan: 'subscription', status: 'active'));
      expect(paywallReasonFor(s, appReleaseDate: release), isNull);
    });
    test('signed out -> needsPurchase', () {
      expect(paywallReasonFor(const EntitlementSignedOut(), appReleaseDate: release),
          PaywallReason.needsPurchase);
    });
    test('loading -> needsPurchase', () {
      expect(paywallReasonFor(const EntitlementLoading(), appReleaseDate: release),
          PaywallReason.needsPurchase);
    });
    test('canceled subscription -> subscriptionLapsed', () {
      final s =
          EntitlementLoaded(_claims(plan: 'subscription', status: 'canceled'));
      expect(paywallReasonFor(s, appReleaseDate: release),
          PaywallReason.subscriptionLapsed);
    });
    test('one-time past update ceiling -> updateCeiling', () {
      final s = EntitlementLoaded(_claims(
          plan: 'onetime',
          status: 'active',
          updatesUntil: DateTime.utc(2026, 1, 1))); // before release
      expect(paywallReasonFor(s, appReleaseDate: release),
          PaywallReason.updateCeiling);
    });
    test('free plan -> needsPurchase', () {
      final s = EntitlementLoaded(
          _claims(plan: 'free', status: 'active', exportEntitled: false));
      expect(paywallReasonFor(s, appReleaseDate: release),
          PaywallReason.needsPurchase);
    });
  });
}
