/// Selected by the release pipeline, never by a receipt file or user setting.
/// Native code independently verifies the channel before enabling StoreKit.
abstract final class DistributionChannel {
  static const name = String.fromEnvironment(
    'SLIPREEL_DISTRIBUTION',
    defaultValue: 'direct',
  );
  static const isAppStore = name == 'app-store';
}
