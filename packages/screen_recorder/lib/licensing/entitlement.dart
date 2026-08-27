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
  if (at.isAfter(claims.expiresAt)) return false;

  switch (claims.plan) {
    case 'subscription':
      return claims.status == 'active' || claims.status == 'grace';
    case 'onetime':
      final until = claims.updatesUntil;
      return until != null && !appReleaseDate.isAfter(until);
    default:
      return false;
  }
}
