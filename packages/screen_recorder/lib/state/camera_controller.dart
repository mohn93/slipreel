import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current camera selection (null = "don't record camera").
/// In-memory only — resets to off each launch, mirroring MicrophoneController.
class CameraController extends StateNotifier<CameraConfig?> {
  CameraController() : super(null);

  void set(CameraConfig? config) {
    if (config != state) state = config;
  }
}

final cameraControllerProvider =
    StateNotifierProvider<CameraController, CameraConfig?>(
        (ref) => CameraController());
