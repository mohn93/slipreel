import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'recording_action_router.dart';
import 'recording_state.dart';

typedef _VoidCallback = void Function();

/// Auto-pauses recording on macOS sleep and surfaces a callback for the
/// on-wake modal. Tracks whether the current pause originated here so manual
/// pauses don't trigger the wake modal.
class SleepObserver {
  SleepObserver({
    required ScreenRecorderPlatform platform,
    required RecordingActionRouter router,
    required ProviderContainer container,
    this.onWake,
  })  : _platform = platform,
        _router = router,
        _container = container {
    _init();
  }

  final ScreenRecorderPlatform _platform;
  final RecordingActionRouter _router;
  final ProviderContainer _container;
  final _VoidCallback? onWake;

  StreamSubscription<Map<dynamic, dynamic>>? _sub;
  ProviderSubscription<RecordingState>? _stateSub;

  /// True iff the current paused state was triggered by willSleep.
  bool pausedBySleep = false;

  Future<void> _init() async {
    await _platform.startSleepObserver();
    _sub = _platform.sleepEvents.listen(_onEvent);
    _stateSub = _container.listen(recordingControllerProvider, (prev, next) {
      // Clear flag on any transition OUT of paused.
      if (prev?.status == RecordingStatus.paused &&
          next.status != RecordingStatus.paused) {
        pausedBySleep = false;
      }
    });
  }

  void _onEvent(Map<dynamic, dynamic> event) {
    final kind = event['event'] as String?;
    switch (kind) {
      case 'willSleep':
        final status = _container.read(recordingControllerProvider).status;
        if (status == RecordingStatus.recording) {
          pausedBySleep = true;
          _router.pauseOrResume();
        }
        break;
      case 'didWake':
        if (pausedBySleep) onWake?.call();
        break;
    }
  }

  void dispose() {
    _sub?.cancel();
    _stateSub?.close();
    _sub = null;
    _stateSub = null;
  }
}

final sleepObserverProvider = Provider<SleepObserver>(
  (ref) => throw UnimplementedError(
    'Override sleepObserverProvider in main()',
  ),
);
