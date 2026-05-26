import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/system_audio_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('starts off, then transitions all -> selected -> off', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(systemAudioControllerProvider.notifier);

    expect(container.read(systemAudioControllerProvider), isNull);

    notifier.set(const SystemAudioConfig(mode: SystemAudioMode.allApps));
    expect(container.read(systemAudioControllerProvider)!.mode,
        SystemAudioMode.allApps);

    notifier.set(const SystemAudioConfig(
        mode: SystemAudioMode.selectedApps, bundleIds: ['com.apple.Music']));
    expect(container.read(systemAudioControllerProvider)!.bundleIds,
        ['com.apple.Music']);

    notifier.set(null);
    expect(container.read(systemAudioControllerProvider), isNull);
  });
}
