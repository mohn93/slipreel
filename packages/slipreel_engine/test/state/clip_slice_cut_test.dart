import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

void main() {
  group('ClipSlice cut/trim fields', () {
    test('constructor stores cutStart/cutEnd; trimStart/trimEnd default to cut bounds', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      expect(c.cutStart, Duration.zero);
      expect(c.cutEnd, const Duration(seconds: 10));
      expect(c.trimStart, Duration.zero);
      expect(c.trimEnd, const Duration(seconds: 10));
    });

    test('explicit trimStart/trimEnd are stored when within cut bounds', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 2),
        trimEnd: const Duration(seconds: 8),
      );
      expect(c.trimStart, const Duration(seconds: 2));
      expect(c.trimEnd, const Duration(seconds: 8));
    });

    test('trimStart below cutStart clamps up to cutStart', () {
      final c = ClipSlice(
        cutStart: const Duration(seconds: 1),
        cutEnd: const Duration(seconds: 10),
        trimStart: Duration.zero,
        trimEnd: const Duration(seconds: 8),
      );
      expect(c.trimStart, const Duration(seconds: 1));
    });

    test('trimEnd above cutEnd clamps down to cutEnd', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 2),
        trimEnd: const Duration(seconds: 20),
      );
      expect(c.trimEnd, const Duration(seconds: 10));
    });

    test('trim range below 100 ms clamps trimEnd up to trimStart + 100ms', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 5),
        trimEnd: const Duration(seconds: 5, milliseconds: 50),
      );
      expect(c.trimEnd, const Duration(seconds: 5, milliseconds: 100));
    });

    test('start/end getters alias trimStart/trimEnd for B-era callers', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 2),
        trimEnd: const Duration(seconds: 8),
      );
      expect(c.start, c.trimStart);
      expect(c.end, c.trimEnd);
    });

    test('effectiveLength = trimEnd - trimStart', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 2),
        trimEnd: const Duration(seconds: 7),
      );
      expect(c.effectiveLength, const Duration(seconds: 5));
    });

    test('cutSpan = cutEnd - cutStart', () {
      final c = ClipSlice(
        cutStart: const Duration(seconds: 1),
        cutEnd: const Duration(seconds: 10),
      );
      expect(c.cutSpan, const Duration(seconds: 9));
    });

    test('isLeftTrimmed true only when trimStart > cutStart', () {
      final untrimmed = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final trimmed = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimStart: const Duration(seconds: 2),
      );
      expect(untrimmed.isLeftTrimmed, false);
      expect(trimmed.isLeftTrimmed, true);
    });

    test('isRightTrimmed true only when trimEnd < cutEnd', () {
      final untrimmed = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final trimmed = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimEnd: const Duration(seconds: 8),
      );
      expect(untrimmed.isRightTrimmed, false);
      expect(trimmed.isRightTrimmed, true);
    });

    test('copyWith preserves all fields by default', () {
      final c = ClipSlice(
        cutStart: const Duration(seconds: 1),
        cutEnd: const Duration(seconds: 9),
        trimStart: const Duration(seconds: 2),
        trimEnd: const Duration(seconds: 8),
        playbackSpeed: 2.0,
        micGainPercent: 50,
        hideCursor: true,
      );
      final c2 = c.copyWith();
      expect(c2, c);
    });

    test('copyWith can change cut and trim independently', () {
      final c = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final c2 = c.copyWith(trimEnd: const Duration(seconds: 7));
      expect(c2.cutEnd, const Duration(seconds: 10));
      expect(c2.trimEnd, const Duration(seconds: 7));
    });

    test('toJson emits cutStart/cutEnd/trimStart/trimEnd in micros', () {
      final c = ClipSlice(
        cutStart: const Duration(seconds: 1),
        cutEnd: const Duration(seconds: 9),
        trimStart: const Duration(seconds: 2),
        trimEnd: const Duration(seconds: 8),
      );
      final j = c.toJson();
      expect(j['cutStartMicros'], 1000000);
      expect(j['cutEndMicros'], 9000000);
      expect(j['trimStartMicros'], 2000000);
      expect(j['trimEndMicros'], 8000000);
      expect(j.containsKey('startMicros'), false);
      expect(j.containsKey('endMicros'), false);
    });

    test('fromJson reads cut/trim fields; missing trim defaults to cut', () {
      final j = {
        'cutStartMicros': 1000000,
        'cutEndMicros': 9000000,
        // trim fields absent
      };
      final c = ClipSlice.fromJson(j);
      expect(c.cutStart, const Duration(seconds: 1));
      expect(c.trimStart, const Duration(seconds: 1));
      expect(c.trimEnd, const Duration(seconds: 9));
    });

    test('fromJson throws when cutStart/cutEnd missing', () {
      expect(
        () => ClipSlice.fromJson(<String, dynamic>{}),
        throwsA(isA<FormatException>()),
      );
    });

    test('==/hashCode include all cut and trim fields', () {
      final base = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
      );
      final diffCut = ClipSlice(
        cutStart: const Duration(milliseconds: 100),
        cutEnd: const Duration(seconds: 10),
      );
      final diffTrim = ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 10),
        trimEnd: const Duration(seconds: 9),
      );
      expect(base == diffCut, false);
      expect(base == diffTrim, false);
      expect(base.hashCode == diffCut.hashCode, false);
    });
  });
}
