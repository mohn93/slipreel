import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  group('ClipSlice', () {
    test('constructor clamps gain to 0..200', () {
      final s = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        micGainPercent: -50,
        systemGainPercent: 300,
      );
      expect(s.micGainPercent, 0);
      expect(s.systemGainPercent, 200);
    });

    test('effectiveLength returns trimEnd - trimStart', () {
      final s = ClipSlice(
        cutStart: const Duration(seconds: 2),
        cutEnd: const Duration(seconds: 7),
      );
      expect(s.effectiveLength, const Duration(seconds: 5));
    });

    test('copyWith preserves unchanged fields', () {
      final s = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
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
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final b = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      expect(a == b, isTrue);
      expect(a.hashCode == b.hashCode, isTrue);
    });

    test('== false when any field differs', () {
      final a = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final b = a.copyWith(playbackSpeed: 2.0);
      expect(a == b, isFalse);
    });

    test('toJson then fromJson round-trips all fields', () {
      final s = ClipSlice(
        cutStart: const Duration(seconds: 1, milliseconds: 500),
        cutEnd: const Duration(seconds: 9, milliseconds: 250),
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
        'cutStartMicros': 0,
        'cutEndMicros': 10_000_000,
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

    test('fromJson tolerates non-numeric optional fields by using defaults',
        () {
      final s = ClipSlice.fromJson({
        'cutStartMicros': 0,
        'cutEndMicros': 10_000_000,
        'playbackSpeed': 'fast',     // wrong type
        'micMuted': 'yes',           // wrong type
        'micGainPercent': null,      // wrong type
      });
      expect(s.playbackSpeed, 1.0);
      expect(s.micMuted, isFalse);
      expect(s.micGainPercent, 100);
    });

    test('copyWith re-applies the gain clamp', () {
      final s = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final next = s.copyWith(micGainPercent: 999, systemGainPercent: -5);
      expect(next.micGainPercent, 200);
      expect(next.systemGainPercent, 0);
    });
  });

  group('Timeline.clips', () {
    test('defaults to an empty clip list', () {
      final t = Timeline.defaults();
      expect(t.clips, isEmpty);
    });

    test('copyWith replaces clips', () {
      final t = Timeline.defaults();
      final clips = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 10)),
      ];
      final next = t.copyWith(clips: clips);
      expect(next.clips, hasLength(1));
      expect(next.clips.first.effectiveLength, const Duration(seconds: 10));
    });

    test('toJson + fromJson round-trip preserves clips', () {
      final clips = [
        ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 5),
          playbackSpeed: 1.5,
        ),
        ClipSlice(
          cutStart: const Duration(seconds: 5),
          cutEnd: const Duration(seconds: 10),
          micMuted: true,
        ),
      ];
      final t = Timeline(clips: clips);
      final round = Timeline.fromJson(t.toJson());
      expect(round.clips, hasLength(2));
      expect(round.clips, equals(clips));
    });

    test('fromJson tolerates a missing clips key', () {
      final t = Timeline.fromJson({'zoomTracks': []});
      expect(t.clips, isEmpty);
    });
  });

  group('clipSliceAt', () {
    test('returns the slice containing the position', () {
      final clips = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 5)),
        ClipSlice(
          cutStart: const Duration(seconds: 5),
          cutEnd: const Duration(seconds: 10),
        ),
      ];
      expect(
        clipSliceAt(clips, const Duration(seconds: 3)).end,
        const Duration(seconds: 5),
      );
      expect(
        clipSliceAt(clips, const Duration(seconds: 7)).start,
        const Duration(seconds: 5),
      );
    });
    test('returns the last slice when position is past the end', () {
      final clips = [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 5)),
        ClipSlice(
          cutStart: const Duration(seconds: 5),
          cutEnd: const Duration(seconds: 10),
        ),
      ];
      expect(
        clipSliceAt(clips, const Duration(seconds: 20)).end,
        const Duration(seconds: 10),
      );
    });
    test('returns an empty fallback when clips is empty', () {
      final s = clipSliceAt(const [], const Duration(seconds: 1));
      expect(s.end, Duration.zero);
    });
  });
}
