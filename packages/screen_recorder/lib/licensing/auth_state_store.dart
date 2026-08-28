import 'dart:convert';
import 'dart:math';

import 'licensing_config.dart';
import 'license_store.dart';

/// Owns the single-use `state` nonce for the browser activation handoff, and
/// builds the pricing URL that carries the device fingerprint + nonce. The
/// nonce guards against a stray/forged deep link activating a token: only the
/// nonce the app just generated is accepted on the callback.
class AuthStateStore {
  AuthStateStore(this._kv);

  final SecureKV _kv;
  static const _key = 'slipreel.auth_state';

  /// Generates a fresh 256-bit nonce, persists it as the sole pending state,
  /// and returns it. Any previously pending nonce is overwritten.
  Future<String> begin() async {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final nonce = base64Url.encode(bytes).replaceAll('=', '');
    await _kv.write(_key, nonce);
    return nonce;
  }

  /// True iff [state] equals the currently pending nonce (constant-time-ish
  /// equality on equal-length strings is not required here — the nonce is
  /// single-use and unguessable).
  Future<bool> matches(String state) async {
    final pending = await _kv.read(_key);
    if (pending == null || pending.isEmpty) return false;
    return pending == state;
  }

  Future<void> clear() => _kv.delete(_key);

  /// `${siteBase}/pricing?device=<fp>&state=<nonce>[&device_name=...]`.
  Uri pricingUrl({
    required String deviceFingerprint,
    required String state,
    String? deviceName,
  }) =>
      _authUrl('/pricing', deviceFingerprint, state, deviceName);

  /// `${siteBase}/login?device=<fp>&state=<nonce>[&device_name=...]` — the
  /// sign-in page for a returning/already-purchased user (vs [pricingUrl]).
  Uri loginUrl({
    required String deviceFingerprint,
    required String state,
    String? deviceName,
  }) =>
      _authUrl('/login', deviceFingerprint, state, deviceName);

  Uri _authUrl(String path, String fingerprint, String state, String? name) {
    final base = Uri.parse(LicensingConfig.siteBaseResolved);
    final query = <String, String>{'device': fingerprint, 'state': state};
    if (name != null && name.isNotEmpty) query['device_name'] = name;
    return base.replace(path: path, queryParameters: query);
  }
}
