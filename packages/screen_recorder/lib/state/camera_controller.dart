import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current camera selection (null = "don't record camera").
/// Seeded from [initial] (the last-used selection) and reports changes via
/// [onChanged] so callers can persist the new selection, mirroring
/// MicrophoneController.
class CameraController extends StateNotifier<CameraConfig?> {
  CameraController({CameraConfig? initial, this.onChanged}) : super(initial);

  final void Function(CameraConfig?)? onChanged;

  void set(CameraConfig? config) {
    if (config != state) {
      state = config;
      onChanged?.call(config);
    }
  }
}

final cameraControllerProvider =
    StateNotifierProvider<CameraController, CameraConfig?>(
        (ref) => CameraController());
