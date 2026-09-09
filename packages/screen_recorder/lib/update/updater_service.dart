import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'updater_backend.dart';

/// Owns the Sparkle feed URL and manual update checks. Kept free of
/// plugin types (the backend is injected) so it is unit-testable and so no
/// Sparkle detail leaks into widgets — the UI only ever calls
/// [checkForUpdates].
class UpdaterService {
  UpdaterService(this._backend);

  final UpdaterBackend _backend;
  bool _initialized = false;

  /// GitHub-Pages-hosted appcast. Mirrors `SUFeedURL` in Info.plist.
  static const String feedUrl = 'https://slipreel.app/appcast.xml';

  /// Point Sparkle at the feed. Automatic checks are disabled before native
  /// plugin initialization so Settings can explain license compatibility. Safe to
  /// call more than once; only the first call configures the updater.
  Future<void> init() async {
    if (_initialized) return;
    await _backend.setFeedURL(feedUrl);
    _initialized = true;
  }

  /// Foreground check — surfaces Sparkle's native UI (including its own
  /// "you're up to date" dialog when there is nothing newer).
  Future<void> checkForUpdates() => _backend.checkForUpdates();
}

/// App-wide updater. Overridden in `main()` with the instance that was already
/// initialized at startup so the Settings tile shares one updater.
final updaterServiceProvider = Provider<UpdaterService>(
  (ref) => UpdaterService(SparkleUpdaterBackend()),
);
