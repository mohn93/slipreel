import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_state_store.dart';
import 'entitlement.dart';
import 'entitlement_verifier.dart';
import 'license_store.dart';
import 'licensing_api.dart';

/// Owns the entitlement lifecycle: loads the cached token on launch, verifies
/// it offline, and re-mints via /v1/token/refresh. Deep-link activation and
/// the browser handoff are added in Task 7.
class LicensingController extends StateNotifier<EntitlementState> {
  LicensingController({
    required LicenseStore store,
    required EntitlementVerifier verifier,
    required LicensingApi api,
    required AuthStateStore authState,
    DateTime Function() now = DateTime.now,
  })  : _store = store,
        _verifier = verifier,
        _api = api,
        _authState = authState,
        _now = now,
        super(const EntitlementLoading());

  final LicenseStore _store;
  final EntitlementVerifier _verifier;
  final LicensingApi _api;
  // ignore: unused_field
  final AuthStateStore _authState; // used starting Task 7 (deep-link activation)
  final DateTime Function() _now;

  /// Read the Keychain token, verify it, publish loaded/signed-out. Called once
  /// at startup before the UI reads entitlement.
  Future<void> load() async {
    final tokens = await _store.load();
    if (tokens == null) {
      state = const EntitlementSignedOut();
      return;
    }
    final claims = await _verifier.verify(tokens.token, now: _now());
    state = claims == null
        ? const EntitlementSignedOut()
        : EntitlementLoaded(claims);
  }

  /// Re-mint from the stored refresh token. No-op without cached tokens; keeps
  /// current state if the network/auth call fails (offline grace lives in the
  /// cached token's own exp).
  Future<void> refreshNow() async {
    final tokens = await _store.load();
    if (tokens == null) return;
    final fresh = await _api.refresh(
      refreshToken: tokens.refreshToken,
      deviceId: tokens.deviceId,
    );
    if (fresh == null) return;
    final claims = await _verifier.verify(fresh, now: _now());
    if (claims == null) return;
    await _store.save(LicenseTokens(
      token: fresh,
      refreshToken: tokens.refreshToken,
      deviceId: tokens.deviceId,
    ));
    state = EntitlementLoaded(claims);
  }
}

/// Overridden in main.dart with the fully-wired instance.
final licensingControllerProvider =
    StateNotifierProvider<LicensingController, EntitlementState>((ref) {
  throw UnimplementedError(
      'licensingControllerProvider must be overridden in main.dart');
});

/// Read-only entitlement state for gates/UI.
final entitlementProvider = Provider<EntitlementState>(
  (ref) => ref.watch(licensingControllerProvider),
);
