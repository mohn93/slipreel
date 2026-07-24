import 'package:auto_updater/auto_updater.dart';

/// Thin seam over the `auto_updater` plugin so [UpdaterService] can be unit
/// tested without the native Sparkle plugin (which only loads in a real macOS
/// app process). The production implementation just forwards to the plugin's
/// global `autoUpdater` singleton.
abstract class UpdaterBackend {
  Future<void> setFeedURL(String url);
  Future<void> setScheduledCheckInterval(int seconds);
  Future<void> checkForUpdates();
}

/// Real backend: delegates to Sparkle via the `auto_updater` plugin.
class SparkleUpdaterBackend implements UpdaterBackend {
  @override
  Future<void> setFeedURL(String url) => autoUpdater.setFeedURL(url);

  @override
  Future<void> setScheduledCheckInterval(int seconds) =>
      autoUpdater.setScheduledCheckInterval(seconds);

  @override
  Future<void> checkForUpdates() => autoUpdater.checkForUpdates();
}
