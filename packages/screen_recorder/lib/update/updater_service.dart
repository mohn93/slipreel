import '../distribution/distribution_channel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../licensing/entitlement.dart';

import 'updater_backend.dart';
import 'required_update.dart';
import 'update_eligibility.dart';
export 'update_eligibility.dart';

/// Owns the Sparkle feed URL and license-aware startup update checks. Kept free of
/// plugin types (the backend is injected) so it is unit-testable and so no
/// Sparkle detail leaks into widgets — the UI only ever calls
/// [checkForUpdates].
class UpdaterService {
  UpdaterService(this._backend, {this.loadRequiredUpdate});

  final Future<RequiredUpdate?> Function()? loadRequiredUpdate;
  RequiredUpdate? _requiredUpdate;
  Future<RequiredUpdate?>? _startupCheck;

  final UpdaterBackend _backend;
  Future<void>? _initialization;
  bool _startupChecked = false;

  /// GitHub-Pages-hosted appcast. Mirrors `SUFeedURL` in Info.plist.
  static const String feedUrl = 'https://slipreel.app/appcast.xml';

  /// Native scheduling stays disabled so it cannot bypass the license gate.
  Future<void> init() => DistributionChannel.isAppStore ? Future.value() : _initialization ??= _backend
      .setFeedURL(feedUrl)
      .catchError((Object error, StackTrace stack) {
        _initialization = null;
        Error.throwWithStackTrace(error, stack);
      });

  /// Check once per launch after licensing resolves. Background checks show
  /// an optional update offer only when a newer release exists.
  Future<RequiredUpdate?> checkAtStartup(
    EntitlementState Function() readEntitlement, {
    DateTime Function()? now,
  }) async {
    if (DistributionChannel.isAppStore) return null;
    if (!canOfferAutomaticUpdate(readEntitlement(), now: now?.call())) {
      return null;
    }
    if (_startupChecked) return _requiredUpdate;
    return _startupCheck ??= _checkAtStartup(
      readEntitlement,
      now: now,
    ).whenComplete(() => _startupCheck = null);
  }

  Future<RequiredUpdate?> _checkAtStartup(
    EntitlementState Function() readEntitlement, {
    DateTime Function()? now,
  }) async {
    await init();
    final requirement = await loadRequiredUpdate?.call();
    if (!canOfferAutomaticUpdate(readEntitlement(), now: now?.call())) {
      return null;
    }
    _startupChecked = true;
    if (requirement != null &&
        requirement.appliesTo(readEntitlement(), now: now?.call())) {
      _requiredUpdate = requirement;
      return requirement;
    }
    await _backend.checkForUpdates(inBackground: true);
    return null;
  }

  /// Foreground check — surfaces Sparkle's native UI (including its own
  /// "you're up to date" dialog when there is nothing newer).
  Future<void> checkForUpdates() async {
    if (DistributionChannel.isAppStore) return;
    await init();
    await _backend.checkForUpdates();
  }
}

/// App-wide updater. Overridden in `main()` with the instance that was already
/// initialized at startup so the Settings tile shares one updater.
final updaterServiceProvider = Provider<UpdaterService>(
  (ref) => UpdaterService(SparkleUpdaterBackend()),
);
