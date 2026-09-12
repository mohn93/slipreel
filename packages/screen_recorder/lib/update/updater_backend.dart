import 'package:flutter/services.dart';
import '../distribution/distribution_channel.dart';

/// Thin seam over the `auto_updater` plugin so [UpdaterService] can be unit
/// tested without the native Sparkle plugin (which only loads in a real macOS
/// app process). The production implementation just forwards to the plugin's
/// global `autoUpdater` singleton.
abstract class UpdaterBackend {
  Future<void> setFeedURL(String url);
  Future<void> setScheduledCheckInterval(int seconds);
  Future<void> checkForUpdates({bool inBackground = false});
}

/// Real backend: delegates to Sparkle via the `auto_updater` plugin.
class SparkleUpdaterBackend implements UpdaterBackend {
  static const _channel = MethodChannel('dev.leanflutter.plugins/auto_updater');
  Future<void> _invoke(String method, Map<String,Object> args) async {
    if (DistributionChannel.isAppStore) return;
    await _channel.invokeMethod<void>(method,args);
  }
  @override
  Future<void> setFeedURL(String url) => _invoke('setFeedURL', {'feedURL':url});

  @override
  Future<void> setScheduledCheckInterval(int seconds) =>
      _invoke('setScheduledCheckInterval', {'interval':seconds});

  @override
  Future<void> checkForUpdates({bool inBackground = false}) =>
      _invoke('checkForUpdates', {'inBackground':inBackground});
}
