// packages/screen_recorder/lib/state/recording_settings_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'recording_settings_store.dart';

class RecordingSettingsController extends StateNotifier<RecordingSettings> {
  RecordingSettingsController({required this.store, required RecordingSettings initial})
      : super(initial);

  final RecordingSettingsStore store;

  static const _validCountdowns = {0, 3, 5};

  Future<void> setCountdownSeconds(int seconds) async {
    if (!_validCountdowns.contains(seconds)) return;
    state = state.copyWith(countdownSeconds: seconds);
    await store.save(state);
  }
}

final recordingSettingsStoreProvider = Provider<RecordingSettingsStore>(
  (ref) => throw UnimplementedError(
    'Override recordingSettingsStoreProvider in main()',
  ),
);

final recordingSettingsControllerProvider =
    StateNotifierProvider<RecordingSettingsController, RecordingSettings>(
  (ref) => throw UnimplementedError(
    'Override recordingSettingsControllerProvider in main()',
  ),
);
