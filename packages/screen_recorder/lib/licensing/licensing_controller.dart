import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'auth_state_store.dart';
import 'deep_link.dart';
import 'device_fingerprint.dart';
import 'entitlement.dart';
import 'entitlement_verifier.dart';
import 'license_store.dart';
import 'licensing_api.dart';

/// Owns the entitlement lifecycle: loads the cached token on launch, verifies
/// it offline, and re-mints via /v1/token/refresh. Also handles deep-link
/// activation and the browser handoff (Task 7).
class LicensingController extends StateNotifier<EntitlementState> {
  LicensingController({
    required LicenseStore store,
    required EntitlementVerifier verifier,
    required LicensingApi api,
    required AuthStateStore authState,
    DateTime Function() now = DateTime.now,
    DeviceFingerprint? fingerprint,
    Future<bool> Function(Uri url)? openUrl,
  })  : _store = store,
        _verifier = verifier,
        _api = api,
        _authState = authState,
        _now = now,
        _fingerprint = fingerprint ?? DeviceFingerprint(),
        _openUrl = openUrl ?? _defaultOpen,
        super(const EntitlementLoading());

  final LicenseStore _store;
  final EntitlementVerifier _verifier;
  final LicensingApi _api;
  final AuthStateStore _authState;
  final DateTime Function() _now;
  final DeviceFingerprint _fingerprint;
  final Future<bool> Function(Uri url) _openUrl;

  static Future<bool> _defaultOpen(Uri url) =>
      launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication);

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

  /// Handle a slipreel:// callback. Ignores anything that is not a valid auth
  /// link whose `state` matches the nonce we last generated (guards against a
  /// forged/stray deep link activating a token). On success: verify, persist,
  /// consume the nonce, publish loaded.
  Future<void> handleDeepLink(Uri uri) async {
    final link = AuthDeepLink.parse(uri);
    if (link == null) return;
    if (!await _authState.matches(link.state)) return;
    final claims = await _verifier.verify(link.token, now: _now());
    if (claims == null) return;
    await _store.save(LicenseTokens(
      token: link.token,
      refreshToken: link.refresh,
      deviceId: link.deviceId,
    ));
    await _authState.clear();
    state = EntitlementLoaded(claims);
  }

  /// Start the browser purchase/sign-in flow. Generates a fresh nonce, then
  /// opens `${site}/pricing?device=<fp>&state=<nonce>`. Returns whether the
  /// browser launch was requested (false if url_launcher declined).
  Future<bool> unlockExport() async {
    final fp = await _fingerprint.compute();
    final name = await _fingerprint.describe();
    final nonce = await _authState.begin();
    final url = _authState.pricingUrl(
        deviceFingerprint: fp, state: nonce, deviceName: name);
    return _openUrl(url);
  }

  /// Like [unlockExport] but opens the sign-in page instead of the plans page,
  /// for a user who has already purchased (another device, or after sign-out).
  Future<bool> openSignIn() async {
    final fp = await _fingerprint.compute();
    final name = await _fingerprint.describe();
    final nonce = await _authState.begin();
    final url = _authState.loginUrl(
        deviceFingerprint: fp, state: nonce, deviceName: name);
    return _openUrl(url);
  }

  /// Clear local credentials and the pending nonce; revert to signed-out.
  /// (Server-side seat release via DELETE /v1/devices/:id is done from the web
  /// account page; a native call can be added later.)
  Future<void> signOut() async {
    await _store.clear();
    await _authState.clear();
    state = const EntitlementSignedOut();
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
