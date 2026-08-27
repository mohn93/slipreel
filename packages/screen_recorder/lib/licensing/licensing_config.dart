/// Compile-time licensing endpoints. Release builds target the production
/// hosts; debug builds can point at a local server via --dart-define:
///   flutter run --dart-define=SLIPREEL_API_BASE=http://localhost:8787 \
///               --dart-define=SLIPREEL_SITE_BASE=http://localhost:8788
class LicensingConfig {
  const LicensingConfig._();

  static const String apiBase = 'https://api.slipreel.app';
  static const String siteBase = 'https://slipreel.app';

  static const String _apiOverride =
      String.fromEnvironment('SLIPREEL_API_BASE');
  static const String _siteOverride =
      String.fromEnvironment('SLIPREEL_SITE_BASE');

  static String get apiBaseResolved =>
      _apiOverride.isEmpty ? apiBase : _apiOverride;
  static String get siteBaseResolved =>
      _siteOverride.isEmpty ? siteBase : _siteOverride;
}
