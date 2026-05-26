import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

void main() {
  test('defaults to empty and accepts an update', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(recordingAudioStreamsProvider), isEmpty);
    c.read(recordingAudioStreamsProvider.notifier).state = [
      const AudioStreamInfo(index: 0, channels: 1, codecName: 'aac'),
    ];
    expect(c.read(recordingAudioStreamsProvider).single.channels, 1);
  });
}
