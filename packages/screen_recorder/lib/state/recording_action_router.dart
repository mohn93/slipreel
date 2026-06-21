import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'countdown_controller.dart';
import 'camera_controller.dart';
import 'global_preferences_controller.dart';
import 'microphone_controller.dart';
import 'permissions_controller.dart';
import 'recording_settings_controller.dart';
import 'recording_state.dart';
import 'system_audio_controller.dart';
import 'window_mode_controller.dart';
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

    // Device-source pre-flight (BEFORE the countdown). An iPhone/iPad over USB
    // is a VIDEO AVCaptureDevice, so Camera permission is required. Checking it
    // here means we never run a 3-2-1 countdown only to deny at the end, and —
    // crucially — we never render the deny UI inside the 68px bar window.
    final armed = _container.read(recordingControllerProvider);
    if (armed.selectedSourceKind == RecordingSource.device &&
        armed.selectedSourceId != null) {
      if (!await _ensureCameraForDevice(context)) return;
    }

    Future<void> doStart() async {
      final controller = _container.read(recordingControllerProvider.notifier);
      // Read optional providers with try/catch — they throw by default until
      // overridden in main(). Tests that don't care about permissions/audio
      // still work; production wires all providers before first use.
      PermissionsSnapshot? snapshot;
      MicrophoneConfig? micConfig;
      SystemAudioConfig? sysAudioConfig;
      CameraConfig? cameraConfig;
      try {
        snapshot = _container.read(permissionsControllerProvider);
      } catch (_) {}
      try {
        micConfig = _container.read(microphoneControllerProvider);
        sysAudioConfig = _container.read(systemAudioControllerProvider);
        cameraConfig = _container.read(cameraControllerProvider);
      } catch (_) {
        // Providers not overridden in test — that's fine; recording can
        // proceed without mic / system audio / camera configs.
      }
      String? defaultSaveLocation;
      try {
        defaultSaveLocation =
            _container.read(globalPreferencesControllerProvider).defaultSaveLocation;
      } catch (_) {}

      // Device sources (iPhone/iPad over USB) take a different start path: the
      // device feeds its own audio/video, so there's no host system-audio,
      // camera, or cursor capture. Branch on the armed source kind.
      final state = _container.read(recordingControllerProvider);
      if (state.selectedSourceKind == RecordingSource.device &&
          state.selectedSourceId != null) {
        await controller.startDeviceRecording(
          deviceId: state.selectedSourceId!,
          captureDeviceAudio:
              _container.read(deviceAudioEnabledProvider),
          microphone: micConfig,
          permissions: snapshot,
          onDenied: (kind) {
            if (!context.mounted) return Future.value();
            return _showDeniedPanel(context, kind);
          },
          defaultSaveLocation: defaultSaveLocation,
        );
        return;
      }

      await controller.startRecording(
        microphone: micConfig,
        systemAudio: sysAudioConfig,
        camera: cameraConfig,
        permissions: snapshot,
        onDenied: (kind) {
          if (!context.mounted) return Future.value();
          return _showDeniedPanel(context, kind);
        },
        defaultSaveLocation: defaultSaveLocation,
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

  /// Ensures Camera permission for a device recording. Returns true to proceed,
  /// false if it ended up denied (a deny panel was shown; caller must abort).
  ///
  /// - granted / unsupported → proceed.
  /// - notDetermined → trigger the macOS camera prompt; proceed iff the user
  ///   grants it inline.
  /// - denied / restricted (or still-not-granted) → show the deny panel, abort.
  ///
  /// If the permissions provider isn't wired (e.g. tests that don't override
  /// it), treats the recording as ungated and returns true — matching the
  /// controller's own permission gate, which also no-ops on a null snapshot.
  Future<bool> _ensureCameraForDevice(BuildContext context) async {
    final PermissionsController perms;
    try {
      perms = _container.read(permissionsControllerProvider.notifier);
    } catch (_) {
      return true;
    }
    var status = _container.read(permissionsControllerProvider).camera;
    if (status == PermissionStatus.granted ||
        status == PermissionStatus.unsupported) {
      return true;
    }
    if (status == PermissionStatus.notDetermined) {
      status = await perms.request(PermissionKind.camera); // system prompt
      if (status == PermissionStatus.granted) return true;
    }
    if (context.mounted) {
      await _showDeniedPanel(context, PermissionKind.camera);
    }
    return false;
  }

  /// Shows the permission-denied UI as a full-screen **panel**, not a bottom
  /// sheet. The recording bar window is ~68px tall, so `showModalBottomSheet`
  /// would clip to an empty scrim there. Switch to panel mode, push the screen,
  /// and restore the bar once it's dismissed.
  Future<void> _showDeniedPanel(BuildContext context, PermissionKind kind) async {
    final window = _container.read(windowModeControllerProvider.notifier);
    await window.showPanel();
    if (context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PermissionDeniedScreen(kind: kind)),
      );
    }
    await window.showBar();
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

/// Whether device-audio capture is enabled for the next device recording
/// (iPhone/iPad over USB). Driven by the bar's device-audio control; read by
/// [RecordingActionRouter] when starting a device source. Defaults to true.
final deviceAudioEnabledProvider = StateProvider<bool>((ref) => true);

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
