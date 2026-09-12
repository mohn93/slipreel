import 'entitlement_claims.dart';

/// The app's current licensing state. The controller (Phase 5b) transitions
/// through these; the export gate (Phase 6) reads the loaded claims via
/// [canExport].
sealed class EntitlementState {
  const EntitlementState();
}

class EntitlementLoading extends EntitlementState {
  const EntitlementLoading();
}

class EntitlementSignedOut extends EntitlementState {
  const EntitlementSignedOut();
}

class EntitlementLoaded extends EntitlementState {
  const EntitlementLoaded(this.claims);
  final EntitlementClaims claims;
}

/// Combines verified native Apple access with signed shared account access.
class EntitlementAppStore extends EntitlementState {
  const EntitlementAppStore({
    this.productId,
    this.expiresAt,
    this.sharedClaims,
  });
  final EntitlementClaims? sharedClaims;
  final String? productId;
  final DateTime? expiresAt;
  bool activeAt(DateTime now) =>
      (productId == 'com.slipreel.store.monthly' ||
          productId == 'com.slipreel.store.yearly') &&
      expiresAt != null &&
      now.isBefore(expiresAt!);
}

/// Whether export is unlocked, per spec §2. [appReleaseDate] is this build's
/// release date (baked at build time in Phase 5b) — the version ceiling for
/// one-time licenses.
bool canExport(
  EntitlementClaims? claims, {
  required DateTime appReleaseDate,
  DateTime? now,
}) {
  if (claims == null) return false;
  final at = (now ?? DateTime.now()).toUtc();
  if (!at.isBefore(claims.expiresAt) || !claims.exportEntitled) return false;

  switch (claims.plan) {
    case 'subscription':
      return claims.status == 'active' || claims.status == 'grace';
    case 'onetime':
      final until = claims.updatesUntil;
      return claims.status == 'active' &&
          until != null &&
          !appReleaseDate.isAfter(until);
    default:
      return false;
  }
}
