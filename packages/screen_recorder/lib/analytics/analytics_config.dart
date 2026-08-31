/// Compile-time analytics config. The public PostHog project key is baked in
/// at build time via --dart-define, so it is not committed to source:
///   flutter build macos --dart-define=SLIPREEL_POSTHOG_KEY=phc_xxx
///
/// The key is write-only (safe to ship in a binary). When it is absent the
/// whole analytics layer no-ops, so debug/dev builds send nothing unless you
/// opt in with the same --dart-define.
///
/// The desktop app posts DIRECTLY to PostHog's US ingestion host — unlike the
/// website (which proxies through nginx to stay first-party for ad-blockers),
/// a native app has no browser, no tracker blockers, and no same-origin rule,
/// so a direct HTTPS call is simplest and most robust. Same PostHog *project*
/// as the website; web vs app is distinguished by the `source` property.
class AnalyticsConfig {
  const AnalyticsConfig._();

  /// PostHog US ingestion host. Override for a local/dev PostHog via
  /// --dart-define=SLIPREEL_POSTHOG_HOST=http://localhost:8000.
  static const String host = 'https://us.i.posthog.com';

  static const String _hostOverride =
      String.fromEnvironment('SLIPREEL_POSTHOG_HOST');

  static String get hostResolved =>
      _hostOverride.isEmpty ? host : _hostOverride;

  /// Public project (write-only) API key. Empty in source; supplied at build.
  static const String projectKey =
      String.fromEnvironment('SLIPREEL_POSTHOG_KEY');

  /// True only when a real project key was baked in. Gates all sending.
  static bool get isConfigured => projectKey.startsWith('phc_');
}
