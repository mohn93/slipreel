// packages/screen_recorder/lib/state/permissions_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

/// Immutable snapshot of all permission states.
class PermissionsSnapshot {
  const PermissionsSnapshot(this.byKind);

  final Map<PermissionKind, PermissionStatus> byKind;

  PermissionStatus get screenRec =>
      byKind[PermissionKind.screenRecording] ?? PermissionStatus.unsupported;
  PermissionStatus get microphone =>
      byKind[PermissionKind.microphone] ?? PermissionStatus.unsupported;
  PermissionStatus get accessibility =>
      byKind[PermissionKind.accessibility] ?? PermissionStatus.unsupported;
  PermissionStatus get camera =>
      byKind[PermissionKind.camera] ?? PermissionStatus.unsupported;

  static const PermissionsSnapshot initial = PermissionsSnapshot({
    PermissionKind.screenRecording: PermissionStatus.unsupported,
    PermissionKind.microphone: PermissionStatus.unsupported,
    PermissionKind.accessibility: PermissionStatus.unsupported,
    PermissionKind.camera: PermissionStatus.unsupported,
  });
}

/// The single source of truth for permission state in the app.
/// Read by onboarding, the deny sheet, and RecordingController.
class PermissionsController extends StateNotifier<PermissionsSnapshot> {
  PermissionsController(this._platform) : super(PermissionsSnapshot.initial);

  final ScreenRecorderPlatform _platform;

  Future<void> refreshAll() async {
    try {
      final results = await Future.wait([
        _platform.getScreenRecordingPermission(),
        _platform.getMicrophonePermission(),
        _platform.getAccessibilityPermission(),
        _platform.getCameraPermission(),
      ]);
      state = PermissionsSnapshot({
        PermissionKind.screenRecording: results[0],
        PermissionKind.microphone: results[1],
        PermissionKind.accessibility: results[2],
        PermissionKind.camera: results[3],
      });
    } catch (e, st) {
      AppLogger.permissions.e('refreshAll failed', error: e, stackTrace: st);
      // Leave state alone — keep last good snapshot.
    }
  }

  Future<PermissionStatus> request(PermissionKind kind) async {
    PermissionStatus result;
    switch (kind) {
      case PermissionKind.screenRecording:
        result = await _platform.requestScreenRecordingPermission();
      case PermissionKind.microphone:
        result = await _platform.requestMicrophonePermission();
      case PermissionKind.accessibility:
        // AX request opens System Settings; status updates after the
        // user toggles + the app is relaunched OR resumes.
        await _platform.requestAccessibilityPermission();
        result = await _platform.getAccessibilityPermission();
      case PermissionKind.camera:
        result = await _platform.requestCameraPermission();
    }
    state = PermissionsSnapshot({
      ...state.byKind,
      kind: result,
    });
    return result;
  }
}

final permissionsControllerProvider =
    StateNotifierProvider<PermissionsController, PermissionsSnapshot>(
  (ref) => throw UnimplementedError(
    'Override permissionsControllerProvider in main() with a real instance',
  ),
);
