import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import 'recording_action_router.dart';

/// Subscribes to the native hotkey EventChannel and routes events through
/// the RecordingActionRouter.
class HotkeyController {
  HotkeyController({
    required ScreenRecorderPlatform platform,
    required RecordingActionRouter router,
    required BuildContext? Function() rootContextProvider,
  })  : _platform = platform,
        _router = router,
        _rootContextProvider = rootContextProvider {
    _init();
  }

  final ScreenRecorderPlatform _platform;
  final RecordingActionRouter _router;
  final BuildContext? Function() _rootContextProvider;
  StreamSubscription<Map<dynamic, dynamic>>? _sub;

  Future<void> _init() async {
    await _platform.registerRecordingHotkeys();
    _sub = _platform.hotkeyEvents.listen(_onEvent);
  }

  void _onEvent(Map<dynamic, dynamic> event) {
    final action = event['action'] as String?;
    switch (action) {
      case 'start':
        final ctx = _rootContextProvider();
        if (ctx != null) _router.start(ctx);
        break;
      case 'stop':
        _router.stop();
        break;
      case 'pauseToggle':
        _router.pauseOrResume();
        break;
      default:
        final kind = event['event'];
        if (kind == 'conflict') {
          AppLogger.platform.w('Hotkey conflict on id ${event['id']}');
        }
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _platform.unregisterRecordingHotkeys();
  }
}

final hotkeyControllerProvider = Provider<HotkeyController>(
  (ref) => throw UnimplementedError(
    'Override hotkeyControllerProvider in main()',
  ),
);
