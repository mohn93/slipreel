import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('AudioData', () {
    test('should serialize to JSON correctly', () {
      final audioData = AudioData(
        data: Uint8List.fromList([0, 1, 2, 3]),
        sampleRate: 48000,
        channels: 2,
        timestampMicros: 1000000,
      );

      final json = audioData.toJson();

      expect(json['data'], Uint8List.fromList([0, 1, 2, 3]));
      expect(json['sampleRate'], 48000);
      expect(json['channels'], 2);
      expect(json['timestampMicros'], 1000000);
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'data': Uint8List.fromList([0, 1, 2, 3]),
        'sampleRate': 48000,
        'channels': 2,
        'timestampMicros': 1000000,
      };

      final audioData = AudioData.fromJson(json);

      expect(audioData.data, Uint8List.fromList([0, 1, 2, 3]));
      expect(audioData.sampleRate, 48000);
      expect(audioData.channels, 2);
      expect(audioData.timestampMicros, 1000000);
    });
  });
}
