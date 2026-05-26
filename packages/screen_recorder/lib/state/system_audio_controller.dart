import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current system-audio selection (null = "don't record system
/// audio"). In-memory only — resets to off each launch, mirroring
/// [microphoneControllerProvider].
class SystemAudioController extends StateNotifier<SystemAudioConfig?> {
  SystemAudioController() : super(null);

  void set(SystemAudioConfig? config) {
    if (config != state) state = config;
  }
}

final systemAudioControllerProvider =
    StateNotifierProvider<SystemAudioController, SystemAudioConfig?>(
        (ref) => SystemAudioController());
