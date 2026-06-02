import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

void main() {
  group('ClipSlice', () {
    test('constructor clamps gain to 0..200', () {
      final s = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
        micGainPercent: -50,
        systemGainPercent: 300,
      );
      expect(s.micGainPercent, 0);
      expect(s.systemGainPercent, 200);
    });

    test('length returns end - start', () {
      final s = ClipSlice(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 7),
      );
      expect(s.length, const Duration(seconds: 5));
    });

    test('copyWith preserves unchanged fields', () {
      final s = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
        playbackSpeed: 1.5,
        hideCursor: true,
      );
      final next = s.copyWith(playbackSpeed: 2.0);
      expect(next.playbackSpeed, 2.0);
      expect(next.start, s.start);
      expect(next.end, s.end);
      expect(next.hideCursor, true);
    });

    test('== is value-based; equal slices are equal', () {
      final a = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final b = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      expect(a == b, isTrue);
      expect(a.hashCode == b.hashCode, isTrue);
    });

    test('== false when any field differs', () {
      final a = ClipSlice(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final b = a.copyWith(playbackSpeed: 2.0);
      expect(a == b, isFalse);
    });

    test('toJson then fromJson round-trips all fields', () {
      final s = ClipSlice(
        start: const Duration(seconds: 1, milliseconds: 500),
        end: const Duration(seconds: 9, milliseconds: 250),
        playbackSpeed: 1.75,
        fadeIn: const Duration(milliseconds: 500),
        fadeOut: const Duration(milliseconds: 250),
        micGainPercent: 120,
        micMuted: true,
        systemGainPercent: 80,
        systemMuted: false,
        hideCursor: true,
        disableSmoothMouse: true,
      );
      final round = ClipSlice.fromJson(s.toJson());
      expect(round, s);
    });

    test('fromJson defaults missing optional keys', () {
      final s = ClipSlice.fromJson({
        'startMicros': 0,
        'endMicros': 10_000_000,
      });
      expect(s.playbackSpeed, 1.0);
      expect(s.fadeIn, Duration.zero);
      expect(s.fadeOut, Duration.zero);
      expect(s.micGainPercent, 100);
      expect(s.micMuted, isFalse);
      expect(s.systemGainPercent, 100);
      expect(s.systemMuted, isFalse);
      expect(s.hideCursor, isFalse);
      expect(s.disableSmoothMouse, isFalse);
    });

    test('fromJson throws when bounds are missing', () {
      expect(
        () => ClipSlice.fromJson({}),
        throwsFormatException,
      );
    });
  });
}
