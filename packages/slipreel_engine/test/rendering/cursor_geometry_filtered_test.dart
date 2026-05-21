import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Builds a recording with [count] samples at 60 Hz spaced 16667 µs apart,
/// each generated from [build]. Default builder produces a straight
/// horizontal line at y=100, x = i*10, all arrow.
CursorRecording _recording(
  int count, {
  CursorPosition Function(int i)? build,
}) {
  final rec = CursorRecording();
  for (var i = 0; i < count; i++) {
    rec.addPosition(
      build?.call(i) ??
          CursorPosition(
            x: i * 10.0,
            y: 100,
            timestampMicros: i * 16667,
            isClicked: false,
            state: CursorState.arrow,
          ),
    );
  }
  return rec;
}

void main() {
  group('cursorAtFiltered — passthrough', () {
    test('inactive config returns identical result to cursorAt', () {
      final rec = _recording(20);
      const cfg = CursorPostProcess.none;
      for (final ms in const [16, 100, 250]) {
        final a = cursorAt(rec, Duration(milliseconds: ms));
        final b = cursorAtFiltered(rec, Duration(milliseconds: ms), cfg);
        expect(b!.x, closeTo(a!.x, 1e-9));
        expect(b.y, closeTo(a.y, 1e-9));
        expect(b.state, a.state);
      }
    });

    test('returns null for empty recording', () {
      final rec = CursorRecording();
      expect(
        cursorAtFiltered(rec, Duration.zero,
            const CursorPostProcess(endFreezeMs: 100)),
        isNull,
      );
    });
  });

  group('cursorAtFiltered — end-freeze', () {
    test('queries past `lastTs − freezeMs` return cap result', () {
      final rec = _recording(60); // 0..59 → ts 0..983333
      const cfg = CursorPostProcess(endFreezeMs: 200);
      final lastTs = rec.positions.last.timestampMicros;
      final cap = Duration(microseconds: lastTs - 200_000);

      // Query 50 ms past the end — should be clamped to the cap and
      // return the same x/y as querying at the cap directly.
      final atCap = cursorAtFiltered(rec, cap, cfg)!;
      final pastEnd =
          cursorAtFiltered(rec, cap + const Duration(milliseconds: 50), cfg)!;
      expect(pastEnd.x, closeTo(atCap.x, 1e-6));
      expect(pastEnd.y, closeTo(atCap.y, 1e-6));
    });

    test('queries before the cap are unaffected', () {
      final rec = _recording(60);
      const cfg = CursorPostProcess(endFreezeMs: 200);
      final unfiltered = cursorAt(rec, const Duration(milliseconds: 100));
      final filtered =
          cursorAtFiltered(rec, const Duration(milliseconds: 100), cfg);
      expect(filtered!.x, closeTo(unfiltered!.x, 1e-9));
      expect(filtered.y, closeTo(unfiltered.y, 1e-9));
    });
  });

  group('cursorAtFiltered — despike', () {
    test('replaces a single-sample spike with the local median', () {
      // 5 samples: indices 0..4. Index 2 is a 100-px x spike.
      final rec = CursorRecording();
      for (var i = 0; i < 5; i++) {
        final isSpike = i == 2;
        rec.addPosition(CursorPosition(
          x: isSpike ? 200 : i * 5.0, // baseline 0,5,10,15,20; spike 200
          y: 100,
          timestampMicros: i * 16667,
          isClicked: false,
        ));
      }
      const cfg = CursorPostProcess(
        removeShakes: true,
        shakeThresholdPx: 20,
      );
      final spikedT = Duration(microseconds: 2 * 16667);
      final raw = cursorAt(rec, spikedT)!;
      final filtered = cursorAtFiltered(rec, spikedT, cfg)!;
      expect(raw.x, 200, reason: 'raw lookup returns the spiked sample');
      // 5-sample window x = [0, 5, 200, 15, 20] → sorted = [0, 5, 15,
      // 20, 200] → median = 15. Filtered output should land on the
      // median, not the spike.
      expect(filtered.x, closeTo(15, 1e-6));
    });

    test('leaves real motion untouched (no false-positive despike)', () {
      // Linear motion at 200 px between samples — well above threshold,
      // but consecutive samples cluster around the trend so each sample's
      // own value is also the median of its neighbourhood.
      final rec = CursorRecording();
      for (var i = 0; i < 7; i++) {
        rec.addPosition(CursorPosition(
          x: i * 200.0, // 0, 200, 400, 600, ...
          y: 0,
          timestampMicros: i * 16667,
          isClicked: false,
        ));
      }
      const cfg = CursorPostProcess(
        removeShakes: true,
        shakeThresholdPx: 20,
      );
      final t = Duration(microseconds: 3 * 16667);
      final raw = cursorAt(rec, t)!;
      final filtered = cursorAtFiltered(rec, t, cfg)!;
      expect(filtered.x, closeTo(raw.x, 1e-6));
    });
  });

  group('cursorAtFiltered — state debounce', () {
    test('sub-window flap is replaced with dominant state', () {
      // Mostly arrow with a single I-beam flap (1 sample = 16 ms,
      // narrower than the 120 ms window). The query lands on the flap.
      final rec = CursorRecording();
      for (var i = 0; i < 12; i++) {
        rec.addPosition(CursorPosition(
          x: i.toDouble(),
          y: 0,
          timestampMicros: i * 16667,
          isClicked: false,
          state: i == 6 ? CursorState.iBeam : CursorState.arrow,
        ));
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      final flapT = Duration(microseconds: 6 * 16667);
      final raw = cursorAt(rec, flapT)!;
      final filtered = cursorAtFiltered(rec, flapT, cfg)!;
      expect(raw.state, CursorState.iBeam,
          reason: 'raw lookup returns the flap state');
      expect(filtered.state, CursorState.arrow,
          reason: 'debounce returns dominant state of ±60 ms window');
    });

    test('sustained transition (>120 ms) still flips state', () {
      // Arrow for ~100 ms then I-beam for ~200 ms. A query inside the
      // I-beam region should still return I-beam.
      final rec = CursorRecording();
      for (var i = 0; i < 24; i++) {
        rec.addPosition(CursorPosition(
          x: i.toDouble(),
          y: 0,
          timestampMicros: i * 16667,
          isClicked: false,
          state: i >= 8 ? CursorState.iBeam : CursorState.arrow,
        ));
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      // Deep inside the I-beam region — 200+ ms past the transition.
      final deepT = Duration(microseconds: 20 * 16667);
      final filtered = cursorAtFiltered(rec, deepT, cfg)!;
      expect(filtered.state, CursorState.iBeam);
    });

    test('position is unaffected by state-debounce', () {
      final rec = CursorRecording();
      for (var i = 0; i < 12; i++) {
        rec.addPosition(CursorPosition(
          x: i * 10.0,
          y: 50,
          timestampMicros: i * 16667,
          isClicked: false,
          state: i == 6 ? CursorState.iBeam : CursorState.arrow,
        ));
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      final t = Duration(microseconds: 6 * 16667);
      final raw = cursorAt(rec, t)!;
      final filtered = cursorAtFiltered(rec, t, cfg)!;
      expect(filtered.x, closeTo(raw.x, 1e-6));
      expect(filtered.y, closeTo(raw.y, 1e-6));
    });
  });

  group('CursorPostProcess fromJson', () {
    test('clamps endFreezeMs to [0, max]', () {
      final cfg = CursorPostProcess.fromJson({'endFreezeMs': 10000});
      expect(cfg.endFreezeMs, CursorPostProcess.endFreezeMaxMs);
      final neg = CursorPostProcess.fromJson({'endFreezeMs': -500});
      expect(neg.endFreezeMs, 0);
    });

    test('clamps shakeThresholdPx to [1, 100]', () {
      final hi = CursorPostProcess.fromJson({'shakeThresholdPx': 500.0});
      expect(hi.shakeThresholdPx, 100.0);
      final lo = CursorPostProcess.fromJson({'shakeThresholdPx': 0.0});
      expect(lo.shakeThresholdPx, 1.0);
    });

    test('missing fields → defaults', () {
      final cfg = CursorPostProcess.fromJson(<String, dynamic>{});
      expect(cfg.endFreezeMs, 0);
      expect(cfg.removeShakes, false);
      expect(cfg.shakeThresholdPx,
          CursorPostProcess.defaultShakeThresholdPx);
      expect(cfg.optimizeChanges, false);
      expect(cfg.isActive, false);
    });

    test('roundtrip', () {
      const cfg = CursorPostProcess(
        endFreezeMs: 750,
        removeShakes: true,
        shakeThresholdPx: 35,
        optimizeChanges: true,
      );
      final r = CursorPostProcess.fromJson(cfg.toJson());
      expect(r, cfg);
      expect(r.isActive, true);
    });
  });
}
