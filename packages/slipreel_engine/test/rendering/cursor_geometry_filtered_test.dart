import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Builds a recording with [count] samples at 60 Hz spaced 16667 µs apart,
/// each generated from [build]. Default builder produces a straight
/// horizontal line at y=100, x = i*10, all arrow.
CursorRecording _recording(int count, {CursorPosition Function(int i)? build}) {
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
        cursorAtFiltered(
          rec,
          Duration.zero,
          const CursorPostProcess(endFreezeMs: 100),
        ),
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
      final pastEnd = cursorAtFiltered(
        rec,
        cap + const Duration(milliseconds: 50),
        cfg,
      )!;
      expect(pastEnd.x, closeTo(atCap.x, 1e-6));
      expect(pastEnd.y, closeTo(atCap.y, 1e-6));
    });

    test('queries before the cap are unaffected', () {
      final rec = _recording(60);
      const cfg = CursorPostProcess(endFreezeMs: 200);
      final unfiltered = cursorAt(rec, const Duration(milliseconds: 100));
      final filtered = cursorAtFiltered(
        rec,
        const Duration(milliseconds: 100),
        cfg,
      );
      expect(filtered!.x, closeTo(unfiltered!.x, 1e-9));
      expect(filtered.y, closeTo(unfiltered.y, 1e-9));
    });
  });

  group('cursorAtFiltered — despike', () {
    test('snaps an out-and-back spike onto the neighbour path', () {
      // 5 samples: indices 0..4. Index 2 is a 200-px x excursion that
      // returns immediately (an accessibility "shake"). Baseline moves
      // 0,5,·,15,20 so the neighbour path is a straight line.
      final rec = CursorRecording();
      for (var i = 0; i < 5; i++) {
        final isSpike = i == 2;
        rec.addPosition(
          CursorPosition(
            x: isSpike ? 200 : i * 5.0,
            y: 100,
            timestampMicros: i * 16667,
            isClicked: false,
          ),
        );
      }
      const cfg = CursorPostProcess(removeShakes: true, shakeThresholdPx: 20);
      final spikedT = Duration(microseconds: 2 * 16667);
      final raw = cursorAt(rec, spikedT)!;
      final filtered = cursorAtFiltered(rec, spikedT, cfg)!;
      expect(raw.x, 200, reason: 'raw lookup returns the spiked sample');
      // Neighbours are (5,100) and (15,100); the sample sits at their
      // temporal midpoint, so the corrected point lands on the line at
      // x=10 — not the per-axis median (15) the old filter produced.
      expect(filtered.x, closeTo(10, 1e-6));
      expect(filtered.y, closeTo(100, 1e-6));
    });

    test('snaps using time interpolation, not an unweighted midpoint', () {
      // The spike sample is much closer in time to its previous
      // neighbour than its next one, so the correct on-path point is a
      // 10% blend toward the next neighbour — x=13, not the 40 a
      // per-axis median of [0,10,500,40,50] would pick.
      final rec = CursorRecording()
        ..addPosition(
          const CursorPosition(x: 0, y: 0, timestampMicros: 0),
        )
        ..addPosition(
          const CursorPosition(x: 10, y: 0, timestampMicros: 16667),
        )
        ..addPosition(
          const CursorPosition(x: 500, y: 500, timestampMicros: 20000),
        )
        ..addPosition(
          const CursorPosition(x: 40, y: 0, timestampMicros: 50000),
        )
        ..addPosition(
          const CursorPosition(x: 50, y: 0, timestampMicros: 66667),
        );
      const cfg = CursorPostProcess(removeShakes: true, shakeThresholdPx: 20);
      final filtered = cursorAtFiltered(
        rec,
        const Duration(microseconds: 20000),
        cfg,
      )!;
      expect(filtered.x, closeTo(13, 0.5));
      expect(filtered.y, closeTo(0, 1e-6));
    });

    test('keeps a fast curved path (no false despike on smooth motion)', () {
      // A real-recording arc: consecutive samples travel ~50-100 px and
      // curve smoothly. The middle sample is >20 px off the per-axis
      // median of its window, so the old filter jogged it; the new
      // filter must leave it because the neighbours are far apart (this
      // is genuine travel, not an out-and-back shake).
      final pts = <(double, double)>[
        (492, 1197),
        (451, 1217),
        (400, 1220),
        (335, 1194),
        (268, 1128),
      ];
      final rec = CursorRecording();
      for (var i = 0; i < pts.length; i++) {
        rec.addPosition(
          CursorPosition(
            x: pts[i].$1,
            y: pts[i].$2,
            timestampMicros: i * 16667,
            isClicked: false,
          ),
        );
      }
      const cfg = CursorPostProcess(removeShakes: true, shakeThresholdPx: 20);
      final t = Duration(microseconds: 2 * 16667);
      final raw = cursorAt(rec, t)!;
      final filtered = cursorAtFiltered(rec, t, cfg)!;
      expect(filtered.x, closeTo(raw.x, 1e-6));
      expect(filtered.y, closeTo(raw.y, 1e-6));
    });

    test('keeps a sharp corner (large net travel, not a return)', () {
      // Cursor travels right, then turns 90° and travels down. The
      // corner sample is off the chord between its neighbours, but the
      // neighbours are 200+ px apart, so it is real motion, not a shake.
      final pts = <(double, double)>[
        (0, 0),
        (100, 0),
        (200, 0), // corner
        (200, 100),
        (200, 200),
      ];
      final rec = CursorRecording();
      for (var i = 0; i < pts.length; i++) {
        rec.addPosition(
          CursorPosition(
            x: pts[i].$1,
            y: pts[i].$2,
            timestampMicros: i * 16667,
            isClicked: false,
          ),
        );
      }
      const cfg = CursorPostProcess(removeShakes: true, shakeThresholdPx: 20);
      final t = Duration(microseconds: 2 * 16667);
      final filtered = cursorAtFiltered(rec, t, cfg)!;
      expect(filtered.x, closeTo(200, 1e-6));
      expect(filtered.y, closeTo(0, 1e-6));
    });

    test('leaves real linear motion untouched', () {
      final rec = CursorRecording();
      for (var i = 0; i < 7; i++) {
        rec.addPosition(
          CursorPosition(
            x: i * 200.0,
            y: 0,
            timestampMicros: i * 16667,
            isClicked: false,
          ),
        );
      }
      const cfg = CursorPostProcess(removeShakes: true, shakeThresholdPx: 20);
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
        rec.addPosition(
          CursorPosition(
            x: i.toDouble(),
            y: 0,
            timestampMicros: i * 16667,
            isClicked: false,
            state: i == 6 ? CursorState.iBeam : CursorState.arrow,
          ),
        );
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      final flapT = Duration(microseconds: 6 * 16667);
      final raw = cursorAt(rec, flapT)!;
      final filtered = cursorAtFiltered(rec, flapT, cfg)!;
      expect(
        raw.state,
        CursorState.iBeam,
        reason: 'raw lookup returns the flap state',
      );
      expect(
        filtered.state,
        CursorState.arrow,
        reason: 'debounce returns dominant state of ±60 ms window',
      );
    });

    test('sustained transition (>120 ms) still flips state', () {
      // Arrow for ~100 ms then I-beam for ~200 ms. A query inside the
      // I-beam region should still return I-beam.
      final rec = CursorRecording();
      for (var i = 0; i < 24; i++) {
        rec.addPosition(
          CursorPosition(
            x: i.toDouble(),
            y: 0,
            timestampMicros: i * 16667,
            isClicked: false,
            state: i >= 8 ? CursorState.iBeam : CursorState.arrow,
          ),
        );
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
        rec.addPosition(
          CursorPosition(
            x: i * 10.0,
            y: 50,
            timestampMicros: i * 16667,
            isClicked: false,
            state: i == 6 ? CursorState.iBeam : CursorState.arrow,
          ),
        );
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      final t = Duration(microseconds: 6 * 16667);
      final raw = cursorAt(rec, t)!;
      final filtered = cursorAtFiltered(rec, t, cfg)!;
      expect(filtered.x, closeTo(raw.x, 1e-6));
      expect(filtered.y, closeTo(raw.y, 1e-6));
    });

    test('switches exactly at the sustained run boundary, not before', () {
      // Arrow for the first 10 samples, then a sustained I-beam run
      // (>120 ms). The rendered state must still read arrow at the last
      // arrow sample and flip to I-beam only at the first I-beam sample —
      // the old ±60 ms majority vote flipped it up to half a window early.
      final rec = CursorRecording();
      for (var i = 0; i < 24; i++) {
        rec.addPosition(
          CursorPosition(
            x: i.toDouble(),
            y: 0,
            timestampMicros: i * 16667,
            isClicked: false,
            state: i >= 10 ? CursorState.iBeam : CursorState.arrow,
          ),
        );
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      final lastArrow = cursorAtFiltered(
        rec,
        Duration(microseconds: 9 * 16667),
        cfg,
      )!;
      final firstIBeam = cursorAtFiltered(
        rec,
        Duration(microseconds: 10 * 16667),
        cfg,
      )!;
      expect(lastArrow.state, CursorState.arrow);
      expect(firstIBeam.state, CursorState.iBeam);
    });

    test('does not lead a sustained transition across a sample gap', () {
      // Sparse sampling before the transition: the ±60 ms window would
      // be dominated by the upcoming I-beam run and flip early. The
      // run-length filter keeps arrow until the I-beam run truly starts.
      final rec = CursorRecording()
        ..addPosition(
          const CursorPosition(
            x: 0,
            y: 0,
            timestampMicros: 0,
          ),
        )
        ..addPosition(
          const CursorPosition(
            x: 1,
            y: 0,
            timestampMicros: 50000,
          ),
        )
        ..addPosition(
          const CursorPosition(
            x: 2,
            y: 0,
            timestampMicros: 100000,
          ),
        )
        ..addPosition(
          const CursorPosition(
            x: 3,
            y: 0,
            timestampMicros: 116667,
          ),
        );
      // Sustained I-beam run from 133334 onward (>120 ms).
      for (var i = 0; i < 8; i++) {
        rec.addPosition(
          CursorPosition(
            x: 4 + i.toDouble(),
            y: 0,
            timestampMicros: 133334 + i * 16667,
            isClicked: false,
            state: CursorState.iBeam,
          ),
        );
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      // t sits inside the still-arrow run (nearest sample ≤ t is arrow
      // at 116667); the I-beam run does not begin until 133334.
      final filtered = cursorAtFiltered(
        rec,
        const Duration(microseconds: 125000),
        cfg,
      )!;
      expect(filtered.state, CursorState.arrow);
    });

    test('absorbs a short run between two different states', () {
      // arrow (long) → iBeam (1 sample, a flap) → pointingHand (long).
      // The flap must vanish into the preceding arrow, never flashing
      // I-beam and never previewing the pointing hand early.
      final rec = CursorRecording();
      for (var i = 0; i < 24; i++) {
        final CursorState state;
        if (i < 10) {
          state = CursorState.arrow;
        } else if (i == 10) {
          state = CursorState.iBeam; // one-sample flap
        } else {
          state = CursorState.pointingHand;
        }
        rec.addPosition(
          CursorPosition(
            x: i.toDouble(),
            y: 0,
            timestampMicros: i * 16667,
            isClicked: false,
            state: state,
          ),
        );
      }
      const cfg = CursorPostProcess(optimizeChanges: true);
      final atFlap = cursorAtFiltered(
        rec,
        Duration(microseconds: 10 * 16667),
        cfg,
      )!;
      expect(atFlap.state, CursorState.arrow);
    });
  });

  group('cursorAtFiltered — loop position', () {
    test('eases from the final path position back to the first position', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(x: 10, y: 20, timestampMicros: 0))
        ..addPosition(
          const CursorPosition(x: 110, y: 70, timestampMicros: 1000000),
        )
        ..addPosition(
          const CursorPosition(x: 210, y: 120, timestampMicros: 2000000),
        );
      const cfg = CursorPostProcess(loopPosition: true);
      const end = Duration(seconds: 3);

      final start = cursorAtFiltered(
        rec,
        const Duration(seconds: 2),
        cfg,
        loopEnd: end,
      )!;
      final middle = cursorAtFiltered(
        rec,
        const Duration(milliseconds: 2500),
        cfg,
        loopEnd: end,
      )!;
      final finish = cursorAtFiltered(rec, end, cfg, loopEnd: end)!;

      expect(start.x, 210);
      expect(start.y, 120);
      expect(middle.x, closeTo(110, 1e-9));
      expect(middle.y, closeTo(70, 1e-9));
      expect(finish.x, 10);
      expect(finish.y, 20);
      expect(
        middle.isClicked,
        isFalse,
        reason: 'the synthetic return must not manufacture clicks',
      );
    });

    test('an explicit trimmed end starts and finishes the loop earlier', () {
      final rec = _recording(181); // ~3 seconds of source cursor data.
      const cfg = CursorPostProcess(loopPosition: true);
      const trimmedEnd = Duration(seconds: 2);

      final finish = cursorAtFiltered(
        rec,
        trimmedEnd,
        cfg,
        loopEnd: trimmedEnd,
      )!;
      expect(finish.x, rec.positions.first.x);
      expect(finish.y, rec.positions.first.y);
    });
  });

  group('cursorVisibleAt — hide when idle', () {
    CursorRecording stationary({bool clickAtOneSecond = false}) {
      final rec = CursorRecording();
      for (var i = 0; i <= 30; i++) {
        rec.addPosition(
          CursorPosition(
            x: 50,
            y: 75,
            timestampMicros: i * 100000,
            isClicked: clickAtOneSecond && i == 10,
          ),
        );
      }
      return rec;
    }

    test('shows initially, then hides after one second without movement', () {
      final rec = stationary();
      const cfg = CursorPostProcess(hideWhenIdle: true);

      expect(
        cursorVisibleAt(rec, const Duration(milliseconds: 500), cfg),
        isTrue,
      );
      expect(
        cursorVisibleAt(rec, const Duration(milliseconds: 1500), cfg),
        isFalse,
      );
    });

    test('recent movement keeps the cursor visible', () {
      final rec = CursorRecording();
      for (var i = 0; i <= 30; i++) {
        rec.addPosition(
          CursorPosition(
            x: i < 11 ? 50 : 70,
            y: 75,
            timestampMicros: i * 100000,
          ),
        );
      }
      const cfg = CursorPostProcess(hideWhenIdle: true);

      expect(
        cursorVisibleAt(rec, const Duration(milliseconds: 1800), cfg),
        isTrue,
      );
      expect(
        cursorVisibleAt(rec, const Duration(milliseconds: 2201), cfg),
        isFalse,
      );
    });

    test('a recent click keeps a stationary cursor visible', () {
      final rec = stationary(clickAtOneSecond: true);
      const cfg = CursorPostProcess(hideWhenIdle: true);

      expect(
        cursorVisibleAt(rec, const Duration(milliseconds: 1500), cfg),
        isTrue,
      );
      expect(
        cursorVisibleAt(rec, const Duration(milliseconds: 2101), cfg),
        isFalse,
      );
    });

    test('the synthetic loop is treated as visible movement', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(x: 0, y: 0, timestampMicros: 0))
        ..addPosition(
          const CursorPosition(x: 100, y: 0, timestampMicros: 2000000),
        );
      const cfg = CursorPostProcess(hideWhenIdle: true, loopPosition: true);

      expect(
        cursorVisibleAt(
          rec,
          const Duration(milliseconds: 2500),
          cfg,
          loopEnd: const Duration(seconds: 3),
        ),
        isTrue,
      );
    });

    test('vanishes with a cubic fade after the idle timeout', () {
      final rec = stationary();
      const cfg = CursorPostProcess(hideWhenIdle: true);

      expect(cursorRevealAt(rec, const Duration(milliseconds: 1000), cfg), 1.0);
      final midway = cursorRevealAt(
        rec,
        const Duration(milliseconds: 1140),
        cfg,
      );
      expect(midway, closeTo(0.125, 0.002));
      expect(cursorRevealAt(rec, const Duration(milliseconds: 1281), cfg), 0.0);
    });

    test('appearance is the reverse blur/fade envelope', () {
      final rec = CursorRecording()
        ..addPosition(const CursorPosition(x: 50, y: 75, timestampMicros: 0))
        ..addPosition(
          const CursorPosition(x: 50, y: 75, timestampMicros: 1999999),
        )
        ..addPosition(
          const CursorPosition(x: 70, y: 75, timestampMicros: 2000000),
        )
        ..addPosition(
          const CursorPosition(x: 70, y: 75, timestampMicros: 3000000),
        );
      const cfg = CursorPostProcess(hideWhenIdle: true);

      expect(cursorRevealAt(rec, const Duration(milliseconds: 1900), cfg), 0.0);
      final midway = cursorRevealAt(
        rec,
        const Duration(milliseconds: 2140),
        cfg,
      );
      expect(midway, closeTo(0.875, 0.002));
      expect(cursorRevealAt(rec, const Duration(milliseconds: 2281), cfg), 1.0);
    });

    test('disabled hide-when-idle stays fully revealed', () {
      expect(
        cursorRevealAt(
          CursorRecording(),
          const Duration(seconds: 5),
          CursorPostProcess.none,
        ),
        1.0,
      );
    });

    test('vanish expands and appearance settles to original size', () {
      expect(cursorIdleScaleForReveal(0), closeTo(1.28, 1e-9));
      expect(cursorIdleScaleForReveal(0.5), closeTo(1.14, 1e-9));
      expect(cursorIdleScaleForReveal(1), 1.0);
      expect(cursorIdleScaleForReveal(-1), closeTo(1.28, 1e-9));
      expect(cursorIdleScaleForReveal(2), 1.0);
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
      expect(cfg.shakeThresholdPx, CursorPostProcess.defaultShakeThresholdPx);
      expect(cfg.optimizeChanges, false);
      expect(cfg.hideWhenIdle, false);
      expect(cfg.loopPosition, false);
      expect(cfg.isActive, false);
    });

    test('roundtrip', () {
      const cfg = CursorPostProcess(
        endFreezeMs: 750,
        removeShakes: true,
        shakeThresholdPx: 35,
        optimizeChanges: true,
        hideWhenIdle: true,
        loopPosition: true,
      );
      final r = CursorPostProcess.fromJson(cfg.toJson());
      expect(r, cfg);
      expect(r.isActive, true);
    });
  });
}
