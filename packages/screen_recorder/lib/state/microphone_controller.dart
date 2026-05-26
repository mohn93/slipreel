import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current microphone selection (null = "don't record microphone").
/// In-memory only — resets to off each launch (the spec's launch default).
class MicrophoneController extends StateNotifier<MicrophoneConfig?> {
  MicrophoneController() : super(null);

  void set(MicrophoneConfig? config) {
    if (config != state) state = config;
  }
}

final microphoneControllerProvider =
    StateNotifierProvider<MicrophoneController, MicrophoneConfig?>(
        (ref) => MicrophoneController());
