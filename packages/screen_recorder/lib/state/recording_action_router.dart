import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'countdown_controller.dart';
import 'microphone_controller.dart';
import 'permissions_controller.dart';
import 'recording_settings_controller.dart';
import 'recording_state.dart';
import 'system_audio_controller.dart';
import '../ui/widgets/permission_denied_sheet.dart';

/// Single funnel for every start/stop/pause trigger — UI button, hotkey,
/// sleep observer. Owns the countdown decision; delegates the deny-sheet
/// gate to RecordingController.startRecording's existing guard.
class RecordingActionRouter {
  RecordingActionRouter(this._container);
  final ProviderContainer _container;

  Future<void> start(BuildContext context) async {
    final settings = _container.read(recordingSettingsControllerProvider);
    final seconds = settings.countdownSeconds;

    Future<void> doStart() async {
      final controller = _container.read(recordingControllerProvider.notifier);
      // Read optional providers with try/catch — they throw by default until
      // overridden in main(). Tests that don't care about permissions/audio
      // still work; production wires all providers before first use.
      PermissionsSnapshot? snapshot;
      MicrophoneConfig? micConfig;
      SystemAudioConfig? sysAudioConfig;
      try {
        snapshot = _container.read(permissionsControllerProvider);
      } catch (_) {}
      try {
        micConfig = _container.read(microphoneControllerProvider);
        sysAudioConfig = _container.read(systemAudioControllerProvider);
      } catch (_) {
        // Providers not overridden in test — that's fine; recording can
        // proceed without mic / system audio configs.
      }
      await controller.startRecording(
        microphone: micConfig,
        systemAudio: sysAudioConfig,
        permissions: snapshot,
        onDenied: (kind) {
          if (!context.mounted) return Future.value();
          return PermissionDeniedSheet.show(context, kind);
        },
      );
    }

    if (seconds <= 0) {
      await doStart();
      return;
    }

    _container.read(countdownControllerProvider.notifier).run(
          seconds: seconds,
          onComplete: () {
            unawaited(doStart());
          },
        );
  }

  Future<void> stop() async {
    final countdown = _container.read(countdownControllerProvider);
    if (countdown.active) {
      _container.read(countdownControllerProvider.notifier).cancel();
      return;
    }
    await _container.read(recordingControllerProvider.notifier).stopRecording();
  }

  Future<void> pauseOrResume() async {
    final status = _container.read(recordingControllerProvider).status;
    final controller = _container.read(recordingControllerProvider.notifier);
    if (status == RecordingStatus.recording) {
      await controller.pauseRecording();
    } else if (status == RecordingStatus.paused) {
      await controller.resumeRecording();
    }
  }
}

/// Throw-by-default provider. Set in main() so HotkeyController + SleepObserver
/// can resolve it via Ref if needed.
final recordingActionRouterProvider = Provider<RecordingActionRouter>(
  (ref) => throw UnimplementedError(
    'Override recordingActionRouterProvider in main()',
  ),
);

/// Mutable singleton set by _MyAppState._initRecordingSurfaces (Task 23).
/// The bar's _pickAndRecord (Task 24) reads this to route start through the
/// countdown. Null until MyApp finishes its first frame.
RecordingActionRouter? recordingActionRouterRef;
