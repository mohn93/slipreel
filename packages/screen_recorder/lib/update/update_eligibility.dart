import '../licensing/entitlement.dart';

/// Free users can update; one-time customers must still be within their
/// included update year. Loading/unknown coverage waits for a resolved state.
bool canOfferAutomaticUpdate(EntitlementState state, {DateTime? now}) {
  if (state is EntitlementSignedOut) return true;
  if (state is! EntitlementLoaded) return false;
  final claims = state.claims;
  final at = (now ?? DateTime.now()).toUtc();
  switch (claims.plan) {
    case 'free':
      return true;
    case 'onetime':
      return claims.updatesUntil != null && !at.isAfter(claims.updatesUntil!);
    case 'subscription':
      return (claims.status == 'active' || claims.status == 'grace') &&
          at.isBefore(claims.expiresAt);
    default:
      return false;
  }
}
