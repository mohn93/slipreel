/// Parsed `slipreel://auth?token=&refresh=&device_id=&state=` callback from the
/// web activation flow. The shape is fixed by the site's success/login pages.
class AuthDeepLink {
  const AuthDeepLink({
    required this.token,
    required this.refresh,
    required this.deviceId,
    required this.state,
  });

  final String token;
  final String refresh;
  final String deviceId;
  final String state;

  /// Returns null unless [uri] is a slipreel://auth link with all four params
  /// present and non-empty. Note macOS delivers the authority as the URI host.
  static AuthDeepLink? parse(Uri uri) {
    if (uri.scheme != 'slipreel') return null;
    if (uri.host != 'auth') return null;
    final q = uri.queryParameters;
    final token = q['token'] ?? '';
    final refresh = q['refresh'] ?? '';
    final deviceId = q['device_id'] ?? '';
    final state = q['state'] ?? '';
    if (token.isEmpty || refresh.isEmpty || deviceId.isEmpty || state.isEmpty) {
      return null;
    }
    return AuthDeepLink(
      token: token,
      refresh: refresh,
      deviceId: deviceId,
      state: state,
    );
  }
}
