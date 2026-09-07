import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'auth_state_store.dart';
import 'build_release_date.g.dart';
import 'export_gate.dart';
import 'licensing_config.dart';
import 'sign_in_feedback.dart';
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

  final signInFeedback = SignInFeedbackController();
  Uri? _lastAuthCallback;

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

  /// Re-mint from the stored refresh token. No-op without cached tokens.
  ///
  /// - [RefreshOk]: verify + persist the fresh token, publish loaded.
  /// - [RefreshRevoked]: the seat was deactivated server-side (this device was
  ///   removed from the account) — clear credentials and lock (signed-out).
  /// - [RefreshTransient]: offline/unknown — keep the current state; offline
  ///   grace lives in the cached token's own exp.
  Future<void> refreshNow() async {
    final tokens = await _store.load();
    if (tokens == null) return;
    final result = await _api.refresh(
      refreshToken: tokens.refreshToken,
      deviceId: tokens.deviceId,
    );
    switch (result) {
      case RefreshOk(:final token):
        final claims = await _verifier.verify(token, now: _now());
        if (claims == null) return;
        await _store.save(LicenseTokens(
          token: token,
          refreshToken: tokens.refreshToken,
          deviceId: tokens.deviceId,
        ));
        state = EntitlementLoaded(claims);
      case RefreshRevoked():
        await signOut();
      case RefreshTransient():
        return;
    }
  }

  /// Handle a slipreel:// callback. Ignores anything that is not a valid auth
  /// link whose `state` matches the nonce we last generated (guards against a
  /// forged/stray deep link activating a token). On success: verify, persist,
  /// consume the nonce, publish loaded.
  Future<void> handleDeepLink(Uri uri) async {
    if (uri.scheme != 'slipreel' || uri.host != 'auth') return;
    // app_links may deliver the initial callback again on its stream.
    if (uri == _lastAuthCallback) return;
    _lastAuthCallback = uri;
    try {
      final nonce = uri.queryParameters['state'] ?? '';
      if (nonce.isEmpty || !await _authState.matches(nonce)) {
        signInFeedback.show(const SignInFeedback(
          'Sign-in link expired',
          'This link does not match the sign-in started on this Mac. '
          'Start sign-in again from Slipreel and use the newest email link.',
          action: 'signin',
        ));
        return;
      }
      final error = uri.queryParameters['error'];
      if (error != null) {
        await _authState.clear();
        signInFeedback.show(error == 'seat_limit'
            ? const SignInFeedback('Device limit reached',
                'This account has reached its device limit. Remove a device '
                'from your account, then sign in again on this Mac.')
            : const SignInFeedback('Could not activate this Mac',
                'Your browser sign-in succeeded, but this Mac could not be '
                'activated. Please try signing in again.', action: 'signin'));
        return;
      }
      final link = AuthDeepLink.parse(uri);
      final claims = link == null
          ? null
          : await _verifier.verify(link.token, now: _now());
      if (link == null || claims == null || claims.deviceId != link.deviceId) {
        signInFeedback.show(const SignInFeedback('Could not verify sign-in',
            'The activation link is invalid or expired. Request a new sign-in '
            'link from Slipreel.', action: 'signin'));
        return;
      }
      await _store.save(LicenseTokens(
        token: link.token, refreshToken: link.refresh, deviceId: link.deviceId,
      ));
      await _authState.clear();
      state = EntitlementLoaded(claims);
      final reason = paywallReasonFor(state,
          appReleaseDate: buildReleaseDate, now: _now());
      if (reason == null) {
        signInFeedback.show(SignInFeedback('Signed in successfully',
          claims.plan == 'onetime'
              ? 'Your one-time license is active on this Mac. Unlimited exports are unlocked.'
              : 'Your subscription is active on this Mac. Unlimited exports are unlocked.'));
      } else if (reason == PaywallReason.updateCeiling) {
        signInFeedback.show(const SignInFeedback('Signed in — update renewal needed',
            'Your one-time license covers an earlier version of Slipreel. '
            'Keep exporting with that version, or renew updates to unlock this version.'));
      } else if (reason == PaywallReason.subscriptionLapsed) {
        signInFeedback.show(const SignInFeedback('Signed in — subscription inactive',
            'Your subscription is not active. Manage your subscription to restore unlimited exports.'));
      } else {
        signInFeedback.show(const SignInFeedback('Signed in — no active license',
            'This account has no active subscription or one-time license. '
            'Any remaining free exports are still available on this Mac. '
            'Choose a plan to unlock unlimited exports.', action: 'pricing'));
      }
    } catch (_) {
      // Do not expose/log callback tokens, file paths, or transport errors.
      signInFeedback.show(const SignInFeedback('Sign-in could not finish',
          'Slipreel could not verify or save your sign-in. Please try again.',
          action: 'signin'));
    }
  }

  Future<bool> openAccount() => _openUrl(
      Uri.parse(LicensingConfig.siteBaseResolved).replace(path: '/account'));

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

/// Retains cold-start callback feedback until the root UI is ready.
final signInFeedbackProvider = ChangeNotifierProvider<SignInFeedbackController>(
  (ref) => ref.watch(licensingControllerProvider.notifier).signInFeedback,
);
