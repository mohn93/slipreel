import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Holds the current system-audio selection (null = "don't record system
/// audio"). Seeded from [initial] (the last-used selection) and reports
/// changes via [onChanged] so callers can persist the new selection,
/// mirroring [microphoneControllerProvider].
class SystemAudioController extends StateNotifier<SystemAudioConfig?> {
  SystemAudioController({SystemAudioConfig? initial, this.onChanged})
      : super(initial);

  final void Function(SystemAudioConfig?)? onChanged;

  void set(SystemAudioConfig? config) {
    if (config != state) {
      state = config;
      onChanged?.call(config);
    }
  }
}

final systemAudioControllerProvider =
    StateNotifierProvider<SystemAudioController, SystemAudioConfig?>(
        (ref) => SystemAudioController());
