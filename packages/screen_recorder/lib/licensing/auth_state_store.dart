import 'dart:convert';
import 'dart:math';

import 'licensing_config.dart';
import 'license_store.dart';

/// Owns the single-use `state` nonce for the browser activation handoff, and
/// builds the pricing URL that carries the device fingerprint + nonce. The
/// nonce guards against a stray/forged deep link activating a token: only the
/// nonce the app generated is accepted on the callback.
class AuthStateStore {
  AuthStateStore(this._kv, {DateTime Function() now = DateTime.now})
      : _now = now;

  final SecureKV _kv;
  final DateTime Function() _now;
  Future<String>? _beginInFlight;
  static const _key = 'slipreel.auth_state';

  /// How long a pending nonce is reused by [begin]. Covers the 30-minute
  /// magic-link lifetime plus a checkout, so clicking Sign in again while an
  /// email is on its way does not invalidate that email's link.
  static const reuseWindow = Duration(hours: 1);

  /// Returns the pending nonce if it was issued within [reuseWindow];
  /// otherwise generates a fresh 256-bit nonce and persists it as the sole
  /// pending state. Overlapping calls (a fast double-click) share one result.
  Future<String> begin() =>
      _beginInFlight ??= _begin().whenComplete(() => _beginInFlight = null);

  Future<String> _begin() async {
    final pending = _decode(await _kv.read(_key));
    final issued = pending?.issued;
    final now = _now();
    if (issued != null &&
        !issued.isAfter(now) &&
        now.difference(issued) < reuseWindow) {
      return pending!.nonce;
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final nonce = base64Url.encode(bytes).replaceAll('=', '');
    await _kv.write(
      _key,
      jsonEncode({'nonce': nonce, 'issued': now.millisecondsSinceEpoch}),
    );
    return nonce;
  }

  /// True iff [state] equals the currently pending nonce (constant-time-ish
  /// equality on equal-length strings is not required here — the nonce is
  /// single-use and unguessable).
  Future<bool> matches(String state) async {
    final pending = _decode(await _kv.read(_key));
    if (pending == null || pending.nonce.isEmpty) return false;
    return pending.nonce == state;
  }

  /// Reads `{"nonce", "issued"}`. A plain string is a nonce written before
  /// reuse existed: still valid for [matches], never reused by [begin].
  static ({String nonce, DateTime? issued})? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('{')) return (nonce: raw, issued: null);
    try {
      final map = jsonDecode(raw);
      final nonce = map is Map ? map['nonce'] : null;
      final issued = map is Map ? map['issued'] : null;
      if (nonce is! String || nonce.isEmpty || issued is! int) return null;
      return (
        nonce: nonce,
        issued: DateTime.fromMillisecondsSinceEpoch(issued, isUtc: true),
      );
    } on Object {
      // Malformed JSON or an out-of-range timestamp: treat as nothing pending.
      return null;
    }
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
