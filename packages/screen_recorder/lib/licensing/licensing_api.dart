import 'dart:convert';

import 'package:http/http.dart' as http;

import 'licensing_config.dart';

/// Thin HTTP client for the VPS licensing endpoints the app calls directly.
/// The only app-initiated call is token refresh; initial minting happens in
/// the browser (web session), delivered back via the slipreel:// deep link.
class LicensingApi {
  LicensingApi({String? baseUrl, http.Client? client})
      : _baseUrl = baseUrl ?? LicensingConfig.apiBaseResolved,
        _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  /// POST /v1/token/refresh. Returns the new signed entitlement token, or null
  /// on any failure (auth rejected, network down, malformed response). Callers
  /// keep using the cached token until its own `exp` on a null result.
  Future<String?> refresh({
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
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['token'] is String) {
        return decoded['token'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
