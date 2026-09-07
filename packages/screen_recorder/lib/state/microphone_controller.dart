import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current microphone selection (null = "don't record microphone").
/// Seeded from [initial] (the last-used selection) and reports changes via
/// [onChanged] so callers can persist the new selection.
class MicrophoneController extends StateNotifier<MicrophoneConfig?> {
  MicrophoneController({MicrophoneConfig? initial, this.onChanged})
      : super(initial);

  final void Function(MicrophoneConfig?)? onChanged;

  void set(MicrophoneConfig? config) {
    if (config != state) {
      state = config;
      onChanged?.call(config);
    }
  }
}

final microphoneControllerProvider =
    StateNotifierProvider<MicrophoneController, MicrophoneConfig?>(
        (ref) => MicrophoneController());
