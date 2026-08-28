import 'dart:convert';

import 'package:http/http.dart' as http;

import 'licensing_config.dart';

/// Outcome of a token refresh. The distinction that matters: a definitive
/// server rejection (the device's seat was revoked — e.g. deactivated from the
/// account page) must lock this device, whereas a transient failure (offline,
/// 5xx, malformed body) must NOT — the app keeps using the cached token under
/// its own `exp` so offline users are not locked out by a flaky network.
sealed class RefreshResult {
  const RefreshResult();
}

/// The server minted a fresh entitlement token.
class RefreshOk extends RefreshResult {
  const RefreshOk(this.token);
  final String token;
}

/// The server rejected the refresh token / device (HTTP 401 or 403): this seat
/// is no longer valid. Callers clear credentials and revert to signed-out.
class RefreshRevoked extends RefreshResult {
  const RefreshRevoked();
}

/// Network error, timeout, 5xx, or a malformed 200: the outcome is unknown, so
/// callers keep the cached token under its own `exp`.
class RefreshTransient extends RefreshResult {
  const RefreshTransient();
}

/// Thin HTTP client for the VPS licensing endpoints the app calls directly.
/// The only app-initiated call is token refresh; initial minting happens in
/// the browser (web session), delivered back via the slipreel:// deep link.
class LicensingApi {
  LicensingApi({String? baseUrl, http.Client? client})
      : _baseUrl = baseUrl ?? LicensingConfig.apiBaseResolved,
        _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  /// POST /v1/token/refresh. A 200 with a token is [RefreshOk]; a 401/403 is
  /// [RefreshRevoked] (the seat was deactivated server-side — lock this
  /// device); anything else (network down, 5xx, malformed body) is
  /// [RefreshTransient] (keep the cached token under its own `exp`).
  Future<RefreshResult> refresh({
    required String refreshToken,
    required String deviceId,
  }) async {
    try {
      final res = await _client.post(
        Uri.parse('$_baseUrl/v1/token/refresh'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'refresh_token': refreshToken,
          'device_id': deviceId,
        }),
      );
      if (res.statusCode == 401 || res.statusCode == 403) {
        return const RefreshRevoked();
      }
      if (res.statusCode != 200) return const RefreshTransient();
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['token'] is String) {
        return RefreshOk(decoded['token'] as String);
      }
      return const RefreshTransient();
    } catch (_) {
      return const RefreshTransient();
    }
  }

  void close() => _client.close();
}
