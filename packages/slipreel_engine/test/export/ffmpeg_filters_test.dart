// packages/slipreel_engine/test/export/ffmpeg_filters_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_filters.dart';

void main() {
  group('ffSeconds', () {
    test('formats microseconds to 6-decimal seconds', () {
      expect(ffSeconds(const Duration(milliseconds: 1500)), '1.500000');
      expect(ffSeconds(Duration.zero), '0.000000');
    });
  });

  group('setptsForSpeed', () {
    test('emits PTS division by the speed', () {
      expect(setptsForSpeed(2.0), 'setpts=PTS/2.0');
      expect(setptsForSpeed(0.5), 'setpts=PTS/0.5');
    });
  });

  group('atempoChain', () {
    test('single factor when within [0.5, 2.0]', () {
      expect(atempoChain(1.5), [closeTo(1.5, 1e-9)]);
      expect(atempoChain(2.0), [closeTo(2.0, 1e-9)]);
      expect(atempoChain(0.5), [closeTo(0.5, 1e-9)]);
    });
    test('decomposes >2.0 into chained factors', () {
      final c = atempoChain(4.0);
      expect(c.length, 2);
      expect(c.reduce((a, b) => a * b), closeTo(4.0, 1e-9));
      expect(c.every((f) => f >= 0.5 && f <= 2.0), isTrue);
    });
    test('decomposes <0.5 into chained factors', () {
      final c = atempoChain(0.25);
      expect(c.reduce((a, b) => a * b), closeTo(0.25, 1e-9));
      expect(c.every((f) => f >= 0.5 && f <= 2.0), isTrue);
    });
  });

  group('speedAtempo', () {
    test('joins atempo filters with comma', () {
      expect(speedAtempo(1.5), 'atempo=1.5');
      expect(speedAtempo(4.0), 'atempo=2.0,atempo=2.0');
    });
  });
}
