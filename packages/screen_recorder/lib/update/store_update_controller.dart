import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../distribution/distribution_channel.dart';
import 'store_firebase_options.dart';
import 'store_update_policy.dart';

final activeUpdateExportsProvider = StateProvider<int>((ref) => 0);
final storeUpdateProvider =
    StateNotifierProvider<StoreUpdateController, StoreUpdatePolicy?>((ref) {
      final controller = StoreUpdateController();
      if (DistributionChannel.isAppStore) unawaited(controller.refresh());
      return controller;
    });

class StoreUpdateController extends StateNotifier<StoreUpdatePolicy?> {
  StoreUpdateController() : super(null);
  FirebaseRemoteConfig? _config;
  StreamSubscription<RemoteConfigUpdate>? _subscription;
  Future<void>? _pending;
  int _build = 0;
  int? _dismissedBuild;

  Future<void> refresh() {
    if (!DistributionChannel.isAppStore) return Future.value();
    return _pending ??= _refresh().whenComplete(() => _pending = null);
  }

  Future<void> _refresh() async {
    try {
      if (_config == null) {
        _build =
            int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
        final app = await Firebase.initializeApp(options: storeFirebaseOptions);
        if (!mounted) return;
        final config = FirebaseRemoteConfig.instanceFor(app: app);
        await config.setConfigSettings(
          RemoteConfigSettings(
            fetchTimeout: const Duration(seconds: 8),
            minimumFetchInterval: const Duration(hours: 1),
          ),
        );
        await config.setDefaults(const {
          'store_update_available': false,
          'store_latest_build': 0,
          'store_minimum_build': 0,
          'store_latest_version': '0.0.0',
        });
        if (!mounted) return;
        _config = config;
        _subscription = config.onConfigUpdated.listen((_) async {
          try {
            await config.activate();
            _publish();
          } catch (_) {
            /* Keep the last successfully activated policy. */
          }
        }, onError: (Object _) {});
        _publish();
      }
      await _config!.fetchAndActivate();
      _publish();
    } catch (_) {
      // Offline launches retain a validated cached policy, never invent a gate.
    }
  }

  void _publish() {
    if (!mounted) return;
    final config = _config!;
    final policy = StoreUpdatePolicy.parse({
      'store_update_available': config.getBool('store_update_available'),
      'store_latest_build': config.getString('store_latest_build'),
      'store_minimum_build': config.getString('store_minimum_build'),
      'store_latest_version': config.getString('store_latest_version'),
    }, _build);
    state =
        policy != null && !policy.required && policy.build == _dismissedBuild
        ? null
        : policy;
  }

  void dismiss() {
    if (state?.required ?? false) return;
    _dismissedBuild = state?.build;
    state = null;
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
