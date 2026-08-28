import 'entitlement.dart';
import 'entitlement_claims.dart';

/// The three reasons export can be blocked, each mapping to a distinct paywall
/// message (spec §2). null (from [paywallReasonFor]) means export is allowed.
enum PaywallReason {
  /// No purchase on this account (free / signed out / loading). Show plans.
  needsPurchase,

  /// A subscription that is no longer active or in grace. Prompt to resubscribe.
  subscriptionLapsed,

  /// A one-time license whose update window ended before this build's release
  /// date (spec §2/§11 perpetual-fallback). Prompt to renew the update year.
  updateCeiling,
}

EntitlementClaims? _claimsOf(EntitlementState state) =>
    state is EntitlementLoaded ? state.claims : null;

/// Whether export is currently allowed for [state], per the spec §2 rules.
/// Loading/signed-out both resolve to false (fail-closed).
bool canExportNow(
  EntitlementState state, {
  required DateTime appReleaseDate,
  DateTime? now,
}) {
  return canExport(_claimsOf(state), appReleaseDate: appReleaseDate, now: now);
}

/// Which paywall message to show, or null when export is allowed.
PaywallReason? paywallReasonFor(
  EntitlementState state, {
  required DateTime appReleaseDate,
  DateTime? now,
}) {
  if (canExportNow(state, appReleaseDate: appReleaseDate, now: now)) {
    return null;
  }
  final claims = _claimsOf(state);
  if (claims != null && claims.plan == 'onetime' &&
      claims.updatesUntil != null &&
      appReleaseDate.isAfter(claims.updatesUntil!)) {
    return PaywallReason.updateCeiling;
  }
  if (claims != null && claims.plan == 'subscription') {
    return PaywallReason.subscriptionLapsed;
  }
  return PaywallReason.needsPurchase;
}
